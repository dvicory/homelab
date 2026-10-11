{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  den.aspects.virtualization.compute = {
    settings.accelerator = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            vendor = mkOption {
              type = types.enum [ "intel" ];
              description = "GPU vendor. It selects the host's diagnostic tools and the workload's acceleration API.";
            };
            pciAddress = mkOption {
              type = types.strMatching "[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\\.[0-7]";
              description = "PCI address of the granted device on the host.";
            };
            source = mkOption {
              type = types.strMatching "/dev/dri/renderD[0-9]+";
              description = ''
                Host render node passed to the guest. Not a `/dev/dri/by-path`
                link: udev creates those by rename, which Incus 7.4 does not
                see, so the node never reaches a running guest.
              '';
            };
            path = mkOption {
              type = types.str;
              default = "/dev/dri/renderD128";
              readOnly = true;
              description = "Render node path inside the guest, whatever the host node is called.";
            };
          };
        }
      );
      default = null;
      description = ''
        Host GPU whose render node the guest receives. Declaring it makes the
        host the GPU's driving domain. Workloads still need the `gpu-render`
        group.
      '';
    };

    # The host side of the grant; compute.nix renders the guest's device.
    nixos =
      { host, pkgs, ... }:
      let
        accelerator = host.settings.virtualization.compute.accelerator;
      in
      lib.mkIf (accelerator != null) {
        # The host drives the GPU, so it owns the firmware (GuC and HuC on Intel).
        hardware.enableRedistributableFirmware = true;
        environment.systemPackages =
          {
            intel = [ pkgs.intel-gpu-tools ];
          }
          .${accelerator.vendor};

        # systemd's default rules make render nodes 0666. This later rule
        # limits them to `render`; Incus creates the guest's node separately.
        # A new render node reruns the source check.
        services.udev.extraRules = ''
          SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render", MODE="0660"
          ACTION=="add", SUBSYSTEM=="drm", KERNEL=="renderD*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="compute-accelerator-source.service"
        '';

        # Fails when the granted node belongs to another PCI device. A missing
        # node is a missing GPU, which the guest tolerates.
        systemd.services.compute-accelerator-source = {
          description = "Check that the compute accelerator source is the declared device";
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "oneshot";
          script = ''
            source=${lib.escapeShellArg accelerator.source}
            declared=${lib.escapeShellArg accelerator.pciAddress}
            if [ ! -e "$source" ]; then
              echo "accelerator source $source is absent; the guest runs without it"
              exit 0
            fi
            actual=$(basename "$(readlink -f "/sys/class/drm/$(basename "$source")/device")")
            if [ "$actual" != "$declared" ]; then
              echo "DRIFT: accelerator source $source belongs to $actual, not the declared $declared" >&2
              exit 1
            fi
            echo "accelerator source $source belongs to the declared device $declared"
          '';
        };
      };
  };
}
