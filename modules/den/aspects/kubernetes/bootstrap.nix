{ self, lib, ... }:
{
  perSystem = { pkgs, system, ... }:
    let
      environment = self.nixidyEnvs.${system}.prod-home.environmentPackage;
      manifests = pkgs.runCommand "household-static-bootstrap" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
        mkdir -p "$out"
        yq 'select(.kind == "Namespace")' ${environment}/*/*.yaml > "$out/namespaces.yaml"
        yq 'select(.kind == "CustomResourceDefinition")' ${environment}/*/*.yaml > "$out/crds.yaml"
        yq 'select(.kind != "Namespace" and .kind != "CustomResourceDefinition" and .kind != "Application")' ${environment}/*/*.yaml > "$out/workloads.yaml"
      '';
    in
    {
      packages.household-bootstrap-manifests = manifests;
      packages.household-bootstrap = pkgs.writeShellApplication {
        name = "household-bootstrap";
        runtimeInputs = [ pkgs.kubectl pkgs.coreutils ];
        text = ''
          if [ "$#" -ne 1 ] || [ "$1" != "--fresh-cluster" ]; then
            echo 'Usage: household-bootstrap --fresh-cluster (uses KUBECONFIG; no pruning or Git access)' >&2
            exit 2
          fi
          crd=$(kubectl get crd applications.argoproj.io --ignore-not-found -o name)
          if [ -n "$crd" ]; then
            applications=$(kubectl get applications.argoproj.io --all-namespaces -o name)
            test -z "$applications" || { echo 'Refusing static bootstrap while Argo Applications exist.' >&2; exit 1; }
          fi
          kubectl apply --server-side --field-manager=argocd-controller -f ${manifests}/namespaces.yaml
          kubectl apply --server-side --field-manager=argocd-controller -f ${manifests}/crds.yaml
          kubectl wait --for=condition=Established --timeout=180s -f ${manifests}/crds.yaml
          # Controllers and admission Jobs converge while dependent objects retry.
          for _ in $(seq 1 60); do
            if kubectl apply --server-side --field-manager=argocd-controller -f ${manifests}/workloads.yaml; then
              echo 'Static resources applied. Check workload readiness before enabling Git reconciliation.'
              exit 0
            fi
            sleep 5
          done
          echo 'Static application failed to converge; retained resources were not pruned.' >&2
          exit 1
        '';
      };
    } // lib.optionalAttrs (lib.hasSuffix "-linux" system) {
      packages.household-bootstrap-bundle = pkgs.linkFarm "household-bootstrap-bundle" [
        { name = "manifests"; path = manifests; }
        { name = "images/kanidm-provision.tar"; path = self.packages.${system}.kanidm-provision-image; }
        {
          name = "operations.txt";
          path = pkgs.writeText "household-bootstrap-operations.txt" ''
            Build this bundle for the compute guest's Linux architecture.
            Copy it to the Incus host with nix copy; no runtime secrets are included.

            Set PROJECT and INSTANCE from the host's /etc/homelab-compute descriptor.
            Before applying manifests, import the pinned application image:
              incus --project "$PROJECT" file push ${self.packages.${system}.kanidm-provision-image} "$INSTANCE/tmp/kanidm-provision.tar"
              incus --project "$PROJECT" exec "$INSTANCE" -- k3s ctr images import --local --snapshotter native /tmp/kanidm-provision.tar
              incus --project "$PROJECT" exec "$INSTANCE" -- rm /tmp/kanidm-provision.tar

            Repeat this import after guest replacement or provisioning-image changes.
            It is application delivery, not an input to the guest OS image.
            The identity Job uses imagePullPolicy=Never and cannot substitute an
            unpinned registry image if this explicit import is missing.

            Stage the declared runtime credentials through the host agenix flow.
            With KUBECONFIG targeting the new guest, run household-bootstrap
            --fresh-cluster. It applies these static manifests without live Git or
            pruning. Check actual workload readiness; successful apply is not readiness.
            Only then publish rendered application directories to the selected Git
            source and apply its bootstrap.yaml to enable Argo reconciliation.
            Do not run the full static bootstrap against an Argo-managed cluster.
          '';
        }
      ];
    };
}
