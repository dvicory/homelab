{
  den.aspects.services.kubernetes = {
    nixos =
      { config, ... }:
      {
        # Metrics collectors reach the authenticated kubelet through Flannel's
        # local pod bridge, not the guest's external management interface.
        networking.firewall.interfaces.cni0.allowedTCPPorts = [ 10250 ];
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
        systemd.services.kubernetes-runtime-secrets = {
          description = "Apply the atomically staged Kubernetes runtime Secrets";
          wantedBy = [ "multi-user.target" ];
          after = [ "k3s.service" ];
          requires = [ "k3s.service" ];
          unitConfig.ConditionPathExists = "/srv/secrets/runtime-secrets.yaml";
          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = "5min";
            Restart = "on-failure";
            RestartSec = "15s";
          };
          script = ''
            ${config.services.k3s.package}/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
              apply --server-side --field-manager=homelab-runtime-secrets \
              -f /srv/secrets/runtime-secrets.yaml
          '';
        };
        systemd.paths.kubernetes-runtime-secrets = {
          wantedBy = [ "multi-user.target" ];
          pathConfig = {
            PathChanged = "/srv/secrets/runtime-secrets.yaml";
            Unit = "kubernetes-runtime-secrets.service";
          };
        };
      };
  };
}
