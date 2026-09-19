{
  self,
  lib,
  system,
  hostName,
}:
let
  host = self.nixosConfigurations.${hostName};
  compute = builtins.fromJSON host.config.environment.etc."homelab/compute.json".text;
  native =
    configuration:
    if configuration.pkgs.stdenv.hostPlatform.system == system then
      configuration
    else
      configuration.extendModules {
        modules = [ { nixpkgs.hostPlatform = lib.mkForce system; } ];
      };
in
{
  # Keep the deployed architecture verbatim; other systems exercise the same
  # configuration as a hypothetical native host, not a cross-compiled guest.
  hostConfig = (native host).config;
  guest = native self.nixosConfigurations.${compute.instance};
}
