{
  den,
  inputs,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;
  sourceNamePattern = "^[A-Za-z0-9][A-Za-z0-9._-]*$";
  validSourceName =
    name: name != "." && name != ".." && builtins.match sourceNamePattern name != null;
  runtimeSecretsType = types.attrsOf (
    types.submodule {
      options = {
        namespace = mkOption { type = types.strMatching "[a-z0-9]([-a-z0-9]*[a-z0-9])?"; };
        name = mkOption { type = types.strMatching "[a-z0-9]([-a-z0-9.]*[a-z0-9])?"; };
        key = mkOption { type = types.strMatching "[a-zA-Z0-9._-]+"; };
        type = mkOption {
          type = types.enum [
            "Opaque"
            "kubernetes.io/tls"
          ];
          default = "Opaque";
        };
        generator = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Name of an age.generators entry that `agenix generate` uses to bootstrap this value; null means the operator supplies it with `agenix edit`.";
        };
      };
    }
  );
in
{
  den.aspects.virtualization.compute.settings.runtimeSecrets = mkOption {
    type = runtimeSecretsType;
    apply =
      value:
      let
        invalid = lib.filter (name: !(validSourceName name)) (builtins.attrNames value);
      in
      assert lib.assertMsg (invalid == [ ])
        "Runtime Secret source names must be basename-only identifiers: ${lib.concatStringsSep ", " invalid}";
      value;
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
        runtimeSecretLabel = "homelab.danielvicory/runtime-secret=true";
        invalidSourceNames = lib.filter (name: !(validSourceName name)) secretNames;
        desiredNames = lib.sort builtins.lessThan (
          lib.mapAttrsToList (
            _: sources:
            let
              entry = cfg.runtimeSecrets.${builtins.head sources};
              keys = lib.sort builtins.lessThan (map (source: cfg.runtimeSecrets.${source}.key) sources);
            in
            "${entry.namespace}\t${entry.name}\t${entry.type}\t${lib.concatStringsSep "," keys}"
          ) secretGroups
        );
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
        generatorOf = name: cfg.runtimeSecrets.${name}.generator;
        delivered = name: builtins.pathExists (secretAge name) || generatorOf name != null;
        argoValidation = lib.concatMapStringsSep "\n" (
          name:
          let
            entry = cfg.runtimeSecrets.${name};
          in
          if entry.namespace != "argocd" || entry.name != "argocd-secret" then
            ""
          else if entry.key == "admin.password" then
            ''
              value="$(${pkgs.coreutils}/bin/cat "$sourceSnapshot/${name}")"
              if [ "$(${pkgs.coreutils}/bin/wc -c < "$sourceSnapshot/${name}")" -ne "''${#value}" ] ||
                [ "$(printf '%s' "$value" | ${pkgs.coreutils}/bin/wc -l)" -ne 0 ] ||
                ! printf '%s' "$value" | ${pkgs.gnugrep}/bin/grep -Eq '^\$2[aby]\$(0[4-9]|[12][0-9]|3[01])\$[./A-Za-z0-9]{53}$'; then
                echo "Argo admin.password is not exactly one bcrypt hash; refusing publication." >&2
                exit 1
              fi
            ''
          else if entry.key == "admin.passwordMtime" then
            ''
              value="$(${pkgs.coreutils}/bin/cat "$sourceSnapshot/${name}")"
              if [ "$(${pkgs.coreutils}/bin/wc -c < "$sourceSnapshot/${name}")" -ne "''${#value}" ] ||
                [ "$(printf '%s' "$value" | ${pkgs.coreutils}/bin/wc -l)" -ne 0 ] ||
                ! printf '%s' "$value" | ${pkgs.gnugrep}/bin/grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$' ||
                ! ${pkgs.coreutils}/bin/date -u -d "$value" +%s >/dev/null 2>&1; then
                echo "Argo admin.passwordMtime is not exactly one RFC3339 timestamp; refusing publication." >&2
                exit 1
              fi
            ''
          else if entry.key == "server.secretkey" then
            ''
              value="$(${pkgs.coreutils}/bin/cat "$sourceSnapshot/${name}")"
              if [ "$(${pkgs.coreutils}/bin/wc -c < "$sourceSnapshot/${name}")" -ne "''${#value}" ] ||
                [ "$(printf '%s' "$value" | ${pkgs.coreutils}/bin/wc -l)" -ne 0 ] ||
                ! printf '%s' "$value" | ${pkgs.gnugrep}/bin/grep -Eq '^[A-Za-z0-9+/=_-]{32,}$'; then
                echo "Argo server.secretkey is not exactly one sufficiently long key; refusing publication." >&2
                exit 1
              fi
            ''
          else
            ""
        ) secretNames;
        stageRuntimeSecrets = pkgs.writeShellScript "stage-kubernetes-runtime-secrets" ''
          set -eu
          exec 8>/run/lock/compute-${cfg.project}-${cfg.instance}-secrets.lock
          ${pkgs.util-linux}/bin/flock 8
          expectedNamesChecksum="''${1:-}"
          export LC_ALL=C
          umask 077
          root=${lib.escapeShellArg secretPath}
          mkdir -p "$root"
          if mountpoint -q "$root"; then
            test "$(findmnt -n -o FSTYPE -M "$root")" = tmpfs
          else
            mount -t tmpfs -o ro,uid=${toString cfg.idmapBase},gid=${toString cfg.idmapBase},mode=0700,size=1m tmpfs "$root"
          fi
          sourceSnapshot=
          cleanup() {
            [ -z "$sourceSnapshot" ] || rm -rf -- "$sourceSnapshot"
            rm -f -- "$root/runtime-secrets.yaml.new" "$root/runtime-secrets.names.new" "$root/runtime-secrets.commit.new"
            mount -o remount,ro "$root"
          }
          trap cleanup EXIT
          mount -o remount,rw "$root"
          sourceSnapshot="$(mktemp -d "$root/.agenix.XXXXXX")"
          ${lib.optionalString (secretNames != [ ]) ''
            agenixRoot="$(readlink -e /run/agenix)"
            test -d "$agenixRoot"
            ${lib.concatMapStringsSep "\n" (name: ''
              install -m 0400 "$agenixRoot/${name}" "$sourceSnapshot/${name}"
              test -s "$sourceSnapshot/${name}"
            '') secretNames}
          ''}
          ${argoValidation}
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
                        "--from-file="
                        + lib.escapeShellArg cfg.runtimeSecrets.${source}.key
                        + "=\"$sourceSnapshot/${source}\""
                      ) sources
                    } --dry-run=client -o yaml \
                    | kubectl label --local -f - ${lib.escapeShellArg runtimeSecretLabel} -o yaml
                  printf '\n---\n'
                ''
              ) secretGroups
            )}
          } > "$root/runtime-secrets.yaml.new"
          : > "$root/runtime-secrets.names.new"
          ${lib.optionalString (desiredNames != [ ]) ''
            printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep "\n" desiredNames)} >> "$root/runtime-secrets.names.new"
          ''}
          yamlChecksum="$(${pkgs.coreutils}/bin/sha256sum "$root/runtime-secrets.yaml.new" | ${pkgs.coreutils}/bin/cut -d ' ' -f 1)"
          namesChecksum="$(${pkgs.coreutils}/bin/sha256sum "$root/runtime-secrets.names.new" | ${pkgs.coreutils}/bin/cut -d ' ' -f 1)"
          if [ -n "$expectedNamesChecksum" ] && [ "$namesChecksum" != "$expectedNamesChecksum" ]; then
            echo "Runtime Secret inventory does not match selected descriptor; refusing publication." >&2
            exit 1
          fi
          generationID="$(printf '%s\n%s\n' "$yamlChecksum" "$namesChecksum" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d ' ' -f 1)"
          printf 'generation=%s yaml-sha256=%s names-sha256=%s\n' \
            "$generationID" "$yamlChecksum" "$namesChecksum" > "$root/runtime-secrets.commit.new"
          chown ${toString cfg.idmapBase}:${toString cfg.idmapBase} \
            "$root/runtime-secrets.yaml.new" "$root/runtime-secrets.names.new" "$root/runtime-secrets.commit.new"
          chmod 0400 \
            "$root/runtime-secrets.yaml.new" "$root/runtime-secrets.names.new" "$root/runtime-secrets.commit.new"
          mv -f -- "$root/runtime-secrets.yaml.new" "$root/runtime-secrets.yaml"
          mv -f -- "$root/runtime-secrets.names.new" "$root/runtime-secrets.names"
          mv -f -- "$root/runtime-secrets.commit.new" "$root/runtime-secrets.commit"
        '';
      in
      assert lib.assertMsg (
        lib.unique targetTriples == targetTriples
      ) "Runtime Secret declarations must not duplicate namespace/name/key targets.";
      assert lib.assertMsg (invalidSourceNames == [ ])
        "Runtime Secret source names must be basename-only identifiers: ${lib.concatStringsSep ", " invalidSourceNames}";
      {
        secretRequests = lib.genAttrs (lib.filter delivered secretNames) (
          name:
          {
            provider = "agenix";
            ageFile = secretAge name;
            mode = "0400";
            restartUnits = [ "compute-stage-secrets.service" ];
          }
          // lib.optionalAttrs (generatorOf name != null) {
            generator.script = generatorOf name;
          }
        );

        systemd.services = {
          compute-stage-secrets = {
            description = "Stage declared Kubernetes runtime Secrets";
            wantedBy = [ "multi-user.target" ];
            before = [ "incus.service" ];
            path = [
              pkgs.coreutils
              pkgs.util-linux
              pkgs.kubectl
            ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              Restart = "on-failure";
              RestartSec = "15s";
            };
            script = ''
              set -eu
              exec 9>/run/lock/compute-${cfg.project}-${cfg.instance}.lock
              flock 9
              exec ${stageRuntimeSecrets}
            '';
          };

          "compute-stage-secrets-current@" = {
            description = "Stage the current declared Kubernetes runtime Secrets";
            path = [
              pkgs.coreutils
              pkgs.util-linux
              pkgs.kubectl
            ];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${stageRuntimeSecrets} %i";
            };
          };
        };
      };
  };
}
