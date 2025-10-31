# Hardcoded secret provider (Dendritic hybrid)
# Provides flake.modules.nixos.secret-hardcoded-provider
{ ... }:
{
  flake.modules.nixos.secret-hardcoded-provider =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib)
        mapAttrs'
        nameValuePair
        mkOption
        mkIf
        ;
      inherit (lib.types)
        attrsOf
        submodule
        str
        path
        ;
      contracts = config._contracts;
      cfg = config.dlab.hardcodedsecret;
    in
    {
      options.dlab.hardcodedsecret = mkOption {
        description = ''
          Hardcoded secret provider for testing.
          WARNING: This is for development/testing only!
          Secrets are stored in the Nix store and are world-readable.
        '';
        default = { };
        type = attrsOf (
          submodule (
            { name, ... }:
            {
              options = contracts.secret.mkProvider {
                settings = mkOption {
                  description = ''
                    Settings specific to hardcoded secret provider.
                  '';
                  type = submodule {
                    options = {
                      content = mkOption {
                        type = str;
                        description = "The secret content (stored in Nix store - NOT SECURE!)";
                      };
                      source = mkOption {
                        type = path;
                        description = "Path to a file containing the secret";
                      };
                    };
                  };
                };
                resultCfg = {
                  path = "/run/secrets/${name}";
                  pathText = "/run/secrets/<name>";
                };
              };
            }
          )
        );
      };
      config = {
        systemd.services = mapAttrs' (
          name: cfg':
          nameValuePair "hardcoded-secret-${name}" (
            mkIf (cfg'.request != null) {
              description = "Provision hardcoded secret: ${name}";
              wantedBy = [ "multi-user.target" ];
              before = cfg'.request.restartUnits;
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script =
                let
                  source =
                    if cfg'.settings ? content then
                      pkgs.writeText "${name}-secret" cfg'.settings.content
                    else
                      cfg'.settings.source;
                in
                ''
                  mkdir -p "$(dirname \"${cfg'.result.path}\")"
                  chmod ${cfg'.request.mode} "${cfg'.result.path}" 2>/dev/null || true
                  chown ${cfg'.request.owner}:${cfg'.request.group} "${cfg'.result.path}" 2>/dev/null || true
                  cp ${source} "${cfg'.result.path}"
                  chmod ${cfg'.request.mode} "${cfg'.result.path}"
                  chown ${cfg'.request.owner}:${cfg'.request.group} "${cfg'.result.path}"
                '';
            }
          )
        ) cfg;
      };
    };
}
