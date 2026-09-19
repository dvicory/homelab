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
        cluster,
        lib,
        ...
      }:
      assert lib.assertMsg (
        cluster.routes.argocd.namespace == "argocd"
        && cluster.routes.argocd.service == "argocd-server"
        && cluster.routes.argocd.port == 80
        && !cluster.routes.argocd.backendTLS
        && cluster.routes.argocd.pathPrefix == "/"
      ) "Argo route must target the hostname-root HTTP Service argocd/argocd-server:80";
      {
        applications.argocd-retained = {
          namespace = "argocd";
          createNamespace = false;
          finalizer = "non-cascading";
          syncPolicy.autoSync = {
            enable = true;
            prune = false;
            selfHeal = true;
          };
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
          helm.releases.argocd = {
            chart = charts.argoproj.argo-cd;
            values = {
              nameOverride = "argocd";
              crds = {
                install = true;
                keep = true;
              };
              configs = {
                cm."application.resourceTrackingMethod" = "annotation";
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
