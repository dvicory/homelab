{
  config,
  den,
  inputs,
  lib,
  self,
  ...
}:
let
  host = self.nixosConfigurations.hvn-hyp1.config;
  guest = self.nixosConfigurations.compute-1.config;
  incusFirewallRestricted =
    firewall:
    let
      portClosed =
        interface:
        !(builtins.elem 8443 interface.allowedTCPPorts)
        && builtins.all (range: !(range.from <= 8443 && range.to >= 8443)) interface.allowedTCPPortRanges;
    in
    portClosed firewall
    && builtins.all (
      name: name == host.services.tailscale.interfaceName || portClosed firewall.interfaces.${name}
    ) (builtins.attrNames firewall.interfaces);
  hostEntity = config.den.hosts.x86_64-linux.hvn-hyp1;
  compute = hostEntity.settings.virtualization.compute;
  # The host's compute aspect, evaluated with a changed declaration.
  computeAspect =
    (import ../den/aspects/virtualization/compute.nix {
      inherit
        den
        lib
        inputs
        config
        ;
    }).den.aspects.virtualization.compute.nixos;
  evaluateWith =
    change:
    computeAspect {
      host = hostEntity // {
        settings = hostEntity.settings // {
          virtualization = hostEntity.settings.virtualization // {
            compute = change compute;
          };
        };
      };
      config = host;
      inherit lib;
      inherit (self.nixosConfigurations.hvn-hyp1) pkgs;
    };
  rejected =
    change:
    !(builtins.tryEval (builtins.deepSeq (evaluateWith change).virtualisation.incus.preseed true))
    .success;
  withDevice =
    name: device: current:
    current
    // {
      devices = current.devices // {
        ${name} = device;
      };
    };
  ungranted =
    builtins.fromJSON
      (evaluateWith (current: current // { accelerator = null; }))
      .environment.etc."homelab/compute.json".text;
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
    ++ [
      "secrets"
      "state"
    ]
    ++ lib.optional (compute.accelerator != null) "gpu-render"
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
      # UID remains one contiguous subordinate range.
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
          map (
            row:
            if row.range == 1 then
              toString row.hostid
            else
              "${toString row.hostid}-${toString (row.hostid + row.range - 1)}"
          ) descriptor.idmap.gid
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
      ) (builtins.attrValues (removeAttrs devices [ "gpu-render" ]))
      && devices.root.pool == compute.pool
      && devices.identity.source == compute.identityPath
      && devices.identity.readonly == "true"
      && devices.eth0.network == compute.network
      &&
        project."restricted.devices.disk.paths" == lib.concatStringsSep "," (
          lib.unique (
            [
              compute.stateRoot
              compute.identityPath
            ]
            ++ baseDiskPaths
            ++ [ "/run/homelab-compute/secrets" ]
          )
        )
      && builtins.all (kind: project."restricted.devices.${kind}" == "block") [
        "gpu"
        "infiniband"
        "pci"
        "proxy"
        "unix-block"
        "unix-hotplug"
        "usb"
      ]
      &&
        project."restricted.devices.unix-char"
        == (if compute.accelerator != null then "allow" else "block");
    # gpu-render never enters the guest's ID map.
    accelerator-grant-leaves-id-map =
      descriptor.config."raw.idmap" == ungranted.config."raw.idmap"
      && descriptor.idmap == ungranted.idmap
      && project."restricted.idmap.gid" == ungranted.projectConfig."restricted.idmap.gid"
      && removeAttrs descriptor.devices [ "gpu-render" ] == ungranted.devices;
    character-devices-only-through-the-grant =
      !(rejected (current: current))
      && rejected (
        withDevice "kvm" {
          type = "unix-char";
          source = "/dev/kvm";
          path = "/dev/kvm";
        }
      )
      && rejected (
        withDevice "gpu" {
          type = "gpu";
          gputype = "physical";
        }
      );
    workload-state-outside-envelope =
      let
        allowed = lib.splitString "," project."restricted.devices.disk.paths";
        sources = lib.filter (source: source != null) (
          map (device: device.source or null) (builtins.attrValues devices)
        );
        retained = map (entry: entry.path) (builtins.attrValues compute.retainedPaths);
      in
      retained != [ ]
      && builtins.all (path: !(builtins.elem path allowed) && !(builtins.elem path sources)) retained
      && devices.state.source == compute.stateRoot
      && devices.state.required == "true";
    optional-media-device =
      let
        media = devices.media or null;
      in
      media == null
      || (
        (media.required or "true") == "false"
        && builtins.all (entry: entry.path != media.source) descriptor.requiredPaths
      );
    no-guest-secret-inputs =
      (guest.secretRequests or { }) == { }
      && (guest.age.secrets or { }) == { }
      && (guest.age.identityPaths or [ ]) == [ ];
    no-broad-network-trust =
      host.networking.firewall.enable
      && host.networking.nftables.enable
      && builtins.all (interface: !(builtins.elem interface host.networking.firewall.trustedInterfaces)) (
        [
          compute.network
          devices.eth0.host_name
          host.services.tailscale.interfaceName
          "*"
          "all"
        ]
        ++ builtins.attrNames config.den.hosts.x86_64-linux.hvn-hyp1.networking.interfaces
      );
    incus-not-open-on-untrusted-interfaces = incusFirewallRestricted host.networking.firewall;
    incus-tailnet-port-present =
      builtins.elem 8443
        host.networking.firewall.interfaces.${host.services.tailscale.interfaceName}.allowedTCPPorts;
    tailscale-transport-present = builtins.elem host.services.tailscale.port host.networking.firewall.allowedUDPPorts;
    independent-ssh-recovery =
      host.services.openssh.enable && builtins.elem 22 host.networking.firewall.allowedTCPPorts;
    bridge-service-ports-present =
      builtins.elem 53 host.networking.firewall.interfaces.${compute.network}.allowedTCPPorts
      &&
        builtins.all
          (port: builtins.elem port host.networking.firewall.interfaces.${compute.network}.allowedUDPPorts)
          [
            53
            67
          ];
    kubelet-pod-bridge-port-present =
      builtins.elem 10250 guest.networking.firewall.interfaces.cni0.allowedTCPPorts
      && !(builtins.elem 10250 guest.networking.firewall.allowedTCPPorts);
    incus-interface-port-rejected =
      !(incusFirewallRestricted
        (self.nixosConfigurations.hvn-hyp1.extendModules {
          modules = [ { networking.firewall.interfaces.guard-test-lan.allowedTCPPorts = [ 8443 ]; } ];
        }).config.networking.firewall
      );
    incus-interface-range-rejected =
      !(incusFirewallRestricted
        (self.nixosConfigurations.hvn-hyp1.extendModules {
          modules = [
            {
              networking.firewall.interfaces.guard-test-lan.allowedTCPPortRanges = [
                {
                  from = 8442;
                  to = 8444;
                }
              ];
            }
          ];
        }).config.networking.firewall
      );
    # INPUT admission/denial, real Incus TLS UI/API, SSH recovery and the
    # forwarded Gateway datapath are covered by compute-ingress-runtime.
    # Inventory the guest's NodePort too: its namespace listener intentionally
    # stands in for the guest, not for the guest's own firewall.
    household-direct-ingress-ports =
      let
        ingress = config.den.clusters.prod-home.ingress;
      in
      ingress.mode == "direct"
      && builtins.elem ingress.nodePort (guest.networking.firewall.interfaces.eth0.allowedTCPPorts or [ ])
      && !(builtins.elem ingress.nodePort host.networking.firewall.allowedTCPPorts)
      && !(builtins.elem 443 host.networking.firewall.allowedTCPPorts)
      && !(builtins.elem 80 host.networking.firewall.allowedTCPPorts)
      && !(builtins.elem 6443 host.networking.firewall.allowedTCPPorts);
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
