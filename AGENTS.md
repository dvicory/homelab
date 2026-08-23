homelab is a declarative NixOS and Den fleet configuration. Prefer explicit, boring, inspectable modules and changes.

Follow the plain-language principles of ISO 24495-1:2023: give readers the information they need and make it easy to find, understand, and use. Favor Zinsser-style clarity: concrete words, direct sentences, active constructions when natural, and no needless clutter. Preserve technical precision; do not simplify away necessary distinctions.

## Authority and OpenSpec

Current `openspec/specs/*/spec.md` requirements own only the durable Homelab contracts they explicitly state. Nix/Den configuration owns the concrete desired fleet state and implementation details not constrained by those contracts.

Active OpenSpec changes describe proposed target contracts. While a change is being implemented, its delta specs guide that work, but current specs remain canonical until the completed and verified change is synced. Proposals, designs, and tasks are planning artifacts rather than current contract authority.

Generated documentation is derived from evaluated configuration and is not a source of authority. Historical or exploratory material and external repositories may inform decisions but do not establish current Homelab contracts. When sources disagree or current behavior appears accidental, surface the ambiguity instead of silently turning supporting material into policy.

## Den and repository structure

Keep host metadata in Den entities and schemas, and behavior in aspects. `den.schema.host.includes` applies shared profiles globally. Schema defaults run outside NixOS module evaluation, so derive them from entity data only.

Treat `provides` as a selectable sub-aspect, not a provider. Reusable parametric user aspects must have scope-unique names.

Aspects report persistence and cache paths through `den.quirks.persist`; the `persist-collector` aspect consumes those declarations.

Keep secrets in the existing agenix and agenix-rekey flow. Standalone profiles that reference `osConfig.age.secrets.*.path` must declare matching `secretRequests`.

For independently developed applications, keep Homelab work focused on the system-facing integration owned here. Consult `management-boundaries` before moving application-internal behavior into this repository.

## Nix

- Never modify `flake.nix` directly. It is auto-generated from the `flake-file` system. Declare inputs in the module closest to where they are used with `flake-file.inputs = { some-package.url = "github:user/repo"; };`, then run `nix run .#write-flake` to update `flake.nix`.
- Helper libraries under `modules/` can be `_`-prefixed so `import-tree` does not load them as modules.
- Keep module `imports` at module scope, not inside `lib.mkIf`.
- Do not mix `config.foo = ...` shorthand with a separate `config = lib.mkMerge [...]` definition.
- Scope lockfile updates with `nix flake lock --update-input <name>` when possible.
