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
| `fastChecks` | Nix/Den placement, storage, identity and public-edge contracts; local compute-runtime and generated-bootstrap behavior; canonical manifest freshness, pinned local schemas, and offline Kyverno policy | All three systems |
| `kubernetesApplications` | `public-edge-runtime`, `media-runtime`, plus the separately executed `verify-kubernetes-api` app (Gateway CEL admission, runtime-Secret API, Argo controller and Gateway controller/CNI/authorization scenarios) | x86-64 Linux |
| `hostRecovery` | `agenix-restart-guard`, `classify-legacy-media`, `mergerfs-capability`, `runtime-secret-k3s`, `compute-ingress-runtime`, `prod-home-replacement` | x86-64 Linux |

The exact mandatory registrations live in `modules/flake/ci.nix`. Missing
required checks or non-derivation replacements fail evaluation of every hosted
check group for the affected platform; the API app and package must also exist.
Other non-VM checks are still projected automatically into `fastChecks`.
Other native VM/KVM checks are projected into `hostRecovery` on x86-64 Linux,
without duplicating the focused application group. Ordinary `ciJobs.checks`
and `ciBundles` still include every registered check; packages, development
outputs and system configurations retain their automatic projection.

Linux also requires `prepare-luks-storage` in `fastChecks`. It exercises real
rsync transfers/checksum verification and refuses unsafe operations before
simulated block/format mutators. It does not prove real partitioning or LUKS
formatting. Error-wording probes of external utilities are not retained as
safety evidence; unsupported fixture xattrs are reported as unexercised.

Native NixOS tests are identified by their `.driver`, and other KVM-dependent
checks by `requiredSystemFeatures`, not display metadata. Hosted application
and host groups require `/dev/kvm`; missing acceleration fails rather than
silently omitting the group. Hosted ARM Linux has no KVM and Darwin cannot run
native Linux VMs, so neither hosts those groups. Linux checks registered for
ARM remain directly buildable on a KVM-capable native ARM builder.
`fastChecks` builds two derivations at a time so the policy gate's parts can
overlap; the VM groups use `--max-jobs 1`; other groups retain normal Nix
parallelism.

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
pinned target-version K3s fixture. Its report must list every required
scenario identity, with no skip, failure or cleanup failure:

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

`media-runtime` exercises pinned native media services and production producer
jobs: actual libraries/profiles/scores, wrong credentials/configuration and
denied access, stable managed identities, preserved unmanaged video bytes,
and Seerr first-owner/steady-state boundaries. It does not prove Kubernetes
RBAC or host mount propagation. Required `prod-home-replacement` separately
covers the real Incus/ZFS/MergerFS/K3s replacement, host-to-guest Secret
staging/rotation, retained data and resource retirement.

### Reproduction and omission probe

On a native x86-64 Linux builder with KVM:

```sh
nix build -L .#hostedCiJobs.x86_64-linux.fastChecks
nix build -L --max-jobs 1 .#hostedCiJobs.x86_64-linux.kubernetesApplications
nix build -L --max-jobs 1 .#hostedCiJobs.x86_64-linux.hostRecovery
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

The application link farm builds the API app; executing it is a separate
required workflow step. Use an explicit local Unix-socket Docker context and a
new report filename (the app refuses overwrite):

```sh
nix run .#verify-kubernetes-api -- \
  --docker-context default --report ./kubernetes-api-result.json
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

Removing `prod-home-manifests-schema` or `media-runtime` instead must fail with
the corresponding identity. Removing `verify-kubernetes-api` from `apps`
must fail evaluation of `kubernetesApplications` with
`Missing required CI app: verify-kubernetes-api`. Removing the required-name
list entry is not this probe: it changes the verification contract rather than
testing registration loss. API empty selection, nonexistent selector, a
removed TLS CEL rule or an Argo mutation are also negative probes, not
accepted exclusions.

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