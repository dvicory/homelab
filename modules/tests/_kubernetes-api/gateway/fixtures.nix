{ pkgs, linuxPkgs, lib, config, inputs, self }:
let
  cluster = config.den.clusters.prod-home;
  instance = "compute-1";
  gateway = (import ../../../den/aspects/kubernetes/services/gateway.nix { }).den.aspects.kubernetes.services.gateway;
  identity = (import ../../../den/aspects/kubernetes/services/identity.nix { inherit config inputs lib; }).den.aspects.kubernetes.services.identity;
  fixtureCluster = cluster // {
    routes = lib.getAttrs [ "argocd" "idm" ] cluster.routes // {
      # Keep the synthetic browser origin out of the real Argo controller's
      # Service/endpoints in the shared fixture.
      argocd = cluster.routes.argocd // { namespace = "gateway-admin-origin"; };
      origin = {
        namespace = "origin"; service = "origin"; port = 8080;
        auth = "native"; exposure = "public"; backendPodSelector.app = "origin";
        hostnames = [ "origin.test" ]; pathPrefix = "/";
        backendTLS = false; backendHostname = null; timeouts = null;
      };
    };
    ingress = cluster.ingress // { mode = "direct"; trustedProxyCIDRs = [ ]; };
  };
  trustedCluster = lib.recursiveUpdate fixtureCluster {
    ingress = { mode = "trustedEdges"; trustedProxyCIDRs = [ "192.0.2.11/32" ]; };
  };
  normalCluster = lib.recursiveUpdate trustedCluster { settings.kubernetes.services.identity.phase = "normal"; };
  renderGateway = inventory: gateway.k8s-manifests {
    cluster = inventory;
    computeResources = config.flake.clusterResources.prod-home // { inherit instance; };
    charts = { }; inherit lib;
  };
  entranceObjects = inventory: map (object:
    if object.kind == "EnvoyProxy" then lib.recursiveUpdate object {
      spec.provider.kubernetes.envoyDeployment = {
        pod.volumes = [ { name = "fixture-ca"; configMap.name = "fixture-ca"; } ];
        container.volumeMounts = [ {
          name = "fixture-ca"; mountPath = "/etc/ssl/certs/ca-certificates.crt";
          subPath = "ca-certificates.crt"; readOnly = true;
        } ];
      };
    } else object) (renderGateway inventory).applications.gateway.objects;
  renderIdentity = phase: identity.k8s-manifests {
    cluster = lib.recursiveUpdate fixtureCluster { settings.kubernetes.services.identity.phase = phase; };
    computeResources = config.flake.clusterResources.prod-home // { inherit instance; };
    inherit lib;
  };
  identityDataPath = "/var/lib/native-gateway/kanidm";
  identityRetained = (renderIdentity "initial").applications.identity-retained.resources;
  identityPV = identityRetained.persistentVolumes.identity-kanidm;
  identityPVC = identityRetained.persistentVolumeClaims.identity-kanidm;
  identityObjects = [
    (identityPV // {
      apiVersion = "v1"; kind = "PersistentVolume";
      metadata = identityPV.metadata // { name = "native-gateway-kanidm"; };
      spec = identityPV.spec // {
        local.path = identityDataPath;
        claimRef = identityPV.spec.claimRef // { name = "native-gateway-kanidm"; };
      };
    })
    (identityPVC // {
      apiVersion = "v1"; kind = "PersistentVolumeClaim";
      metadata = identityPVC.metadata // { name = "native-gateway-kanidm"; namespace = "identity"; };
      spec = identityPVC.spec // { volumeName = "native-gateway-kanidm"; };
    })
  ] ++ map (object:
    if object.kind == "Deployment" then lib.recursiveUpdate object {
      spec.template.spec = {
        securityContext.fsGroup = 1000;
        volumes = map (volume: if volume.name == "data" then {
          name = "data"; persistentVolumeClaim.claimName = "native-gateway-kanidm";
        } else volume) object.spec.template.spec.volumes;
      };
    } else object) (renderIdentity "initial").applications.identity.objects;
  provisionObjects = map (object:
    if object.kind == "Job" then lib.recursiveUpdate object {
      spec.template.spec = {
        containers = map (container: container // {
          env = container.env ++ [ { name = "SSL_CERT_FILE"; value = "/fixture-ca/ca.crt"; } ];
          volumeMounts = container.volumeMounts ++ [ { name = "fixture-ca"; mountPath = "/fixture-ca"; readOnly = true; } ];
        }) object.spec.template.spec.containers;
        volumes = object.spec.template.spec.volumes ++ [ { name = "fixture-ca"; configMap.name = "fixture-ca"; } ];
      };
    } else object) (lib.filter (object: object.metadata.name == "kanidm-provision"
      || lib.hasPrefix "kanidm-client-secret-" object.metadata.name || object.kind == "Secret")
      (renderIdentity "normal").applications.identity.objects);
  provisionConfig = builtins.head (lib.filter (object: object.kind == "ConfigMap") provisionObjects);
  administrator = builtins.head (builtins.fromJSON provisionConfig.data."members.json");
  applicationObjects = application: if application ? content then application.content.objects else application.objects;
  list = name: objects: pkgs.writeText "${name}.json" (builtins.toJSON { apiVersion = "v1"; kind = "List"; items = objects; });
  originImage = linuxPkgs.dockerTools.buildImage {
    name = "homelab/native-gateway-origin"; tag = "1";
    copyToRoot = linuxPkgs.buildEnv {
      name = "native-gateway-origin-root";
      paths = [ linuxPkgs.busybox (linuxPkgs.runCommand "native-gateway-origin-www" { } ''
        mkdir -p "$out/www"
        for probe in index.html direct-probe trusted-probe blocked-probe; do
          echo origin > "$out/www/$probe"
        done
      '') ];
    };
    config.Cmd = [ "httpd" "-f" "-p" "8080" "-h" "/www" ];
  };
  originRef = "${originImage.imageName}:${originImage.imageTag}";
  originDeployment = namespace: labels: {
    apiVersion = "apps/v1"; kind = "Deployment"; metadata = { name = "origin"; inherit namespace; };
    spec = {
      selector.matchLabels = labels;
      template = { metadata.labels = labels; spec.containers = [ {
        name = "origin"; image = originRef; imagePullPolicy = "Never"; ports = [ { containerPort = 8080; } ];
      } ]; };
    };
  };
  originService = namespace: name: port: labels: {
    apiVersion = "v1"; kind = "Service"; metadata = { inherit name namespace; };
    spec = { selector = labels; ports = [ { inherit port; targetPort = 8080; } ]; };
  };
  browserPython = linuxPkgs.python3.withPackages (ps: [ ps.playwright ]);
  toolsImage = linuxPkgs.dockerTools.buildImage {
    name = "homelab/native-gateway-client"; tag = "1";
    copyToRoot = linuxPkgs.buildEnv {
      name = "native-gateway-client-root";
      paths = [ linuxPkgs.busybox linuxPkgs.curl linuxPkgs.jq linuxPkgs.openssl
        linuxPkgs.coreutils linuxPkgs.socat linuxPkgs.nssTools linuxPkgs.chromium browserPython linuxPkgs.cacert linuxPkgs.dejavu_fonts ];
      pathsToLink = [ "/bin" "/etc" "/share/fonts" ];
      ignoreCollisions = true;
    };
    extraCommands = ''
      mkdir -p tmp root usr/share
      chmod 1777 tmp
      chmod 0700 root
      ln -s /share/fonts usr/share/fonts
    '';
    config = { Cmd = [ "/bin/sh" "-c" "sleep infinity" ]; Env = [ "HOME=/root" "PATH=/bin" ]; };
  };
  provisionImage = self.packages.x86_64-linux.kanidm-provision-image;
  helper = pkgs.writeShellScriptBin "gateway-case" (builtins.readFile ./case.sh);
  manifests = ../../../.. + "/generated/manifests/prod-home";
in {
  images = [ originImage toolsImage provisionImage ];
  kubernetesImages = [ originRef "${provisionImage.imageName}:${provisionImage.imageTag}" ];
  settings = {
    inherit administrator;
    inherit identityDataPath;
    nodePort = cluster.ingress.nodePort;
    idmHost = builtins.head cluster.routes.idm.hostnames;
    adminHost = builtins.head cluster.routes.argocd.hostnames;
    hostnames = cluster.routes.idm.hostnames ++ cluster.routes.argocd.hostnames;
    toolsImage = "${toolsImage.imageName}:${toolsImage.imageTag}";
    registryImages = [
      (renderGateway fixtureCluster).applications.gateway-controller.helm.releases.envoy-gateway.values.global.images.envoyGateway.image
      (builtins.head (lib.filter (object: object.kind == "EnvoyProxy") (entranceObjects fixtureCluster))).spec.provider.kubernetes.envoyDeployment.container.image
      (builtins.head (builtins.head (lib.filter (object: object.kind == "Deployment") identityObjects)).spec.template.spec.containers).image
    ];
    paths = [ helper pkgs.coreutils ];
    retained = "${manifests}/gateway-retained";
    crds = "${manifests}/gateway-crds";
    controller = "${manifests}/gateway-controller";
    direct = toString (list "native-gateway-direct" (entranceObjects fixtureCluster));
    trusted = toString (list "native-gateway-trusted" (entranceObjects trustedCluster));
    identity = toString (list "native-gateway-identity" identityObjects);
    provision = toString (list "native-gateway-provision" provisionObjects);
    adminRoutes = toString (list "native-gateway-admin-routes" (applicationObjects (renderGateway normalCluster).applications.identity-gateway));
    adminPolicies = toString (list "native-gateway-admin-policies" (applicationObjects (renderIdentity "normal").applications.identity-gateway));
    identityDNS = toString (list "native-gateway-identity-dns" [ {
      apiVersion = "v1"; kind = "ConfigMap"; metadata = { name = "coredns-custom"; namespace = "kube-system"; };
      data = (renderIdentity "normal").applications.cluster-dns.resources.configMaps.coredns-custom.data;
    } ]);
    origins = toString (list "native-gateway-origins" [
      { apiVersion = "v1"; kind = "Namespace"; metadata.name = "origin"; }
      { apiVersion = "v1"; kind = "Namespace"; metadata.name = "identity"; }
      { apiVersion = "v1"; kind = "Namespace"; metadata.name = fixtureCluster.routes.argocd.namespace; }
      (originDeployment "origin" { app = "origin"; })
      (originService "origin" "origin" 8080 { app = "origin"; })
      (originDeployment fixtureCluster.routes.argocd.namespace fixtureCluster.routes.argocd.backendPodSelector)
      (originService fixtureCluster.routes.argocd.namespace fixtureCluster.routes.argocd.service fixtureCluster.routes.argocd.port fixtureCluster.routes.argocd.backendPodSelector)
    ]);
    # Interpolation copies the driver into the store and records the
    # dependency; a bare toString path need not exist at run time.
    authorization = "${../../_gateway-runtime/authorization.py}";
    python = "${browserPython}/bin/python3";
    chromium = "${linuxPkgs.chromium}/bin/chromium";
  };
  setup = pkgs.writeShellScript "native-gateway-setup" (builtins.readFile ./setup.sh);
  scenarios = [
    "gateway-current-generation-status"
    "gateway-direct-source-spoofing"
    "gateway-trusted-cni-source-boundary"
    "gateway-referencegrant-deny-restore"
    "gateway-backend-name-deny-restore"
    "gateway-backend-ca-deny-restore"
    "gateway-real-webauthn-authorization"
    "gateway-access-error-log-privacy"
  ];
  testDirectories = [
    ./01-status ./02-direct ./03-cni ./04-grant
    ./05-name ./06-ca ./07-browser ./08-privacy
  ];
}
