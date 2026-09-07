{ lib, ... }:
{
  den.aspects.kubernetes.services.media = {
    settings.configurationSecret = lib.mkOption {
      type = lib.types.str;
      default = "media-runtime";
      description = ''
        Runtime Secret in media containing RADARR_API_KEY, SONARR_API_KEY,
        SABNZBD_API_KEY, SABNZBD_USERNAME, SABNZBD_PASSWORD and
        JELLYFIN_OWNER_USERNAME/PASSWORD/EMAIL. Complete
        Jellyfin's native first-run wizard first; the account must be its
        administrator and, on retained Seerr, the existing Seerr owner (id 1).
        Seerr's first owner is created through its native Jellyfin login API.
        Optional SEERR_API_KEY permits reconciliation when the old Jellyfin
        endpoint or owner password has changed; obtain it from Seerr Settings.
        No API keys, cookies or passwords are written to Nix or logged.
      '';
    };
    includes = [ {
      name = "media/configuration";
      k8s-manifests = { cluster, ... }:
        let
          routes = cluster.routes;
          prefix = name: lib.optionalString (routes.${name}.pathPrefix != "/") (lib.removeSuffix "/" routes.${name}.pathPrefix);
          external = name: "https://${builtins.head routes.${name}.hostnames}${prefix name}";
          endpoint = name: "http://${routes.${name}.service}.${routes.${name}.namespace}.svc:${toString routes.${name}.port}${prefix name}";
          policy = {
            profile = { name = "Homelab 1080p"; qualities = [ "HDTV-1080p" "WEBDL-1080p" "WEBRip-1080p" "Bluray-1080p" ]; cutoff = "Bluray-1080p"; upgradeAllowed = true; };
            arr = {
              radarr = { url = endpoint "radarr"; root = "/data/movies"; category = "movies"; categoryField = "movieCategory"; externalUrl = external "radarr"; };
              sonarr = { url = endpoint "sonarr"; root = "/data/tv"; category = "tv"; categoryField = "tvCategory"; externalUrl = external "sonarr"; };
            };
            sab = { host = "${routes.sabnzbd.service}.${routes.sabnzbd.namespace}.svc"; port = routes.sabnzbd.port; };
            seerr = { url = endpoint "requests"; applicationUrl = external "requests"; };
            jellyfin = { ip = "${routes.jellyfin.service}.${routes.jellyfin.namespace}.svc"; port = routes.jellyfin.port; useSsl = false; urlBase = prefix "jellyfin"; externalHostname = external "jellyfin"; };
          };
          # Uses the already-pinned Seerr runtime, whose v3.4.1 Dockerfile bases
          # the final stage on Node 22.22.2. Native fetch/fs need no npm packages,
          # curl, jq, image build, or private Seerr/Nixflix implementation imports.
          image = "ghcr.io/seerr-team/seerr:v3.4.1@sha256:f4768de5f616248d723e05891f3345a1402123775d03bf0890dbfedc0831bda1";
          script = ''
            import { readFileSync, existsSync } from 'node:fs';
            const policy = JSON.parse(readFileSync('/configuration/policy.json', 'utf8'));
            const secret = name => {
              const value = readFileSync('/secrets/' + name, 'utf8').replace(/\r?\n$/, "");
              if (!value.trim()) throw new Error('Empty required Secret key: ' + name);
              return value;
            };
            function api(base, headers = {}) {
              const cookies = new Map();
              return async (path, method = 'GET', body) => {
                let response;
                try {
                  response = await fetch(base + path, {
                    method, headers: { 'Content-Type': 'application/json', ...headers,
                      ...(cookies.size ? { Cookie: [...cookies].map(([k, v]) => k + '=' + v).join('; ') } : {}),
                      ...(cookies.has('XSRF-TOKEN') ? { 'X-XSRF-TOKEN': decodeURIComponent(cookies.get('XSRF-TOKEN')) } : {}),
                    },
                    body: body === undefined ? undefined : JSON.stringify(body),
                    signal: AbortSignal.timeout(20000), redirect: 'error',
                  });
                } catch { throw new Error(method + ' ' + path + ': dependency unreachable'); }
                // Never print response bodies: upstream errors may echo credentials.
                if (!response.ok) throw new Error(method + ' ' + path + ': HTTP ' + response.status);
                for (const cookie of response.headers.getSetCookie()) {
                  const pair = cookie.split(';')[0], index = pair.indexOf('=');
                  cookies.set(pair.slice(0, index), pair.slice(index + 1));
                }
                const text = await response.text();
                try { return { value: text ? JSON.parse(text) : null }; }
                catch { throw new Error(method + ' ' + path + ': invalid JSON response'); }
              };
            }
            function one(items, predicate, label) {
              const matches = items.filter(predicate);
              if (matches.length > 1) throw new Error('Ambiguous managed ' + label + '; resolve duplicate identities before retry');
              return matches[0];
            }
            async function arr(name) {
              const desired = policy.arr[name];
              const request = api(desired.url + '/api/v3', { 'X-Api-Key': secret(name.toUpperCase() + '_API_KEY') });
              const get = async path => (await request(path)).value;
              const roots = await get('/rootfolder');
              if (!one(roots, r => r.path === desired.root, 'root')) await request('/rootfolder', 'POST', { path: desired.root });

              const existingProfile = one(await get('/qualityprofile'), p => p.name === policy.profile.name, 'profile');
              const schema = await get('/qualityprofile/schema');
              const qualities = schema.items.flatMap(i => i.quality ? [i] : i.items);
              const selected = policy.profile.qualities.map(name => {
                const item = one(qualities, i => i.quality.name === name, 'quality');
                if (!item) throw new Error('Declared quality unavailable: ' + name);
                return { ...item, allowed: true };
              });
              const cutoff = selected.find(i => i.quality.name === policy.profile.cutoff);
              if (!cutoff) throw new Error('Cutoff must be an allowed quality');
              const profile = {
                ...(existingProfile || schema), name: policy.profile.name,
                upgradeAllowed: policy.profile.upgradeAllowed, cutoff: cutoff.quality.id,
                // Own this profile's quality membership/order only. Quality size
                // definitions, custom formats and every other profile stay native.
                items: [...qualities.filter(i => !policy.profile.qualities.includes(i.quality.name)).map(i => ({ ...i, allowed: false })), ...selected],
              };
              if (!existingProfile) delete profile.id;
              await request('/qualityprofile' + (existingProfile ? '/' + existingProfile.id : ""), existingProfile ? 'PUT' : 'POST', profile);

              const clientName = 'SABnzbd (Homelab)';
              const existing = one(await get('/downloadclient'), c => c.name === clientName, 'download client');
              if (existing && existing.implementation !== 'Sabnzbd') throw new Error('Managed client name belongs to another implementation');
              const client = existing || one(await get('/downloadclient/schema'), c => c.implementation === 'Sabnzbd', 'SAB schema');
              if (!client) throw new Error('SABnzbd schema unavailable');
              const fields = { host: policy.sab.host, port: policy.sab.port, useSsl: false, urlBase: "", apiKey: secret('SABNZBD_API_KEY'), username: secret('SABNZBD_USERNAME'), password: secret('SABNZBD_PASSWORD'), [desired.categoryField]: desired.category };
              for (const [name, value] of Object.entries(fields)) {
                const field = one(client.fields, f => f.name === name, 'SAB field');
                if (!field) throw new Error('SABnzbd schema field unavailable: ' + name);
                field.value = value;
              }
              Object.assign(client, { name: clientName, enable: true, priority: 1 });
              if (!existing) delete client.id;
              await request('/downloadclient' + (existing ? '/' + existing.id : ""), existing ? 'PUT' : 'POST', client);
            }
            async function seerr() {
              const base = policy.seerr.url + '/api/v1';
              const headers = { Origin: policy.seerr.url };
              const request = api(base, headers);
              const publicSettings = (await request('/settings/public')).value;
              if (existsSync('/secrets/SEERR_API_KEY')) {
                headers['X-Api-Key'] = secret('SEERR_API_KEY');
              } else {
                const login = { username: secret('JELLYFIN_OWNER_USERNAME'), password: secret('JELLYFIN_OWNER_PASSWORD'), email: secret('JELLYFIN_OWNER_EMAIL'), serverType: 2 };
                if (publicSettings.mediaServerType === 4) Object.assign(login, {
                  hostname: policy.jellyfin.ip, port: policy.jellyfin.port,
                  useSsl: policy.jellyfin.useSsl, urlBase: policy.jellyfin.urlBase,
                });
                const session = await request('/auth/jellyfin', 'POST', login);
                if (session.value.id !== 1) throw new Error('Runtime Jellyfin account is not the Seerr owner (id 1)');
                // Switch to native API-key auth after the supported owner login.
                const main = (await request('/settings/main')).value;
                headers['X-Api-Key'] = main.apiKey;
              }
              const owner = (await request('/auth/me')).value;
              if (owner.id !== 1) throw new Error('Configuration requires Seerr owner');
              await request('/settings/jellyfin', 'POST', policy.jellyfin);
              await request('/settings/main', 'POST', { applicationUrl: policy.seerr.applicationUrl });
              for (const [name, desired] of Object.entries(policy.arr)) {
                const arrKey = secret(name.toUpperCase() + '_API_KEY');
                const profiles = (await api(desired.url + '/api/v3', { 'X-Api-Key': arrKey })('/qualityprofile')).value;
                const profile = one(profiles, p => p.name === policy.profile.name, 'Seerr quality profile');
                if (!profile) throw new Error('Run Arr configuration before Seerr');
                const path = '/settings/' + name;
                const connectionName = name === 'radarr' ? 'Radarr' : 'Sonarr';
                const existing = one((await request(path)).value, s => s.name === connectionName, 'Seerr connection');
                const url = new URL(desired.url);
                const server = {
                  tags: [], overrideRule: [], tagRequests: false,
                  ...(existing || {}), name: connectionName, hostname: url.hostname,
                  port: Number(url.port), useSsl: false, baseUrl: url.pathname === '/' ? "" : url.pathname,
                  apiKey: arrKey, activeProfileId: profile.id, activeProfileName: policy.profile.name,
                  activeDirectory: desired.root, externalUrl: desired.externalUrl,
                  isDefault: true, is4k: false, syncEnabled: true, preventSearch: false,
                  ...(name === 'radarr' ? { minimumAvailability: 'released' } : {
                    seriesType: 'standard', animeSeriesType: 'anime',
                    activeAnimeProfileId: profile.id, activeAnimeProfileName: policy.profile.name,
                    activeAnimeDirectory: desired.root, enableSeasonFolders: true, monitorNewItems: 'all',
                  }),
                };
                delete server.id; // readOnly in the API schema; PUT's URL retains it.
                await request(path + '/test', 'POST', server);
                await request(path + (existing ? '/' + existing.id : ""), existing ? 'PUT' : 'POST', server);
              }
              await request('/settings/initialize', 'POST');
            }
            try {
              const target = process.argv[2];
              if (target === 'seerr') await seerr(); else if (Object.hasOwn(policy.arr, target)) await arr(target); else throw new Error('Unknown configuration target');
              console.log(target + ': declared configuration reconciled');
            } catch (error) { console.error(error.message); process.exitCode = 1; }
          '';
          configuration = { script = script; "policy.json" = builtins.toJSON policy; };
          jobSpec = target: {
            backoffLimit = 6;
            activeDeadlineSeconds = 900;
            template = {
              metadata.labels."app.kubernetes.io/name" = "media-configuration-${target}";
              spec = {
                restartPolicy = "Never";
                automountServiceAccountToken = false;
                securityContext = { runAsUser = 1000; runAsGroup = 1000; runAsNonRoot = true; fsGroup = 1000; seccompProfile.type = "RuntimeDefault"; };
                containers = [ {
                  name = "configure";
                  inherit image;
                  command = [ "node" "/configuration/configure.mjs" target ];
                  resources = { requests = { cpu = "25m"; memory = "64Mi"; }; limits = { cpu = "500m"; memory = "256Mi"; }; };
                  securityContext = { allowPrivilegeEscalation = false; readOnlyRootFilesystem = true; capabilities.drop = [ "ALL" ]; };
                  volumeMounts = [ { name = "configuration"; mountPath = "/configuration"; readOnly = true; } { name = "secrets"; mountPath = "/secrets"; readOnly = true; } ];
                } ];
                volumes = [
                  { name = "configuration"; configMap = { name = "media-configuration"; items = [ { key = "script"; path = "configure.mjs"; } { key = "policy.json"; path = "policy.json"; } ]; }; }
                  { name = "secrets"; secret = { secretName = cluster.settings.kubernetes.services.media.configurationSecret; defaultMode = 288; }; }
                ];
              };
            };
          };
          # PostSync Jobs belong to their own Application: failure cannot gate any
          # app's startup/readiness. Suspended CronJobs are durable rerun templates.
          # Ownership: add roots; upsert named profile/client/Seerr servers retaining
          # IDs and unspecified fields. Never delete collections, media or users.
          # Seerr's supported default-server API also clears other non-4k defaults.
          # SAB categories/paths remain owned by SAB's native INI initializer.
          # Reconcile/rotation/drift: kubectl -n media create job --from=cronjob/media-config-radarr media-config-radarr-<unique>
          # Repeat for sonarr, then seerr after both succeed. Re-sync this Application
          # to run all hooks. Do not launch concurrent manual runs of the same target.
          jobs = lib.concatMap (target:
            let
              runnable = jobSpec target;
            in [
              { apiVersion = "batch/v1"; kind = "CronJob"; metadata = { name = "media-config-${target}"; namespace = "media"; }; spec = { schedule = "0 4 * * *"; suspend = true; concurrencyPolicy = "Forbid"; successfulJobsHistoryLimit = 1; failedJobsHistoryLimit = 2; jobTemplate.spec = runnable; }; }
              { apiVersion = "batch/v1"; kind = "Job"; metadata = { name = "media-config-${target}"; namespace = "media"; annotations = { "argocd.argoproj.io/hook" = "PostSync"; "argocd.argoproj.io/hook-delete-policy" = "BeforeHookCreation"; "argocd.argoproj.io/sync-wave" = if target == "seerr" then "1" else "0"; }; }; spec = runnable; }
            ]) [ "radarr" "sonarr" "seerr" ];
        in {
          applications.media-configuration = {
            namespace = "media";
            objects = [ { apiVersion = "v1"; kind = "ConfigMap"; metadata = { name = "media-configuration"; namespace = "media"; }; data = configuration; } ] ++ jobs;
          };
        };
    } ];
  };
}
