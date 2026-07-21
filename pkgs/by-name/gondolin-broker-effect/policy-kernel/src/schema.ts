import * as Either from "effect/Either"
import * as Schema from "effect/Schema"

export const decodeOptions = { onExcessProperty: "error" as const }
export const nonEmptyString = Schema.String.pipe(Schema.filter((value): value is string => value.length > 0))
export const nonNegativeInteger = Schema.Number.pipe(
  Schema.filter((value): value is number => Number.isFinite(value) && Number.isInteger(value) && value >= 0)
)
const jsonNumber = Schema.Number.pipe(Schema.filter((value): value is number => Number.isFinite(value)))

export type JsonValue = null | boolean | number | string | ReadonlyArray<JsonValue> | { readonly [key: string]: JsonValue }
export const JsonValueSchema: Schema.Schema<JsonValue> = Schema.suspend(() =>
  Schema.Union(
    Schema.Null,
    Schema.Boolean,
    jsonNumber,
    Schema.String,
    Schema.Array(JsonValueSchema),
    Schema.Record({ key: Schema.String, value: JsonValueSchema })
  )
)

export const ResourcePrefixSchema = nonEmptyString
export type ResourcePrefix = Schema.Schema.Type<typeof ResourcePrefixSchema>

export const obligationKindValues = [
  "lease", "budget", "approval", "network", "adapter", "redact", "audit", "quarantine", "reconciliation", "fence", "hard_cancel"
] as const
export type ObligationKind = (typeof obligationKindValues)[number]
const ObligationKindSchema = Schema.Literal(...obligationKindValues)

const obligationObjectSchemas = [
  Schema.Struct({ kind: Schema.Literal("lease"), leaseClass: nonEmptyString }),
  Schema.Struct({ kind: Schema.Literal("budget"), dimension: nonEmptyString, maximum: nonNegativeInteger }),
  Schema.Struct({ kind: Schema.Literal("approval"), approvalClass: nonEmptyString }),
  Schema.Struct({ kind: Schema.Literal("network"), bundleId: nonEmptyString }),
  Schema.Struct({ kind: Schema.Literal("adapter"), adapterId: nonEmptyString, actionClass: nonEmptyString }),
  Schema.Struct({ kind: Schema.Literal("redact"), classification: nonEmptyString }),
  Schema.Struct({ kind: Schema.Literal("audit"), eventClass: nonEmptyString }),
  Schema.Struct({ kind: Schema.Literal("quarantine"), artifactClass: nonEmptyString }),
  Schema.Struct({ kind: Schema.Literal("reconciliation"), effectClass: nonEmptyString }),
  Schema.Struct({ kind: Schema.Literal("fence"), fence: nonEmptyString }),
  Schema.Struct({ kind: Schema.Literal("hard_cancel"), reason: nonEmptyString })
] as const

export const ObligationSchema = Schema.Union(ObligationKindSchema, ...obligationObjectSchemas)
export type Obligation = Schema.Schema.Type<typeof ObligationSchema>

export const NumericLimitsSchema = Schema.Record({ key: nonEmptyString, value: nonNegativeInteger })
export type NumericLimits = Schema.Schema.Type<typeof NumericLimitsSchema>

export const PolicyStatementSchema = Schema.Struct({
  effect: Schema.Literal("allow", "deny"),
  actions: Schema.Array(nonEmptyString),
  resources: Schema.Array(ResourcePrefixSchema),
  limits: Schema.optional(NumericLimitsSchema),
  obligations: Schema.optional(Schema.Array(ObligationSchema)),
  reason: Schema.optional(nonEmptyString)
})
export type PolicyStatement = Schema.Schema.Type<typeof PolicyStatementSchema>

export const PolicyDocumentSchema = Schema.Struct({
  version: Schema.Literal(1),
  statements: Schema.Array(PolicyStatementSchema)
})
export type PolicyDocument = Schema.Schema.Type<typeof PolicyDocumentSchema>

export const PolicyActionSchema = Schema.Struct({
  action: nonEmptyString,
  resource: nonEmptyString,
  parameters: Schema.optional(Schema.Record({ key: Schema.String, value: JsonValueSchema }))
})
export type PolicyAction = Schema.Schema.Type<typeof PolicyActionSchema>

export const decodePolicyDocument = (input: unknown): PolicyDocument => Schema.decodeUnknownSync(PolicyDocumentSchema, decodeOptions)(input)
export const decodePolicyAction = (input: unknown): PolicyAction => Schema.decodeUnknownSync(PolicyActionSchema, decodeOptions)(input)

export const decodePolicyDocumentEither = (input: unknown): Either.Either<PolicyDocument, unknown> => {
  try {
    return Either.right(decodePolicyDocument(input))
  } catch (error) {
    return Either.left(error)
  }
}
export const decodePolicyActionEither = (input: unknown): Either.Either<PolicyAction, unknown> => {
  try {
    return Either.right(decodePolicyAction(input))
  } catch (error) {
    return Either.left(error)
  }
}
