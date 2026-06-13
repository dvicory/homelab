{ pkgs, lib, ... }: {
  den.default.nixos =
    { config, ... }:
    let
      inherit (lib) mkIf mapAttrs' nameValuePair;

      hardcodedReqs = lib.filterAttrs (_: req: req.provider or "agenix" == "hardcoded") config.secretRequests;
    in
    mkIf (hardcodedReqs != { }) {
      systemd.services = mapAttrs' (name: req: let
        secretPath = req.key or "/run/secrets/${name}";
        source =
          if req ? content && req.content != null then
            pkgs.writeText "${name}-secret" req.content
          else if req ? source && req.source != null then
            req.source
          else
            throw "hardcoded secret '${name}' must specify either 'content' or 'source'";
      in
        nameValuePair "hardcoded-secret-${name}" {
          description = "Provision hardcoded secret: ${name}";
          wantedBy = [ "multi-user.target" ];
          before = req.restartUnits or [ ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            mkdir -p "$(dirname ${secretPath})"
            chmod ${req.mode or "0400"} "${secretPath}" 2>/dev/null || true
            chown ${req.owner or "root"}:${req.group or "root"} "${secretPath}" 2>/dev/null || true
            cp ${source} "${secretPath}"
            chmod ${req.mode or "0400"} "${secretPath}"
            chown ${req.owner or "root"}:${req.group or "root"} "${secretPath}"
          '';
        }
      ) hardcodedReqs;

      warnings = lib.optional (hardcodedReqs != { })
        "Hardcoded secrets used for: ${builtins.toString (builtins.attrNames hardcodedReqs)}";
    };
}
