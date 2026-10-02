{ pkgs, linuxPkgs, lib, config, inputs, self }:
let
  configurations = import ../../_compute-configurations.nix {
    inherit self lib;
    system = linuxPkgs.stdenv.hostPlatform.system;
    hostName = config.den.clusters.prod-home.hostName;
  };
  guest = configurations.guest.config;
  instance = (builtins.fromJSON configurations.hostConfig.environment.etc."homelab/compute.json".text).instance;
  service = guest.systemd.services.kubernetes-runtime-secrets;
  deployedSystem = self.nixosConfigurations.${instance}.config.nixpkgs.hostPlatform.system;
  # Preserve every absolute path and Nix reference in the evaluated production
  # script. dockerTools includes its complete reference closure, including K3s.
  reconcile = linuxPkgs.writeShellScriptBin "native-runtime-secret-reconcile" ''
    export PATH=${lib.makeBinPath service.path}
    ${service.script}
  '';
  image = linuxPkgs.dockerTools.buildLayeredImage {
    name = "homelab/native-runtime-secret";
    tag = "1";
    contents = [ reconcile linuxPkgs.coreutils ];
    config.Cmd = [ "${linuxPkgs.coreutils}/bin/sleep" "infinity" ];
  };
  imageReference = "${image.imageName}:${image.imageTag}";
  readabilityImage = linuxPkgs.dockerTools.buildImage {
    name = "homelab/native-secret-readability";
    tag = "1";
    copyToRoot = linuxPkgs.buildEnv {
      name = "native-secret-readability-root";
      paths = [ linuxPkgs.busybox ];
      pathsToLink = [ "/bin" ];
    };
    config.Cmd = [ "/bin/sh" ];
  };
  helper = pkgs.writeText "native-runtime-secret-commands.sh" (builtins.readFile ./commands.sh);
  setup = pkgs.writeShellScript "native-runtime-secret-setup" ''
    set -euo pipefail
    source ${helper}
    secret_exec ${linuxPkgs.coreutils}/bin/mkdir -p /run/kubernetes-runtime-secrets /srv /var/lib/homelab-runtime-secrets /etc/rancher/k3s
    secret_exec ${linuxPkgs.coreutils}/bin/chmod 0700 /run/kubernetes-runtime-secrets /var/lib/homelab-runtime-secrets
    secret_exec ${linuxPkgs.coreutils}/bin/ln -s /run/kubernetes-runtime-secrets /srv/secrets
    kubeconfig="$FIXTURE_WORK/secret-kubeconfig.json"
    "$KUBECTL" config view --raw --flatten -o json |
      jq --arg server "https://$FIXTURE_NODE_IP:6443" '
        .clusters[].cluster.server = $server |
        .clusters[].cluster["tls-server-name"] = "127.0.0.1" |
        .contexts[].name = "default" | .["current-context"] = "default"
      ' > "$kubeconfig"
    chmod 0600 "$kubeconfig"
    secret_docker cp "$kubeconfig" "$FIXTURE_SECRET:/etc/rancher/k3s/k3s.yaml"
    secret_exec ${linuxPkgs.coreutils}/bin/chmod 0600 /etc/rancher/k3s/k3s.yaml
    secret_exec ${guest.services.k3s.package}/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml --context default --request-timeout=10s get --raw=/readyz >/dev/null
    secret_exec ${guest.services.k3s.package}/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml --context default --request-timeout=10s version -o json |
      jq -e '.clientVersion.gitVersion == .serverVersion.gitVersion' >/dev/null
  '';
in
{
  settings = {
    inherit helper deployedSystem;
    reconcile = lib.getExe reconcile;
    system = linuxPkgs.stdenv.hostPlatform.system;
    nativePlatformOverride = linuxPkgs.stdenv.hostPlatform.system != deployedSystem;
    provenance = "nixosConfigurations.${instance}.config.systemd.services.kubernetes-runtime-secrets.script";
    scriptSha256 = builtins.hashString "sha256" service.script;
    coreutils = "${linuxPkgs.coreutils}/bin";
    readabilityImage = "${readabilityImage.imageName}:${readabilityImage.imageTag}";
    paths = [ pkgs.coreutils pkgs.diffutils pkgs.bash ];
  };
  images = [ image readabilityImage ];
  kubernetesImages = [ "${readabilityImage.imageName}:${readabilityImage.imageTag}" ];
  inherit setup;
  containers = [{
    suffix = "secret";
    image = imageReference;
    command = [ "${linuxPkgs.coreutils}/bin/sleep" "infinity" ];
  }];
  scenarios = [
    "runtime-secret-initial-exact-ack"
    "runtime-secret-missing-desired-inventory"
    "runtime-secret-stale-desired-inventory"
    "runtime-secret-malformed-desired-inventory"
    "runtime-secret-malformed-owned-inventory"
    "runtime-secret-duplicate-owned-inventory"
    "runtime-secret-failed-uid-recording-keeps-ack"
    "runtime-secret-ssa-uid"
    "runtime-secret-empty-generation-relinquishes-only-owned-fields"
    "runtime-secret-matching-uid-shared-owner-tls-retirement"
    "runtime-secret-matching-uid-sole-owner-tls-retirement"
    "runtime-secret-projected-mode-zero-unreadable"
    "runtime-secret-fsgroup-readable"
  ];
}
