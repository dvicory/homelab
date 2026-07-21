import * as Context from "effect/Context"
import * as Layer from "effect/Layer"
import type { EvaluationRequest, PolicyDecision } from "./decision.js"
import { evaluate } from "./decision.js"
import type { AuthorizedAction } from "./authorization.js"
import { authorize } from "./authorization.js"
import type { ActionRegistry } from "./registry.js"
import { DefaultActionRegistry } from "./registry.js"
import { decodePolicyDocument } from "./schema.js"
import type { PolicyDocument } from "./schema.js"

export interface PolicyKernelService {
  readonly registry: ActionRegistry
  readonly evaluate: (request: EvaluationRequest) => PolicyDecision
  readonly authorize: (request: EvaluationRequest) => AuthorizedAction
  readonly decodePolicyDocument: (input: unknown) => PolicyDocument
}

export class PolicyKernel extends Context.Tag("@agent-x/policy-kernel/PolicyKernel")<PolicyKernel, PolicyKernelService>() {}

export const makePolicyKernel = (registry: ActionRegistry = DefaultActionRegistry): PolicyKernelService => Object.freeze({
  registry,
  evaluate: (request: EvaluationRequest) => evaluate({ ...request, registry: request.registry ?? registry }),
  authorize: (request: EvaluationRequest) => authorize({ ...request, registry: request.registry ?? registry }),
  decodePolicyDocument
})

export const makePolicyKernelLayer = (registry: ActionRegistry = DefaultActionRegistry) =>
  Layer.succeed(PolicyKernel, makePolicyKernel(registry))
