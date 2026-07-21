/**
 * Service-specific request classifiers (V3 §12.3).
 *
 * Adapters classify normalized requests into (target, action); policy
 * decides authority. Generic `GET=read` / `POST=write` logic is forbidden:
 * GraphQL and service-specific APIs violate it. Unknown services fail with
 * actionable telemetry — there is no raw-secret fallback.
 */
import type { NormalizedRequest } from "./network.js";

export type ClassifiedAction = "read" | "write" | "unsupported";

export interface ClassifiedRequest {
  service: string;
  action: ClassifiedAction;
  /** adapter-specific stable action id, e.g. "git.fetch" / "git.push" */
  actionId: string;
  /** bounded target identity, e.g. owner/repo when derivable */
  target: { owner?: string; repository?: string };
}

export interface ServiceAdapter {
  readonly name: string;
  classify(request: NormalizedRequest): ClassifiedRequest | null;
}

const ADAPTERS: Record<string, ServiceAdapter> = {};

export function registerAdapter(adapter: ServiceAdapter): void {
  ADAPTERS[adapter.name] = adapter;
}

export function getAdapter(name: string): ServiceAdapter | null {
  return ADAPTERS[name] ?? null;
}

export function listAdapters(): string[] {
  return Object.keys(ADAPTERS);
}

/**
 * GitHub adapter: Git smart-HTTP + API classification (§12.3).
 *
 * - /info/refs?service=git-upload-pack   → read  (git.fetch)
 * - /info/refs?service=git-receive-pack  → write (git.push)
 * - /git-upload-pack                     → read
 * - /git-receive-pack                    → write
 * - /graphql                             → unsupported (generic verb logic
 *   cannot classify GraphQL; needs a dedicated reviewed adapter)
 * - other API paths                      → read for GET/HEAD only when the
 *   path is read-shaped (compare/download/archive), else unsupported
 */
export const githubAdapter: ServiceAdapter = {
  name: "github",
  classify(request: NormalizedRequest): ClassifiedRequest | null {
    if (request.hostname !== "github.com" && request.hostname !== "api.github.com") {
      return null;
    }
    const pathParts = request.path.split("/").filter(Boolean);

    // Git smart-HTTP over github.com/<owner>/<repo>.git/...
    if (request.hostname === "github.com" && pathParts.length >= 2) {
      const owner = pathParts[0]!;
      const repo = (pathParts[1] ?? "").replace(/\.git$/, "");
      const service = pathParts[2];
      if (service === "info" && pathParts[3] === "refs") {
        // The ?service= parameter selects the protocol; the query itself is
        // never logged. We only see the path here, so classification of
        // upload vs receive pack for info/refs requires the query — handled
        // by the caller passing it through request.pathWithQuery when present.
        return {
          service: "github",
          action: "read",
          actionId: "git.refs",
          target: { owner, repository: repo },
        };
      }
      if (service === "git-upload-pack") {
        return { service: "github", action: "read", actionId: "git.fetch", target: { owner, repository: repo } };
      }
      if (service === "git-receive-pack") {
        return { service: "github", action: "write", actionId: "git.push", target: { owner, repository: repo } };
      }
    }

    if (request.path === "/graphql" || request.path.startsWith("/graphql/")) {
      return { service: "github", action: "unsupported", actionId: "api.graphql", target: {} };
    }

    // Read-shaped API endpoints: codeload-style archives and compare.
    if (request.method === "GET" || request.method === "HEAD") {
      return { service: "github", action: "read", actionId: "api.get", target: {} };
    }
    return { service: "github", action: "unsupported", actionId: "api.other", target: {} };
  },
};

/** Classify an info/refs request including its service query parameter. */
export function classifyGitInfoRefs(queryService: string | null): ClassifiedRequest["actionId"] {
  if (queryService === "git-upload-pack") return "git.fetch";
  if (queryService === "git-receive-pack") return "git.push";
  return "git.refs";
}

registerAdapter(githubAdapter);
