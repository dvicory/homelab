import { Schema } from "effect";
import { EnvironmentKey, WorkspaceId, WorkspaceLeaseId } from "./domain.js";

const Identifier = Schema.String.pipe(
  Schema.minLength(1),
  Schema.maxLength(256),
  Schema.pattern(/^[A-Za-z0-9][A-Za-z0-9._:@-]*$/),
);
const NonNegativeInt = Schema.Int.pipe(Schema.greaterThanOrEqualTo(0));

export const Sha256Digest = Schema.String.pipe(Schema.pattern(/^[0-9a-f]{64}$/));
export type Sha256Digest = typeof Sha256Digest.Type;

export const RevisionId = WorkspaceId;
export type RevisionId = typeof RevisionId.Type;

const relativePath = (value: string, allowWholeWorkspace: boolean): boolean => {
  if (allowWholeWorkspace && value === ".") return true;
  if (
    value.length === 0 ||
    value.startsWith("/") ||
    value.endsWith("/") ||
    value.includes("\0") ||
    value.normalize("NFC") !== value
  ) return false;
  return value.split("/").every((segment) => segment.length > 0 && segment !== "." && segment !== "..");
};

export const WorkspaceSelectionRoot = Schema.String.pipe(
  Schema.maxLength(4096),
  Schema.filter((value): value is string => relativePath(value, true)),
);
export type WorkspaceSelectionRoot = typeof WorkspaceSelectionRoot.Type;

export const WorkspaceRevisionPath = Schema.String.pipe(
  Schema.maxLength(4096),
  Schema.filter((value): value is string => relativePath(value, false)),
);
export type WorkspaceRevisionPath = typeof WorkspaceRevisionPath.Type;

export const WorkspaceRevisionEntry = Schema.Struct({
  path: WorkspaceRevisionPath,
  kind: Schema.Union(Schema.Literal("directory"), Schema.Literal("file")),
  mode: Schema.Union(Schema.Literal(0o644), Schema.Literal(0o755)),
  byteLength: NonNegativeInt,
  contentDigest: Schema.NullOr(Sha256Digest),
}).pipe(
  Schema.filter((entry) =>
    entry.kind === "directory"
      ? entry.mode === 0o755 && entry.byteLength === 0 && entry.contentDigest === null
      : entry.contentDigest !== null
  ),
);
export type WorkspaceRevisionEntry = typeof WorkspaceRevisionEntry.Type;

export const StageWorkspacePublication = Schema.Struct({
  finalizationId: Identifier,
  policyDecisionDigest: Sha256Digest,
  sourceActivationId: WorkspaceId,
  selectedRoots: Schema.Array(WorkspaceSelectionRoot).pipe(Schema.minItems(1), Schema.maxItems(128)),
});
export type StageWorkspacePublication = typeof StageWorkspacePublication.Type;

export const StageWorkspaceImport = Schema.Struct({
  preparationId: Identifier,
  policyDecisionDigest: Sha256Digest,
  sourceRevisionId: RevisionId,
  destinationTaskId: Identifier,
  destinationRunId: Identifier,
  destinationEnvironmentKey: EnvironmentKey,
  sourcePolicyDigest: Sha256Digest,
  destinationPolicyDigest: Sha256Digest,
  relationDigest: Sha256Digest,
});
export type StageWorkspaceImport = typeof StageWorkspaceImport.Type;

export const CompleteWorkspaceImport = Schema.Struct({
  preparationId: Identifier,
  destinationWorkspaceId: WorkspaceId,
  destinationWorkspaceLeaseId: WorkspaceLeaseId,
});
export type CompleteWorkspaceImport = typeof CompleteWorkspaceImport.Type;
