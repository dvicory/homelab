# Media operations

Radarr, Sonarr, Prowlarr, SABnzbd and Seerr run in the `media` namespace on
the compute guest. The `media-configuration` Application configures them:
its PostSync Jobs run Configarr and then the Seerr helper after each sync,
and its CronJobs repeat both every six hours.

Do not relax media directory permissions. Arr and SABnzbd get media access
from the media group that their startup hook adds, not from wider modes.

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

Seerr starts in the `initial` phase, listed under "Current stack" in
[`docs/operations.md`](../operations.md). In that phase the `requests`
route is not published, and only the Seerr PostSync Job may claim Seerr's
first owner, the Jellyfin administrator.

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

3. Through the forwarded port, sign in as the Jellyfin administrator and
   check:
   - Under Jellyfin settings, the `Movies` library is enabled.
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
sign-in and removes the first-owner authority. Later Seerr runs use the
`SEERR_API_KEY` runtime Secret.

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
