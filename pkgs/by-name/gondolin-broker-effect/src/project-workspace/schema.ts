import type { BrokerDatabaseService } from "../database.js";

const GENERATION_COLUMNS = new Set([
  "source_generation_id",
  "repository_id",
  "project",
  "project_revision",
  "source_revision",
  "provider_revision",
  "resolved_revision",
  "adapter_revision",
  "policy_digest",
  "state",
  "failure_reason",
  "created_at",
  "updated_at",
]);

/** Initialize durable Project source-generation, materialization, and result records. */
export const initializeProjectWorkspaceSchema = (database: BrokerDatabaseService): void =>
  database.transaction(() => {
    const db = database.connection;
    const prior = db.prepare(
      "SELECT name FROM sqlite_schema WHERE type='table' AND name='project_source_generations'",
    ).get() as { name: string } | undefined;
    if (prior !== undefined) {
      const columns = new Set(
        (db.prepare("PRAGMA table_info(project_source_generations)").all() as Array<{ name: string }>).map(
          ({ name }) => name,
        ),
      );
      if (
        columns.size !== GENERATION_COLUMNS.size ||
        [...GENERATION_COLUMNS].some((name) => !columns.has(name))
      ) {
        // No compatible provenance or recovery contract exists across a
        // schema break; clean cutover deliberately discards it.
        db.exec(`
          DROP TABLE IF EXISTS project_workspace_results;
          DROP TABLE IF EXISTS project_materialization_journal;
          DROP TABLE IF EXISTS project_materializations;
          DROP TABLE project_source_generations;
        `);
      }
    }
    db.exec(`
      CREATE TABLE IF NOT EXISTS project_source_generations (
        source_generation_id TEXT PRIMARY KEY CHECK (length(source_generation_id) = 64),
        repository_id TEXT NOT NULL,
        project TEXT NOT NULL,
        project_revision TEXT NOT NULL CHECK (length(project_revision) = 64),
        source_revision TEXT NOT NULL CHECK (length(source_revision) = 64),
        provider_revision TEXT NOT NULL CHECK (length(provider_revision) = 64),
        resolved_revision TEXT NOT NULL,
        adapter_revision TEXT NOT NULL CHECK (length(adapter_revision) = 64),
        policy_digest TEXT NOT NULL CHECK (length(policy_digest) = 64),
        state TEXT NOT NULL CHECK (state IN ('resolving','ready','failed')),
        failure_reason TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      ) STRICT;
      CREATE INDEX IF NOT EXISTS project_source_generations_lookup
        ON project_source_generations(repository_id, project, source_revision, state);

      CREATE TABLE IF NOT EXISTS project_materializations (
        materialization_id TEXT PRIMARY KEY CHECK (length(materialization_id) = 36),
        source_generation_id TEXT NOT NULL REFERENCES project_source_generations(source_generation_id),
        repository_id TEXT NOT NULL,
        project TEXT NOT NULL,
        project_revision TEXT NOT NULL CHECK (length(project_revision) = 64),
        task_id TEXT NOT NULL,
        run_id TEXT NOT NULL,
        environment_key TEXT NOT NULL,
        workspace_id TEXT NOT NULL,
        workspace_lease_id TEXT NOT NULL,
        lease_fencing_token INTEGER NOT NULL CHECK (lease_fencing_token > 0),
        permission TEXT NOT NULL CHECK (permission IN ('read-only','workspace-write')),
        authority_facts_json TEXT NOT NULL CHECK (
          json_valid(authority_facts_json) AND json_type(authority_facts_json) = 'object'
        ),
        policy_digest TEXT NOT NULL CHECK (length(policy_digest) = 64),
        state TEXT NOT NULL CHECK (state IN ('staging','installing','ready','released','failed','deleted')),
        entry_count INTEGER NOT NULL CHECK (entry_count >= 0),
        total_bytes INTEGER NOT NULL CHECK (total_bytes >= 0),
        failure_reason TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        ready_at INTEGER
      ) STRICT;
      CREATE UNIQUE INDEX IF NOT EXISTS project_materializations_one_run
        ON project_materializations(run_id)
        WHERE state NOT IN ('failed','deleted');
      CREATE INDEX IF NOT EXISTS project_materializations_task
        ON project_materializations(task_id, created_at DESC);
      CREATE INDEX IF NOT EXISTS project_materializations_state
        ON project_materializations(state, updated_at);

      CREATE TABLE IF NOT EXISTS project_materialization_journal (
        journal_id INTEGER PRIMARY KEY AUTOINCREMENT,
        materialization_id TEXT NOT NULL REFERENCES project_materializations(materialization_id),
        phase TEXT NOT NULL CHECK (phase IN (
          'staged','acquired','sanitized','validated','installed','released',
          'result_recorded','deleted','failed'
        )),
        detail TEXT,
        created_at INTEGER NOT NULL,
        UNIQUE(materialization_id, phase)
      ) STRICT;

      CREATE TABLE IF NOT EXISTS project_workspace_results (
        result_id TEXT PRIMARY KEY CHECK (length(result_id) = 36),
        materialization_id TEXT NOT NULL UNIQUE REFERENCES project_materializations(materialization_id),
        task_id TEXT NOT NULL,
        run_id TEXT NOT NULL,
        environment_key TEXT NOT NULL,
        workspace_id TEXT NOT NULL,
        project TEXT NOT NULL,
        project_revision TEXT NOT NULL CHECK (length(project_revision) = 64),
        source_generation_id TEXT NOT NULL REFERENCES project_source_generations(source_generation_id),
        result_generation TEXT NOT NULL CHECK (length(result_generation) = 64),
        changed INTEGER NOT NULL CHECK (changed IN (0,1)),
        changed_paths_json TEXT NOT NULL CHECK (
          json_valid(changed_paths_json) AND json_type(changed_paths_json) = 'array'
        ),
        state TEXT NOT NULL CHECK (state IN ('recorded','deleted')),
        created_at INTEGER NOT NULL,
        deleted_at INTEGER
      ) STRICT;
      CREATE INDEX IF NOT EXISTS project_workspace_results_task
        ON project_workspace_results(task_id, created_at DESC);
    `);
  });
