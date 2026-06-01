{ lib, inputs, ... }: {
  den.default.nixos =
    { config, lib, ... }:
    let
      inherit (lib) filterAttrs mapAttrs optionalAttrs;

      mkAgeSecret = name: req:
        {
          rekeyFile = req.ageFile;
          mode = req.mode or "0400";
          owner = req.owner or "root";
          group = req.group or "root";
        }
        // optionalAttrs (req.restartUnits or [ ] != [ ]) {
          inherit (req) restartUnits;
        };

      agenixReqs = filterAttrs (
        _: req: req.provider or "agenix" == "agenix" && req.ageFile or null != null
      ) config.secretRequests;
    in
    {
      config.age.secrets = mapAttrs mkAgeSecret agenixReqs;
    };
}
