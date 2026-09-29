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
  gateway =
    (import ../den/aspects/kubernetes/services/gateway.nix { }).den.aspects.kubernetes.services.gateway;
  withPhase =
    phase:
    lib.recursiveUpdate cluster {
      settings.kubernetes.services.identity.phase = phase;
    };
  renderIdentity =
    inventory:
    identity.k8s-manifests {
      cluster = inventory;
      inherit computeResources lib;
    };
  renderGateway =
    inventory:
    gateway.k8s-manifests {
      cluster = inventory;
      inherit computeResources lib;
      charts = { };
    };
  initial = renderIdentity (withPhase "initial");
  provisioning = renderIdentity (withPhase "provisioning");
  normal = renderIdentity (withPhase "normal");
  initialGateway = renderGateway (withPhase "initial");
  provisioningGateway = renderGateway (withPhase "provisioning");
  normalGateway = renderGateway (withPhase "normal");
  initialObjects = initial.applications.identity.objects;
  provisioningObjects = provisioning.applications.identity.objects;
  normalObjects = normal.applications.identity.objects;
  hasObject =
    objects: kind: name:
    lib.any (object: object.kind == kind && object.metadata.name == name) objects;
  applicationObjects =
    application: if application ? content then application.content.objects else application.objects;
  normalPolicyObjects = applicationObjects normal.applications.identity-gateway;
  normalRouteObjects = applicationObjects normalGateway.applications.identity-gateway;
  provisioningJob = builtins.head (
    lib.filter (
      object: object.kind == "Job" && object.metadata.name == "kanidm-provision"
    ) provisioningObjects
  );
  provisionData =
    objects:
    (builtins.head (
      lib.filter (
        object: object.kind == "ConfigMap" && object.metadata.name == "kanidm-provision"
      ) objects
    )).data;
  provisionMembers = objects: builtins.fromJSON (provisionData objects)."members.json";
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
  initialResources = identity.compute-resources { cluster = withPhase "initial"; };
  failures = lib.filterAttrs (_: value: !value) {
    three-phases-declared =
      identity.settings.phase.type.functor.payload.values == [
        "initial"
        "provisioning"
        "normal"
      ];
    initial-credential-absent =
      !(initialResources.runtimeSecrets ? "identity--kanidm-provision--idm-admin-password");
    initial-provisioning-absent =
      !(hasObject initialObjects "Role" "kanidm-client-secret")
      && !(hasObject initialObjects "RoleBinding" "kanidm-client-secret")
      && !(hasObject initialObjects "Job" "kanidm-provision");
    provisioning-rbac-before-job =
      hasObject provisioningObjects "Role" "kanidm-client-secret"
      && hasObject provisioningObjects "RoleBinding" "kanidm-client-secret"
      && hasObject provisioningObjects "ServiceAccount" "kanidm-provision"
      && provisioningJob.metadata.annotations."argocd.argoproj.io/hook" == "PostSync"
      && provisioningJob.spec.template.spec.serviceAccountName == "kanidm-provision";
    provisioning-job-present = hasObject provisioningObjects "Job" "kanidm-provision";
    administrator-membership-gated =
      provisionMembers provisioningObjects == [ ]
      && provisionMembers normalObjects
      == builtins.attrNames (builtins.fromJSON (provisionData normalObjects)."state.json").persons;
    provisioning-admin-access-absent =
      !(provisioning.applications.identity-gateway.condition)
      && !(provisioningGateway.applications.identity-gateway.condition)
      && !(hasObject provisioningGateway.applications.gateway.objects "HTTPRoute" "argocd");
    normal-admin-access-atomic =
      normal.applications.identity-gateway.condition
      && normalGateway.applications.identity-gateway.condition
      && hasObject normalPolicyObjects "SecurityPolicy" "argocd-admin"
      && hasObject normalRouteObjects "HTTPRoute" "argocd"
      &&
        (builtins.head (lib.filter (object: object.kind == "SecurityPolicy") normalPolicyObjects))
        .metadata.annotations."argocd.argoproj.io/sync-wave" == "-1"
      &&
        (builtins.head (lib.filter (object: object.kind == "HTTPRoute") normalRouteObjects))
        .metadata.annotations."argocd.argoproj.io/sync-wave" == "0";
    native-route-present-throughout =
      lib.all (rendered: hasObject rendered.applications.gateway.objects "HTTPRoute" "idm")
        [
          initialGateway
          provisioningGateway
          normalGateway
        ];
    no-active-backup-policy =
      !(lib.hasInfix "[online_backup]" serverConfig)
      && !(lib.hasInfix "schedule =" serverConfig)
      && !(lib.hasInfix "versions =" serverConfig);
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
