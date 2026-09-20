# Household backup policy handoff

Status: operator decisions only. Nothing here schedules a capture, provisions a
destination, or authorizes production access. Routine capture tooling is
OpenSpec `reliable-household-services` task 2.4 and does not exist yet; no
scheduler, no off-host destination and no restore tooling are implemented.
Recommended defaults below are recommendations, not measured or declared facts.
Pause and restore numbers must come from disposable measurement before any
schedule is set.

Read the [generated operations runbook](../operations.md) for the retained-state
table this policy covers and the [software cutover](software-cutover.md) for the
release gate that requires an independent copy before production changes. The
per-application capture analysis (task 2.3) lives in the private continuity
notes, not in this repository.

## Data classes

| Class | Contents | Why it is separate |
| --- | --- | --- |
| Application state | Every `/var/lib/homelab/compute-1/state/<key>` in the retained-state table except the Immich library | Small, changes constantly, has a native export per application |
| Irreplaceable photos and documents | `immich-library` (originals, profile, uploaded files) plus its matched `immich-postgres` dump | Cannot be re-acquired; the only class where loss is permanent |
| Bulk media | `/srv/media/data` (mergerfs, TiB scale) | Re-acquirable through the Arr stack; protected by a separate policy, not by application-state capture |
| Disposable | Argo datastore, container caches, Prometheus TSDB, Alertmanager, Loki | Rebuilt from Git and bounded retention; no recovery point unless the operator decides otherwise (decision 5) |

## Terms the decisions use

- **RPO (tolerated data loss):** the oldest acceptable recovery point when the
  host is lost. Cadence must be at least as frequent as the RPO.
- **Independent destination:** a copy that survives the failure the backup
  exists for. For this fleet that means outside `rpool`, outside `hvn-hyp1`,
  and for the irreplaceable class outside the house. The same encrypted pool,
  a second dataset, a ZFS snapshot, an Incus export, or a copy on the media
  pool of the same host are all same-host copies and are **not** backups
  (`household-services` spec: "Same-host recovery points SHALL NOT be described
  as independent backups"). No external destination has been purchased or
  provisioned; selecting one is outside this change and needs its own
  authorization.
- **Consistency guarantee:** what the native export promises about the state
  inside one recovery point. A whole-`/persist` ZFS snapshot is crash-consistent
  only; it may serve as a transfer source after native exports land, never as
  the recovery point itself.
- **Truthful completion:** a recovery point is complete only when the native
  export finished, its artifact was verified (archive opens, JSON parses, dump
  restores or at least `pg_restore --list` succeeds), the recorded
  application version matches, and the copy reached the independent
  destination with a checksum. Export success alone is not completion, and one
  application's success must not clear another's failed state.

## Decisions per data class

Recommended defaults, with the reasoning the operator should confirm or reject.

| Class | RPO options | Recommended | Cadence | Retention | Destination requirement | Pause limit |
| --- | --- | --- | --- | --- | --- | --- |
| Application state | 1 h / 24 h / 7 d | 24 h: household records (requests, history, Kanidm accounts) rarely change by more than a day's worth | nightly, one window per application, unsynchronized | 7 daily + 4 weekly; longest retention for Kanidm because an account deletion is only noticed late | off-host; off-site preferred but not required | seconds; none for most exports |
| Irreplaceable photos | 1 h / 24 h / 7 d | 24 h for the database dump; files are immutable once uploaded, so a 24 h file sync loses at most one day of uploads | nightly dump then incremental file copy | dumps: 30 daily; files: keep deleted originals 90 d before purge | off-host **and** off-site (3-2-1: two copies on two media, one away) | none with DB-first/files-second; minutes if maintenance mode is chosen (decision 1) |
| Bulk media | accept loss / partial (curated subset) / full | accept loss for the re-acquirable bulk; curate any subset that is not re-acquirable into the irreplaceable class | none by default | n/a | if any subset is protected: off-host, capacity planned separately | none |
| Disposable | none | none; rebuild from Git plus retention windows | n/a | n/a | n/a | n/a |

Restore test expectation for every protected class: restore one recovery point
into an empty disposable target at least quarterly and after any pinned
application version change, and verify user-visible behavior (a login, a
library entry, a request record, a photo), not only that files exist. The first
scheduled backup is not trusted until its restore has been performed once.

## Consistency guarantee and interruption per application

From the task 2.3 analysis. "Interruption" is the expected pause before
measurement; task 2.4 must measure it. Any pause above seconds for routine
capture, or above minutes overnight, returns to the operator instead of being
absorbed silently.

| Application | Native export | Guarantee | Expected interruption |
| --- | --- | --- | --- |
| Jellyfin | `POST /Backup/Create` archive | application-consistent; restore needs a restart | none |
| Immich | scheduled/manual database dump into `UPLOAD_LOCATION/backups`, then file copy | database-consistent; files may include uploads newer than the dump (orphans reconcilable by v3.1.0 integrity jobs) | none, or minutes in maintenance mode |
| Radarr, Sonarr, Prowlarr | `Backup` command, copy newest zip | application-consistent | none |
| SABnzbd | `create_backup` zip of ini and admin databases | configuration and history consistent; in-flight queue depends on decision 2 | none or seconds if paused |
| Seerr | `sqlite3 .backup` plus `settings.json` | database-consistent; settings file copied separately | none |
| Kanidm | declared `[online_backup]` JSON export (already in `identity.nix`, nightly 22:00, same-host only) | application-consistent | none |
| Grafana | `sqlite3 .backup` of `grafana.db` | database-consistent | none |

Cross-application writers (Argo PostSync hook Jobs for roots, Configarr,
Prowlarr and Seerr; the Kanidm provision Job) write idempotent managed fields
through native APIs during a sync. They are not part of a shared capture
boundary unless a torn run is demonstrated (decision 4).

## Open questions restated as decisions

Recommended answers; the operator confirms each in the table at the end.

1. **Immich set matching.** Accept DB-first/files-second with zero interruption
   and rely on the integrity jobs for orphans. Choose maintenance mode (minutes,
   Immich only, overnight) only if a restore test shows unreconcilable orphans.
   `design.md` cites an upstream `#backup-ordering` anchor that no longer exists;
   verify the current upstream guidance before deciding.
2. **SABnzbd in-flight queue.** Accept loss. Arr re-adds interrupted downloads;
   protecting `incomplete/` would pull bulk media into the application class.
3. **Unpinned Arr/SAB versions.** Record the resolved version from
   `/api/v*/system/status` inside each recovery point now; move to pinned tags
   when the aspects are next revised. Both satisfy the "matching version"
   requirement; recording is the smaller change.
4. **Argo pause during exports.** No pause. Hook writes are idempotent; add a
   released Argo pause only if task 2.4 demonstrates a torn export.
5. **Monitoring history.** Treat Prometheus, Alertmanager and Loki as
   disposable. Enabling `--web.enable-admin-api` for TSDB snapshots is a change
   the operator must want for its own sake.
6. **Whole-`/persist` snapshot as transfer source.** Not needed for the
   recommended policy. If wanted, it requires moving the fixture `/persist` onto
   the fixture ZFS pool first so it can be proven; that is a test change.
7. **SABnzbd backup folder.** Yes, pin it to a `/config` subpath in the
   init-container ini writer so the export lands inside retained state.
8. **Admin credentials for Immich and Jellyfin APIs.** Declare them as runtime
   Secrets through the existing agenix flow before task 2.4; do not reuse the
   Seerr login credential or generate identities at capture time.

## Operator decision table

Fill in one row per class (add rows per application where the class default
does not fit). Leave a cell blank rather than guessing; a blank blocks
scheduling, which is the intended effect.

| Data class | RPO | Cadence | Retention | Destination | Pause limit | Owner decision (date, accept/override, note) |
| --- | --- | --- | --- | --- | --- | --- |
| Application state | | | | | | |
| Irreplaceable photos (Immich library + dump) | | | | | | |
| Bulk media | | | | | | |
| Disposable | | | | | | |
| Decisions 1-8 | | | | | | |

## Prerequisites that need separate authorization

- An off-host (and for photos off-site) destination, its capacity, credentials
  and its own encryption; none exists today.
- Production inspection to size `rpool` free space (about 26.5 GiB at the last
  read-only inventory) before any export lands on it; exports are same-host
  intermediates, not backups.
- Measured pause, export duration and restore results from task 2.4 in the
  disposable environment before the first production schedule.
- The runtime Secrets from decision 8, and the retained-storage
  [reattachment metadata](../../modules/den/aspects/kubernetes/services/retained-storage.md)
  for ordinary Helm releases, which restore depends on but which is not a data
  backup.
