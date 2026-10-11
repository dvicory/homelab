# Runs the packaged prepare-luks-storage end to end on disposable QEMU SCSI
# disks with the real storage tools. The sandboxed prepare-luks-storage check
# keeps the refusal scenarios with fake block probes and format mutators; this
# VM proves that every production call of those tools works with the real
# binaries. See prepare-luks-storage-runtime.sh.
{ lib, ... }:
{
  perSystem =
    {
      config,
      pkgs,
      system,
      ...
    }:
    let
      package = config.packages.prepare-luks-storage;
      script = "${package}/bin/prepare-luks-storage";
      # Block probes, partitioning, LUKS, measurements and transfer.
      tracedTools = [
        "lsblk"
        "findmnt"
        "wipefs"
        "udevadm"
        "sgdisk"
        "cryptsetup"
        "stat"
        "du"
        "df"
        "readlink"
        "rsync"
      ];
      # One JSON object per simple command in the packaged script whose name
      # is a traced tool, from shfmt's syntax tree rather than a text search:
      # its line, enclosing function and leading literal arguments. A call is
      # matched to its site by function, tool and those arguments, because
      # bash reports the function's first line for calls in a process
      # substitution.
      callSites =
        pkgs.runCommand "prepare-luks-storage-call-sites"
          {
            nativeBuildInputs = [
              pkgs.shfmt
              pkgs.python3
            ];
            tools = lib.concatStringsSep " " tracedTools;
          }
          ''
            shfmt --to-json < ${script} > ast.json
            python3 - ast.json $tools > "$out" <<'PY'
            import json
            import sys

            tools = set(sys.argv[2:])
            sites = []

            def literal(word):
                value = ""
                for part in word.get("Parts", []):
                    if part["Type"] in ("Lit", "SglQuoted"):
                        value += part["Value"]
                    elif part["Type"] == "DblQuoted" and all(p["Type"] == "Lit" for p in part.get("Parts", [])):
                        value += "".join(p["Value"] for p in part.get("Parts", []))
                    else:
                        return None
                return value

            def walk(node, function):
                if isinstance(node, dict):
                    if node.get("Type") == "FuncDecl":
                        function = node["Name"]["Value"]
                    args = node.get("Args") if node.get("Type") == "CallExpr" else None
                    if args and literal(args[0]) in tools:
                        prefix = []
                        for word in args[1:]:
                            value = literal(word)
                            if value is None:
                                break
                            prefix.append(value)
                        sites.append({
                            "line": args[0]["Pos"]["Line"],
                            "function": function,
                            "tool": literal(args[0]),
                            "prefix": prefix,
                        })
                    for value in node.values():
                        walk(value, function)
                elif isinstance(node, list):
                    for value in node:
                        walk(value, function)

            with open(sys.argv[1]) as handle:
                walk(json.load(handle), "main")
            missing = sorted(tools - {site["tool"] for site in sites})
            if missing:
                raise SystemExit(f"no call of {missing} found in the packaged script; update tracedTools")
            for a in sites:
                for b in sites:
                    if a is not b and (a["function"], a["tool"]) == (b["function"], b["tool"]) \
                            and b["prefix"][:len(a["prefix"])] == a["prefix"]:
                        raise SystemExit(f"call sites at lines {a['line']} and {b['line']} are indistinguishable")
            for site in sorted(sites, key=lambda s: s["line"]):
                print(json.dumps(site))
            PY
          '';
      test = pkgs.testers.runNixOSTest {
        name = "prepare-luks-storage-runtime";
        requiredFeatures.kvm = true;
        nodes.machine =
          { pkgs, ... }:
          {
            system.stateVersion = "26.05";
            virtualisation = {
              memorySize = 2048;
              # SCSI disks report a serial and, when set, a WWN, as the
              # production SATA/SAS data disks do.
              qemu.diskInterface = "scsi";
              emptyDiskImages = [
                {
                  # Sparse; covers a small source plus the tool's 10 GiB headroom.
                  size = 12288;
                  driveConfig.deviceExtraOpts = {
                    serial = "PR44TARGETA";
                    wwn = "0x5000c500000a0001";
                  };
                }
                {
                  size = 64;
                  driveConfig.deviceExtraOpts.serial = "PR44NOWWNB";
                }
                {
                  size = 64;
                  driveConfig.deviceExtraOpts = {
                    serial = "PR44WHOLEC";
                    wwn = "0x5000c500000c0003";
                  };
                }
              ];
            };
            environment.systemPackages = [
              pkgs.cryptsetup
              pkgs.python3
              pkgs.util-linux
              pkgs.xfsprogs
            ];
          };
        testScript = ''
          start_all()
          machine.wait_for_unit("multi-user.target")
          machine.succeed(
              "PREPARE_LUKS_STORAGE=${script} "
              "CALL_SITES=${callSites} "
              "TRACED_TOOLS='${lib.concatStringsSep " " tracedTools}' "
              "bash ${./prepare-luks-storage-runtime.sh} >&2"
          )
        '';
      };
    in
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        prepare-luks-storage-runtime = test // {
          meta = test.meta // {
            hestia.group = "${system}-prepare-luks-storage-runtime";
          };
        };
      };
    };
}
