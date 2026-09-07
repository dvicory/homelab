{ self, lib, ... }:
{
  perSystem = { pkgs, system, ... }: lib.optionalAttrs (lib.hasSuffix "-linux" system) (
    let
      environment = self.nixidyEnvs.${system}.prod-home.environmentPackage;
      inventory = pkgs.writeText "household-recovery-inventory.json" (builtins.toJSON {
        format = 1;
        # The store identity binds every chart, image and rendered resource, not
        # a second hand-maintained list of application versions.
        manifests = toString environment;
        namespaces = [ "jellyfin" "immich" "media" "identity" "monitoring" ];
        paths = [ "jellyfin-config" "immich-library" "immich-postgres" "radarr" "sonarr" "sabnzbd" "seerr" "media-data" "identity-kanidm" "monitoring-prometheus" "monitoring-alertmanager" "monitoring-grafana" "monitoring-loki" ];
      });
      guidance = pkgs.writeText "household-recovery-operations.txt" ''
        household-recovery export|restore|resume DESCRIPTOR POINT METRICS_DIRECTORY

        Run as root on the disposable Linux Incus host. DESCRIPTOR is the
        root-owned compute JSON from /etc/homelab/compute.json; POINT is an absolute
        new export directory, or an existing complete trusted export for restore.
        METRICS_DIRECTORY must already exist and be scraped by node exporter's
        textfile collector on this host. No production invocation is authorized.
        The exact Nix inventory is ${inventory}; software identity is ${environment}.
        Keep this package and that manifest output with each recovery point.

        Export suspends Argo by stopping every Argo Deployment/StatefulSet, waits
        for controller pods to exit, stops household Deployments then StatefulSets
        (database excepted), and rejects active Jobs, unsuspended schedules and unknown writers.
        PostgreSQL 14 pg_basebackup in the pinned database container produces a
        native tar with WAL and a manifest. All writers are stopped before this
        backup; custom tablespaces are refused. The Incus guest is then stopped
        before archiving every declared retained path except database pgdata.
        Runtime credentials and read-only legacy media are separate prerequisites,
        not silently captured: retain the agenix identities, staged secrets and
        original read-only media independently. Queue/model/cache state is disposable.

        Restore accepts only the identical versioned inventory, descriptor and
        complete SHA256-verified file set. It verifies the native PostgreSQL backup
        and stages every path before moving any target. Free-space checks reserve
        room for the entire staged set plus headroom on each destination filesystem.
        Existing target directories are renamed to sibling .displaced-TIMESTAMP
        directories, never deleted. Do not restore from untrusted archives: checksums
        detect damage, not malicious provenance. Existing guest credentials must
        match the backed-up PostgreSQL role passwords and application state.

        Neither success nor failure starts writers automatically. After a successful
        operation inspect POINT.session/journal, then explicitly run resume with
        the same arguments. Resume starts the guest, restores saved workload counts,
        waits for readiness, and restores Argo last. Do not concurrently deploy,
        run compute-guest or operate Incus/Kubernetes during recovery. Recovery uses
        the compute lifecycle lock but cannot serialize external administrators.
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
    in {
      packages.household-recovery = pkgs.writeShellApplication {
        name = "household-recovery";
        runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.gnutar pkgs.gnused pkgs.jq pkgs.yq-go pkgs.util-linux pkgs.incus pkgs.postgresql_14 ];
        text = ''
          export RECOVERY_INVENTORY=${inventory}
          export RECOVERY_GUIDANCE=${guidance}
          export RECOVERY_MANIFESTS=${environment}
        '' + builtins.readFile ./_recovery.sh;
      };
    }
  );
}
