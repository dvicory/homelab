import { Schema } from "effect";
import { EnvironmentKey, WorkspacePermission } from "../domain.js";

const Identifier = Schema.String.pipe(
  Schema.minLength(1),
  Schema.maxLength(256),
  Schema.pattern(/^[A-Za-z0-9][A-Za-z0-9._:@-]*$/),
);
const Digest = Schema.String.pipe(Schema.pattern(/^[0-9a-f]{64}$/));

/** A source generation is an opaque immutable content identity, never a path. */
export const SourceGenerationId = Digest;
export type SourceGenerationId = typeof SourceGenerationId.Type;

/**
 * Trusted resolution of one Nix-authoritative Project source into an
 * immutable source generation. Control-plane only; model-facing protocols
 * never select repositories, revisions, or providers.
 */
export const ResolveProjectSourceRequest = Schema.Struct({
  project: Identifier,
  projectRevision: Digest,
  repositoryId: Identifier,
  sourceRevision: Digest,
});
export type ResolveProjectSourceRequest = typeof ResolveProjectSourceRequest.Type;

export const ResolveProjectSourceResponse = Schema.Struct({
  sourceGeneration: SourceGenerationId,
  resolvedRevision: Schema.String.pipe(Schema.minLength(1)),
  adapterRevision: Digest,
});
export type ResolveProjectSourceResponse = typeof ResolveProjectSourceResponse.Type;

export type SourceGenerationState = "resolving" | "ready" | "failed";

export interface SourceGenerationRecord {
  readonly sourceGenerationId: string;
  readonly repositoryId: string;
  readonly project: string;
  readonly projectRevision: string;
  readonly sourceRevision: string;
  readonly providerRevision: string;
  readonly resolvedRevision: string;
  readonly adapterRevision: string;
  readonly policyDigest: string;
  readonly state: SourceGenerationState;
  readonly failureReason: string | null;
  readonly createdAt: number;
  readonly updatedAt: number;
}

export type MaterializationState =
  | "staging"
  | "installing"
  | "ready"
  | "released"
  | "failed"
  | "deleted";

export type MaterializationPhase =
  | "staged"
  | "acquired"
  | "sanitized"
  | "validated"
  | "installed"
  | "released"
  | "result_recorded"
  | "deleted"
  | "failed";

export interface MaterializationRecord {
  readonly materializationId: string;
  readonly sourceGenerationId: string;
  readonly repositoryId: string;
  readonly project: string;
  readonly projectRevision: string;
  readonly taskId: string;
  readonly runId: string;
  readonly environmentKey: string;
  readonly workspaceId: string;
  readonly workspaceLeaseId: string;
  readonly leaseFencingToken: number;
  readonly permission: WorkspacePermission;
  readonly authorityFacts: Readonly<Record<string, unknown>>;
  readonly policyDigest: string;
  readonly state: MaterializationState;
  readonly entryCount: number;
  readonly totalBytes: number;
  readonly failureReason: string | null;
  readonly createdAt: number;
  readonly updatedAt: number;
  readonly readyAt: number | null;
}

export type ProjectResultState = "recorded" | "deleted";

/**
 * Bounded provenance describing how one task's private work plane diverged
 * from its baseline source generation. A descriptor never implies canonical
 * merge, push, or publication.
 */
export interface ProjectResultRecord {
  readonly resultId: string;
  readonly materializationId: string;
  readonly taskId: string;
  readonly runId: string;
  readonly environmentKey: string;
  readonly workspaceId: string;
  readonly project: string;
  readonly projectRevision: string;
  readonly sourceGenerationId: string;
  readonly resultGeneration: string;
  readonly changed: boolean;
  readonly changedPaths: ReadonlyArray<string>;
  readonly state: ProjectResultState;
  readonly createdAt: number;
  readonly deletedAt: number | null;
}

export const ReadProjectResultRequest = Schema.Struct({
  taskId: Identifier,
  runId: Identifier,
});
export type ReadProjectResultRequest = typeof ReadProjectResultRequest.Type;
