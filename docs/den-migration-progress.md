# Den Migration Progress

Tracking implementation of `docs/den-migration-v6.md`.

| Phase | Status | Date | Notes |
|-------|--------|------|-------|
| 0.1: Parametric Nix Aspect | completed | 2026-05-24 | |
| 0.2: Missing base packages + vim | completed | 2026-05-24 | |
| 0.3: Chrony persist fix | completed | 2026-05-24 | |
| 0.4: Initrd extraBin | completed | 2026-05-24 | |
| 0.5: MergerFS wiring | completed | 2026-05-24 | Converted to den-native aspect |
| 1: Parametric Users | completed | 2026-05-25 | Companion fns in den.default.includes |
| 2: Settings on Aspects | pending | | |
| 3: Quirks | pending | | |
| 4: Rename & Reorganize | pending | | |
| 5: Group-Based Users | pending | | |
| 6: Fork-Gated | blocked | | |

## Key discoveries

### Phase 0
- Mergerfs: flake modules imported via `imports` don't work for den hosts because `nix/den.nix` only passes `host.mainModule` to `nixosSystem`. Converted to `den.aspects.services.mergerfs`.
- SSH host keys: `hostKeys = lib.mkForce []` was in `den.default.nixos` (applies to all hosts). Moved to impermanence aspect.

### Phase 1
- `den.schema.host.users` already declared by den's core (host.nix:47). User fields go on `den.schema.user`.
- Entity context cannot access NixOS-level `config.sops.secrets`. SOPS paths must be hardcoded (`/run/secrets/users/<name>/hashedPassword`).
- Bare functions in `den.default.includes` with `{ host, user }` args work for per-user NixOS contributions.
- `den.schema.host.includes` and `den.schema.user.includes` bare functions did NOT contribute nixos bodies on this den version.
- `lib.mkMerge` cannot be used as a direct `nixos` body return value in bare functions — must use direct attrsets.
- Duplicate dynamic attr error when using `users.users.${name}.field1` + `users.users.${name}.field2` in same attrset — use submodule syntax.
