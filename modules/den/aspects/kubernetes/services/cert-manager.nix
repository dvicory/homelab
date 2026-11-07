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
    { cluster, lib, ... }:
    let
      issuer = "letsencrypt-prod";
      version = "v1.21.3";
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
          # The patch's ARI renewal fix needs the additive status.acme.ari.certID
          # schema as well as matching images; retain the cert-manager.io/v1 APIs.
          chart = lib.helm.downloadHelmChart {
            repo = "oci://quay.io/jetstack/charts";
            chart = "cert-manager";
            inherit version;
            chartHash = "sha256-kjGAYWkePhiNrUUdpesTcGa9jlpFk1/gZs8sztLElRw=";
          };
          values = {
            crds.enabled = true;
            # The guest's resolvers see the LAN view of the zone; DNS-01 self
            # checks must consult the public resolvers that hold the TXT record.
            dns01RecursiveNameservers = "1.1.1.1:53,1.0.0.1:53";
            dns01RecursiveNameserversOnly = true;
            image = image "quay.io/jetstack/cert-manager-controller" "sha256:9f4f96a33c7774cef24466fcd85031997531a03a8d117f151126baa8d1290dcc";
            webhook.image = image "quay.io/jetstack/cert-manager-webhook" "sha256:055ac8e9de6a0ba6763794838fe38944acc650f68ebe1b01dd8be079e580f458";
            cainjector.image = image "quay.io/jetstack/cert-manager-cainjector" "sha256:083d0e906f8eb44e255fe4ff817ae54e49f9ed82e22f1011bb4e9e4f4b8a641f";
            acmesolver.image = image "quay.io/jetstack/cert-manager-acmesolver" "sha256:c8c1225bb2fe8ab37a330b77f0d8c2ee6a41210fcb54fc07ca606ab9a022b8b7";
            # The startupapicheck renders as a plain Job under Argo (Helm
            # hooks are ignored); a failed Job is immutable and would wedge
            # every wave >= 2 application. The webhook Deployment's own health
            # already gates the issuance application.
            startupapicheck.enabled = false;
            startupapicheck.image = image "quay.io/jetstack/cert-manager-startupapicheck" "sha256:1c519d4afca1413d1e4ccd78bdc756184418ab55a34569a3b3de39d32f9974e1";
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
