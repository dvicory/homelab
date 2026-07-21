import type { Obligation, ObligationKind, ResourcePrefix } from "./schema.js"
import { obligationKindValues } from "./schema.js"

export interface ActionDefinition {
  readonly action: string
  readonly resources?: ReadonlyArray<ResourcePrefix>
  readonly obligations?: ReadonlyArray<ObligationKind>
}
export type ActionRegistryInput =
  | ReadonlyArray<ActionDefinition>
  | Readonly<Record<string, Omit<ActionDefinition, "action"> | ReadonlyArray<ResourcePrefix>>>
export interface ActionRegistry {
  readonly definitions: ReadonlyMap<string, ActionDefinition>
  readonly has: (action: string) => boolean
  readonly get: (action: string) => ActionDefinition | undefined
  readonly supportsObligation: (action: string, obligation: Obligation) => boolean
}

const normalizeDefinition = (action: string, value: Omit<ActionDefinition, "action"> | ReadonlyArray<ResourcePrefix>): ActionDefinition => {
  if (Array.isArray(value)) return Object.freeze({ action, resources: Object.freeze([...value]) })
  const definition = value as Omit<ActionDefinition, "action">
  return Object.freeze({
    action,
    ...(definition.resources === undefined ? {} : { resources: Object.freeze([...definition.resources]) }),
    ...(definition.obligations === undefined ? {} : { obligations: Object.freeze([...definition.obligations]) })
  })
}

export const makeActionRegistry = (input: ActionRegistryInput = []): ActionRegistry => {
  const definitions = new Map<string, ActionDefinition>()
  const entries: ReadonlyArray<[string, ActionDefinition]> = Array.isArray(input)
    ? input.map((definition) => [definition.action, Object.freeze({
      action: definition.action,
      ...(definition.resources === undefined ? {} : { resources: Object.freeze([...definition.resources]) }),
      ...(definition.obligations === undefined ? {} : { obligations: Object.freeze([...definition.obligations]) })
    })] as [string, ActionDefinition])
    : Object.entries(input).map(([action, value]) => [action, normalizeDefinition(action, value)] as [string, ActionDefinition])

  for (const [action, definition] of entries) {
    if (action.length === 0 || definitions.has(action) || definition.action !== action) {
      throw new Error(`invalid or duplicate action definition: ${action}`)
    }
    if (definition.resources?.some((resource) => resource.length === 0)) {
      throw new Error(`invalid resource prefix for action: ${action}`)
    }
    if (definition.obligations?.some((kind) => !obligationKindValues.includes(kind))) {
      throw new Error(`unsupported obligation for action: ${action}`)
    }
    definitions.set(action, definition)
  }
  const frozen = new Map(definitions)
  return Object.freeze({
    definitions: frozen,
    has: (action: string) => frozen.has(action),
    get: (action: string) => frozen.get(action),
    supportsObligation: (action: string, obligation: Obligation) => {
      const supported = frozen.get(action)?.obligations
      const kind = typeof obligation === "string" ? obligation : obligation.kind
      return supported !== undefined && supported.includes(kind)
    }
  })
}

export const DefaultActionRegistry = makeActionRegistry([
  "task.create", "task.cancel", "task.complete", "task.supersede", "workflow.patch", "workflow.dispatch",
  "worker.spawn", "worker.join", "model.invoke", "tool.invoke", "terminal.exec", "terminal.background", "pty.open",
  "file.read", "file.write", "file.list", "artifact.export", "artifact.publish", "memory.read", "memory.write",
  "skill.use", "adapter.invoke", "network.request", "credential.use", "external_effect.perform", "approval.propose",
  "approval.resolve", "policy.promote", "extension.promote", "runtime.select"
].map((action) => ({ action })))
