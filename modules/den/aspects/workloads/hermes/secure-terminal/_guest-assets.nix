# Immutable guest asset catalog (V3 §9.3).
#
# One shared constructor builds small, named NixOS guest assets through
# gondolin-nix's mkGondolinGuestAssets. Security policy never assembles
# images dynamically; profiles/worklanes select named (asset, template)
# pairs. Offline vs networked and anonymous vs authenticated are policy
# differences, not duplicate root filesystems.
#
# Each asset embeds a deterministic Gondolin-compatible buildId in its
# manifest.json (kernel/initramfs/rootfs/helper-stack content), which the
# broker reads at startup for generation identity.
{ inputs }:

let
  # CA trust and base environment shared by every asset.
  baseGuestModule = { pkgs, ... }: {
    environment.etc."ssl/certs/ca-bundle.crt".source = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    environment.variables = {
      SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
      GIT_SSL_CAINFO = "/etc/ssl/certs/ca-bundle.crt";
      NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
      CURL_CA_BUNDLE = "/etc/ssl/certs/ca-bundle.crt";
    };

    # Keep early PID 1 diagnostics on the QEMU console. Intermittent failures
    # happen while systemd runs generators, before journald is available.
    systemd.settings.Manager = {
      LogLevel = "debug";
      LogTarget = "console";
      LogLocation = true;
    };
  };

  # general: full development surface for project/research work.
  generalGuestModule = { pkgs, ... }: {
    environment.systemPackages = with pkgs; [
      nodejs_22
      python3
      git
      curl
      jq
      bashInteractive
      coreutils
      findutils
      gnugrep
      gnused
      gawk
      gnutar
      gzip
      bzip2
      xz
      zip
      unzip
      patch
    ];
  };

  # minimal: narrow surface for authenticated or sensitive operations.
  minimalGuestModule = { pkgs, ... }: {
    environment.systemPackages = with pkgs; [
      gitMinimal
      curl
      jq
      bashInteractive
      coreutils
      findutils
    ];
  };

  mkAsset =
    hostSystem: name: guestModule:
    inputs.gondolin-nix.lib.mkGondolinGuestAssets {
      inherit hostSystem;
      modules = [
        baseGuestModule
        guestModule
        {
          virtualisation.gondolin.guest.rootfsLabel = "gondolin-${name}";
        }
      ];
    };

in
{
  # Build the catalog for one host system. Keys match policy asset names.
  mkGuestAssets = hostSystem: {
    general = mkAsset hostSystem "general" generalGuestModule;
    minimal = mkAsset hostSystem "minimal" minimalGuestModule;
  };
}
