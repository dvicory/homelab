import { Schema } from "effect";

const Identifier = Schema.String.pipe(
  Schema.minLength(1),
  Schema.maxLength(256),
  Schema.pattern(/^[A-Za-z0-9][A-Za-z0-9._:@-]*$/),
);
const BrokerIdentity = Schema.String.pipe(
  Schema.minLength(1),
  Schema.maxLength(1024),
  Schema.pattern(/^[A-Za-z0-9][A-Za-z0-9._:@-]*$/),
);
const Revision = Schema.String.pipe(Schema.pattern(/^[0-9a-f]{64}$/));
const PositiveInt = Schema.Int.pipe(Schema.greaterThan(0));
const NonNegativeInt = Schema.Int.pipe(Schema.greaterThanOrEqualTo(0));
const RunId = Schema.Union(BrokerIdentity, PositiveInt);

export const InputPreparationLimits = Schema.Struct({
  maxInputs: PositiveInt,
  maxInputBytes: PositiveInt,
  maxInputEntries: PositiveInt,
  maxInputPathBytes: PositiveInt,
});
export type InputPreparationLimits = typeof InputPreparationLimits.Type;

export const TaskRunInput = Schema.Struct({
  producerTaskId: BrokerIdentity,
  producerRunId: RunId,
  mountName: Identifier,
  producerLane: Identifier,
  producerProject: Schema.optional(Identifier),
  producerSourceGeneration: Schema.optional(BrokerIdentity),
  handoffId: Identifier,
});
export type TaskRunInput = typeof TaskRunInput.Type;

export const PrepareTaskRunInputsRequest = Schema.Struct({
  environmentKey: Identifier,
  board: Identifier,
  taskId: Identifier,
  runId: RunId,
  generation: PositiveInt,
  digest: Revision,
  lane: Identifier,
  laneRevision: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(256)),
  policyRevision: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(256)),
  limits: InputPreparationLimits,
  inputs: Schema.Array(TaskRunInput),
});
export type PrepareTaskRunInputsRequest = typeof PrepareTaskRunInputsRequest.Type;

export const PreparedTaskRunInput = Schema.Struct({
  producerTaskId: BrokerIdentity,
  mountName: Identifier,
  guestPath: Schema.String.pipe(Schema.pattern(/^\/workspace\/inputs\/[A-Za-z0-9][A-Za-z0-9._:@-]*$/)),
});
export type PreparedTaskRunInput = typeof PreparedTaskRunInput.Type;

export const PrepareTaskRunInputsResponse = Schema.Struct({
  preparationId: Identifier,
  inputs: Schema.Array(PreparedTaskRunInput),
});
export type PrepareTaskRunInputsResponse = typeof PrepareTaskRunInputsResponse.Type;
