# MicroVM guest resolver — producer/consumer pair that resolves guest
# host entities into microvm.vms.<name> definitions on the host.
#
# Based on sini's microvm-guests.nix but simplified:
# - No GPU passthrough (no gpuLib, no passthrough resolution, no vfio gates)
# - No root key injection from user registry (use bridge SSH / Tailscale SSH)
# - No gpu-claims quirk
# - Keeps the ro-store virtiofs share pattern + submodule opts extraction
{ den, lib, ... }: let
  roStoreShare = {
    source = "/nix/store";
    mountPoint = "/nix/.ro-store";
    tag = "ro-store";
    proto = "virtiofs";
  };

  # The microvm.nix `microvm.vms.<name>` submodule does NOT accept a top-level
  # `imports` key — its option set is closed (pkgs/config/autostart/...). So the
  # resolved "microvm" class module (which sets host-side submodule options such
  # as `pkgs`) is evaluated here into a flat attrset of those options, which the
  # consumer can splice directly into the submodule definition.
  microvmSubmoduleOpts = mod:
    (lib.evalModules {
      modules = [ mod { freeformType = lib.types.attrsOf lib.types.raw; } ];
    }).config;
in {
  # PRODUCE: host-parametric, eager. Resolve each guest to module data.
  den.aspects.virtualization.microvm-host.microvm-guests =
    { host, ... }: map (vm: {
      inherit (vm) name;
      osModules = den.lib.aspects.resolve vm.class (den.lib.resolveEntity "host" { host = vm; });
      microvmOpts = microvmSubmoduleOpts (den.lib.aspects.resolve "microvm" vm.aspect);
      sharedNixStore = host.microvm.sharedNixStore;
    }) host.microvm.guests;

  # CONSUME: turn each resolved guest into a microvm.vms.<name> definition.
  den.aspects.virtualization.microvm-host.nixos =
    { microvm-guests, config, ... }: {
      microvm.vms = lib.listToAttrs (map (g:
        lib.nameValuePair g.name (
          # Host-side submodule options (e.g. pkgs) from the microvm class…
          g.microvmOpts // {
            # …and the guest's full NixOS toplevel from its host pipeline.
            # The guest's nixos block includes microvm.shares, microvm.interfaces,
            # etc. directly (not via the microvm class), so we just splice
            # in the full resolved config.
            config = {
              imports = [ g.osModules ];
            };
          }
        )
      ) microvm-guests);
    };
}
