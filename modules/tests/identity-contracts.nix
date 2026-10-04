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
  provisioning = renderIdentity (withPhase "provisioning");
  normal = renderIdentity (withPhase "normal");
  provisioningObjects = provisioning.applications.identity.objects;
  normalObjects = normal.applications.identity.objects;
  applicationObjects =
    application: if application ? content then application.content.objects else application.objects;
  normalPolicyObjects = applicationObjects normal.applications.identity-gateway;
  provisionData =
    objects:
    (builtins.head (
      lib.filter (
        object: object.kind == "ConfigMap" && object.metadata.name == "kanidm-provision"
      ) objects
    )).data;
  normalProvisionJob = builtins.head (
    lib.filter (
      object: object.kind == "Job" && object.metadata.name == "kanidm-provision"
    ) normalObjects
  );
  provisionContainer = builtins.head normalProvisionJob.spec.template.spec.containers;
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
    initial-credential-absent =
      !(initialResources.runtimeSecrets ? "identity--kanidm-provision--idm-admin-password");
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
      && builtins.attrNames normalState.groups == [ (envValue "KANIDM_ADMIN_GROUP") ]
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
