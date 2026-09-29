# Generates docs/storage.md from the evaluated Den storage declarations:
# LUKS data disks, mergerfs pools, and managed storage roots per host.
# Regenerate with `nix run .#write-files`; `nix run .#diff-files` reports
# drift.
{
  config,
  lib,
  ...
}:
let
  hosts = lib.concatLists (
    lib.mapAttrsToList (
      _system: byName: lib.mapAttrsToList (hostName: host: { inherit hostName host; }) byName
    ) config.den.hosts
  );

  hasData =
    entry:
    (entry.host.settings.disk.luks-storage.disks or { }) != { }
    || (entry.host.settings.services.mergerfs.pools or { }) != { }
    || (entry.host.settings.services.storage-roots.roots or { }) != { };

  diskSection =
    host:
    let
      disks = host.settings.disk.luks-storage.disks or { };
      rows = lib.mapAttrsToList (
        name: disk:
        lib.concatStringsSep " | " [
          "| `${name}`"
          "`${disk.device}`"
          "`${disk.mapperName}`"
          "`${disk.mountpoint}`"
          "`${disk.fsType}`"
          (if disk.discard then "yes" else "no")
          "${if disk.provisioned then "yes" else "no"} |"
        ]
      ) disks;
    in
    lib.optionalString (disks != { }) ''
      ### LUKS data disks

      | Disk | Declared device | Mapper | Mountpoint | Filesystem | Discard | Provisioned |
      | --- | --- | --- | --- | --- | --- | --- |
      ${lib.concatStringsSep "\n" rows}

      `Provisioned = no` declares only the wrapper and the agenix key path.
      `yes` adds the crypttab row and the direct mount. Neither value proves
      physical work ran.
    '';

  poolSection =
    host:
    let
      pools = host.settings.services.mergerfs.pools or { };
      poolBlock =
        poolPath: pool:
        let
          rows = lib.imap0 (
            i: branch:
            lib.concatStringsSep " | " [
              "| ${toString (i + 1)}"
              "`${branch.path}`"
              "${if branch.create then "yes" else "no"}"
              "${if branch.required then "yes" else "no"}"
              "${
                if branch.unit != null then
                  "`${branch.unit}`"
                else if branch.fileSystemMount or false then
                  "the `fileSystems` mount of this path"
                else
                  "none"
              } |"
            ]
          ) pool.branches;
        in
        ''
          Pool `${poolPath}`:

          | # | Branch | Create | Required | Mount unit |
          | --- | --- | --- | --- | --- |
          ${lib.concatStringsSep "\n" rows}
        '';
    in
    lib.optionalString (pools != { }) ''
      ### mergerfs pools

      Branches are listed in declaration order. `Create = no` keeps existing
      content readable but excludes the branch from new writes.
      `Required = yes` makes an unmounted branch refuse the whole pool; the
      pool unit binds to each required branch's mount unit.

      ${lib.concatStringsSep "\n" (lib.mapAttrsToList poolBlock pools)}
    '';

  rootSection =
    host:
    let
      roots = host.settings.services.storage-roots.roots or { };
      rows = lib.mapAttrsToList (
        _name: root:
        lib.concatStringsSep " | " [
          "| `${root.path}`"
          "`${root.user}`"
          "`${root.group}`"
          "`${root.mode}`"
          "${
            if root.access == [ ] then
              "none"
            else
              "`" + lib.concatMapStringsSep "`, `" (entry: "${entry.group}:${entry.access}") root.access + "`"
          } |"
        ]
      ) roots;
    in
    lib.optionalString (roots != { }) ''
      ### Managed storage roots

      | Root | Owner | Group | Mode | Default access |
      | --- | --- | --- | --- | --- |
      ${lib.concatStringsSep "\n" rows}

      `Default access` lists the ACL entries a root declares so content
      created inside inherits them; `none` means the root declares owner,
      group, and mode only. Activation never rewrites ownership, modes, or
      access entries of existing content.
    '';

  hostSection =
    { hostName, host }:
    ''
      ## `${hostName}`

      ${diskSection host}
      ${poolSection host}
      ${rootSection host}
    '';

  hostSections = lib.concatMapStringsSep "\n" hostSection (builtins.filter hasData hosts);
in
{
  perSystem =
    { ... }:
    {
      files.file."docs/storage.md".text = ''
        <!-- provenance: generated from evaluated Den/Nix declarations by modules/flake/docs/storage.nix; keep the committed copy in sync. -->
        # Storage

        The declared storage layout per host, generated from evaluated
        configuration. It is not a source of authority. The current storage
        contract is
        [`storage-foundations`](../openspec/specs/storage-foundations/spec.md).
        The placement rules are still a proposed change,
        [`storage-placement-contract`](../openspec/changes/storage-placement-contract/),
        and become current only when that change is archived. The reasoning
        behind the namespace and the device encryption lives in [ADR-0006](architecture/decisions/0006-stable-semantic-storage-namespace.md)
        and [ADR-0007](architecture/decisions/0007-block-level-encryption-for-data-disks.md);
        the disk conversion procedure is in
        [`docs/operations/luks-storage-migration.md`](operations/luks-storage-migration.md).

        ${hostSections}
      '';
    };
}
