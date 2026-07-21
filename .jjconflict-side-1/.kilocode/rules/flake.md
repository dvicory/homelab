# flake.md

Guidelines for managing flake inputs and module structure in this repository.

## Guidelines

- Never modify `flake.nix` directly. It is auto-generated from the `flake-file` system:

> flake-file lets you make your `flake.nix` dynamic and modular. Instead of maintaining a single, monolithic `flake.nix`, you define your flake inputs in separate modules _close_ to where their inputs are used. flake-file then automatically generates a clean, up-to-date `flake.nix` for you.
>
> - Keep your flake modular: Manage flake inputs just like the rest of your Nix configuration.
> - Automatic updates: Regenerate your `flake.nix` with a single command (`nix run .#write-flake`) whenever your options change.
> - Flake as dependency manifest: Use `flake.nix` only for declaring dependencies, not for complex Nix code.

- All nix files inside the `modules` directory are recursively imported using `import-tree` and output automatically.

- Files with `_` anywhere in their path are ignored by `import-tree`. Use this for hardware configs or files that should not be auto-imported.

- All files in `modules/` must be valid flake-parts modules. Regular NixOS modules should be placed in `_` prefixed directories (or outside of `modules/`) and imported manually.

- Arguments like `pkgs` must be declared at the module function level, not at the flake-parts module level. Use `{ ... }: { flake.modules.nixos.aspect = { pkgs, ... }: { ... }; }` not `{ pkgs, ... }: { flake.modules.nixos.aspect = { ... }; }`.

- New files must be added to git before Nix can see them in flake evaluations. Use `git mv` if renaming/moving files.

- Import paths in dendritic modules are relative to the file location, not the flake root.
