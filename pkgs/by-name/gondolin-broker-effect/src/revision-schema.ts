import type { BrokerDatabaseService } from "./database.js";

export const MANIFEST_VERSION = 1;

export const initializeRevisionSchema = (database: BrokerDatabaseService): void =>
  database.transaction(() => database.connection.exec(`
    CREATE TABLE IF NOT EXISTS workspace_revisions (
      revision_id TEXT PRIMARY KEY CHECK (length(revision_id) = 36),
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
      selected_roots_json TEXT NOT NULL CHECK (json_valid(selected_roots_json)),
      state TEXT NOT NULL CHECK (state IN ('staging','ready','quarantined','failed')),
      manifest_version INTEGER NOT NULL CHECK (manifest_version = 1),
      manifest_digest TEXT CHECK (manifest_digest IS NULL OR length(manifest_digest) = 64),
      entry_count INTEGER NOT NULL CHECK (entry_count >= 0),
      logical_bytes INTEGER NOT NULL CHECK (logical_bytes >= 0),
      failure_reason TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      ready_at INTEGER,
      CHECK (
        (state = 'ready' AND manifest_digest IS NOT NULL AND ready_at IS NOT NULL AND failure_reason IS NULL)
        OR (state = 'staging' AND manifest_digest IS NULL AND ready_at IS NULL AND failure_reason IS NULL)
        OR (state IN ('quarantined','failed') AND manifest_digest IS NULL AND ready_at IS NULL AND failure_reason IS NOT NULL)
      )
    ) STRICT;

    CREATE INDEX IF NOT EXISTS workspace_revisions_source_task
      ON workspace_revisions(source_task_id, created_at DESC);
    CREATE INDEX IF NOT EXISTS workspace_revisions_state
      ON workspace_revisions(state, updated_at);

    CREATE TABLE IF NOT EXISTS workspace_revision_imports (
      preparation_id TEXT PRIMARY KEY,
      source_revision_id TEXT NOT NULL REFERENCES workspace_revisions(revision_id),
      source_task_id TEXT NOT NULL,
      source_run_id TEXT NOT NULL,
      destination_task_id TEXT NOT NULL,
      destination_run_id TEXT NOT NULL UNIQUE,
      destination_environment_key TEXT NOT NULL,
      source_policy_digest TEXT NOT NULL CHECK (length(source_policy_digest) = 64),
      destination_policy_digest TEXT NOT NULL CHECK (length(destination_policy_digest) = 64),
      policy_decision_digest TEXT NOT NULL CHECK (length(policy_decision_digest) = 64),
      relation_digest TEXT NOT NULL CHECK (length(relation_digest) = 64),
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
        (state = 'staging' AND (
          (destination_workspace_id IS NULL AND destination_workspace_lease_id IS NULL AND
            destination_lease_fencing_token IS NULL)
          OR (destination_workspace_id IS NOT NULL AND destination_workspace_lease_id IS NOT NULL AND
            destination_lease_fencing_token IS NOT NULL)
        ) AND failure_reason IS NULL AND ready_at IS NULL)
        OR (state = 'ready' AND destination_workspace_id IS NOT NULL AND
          destination_workspace_lease_id IS NOT NULL AND destination_lease_fencing_token IS NOT NULL AND
          failure_reason IS NULL AND ready_at IS NOT NULL)
        OR (state = 'failed' AND destination_workspace_id IS NULL AND
          destination_workspace_lease_id IS NULL AND destination_lease_fencing_token IS NULL AND
          failure_reason IS NOT NULL AND ready_at IS NULL)
      )
    ) STRICT;

    CREATE INDEX IF NOT EXISTS workspace_revision_imports_source
      ON workspace_revision_imports(source_revision_id, created_at DESC);
  `));
