/**
 * Environment lifecycle (V3 §8.2, §15.3).
 *
 * States: creating → active → closing → warm → pruned
 *                    ↘ failed
 *         warm → recreating → active
 *
 * A VM generation is identified by asset buildId + template version +
 * effective policy hash + mount topology identity + workspace identity.
 * `ensure` reports created/resumed/recreated plus generation and a
 * machine-readable reason. Every process handle is generation-tagged; a
 * handle from an old generation fails with process.stale_generation and
 * never targets a reused PID or a new VM.
 */
import fs from "node:fs";
import path from "node:path";
import { BrokerError, REASONS } from "./errors.js";
import { sha256Hex } from "./policy.js";
import type { AuditLog } from "./audit.js";
import type { CgroupManager, VmCgroup } from "./cgroups.js";
import type { ExecEnvironment, ExecManager } from "./exec.js";
import type { VmHandle, VmProvider } from "./gondolin.js";
import type { EffectivePolicy } from "./policy.js";
import type { EnvironmentRow, Registry } from "./registry.js";

export interface LifecyclePaths {
  stateDir: string;
  runtimeDir: string;
}

export interface EnsureRequest {
  envKey: string;
  policy: EffectivePolicy;
}

export interface EnsureResult {
  outcome: "created" | "resumed" | "recreated";
  generation: string;
  reason: string;
  buildId: string;
}

interface LiveEnvironment {
  envKey: string;
  generation: string;
  policy: EffectivePolicy;
  vm: VmHandle;
  cgroupPath: string;
  rootDiskPath: string;
  workspaceGuestPath: string;
  workspaceHostPath: string | null;
}

export interface LifecycleDeps {
  registry: Registry;
  audit: AuditLog;
  provider: VmProvider;
  cgroups: CgroupManager;
  paths: LifecyclePaths;
  /** builds the per-VM network enforcement (httpHooks/dns) */
  buildNetwork: (policy: EffectivePolicy) => Promise<{ httpHooks: unknown; dns: unknown; allowWebSockets: boolean }>;
  execManager?: ExecManager;
  now?: () => number;
}

const WORKSPACE_GUEST_PATH = "/workspace";
const MAX_ENV_KEY_LENGTH = 128;

export class LifecycleManager {
  #registry: Registry;
  #audit: AuditLog;
  #provider: VmProvider;
  #cgroups: CgroupManager;
  #paths: LifecyclePaths;
  #buildNetwork: LifecycleDeps["buildNetwork"];
  #exec: ExecManager | null;
  #now: () => number;
  #live = new Map<string, LiveEnvironment>();
  #starts: number[] = [];
  #cgroupHandles = new Map<string, VmCgroup>();

  constructor(deps: LifecycleDeps) {
    this.#registry = deps.registry;
    this.#audit = deps.audit;
    this.#provider = deps.provider;
    this.#cgroups = deps.cgroups;
    this.#paths = deps.paths;
    this.#buildNetwork = deps.buildNetwork;
    this.#exec = deps.execManager ?? null;
    this.#now = deps.now ?? Date.now;
  }

  attachExecManager(exec: ExecManager): void {
    this.#exec = exec;
  }

  /** Workspace host path for an environment; created on demand, owned by
   * the sandbox account (§10.1). */
  workspaceHostPath(envKey: string): string {
    return path.join(this.#paths.stateDir, "conversations", envKey);
  }

  /** Generation identity over the §8.2 tuple. */
  computeGeneration(envKey: string, policy: EffectivePolicy): string {
    const mountTopology = sha256Hex(
      JSON.stringify({
        workspace: policy.workspace,
        readOnlyInputs: policy.readOnlyInputs,
        guestPath: WORKSPACE_GUEST_PATH,
      }),
    );
    return sha256Hex(
      [
        policy.buildId,
        `${policy.templateName}:${policy.templateVersion}`,
        policy.policyHash,
        mountTopology,
        envKey,
      ].join("\n"),
    ).slice(0, 32);
  }

  #validateEnvKey(envKey: string): void {
    if (
      envKey.length === 0 ||
      envKey.length > MAX_ENV_KEY_LENGTH ||
      !/^[A-Za-z0-9_.-]+$/.test(envKey)
    ) {
      throw new BrokerError(REASONS.PROTOCOL_FRAME, "invalid environment key", {
        length: envKey.length,
      });
    }
  }

  #admitVmStart(policy: EffectivePolicy): void {
    const active = this.#live.size;
    if (active >= policy.floor.maxVms) {
      throw new BrokerError(REASONS.ADMISSION_VMS, "profile VM ceiling reached", {
        active,
        max: policy.floor.maxVms,
      });
    }
    const minuteAgo = this.#now() - 60_000;
    this.#starts = this.#starts.filter((ts) => ts > minuteAgo);
    if (this.#starts.length >= policy.floor.maxVmStartsPerMinute) {
      throw new BrokerError(REASONS.ADMISSION_STARTS, "VM start rate limit", {
        starts: this.#starts.length,
      });
    }
    this.#starts.push(this.#now());
  }

  /** ensure: create, resume, or recreate the environment (§8.2). */
  async ensure(request: EnsureRequest): Promise<EnsureResult> {
    this.#validateEnvKey(request.envKey);
    const now = this.#now();
    const generation = this.computeGeneration(request.envKey, request.policy);

    const tombstone = this.#registry.getTombstone(request.envKey);
    if (tombstone) {
      throw new BrokerError(REASONS.ENV_TOMBSTONED, "environment was deleted", {
        envKey: request.envKey,
        deletedAt: tombstone.deletedAt,
        reason: tombstone.reason,
      });
    }

    const existing = this.#registry.getEnvironment(request.envKey);
    if (existing && existing.state === "active" && existing.generation === generation) {
      this.#registry.touchEnvironment(request.envKey, now);
      return { outcome: "resumed", generation, reason: "same_generation", buildId: request.policy.buildId };
    }

    const outcome = existing ? "recreated" : "created";
    const reason = existing
      ? existing.generation !== generation
        ? "generation_changed"
        : `state_${existing.state}`
      : "new_environment";

    // Tear down any stale generation before booting the new one.
    if (this.#live.has(request.envKey)) {
      await this.#teardown(request.envKey, "generation_changed");
    }

    this.#admitVmStart(request.policy);

    const workspaceHostPath =
      request.policy.workspace.type === "none" ? null : this.workspaceHostPath(request.envKey);
    if (workspaceHostPath !== null) {
      fs.mkdirSync(workspaceHostPath, { recursive: true, mode: 0o700 });
    }

    const row: EnvironmentRow = {
      envKey: request.envKey,
      profile: request.policy.profile,
      worklane: request.policy.worklane,
      template: request.policy.templateName,
      asset: request.policy.assetName,
      buildId: request.policy.buildId,
      policyHash: request.policy.policyHash,
      generation,
      workspacePath: workspaceHostPath,
      state: "creating",
      stateReason: null,
      createdAt: existing?.createdAt ?? now,
      lastActivityAt: now,
    };
    this.#registry.transaction(() => {
      if (existing) {
        this.#registry.rotateEnvironment(row);
      } else {
        this.#registry.insertEnvironment(row);
      }
    });

    try {
      await this.#boot(row, request.policy, generation);
    } catch (err) {
      this.#registry.updateEnvironmentState(request.envKey, "failed", asMessage(err), this.#now());
      throw err;
    }

    this.#registry.updateEnvironmentState(request.envKey, "active", null, this.#now());
    this.#audit.emit({
      ts: this.#now(),
      profile: request.policy.profile,
      worklane: request.policy.worklane,
      envKey: request.envKey,
      generation,
      requestId: null,
      event: "lifecycle",
      reason: outcome,
      layer: null,
      metadata: { outcome, reason, template: request.policy.templateName, asset: request.policy.assetName },
    });
    return { outcome, generation, reason, buildId: request.policy.buildId };
  }

  async #boot(row: EnvironmentRow, policy: EffectivePolicy, generation: string): Promise<void> {
    const network = await this.#buildNetwork(policy);
    const rootDiskPath = path.join(this.#paths.runtimeDir, `root-${row.envKey}-${generation}.qcow2`);
    fs.mkdirSync(this.#paths.runtimeDir, { recursive: true, mode: 0o700 });

    const cgroup = this.#cgroups.create(generation, {
      memoryMiB: policy.resources.memoryMiB,
      cpus: policy.resources.cpus,
      pidsMax: policy.resources.pidsMax,
    });

    try {
      const vm = await this.#provider.createVm({
        assetPath: policy.assetPath,
        rootDiskPath,
        memoryMiB: policy.resources.memoryMiB,
        cpus: policy.resources.cpus,
        workspaceHostPath: row.workspacePath,
        workspaceGuestPath: WORKSPACE_GUEST_PATH,
        httpHooks: network.httpHooks,
        dns: network.dns,
        allowWebSockets: network.allowWebSockets,
        sessionLabel: `hermes-${policy.profile}-${row.envKey}`.slice(0, 64),
      });
      const pid = vm.hostPid();
      if (pid !== null) {
        cgroup.attach(pid);
      }
      this.#live.set(row.envKey, {
        envKey: row.envKey,
        generation,
        policy,
        vm,
        cgroupPath: cgroup.path,
        rootDiskPath,
        workspaceGuestPath: WORKSPACE_GUEST_PATH,
        workspaceHostPath: row.workspacePath,
      });
      this.#cgroupHandles.set(row.envKey, cgroup);
    } catch (err) {
      cgroup.destroy();
      try {
        fs.rmSync(rootDiskPath, { force: true });
      } catch {
        // best effort
      }
      throw err;
    }
  }

  /** Live VM view for the exec layer (null when not active). */
  getLive(envKey: string): ExecEnvironment | null {
    const live = this.#live.get(envKey);
    if (!live) return null;
    return {
      envKey: live.envKey,
      generation: live.generation,
      vm: live.vm,
      policy: live.policy,
      workspaceGuestPath: live.workspaceGuestPath,
    };
  }

  /** Status for one environment (or the whole profile scope). */
  status(envKey: string | null): unknown {
    if (envKey !== null) {
      this.#validateEnvKey(envKey);
      const row = this.#registry.getEnvironment(envKey);
      if (!row) {
        throw new BrokerError(REASONS.ENV_NOT_FOUND, "environment not found", { envKey });
      }
      return {
        envKey: row.envKey,
        state: row.state,
        generation: row.generation,
        template: row.template,
        asset: row.asset,
        buildId: row.buildId,
        live: this.#live.has(envKey),
        stateReason: row.stateReason,
        lastActivityAt: row.lastActivityAt,
      };
    }
    return {
      environments: this.#registry.listEnvironments().map((row) => ({
        envKey: row.envKey,
        state: row.state,
        generation: row.generation,
        live: this.#live.has(row.envKey),
      })),
    };
  }

  /** close: hard stop the VM; workspace persists per retention (§15.3). */
  async close(envKey: string): Promise<{ generation: string; state: string }> {
    this.#validateEnvKey(envKey);
    const row = this.#registry.getEnvironment(envKey);
    if (!row) {
      throw new BrokerError(REASONS.ENV_NOT_FOUND, "environment not found", { envKey });
    }
    this.#registry.updateEnvironmentState(envKey, "closing", null, this.#now());
    await this.#teardown(envKey, "client_close");
    // VM is gone; the authorized VFS workspace remains → warm (§15.3).
    this.#registry.updateEnvironmentState(envKey, "warm", null, this.#now());
    return { generation: row.generation, state: "warm" };
  }

  /** delete: tombstone before removing data; idempotent (§15.4). */
  async delete(envKey: string, reason: string): Promise<void> {
    this.#validateEnvKey(envKey);
    const now = this.#now();
    const row = this.#registry.getEnvironment(envKey);
    if (!row) {
      this.#registry.insertTombstone({ envKey, generation: "unknown", deletedAt: now, reason });
      return;
    }
    this.#registry.transaction(() => {
      this.#registry.insertTombstone({ envKey, generation: row.generation, deletedAt: now, reason });
      this.#registry.deleteEnvironment(envKey);
    });
    await this.#teardown(envKey, reason);
    if (row.workspacePath) {
      fs.rmSync(row.workspacePath, { recursive: true, force: true });
    }
    this.#audit.emit({
      ts: now,
      profile: row.profile,
      worklane: row.worklane,
      envKey,
      generation: row.generation,
      requestId: null,
      event: "lifecycle",
      reason: "deleted",
      layer: null,
      metadata: { reason },
    });
  }

  async #teardown(envKey: string, reason: string): Promise<void> {
    const live = this.#live.get(envKey);
    this.#live.delete(envKey);
    if (this.#exec) {
      const generation = live?.generation ?? "unknown";
      await this.#exec.invalidateEnvironment(envKey, generation, reason);
    }
    if (live) {
      try {
        await live.vm.close();
      } catch {
        // close is best effort; cgroup teardown below is authoritative
      }
    }
    const cgroup = this.#cgroupHandles.get(envKey);
    this.#cgroupHandles.delete(envKey);
    cgroup?.destroy();
    if (live) {
      try {
        fs.rmSync(live.rootDiskPath, { force: true });
      } catch {
        // best effort
      }
    }
  }

  /** Environment rows for reconciliation. */
  liveEnvKeys(): string[] {
    return [...this.#live.keys()];
  }
}

function asMessage(err: unknown): string {
  return err instanceof Error ? err.message.slice(0, 200) : String(err).slice(0, 200);
}
