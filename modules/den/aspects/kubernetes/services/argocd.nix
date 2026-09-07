{ ... }:
{
  den.aspects.kubernetes.services.argocd = {
    k8s-manifests =
      { charts, ... }:
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
