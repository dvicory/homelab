# homelab

Declarative NixOS homelab and nix-darwin workstation configuration, organized
with [Den](https://github.com/denful/den) and flake-parts. The homelab runs
household identity, media and monitoring services in a managed K3s compute
guest, with host-owned persistent storage.

## Find what you need

- **Operate or recover services:** [Household operations](docs/operations.md),
  [identity](docs/operations/identity.md), [Homarr](docs/operations/homarr.md),
  [media](docs/operations/media.md), [Jellyfin](docs/operations/jellyfin.md) and
  [monitoring](docs/operations/monitoring.md).
- **Understand storage:** [Declared layout](docs/storage.md) and
  [disk migration](docs/operations/luks-storage-migration.md).
- **Contribute and verify:** [CI and local checks](CI.md).
- **Understand decisions and guarantees:** [Architecture decisions](docs/architecture/decisions/)
  and [current OpenSpec contracts](openspec/specs/).
  [Active changes](openspec/changes/) are proposals, not current guarantees.

## Where desired state lives

| Change | Start here |
| --- | --- |
| Host hardware, roles or settings | [`modules/den/hosts/`](modules/den/hosts/) |
| Cluster services, routes or placement | [`modules/den/clusters/`](modules/den/clusters/) |
| Shared behavior | [`modules/den/aspects/`](modules/den/aspects/) |
| Entity fields and defaults | [`modules/den/schema/`](modules/den/schema/) |
| How entities include and contribute to one another | [`modules/den/policies/`](modules/den/policies/) and [`quirks/`](modules/den/quirks/) |
| Flake outputs and CI selection | [`modules/flake/`](modules/flake/) |
| Verification behavior | [`modules/tests/`](modules/tests/) |

Keep metadata on Den entities and behavior in aspects. Reuse the existing
contribution and collection paths rather than adding a parallel registry.

## Make a safe change

1. Read the relevant current contract and runbook. Change the Nix declaration,
   not a generated copy or a live service's managed settings.
2. Track new source files with `jj file track <path>` before evaluating the
   flake. Nix files under `modules/` are imported automatically; underscore-prefixed
   files are excluded from automatic import.
3. Regenerate affected documentation or manifests and review the resulting
   diff. [CI.md](CI.md) explains the files writer; the
   [deployment runbook](docs/operations.md#deploy-configuration) covers manifests.
   `flake.nix` is also generated: edit its `flake-file` declarations in modules,
   then use `nix run .#write-flake`.
4. Run the relevant checks on a compatible disposable builder using
   [CI.md](CI.md). Report what executed, not just what evaluated or built.

**Publishing can deploy.** Argo tracks the production branch; see the
[deployment runbook](docs/operations.md#deploy-configuration) before publishing
manifest changes. A successful check is not authorization to merge, activate,
sync or deploy.

Never use production Docker, Incus, mounts or credentials for test fixtures.
Keep decrypted secrets out of Git, Nix store outputs, images and logs. Public
cache signing keys grant trust to executable outputs; do not accept new keys
or disable signature checks to work around a failed build.
