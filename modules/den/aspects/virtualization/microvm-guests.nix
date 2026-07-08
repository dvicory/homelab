# MicroVM guest resolver — producer/consumer pair that resolves guest
# host entities into microvm.vms.<name> definitions on the host.
#
# Based on sini's microvm-guests.nix but simplified:
# - No GPU passthrough (no _gpu-passthrough-lib.nix, no gpu-claims quirk)
# - No root key injection from user registry (use bridge SSH / Tailscale SSH)
# - No gpu-claims quirk
{ den, inputs, lib, ... }: let
  microvmSubmoduleOpts = mod:
    (lib.evalModules {
      modules = [ mod { freeformType = lib.types.attrsOf lib.types.raw; } ];
    }).config;
in {
  den.aspects.virtualization.microvm-host.microvm-guests =
    { host, ... }: map (vm: {
      inherit (vm) name;
      osModules = den.lib.aspects.resolve vm.class (den.lib.resolveEntity "host" { host = vm; });
      microvmOpts = microvmSubmoduleOpts (den.lib.aspects.resolve "microvm" vm.aspect);
      sharedNixStore = host.microvm.sharedNixStore;
    }) host.microvm.guests;

  den.aspects.virtualization.microvm-host.nixos =
    { microvm-guests, ... }: {
      microvm.vms = lib.listToAttrs (map (g:
        lib.nameValuePair g.name (
          g.microvmOpts // {
            config = {
              # Include the home-manager NixOS module — the auto-applied
              # core.users.home-manager aspect (via den.schema.host.includes)
              # sets home-manager.* options that need the module to exist.
              # In the standalone fleet pipeline, this is added by instantiate;
              # in the microvm splice, we add it here.
              imports = [
                g.osModules
                inputs.home-manager.nixosModules.home-manager
              ];
            };
          }
        )
      ) microvm-guests);
    };
}
