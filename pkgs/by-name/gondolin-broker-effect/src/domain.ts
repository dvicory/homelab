import { Schema } from "effect";

const Identifier = Schema.String.pipe(
  Schema.minLength(1),
  Schema.maxLength(256),
  Schema.pattern(/^[A-Za-z0-9][A-Za-z0-9._:@-]*$/),
);

const PositiveInt = Schema.Int.pipe(Schema.greaterThan(0));
const NonNegativeInt = Schema.Int.pipe(Schema.greaterThanOrEqualTo(0));
const Revision = Schema.String.pipe(Schema.pattern(/^[0-9a-f]{64}$/));

export const EnvironmentKey = Identifier;
export type EnvironmentKey = typeof EnvironmentKey.Type;

export const Generation = PositiveInt;
export type Generation = typeof Generation.Type;
export const WorkspaceId = Schema.String.pipe(
  Schema.pattern(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/),
);
export type WorkspaceId = typeof WorkspaceId.Type;

export const WorkspaceLeaseId = WorkspaceId;
export type WorkspaceLeaseId = typeof WorkspaceLeaseId.Type;

export const WorkspacePermission = Schema.Literal("read-only", "workspace-write");
export type WorkspacePermission = typeof WorkspacePermission.Type;

export const LaneAuthority = Schema.Struct({
  authorityClass: Identifier,
  workspaceProvider: Identifier,
  maximumPermission: WorkspacePermission,
});
export type LaneAuthority = typeof LaneAuthority.Type;

export const TaskRunAuthorityFacts = Schema.Struct({
  catalogueRevision: Revision,
  lane: Identifier,
  laneRevision: Revision,
  project: Schema.optional(Identifier),
  projectRevision: Schema.optional(Revision),
  sourceGeneration: Schema.optional(Revision),
  permission: WorkspacePermission,
  workspaceProvider: Identifier,
  authorityClass: Identifier,
  policyRevision: Revision,
});
export type TaskRunAuthorityFacts = typeof TaskRunAuthorityFacts.Type;

export const TaskRunAuthority = Schema.Struct({
  ...TaskRunAuthorityFacts.fields,
  policyDigest: Revision,
});
export type TaskRunAuthority = typeof TaskRunAuthority.Type;

export const TaskRunIdentity = Schema.Struct({
  taskId: Identifier,
  runId: Identifier,
});
export type TaskRunIdentity = typeof TaskRunIdentity.Type;

const OptionalTaskRunIdentity = {
  taskRun: Schema.optional(TaskRunIdentity),
};

export const EnsureRequest = Schema.Struct({
  environmentKey: EnvironmentKey,
  ...OptionalTaskRunIdentity,
});
export type EnsureRequest = typeof EnsureRequest.Type;

export const AuthorityBinding = Schema.Struct({
  profile: Identifier,
  executor: Identifier,
  authorityClass: Identifier,
  policyDigest: Schema.String.pipe(Schema.pattern(/^[0-9a-f]{64}$/)),
  workspaceId: WorkspaceId,
  workspaceLeaseId: WorkspaceLeaseId,
});
export type AuthorityBinding = typeof AuthorityBinding.Type;

export const BindAuthorityRequest = Schema.Struct({
  environmentKey: EnvironmentKey,
  authorityClass: Identifier,
  workspaceId: WorkspaceId,
  workspaceLeaseId: WorkspaceLeaseId,
});
export type BindAuthorityRequest = typeof BindAuthorityRequest.Type;


export const ActivateTaskRunRequest = Schema.Struct({
  environmentKey: EnvironmentKey,
  taskId: Identifier,
  runId: Identifier,
  ...TaskRunAuthorityFacts.fields,
  workspaceId: WorkspaceId,
  workspaceLeaseId: WorkspaceLeaseId,
});
export type ActivateTaskRunRequest = typeof ActivateTaskRunRequest.Type;

export const ConsumeTaskRunRequest = Schema.Struct({
  environmentKey: EnvironmentKey,
  ...TaskRunIdentity.fields,
});
export type ConsumeTaskRunRequest = typeof ConsumeTaskRunRequest.Type;

export const EnvironmentRef = Schema.Struct({
  environmentKey: EnvironmentKey,
  generation: Generation,
  ...OptionalTaskRunIdentity,
});
export type EnvironmentRef = typeof EnvironmentRef.Type;

export const WorkspaceAcquireRequest = Schema.Struct({
  environmentKey: EnvironmentKey,
  workspaceId: Schema.optional(WorkspaceId),
});
export type WorkspaceAcquireRequest = typeof WorkspaceAcquireRequest.Type;

export const WorkspaceRef = Schema.Struct({
  environmentKey: EnvironmentKey,
  workspaceId: WorkspaceId,
});
export type WorkspaceRef = typeof WorkspaceRef.Type;

export const WorkspaceLeaseRef = Schema.Struct({
  ...WorkspaceRef.fields,
  leaseId: WorkspaceLeaseId,
});
export type WorkspaceLeaseRef = typeof WorkspaceLeaseRef.Type;

export const StatusRequest = Schema.Struct({
  environmentKey: EnvironmentKey,
});
export type StatusRequest = typeof StatusRequest.Type;

export const ExecRequest = Schema.Struct({
  environmentKey: EnvironmentKey,
  generation: Generation,
  ...OptionalTaskRunIdentity,
  argv: Schema.Array(Schema.String).pipe(Schema.minItems(1), Schema.maxItems(256)),
  cwd: Schema.optional(Schema.String),
  env: Schema.optional(Schema.Record({ key: Schema.String, value: Schema.String })),
  stdinBase64: Schema.optional(Schema.String),
  timeoutMs: Schema.optional(PositiveInt),
  outputLimitBytes: Schema.optional(PositiveInt),
});
export type ExecRequest = typeof ExecRequest.Type;

export const FileRef = Schema.Struct({
  environmentKey: EnvironmentKey,
  generation: Generation,
  ...OptionalTaskRunIdentity,
  path: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(4096)),
});
export type FileRef = typeof FileRef.Type;

export const ReadFileRequest = Schema.Struct({
  ...FileRef.fields,
  maxBytes: Schema.optional(PositiveInt),
});
export type ReadFileRequest = typeof ReadFileRequest.Type;

export const WriteFileRequest = Schema.Struct({
  ...FileRef.fields,
  dataBase64: Schema.String,
  create: Schema.optional(Schema.Boolean),
  truncate: Schema.optional(Schema.Boolean),
});
export type WriteFileRequest = typeof WriteFileRequest.Type;

export const ListFileRequest = Schema.Struct({
  ...FileRef.fields,
  limit: Schema.optional(PositiveInt),
});
export type ListFileRequest = typeof ListFileRequest.Type;

export const MakeDirectoryRequest = Schema.Struct({
  ...FileRef.fields,
  recursive: Schema.optional(Schema.Boolean),
});
export type MakeDirectoryRequest = typeof MakeDirectoryRequest.Type;

export const RemoveFileRequest = Schema.Struct({
  ...FileRef.fields,
  recursive: Schema.optional(Schema.Boolean),
});
export type RemoveFileRequest = typeof RemoveFileRequest.Type;

export const Asset = Schema.Struct({
  path: Schema.String.pipe(Schema.minLength(1)),
  buildId: Schema.optional(Identifier),
});
export type Asset = typeof Asset.Type;

const NetworkPort = Schema.Int.pipe(
  Schema.greaterThan(0),
  Schema.lessThanOrEqualTo(65535),
);

export const NetworkOriginCapability = Schema.Struct({
  version: Schema.Literal(1),
  kind: Schema.Literal("network-origin"),
  scheme: Schema.Union(Schema.Literal("http"), Schema.Literal("https")),
  host: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(253)),
  ports: Schema.optional(Schema.Array(NetworkPort).pipe(Schema.minItems(1), Schema.maxItems(16))),
  addressMode: Schema.Union(Schema.Literal("public"), Schema.Literal("pinned-private")),
});
export type NetworkOriginCapability = typeof NetworkOriginCapability.Type;

export const CapabilityBatch = Schema.Array(Schema.Unknown).pipe(
  Schema.minItems(1),
  Schema.maxItems(32),
);
export type CapabilityBatch = typeof CapabilityBatch.Type;

export const PreparedNetworkOriginCapability = Schema.Struct({
  version: Schema.Literal(1),
  kind: Schema.Literal("network-origin"),
  scheme: Schema.Union(Schema.Literal("http"), Schema.Literal("https")),
  host: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(253)),
  ports: Schema.Array(NetworkPort).pipe(Schema.minItems(1), Schema.maxItems(16)),
  addressMode: Schema.Union(Schema.Literal("public"), Schema.Literal("pinned-private")),
  canonicalOrigin: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(320)),
  pinnedAddresses: Schema.Array(Schema.String).pipe(Schema.maxItems(32)),
});
export type PreparedNetworkOriginCapability = typeof PreparedNetworkOriginCapability.Type;

export const GrantScope = Schema.Union(
  Schema.Literal("once"),
  Schema.Literal("task"),
  Schema.Literal("conversation"),
  Schema.Literal("timed"),
  Schema.Literal("profile"),
  Schema.Literal("executor"),
);
export type GrantScope = typeof GrantScope.Type;

export const PrepareAccessRequest = Schema.Struct({
  environmentKey: EnvironmentKey,
  capabilities: CapabilityBatch,
  requestedScope: GrantScope,
  durationSeconds: Schema.optional(PositiveInt),
  rationale: Schema.optional(Schema.String.pipe(Schema.maxLength(2048))),
});
export type PrepareAccessRequest = typeof PrepareAccessRequest.Type;

export const DecideAccessRequest = Schema.Struct({
  requestId: Identifier,
  decision: Schema.Union(Schema.Literal("approve"), Schema.Literal("deny")),
  scope: Schema.optional(GrantScope),
  durationSeconds: Schema.optional(PositiveInt),
  principal: Identifier,
});
export type DecideAccessRequest = typeof DecideAccessRequest.Type;

export const ListGrantsRequest = Schema.Struct({
  environmentKey: Schema.optional(EnvironmentKey),
});
export type ListGrantsRequest = typeof ListGrantsRequest.Type;

export const RevokeGrantRequest = Schema.Struct({
  grantId: Identifier,
  principal: Identifier,
});
export type RevokeGrantRequest = typeof RevokeGrantRequest.Type;

export const RevokeEnvironmentGrantsRequest = Schema.Struct({
  environmentKey: EnvironmentKey,
  scopes: Schema.Array(GrantScope).pipe(Schema.minItems(1), Schema.maxItems(6)),
  principal: Identifier,
});
export type RevokeEnvironmentGrantsRequest = typeof RevokeEnvironmentGrantsRequest.Type;

export const NetworkDestination = Schema.Struct({
  kind: Schema.Union(
    Schema.Literal("exact"),
    Schema.Literal("subdomains"),
    Schema.Literal("host-and-subdomains"),
  ),
  host: Schema.String.pipe(Schema.minLength(1)),
  ports: Schema.optional(Schema.Array(NetworkPort).pipe(Schema.minItems(1))),
});
export type NetworkDestination = typeof NetworkDestination.Type;

export const NetworkPolicy = Schema.Struct({
  mode: Schema.Union(
    Schema.Literal("deny-all"),
    Schema.Literal("bundles"),
    Schema.Literal("public-anonymous"),
  ),
  destinations: Schema.Array(NetworkDestination),
});
export type NetworkPolicy = typeof NetworkPolicy.Type;

export const WorklaneLimits = Schema.Struct({
  maxCommandMs: PositiveInt,
  maxOutputBytes: PositiveInt,
  maxInputBytes: NonNegativeInt,
  maxFileBytes: PositiveInt,
  maxListEntries: PositiveInt,
  maxConcurrentExecs: PositiveInt,
});
export type WorklaneLimits = typeof WorklaneLimits.Type;

export const Worklane = Schema.Struct({
  asset: Identifier,
  memoryMiB: PositiveInt,
  cpus: PositiveInt,
  workspaceGuestPath: Schema.String.pipe(Schema.minLength(1)),
  limits: WorklaneLimits,
});
export type Worklane = typeof Worklane.Type;

export const decodeExact = <A, I>(schema: Schema.Schema<A, I>, input: unknown) =>
  Schema.decodeUnknown(schema)(input, { onExcessProperty: "error" });
