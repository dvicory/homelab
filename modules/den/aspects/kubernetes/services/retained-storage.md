# Experimental retained-storage procedure

This page documents the ordinary-Helm `retained-local` interface and its
representative Grafana fixture. It is not the primary household runbook, a
whole-stack backup procedure, production readiness evidence or production
authorization. Read the [household operations runbook](../../../../../docs/operations.md)
for the current declaration tables and lifecycle boundaries.

```sh
household-bootstrap --status
household-bootstrap --fresh-cluster
household-bootstrap --check-ready
household-bootstrap --retry-jobs
```

The commands below document only the ordinary-Helm `retained-local` interface
and its representative Grafana fixture. Household compute-loss recovery uses
guest replacement plus Argo reconciliation; it does not use whole-stack export,
restore, or resume commands.

## Ordinary Helm applications on retained storage

`retained-storage.nix` supplies the default `retained-local` StorageClass through an upstream provisioner. It creates **local PVs**, uses delayed binding and `Retain`, and permits only the declared compute node and host-backed parent. Existing static application volumes are unchanged.

Applications need normal PVCs and compatible chart security settings—not a Homelab application definition, host path or manually allocated UID. Fresh directories are private; Kubernetes applies the chart's filesystem group. The provisioner's helper runs as root **inside the unprivileged guest**, not as physical-host root. This storage capability is not admission control for untrusted charts or privileged/hostPath Pods.

### Install the representative Helm fixture

Use [grafana-example.yaml](grafana-example.yaml) only as disposable evidence
for ordinary Helm, retained-local PVCs and UI-owned state. Keep Argo from
owning this separate release.

```sh
helm pull grafana --repo https://grafana-community.github.io/helm-charts --version 13.2.2
printf '%s  %s\n' 40c4322f98df20865f06289dcd3010ff912dedf974d47239e61a1a6a579ad355 grafana-13.2.2.tgz | sha256sum -c -
helm upgrade --install grafana-example ./grafana-13.2.2.tgz \
  --namespace monitoring --values grafana-example.yaml --wait --timeout 5m
kubectl -n monitoring port-forward --address=127.0.0.1 service/grafana-example 3000:80
```

Use a private SSH tunnel when running port-forward remotely. This does not
publish an application route. Create and save a dashboard through the UI, then
confirm it survives a deployment restart. The values pin Grafana's
multiarchitecture image digest and configure a 1 GiB memory ceiling.

## Capture metadata before guest replacement

Run on the Incus host with its trusted Kubernetes credentials. Keep the recovery directory outside the guest, on protected persistent host storage. Stop changes to the selected release/claims during capture and recovery; do not enable Argo or run concurrent Helm operations against those objects.

The following captures **reattachment metadata, not a data backup**. Refresh it after release or volume changes. Unexpected guest loss before new metadata is captured remains a recovery gap; scheduled metadata/application backup is separate work.

```sh
set -eu
umask 077
recovery=/var/lib/homelab/compute-1/manual/grafana-helm-reattach
mkdir -p -m 0700 "$recovery" # Use a fresh directory; do not overwrite an older set.
kubectl -n monitoring get pvc grafana-example -o json > "$recovery/pvc-original.json"
volume=$(jq -er '.spec.volumeName' "$recovery/pvc-original.json")
kubectl get pv "$volume" -o json > "$recovery/pv-original.json"
jq -e --slurpfile pvc "$recovery/pvc-original.json" '
  .spec.persistentVolumeReclaimPolicy == "Retain" and
  .spec.local.path != null and
  .spec.claimRef.uid == $pvc[0].metadata.uid and
  .spec.claimRef.namespace == "monitoring" and
  .spec.claimRef.name == "grafana-example"
' "$recovery/pv-original.json" > /dev/null

clean='del(.status, .metadata.uid, .metadata.resourceVersion,
  .metadata.creationTimestamp, .metadata.generation, .metadata.managedFields,
  .metadata.selfLink, .metadata.deletionTimestamp, .metadata.deletionGracePeriodSeconds)'
jq "$clean | .spec.claimRef |= {name, namespace}" \
  "$recovery/pv-original.json" > "$recovery/pv.json"
jq "$clean | del(.metadata.annotations[\"pv.kubernetes.io/bind-completed\"],
  .metadata.annotations[\"pv.kubernetes.io/bound-by-controller\"],
  .metadata.annotations[\"volume.kubernetes.io/selected-node\"])" \
  "$recovery/pvc-original.json" > "$recovery/pvc.json"
kubectl -n monitoring get secrets -l owner=helm,name=grafana-example -o json |
  jq ".items |= map($clean)" > "$recovery/helm-releases.json"
cp grafana-example.yaml "$recovery/grafana-values.yaml"
cp grafana-13.2.2.tgz "$recovery/"
```

Retain the matching static platform manifests, guest bundle and host descriptor as well. Preserve the source credentials used by host secret staging. Helm release Secrets may themselves contain confidential values; never put this recovery directory in Git or the Nix store. Any additional application-generated Secrets require their own protected capture.

## Replace and reattach

Use the [household operations runbook](../../../../../docs/operations.md) and
`compute-guest replace --bundle BUNDLE --confirm INSTANCE` with the trusted host
descriptor. Guest deletion is destructive and requires the appropriate
environment authorization. Do not stop the disposable fixture owner: its
teardown also removes retained test data.

After replacement, acquire the new guest kubeconfig through the private
management path; the old cluster's CA/client material is stale. Preserve the
configured node hostname. A different host/node is a deliberate storage-placement
migration, not this procedure.

1. Seed Argo on the replacement guest with `household-bootstrap-host` and reestablish host-staged runtime Secrets; verify `monitoring/grafana-admin` exists. Do not install the ordinary Helm release yet, and keep Argo from owning its objects.
2. Verify the saved PV's host backing directory and existing application files are present on the intended retained mount. **Do not create an empty substitute or clear an unrelated existing binding.** Stop if this is not the recorded storage.
3. On the fresh cluster, restore the original binding and Helm records before starting the application:

```sh
kubectl create -f "$recovery/pv.json"
kubectl create -f "$recovery/pvc.json"
kubectl -n monitoring wait pvc/grafana-example \
  --for=jsonpath='{.status.phase}'=Bound --timeout=60s
kubectl create -f "$recovery/helm-releases.json"
helm upgrade grafana-example "$recovery/grafana-13.2.2.tgz" \
  --namespace monitoring --values "$recovery/grafana-values.yaml" \
  --wait --timeout 5m
```

Use `create`, not a forced apply over unknown resources. The restored PVC keeps its explicit `volumeName`; the PV keeps its recorded local path, node affinity and namespace/claim reservation, but not the old claim UID. This binds the replacement claim to the original data without provisioning a new directory. Helm recreates its missing workload resources from the retained release inputs.

Reopen private access, authenticate with the same credential and inspect the original dashboard. Verify its UID/content and the original backing path—not just pod readiness. Release normal reconciliation only after these checks.


## Limits

- Retention is not backup. This procedure does not survive loss/corruption of the host data or prove an independent backup destination.
- After total Kubernetes datastore loss, dynamically provisioned `retained-local` volumes reattach only through metadata captured by this procedure beforehand. There is no deterministic in-cluster recovery mechanism yet; treat captures as perishable prerequisites, not backups.
- PVC capacity requests are not enforced filesystem quotas; expansion and cross-node failover are not provided.
- Do not migrate existing media volumes or permissions through this procedure. Shared-media access requires separate writer/reader verification.
- Production deployment, credentials, public access and hardware validation remain separate gates.
