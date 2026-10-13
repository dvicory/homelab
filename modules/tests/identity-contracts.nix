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
  argocdSecret = lib.findFirst (
    secret: "$" + secret.name + ":" + secret.key == normalOidc.clientSecret
  ) null argocdClient.secrets;
  argocdRoute = cluster.routes.argocd;
  adminRoutes = lib.filterAttrs (_: route: route.auth == "admin") cluster.routes;
  routeUrls =
    route:
    map (hostname: "https://${hostname}${lib.removeSuffix "/" route.pathPrefix}") route.hostnames;
  clientSecrets = clients: lib.concatMap (client: client.secrets) clients;
  normalSecurityPolicies = lib.filter (object: object.kind == "SecurityPolicy") normalPolicyObjects;
  # An administrator route without a display name has no Kanidm entry name.
  extraAdminRoute =
    name: displayName:
    lib.recursiveUpdate (withPhase "normal") {
      routes.${name} = argocdRoute // {
        inherit displayName;
        hostnames = [ "extra.example.test" ];
        pathPrefix = "/extra/";
      };
    };
  renderedState =
    inventory:
    builtins.fromJSON (provisionData (renderIdentity inventory).applications.identity.objects)."state.json";
  rendersIdentity =
    inventory:
    (builtins.tryEval (
      builtins.deepSeq (provisionData (renderIdentity inventory).applications.identity.objects) true
    )).success;
  kanidmIngress =
    objects: (findObject objects "NetworkPolicy" namespace "kanidm-private").spec.ingress;
  namespace = "identity";
  inherit (cluster.settings.kubernetes.services.identity) adminGroup householdGroup directory;
  jellyfinRoute = cluster.routes.jellyfin;
  normalPolicies = builtins.fromJSON (provisionData normalObjects)."policies.json";
  policyFor = group: lib.findFirst (policy: policy.group == group) null normalPolicies;
  # Kanidm's credential-type minimums, weakest first.
  credentialStrengths = [
    "any"
    "mfa"
    "passkey"
    "attested_passkey"
  ];
  kanidmDeployment = findObject normalObjects "Deployment" namespace "kanidm";
  kanidmService = findObject normalObjects "Service" namespace "kanidm";
  # NetworkPolicies are additive, regardless of name or application owner.
  admissionObjects =
    identityRendered: gatewayRendered:
    lib.concatMap (
      application:
      if application.condition or true then
        application.content.objects or (application.objects or [ ])
      else
        [ ]
    ) (builtins.attrValues identityRendered.applications ++ builtins.attrValues gatewayRendered.applications);
  kanidmLabels = kanidmDeployment.spec.template.metadata.labels;
  selectsKanidm =
    selector:
    lib.matchAttrs (selector.matchLabels or { }) kanidmLabels
    && lib.all (
      expression:
      let
        present = builtins.hasAttr expression.key kanidmLabels;
        listed = present && lib.elem kanidmLabels.${expression.key} (expression.values or [ ]);
      in
      if expression.operator == "In" then listed
      else if expression.operator == "NotIn" then !listed
      else if expression.operator == "Exists" then present
      else if expression.operator == "DoesNotExist" then !present
      else throw "Unsupported Kubernetes selector operator"
    ) (selector.matchExpressions or [ ]);
  directoryPeers =
    objects:
    lib.unique (lib.concatMap (
      policy:
      lib.concatMap (
        rule:
        let
          ports = rule.ports or [ ];
          admits = port:
            (port.protocol or "TCP") == "TCP"
            && (
              !(port ? port)
              || port.port == "ldaps"
              || (builtins.isInt port.port
                && port.port <= directory.port
                && directory.port <= (port.endPort or port.port))
            );
        in
        if ports == [ ] || lib.any admits ports then
          if rule.from or [ ] == [ ] then [ "anyone" ] else rule.from
        else [ ]
      ) (policy.spec.ingress or [ ])
    ) (lib.filter (
      object:
      object.kind == "NetworkPolicy"
      && object.metadata.namespace == namespace
      && selectsKanidm object.spec.podSelector
      && lib.elem "Ingress" (object.spec.policyTypes or [ "Ingress" ])
    ) objects));
  allowsArgocdServer = lib.any (
    rule:
    lib.any (
      peer:
      (peer.namespaceSelector.matchLabels."kubernetes.io/metadata.name" or null) == argocdRoute.namespace
      && (peer.podSelector.matchLabels or null) == argocdRoute.backendPodSelector
    ) (rule.from or [ ])
  );
  publicationIntact =
    objects: declared:
    let
      secret = findObject objects "Secret" declared.namespace declared.name;
      role = findObject objects "Role" declared.namespace "kanidm-client-secret-${declared.name}";
      binding = findObject objects "RoleBinding" declared.namespace "kanidm-client-secret-${declared.name}";
    in
    secret != null
    && !(secret ? data)
    && !(secret ? stringData)
    && (secret.metadata.labels or { }) == declared.labels
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
      && (rule.resourceNames or [ ]) == [ declared.name ]
      && lib.all (
        verb:
        builtins.elem verb [
          "get"
          "patch"
        ]
      ) rule.verbs
    ) role.rules;
  failures = lib.filterAttrs (_: value: !value) {
    # Kanidm serves LDAPS on the declared directory port, on its Service.
    directory-listens =
      lib.hasInfix ''ldapbindaddress = "0.0.0.0:${toString directory.port}"'' serverConfig
      && builtins.elem {
        name = "ldaps";
        containerPort = directory.port;
      } (builtins.head kanidmDeployment.spec.template.spec.containers).ports
      && builtins.elem {
        name = "ldaps";
        port = directory.port;
        targetPort = "ldaps";
        protocol = "TCP";
      } kanidmService.spec.ports;
    # Only Jellyfin's pods reach the directory, in every phase.
    directory-admits-only-jellyfin = lib.all (
      objects:
      directoryPeers objects == [
        {
          namespaceSelector.matchLabels."kubernetes.io/metadata.name" = jellyfinRoute.namespace;
          podSelector.matchLabels = jellyfinRoute.backendPodSelector;
        }
      ]
    ) [
      (admissionObjects initial initialGateway)
      (admissionObjects provisioning provisioningGateway)
      (admissionObjects normal normalGateway)
    ];
    # Kanidm applies the strictest value of each setting across a person's
    # groups. Administrators state an MFA-or-stronger minimum themselves and
    # never bind to LDAP with their primary password. Household members bind
    # with it, and the all-persons floor must not exceed their minimum, or a
    # password-only member could not exist.
    account-policies-declared =
      let
        rank = minimum: lib.lists.findFirstIndex (value: value == minimum) null credentialStrengths;
        admin = policyFor adminGroup;
        household = policyFor householdGroup;
        floor = policyFor "idm_all_persons";
      in
      lib.all (policy: rank policy.credentialTypeMinimum != null) normalPolicies
      && lib.length (lib.unique (map (policy: policy.group) normalPolicies)) == lib.length normalPolicies
      && admin != null
      && rank admin.credentialTypeMinimum >= rank "mfa"
      && admin.allowPrimaryCredFallback == false
      && household != null
      && household.allowPrimaryCredFallback == true
      && floor != null
      && rank floor.credentialTypeMinimum <= rank household.credentialTypeMinimum
      && normalPolicies == builtins.fromJSON (provisionData provisioningObjects)."policies.json";
    # Provisioning creates the household group but never owns its members.
    household-membership-operator-owned =
      normalState.groups.${householdGroup} == {
        members = [ ];
        overwriteMembers = false;
      }
      && householdGroup != adminGroup;
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
      lib.all (publicationIntact provisioningObjects) (clientSecrets (provisionClients provisioningObjects))
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
      && lib.all (publicationIntact normalObjects) (clientSecrets normalClients);
    # Kanidm lists each client a person may use as an application. Each
    # administrator route has exactly one client, named after the route,
    # whose display name and landing are that application's.
    one-client-per-admin-route =
      builtins.attrNames normalState.systems.oauth2 == builtins.attrNames adminRoutes
      && lib.all (
        name:
        let
          route = adminRoutes.${name};
          client = normalState.systems.oauth2.${name};
        in
        client.displayName == route.displayName
        && lib.hasPrefix "${builtins.head (routeUrls route)}/" client.originLanding
        && lib.all (url: builtins.elem "${url}/oauth2/callback" client.originUrl) (routeUrls route)
      ) (builtins.attrNames adminRoutes)
      && rendersIdentity (extraAdminRoute "extra" "Extra")
      && !(rendersIdentity (extraAdminRoute "extra" null))
      && !(rendersIdentity (extraAdminRoute "extra.app" "Extra"))
      && (renderedState (extraAdminRoute "extra" "Extra")).systems.oauth2.extra.originUrl == [
        "https://extra.example.test/extra/oauth2/callback"
      ];
    # Each administrator route's Gateway sign-in uses that route's client and
    # a Gateway Secret the Job publishes for it.
    admin-policy-uses-route-client =
      builtins.length normalSecurityPolicies == builtins.length (builtins.attrNames adminRoutes)
      && lib.all (
        name:
        let
          policy = findObject normalPolicyObjects "SecurityPolicy" "gateway" "${name}-admin";
          client = lib.findFirst (client: client.name == name) null normalClients;
        in
        policy != null
        && client != null
        && policy.spec.oidc.clientID == name
        && policy.spec.oidc.provider.issuer
          == "https://${builtins.head cluster.routes.idm.hostnames}/oauth2/openid/${name}"
        && builtins.elem {
          namespace = "gateway";
          name = policy.spec.oidc.clientSecret.name;
          key = "client-secret";
          labels = { };
        } client.secrets
        && lib.all (scope: builtins.elem scope client.scopes) policy.spec.oidc.scopes
      ) (builtins.attrNames adminRoutes);
    # Argo CD's own sign-in uses its route's client, so Kanidm lists Argo CD
    # once, and that entry starts Argo CD's sign-in.
    argocd-shares-route-client =
      (findObject normalPolicyObjects "SecurityPolicy" "gateway" "argocd-admin").spec.oidc.clientID
      == normalOidc.clientID
      && normalState.systems.oauth2.${normalOidc.clientID}.originLanding
        == "${builtins.head (routeUrls argocdRoute)}/auth/login";
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
      == map (url: "${url}/oauth2/callback") (routeUrls argocdRoute)
      ++ map (url: "${url}/auth/callback") (routeUrls argocdRoute)
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
      && lib.all (scope: builtins.elem scope argocdClient.scopes) normalOidc.requestedScopes
      && builtins.elem "groups_name" normalOidc.requestedScopes
      && !(builtins.elem "groups" normalOidc.requestedScopes)
      && normalArgocd.rbac.scopes == "[groups]"
      && envValue "KANIDM_ADMIN_GROUP" == cluster.settings.kubernetes.services.identity.adminGroup
      && builtins.attrNames normalState.groups == lib.sort builtins.lessThan [
        (envValue "KANIDM_ADMIN_GROUP")
        householdGroup
      ]
      && normalArgocd.rbac."policy.csv" == "g, ${envValue "KANIDM_ADMIN_GROUP"}, role:admin\n"
      && normalArgocd.rbac."policy.default" == "";
    argocd-client-secret-reference =
      argocdSecret != null
      && argocdSecret.namespace == argocdRoute.namespace
      && argocdSecret.labels == { "app.kubernetes.io/part-of" = "argocd"; }
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
