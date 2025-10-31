{ self, ... }:
{
  flake.modules.nixos.profiles-networking =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      # Networking related packages
      environment.systemPackages = with pkgs; [
        # Basic utilities
        curl
        xh

        # Debugging
        trippy
      ];

      # Systemd
      networking.useNetworkd = true;

      # General
      networking.dhcpcd.enable = lib.mkDefault false;

      # NFTables / Firewall
      networking.nftables.enable = true;

      networking.firewall = {
        enable = lib.mkDefault true;
      };

      # DNS
      networking.nameservers = lib.mkDefault [
        "1.1.1.1#one.one.one.one"
        "9.9.9.9#dns.quad9.net"
      ];

      boot.initrd.systemd = lib.mkIf config.boot.initrd.systemd.enable {
        # super hacky way to get systemd-resolved working with DNS-over-TLS in initrd
        # for whatever reason, the certs aren't in the right spot for resolved to find them
        # another option might be to disable DNS-over-TLS in initrd, but that seems worse
        # than just copying the certs over
        # extraFiles = {
        #   "/etc/systemd/resolved.conf.d/10-initrd.conf" = pkgs.writeText "10-initrd.conf" ''
        #     [Resolve]
        #     DNSOverTLS=no
        #   '';
        # };
        services."resolved-cert-setup" =
          lib.mkIf
            (
              config.services.resolved.enable
              && (
                config.services.resolved.dnsovertls == "true"
                || config.services.resolved.dnsovertls == "opportunistic"
              )
            )
            {
              description = "Prepare SSL certificates for systemd-resolved in initrd";
              wantedBy = [ "nss-lookup.target" ];
              before = [ "nss-lookup.target" ];

              unitConfig = {
                DefaultDependencies = false;
              };

              serviceConfig = {
                Type = "oneshot";
                ExecStart = [
                  # Make sure the directory exists
                  "/bin/mkdir -p /etc/ssl/certs"
                  # Copy the CA bundle to where resolved expects it
                  "/bin/ln -sf /etc/ssl/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt"
                ];
                RemainAfterExit = "yes";
              };
            };
      };

      services.resolved = {
        enable = lib.mkDefault true;
        dnsovertls = lib.mkDefault "true";
        dnssec = lib.mkDefault "true";

        # TODO: dedicated security hardening?
        # llmnr = lib.mkDefault "false";
      };

      # Networks
      systemd.network = {
        enable = true;
        networks = self.lib.dlab.hostToSystemdNetwork config.dlab.hostName;
      };
    };
}
