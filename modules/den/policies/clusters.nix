{
  lib,
  den,
  config,
  inputs,
  withSystem,
  ...
}:
let
  inherit (den.lib.policy) resolve;
  clusters = config.den.clusters;
  clusterAspect =
    { cluster, ... }:
    let
      aspect = den.aspects.${cluster.name} or null;
    in
    assert lib.assertMsg (aspect != null) "Cluster ${cluster.name} has no application aspect";
    [ (den.lib.policy.include aspect) ];
in
{
  config = {
    den.policies.environment-to-clusters =
      { environment, ... }:
      lib.concatMap (
        name:
        let
          cluster = clusters.${name};
        in
        assert lib.assertMsg (builtins.hasAttr cluster.environment config.den.environments)
          "Cluster ${name} references unknown environment ${cluster.environment}";
        lib.optionals (cluster.environment == environment.name) [
          (resolve.to "cluster" {
            cluster = cluster // {
              inherit name;
            };
          })
        ]
      ) (builtins.attrNames clusters);

    den.policies.cluster-to-resources =
      { cluster, ... }:
      den.lib.policy.instantiate {
        inherit (cluster) name;
        class = "compute-resources";
        intoAttr = [
          "clusterResources"
          cluster.name
        ];
        instantiate =
          { modules, ... }:
          let evaluated = lib.evalModules {
            specialArgs = { inherit cluster; };
            modules = modules ++ [
              (inputs.nixpkgs + "/nixos/modules/misc/assertions.nix")
              {
                options.preCaptureChecks = lib.mkOption {
                  type = lib.types.lines;
                  default = "";
                  description = "Service-owned checks run with k() access before cold capture stops writers.";
                };
                options.retainedPaths = lib.mkOption {
                  default = { };
                  type = lib.types.attrsOf (
                    lib.types.submodule {
                      options = {
                        uid = lib.mkOption { type = lib.types.ints.unsigned; };
                        gid = lib.mkOption { type = lib.types.ints.unsigned; };
                        mode = lib.mkOption { type = lib.types.str; };
                        readOnly = lib.mkOption {
                          type = lib.types.bool;
                          default = false;
                        };
                      };
                    }
                  );
                };
                options.runtimeSecrets = den.aspects.virtualization.compute.settings.options.runtimeSecrets;
              }
            ];
          };
          in lib.asserts.checkAssertWarn evaluated.config.assertions evaluated.config.warnings evaluated.config;
      };

    den.policies.cluster-to-nixidy =
      { cluster, environment, ... }:
      map (
        system:
        den.lib.policy.instantiate {
          inherit (cluster) name;
          class = "k8s-manifests";
          intoAttr = [
            "nixidyEnvs"
            system
            cluster.name
          ];
          instantiate =
            { modules, ... }:
            withSystem system (
              { pkgs, ... }:
              (lib.makeOverridable inputs.nixidy.lib.mkEnv) {
                inherit pkgs;
                # Den emits module diagnostics at the standard root paths.
                modules = modules ++ [
                  (lib.mkAliasOptionModule [ "warnings" ] [ "nixidy" "warnings" ])
                  (lib.mkAliasOptionModule [ "assertions" ] [ "nixidy" "assertions" ])
                ];
                charts = inputs.nixhelm.chartsDerivations.${system} or { };
                extraSpecialArgs = {
                  inherit
                    inputs
                    system
                    cluster
                    environment
                    ;
                  compute =
                    config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
                };
              }
            );
        }
      ) (lib.unique config.systems);

    den.policies.cluster-aspect = clusterAspect;
    den.schema.environment.includes = [ den.policies.environment-to-clusters ];
    den.schema.cluster.includes = [
      den.policies.cluster-to-resources
      den.policies.cluster-to-nixidy
      den.policies.cluster-aspect
    ];
  };
}
