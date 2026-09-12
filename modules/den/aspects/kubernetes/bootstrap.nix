{ self, lib, ... }:
{
  perSystem =
    {
      config,
      pkgs,
      system,
      ...
    }:
    let
      environment = ../../../../generated/manifests/prod-home;
      manifests = pkgs.runCommand "household-static-bootstrap" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
        mkdir -p "$out"
        cp ${environment}/argocd-retained/Namespace-argocd.yaml "$out/namespaces.yaml"
        yq '.' ${environment}/argocd/CustomResourceDefinition-*.yaml > "$out/crds.yaml"
        rm -f "$out/controllers.yaml"
        first=1
        for file in ${environment}/argocd/*.yaml; do
          case "$(basename "$file")" in
            CustomResourceDefinition-*) ;;
            *)
              if [ "$first" -eq 1 ]; then first=0; else printf '\n---\n' >> "$out/controllers.yaml"; fi
              cat "$file" >> "$out/controllers.yaml"
              ;;
          esac
        done
        cp ${environment}/bootstrap.yaml "$out/root.yaml"
        yq 'select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet")' "$out/controllers.yaml" > "$out/readiness.yaml"
        yq 'select(.kind == "Prometheus" or .kind == "Alertmanager")' "$out/controllers.yaml" > "$out/operator-readiness.yaml"
        yq 'select(.kind == "Job")' "$out/controllers.yaml" > "$out/jobs.yaml"
        yq 'select(.kind == "Job" and .spec.ttlSecondsAfterFinished == null)' "$out/controllers.yaml" > "$out/persistent-jobs.yaml"
        yq 'select((.metadata.annotations."helm.sh/hook" // "") | contains("pre-install"))' "$out/controllers.yaml" > "$out/pre-install.yaml"
        yq 'select(.kind == "Job")' "$out/pre-install.yaml" > "$out/pre-install-jobs.yaml"
      '';
      bootstrap = pkgs.writeShellApplication {
        name = "household-bootstrap";
        runtimeInputs = with pkgs; [
          coreutils
          jq
          kubectl
          yq-go
        ];
        text = ''
          set -euo pipefail

          manifests=${lib.escapeShellArg manifests}

          # Test seam: a fixture host may point the same implementation at a
          # variant seed tree (e.g. a test-local root Application).
          if [ -n "''${HOUSEHOLD_BOOTSTRAP_MANIFESTS:-}" ]; then
            manifests=$HOUSEHOLD_BOOTSTRAP_MANIFESTS
          fi

          usage() {
            cat <<'EOF'
          Usage:
            household-bootstrap --status
            household-bootstrap --fresh-cluster
            household-bootstrap --retry-jobs
            household-bootstrap --check-ready

          --status         Read-only report of declared controllers and bootstrap Jobs.
          --fresh-cluster  Apply the Argo namespace, CRDs and controllers without pruning or Git.
          --retry-jobs     Recreate only declared terminal Failed hook Jobs.
          --check-ready    Block until the declared node, controllers and Jobs are ready.
          EOF
          }

          check_argo() {
            local crd applications
            if ! crd=$(kubectl get crd applications.argoproj.io --ignore-not-found -o name); then
              echo 'Unable to inspect Argo Applications; refusing static operation.' >&2
              return 1
            fi
            if [ -n "$crd" ]; then
              if ! applications=$(kubectl get applications.argoproj.io --all-namespaces -o name); then
                echo 'Unable to inspect Argo Applications; refusing static operation.' >&2
                return 1
              fi
              if [ -n "$applications" ]; then
                echo 'Refusing static operation while Argo Applications exist.' >&2
                return 1
              fi
            fi
          }

          report_file() {
            local file=$1 kind namespace name object desired ready succeeded state details
            local unavailable=0
            while IFS=$'\t' read -r kind namespace name; do
              [ -n "$name" ] || continue
              if ! object=$(kubectl get "$kind" "$name" --namespace "$namespace" \
                --ignore-not-found -o json 2>/dev/null); then
                printf '  UNAVAILABLE %s %s/%s\n' "$kind" "$namespace" "$name"
                unavailable=1
                continue
              fi
              if [ -z "$object" ]; then
                printf '  MISSING %s %s/%s\n' "$kind" "$namespace" "$name"
                continue
              fi
              if ! jq -e --arg name "$name" '.metadata.name == $name' <<<"$object" >/dev/null; then
                printf '  UNAVAILABLE %s %s/%s\n' "$kind" "$namespace" "$name"
                unavailable=1
                continue
              fi
              case "$kind" in
                Deployment|StatefulSet)
                  desired=$(jq -r '.spec.replicas // 1' <<<"$object")
                  ready=$(jq -r '.status.readyReplicas // 0' <<<"$object")
                  if [[ "$desired" =~ ^[0-9]+$ && "$ready" =~ ^[0-9]+$ ]] &&
                    (( ready == desired )); then
                    state=READY
                  else
                    state=NOT_READY
                  fi
                  details="$ready/$desired ready"
                  ;;
                DaemonSet)
                  desired=$(jq -r '.status.desiredNumberScheduled // 0' <<<"$object")
                  ready=$(jq -r '.status.numberReady // 0' <<<"$object")
                  if [[ "$desired" =~ ^[0-9]+$ && "$ready" =~ ^[0-9]+$ ]] &&
                    (( desired > 0 && ready == desired )); then
                    state=READY
                  else
                    state=NOT_READY
                  fi
                  details="$ready/$desired ready"
                  ;;
                Prometheus|Alertmanager)
                  state=NOT_READY
                  if jq -e 'any(.status.conditions[]?;
                    .type == "Available" and .status == "True" and
                    .observedGeneration == $generation)' \
                    --argjson generation "$(jq '.metadata.generation' <<<"$object")" \
                    <<<"$object" >/dev/null; then
                    state=READY
                  fi
                  details=$(jq -r '.status.conditions[]? | select(.type == "Available") | .reason' <<<"$object")
                  ;;
                Job)
                  desired=$(jq -r '.spec.completions // 1' <<<"$object")
                  succeeded=$(jq -r '.status.succeeded // 0' <<<"$object")
                  if jq -e 'any(.status.conditions[]?; .type == "Complete" and .status == "True")' <<<"$object" >/dev/null; then
                    state=READY
                  elif jq -e 'any(.status.conditions[]?; .type == "Failed" and .status == "True")' <<<"$object" >/dev/null; then
                    state=FAILED
                  else
                    state=NOT_READY
                  fi
                  details="$succeeded/$desired succeeded"
                  ;;
                *)
                  state=UNKNOWN
                  details='unsupported declared kind'
                  ;;
              esac
              printf '  %s %s %s/%s (%s)\n' "$state" "$kind" "$namespace" "$name" "$details"
            done < <(
              yq -r -N '
                select(.kind != null and .metadata.name != null) |
                [.kind, (.metadata.namespace // "default"), .metadata.name] | @tsv
              ' "$file"
            )
            return "$unavailable"
          }

          status() {
            local unavailable=0
            echo 'Declared controllers:'
            if [ -s "$manifests/readiness.yaml" ]; then
              report_file "$manifests/readiness.yaml" || unavailable=1
            else
              echo '  (none declared)'
            fi
            if [ -s "$manifests/operator-readiness.yaml" ]; then
              report_file "$manifests/operator-readiness.yaml" || unavailable=1
            fi
            echo 'Declared bootstrap Jobs:'
            if [ -s "$manifests/jobs.yaml" ]; then
              report_file "$manifests/jobs.yaml" || unavailable=1
            else
              echo '  (none declared)'
            fi
            echo 'Missing TTL-managed Helm Jobs may have been collected; their completion history is not retained.'
            return "$unavailable"
          }

          retry_jobs() {
            local kind namespace name policy object active failed_condition complete_condition current_policy
            local -a retry_targets=()

            check_argo
            while IFS=$'\t' read -r kind namespace name policy; do
              [ "$kind" = Job ] || continue
              case ",$policy," in
                *,BeforeHookCreation,*) ;;
                *) continue ;;
              esac
              if ! object=$(kubectl get job "$name" --namespace "$namespace" \
                --ignore-not-found -o json 2>/dev/null); then
                echo "Unable to inspect declared Job $namespace/$name; refusing retry." >&2
                return 1
              fi
              if [ -z "$object" ]; then
                echo "Declared Job $namespace/$name is missing; refusing retry." >&2
                return 1
              fi
              active=$(jq -r '.status.active // 0' <<<"$object")
              if ! [[ "$active" =~ ^[0-9]+$ ]]; then
                echo "Declared Job $namespace/$name has unknown activity; refusing retry." >&2
                return 1
              fi
              if (( active > 0 )); then
                echo "Declared Job $namespace/$name is active; refusing retry." >&2
                return 1
              fi
              failed_condition=$(jq -r '
                any(.status.conditions[]?; .type == "Failed" and .status == "True")
              ' <<<"$object")
              complete_condition=$(jq -r '
                any(.status.conditions[]?; .type == "Complete" and .status == "True")
              ' <<<"$object")
              if [ "$failed_condition" = true ]; then
                retry_targets+=("$namespace"$'\t'"$name")
              elif [ "$complete_condition" = true ]; then
                :
              else
                echo "Declared Job $namespace/$name is not terminal; refusing retry." >&2
                return 1
              fi
            done < <(
              yq -r -N '
                select(.kind == "Job") |
                [
                  (.kind),
                  (.metadata.namespace // "default"),
                  .metadata.name,
                  (.metadata.annotations."argocd.argoproj.io/hook-delete-policy" // "")
                ] | @tsv
              ' "$manifests/jobs.yaml"
            )

            if [ "''${#retry_targets[@]}" -eq 0 ]; then
              echo 'No declared terminal Failed Jobs require retry.'
              return 0
            fi
            local target selected
            for target in "''${retry_targets[@]}"; do
              IFS=$'\t' read -r namespace name <<<"$target"
              check_argo
              if ! object=$(kubectl get job "$name" --namespace "$namespace" \
                --ignore-not-found -o json 2>/dev/null); then
                echo "Unable to recheck declared Job $namespace/$name; refusing retry." >&2
                return 1
              fi
              if [ -z "$object" ]; then
                echo "Declared Job $namespace/$name disappeared; refusing retry." >&2
                return 1
              fi
              current_policy=$(jq -r '.metadata.annotations."argocd.argoproj.io/hook-delete-policy" // ""' <<<"$object")
              case ",$current_policy," in
                *,BeforeHookCreation,*) ;;
                *)
                  echo "Declared Job $namespace/$name no longer has BeforeHookCreation; refusing retry." >&2
                  return 1
                  ;;
              esac
              active=$(jq -r '.status.active // 0' <<<"$object")
              failed_condition=$(jq -r '
                any(.status.conditions[]?; .type == "Failed" and .status == "True")
              ' <<<"$object")
              if ! [[ "$active" =~ ^[0-9]+$ ]] || (( active > 0 )) ||
                [ "$failed_condition" != true ]; then
                echo "Declared Job $namespace/$name is no longer a terminal Failed Job; refusing retry." >&2
                return 1
              fi
              selected=$(namespace="$namespace" name="$name" yq -o=yaml '
                select(
                  .kind == "Job" and
                  (.metadata.namespace // "default") == strenv(namespace) and
                  .metadata.name == strenv(name)
                )
              ' "$manifests/jobs.yaml")
              [ -n "$selected" ] || {
                echo "Declared Job $namespace/$name could not be selected; refusing retry." >&2
                return 1
              }
              echo "Retrying terminal Failed Job $namespace/$name."
              kubectl delete job "$name" --namespace "$namespace" \
                --cascade=foreground --wait=true --timeout=120s
              printf '%s\n' "$selected" |
                kubectl apply --server-side --field-manager=argocd-controller -f -
            done
            echo 'Declared terminal Failed Jobs were recreated; run household-bootstrap --status or --check-ready.'
          }


          check_ready() {
            cat >&2 <<'EOF'
          Readiness prerequisites: stage all declared runtime credentials through agenix.
          This command checks the replacement node and Argo seed only. Native
          first-run enrollment and application acceptance remain separate checks.
          EOF
            kubectl wait --for=condition=Ready nodes --all --timeout=180s
            kubectl rollout status --timeout=600s -f "$manifests/readiness.yaml"
            if [ -s "$manifests/operator-readiness.yaml" ]; then
              kubectl wait --for=condition=Available --timeout=600s -f "$manifests/operator-readiness.yaml"
            fi
            if [ -s "$manifests/persistent-jobs.yaml" ]; then
              kubectl wait --for=condition=Complete --timeout=600s -f "$manifests/persistent-jobs.yaml"
            fi
            echo 'Replacement node and Argo seed are ready. Apply the canonical root Application next.'
          }


          fresh_cluster() {
            check_argo
            kubectl apply --server-side --field-manager=argocd-controller -f "$manifests/namespaces.yaml"
            kubectl apply --server-side --field-manager=argocd-controller -f "$manifests/crds.yaml"
            # New CRDs can report null conditions, which kubectl wait rejects.
            local deadline=$((SECONDS + 180)) remaining crds
            while :; do
              remaining=$((deadline - SECONDS))
              if [ "$remaining" -le 0 ]; then
                echo 'Timed out waiting for all Argo CRDs to become Established.' >&2
                return 1
              fi
              crds=$(kubectl get --request-timeout="$remaining"s -f "$manifests/crds.yaml" -o json)
              if jq -e '
                (.items // [.]) | length > 0 and
                all(.[]; any(.status.conditions[]?; .type == "Established" and .status == "True"))
              ' <<<"$crds" >/dev/null; then
                break
              fi
              sleep 1
            done
            echo 'All Argo CRDs are established.'
            # Honour the chart's pre-install boundary: Redis credentials must
            # exist before controller rollout deadlines start.
            if [ -s "$manifests/pre-install.yaml" ]; then
              kubectl apply --server-side --field-manager=argocd-controller -f "$manifests/pre-install.yaml"
              if [ -s "$manifests/pre-install-jobs.yaml" ]; then
                kubectl wait --for=condition=Complete --timeout=600s -f "$manifests/pre-install-jobs.yaml"
              fi
            fi
            # Apply the remaining seed after its prerequisite hooks complete.
            for _ in $(seq 1 60); do
              if kubectl apply --server-side --field-manager=argocd-controller -f "$manifests/controllers.yaml"; then
                echo 'Argo seed applied, not yet ready. Run household-bootstrap --check-ready, then apply the canonical root Application.'
                return 0
              fi
              sleep 5
            done
            echo 'Argo seed failed to converge.' >&2
            return 1
          }

          if [ "$#" -eq 1 ] && [ "$1" = "--help" ]; then
            usage
            exit 0
          fi
          if [ "$#" -ne 1 ]; then
            usage >&2
            exit 2
          fi
          case "$1" in
            --status) status ;;
            --fresh-cluster) fresh_cluster ;;
            --retry-jobs) retry_jobs ;;
            --check-ready) check_ready ;;
            *) usage >&2; exit 2 ;;
          esac
        '';
      };
    in
    {
      checks.household-bootstrap-crds =
        pkgs.runCommand "household-bootstrap-crds" { nativeBuildInputs = [ pkgs.yq-go ]; }
          ''
            yq ea -e '[select(.kind == "CustomResourceDefinition") | .metadata.name] | sort | join(",") == "applications.argoproj.io,applicationsets.argoproj.io,appprojects.argoproj.io"' \
              ${manifests}/crds.yaml > /dev/null
            touch "$out"
          '';

      packages = {
        household-bootstrap-manifests = manifests;
        household-bootstrap = bootstrap;
      }
      // lib.optionalAttrs (lib.hasSuffix "-linux" system) (
        let
          image = self.packages.${system}.kanidm-provision-image;
          computeGuest = self.packages.${system}.compute-guest;
          hostBootstrap = pkgs.writeShellApplication {
            name = "household-bootstrap-host";
            runtimeInputs = with pkgs; [
              computeGuest
              coreutils
              incus
              jq
              kubectl
              yq-go
              util-linux
            ];
            text = ''
              set -euo pipefail

              usage() {
                cat <<'EOF'
              Usage: household-bootstrap-host DESCRIPTOR --confirm INSTANCE

              Deliver the Argo seed to an existing Running Incus guest, then hand off to Git reconciliation.
              The command never creates/deletes guests, publishes Git,
              changes host configuration, or generates credentials.
              EOF
              }
              die() {
                echo "household-bootstrap-host: $1" >&2
                exit 1
              }

              if [ "$#" -eq 1 ] && [ "$1" = "--help" ]; then
                usage
                exit 0
              fi
              if [ "$#" -ne 3 ] || [ "$2" != "--confirm" ]; then
                usage >&2
                exit 2
              fi
              [ "$(id -u)" -eq 0 ] || die 'run as root on the physical Linux Incus host'

              descriptor=$1
              descriptor_target=$(readlink -f -- "$descriptor") ||
                die "cannot resolve descriptor: $descriptor"
              [ -f "$descriptor_target" ] || die 'descriptor is not a regular file'
              [ "$(stat -c %u "$descriptor_target")" = 0 ] ||
                die 'descriptor must be root-owned'
              descriptor_mode=$(stat -c %a "$descriptor_target")
              if (( 0$descriptor_mode & 022 )); then
                die 'descriptor must not be writable by group or other users'
              fi
              descriptor_json=$(cat "$descriptor_target") ||
                die 'cannot read descriptor'
              project=$(jq -er '.project | strings | select(length > 0)' <<<"$descriptor_json") ||
                die 'descriptor has no project'
              instance=$(jq -er '.instance | strings | select(length > 0)' <<<"$descriptor_json") ||
                die 'descriptor has no instance'
              address=$(jq -er '.address | strings | select(length > 0)' <<<"$descriptor_json") ||
                die 'descriptor has no address'
              [ "$3" = "$instance" ] ||
                die "explicit acknowledgment required: --confirm $instance"
              [[ "$project" =~ ^[a-zA-Z0-9_-]+$ && "$instance" =~ ^[a-zA-Z0-9_-]+$ ]] ||
                die 'invalid project or instance name'
              exec 9>"/run/lock/compute-$project-$instance.lock"
              flock -n 9 || die 'another compute lifecycle operation is running'

              manifests=${lib.escapeShellArg manifests}
              image=${lib.escapeShellArg (toString image)}
              bootstrap=${lib.escapeShellArg "${bootstrap}/bin/household-bootstrap"}
              # Test seams: a fixture host runs the same implementation against
              # a variant seed tree and its own Incus socket.
              if [ -n "''${HOUSEHOLD_BOOTSTRAP_MANIFESTS:-}" ]; then
                manifests=$HOUSEHOLD_BOOTSTRAP_MANIFESTS
              fi
              if [ -n "''${HOUSEHOLD_KANIDM_IMAGE:-}" ]; then
                image=$HOUSEHOLD_KANIDM_IMAGE
              fi
              if [ -n "''${HOUSEHOLD_BOOTSTRAP_BIN:-}" ]; then
                bootstrap=$HOUSEHOLD_BOOTSTRAP_BIN
              fi
              [ -f "$image" ] || die "pinned Kanidm image is unavailable: $image"
              for file in namespaces.yaml controllers.yaml root.yaml; do
                [ -r "$manifests/$file" ] || die "bootstrap artifact is incomplete: $file"
              done

              export INCUS_SOCKET="''${INCUS_SOCKET:-/var/lib/incus/unix.socket}"
              incus_cmd() {
                incus --force-local --project "$project" "$@"
              }
              # Reuse this command's held lock; inspect takes the lock itself otherwise.
              compute-guest --spec "$descriptor_target" --lock-fd 9 inspect ||
                die 'unable to validate declared compute envelope; refusing before mutation'
              instances=$(incus_cmd list "$instance" --format json) ||
                die "cannot inspect Incus target $project/$instance"
              if ! jq -e --arg expected "$instance" '
                length == 1 and
                .[0].name == $expected and
                .[0].status == "Running"
              ' <<<"$instances" >/dev/null; then
                die "target $project/$instance must already exist and be Running"
              fi

              tmp=$(mktemp -d)
              chmod 700 "$tmp"
              [ "$(stat -c %u:%a "$tmp")" = 0:700 ] ||
                die 'temporary directory is not root-private'
              raw_kubeconfig="$tmp/kubeconfig.raw"
              kubeconfig="$tmp/kubeconfig"
              argo_error="$tmp/argo-error"
              remote_image="/tmp/household-kanidm-provision-$$.tar"
              image_staged=0
              cleanup() {
                if [ "$image_staged" -eq 1 ]; then
                  incus_cmd exec "$instance" --mode=non-interactive -- \
                    rm -f -- "$remote_image" >/dev/null 2>&1 || true
                fi
                rm -rf -- "$tmp"
              }
              trap cleanup EXIT

              incus_cmd exec "$instance" --mode=non-interactive -- \
                cat /etc/rancher/k3s/k3s.yaml > "$raw_kubeconfig" ||
                die 'cannot acquire fresh kubeconfig from selected guest'
              chmod 600 "$raw_kubeconfig"
              yq -e '
                (.clusters | length == 1) and
                (.users | length >= 1) and
                (.contexts | length >= 1) and
                ((.clusters[0].cluster."certificate-authority-data" // "") | length > 0) and
                ((.users[0].user."client-certificate-data" // "") | length > 0) and
                ((.users[0].user."client-key-data" // "") | length > 0) and
                ((.clusters[0].cluster.server // "") | length > 0)
              ' "$raw_kubeconfig" >/dev/null ||
                die 'guest kubeconfig lacks embedded CA/client identity'
              endpoint="https://$address:6443"
              endpoint="$endpoint" yq -o=yaml '
                .clusters[0].cluster.server = strenv(endpoint)
              ' "$raw_kubeconfig" > "$kubeconfig" ||
                die 'cannot rewrite kubeconfig endpoint'
              chmod 600 "$kubeconfig"
              endpoint="$endpoint" yq -e '
                .clusters[0].cluster.server == strenv(endpoint) and
                ((.clusters[0].cluster."certificate-authority-data" // "") | length > 0) and
                ((.users[0].user."client-certificate-data" // "") | length > 0) and
                ((.users[0].user."client-key-data" // "") | length > 0)
              ' "$kubeconfig" >/dev/null ||
                die 'kubeconfig rewrite changed or lost cluster identity'
              export KUBECONFIG="$kubeconfig"

              node=$(kubectl get node "$instance" -o json) ||
                die "Kubernetes target node $instance is missing"
              jq -e --arg expected "$instance" '
                .metadata.name == $expected and
                (.metadata.labels["kubernetes.io/hostname"] // "") == $expected
              ' <<<"$node" >/dev/null ||
                die "Kubernetes target node does not match declared placement: $instance"
              declared_nodes=$(
                {
                  yq -r -N '
                    select(.spec.template.spec.nodeSelector."kubernetes.io/hostname" != null) |
                    .spec.template.spec.nodeSelector."kubernetes.io/hostname"
                  ' "$manifests/controllers.yaml"
                  yq -r -N '
                    .. | select(tag == "!!map" and .key == "kubernetes.io/hostname") |
                    .values[]
                  ' "$manifests/controllers.yaml"
                } | sort -u
              )
              if [ -n "$declared_nodes" ]; then
                while IFS= read -r declared_node; do
                  [ "$declared_node" = "$instance" ] ||
                    die "bootstrap artifact declares node $declared_node, not $instance"
                done <<<"$declared_nodes"
              fi

              if ! crd=$(kubectl get crd applications.argoproj.io \
                --ignore-not-found -o name 2>"$argo_error"); then
                cat "$argo_error" >&2
                die 'unable to inspect Argo Applications; refusing before mutation'
              fi
              if [ -n "$crd" ]; then
                applications=$(kubectl get applications.argoproj.io --all-namespaces \
                  -o name 2>"$argo_error") || {
                  cat "$argo_error" >&2
                  die 'unable to inspect Argo Applications; refusing before mutation'
                }
                [ -z "$applications" ] ||
                  die 'Argo Applications already exist; refusing before mutation'
              fi
              incus_cmd exec "$instance" --mode=non-interactive -- \
                test -s /srv/secrets/runtime-secrets.yaml ||
                die 'existing staged runtime secrets are missing from the guest'

              echo "Importing the pinned Kanidm provisioning image into $project/$instance."
              image_staged=1
              incus_cmd file push "$image" "$instance$remote_image"
              incus_cmd exec "$instance" --mode=non-interactive -- \
                k3s ctr images import --local --snapshotter native "$remote_image"
              incus_cmd exec "$instance" --mode=non-interactive -- \
                rm -f -- "$remote_image"
              image_staged=0

              kubectl apply --server-side --field-manager=argocd-controller \
                -f "$manifests/namespaces.yaml"
              # The narrowed seed owns only the Argo namespace. Secret delivery
              # owns the namespaces its Secrets live in: derive them from the
              # manifest itself so a narrowed seed cannot silently drop secret
              # targets (server-side apply fails objects in missing namespaces).
              secret_namespaces=$(incus_cmd exec "$instance" --mode=non-interactive -- \
                cat /srv/secrets/runtime-secrets.yaml | yq -N -r '.metadata.namespace | select(. != null)' | sort -u) ||
                die 'unable to list secret namespaces from the staged manifest'
              while IFS= read -r secret_namespace; do
                [ -n "$secret_namespace" ] || die 'staged Secret without a namespace'
                kubectl create namespace "$secret_namespace" --dry-run=client -o yaml |
                  kubectl apply --server-side --field-manager=homelab-runtime-secrets -f - ||
                  die "cannot ensure secret namespace $secret_namespace"
              done <<<"$secret_namespaces"
              incus_cmd exec "$instance" --mode=non-interactive -- \
                cat /srv/secrets/runtime-secrets.yaml |
                kubectl apply --server-side --force-conflicts --field-manager=homelab-runtime-secrets -f -
              "$bootstrap" --fresh-cluster
              "$bootstrap" --check-ready
              kubectl apply --server-side --field-manager=argocd-controller -f "$manifests/root.yaml"
              echo 'Argo seed is ready and the canonical root Application was applied. Verify child synchronization before application acceptance.'
            '';
          };
        in
        {
          household-bootstrap-host = hostBootstrap;
          household-bootstrap-bundle = pkgs.linkFarm "household-bootstrap-bundle" [
            {
              name = "manifests";
              path = manifests;
            }
            {
              name = "images/kanidm-provision.tar";
              path = image;
            }
            {
              name = "bin/household-bootstrap";
              path = "${bootstrap}/bin/household-bootstrap";
            }
            {
              name = "bin/household-bootstrap-host";
              path = "${hostBootstrap}/bin/household-bootstrap-host";
            }
            {
              name = "operations.md";
              path = config.files.file."docs/operations.md".source;
            }
          ];
        }
      );
    };
}
