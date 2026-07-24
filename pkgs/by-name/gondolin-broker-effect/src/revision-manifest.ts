import { createHash } from "node:crypto";
import { Schema } from "effect";
import {
  Sha256Digest,
  WorkspaceRevisionEntry,
  type WorkspaceRevisionEntry as RevisionEntry,
} from "./revision-domain.js";
import { brokerError } from "./errors.js";
import { MANIFEST_VERSION } from "./revision-schema.js";

const DOMAIN = "agent-x.workspace-revision.manifest.v1\n";

export interface RevisionManifest {
  readonly version: 1;
  readonly manifestDigest: string;
  readonly entries: ReadonlyArray<RevisionEntry>;
}

const RevisionManifestFile = Schema.Struct({
  version: Schema.Literal(1),
  manifestDigest: Sha256Digest,
  entries: Schema.Array(WorkspaceRevisionEntry),
});

const decodeManifest = Schema.decodeUnknownSync(RevisionManifestFile, { onExcessProperty: "error" });
const decodeEntry = Schema.decodeUnknownSync(WorkspaceRevisionEntry, { onExcessProperty: "error" });

const orderedEntries = (input: ReadonlyArray<RevisionEntry>): ReadonlyArray<RevisionEntry> => {
  const entries = input.map((entry) => decodeEntry(entry)).sort((left, right) =>
    Buffer.compare(Buffer.from(left.path, "utf8"), Buffer.from(right.path, "utf8")));
  for (let index = 1; index < entries.length; index += 1) {
    if (entries[index - 1]?.path === entries[index]?.path) {
      throw brokerError("revision.conflict", "manifest contains duplicate paths");
    }
  }
  return entries;
};

const digestMaterial = (entries: ReadonlyArray<RevisionEntry>): string =>
  `${DOMAIN}${JSON.stringify(entries.map((entry) => [
    entry.path,
    entry.kind,
    entry.mode,
    entry.byteLength,
    entry.contentDigest,
  ]))}`;

export const makeRevisionManifest = (input: ReadonlyArray<RevisionEntry>): RevisionManifest => {
  const entries = orderedEntries(input);
  return {
    version: MANIFEST_VERSION,
    manifestDigest: createHash("sha256").update(digestMaterial(entries), "utf8").digest("hex"),
    entries,
  };
};

export const serializeRevisionManifest = (manifest: RevisionManifest): string =>
  `${JSON.stringify(manifest)}\n`;

export const parseRevisionManifest = (raw: string): RevisionManifest => {
  let decoded: typeof RevisionManifestFile.Type;
  try {
    decoded = decodeManifest(JSON.parse(raw));
  } catch (error) {
    throw brokerError("revision.failed", "stored revision manifest is invalid", {
      cause: error instanceof Error ? error.message : String(error),
    });
  }
  const expected = makeRevisionManifest(decoded.entries);
  if (decoded.version !== MANIFEST_VERSION || expected.manifestDigest !== decoded.manifestDigest) {
    throw brokerError("revision.failed", "stored revision manifest digest does not match its entries");
  }
  return expected;
};
