{ den, lib, inputs, ... }: {
  # The secrets.agenix aspect provides all agenix configuration for a host:
  # - agenix + agenix-rekey NixOS module imports
  # - The secretRequests option + conversion to age.secrets
  # - age.identityPaths (SSH host key from /persist)
  # - age.rekey (masterIdentities, hostPubkey, storage paths)
  # - home-manager sharedModules
  # - The generators module (ssh-key, age-identity, etc.)
  den.aspects.secrets.agenix = {
    nixos = { host, config, lib, ... }:
      let
        hasImpermanence = host.hasAspect den.aspects.disk.impermanence;
        persistPrefix = lib.optionalString hasImpermanence "/persist";

        inherit (lib) filterAttrs mapAttrs mapAttrs' nameValuePair mkOption types;

        mkAgeSecret = name: req:
          {
            rekeyFile = req.ageFile;
            mode = req.mode or "0400";
            owner = req.owner or "root";
            group = req.owner or "root";
          } // lib.optionalAttrs (req.generator ? script) {
            generator.script = req.generator.script;
          };

        agenixReqs = filterAttrs (
          _: req: req.provider or "agenix" == "agenix" && req.ageFile or null != null
        ) config.secretRequests;

        restartReqs = filterAttrs (
          _: req: (req.restartUnits or [ ]) != [ ]
        ) agenixReqs;
      in {
        imports = [
          inputs.agenix.nixosModules.default
          inputs.agenix-rekey.nixosModules.default
          (import ./_generators.nix)
        ];

        options.secretRequests = mkOption {
          type = types.attrsOf (types.submodule ({ name, ... }: {
            options = {
              provider = mkOption {
                type = types.enum [ "agenix" ];
                default = "agenix";
                description = "Secret provider to fulfill this request.";
              };
              ageFile = mkOption {
                type = types.nullOr types.path;
                default = null;
                description = "Path to the age-encrypted secret file.";
              };
              mode = mkOption {
                type = types.str;
                default = "0400";
                description = "File permissions for the decrypted secret.";
              };
              owner = mkOption {
                type = types.str;
                default = "root";
                description = "User who should own the secret file.";
              };
              group = mkOption {
                type = types.str;
                default = "root";
                description = "Group who should own the secret file.";
              };
              restartUnits = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = "Systemd units to restart when the secret file changes.";
              };
              generator = mkOption {
                type = types.nullOr (types.submodule {
                  options = {
                    script = mkOption {
                      type = types.either types.str (types.functionTo types.str);
                      description = ''
                        Name of a globally-defined agenix-rekey generator (e.g.
                        "ssh-key", "passphrase", "hex") or a function returning
                        a script. When set, `agenix generate` will produce the
                        secret content if the .age file does not exist yet.
                      '';
                    };
                  };
                });
                default = null;
                description = ''
                  Optional agenix-rekey generator. If set, the secret is
                  bootstrapped via `agenix generate` instead of requiring a
                  pre-existing master-key-encrypted .age file.
                '';
              };
            };
          }));
          default = { };
          description = ''
            Provider-agnostic secret requests. Services declare what secrets
            they need, and the agenix provider fulfills them.
          '';
        };

        config = {
          age = {
            identityPaths = [ "${persistPrefix}/etc/ssh/ssh_host_ed25519_key" ];

            rekey = {
              masterIdentities = [
                {
                  identity = inputs.self + "/.secrets/keys/master.age";
                  pubkey = inputs.self + "/.secrets/pub/master.pub";
                }
              ];
              storageMode = "local";
              hostPubkey = builtins.readFile host.public_key;
              generatedSecretsDir = host.secretPath + "/generated";
              localStorageDir = host.secretPath + "/rekeyed";
            };

            secrets = mapAttrs mkAgeSecret agenixReqs;
          };

          systemd.paths = mapAttrs' (name: _:
            nameValuePair "agenix-restart-${name}" {
              wantedBy = [ "multi-user.target" ];
              pathConfig.PathModified = config.age.secrets.${name}.path;
            }
          ) restartReqs;

          systemd.services = mapAttrs' (name: req:
            nameValuePair "agenix-restart-${name}" {
              serviceConfig.Type = "oneshot";
              serviceConfig.ExecStart = "${config.systemd.package}/bin/systemctl try-restart ${lib.concatStringsSep " " req.restartUnits}";
            }
          ) restartReqs;

          system.activationScripts = lib.mkIf (config.age.secrets != { }) {
            removeAgenixLink.text = "[[ ! -L /run/agenix ]] && [[ -d /run/agenix ]] && rm -rf /run/agenix";
            agenixNewGeneration.deps = [ "removeAgenixLink" ];
          };

          _module.args.secrets = lib.mapAttrs (_: v: v.path) config.age.secrets;
        } // {
          home-manager.sharedModules = [
            inputs.agenix.homeManagerModules.default
            inputs.agenix-rekey.homeManagerModules.default
            (
              { config, lib, ... }:
              {
                _module.args.secrets = lib.mapAttrs (_: v: v.path) config.age.secrets;
              }
            )
          ];
        };
      };

    persist = {
      # Agenix-rekey generators state
    };
  };
}
