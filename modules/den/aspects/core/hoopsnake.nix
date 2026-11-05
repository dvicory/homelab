{ inputs, ... }:
{
  den.aspects.core.hoopsnake.nixos =
    { host, ... }:
    let
      source = inputs.nixpkgs.legacyPackages.${host.system}.applyPatches {
        name = "hoopsnake-systemd-initrd-source";
        src = inputs.hoopsnake.outPath;
        patches = [ ./hoopsnake-systemd-initrd.patch ];
        # Reuse the exact patched source across build platforms.
        # Recompute when the Hoopsnake pin or patch changes.
        outputHashMode = "recursive";
        outputHash = "sha256-Xh9UZjT0DuWH3cDtS+s0MuxNslKYlVzX8FauhpDzGiE=";
      };
    in
    {
      imports = [
        (import "${source}/nixos/module.nix" {
          withSystem =
            system: f:
            f {
              config.packages.default = inputs.hoopsnake.packages.${system}.default;
            };
        })
      ];
    };
}
