{ inputs, lib, ... }:
let
  # Released security updates awaiting Nixpkgs #586271 and #586269.
  # Remove once both ordinary-root compiler recipes include these releases.
  overlay =
    _final: prev:
    lib.mapAttrs
      (
        name: release:
        let
          compiler = prev.${name};
        in
        if lib.versionAtLeast compiler.version release.version then
          compiler
        else
          compiler.overrideAttrs {
            inherit (release) version;
            src = prev.fetchurl {
              url = "https://go.dev/dl/go${release.version}.src.tar.gz";
              inherit (release) hash;
            };
          }
      )
      {
        go_1_26 = {
          version = "1.26.11";
          hash = "sha256-1EEBsP8n7SpMda1GwXucdDWSCeLrLKfJ32y0/baOGWk=";
        };
        go_1_27 = {
          version = "1.27.4";
          hash = "sha256-c8+4VxrsDAEXdofbhxY9Rqog6XeWcncokaoXZU2aYJk=";
        };
      };
in
{
  perSystem = { system, ... }: {
    _module.args.pkgs = inputs.nixpkgs.legacyPackages.${system}.extend overlay;
  };

  den.schema.host.includes = [
    {
      name = "security/go-toolchains";
      os.nixpkgs.overlays = [ overlay ];
    }
  ];
}
