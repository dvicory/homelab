{ config, den, ... }:
let
  renderGid = config.den.groups.gpu-render.gid;
in
{
  den.aspects.virtualization.i915-native-guest.nixos =
    { lib, pkgs, ... }:
    let
      gpu = import ../../../../pkgs/by-name/gpu-native-context/package.nix { inherit pkgs; };
      replacedProviders = map lib.getName [
        gpu.mesa
        gpu.mediaDriver
        gpu.vpl
      ];
    in
    {
      config.users.groups.gpu-render.gid = renderGid;
      config.services.udev.extraRules = ''
        SUBSYSTEM=="drm", KERNEL=="renderD128", GROUP="gpu-render", MODE="0660"
      '';
      config.systemd.tmpfiles.settings."i915-native-guest"."/dev/dri".d = {
        mode = "0755";
        user = "root";
        group = "root";
      };

      # Replace only providers already contained in the private bundle. Other
      # extra drivers remain registered; unrecognized file conflicts still fail.
      options.hardware.graphics.extraPackages = lib.mkOption {
        apply =
          packages:
          builtins.filter (package: !(builtins.elem (lib.getName package) replacedProviders)) packages;
      };

      # Applications must link this dispatcher normally. Merely installing a
      # second libvpl in systemPackages would not change their library closure.
      config.nixpkgs.overlays = [
        (final: previous: {
          libvpl = import ../../../../pkgs/by-name/gpu-native-context/libvpl-driver-link.nix {
            pkgs = final;
            libvpl = previous.libvpl;
          };
        })
      ];

      # This explicit device profile replaces the default Mesa driver set.
      # NixOS publishes the bundle through its normal /run/opengl-driver link.
      config.hardware.graphics = {
        enable = true;
        package = lib.mkForce gpu.driverEnvironment;
      };
    };

  den.aspects.virtualization.i915-native-guest.provides.k3s = {
    includes = [ den.aspects.virtualization.i915-native-guest ];
    nixos =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      let
        gpu = import ../../../../pkgs/by-name/gpu-native-context/package.nix { inherit pkgs; };
        runtimeSpec = import ../../../../pkgs/by-name/gpu-native-context/k3s-runtime-spec.nix {
          inherit pkgs;
          inherit (gpu) driverEnvironment dispatcher;
          k3s = config.services.k3s.package;
          retainedRuntimeHook = config.system.build.retainedRuntimeHook or null;
        };
        runtimeClass = (pkgs.formats.json { }).generate "i915-native-runtime-class.json" {
          apiVersion = "node.k8s.io/v1";
          kind = "RuntimeClass";
          metadata.name = "i915-native";
          handler = "i915-native";
        };
        template = pkgs.writeText "i915-native-config-v3.toml.tmpl" ''
          {{ template "base" . }}

          [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.'i915-native']
            runtime_type = "io.containerd.runc.v2"
            base_runtime_spec = "${runtimeSpec}/config.json"

          [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.'i915-native'.options]
            SystemdCgroup = {{ .SystemdCgroup }}
        '';
        templateDirectory = "/var/lib/rancher/k3s/agent/etc/containerd";
        templateSource = "/etc/homelab/i915-native-k3s/config-v3.toml.tmpl";
      in
      {
        assertions = [
          {
            assertion = config.services.k3s.enable;
            message = "i915-native k3s requires the guest's ordinary embedded containerd.";
          }
          {
            assertion = config.services.k3s.containerdConfigTemplate == null;
            message = "i915-native k3s must not take over another containerd template.";
          }
          {
            assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
            message = "i915-native k3s entrypoints currently target the retained x86_64 Jellyfin image.";
          }
        ];

        # Artifacts only: neither a fleet selection nor an auto-deployed AddOn.
        system.build.i915NativeK3sRuntimeSpec = runtimeSpec;
        system.build.i915NativeK3sRuntimeClass = runtimeClass;
        environment.etc."homelab/i915-native-k3s/runtime-class.json".source = runtimeClass;
        environment.etc."homelab/i915-native-k3s/config-v3.toml.tmpl".source = template;

        # Refuse mutable/pre-existing competing templates, too. A stable owned
        # symlink permits profile updates without replacing somebody else's file.
        systemd.services.k3s.preStart = lib.mkBefore ''
          directory=${lib.escapeShellArg templateDirectory}
          target="$directory/config-v3.toml.tmpl"
          if [ -e "$directory/config.toml.tmpl" ] || [ -L "$directory/config.toml.tmpl" ]; then
            echo "i915-native k3s refuses an existing legacy containerd template" >&2
            exit 1
          fi
          if [ -e "$target" ] || [ -L "$target" ]; then
            if [ "$(${pkgs.coreutils}/bin/readlink "$target")" != ${lib.escapeShellArg templateSource} ]; then
              echo "i915-native k3s refuses an existing containerd v3 template" >&2
              exit 1
            fi
          else
            ${pkgs.coreutils}/bin/mkdir -p "$directory"
            ${pkgs.coreutils}/bin/ln -s ${lib.escapeShellArg templateSource} "$target"
          fi
        '';
        systemd.services.k3s.restartTriggers = [ template ];
      };
  };
}
