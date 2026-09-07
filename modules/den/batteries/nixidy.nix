{ den, ... }:
{
  den.classes.k8s-manifests.description = "Kubernetes manifests collected for Nixidy";

# Nixidy's environment config is exposed by the cluster instantiate policy as
# `flake.nixidyEnvs.<system>.<cluster>`. Keep all artifact derivations on the
# upstream config.build boundary (`environmentPackage`, `bootstrapPackage`,
# `activationPackage`, and `declarativePackage`).
}
