{ lib, den, config, inputs, withSystem, ... }:
let
  inherit (den.lib.policy) resolve;
  clusters = config.den.clusters;
  clusterAspect =
    { cluster, ... }:
    let aspect = den.aspects.${cluster.name} or null;
    in lib.optionals (aspect != null) [ (den.lib.policy.include aspect) ];
in
{
  config = {
    den.policies.environment-to-clusters =
      { environment, ... }:
      lib.concatMap (
        name:
        let cluster = clusters.${name};
        in lib.optionals (cluster.environment == environment.name) [
          (resolve.to "cluster" { cluster = cluster // { inherit name; }; })
        ]
      ) (builtins.attrNames clusters);

    den.policies.cluster-to-nixidy =
      { cluster, environment, ... }:
      map
        (system:
          den.lib.policy.instantiate {
            inherit (cluster) name;
            class = "k8s-manifests";
            intoAttr = [ "nixidyEnvs" system cluster.name ];
            instantiate = { modules, ... }:
              withSystem system ({ pkgs, ... }:
                inputs.nixidy.lib.mkEnv {
                  inherit pkgs;
                  # Den emits module diagnostics at the standard root paths.
                  modules = modules ++ [
                    (lib.mkAliasOptionModule [ "warnings" ] [ "nixidy" "warnings" ])
                    (lib.mkAliasOptionModule [ "assertions" ] [ "nixidy" "assertions" ])
                  ];
                  charts = inputs.nixhelm.chartsDerivations.${system} or { };
                  extraSpecialArgs = {
                    inherit inputs system cluster environment;
                    images = config.flake.imageRefs.${system} or { };
                  };
                }
              );
          }
        )
        (lib.unique config.systems);

    den.policies.cluster-aspect = clusterAspect;
    den.schema.environment.includes = [ den.policies.environment-to-clusters ];
    den.schema.cluster.includes = [
      den.policies.cluster-to-nixidy
      den.policies.cluster-aspect
    ];
  };
}
