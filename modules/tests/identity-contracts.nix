{
  config,
  inputs,
  lib,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    let
      oidcClients = config.flake.nixidyEnvs.${system}.prod-home.config.oidcClients;
      cluster = config.den.clusters.prod-home // {
        routes = config.flake.clusterRoutes.prod-home.routes;
      };
      compute =
        config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
      computeResources = config.flake.clusterResources.prod-home // {
        inherit (compute) instance retainedPaths;
      };
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
          routes = inventory.routes;
          config = { inherit oidcClients; };
          charts = { };
          inherit lib;
        };
      argocdConfigs =
        inventory: (renderArgocd inventory).applications.argocd.helm.releases.argocd.values.configs;
      renderIdentity =
        inventory:
        identity.k8s-manifests {
          cluster = inventory;
          routes = inventory.routes;
          config = { inherit oidcClients; };
          inherit computeResources lib;
        };
      gateway =
        (import ../den/aspects/kubernetes/services/gateway.nix { }).den.aspects.kubernetes.services.gateway;
      renderGateway =
        inventory:
        gateway.k8s-manifests {
          cluster = inventory;
          routes = inventory.routes;
          charts = { };
          inherit computeResources lib;
        };
      initial = renderIdentity (withPhase "initial");
      initialGateway = renderGateway (withPhase "initial");
      provisioningGateway = renderGateway (withPhase "provisioning");
      normalGateway = renderGateway (withPhase "normal");
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
      initialResources = identity.compute-resources { cluster = withPhase "initial"; };
      findObject =
        objects: kind: namespace: name:
        lib.findSingle (
          object:
          object.kind == kind
          && object.metadata.name == name
          && (object.metadata.namespace or "") == namespace
        ) null null objects;
      normalState = builtins.fromJSON (provisionData normalObjects)."state.json";
      provisionClients = objects: builtins.fromJSON (provisionData objects)."clients.json";
      normalClients = provisionClients normalObjects;
      # Argo CD side, rendered from the same cluster inventory.
      normalArgocd = argocdConfigs (withPhase "normal");
      normalOidc = builtins.fromJSON normalArgocd.cm."oidc.config";
      argocdRoute = cluster.routes.argocd;
      clientSecrets = clients: lib.concatMap (client: client.secrets) clients;
      sharedSecretObjects =
        key: labels:
        (config.flake.nixidyEnvs.${system}.prod-home.override (args: {
          modules = args.modules ++ [
            {
              applications.identity.objects = lib.mkForce (
                (identity.k8s-manifests {
                  cluster = withPhase "normal";
                  routes = cluster.routes // {
                    collision-peer = argocdRoute // {
                      hostnames = [ "collision-peer.test" ];
                    };
                  };
                  config.oidcClients = oidcClients // {
                    collision-peer = oidcClients.argocd // {
                      clientID = "collision-peer";
                      routeKey = "collision-peer";
                      secret = oidcClients.argocd.secret // {
                        inherit key labels;
                      };
                    };
                  };
                  inherit computeResources lib;
                }).applications.identity.objects
              );
            }
          ];
        })).config.applications.identity.objects;
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
      serverConfig = builtins.fromTOML (mountedServerConfig normalObjects).content;
      mountedServerConfig =
        objects:
        let
          pod = (findObject objects "Deployment" namespace "kanidm").spec.template.spec;
          container = lib.findFirst (container: container.name == "kanidm") null pod.containers;
          mount = lib.findFirst (mount: lib.elem mount.mountPath container.args) null container.volumeMounts;
          volume = lib.findFirst (volume: volume.name == mount.name) null pod.volumes;
          configMap = findObject objects "ConfigMap" namespace volume.configMap.name;
        in
        {
          inherit volume;
          inherit (configMap.metadata) name;
          immutable = configMap.immutable or false;
          content = configMap.data.${mount.subPath};
        };
      # NetworkPolicies are additive, regardless of name or application owner.
      admissionObjects =
        identityRendered: gatewayRendered:
        lib.concatMap
          (
            application:
            if application.condition or true then
              application.content.objects or (application.objects or [ ])
            else
              [ ]
          )
          (
            builtins.attrValues identityRendered.applications
            ++ builtins.attrValues gatewayRendered.applications
          );
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
          if expression.operator == "In" then
            listed
          else if expression.operator == "NotIn" then
            !listed
          else if expression.operator == "Exists" then
            present
          else if expression.operator == "DoesNotExist" then
            !present
          else
            throw "Unsupported Kubernetes selector operator"
        ) (selector.matchExpressions or [ ]);
      admitsPort =
        number: name: rule:
        let
          ports = rule.ports or [ ];
          admits =
            port:
            (port.protocol or "TCP") == "TCP"
            && (
              !(port ? port)
              || port.port == name
              || (builtins.isInt port.port && port.port <= number && number <= (port.endPort or port.port))
            );
        in
        ports == [ ] || lib.any admits ports;
      directoryPeers =
        objects:
        lib.unique (
          lib.concatMap
            (
              policy:
              lib.concatMap (
                rule:
                if admitsPort directory.port "ldaps" rule then
                  if rule.from or [ ] == [ ] then [ "anyone" ] else rule.from
                else
                  [ ]
              ) (policy.spec.ingress or [ ])
            )
            (
              lib.filter (
                object:
                object.kind == "NetworkPolicy"
                && object.metadata.namespace == namespace
                && selectsKanidm object.spec.podSelector
                && lib.elem "Ingress" (object.spec.policyTypes or [ "Ingress" ])
              ) objects
            )
        );
      allowsArgocdServer = lib.any (
        rule:
        admitsPort 8443 "https" rule
        && lib.any (
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
          binding =
            findObject objects "RoleBinding" declared.namespace
              "kanidm-client-secret-${declared.name}";
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
        # Change server configuration without changing its image, ports or storage.
        server-config-rollout =
          lib.all
            (
              phase:
              let
                inventory = withPhase phase;
                baseline = renderIdentity inventory;
                changed = renderIdentity (
                  lib.recursiveUpdate inventory {
                    routes.idm = {
                      hostnames = [ "config-rollout.example.test" ];
                      backendHostname = "config-rollout.example.test";
                    };
                  }
                );
                unchanged = renderIdentity (
                  lib.recursiveUpdate inventory {
                    routes.idm.displayName = "Same server configuration";
                  }
                );
                baselineObjects = baseline.applications.identity.objects;
                changedObjects = changed.applications.identity.objects;
                unchangedObjects = unchanged.applications.identity.objects;
                deploymentFor = objects: findObject objects "Deployment" namespace "kanidm";
                baselineSpec = (deploymentFor baselineObjects).spec;
                changedSpec = (deploymentFor changedObjects).spec;
                baselineConfig = mountedServerConfig baselineObjects;
                changedConfig = mountedServerConfig changedObjects;
                unchangedConfig = mountedServerConfig unchangedObjects;
              in
              baselineConfig.content != changedConfig.content
              && baselineConfig.name != changedConfig.name
              && baselineConfig.immutable
              && changedConfig.immutable
              && !(baselineConfig.volume.configMap.optional or false)
              && !(changedConfig.volume.configMap.optional or false)
              && findObject baselineObjects "ConfigMap" namespace changedConfig.name == null
              && baselineSpec.template != changedSpec.template
              &&
                baselineSpec.template == lib.recursiveUpdate changedSpec.template {
                  spec.volumes = map (
                    volume:
                    if volume.name == changedConfig.volume.name then
                      lib.recursiveUpdate volume { configMap.name = baselineConfig.name; }
                    else
                      volume
                  ) changedSpec.template.spec.volumes;
                }
              &&
                builtins.removeAttrs baselineSpec [ "template" ] == builtins.removeAttrs changedSpec [ "template" ]
              && baselineSpec.replicas == 1
              && baselineSpec.strategy.type == "Recreate"
              && baseline.applications.identity-retained == changed.applications.identity-retained
              && baselineConfig == unchangedConfig
              && baselineSpec.template == (deploymentFor unchangedObjects).spec.template
            )
            [
              "initial"
              "provisioning"
              "normal"
            ];
        server-local-backup-disabled =
          lib.all
            (
              rendered:
              !(
                (builtins.fromTOML (mountedServerConfig rendered.applications.identity.objects).content)
                ? online_backup
              )
            )
            [
              initial
              provisioning
              normal
            ];
        # Kanidm serves LDAPS on the declared directory port, on its Service.
        directory-listens =
          serverConfig.ldapbindaddress == "0.0.0.0:${toString directory.port}"
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
        directory-admits-only-jellyfin =
          lib.all
            (
              objects:
              directoryPeers objects == [
                {
                  namespaceSelector.matchLabels."kubernetes.io/metadata.name" = jellyfinRoute.namespace;
                  podSelector.matchLabels = jellyfinRoute.backendPodSelector;
                }
              ]
            )
            [
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
        initial-credential-absent =
          !(initialResources.runtimeSecrets ? "identity--kanidm-provision--idm-admin-password");
        # Every Kanidm client in the provisioning state has a publication entry,
        # and every entry's Secret, Role and RoleBinding are declared without
        # `create` rights in both activated phases.
        client-secrets-declared-without-create =
          lib.sort builtins.lessThan (map (client: client.name) normalClients)
          == builtins.attrNames normalState.systems.oauth2
          && lib.all (publicationIntact normalObjects) (clientSecrets normalClients);
        client-secret-destinations-distinct =
          publicationIntact (sharedSecretObjects "other-client-secret" { }) (
            oidcClients.argocd.secret // { namespace = argocdRoute.namespace; }
          )
          && !(builtins.tryEval (
            builtins.deepSeq (sharedSecretObjects oidcClients.argocd.secret.key { }) true
          )).success;
        client-secret-labels-consistent =
          !(builtins.tryEval (
            builtins.deepSeq (sharedSecretObjects "other-client-secret" {
              "app.kubernetes.io/part-of" = "collision-peer";
            }) true
          )).success;
        administrator-eligibility-restricted =
          !(builtins.tryEval (
            builtins.deepSeq (provisionClients
              (identity.k8s-manifests {
                cluster = withPhase "normal";
                inherit (cluster) routes;
                config.oidcClients = lib.recursiveUpdate oidcClients {
                  radarr.eligibleGroup = householdGroup;
                };
                inherit computeResources lib;
              }).applications.identity.objects
            ) true
          )).success;
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
        # Only the declared administrator group receives an Argo CD role.
        argocd-admin-group-restricted =
          normalArgocd.rbac.scopes == "[groups]"
          && normalArgocd.rbac."policy.csv" == "g, ${adminGroup}, role:admin\n"
          && normalArgocd.rbac."policy.default" == "";
        argocd-pkce-required =
          normalOidc.enablePKCEAuthentication
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
      checks.identity-contracts =
        assert lib.assertMsg (failures == { })
          "Identity contract checks failed: ${builtins.concatStringsSep ", " (builtins.attrNames failures)}";
        pkgs.writeText "identity-contracts" "ok\n";
    };
}
