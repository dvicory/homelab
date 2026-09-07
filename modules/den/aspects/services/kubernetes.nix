{ ... }:
{
  den.aspects.services.kubernetes = {
    nixos =
      { config, ... }:
      {
        services.k3s = {
          enable = true;
          role = "server";
          # SQLite, Flannel, CoreDNS, and kube-proxy remain the supported
          # single-node path. Only packaged components outside this slice are
          # disabled.
          disable = [
            "local-storage"
            "servicelb"
            "traefik"
          ];
          extraFlags = [ "--snapshotter=native" ];
          extraKubeletConfig = {
            featureGates.KubeletInUserNamespace = true;
          };
          extraKubeProxyConfig = {
            mode = "iptables";
            clientConnection.kubeconfig = "/var/lib/rancher/k3s/agent/kubeproxy.kubeconfig";
            conntrack = {
              maxPerCore = 0;
              tcpEstablishedTimeout = "0s";
              tcpCloseWaitTimeout = "0s";
            };
          };
          # K3s's native template detects the outer user namespace and sets
          # disable_apparmor/restrict_oom_score_adj itself.
          images = [ config.services.k3s.package.airgap-images ];
        };
      };
  };
}
