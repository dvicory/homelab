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
        patchedHermes =
          pkgs.callPackage (self + "/pkgs/by-name/hermes-agent-patched/package.nix")
            {
              hermesAgent = hermesWithTestDependencies;
              src = inputs.hermes-agent;
            };
        codexWorkerLane = pkgs.callPackage (
          self + "/pkgs/by-name/hermes-codex-worker-lane/package.nix"
        ) { };
        sandboxAccess = pkgs.callPackage (
          self + "/pkgs/by-name/hermes-sandbox-access/package.nix"
        ) { };
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
      in
      {
        # Exercise non-default lane names and descriptions independently from
        # the generic patched-Hermes/worker runtime test below.
        checks.hermes-codex-worker-lane-custom-skill = customCodexWorkerLane;
        checks.hermes-worker-lane =
          pkgs.callPackage (self + "/pkgs/by-name/hermes-agent-patched/check.nix")
            {
              inherit codexWorkerLane patchedHermes sandboxAccess;
            };
      }
    );
}
