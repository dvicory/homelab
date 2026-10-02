# homelab

## Local verification

Schema and repository semantics are separate gates. Run both:

```sh
system=$(nix eval --impure --raw --expr builtins.currentSystem)
nix build --no-link \
  "path:.#checks.$system.prod-home-manifests-schema" \
  "path:.#checks.$system.prod-home-gitops-source"
```

The schema gate validates original canonical YAML against pinned local
Kubernetes and exact tracked CRD schemas, rejects duplicate keys, and
accounts for every effective document. Its negative cases reject missing
schemas, collisions, empty input and skipped validation. Converted CRD
schemas do not prove CEL admission, all ObjectMeta rules, controller
behavior or traffic. The semantic gate retains repository confinement,
ownership, retention, lifecycle and AppProject authority checks.

For actual Gateway CEL admission and rejected-update preservation, use a
local Docker Unix-socket context and a new result filename:

```sh
nix run path:.#verify-kubernetes-api -- \
  --docker-context colima --report ./api-result.json
```

This creates a pinned disposable K3s API with explicit credentials and a
loopback endpoint, then removes its container, volumes and credentials.
It does not prove controller or network behavior. The
`--remove-gateway-tls-cel` mutation must fail; an empty `--test-dir`,
`--exclude-test-regex '.*'`, an unmatched `--selector`, or a skipped
scenario must also fail. Reports contain sanitized outcomes and timings,
not kubeconfigs or raw assertion errors.

## Media verification

On an x86_64 Linux builder with KVM, `nix build .#checks.x86_64-linux.media-runtime -L` runs the pinned media services in a disposable Docker VM without production mounts or credentials.

Native service behavior is the category-integration proof. SABnzbd owns its default `*` category; the local initializer checks must not equate its complete category inventory with the configured Arr instances.