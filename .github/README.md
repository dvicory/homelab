# homelab

## CI

`.github/workflows/ci.yml` runs for pushes to `main`, pull requests, and
manual dispatches from any ref. Pushes to other branches alone do not start
Nix CI.

`modules/flake/ci.nix` automatically projects packages, checks, development
shells, formatters, NixOS and Darwin systems, and Home Manager activation
packages for x86-64 Linux, ARM64 Linux, and ARM64 Darwin. Each runner evaluates
its own system's projection: nixidy chart evaluation can require native builds.
Every CI group is a directly buildable Nix derivation. `ciBundles.<system>`
builds the complete projection; neither target requires GitHub Actions.

`hostedCiPlan.<system>` supplies the standard group names, lazy check
inventory and native application descriptors. The workflow dispatches that
plan; it does not maintain a second list of output categories or branch on a
test/application name. Platform-specific Darwin bootstrap remains an executor
dependency, not a workload-selection rule. Complete fast-check aggregates are
listed first in the build matrix to request runners early; GitHub still controls
actual runner availability and start order.

`hostedCiArtifacts.<system>` supplies lazy `groups`, `checks`,
`nativeApplications` and `bootstrap` leaves, plus the local check `inventory`.
Complete fast-check executors evaluate their inventory and aggregate together,
then release the evaluator before building. A selected-check dispatch forces only
its artifact leaf and records its exact selected receipt, without evaluating or
uploading a complete platform inventory. Other executors also force only their
own artifact leaf. Each leaf declares exact derivation/output paths; native
leaves also declare the executable. Foreign and unsupported derivations stay
unforced.

On a builder for the selected system:

```sh
nix build .#ciBundles.aarch64-darwin
nix build .#ciJobs.x86_64-linux.nixosConfigurations
nix build .#checks.aarch64-linux.den-semantics
```

### Required evidence layers

`modules/flake/ci.nix` keeps the mandatory semantic/schema/policy,
Kubernetes application, host-recovery and native-application identities.
They are registration contracts, not execution groups. Missing checks,
non-derivation replacements, fast checks replaced by runtime tests, runtime
gates replaced by non-runtime checks, or required gates made unsupported on
their hosted platform fail evaluation. Native apps must have matching
executable packages and exactly one native descriptor; packaging is not
acceptance.

The generic fast projection is `hostedCiJobs.<system>.checks`. Every hosted
runtime check gets its own native runner according to its actual capabilities.
All standard `ciJobs` groups still come from Nix, including packages,
development outputs and system configurations. `ciBundles` includes every
registered check, including checks unsupported by hosted runners.

`All required CI` joins the successful plan, build matrix, native matrix,
Darwin configuration and Darwin Linux-builder bootstrap. It requires all
three planned and evaluated platform inventories, every standard output
group, every hosted runtime registration, every native execution, and the
bootstrap receipt. Every executor uploads its separately evaluated
`ci-artifact.json` declaration alongside `ci-receipt.json`. The join compares
the successful build's exact derivation and output paths with that declaration;
check receipts also retain exact check derivations. Native receipts require the
declared executable, complete descriptor and checked report SHA-256.
Missing/duplicate/unexpected declarations or receipts, unrelated builds,
replaced output paths, changed persisted report bytes, failed/skipped roles and
scoped dispatches cannot satisfy the aggregate. This is dispatch/build
integrity within workflow artifact provenance, not an attestation against an
executor forging both files. Make this stable context required in branch
protection; that configuration remains a maintainer action.

Mandatory host recovery includes `compute-network-policy-runtime`,
`compute-guest-upgrade`, `prod-home-replacement` and
`prod-home-consumer-resilience`. The two recovery families retain separate
replacement and consumer-resilience evidence; neither is replaced by native
Kubernetes coverage. Detailed Argo resource retirement runs in the required
native suite; the replacement VM retains real data, ownership, mount and
accelerator observations through guest replacement.

After restarting K3s, the NetworkPolicy fixture waits for actual execution in
its probe containers, not persisted Node Ready status. This readiness check
sends no traffic: first network connections remain single-shot and existing
continuous watchers are not restarted. Filler Pods use a distinct controller
selector so their ReplicaSet cannot adopt the named service stand-ins.

This tooling slice changes no intended production behavior or policy.
Removing Go assertions can still change the current
`retained-directories-image` producer identity without changing runtime code.
Consumers remain on the independently selected verified release in
`assets/helper-release/verified.json`, using its immutable GHCR digests.
An unselected producer change does not move those consumers. Follow the
[helper image delivery procedure](../docs/operations/jellyfin.md#deliver-helper-images):
ordinary protected-main publication and anonymous verification precede a
separately reviewed selection. There is no last manual import; this tooling
change selects no new production helper and performs no production operation.

Linux also requires the fast `prepare-luks-storage` check. It exercises real
rsync transfers/checksum verification and refuses unsafe operations before
simulated block/format mutators. It does not prove real partitioning or LUKS
formatting; `prepare-luks-storage-runtime` does. It runs the packaged tool on
disposable VM disks through preflight, format, the documented realization,
quiesce, copy and verify, and refuses an in-use disk and a disk without a WWN.
Every call of the block, partition, LUKS, measurement and transfer tools in
the packaged script, found in its syntax tree, must run the real binary and
succeed; only findmnt's silent "no mount" exit 1 is accepted. Error-wording
probes of external utilities are not retained as safety evidence; unsupported
fixture xattrs are reported as unexercised.

The schema gate checks original canonical YAML against pinned local schemas,
using PyYAML's libyaml parser where available while retaining strict duplicate,
merge and string-key checks and complete document/schema accounting. It does not prove
CEL, admission, controller reconciliation or traffic; the official CRD envelope
schema also permits some extra fields. Kyverno owns rendered semantic policy;
`argocd-application-health` separately executes the production health Lua.

`prod-home-manifests-policy` runs pinned offline Kyverno against canonical
manifests and twelve genuine identity/Seerr/ingress renders. Each family
declaration in `modules/tests/_kubernetes-policy/fixtures/` lists the rules
that must pass for every rendered resource and the scenarios that must fail.
The inputs derivation turns them into native Tests whose resources come from
the genuine renders, changed only by a small `yq` mutation. Tests retain exact
rule/resource outcomes; missing coverage, skips and evaluation errors fail.
Policy, fixture and generated Test loading rejects duplicate YAML mapping keys,
including keys inside merge sources, before generating expected outcomes.
Valid merge overrides and aliases remain supported.
The accelerator grant admits only the declared Jellyfin holder's `/dev/dri`
mount and evaluated `gpu-render` group. No workload may be privileged, including
the network-policy enforcer; a dedicated negative fixture guards that boundary.

The gate runs as five independent derivations: `transport`, `gitops`,
`edge-identity` and two round-robin halves of `workloads`
(`prod-home-manifests-policy-<family>[-<half>]`). The aggregate
`prod-home-manifests-policy` check requires every declaration-derived scenario
to pass in exactly one part. Compatible Tests share native Kyverno invocations;
each result remains bound to its engine-emitted Test path, declared name and
complete rule/resource outcomes. Parts and the aggregate must use the same
prepared input contents; editing a report and its inventory together cannot
remove required coverage.

Schema evidence is prepared once in immutable Nix inputs and reused by the
parts. Mutable input copies are revalidated. The aggregate checks schema and
CRD provenance and runs the schema counterfactuals once.

Schema counterfactuals assert native invalid-resource status and validation
paths, not error-message wording.

```sh
nix build --no-link ".#checks.$(nix eval --impure --raw --expr builtins.currentSystem).prod-home-manifests-policy" -L
```

The static Argo bootstrap bundle consumes the Argo controller/CRD tree, retained
Argo Namespace, root Application and AppProject. Unrelated application manifests
do not invalidate it; seed equality, project checks and CRD checks remain required.

Superseded rendered Nix/Python semantic validators have been removed after
complete native positive, negative and fail-closed coverage. Genuine input,
application/Lua execution and generation checks remain separate.
No production admission controller is installed.

`verify-kubernetes-api` runs pinned Chainsaw scenarios against a disposable,
pinned target-version K3s fixture. Like the production guest, it disables K3s's
embedded network-policy controller and uses nftables kube-proxy. It imports the
canonical enforcer's pinned image, applies the canonical unprivileged
`NET_ADMIN` DaemonSet and waits for readiness before the scenarios.
The existing disposable Linux Docker executor loads the fixed `br_netfilter`
kernel prerequisite and fails if it is unavailable. The owned K3s node explicitly
enables its IPv4 bridge hook at creation, so same-bridge Service replies traverse
the required NAT hooks. This prepares the ephemeral executor only; it is not a
production-host module/sysctl operation or a fresh/reboot policy guarantee.

The fast `verification-reports` check exercises report acceptance, first
command-failure preservation through failed cleanup, CoreDNS zero-versus-unknown
evidence and declared-build receipt rejection without a cluster. An observed
Deployment with a usable status mapping defaults omitted `readyReplicas` to zero;
absent or malformed status remains unknown.

The native execution report must list every required scenario identity, with no skip, failure
or cleanup failure:

- Gateway CEL admission: the actual tracked CRD admits a valid resource,
  rejects HTTP-with-TLS for the intended reason and preserves prior state.
- Runtime-Secret API: the exact evaluated production reconciliation script
  preserves foreign keys and replacement UIDs, refuses malformed or stale
  inventory without mutation, keeps the prior acknowledgment when UID
  recording fails, and retires same-UID shared and sole-owner TLS objects.
  Two kubelet scenarios check projected Secret file readability.
- Argo: real controllers with disposable Git cover current-revision failed and
  missing child blocking and recovery, retained-directory hook sequencing,
  self-heal, Git omission without pruning, and direct and root-child
  retirement that preserves usable retained Namespace/PV/PVC identities.
- Gateway: generation-aware controller status, distinct trusted and untrusted
  source addresses with actual CNI denial, spoofed metadata replacement,
  ReferenceGrant and backend TLS name/CA denial and recovery, real Chromium
  WebAuthn/Kanidm/OIDC authorization through
  `modules/tests/_gateway-runtime/authorization.py`, and access/error-log
  privacy.

These scenarios replace the `gateway-runtime` NixOS VM check and the
Kubernetes API cases of `runtime-secret-k3s`. The Argo scenarios are new
controller coverage. They are disposable fixtures, not
production availability or deployment proof. Node-local storage and Docker
bridge peers do not prove Incus mounts, ID maps or host nftables.

`runtime-secret-k3s` keeps the host seam the native fixture cannot observe:
the evaluated production systemd unit starts, creates its state directory,
acknowledges the exact generation, fails with `Result=exit-code` on incomplete
delivery without changing prior state, and succeeds again after repair.
`public-edge-runtime` covers public-edge TLS/header/request/logging boundaries.
Host checks retain mount/ID-map/filesystem/firewall/service-delivery evidence;
no Kubernetes-only replacement justifies removing that coverage.

`media-live-acceptance` executes the unchanged pinned native media suite on the
hosted Docker daemon, using the packaged runner's exact source/manifests/policy
inputs rather than the invoking checkout. It proves actual libraries,
profiles/scores, wrong credentials/configuration and denied access, stable
managed identities, preserved unmanaged video bytes, Seerr first-owner and
steady-state boundaries, serialized producer entry points and owned cleanup.
It does not prove Kubernetes RBAC or host mount propagation. Required
`compute-guest-upgrade`, `prod-home-replacement` and
`prod-home-consumer-resilience` separately retain existing guest activation,
real Incus/ZFS/MergerFS/K3s replacement and consumer-resilience evidence.

`media-ingress-runtime` applies the committed media NetworkPolicies on a K3s
node that enforces them. The Gateway proxy and each declared client reach
Radarr, Sonarr, Prowlarr and SABnzbd, which have no login of their own; every
other pod is refused.

### Reproduction and omission probe

On a native x86-64 Linux builder with KVM:

```sh
nix eval --json .#hostedCiPlan > hosted-plan.json
nix eval --json .#hostedCiInventory.x86_64-linux > hosted-inventory.json
nix build -L .#hostedCiJobs.x86_64-linux.checks
jq -r '.runtime[].drvPath' hosted-inventory.json | while IFS= read -r drv; do
  nix build -L --max-jobs 1 "$drv^*"
done
# Native interactive interface is unchanged.
nix build .#checks.x86_64-linux.runtime-secret-k3s.driver
(
  run_dir=$(mktemp -d /var/tmp/homelab-test.XXXXXX)
  trap 'rm -rf -- "$run_dir"' EXIT
  XDG_RUNTIME_DIR="$run_dir" ./result/bin/nixos-test-driver
)
```

Manual drivers prefer `XDG_RUNTIME_DIR` over `TMPDIR` and retain VM disks after
shutdown. Use owned, mode-0700 disk-backed scratch as above: accumulated VM
images can exhaust `/run/user/$UID` tmpfs and cause guest block-device I/O
failures. Hosted builds already use the disk-backed `/nix/build` directory.

Native descriptors build both runners; their full execution is separately
required. The API descriptor supplies `--docker-context default`, its owned
fresh `reportFile`, and `reportCheckArguments` for the same packaged app.
The generic executor runs in its job-owned evidence directory, refuses an
existing report, checks the completed report, and binds the uploaded exact
bytes to the success receipt. Applications without a persisted report need
neither additional field; the standard media arguments and suite are unchanged.

```sh
nix run .#verify-kubernetes-api -- \
  --docker-context default --report ./kubernetes-api-result.json
nix run .#verify-kubernetes-api -- --check-report ./kubernetes-api-result.json
nix run .#media-live-acceptance -- \
  --docker-host unix:///var/run/docker.sock --platform linux/amd64
```

Hosted execution verifies that `default` addresses exactly
`unix:///var/run/docker.sock`; local reproduction may explicitly select another
Unix-socket context, such as `colima`. The app ignores ambient Docker/Kubernetes
credentials, creates its own loopback-only API and kubeconfig, and removes its
owned container, anonymous volumes and credentials even on scenario failure.
Cleanup failure makes the gate fail. The approved sanitized report is included
in the generic `native-<system>-<application>-<run-id>` evidence artifact even
on failure; raw fixture logs, kubeconfig and assertion errors are not exported.

Owned image-import failures distinguish archive copy, `ctr` import and archive
cleanup, retaining only the zero-based archive ordinal rather than archive names or command arguments. A failed import
also projects only known dial-failure categories for the fixture's fixed
containerd socket from at most 8 KiB of stderr, then performs a readonly `ctr version`
server RPC with one-second connect, two-second request and four-second process
deadlines. Both RPC output streams are discarded; its return code or fixed
timeout/transport category is diagnostic only. The original command failure and
full cleanup remain authoritative; neither socket existence nor API `/readyz`
alone establishes containerd RPC readiness.

Argo failure witnesses capture only owned, whitelisted status fields before
cleanup. Native catch scripts use Chainsaw's injected current context.
Gateway prerequisite failures also retain a bounded pre-cleanup witness:
the pending condition/watch stage, fixed Gateway resources' current and observed
generations, allowlisted status/reason categories, controller/ancestor matches,
owned controller/proxy workload readiness, and node address types (not values).
For one owned proxy, failure-only diagnostics use native `kubectl port-forward`
bound to localhost. It reads allowlisted Envoy server/XDS/TLS/listener counters
before the actual readiness endpoint: a refused remote readiness port terminates
the shared forward, and that listener itself depends on XDS. Curl ignores ambient configuration and
limits each response to 16 KiB and three seconds; native response bodies, dynamic
stat names and addresses are discarded. Forwarding is stopped before fixture
cleanup, with interrupts ignored during stop/reap/close and prior handlers restored
afterward. These observations are not safety acceptance. The native API proxy
separately reaches the readiness port by Pod IP from the owned K3s node network,
distinguishing that path from port-forward's local socket. It discards stdout and
stderr without buffering, records only the return code and a fixed failure
category, and retains its three-second request and five-second process timeouts.
Failure-only DNS evidence reads that owned Envoy container's CRI identity and
resolver mount, then makes bounded lookups of the fixed xDS Service name through
the configured DNS Service IP and one ready CoreDNS endpoint, from the same
actual network namespace. Only return codes, fixed error categories,
answer/Service matching booleans and CoreDNS Service/endpoint counts survive.
The API's null EndpointSlice `endpoints` representation means an empty list,
as do absent/null optional workload arrays. Required List `items` must remain
arrays; missing required fields and malformed shapes remain unavailable, not
zero endpoints. The same bounded witness projects
CoreDNS Deployment counts and at most four owned Pods' readiness/phase counts,
standard scheduling/sandbox/init/container conditions and fixed waiting-reason
counts. Events are queried only by those Pods' actual UIDs; at most
32 events retain fixed Kubernetes reasons, counts and the existing curated error
categories. Only Pod indices survive, never names, UIDs, specs, messages or logs;
unknown reasons/categories remain explicit rather than guessing a cause.
Workload/event read failure does not discard DNS query evidence. Unexpected
collector errors expose only a fixed exception-type category.
Read-only node facts also project `br_netfilter` module presence and the
node-network-namespace IPv4 bridge hook flag; unreadable facts remain null.
Missing tools, resolvers or namespace access remain unavailable evidence, not
network root causes. Native resolver contents, names, addresses and output are
discarded; no Pod, policy or readiness setting changes.
It exports no raw API objects, messages, logs, events or Secrets. An unavailable
witness cannot turn the original prerequisite failure into acceptance.

Behavior counterfactuals use the same app with a new report filename. Each
must fail, and its report must show the failure at the intended scenario step;
a mutation that passes every scenario fails with
`negative-mutation-unexpectedly-passed`, which is not a valid rejection:

```sh
nix run .#verify-kubernetes-api -- --docker-context default \
  --remove-gateway-tls-cel --report ./kubernetes-api-no-cel.json
nix run .#verify-kubernetes-api -- --docker-context default \
  --argo-mutation always-healthy --report ./kubernetes-api-always-healthy.json
```

The other Argo mutations are `source-error-ignored` (removes only the health
Lua's source-comparison guard) and `cascade-retained` (removes the retained
objects' `Prune=false,Delete=false` sync options and adds a cascading
finalizer).

This mutation removes a real registration from the actual flake checks without
editing source or executing test outputs. Evaluation can still realize Helm
and other import-from-derivation inputs. Run from the checkout on native Linux;
require the named missing-check diagnostic, not merely any nonzero exit:

```sh
nix eval --json --impure --max-jobs 1 --cores 4 --expr '
  let
    f = builtins.getFlake (toString ./.);
    ci = import ./modules/flake/ci.nix {
      lib = f.inputs.nixpkgs.lib;
      withSystem = system: action: action {
        pkgs = import f.inputs.nixpkgs { inherit system; };
      };
      self = f // {
        checks = f.checks // {
          x86_64-linux = builtins.removeAttrs f.checks.x86_64-linux [
            "runtime-secret-k3s"
          ];
        };
      };
    };
  in ci.flake.hostedCiPlan.x86_64-linux
'
# Expected: Missing required CI checks for x86_64-linux: runtime-secret-k3s
```

Removing `prod-home-manifests-schema`, `compute-guest-upgrade`,
`prod-home-replacement` or `prod-home-consumer-resilience` instead must fail
with the corresponding identity. ARM Linux also requires native
`agenix-restart-guard` registration and runtime capability.
Removing any required native app or its package, replacing the package with a
non-derivation or changing the app away from its executable package must fail
with `Required native CI apps must have matching executable packages`.
Removing the required-name list entry changes the verification contract; it is
not a registration-loss probe. API empty selection, nonexistent selector,
removed TLS CEL or Argo mutations remain negative probes, not exclusions.
For workflow accounting, remove one successful receipt, one evaluated platform
inventory or one persisted report from a disposable artifact copy; the final
aggregation must fail. Replacing an executor's successful build with an
unrelated derivation, changing its declared output paths, substituting a native
program or changing accepted report bytes must fail.
The accounting self-check and real downloaded-artifact join are runnable:

```sh
python3 .github/required-ci.py --self-test
# After downloading the full workflow artifacts into the documented directories:
RUN_ID="$RUN_ID" python3 .github/required-ci.py "$RUNNER_TEMP"
```

The join reads `required-plan/check-inventory.json`, one
`required-inventories/check-inventory-<system>-checks-<run-id>/check-inventory.json`
per platform, `required-receipts/*/ci-receipt.json` and its independently
evaluated `ci-artifact.json`, and
`required-native/native-<system>-<application>-<run-id>/<reportFile>`.

Linux VM checks remain directly buildable for x86-64 and ARM64. Hosted CI
partitions actual derivations using NixOS test drivers and declared
`requiredSystemFeatures`, never check names or Hestia groups. A driver identifies
a runtime check, not a KVM requirement. Nix exports each entry's `requirements`
(`kvm`, `uidRange`, `cgroups`), hosted eligibility and explicit unsupported reason
through `hostedCiInventory.<system>`; the workflow carries those facts into its
matrix. Every hosted runtime check gets a separate native runner with
`--max-jobs 1`; the fast aggregate contains no runtime or unsupported checks.
All platforms retain their semantic/schema/freshness inventory and
package/configuration/development groups. ARM VM/KVM checks remain explicitly
unsupported on hosted runners without KVM; capable ARM builders can build them
directly. Unknown required system features also receive an explicit unsupported
reason rather than being scheduled on an incapable runner.

Cold recovery deliberately discards the guest container cache and pulls the
canonical public images online. The fixture's first bootstrap diagnostic
interval fails promptly on classified registry refusals without preloading,
retrying, weakening readiness or changing the shipped bootstrap command.
Only its owned bootstrap process group is stopped, including surviving children
when the leader exits first. The leader stays unreaped until group shutdown.
Children retain their full 30-second SIGTERM grace even if the leader exits first.
Bootstrap output and interval diagnostics are captured while supervising the
owned process group, then printed on every outcome. Classified registry
refusals retain the outer journal, containerd and workload dumps too. Disposable
fixture credential values do not suppress diagnostics; assertions still reject
credential leaks from shipped staging and application commands.
`prod-home-registry-failures` checks the pure classification boundary and real
owned-child cleanup for running and exited-but-unreaped leaders, with an
unrelated session left alive. It does not simulate registry APIs or replace
the two complete cold recovery scenarios.

Argo CD image repository, version and digest changes belong in
`modules/den/aspects/kubernetes/services/argocd.nix`. Regenerate the canonical
manifests with `sync-prod-home-manifests`; do not override those references
only inside a recovery fixture.

`agenix-restart-guard` uses the existing NixOS systemd-nspawn test driver on
both native Linux architectures. It uses the same production generator/algorithm,
rebuilt for the hypothetical native ARM fixture rather than changing hvn-hyp1's
deployed architecture, and preserves the private stamp modes (700/600), initial
consumer start, unchanged-content non-restarts, exactly one rotation restart,
and repeated-rotation non-restart assertions. There is no duplicate VM suite or
script/hash assertion. PAM, hardening, kernel, network and security boundary tests
retain their VM gates. Only disposable Linux lanes requiring `uid-range` enable
Nix auto-allocated UIDs and the cgroups experimental feature, after requiring a
cgroup-v2 host. Darwin never schedules this Linux container test.

`classify-legacy-media` retains its VM wrapper. The existing container backend
under pinned Nix 2.35.2 reached the real ACL assertion, where `setfacl` failed
with `Operation not supported` despite kernel POSIX ACL support. This matches
the documented Linux build-sandbox xattr limitation in the
[Nix 2.35 release notes](https://nix.dev/manual/nix/2.35/release-notes/rl-2.35.html#improvements),
not an inherent private-kernel requirement for ACLs. No container parity or
performance improvement is claimed; the ACL assertion remains required.

Every registered check must be a derivation and belongs exactly once to the
fast, hosted runtime, or unsupported partition. Future registrations join
automatically. Planning reads lazy feature declarations across the selected
platforms without forcing raw test derivations or `drvPath`. Native check jobs
upload evaluated platform inventory with exact hosted derivation identities;
unsupported entries retain `drvPath = null`, so a Darwin receipt cannot force an
unsupported Linux build graph. Runtime receipts retain their exact derivations.

Build jobs release their separate `nix eval` heap before building the exact
derivation, preserving memory for the test. A hosted x86-64 runner has 4 vCPUs
and 16 GiB of memory: VM fixtures must fit, leaving several GiB beyond guest
memory. Oversubscription can lose the runner without producing a test result.

Hosted CI builds the full ARM64 Darwin configuration. An ARM64 Linux job first
builds the Linux system closure used by its `nix.linux-builder` VM and passes
that closure to the macOS job through a one-day workflow artifact. Only the
Darwin configuration job waits for this bootstrap; Linux and other Darwin
groups do not. This breaks the first-build cycle without weakening the
production configuration. The workstation builds the same configuration as
its activation gate.

Manual dispatch builds all hosted groups by default. Set `system` to build
only that platform, or set `check` to run one check (defaulting to x86-64 when
no specific platform is selected). A single-check dispatch or an ARM-only
dispatch is not complete infrastructure verification:

```sh
gh workflow run ci.yml --ref "$REF" -f check=den-semantics
gh workflow run ci.yml --ref "$REF" -f system=aarch64-linux
```

Check names and implementations belong in Nix, not workflow branches. Single
dispatch validates a check or native application's registration and platform;
unsupported or ambiguous selections fail rather than silently skipping.

`modules/flake/ci.nix` owns native app package identities, arguments, deadlines,
cleanup prefixes and executor requirements through `hostedCiPlan`. Every
declared app receives exactly one matrix row, on full runs and single dispatch.
The native executor builds that package, runs the whole app even when its
dependencies are cached, and independently checks owned Docker cleanup.

`check=media-live-acceptance` selects the standard native x86-64 Docker suite;
it does not require root-owned storage or change host resolution.
`check=household-sign-in-runtime` selects the complete native x86-64 household
suite. Both packages carry their exact source, canonical manifests and policy
inputs, rather than borrowing files from the caller's checkout. The household
package materializes its Python suite and manifests; its three helpers use
the selected immutable verified GHCR identities and are pulled normally,
never loaded from local archives or aliased from current producer outputs.
The suite retains LDAP/Jellyfin/Seerr authentication, MFA and POSIX-password
migration, recovery, certificate/group security, and established-session
HTTP 200 plus original-user-ID acceptance while fresh login is denied after
membership removal. Directory NetworkPolicy remains a separate real
K3s/kernel VM gate.

The delivered Configarr and Seerr producers use exit 0 for success and exit 1
for application failure. Synchronous and serialized runs require that exact
outcome, alongside real API/state/lock assertions. `media-producer-exit` checks
the small exit policy without Docker; the application suite does not inject
Docker startup failures or deliberate crashes. Failure labels include only
numeric status, not Docker/application stderr or generated credentials.

The household app is also available as `nix run .#household-sign-in-runtime`.
Run it only as root in an exclusive disposable native x86 Linux Docker
fixture, with the Nix-declared canonical directory hostname resolving to
`127.0.0.1`. Its existing `TMPDIR` parent (default `/root`) is canonicalized;
the `household` child must not exist, including a dangling symlink. The app
refuses existing fixture containers and network before pulling images, never
edits host resolution, and cleans only owned containers, network and synthetic
credentials on exit. No production account, credential or Seerr publication
is part of this acceptance.

The generic native executor dispatches `requirements.root`,
`requirements.ownedStorage` and `loopbackHost`, never application names.
Owned storage is restricted to an exclusive disposable Linux Docker runner:
it places `/nix`, Docker and containerd data on its owned Btrfs loop image.
Setup refuses an existing image (including dangling symlinks), `/nix`, daemon
storage symlinks and existing target mounts. Cleanup validates the recorded
image UUID and exact FSROOT of every mount before stopping Docker/containerd,
unmounting their bind mounts or deleting owned scratch. The Nix store remains
mounted through post-actions; final mount/loop/image teardown belongs to the
exclusive disposable runner's lifetime. Independent acceptance cleanup checks
the whole daemon and owned scratch, not just a name prefix. The executor adds
the declared canonical-domain loopback entry; the app itself never does.
Owned `TMPDIR` is selected only after Nix installation and cache setup:
installation can change ownership under `/nix` and break its own temporary
directory if pointed there early.

Linux runners enable available KVM acceleration. System builds and checks can
reuse narinfo and objects uploaded by other jobs.
Hestia's binary version is pinned alongside its action. Use core v3.1.0 or
newer: it rejects cached narinfos whose backing packs are unavailable, rather
than repeatedly advertising objects that fail during download. The manifest
and backing packs are separate GitHub cache entries; a manifest hit alone
does not prove that its objects remain available.

All jobs read the public `dvicory-homelab` Cachix cache and the signed upstream
`https://cache.numtide.com` cache documented by the pinned `llm-agents` input.
CI and shared Nix settings append its fixed public key
`niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=`.
The owner approved this signer for CI and shared fleet Nix settings. This grants
Numtide trust to supply executable store outputs, not just package metadata.
The key is not restricted to Codex or one package: it can authenticate any
requested store output. Its configured scope belongs to Nix desired state;
signature checks do not make an untrusted publisher safe.
CI appends the upstream cache and key to the user configuration after Cachix:
Cachix's base settings override installer-level `extra-*` values. The later
Hestia configuration preserves this user configuration. Existing substituters
and keys remain configured. This permits exact upstream package substitution
without changing package sources or versions. Signature verification remains
required; CI does not automatically accept PR-provided flake configuration or
grant upstream cache-write access. Successful `main` push
jobs publish their existing outputs, runtime closures, and realized build
dependencies directly from the build runner; another job's failure does not
prevent those uploads. Publication uses the derivation roots recorded by the
successful build, including dependencies embedded in compressed images that
have no runtime store references. It excludes the source/derivation-only
closure and never builds missing outputs for publication. There is no second
build on a separate publication runner. The `cachix-publish` environment remains
restricted to `main`, and only the publication step receives its per-cache write
token. Pull requests and manual dispatches remain read-only.

The generated-manifest package retains each declared application's Helm chart
as an evaluation input, so ordinary `main` publication includes those realized
fixed-output charts even though IFD rendering embeds only their resulting YAML.
The app-template chart uses upstream's OCI distribution with the locked version
and unpacked-content hash; a different chart tree still fails the pinned hash.
This changes neither rendered desired state nor cache trust.

A successful warm `main` job does not prove that a cold PR runner can substitute
its dependencies. For a repeated compiled dependency, compare the exact
derivation and every required output with the `main` log, then query each output
using `nix path-info --store https://dvicory-homelab.cachix.org "$output"`.
A 404 means the output is unavailable, not that its derivation changed; Cachix
also hides paths whose closure is incomplete. The publisher's realized-only
selection includes the patched Incus server, documentation, agent loader and
client even when a VM image hides them from its runtime references.

Restore unavailable dependencies only through owner-approved protected-main
publication of the exact successful outputs and their closures. Never use PR
credentials or accept unsigned NARs to make a cold-cache proof pass. Measure
substitution from an empty isolated store with builds disabled before
attributing a runtime improvement to the cache.

Exact derivations, not changed-file guesses, determine cache reuse. Runtime
fixtures must reference individual files, package-local directories (including
the test's adjacent scripts), or explicit filesets rather than interpolate
`self` paths that retain the entire flake source as a build input. The recovery
fixture includes all of its copied manifests and no unrelated applications.
Hermes image tags still identify the Git source revision; changing that
deployment provenance is not a cache optimization.

Nix store contents published by CI are public, so CI outputs must never contain
decrypted secrets.

### Required-green main Nix helper candidates

`helper-release.yml` is reusable only: **Nix CI** calls it automatically for a
same-repository `push` to `main`, after **Required CI** succeeds. That gate joins
every required CI dependency, including all build matrix legs, the Darwin
builder bootstrap, the Actions security audit and `All required CI`'s strict
inventory/execution/report join. Every dependency must succeed;
failed, cancelled or skipped dependencies refuse publication. PRs and manual or
selected CI runs never publish. There is no early PR admission, `workflow_run`
trigger, manual publisher dispatch or per-release approval click.

Both caller and callee check the trusted repository, main push event, CI workflow
path and immutable source/tooling SHA. The callee also checks GitHub's actual
workflow ID, run ID, attempt, repository and main head facts, and the completed,
successful **Required CI** job for that exact SHA/attempt. It repeats that check
before publication. The parent run is still executing the publisher, so its
overall conclusion is deliberately not the gate. The exact merged-main push SHA
is retained even if a newer main push arrives; consumers never follow a branch
or mutable image tag.

The producer's local Git reference declares `shallow=1` for Actions'
detached checkout; its `rev` remains the exact authorized SHA.

The producer builds and audits four native x86-64 helpers in a read-only,
sandboxed job. Only the caller's narrowly scoped reusable-workflow call grants
`packages: write`; the callee reduces permissions for authorization, build and
verification, leaving that authority only in its publisher job. No repository
write permission, inherited repository secrets or approval environment is used.
GitHub's token is repository-associated package authority, **not four
package-scoped credentials**. Fixed destinations remain enforced by publisher
code; artifact data cannot choose them.

The publisher downloads an immutable artifact ID from its own read-only build
and checks the independently recorded metadata fingerprint, every archive's
actual checksum, config/rootfs and native platform. It checks out
`github.workflow_sha`, which must equal the exact main producer SHA, and runs
only that main-owned publisher tooling. It never executes transferred scripts
or image entrypoints. Publication credentials live in an ephemeral
authentication file removed on exit.

Data separation does not make archives safe. The credentialed job still trusts
its parsers, pinned Actions and tools. Hashes bind transferred bytes, and
credential scanning detects recognizable material; neither proves those bytes
harmless or free of every possible secret. No audit finding is suppressed.
Publication keeps Docker schema 2 config bytes, which GHCR and K3s support.
Converting them to OCI rewrites creation/history timestamps and is refused by
the exact producer-config identity check.

The fixed destinations are
`ghcr.io/dvicory/homelab/{retained-directories,kanidm-provision,jellyfin-provisioner,jellarr}`.
Automation requires a separately approved merge of this workflow and repository
Actions package-write access to those destinations. This configuration does not
authorize an unreviewed branch-owned publisher, personal token substitution or
package visibility changes.

New GHCR packages default private. Public visibility and repository Actions
access are external package-settings prerequisites, not mutations this workflow
performs. If visibility prevents verification, resolve it only with separate
owner authorization, then rerun the failed **verify** job, not the successful
publisher. The verification job has no package-write permission and
uses `--no-creds`, verified TLS and full digest retrieval to compare the remote
config/rootfs with the original Nix output. A private or mismatched candidate
remains ineligible even if authenticated publication succeeded.

`helper-verified-<sha>` records candidates for a separately tested/reviewed
consumer PR; it does not deploy them. Seven-day Actions artifacts only transfer
builds and evidence. Retain selected and supported rollback manifests/layers in
GHCR without automatic pruning, plus their committed source/digest mappings.
No GitHub Release archive or independent offline/exact-byte recovery guarantee
is added. A lost registry version must be rebuilt from still-available locked
inputs and may have a different digest; a GitHub-wide outage remains an
availability limit, never permission to use a mutable fallback.

The native disposable check is
`checks.x86_64-linux.helper-release-runtime`; it builds the existing retained
helper and a genuinely recompiled version, runs their Kubernetes Jobs through
a real TLS registry without helper preloads/imports, and checks anonymous
access, refusal, explicit old-digest rollback and retained-state identity.
`checks.<system>.helper-source` exercises exact main-caller and completed
required-job receipt authorization, including refusal of PR/manual/fork sources.
`checks.<system>.helper-release` runs the registered archive/admission audit,
including referenced extensionless layers, linked transfer files, metadata
credentials and public-certificate controls.

GitHub enforces full-SHA action pins and the repository action allowlist.
Dependabot groups action updates into a weekly pull request after a seven-day
cooldown. `.github/workflows/security.yml` runs zizmor when GitHub automation
changes and is also called by every Nix CI run, rejecting medium-or-higher
findings before helper publication.

The reusable call uses GitHub's documented [same-commit local workflow
reference](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows#calling-a-reusable-workflow).
The [caller context and permission
rules](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations)
mean the callee sees the caller's `github` facts and can only reduce the caller's
token permissions, not elevate them. No environment secret or approval
configuration is required for automatic helper promotion.