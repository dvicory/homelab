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
  argocdAspect =
    (import ../den/aspects/kubernetes/services/argocd.nix { inherit lib; })
    .den.aspects.kubernetes.services.argocd;
  withPhase =
    phase:
    lib.recursiveUpdate cluster {
      settings.kubernetes.services.identity.phase = phase;
    };
  renderArgocd =
    inventory:
    argocdAspect.k8s-manifests {
      cluster = inventory;
      charts = { };
      inherit lib;
    };
  argocdConfigs =
    inventory: (renderArgocd inventory).applications.argocd.helm.releases.argocd.values.configs;
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
    ) normalPolicyObjects
  );
  serverConfig =
    (builtins.head (
      lib.filter (
        object: object.kind == "ConfigMap" && object.metadata.name == "kanidm-config"
      ) initialObjects
    )).data."server.toml";
  initialResources = identity.compute-resources { cluster = withPhase "initial"; };
  findObject =
    objects: kind: namespace: name:
    lib.findFirst (
      object:
      object.kind == kind
      && object.metadata.name == name
      && (object.metadata.namespace or "") == namespace
    ) null objects;
  normalState = builtins.fromJSON (provisionData normalObjects)."state.json";
  provisionClients = objects: builtins.fromJSON (provisionData objects)."clients.json";
  normalClients = provisionClients normalObjects;
  envValue =
    name: (lib.findFirst (entry: entry.name == name) { value = null; } provisionContainer.env).value;
  # Argo CD side, rendered from the same cluster inventory.
  normalArgocd = argocdConfigs (withPhase "normal");
  normalOidc = builtins.fromJSON normalArgocd.cm."oidc.config";
  argocdClient = lib.findFirst (client: client.name == normalOidc.clientID) null normalClients;
  argocdRoute = cluster.routes.argocd;
  kanidmIngress =
    objects: (findObject objects "NetworkPolicy" namespace "kanidm-private").spec.ingress;
  namespace = "identity";
  allowsArgocdServer = lib.any (
    rule:
    lib.any (
      peer:
      (peer.namespaceSelector.matchLabels."kubernetes.io/metadata.name" or null) == argocdRoute.namespace
      && (peer.podSelector.matchLabels or null) == argocdRoute.backendPodSelector
    ) (rule.from or [ ])
  );
  publicationIntact =
    objects: client:
    let
      secret = findObject objects "Secret" client.secret.namespace client.secret.name;
      role = findObject objects "Role" client.secret.namespace "kanidm-client-secret-${client.name}";
      binding =
        findObject objects "RoleBinding" client.secret.namespace
          "kanidm-client-secret-${client.name}";
    in
    secret != null
    && !(secret ? data)
    && !(secret ? stringData)
    && (secret.metadata.labels or { }) == client.secret.labels
    && role != null
    && binding != null
    && binding.roleRef.name == role.metadata.name
    &&
      binding.subjects == [
        {
          kind = "ServiceAccount";
          name = "kanidm-provision";
          inherit namespace;
        }
      ]
    # No `create`: the Job can only read and patch its one declared Secret.
    && lib.all (
      rule:
      rule.resources == [ "secrets" ]
      && (rule.resourceNames or [ ]) == [ client.secret.name ]
      && lib.all (
        verb:
        builtins.elem verb [
          "get"
          "patch"
        ]
      ) rule.verbs
    ) role.rules;
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
      !(lib.any (
        object:
        builtins.elem object.kind [
          "Role"
          "RoleBinding"
          "Secret"
        ]
      ) initialObjects)
      && !(hasObject initialObjects "Job" "kanidm-provision");
    provisioning-rbac-before-job =
      lib.all (publicationIntact provisioningObjects) (provisionClients provisioningObjects)
      && hasObject provisioningObjects "ServiceAccount" "kanidm-provision"
      && provisioningJob.metadata.annotations."argocd.argoproj.io/hook" == "PostSync"
      && provisioningJob.spec.template.spec.serviceAccountName == "kanidm-provision";
    provisioning-job-present = hasObject provisioningObjects "Job" "kanidm-provision";
    oidc-transport-with-admin-consumer =
      lib.all
        (
          objects:
          !(hasObject objects "Backend" "kanidm-oidc")
          && !(hasObject objects "BackendTLSPolicy" "kanidm-oidc-tls")
        )
        [
          initialObjects
          provisioningObjects
          normalObjects
        ]
      && hasObject normalPolicyObjects "Backend" "kanidm-oidc"
      && hasObject normalPolicyObjects "BackendTLSPolicy" "kanidm-oidc-tls";
    administrator-membership-gated =
      provisionMembers provisioningObjects == [ ]
      &&
        provisionMembers normalObjects
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
    # Every Kanidm client in the provisioning state has a publication entry,
    # and every entry's Secret, Role and RoleBinding are declared without
    # `create` rights in both activated phases.
    client-secrets-declared-without-create =
      lib.sort builtins.lessThan (map (client: client.name) normalClients)
      == builtins.attrNames normalState.systems.oauth2
      && lib.all (publicationIntact normalObjects) normalClients;
    admin-gateway-session-renews = lib.all (policy: policy.spec.oidc.refreshToken) (
      lib.filter (object: object.kind == "SecurityPolicy") normalPolicyObjects
    );
    argocd-sign-in-normal-only =
      lib.all
        (
          phase:
          let
            configs = argocdConfigs (withPhase phase);
          in
          !(configs.cm ? "oidc.config") && configs.rbac."policy.csv" == ""
        )
        [
          "initial"
          "provisioning"
        ]
      && normalArgocd.cm ? "oidc.config"
      && !(allowsArgocdServer (kanidmIngress provisioningObjects))
      && allowsArgocdServer (kanidmIngress normalObjects);
    # Redirects registered in Kanidm are exactly Argo CD's callbacks for the
    # declared route hostnames, and Argo CD knows every one of those URLs.
    argocd-redirects-match-route =
      normalState.systems.oauth2.${normalOidc.clientID}.originUrl
      == map (hostname: "https://${hostname}/auth/callback") argocdRoute.hostnames
      &&
        [ normalArgocd.cm.url ] ++ builtins.fromJSON normalArgocd.cm.additionalUrls
        == map (hostname: "https://${hostname}") argocdRoute.hostnames
      &&
        normalOidc.issuer
        == "https://${builtins.head cluster.routes.idm.hostnames}/oauth2/openid/${normalOidc.clientID}";
    # Kanidm denies a request whose scopes are not all mapped to the user's
    # groups, and `groups_name` emits short group names in the `groups`
    # claim. The RBAC group must be the one group the Job maps scopes to.
    argocd-admin-group-matches-kanidm =
      argocdClient != null
      && normalOidc.requestedScopes == argocdClient.scopes
      && builtins.elem "groups_name" normalOidc.requestedScopes
      && !(builtins.elem "groups" normalOidc.requestedScopes)
      && normalArgocd.rbac.scopes == "[groups]"
      && envValue "KANIDM_ADMIN_GROUP" == cluster.settings.kubernetes.services.identity.adminGroup
      && builtins.attrNames normalState.groups == [ (envValue "KANIDM_ADMIN_GROUP") ]
      && normalArgocd.rbac."policy.csv" == "g, ${envValue "KANIDM_ADMIN_GROUP"}, role:admin\n"
      && normalArgocd.rbac."policy.default" == "";
    argocd-client-secret-reference =
      normalOidc.clientSecret == "$" + argocdClient.secret.name + ":" + argocdClient.secret.key
      && argocdClient.secret.namespace == argocdRoute.namespace
      && argocdClient.secret.labels == { "app.kubernetes.io/part-of" = "argocd"; }
      && normalOidc.enablePKCEAuthentication
      && !normalState.systems.oauth2.${normalOidc.clientID}.allowInsecureClientDisablePkce
      && !normalState.systems.oauth2.${normalOidc.clientID}.public;
    # Local `admin` sign-in exists only before Kanidm sign-in does. It sits
    # behind the Gateway's Kanidm gate, so it cannot help when Kanidm is down.
    argocd-local-admin-normal-disabled =
      normalArgocd.cm."admin.enabled" == false
      && lib.all (phase: (argocdConfigs (withPhase phase)).cm."admin.enabled" == true) [
        "initial"
        "provisioning"
      ];
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
