/**
  # Test VM - Dummy Host

  Minimal host for testing the dendritic pattern without skarabox.
  Demonstrates that regular hosts and skarabox hosts can coexist.
*/
{ lib, ... }:
{
  flake.modules.nixos.testvm =
    { config, ... }:
    {
      this.host = {
        system = "x86_64-linux";
        tags = [
          "test"
          "virtual"
        ];
        networks = {
          # No specific network config for testvm
        };
        rootPool = {
          name = "rpool";
          disk1 = "/dev/vda";
        };
        users = {
          # Minimal user config for testing
        };
        deploy = {
          target = "testvm.local";
          user = "root";
        };
        secrets = {
          hostSopsFile = "modules/hosts/testvm/secrets.yaml";
          sharedSopsFile = "shared/secrets.yaml";
        };
      };

      flake.dlab.hosts.testvm = config.this.host;
    };
}
