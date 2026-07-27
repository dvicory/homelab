import { Schema } from "effect";
import { EnvironmentKey, WorkspaceId, WorkspaceLeaseId } from "../domain.js";

const Identifier = Schema.String.pipe(
  Schema.minLength(1),
  Schema.maxLength(256),
  Schema.pattern(/^[A-Za-z0-9][A-Za-z0-9._:@-]*$/),
);
const Digest = Schema.String.pipe(Schema.pattern(/^[0-9a-f]{64}$/));

/** A handoff is an opaque durable identity, never a storage path. */
export const HandoffId = WorkspaceId;
export type HandoffId = typeof HandoffId.Type;

const normalizedRelativePath = (value: string): boolean => {
  if (
    value.length === 0 ||
    value.startsWith("/") ||
    value.endsWith("/") ||
    value.includes("\\") ||
    value.includes("\0") ||
    value.normalize("NFC") !== value
  ) return false;
  return value.split("/").every((segment) => segment.length > 0 && segment !== "." && segment !== "..");
};

/** A normalized path below the frozen handoff output directory. */
export const HandoffRelativePath = Schema.String.pipe(
  Schema.maxLength(4096),
  Schema.filter((value): value is string => normalizedRelativePath(value)),
);
export const SelectedArtifactPath = HandoffRelativePath.pipe(
  Schema.filter((value): value is string => value.startsWith("output/") && value.length > "output/".length),
);
export type SelectedArtifactPath = typeof SelectedArtifactPath.Type;

export const SelectedArtifacts = Schema.Array(SelectedArtifactPath).pipe(
  Schema.filter((values): values is ReadonlyArray<SelectedArtifactPath> => new Set(values).size === values.length),
);
export type SelectedArtifacts = typeof SelectedArtifacts.Type;

export type HandoffRelativePath = typeof HandoffRelativePath.Type;
export const CaptureWorkspaceHandoffRequest = Schema.Struct({
  finalizationId: Identifier,
  environmentKey: EnvironmentKey,
  taskId: Identifier,
  runId: Identifier,
  selectedArtifacts: SelectedArtifacts,
});
export type CaptureWorkspaceHandoffRequest = typeof CaptureWorkspaceHandoffRequest.Type;

export const ImportWorkspaceHandoffRequest = Schema.Struct({
  preparationId: Identifier,
  sourceHandoffId: HandoffId,
  sourceTaskId: Identifier,
  destinationTaskId: Identifier,
  destinationRunId: Identifier,
  destinationEnvironmentKey: EnvironmentKey,
});
export type ImportWorkspaceHandoffRequest = typeof ImportWorkspaceHandoffRequest.Type;

export const StageWorkspaceCapture = Schema.Struct({
  finalizationId: Identifier,
  policyDecisionDigest: Digest,
  sourceActivationId: WorkspaceId,
  selectedArtifacts: SelectedArtifacts,
});
export type StageWorkspaceCapture = typeof StageWorkspaceCapture.Type;

export const StageWorkspaceImport = Schema.Struct({
  preparationId: Identifier,
  policyDecisionDigest: Digest,
  sourceHandoffId: HandoffId,
  destinationTaskId: Identifier,
  destinationRunId: Identifier,
  destinationEnvironmentKey: EnvironmentKey,
  sourcePolicyDigest: Digest,
  destinationPolicyDigest: Digest,
});
export type StageWorkspaceImport = typeof StageWorkspaceImport.Type;

export const CompleteWorkspaceImport = Schema.Struct({
  preparationId: Identifier,
  destinationWorkspaceId: WorkspaceId,
  destinationWorkspaceLeaseId: WorkspaceLeaseId,
});
export type CompleteWorkspaceImport = typeof CompleteWorkspaceImport.Type;

export const PrepareWorkspaceExportRequest = Schema.Struct({
  deliveryId: Identifier,
  handoffId: HandoffId,
  relativePath: HandoffRelativePath,
});
export type PrepareWorkspaceExportRequest = typeof PrepareWorkspaceExportRequest.Type;

export const ReadWorkspaceExportRequest = Schema.Struct({
  exportToken: Identifier,
});
export type ReadWorkspaceExportRequest = typeof ReadWorkspaceExportRequest.Type;

export const ReleaseWorkspaceExportRequest = Schema.Struct({
  exportToken: Identifier,
});
export type ReleaseWorkspaceExportRequest = typeof ReleaseWorkspaceExportRequest.Type;
