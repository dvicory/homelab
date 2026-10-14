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

On a builder for the selected system:

```sh
nix build .#ciBundles.aarch64-darwin
nix build .#ciJobs.x86_64-linux.nixosConfigurations
nix build .#checks.aarch64-linux.den-semantics
```

### Required evidence layers

Hosted CI uses three directly buildable groups, not Hestia metadata suffixes:

| Group | Required coverage | Hosted platform |
| --- | --- | --- |
| `fastChecks` | Nix/Den placement, storage, identity, public-edge and current Jellyfin/media contracts; credential/input safety; local compute-runtime and generated-bootstrap behavior; canonical manifest freshness, pinned local schemas, and offline Kyverno policy | All three systems |
| `kubernetesApplications` | `public-edge-runtime`, `media-ingress-runtime`, and separate full execution of `verify-kubernetes-api` (admission, Secret API, Argo and Gateway controller/CNI/authorization) and `media-live-acceptance` (native media APIs) | x86-64 Linux |
| `hostRecovery` | Secret/service delivery, storage tools, mount/ID-map/filesystem/firewall enforcement, identity provisioning, ESP mirror recovery, existing-guest upgrade and whole-guest replacement | x86-64 Linux |

The exact mandatory registrations live in `modules/flake/ci.nix`. Missing
required checks, non-derivation replacements or VM gates replaced by non-VM
checks fail hosted evaluation. Both native apps must have matching executable
packages; building those packages alone is not acceptance.
Other non-VM checks are still projected automatically into `fastChecks`.
Other native VM/KVM checks are projected into `hostRecovery` on x86-64 Linux,
without duplicating the focused application group. Ordinary `ciJobs.checks`
and `ciBundles` still include every registered check; packages, development
outputs and system configurations retain their automatic projection.

`hostedCiInventory.<system>` records every check's derivation, required system
features, hosted group or explicit unsupported-platform reason, and the native
executables. Every hosted check must occur in exactly one group. `All required
CI` requires all three platforms, every projected group and successful
check/native execution receipts. A missing matrix job, skipped/failed group,
missing receipt or native runner that was only packaged cannot satisfy it.
Make this stable aggregate context required in branch protection; configuring
GitHub branch protection remains a maintainer action.

The mandatory host inventory includes `compute-network-policy-runtime`,
`compute-guest-upgrade` and `prod-home-replacement`, not just whichever checks
happen to remain registered. The current combined `prod-home-replacement`
fixture retains both replacement and consumer-resilience assertions. When the
approved PR67 dependency is integrated, its two-family split and real required
gate definitions must be carried with it. Neither recovery concept is replaced
by native Kubernetes coverage. Broad VM scenario narrowing remains deferred
until equivalent native acceptance passes.

Linux also requires `prepare-luks-storage` in `fastChecks`. It exercises real
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

Native NixOS tests are identified by their `.driver`, and other KVM-dependent
checks by `requiredSystemFeatures`, not display metadata. Hosted application
and host groups require `/dev/kvm`; missing acceleration fails rather than
silently omitting the group. Hosted ARM Linux has no KVM and Darwin cannot run
native Linux VMs, so neither hosts those groups. Linux checks registered for
ARM remain directly buildable on a KVM-capable native ARM builder.
`fastChecks` builds two derivations at a time so the policy gate's parts can
overlap; the VM groups use `--max-jobs 1`; other groups retain normal Nix
parallelism. All VM-bearing groups evaluate in a separate `nix eval` process
and then build the resulting derivation, releasing the evaluator heap before
starting a guest.

A hosted x86-64 runner has 4 vCPUs and 16 GiB of memory. VM fixtures must fit
there: request at most 4 cores and leave several GiB beyond guest memory.
Oversubscription can lose the runner without producing a test result.

The schema gate checks original canonical YAML against pinned local schemas,
with duplicate-key and complete document/schema accounting. It does not prove
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
The accelerator grant admits only the declared Jellyfin holder's `/dev/dri`
mount and evaluated `gpu-render` group. No workload may be privileged, including
the network-policy enforcer; a dedicated negative fixture guards that boundary.

The gate runs as five independent derivations: `transport`, `gitops`,
`edge-identity` and two round-robin halves of `workloads`
(`prod-home-manifests-policy-<family>[-<half>]`). The aggregate
`prod-home-manifests-policy` check requires every declared scenario to pass
in exactly one part, then runs the per-render schema and CRD provenance
checks and the schema counterfactuals once.

Schema counterfactuals assert native invalid-resource status and validation
paths, not error-message wording.

```sh
nix build --no-link ".#checks.$(nix eval --impure --raw --expr builtins.currentSystem).prod-home-manifests-policy" -L
```

Superseded rendered Nix/Python semantic validators have been removed after
complete native positive, negative and fail-closed coverage. Genuine input,
application/Lua execution and generation checks remain separate.
No production admission controller is installed.

`verify-kubernetes-api` runs pinned Chainsaw scenarios against a disposable,
pinned target-version K3s fixture. Like the production guest, it disables K3s's
embedded network-policy controller and uses nftables kube-proxy. It imports the
canonical enforcer's pinned image, applies the canonical unprivileged
`NET_ADMIN` DaemonSet and waits for readiness before the scenarios.
Its report must list every required scenario identity, with no skip, failure
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
`compute-guest-upgrade` and `prod-home-replacement` separately retain existing
guest activation and real Incus/ZFS/MergerFS/K3s replacement evidence.

`media-ingress-runtime` applies the committed media NetworkPolicies on a K3s
node that enforces them. The Gateway proxy and each declared client reach
Radarr, Sonarr, Prowlarr and SABnzbd, which have no login of their own; every
other pod is refused.

### Reproduction and omission probe

On a native x86-64 Linux builder with KVM:

```sh
nix eval --json .#hostedCiInventory.x86_64-linux
nix build -L .#hostedCiJobs.x86_64-linux.fastChecks
for group in kubernetesApplications hostRecovery; do
  drv=$(nix eval --raw ".#hostedCiJobs.x86_64-linux.$group.drvPath")
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

The application link farm builds both native runners; their full execution is
separately required. Use an explicit local Unix-socket Docker context and a new
API report filename (the app refuses overwrite). CI also validates the
completed report through the same packaged API runner:

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
Cleanup failure makes the gate fail. Only its sanitized report is uploaded,
including on failure; no raw Docker logs, kubeconfig or assertion errors.

Argo failure witnesses capture only owned, whitelisted status fields before
cleanup. Native catch scripts use Chainsaw's injected current context.

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
nix eval --impure --max-jobs 1 --cores 4 --expr '
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
  in ci.flake.hostedCiJobs.x86_64-linux.fastChecks.drvPath
'
# Expected: Missing required CI checks for x86_64-linux: runtime-secret-k3s
```

Removing `prod-home-manifests-schema`, `compute-guest-upgrade` or
`prod-home-replacement` instead must fail with the corresponding identity.
Removing either required native app or package, replacing the package with a
non-derivation or changing the app away from its executable package must fail
with `Required native CI apps must have matching executable packages`.
Removing the required-name list entry changes the verification contract; it is
not a registration-loss probe. API empty selection, nonexistent selector,
removed TLS CEL or Argo mutations remain negative probes, not exclusions.
For workflow accounting, remove one successful receipt or one platform
inventory from a disposable artifact copy; the final aggregation must fail.

Hosted CI builds the full ARM64 Darwin configuration. An ARM64 Linux job first
builds the Linux system closure used by its `nix.linux-builder` VM and passes
that closure to the macOS job through a one-day workflow artifact. This breaks
the first-build cycle without weakening the production configuration. The
workstation builds the same configuration as its activation gate.

Manual dispatch builds all hosted groups by default. Set `system` to build
only that platform, or set `check` to run one check (defaulting to x86-64 when
no specific platform is selected). A single-check dispatch or an ARM-only
dispatch is not complete infrastructure verification:

```sh
gh workflow run ci.yml --ref "$REF" -f check=den-semantics
gh workflow run ci.yml --ref "$REF" -f system=aarch64-linux
```

Successful check groups upload nonempty native outputs as
`check-output-<group>-<system>-<run-id>` artifacts; empty successful outputs
retain their evidence in the job log. The real API step uploads the sanitized
`kubernetes-api-<system>-<run-id>` report on success or failure. Scenario identity,
operation status, skipped selection and owned-state cleanup are enforced by
the existing scenario implementations, not by artifact presence.
All jobs read the public `dvicory-homelab` Cachix cache. Successful `main` push
jobs publish their existing outputs and runtime closures directly from the build
runner; another job's failure does not prevent those uploads. There is no second
build on a separate publication runner. The `cachix-publish` environment remains
restricted to `main`, and only the publication step receives its per-cache write
token. Pull requests and manual dispatches remain read-only.

Nix store contents published by CI are public, so CI outputs must never contain
decrypted secrets.

GitHub enforces full-SHA action pins and the repository action allowlist.
Dependabot groups action updates into a weekly pull request after a seven-day
cooldown. `.github/workflows/security.yml` runs zizmor when GitHub automation
changes and rejects medium-or-higher findings.