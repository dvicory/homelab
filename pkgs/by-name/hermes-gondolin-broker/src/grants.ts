/**
 * Runtime grants (V3 §11.2, §12.6).
 *
 * A grant activates one predeclared `grantable` capability (network bundle
 * or credential capability) for one environment, bounded by scope and
 * expiry. Grants never widen the immutable policy: activation validates
 * against the effective policy, records the policy generation, and anything
 * unknown or undeclared fails closed. Writes default to once-only approval;
 * stale policy generations invalidate grants on evaluation.
 */
import { randomUUID } from "node:crypto";
import { BrokerError, REASONS } from "./errors.js";
import type { EffectivePolicy, GrantScope } from "./policy.js";
import type { GrantRow, Registry } from "./registry.js";

const SCOPE_ORDER: Record<GrantScope, number> = { once: 0, task: 1, session: 2 };

/** Maximum lifetime per scope; expiry is always recorded (bounded grants). */
const SCOPE_TTL_MS: Record<GrantScope, number> = {
  once: 10 * 60 * 1000,
  task: 8 * 60 * 60 * 1000,
  session: 24 * 60 * 60 * 1000,
};

export interface GrantRequest {
  capability: string;
  scope: GrantScope;
}

export interface GrantResult {
  grantId: string;
  capability: string;
  scope: GrantScope;
  expiresAt: number;
  policyGeneration: string;
}

export class GrantManager {
  #registry: Registry;

  constructor(registry: Registry) {
    this.#registry = registry;
  }

  /** Activate a grantable capability for an environment. */
  activate(envKey: string, policy: EffectivePolicy, request: GrantRequest, now: number): GrantResult {
    if (!policy.grantable.includes(request.capability)) {
      throw new BrokerError(REASONS.GRANT_NOT_GRANTABLE, `capability is not grantable in this policy`, {
        capability: request.capability,
      });
    }
    const scopeIndex = SCOPE_ORDER[request.scope];
    const maxIndex = Math.max(-1, ...policy.grantScopes.map((s) => SCOPE_ORDER[s]));
    if (policy.grantScopes.length === 0 || scopeIndex > maxIndex) {
      throw new BrokerError(REASONS.GRANT_SCOPE, `grant scope not permitted by policy`, {
        scope: request.scope,
        allowed: policy.grantScopes,
      });
    }
    const expiresAt = now + SCOPE_TTL_MS[request.scope];
    const grantId = randomUUID();
    this.#registry.insertGrant({
      grantId,
      envKey,
      capability: request.capability,
      scope: request.scope,
      policyGeneration: policy.policyHash,
      createdAt: now,
      expiresAt,
      revokedAt: null,
    });
    return {
      grantId,
      capability: request.capability,
      scope: request.scope,
      expiresAt,
      policyGeneration: policy.policyHash,
    };
  }

  /** Revoke an active grant; idempotent. */
  revoke(grantId: string, now: number): boolean {
    return this.#registry.revokeGrant(grantId, now) > 0;
  }

  /** Active grants for an environment, filtered to the current policy
   * generation. Stale-generation grants are invisible (§12.6). */
  active(envKey: string, policy: EffectivePolicy, now: number): GrantRow[] {
    return this.#registry
      .listGrants(envKey, now)
      .filter((g) => g.policyGeneration === policy.policyHash);
  }

  /** Whether a capability is currently active for the environment. */
  isActive(envKey: string, capability: string, policy: EffectivePolicy, now: number): boolean {
    const grant = this.#registry.activeGrant(envKey, capability, now);
    return grant !== null && grant.policyGeneration === policy.policyHash;
  }

  /** Consume a `once` grant: the first authorized use revokes it. */
  consumeOnce(grant: GrantRow, now: number): void {
    if (grant.scope === "once") {
      this.#registry.revokeGrant(grant.grantId, now);
    }
  }
}
