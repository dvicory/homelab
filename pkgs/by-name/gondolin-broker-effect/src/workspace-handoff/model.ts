import { Schema } from "effect";
import { EnvironmentKey, WorkspaceId } from "../domain.js";

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
export const StageWorkspaceCapture = Schema.Struct({
  finalizationId: Identifier,
  sourceActivationId: Identifier,
  policyDecisionDigest: Digest,
  selectedArtifacts: SelectedArtifacts,
});
export type StageWorkspaceCapture = typeof StageWorkspaceCapture.Type;



export const ReadWorkspaceArtifactRequest = Schema.Struct({
  handoffId: HandoffId,
  relativePath: HandoffRelativePath,
});
export type ReadWorkspaceArtifactRequest = typeof ReadWorkspaceArtifactRequest.Type;
