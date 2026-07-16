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
          pkgs.callPackage (self + "/pkgs/by-name/hermes-agent-with-worker-lanes/package.nix")
            {
              hermesAgent = hermesWithTestDependencies;
              src = inputs.hermes-agent;
            };
        codexWorkerLane = pkgs.callPackage (
          self + "/pkgs/by-name/hermes-codex-worker-lane/package.nix"
        ) { };
      in
      {
        checks.hermes-worker-lane =
          pkgs.callPackage (self + "/pkgs/by-name/hermes-agent-with-worker-lanes/check.nix")
            {
              inherit codexWorkerLane patchedHermes;
            };
      }
    );
}
