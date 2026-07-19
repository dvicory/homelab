/**
 * Broker activity log (V3 §17).
 *
 * NOT a complete activity journal: it observes broker requests and decisions,
 * execution start/end/signal/cancel metadata, selected VFS operations,
 * mediated network request metadata and decisions, grant changes, lifecycle
 * and reconciliation events, and export operations. It does not observe
 * arbitrary rootfs/tmpfs file activity, every child process, semantic
 * causality, opaque WebSocket traffic, or host activity outside the broker.
 *
 * Default events exclude command bodies, file contents, response bodies,
 * headers, URLs with queries, placeholders, and secret values. Metadata is
 * bounded; retention is enforced by count and age.
 */
import { DatabaseSync } from "node:sqlite";

export type AuditEventType =
  | "request"
  | "decision"
  | "exec.start"
  | "exec.end"
  | "exec.signal"
  | "exec.cancel"
  | "fs.op"
  | "net.request"
  | "net.decision"
  | "grant.activate"
  | "grant.revoke"
  | "lifecycle"
  | "reconcile"
  | "export";

export interface AuditEvent {
  ts: number;
  profile: string;
  worklane: string | null;
  envKey: string | null;
  generation: string | null;
  requestId: number | null;
  event: AuditEventType;
  reason: string | null;
  /** constraining policy layer: floor | profile | worklane | template | grant */
  layer: string | null;
  metadata: Record<string, unknown>;
}

/** Metadata keys that may carry sensitive content and are always dropped. */
const FORBIDDEN_METADATA: Record<string, true> = {
  command: true,
  argv: true,
  body: true,
  content: true,
  headers: true,
  query: true,
  secret: true,
  placeholder: true,
  token: true,
  authorization: true,
  cookie: true,
};

/** Per-value bounds so a single event cannot balloon the log. */
const MAX_METADATA_ENTRIES = 32;
const MAX_METADATA_STRING = 256;

/** Strip anything that could carry command bodies, file contents, response
 * bodies, headers, URLs with queries, placeholders, or secret values. */
export function sanitizeMetadata(metadata: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  let count = 0;
  for (const [key, value] of Object.entries(metadata)) {
    if (count >= MAX_METADATA_ENTRIES) break;
    const lowered = key.toLowerCase();
    if (FORBIDDEN_METADATA[lowered]) continue;
    if (typeof value === "string") {
      // URLs are stored origin-only (no query/fragment).
      out[key] = value.length > MAX_METADATA_STRING ? `${value.slice(0, MAX_METADATA_STRING)}…` : value;
    } else if (
      typeof value === "number" ||
      typeof value === "boolean" ||
      value === null
    ) {
      out[key] = value;
    } else {
      continue; // nested structures are not log-safe by default
    }
    count += 1;
  }
  return out;
}

/** Origin (scheme://host[:port]) with query and fragment stripped. */
export function originOnly(url: string): string {
  try {
    const parsed = new URL(url);
    return `${parsed.protocol}//${parsed.host}`;
  } catch {
    return "<unparseable>";
  }
}

export interface AuditQuery {
  envKey?: string;
  event?: AuditEventType;
  since?: number;
  limit?: number;
}

export class AuditLog {
  #db: DatabaseSync;
  #maxRows: number;
  #maxAgeMs: number;

  constructor(db: DatabaseSync, options: { maxRows?: number; maxAgeMs?: number } = {}) {
    this.#db = db;
    this.#maxRows = options.maxRows ?? 1_000_000;
    this.#maxAgeMs = options.maxAgeMs ?? 30 * 24 * 60 * 60 * 1000;
  }

  emit(event: AuditEvent): void {
    const metadata = sanitizeMetadata(event.metadata);
    this.#db
      .prepare(
        `INSERT INTO audit (ts, profile, worklane, env_key, generation, request_id, event, reason, layer, metadata)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        event.ts,
        event.profile,
        event.worklane,
        event.envKey,
        event.generation,
        event.requestId,
        event.event,
        event.reason,
        event.layer,
        JSON.stringify(metadata),
      );
  }

  query(filter: AuditQuery): AuditEvent[] {
    const clauses: string[] = [];
    const params: (string | number)[] = [];
    if (filter.envKey !== undefined) {
      clauses.push("env_key = ?");
      params.push(filter.envKey);
    }
    if (filter.event !== undefined) {
      clauses.push("event = ?");
      params.push(filter.event);
    }
    if (filter.since !== undefined) {
      clauses.push("ts >= ?");
      params.push(filter.since);
    }
    const limit = Math.min(filter.limit ?? 500, 5000);
    const where = clauses.length === 0 ? "" : ` WHERE ${clauses.join(" AND ")}`;
    const rows = this.#db
      .prepare(`SELECT * FROM audit${where} ORDER BY ts DESC LIMIT ?`)
      .all(...params, limit) as unknown as Array<{
      ts: number;
      profile: string;
      worklane: string | null;
      env_key: string | null;
      generation: string | null;
      request_id: number | null;
      event: string;
      reason: string | null;
      layer: string | null;
      metadata: string;
    }>;
    return rows.map((row) => ({
      ts: row.ts,
      profile: row.profile,
      worklane: row.worklane,
      envKey: row.env_key,
      generation: row.generation,
      requestId: row.request_id,
      event: row.event as AuditEventType,
      reason: row.reason,
      layer: row.layer,
      metadata: JSON.parse(row.metadata) as Record<string, unknown>,
    }));
  }

  /** Enforce retention: drop rows past age and count caps. */
  prune(now: number): number {
    const cutoff = now - this.#maxAgeMs;
    const byAge = this.#db.prepare("DELETE FROM audit WHERE ts < ?").run(cutoff);
    const byCount = this.#db
      .prepare(
        `DELETE FROM audit WHERE id NOT IN (
           SELECT id FROM audit ORDER BY ts DESC LIMIT ?
         )`,
      )
      .run(this.#maxRows);
    return Number(byAge.changes) + Number(byCount.changes);
  }
}
