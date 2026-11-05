# Portable retained-storage experiments

These experiments ask whether application data can stay on the host while the Kubernetes node changes from an unprivileged Incus container to an Incus VM. They do not migrate production storage, activate production NixOS configuration, or replace PR #83.

## Decision after virtiofs qualification

**A newer stock guest kernel clears the demonstrated blocker for `cache=always`; both `--allow-mmap` alternatives still fail one filesystem case.** Keep the host-owned filesystem/local-path architecture. The bounded database and recovery results support continuing with virtiofs, not a claim that every database/application failure or physical device fault has been qualified.

The operator has reserved the cache choice. No configuration has been selected or deployed. The earlier preference for never-plus-mmap is superseded by the corrected-guest comparison below; its passing ordinary database tests do not erase the remaining filesystem failure.

Stock upstream Linux 7.3.1 contains the identified FUSE fix and was actually booted without changing the host or application userspace. No local kernel fork, application-image update, journal fallback or environment-variable workaround was needed for that qualification. The exact 6.18.49 backport's source build passed, but its interrupted kernel build is not a same-version runtime result.

PR #95 remains research evidence and reproducible workloads, not a deployment PR. PR #83 stays open and unchanged. The replacement architecture still needs its retained-allocation/adoption policy, ordinary startup checks, persistent compute/Kubernetes-state placement and independently qualified mapped-ACL Incus integration; passing the transport checks does not implement those protections.

## Corrected-guest comparison — 2026-11-06

The native NixOS guest ran first with Linux 6.18.49, then with stock Linux 7.3.1 from [Nixpkgs 1d060086](https://github.com/NixOS/nixpkgs/tree/1d060086d60cb76a40cf37109f979d88a5bd6396). The guest retained the same Python 3.14.7, SQLite 3.53.3, PostgreSQL 18.6 and workload bytes. Host Linux 6.18.49, Incus 7.4, virtiofsd 1.14 and QEMU 11.1 were not upgraded. Data used a real quota-bounded ZFS filesystem with `sync=standard`, not tmpfs.

| Data-export configuration | Linux 6.18.49 EOF cases | Linux 7.3.1 EOF cases | Ordinary filesystem / SQLite / PostgreSQL |
|---|---|---|---|
| always (`io.cache=unsafe`) | All four failed | All four passed | Passed |
| never + allow-mmap | Three failed; same-page write passed | Later-page pwrite failed; other three passed | Passed |
| metadata + allow-mmap | Three failed; same-page write passed | Later-page pwrite failed; other three passed | Passed |

Each corrected-kernel configuration had three fresh-epoch EOF repeats. The direct modes consistently exposed byte `0xee` at offset 9,216 where zeros were required. Ext4 controls passed. The actual result matches the upstream change's scope: buffered extending writes, truncate and fallocate are changed; the direct-write iterator is not. The [upstream ancestry comparison](https://api.github.com/repos/gregkh/linux/compare/34b5c4a6e4fb9dbb3f9d87f3b0fb0372105c8302...v7.3.1?per_page=1) places the exact fix in 7.3.1. This broader version comparison does not isolate that commit from every other kernel change.

### What “file-extension failure” means

This is **not ordinary appending to a file**. The reproducer maps a file whose end falls partway through a page, deliberately dirties bytes beyond its logical end, then extends the file. Newly exposed bytes should be zero. The remaining direct-mode case exposes the old dirt instead.

No ordinary SQLite/PostgreSQL corruption was observed. Inspected stock SQLite allocates WAL shared memory before mapping and normally maps database content read-only; inspected PostgreSQL relation/WAL growth does not supply the preceding dirty-tail mapping. Custom VFSs, extensions and other writable-mapped formats remain outside that source analysis. A general-filesystem counterexample still matters even when the two tested databases do not reach it.

### Corrected-kernel database and failure evidence

All three configurations passed real mapped/buffered visibility, guest-local POSIX/flock exclusion/release, file/directory fsync and atomic replacement. Each ordinary SQLite run finished with 4,000 exact rows, two writers, three readers, real pinned/checkpoint transitions and integrity `ok`. Each PostgreSQL run finished with 480 exact rows, concurrent writer/reader/checkpoint progress and zero bad offline checksums. These are bounded runs, not a soak test.

Only the viable always configuration proceeded through the corrected-kernel fault lane:

- SQLite recovered exactly 24 externally recorded, fsynced ACKs after process kill, forced VM stop and exact data-daemon death; the pending transaction stayed absent.
- PostgreSQL VM and isolated daemon cases recovered their independently specified 480-row baselines plus 24 acknowledged pairs: 528 rows, exact payloads, no sentinel and zero bad checksums.
- A host ZFS snapshot captured the active SQLite DB/WAL recovery set. After fencing the original owner, an exclusive clone in a fresh mount/backend epoch recovered all 24 ACKs. This is not PostgreSQL backup qualification.
- Owned readonly/quota faults returned EROFS/EDQUOT. Fresh SQLite opens failed with **SQLITE_CANTOPEN**, not IOERR_WRITE; cold recovery retained exactly the previous acknowledged rows and no failed-run rows.
- After daemon death, a fresh write+fsync stalled at least eight seconds. Neither prompt EIO nor hot reconnection was established. Recovery used a fenced fresh guest/backend epoch, not an assumed Pod-restart repair.

The host controller fsynced each external ACK before releasing the guest handshake. Its exact submitted source and substitutions, ledgers and raw failure streams are retained privately. Initial fixture errors are preserved: a daemon parent/child pair invalidated a single-PID selector before signaling; reusing PostgreSQL data across two faults exceeded the original one-crash verifier's baseline model. An independent expected-row union verified all 576 rows before a fresh isolated daemon case passed the unchanged verifier. Neither fixture error is evidence of database corruption.

### Narrow equal-resource measurement

Three interleaved repeats per configuration used Linux 7.3.1, one GiB RAM, two CPUs and 1,000 FULL-sync WAL commits. Throughput includes BEGIN/INSERT/COMMIT; latency brackets COMMIT alone. Automatic checkpoints remained enabled at 1,000; exact verification and explicit TRUNCATE happened afterward.

| Configuration | Median commits/second | Median p95 COMMIT |
|---|---:|---:|
| always | 891.1 | 1.690 ms |
| never + allow-mmap | 1,021.3 | 1.355 ms |
| metadata + allow-mmap | 949.6 | 1.472 ms |

These roughly one-second loops are not a production ranking and must not be compared with the earlier Alpine benchmark's different setup. The direct modes remain semantically blocked despite their measured speed.

### Configuration and recovery tradeoffs

Always retains ordinary guest file-data cache, which can avoid repeated transport reads but duplicates host/application caches and can hide transport loss behind cached reads. Never/metadata skip that ordinary data cache, but mapped pages still exist and mixed direct/mapped I/O needs correct invalidation. Metadata also retains directory/attribute caching. None makes an independent host or second-guest writer coherent with the owning guest's locks.

All modes require exclusive ownership, fencing before migration/restore and a complete recovery set. Snapshot reads should use an immutable snapshot, not separately copied changing DB/WAL files. A stopped guest and retired connection establish a new cache epoch; reopen, Pod restart or guest pause alone do not. No physical host power-cut, real device-failure, long-soak, warm-cache resource or multi-writer guarantee is claimed.

Always already has an Incus device setting; it does not need an allow-mmap option. The alternatives would need supported Incus option management **and** correction of the remaining direct-I/O failure. No additional kernel patch, raw-argument escape hatch, CSI control plane or runtime hook was built to conceal that result. UID/GID/named-ACL manager qualification is a separate prerequisite, not an allow-mmap switch.

### Reproduction and provenance

`guest-kernel.nix` reuses the native NixOS Incus VM image/agent module. Its default pair targets the original 6.18.49 package; `fixedKernel` accepts an existing upstream package to keep guest userspace unchanged. The 7.3.1 qualification used the package from the exact Nixpkgs revision above. The vendored `fuse-partial-eof-6.18.49.patch` is a real stable-tree diff of the exact upstream twelve-line change; real `applyPatches` completed without offsets/fuzz. No backport-only kernel runtime pass is claimed.

The coherent `/etc/vfq` script directory needs no PYTHONPATH. Create-only tmpfiles mode/owner/group preserve an already mounted payload while leaving the missing-mount underlay root-owned mode 0700. PostgreSQL tools must use their real package `bin` directory, resolved from `initdb`, rather than `/run/current-system/sw/bin`, because initdb derives its shared-data path from its executable location.

The published Python workers and guest recipe do **not** include the private host-side fault driver. The externally acknowledged process/VM/daemon-death, readonly/quota-fault and fenced ZFS snapshot/clone lanes are therefore **not publicly reproducible end to end** from this repository alone. Host-side orchestration recorded and fsynced ACKs, stopped the exact daemon or VM, and changed only the owned dataset's fault settings. It captured the active disposable dataset's snapshot, then fenced the old writer before restoring the clone. The workers consume handshakes and verify recovery; they do not perform those host steps. Submitted controller source, commands and raw receipts remain in the private evidence workspace.

`python3 -B test_policy.py` runs the small helper-log attribution, lease-revision and literal SQLite-path regressions without a Kubernetes cluster. Lifecycle leases require a full lowercase Git commit SHA, not a branch, tag, `HEAD` or abbreviation, because Argo's completed operation records the resolved SHA.

All new disposable instances, project/pool/image references, dataset, snapshot and restore clone were retired after evidence capture. The host and production guests were not activated, rebooted or migrated. No cache selection, upstream submission or full PR #83 replacement implementation occurred.


## Previous virtiofs/database qualification — 2026-11-05

### Actual stack and comparison

Incus 7.4.0, virtiofsd 1.14.0, QEMU 11.1.0, host Linux 6.18.49, stock Alpine 3.23 VM Linux 6.18.60-0-virt, Python 3.14.7, SQLite 3.53.3 and guest PostgreSQL 18.6. One VM, one data-export connection, mapped UID/GID 1000, four GiB RAM/two CPUs, real host ZFS backing with `sync=standard`. Data was not on tmpfs; only disposable OS roots and external evidence used RAM.

| Data-export configuration | Incus-managed support tested | SQLite WAL/checkpoints and PostgreSQL | Partial-EOF zero-fill regression |
|---|---|---|---|
| `cache=always` | `io.cache=unsafe` | Passed | Failed all four cases |
| `cache=never --allow-mmap` | No existing device setting | Passed through standalone experimental attachment | Failed three cases; same-page write passed |
| `cache=metadata --allow-mmap` | No existing device setting | Passed through standalone experimental attachment | Failed three cases; same-page write passed |

The standalone alternatives used the **unmodified resident daemon**, default namespace sandbox/seccomp, real UID/GID translation, an owned socket and an additional virtiofs device through only the disposable VM's `raw.qemu`. They were manually mounted in that guest. No production daemon PATH, service, security policy or executable changed; the data source was never exported simultaneously by two daemons. This qualifies the stack experimentally, not Incus-managed lifecycle support for the option.

### What the bounded checks prove

- SQLite: two writer processes each committed 1,000 atomic row pairs while three reader processes checked pinned/refreshed snapshots, complete pairs, exact payloads and later writer progress. PASSIVE/FULL checkpoints encountered real pinned frames; releasing readers allowed complete PASSIVE/FULL/RESTART/TRUNCATE checkpoints and actual WAL truncation. Each configuration finished with exactly 4,000 rows and `integrity_check=ok`. These roughly ten-second runs, plus smaller first runs, are not a long-duration soak.
- PostgreSQL: two writer clients and an observing client used distinct server backends. Each configuration preserved 480 exact baseline rows, a checkpoint before both writers' later progress, and 270–283 reader observations over about 31–33 seconds. Offline `pg_checksums --check` reported zero bad checksums. Actual settings were `fsync=on`, `synchronous_commit=on`, `full_page_writes=on`, checksums on, `wal_sync_method=fdatasync`, `io_method=worker` and one-MiB WAL segments. These are statement-snapshot observations, not PostgreSQL repeatable-read tests.
- Filesystem: independent guest processes checked bidirectional shared-mmap and pwrite visibility, flush/fsync followed by fresh-process exact reads, POSIX byte-range/flock exclusion and release, and concurrent-reader observations across 32 fsynced replacements. Each reader acknowledged every complete known generation. This is bounded atomic-replacement evidence, not exhaustive syscall-interleaving proof.
- Faults: every configuration recovered 24 externally fsynced SQLite acknowledgments after a process kill and after a forced VM stop. Before each fault, committed frames remained uncheckpointed behind a pinned reader. Each also recovered its PostgreSQL baseline plus 24 acknowledged pairs after the **exact data daemon** was killed; the open uncommitted sentinel stayed absent and offline checksums passed.
- A final independent cold read verified **14,616 SQLite rows in 15 test databases**, exact payload bytes and integrity, including the snapshot recovery copies. External ACKs lived outside the tested filesystem and were fsynced before the writer could advance.

Fault injection occurred at recorded acknowledged/open-transaction boundaries, not arbitrary in-flight commit times. An unacknowledged in-flight commit can remain ambiguous; applications must not interpret a lost reply as proof of rollback. No physical host power-cut, real device failure, concurrent external writer, ACL/xattr qualification or live VM migration is claimed. The correctness workloads do not establish a performance winner: cache avoidance can cost ordinary I/O, and these paced/full-verification runs are not comparable to the earlier serialized benchmark.

### Demonstrated blocker, not a cache-name objection

The [upstream FUSE partial-EOF defect and fix](https://github.com/torvalds/linux/commit/34b5c4a6e4fb9dbb3f9d87f3b0fb0372105c8302) concern mmap-dirtied bytes beyond a non-page-aligned EOF becoming visible after extension instead of zeros. The [upstream selftest ordering](https://lists.openwall.net/linux-kernel/2026/08/24/1443) was reproduced without flush/close/reopen before observation.

On `cache=always`, extending by later-page pwrite, ftruncate, fallocate and same-page pwrite all exposed stale `0xee` at offset 9,216. Never/metadata plus mmap failed the first three cases, not the same-page case. The identical reproducer passed all four on the existing guest OS filesystem in a private mount namespace, with actual ext4 provenance; **that was a control, not a proposed block-volume architecture**. The mount-report helper was corrected to match the path's actual device rather than a lower overmount.

Ordinary SQLite database/WAL and PostgreSQL relation files were not shown to meet the reproducer's partial-EOF mmap preconditions. These passing database runs did not erase the general-filesystem failure. At this earlier checkpoint no corrected guest kernel had been tested; the subsequent native NixOS comparison above supersedes that limitation without inventing a database-corruption incident.

### Coherence, locks and persistence

The [pinned daemon implementation](https://gitlab.com/virtio-fs/virtiofsd/-/blob/v1.14.0/src/passthrough/mod.rs) distinguishes file-cache policy, `--allow-mmap`, `--writeback` and host `O_DIRECT`. Always uses KEEP_CACHE; never/metadata use DIRECT_IO for regular files. `--allow-mmap` negotiates permission for shared mappings of those direct-I/O files. It does **not** remove mapped-page cache or external-writer incoherence. The [daemon documentation](https://gitlab.com/virtio-fs/virtiofsd/-/blob/v1.14.0/README.md) requires exclusive access, and [guest FUSE code](https://github.com/gregkh/linux/blob/v6.18.60/fs/fuse/file.c) coordinates mapped/cached and direct I/O inside that guest.

Incus's filesystem `unsafe` mapping requests `--cache=always`, **not** `--writeback`, QEMU block-disk unsafe caching or fsync suppression. Guest FUSE fsync waits relevant dirty pages/requests and reports errors; the daemon calls host fsync/fdatasync. Writable mmap can still create dirty pages even without negotiated FUSE writeback caching. SQLite's SHM WAL index is reconstructible coordination state, not the durable WAL itself; successful SHM mmap alone says nothing about transaction persistence. See [SQLite WAL](https://sqlite.org/wal.html) and [WAL-index semantics](https://sqlite.org/walformat.html).

The daemon does not forward these advisory locks to the host: missing POSIX/FLOCK capabilities make Linux use guest-local locks. One guest filesystem connection is therefore essential. Bind mounts and container namespaces within that guest share the domain; a host database process, second guest or independent connection is not coordinated by those locks.

Backend death did **not** produce a prompt error: fresh write+fsync probes stalled for at least eight seconds in every configuration. Whole-guest stop/start with a new daemon/mount epoch recovered the recorded data; automatic hot reconnect was not established. A Pod restart, pause/resume or daemon replacement alone is not a cache-epoch/fencing guarantee.

### Source failures, backup and recovery

Never-plus-mmap propagated an owned backing filesystem's readonly transition as `EROFS` without a write acknowledgment; original synced bytes survived fenced recovery. An owned ZFS quota produced `EDQUOT` and an already-open FULL-sync SQLite writer returned `SQLITE_IOERR_WRITE`, not an acknowledgment. After fencing, restoring only the test quota and removing the test filler, cold recovery preserved exactly the prior 24 commits and no failed transaction. A new connection also failed to open WAL while the quota was exhausted. These test error propagation, **not** physical EIO, controller flush honesty, power-loss protection or a permanent poison-state guarantee. Do not retry fsync until success and call potentially lost data repaired.

Both always and never-plus-mmap had a host ZFS snapshot taken while a writer held acknowledged uncheckpointed WAL and an uncommitted transaction. After writer fencing, DB+matching WAL were copied from the immutable snapshot, not the live files; SHM was rebuilt in a fresh guest/backend epoch. All 24 acknowledged transactions recovered exactly in each case. This demonstrates a crash-consistent recovery set at that boundary, not capture of guest-unsynced changes or every application's backup requirements.

For operations: use an application-consistent backup inside the owner where needed, or an atomic dataset snapshot containing the complete recovery set. Read the immutable snapshot, not a changing live database from the host. Never copy live DB/WAL independently or restore under active old mappings. Stop/fence the owner, restore the intended complete state and establish a fresh mount/cache epoch; later acknowledged data beyond a selected historical backup is intentionally lost. [SQLite's corruption guidance](https://sqlite.org/howtocorrupt.html) explains the live-copy hazard; [PostgreSQL reliability](https://www.postgresql.org/docs/18/wal-reliability.html) explains its sync assumptions.

### Incus upstream assessment and stop boundary

[Incus 7.4's launcher](https://github.com/lxc/incus/blob/v7.4.0/internal/server/device/device_utils_disk.go#L323-L440) exposes no `--allow-mmap` setting; raw mount options do not reach it, and raw QEMU options do not alter its managed daemon. A supported never/metadata-plus-mmap deployment needs an Incus change. **[INFERENCE]** A small per-filesystem-disk opt-in, independent of cache policy, is worth proposing upstream: validate explicit virtiofs use, preserve defaults, append the flag, expose an API extension, document exclusive ownership and test actual WAL/invalid combinations. Unsupported daemon behavior must fail clearly; 1.14 does not advertise an allow-mmap capability token.

This is a bounded upstreamable option assessment, not a patch, accepted proposal or proof that Incus enforces exclusive ownership. `cache=always` itself would not need that option if a corrected guest stack were qualified. Maintainer acceptance remains unknown; no upstream issue/PR or local fork was created.

**The earlier tested image remained a no-go for critical storage.** The later corrected-guest comparison above narrows that blocker to the direct-I/O alternatives. Neither result warrants a different storage control plane, experimental raw-QEMU deployment, runtime-wide process retirement or a new compatibility project.

All follow-up instances, image references, transient daemons, project, pool, bridge, both snapshots, dataset and RAM scratch were retired after evidence capture. Production compute remained running; Incus PID/activation and the existing strict SSH master were preserved. Private receipts include initial failures and their specific harness corrections; no generated bootstrap inventory, credentials or raw machine logs are published here.

## Initial portability and lifecycle evidence


All three bounded experiments completed, including actual container-to-VM replacement and a real cached same-Pod restart after payload-path withdrawal. These results qualify the observed mechanisms and limits—not a production migration.

### Bind and virtiofs transport

The same Python workload ran against one real, quota-bounded host ZFS filesystem. The container used a bind mount; the VM used actual Incus virtiofs. Both used guest UID/GID 1000, mapped to the same host owner, with mode `0700`; UID 1001 was denied access. Neither transport used tmpfs for the measured data.

Both passed:

- SQLite WAL with `synchronous=FULL`.
- File and directory `fsync`, rename with preserved contents, and two-process write-lock contention followed by successful lock reacquisition.
- Exact recovery after process SIGKILL in each guest and after a forced VM stop. A pinned reader established that acknowledged commits still depended on uncheckpointed WAL frames before each fault.
- Reverification of all earlier crash acknowledgments, through the faulted transport first. A final independent read verified all 900 committed rows across nine runs, including their exact payload bytes; pending rows were absent and SQLite integrity checks passed.

The external acknowledgment ledger survived guest faults outside the tested filesystem. This is not a host-power-loss test. Simultaneous host/guest or cross-guest writers are not supported by this experiment: only one guest owned the export at a time, and VM mounts/caches were recreated between phases.

#### A necessary Incus setting—not an application workaround

Stock Incus filesystem cache modes `none` and `metadata` failed SQLite WAL: shared `mmap` returned `ENODEV`, producing `SQLITE_IOERR_SHMMAP`. The actual virtiofsd arguments lacked `--allow-mmap`.

Explicit filesystem `io.cache=unsafe` worked. The [Incus v7.4 launcher](https://github.com/lxc/incus/blob/v7.4.0/internal/server/device/device_utils_disk.go#L385-L401) maps this to virtiofsd `--cache=always`; it does **not** select QEMU's unsafe block-disk cache mode. The name must not be hidden, and the result does not justify concurrent external writers. The actual FULL/fsync/crash results above apply only to the tested single-owner configuration. No SQLite journal-mode fallback, application change, host upgrade, or patch was used.

#### Measured cost

Three interleaved repeats per transport, 100 serialized 1-KiB transactions each. Boot, post-run verification and checkpointing were outside workload timing. Values below are medians of the three runs; they describe this host-backed filesystem and workload, not a general application performance guarantee.

| Transport | Commits/second | Median commit latency | 95th-percentile commit latency |
|---|---:|---:|---:|
| Unprivileged container / bind | 18.66 | 49.27 ms | 126.69 ms |
| Incus VM / virtiofs | 12.68 | 76.11 ms | 181.79 ms |

Both benchmark guests had 4 GiB RAM and two CPUs. Host/container kernel: 6.18.49; VM kernel: 6.18.60-0-virt; Incus 7.4.0; QEMU 11.1.0; virtiofsd 1.14.0; identical Python 3.14.7 / SQLite 3.53.3 workload. Guest images were stock Alpine 3.23. The VM image required Secure Boot disabled on that disposable VM only.

Permission qualification covers numeric ownership and mode bits, not existing ACL-dependent data, xattrs or generation-bearing filesystem handles. Existing production data was not changed to make the test pass.

### Publication lifetime: what mounts protect, and what they do not

Both transports passed the same native mount experiment. Distinctive original and replacement bytes made wrong-target writes observable; the host independently checked the exact resulting files.

| Operation | Observed result | Consequence |
|---|---|---|
| Rename the payload directory and create a replacement at its old path | Published bind and open file/directory descriptors still referred to the original | Path replacement does not redirect existing references |
| Start another process using that still-published bind | It wrote only to the original | A process restart alone does not imply a new storage attachment |
| Lazily unmount the published bind while retaining descriptors | Descriptor-based writes still reached the original | Immediate process termination is not required to prevent substitute writes in this case |
| Resolve the replacement path or create a fresh bind/remount | Writes reached the replacement | Native mounts alone do not authorize a fresh attachment |
| Write through the empty underlay exposed by unmount | The write succeeded outside retained storage | A bare writable pathname is not a fail-closed storage boundary |

The last two rows are deliberate counterexamples, not passing enforcement checks. This experiment added no guard or runtime hook. It supports keeping existing correct references alive while separately checking fresh publication.

The native-process experiment alone does not establish kubelet/containerd's cached same-Pod restart behavior; the Kubernetes case below exercises that separately. Physical backing-device failure was not injected: stopping a daemon or guest would not establish equivalent behavior, and faulting the shared host pool was outside authorization.

### Argo allocation and retained-claim lifecycle

These runs used real Argo reconciliation against a separate Git repository, stock K3s 1.35.8, Rancher local-path-provisioner 0.0.37 and Argo CD 3.5.2. Application and existing application-init processes actually ran as UID/GID 1000. A unique, application-written and fsynced initial-PVC-UID value distinguished preserved state from a silently fresh initialization; repeated generic `commit` lines would not have proved that.

| Case | Observed result | Mechanism |
|---|---|---|
| First application/PVC declared in Git | Argo allocated a local PV with stable logical-node affinity; no per-app host/Nix/Incus action | Stock Argo and local-path provisioning |
| Recreate a Pod using the same PVC UID | Exact initial application state survived | Native PV binding and retained payload |
| Remove a protected PVC from Git | `Prune=false` kept the original claim | Native Argo protection |
| Cascade-delete its Application | `Delete=false` kept the protected claim | Native Argo protection |
| Delete an unprotected Retain claim, then recreate its intent | Old data survived, but stock provisioning allocated a new UID/PV with fresh state | **Counterexample:** Retain alone does not prevent silent substitution |
| Delete a disposable claim | Its PV and payload were removed; retained data stayed intact | Separate native Delete policy and bounded teardown |
| Recreate an established claim with the prototype enabled | Helper refused the new UID; no fresh substitute directory appeared | Durable reservation/history in the stock setup extension |
| Approve adoption after excluding old writers | Registry authorization and native PV/PVC rebinding preserved the exact original application state | Explicit recovery operation, not automatic identity matching |
| Start with an absent established local path | Kubelet reported a causal mount failure; application writers never started | Native local PV path semantics |
| Start with a replacement directory at that path | Metadata inode mismatch stopped the injected check before application init; substitute stayed empty | Prototype startup check |
| Discard and reconstruct Kubernetes' database | New claim UIDs required explicit adoption; node UID changed but logical name/affinity and original data survived | Git reconstruction, external history and native binding |

The fresh VM had a new guest root and no K3s installation; the old container was stopped before it started. Argo reconstructed claims without copying the old Kubernetes database or replaying empty-root bootstrap. New claim UIDs remained blocked until explicit approval, then native rebinding preserved original local-PV paths, logical node affinity and exact initial application state through actual virtiofs.

### What the startup experiment proves

Native Kubernetes 1.35 beta MutatingAdmissionPolicy injected the same check before application init for Deployment, StatefulSet, Job, CronJob and bare-Pod consumers, including a Pod admitted before its PVC existed. No application Helm customization was used. On the restored VM, the actual payload path was then renamed and a writable replacement created. A cached application restart kept the same Pod UID and completed guard timestamp, read the original application marker and wrote to the held original; the substitute stayed empty. The guard did **not** rerun, and no Pod replacement or forced writer retirement was used to manufacture that result.

The checker mounts metadata separately and read-only, rather than placing markers in application directories. Admission rejected borrowing its reserved metadata/code/token volumes from application, other init and ephemeral containers. These narrow probes do not establish a complete hostile-administrator security boundary.

The prototype is deliberately not a production recommendation:

- Its binding and code/RBAC prerequisites enroll one namespace. Workload-kind coverage does not prove automatic enrollment of arbitrary new namespaces or every Kubernetes volume form.
- Generic ephemeral volumes are not checked. Pods with only those volumes do not receive the startup check; mixed Pods have only their direct PVC references checked.
- The trusted checker runs as UID 0 and uses hostPath for metadata. HostPath conflicts with **Baseline and Restricted** [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/); UID 0 adds a Restricted conflict. Production admission boundaries must not be weakened silently to accommodate it.
- Disposable consumers actually failed when PVC-API permission was removed or metadata became unavailable. Universal injection therefore adds a real availability dependency to workloads that do not need retained-state protection.

### Minimum history and its limits

The prototype records native PVC namespace/name, authorized UID, path, directory inode and allocation state. It adds no logical-ID annotation or second manually maintained application inventory. Stock flat local-path directory names let its existing helper mount/scripts do the work; no unsafe path/template flag or extra helper authority was needed.

An explicit empty-root bootstrap creates history once; its schema and ready-version row commit in one SQLite transaction. Allocation commits a pending reservation before exclusive directory creation, then records active state. Same-UID retries validate the existing allocation. Interruption after reservation can retry if no directory exists; interruption after directory creation leaves ambiguity and refuses automatic import. Directory creation and SQLite commit are not one transaction.

Actual interruption, collision, namespace separation, lost/corrupt history, stale approval and explicit SQLite-backup restoration cases passed. Missing history never became an automatically empty registry. A restored registry still requires quiesced callers and consistent payload recovery; this was not an off-host backup/restore or Preserve test.

**Directory identity is not application integrity or physical authentication.** Deleting an application file inside an unchanged directory still passed the check. Inode reuse was not observed in the earlier hvn-hyp1 run's 64 delete/recreate attempts, but the local Colima review run reused the inode on its first attempt and the prototype accepted the replacement. This is a demonstrated silent-substitution gap in the inode-only check, not a production-ready identity guarantee. Coherent rollback, copied history and stronger backing-filesystem identity remain outside this mechanism.

The review follow-up reran the policy and registry cases on disposable Kubernetes 1.35.8, Argo CD 3.5.2 and local-path-provisioner 0.0.37. It verified bootstrap Job completion before pruning, a real recreated PVC UID before pausing Argo, refusal of abruptly interrupted schema bootstrap, and causal provisioner-log evidence after the helper Pod disappeared. This qualifies the orchestration fixes, not another Incus/virtiofs transport or backup.

## Reproducible experimental source

- `sqlite_workload.py`: the unchanged consumer workload, contention and crash checks.
- `transport.py`: exclusive-owner comparator and external acknowledgment custody.
- `publication.py`: native bind/reference cases and explicit wrong-target counterexamples.
- `registry.py` and `lifecycle.py`: the minimal history/startup prototype and actual Argo lifecycle experiment, not a production integration.

These are bounded experimental programs, not a production storage service or a proposed permanent operator runbook. Their runtime leases name only disposable fixtures; they must not be pointed at production. Raw machine receipts remain in the operator's private experiment workspace rather than adding generated manifests, credentials, or bootstrap logs to the repository.

All owned test instances, image references, project, bridge, storage pool, data dataset and RAM scratch were retired after preserving evidence. Production `compute-1` remained running, the pre-existing GPU VM remained stopped, the Incus daemon identity stayed unchanged, and the existing SSH master was preserved. No production deployment, host upgrade or storage migration ran.
