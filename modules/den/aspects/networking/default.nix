{ lib, ... }: {
  den.aspects."networking/default" = { host, ... }:
  let
    interfaces = host.networking.interfaces or { };

    toSystemdNetwork = lib.mapAttrs (name: iface: {
      matchConfig.Name = name;
      address = lib.optional (iface ? ipv4 && iface.ipv4 != null) iface.ipv4;
      gateway = lib.optional (iface ? gateway && iface.gateway != null) iface.gateway;
      networkConfig.DHCP = if iface.dhcp or false then "yes" else "no";
    }) interfaces;
  in {
    nixos = { config, pkgs, ... }: {
      environment.systemPackages = with pkgs; [
        curl
        xh
        trippy
      ];

      networking.useNetworkd = true;
      networking.dhcpcd.enable = lib.mkDefault false;

      services.openssh.enable = lib.mkDefault true;

      networking.nftables.enable = true;
      networking.firewall.enable = lib.mkDefault true;

      networking.nameservers = lib.mkDefault [
        "1.1.1.1#one.one.one.one"
        "9.9.9.9#dns.quad9.net"
      ];

      services.resolved = {
        enable = lib.mkDefault true;
        settings.Resolve = {
          DNSOverTLS = lib.mkDefault "true";
          DNSSEC = lib.mkDefault "true";
        };
      };

      systemd.network.networks = toSystemdNetwork;

      # systemd-resolved needs CA certificates in the expected location for
      # DNS-over-TLS in initrd. The certs end up in /etc/ssl/certs from the
      # ca-certools package in the initrd store, but resolved looks in
      # /etc/ssl/certs/ca-certificates.crt. This service symlinks them.
      boot.initrd.systemd = lib.mkIf config.boot.initrd.systemd.enable {
        services."resolved-cert-setup" = lib.mkIf (
          config.services.resolved.enable
          && (
            let dnsTls = config.services.resolved.settings.Resolve.DNSOverTLS or null;
            in dnsTls == "true" || dnsTls == "opportunistic"
          )
        ) {
          description = "Prepare SSL certificates for systemd-resolved in initrd";
          wantedBy = [ "nss-lookup.target" ];
          before = [ "nss-lookup.target" ];

          unitConfig.DefaultDependencies = false;

          serviceConfig = {
            Type = "oneshot";
            ExecStart = [
              "/bin/mkdir -p /etc/ssl/certs"
              "/bin/ln -sf /etc/ssl/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt"
            ];
            RemainAfterExit = "yes";
          };
        };
      };
    };
  };
}
