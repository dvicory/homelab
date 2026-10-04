{ pkgs, linuxPkgs, lib, config, inputs, self }:
let
  directories = self.packages.x86_64-linux.retained-directories-image;
  probe = linuxPkgs.dockerTools.buildImage {
    name = "homelab/native-argo-probe";
    tag = "1";
    copyToRoot = linuxPkgs.buildEnv {
      name = "native-argo-probe-root";
      paths = [ linuxPkgs.busybox ];
      pathsToLink = [ "/bin" ];
    };
    config.Cmd = [ "/bin/sh" ];
  };
  git = linuxPkgs.dockerTools.buildImage {
    name = "homelab/native-argo-git";
    tag = "1";
    copyToRoot = linuxPkgs.buildEnv {
      name = "native-argo-git-root";
      paths = [ linuxPkgs.git linuxPkgs.busybox ];
      pathsToLink = [ "/bin" ];
    };
    extraCommands = ''
      mkdir -p srv/git tmp
      chmod 1777 tmp
    '';
    config.Cmd = [ "/bin/git" "daemon" "--reuseaddr" "--export-all" "--base-path=/srv/git" "--listen=0.0.0.0" "/srv/git" ];
  };
  probeRef = "${probe.imageName}:${probe.imageTag}";
  gitRef = "${git.imageName}:${git.imageTag}";
  action = pkgs.writeShellScript "native-argo-action" ''
    export PATH=${lib.makeBinPath [ pkgs.yq-go pkgs.coreutils ]}:"$PATH"
    exec ${pkgs.bash}/bin/bash ${./action.sh} "$@"
  '';
in
{
  settings = {
    bootstrap = self.packages.${pkgs.stdenv.hostPlatform.system}.household-bootstrap-manifests;
    manifests = ../../../../generated/manifests/prod-home;
    crdReadiness = ./crd-established.yaml;
    captureRetained = pkgs.writeShellScript "native-argo-retained-witness" ''
      exec ${pkgs.python3}/bin/python3 ${../report.py} --capture-retained
    '';
    probeImage = probeRef;
    directoriesImage = directories.imageReference;
    registryManifestDirectories = [ self.packages.${pkgs.stdenv.hostPlatform.system}.household-bootstrap-manifests ];
    inherit action;
    paths = [ pkgs.yq-go pkgs.coreutils ];
  };
  images = [ probe directories git ];
  kubernetesImages = [ probeRef directories.imageReference ];
  containers = [ {
    suffix = "argo-git";
    image = gitRef;
    ip = 30;
    command = [ "/bin/git" "daemon" "--reuseaddr" "--export-all" "--base-path=/srv/git" "--listen=0.0.0.0" "/srv/git" ];
  } ];
  setup = pkgs.writeShellScript "native-argo-setup" ''
    exec ${action} setup
  '';
  testDirectories = [
    ./01-child-gating
    ./02-retained-hook
    ./03-self-heal
    ./04-git-omission
    ./05-direct-retirement
    ./06-root-child-retirement
  ];
  scenarios = [
    "argo-01-child-gating-recovery"
    "argo-02-retained-hook-sequencing"
    "argo-03-workload-self-heal"
    "argo-04-git-omission"
    "argo-05-direct-retirement"
    "argo-06-root-child-retirement"
  ];
}
