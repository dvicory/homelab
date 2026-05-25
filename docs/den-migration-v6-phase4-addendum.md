# Phase 4 Addendum: Aspect Name Notation

## Context

After the Phase 4 file reorganization, aspect names were updated from
`den.aspects."dlab/profile/disks"` to `den.aspects.disk.zfs` (dot notation),
matching the style used by sini and den's own templates.

## Symptom

```
error: hasAspect: ref must have both `name` and `meta` (got set).
```

Occurs when `host.hasAspect den.aspects.disk.zfs` is called from within a
parametric aspect wrapper `{ host, ... }: { nixos = ...; }`.

Happens with dot notation (`den.aspects.disk.zfs`). Does NOT happen with slash
notation (`den.aspects."disk/zfs"`).

## What works

- `nix flake check` passes with `den.aspects."disk/zfs"` (slash notation)
- A fresh test with `den.aspects.testns.testaspect` (dot, non-self-referencing)
  passes all hasAspect checks
- Upstream den CI tests (`templates/ci/modules/features/has-aspect.nix`) use
  dot notation for single-word names (`den.aspects.feature`,
  `den.aspects.child`) and pass on `denful/den` main
- Sini uses `den.aspects.disk.impermanence` (dot, multi-word) and works on the
  fork (`sini/den/feat/entity-gen-schema-port`)

## What fails

- `host.hasAspect den.aspects.disk.zfs` called from within the parametric
  wrapper of `den.aspects.disk.zfs` itself (self-referencing hasAspect with a
  multi-word dot-notation name)
- Also fails when called from a different aspect's nixos body
  (`den.aspects.disk.impermanence` calling
  `host.hasAspect den.aspects.disk.zfs`)

## Relevant den source

`has-aspect.nix:9-12` validates the aspect reference:

```nix
if (ref ? name) && (ref ? meta) then
  pathKey (aspectPath ref)
else
  throw "hasAspect: ref must have both `name` and `meta` (got ${builtins.typeOf ref}).";
```

`modules/options.nix` declares aspect type as `lazyAttrsOf`:

```nix
options.den.aspects = lib.mkOption {
  type = lib.types.lazyAttrsOf aspectType;
};
```

## Questions for adversarial review

1. Why does `den.aspects.disk.zfs` resolve to a value without `name` and `meta`
   when accessed from a NixOS-class module body (nixos = { ... }), but
   `den.aspects."disk/zfs"` does?
2. Is this a `lazyAttrsOf` evaluation timing issue, a nested-key vs flat-key
   resolution difference, or something else?
3. Upstream tests only cover single-word dot-notation names
   (`den.aspects.feature`). Does `lazyAttrsOf` handle multi-word dotted names
   (`den.aspects.disk.zfs`) the same as flat slash-separated names
   (`den.aspects."disk/zfs"`)?
4. Given that sini works with `den.aspects.disk.impermanence`, what change
   (between `denful/den` main and `sini/den` fork) enables multi-word dot
   notation?
