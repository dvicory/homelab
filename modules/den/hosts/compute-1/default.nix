{
  config,
  den,
  ...
}:
let
  mediaGid = config.den.groups.media.gid;
  ingress = config.den.clusters.prod-home.ingress;
in
{
  den.hosts.x86_64-linux.compute-1 = {
    environment = "prod";
    system-access-groups = [ "server-access" ];
    settings.core.users.secrets.enable = false;
    aspect = {
      includes = [
        den.aspects.compute-1
        den.aspects.virtualization.incus-guest.provides.container
      ];
    };
    networking.interfaces.eth0 = {
      dhcp = "yes";
      managed = false;
    };
  };

  den.aspects.compute-1 = {
    includes = [
      den.aspects.core.base
      den.aspects.core.security.openssh
      den.aspects.services.kubernetes
    ];

    nixos =
      {
        lib,
        ...
      }:
      {
        # Kubelet must traverse the unshifted root:media (2770) hostPath
        # before it can mount the library for media-capable pods.
        systemd.services.k3s.serviceConfig.SupplementaryGroups = [ (toString mediaGid) ];
        # Exists without the GPU, so a Pod that mounts it still starts.
        systemd.tmpfiles.rules = [ "d /dev/dri 0755 root root -" ];
        networking.hostName = "compute-1";
        networking.firewall.allowedTCPPorts = [
          22
          6443
        ];
        # Direct household ingress: the host DNATs tcp/443 to this NodePort on
        # the bridge-facing NIC only. Other ingress modes expose nothing.
        networking.firewall.interfaces.eth0.allowedTCPPorts = lib.optional (
          ingress.mode == "direct"
        ) ingress.nodePort;
        programs.command-not-found.enable = lib.mkForce false;

        # Guest management remains disabled until its independent host-key
        # trust is provisioned. The host/Incus path remains the recovery path.
        deployment = {
          enable = false;
          target = "10.210.0.10";
          sshUser = "daniel";
          knownHostsPath = null;
        };
      };
  };
}
