{ lib, ... }: {
  den.aspects.networking.default = {
    nixos = { host, config, pkgs, environment, ... }:
    let
      interfaces = host.networking.interfaces or { };
      envNetworks = environment.networks or { };
      defaultNet = envNetworks.default or { };

      effectiveDhcp = ifCfg:
        if ifCfg.dhcp or null != null then
          ifCfg.dhcp
        else if !(ifCfg.managed or true) then
          "none"
        else if (ifCfg.ipv4 or []) != [] then
          "ipv6"
        else
          "yes";

      mkManagedNetworkConfig = name: ifCfg: {
        matchConfig.Name = name;
        address = ifCfg.ipv4 or [] ++ ifCfg.ipv6 or [];
        networkConfig = {
          DHCP = effectiveDhcp ifCfg;
          IPv6AcceptRA = true;
          IPv6PrivacyExtensions = "yes";
          DNSOverTLS = true;
          DNSSEC = "allow-downgrade";
        } // lib.optionalAttrs (defaultNet ? dnsServers) {
          DNS = defaultNet.dnsServers;
        };
        routes = lib.optionals (defaultNet ? gatewayIp) [
          { Gateway = defaultNet.gatewayIp; }
        ] ++ lib.optionals (defaultNet ? gatewayIpV6) [
          { Gateway = defaultNet.gatewayIpV6; }
        ];
        linkConfig = lib.optionalAttrs (ifCfg ? mtu && ifCfg.mtu != null) {
          MTUBytes = toString ifCfg.mtu;
        };
        routingPolicyRules = [];
      };

      mkUnmanagedNetworkConfig = name: ifCfg: {
        matchConfig.Name = name;
        address = ifCfg.ipv4 or [] ++ ifCfg.ipv6 or [];
        networkConfig = {
          DHCP = effectiveDhcp ifCfg;
          LinkLocalAddressing = if ifCfg ? linkLocal then ifCfg.linkLocal else "no";
        };
        linkConfig = lib.optionalAttrs (ifCfg ? mtu && ifCfg.mtu != null) {
          MTUBytes = toString ifCfg.mtu;
        } // {
          ActivationPolicy = "up";
        };
      };

      mkNetworkConfig = name: ifCfg:
        if (ifCfg.managed or true) then
          mkManagedNetworkConfig name ifCfg
        else
          mkUnmanagedNetworkConfig name ifCfg;

      toSystemdNetwork = lib.mapAttrs mkNetworkConfig interfaces;
    in {
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
