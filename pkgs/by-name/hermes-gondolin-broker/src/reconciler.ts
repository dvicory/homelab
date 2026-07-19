/**
 * Startup and periodic reconciliation (V3 §15.4).
 *
 * Compares registry rows, workspace directories, runtime files, live VMs,
 * grants, and tombstones; terminates orphan processes; marks interrupted
 * creations/closures failed or warm; expires grants and process buffers;
 * quarantines unknown directories; and never resurrects a deleted or
 * tombstoned key from leftover files.
 */
import fs from "node:fs";
import path from "node:path";
import type { AuditLog } from "./audit.js";
import type { LifecycleManager } from "./lifecycle.js";
import type { Registry } from "./registry.js";

export interface ReconcileReport {
  markedFailed: string[];
  markedWarm: string[];
  expiredProcesses: number;
  quarantinedDirs: string[];
  prunedAuditRows: number;
}

export interface ReconcilerDeps {
  registry: Registry;
  audit: AuditLog;
  lifecycle: LifecycleManager;
  stateDir: string;
  runtimeDir: string;
  pruneAudit: () => number;
  now?: () => number;
}

/** Directories the broker owns outright under stateDir (never quarantined). */
const OWNED_STATE_DIRS: Record<string, true> = {
  conversations: true,
  worktrees: true,
  projects: true,
  durable: true,
  quarantine: true,
  tombstones: true,
};

export function reconcile(deps: ReconcilerDeps): ReconcileReport {
  const now = deps.now?.() ?? Date.now();
  const report: ReconcileReport = {
    markedFailed: [],
    markedWarm: [],
    expiredProcesses: 0,
    quarantinedDirs: [],
    prunedAuditRows: 0,
  };

  // 1. Interrupted lifecycle transitions: 'creating' never finished booting
  //    (broker died mid-boot) → failed; 'closing' never finished teardown →
  //    warm (workspace kept). Rows pointing at a live in-memory VM are fine.
  for (const row of deps.registry.listEnvironments()) {
    if (deps.registry.getTombstone(row.envKey)) {
      // A tombstoned key must never be resurrected from a leftover row.
      deps.registry.deleteEnvironment(row.envKey);
      continue;
    }
    if (row.state === "creating" || row.state === "recreating") {
      deps.registry.updateEnvironmentState(row.envKey, "failed", "interrupted_creation", now);
      report.markedFailed.push(row.envKey);
    } else if (row.state === "closing") {
      deps.registry.updateEnvironmentState(row.envKey, "warm", "interrupted_close", now);
      report.markedWarm.push(row.envKey);
    }
  }

  // 2. Expire finished background process buffers.
  report.expiredProcesses = deps.registry.deleteExpiredProcesses(now);

  // 3. Quarantine unknown workspace directories: a directory without a
  //    valid registry row is orphaned, never adopted (§15.2).
  const conversationsDir = path.join(deps.stateDir, "conversations");
  if (fs.existsSync(conversationsDir)) {
    const known = new Set(
      deps.registry
        .listEnvironments()
        .map((row) => row.workspacePath)
        .filter((p): p is string => p !== null)
        .map((p) => path.basename(p)),
    );
    for (const entry of fs.readdirSync(conversationsDir, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      if (known.has(entry.name)) continue;
      if (deps.registry.getTombstone(entry.name)) {
        // Leftover data of a deleted key: never resurrect — remove it.
        fs.rmSync(path.join(conversationsDir, entry.name), { recursive: true, force: true });
        continue;
      }
      const quarantineDir = path.join(deps.stateDir, "quarantine");
      fs.mkdirSync(quarantineDir, { recursive: true, mode: 0o700 });
      const target = path.join(quarantineDir, `${entry.name}-${now}`);
      fs.renameSync(path.join(conversationsDir, entry.name), target);
      report.quarantinedDirs.push(target);
    }
  }

  // 4. Drop runtime files of generations nothing tracks.
  if (fs.existsSync(deps.runtimeDir)) {
    const liveGenerations = new Set(
      deps.registry.listEnvironments().map((row) => `${row.envKey}-${row.generation}`),
    );
    for (const entry of fs.readdirSync(deps.runtimeDir)) {
      const match = entry.match(/^root-(.+)\.qcow2$/);
      if (!match) continue;
      const stem = match[1]!;
      if ([...liveGenerations].some((g) => stem === g)) continue;
      try {
        fs.rmSync(path.join(deps.runtimeDir, entry), { force: true });
      } catch {
        // best effort
      }
    }
  }

  // 5. Audit retention.
  report.prunedAuditRows = deps.pruneAudit();

  deps.audit.emit({
    ts: now,
    profile: "broker",
    worklane: null,
    envKey: null,
    generation: null,
    requestId: null,
    event: "reconcile",
    reason: null,
    layer: null,
    metadata: {
      markedFailed: report.markedFailed.length,
      markedWarm: report.markedWarm.length,
      expiredProcesses: report.expiredProcesses,
      quarantinedDirs: report.quarantinedDirs.length,
      prunedAuditRows: report.prunedAuditRows,
    },
  });
  return report;
}

/** Ensure the broker's state directory layout exists with owner-only modes. */
export function ensureStateLayout(stateDir: string, runtimeDir: string): void {
  for (const dir of Object.keys(OWNED_STATE_DIRS)) {
    fs.mkdirSync(path.join(stateDir, dir), { recursive: true, mode: 0o700 });
  }
  fs.mkdirSync(runtimeDir, { recursive: true, mode: 0o700 });
}
