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
  idRange = "${toString compute.idmapBase}-${toString (compute.idmapBase + compute.idmapSize - 1)}";
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
      builtins.attrNames devices == [
        "config"
        "eth0"
        "identity"
        "media"
        "root"
      ]
      && builtins.all (
        d:
        builtins.elem d.type [
          "disk"
          "nic"
        ]
      ) (builtins.attrValues devices)
      && devices.root.pool == compute.pool
      && devices.config.source == compute.statePath
      && devices.identity.source == compute.identityPath
      && devices.identity.readonly == "true"
      && devices.media.source == compute.mediaPath
      && devices.eth0.network == compute.network
      &&
        project."restricted.devices.disk.paths" == lib.concatStringsSep "," [
          compute.statePath
          compute.identityPath
          compute.mediaPath
        ]
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
