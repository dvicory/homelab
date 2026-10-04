{
  config,
  inputs,
  lib,
  self,
  ...
}:
let
  # Version acceptance: render the real Jellyfin k8s-manifests aspect with the
  # cluster and the compute facts it reads from the cluster-to-nixidy
  # projection, varying only the provisioner package that jellyfin.nix reads
  # from inputs.self.packages.
  releaseCluster = config.den.clusters.prod-home;
  releaseCompute =
    config.den.hosts.${releaseCluster.hostSystem}.${releaseCluster.hostName}.settings.virtualization.compute;
  releaseComputeResources = {
    inherit (releaseCompute) accelerator instance retainedPaths;
    inherit (config.flake.clusterResources.prod-home) mediaPaths;
  };
  releaseSystem =
    inputs.self.nixosConfigurations.${releaseComputeResources.instance}.pkgs.stdenv.hostPlatform.system;
  provisionerPackage = inputs.self.packages.${releaseSystem}.jellyfin-provisioner-image;
  renderJellyfin = provisioner: renderJellyfinWith { inherit provisioner; };
  renderJellyfinWith =
    {
      provisioner ? provisionerPackage,
      cluster ? releaseCluster,
    }:
    (import ../den/aspects/kubernetes/services/jellyfin.nix {
      inherit config lib;
      inputs = inputs // {
        self = inputs.self // {
          packages = inputs.self.packages // {
            ${releaseSystem} = inputs.self.packages.${releaseSystem} // {
              jellyfin-provisioner-image = provisioner;
            };
          };
        };
      };
    }).den.aspects.kubernetes.services.jellyfin.k8s-manifests
      {
        inherit cluster;
        computeResources = releaseComputeResources;
      };
  # Jellarr configuration rendered for a declared transcoding mode.
  jellarrConfigFor =
    transcoding:
    let
      rendered = renderJellyfinWith {
        cluster = lib.recursiveUpdate releaseCluster {
          settings.kubernetes.services.jellyfin = { inherit transcoding; };
        };
      };
      configMap = lib.findFirst (
        object: object.kind == "ConfigMap" && object.metadata.name == "jellarr-configuration"
      ) (throw "Jellyfin render has no Jellarr ConfigMap") rendered.applications.jellyfin-configuration.objects;
    in
    configMap.data."config.yml";
  # One side of the release moves; everything else is the shipped package.
  drift =
    {
      release ? { },
      build ? { },
    }:
    provisionerPackage
    // {
      passthru = provisionerPackage.passthru // {
        release = provisionerPackage.passthru.release // release;
        provisioner =
          provisionerPackage.passthru.provisioner
          // lib.optionalAttrs (build ? version) { inherit (build) version; }
          // lib.optionalAttrs (build ? sourceRev) {
            src = provisionerPackage.passthru.provisioner.src // {
              rev = build.sourceRev;
            };
          };
      };
    };
  laterSourceRev = "0123456789abcdef0123456789abcdef01234567";
  # The evaluation only reaches weak head normal form, which forces the
  # route and release assertions in jellyfin.nix and none of the resource
  # bodies. Every case shares the route, cluster and compute inputs with the
  # conformant render, so a rejected case can only fail a release assertion.
  # tryEval catches only throw/assert; any other error aborts the check.
  rejected = provisioner: !(builtins.tryEval (renderJellyfin provisioner)).success;
  driftCases = {
    # A coherent provisioner-only bump: package version and source move,
    # the stock runtime stays on 12.1.
    provisioner-source-moves-alone = drift {
      release = {
        version = "12.2";
        sourceRev = laterSourceRev;
      };
      build = {
        version = "12.2";
        sourceRev = laterSourceRev;
      };
    };
    # An image-only updater moves the stock runtime digest.
    runtime-digest-moves-alone = drift {
      release.runtimeDigest = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
    };
    # The stock runtime tag moves while the provisioner stays on 12.1.
    runtime-release-moves-alone = drift {
      release.runtimeImage = "docker.io/jellyfin/jellyfin:12.2";
    };
    # The provisioner build changes source without its release declaration.
    provisioner-build-leaves-declaration = drift {
      build.sourceRev = laterSourceRev;
    };
    # The PR #17902 patch revision moves without a reviewed release change.
    provision-patch-moves-alone = drift {
      release.provisionPatchRev = laterSourceRev;
    };
  };
  conformant = renderJellyfin provisionerPackage;
  conformantDeployment = lib.findFirst (
    object: object.kind == "Deployment" && object.metadata.name == "jellyfin"
  ) (throw "conformant Jellyfin render has no Deployment") conformant.applications.jellyfin.objects;
  conformantImages = {
    provisioner = (builtins.head conformantDeployment.spec.template.spec.initContainers).image;
    runtime = (builtins.head conformantDeployment.spec.template.spec.containers).image;
  };
  releaseFailures =
    lib.optional (
      !(builtins.tryEval (builtins.deepSeq conformantImages true)).success
    ) "conformant-release-renders"
    ++ lib.attrNames (lib.filterAttrs (_: provisioner: !(rejected provisioner)) driftCases);
  # Administrator names: evaluate the real option declaration on its own, so
  # a rejection can only come from its type check.
  administratorOption =
    (import ../den/aspects/kubernetes/services/jellyfin.nix { inherit config inputs lib; })
    .den.aspects.kubernetes.services.jellyfin.settings.administrator;
  administratorAccepted =
    name:
    (builtins.tryEval
      (lib.evalModules {
        modules = [
          { options.administrator = administratorOption; }
          { administrator = name; }
        ];
      }).config.administrator
    ).success;
  administratorCases = {
    declared = releaseCluster.settings.kubernetes.services.jellyfin.administrator;
    inner-space = "Jellyfin Admin";
  };
  # The first name is the runtime post-preflight fault in
  # prod-home-replacement.py; evaluation must refuse to deliver it.
  rejectedAdministrators = {
    slash = "post-preflight/fault";
    parent = "..";
    leading-space = " daniel";
  };
  administratorFailures =
    lib.attrNames (lib.filterAttrs (_: name: !(administratorAccepted name)) administratorCases)
    ++ lib.attrNames (lib.filterAttrs (_: administratorAccepted) rejectedAdministrators);
in
{
  perSystem =
    { pkgs, system, ... }:
    let
      environment = ../../generated/manifests/prod-home;
      encodingVariants = pkgs.writeText "jellyfin-encoding-variants.json" (
        builtins.toJSON {
          hardware = jellarrConfigFor "hardware";
          software = jellarrConfigFor "software";
        }
      );
      # Jellarr validates its whole configuration against a strict schema
      # before it reads the API key, so the pinned CLI checks a file offline.
      jellarrCli = lib.optionalString pkgs.stdenv.hostPlatform.isLinux (
        lib.getExe self.packages.${system}.jellarr-image.passthru.jellarr
      );
      renderedImages = pkgs.writeText "jellyfin-release-render.json" (
        builtins.unsafeDiscardStringContext (builtins.toJSON conformantImages)
      );
      python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
    in
    {
      checks.jellyfin-contracts =
        assert lib.assertMsg (releaseFailures == [ ])
          "Jellyfin release invariant checks failed: ${lib.concatStringsSep ", " releaseFailures}";
        assert lib.assertMsg (administratorFailures == [ ])
          "Jellyfin administrator name checks failed: ${lib.concatStringsSep ", " administratorFailures}";
        pkgs.runCommand "jellyfin-contracts"
          {
            nativeBuildInputs = [
              python
              pkgs.nodejs
              pkgs.bash
              pkgs.findutils
              pkgs.gnugrep
            ];
          }
          ''
            python - ${environment} ${renderedImages} ${encodingVariants} <<'PY'
            import copy
            import json
            import pathlib
            import sys
            import yaml

            environment = pathlib.Path(sys.argv[1])
            release_render = json.loads(pathlib.Path(sys.argv[2]).read_text())
            encoding_variants = json.loads(pathlib.Path(sys.argv[3]).read_text())
            deployment = yaml.safe_load((environment / "jellyfin" / "Deployment-jellyfin.yaml").read_text())
            pod = deployment["spec"]["template"]["spec"]
            # The release-drift cases in this check render through the same
            # harness; it must reproduce the delivered images exactly.
            assert release_render == {
                "provisioner": pod["initContainers"][0]["image"],
                "runtime": pod["containers"][0]["image"],
            }, "the release-drift harness renders the delivered Jellyfin images"

            configuration = yaml.safe_load(
                (environment / "jellyfin-configuration" / "ConfigMap-jellarr-configuration.yaml").read_text()
            )
            variants = {mode: yaml.safe_load(text) for mode, text in encoding_variants.items()}
            pathlib.Path("jellarr-hardware.yml").write_text(encoding_variants["hardware"])
            pathlib.Path("jellarr-software.yml").write_text(encoding_variants["software"])
            unknown = copy.deepcopy(variants["hardware"])
            unknown["encoding"]["enableToneMapping"] = True
            pathlib.Path("jellarr-unknown-key.yml").write_text(yaml.safe_dump(unknown))
            pathlib.Path("bootstrap.mjs").write_text(configuration["data"]["bootstrap.mjs"])

            PY

            # Both transcoding variants pass Jellarr's strict schema; an
            # unknown encoding key does not. A valid file gets as far as the
            # missing API key.
            ${lib.optionalString (jellarrCli != "") ''
              schema() {
                env -u JELLARR_API_KEY HOME="$PWD" ${jellarrCli} --configFile "$1" > "$1.out" 2>&1 || true
              }
              for variant in jellarr-hardware.yml jellarr-software.yml; do
                schema "$variant"
                grep -q "JELLARR_API_KEY required" "$variant.out" || { cat "$variant.out" >&2; exit 1; }
                if grep -q "Configuration validation failed" "$variant.out"; then cat "$variant.out" >&2; exit 1; fi
              done
              schema jellarr-unknown-key.yml
              grep -q "Configuration validation failed" jellarr-unknown-key.yml.out \
                || { cat jellarr-unknown-key.yml.out >&2; exit 1; }
            ''}
            node ${./jellyfin-bootstrap.mjs} bootstrap.mjs

            # Partial-state preflight: run the script the provisioner image runs
            # against empty, initialized and partial /config fixtures.
            preflight() {
              JELLYFIN_DATA_DIR="$1" JELLYFIN_CONFIG_DIR="$1/config" \
                bash -o errexit -o nounset -o pipefail ${../../pkgs/by-name/jellyfin-provisioner-image/preflight.sh} \
                >"$1.out" 2>"$1.err"
            }
            listing() {
              (find "$1" -printf '%P %s %T@\n' 2>/dev/null || true) | sort
            }
            accepts() {
              preflight "$1" || { echo "preflight refused $1: $(cat "$1.err")" >&2; exit 1; }
              grep -qF "$2" "$1.out" || { echo "preflight did not report '$2' for $1" >&2; exit 1; }
            }
            refuses() {
              before=$(listing "$1")
              if preflight "$1"; then echo "preflight accepted $1" >&2; exit 1; fi
              grep -qF "$2" "$1.err" || { echo "preflight refused $1 without '$2': $(cat "$1.err")" >&2; exit 1; }
              [ "$before" = "$(listing "$1")" ] || { echo "preflight changed $1" >&2; exit 1; }
            }
            mkdir -p cases/fresh cases/initialized/config cases/initialized/data
            printf '<?xml version="1.0" encoding="utf-8"?>\n<ServerConfiguration>\n  <IsStartupWizardCompleted>true</IsStartupWizardCompleted>\n</ServerConfiguration>\n' \
              > cases/initialized/config/system.xml
            : > cases/initialized/data/jellyfin.db
            # The state a post-preflight failure leaves: setup flag false, database present.
            mkdir -p cases/partial-setup/config cases/partial-setup/data
            sed 's/>true</>false</' cases/initialized/config/system.xml > cases/partial-setup/config/system.xml
            : > cases/partial-setup/data/jellyfin.db
            mkdir -p cases/partial-log/log cases/hidden-entry
            : > cases/partial-log/log/log_19700101.log
            : > cases/hidden-entry/.compute-recovery-marker
            accepts cases/fresh "provisioning fresh state"
            accepts cases/initialized "is initialized"
            refuses cases/partial-setup "refusing partial provisioning state"
            refuses cases/partial-log "refusing partial provisioning state"
            refuses cases/hidden-entry "refusing partial provisioning state"
            refuses cases/missing "is not a directory"
            touch "$out"
          '';
    };
}
