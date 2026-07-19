#!/usr/bin/env node
/**
 * Broker entrypoint (V3 §7, §13).
 *
 * Consumes the systemd-activated socket (fd 3), opens the registry,
 * reconciles interrupted state, and serves the typed operation surface.
 * The broker never binds the pathname the socket unit owns, and exits
 * fail-closed when activation is absent, policy is missing/invalid, or KVM
 * is unavailable.
 */
import net from "node:net";
import { AuditLog } from "./audit.js";
import { CgroupManager } from "./cgroups.js";
import { loadConfig } from "./config.js";
import { asBrokerError, BrokerError, REASONS } from "./errors.js";
import { ExecManager, type StreamSink } from "./exec.js";
import { createGondolinProvider, loadGondolinSdk, type VmProvider } from "./gondolin.js";
import { GrantManager } from "./grants.js";
import { LifecycleManager } from "./lifecycle.js";
import { buildNetworkEnforcement, type NetworkEnforcement } from "./network.js";
import { composePolicy, type ComposeRequest, type EffectivePolicy } from "./policy.js";
import {
  assertPayloadFields,
  BrokerConnection,
  consumeSystemdActivation,
  decodeBase64Field,
  errorResponse,
  okResponse,
  optionalInt,
  optionalString,
  PROTOCOL_VERSION,
  requiredString,
  type RequestFrame,
  type ResponseFrame,
  type StreamFrame,
} from "./protocol.js";
import { ensureStateLayout, reconcile } from "./reconciler.js";
import { Registry } from "./registry.js";
import { VfsService } from "./vfs.js";

const OP_FIELDS: Record<string, Record<string, true>> = {
  ensure: { envKey: true, worklane: true, template: true, asset: true },
  status: { envKey: true },
  "exec.start": {
    envKey: true, argv: true, shell: true, cwd: true, env: true,
    stdin: true, background: true, timeoutMs: true,
  },
  "exec.stdin": { procId: true, data: true, eof: true },
  "exec.signal": { procId: true, signo: true },
  "exec.wait": { procId: true, timeoutMs: true },
  "exec.cancel": { procId: true },
  "fs.stat": { envKey: true, path: true },
  "fs.list": { envKey: true, path: true },
  "fs.read": { envKey: true, path: true },
  "fs.writeAtomic": { envKey: true, path: true, data: true, mode: true },
  "fs.mkdir": { envKey: true, path: true, recursive: true },
  "fs.remove": { envKey: true, path: true, recursive: true },
  close: { envKey: true },
};

interface ServerContext {
  registry: Registry;
  audit: AuditLog;
  lifecycle: LifecycleManager;
  exec: ExecManager;
  vfs: VfsService;
  grants: GrantManager;
  config: ReturnType<typeof loadConfig>;
}

function composeFromRequest(ctx: ServerContext, payload: Record<string, unknown>) {
  const envKey = requiredString(payload, "envKey", "ensure");
  const compose: ComposeRequest = {
    profile: ctx.config.profile,
    worklane: optionalString(payload, "worklane", "ensure"),
    ...(payload.template !== undefined && payload.template !== null
      ? { template: requiredString(payload, "template", "ensure") }
      : {}),
    ...(payload.asset !== undefined && payload.asset !== null
      ? { asset: requiredString(payload, "asset", "ensure") }
      : {}),
  };
  const policy = composePolicy(ctx.config.policy, compose);
  return { envKey, policy };
}

async function handleEnsure(ctx: ServerContext, frame: RequestFrame) {
  const { envKey, policy } = composeFromRequest(ctx, frame.payload);
  const result = await ctx.lifecycle.ensure({ envKey, policy });
  return {
    outcome: result.outcome,
    generation: result.generation,
    reason: result.reason,
    buildId: result.buildId,
    policyHash: policy.policyHash,
  };
}

async function handleExecStart(
  ctx: ServerContext,
  frame: RequestFrame,
  reply: (frame: ResponseFrame | StreamFrame) => void,
) {
  const envKey = requiredString(frame.payload, "envKey", frame.op);
  const background = frame.payload.background === true;

  const argvRaw = frame.payload.argv;
  const envRaw = frame.payload.env;
  const start = ctx.exec.start(
    envKey,
    {
      ...(argvRaw !== undefined && argvRaw !== null ? { argv: argvRaw as string[] } : {}),
      ...(frame.payload.shell !== undefined && frame.payload.shell !== null
        ? { shell: requiredString(frame.payload, "shell", frame.op) }
        : {}),
      ...(frame.payload.cwd !== undefined && frame.payload.cwd !== null
        ? { cwd: requiredString(frame.payload, "cwd", frame.op) }
        : {}),
      ...(envRaw !== undefined && envRaw !== null
        ? { env: envRaw as Record<string, string> }
        : {}),
      stdin: frame.payload.stdin === true,
      background,
      ...(frame.payload.timeoutMs !== undefined && frame.payload.timeoutMs !== null
        ? { timeoutMs: optionalInt(frame.payload, "timeoutMs", frame.op, 1, 86_400_000)! }
        : {}),
    },
    background
      ? null
      : {
          output: (procId, stream, seq, data, truncated) => {
            reply({
              v: PROTOCOL_VERSION,
              id: frame.id,
              event: "exec.output",
              stream,
              seq,
              data: data.toString("base64"),
              truncated,
            });
          },
          exit: (procId, result) => {
            reply({
              v: PROTOCOL_VERSION,
              id: frame.id,
              event: "exec.exit",
              exitCode: result.exitCode,
              signal: result.signal,
              reason: result.reason,
              truncated: result.truncated,
            });
          },
        } satisfies StreamSink,
  );

  if (background) {
    return { procId: start.procId, generation: start.generation, background: true };
  }
  // Foreground: announce the handle before streaming so the client can
  // address it (cancel/stdin) while output is in flight.
  reply({
    v: PROTOCOL_VERSION,
    id: frame.id,
    event: "exec.state",
    procId: start.procId,
    generation: start.generation,
  });
  // The response follows the exit event with the completion.
  const completion = await ctx.exec.wait(start.procId, 86_400_000);
  return {
    procId: start.procId,
    generation: start.generation,
    background: false,
    exitCode: completion.exitCode,
    signal: completion.signal,
    reason: completion.reason,
    truncated: completion.truncated,
  };
}

async function handleFs(ctx: ServerContext, frame: RequestFrame): Promise<unknown> {
  const envKey = requiredString(frame.payload, "envKey", frame.op);
  const live = ctx.lifecycle.getLive(envKey);
  if (!live) {
    throw new BrokerError(REASONS.ENV_NOT_FOUND, "no active environment", { envKey });
  }
  const root = live.workspaceGuestPath;
  const path = requiredString(frame.payload, "path", frame.op);
  const auditMeta = { op: frame.op, path };

  switch (frame.op) {
    case "fs.stat": {
      const stat = await ctx.vfs.stat(live.vm.fs, root, path);
      ctx.audit.emit(auditEvent(ctx, live, frame, "fs.op", auditMeta));
      return stat;
    }
    case "fs.list":
      return { entries: await ctx.vfs.list(live.vm.fs, root, path) };
    case "fs.read": {
      const data = await ctx.vfs.read(live.vm.fs, root, path);
      ctx.audit.emit(auditEvent(ctx, live, frame, "fs.op", { ...auditMeta, bytes: data.length }));
      return { data: data.toString("base64") };
    }
    case "fs.writeAtomic": {
      const mode = requiredString(frame.payload, "mode", frame.op);
      if (mode !== "create" && mode !== "replace" && mode !== "create-exclusive") {
        throw new BrokerError(REASONS.PROTOCOL_FRAME, "mode must be create|replace|create-exclusive");
      }
      const data = decodeBase64Field(frame.payload.data, ctx.config.policy.floor.maxInputBytes, "data");
      await ctx.vfs.writeAtomic(live.vm.fs, root, path, data, mode);
      ctx.audit.emit(auditEvent(ctx, live, frame, "fs.op", { ...auditMeta, bytes: data.length, mode }));
      return { written: data.length };
    }
    case "fs.mkdir":
      await ctx.vfs.mkdir(live.vm.fs, root, path, frame.payload.recursive === true);
      return { created: true };
    case "fs.remove":
      await ctx.vfs.remove(live.vm.fs, root, path, frame.payload.recursive === true);
      ctx.audit.emit(auditEvent(ctx, live, frame, "fs.op", auditMeta));
      return { removed: true };
    default:
      throw new BrokerError(REASONS.PROTOCOL_UNKNOWN_OP, "unknown fs operation", { op: frame.op });
  }
}

function auditEvent(
  ctx: ServerContext,
  live: { envKey: string; generation: string; policy: { profile: string; worklane: string | null } },
  frame: RequestFrame,
  event: "fs.op" | "request" | "decision",
  metadata: Record<string, unknown>,
) {
  return {
    ts: Date.now(),
    profile: live.policy.profile,
    worklane: live.policy.worklane,
    envKey: live.envKey,
    generation: live.generation,
    requestId: frame.id,
    event,
    reason: null,
    layer: null,
    metadata,
  };
}

async function dispatch(
  ctx: ServerContext,
  frame: RequestFrame,
  reply: (frame: ResponseFrame | StreamFrame) => void,
): Promise<unknown> {
  const fields = OP_FIELDS[frame.op];
  if (!fields) {
    throw new BrokerError(REASONS.PROTOCOL_UNKNOWN_OP, "unknown operation", { op: frame.op });
  }
  assertPayloadFields(frame.payload, fields, frame.op);

  switch (frame.op) {
    case "ensure":
      return handleEnsure(ctx, frame);
    case "status":
      return ctx.lifecycle.status(optionalString(frame.payload, "envKey", frame.op));
    case "exec.start":
      return handleExecStart(ctx, frame, reply);
    case "exec.stdin": {
      const procId = requiredString(frame.payload, "procId", frame.op);
      if (frame.payload.eof === true) {
        ctx.exec.stdin(procId, null);
      } else {
        const data = decodeBase64Field(frame.payload.data, ctx.config.policy.floor.maxInputBytes, "data");
        ctx.exec.stdin(procId, data);
      }
      return { accepted: true };
    }
    case "exec.signal": {
      const procId = requiredString(frame.payload, "procId", frame.op);
      const signo = optionalInt(frame.payload, "signo", frame.op, 1, 64) ?? 9;
      // The SDK exposes hard termination; graceful guest signal delivery is
      // gated on the Hermes behavior inventory (V3 Phase 4).
      const completion = await ctx.exec.cancel(procId);
      return { procId, signo, ...completion };
    }
    case "exec.wait": {
      const procId = requiredString(frame.payload, "procId", frame.op);
      const timeoutMs = optionalInt(frame.payload, "timeoutMs", frame.op, 0, 3_600_000) ?? 30_000;
      const completion = await ctx.exec.wait(procId, timeoutMs);
      const ring = ctx.exec.ringSnapshot(procId);
      return {
        procId,
        ...completion,
        output: ring.data.toString("base64"),
        outputTruncated: ring.truncated,
      };
    }
    case "exec.cancel": {
      const procId = requiredString(frame.payload, "procId", frame.op);
      const completion = await ctx.exec.cancel(procId);
      return { procId, ...completion };
    }
    case "fs.stat":
    case "fs.list":
    case "fs.read":
    case "fs.writeAtomic":
    case "fs.mkdir":
    case "fs.remove":
      return handleFs(ctx, frame);
    case "close": {
      const envKey = requiredString(frame.payload, "envKey", frame.op);
      return ctx.lifecycle.close(envKey);
    }
    default:
      throw new BrokerError(REASONS.PROTOCOL_UNKNOWN_OP, "unknown operation", { op: frame.op });
  }
}

export interface RunningBroker {
  close(): Promise<void>;
}

export async function startBroker(options: {
  provider?: VmProvider;
  env?: NodeJS.ProcessEnv;
  /** Test seam: serve on an already-bound server instead of systemd
   * activation. Production always uses activation (fd 3). */
  listen?: net.Server;
} = {}): Promise<RunningBroker> {
  const config = loadConfig(options.env);
  ensureStateLayout(config.stateDir, config.runtimeDir);

  const registry = new Registry(config.registryPath);
  const audit = new AuditLog(registry.db);
  const sdk = await loadGondolinSdk();
  const provider = options.provider ?? (await createGondolinProvider());
  const cgroups = new CgroupManager();
  const grants = new GrantManager(registry);
  const vfs = new VfsService();

  const buildNetwork = async (policy: EffectivePolicy): Promise<NetworkEnforcement> =>
    buildNetworkEnforcement(policy, sdk as Parameters<typeof buildNetworkEnforcement>[1]);

  const lifecycle = new LifecycleManager({
    registry,
    audit,
    provider,
    cgroups,
    paths: { stateDir: config.stateDir, runtimeDir: config.runtimeDir },
    buildNetwork,
  });
  const exec = new ExecManager(registry, audit, {
    get: (envKey) => lifecycle.getLive(envKey),
    destroyVm: async (envKey, reason) => {
      await lifecycle.close(envKey).catch(() => {});
    },
  });
  lifecycle.attachExecManager(exec);

  reconcile({
    registry,
    audit,
    lifecycle,
    stateDir: config.stateDir,
    runtimeDir: config.runtimeDir,
    pruneAudit: () => audit.prune(Date.now()),
  });

  const ctx: ServerContext = { registry, audit, lifecycle, exec, vfs, grants, config };

  const onConnection = (socket: net.Socket): void => {
    new BrokerConnection(
      socket,
      config.policy.floor.maxFrameBytes,
      async (frame, reply) => {
        try {
          const result = await dispatch(ctx, frame, reply);
          reply(okResponse(frame.id, result));
        } catch (err) {
          reply(errorResponse(frame.id, asBrokerError(err, `${frame.op} failed`)));
        }
      },
      () => {},
    );
  };

  let server: net.Server;
  if (options.listen) {
    server = options.listen;
    server.on("connection", onConnection);
  } else {
    const activation = consumeSystemdActivation(onConnection, (err) => {
      process.stderr.write(`broker socket error: ${err.message}\n`);
    });
    if (!activation) {
      throw new BrokerError(REASONS.POLICY_MISSING, "systemd socket activation required (LISTEN_FDS)");
    }
    server = activation.server;
  }

  const close = async (): Promise<void> => {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    registry.close();
  };
  return { close };
}

const isMain = process.argv[1] !== undefined && import.meta.url === new URL(`file://${process.argv[1]}`).href;
if (isMain) {
  startBroker().catch((err: unknown) => {
    const brokerErr = asBrokerError(err, "broker startup failed");
    process.stderr.write(`${brokerErr.reason}: ${brokerErr.message}\n`);
    process.exit(1);
  });
}
