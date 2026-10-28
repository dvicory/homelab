# Media operations

Radarr, Sonarr, Prowlarr, SABnzbd and Seerr run in the `media` namespace on
the compute guest. The `media-configuration` Application configures them:
its PostSync Jobs run Configarr and then the Seerr helper after each sync,
and its CronJobs repeat both every six hours.

Do not relax media directory permissions. Arr and SABnzbd get media access
from the media group that their startup hook adds, not from wider modes.

## Sign-in

Open Radarr, Sonarr, Prowlarr and SABnzbd from their Kanidm tiles. The
Gateway asks for Kanidm sign-in as a member of `homelab-admin`; the apps
themselves have no login. Their APIs still require each app's API key.

Open Seerr at <https://requests.plus2.danielvicory.dev> and use its native
Jellyfin sign-in. There is no Gateway OIDC sign-in in front of Seerr.

Inside the cluster, NetworkPolicy admits only the Gateway proxy and, on the
app's port, each app's declared callers:

| App | Callers besides the Gateway proxy |
| --- | --- |
| Radarr, Sonarr | Configarr, Prowlarr; Seerr and the Seerr helper for instances with a Seerr role |
| Prowlarr | Configarr, every Radarr and Sonarr instance |
| SABnzbd | Every Radarr and Sonarr instance |

Any other pod, in `media` or elsewhere, is refused. A new caller must first
be added to `modules/den/aspects/kubernetes/services/media.nix`.

If the Gateway or Kanidm is down, reach an app with
`kubectl -n media port-forward svc/<app> <port>` from the host's cluster
access. Port-forwarding is not subject to NetworkPolicy, and the forwarded
port has no login, so treat that access like the cluster access it comes
from.

## Records the household may change

Managed records end in `(Homelab)`: the `SABnzbd (Homelab)` download client
in Radarr and Sonarr, and the `Radarr (Homelab)` and `Sonarr (Homelab)`
servers in Seerr. Each run rewrites these records. Do not edit or rename
them by hand.

Records with other names are left alone, so the household may add its own
download clients and Seerr servers. A managed Seerr server is the default
for its tier, so Seerr clears the default flag on any other server in that
tier.

## Publish Seerr

The current Seerr publication phase is listed under "Current stack" in
[`docs/operations.md`](../operations.md). In the `initial` phase the
`requests` route is not published, and only the Seerr PostSync Job may
claim the first owner. Fresh state uses the declared Jellyfin administrator;
initialized installations retain their existing owner (`daniel` in this
household). Changing the declared administrator does not transfer ownership.

Never select `ready` before that claim succeeds: until then, the Seerr
setup page lets anyone who reaches it claim the server.

1. Confirm that the Seerr Job succeeded:

   ```sh
   kubectl -n media get job media-config-seerr
   ```

2. Forward the Seerr port in one terminal:

   ```sh
   kubectl -n media port-forward service/seerr 5055:5055
   ```

   In another terminal, confirm that `initialized` is `true`:

   ```sh
   curl -s http://localhost:5055/api/v1/settings/public
   ```

3. Through the forwarded port, sign in as the retained Seerr owner, not
   automatically the current Jellyfin administrator, and check:
   - Under Jellyfin settings, the `Movies` and `Shows` libraries are enabled.
   - Under Services, `Radarr (Homelab)` and `Sonarr (Homelab)` use the
     profiles declared in `seerr.json`:

     ```sh
     kubectl -n media get configmap media-configuration \
       -o jsonpath='{.data.seerr\.json}'
     ```

4. Only then set `settings.kubernetes.services.seerr.phase = "ready"` in
   `modules/den/clusters/home.nix`. Regenerate and commit the manifests as
   described under "Deploy configuration" in
   [`docs/operations.md`](../operations.md).

Expected result: Argo CD publishes the `requests` route with Seerr's native
sign-in and removes only the first-owner authority. The owner and retained
data stay unchanged. Later Seerr runs use the `SEERR_API_KEY` runtime Secret;
the `jellyfin-admin` Secret remains available to Jellyfin and Jellarr.

If `initialized` is `false`, do not complete the setup page by hand. Fix the
Job failure as described below.

## Configuration Job failures

A Configarr or Seerr Job fails when a service it configures is unhealthy or
rejects a change. Repair the unhealthy dependency before you publish Seerr.

1. Read the failed Job's log:

   ```sh
   kubectl -n media logs job/media-configarr
   kubectl -n media logs job/media-config-seerr
   ```

2. Fix the cause. The Seerr helper needs Jellyfin, its
   `jellyfin-configuration` Job, Radarr and Sonarr, and a successful
   Configarr run; `Run Configarr before Seerr` means the declared quality
   profile does not exist yet.
3. Sync the `media-configuration` Application again so Argo CD reruns its
   PostSync Jobs. In the `initial` phase only this PostSync Job can claim the
   first owner; the six-hour CronJob cannot.

Expected result: both Jobs complete.

Each helper holds a lock file while it runs. Do not delete or replace a lock
file while a helper runs.

## Native media acceptance

Run the pinned application suite against a disposable native Linux x86 Docker daemon:

```sh
nix run .#media-live-acceptance -- \
  --docker-host unix:///var/run/docker.sock --platform linux/amd64
```

This requires a native Linux x86 Docker Engine with API 1.45 or newer.
The suite creates its own internal network, containers and Linux volume,
then verifies owned cleanup before reporting success. It renders explicit
`initial` and `ready` Seerr Jobs to test first-owner refusal/claim and later
API-key reconciliation independently of the production publication phase.
Bootstrap transport checks use the Job's declared non-root identity.
It does not use household data or secrets.

Nix CI runs this entire suite as the required `media-live-acceptance (x86_64-linux)`
job, separately from sandboxed flake checks. To select it alone with
`workflow_dispatch`, set `check` to `media-live-acceptance`; it always uses the
native x86 runner. The `native-x86_64-linux-media-live-acceptance-<run-id>` artifact
retains diagnostics for the run. The suite is executed on every full CI run even
when its Nix app dependencies are cached.

This exercises media application APIs and producer behavior. It does not prove
Kubernetes RBAC, NetworkPolicy or Gateway behavior, or the
Incus/MergerFS/ZFS/GPU storage and acceleration boundaries.

Accept acceleration changes using real hardware workloads with validated output.
Device lists and session creation establish discovery only; CPU fault-injection
tests cover error and ownership logic, not hardware codec, filter or inference
execution.
