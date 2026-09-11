{
  config,
  lib,
  self,
  ...
}:
let
  host = self.nixosConfigurations.hvn-hyp1.config;
  guest = self.nixosConfigurations.compute-1.config;
  compute = config.den.hosts.x86_64-linux.hvn-hyp1.settings.virtualization.compute;
  preseed = host.virtualisation.incus.preseed;
  project = (lib.findFirst (p: p.name == compute.project) null preseed.projects).config;
  profile = lib.findFirst (
    p: p.name == compute.profile && p.project == compute.project
  ) null preseed.profiles;
  devices = profile.devices;
  baseDiskPaths = lib.filter (path: path != null) (
    lib.mapAttrsToList (
      _: entry: if (entry.type or null) == "disk" then entry.source or null else null
    ) compute.devices
  );
  descriptor = builtins.fromJSON host.environment.etc."homelab/compute.json".text;
  idRange = "${toString compute.idmapBase}-${toString (compute.idmapBase + compute.idmapSize - 1)}";
  expectedDeviceNames = lib.sort builtins.lessThan (
    builtins.attrNames compute.devices
    ++ builtins.attrNames compute.retainedPaths
    ++ lib.optional (compute.runtimeSecrets != { }) "secrets"
  );
  owners = builtins.attrNames (
    lib.filterAttrs (
      _: configuration: configuration.config.environment.etc ? "homelab/compute.json"
    ) self.nixosConfigurations
  );
  assertions = {
    intended-host-owns-compute = owners == [ "hvn-hyp1" ];
    unprivileged-confinement =
      project.restricted == "true"
      && project."restricted.containers.lowlevel" == "block"
      && project."restricted.containers.interception" == "block"
      && project."restricted.containers.privilege" == "unprivileged"
      && profile.config."security.privileged" == "false"
      && profile.config."security.idmap.isolated" == "true"
      && profile.config."security.guestapi" == "false"
      &&
        lib.filter (name: lib.hasPrefix "raw." name) (builtins.attrNames profile.config) == [ "raw.idmap" ];
    # The map is generated from the declared capability set, so the contracts
    # assert the generated rows rather than restating a hand-written shape.
    fixed-nonroot-translation =
      compute.idmapBase > 0
      && compute.idmapSize > 0
      # the profile is rendered from the effective config the descriptor carries
      && profile.config."raw.idmap" == descriptor.config."raw.idmap"
      # UID remains one contiguous subordinate range
      &&
        descriptor.idmap.uid == [
          {
            nsid = 0;
            hostid = compute.idmapBase;
            range = compute.idmapSize;
          }
        ]
      # GID covers the whole guest range, interrupted only by declared capabilities
      && (builtins.foldl' (total: row: total + row.range) 0 descriptor.idmap.gid) == compute.idmapSize
      &&
        builtins.length (
          builtins.filter (row: row.nsid == row.hostid && row.range == 1) descriptor.idmap.gid
        ) == builtins.length descriptor.capabilityGids
      # every declared capability is identity-mapped
      && builtins.all (
        gid:
        builtins.elem {
          nsid = gid;
          hostid = gid;
          range = 1;
        } descriptor.idmap.gid
      ) descriptor.capabilityGids
      # project allowances are exactly the host IDs the generated map uses
      &&
        project."restricted.idmap.gid" == lib.concatStringsSep "," (
          map (row: "${toString row.hostid}-${toString (row.hostid + row.range - 1)}") descriptor.idmap.gid
        )
      && project."restricted.idmap.uid" == idRange
      # host authorization for each capability is one narrow ID, not a band
      && builtins.all (
        gid:
        builtins.elem {
          startGid = gid;
          count = 1;
        } host.users.users.root.subGidRanges
      ) descriptor.capabilityGids;
    no-management-device-exposure =
      lib.sort builtins.lessThan (builtins.attrNames devices) == expectedDeviceNames
      && builtins.all (
        d:
        builtins.elem d.type [
          "disk"
          "nic"
        ]
      ) (builtins.attrValues devices)
      && devices.root.pool == compute.pool
      && builtins.all (
        name:
        devices.${name}.source == compute.retainedPaths.${name}.path
        && devices.${name}.path == compute.retainedPaths.${name}.guestPath
        && devices.${name}.readonly == lib.boolToString compute.retainedPaths.${name}.readOnly
      ) (builtins.attrNames compute.retainedPaths)
      && devices.identity.source == compute.identityPath
      && devices.identity.readonly == "true"
      && devices.eth0.network == compute.network
      &&
        project."restricted.devices.disk.paths" == lib.concatStringsSep "," (
          lib.unique (
            map (entry: entry.path) (builtins.attrValues compute.retainedPaths)
            ++ [ compute.identityPath ]
            ++ baseDiskPaths
            ++ lib.optional (compute.runtimeSecrets != { }) "/run/homelab-compute/secrets"
          )
        )
      && devices.media.required == "false"
      && devices.media.source == "/srv/media"
      && builtins.all (entry: entry.path != "/srv/media") descriptor.requiredPaths
      && builtins.all (kind: project."restricted.devices.${kind}" == "block") [
        "gpu"
        "infiniband"
        "pci"
        "proxy"
        "unix-block"
        "unix-char"
        "unix-hotplug"
        "usb"
      ];
    runtime-only-private-identity =
      (guest.secretRequests or { }) == { }
      && (guest.age.secrets or { }) == { }
      && (guest.age.identityPaths or [ ]) == [ ]
      && !guest.services.openssh.generateHostKeys
      && builtins.all (
        key: lib.hasPrefix "${devices.identity.path}/" key.path
      ) guest.services.openssh.hostKeys;
    no-broad-network-trust =
      host.networking.firewall.enable
      && host.networking.nftables.enable
      && builtins.all (interface: !(builtins.elem interface host.networking.firewall.trustedInterfaces)) (
        [
          compute.network
          devices.eth0.host_name
          "*"
          "all"
        ]
        ++ builtins.attrNames config.den.hosts.x86_64-linux.hvn-hyp1.networking.interfaces
      );
  };
  failures = builtins.attrNames (lib.filterAttrs (_: passed: !passed) assertions);
in
{
  perSystem = { pkgs, ... }: {
    checks.compute-contracts =
      assert lib.assertMsg (
        failures == [ ]
      ) "Compute boundary failures: ${lib.concatStringsSep ", " failures}";
      pkgs.writeText "compute-contracts" "ok\n";
  };
}
