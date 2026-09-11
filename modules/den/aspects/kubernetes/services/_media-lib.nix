{ lib }:
let
  retained = {
    "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false";
  };
in
rec {
  serviceName = kind: name: if name == kind then kind else "${kind}-${name}";
  retainedEntry =
    compute: key:
    assert lib.assertMsg (builtins.hasAttr key compute.retainedPaths)
      "Media state ${key} is not declared in compute.retainedPaths.";
    builtins.getAttr key compute.retainedPaths;
  fixedRoute =
    {
      cluster,
      name,
      app,
    }:
    assert lib.assertMsg (builtins.hasAttr name cluster.routes) "Media route ${name} is not declared.";
    let
      route = builtins.getAttr name cluster.routes;
    in
    assert lib.assertMsg (
      route.namespace == app.namespace && route.service == app.service && route.port == app.port
    ) "Media route ${name} must target ${app.namespace}/${app.service}:${toString app.port}.";
    route;

  routePrefix =
    route:
    if route == null || route.pathPrefix == "/" then "" else lib.removeSuffix "/" route.pathPrefix;

  secretRef = secretName: key: {
    valueFrom.secretKeyRef = {
      name = secretName;
      inherit key;
    };
  };
  mkStorage =
    compute: key: size:
    let
      entry = retainedEntry compute key;
      claim = "media-${key}";
    in
    assert lib.assertMsg (!entry.readOnly) "Media claim ${claim} must be writable.";
    [
      {
        apiVersion = "v1";
        kind = "PersistentVolume";
        metadata = {
          name = claim;
          annotations = retained;
        };
        spec = {
          capacity.storage = size;
          volumeMode = "Filesystem";
          accessModes = [ "ReadWriteOnce" ];
          persistentVolumeReclaimPolicy = "Retain";
          storageClassName = "";
          local.path = entry.guestPath;
          claimRef = {
            namespace = "media";
            name = claim;
          };
          nodeAffinity.required.nodeSelectorTerms = [
            {
              matchExpressions = [
                {
                  key = "kubernetes.io/hostname";
                  operator = "In";
                  values = [ compute.instance ];
                }
              ];
            }
          ];
        };
      }
      {
        apiVersion = "v1";
        kind = "PersistentVolumeClaim";
        metadata = {
          name = claim;
          namespace = "media";
          annotations = retained;
        };
        spec = {
          accessModes = [ "ReadWriteOnce" ];
          storageClassName = "";
          volumeName = claim;
          resources.requests.storage = size;
        };
      }
    ];
}
