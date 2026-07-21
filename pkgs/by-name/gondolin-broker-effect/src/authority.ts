import { Effect } from "effect";
import type { AuthorizationResult, AuthorizationService } from "./auth.js";
import type { BrokerConfigService } from "./config.js";
import type { NetworkPolicy, Worklane } from "./domain.js";
import { brokerError, type BrokerError } from "./errors.js";
import type {
  AuthorityBindingRecord,
  RegistryService,
} from "./registry.js";

export interface ResolvedAuthorityPolicy {
  readonly worklaneName: string;
  readonly worklane: Worklane;
  readonly asset: {
    readonly path: string;
    readonly buildId: string;
  };
  readonly decision: AuthorizationResult;
  readonly network: NetworkPolicy;
}

export const getOrBindDefaultAuthority = (
  registry: RegistryService,
  config: BrokerConfigService,
  environmentKey: string,
): Effect.Effect<AuthorityBindingRecord, BrokerError> =>
  registry.getAuthority(environmentKey).pipe(
    Effect.flatMap((existing) => {
      if (existing === undefined) {
        return registry.bindAuthority({
          environmentKey,
          profile: config.profile,
          executor: config.policyFile.defaultExecutor,
          authorityClass: config.policyFile.defaultAuthorityClass,
          policyDigest: config.policyFile.policyDigest,
        });
      }
      if (existing.profile !== config.profile) {
        return Effect.fail(brokerError("authority.conflict", "environment authority belongs to another profile", {
          environmentKey,
          bindingProfile: existing.profile,
          activeProfile: config.profile,
        }));
      }
      if (existing.policyDigest !== config.policyFile.policyDigest) {
        return Effect.fail(brokerError("policy.indeterminate", "environment authority uses an inactive policy digest", {
          environmentKey,
          bindingPolicyDigest: existing.policyDigest,
          activePolicyDigest: config.policyFile.policyDigest,
        }));
      }
      return Effect.succeed(existing);
    }),
  );

export const resolveAuthorityPolicy = (
  config: BrokerConfigService,
  authorization: AuthorizationService,
  binding: AuthorityBindingRecord,
): Effect.Effect<ResolvedAuthorityPolicy, BrokerError> =>
  Effect.gen(function* () {
    const worklaneName = binding.authorityClass;
    const worklane = config.policyFile.worklanes[worklaneName];
    if (worklane === undefined) {
      return yield* brokerError("policy.indeterminate", "bound authority class is unavailable", {
        authorityClass: binding.authorityClass,
      });
    }
    const asset = config.policyFile.assets[worklane.asset];
    if (asset === undefined) {
      return yield* brokerError("request.invalid", "worklane asset is unavailable", {
        worklane: worklaneName,
        asset: worklane.asset,
      });
    }
    const decision = yield* authorization.authorize({
      action: "environment.ensure",
      resource: `worklane:${worklaneName}:environment:${binding.environmentKey}`,
      requestedLimits: {
        memoryMiB: worklane.memoryMiB,
        cpus: worklane.cpus,
        ...worklane.limits,
      },
    });
    if (decision.policyDigest !== binding.policyDigest) {
      return yield* brokerError("policy.indeterminate", "bound policy digest is unavailable", {
        authorityClass: binding.authorityClass,
        boundPolicyDigest: binding.policyDigest,
        activePolicyDigest: decision.policyDigest,
      });
    }
    const networkObligations = decision.obligations.filter(
      (obligation) => typeof obligation === "object" && obligation.kind === "network",
    );
    if (networkObligations.length !== 1) {
      return yield* brokerError(
        "policy.indeterminate",
        "environment authorization must produce exactly one network obligation",
        { worklane: worklaneName, count: networkObligations.length },
      );
    }
    const networkPolicyId = networkObligations[0]!.bundleId;
    const network = config.policyFile.networkPolicies[networkPolicyId];
    if (network === undefined) {
      return yield* brokerError(
        "policy.indeterminate",
        "network obligation references an unknown policy",
        { worklane: worklaneName, networkPolicyId },
      );
    }
    return { worklaneName, worklane, asset, decision, network };
  });
