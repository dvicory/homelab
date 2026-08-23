homelab is a declarative NixOS and Den fleet configuration. Prefer explicit, boring, inspectable modules and changes.

The repository is temporarily between canonical OpenSpec baselines. The legacy `openspec/specs/*/spec.md` files have been removed because they described a historical Den migration rather than the intended current contract. Until a replacement baseline is explicitly established, current Nix/Den configuration is the source of truth for configured fleet behavior.

Active OpenSpec changes may propose future contracts, but they do not become current merely because implementation has started. Historical, generated, and exploratory material is non-authoritative unless explicitly designated otherwise. When current behavior is ambiguous or appears accidental, surface the ambiguity instead of silently turning supporting material into policy.

Keep host metadata in Den entities and schemas, and behavior in aspects. `den.schema.host.includes` applies shared profiles globally. Schema defaults run outside NixOS module evaluation, so derive them from entity data only.

Treat `provides` as a selectable sub-aspect, not a provider. Reusable parametric user aspects must have scope-unique names.

Aspects report persistence and cache paths through `den.quirks.persist`; the `persist-collector` aspect consumes those declarations.

Keep secrets in the existing agenix and agenix-rekey flow. Standalone profiles that reference `osConfig.age.secrets.*.path` must declare matching `secretRequests`.

## Nix

- Never modify `flake.nix` directly. It is auto-generated from the `flake-file` system. Declare inputs in the module closest to where they are used with `flake-file.inputs = { some-package.url = "github:user/repo"; };`, then run `nix run .#write-flake` to update `flake.nix`.
- Helper libraries under `modules/` can be `_`-prefixed so `import-tree` does not load them as modules.
- Keep module `imports` at module scope, not inside `lib.mkIf`.
- Do not mix `config.foo = ...` shorthand with a separate `config = lib.mkMerge [...]` definition.
- Scope lockfile updates with `nix flake lock --update-input <name>` when possible.
