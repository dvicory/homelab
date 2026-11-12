{ den, ... }:
{
  den.classes.k8s-manifests.description = "Kubernetes manifests collected for Nixidy";
  den.classes.compute-resources.description = "Host resource requirements of selected cluster services";
  den.classes.route-metadata.description = "Service backend metadata merged with site route policy";

  # Nixidy's environment config is exposed by the cluster instantiate policy as
  # `flake.nixidyEnvs.<system>.<cluster>`. Keep all artifact derivations on the
  # upstream config.build boundary (`environmentPackage`, `bootstrapPackage`,
  # `activationPackage`, and `declarativePackage`).
}
