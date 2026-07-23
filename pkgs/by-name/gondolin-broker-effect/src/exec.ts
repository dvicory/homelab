import {
  Context,
  Duration,
  Effect,
  Layer,
  Ref,
  Stream,
  TSemaphore,
} from "effect";
import { Authorization } from "./auth.js";
import type { ExecRequest } from "./domain.js";
import { Environments } from "./environments.js";
import { brokerError, type BrokerError } from "./errors.js";
import type { VmOutput } from "./runtime.js";

export type ExecEvent =
  | {
      readonly type: "start";
      readonly environmentKey: string;
      readonly generation: number;
      readonly decisionDigest: string;
      readonly timeoutMs: number;
      readonly outputLimitBytes: number;
    }
  | {
      readonly type: "output";
      readonly sequence: number;
      readonly stream: "stdout" | "stderr";
      readonly dataBase64: string;
    }
  | {
      readonly type: "exit";
      readonly exitCode: number | null;
      readonly signal: number | null;
    };

export interface ExecutorService {
  readonly execute: (request: ExecRequest) => Stream.Stream<ExecEvent, BrokerError>;
}

const streamProcessOutput = (
  output: AsyncIterable<VmOutput>,
): Stream.Stream<VmOutput, BrokerError> =>
  Stream.asyncPush<VmOutput, BrokerError>((emit) =>
    Effect.acquireRelease(
      Effect.sync(() => {
        const subscription = { active: true };
        void (async () => {
          try {
            for await (const chunk of output) {
              if (!subscription.active) return;
              emit.single(chunk);
            }
            if (subscription.active) emit.end();
          } catch (error) {
            if (subscription.active) {
              emit.fail(
                brokerError("runtime.operation_failed", "guest output stream failed", {
                  cause: error instanceof Error ? error.message : String(error),
                }),
              );
            }
          }
        })();
        return subscription;
      }),
      (subscription) => Effect.sync(() => {
        subscription.active = false;
      }),
    ),
  );


export class Executor extends Context.Tag("@agent-x/gondolin-broker-effect/Executor")<
  Executor,
  ExecutorService
>() {}

const make = Effect.gen(function* () {
  const authorization = yield* Authorization;
  const environments = yield* Environments;

  const execute = (request: ExecRequest): Stream.Stream<ExecEvent, BrokerError> =>
    Stream.unwrap(
      Ref.make(false).pipe(
        Effect.map((completed) =>
          Stream.unwrapScoped(
            Effect.gen(function* () {
              const environment = yield* environments.lease({
                environmentKey: request.environmentKey,
                generation: request.generation,
                ...(request.taskRun === undefined ? {} : { taskRun: request.taskRun }),
              });
              yield* TSemaphore.withPermitScoped(environment.execPermits);
              const decision = yield* authorization.authorize({
                action: "exec.foreground",
                resource: `environment:${request.environmentKey}/exec`,
                requestedLimits: {
                  timeoutMs: request.timeoutMs ?? environment.limits.maxCommandMs,
                  outputBytes: request.outputLimitBytes ?? environment.limits.maxOutputBytes,
                  inputBytes: environment.limits.maxInputBytes,
                },
              });
              const timeoutMs = Math.min(
                request.timeoutMs ?? environment.limits.maxCommandMs,
                environment.limits.maxCommandMs,
                decision.limits.timeoutMs ?? Number.POSITIVE_INFINITY,
              );
              const outputLimitBytes = Math.min(
                request.outputLimitBytes ?? environment.limits.maxOutputBytes,
                environment.limits.maxOutputBytes,
                decision.limits.outputBytes ?? Number.POSITIVE_INFINITY,
              );
              const stdin = request.stdinBase64 === undefined
                ? Buffer.alloc(0)
                : Buffer.from(request.stdinBase64, "base64");
              if (stdin.byteLength > environment.limits.maxInputBytes) {
                return yield* brokerError("exec.invalid", "command input exceeds its byte limit", {
                  maxInputBytes: environment.limits.maxInputBytes,
                  receivedBytes: stdin.byteLength,
                });
              }
              const processHandle = yield* Effect.tryPromise({
                try: () => environment.vm.exec({
                  argv: request.argv,
                  ...(request.cwd === undefined ? {} : { cwd: request.cwd }),
                  ...(request.env === undefined ? {} : { env: request.env }),
                }),
                catch: (error) =>
                  brokerError("runtime.operation_failed", "failed to start guest process", {
                    cause: error instanceof Error ? error.message : String(error),
                  }),
              });
              yield* Effect.try({
                try: () => {
                  if (stdin.byteLength > 0) processHandle.write(stdin);
                  processHandle.end();
                },
                catch: (error) =>
                  brokerError("runtime.operation_failed", "failed to initialize guest process input", {
                    cause: error instanceof Error ? error.message : String(error),
                  }),
              });
              const bytes = yield* Ref.make(0);
              const sequence = yield* Ref.make(0);
              const output = streamProcessOutput(processHandle.output).pipe(
                Stream.mapEffect((chunk) =>
                  Effect.gen(function* () {
                    const total = yield* Ref.updateAndGet(bytes, (value) => value + chunk.data.byteLength);
                    if (total > outputLimitBytes) {
                      return yield* brokerError("exec.output_limit", "command output exceeded its byte limit", {
                        outputLimitBytes,
                        observedBytes: total,
                      });
                    }
                    const next = yield* Ref.getAndUpdate(sequence, (value) => value + 1);
                    return {
                      type: "output" as const,
                      sequence: next,
                      stream: chunk.stream,
                      dataBase64: Buffer.from(chunk.data).toString("base64"),
                    };
                  }),
                ),
              );
              const exit = Stream.fromEffect(
                Effect.tryPromise({
                  try: () => processHandle.result,
                  catch: (error) =>
                    brokerError("runtime.operation_failed", "guest process result failed", {
                      cause: error instanceof Error ? error.message : String(error),
                    }),
                }).pipe(
                  Effect.tap(() => Ref.set(completed, true)),
                  Effect.map((result) => ({ type: "exit" as const, ...result })),
                ),
              );
              const start = Stream.succeed<ExecEvent>({
                type: "start",
                environmentKey: request.environmentKey,
                generation: request.generation,
                decisionDigest: decision.decisionDigest,
                timeoutMs,
                outputLimitBytes,
              });
              const deadline = Effect.sleep(Duration.millis(timeoutMs)).pipe(
                Effect.andThen(Effect.fail(brokerError("exec.timeout", "command exceeded its deadline", { timeoutMs }))),
              );
              return Stream.concat(start, Stream.concat(output, exit)).pipe(Stream.interruptWhen(deadline));
            }),
          ).pipe(
            Stream.ensuring(
              Ref.get(completed).pipe(
                Effect.flatMap((done) =>
                  done
                    ? Effect.void
                    : environments.hardTerminateLeased(
                        { environmentKey: request.environmentKey, generation: request.generation },
                        "command did not complete; environment hard-closed",
                      ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

  return { execute } satisfies ExecutorService;
});

export const ExecutorLive = Layer.effect(Executor, make);
