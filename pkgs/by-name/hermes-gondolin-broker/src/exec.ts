/**
 * Guest execution (V3 §13.3).
 *
 * - Argument arrays by default; shell execution is an explicit flag.
 * - Working directory resolves under the environment's authorized guest
 *   workspace path.
 * - Environment variables pass a policy allowlist with size bounds.
 * - stdout/stderr are binary-safe, ordered per stream, bounded, and
 *   backpressured (SDK windowing); truncation is reported.
 * - Foreground completion reports exit code, signal, timeout/cancellation
 *   reason, and truncation.
 * - Hard cancellation aborts the guest process and escalates to VM close;
 *   local promise cancellation alone is never the answer.
 * - Background sessions have broker-owned ids, bounded ring buffers,
 *   completion state, expiry, and generation tags. A VM close invalidates
 *   every process handle.
 */
import { randomUUID } from "node:crypto";
import { BrokerError, REASONS } from "./errors.js";
import type { VmExecHandle, VmHandle } from "./gondolin.js";
import type { AuditLog } from "./audit.js";
import type { EffectivePolicy } from "./policy.js";
import type { ProcessRow, Registry } from "./registry.js";
import { confineGuestPath } from "./vfs.js";

/** Env names always allowed (non-sensitive process plumbing). */
const BASE_ENV_ALLOW: Record<string, true> = {
  PATH: true,
  HOME: true,
  LANG: true,
  LC_ALL: true,
  LC_CTYPE: true,
  TERM: true,
  TZ: true,
  TMPDIR: true,
  SHELL: true,
  USER: true,
  LOGNAME: true,
};

/** Patterns never forwarded: anything credential-shaped. */
const ENV_DENY_RE = /(TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|AUTH|KEY|PRIVATE|CERT)/i;

export interface ExecEnvironment {
  envKey: string;
  generation: string;
  vm: VmHandle;
  policy: EffectivePolicy;
  workspaceGuestPath: string;
}

export interface ExecEnvironmentSource {
  get(envKey: string): ExecEnvironment | null;
  /** close the VM (hard-cancel escalation); returns a new generation marker */
  destroyVm(envKey: string, reason: string): Promise<void>;
}

export interface StreamSink {
  output(procId: string, stream: "stdout" | "stderr", seq: number, data: Buffer, truncated: boolean): void;
  exit(
    procId: string,
    result: {
      exitCode: number | null;
      signal: number | null;
      reason: string | null;
      truncated: boolean;
    },
  ): void;
}

interface TrackedProcess {
  procId: string;
  envKey: string;
  generation: string;
  handle: VmExecHandle;
  background: boolean;
  deadline: number | null;
  sink: StreamSink | null;
  stdoutBytes: number;
  stderrBytes: number;
  stdoutSeq: number;
  stderrSeq: number;
  truncated: boolean;
  ring: Buffer[];
  ringBytes: number;
  done: Promise<Completion>;
  finished: boolean;
}

export interface Completion {
  exitCode: number | null;
  signal: number | null;
  reason: string | null;
  truncated: boolean;
}

export interface ExecStartRequest {
  argv?: string[];
  shell?: string;
  cwd?: string;
  env?: Record<string, string>;
  stdin?: boolean;
  background?: boolean;
  timeoutMs?: number;
}

export interface ExecStartResult {
  procId: string;
  generation: string;
}

const KILL_ESCALATION_MS = 2000;
const BACKGROUND_RETENTION_MS = 30 * 60 * 1000;

export class ExecManager {
  #registry: Registry;
  #audit: AuditLog;
  #source: ExecEnvironmentSource;
  #processes = new Map<string, TrackedProcess>();
  #now: () => number;

  constructor(
    registry: Registry,
    audit: AuditLog,
    source: ExecEnvironmentSource,
    now: () => number = Date.now,
  ) {
    this.#registry = registry;
    this.#audit = audit;
    this.#source = source;
    this.#now = now;
  }

  #getEnvironment(envKey: string): ExecEnvironment {
    const env = this.#source.get(envKey);
    if (!env) {
      throw new BrokerError(REASONS.ENV_NOT_FOUND, "no active environment", { envKey });
    }
    return env;
  }

  /** Validate and normalize an exec.start payload against policy. */
  normalizeStart(env: ExecEnvironment, request: ExecStartRequest): {
    argv: string[];
    cwd: string;
    envVars: Record<string, string>;
    stdin: boolean;
    background: boolean;
    timeoutMs: number;
  } {
    const usingShell = request.shell !== undefined;
    if (usingShell === (request.argv !== undefined)) {
      throw new BrokerError(REASONS.PROTOCOL_FRAME, "exactly one of argv or shell is required");
    }
    let argv: string[];
    if (usingShell) {
      if (typeof request.shell !== "string" || request.shell.length === 0) {
        throw new BrokerError(REASONS.PROTOCOL_FRAME, "shell must be a non-empty string");
      }
      if (request.shell.length > env.policy.floor.maxInputBytes) {
        throw new BrokerError(REASONS.RESOURCE_INPUT, "command exceeds input cap");
      }
      argv = ["/bin/sh", "-lc", request.shell];
    } else {
      const list = request.argv!;
      if (!Array.isArray(list) || list.length === 0 || list.some((a) => typeof a !== "string")) {
        throw new BrokerError(REASONS.PROTOCOL_FRAME, "argv must be a non-empty string array");
      }
      const total = list.reduce((n, a) => n + a.length, 0);
      if (total > env.policy.floor.maxInputBytes) {
        throw new BrokerError(REASONS.RESOURCE_INPUT, "argv exceeds input cap");
      }
      argv = [...list];
    }

    const cwd = confineGuestPath(request.cwd ?? env.workspaceGuestPath, env.workspaceGuestPath);

    const envVars: Record<string, string> = {};
    let envBytes = 0;
    for (const [key, value] of Object.entries(request.env ?? {})) {
      if (!BASE_ENV_ALLOW[key] && !env.policy.envAllow.includes(key)) {
        throw new BrokerError(REASONS.RESOURCE_ENV, "env var not on the policy allowlist", { key });
      }
      if (ENV_DENY_RE.test(key)) {
        throw new BrokerError(REASONS.RESOURCE_ENV, "credential-shaped env vars are never forwarded", {
          key,
        });
      }
      if (typeof value !== "string") {
        throw new BrokerError(REASONS.PROTOCOL_FRAME, "env values must be strings", { key });
      }
      envBytes += key.length + value.length;
      if (envBytes > env.policy.floor.maxInputBytes) {
        throw new BrokerError(REASONS.RESOURCE_ENV, "env exceeds size bound");
      }
      envVars[key] = value;
    }

    const running = [...this.#processes.values()].filter(
      (p) => p.envKey === env.envKey && !p.finished,
    ).length;
    if (running >= env.policy.resources.maxExecsPerVm) {
      throw new BrokerError(REASONS.ADMISSION_STARTS, "too many concurrent guest processes", {
        running,
      });
    }

    const requested = request.timeoutMs ?? env.policy.resources.maxCommandMs;
    const timeoutMs = Math.min(requested, env.policy.resources.maxCommandMs);

    return {
      argv,
      cwd,
      envVars,
      stdin: request.stdin === true,
      background: request.background === true,
      timeoutMs,
    };
  }

  /** Start a guest process. Foreground callers pass a sink for stream frames;
   * background sessions buffer into the bounded ring. */
  start(envKey: string, request: ExecStartRequest, sink: StreamSink | null): ExecStartResult {
    const env = this.#getEnvironment(envKey);
    const spec = this.normalizeStart(env, request);
    const now = this.#now();
    const procId = randomUUID();

    const handle = env.vm.exec({
      argv: spec.argv,
      cwd: spec.cwd,
      env: spec.envVars,
      stdin: spec.stdin,
    });

    const tracked: TrackedProcess = {
      procId,
      envKey,
      generation: env.generation,
      handle,
      background: spec.background,
      deadline: spec.timeoutMs > 0 ? now + spec.timeoutMs : null,
      sink,
      stdoutBytes: 0,
      stderrBytes: 0,
      stdoutSeq: 0,
      stderrSeq: 0,
      truncated: false,
      ring: [],
      ringBytes: 0,
      done: Promise.resolve({ exitCode: null, signal: null, reason: null, truncated: false }),
      finished: false,
    };
    this.#processes.set(procId, tracked);

    this.#registry.insertProcess({
      procId,
      envKey,
      generation: env.generation,
      mode: spec.background ? "background" : "foreground",
      cwd: spec.cwd,
      state: "running",
      exitCode: null,
      signal: null,
      cancelReason: null,
      startedAt: now,
      endedAt: null,
      expiresAt: null,
    });
    this.#audit.emit({
      ts: now,
      profile: env.policy.profile,
      worklane: env.policy.worklane,
      envKey,
      generation: env.generation,
      requestId: null,
      event: "exec.start",
      reason: null,
      layer: null,
      metadata: { procId, cwd: spec.cwd, background: spec.background, shell: request.shell !== undefined },
    });

    handle.onOutput((stream, chunk) => this.#onOutput(tracked, stream, chunk));
    tracked.done = this.#watch(tracked, env);

    return { procId, generation: env.generation };
  }

  async #watch(tracked: TrackedProcess, env: ExecEnvironment): Promise<Completion> {
    const completion = await this.#raceDeadline(tracked, env);
    this.#finalize(tracked, env, completion);
    return completion;
  }

  async #raceDeadline(tracked: TrackedProcess, env: ExecEnvironment): Promise<Completion> {
    let timeoutId: NodeJS.Timeout | undefined;
    try {
      const result = await Promise.race([
        tracked.handle.result,
        ...(tracked.deadline !== null
          ? [
              new Promise<"timeout">((resolve) => {
                timeoutId = setTimeout(() => resolve("timeout"), tracked.deadline! - this.#now());
              }),
            ]
          : []),
      ]);
      if (result === "timeout") {
        await this.#hardKill(tracked, env, "timeout");
        return { exitCode: null, signal: null, reason: "timeout", truncated: tracked.truncated };
      }
      return {
        exitCode: result.exitCode,
        signal: result.signal,
        reason: null,
        truncated: tracked.truncated,
      };
    } catch {
      return { exitCode: null, signal: null, reason: "transport_failure", truncated: tracked.truncated };
    } finally {
      clearTimeout(timeoutId);
    }
  }

  #onOutput(tracked: TrackedProcess, stream: "stdout" | "stderr", chunk: Buffer): void {
    const cap = this.#outputCap(tracked);
    const used = stream === "stdout" ? tracked.stdoutBytes : tracked.stderrBytes;
    const remaining = Math.max(0, cap - used);
    const accepted = chunk.subarray(0, remaining);
    if (accepted.length < chunk.length) tracked.truncated = true;

    if (stream === "stdout") {
      tracked.stdoutBytes += accepted.length;
      tracked.stdoutSeq += 1;
      tracked.sink?.output(tracked.procId, "stdout", tracked.stdoutSeq, accepted, tracked.truncated);
    } else {
      tracked.stderrBytes += accepted.length;
      tracked.stderrSeq += 1;
      tracked.sink?.output(tracked.procId, "stderr", tracked.stderrSeq, accepted, tracked.truncated);
    }

    if (tracked.background && accepted.length > 0) {
      const ringCap = this.#ringCap(tracked);
      tracked.ring.push(Buffer.from(accepted));
      tracked.ringBytes += accepted.length;
      while (tracked.ringBytes > ringCap && tracked.ring.length > 1) {
        const dropped = tracked.ring.shift()!;
        tracked.ringBytes -= dropped.length;
        tracked.truncated = true;
      }
    }
  }

  #outputCap(tracked: TrackedProcess): number {
    const env = this.#source.get(tracked.envKey);
    return env?.policy.resources.maxOutputBytes ?? 8 * 1024 * 1024;
  }

  #ringCap(tracked: TrackedProcess): number {
    const env = this.#source.get(tracked.envKey);
    return env?.policy.resources.ringBufferBytes ?? 262144;
  }

  #finalize(tracked: TrackedProcess, env: ExecEnvironment, completion: Completion): void {
    if (tracked.finished) return;
    tracked.finished = true;
    const now = this.#now();
    const state =
      completion.reason === "cancelled" ? "cancelled" : completion.reason === null ? "exited" : "failed";
    this.#registry.finishProcess(
      tracked.procId,
      state,
      completion.exitCode,
      completion.signal,
      completion.reason,
      now,
    );
    if (tracked.background) {
      this.#registry.finishProcess(
        tracked.procId,
        state,
        completion.exitCode,
        completion.signal,
        completion.reason,
        now,
      );
      this.#setExpiry(tracked.procId, now + BACKGROUND_RETENTION_MS);
    }
    tracked.sink?.exit(tracked.procId, completion);
    this.#audit.emit({
      ts: now,
      profile: env.policy.profile,
      worklane: env.policy.worklane,
      envKey: tracked.envKey,
      generation: tracked.generation,
      requestId: null,
      event: "exec.end",
      reason: completion.reason,
      layer: null,
      metadata: {
        procId: tracked.procId,
        exitCode: completion.exitCode,
        signal: completion.signal,
        truncated: completion.truncated,
      },
    });
  }

  #setExpiry(procId: string, expiresAt: number): void {
    const row = this.#registry.getProcess(procId);
    if (!row) return;
    this.#registry.insertProcess({ ...row, expiresAt });
  }

  /** Hard kill: abort the guest process; escalate to VM close (§13.3). */
  async #hardKill(tracked: TrackedProcess, env: ExecEnvironment, reason: string): Promise<void> {
    tracked.handle.kill();
    const died = await Promise.race([
      tracked.handle.result.then(() => true).catch(() => true),
      new Promise<false>((resolve) => setTimeout(() => resolve(false), KILL_ESCALATION_MS)),
    ]);
    if (!died) {
      await this.#source.destroyVm(tracked.envKey, `exec ${reason} escalation`);
    }
  }

  #tracked(procId: string): TrackedProcess {
    const tracked = this.#processes.get(procId);
    if (!tracked) {
      throw new BrokerError(REASONS.PROC_NOT_FOUND, "unknown process handle", { procId });
    }
    return tracked;
  }

  /** Generation-tag check: handles from an old generation never target a
   * reused PID or a new VM (§8.2). */
  #assertGeneration(tracked: TrackedProcess): void {
    const env = this.#source.get(tracked.envKey);
    if (!env || env.generation !== tracked.generation) {
      throw new BrokerError(REASONS.STALE_GENERATION, "process belongs to a stale generation", {
        procId: tracked.procId,
      });
    }
  }

  stdin(procId: string, data: Buffer | null): void {
    const tracked = this.#tracked(procId);
    this.#assertGeneration(tracked);
    if (tracked.finished) {
      throw new BrokerError(REASONS.PROTOCOL_BAD_STATE, "process already finished");
    }
    if (data === null) {
      tracked.handle.endStdin();
      return;
    }
    if (data.length > this.#inputCap()) {
      throw new BrokerError(REASONS.RESOURCE_INPUT, "stdin chunk exceeds input cap");
    }
    tracked.handle.write(data);
  }

  #inputCap(): number {
    return 1024 * 1024;
  }

  async cancel(procId: string): Promise<Completion> {
    const tracked = this.#tracked(procId);
    this.#assertGeneration(tracked);
    if (tracked.finished) {
      return { exitCode: null, signal: null, reason: "already_finished", truncated: tracked.truncated };
    }
    const env = this.#getEnvironment(tracked.envKey);
    this.#audit.emit({
      ts: this.#now(),
      profile: env.policy.profile,
      worklane: env.policy.worklane,
      envKey: tracked.envKey,
      generation: tracked.generation,
      requestId: null,
      event: "exec.cancel",
      reason: null,
      layer: null,
      metadata: { procId },
    });
    await this.#hardKill(tracked, env, "cancelled");
    const completion: Completion = {
      exitCode: null,
      signal: null,
      reason: "cancelled",
      truncated: tracked.truncated,
    };
    this.#finalize(tracked, env, completion);
    return completion;
  }

  /** Wait for completion (bounded). Returns the completion record; for
   * background sessions this is a poll, not a blocking stream. */
  async wait(procId: string, timeoutMs: number): Promise<Completion & { pending: boolean }> {
    const tracked = this.#tracked(procId);
    if (tracked.finished) {
      return { ...(await tracked.done), pending: false };
    }
    this.#assertGeneration(tracked);
    let timer: NodeJS.Timeout | undefined;
    try {
      const result = await Promise.race([
        tracked.done.then((c) => ({ ...c, pending: false as const })),
        new Promise<{ pending: true }>((resolve) => {
          timer = setTimeout(() => resolve({ pending: true }), Math.max(0, timeoutMs));
        }),
      ]);
      if (result.pending) {
        return {
          exitCode: null,
          signal: null,
          reason: null,
          truncated: tracked.truncated,
          pending: true,
        };
      }
      return result;
    } finally {
      clearTimeout(timer);
    }
  }

  /** Buffered ring contents for a background session (base64 by the caller). */
  ringSnapshot(procId: string): { data: Buffer; truncated: boolean } {
    const tracked = this.#tracked(procId);
    return { data: Buffer.concat(tracked.ring), truncated: tracked.truncated };
  }

  /** Invalidate every process of an environment (VM close / generation
   * rotation): all handles die, never retarget (§13.3). */
  async invalidateEnvironment(envKey: string, generation: string, reason: string): Promise<void> {
    const victims = [...this.#processes.values()].filter((p) => p.envKey === envKey);
    await Promise.all(
      victims.map(async (tracked) => {
        if (tracked.finished) return;
        const env = this.#source.get(envKey);
        const completion: Completion = {
          exitCode: null,
          signal: null,
          reason,
          truncated: tracked.truncated,
        };
        if (env) {
          this.#finalize(tracked, env, completion);
        } else {
          tracked.finished = true;
          this.#registry.finishProcess(tracked.procId, "failed", null, null, reason, this.#now());
          tracked.sink?.exit(tracked.procId, completion);
        }
      }),
    );
    void generation;
  }

  /** Process rows for status/reconciliation. */
  processRow(procId: string): ProcessRow | null {
    return this.#registry.getProcess(procId);
  }
}
