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
      id = "fixture/kubernetes-volumes";
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
  };
  rendererBoundaryAssertions =
    let
      rendered = retainedStorageRenderer {
        computeResources = rendererFixture;
        inherit lib;
      };
      app = rendered.applications.local-path-provisioner;
      helper = builtins.fromJSON app.resources.configMaps.local-path-config.data."helperPod.yaml".content;
    in
    app.helm.releases.local-path-provisioner.values.nodePathMap == [
      {
        node = rendererFixture.instance;
        paths = [ rendererFixture.stateRoot.guestPath ];
      }
    ]
    && helper.spec.automountServiceAccountToken == false
    &&
      (builtins.head helper.spec.containers).volumeMounts == [
        {
          name = "data";
          mountPath = "/retained";
          readOnly = true;
        }
      ];
  retainedObjects =
    paths:
    (retainedStorageRenderer {
      computeResources = rendererFixture // {
        retainedPaths = rendererFixture.retainedPaths // paths;
      };
      inherit lib;
    }).applications.retained-storage.objects;
  retainedDirectoriesAssertions =
    let
      inventory =
        objects:
        builtins.fromJSON (
          (lib.findFirst (object: object.kind == "ConfigMap") null objects).data."directories.json"
        );
      base = retainedObjects { };
      added = {
        id = "fixture/added";
        path = "/host-only/state/added";
        guestPath = "/srv/state/added";
        uid = 751;
        gid = 751;
        mode = "0750";
        readOnly = false;
      };
      extended = retainedObjects { inherit added; };
    in
    lib.all (object: object.kind != "Job") base
    &&
      inventory extended == inventory base
      // {
        added = {
          inherit (added)
            id
            uid
            gid
            mode
            ;
        };
      };
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
          "Retained publication must use the guest root and a read-only helper mount";
        assert lib.assertMsg retainedDirectoriesAssertions
          "New retained identities must change compared inventory without a mutating hook";
        assert lib.assertMsg policyAssertions
          "Cluster policies must reject undeclared environments, hosts and application aspects";
        pkgs.writeText "placement-contracts" "ok\n";
    };
}
