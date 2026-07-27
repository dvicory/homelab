import type { BrokerDatabaseService } from "../database.js";
import { brokerError } from "../errors.js";

/**
 * Initialize the hashless finalized-handoff tables.
 *
 * The old revision tables are deliberately not migrated by interpretation: a
 * broker that sees them fails closed rather than treating revision metadata as
 * an authenticated handoff.
 */
export const initializeHandoffSchema = (database: BrokerDatabaseService): void =>
  database.transaction(() => {
    const db = database.connection;
    const legacy = db.prepare(`
      SELECT name FROM sqlite_schema
      WHERE type='table' AND name IN ('workspace_revisions', 'workspace_revision_imports')
      ORDER BY name
    `).all() as Array<{ name: string }>;
    if (legacy.length > 0) {
      throw brokerError(
        "handoff.failed",
        "legacy workspace revision state is present; reset or migrate it explicitly before enabling handoffs",
        { tables: legacy.map(({ name }) => name) },
      );
    }

    db.exec(`
      CREATE TABLE IF NOT EXISTS workspace_handoffs (
        handoff_id TEXT PRIMARY KEY CHECK (length(handoff_id) = 36),
        finalization_id TEXT NOT NULL UNIQUE,
        source_activation_id TEXT NOT NULL UNIQUE REFERENCES task_run_activations(activation_id),
        source_task_id TEXT NOT NULL,
        source_run_id TEXT NOT NULL,
        source_environment_key TEXT NOT NULL,
        source_workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
        source_workspace_lease_id TEXT NOT NULL REFERENCES workspace_leases(lease_id),
        source_lease_fencing_token INTEGER NOT NULL CHECK (source_lease_fencing_token > 0),
        policy_digest TEXT NOT NULL CHECK (length(policy_digest) = 64),
        policy_decision_digest TEXT NOT NULL CHECK (length(policy_decision_digest) = 64),
        selected_artifacts_json TEXT NOT NULL CHECK (json_valid(selected_artifacts_json) AND json_type(selected_artifacts_json) = 'array'),
        state TEXT NOT NULL CHECK (state IN ('staging','ready','publication_failed','quarantined','failed')),
        entry_count INTEGER NOT NULL CHECK (entry_count >= 0),
        total_bytes INTEGER NOT NULL CHECK (total_bytes >= 0),
        failure_reason TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        ready_at INTEGER,
        CHECK (
          (state = 'ready' AND ready_at IS NOT NULL AND failure_reason IS NULL)
          OR (state = 'staging' AND ready_at IS NULL AND failure_reason IS NULL)
          OR (state IN ('publication_failed','quarantined','failed') AND ready_at IS NULL AND failure_reason IS NOT NULL)
        )
      ) STRICT;

      CREATE INDEX IF NOT EXISTS workspace_handoffs_source_task
        ON workspace_handoffs(source_task_id, created_at DESC);
      CREATE INDEX IF NOT EXISTS workspace_handoffs_state
        ON workspace_handoffs(state, updated_at);

      CREATE TABLE IF NOT EXISTS workspace_handoff_imports (
        preparation_id TEXT PRIMARY KEY,
        source_handoff_id TEXT NOT NULL REFERENCES workspace_handoffs(handoff_id),
        source_task_id TEXT NOT NULL,
        source_run_id TEXT NOT NULL,
        destination_task_id TEXT NOT NULL,
        destination_run_id TEXT NOT NULL UNIQUE,
        destination_environment_key TEXT NOT NULL,
        source_policy_digest TEXT NOT NULL CHECK (length(source_policy_digest) = 64),
        destination_policy_digest TEXT NOT NULL CHECK (length(destination_policy_digest) = 64),
        policy_decision_digest TEXT NOT NULL CHECK (length(policy_decision_digest) = 64),
        destination_workspace_id TEXT REFERENCES workspaces(workspace_id),
        destination_workspace_lease_id TEXT REFERENCES workspace_leases(lease_id),
        destination_lease_fencing_token INTEGER CHECK (
          destination_lease_fencing_token IS NULL OR destination_lease_fencing_token > 0
        ),
        state TEXT NOT NULL CHECK (state IN ('staging','ready','failed')),
        failure_reason TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        ready_at INTEGER,
        CHECK (
          (state = 'staging' AND failure_reason IS NULL AND ready_at IS NULL)
          OR (state = 'ready' AND destination_workspace_id IS NOT NULL AND
            destination_workspace_lease_id IS NOT NULL AND destination_lease_fencing_token IS NOT NULL AND
            failure_reason IS NULL AND ready_at IS NOT NULL)
          OR (state = 'failed' AND destination_workspace_id IS NULL AND
            destination_workspace_lease_id IS NULL AND destination_lease_fencing_token IS NULL AND
            failure_reason IS NOT NULL AND ready_at IS NULL)
        )
      ) STRICT;

      CREATE INDEX IF NOT EXISTS workspace_handoff_imports_source
        ON workspace_handoff_imports(source_handoff_id, created_at DESC);

      CREATE TABLE IF NOT EXISTS workspace_handoff_exports (
        export_token TEXT PRIMARY KEY,
        delivery_id TEXT NOT NULL UNIQUE,
        handoff_id TEXT NOT NULL REFERENCES workspace_handoffs(handoff_id),
        relative_path TEXT NOT NULL,
        file_name TEXT NOT NULL,
        byte_size INTEGER NOT NULL CHECK (byte_size >= 0),
        expires_at INTEGER NOT NULL,
        state TEXT NOT NULL CHECK (state IN ('active','released','expired')),
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      ) STRICT;

      CREATE INDEX IF NOT EXISTS workspace_handoff_exports_expiry
        ON workspace_handoff_exports(state, expires_at);
      CREATE INDEX IF NOT EXISTS workspace_handoff_exports_handoff
        ON workspace_handoff_exports(handoff_id, relative_path);
    `);
  });
