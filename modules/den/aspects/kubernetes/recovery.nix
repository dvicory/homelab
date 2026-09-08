{
  config,
  self,
  lib,
  ...
}:
let
  cluster = config.den.clusters.prod-home;
  compute =
    config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
in
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (lib.hasSuffix "-linux" system) (
      let
        environment = self.nixidyEnvs.${system}.prod-home.environmentPackage;
        retained = pkgs.writeText "household-recovery-retained-paths.json" (
          builtins.toJSON (
            lib.mapAttrs (_: entry: { inherit (entry) guestPath readOnly; }) compute.retainedPaths
          )
        );
        preflight = pkgs.writeText "household-recovery-preflight.sh" config.flake.clusterResources.prod-home.preCaptureChecks;
        inventory =
          pkgs.runCommand "household-recovery-inventory.json"
            {
              nativeBuildInputs = [
                pkgs.findutils
                pkgs.jq
                pkgs.yq-go
              ];
            }
            ''
              resources=$(mktemp)
              trap 'rm -f "$resources"' EXIT
              find -L ${lib.escapeShellArg (toString environment)} \
                -type f \( -name '*.yaml' -o -name '*.yml' \) \
                -exec yq -o=json '.' {} + | jq -s '[.[] | select(type == "object")]' > "$resources"
              jq -e 'length > 0' "$resources" >/dev/null
              jq -n \
                --arg manifests ${lib.escapeShellArg (toString environment)} \
                --slurpfile retained ${retained} \
                --slurpfile resources "$resources" '
                def rendered: $resources[0];
                def retainedEntries: $retained[0] | to_entries;
                def localPVs:
                  [ rendered[]
                    | select(.kind == "PersistentVolume")
                    | select((.spec.local.path? // null) | type == "string")
                    | select(.metadata.name? | type == "string")
                  ];
                def staticGuestPaths: [localPVs[].spec.local.path] | unique;
                def staticPVNames: [localPVs[].metadata.name] | unique;
                def dynamicGuestPaths:
                  [ rendered[]
                    | select(.kind == "ConfigMap")
                    | .data["config.json"]?
                    | select(type == "string")
                    | fromjson?
                    | .nodePathMap[]?.paths[]?
                  ]
                  | map(select(type == "string"))
                  | unique;
                def dynamicNamespaces:
                  [ rendered[]
                    | . as $resource
                    | select(.kind == "ConfigMap")
                    | .data["config.json"]?
                    | select(type == "string")
                    | fromjson?
                    | select(.nodePathMap? | type == "array")
                    | $resource.metadata.namespace?
                  ]
                  | map(select(type == "string"))
                  | unique;
                def renderedDaemonSets:
                  [ rendered[]
                    | select(.kind == "DaemonSet")
                    | select(.metadata.namespace? | type == "string")
                    | select(.metadata.name? | type == "string")
                    | { namespace: .metadata.namespace, name: .metadata.name }
                  ]
                  | unique_by([.namespace, .name])
                  | sort_by([.namespace, .name]);
                def staticNames:
                  [ retainedEntries[]
                    | select(.value.guestPath as $path | staticGuestPaths | index($path) != null)
                    | .key
                  ]
                  | unique;
                def dynamicNames:
                  [ retainedEntries[]
                    | select(.value.guestPath as $path | dynamicGuestPaths | index($path) != null)
                    | .key
                  ]
                  | unique;
                def stateNamespaces:
                  (
                    [ rendered[]
                      | select(.kind == "PersistentVolumeClaim")
                      | select(
                          (.spec.volumeName? // "") as $volume
                          | staticPVNames | index($volume) != null
                        )
                      | .metadata.namespace?
                    ]
                    + [ rendered[]
                        | select(.kind == "Prometheus" or .kind == "Alertmanager")
                        | select(
                            (.spec.storage.volumeClaimTemplate.spec.volumeName? // "") as $volume
                            | staticPVNames | index($volume) != null
                          )
                        | .metadata.namespace?
                      ]
                    + dynamicNamespaces
                  )
                  | map(select(type == "string"))
                  | unique
                  | sort;
                {
                  format: 2,
                  manifests: $manifests,
                  namespaces: stateNamespaces,
                  daemonsets: renderedDaemonSets,
                  paths: ([retainedEntries[].key] | unique | sort),
                  dynamicPaths: (dynamicNames | sort),
                  unresolvedPaths: (
                    ([retainedEntries[].key] - (staticNames + dynamicNames))
                    | unique
                    | sort
                  )
                }
              ' > "$out"
            '';
        guidance = pkgs.writeText "household-recovery-operations.txt" ''
          household-recovery export|restore|resume DESCRIPTOR POINT METRICS_DIRECTORY

          Run as root on the disposable Linux Incus host. DESCRIPTOR is the
          root-owned compute JSON from /etc/homelab/compute.json; POINT is an absolute
          new export directory, or an existing complete trusted export for restore.
          METRICS_DIRECTORY must already exist and be scraped by node exporter's
          textfile collector on this host. No production invocation is authorized.
          The exact Nix inventory is ${inventory}; software identity is ${environment}.
          Keep this package and that manifest output with each recovery point.
          Inventory membership is generated from compute.retainedPaths and rendered
          retained PV/PVC or dynamic-provisioner owners. A retained dynamic-PVC parent
          with any child is refused: ordinary Helm ownership and image allowlists are
          not represented here, so use its separate recorded reattachment/application
          backup path.

          Export suspends Argo by stopping every Argo Deployment/StatefulSet, waits
          for controller pods to exit, stops household Deployments then StatefulSets,
          and rejects active Jobs, unsuspended schedules and unknown writers.
          Evaluated service-owned pre-capture checks run while writers are still
          online; a failed check aborts before any writer is quiesced. The Incus
          guest is then stopped before archiving every declared retained path.
          Runtime credentials and read-only legacy media are separate prerequisites,
          not silently captured: retain the agenix identities, staged secrets and
          original read-only media independently. Queue/model/cache state is disposable.
          Restore accepts only the identical versioned inventory, descriptor and
          complete SHA256-verified file set. It stages every retained path under
          POINT.session/staged before changing any target.
          Free-space checks reserve room for the complete staged set and a full
          displaced copy of every live target, plus the final populated target
          sets and headroom, on each affected filesystem. Existing mount roots are
          never renamed: their modes, ownership and mount boundaries remain in
          place while their contents are copied to
          validated stage. GNU tar/cp preserve contained symlinks, ACLs and xattrs
          where the filesystem supports them. Never delete a session's staged or
          displaced sets until recovery is independently verified.
          Do not restore from untrusted archives: checksums detect damage, not
          malicious provenance. Existing guest credentials must match the backed-up
          PostgreSQL role passwords and application state.

          Neither success nor failure starts writers automatically. After a successful
          operation inspect POINT.session/journal, then explicitly run resume with
          the same arguments. Resume starts the guest, waits for a Kubernetes node
          Ready condition, restores saved workload counts and waits for each actual
          workload rollout. Argo controllers are restored last; resume waits for
          their rollouts and Ready pods, then rechecks workloads before marking the
          session resumed. Do not concurrently deploy, run compute-guest or operate
          Incus/Kubernetes during recovery. Recovery uses the compute lifecycle lock
          but cannot serialize external administrators.
          If any operation fails, leave the guest/reconcilers stopped; fix the cause
          and inspect staged/displaced directories and journal before manual recovery.
          Partial restore has NO automatic rollback or resume. Resume refuses it.
          A failed export is POINT.partial-TIMESTAMP, never a complete point.
          Repeated restore is deliberately blocked by the session directory; retain
          it and choose a separate copy of a trusted point for another explicit run.
          Metrics mark a failed/in-progress attempt immediately, preserve the prior
          successful-export timestamp, and publish success atomically only after the
          entire operation. Only a complete export advances recovery-point freshness.
          Same-host exports are recovery points, NOT independent backups. Copy the
          complete point and pinned tools/manifests off-host via your backup system.
        '';
      in
      {
        packages.household-recovery = pkgs.writeShellApplication {
          name = "household-recovery";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.findutils
            pkgs.gnutar
            pkgs.gnused
            pkgs.jq
            pkgs.yq-go
            pkgs.util-linux
            pkgs.incus
          ];
          text = ''
            export RECOVERY_INVENTORY=${inventory}
            export RECOVERY_GUIDANCE=${guidance}
            export RECOVERY_PREFLIGHT=${preflight}
          ''
          + builtins.readFile ./_recovery.sh;
        };
      }
    );
}
