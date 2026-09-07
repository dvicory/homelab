## Context

See [proposal.md](proposal.md) for scope and [the compute-recovery delta](specs/compute-recovery/spec.md) for proposed guarantees.

The operator approved implementation after review: an unprivileged Incus system container, K3s/Flannel, Nix-delivered resources, retained application data, and operator-private Jellyfin access. The accepted isolation decision is recorded in [ADR-0001](../../../docs/architecture/decisions/0001-unprivileged-application-compute.md). Subsequent discussion approved workload-level storage failure handling, host bind mounts, and explicit application-update recovery. **No deployment is authorized.** Approval is not evidence that the implementation exists or runs.

### Evidence and skepticism

- `modules/den/hosts/hvn-hyp1/default.nix` includes Incus, encrypted ZFS persistence, mergerfs, and existing gocryptfs media mounts. It still includes the legacy Hermes nspawn integration; leave it alone.
- `modules/den/aspects/virtualization/incus.nix` currently configures the daemon/UI, API port, and persistence, not a compute project or guest.
- `modules/den/aspects/disk/zfs/pool.nix` declares encrypted `rpool` datasets including `/persist`. This is desired configuration, not proof of current mounted storage, encryption state, capacity, or redundancy. No new physical storage layout is needed for this slice.
- Local evaluation of the unchanged lockfile resolves Incus **7.4.0** and K3s **1.35.8+k3s1**. Pinned nixpkgs already supplies NixOS LXC images, K3s image import, and generated manifest delivery. Reuse these before introducing a platform generator.
- `initial-k8s` is predominantly architecture/inventory/collector work, not a deployable Kubernetes slice. It contains unrelated branch changes and dated facts. Do not transplant its nspawn, disk migration, Argo, identity, or public-edge assumptions.
- Revision `mpkkqksmmwrl` contains a standalone `compute-1` container, private Incus network/profile, and bootstrap/identity scripts. Useful ideas: independent guest configuration, outer user-namespace settings, and an identity volume outside the root. Defects to avoid: accepting an existing instance after checking only its type; treating failed queries as absence; verifying the uploaded public key rather than deriving it from the installed private key; and lifecycle operations without serialization. Its shown tests are configuration assertions, not proof of nested K3s or recovery.
- Sini's Kubernetes configuration has multiple controllers, separate containerd configuration, BGP, and site-specific network/firewall assumptions. It is a reference, not a starting bundle. In particular, do not copy broad trusted interfaces, disabled firewall rules, or bootstrap scripts that skip reconciliation merely because an installation already exists.

## Goals / Non-Goals

**Goals:** one complete service lifecycle; bounded host changes; independent guest deployment; no identity in reusable artifacts; deterministic storage access after guest deletion; and a recovery test that detects real loss of application state.

**Non-goals:** the proposal's exclusions apply. This is neither a host-loss recovery design nor a universal guest orchestrator. Do not add a new fleet schema, controller, or generic dependency engine solely for one container.

## Decisions

Use native NixOS, Incus, and Kubernetes facilities first; established upstream tools next; custom code only for a demonstrated remaining gap. Keep commands inspectable and avoid a new controller, persistent orchestration database, or broad configuration schema.

### 1. Keep the runtime envelope host-owned and the guest independently managed

Use a Den `compute-1` host entity with normal fleet access resolution and a separate guest aspect. Keep placement, bridge address, resource envelope, storage source, and identity references in the declaring host's metadata/settings; reusable behavior lives in aspects. Reuse existing persistence and secret request collection.

Build the guest image from its own NixOS output. Do not make every physical-host evaluation build the guest image, and do not require a repository checkout on `hvn-hyp1`. The macOS command selects a pinned source revision, builds or obtains the Linux outputs through an available builder, copies closures to the target, and invokes the installed lifecycle tool. Building Linux outputs may require a Linux builder; no remote build or activation is implied by this proposal.

Routine guest updates use its own NixOS closure and existing deploy-rs conventions through the physical host as a pinned SSH jump host, with explicit SSH jump configuration and separate trust files for both hops. Host deployment changes the envelope; guest deployment changes the guest generation. Guest updates participate in the same host-side lifecycle lock as replacement and identity staging. Keep Jellyfin's image independently pinned; any update that changes it follows the application-upgrade procedure below.

**Alternative:** embed the complete guest lifecycle into every host switch. Rejected because unrelated host changes should not replace an application domain or force a guest image build.

### 2. Use a narrow unprivileged container envelope

Declare `security.privileged=false`, an isolated UID/GID range, a private managed NIC, explicit memory/CPU/process limits, and only the required storage devices. Keep the Incus socket and host-global writable `/sys`, `/proc`, and device trees out of the guest. Do not disable AppArmor confinement wholesale.

Reserve an explicit host subordinate-ID range for this guest in Nix. The exact base is an entity value and must be checked for collisions before first provisioning. Guest UID/GID 751 reuses the existing Jellyfin identity from `deterministic-uids.nix`; host ownership is the declared translation of that identity, not a second manually chosen service UID. Fixed mapping avoids making persisted ownership depend on whichever automatic range Incus allocates after deletion. Verify expanded runtime settings and actual maps; profile inheritance alone is not proof.

Allow nesting. Start with no BPF delegation or broad mount interception. Any narrow syscall mediation required for OCI unpacking must be named, justified, and tested against the pinned stack; inability to run without additional authority is a decision gate, not permission to enable a privileged fallback.

**Alternative:** automatic isolated ID allocation plus idmapped mounts everywhere. Rejected for the first slice because the existing media view layers mergerfs over gocryptfs, and idmapped-mount compatibility must not be assumed. The fixed-map model works without shifting the media tree.

### 3. Use K3s defaults where they fit the user namespace

Use single-server K3s with SQLite, CoreDNS, Flannel, and kube-proxy. Disable Traefik, ServiceLB, and dynamic local-path provisioning: this slice has one private access path and explicitly bound retained storage, not arbitrary PVC allocation. Keep the distribution's supported network-policy mechanism rather than adding a second CNI for this workload.

Run K3s as root **inside the outer unprivileged container**, not K3s's separate experimental `--rootless` launcher. Configure the pinned kubelet user-namespace feature gate, kube-proxy conntrack behavior, and containerd user-namespace restrictions using the current module/runtime schema. Set `extraKubeProxyConfig.clientConnection.kubeconfig` explicitly to `/var/lib/rancher/k3s/agent/kubeproxy.kubeconfig`: the module requires it when supplying custom proxy configuration. Validate generated containerd TOML against the pinned runtime rather than copying an obsolete plugin table.

Use containerd's native snapshotter initially to avoid making overlay-on-ZFS or FUSE device delegation another prerequisite. This trades disk consumption and image unpack speed for a smaller compatibility surface. Keep the workload/image count bounded and measure usage; switch to overlayfs only after proving it on the actual backing filesystem. It is not a fleet-wide snapshotter policy.

Kubernetes documents Flannel VXLAN as known to work in a node user namespace. Cilium's normal model needs BPF/kernel authority; Incus BPF tokens are a possible research path, not evidence that this Cilium/kernel/runtime combination works. Defer Cilium, Hubble, and Gateway API rather than declaring them impossible or silently expanding host authority.

**Alternatives:** RKE2 and a separate containerd service add deployment/runtime surface without improving the one-node recovery test. Embedded etcd snapshots preserve disposable cluster state rather than proving reconstruction. Both can be reconsidered for multi-node needs.

### 4. Deliver manifests and images through the Nix closure

Use `services.k3s.manifests` with Nix-generated resources and `services.k3s.images` for the pinned K3s airgap image archive plus a digest- and hash-pinned Jellyfin image. The guest should not require a working in-cluster registry, Git server, secret operator, Helm repository, or GitOps controller to recover. Artifact acquisition still depends on declared Nix/source/image origins or retained build outputs; reproducibility is not a promise those upstreams will exist forever.

Declare a namespace, static retained PVs with node affinity, explicitly bound PVCs, one Jellyfin Deployment with `Recreate` strategy, probes, bounded requests/limits, and a private service. Choose the Kubernetes volume type that supports the verified attachment and propagation behavior; do not assume local PVs and hostPath volumes have interchangeable propagation semantics. Specify non-root UID/GID 751, drop capabilities, disable privilege escalation, and disable unnecessary service-account token mounting. Limit security exceptions to those required by the selected image and verify actual startup.

Use a read-only media mount, persistent `/config`, and disposable bounded cache/transcode storage. Do not preserve Kubernetes-generated PV directory names as an accidental recovery interface. Set retained volumes' reclaim policy to `Retain`, give them stable local paths and node affinity, and bind each claim explicitly to its declared volume. Storage lifecycle stays outside Kubernetes.

Keep stable manifest filenames. The pinned K3s AddOn controller prunes objects omitted from an updated, still-existing manifest; deleting the whole manifest file is the separate case that leaves resources behind. Keep retained storage and its namespace separate from disposable workload resources. Retire disposable objects through their existing manifest, verify removal, and only then retire an empty manifest file. Do not add a custom inventory or pruning controller, and do not introduce another owner for the same objects. Prove a removed disposable object disappears while an unrelated object and retained data remain.

**Alternative:** Nixidy/Argo plus secret and gateway operators. Rejected for this one workload because they introduce additional state and bootstrap ordering before a rebuild has been demonstrated. Adopt a controller when multiple application release lifecycles justify it.

### 5. Keep durable state independent of root and cluster state

| State | Proposed location/attachment | Recovery treatment |
|---|---|---|
| Guest root, K3s SQLite, CNI state, container runtime cache | Incus instance root | Delete and reconstruct; no external K3s-state bind |
| Guest SSH private identity | Existing agenix/rekey flow; staged outside the guest root | Recover from encrypted source and authorized host/operator identity |
| Jellyfin configuration, users, database, plugins, playback state | Host-owned directory under persistent encrypted storage; bind at `/srv/jellyfin/config` | Retain as one consistent application-state unit |
| Media payload | Explicit host source, initially the existing `/mnt/storage/media` view | Read-only outer bind at `/srv/media`; not moved or reformatted |
| Transcodes/cache | Bounded disposable workload storage | Regenerate |
| Kubernetes resources | Nix-generated manifests | Reapply into a fresh cluster |
| Initial admin/library setup | Jellyfin application administration through private access | Performed once; captured in retained `/config`, never repeated during guest rebuild |

Place new application and identity directories outside Incus instance-root storage, declared through `den.quirks.persist`/the existing collector. The instance's Incus pool may use the existing encrypted persistent host storage; do not change pool drivers or initialize physical disks as part of this change. Preflight must verify actual source mounts and encryption before treating them as protected durable storage. Capacity is a deployment gate; directory storage does not magically enforce filesystem quotas.

For configuration storage, create only the new empty application directory with its translated owner; never recursively chown existing data to repair a mapping mistake. For media, use an unshifted read-only bind and verify that the translated workload identity can traverse and read the intended source. If permissions are inadequate, stop for an explicit narrow read-access change; never map host root or make the media tree world-writable. Do not assume ACL support through gocryptfs or idmapped mounts through mergerfs.

Separate node-essential storage from application-only storage. Incus may start the node independently of media availability; do not make required media devices or a host-wide mount-readiness unit gate all of Kubernetes. Only loss of the node's own root/runtime storage belongs at that boundary.

For application storage, first prove native host bind exports and one-way mount propagation through Incus and the chosen Kubernetes volume type. Use stable export parents so an absent application mount need not prevent guest boot; an unmounted leaf must deny workload access, not resemble an empty library. Validate the intended filesystem and required media branches, not merely directory existence. Gate application startup on that validation, and prove source loss fails access without exposing a substitute directory. Prove reattachment reaches a new or recovered pod without restarting the node. A readiness probe alone does not stop background application work; an init container alone does not handle runtime loss; a liveness restart alone does not validate the replacement source. Do not claim those mechanisms individually satisfy the contract.

Keep Jellyfin's media attachment read-only. Host bind mounts also support writable application state and future selected media writers; virtiofs is a VM transport, not needed for this system container. A future writable attachment requires explicit per-workload filesystem permissions and mount access, not a blanket grant to current readers. Do not add future workloads or pre-grant their write access now.

**Alternative:** retain all `/var/lib/rancher/k3s` or rely on dynamically provisioned PVC paths. Rejected because this would conceal cluster-state dependencies and weaken the destruction test.

### 6. Bootstrap private identity without a guest decryption dependency

Add the guest's encrypted SSH host key and public key through the existing agenix/rekey workflow when secret creation is authorized. The physical host declares the matching secret request and stages a root-protected copy with the guest's translated root ownership, using an atomic write into a host-owned directory outside the rootfs. Bind only the needed identity files read-only into the guest; do not mount all host secrets or place plaintext keys in Incus configuration.

Derive the public key from the staged private key and compare it with the declared guest public key before starting SSH. Missing or mismatched identity is a hard stop; SSH must not silently generate a replacement. Keep host `known_hosts` separate from guest `known_hosts`, with strict verification on both hops. The bootstrap path remains available through host SSH and Incus even while guest SSH is down.

No cluster secret operator or long-lived cluster join credential is needed for this single-node workload. K3s's regenerated CA, tokens, and kubeconfig are disposable; operators refresh cluster access through the authenticated guest/host management path. Jellyfin passwords and setup state live in retained application data and do not become Nix literals.

### 7. Expose only an operator-private service first

Use an Incus-managed NAT bridge; do not bridge the physical uplink or change the LAN router. Reuse the experimental `10.210.0.0/24` only as a proposed address allocation, subject to local configuration and later target route-collision checks. Keep the host's current management network unchanged.

Expose Jellyfin through a fixed service NodePort on the guest, reachable via a local-only SSH tunnel through the authorized physical-host access path. Bind the local tunnel to `127.0.0.1`; add no public port, setup wizard, DNS change, Incus proxy listener, or LAN-wide service. NodePort and a NAT bridge do not themselves enforce private access.

Enforce the declared guest boundary for service and management ports, covering routed LAN/WAN/tailnet traffic and same-bridge guests. Use pinned Incus NIC-level ACL support where applicable and complementary NixOS firewall rules; network-level bridge ACLs or host FORWARD rules alone are not interchangeable with NIC-level enforcement. Verify actual paths, including NAT, with allowed and denied clients.

Retain NixOS firewalling and restrict Kubernetes management listeners deliberately without binding every component to loopback and breaking legitimate node/pod traffic. Add no broad trusted interface. Household access and shared TLS/routing remain a later explicit exposure decision.

### 8. Own a small, explicit lifecycle rather than a controller

Use thin operations over existing CLIs for inspection, image import, instance creation, and explicit replacement. Do not build a controller or a separate plan/state database. One host-side lock covers operations that can race on the instance or retained application state, including normal guest updates and identity staging.

NixOS is the sole owner of projects, networks, profiles, and pools through `virtualisation.incus.preseed`, supplied by Den aspect settings as Nix attrsets. Preseed overwrites supported existing resources: inspect for conflicts before its first activation, not afterward inside a helper. Instance operations verify this envelope; they do not reconcile it a second time.

Safe create/reconcile:

1. Validate node-essential mounts, available capacity, ID range, network allocation, identity, and artifact availability. Report application-storage availability separately without stopping the node or unrelated workloads.
2. Verify the NixOS-owned project/network/profile/pool configuration. Refuse incompatible drift; do not rewrite these resources.
3. Obtain/import the exact image by content identity. Distinguish a structured not-found response from an unavailable daemon or unauthorized request.
4. For an existing instance, inspect expanded configuration and devices. Refuse dangerous drift and preserve its root. Do not regard 'type=container' as conformance.
5. For an absent instance, create it stopped with the declared storage interfaces, verify identity and node-essential prerequisites, then start it. Application storage gates its consumers, not node startup.
6. Use bounded checks for management access, Kubernetes readiness, application storage, and Jellyfin readiness. Report the failing layer; a healthy node with blocked application storage is not a fully usable service.

Separate three operations:

- **Same-version guest replacement:** stage the selected image and validate retained inputs before deletion; require a target-specific acknowledgment; stop Jellyfin cleanly and then the guest; delete only the instance/root; reconstruct Kubernetes and reattach retained data. Preserve application software identity. A safety copy may be taken for the destructive drill, but replacement is not implicitly an application upgrade.
- **OS/Kubernetes update:** deploy the guest generation under the lifecycle lock while keeping the independently pinned Jellyfin image unchanged. Verify workload access afterward; Nix generation rollback is not a claim of database rollback.
- **Jellyfin upgrade:** obtain the new image and retain the old one before interrupting service; prevent reconciliation from restarting Jellyfin during maintenance; stop the workload and confirm no writer remains; preserve a consistent copy of the complete configuration directory, with its owner/modes and matching application image, guest generation, and repository revision; then deploy the new image and verify login, library access, and playback.

Use an explicit operator-triggered maintenance procedure and standard copy/snapshot and Kubernetes operations, not an automatic rollback engine. Verify available space and successful copy completion before starting the new application. Keep the previous successful recovery point until a replacement recovery point is complete; an interrupted copy must not become the selected recovery point.

On failure, leave retained data recoverable and report the failing layer. Restoring the older application requires an explicit restore of its matching configuration copy and software unless database compatibility has been established. State that this discards application changes since the recovery point, not media files: Jellyfin cannot write the media library. Never delete the containing project, pool, or retained paths as part of guest replacement.

## Risks / Trade-offs

- **Unproven nesting:** local evaluation cannot exercise Incus, cgroup delegation, native snapshotting, kubelet, or netfilter on the physical host. → Supply local checks now; leave actual runtime gates open until deployment is authorized. If boundary expansion is required, stop.
- **Incomplete private-service networking:** Incus NAT and Kubernetes NodePort can bypass naive input-only firewall rules. → Check forwarding and actual source reachability, not only declared allowed ports.
- **Storage permissions and mount support:** existing mergerfs/gocryptfs access may not fit the translated UID. → Fail closed; inspect after authorization; do not repair by recursive ownership changes or broad privileges.
- **Capacity:** a directory-backed root and native snapshotter have higher disk usage and no inherent per-instance quota. → Preflight free space, bound pod scratch/ephemeral storage, observe actual consumption, and do not advertise hard host disk isolation.
- **Manifest ownership:** deleting a manifest file leaves resources behind. → Use native pruning within stable manifests, separate retained storage/namespace, and verify retirement before removing an empty file; no second pruning mechanism.
- **Database migration:** retaining data alone does not make binary downgrades safe. → Preserve a quiesced matching pre-upgrade state copy and document restore pairing.
- **Single failure domain:** host storage loss removes both live state and local copies. → State this limitation; independent backup/restore is the next major capability, not an implied result of guest recreation.
- **Upstream availability:** pins prevent silent version drift but do not preserve upstream artifacts. → Make artifact origins explicit, preload runtime images, and retain tested build outputs where operationally required.

## Migration Plan

### Current authorized work

Implementation was explicitly approved after proposal review and the subsequent storage/update discussion. Reconcile these artifacts first, then implement the host envelope, guest image, workload, and minimal lifecycle operations. No remote inspection, secret creation, host activation, or remote build on `hvn-hyp1` is authorized.

Verify exact option leaves, generated runtime configuration/manifests, image contents, and lifecycle failure behavior locally. Prove the native storage attachment/loss/return path in an isolated Linux runtime before treating workload gating as implemented. Keep one meaningful integration scenario for unprivileged Incus → K3s → Jellyfin recovery; macOS-only evaluation is not a substitute. Keep target-runtime tasks unchecked until exercised.

### Later deployment gate

After explicit authorization, inspect `hvn-hyp1` read-only first: actual mounts/encryption, free space, kernel/cgroup support, ID mappings, network collisions, current Incus resources, media read permissions, and independent management access. Provision only new slice-owned directories and identity after reviewing the plan; never run disko or change existing media encryption. Deploy the envelope and guest, perform initial Jellyfin setup privately, and prove playback before asking for destructive replacement.

### Destruction acceptance

1. Record the repository revision, image identity, declared retained inputs, effective unprivileged settings, and representative media identity without exposing credentials or private filenames in public logs.
2. Create a real Jellyfin user, configure a library, play an item, and record a changed playback position/favorite or watched state. Verify media writes are denied.
3. Capture a consistent application-state recovery copy. Obtain explicit approval to delete the named guest.
4. Delete the guest root and its Kubernetes database. Do not attach an old cluster-state volume or restore a Kubernetes backup.
5. Recreate solely through repository-owned tooling and retained inputs. Assert a fresh Kubernetes instance while the same application user, library, and recorded state remain.
6. Authenticate and play the representative item again without running Jellyfin setup. Repeat replacement once to expose one-time bootstrap dependencies.
7. Exercise node boot without application media, media loss while Jellyfin is running, and restoration without a node restart. Verify the application never substitutes an underlying directory and unrelated workloads and management remain available. Also exercise mismatched identity, repeated provisioning, and undeclared network paths.

The first proof is guest replacement on a surviving host, not a promise of production readiness beyond the tested failure model.

## References

- [Kubernetes node components in user namespaces](https://kubernetes.io/docs/tasks/administer-cluster/kubelet-in-userns/): cgroup v2, runtime restrictions, kubelet gate, and Flannel guidance. Current website examples must be checked against the pinned version.
- [Incus ID mappings](https://linuxcontainers.org/incus/docs/main/userns-idmap/): isolated ranges and explicit mapping base.
- [Incus instance options](https://linuxcontainers.org/incus/docs/main/reference/instance_options/): nesting, confinement, resource, and syscall controls.
- [Incus BPF tokens](https://linuxcontainers.org/incus/docs/main/explanation/bpf-tokens/): delegation exists; compatibility with this Cilium deployment is not established.
- [Cilium system requirements](https://docs.cilium.io/en/stable/operations/system_requirements/): BPF/kernel privileges and network-namespace access.
- Pinned nixpkgs `nixos/modules/services/cluster/rancher/default.nix` and `k3s.nix`: manifest/image integration, SQLite default, and explicit kube-proxy kubeconfig requirement.
- [Pinned K3s AddOn controller](https://github.com/k3s-io/k3s/blob/v1.35.8%2Bk3s1/pkg/deploy/controller.go): native object pruning within an existing manifest; whole-file deletion is separate.
- [Incus disk devices](https://linuxcontainers.org/incus/docs/main/reference/devices_disk/), [Kubernetes volumes](https://kubernetes.io/docs/concepts/storage/volumes/), and [container probes](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#container-probes): attachment, propagation, and probe boundaries require integration verification.
