The role of this file is to describe common mistakes and confusion points that agents might encounter as they work in this project. If you ever encounter something in the project that surprises you, please alert the developer working with you and indicate that this is the case in the AGENTS.md file to help prevent future agents from having the same issue.

## Repository hygiene

- **Do not start tracking Markdown planning artifacts by default.** Newly created `.md` files used for plans, reviews, handoffs, status tracking, acceptance prompts, or working notes must remain local and untracked unless the developer explicitly asks to start tracking or commit them. Markdown files already tracked by Git may be edited and committed normally. Do not infer permission to `git add` a new tracking document merely because the task requested that it be written.

## Nix gotchas

- **macOS `patch` (BSD) and `git apply` behave differently from nixpkgs' GNU `patch`.** `applyPatches` uses GNU patch with fuzz and offset search, so hunks that `git apply` rejects (zero-fuzz, exact context) or BSD patch rejects (weaker offset handling) can still apply in the Nix build. Never hand-author unified-diff hunk headers: materialize the exact source after all earlier patches, edit that scratch tree, and generate the patch with `git diff --no-index` or `diff -u`; hand-counted ranges easily produce a syntactically malformed patch before context matching begins. Always verify with a real `applyPatches` build; a `.rej` locally does not mean the build fails, and a clean local apply does not prove the hunk matches upstream context.

- **The Hermes Python venv fails to build on aarch64-darwin inside the Nix sandbox.** `python3.12-av`'s `pythonImportsCheckPhase` gets SIGKILLed loading ffmpeg dylibs in the sandbox. Run checks locally with `nix flake check --option sandbox false`; Linux builders are unaffected.

- **Helper files under `modules/` must be `_`-prefixed.** `import-tree` treats every `.nix` file as a flake-parts module in one namespace; plain function libraries (e.g. `secrets/_generators.nix`, `secure-terminal/_network-dsl.nix`) are skipped only when underscore-prefixed. Import them from the consuming module with `import ./_file.nix`.

- **`nix flake lock` rewrites node numbering across the lockfile.** Adding one input renumbers shared transitive nodes (nixpkgs_N) and looks like a mass update; verify with a node-content multiset diff instead of `git diff` noise. Scope with `nix flake lock --update-input <name>` when possible.

- **Evaluating a whole NixOS module submodule attrset can force unset optional fields.** For example, `nix eval --json ...config.systemd.sockets` can fail on an undefined `startLimitBurst` even though the host configuration and individual socket attributes evaluate. Query the exact leaf attribute needed instead of forcing the entire `systemd.services` or `systemd.sockets` subtree.

- **New files must be `git add`-ed before Nix can see them.** Nix resolves the source tree from git-tracked files. A `nix run .#write-flake` on an unstageed file produces "path does not exist" errors with store paths.

- **The root `.gitignore` pattern `result-*` matches files at any depth.** Avoid names such as `result-schema.json` for Nix package sources, or explicitly account for the ignore; otherwise the file exists locally but is omitted from the flake source.

- **`imports` inside `lib.mkIf` is processed as config data, not as module imports.** Module imports at the NixOS module level (`nixos = { ... }: { ... }`) must be top-level attributes, not inside `mkIf`. If you put `imports = [...]` inside `lib.mkIf`, the imported module's options never get declared — you'll get "The option `X' does not exist" errors even though the condition is true.

- **`config.<key> = value` shorthand conflicts with `config = lib.mkMerge [...]`.** If you use the shorthand `config.someOption = value` at the NixOS module top level, you can't also have `config = lib.mkMerge [...]` in the same module. Keep everything inside `mkMerge`.

- **Pipe operators (`|>`) require `--extra-experimental-features pipe-operators`.** The `nix run .#write-flake` evaluation context only has `nix-command flakes` enabled, not `pipe-operators`. Use traditional function composition or let-bindings in files that participate in flake evaluation.

- **Standalone homes force declared secret paths when their Quadlet configuration is evaluated.** A profile that references `osConfig.age.secrets.<name>.path` must have a matching `secretRequests` entry. If that request is conditional on the encrypted `.age` file existing, add the secret before evaluating the profile's full Quadlet configuration; otherwise Nix reports the secret attribute as missing.

- **`Network=container:<name>` does not establish a systemd dependency.** It only tells Podman which already-running network namespace to join. A dependent Quadlet must also set `unitConfig.Requires` and `unitConfig.After` to `<name>.container`, so Quadlet translates the dependency to the generated service units.

- **hvn-hyp1 still includes the legacy `services.hermes` nspawn aspect.** Its `hermes-env.age` secret also remains present. Do not assume the rootless QA/prod Quadlets replaced it until that aspect and secret are explicitly removed during the cutover.

- **Indented Nix string heredocs preserve indentation.** Do not create an executable helper by putting its shebang in an indented shell heredoc; the leading spaces break shebang recognition. Prefer `pkgs.writeShellScript` for executable helpers.

- **Hermes' top-level `toolsets` config key is deprecated and ignored.** Configure ordinary CLI/gateway surfaces through `platform_toolsets.<platform>`. Dispatcher-spawned Kanban workers receive their task-scoped Kanban tools from `HERMES_KANBAN_TASK`, but a normal Telegram session needs `kanban` in `platform_toolsets.telegram` before it can orchestrate with `kanban_create`.

- **The pinned Hermes SSH file-sync implementation does not match its documentation.** The docs describe `terminal.file_sync_enabled`, `terminal.file_sync_max_mb`, and writeback under `~/.hermes/cache/remote-syncs/<session-id>`, but the pinned Python code does not read those settings or create that destination. `SSHEnvironment` uploads credentials/skills/caches and, on cleanup, applies changed and newly inferred non-credential skill/cache files directly back to gateway paths with remote-wins conflict handling. Do not use stock SSH sync as a hostile-code boundary; disable or patch it and use explicit quarantined artifact export.

- **The Hermes flake does not publish every system enumerated by this flake.** In particular, the pinned Hermes release has no `x86_64-darwin` package. Gate portable checks with `builtins.hasAttr system inputs.hermes-agent.packages` instead of selecting the package unconditionally or hard-coding a single supported system.

- **A root-owned Git checkout cannot be used as an inferred flake by another user.** Nix/libgit2 rejects `git+file:` sources whose repository owner differs from the current user. The Hermes deployer therefore materializes a user-owned release checkout before Home Manager switches it; do not substitute a bare root-owned checkout. This also preserves `inputs.self.shortRev`, which a `path:` flake reference may not provide.

- **`set -e` does not protect commands inside a function called by `if ! function`.** Bash disables errexit in that context. Deployment functions must explicitly use `command || return 1` for every critical command so failed activation cannot continue to a canary against the old workload.

- **Do not enable `users.users.<name>.autoSubUidGidRange` for registry users.** The user enrichment aspect already derives deterministic subordinate UID/GID ranges from the registry UID. Enabling NixOS auto-allocation conflicts with `deterministic-uids.nix` and produces failed assertions for those users.

- **A shared Git metadata directory may locally exclude top-level Hermes roadmap documents even when `.gitignore` does not.** Use `git check-ignore -v --no-index <path>` to identify the source when `git add` reports one ignored; force-add only when the document is intentionally being placed under version control.

## Den framework patterns

- **Per-host metadata lives on `den.hosts.<name>` as entity data, not as NixOS options.** Use `den.schema.host` to type it. Parametric aspects (`{ host, ... }`) in `includes` or `den.schema.host.includes` receive the full entity context including schema options. This replaces the old pattern of "data carrier" NixOS options.

- **`den.schema.host.includes` auto-applies aspects to all hosts.** Profiles like time and networking that should apply everywhere belong here instead of being listed in each host's `includes`.

- **`den.batteries.forward` can't access NixOS config values.** The forwarder evaluates before the NixOS module system, so `config.services.chrony.directory` etc. are not available in `intoPath` or `guard`. For routing that depends on dynamic NixOS values, use a plain NixOS option instead.

- **`provides` means "optional selectable sub-aspect," not "provider."** A `provides.bouncer` sub-aspect on crowdsec means "an optional bouncer add-on that depends on the parent aspect." The parent itself is not a `provides`.

- **`den.schema.host` runs outside the NixOS module system.** Schema option defaults can only depend on `host.name` and `host.system`, not on NixOS config values.

- **Reference den docs before guessing.** The local `~/src/den/` directory has README.md and CLAUDE.md. Online: https://den.denful.dev/overview and https://deepwiki.com/denful/den. Use `~/src/den-examples/sini` as the reference example implementation of a den configuration from sini.

- **Reusable user aspects must be parametric and return a scope-unique `name`.** Pointing multiple registry users at the same static aspect can collapse their host contributions under one aspect identity. Follow the `userEnrich` pattern: accept `{ user, ... }` and return a name containing `user.userName`.

- **Do not use optional parametric arguments to make one aspect serve unrelated scope contexts.** Den only binds context arguments advertised for the active scope; an aspect attempting to branch on optional `user` versus `account` arguments can resolve empty. Use small context-specific adapter aspects backed by shared helpers instead.

## Flake input management

- **Regenerate flake with `nix run .#write-flake --impure`** after changing `modules/meta/inputs.nix` or any other file that declares `flake-file.inputs`.

## denful/den migration patterns (this repo specifically)

- The migration replaced a custom Host Inventory DSL + `self.modules.nixos.*` registry with den's native host entities and aspects.
- Host-specific NixOS config (SOPS paths, kernel params, filesystem mounts) stays inline in `den.aspects.<name>.nixos` blocks.
- Profile config that needs per-host data (ZFS pools, network interfaces) reads it from `host.zfs.*` / `host.networking.*` in a parametric aspect.
- Aspects emit `persist = [...]` / `cache = [...]` quirk data via `den.quirks.persist` (defined in `modules/den/quirks/impermanence.nix`). The `persist-collector` aspect (`modules/den/aspects/core/persist-collector.nix`) reads the quirk data and merges into `environment.persistence`.
