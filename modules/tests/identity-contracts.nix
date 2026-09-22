{
  config,
  inputs,
  lib,
  ...
}:
let
  cluster = config.den.clusters.prod-home;
  computeResources = config.clusterResources.prod-home;
  identity =
    (import ../den/aspects/kubernetes/services/identity.nix {
      inherit config inputs lib;
    }).den.aspects.kubernetes.services.identity;
  render =
    inventory:
    identity.k8s-manifests {
      cluster = inventory;
      inherit computeResources lib;
    };
  normalCluster = lib.recursiveUpdate cluster {
    settings.kubernetes.services.identity.phase = "normal";
  };
  initial = render cluster;
  normal = render normalCluster;
  initialObjects = initial.applications.identity.objects;
  normalObjects = normal.applications.identity.objects;
  normalGatewayObjects = normal.applications.identity-gateway.content.objects;
  hasObject =
    objects: kind: name:
    lib.any (object: object.kind == kind && object.metadata.name == name) objects;
  normalProvisionJob = builtins.head (
    lib.filter (
      object: object.kind == "Job" && object.metadata.name == "kanidm-provision"
    ) normalObjects
  );
  provisionContainer = builtins.head normalProvisionJob.spec.template.spec.containers;
  oidcTLSPolicy = builtins.head (
    lib.filter (
      object: object.kind == "BackendTLSPolicy" && object.metadata.name == "kanidm-oidc-tls"
    ) normalObjects
  );
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
    custom-ca-secret-absent = !(initialResources.runtimeSecrets ? "identity--kanidm-tls--ca.crt");
    initial-provision-job-absent = !(hasObject initialObjects "Job" "kanidm-provision");
    initial-oidc-backend-absent = !(hasObject initialObjects "Backend" "kanidm-oidc");
    initial-gateway-integration-absent = !initial.applications.identity-gateway.condition;
    normal-provision-job-present = hasObject normalObjects "Job" "kanidm-provision";
    normal-oidc-backend-present = hasObject normalObjects "Backend" "kanidm-oidc";
    normal-gateway-integration-present = normal.applications.identity-gateway.condition;
    gateway-rbac-owned-by-integration =
      hasObject normalGatewayObjects "Role" "kanidm-client-secret"
      && hasObject normalGatewayObjects "RoleBinding" "kanidm-client-secret"
      && !(hasObject normalObjects "Role" "kanidm-client-secret")
      && !(hasObject normalObjects "RoleBinding" "kanidm-client-secret");
    backup-cadence-unowned = !(lib.hasInfix "[online_backup]" serverConfig);
    public-pki-validation =
      oidcTLSPolicy.spec.validation.wellKnownCACertificates == "System"
      && oidcTLSPolicy.spec.validation.hostname == builtins.head cluster.routes.idm.hostnames
      && !(lib.any (
        entry:
        builtins.elem (entry.name or "") [
          "SSL_CERT_FILE"
          "CURL_CA_BUNDLE"
        ]
      ) provisionContainer.env)
      && !(lib.any (mount: mount.name == "trust") provisionContainer.volumeMounts)
      && !(lib.any (volume: volume.name == "trust") normalProvisionJob.spec.template.spec.volumes);
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
