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
  recovery = lib.findFirst (entry: entry.path == compute.recoveryPath) null descriptor.requiredPaths;
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
    fixed-nonroot-translation =
      compute.idmapBase > 0
      && compute.idmapSize > 0
      && project."restricted.idmap.uid" == idRange
      && project."restricted.idmap.gid" == idRange
      && profile.config."raw.idmap" == "both ${idRange} 0-${toString (compute.idmapSize - 1)}";
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
      && recovery.uid == 0
      && recovery.gid == 0
      && recovery.mode == "0750"
      && !recovery.readOnly
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
