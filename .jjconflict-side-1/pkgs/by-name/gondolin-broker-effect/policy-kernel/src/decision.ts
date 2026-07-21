import { sha256 } from "@noble/hashes/sha256"
import { bytesToHex } from "@noble/hashes/utils"
import { decodePolicyAction } from "./schema.js"
import type { NumericLimits, Obligation, ObligationKind, PolicyAction, PolicyDocument, PolicyStatement } from "./schema.js"
import type { ActionRegistry } from "./registry.js"
import { DefaultActionRegistry } from "./registry.js"

export type PolicyReasonCode =
  | "ALLOW"
  | "UNKNOWN_ACTION"
  | "RESOURCE_NOT_REGISTERED"
  | "NO_MATCHING_ALLOW"
  | "EXPLICIT_DENY"
  | "UNSUPPORTED_OBLIGATION"
  | "INVALID_REQUEST"

export interface DecisionEvidence {
  readonly digest: string
  readonly policyDigest: string
  readonly actionDigest: string
  readonly reasonCodes: ReadonlyArray<PolicyReasonCode>
}
export interface AllowDecision {
  readonly kind: "allow"
  readonly effectiveAuthority: EffectiveAuthority
  readonly obligations: ReadonlyArray<Obligation>
  readonly evidence: DecisionEvidence
  readonly reasonCodes: ReadonlyArray<PolicyReasonCode>
  readonly digest: string
}
export interface DenyDecision {
  readonly kind: "deny"
  readonly reasons: ReadonlyArray<PolicyReasonCode>
  readonly evidence: DecisionEvidence
  readonly reasonCodes: ReadonlyArray<PolicyReasonCode>
  readonly digest: string
}
export type PolicyDecision = AllowDecision | DenyDecision
export interface EvaluationRequest {
  readonly policy: PolicyDocument
  readonly action: PolicyAction
  readonly registry?: ActionRegistry
  readonly supportedObligations?: ReadonlyArray<ObligationKind>
}
export interface EffectiveAuthority {
  readonly action: string
  readonly resource: string
  readonly limits: NumericLimits
  readonly obligations: ReadonlyArray<Obligation>
}
export const canonicalize = (value: unknown): string => {
  if (value === null) return "null"
  if (typeof value === "string" || typeof value === "boolean") return JSON.stringify(value)
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new TypeError("canonical JSON does not permit non-finite numbers")
    return JSON.stringify(value)
  }
  if (typeof value !== "object") throw new TypeError("canonical JSON does not permit this value")
  if (Array.isArray(value)) return `[${value.map(canonicalize).join(",")}]`
  if (Object.getPrototypeOf(value) !== Object.prototype && Object.getPrototypeOf(value) !== null) {
    throw new TypeError("canonical JSON requires plain objects")
  }
  if (Object.getOwnPropertySymbols(value).length > 0) throw new TypeError("canonical JSON does not permit symbols")
  const object = value as Record<string, unknown>
  return `{${Object.keys(object).sort().map((key) => `${JSON.stringify(key)}:${canonicalize(object[key])}`).join(",")}}`
}

export const deterministicDigest = (value: unknown): string => {
  const encoded = new TextEncoder().encode(canonicalize(value))
  return bytesToHex(sha256(encoded))
}

const resourceMatches = (pattern: string, resource: string): boolean =>
  pattern.endsWith("*")
    ? resource.startsWith(pattern.slice(0, -1))
    : resource === pattern;
const statementMatches = (statement: PolicyStatement, action: PolicyAction): boolean =>
  statement.actions.includes(action.action) && statement.resources.some((prefix) => resourceMatches(prefix, action.resource))

const minimumLimits = (statements: ReadonlyArray<PolicyStatement>): NumericLimits => {
  const result: Record<string, number> = {}
  for (const statement of statements) {
    for (const [dimension, value] of Object.entries(statement.limits ?? {})) {
      const previous = result[dimension]
      result[dimension] = previous === undefined ? value : Math.min(previous, value)
    }
  }
  return Object.freeze(result)
}
const uniqueObligations = (statements: ReadonlyArray<PolicyStatement>): ReadonlyArray<Obligation> => {
  const result: Obligation[] = []
  const seen = new Set<string>()
  for (const statement of statements) {
    for (const obligation of statement.obligations ?? []) {
      const key = canonicalize(obligation)
      if (!seen.has(key)) {
        seen.add(key)
        result.push(obligation)
      }
    }
  }
  return Object.freeze(result)
}
const evidenceFor = (policy: PolicyDocument, action: PolicyAction, reasonCodes: ReadonlyArray<PolicyReasonCode>): DecisionEvidence => {
  const policyDigest = deterministicDigest(policy)
  const actionDigest = deterministicDigest(action)
  const base = { policyDigest, actionDigest, reasonCodes: Object.freeze([...reasonCodes]) }
  return Object.freeze({ ...base, digest: deterministicDigest(base) })
}
const deny = (policy: PolicyDocument, action: PolicyAction, reason: PolicyReasonCode): DenyDecision => {
  const reasonCodes = Object.freeze([reason])
  const evidence = evidenceFor(policy, action, reasonCodes)
  return Object.freeze({ kind: "deny", reasons: reasonCodes, reasonCodes, evidence, digest: evidence.digest })
}

export const evaluate = (request: EvaluationRequest): PolicyDecision => {
  let action: PolicyAction
  try {
    action = decodePolicyAction(request.action)
  } catch {
    const fallback = { action: "", resource: "" } as PolicyAction
    return deny(request.policy, fallback, "INVALID_REQUEST")
  }
  const registry = request.registry ?? DefaultActionRegistry
  const definition = registry.get(action.action)
  if (definition === undefined) return deny(request.policy, action, "UNKNOWN_ACTION")
  if (
    definition.resources !== undefined &&
    !definition.resources.some((pattern) => resourceMatches(pattern, action.resource))
  ) {
    return deny(request.policy, action, "RESOURCE_NOT_REGISTERED")
  }

  const matching = request.policy.statements.filter((statement) => statementMatches(statement, action))
  if (matching.some((statement) => statement.effect === "deny")) return deny(request.policy, action, "EXPLICIT_DENY")
  const allows = matching.filter((statement) => statement.effect === "allow")
  if (allows.length === 0) return deny(request.policy, action, "NO_MATCHING_ALLOW")

  const obligations = uniqueObligations(allows)
  const supported = request.supportedObligations === undefined ? undefined : new Set(request.supportedObligations)
  for (const obligation of obligations) {
    const kind = typeof obligation === "string" ? obligation : obligation.kind
    if (!registry.supportsObligation(action.action, obligation) || (supported !== undefined && !supported.has(kind))) {
      return deny(request.policy, action, "UNSUPPORTED_OBLIGATION")
    }
  }

  const effectiveAuthority = Object.freeze({ action: action.action, resource: action.resource, limits: minimumLimits(allows), obligations })
  const reasonCodes = Object.freeze(["ALLOW"] as const)
  const evidence = evidenceFor(request.policy, action, reasonCodes)
  return Object.freeze({ kind: "allow", effectiveAuthority, obligations, evidence, reasonCodes, digest: evidence.digest })
}
