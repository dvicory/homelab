{
  den,
  lib,
  inputs,
  config,
  ...
}:
let
  inherit (lib) mkOption types;
  # The fleet group registry belongs to Den's configuration scope, not to the
  # resulting NixOS configuration, so it is captured here where the compute
  # aspect can resolve a declared capability name to its stable GID.
  fleetGroups = config.den.groups or { };
  idmap = import ./_idmap.nix { inherit lib; };
  requiredPathType = types.submodule {
    options = {
      uid = mkOption { type = types.ints.unsigned; };
      gid = mkOption { type = types.ints.unsigned; };
      mode = mkOption { type = types.str; };
      readOnly = mkOption {
        type = types.bool;
        default = false;
      };
    };
  };
  deviceType = types.submodule {
    freeformType = types.attrsOf types.anything;
    options.requiredPath = mkOption {
      type = types.nullOr requiredPathType;
      default = null;
      description = "Host ownership metadata for a required source-backed disk device.";
    };
  };
in
{
  den.aspects.virtualization.compute = {
    settings = {
      options = {
        project = mkOption {
          type = types.str;
          description = "Incus project owning the compute envelope.";
        };
        instance = mkOption {
          type = types.str;
          description = "Incus instance name for the replaceable guest.";
        };
        profile = mkOption {
          type = types.str;
          description = "Incus profile containing the guest envelope.";
        };
        pool = mkOption {
          type = types.str;
          description = "Incus storage pool for the guest root.";
        };
        network = mkOption {
          type = types.str;
          description = "Private Incus network for the guest NIC.";
        };
        address = mkOption {
          type = types.str;
          description = "Fixed DHCP address requested by the guest NIC.";
        };
        idmapBase = mkOption {
          type = types.ints.positive;
          description = "Fixed host UID/GID base reserved for the guest.";
        };
        idmapSize = mkOption {
          type = types.ints.positive;
          description = "Fixed UID/GID map size reserved for the guest.";
        };
        storageCapabilities = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Fleet group names whose stable POSIX GID crosses this compute
            boundary as an identity mapping, so a workload can hold the
            capability under the same number inside and outside the guest.

            Only capabilities that actually have to cross belong here. Each one
            becomes a hole in the guest's otherwise contiguous GID map and needs
            matching host subordinate-GID authorization and a project range that
            permits it; the guest's UID map and its other GIDs stay ordinary
            translated ones.
          '';
        };
        stateRoot = mkOption {
          type = types.str;
          description = "Host-owned parent for the selected services' retained state.";
        };
        retainedPaths = mkOption {
          type = types.attrsOf (
            types.submodule {
              options = {
                path = mkOption { type = types.str; };
                guestPath = mkOption { type = types.str; };
                uid = mkOption { type = types.ints.unsigned; };
                gid = mkOption { type = types.ints.unsigned; };
                mode = mkOption { type = types.str; };
                readOnly = mkOption {
                  type = types.bool;
                  default = false;
                };
              };
            }
          );
          description = "Retained host directories and their guest ownership and attachment boundary.";
        };
        identityPath = mkOption {
          type = types.str;
          description = "Persistent guest identity directory on the host.";
        };
        config = mkOption {
          type = types.attrsOf types.str;
          description = "Complete desired Incus instance configuration.";
        };
        devices = mkOption {
          type = types.attrsOf deviceType;
          description = "Complete desired Incus instance device map.";
        };
      };
      config = { };
    };

    persist =
      { host, ... }:
      let
        cfg = host.settings.virtualization.compute;
      in
      [
        {
          directories = [ "/var/lib/incus-storage-pools/${cfg.pool}" ];
          user = "root";
          group = "root";
        }
        {
          directories = [ cfg.identityPath ];
          user = toString cfg.idmapBase;
          group = toString cfg.idmapBase;
          mode = "0700";
        }
      ]
      ++ lib.mapAttrsToList (_: entry: {
        directories = [ entry.path ];
        user = toString (cfg.idmapBase + entry.uid);
        group = toString (cfg.idmapBase + entry.gid);
        inherit (entry) mode;
      }) cfg.retainedPaths;

    nixos =
      {
        host,
        config,
        lib,
        pkgs,
        ...
      }:
      let
        cfg = host.settings.virtualization.compute;
        runtimeSecrets = cfg.runtimeSecrets or { };
        secretPath = "/run/homelab-compute/secrets";
        secretNames = builtins.attrNames runtimeSecrets;
        retainedNames = builtins.attrNames cfg.retainedPaths;
        reservedDeviceNames = [ "secrets" ];
        baseDeviceNames = builtins.attrNames cfg.devices;
        reservedCollisions = lib.filter (name: builtins.elem name baseDeviceNames) reservedDeviceNames;
        retainedCollisions = lib.filter (
          name: builtins.elem name (baseDeviceNames ++ reservedDeviceNames)
        ) retainedNames;
        invalidRetainedIds = lib.filter (
          name:
          let
            entry = cfg.retainedPaths.${name};
          in
          entry.uid >= cfg.idmapSize || entry.gid >= cfg.idmapSize
        ) retainedNames;

        # Crossing storage capabilities. A declared capability keeps its fleet
        # GID on both sides of the boundary: its number is mapped identically,
        # which turns the guest's ordinary contiguous GID shift into that range
        # minus one hole per capability. The host authorization, the project
        # range, and the map the lifecycle tool expects all derive from this one
        # set, so a capability cannot be half-declared.
        groupRegistry = fleetGroups;
        capabilityEntries = map (name: {
          inherit name;
          group = groupRegistry.${name} or null;
        }) cfg.storageCapabilities;
        unknownCapabilities = map (entry: entry.name) (
          builtins.filter (entry: entry.group == null) capabilityEntries
        );
        invalidCapabilities = map (entry: entry.name) (
          builtins.filter (
            entry:
            entry.group != null
            && (
              (entry.group.gid or null) == null
              || !(builtins.elem "posix" (entry.group.labels or [ ]))
              || entry.group.gid < 1
              || entry.group.gid >= cfg.idmapSize
            )
          ) capabilityEntries
        );
        capabilityGids = lib.sort builtins.lessThan (
          map (entry: entry.group.gid) (builtins.filter (entry: entry.group != null) capabilityEntries)
        );
        capabilityGidsUnique = capabilityGids == lib.unique capabilityGids;
        capabilityNamesUnique = cfg.storageCapabilities == lib.unique cfg.storageCapabilities;
        idmapPlan = idmap.plan {
          inherit (cfg) idmapBase idmapSize;
          inherit capabilityGids;
        };
        # An identity-mapped capability host ID must live outside the ordinary
        # host range, or the same host ID would be claimed twice.
        overlappingCapabilities = builtins.filter (
          hostId: hostId >= cfg.idmapBase && hostId < cfg.idmapBase + cfg.idmapSize
        ) idmapPlan.identityHostIds;
        capabilitySubGidRanges = builtins.filter (entry: entry != null) idmapPlan.subordinateGidRanges;
        instanceConfig =
          assert lib.assertMsg (unknownCapabilities == [ ])
            "Declared storage capabilities are not fleet groups: ${lib.concatStringsSep ", " unknownCapabilities}";
          assert lib.assertMsg (invalidCapabilities == [ ])
            "Storage capabilities must be POSIX groups with a GID between 1 and idmapSize: ${lib.concatStringsSep ", " invalidCapabilities}";
          assert lib.assertMsg capabilityNamesUnique "Storage capability names must be unique.";
          assert lib.assertMsg capabilityGidsUnique "Storage capabilities resolve to the same GID.";
          assert lib.assertMsg (overlappingCapabilities == [ ])
            "A capability host ID overlaps the ordinary subordinate range: ${lib.concatStringsSep ", " (map toString overlappingCapabilities)}";
          assert lib.assertMsg (
            !(cfg.config ? "raw.idmap")
          ) "raw.idmap is derived from storageCapabilities and must not be declared directly on the instance";
          cfg.config // { "raw.idmap" = idmapPlan.rawIdmap; };
        baseDevices = lib.mapAttrs (_: entry: removeAttrs entry [ "requiredPath" ]) cfg.devices;
        requiredDeviceEntries = lib.filterAttrs (
          _: entry:
          (entry.type or null) == "disk"
          && (entry.required or "false") == "true"
          && (entry.source or null) != null
          && (entry.source or null) != cfg.identityPath
        ) cfg.devices;
        missingRequiredPathMetadata = lib.attrNames (
          lib.filterAttrs (_: entry: (entry.requiredPath or null) == null) requiredDeviceEntries
        );
        deviceRequiredPaths = lib.mapAttrsToList (_: entry: {
          path = entry.source;
          inherit (entry.requiredPath)
            uid
            gid
            mode
            readOnly
            ;
        }) requiredDeviceEntries;
        deviceDiskPaths = lib.filter (path: path != null) (
          lib.mapAttrsToList (
            _: entry: if (entry.type or null) == "disk" then entry.source or null else null
          ) cfg.devices
        );
        devices =
          assert lib.assertMsg (
            reservedCollisions == [ ]
          ) "Incus device map uses reserved names: ${lib.concatStringsSep ", " reservedCollisions}";
          assert lib.assertMsg (
            retainedCollisions == [ ]
          ) "Retained paths collide with Incus device names: ${lib.concatStringsSep ", " retainedCollisions}";
          assert lib.assertMsg (
            invalidRetainedIds == [ ]
          ) "Retained path IDs must be below idmapSize: ${lib.concatStringsSep ", " invalidRetainedIds}";
          assert lib.assertMsg (missingRequiredPathMetadata == [ ])
            "Required source-backed disk devices need requiredPath metadata: ${lib.concatStringsSep ", " missingRequiredPathMetadata}";
          baseDevices
          // lib.mapAttrs (_: entry: {
            type = "disk";
            source = entry.path;
            path = entry.guestPath;
            propagation = "rprivate";
            readonly = lib.boolToString entry.readOnly;
            required = "true";
          }) cfg.retainedPaths
          // lib.optionalAttrs (secretNames != [ ]) {
            secrets = {
              type = "disk";
              source = secretPath;
              path = "/srv/secrets";
              readonly = "true";
              required = "true";
            };
          };
        projectConfig = {
          "features.images" = "true";
          "features.networks" = "false";
          restricted = "true";
          "restricted.containers.interception" = "block";
          "restricted.containers.lowlevel" = "block";
          # Incus classifies security.idmap.base/size as unrestricted low-level
          # config. A range-limited raw.idmap keeps raw LXC/AppArmor blocked.
          "restricted.idmap.uid" = idmapPlan.permittedHostUidRanges;
          "restricted.idmap.gid" = idmapPlan.permittedHostGidRanges;
          "restricted.containers.nesting" = "allow";
          "restricted.containers.privilege" = "unprivileged";
          "restricted.devices.disk" = "allow";
          "restricted.devices.disk.paths" = lib.concatStringsSep "," (
            lib.unique (
              map (entry: entry.path) (builtins.attrValues cfg.retainedPaths)
              ++ [ cfg.identityPath ]
              ++ deviceDiskPaths
              ++ lib.optional (secretNames != [ ]) secretPath
            )
          );
          "restricted.devices.gpu" = "block";
          "restricted.devices.infiniband" = "block";
          "restricted.devices.nic" = "managed";
          "restricted.devices.pci" = "block";
          "restricted.devices.proxy" = "block";
          "restricted.devices.unix-block" = "block";
          "restricted.devices.unix-char" = "block";
          "restricted.devices.unix-hotplug" = "block";
          "restricted.devices.usb" = "block";
          "restricted.networks.access" = cfg.network;
        };
        identityAge = inputs.self + "/.secrets/hosts/${cfg.instance}/runtime_host_key.age";
        identityPub = inputs.self + "/.secrets/hosts/${cfg.instance}/runtime_host_key.pub";
        hasIdentity = builtins.pathExists identityAge && builtins.pathExists identityPub;
        publicKey =
          if builtins.pathExists identityPub then lib.trim (builtins.readFile identityPub) else null;
        publicKeyFile = pkgs.writeText "${cfg.instance}-public-key" (
          if publicKey == null then "" else publicKey
        );
        poolPath = "/var/lib/incus-storage-pools/${cfg.pool}";
        networkConfig = {
          "ipv4.address" = "10.210.0.1/24";
          "ipv4.dhcp" = "true";
          "ipv4.dhcp.ranges" = "${cfg.address}-${cfg.address}";
          "ipv4.nat" = "true";
          "ipv6.address" = "none";
        };
        preseed = {
          projects = [
            {
              name = cfg.project;
              config = projectConfig;
            }
          ];
          storage_pools = [
            {
              name = cfg.pool;
              driver = "dir";
              config.source = poolPath;
            }
          ];
          networks = [
            {
              # Incus managed bridges live in the default network project.
              project = "default";
              name = cfg.network;
              type = "bridge";
              config = networkConfig;
            }
          ];
          profiles = [
            {
              project = cfg.project;
              name = cfg.profile;
              description = "Unprivileged private compute envelope";
              config = instanceConfig;
              inherit devices;
            }
          ];
        };
        preseedFile = pkgs.writeText "compute-incus-preseed.json" (builtins.toJSON preseed);
        preseedGate = pkgs.writeShellScript "compute-incus-preseed-gate" ''
          set -eu
          export INCUS_SOCKET=/var/lib/incus/unix.socket
          incus=${config.virtualisation.incus.package}/bin/incus
          jq=${pkgs.jq}/bin/jq
          desired=${lib.escapeShellArg preseedFile}
          missing=0
          project_exists=0

          conflict() {
            echo "compute Incus preseed conflict: $1" >&2
            exit 1
          }

          query() {
            "$incus" --force-local query "$1"
          }

          check_project() {
            wanted=$("$jq" -c '.projects[0]' "$desired")
            name=$(printf '%s\n' "$wanted" | "$jq" -r '.name')
            project="$name"
            current=$(query "/1.0/projects?recursion=1")
            actual=$(printf '%s\n' "$current" |
              "$jq" -c --arg name "$name" '[.[] | select(.name == $name)] | .[0] // empty')
            if [ -z "$actual" ]; then
              missing=1
              return
            fi
            if ! "$jq" -n -e --argjson wanted "$wanted" --argjson actual "$actual" '
              all($wanted.config | to_entries[]; $actual.config[.key] == .value)
            ' >/dev/null; then
              conflict "project/$name"
            fi
            project_exists=1
          }

          check_pool() {
            wanted=$("$jq" -c '.storage_pools[0]' "$desired")
            name=$(printf '%s\n' "$wanted" | "$jq" -r '.name')
            current=$(query "/1.0/storage-pools?recursion=1")
            actual=$(printf '%s\n' "$current" |
              "$jq" -c --arg name "$name" '[.[] | select(.name == $name)] | .[0] // empty')
            if [ -z "$actual" ]; then
              missing=1
              return
            fi
            if ! "$jq" -n -e --argjson wanted "$wanted" --argjson actual "$actual" '
              $actual.driver == $wanted.driver
              and $actual.config.source == $wanted.config.source
            ' >/dev/null; then
              conflict "storage-pool/$name"
            fi
          }

          check_network() {
            wanted=$("$jq" -c '.networks[0]' "$desired")
            name=$(printf '%s\n' "$wanted" | "$jq" -r '.name')
            current=$(query "/1.0/networks?recursion=1&project=default")
            actual=$(printf '%s\n' "$current" |
              "$jq" -c --arg name "$name" '[.[] | select(.name == $name)] | .[0] // empty')
            if [ -z "$actual" ]; then
              missing=1
              return
            fi
            if ! "$jq" -n -e --argjson wanted "$wanted" --argjson actual "$actual" '
              $actual.type == $wanted.type
              and (($actual.config // {}) | with_entries(
                select(.key != "bridge.hwaddr" and ((.key | startswith("volatile.")) | not))
              )) == ($wanted.config // {})
            ' >/dev/null; then
              conflict "network/default/$name"
            fi
          }

          check_profile() {
            wanted=$("$jq" -c '.profiles[0]' "$desired")
            name=$(printf '%s\n' "$wanted" | "$jq" -r '.name')
            if [ "$project_exists" -eq 0 ]; then
              missing=1
              return
            fi
            project_query=$("$jq" -nr --arg project "$project" '$project | @uri')
            current=$(query "/1.0/profiles?recursion=1&project=$project_query")
            actual=$(printf '%s\n' "$current" |
              "$jq" -c --arg name "$name" '[.[] | select(.name == $name)] | .[0] // empty')
            if [ -z "$actual" ]; then
              missing=1
              return
            fi
            if ! "$jq" -n -e --argjson wanted "$wanted" --argjson actual "$actual" '
              $actual.config == $wanted.config and $actual.devices == $wanted.devices
            ' >/dev/null; then
              conflict "profile/$project/$name"
            fi
          }

          check_project
          check_pool
          check_network
          check_profile

          if [ "$missing" -eq 1 ]; then
            echo missing
          else
            echo matching
          fi
        '';
        lockedPreseed = pkgs.writeShellScript "locked-compute-preseed" ''
          set -eu
          result="$(${preseedGate})"
          echo "compute Incus envelope adoption check: $result; applying native preseed."
          ${config.systemd.services.incus-preseed.script}
        '';

        requiredPaths =
          lib.mapAttrsToList (_: entry: {
            inherit (entry) path mode readOnly;
            uid = cfg.idmapBase + entry.uid;
            gid = cfg.idmapBase + entry.gid;
          }) cfg.retainedPaths
          ++ [
            {
              path = cfg.identityPath;
              uid = cfg.idmapBase;
              gid = cfg.idmapBase;
              mode = "0700";
              readOnly = false;
            }
          ]
          ++ deviceRequiredPaths;
        descriptor = {
          inherit
            publicKey
            projectConfig
            poolPath
            networkConfig
            requiredPaths
            devices
            ;
          inherit (cfg)
            project
            instance
            profile
            pool
            network
            address
            idmapBase
            idmapSize
            retainedPaths
            runtimeSecrets
            identityPath
            ;
          # The profile is rendered from the effective config, so the descriptor
          # must carry that same value or the adoption gate compares the desired
          # envelope against something the same evaluation never produced.
          config = instanceConfig;
          baseConfig = cfg.config;
          inherit capabilityGids;
          idmap = {
            inherit (idmapPlan) uid gid;
          };
        };
      in
      {
        environment.systemPackages = [
          (pkgs.callPackage (inputs.self + "/pkgs/by-name/compute-guest/package.nix") { })
        ];
        # The kernel's setuid helpers refuse to build a map containing host IDs
        # the caller has no subordinate range for, so a crossing capability needs
        # its own line here — narrow, one ID per capability, not a band.
        users.users.root.subGidRanges = capabilitySubGidRanges;
        virtualisation.incus.preseed = preseed;
        # Keep the read-only adoption check and any native preseed in one
        # lifecycle lock; a conflict therefore aborts before preseed mutation.
        systemd.services.incus-preseed.serviceConfig.ExecStart =
          lib.mkForce "${pkgs.util-linux}/bin/flock -n /run/lock/compute-${cfg.project}-${cfg.instance}.lock ${lockedPreseed}";

        environment.etc."homelab/compute.json" = {
          mode = "0444";
          text = builtins.toJSON descriptor + "\n";
        };

        networking.firewall.interfaces.${cfg.network} = {
          allowedUDPPorts = [
            53
            67
          ];
          allowedTCPPorts = [ 53 ];
        };

        secretRequests = lib.optionalAttrs hasIdentity {
          "${cfg.instance}-host-key" = {
            provider = "agenix";
            ageFile = identityAge;
            mode = "0400";
            restartUnits = [ "compute-stage-identity.service" ];
          };
        };
        systemd.services.compute-stage-identity = {
          description = "Stage the declared compute SSH identity";
          wantedBy = lib.optional hasIdentity "multi-user.target";
          before = [ "incus.service" ];
          path = [
            pkgs.coreutils
            pkgs.util-linux
            pkgs.openssh
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            UMask = "0077";
          };
          script = ''
            set -eu
            exec 9>/run/lock/compute-${cfg.project}-${cfg.instance}.lock
            flock -n 9
            test -s ${publicKeyFile}
            key=/run/agenix/${cfg.instance}-host-key
            actual="$(ssh-keygen -y -f "$key")"
            expected="$(cut -d ' ' -f 1-2 ${publicKeyFile})"
            test "$actual" = "$expected"
            install -m 0400 -o ${toString cfg.idmapBase} -g ${toString cfg.idmapBase} "$key" ${cfg.identityPath}/.key-new
            install -m 0444 -o ${toString cfg.idmapBase} -g ${toString cfg.idmapBase} ${publicKeyFile} ${cfg.identityPath}/.pub-new
            mv -T ${cfg.identityPath}/.key-new ${cfg.identityPath}/ssh_host_ed25519_key
            mv -T ${cfg.identityPath}/.pub-new ${cfg.identityPath}/ssh_host_ed25519_key.pub
          '';
        };

        # Native nftables bridge rules own L2 filtering. A second br_netfilter
        # pass through inet conntrack invalidates DHCP packets before host input.
        boot.kernel.sysctl = {
          "net.bridge.bridge-nf-call-iptables" = 0;
          "net.bridge.bridge-nf-call-ip6tables" = 0;
          "net.bridge.bridge-nf-call-arptables" = 0;
        };

        # Incus 7.4 supports NIC ACLs, but its preseed API has no ACL object
        # field. Keep the host boundary declarative until a native ACL owner is
        # available; this catches routed and same-bridge ingress early.
        networking.nftables.tables."homelab-compute-boundary" = {
          family = "inet";
          content = ''
            chain forward {
              type filter hook forward priority -50; policy accept;
              oifname "${cfg.network}" ct state { established, related } accept
              oifname "${cfg.network}" drop
            }
          '';
        };

        networking.nftables.tables."homelab-compute-bridge-boundary" = {
          family = "bridge";
          content = ''
            chain forward {
              type filter hook forward priority -50; policy accept;
              oifname "${cfg.devices.eth0.host_name}" ct state { established, related } accept
              oifname "${cfg.devices.eth0.host_name}" drop
            }
          '';
        };
      };
  };
}
