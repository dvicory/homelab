{ lib, self, ... }:
let
  application = self.packages.x86_64-linux.jellyfin-kubernetes;
  manifests = application.passthru.manifests;
  resources = manifests.retained ++ manifests.workload;
  find = kind: name: lib.findFirst (r: r.kind == kind && r.metadata.name == name) null resources;
  pv = (find "PersistentVolume" "jellyfin-config").spec;
  pvc = find "PersistentVolumeClaim" "jellyfin-config";
  pod = (find "Deployment" "jellyfin").spec.template.spec;
  containers = pod.containers ++ pod.initContainers;
  mediaVolume = lib.findFirst (volume: volume.name == "media") null pod.volumes;
  assertions = {
    retained-explicit-binding =
      pv.persistentVolumeReclaimPolicy == "Retain"
      && pvc.spec.volumeName == "jellyfin-config"
      && pvc.spec.storageClassName == pv.storageClassName;
    retained-local-volume =
      let
        term = builtins.elemAt pv.nodeAffinity.required.nodeSelectorTerms 0;
        expression = builtins.elemAt term.matchExpressions 0;
      in
      pv.local.path == "/srv/jellyfin/config" && builtins.elem "compute-1" expression.values;
    nonroot-workload = builtins.all (
      container:
      container.securityContext.runAsNonRoot
      && container.securityContext.runAsUser > 0
      && container.securityContext.runAsGroup > 0
      && !container.securityContext.allowPrivilegeEscalation
      && builtins.elem "ALL" container.securityContext.capabilities.drop
      && (container.securityContext.capabilities.add or [ ]) == [ ]
    ) containers;
    readonly-media = builtins.all (
      container: (lib.findFirst (mount: mount.name == "media") null container.volumeMounts).readOnly
    ) containers;
    hostpath-media-propagation =
      mediaVolume.hostPath.path == "/srv/media"
      && mediaVolume.hostPath.type == "Directory"
      && builtins.all (
        container:
        (lib.findFirst (mount: mount.name == "media") null container.volumeMounts).mountPropagation
        == "HostToContainer"
      ) containers;
    offline-pinned-images = builtins.all (container: container.imagePullPolicy == "Never") containers;
    no-overlapping-writers = (find "Deployment" "jellyfin").spec.strategy.type == "Recreate";
  };
  failures = builtins.attrNames (lib.filterAttrs (_: passed: !passed) assertions);
in
{
  perSystem = { pkgs, ... }: {
    checks.jellyfin-contracts =
      assert lib.assertMsg (
        failures == [ ]
      ) "Jellyfin boundary failures: ${lib.concatStringsSep ", " failures}";
      pkgs.writeText "jellyfin-contracts" "ok\n";
  };
}
