# Phase 3 Addendum: Quirks & Custom Classes

`docs/den-migration-v6.md` classifies Phase 3 quirk features as "Core den."
Implementation testing revealed these features require the den fork after all.

## Findings

### Quirk Pipes

`den.quirks.persist.description = "..."` registers in `den.quirks` (verified via class-quirk overlap assertion), and the `pipeRegistry = den.quirks or { }` in `key-classification.nix` sees it. However, the pipe collection and data assembly (`assemble-pipes.nix`) does not flow on `denful/den` main at the tested commit (`0b250e1`).

When an aspect emits `persist = [...]` as a top-level key, the key classifier marks it as `unregisteredClassKeys` (line 19 in `classify.nix`), which gets merged into `classKeys`. Den then tries to load `persist` as a NixOS class module — producing `"The option `persist' does not exist"`.

### `den.batteries.forward`

The `forward` battery provides infrastructure for custom classes (`forward.nix` reads `den.classes` for pre-existing class registrations) but does **not** register the `fromClass` name in `den.classes` on this den version. The key classifier therefore does not recognize the custom class, and forwarded keys fall through to the NixOS module system as unregistered options.

The `custom-classes.mdx` den docs example creates a `persys` forward class that works on the fork (`sini/den/feat/entity-gen-schema-port`).

### What works

The existing `persist.directories` NixOS option (declared in `den.default.nixos.options`) functions as the collection mechanism. Aspects emit `persist.directories = [...]` directly, and the impermanence aspect reads `config.persist.directories`.

## Action after fork merge

When switching to `sini/den/feat/entity-gen-schema-port` (or when these features land in main):

1. **Quirk pipes**: Declare `den.quirks.persist` / `den.quirks.cache` / `den.quirks.firewall`, update aspects to emit `persist = [...]` / `cache = [...]` / `firewall = [...]`, wire collectors.
2. **`den.batteries.forward` for persist**: Create `persistForward` and `cacheForward` classes, add to `den.schema.host.includes`, guard on `options ? environment.persistence`. Remove `persist.directories` NixOS option.
3. **Firewall collector**: Replace `networking.firewall.allowedTCPPorts` with quirk-based `firewall = [...]` collection.
