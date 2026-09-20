{ inputs, ... }:
{
  den.aspects.services.kubernetes = {
    nixos =
      { config, pkgs, ... }:
      {
        assertions = [
          {
            assertion =
              config.services.k3s.package.version
              == inputs.nixpkgs.legacyPackages.${config.nixpkgs.hostPlatform.system}.k3s.version;
            message = "The K3s runtime must match the pinned package used to render Kubernetes manifests.";
          }
        ];
        # Metrics collectors reach the authenticated kubelet through Flannel's
        # local pod bridge, not the guest's external management interface.
        networking.firewall.interfaces.cni0.allowedTCPPorts = [ 10250 ];
        services.k3s = {
          enable = true;
          role = "server";
          # SQLite, Flannel, CoreDNS, and kube-proxy remain the supported
          # single-node path. Only packaged components outside this slice are
          # disabled.
          disable = [
            "local-storage"
            "servicelb"
            "traefik"
          ];
          extraFlags = [ "--snapshotter=overlayfs" ];
          extraKubeletConfig = {
            featureGates.KubeletInUserNamespace = true;
          };
          extraKubeProxyConfig = {
            mode = "iptables";
            clientConnection.kubeconfig = "/var/lib/rancher/k3s/agent/kubeproxy.kubeconfig";
            conntrack = {
              maxPerCore = 0;
              tcpEstablishedTimeout = "0s";
              tcpCloseWaitTimeout = "0s";
            };
          };
          # K3s's native template detects the outer user namespace and sets
          # disable_apparmor/restrict_oom_score_adj itself.
          images = [ config.services.k3s.package.airgap-images ];
        };
        systemd.services.kubernetes-runtime-secrets = {
          path = [
            pkgs.coreutils
            pkgs.gawk
            pkgs.gnugrep
          ];
          description = "Apply the atomically staged Kubernetes runtime Secrets";
          wantedBy = [ "multi-user.target" ];
          after = [ "k3s.service" ];
          requires = [ "k3s.service" ];
          unitConfig.ConditionPathExists = "/srv/secrets/runtime-secrets.commit";
          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = "5min";
            Restart = "on-failure";
            RestartSec = "15s";
            StateDirectory = "homelab-runtime-secrets";
            StateDirectoryMode = "0700";
          };
          script = ''
            set -euo pipefail
            kubectl() {
              ${config.services.k3s.package}/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml "$@"
            }
            root=/srv/secrets
            state=/var/lib/homelab-runtime-secrets
            snapshot="$state/snapshot.$$"
            desired="$snapshot/runtime-secrets.names"
            yaml="$snapshot/runtime-secrets.yaml"
            marker="$snapshot/runtime-secrets.commit"
            owned="$snapshot/owned"
            inventory="$state/owned"
            inventoryNew="$state/owned.new.$$"
            appliedNew="$state/applied-generation.new.$$"
            cleanup() {
              rm -rf -- "$snapshot" "$inventoryNew" "$appliedNew"
            }
            trap cleanup EXIT
            mkdir "$snapshot"
            cp -- "$root/runtime-secrets.commit" "$marker"
            cp -- "$root/runtime-secrets.names" "$desired"
            cp -- "$root/runtime-secrets.yaml" "$yaml"
            if [ -e "$inventory" ]; then
              cp -- "$inventory" "$owned"
            else
              : > "$owned"
            fi
            chmod 0400 "$marker" "$desired" "$yaml" "$owned"

            if ! ${pkgs.gawk}/bin/awk '
              NR == 1 && $0 ~ /^generation=[0-9a-f]{64} yaml-sha256=[0-9a-f]{64} names-sha256=[0-9a-f]{64}$/ { valid = 1 }
              END { exit !(valid && NR == 1) }
            ' "$marker"; then
              echo "Runtime Secret generation marker is malformed; refusing reconciliation." >&2
              exit 1
            fi
            IFS=' ' read -r generationField yamlField namesField extra < "$marker"
            [ -z "''${extra:-}" ] || {
              echo "Runtime Secret generation marker is malformed; refusing reconciliation." >&2
              exit 1
            }
            generation="''${generationField#generation=}"
            expectedYaml="''${yamlField#yaml-sha256=}"
            expectedNames="''${namesField#names-sha256=}"
            actualYaml="$(sha256sum "$yaml" | cut -d ' ' -f 1)"
            actualNames="$(sha256sum "$desired" | cut -d ' ' -f 1)"
            [ "$actualYaml" = "$expectedYaml" ] || {
              echo "Runtime Secret YAML checksum does not match generation; refusing reconciliation." >&2
              exit 1
            }
            [ "$actualNames" = "$expectedNames" ] || {
              echo "Runtime Secret inventory checksum does not match generation; refusing reconciliation." >&2
              exit 1
            }
            actualGeneration="$(printf '%s\n%s\n' "$actualYaml" "$actualNames" | sha256sum | cut -d ' ' -f 1)"
            [ "$actualGeneration" = "$generation" ] || {
              echo "Runtime Secret generation ID does not match staged files; refusing reconciliation." >&2
              exit 1
            }

            LC_ALL=C sort "$desired" > "$snapshot/desired.sorted"
            cmp -s "$desired" "$snapshot/desired.sorted" || {
              echo "Runtime Secret desired inventory is not canonical; refusing reconciliation." >&2
              exit 1
            }
            if LC_ALL=C uniq -d "$desired" | grep -q .; then
              echo "Runtime Secret desired inventory contains duplicates; refusing reconciliation." >&2
              exit 1
            fi
            if ! ${pkgs.gawk}/bin/awk -F '\t' '
              NF != 2 ||
              length($1) > 63 || length($2) > 253 ||
              $1 !~ /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/ ||
              $2 !~ /^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$/ { invalid = 1 }
              END { exit invalid }
            ' "$desired"; then
              echo "Runtime Secret desired inventory is malformed; refusing reconciliation." >&2
              exit 1
            fi
            if ! ${pkgs.gawk}/bin/awk -F '\t' '
              NF != 3 ||
              length($1) > 63 || length($2) > 253 ||
              $1 !~ /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/ ||
              $2 !~ /^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$/ ||
              $3 == "" || $3 ~ /[[:space:]]/ { invalid = 1 }
              END { exit invalid }
            ' "$owned"; then
              echo "Runtime Secret ownership inventory is malformed; refusing reconciliation." >&2
              exit 1
            fi
            if LC_ALL=C cut -f1,2 "$owned" | sort | uniq -d | grep -q .; then
              echo "Runtime Secret ownership inventory contains duplicates; refusing reconciliation." >&2
              exit 1
            fi

            if test -s "$yaml"; then
              # Reconcile source-owned keys after application bootstrap edits;
              # server-side apply preserves undeclared application-owned keys.
              if kubectl apply --server-side --force-conflicts \
                --field-manager=homelab-runtime-secrets \
                -f "$yaml" >/dev/null 2>&1; then
                :
              else
                status=$?
                echo "Runtime Secret reconciliation failed (exit $status); native output suppressed." >&2
                exit "$status"
              fi
            fi
            if [ ! -e "$inventory" ]; then
              : > "$inventory"
              chmod 0600 "$inventory"
            fi
            while IFS="$(printf '\t')" read -r namespace name uid extra; do
              found=false
              while IFS="$(printf '\t')" read -r desiredNamespace desiredName; do
                if [ "$namespace" = "$desiredNamespace" ] && [ "$name" = "$desiredName" ]; then
                  found=true
                  break
                fi
              done < "$desired"
              [ "$found" = false ] || continue
              if currentUID="$(kubectl get secret "$name" --namespace "$namespace" \
                --ignore-not-found -o jsonpath='{.metadata.uid}')"; then
                :
              else
                status=$?
                echo "Runtime Secret UID inspection failed (exit $status); native output suppressed." >&2
                exit "$status"
              fi
              [ -n "$currentUID" ] && [ "$currentUID" = "$uid" ] || continue
              if printf '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"%s","namespace":"%s","uid":"%s"},"type":"Opaque"}\n' \
                "$name" "$namespace" "$uid" |
                kubectl apply --server-side --force-conflicts \
                  --field-manager=homelab-runtime-secrets -f - >/dev/null 2>&1; then
                :
              else
                status=$?
                echo "Runtime Secret retirement failed (exit $status); native output suppressed." >&2
                exit "$status"
              fi
            done < "$owned"
            : > "$inventoryNew"
            while IFS="$(printf '\t')" read -r namespace name extra; do
              if uid="$(kubectl get secret "$name" --namespace "$namespace" \
                -o jsonpath='{.metadata.uid}')"; then
                :
              else
                status=$?
                echo "Runtime Secret UID recording failed (exit $status); native output suppressed." >&2
                exit "$status"
              fi
              [ -n "$uid" ] || {
                echo "Runtime Secret has no UID after reconciliation; refusing inventory update." >&2
                exit 1
              }
              printf '%s\t%s\t%s\n' "$namespace" "$name" "$uid" >> "$inventoryNew"
            done < "$desired"
            chmod 0600 "$inventoryNew"
            mv -f -- "$inventoryNew" "$inventory"
            printf '%s\n' "$generation" > "$appliedNew"
            chmod 0600 "$appliedNew"
            mv -f -- "$appliedNew" "$state/applied-generation"
            echo "Declared runtime Secrets reconciled."
          '';
        };
        systemd.paths.kubernetes-runtime-secrets = {
          wantedBy = [ "multi-user.target" ];
          pathConfig = {
            PathChanged = "/srv/secrets/runtime-secrets.commit";
            Unit = "kubernetes-runtime-secrets.service";
          };
        };
      };
  };
}
