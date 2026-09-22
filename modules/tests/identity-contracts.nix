{
  config,
  inputs,
  lib,
  ...
}:
let
  cluster = config.den.clusters.prod-home;
  compute =
    config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
  identity =
    (import ../den/aspects/kubernetes/services/identity.nix {
      inherit config inputs lib;
    }).den.aspects.kubernetes.services.identity;
  render =
    inventory:
    identity.k8s-manifests {
      cluster = inventory;
      inherit compute lib;
    };
  normalCluster = lib.recursiveUpdate cluster {
    settings.kubernetes.services.identity.phase = "normal";
  };
  initial = render cluster;
  normal = render normalCluster;
  initialObjects = initial.applications.identity.objects;
  normalObjects = normal.applications.identity.objects;
  hasObject =
    objects: kind: name:
    lib.any (object: object.kind == kind && object.metadata.name == name) objects;
  serverConfig =
    (builtins.head (
      lib.filter (
        object: object.kind == "ConfigMap" && object.metadata.name == "kanidm-config"
      ) initialObjects
    )).data."server.toml";
  initialResources = identity.compute-resources { inherit cluster; };
  failures = lib.filterAttrs (_: value: !value) {
    initial-phase-declared = cluster.settings.kubernetes.services.identity.phase == "initial";
    initial-credential-absent =
      !(initialResources.runtimeSecrets ? "identity--kanidm-provision--idm-admin-password");
    initial-provision-job-absent = !(hasObject initialObjects "Job" "kanidm-provision");
    initial-oidc-backend-absent = !(hasObject initialObjects "Backend" "kanidm-oidc");
    initial-gateway-integration-absent = !initial.applications.identity-gateway.condition;
    normal-provision-job-present = hasObject normalObjects "Job" "kanidm-provision";
    normal-oidc-backend-present = hasObject normalObjects "Backend" "kanidm-oidc";
    normal-gateway-integration-present = normal.applications.identity-gateway.condition;
    backup-cadence-unowned = !(lib.hasInfix "[online_backup]" serverConfig);
  };
in
{
  perSystem =
    { pkgs, ... }:
    {
      checks.identity-contracts =
        assert lib.assertMsg (failures == { })
          "Identity contract checks failed: ${builtins.concatStringsSep ", " (builtins.attrNames failures)}";
        pkgs.writeText "identity-contracts" "ok\n";
    };
}
