{
  lib,
  inputs,
  den,
  rootPath,
  ...
}:
let
  inherit (lib) mkOption types;

  interfaceType = types.submodule {
    options = {
      ipv4 = mkOption {
        type = types.coercedTo types.str (s: [ s ]) (types.listOf types.str);
        default = [ ];
        description = "IPv4 addresses in CIDR notation";
      };
      ipv6 = mkOption {
        type = types.coercedTo types.str (s: [ s ]) (types.listOf types.str);
        default = [ ];
        description = "IPv6 addresses in CIDR notation";
      };
      dhcp = mkOption {
        type = types.nullOr (
          types.coercedTo types.bool (v: if v then "yes" else null) (
            types.enum [
              "none"
              "ipv4"
              "ipv6"
              "yes"
            ]
          )
        );
        default = null;
        description = "DHCP mode. null = auto, true = yes";
      };
      gateway = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Default gateway for this interface";
      };
      initrd = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable this interface in initrd";
        };
      };
      managed = mkOption {
        type = types.bool;
        default = true;
        description = "Apply environment gateway/DNS/subnet";
      };
      mtu = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "MTU for this interface";
      };
      linkLocal = mkOption {
        type = types.nullOr (
          types.enum [
            "ipv4"
            "ipv6"
            "yes"
            "no"
          ]
        );
        default = null;
        description = "Link-local addressing";
      };
      requiredForOnline = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "RequiredForOnline value";
      };
    };
  };

  exporterType = types.submodule {
    options = {
      port = mkOption {
        type = types.int;
        description = "Port number";
      };
      path = mkOption {
        type = types.str;
        default = "/metrics";
      };
      interval = mkOption {
        type = types.str;
        default = "30s";
      };
    };
  };

  # Aspect settings are strict modules shared by host and user entity schemas.
  settingsType = import ./_settings-type.nix { inherit lib den; };
in
{
  den.schema.host.isEntity = true;
  den.schema.host.imports = [
    (
      { config, ... }:
      {
        options = {
          channel = mkOption {
            type = types.str;
            default = "nixos-unstable";
            description = "Nixpkgs channel for this host";
          };

          environment = mkOption {
            type = types.str;
            default = "prod";
            description = "Environment name this host belongs to";
          };

          system-owner = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Primary user for this host";
          };

          system-access-groups = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Groups granting Unix account creation on this host";
          };

          ipv4 = mkOption {
            type = types.listOf types.str;
            readOnly = true;
            description = "Primary IPv4 addresses (derived from first interface with IPs, CIDR stripped)";
            default =
              let
                ifaces = config.networking.interfaces or { };
                ifaceList = lib.attrValues ifaces;
                withIps = lib.findFirst (i: (i.ipv4 or [ ]) != [ ]) null ifaceList;
                stripCidr = addr: builtins.head (lib.splitString "/" addr);
              in
              if withIps != null then map stripCidr withIps.ipv4 else [ ];
          };

          ipv6 = mkOption {
            type = types.listOf types.str;
            readOnly = true;
            description = "Primary IPv6 addresses (derived from first interface with IPs)";
            default =
              let
                ifaces = config.networking.interfaces or { };
                ifaceList = lib.attrValues ifaces;
                withIps = lib.findFirst (i: (i.ipv6 or [ ]) != [ ]) null ifaceList;
              in
              if withIps != null then withIps.ipv6 else [ ];
          };

          networking =
            mkOption {
              type = types.submodule {
                options = {
                  interfaces = mkOption {
                    type = types.attrsOf interfaceType;
                    default = { };
                    description = "Network interfaces";
                  };
                  bonds = mkOption {
                    type = types.attrsOf (
                      types.submodule {
                        options = {
                          interfaces = mkOption { type = types.listOf types.str; };
                          mode = mkOption {
                            type = types.str;
                            default = "balance-rr";
                          };
                          transmitHashPolicy = mkOption {
                            type = types.nullOr types.str;
                            default = null;
                          };
                        };
                      }
                    );
                    default = { };
                    description = "Bond definitions";
                  };
                  autobridging = mkOption {
                    type = types.bool;
                    default = false;
                  };
                  bridges = mkOption {
                    type = types.attrsOf (types.listOf types.str);
                    default = { };
                  };
                };
              };
              default = { };
            }
            // {
              identity = false;
            };

          zfs = {
            rootPool = mkOption {
              type = types.nullOr (
                types.submodule {
                  options = {
                    name = mkOption {
                      type = types.str;
                      description = "ZFS pool name for the root pool";
                    };
                    disk1 = mkOption {
                      type = types.str;
                      description = "Primary disk device for the root pool";
                    };
                  };
                }
              );
              default = null;
              description = "ZFS root pool configuration";
            };
            swap = {
              enable = mkOption {
                type = types.bool;
                default = false;
                description = "Enable swap partition via disko";
              };
              size = mkOption {
                type = types.str;
                default = "8G";
                description = "Size of the swap partition";
              };
            };
          };

          disk = {
            device = mkOption {
              type = types.nullOr types.str;
              default = config.zfs.rootPool.disk1 or null;
              description = "Root disk device for disko layout (defaults to ZFS pool disk)";
            };
          };

          facts =
            mkOption {
              type = types.nullOr types.path;
              default = null;
              description = "Path to nixos-facter report for hardware detection";
            }
            // {
              identity = false;
            };

          secretPath =
            mkOption {
              type = types.nullOr types.path;
              default = null;
              description = "Path to per-host agenix secrets directory";
            }
            // {
              identity = false;
            };

          public_key =
            mkOption {
              type = types.nullOr types.path;
              default = null;
              description = "Path to host SSH public key for agenix-rekey hostPubkey";
            }
            // {
              identity = false;
            };

          exporters =
            mkOption {
              type = types.attrsOf exporterType;
              default = { };
              description = "Prometheus exporter definitions for this host";
            }
            // {
              identity = false;
            };

          settings =
            mkOption {
              type = settingsType;
              default = { };
              description = "Per-aspect typed settings (auto-discovered from aspect tree)";
            }
            // {
              identity = false;
            };
        };

        config = {
          secretPath = lib.mkDefault (rootPath + "/.secrets/hosts/${config.name}");
          facts = lib.mkDefault (rootPath + "/hosts/${config.name}/facter.json");
          public_key = lib.mkDefault (
            if config.secretPath != null then config.secretPath + "/runtime_host_key.pub" else null
          );

          instantiate = lib.mkDefault inputs.nixpkgs.lib.nixosSystem;

          home-manager.module = lib.mkDefault inputs.home-manager.nixosModules.home-manager;
        };
      }
    )
  ];
}
