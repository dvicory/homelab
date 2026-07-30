import type { BrokerDatabaseService } from "../database.js";

const HANDOFF_COLUMNS = new Set([
  "handoff_id",
  "finalization_id",
  "source_activation_id",
  "source_task_id",
  "source_run_id",
  "source_environment_key",
  "source_workspace_id",
  "source_workspace_lease_id",
  "source_lease_fencing_token",
  "authority_facts_json",
  "policy_digest",
  "policy_decision_digest",
  "selected_artifacts_json",
  "state",
  "entry_count",
  "total_bytes",
  "failure_reason",
  "created_at",
  "updated_at",
  "ready_at",
]);

/** Initialize the immutable handoff and append-only finalization journal. */
export const initializeHandoffSchema = (database: BrokerDatabaseService): void =>
  database.transaction(() => {
    const db = database.connection;
    const prior = db.prepare(
      "SELECT name FROM sqlite_schema WHERE type='table' AND name='workspace_handoffs'",
    ).get() as { name: string } | undefined;
    if (prior !== undefined) {
      const columns = new Set(
        (db.prepare("PRAGMA table_info(workspace_handoffs)").all() as Array<{ name: string }>).map(
          ({ name }) => name,
        ),
      );
      if ([...HANDOFF_COLUMNS].some((name) => !columns.has(name))) {
        // The earlier publication/import prototype has no compatible authority
        // or recovery contract. Clean cutover deliberately discards it.
        db.exec(`
          DROP TABLE IF EXISTS workspace_handoff_exports;
          DROP TABLE IF EXISTS workspace_handoff_imports;
          DROP TABLE IF EXISTS workspace_handoff_finalization_journal;
          DROP TABLE workspace_handoffs;
        `);
      }
    }
    db.exec(`
      DROP TABLE IF EXISTS workspace_handoff_exports;
      DROP TABLE IF EXISTS workspace_handoff_imports;

      CREATE TABLE IF NOT EXISTS workspace_handoffs (
        handoff_id TEXT PRIMARY KEY CHECK (length(handoff_id) = 36),
        finalization_id TEXT NOT NULL UNIQUE,
        source_activation_id TEXT NOT NULL UNIQUE REFERENCES task_run_activations(activation_id),
        source_task_id TEXT NOT NULL,
        source_run_id TEXT NOT NULL,
        source_environment_key TEXT NOT NULL,
        source_workspace_id TEXT NOT NULL,
        source_workspace_lease_id TEXT NOT NULL,
        source_lease_fencing_token INTEGER NOT NULL CHECK (source_lease_fencing_token > 0),
        authority_facts_json TEXT NOT NULL CHECK (json_valid(authority_facts_json) AND json_type(authority_facts_json) = 'object'),
        policy_digest TEXT NOT NULL CHECK (length(policy_digest) = 64),
        policy_decision_digest TEXT NOT NULL CHECK (length(policy_decision_digest) = 64),
        selected_artifacts_json TEXT NOT NULL CHECK (json_valid(selected_artifacts_json) AND json_type(selected_artifacts_json) = 'array'),
        state TEXT NOT NULL CHECK (state IN ('staging','ready','quarantined','failed')),
        entry_count INTEGER NOT NULL CHECK (entry_count >= 0),
        total_bytes INTEGER NOT NULL CHECK (total_bytes >= 0),
        failure_reason TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        ready_at INTEGER,
        reclaimable INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS workspace_handoffs_source
        ON workspace_handoffs(source_task_id, source_run_id, created_at DESC);
      CREATE INDEX IF NOT EXISTS workspace_handoffs_state
        ON workspace_handoffs(state, updated_at);

      CREATE TABLE IF NOT EXISTS workspace_handoff_finalization_journal (
        journal_id INTEGER PRIMARY KEY AUTOINCREMENT,
        finalization_id TEXT NOT NULL REFERENCES workspace_handoffs(finalization_id),
        handoff_id TEXT NOT NULL REFERENCES workspace_handoffs(handoff_id),
        phase TEXT NOT NULL CHECK (phase IN (
          'staged','fenced','vm_closed','copied','validated','installed','ready','quarantined','failed'
        )),
        detail TEXT,
        created_at INTEGER NOT NULL,
        UNIQUE(finalization_id, phase)
      );
      CREATE INDEX IF NOT EXISTS workspace_handoff_journal_operation
        ON workspace_handoff_finalization_journal(finalization_id, journal_id);
    `);
    const columns = new Set(
      (db.prepare("PRAGMA table_info(workspace_handoffs)").all() as Array<{ name: string }>).map(
        ({ name }) => name,
      ),
    );
    if (!columns.has("reclaimable")) {
      db.exec("ALTER TABLE workspace_handoffs ADD COLUMN reclaimable INTEGER NOT NULL DEFAULT 0");
    }
  });
