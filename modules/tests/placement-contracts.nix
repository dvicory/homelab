{
  config,
  den,
  inputs,
  lib,
  withSystem,
  ...
}:
let
  cluster = config.den.clusters.prod-home;
  environment = config.den.environments.${cluster.environment};
  retainedStorageRenderer =
    (import ../den/aspects/kubernetes/services/retained-storage.nix { inherit config inputs; })
    .den.aspects.kubernetes.services.retained-storage.k8s-manifests;
  rendererFixture = {
    instance = "compute-1";
    retainedPaths.kubernetes-volumes = {
      path = "/host-only/state/kubernetes-volumes";
      guestPath = "/srv/state/kubernetes-volumes";
      uid = 0;
      gid = 0;
      mode = "0700";
      readOnly = false;
    };
    stateRoot = {
      guestPath = "/srv/state";
      marker = ".homelab-state-root";
    };
    storageCapabilities = [ "media" ];
    runtimeSecrets = { };
    images = [ "guest-image" ];
  };
  rendererBoundaryAssertions =
    let
      render =
        retained:
        retainedStorageRenderer {
          computeResources = rendererFixture // {
            retainedPaths.kubernetes-volumes = retained;
            unrelatedProjectedCapability = "ignored";
          };
          inherit lib;
        };
      nodePaths =
        retained:
        (render retained).applications.local-path-provisioner.helm.releases.local-path-provisioner.values.nodePathMap;
      retained = rendererFixture.retainedPaths.kubernetes-volumes;
    in
    nodePaths retained == [
      {
        node = rendererFixture.instance;
        paths = [ retained.guestPath ];
      }
    ]
    && lib.all (
      unsafe:
      !(builtins.tryEval (builtins.deepSeq (nodePaths (retained // unsafe)) true)).success
    ) [
      { uid = 1000; }
      { gid = 1000; }
      { mode = "0755"; }
      { readOnly = true; }
    ];
  policiesFor =
    declared:
    (import ../den/policies/clusters.nix {
      inherit
        den
        inputs
        lib
        withSystem
        ;
      config = config // {
        den = config.den // {
          clusters.prod-home = declared;
        };
      };
    }).config.den.policies;
  rejected = value: !(builtins.tryEval (builtins.length value)).success;
  policy = policiesFor cluster;
  policyAssertions =
    !rejected (policy.environment-to-clusters { inherit environment; })
    && rejected (
      (policiesFor (cluster // { environment = "missing-placement-environment"; }))
      .environment-to-clusters
        { inherit environment; }
    )
    && rejected (
      (policiesFor (cluster // { hostName = "missing-placement-host"; })).environment-to-clusters {
        inherit environment;
      }
    )
    && rejected (
      policy.cluster-aspect {
        cluster = cluster // {
          name = "missing-placement-aspect";
        };
      }
    );
in
{
  perSystem =
    { pkgs, ... }:
    {
      checks.placement-contracts =
        assert lib.assertMsg rendererBoundaryAssertions
          "Retained storage must project only its guest path and refuse unsafe parent ownership or access";
        assert lib.assertMsg policyAssertions
          "Cluster policies must reject undeclared environments, hosts and application aspects";
        pkgs.writeText "placement-contracts" "ok\n";
    };
}
