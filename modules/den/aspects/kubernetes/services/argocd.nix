{ ... }:
{
  den.aspects.kubernetes.services.argocd = {
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
      };
    };
    k8s-manifests =
      {
        charts,
        ...
      }:
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
                cm."application.resourceTrackingMethod" = "annotation";
                cm."resource.customizations.health.argoproj.io_Application" = ''
                  hs = {}
                  hs.status = "Progressing"
                  hs.message = ""
                  if obj.status ~= nil then
                    if obj.status.health ~= nil then
                      hs.status = obj.status.health.status
                      if obj.status.health.message ~= nil then
                        hs.message = obj.status.health.message
                      end
                    end
                  end
                  return hs
                '';
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
