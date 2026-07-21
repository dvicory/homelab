import type { EvaluationRequest, EffectiveAuthority, DenyDecision, PolicyDecision } from "./decision.js"
import { evaluate } from "./decision.js"
import type { PolicyAction } from "./schema.js"

const authorizedBrand: unique symbol = Symbol("AuthorizedAction")
const authorizedValues = new WeakSet<object>()

export interface AuthorizedAction {
  readonly action: PolicyAction
  readonly authority: EffectiveAuthority
  readonly decisionDigest: string
  readonly [authorizedBrand]: true
}

export class AuthorizationDeniedError extends Error {
  readonly decision: DenyDecision
  constructor(decision: DenyDecision) {
    super(`policy denied action (${decision.reasons.join(",")})`)
    this.name = "AuthorizationDeniedError"
    this.decision = decision
  }
}

export const authorize = (request: EvaluationRequest, suppliedDecision?: PolicyDecision): AuthorizedAction => {
  const decision = evaluate(request)
  if (suppliedDecision !== undefined && suppliedDecision.digest !== decision.digest) {
    throw new AuthorizationDeniedError(decision.kind === "deny" ? decision : {
      kind: "deny",
      reasons: ["INVALID_REQUEST"],
      reasonCodes: ["INVALID_REQUEST"],
      evidence: decision.evidence,
      digest: decision.digest
    })
  }
  if (decision.kind !== "allow") throw new AuthorizationDeniedError(decision)
  const action = Object.freeze({ ...request.action })
  const authorized = Object.freeze({
    action,
    authority: decision.effectiveAuthority,
    decisionDigest: decision.digest,
    [authorizedBrand]: true as const
  })
  authorizedValues.add(authorized)
  return authorized
}

export const isAuthorizedAction = (value: unknown): value is AuthorizedAction =>
  typeof value === "object" && value !== null && authorizedValues.has(value)
