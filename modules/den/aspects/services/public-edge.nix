{
  config,
  lib,
  inputs,
  ...
}:
let
  inherit (lib) mkOption types;
  ingress = config.den.clusters.prod-home.ingress;
  mkRole = role: {
    settings = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable the transport-only public ${role}.";
      };
      authKeyFile = mkOption {
        type = types.nullOr (types.strMatching "/.*");
        default = if role == "origin" then "/srv/secrets/tailscale-auth-key" else null;
        description = "Scoped Tailscale enrollment file; null requests the relay's agenix-managed public-tailscale-auth-key.";
      };
    };
    persist = lib.optional (role == "relay") "/var/lib/tailscale";
    nixos =
      {
        host,
        config,
        pkgs,
        ...
      }:
      let
        cfg = host.settings.services."public-${role}";
        public = ingress.public;
        isRelay = role == "relay";
        interface = config.services.tailscale.interfaceName;
        remoteAddress = if isRelay then public.originAddress else public.peerAddress;
        connectionFlags = [
          "--accept-dns=false"
          "--accept-routes=false"
          "--advertise-routes="
          "--advertise-exit-node=false"
          "--ssh=false"
        ]
        ++ lib.optional (!isRelay) "--snat-subnet-routes=false";
      in
      {
        imports = [ ../core/network/_firewall-lifetime.nix ];
        config = lib.mkIf cfg.enable (
          {
            assertions = [
              {
                assertion = public != null;
                message = "public-${role} requires cluster.ingress.public";
              }
              {
                assertion = isRelay || cfg.authKeyFile != null;
                message = "public-origin requires its separately staged enrollment file";
              }
              {
                assertion = !(builtins.elem interface config.networking.firewall.trustedInterfaces);
                message = "public-${role} must not trust the whole Tailscale interface";
              }
            ];
            services.tailscale = {
              enable = true;
              openFirewall = true;
              authKeyFile =
                if cfg.authKeyFile != null then
                  cfg.authKeyFile
                else
                  config.age.secrets.public-tailscale-auth-key.path;
              extraUpFlags = connectionFlags;
              extraSetFlags = connectionFlags;
            };
            # nftables kube-proxy defaults to primary addresses, excluding the
            # native TUN. The transport rules below admit only its public port.
            services.k3s = lib.mkIf (!isRelay) {
              extraKubeProxyConfig.nodePortAddresses = [ "0.0.0.0/0" ];
            };
            systemd.services.tailscaled = {
              after = [ "nftables.service" ];
              wants = [ "nftables.service" ];
              serviceConfig.ExecStartPre = [ "${pkgs.nftables}/bin/nft list table inet public-transport" ];
            };
            networking.firewall.allowedTCPPorts = lib.optional isRelay 443;
            networking.firewall.interfaces.${interface}.allowedTCPPorts = lib.optional (
              !isRelay
            ) public.nodePort;
            services.haproxy = lib.mkIf isRelay {
              enable = true;
              config = ''
                global
                  maxconn 4096
                defaults
                  mode tcp
                  timeout connect 10s
                  timeout client 1h
                  timeout server 1h
                frontend public_tls
                  bind 0.0.0.0:443
                  default_backend public_origin
                backend public_origin
                  source ${public.peerAddress}
                  server origin ${public.originAddress}:${toString public.nodePort} send-proxy-v2
              '';
            };
            systemd.services.haproxy = lib.mkIf isRelay {
              after = [
                "tailscaled-autoconnect.service"
                "tailscaled-set.service"
              ];
              wants = [
                "tailscaled-autoconnect.service"
                "tailscaled-set.service"
              ];
            };
            # These precede ordinary established/management accepts. Only the
            # declared receiver is reachable; IPv6 never supplies a bypass.
            networking.nftables.enable = true;
            networking.nftables.tables.public-transport = {
              family = "inet";
              content =
                if isRelay then
                  ''
                    chain input {
                      type filter hook input priority -100; policy accept;
                      iifname "${interface}" ct state established,related accept
                      iifname "${interface}" drop
                      ip saddr ${remoteAddress} drop
                    }
                    chain output {
                      type filter hook output priority -100; policy accept;
                      oifname "${interface}" ip daddr ${public.originAddress} tcp dport ${toString public.nodePort} accept
                      oifname "${interface}" ct state established,related accept
                      oifname "${interface}" drop
                    }
                    chain forward {
                      type filter hook forward priority -100; policy accept;
                      iifname "${interface}" drop
                      oifname "${interface}" drop
                    }
                  ''
                else
                  ''
                    chain input {
                      type filter hook input priority -100; policy accept;
                      iifname "${interface}" ip saddr ${public.peerAddress} ip daddr ${public.originAddress} tcp dport ${toString public.nodePort} accept
                      iifname "${interface}" ct state established,related accept
                      iifname "${interface}" drop
                      ip saddr ${public.peerAddress} drop
                      ip6 saddr ${public.peerIPv6Address} drop
                    }
                    chain forward {
                      type filter hook forward priority -100; policy accept;
                      iifname "${interface}" ip saddr ${public.peerAddress} meta l4proto tcp ct original ip daddr ${public.originAddress} ct original proto-dst ${toString public.nodePort} accept
                      iifname "${interface}" drop
                      oifname "${interface}" ct state established,related accept
                      oifname "${interface}" drop
                      ip saddr ${public.peerAddress} drop
                      ip6 saddr ${public.peerIPv6Address} drop
                    }
                    chain output {
                      type filter hook output priority -100; policy accept;
                      oifname "${interface}" ct state established,related accept
                      oifname "${interface}" drop
                    }
                  '';
            };
          }
          // lib.optionalAttrs (isRelay && cfg.authKeyFile == null) {
            secretRequests.public-tailscale-auth-key = {
              provider = "agenix";
              ageFile = inputs.self + "/.secrets/hosts/${host.name}/public-tailscale-auth-key.age";
              mode = "0400";
              restartUnits = [ "tailscaled-autoconnect.service" ];
            };
          }
        );
      };
  };
in
{
  den.aspects.services.public-origin = mkRole "origin";
  den.aspects.services.public-relay = mkRole "relay";
}
