# In-cluster certificate issuance for the household edge. cert-manager is the
# sole writer of the TLS Secrets; the cluster owns their lifecycle because a
# rebuilt guest re-issues them anyway, so no certificate material crosses the
# host/guest boundary as a runtime Secret.
{ ... }:
{
  den.aspects.kubernetes.services.cert-manager.compute-resources.runtimeSecrets = {
    # Cloudflare DNS-edit token for the zone; the operator supplies it through
    # agenix edit under .secrets/hosts/<compute instance>/.
    "cert-manager--cloudflare-api-token--api-token" = {
      namespace = "cert-manager";
      name = "cloudflare-api-token";
      key = "api-token";
    };
  };
  den.aspects.kubernetes.services.cert-manager.k8s-manifests =
    { cluster, charts, ... }:
    let
      issuer = "letsencrypt-prod";
      version = "v1.21.1";
      image = repository: digest: {
        inherit repository digest;
        tag = version;
      };
      certificate = namespace: name: dnsNames: {
        apiVersion = "cert-manager.io/v1";
        kind = "Certificate";
        metadata = {
          inherit name namespace;
        };
        spec = {
          secretName = name;
          inherit dnsNames;
          issuerRef = {
            name = issuer;
            kind = "ClusterIssuer";
          };
        };
      };
    in
    {
      applications.cert-manager = {
        namespace = "cert-manager";
        annotations."argocd.argoproj.io/sync-wave" = "1";
        finalizer = "foreground";
        helm.releases.cert-manager = {
          chart = charts.jetstack.cert-manager;
          values = {
            crds.enabled = true;
            # The guest's resolvers see the LAN view of the zone; DNS-01 self
            # checks must consult the public resolvers that hold the TXT record.
            dns01RecursiveNameservers = "1.1.1.1:53,1.0.0.1:53";
            dns01RecursiveNameserversOnly = true;
            image = image "quay.io/jetstack/cert-manager-controller" "sha256:416a2d76870d996460e62bd7f521bf14fa017be9e3e904aab92163a331fcb61a";
            webhook.image = image "quay.io/jetstack/cert-manager-webhook" "sha256:d8b3961b51c8c7320633f8208dc46bf88aa13804d0f7cbe48a096b2c523cee42";
            cainjector.image = image "quay.io/jetstack/cert-manager-cainjector" "sha256:ccf6b919ec0500745a47a910118f834f9636d0aac1ff221245cd2557ed8c7c98";
            acmesolver.image = image "quay.io/jetstack/cert-manager-acmesolver" "sha256:dbc7cc1354f603918e7c5af7f55a0a620537394452c93a565bde75c6f48e8837";
            startupapicheck.image = image "quay.io/jetstack/cert-manager-startupapicheck" "sha256:d8ab6416e6e7303a86fa0a8daa82c94a8001f21c9d78eb2e7db20534e5d07ae8";
          };
        };
      };
      applications.cert-manager-issuance = {
        namespace = "cert-manager";
        annotations."argocd.argoproj.io/sync-wave" = "2";
        finalizer = "foreground";
        objects = [
          {
            apiVersion = "cert-manager.io/v1";
            kind = "ClusterIssuer";
            metadata.name = issuer;
            spec.acme = {
              server = "https://acme-v02.api.letsencrypt.org/directory";
              privateKeySecretRef.name = "letsencrypt-prod-account";
              solvers = [
                {
                  dns01.cloudflare.apiTokenSecretRef = {
                    name = "cloudflare-api-token";
                    key = "api-token";
                  };
                }
              ];
            };
          }
          (certificate "gateway" "gateway-tls" [
            "*.${cluster.domain}"
            "*.${cluster.backupDomain}"
          ])
          (certificate "identity" "kanidm-tls" cluster.routes.idm.hostnames)
        ];
      };
    };
}
