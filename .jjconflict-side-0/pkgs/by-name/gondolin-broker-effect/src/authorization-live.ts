import {
  AuthorizationDeniedError,
  PolicyKernel,
  decodePolicyDocument,
  makeActionRegistry,
  makePolicyKernel,
} from "@agent-x/policy-kernel";
import { Effect, Layer } from "effect";
import { Authorization, BrokerActions, type AuthorizationService } from "./auth.js";
import { BrokerConfig } from "./config.js";
import { brokerError } from "./errors.js";

const brokerActionRegistry = makeActionRegistry(BrokerActions.map((action) => ({ action })));

export const BrokerPolicyKernelLive = Layer.effect(
  PolicyKernel,
  Effect.gen(function* () {
    const config = yield* BrokerConfig;
    yield* Effect.try({
      try: () => decodePolicyDocument(config.policyFile.policy),
      catch: (error) =>
        brokerError("request.invalid", "embedded policy document is invalid", {
          cause: error instanceof Error ? error.message : String(error),
        }),
    });
    return makePolicyKernel(brokerActionRegistry);
  }),
);

const make = Effect.gen(function* () {
  const config = yield* BrokerConfig;
  const kernel = yield* PolicyKernel;
  const policy = yield* Effect.try({
    try: () => kernel.decodePolicyDocument(config.policyFile.policy),
    catch: (error) =>
      brokerError("request.invalid", "embedded policy document is invalid", {
        cause: error instanceof Error ? error.message : String(error),
      }),
  });

  return {
    authorize: (request) =>
      Effect.try({
        try: () =>
          kernel.authorize({
            policy,
            action: {
              action: request.action,
              resource: request.resource,
              ...(request.requestedLimits === undefined
                ? {}
                : { parameters: { requestedLimits: request.requestedLimits } }),
            },
            supportedObligations: [],
          }),
        catch: (error) => {
          if (error instanceof AuthorizationDeniedError) {
            const reason = error.decision.reasonCodes[0];
            return brokerError(
              reason === "EXPLICIT_DENY" || reason === "NO_MATCHING_ALLOW"
                ? "policy.denied"
                : "policy.indeterminate",
              "policy did not authorize the broker operation",
              { policyReasons: error.decision.reasonCodes },
            );
          }
          return brokerError("policy.indeterminate", "policy evaluation failed", {
            cause: error instanceof Error ? error.message : String(error),
          });
        },
      }).pipe(
        Effect.map((authorized) => ({
          decisionDigest: authorized.decisionDigest,
          policyGeneration: config.policyFile.policyGeneration,
          limits: authorized.authority.limits,
        })),
      ),
  } satisfies AuthorizationService;
});

export const AuthorizationLive = Layer.effect(Authorization, make);
