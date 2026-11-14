{
  config,
  inputs,
  lib,
  self,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    let
      k3sPackage = self.nixosConfigurations.compute-1.config.services.k3s.package;
      k3sVersion = k3sPackage.version;
      syncPackage = pkgs.callPackage ../../pkgs/by-name/dependency-track-sync/package.nix { };
      # Select the actual Den variant only inside this qualification evaluation.
      # Its NixOS leaf supplies the exact production credential preparation code.
      base =
        inputs.flake-parts.lib.mkFlake
          {
            inputs = inputs // {
              inherit self;
            };
          }
          {
            imports = [ (inputs.import-tree [ (self.outPath + "/modules") ]) ];
            debug = true;
          };
      selected = base.debug.extendModules {
        modules = [
          ({ den, ... }: {
            den.aspects.prod-home.includes = [ den.aspects.kubernetes.services.dependency-track ];
            den.clusters.prod-home.settings.kubernetes.services.dependency-track = {
              databasePhase = "bootstrap";
              automaticInventory = true;
            };
            den.aspects.compute-1.includes = [
              den.aspects.workloads.dependency-track-sync.compute-guest
            ];
            den.hosts.x86_64-linux.compute-1.settings.workloads.dependency-track-sync.apiUrl =
              "http://127.0.0.1:1022";
          })
        ];
      };
      credentialStage =
        selected.config.flake.nixosConfigurations.compute-1.config.systemd.services.dependency-track-sync-credentials.serviceConfig.ExecStart;
      brokerPortGuard =
        selected.config.flake.nixosConfigurations.compute-1.config.systemd.services.dependency-track-sync-api-tunnel.serviceConfig.ExecStartPre;
      failureNotifier =
        selected.config.flake.nixosConfigurations.compute-1.config.systemd.services.dependency-track-sync-failure.serviceConfig.ExecStart;
      monitoring =
        (import ../den/aspects/kubernetes/services/monitoring/alerting.nix {
          inherit config inputs lib;
        }).den.aspects.kubernetes.services.monitoring.alerting.k8s-manifests
          {
            cluster = config.den.clusters.prod-home;
            computeResources = config.flake.clusterResources.prod-home;
            charts = { };
          };
      alertmanagerValues = monitoring.applications.monitoring.helm.releases.alertmanager.values;
      alertmanagerContainer = alertmanagerValues.controllers.main.containers.alertmanager;
      alertmanagerConfig = builtins.fromJSON (
        (lib.findSingle
          (object: object.kind == "ConfigMap" && object.metadata.name == "alertmanager-config")
          (throw "Missing source Alertmanager configuration")
          (throw "Ambiguous source Alertmanager configuration")
          monitoring.applications.monitoring.objects
        ).data."alertmanager.yaml"
      );
      failureEventRoute =
        lib.findSingle (route: builtins.elem "alertname=\"DependencyTrackInventoryRefreshFailed\"" (route.matchers or [ ]))
          (throw "Missing source inventory failure event route")
          (throw "Ambiguous source inventory failure event route")
          alertmanagerConfig.route.routes;
      alertmanager = {
        image = "${alertmanagerContainer.image.repository}:${alertmanagerContainer.image.tag}";
        resources = alertmanagerContainer.resources;
        eventRoute = failureEventRoute;
        # Keep the source event route, but no provider configuration or credentials.
        config = {
          route = alertmanagerConfig.route // {
            routes = [ failureEventRoute ];
          };
          receivers = map (receiver: { inherit (receiver) name; }) alertmanagerConfig.receivers;
        };
      };
      service =
        (import ../den/aspects/kubernetes/services/dependency-track.nix {
          inherit config inputs lib;
        }).den.aspects.kubernetes.services.dependency-track;
      retainedPaths =
        lib.mapAttrs
          (
            name: value:
            value
            // {
              guestPath = "/srv/dependency-track/${lib.removePrefix "dependency-track-" name}";
              readOnly = false;
            }
          )
          (service.compute-resources {
            cluster.settings.kubernetes.services.dependency-track.databasePhase = "bootstrap";
            cluster.settings.kubernetes.services.dependency-track.automaticInventory = false;
          }).retainedPaths;
      render =
        databasePhase:
        service.k8s-manifests {
          cluster.settings.kubernetes.services.dependency-track = {
            inherit databasePhase;
            apiBaseUrl = "http://127.0.0.1:18080";
            advisoryRefresh = false;
            initialMirror = false;
            automaticInventory = false;
          };
          computeResources = {
            inherit retainedPaths;
            instance = "compute-1";
          };
        };
      bootstrap = render "bootstrap";
      retained = bootstrap.applications.dependency-track-retained.resources;
      objects = [
        {
          apiVersion = "v1";
          kind = "Namespace";
          metadata.name = "dependency-track";
        }
      ]
      ++ lib.mapAttrsToList (
        name: value:
        value
        // {
          apiVersion = "v1";
          kind = "PersistentVolume";
          metadata = value.metadata // {
            inherit name;
          };
        }
      ) retained.persistentVolumes
      ++ lib.mapAttrsToList (
        name: value:
        value
        // {
          apiVersion = "v1";
          kind = "PersistentVolumeClaim";
          metadata = value.metadata // {
            inherit name;
            namespace = "dependency-track";
          };
        }
      ) retained.persistentVolumeClaims;
      manifest =
        name: items:
        pkgs.writeText name (
          builtins.toJSON {
            apiVersion = "v1";
            kind = "List";
            inherit items;
          }
        );
      settings = pkgs.writeText "dependency-track-qualification.json" (
        builtins.toJSON {
          docker = lib.getExe' pkgs.docker-client "docker";
          kubectl = lib.getExe' k3sPackage.k3sBundle "kubectl";
          system = k3sPackage.system;
          sync = lib.getExe syncPackage;
          credentialStage = toString credentialStage;
          brokerPortGuard = toString brokerPortGuard;
          failureNotifier = toString failureNotifier;
          failureHost = "compute-1";
          inherit alertmanager;
          cat = lib.getExe' pkgs.coreutils "cat";
          id = lib.getExe' pkgs.coreutils "id";
          nonLoginShell = lib.getExe' pkgs.coreutils "false";
          bash = lib.getExe' pkgs.bash "bash";
          unshare = lib.getExe' pkgs.util-linux "unshare";
          nsenter = lib.getExe' pkgs.util-linux "nsenter";
          useradd = lib.getExe' pkgs.shadow "useradd";
          groupadd = lib.getExe' pkgs.shadow "groupadd";
          userdel = lib.getExe' pkgs.shadow "userdel";
          groupdel = lib.getExe' pkgs.shadow "groupdel";
          repository = "dvicory/homelab";
          qualificationTargets = {
            host = {
              id = "3ca171bb4d06a0d2584c981f";
              kind = "nix";
              state = "desired";
              system = "x86_64-linux";
              target = "nixosConfigurations.compute-1.config.system.build.toplevel";
            };
            oci = {
              id = "cc64e08c1afb4776b4d587d4";
              kind = "oci";
              state = "referenced";
              system = "x86_64-linux";
              source = "generated/manifests/prod-home/argocd/Deployment-argocd-redis.yaml";
              pointer = "/spec/template/spec/containers/redis/image";
              ociPlatform = "linux/amd64";
            };
          };
          inherit k3sVersion;
          # Resolve the source-selected upstream release to an immutable digest.
          image = "rancher/k3s:v${lib.replaceStrings [ "+" ] [ "-" ] k3sVersion}";
          networkPolicy = ../../generated/manifests/prod-home/network-policy;
          retained = manifest "dependency-track-qualification-retained.json" objects;
          bootstrap = manifest "dependency-track-qualification-bootstrap.json" bootstrap.applications.dependency-track.objects;
          restore = manifest "dependency-track-qualification-restore.json" (render "restore")
          .applications.dependency-track.objects;
        }
      );
      python = pkgs.python3.withPackages (p: [ p.pyyaml ]);
      runner = pkgs.writeShellScriptBin "qualify-dependency-track" ''
        export PYTHONPATH=${syncPackage}/lib/dependency-track-sync
        exec ${python}/bin/python3 -B ${./_dependency-track/run.py} --settings ${settings} "$@"
      '';
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      apps.qualify-dependency-track = {
        type = "app";
        program = lib.getExe runner;
      };
      packages.qualify-dependency-track = runner;
    };
}
