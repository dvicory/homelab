# Portable retained-storage experiments

These experiments ask whether application data can stay on the host while the Kubernetes node changes from an unprivileged Incus container to an Incus VM. They do not migrate production storage, change NixOS configuration, or replace PR #83.

## Recommendation before any production change

Keep host-owned shared storage plus stock local-path as the direction. The experiments justify removing runtime-wide process retirement for still-correct original references; they do not justify dropping checks on genuinely fresh attachment or accepting recreated PVC UIDs automatically.

Do **not** ship the universal startup-check prototype as a complete replacement for PR #83. Its namespace enrollment, Pod Security and disposable-availability costs remain unresolved, and its identity guarantee is operational rather than physical or application-file integrity. The next design decision is the precise guarantee to accept—not another controller, anchor protocol, ZFS delegation or automatic migration.

Persistent Kubernetes/compute-state placement and fail-closed ordinary startup also remain infrastructure integration work; reconstructing application claims after database loss does not prove those deployment protections. PR #83 stays unchanged while this evidence is reviewed.

## Current evidence

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
- The trusted checker runs as UID 0 and uses hostPath for metadata. HostPath conflicts with **Baseline and Restricted** [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/); UID 0 adds a Restricted conflict. Production admission boundaries must not be weakened silently to accommodate it.
- Disposable consumers actually failed when PVC-API permission was removed or metadata became unavailable. Universal injection therefore adds a real availability dependency to workloads that do not need retained-state protection.

### Minimum history and its limits

The prototype records native PVC namespace/name, authorized UID, path, directory inode and allocation state. It adds no logical-ID annotation or second manually maintained application inventory. Stock flat local-path directory names let its existing helper mount/scripts do the work; no unsafe path/template flag or extra helper authority was needed.

An explicit empty-root bootstrap creates history once. Allocation commits a pending reservation before exclusive directory creation, then records active state. Same-UID retries validate the existing allocation. Interruption after reservation can retry if no directory exists; interruption after directory creation leaves ambiguity and refuses automatic import. SQLite transactions serialize metadata, but directory creation and SQLite commit are not one transaction.

Actual interruption, collision, namespace separation, lost/corrupt history, stale approval and explicit SQLite-backup restoration cases passed. Missing history never became an automatically empty registry. A restored registry still requires quiesced callers and consistent payload recovery; this was not an off-host backup/restore or Preserve test.

**Directory identity is not application integrity or physical authentication.** Deleting an application file inside an unchanged directory still passed the check: an observed counterexample, not a claimed protection. Inode reuse was not observed in 64 delete/recreate attempts, which does not establish that reuse is impossible. Coherent rollback, copied history and stronger backing-filesystem identity remain outside this directory-inode mechanism.

## Reproducible experimental source

- `sqlite_workload.py`: the unchanged consumer workload, contention and crash checks.
- `transport.py`: exclusive-owner comparator and external acknowledgment custody.
- `publication.py`: native bind/reference cases and explicit wrong-target counterexamples.
- `registry.py` and `lifecycle.py`: the minimal history/startup prototype and actual Argo lifecycle experiment, not a production integration.

These are bounded experimental programs, not a production storage service or a proposed permanent operator runbook. Their runtime leases name only disposable fixtures; they must not be pointed at production. Raw machine receipts remain in the operator's private experiment workspace rather than adding generated manifests, credentials, or bootstrap logs to the repository.

All owned test instances, image references, project, bridge, storage pool, data dataset and RAM scratch were retired after preserving evidence. Production `compute-1` remained running, the pre-existing GPU VM remained stopped, the Incus daemon identity stayed unchanged, and the existing SSH master was preserved. No production deployment, host upgrade or storage migration ran.
