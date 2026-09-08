{
  den,
  inputs,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;
  runtimeSecretsType = types.attrsOf (
    types.submodule {
      options = {
        namespace = mkOption { type = types.strMatching "[a-z0-9]([-a-z0-9]*[a-z0-9])?"; };
        name = mkOption { type = types.strMatching "[a-z0-9]([-a-z0-9.]*[a-z0-9])?"; };
        key = mkOption { type = types.strMatching "[a-zA-Z0-9._-]+"; };
        type = mkOption {
          type = types.strMatching "[A-Za-z0-9./-]+";
          default = "Opaque";
        };
      };
    }
  );
in
{
  den.aspects.virtualization.compute.settings.options.runtimeSecrets = mkOption {
    type = runtimeSecretsType;
    default = { };
    description = "Kubernetes runtime files keyed namespace--secret--key; encrypted inputs live under the guest's host secret directory.";
  };

  den.aspects.services."kubernetes-runtime-secrets" = {
    nixos =
      {
        host,
        pkgs,
        lib,
        ...
      }:
      let
        cfg = host.settings.virtualization.compute;
        secretPath = "/run/homelab-compute/secrets";
        secretNames = builtins.attrNames cfg.runtimeSecrets;
        targetTriples = map (
          source:
          let
            entry = cfg.runtimeSecrets.${source};
          in
          "${entry.namespace}/${entry.name}/${entry.key}"
        ) secretNames;
        secretGroups = lib.groupBy (
          source:
          let
            entry = cfg.runtimeSecrets.${source};
          in
          "${entry.namespace}/${entry.name}"
        ) secretNames;
        secretAge = name: inputs.self + "/.secrets/hosts/${cfg.instance}/${name}.age";
      in
      assert lib.assertMsg (
        lib.unique targetTriples == targetTriples
      ) "Runtime Secret declarations must not duplicate namespace/name/key targets.";
      {
        secretRequests =
          lib.genAttrs (lib.filter (name: builtins.pathExists (secretAge name)) secretNames)
            (name: {
              provider = "agenix";
              ageFile = secretAge name;
              mode = "0400";
              restartUnits = [ "compute-stage-secrets.service" ];
            });

        systemd.services.compute-stage-secrets = {
          description = "Stage declared Kubernetes runtime Secrets";
          wantedBy = lib.optional (secretNames != [ ]) "multi-user.target";
          before = [ "incus.service" ];
          path = [
            pkgs.coreutils
            pkgs.util-linux
            pkgs.kubectl
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            set -eu
            umask 077
            exec 9>/run/lock/compute-${cfg.project}-${cfg.instance}.lock
            flock -n 9
            root=${lib.escapeShellArg secretPath}
            mkdir -p "$root"
            if mountpoint -q "$root"; then
              test "$(findmnt -n -o FSTYPE -M "$root")" = tmpfs
            else
              mount -t tmpfs -o ro,uid=${toString cfg.idmapBase},gid=${toString cfg.idmapBase},mode=0700,size=1m tmpfs "$root"
            fi
            ${lib.concatMapStringsSep "\n" (name: ''
              test -s /run/agenix/${lib.escapeShellArg name}
            '') secretNames}
            mount -o remount,rw "$root"
            trap 'rm -f -- "$root/runtime-secrets.yaml.new"; mount -o remount,ro "$root"' EXIT
            {
              :
              ${lib.concatStringsSep "\n" (
                lib.mapAttrsToList (
                  _: sources:
                  let
                    entry = cfg.runtimeSecrets.${builtins.head sources};
                  in
                  assert lib.assertMsg (lib.all (
                    source: cfg.runtimeSecrets.${source}.type == entry.type
                  ) sources) "Runtime keys for ${entry.namespace}/${entry.name} must share one Secret type";
                  ''
                    kubectl create secret generic ${lib.escapeShellArg entry.name} \
                      --namespace ${lib.escapeShellArg entry.namespace} \
                      --type ${lib.escapeShellArg entry.type} \
                      ${
                        lib.concatMapStringsSep " " (
                          source:
                          "--from-file=" + lib.escapeShellArg "${cfg.runtimeSecrets.${source}.key}=/run/agenix/${source}"
                        ) sources
                      } --dry-run=client -o yaml
                    printf '\n---\n'
                  ''
                ) secretGroups
              )}
            } > "$root/runtime-secrets.yaml.new"
            chown ${toString cfg.idmapBase}:${toString cfg.idmapBase} "$root/runtime-secrets.yaml.new"
            chmod 0400 "$root/runtime-secrets.yaml.new"
            mv -f -- "$root/runtime-secrets.yaml.new" "$root/runtime-secrets.yaml"
          '';
        };
      };
  };
}
