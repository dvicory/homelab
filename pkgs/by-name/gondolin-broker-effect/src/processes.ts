import { randomUUID } from "node:crypto";
import {
  Context,
  Deferred,
  Duration,
  Effect,
  Fiber,
  Layer,
  Stream,
  type Scope,
} from "effect";
import type {
  ProcessPollRequest,
  ProcessRef,
  ProcessSpawnRequest,
  TaskRunIdentity,
} from "./domain.js";
import { Environments } from "./environments.js";
import { BrokerConfig } from "./config.js";
import { brokerError, type BrokerError } from "./errors.js";
import { Executor, type ExecEvent } from "./exec.js";

type ProcessState = "running" | "exited" | "cancelled" | "lost";

type RetainedOutput = {
  readonly cursor: number;
  readonly sequence: number;
  readonly stream: "stdout" | "stderr";
  readonly dataBase64: string;
  readonly bytes: number;
};

type ProcessRecord = {
  readonly processId: string;
  readonly environmentKey: string;
  readonly generation: number;
  readonly taskRun: TaskRunIdentity | undefined;
  readonly createdAt: number;
  state: ProcessState;
  reason: string | null;
  exitCode: number | null;
  signal: number | null;
  terminalAt: number | null;
  decisionDigest: string | null;
  outputLimitBytes: number;
  retainedBytes: number;
  truncatedBytes: number;
  nextCursor: number;
  output: Array<RetainedOutput>;
  fiber: Fiber.RuntimeFiber<void, never> | undefined;
};

export type ProcessSpawnResult = {
  readonly processId: string;
  readonly environmentKey: string;
  readonly generation: number;
  readonly state: "running";
};

export type ProcessPollResult = {
  readonly processId: string;
  readonly state: ProcessState;
  readonly reason: string | null;
  readonly exitCode: number | null;
  readonly signal: number | null;
  readonly output: ReadonlyArray<Omit<RetainedOutput, "bytes">>;
  readonly nextCursor: number;
  readonly firstAvailableCursor: number;
  readonly truncatedBytes: number;
};

export interface ProcessService {
  readonly spawn: (request: ProcessSpawnRequest) => Effect.Effect<ProcessSpawnResult, BrokerError>;
  readonly poll: (request: ProcessPollRequest) => Effect.Effect<ProcessPollResult, BrokerError>;
  readonly cancel: (request: ProcessRef) => Effect.Effect<ProcessPollResult, BrokerError>;
}

export class Processes extends Context.Tag("@agent-x/gondolin-broker-effect/Processes")<
  Processes,
  ProcessService
>() {}
const OUTPUT_CHUNK_BYTES = 1024;



const sameTaskRun = (
  left: TaskRunIdentity | undefined,
  right: TaskRunIdentity | undefined,
): boolean =>
  left === undefined
    ? right === undefined
    : right !== undefined && left.taskId === right.taskId && left.runId === right.runId;

const publicState = (
  record: ProcessRecord,
  cursor: number,
  maxBytes: number,
): ProcessPollResult => {
  const firstAvailableCursor = record.output[0]?.cursor ?? record.nextCursor;
  const requestedCursor = Math.max(cursor, firstAvailableCursor - 1);
  let responseBytes = 0;
  const output: Array<Omit<RetainedOutput, "bytes">> = [];
  for (const { bytes, ...event } of record.output) {
    if (event.cursor <= requestedCursor) continue;
    if (responseBytes + bytes > maxBytes) break;
    responseBytes += bytes;
    output.push(event);
  }
  return {
    processId: record.processId,
    state: record.state,
    reason: record.reason,
    exitCode: record.exitCode,
    signal: record.signal,
    output,
    nextCursor: output.at(-1)?.cursor ?? requestedCursor,
    firstAvailableCursor,
    truncatedBytes: record.truncatedBytes,
  };
};

const appendOutput = (
  record: ProcessRecord,
  event: Extract<ExecEvent, { readonly type: "output" }>,
): void => {
  const data = Buffer.from(event.dataBase64, "base64");
  for (let offset = 0; offset < data.byteLength; offset += OUTPUT_CHUNK_BYTES) {
    const chunk = data.subarray(offset, Math.min(data.byteLength, offset + OUTPUT_CHUNK_BYTES));
    record.nextCursor += 1;
    record.output.push({
      cursor: record.nextCursor,
      sequence: event.sequence,
      stream: event.stream,
      dataBase64: chunk.toString("base64"),
      bytes: chunk.byteLength,
    });
    record.retainedBytes += chunk.byteLength;
  }
  while (record.retainedBytes > record.outputLimitBytes && record.output.length > 0) {
    const removed = record.output.shift();
    if (removed === undefined) break;
    record.retainedBytes -= removed.bytes;
    record.truncatedBytes += removed.bytes;
  }
};

const make = Effect.gen(function* () {
  const executor = yield* Executor;
  const config = yield* BrokerConfig;
  const cleanupIntervalMs = Math.min(
    60 * 1000,
    Math.max(10, Math.floor(config.policyFile.processRegistry.terminalTtlMs / 4)),
  );
  const environments = yield* Environments;
  const applicationScope = yield* Effect.scope;
  const records = new Map<string, ProcessRecord>();

  const requireRecord = (request: ProcessRef): Effect.Effect<ProcessRecord, BrokerError> =>
    Effect.gen(function* () {
      const record = records.get(request.processId);
      if (
        record === undefined ||
        record.environmentKey !== request.environmentKey ||
        record.generation !== request.generation ||
        !sameTaskRun(record.taskRun, request.taskRun)
      ) {
        return yield* brokerError("process.not_found", "background process is not available");
      }
      if (record.state === "running") {
        yield* Effect.scoped(
          environments.lease({
            environmentKey: request.environmentKey,
            generation: request.generation,
            ...(request.taskRun === undefined ? {} : { taskRun: request.taskRun }),
          }).pipe(Effect.asVoid),
        );
      } else {
        const status = yield* environments.status(request.environmentKey);
        if (status.generation !== request.generation) {
          return yield* brokerError("process.not_found", "background process is not available");
        }
      }
      return record;
    });

  const spawn = (request: ProcessSpawnRequest): Effect.Effect<ProcessSpawnResult, BrokerError> =>
    Effect.gen(function* () {
      const processId = randomUUID();
      const started = yield* Deferred.make<void, BrokerError>();
      const record: ProcessRecord = {
        processId,
        environmentKey: request.environmentKey,
        generation: request.generation,
        taskRun: request.taskRun,
        createdAt: Date.now(),
        state: "running",
        reason: null,
        exitCode: null,
        signal: null,
        terminalAt: null,
        decisionDigest: null,
        outputLimitBytes: 1,
        retainedBytes: 0,
        truncatedBytes: 0,
        nextCursor: 0,
        output: [],
        fiber: undefined,
      };
      const existing = yield* Effect.sync(() =>
        [...records.values()].find(
          (candidate) =>
            candidate.environmentKey === request.environmentKey && candidate.state === "running",
        ),
      );
      const runningCount = yield* Effect.sync(
        () => [...records.values()].filter((candidate) => candidate.state === "running").length,
      );
      if (runningCount >= config.policyFile.processRegistry.maxConcurrent) {
        return yield* brokerError("environment.capacity", "background process capacity reached", {
          maxConcurrent: config.policyFile.processRegistry.maxConcurrent,
        });
      }
      if (existing !== undefined) {
        return yield* brokerError(
          "environment.capacity",
          "environment already owns a running background process",
          { environmentKey: request.environmentKey },
        );
      }
      yield* Effect.sync(() => {
        records.set(processId, record);
      });

      const supervise = Stream.runForEach(
        executor.execute(request, "background"),
        (event) => Effect.gen(function* () {
          if (event.type === "start") {
            record.decisionDigest = event.decisionDigest;
            record.outputLimitBytes = Math.max(
              1,
              Math.min(
                event.outputLimitBytes,
                config.policyFile.processRegistry.retainedOutputBytes,
              ),
            );
            yield* Deferred.succeed(started, undefined);
          } else if (event.type === "output") {
            appendOutput(record, event);
          } else if (record.state === "running") {
            record.state = "exited";
            record.exitCode = event.exitCode;
            record.signal = event.signal;
            record.terminalAt = Date.now();
          }
        }),
      ).pipe(
        Effect.catchAll((error) =>
          environments.hardTerminateLeased(
            { environmentKey: record.environmentKey, generation: record.generation },
            "background process failed",
            "failed",
          ).pipe(
            Effect.andThen(Effect.sync(() => {
              if (record.state === "running") {
                record.state = "lost";
                record.reason = error.reason;
                record.terminalAt = Date.now();
              }
            })),
            Effect.andThen(Deferred.fail(started, error).pipe(Effect.ignore)),
          ),
        ),
        Effect.ensuring(
          Effect.sync(() => {
            if (record.state === "running") {
              record.state = "lost";
              record.reason = "runtime.terminated";
              record.terminalAt = Date.now();
            }
          }),
        ),
      );
      const fiber = yield* Effect.forkIn(supervise, applicationScope);
      record.fiber = fiber;
      const startResult = yield* Effect.exit(Deferred.await(started));
      if (startResult._tag === "Failure") {
        records.delete(processId);
        yield* Fiber.interrupt(fiber);
        return yield* brokerError("runtime.start_failed", "failed to start background process");
      }
      return {
        processId,
        environmentKey: request.environmentKey,
        generation: request.generation,
        state: "running" as const,
      };
    });

  const poll = (request: ProcessPollRequest): Effect.Effect<ProcessPollResult, BrokerError> =>
    requireRecord(request).pipe(
      Effect.map((record) =>
        publicState(
          record,
          request.cursor,
          Math.min(
            request.maxBytes ?? config.policyFile.processRegistry.maxPollBytes,
            config.policyFile.processRegistry.maxPollBytes,
          ),
        ),
      ),
    );

  const cancel = (request: ProcessRef): Effect.Effect<ProcessPollResult, BrokerError> =>
    Effect.gen(function* () {
      const record = yield* requireRecord(request);
      if (record.state === "running") {
        record.state = "cancelled";
        record.reason = "client_cancel";
        record.terminalAt = Date.now();
        yield* Effect.all(
          [
            record.fiber === undefined ? Effect.void : Fiber.interrupt(record.fiber),
            environments.hardTerminateLeased(
              { environmentKey: record.environmentKey, generation: record.generation },
              "background process cancelled",
              "closed",
            ),
          ],
          { concurrency: "unbounded", discard: true },
        );
      }
      return publicState(record, 0, config.policyFile.processRegistry.maxPollBytes);
    });

  yield* environments.registerCloseHook((reference) =>
    Effect.forEach(
      [...records.values()].filter(
        (record) =>
          record.state === "running"
          && record.environmentKey === reference.environmentKey
          && record.generation === reference.generation,
      ),
      (record) =>
        Effect.gen(function* () {
          record.state = "cancelled";
          record.reason = "environment_closed";
          record.terminalAt = Date.now();
          if (record.fiber !== undefined) yield* Fiber.interrupt(record.fiber);
        }),
      { concurrency: "unbounded", discard: true },
    ),
  );

  yield* Effect.forkIn(
    Effect.forever(
      Effect.sleep(Duration.millis(cleanupIntervalMs)).pipe(
        Effect.andThen(Effect.sync(() => {
          const cutoff = Date.now() - config.policyFile.processRegistry.terminalTtlMs;
          for (const [processId, record] of records) {
            if (record.terminalAt !== null && record.terminalAt < cutoff) records.delete(processId);
          }
        })),
      ),
    ),
    applicationScope,
  );

  return { spawn, poll, cancel } satisfies ProcessService;
});

export const ProcessesLive = Layer.scoped(Processes, make);
