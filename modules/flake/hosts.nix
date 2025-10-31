/**
  # Host Inventory DSL

  The DSL provides a structured way to define hosts, their network configurations, users,
  and deployment metadata, enabling easy querying of host relationships and automatic
  generation of NixOS configurations.

  ## Purpose

  - Centralized host inventory management
  - Type-safe configuration with validation
  - Declarative network and user management

  ## DSL Structure

  ### Hosts (`config.flake.dlab.hosts`)
  Attrset of host definitions with the following attributes:

  - `system`: System architecture (e.g., "x86_64-linux", "aarch64-linux")
  - `tags`: List of strings for categorization (e.g., ["server", "storage"])
  - `networks`: Attrset of network configurations with per-interface settings (including initrd.enable for early networking)
  - `rootPool`: ZFS root pool configuration (name, disk1, optional disk2 for mirroring)
  - `users`: Attrset of user accounts with groups, passwords, and SSH keys
  - `deploy`: Deployment target, user, and network reference

  ### Networks (`config.flake.dlab.networks`)
  Global network metadata shared across hosts:
  - `cidr`: Subnet in CIDR notation
  - `gateway`: Optional default gateway

  ## Usage Examples

  ### Basic Host Definition
  ```nix
  config.flake.dlab.hosts = {
    myhost = {
      system = "x86_64-linux";
      tags = [ "server" "web" ];
      networks = {
        mgmt = {
          interfaces = {
            eth0 = {
              ipv4 = "192.168.10.100";
              dhcp = false;
              initrd.enable = true;  # Management interface for initrd
            };
          };
        };
      };
      rootPool = {
        name = "rpool";
        disk1 = "/dev/sda";
      };
      users = {
        admin = {
          groups = [ "wheel" ];
          sshKeys = [ ./keys/admin.pub ];
        };
      };
      deploy = {
        target = "192.168.10.100";
        user = "root";
      };
    };
  };
  ```
*/
{
  config,
  self,
  lib,
  ...
}:
let
  sharedUsers = {
    daniel = {
      groups = [
        "wheel"
        "network"
      ];
      # TODO: use contract to fulfill this?
      hashedPasswordPath = "users/daniel/hashedPassword";
      sshKeys = [
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDJwFwHDxRBF5i9J2XeInui9zO2Q8bMTvKwZJgOU3j8D6qW/la+/at68gxSwMN2VzQPhLXAP6G9dupJQGXXPTF22SNm+2BUwJ9zCaq5cfsBrXNEm7XKQ5ar4X2t2gtOay+K/LiTFIp3W23KBLtKZH4/HZwIKMNXW6xzWFA/deRKfpqAbkzdL29IGLgDuyyzoReLL3mzCO1KSprg4VOtgTjjduWxCXvhw0Hi/StDUs9PwySIXR2mHVpn//7bV4zTMH2Z/qFFW2W66yImJcxg1H2ZogkY2tDKaANEaCA1JwEJkSrqE28oHMS+OUY8BhCHj6C+m8Eusf41WAHfFMJEuIq5Dw6XCvOp7GySvb3OVx7GdCWEC6UhkCmecNi1U18u4LumF45bmS77ohol+LdYyGtAHK4yNkRRlM6en3Zn43Gn+ffNDyxuqyaVjbQFM0VUYA0EEyyPgv3irkVXnFtCRZYxe7zTdh+qAu8IZRRVEZV23+OmYBrhGwOQk+qQnJ1hq5m2baUiBprYj2icEXYnqEcNfqbdBZDX3DAzIiFJzs03qknvqT0Bjscqp8WUeIIfzTGt7fusOiBBDy7g4NVFNoTjK8NUr7C6dauQxy2+BdxCaphuI/ljyze0Lomif2O9QAVvYHoYtZ4xYNcQWr2+iwaHLAl1XN1sw8hSryGxWPkjpQ=="
      ];
    };
  };

  # Import mk-os builders
  inherit (self.lib.utilities) deepMerge;
  inherit (self.lib.mk-os) mkNixos mkDarwin;

  # Generate configurations directly from DSL - DSL is single source of truth
  # Map each host to its appropriate configuration
  nixosHosts = lib.mapAttrs (name: host: mkNixos host.system "nixos" name) (
    lib.filterAttrs (_: host: lib.hasSuffix "-linux" host.system && host.enable) config.flake.dlab.hosts
  );

  darwinHosts = lib.mapAttrs (name: host: mkDarwin host.system name) (
    lib.filterAttrs (
      _: host: lib.hasSuffix "-darwin" host.system && host.enable
    ) config.flake.dlab.hosts
  );
in
{
  options.flake.dlab.hosts = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Enable this host definition.";
            };

            system = lib.mkOption {
              type = lib.types.enum config.systems;
              description = "System type for the host.";
            };

            tags = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Simple tags for categorizing hosts.";
            };

            networks = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule (
                  { name, ... }:
                  {
                    options = {
                      interfaces = lib.mkOption {
                        type = lib.types.attrsOf (
                          lib.types.submodule (
                            { name, ... }:
                            {
                              options = {
                                ipv4 = lib.mkOption {
                                  type = lib.types.nullOr lib.types.str;
                                  default = null;
                                  description = "IPv4 address for this interface.";
                                };

                                dhcp = lib.mkOption {
                                  type = lib.types.bool;
                                  default = false;
                                  description = "Enable DHCP for this interface.";
                                };

                                initrd = lib.mkOption {
                                  type = lib.types.submodule {
                                    options = {
                                      enable = lib.mkOption {
                                        type = lib.types.bool;
                                        default = false;
                                        description = "Enable this interface in initrd for early networking.";
                                      };
                                    };
                                  };
                                  default = { };
                                  description = "Initrd configuration for this interface.";
                                };
                              };
                            }
                          )
                        );
                        description = "Per-interface network configuration.";
                      };
                    };
                  }
                )
              );
              description = "Networks this host participates in.";
            };

            rootPool = lib.mkOption {
              type = lib.types.submodule {
                options = {
                  name = lib.mkOption {
                    type = lib.types.str;
                    description = "Name of the ZFS root pool.";
                  };

                  disk1 = lib.mkOption {
                    type = lib.types.str;
                    description = "Primary device path for root pool.";
                  };

                  disk2 = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Optional secondary mirror disk path.";
                  };
                };
              };
              description = "Root pool device configuration (for ZFS auto-formatting, etc).";
            };

            users = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule (
                  { name, ... }:
                  {
                    options = {
                      groups = lib.mkOption {
                        type = lib.types.listOf lib.types.str;
                        default = [ ];
                        description = "Groups this user belongs to.";
                      };

                      hashedPasswordPath = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = "Optional path to the user's hashed password file in secrets.";
                      };

                      sshKeys = lib.mkOption {
                        type = lib.types.listOf (
                          lib.types.oneOf [
                            lib.types.singleLineStr
                            lib.types.pathInStore
                          ]
                        );
                        default = [ ];
                        description = "SSH public keys as file paths or strings.";
                      };
                    };
                  }
                )
              );
              default = { };
              apply = v: deepMerge sharedUsers v;
              # apply = users: lib.mapAttrs (uname: uattrs:
              #   if lib.hasAttr uname sharedUsers then
              #     lib.recursiveUpdate sharedUsers.${uname} uattrs
              #   else
              #     uattrs
              # ) users;
              description = "Users available on this host.";
            };

            deploy = lib.mkOption {
              type = lib.types.submodule {
                options = {
                  target = lib.mkOption {
                    type = lib.types.str;
                    description = "Deployment target (hostname or IP).";
                  };

                  user = lib.mkOption {
                    type = lib.types.str;
                    default = "root";
                    description = "SSH user for deployment.";
                  };

                  sshPort = lib.mkOption {
                    type = lib.types.int;
                    default = 22;
                    description = "SSH port for deployment.";
                  };

                  bootSshPort = lib.mkOption {
                    type = lib.types.int;
                    default = 2222;
                    description = "Boot SSH port for installation.";
                  };

                  knownHostsPath = lib.mkOption {
                    type = lib.types.str;
                    default = "modules/hosts/${name}/known_hosts";
                    description = "Path to known_hosts file.";
                  };

                  bootHostKeyPath = lib.mkOption {
                    type = lib.types.str;
                    default = "modules/hosts/${name}/boot_host_key";
                    description = "Host key path for /boot.";
                  };

                  runtimeHostKeyPath = lib.mkOption {
                    type = lib.types.str;
                    default = "modules/hosts/${name}/runtime_host_key";
                    description = "Host key path for runtime.";
                  };
                };
              };
              description = "Deployment metadata.";
            };

            remoteUnlock = lib.mkOption {
              type = lib.types.submodule {
                options = {
                  enable = lib.mkOption {
                    type = lib.types.bool;
                    default = true;
                    description = "Enable remote unlock functionality.";
                  };

                  # authorizedKeys = lib.mkOption {
                  #   type = lib.types.listOf (lib.types.oneOf [ lib.types.singleLineStr lib.types.pathInStore ]);
                  #   description = "Keys to allow for remote unlock.";
                  # };

                  tailscaleClientSecretPath = lib.mkOption {
                    type = lib.types.str;
                    default = "shared/tailscale_client_secret";
                    description = "Path to Tailscale client secret file for remote unlock.";
                  };
                };
              };
              default = { };
              description = "Remote unlock settings for Hoopsnake.";
            };

            secrets = lib.mkOption {
              type = lib.types.submodule {
                options = {
                  hostSopsFile = lib.mkOption {
                    type = lib.types.str;
                    default = "modules/hosts/${name}/secrets.yaml";
                    description = "Per-host SOPS secrets file.";
                  };

                  sharedSopsFile = lib.mkOption {
                    type = lib.types.str;
                    default = "shared/secrets.yaml";
                    description = "Shared SOPS secrets file.";
                  };

                  rootPassphraseSopsPath = lib.mkOption {
                    type = lib.types.str;
                    default = "[\"${name}\"][\"disks\"][\"rootPassphrase\"]";
                    description = "Path to root passphrase in SOPS.";
                  };
                };
              };
              default = {
                hostSopsFile = "modules/hosts/${name}/secrets.yaml";
                sharedSopsFile = "shared/secrets.yaml";
                rootPassphraseSopsPath = "[\"${name}\"][\"disks\"][\"rootPassphrase\"]";
              };
              description = "Secrets configuration for SOPS-based encryption.";
            };
          };
        }
      )
    );
    description = "Homelab host inventory (DSL).";
  };

  options.flake.dlab.networks = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            cidr = lib.mkOption {
              type = lib.types.str;
              description = "Subnet in CIDR notation for this network.";
            };

            gateway = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Default gateway (optional).";
              apply =
                v:
                assert (v == null || lib.isString v);
                v;
            };
          };
        }
      )
    );
    description = "Global network metadata shared across hosts.";
  };

  options.flake.dlab.packages = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = "DLab package definitions.";
  };

  config.flake.dlab.networks = {
    homelan = {
      cidr = "172.27.50.0/24";
      gateway = "172.27.50.1";
    };
    mgmt = {
      cidr = "192.168.10.0/24";
      gateway = "192.168.10.1";
    };
    storage = {
      cidr = "10.0.0.0/24";
      gateway = null;
    };
  };

  config.flake.dlab.hosts = {
    builder = {
      system = "aarch64-linux";
      tags = [
        "builder"
        "virtual"
      ];
      networks = {
        mgmt = {
          interfaces = {
            enp0s1 = {
              # ipv4 = "192.168.10.5";
              dhcp = true;
              initrd.enable = true; # Management interface for initrd
            };
          };
        };
      };

      rootPool = {
        name = "rpool";
        disk1 = "/dev/vda";
      };

      users = sharedUsers;

      deploy = {
        target = "192.168.65.90";
        user = "nixos";
        knownHostsPath = "modules/hosts/builder/known_hosts";
        bootHostKeyPath = "modules/hosts/builder/boot_host_key";
        runtimeHostKeyPath = "modules/hosts/builder/runtime_host_key";
      };

      secrets = {
        hostSopsFile = "modules/hosts/builder/secrets.yaml";
        sharedSopsFile = "shared/secrets.yaml";
      };
    };
  };

  config.flake.nixosConfigurations = nixosHosts;
  config.flake.darwinConfigurations = darwinHosts;
}
