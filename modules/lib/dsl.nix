{ lib, self, ... }:
{
  flake.lib.dlab =
    let
      dsl = {
        toSystemdNetwork =
          hosts: networks: hostName:
          lib.pipe hostName [
            (hostName: hosts.${hostName}) # Get the specific host configuration
            (
              host:
              lib.mapAttrs (
                networkName: network:
                # Outer map: Iterate over the networks configured for the host
                let
                  networkMeta = networks.${networkName};
                  prefixLength = lib.toInt (lib.last (lib.splitString "/" networkMeta.cidr));
                in
                lib.mapAttrs' (
                  interfaceName: interface:
                  # Inner map: Iterate over the interfaces on this network
                  lib.nameValuePair "10-${interfaceName}" {
                    name = interfaceName;
                    address = lib.optional (interface.ipv4 != null) "${interface.ipv4}/${toString prefixLength}";
                    gateway = lib.optional (interface.ipv4 != null) networkMeta.gateway;
                    DHCP = if interface.dhcp then "yes" else "no";

                    # TODO: make it possible to configure DNS servers per-interface
                    # dns = [
                    #   "1.1.1.1#one.one.one.one"
                    #   "9.9.9.9#dns.quad9.net"
                    # ];

                    # This method uses systemd.network's native options
                    # networkConfig = {
                    #   Address = lib.optional (interface.ipv4 != null) "${interface.ipv4}/${toString prefixLength}";
                    #   DNS = [
                    #     "1.1.1.1#one.one.one.one"
                    #     "9.9.9.9#dns.quad9.net"
                    #   ];
                    # };
                  }
                ) network.interfaces
              ) host.networks
            )
            # The result is an attribute set of attribute sets, where the inner sets are the
            # network interface configurations. NixOS systemd.network expects a single
            # attribute set of configurations, which are typically named after the interface.
            # We use lib.foldl' lib.recursiveUpdate {} to flatten this structure.
            (networkConfigs: lib.foldl' lib.recursiveUpdate { } (lib.attrValues networkConfigs))
          ];
      };
    in
    {
      inherit dsl;

      # Generate systemd-networkd configuration for a host
      hostToSystemdNetwork = dsl.toSystemdNetwork self.dlab.hosts self.dlab.networks;

      # Get all hosts with a specific tag
      hostsWithTag = tag: hosts: lib.filterAttrs (_: host: lib.elem tag host.tags) hosts;

      # Get all hosts connected to a specific network
      hostsInNetwork =
        networkName: hosts: lib.filterAttrs (_: host: lib.hasAttr networkName host.networks) hosts;

      # Get interface configuration for a specific host/network/interface
      getInterfaceConfig =
        hostName: networkName: interfaceName: hosts:
        let
          host = hosts.${hostName};
          network = host.networks.${networkName};
        in
        network.interfaces.${interfaceName};

      # Get all users that can access a specific host
      usersForHost = hostName: hosts: lib.attrNames hosts.${hostName}.users;

      # Get all networks a host is connected to
      networksForHost = hostName: hosts: lib.attrNames hosts.${hostName}.networks;

      # Get deployment target for a host
      deploymentTarget = hostName: hosts: hosts.${hostName}.deploy.target;

      # Get SSH public key files for a user on a specific host
      sshKeysForUser =
        userName: hostName: hosts:
        lib.pipe hosts [
          # Get the specific host configuration
          (hosts: hosts.${hostName}.users.${userName} or { })
          # Extract SSH keys (or empty list if not found)
          (user: user.sshKeys or [ ])
          # Normalize each key to a string using readAsStr
          (lib.map self.lib.utilities.readAsStr)
          # In case any keys have multiple lines, split them into separate keys
          (lib.concatMap (lib.splitString "\n"))
          # Filter out empty keys
          (lib.filter (key: key != ""))
        ];
    };
}
