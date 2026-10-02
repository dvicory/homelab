{ config, extendModules, lib, rootPath, self, ... }:
{
  perSystem = { pkgs, system, ... }:
    let
      cluster = config.den.clusters.prod-home;
      environment = config.den.environments.${cluster.environment};
      compute = config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
      resources = config.flake.clusterResources.prod-home;
      original = self.nixidyEnvs.${system}.prod-home;
      python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
      policySource = ./_kubernetes-policy;
      helper = "${policySource}/transport.py";
      # The lock's package is named kyverno, not kyverno-cli; its sole binary is the CLI.
      kyverno = pkgs.kyverno;
      schemaRunner = self.packages.${system}.prod-home-manifests-schema;
      schemas = self.packages.${system}.prod-home-kubernetes-schemas;
      variants = lib.cartesianProduct {
        identity = [ "initial" "provisioning" "normal" ];
        seerr = [ "initial" "ready" ];
        mode = [ "direct" "trustedEdges" ];
      };
      mkVariant = item:
        let
          fixture = extendModules {
            modules = [{
              den.clusters.prod-home = {
                settings.kubernetes.services.identity.phase = lib.mkForce item.identity;
                settings.kubernetes.services.seerr.phase = lib.mkForce item.seerr;
                ingress.mode = lib.mkForce item.mode;
                ingress.trustedProxyCIDRs = lib.mkForce (
                  lib.optionals (item.mode == "trustedEdges") [ "10.0.0.11/32" "10.0.0.12/32" ]
                );
              };
            }];
          };
          inventory = fixture.config.den.clusters.prod-home;
          rendered = fixture.config.flake.nixidyEnvs.${system}.prod-home;
        in {
          name = "${item.identity}-${item.seerr}-${item.mode}";
          cluster = inventory;
          inherit rendered;
          manifests = rendered.config.build.environmentPackage;
          bootstrap = rendered.config.build.bootstrapPackage;
        };
      renders = map mkVariant variants;
      expectedFor = rendered: inventory: pkgs.writeText "policy-expected.json" (builtins.toJSON {
        environment = { inherit (environment) domain backupDomain; };
        computeResources = {
          inherit (compute) instance;
          mediaPaths = { inherit (resources.mediaPaths) data library; };
          retainedPaths.identity-kanidm = { inherit (compute.retainedPaths.identity-kanidm) guestPath; };
          runtimeSecrets.jellyfin--jellyfin-admin--password = {
            inherit (resources.runtimeSecrets.jellyfin--jellyfin-admin--password) namespace name key;
          };
        };
        cluster = {
          settings.kubernetes.services = {
            identity.phase = inventory.settings.kubernetes.services.identity.phase;
            seerr.phase = inventory.settings.kubernetes.services.seerr.phase;
            media = lib.genAttrs [ "radarr" "sonarr" ] (family:
              lib.mapAttrs (_: instance: { inherit (instance) state; }) inventory.settings.kubernetes.services.media.${family}
            );
          };
          ingress = { inherit (inventory.ingress) mode trustedProxyCIDRs nodePort; };
          routes = lib.mapAttrs (_: route: {
            inherit (route) namespace service port auth exposure hostnames pathPrefix backendTLS backendPodSelector;
            backendHostname = route.backendHostname or null;
            timeouts = route.timeouts or null;
          }) inventory.routes;
        };
        retainedPaths = lib.genAttrs [ "jellyfin-config" "sabnzbd" ] (name: {
          inherit (compute.retainedPaths.${name}) uid gid;
        });
        repository = rendered.config.nixidy.target.repository;
        revision = rendered.config.nixidy.target.branch;
        prefix = rendered.config.nixidy.target.rootPath + "/";
        project = rendered.config.nixidy.env;
        appendNameWithEnv = rendered.config.nixidy.appendNameWithEnv;
        destination = rendered.config.nixidy.defaults.destination.server;
      });
      inputsPackage = pkgs.runCommand "prod-home-manifests-policy-inputs" { nativeBuildInputs = [ python ]; } ''
        mkdir -p "$out"
        cp -R ${policySource} "$out/policies"
        chmod -R u+w "$out/policies"
        pack() {
          name=$1
          manifests=$2
          bootstrap=$3
          expected=$4
          mkdir -p "$out/$name/manifests" "$out/$name/bootstrap"
          cp -aL "$manifests/." "$out/$name/manifests/"
          cp -aL "$bootstrap/." "$out/$name/bootstrap/"
          cp "$expected" "$out/$name/expected.json"
          ${lib.getExe schemaRunner} "$out/$name/manifests" ${schemas} "$out/$name/schema-report.json"
          python ${helper} bind-crds --manifests "$out/$name/manifests" \
            --reference ${rootPath}/generated/manifests/prod-home
          python ${helper} bundle --manifests "$out/$name/manifests" \
            --bootstrap "$out/$name/bootstrap" --expected "$out/$name/expected.json" \
            --variant "$name" --output "$out/$name"
        }
        pack canonical ${rootPath}/generated/manifests/prod-home \
          ${original.config.build.bootstrapPackage} ${expectedFor original cluster}
        ${lib.concatMapStringsSep "\n" (variant: ''
          pack ${variant.name} ${variant.manifests} ${variant.bootstrap} \
            ${expectedFor variant.rendered variant.cluster}
        '') renders}
      '';
      runner = pkgs.writeShellApplication {
        name = "check-prod-home-manifests-policy";
        runtimeInputs = [ python kyverno pkgs.yq-go pkgs.jq ];
        text = ''
          if [ "$#" -gt 2 ]; then
            echo 'usage: check-prod-home-manifests-policy [immutable-inputs [report-directory]]' >&2
            exit 2
          fi
          source="''${1:-${inputsPackage}}"
          reports="''${2:-policy-report}"
          python ${helper} run --inputs "$source" --output "$reports" \
            --kyverno ${lib.getExe kyverno} --yq ${lib.getExe pkgs.yq-go} \
            --schema-runner ${lib.getExe schemaRunner} --schemas ${schemas} \
            --schema-manifests ${rootPath}/generated/manifests/prod-home
          bash ${policySource}/schema-counterfactuals.sh "$source" ${schemas} \
            ${lib.getExe schemaRunner} "$reports/schema-counterfactuals"
        '';
      };
    in {
      checks.prod-home-manifests-policy = pkgs.runCommandLocal "prod-home-manifests-policy" { } ''
        ${lib.getExe runner} ${inputsPackage} "$out"
      '';
      packages.prod-home-manifests-policy-inputs = inputsPackage;
      packages.prod-home-manifests-policy-runner = runner;
      packages.prod-home-manifests-policy-cli = kyverno;
    };
}
