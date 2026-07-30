{
  inputs,
  self,
  ...
}:
{
  perSystem =
    {
      lib,
      pkgs,
      system,
      ...
    }:
    lib.recursiveUpdate
      (lib.optionalAttrs (builtins.hasAttr system inputs.hermes-agent.packages) (
        let
          hermesWithTestDependencies = (inputs.hermes-agent.packages.${system}.default).override {
            extraDependencyGroups = [
              "messaging"
              "dev"
            ];
          };
          patchedHermes = pkgs.callPackage (self + "/pkgs/by-name/hermes-agent-patched/package.nix") {
            hermesAgent = hermesWithTestDependencies;
            src = inputs.hermes-agent;
          };
          codexWorkerLane = pkgs.callPackage (
            self + "/pkgs/by-name/hermes-codex-worker-lane/package.nix"
          ) { };
          sandboxAccess = pkgs.callPackage (self + "/pkgs/by-name/hermes-sandbox-access/package.nix") { };
          qaHome = self.homeConfigurations."hermes-qa-runner@hvn-hyp1";
          qaContainer = qaHome.config.virtualisation.quadlet.containers.hermes-qa.containerConfig;
          qaCodexLanes = builtins.fromJSON qaContainer.environments.CODEX_WORKER_LANES;
          qaVolumes = qaContainer.volumes;
          configMountTarget = ":/home/hermes/.hermes/config.yaml:ro";
          qaConfigMount =
            lib.findFirst (lib.hasSuffix configMountTarget)
              (throw "QA Hermes container has no managed config mount")
              qaVolumes;
          qaConfigPath = lib.removeSuffix configMountTarget qaConfigMount;
          customCodexWorkerLane =
            pkgs.callPackage (self + "/pkgs/by-name/hermes-codex-worker-lane/package.nix")
              {
                lanes = [
                  {
                    name = "architecture-review";
                    description = "architecture decisions that require no file changes";
                    approvalPolicy = "never";
                    approvalsReviewer = "user";
                    sandboxMode = "read-only";
                    networkAccess = false;
                    maxConcurrency = 1;
                  }
                  {
                    name = "code-with-network";
                    description = "implementation that needs access to declared network services";
                    approvalPolicy = "never";
                    approvalsReviewer = "user";
                    sandboxMode = "workspace-write";
                    networkAccess = true;
                    maxConcurrency = 1;
                  }
                ];
              };
          workerLaneSettings = import (self + "/modules/den/aspects/workloads/hermes/_settings.nix") {
            inherit lib;
          };
          catalogueLib = import (self + "/modules/den/aspects/workloads/hermes/_catalogue.nix") {
            inherit lib;
          };
          evalWorkerLaneSettings =
            value:
            lib.evalModules {
              modules = [
                {
                  options.settings = lib.mkOption {
                    type = lib.types.submodule {
                      options = workerLaneSettings;
                    };
                  };
                  config.settings = value;
                }
              ];
            };
          validWorkerLane =
            (evalWorkerLaneSettings {
              instance = "test";
              workerLanes.project = {
                description = "project implementation";
                runtime = "hermes";
                profile = "default";
                agent = {
                  model = "test-model";
                  reasoningEffort = "high";
                  tools = [ "terminal" ];
                  skills = [ "nix" ];
                };
                workspace = {
                  projectMode = "required";
                  projectProvider = "broker-project";
                  maximumPermission = "workspace-write";
                  supportedSourceKinds = [ "git" ];
                  inputs = {
                    maxInputs = 4;
                    maxBytes = 16777216;
                    maxEntries = 5000;
                    maxPathBytes = 2048;
                  };
                };
                policy.worklane = "project";
                execution = {
                  timeoutSeconds = 1800;
                  maxTurns = 20;
                  cpus = 2;
                  memoryMiB = 4096;
                  diskMiB = 16384;
                };
                maxConcurrency = 2;
              };
              boards.main = {
                allowedLanes = [ "project" ];
                allowedProjects = [ "repository" ];
                defaultProject = "repository";
              };
              projects.repository = {
                title = "Repository";
                source = {
                  type = "git";
                  repositoryId = "repository";
                };
                laneAccess.project = "workspace-write";
              };
              projectSources.repository = {
                type = "git";
                upstream = "https://github.com/example/repository.git";
                defaultRef = "main";
                credential = {
                  adapter = "github-token";
                  secretRef = "test-github";
                };
              };
            }).config.settings;
          validCatalogue = catalogueLib.resolve validWorkerLane;
          invalidBoardReference = builtins.tryEval (
            builtins.deepSeq (catalogueLib.resolve (
              validWorkerLane
              // {
                boards.invalid = {
                  allowedLanes = [ "missing" ];
                  allowedProjects = [ ];
                };
              }
            )) true
          );
          invalidPermissionEscalation = builtins.tryEval (
            builtins.deepSeq (catalogueLib.resolve (
              lib.recursiveUpdate validWorkerLane {
                workerLanes.project.workspace.maximumPermission = "read-only";
              }
            )) true
          );
          invalidSourceUpstream = builtins.tryEval (
            builtins.deepSeq (catalogueLib.resolve (
              lib.recursiveUpdate validWorkerLane {
                projectSources.repository.upstream = "https://token@github.com/example/repository.git";
              }
            )) true
          );
          invalidStoreUpstream = builtins.tryEval (
            builtins.deepSeq (catalogueLib.resolve (
              lib.recursiveUpdate validWorkerLane {
                projectSources.repository.upstream = "/nix/store/abcd-source";
              }
            )) true
          );
          invalidUnknownRepository = builtins.tryEval (
            builtins.deepSeq (catalogueLib.resolve (
              lib.recursiveUpdate validWorkerLane {
                projects.repository.source.repositoryId = "missing";
              }
            )) true
          );
          invalidCredentialRef = builtins.tryEval (
            builtins.deepSeq ((evalWorkerLaneSettings (
              lib.recursiveUpdate validWorkerLane {
                projectSources.repository.credential.secretRef = "/run/secrets/token";
              }
            )).config.settings) true
          );
          invalidMemoryMode = builtins.tryEval (
            builtins.deepSeq ((evalWorkerLaneSettings {
              workerLanes.invalid = {
                description = "invalid memory mode";
                runtime = "hermes";
                memory = "profile";
              };
            }).config.settings.workerLanes.invalid
            ) true
          );
          invalidUnknownSetting = builtins.tryEval (
            builtins.deepSeq ((evalWorkerLaneSettings {
              instance = "test";
              unknownInfrastructureField = true;
            }).config.settings
            ) true
          );
          invalidInputCeilings = builtins.tryEval (
            builtins.deepSeq (catalogueLib.resolve (
              lib.recursiveUpdate validWorkerLane {
                workerLanes.project.workspace.inputs.maxInputs = 0;
              }
            )) true
          );
        in
        (
          {
            # Exercise non-default lane names and descriptions independently from
            # the generic patched-Hermes/worker runtime test below.
            checks.hermes-codex-worker-lane-custom-skill = customCodexWorkerLane;
            checks.hermes-worker-lane-options =
              assert validWorkerLane.instance == "test";
              assert validWorkerLane.workerLanes.project.memory == "disabled";
              assert validWorkerLane.workerLanes.project.maxConcurrency == 2;
              assert !invalidMemoryMode.success;
              assert !invalidUnknownSetting.success;
              assert builtins.stringLength validCatalogue.revision == 64;
              assert validCatalogue.revision == (catalogueLib.resolve validWorkerLane).revision;
              assert builtins.stringLength validCatalogue.sourceRevisions.repository == 64;
              assert builtins.stringLength validCatalogue.providerRevisions.broker-project == 64;
              assert !invalidBoardReference.success;
              assert !invalidPermissionEscalation.success;
              assert !invalidSourceUpstream.success;
              assert !invalidStoreUpstream.success;
              assert !invalidUnknownRepository.success;
              assert !invalidCredentialRef.success;
              assert !invalidInputCeilings.success;
              assert validCatalogue.workerLanes.project.workspace.inputs.maxInputs == 4;
              assert validCatalogue.workerLanes.project.workspace.inputs.maxBytes == 16777216;
              assert lib.all (lane: lane.networkAccess) qaCodexLanes;
              assert lib.all (lane: lane.approvalPolicy == "never") qaCodexLanes;
              pkgs.runCommand "hermes-worker-lane-options" { } "touch $out";
            checks.hermes-worker-lane =
              pkgs.callPackage (self + "/pkgs/by-name/hermes-agent-patched/check.nix")
                {
                  inherit codexWorkerLane patchedHermes sandboxAccess;
                };
          }
          // lib.optionalAttrs (system == "x86_64-linux") {
            checks.hermes-qa-runtime-catalogue = pkgs.runCommand "hermes-qa-runtime-catalogue" { } ''
              export HERMES_HOME="$TMPDIR/hermes-home"
              export HERMES_QA_CONFIG=${qaConfigPath}
              export PYTHONPATH=${patchedHermes.patchedSource}
              ${patchedHermes.hermesVenv}/bin/python3 \
                ${self + "/modules/tests/hermes-qa-runtime-catalogue.py"}
              touch $out
            '';
          }
        )
      ))
      (
        # The CLI package is portable, but its macOS `sandbox-exec` backend
        # cannot nest inside Nix's own Seatbelt build sandbox. Exercise the
        # enforcement path on every published Linux package; Darwin requires
        # the equivalent host-level smoke test.
        lib.optionalAttrs
          (lib.hasSuffix "-linux" system && builtins.hasAttr system inputs.llm-agents.packages)
          {
            checks.hermes-codex-permission-profiles =
              let
                codex = lib.getExe inputs.llm-agents.packages.${system}.codex;
              in
              pkgs.runCommand "hermes-codex-permission-profiles" { } ''
                workspace="$TMPDIR/workspace"
                mkdir -p "$workspace"
                cd "$workspace"

                if ${codex} \
                  --config 'features.network_proxy=true' \
                  --config 'permissions.hermes-worker.extends=":read-only"' \
                  --config 'permissions.hermes-worker.network.enabled=true' \
                  --config 'permissions.hermes-worker.network.mode="full"' \
                  sandbox --permission-profile hermes-worker -- \
                  touch read-only-write
                then
                  echo "read-only permission profile allowed a workspace write" >&2
                  exit 1
                fi
                test ! -e "$workspace/read-only-write"

                ${codex} \
                  --config 'permissions.hermes-worker.extends=":workspace"' \
                  sandbox --permission-profile hermes-worker -- \
                  touch workspace-write
                test -e "$workspace/workspace-write"
                touch "$out"
              '';
          }
      );
}
