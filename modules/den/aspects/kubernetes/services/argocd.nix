{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  den.aspects.kubernetes.services.argocd = {
    settings.oidc = mkOption {
      type = types.submodule {
        options = {
          # Kanidm refuses an authorization request unless every requested
          # scope is in a scope map of a group the user belongs to.
          # `groups_name` makes Kanidm 1.11 emit the `groups` claim as short
          # group names (`homelab-admin`), not SPNs or UUIDs.
          scopes = mkOption {
            type = types.listOf types.str;
            default = [
              "openid"
              "profile"
              "email"
              "groups_name"
            ];
            description = "Scopes Argo CD requests; identity provisioning maps each one to the administrator group.";
          };
          secretName = mkOption {
            type = types.str;
            default = "argocd-kanidm-oidc";
            description = "Secret in Argo CD's namespace where identity provisioning publishes the client secret.";
          };
          secretKey = mkOption {
            type = types.str;
            default = "clientSecret";
            description = "Key of the client secret in that Secret.";
          };
        };
      };
      default = { };
      description = "Argo CD's sign-in through Kanidm. Identity provisioning adds these values to the Kanidm client of the `argocd` route, which the Gateway also uses.";
    };
    compute-resources.runtimeSecrets = {
      "argocd--argocd-secret--admin.password" = {
        namespace = "argocd";
        name = "argocd-secret";
        key = "admin.password";
      };
      "argocd--argocd-secret--admin.passwordMtime" = {
        namespace = "argocd";
        name = "argocd-secret";
        key = "admin.passwordMtime";
      };
      "argocd--argocd-secret--server.secretkey" = {
        namespace = "argocd";
        name = "argocd-secret";
        key = "server.secretkey";
        generator = "alnum-no-newline";
      };
    };
    k8s-manifests =
      {
        cluster,
        charts,
        lib,
        ...
      }:
      let
        identity = cluster.settings.kubernetes.services.identity;
        oidc = cluster.settings.kubernetes.services.argocd.oidc;
        identityNormal = identity.phase == "normal";
        idmHostname = builtins.head cluster.routes.idm.hostnames;
        urls = map (hostname: "https://${hostname}") cluster.routes.argocd.hostnames;
        # Identity names each administrator route's Kanidm client after the
        # route, so Argo CD and its Gateway sign-in share one client.
        clientName = "argocd";
        # Argo CD parses oidc.config as YAML; JSON is valid YAML.
        # Kanidm 1.11 requires PKCE; Argo CD 3.5 performs it server-side
        # and still authenticates with the client secret.
        oidcConfig = {
          name = "Kanidm";
          issuer = "https://${idmHostname}/oauth2/openid/${clientName}";
          clientID = clientName;
          clientSecret = "$" + oidc.secretName + ":" + oidc.secretKey;
          requestedScopes = oidc.scopes;
          enablePKCEAuthentication = true;
        };
      in
      {
        applications.argocd-retained = {
          namespace = "argocd";
          annotations."argocd.argoproj.io/sync-wave" = "-3";
          createNamespace = false;
          retained = true;
          objects = [
            {
              apiVersion = "v1";
              kind = "Namespace";
              metadata = {
                name = "argocd";
                annotations."argocd.argoproj.io/sync-options" = "Prune=false,Delete=false";
              };
            }
          ];
        };

        applications.argocd = {
          namespace = "argocd";
          createNamespace = false;
          annotations."argocd.argoproj.io/sync-wave" = "-2";
          helm.releases.argocd = {
            chart = charts.argoproj.argo-cd;
            values = {
              global.image.tag = "v3.5.2@sha256:e2aadfae709d904e87f46ba4aa49601d827b3022db22cd4d03aae816a2e7097b";
              redis.image.tag = "8.6.4-alpine@sha256:2cc044fc5a07c9b701f8f1255a309ae9ad7856e694ac03513bf3648c01e40763";
              nameOverride = "argocd";
              global.networkPolicy.create = false;
              controller.networkPolicy.create = true;
              redis.networkPolicy.create = true;
              repoServer.networkPolicy.create = true;
              crds = {
                install = true;
                keep = true;
              };
              configs = {
                cm = {
                  "application.resourceTrackingMethod" = "annotation";
                  "resource.customizations.health.argoproj.io_Application" = ''
                    hs = {}
                    hs.status = "Progressing"
                    hs.message = ""
                    if obj.status ~= nil then
                      for _, condition in ipairs(obj.status.conditions or {}) do
                        if condition.type == "ComparisonError" then
                          return {status = "Degraded", message = "Application source comparison failed"}
                        end
                      end
                      if obj.status.health ~= nil then
                        hs.status = obj.status.health.status
                        if obj.status.health.message ~= nil then
                          hs.message = obj.status.health.message
                        end
                      end
                    end
                    return hs
                  '';
                  # Argo CD picks the sign-in callback that matches the
                  # request's hostname from url and additionalUrls.
                  url = builtins.head urls;
                  additionalUrls = builtins.toJSON (builtins.tail urls);
                  # The local `admin` account exists only until Kanidm
                  # sign-in does. It cannot serve as break-glass: it sits
                  # behind the Gateway's Kanidm gate, so it is unreachable
                  # whenever Kanidm is down. Recovery uses kubectl on the
                  # host instead (docs/operations/identity.md).
                  "admin.enabled" = !identityNormal;
                }
                // lib.optionalAttrs identityNormal {
                  "oidc.config" = builtins.toJSON oidcConfig;
                };
                # Deny by default. Only the Kanidm administrator group, as
                # emitted in the `groups` claim, receives Argo CD's admin role.
                rbac = {
                  "policy.default" = "";
                  "policy.csv" = lib.optionalString identityNormal "g, ${identity.adminGroup}, role:admin\n";
                  scopes = "[groups]";
                };
                # Credentials are provisioned at runtime from host-staged files;
                # never generate or embed administrator values during evaluation.
                secret.createSecret = false;
                params."server.insecure" = true;
              };
              server = {
                replicas = 1;
                insecure = true;
                service.type = "ClusterIP";
                service.servicePortHttp = 80;
                networkPolicy.create = false;
              };
              dex.enabled = false;
              notifications.enabled = false;
              applicationSet.replicas = 1;
              redis-ha.enabled = false;
            };
          };
        };
      };
  };
}
