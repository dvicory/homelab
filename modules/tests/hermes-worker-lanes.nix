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
    lib.optionalAttrs (builtins.hasAttr system inputs.hermes-agent.packages) (
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
        customCodexWorkerLane =
          pkgs.callPackage (self + "/pkgs/by-name/hermes-codex-worker-lane/package.nix")
            {
              lanes = [
                {
                  name = "architecture-review";
                  description = "architecture decisions that require no file changes";
                  approvalPolicy = "on-request";
                  approvalsReviewer = "auto_review";
                  sandboxMode = "read-only";
                  networkAccess = false;
                  maxConcurrency = 1;
                }
                {
                  name = "code-with-network";
                  description = "implementation that needs access to declared network services";
                  approvalPolicy = "on-request";
                  approvalsReviewer = "auto_review";
                  sandboxMode = "workspace-write";
                  networkAccess = true;
                  maxConcurrency = 1;
                }
              ];
            };
        workerLaneSettings = import (self + "/modules/den/aspects/workloads/hermes/_settings.nix") {
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
          }).config.settings;
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
      in
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
          pkgs.runCommand "hermes-worker-lane-options" { } "touch $out";
        checks.hermes-worker-lane =
          pkgs.callPackage (self + "/pkgs/by-name/hermes-agent-patched/check.nix")
            {
              inherit codexWorkerLane patchedHermes sandboxAccess;
            };
      }
    );
}
