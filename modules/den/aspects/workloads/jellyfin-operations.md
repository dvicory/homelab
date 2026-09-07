# Household operations, including Jellyfin

The [shared operations output](../kubernetes/operations.nix) derives retained-path,
runtime-secret-name and route inventories from the evaluated host/cluster leaves.
It contains production-architecture commands and remaining bootstrap/recovery gates,
without building Linux render closures just to read guidance on Darwin:

```sh
# FLAKE is the approved immutable source reference.
GUIDE=$(nix build --no-link --print-out-paths "$FLAKE#household-operations")
cat "$GUIDE"
```

Guest OS delivery remains separate from application delivery. Nixidy renders the
selected release; static fresh-cluster bootstrap uses no live Git and does not
prune, then Argo owns normal reconciliation. Read the selected bootstrap bundle's
`operations.txt` for native uncompressed identity-image import **before Jobs**;
read `household-recovery --help` for quiesced export/restore and explicit resume.
Do not substitute manual scale/copy operations or environment-wide pruning.

Native Kanidm recovery-account setup and Jellyfin's first owner require explicit
first-run steps; replacement reuses their retained state, not another setup.
Runtime credentials stay in the agenix/rekey flow, never manifests or Nix strings.
Nix owns declared service connections and settings; application-owned users,
history and content must survive reconciliation.

The generated output describes declarations, not full platform acceptance or
permission to operate production. Local Linux, native Darwin, physical hardware,
real providers, off-host backup and client/identity failover need distinct evidence.
Production access, credentials, deployment and DNS changes remain separately gated.
See [canonical identity and ingress](../../../../docs/architecture/decisions/0003-independent-ingress-and-canonical-identity.md)
and [declarative application ownership](../../../../docs/architecture/decisions/0004-declarative-application-configuration.md)
for rationale; active OpenSpec changes do not replace current contracts.
