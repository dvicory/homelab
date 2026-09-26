import { readFileSync } from 'node:fs';

const policy = JSON.parse(readFileSync((process.env.MEDIA_CONFIGURATION_ROOT || '/configuration') + '/seerr.json', 'utf8'));
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const secret = name => {
  const value = readFileSync((process.env.MEDIA_SECRETS_ROOT || '/secrets') + '/' + name, 'utf8').replace(/\r?\n$/, '');
  if (!value.trim()) throw new Error('Empty required Secret key: ' + name);
  return value;
};

function api(base, headers = {}) {
  const cookies = new Map();
  return async (path, method = 'GET', body) => {
    let response;
    try {
      response = await fetch(base + path, {
        method,
        headers: {
          'Content-Type': 'application/json', ...headers,
          ...(cookies.size ? { Cookie: [...cookies].map(([key, value]) => key + '=' + value).join('; ') } : {}),
          ...(cookies.has('XSRF-TOKEN') ? { 'X-XSRF-TOKEN': decodeURIComponent(cookies.get('XSRF-TOKEN')) } : {}),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(20000),
        redirect: 'error',
      });
    } catch {
      throw new Error(method + ' ' + path + ': dependency unreachable');
    }
    if (!response.ok) throw new Error(method + ' ' + path + ': HTTP ' + response.status);
    for (const cookie of response.headers.getSetCookie()) {
      const pair = cookie.split(';')[0], index = pair.indexOf('=');
      cookies.set(pair.slice(0, index), pair.slice(index + 1));
    }
    const text = await response.text();
    try { return text ? JSON.parse(text) : null; }
    catch { throw new Error(method + ' ' + path + ': invalid JSON response'); }
  };
}

function one(items, predicate, label) {
  if (!Array.isArray(items)) throw new Error('Invalid ' + label + ' list');
  const matches = items.filter(predicate);
  if (matches.length > 1) throw new Error('Ambiguous ' + label);
  return matches[0];
}

async function administratorPassword() {
  const token = readFileSync('/var/run/secrets/kubernetes.io/serviceaccount/token', 'utf8');
  const { name, key } = policy.jellyfin.secret;
  const request = api('https://kubernetes.default.svc', { Authorization: 'Bearer ' + token });
  const result = await request('/api/v1/namespaces/' + encodeURIComponent(policy.jellyfin.namespace) + '/secrets/' + encodeURIComponent(name));
  const encoded = result?.data?.[key];
  if (typeof encoded !== 'string' || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) {
    throw new Error('Jellyfin administrator Secret is missing or invalid');
  }
  const password = Buffer.from(encoded, 'base64').toString('utf8').replace(/\r?\n$/, '');
  if (!password.trim()) throw new Error('Jellyfin administrator Secret is empty');
  return password;
}

function checkedStatus(status, libraryId) {
  if (typeof status?.running !== 'boolean' || !Number.isInteger(status.progress) ||
      !Number.isInteger(status.total) || status.progress < 0 || status.total < 0 ||
      (status.libraries !== undefined && (!Array.isArray(status.libraries) ||
        !status.libraries.some(library => library.id === libraryId && library.enabled === true))) ||
      (!status.running && !Array.isArray(status.libraries))) {
    throw new Error('Unsupported Jellyfin sync status');
  }
  return status;
}

async function configure() {
  const base = policy.seerr.url + '/api/v1';
  const headers = { Origin: policy.seerr.url, 'X-Api-Key': secret('SEERR_API_KEY') };
  const request = api(base, headers);
  const publicSettings = await request('/settings/public');
  if (![2, 4].includes(publicSettings?.mediaServerType)) throw new Error('Seerr is not available for Jellyfin onboarding');
  const { username, library: libraryName, namespace: _namespace, secret: _secret, ...jellyfinSettings } = policy.jellyfin;
  if (publicSettings.mediaServerType === 2 || publicSettings.initialized) {
    const configured = await request('/settings/jellyfin');
    if (configured?.ip !== jellyfinSettings.ip || configured.port !== jellyfinSettings.port ||
        Boolean(configured.useSsl) !== jellyfinSettings.useSsl ||
        (configured.urlBase || '') !== jellyfinSettings.urlBase) {
      throw new Error('Seerr Jellyfin host differs from the declared Jellyfin server');
    }
  } else {
    // The pre-owner API key cannot read /settings/jellyfin. Inspect the same
    // retained settings Seerr loads before allowing its auth endpoint to use
    // a stored hostname instead of the hostname supplied below.
    const saved = JSON.parse(readFileSync((process.env.SEERR_STATE_ROOT || '/seerr-state') + '/settings.json', 'utf8'));
    if (saved?.main?.mediaServerType !== 4 || saved?.jellyfin?.ip !== '') {
      throw new Error('Cannot verify unclaimed Seerr has no configured Jellyfin host');
    }
    const password = await administratorPassword();
    const session = await request('/auth/jellyfin', 'POST', {
      username, password, serverType: 2,
      hostname: jellyfinSettings.ip,
      port: jellyfinSettings.port,
      useSsl: jellyfinSettings.useSsl,
      urlBase: jellyfinSettings.urlBase,
    });
    if (session?.id !== 1) throw new Error('Jellyfin administrator is not the Seerr owner');
  }
  const owner = await request('/auth/me');
  if (owner?.id !== 1) throw new Error('Configuration requires Seerr owner');

  await request('/settings/jellyfin', 'POST', jellyfinSettings);
  await request('/settings/main', 'POST', { applicationUrl: policy.seerr.applicationUrl });
  for (const [kind, roles] of Object.entries(policy.arr)) {
    const path = '/settings/' + kind;
    const current = await request(path);
    for (const role of ['standard', '4k']) {
      const connectionName = (kind === 'radarr' ? 'Radarr' : 'Sonarr') + (role === '4k' ? ' 4K' : '');
      const existing = one(current, item => item.name === connectionName, 'Seerr connection');
      const desired = roles[role];
      if (!desired) {
        if (existing) await request(path + '/' + existing.id, 'DELETE');
        continue;
      }
      const profiles = await api(desired.url + '/api/v3', { 'X-Api-Key': secret(desired.apiSecretKey) })('/qualityprofile');
      const profile = one(profiles, item => item.name === desired.profile, 'Seerr quality profile');
      if (!profile) throw new Error('Run Configarr before Seerr');
      const url = new URL(desired.url);
      const server = {
        tags: [], overrideRule: [], tagRequests: false,
        ...(existing || {}),
        name: connectionName,
        hostname: url.hostname,
        port: Number(url.port),
        useSsl: url.protocol === 'https:',
        baseUrl: url.pathname === '/' ? '' : url.pathname,
        apiKey: secret(desired.apiSecretKey),
        activeProfileId: profile.id,
        activeProfileName: desired.profile,
        activeDirectory: desired.root,
        externalUrl: desired.externalUrl,
        isDefault: true,
        is4k: role === '4k',
        syncEnabled: true,
        preventSearch: false,
        ...(kind === 'radarr' ? { minimumAvailability: 'released' } : {
          seriesType: 'standard', animeSeriesType: 'anime',
          activeAnimeProfileId: profile.id,
          activeAnimeProfileName: desired.profile,
          activeAnimeDirectory: desired.root,
          enableSeasonFolders: true,
          monitorNewItems: 'all',
        }),
      };
      delete server.id;
      await request(path + '/test', 'POST', server);
      await request(path + (existing ? '/' + existing.id : ''), existing ? 'PUT' : 'POST', server);
    }
  }

  // The Seerr library GET mutates enabled flags. Discover the ID from Jellyfin first.
  const jellyfinUrl = (jellyfinSettings.useSsl ? 'https://' : 'http://') +
    jellyfinSettings.ip + ':' + jellyfinSettings.port + jellyfinSettings.urlBase;
  const configuredJellyfin = await request('/settings/jellyfin');
  if (typeof configuredJellyfin?.apiKey !== 'string' || !configuredJellyfin.apiKey) {
    throw new Error('Seerr has no Jellyfin API key after owner claim');
  }
  const jellyfinAuthorization = 'MediaBrowser Client="homelab-seerr", Device="Kubernetes Job", DeviceId="media-config-seerr", Version="1", Token="' + configuredJellyfin.apiKey + '"';
  const folders = await api(jellyfinUrl, { Authorization: jellyfinAuthorization })('/Library/MediaFolders');
  const selected = one(folders?.Items, item => item.Name === libraryName && item.Type === 'CollectionFolder' && item.CollectionType === 'movies', 'Movies library');
  if (typeof selected?.Id !== 'string' || !selected.Id || selected.Id.includes(',')) throw new Error('Configured Movies library not found or invalid');
  if (folders.Items.filter(item => item.Id === selected.Id).length !== 1) throw new Error('Ambiguous Movies library ID');
  const enabled = await request('/settings/jellyfin/library?sync=true&enable=' + encodeURIComponent(selected.Id));
  const active = one(enabled, item => item.id === selected.Id, 'enabled Movies library');
  if (active?.name !== libraryName || active.type !== 'movie' || active.enabled !== true) {
    throw new Error('Seerr did not enable the configured Movies library');
  }
  const started = checkedStatus(await request('/settings/jellyfin/sync', 'POST', { start: true }), selected.Id);
  if (!started.running) throw new Error('Jellyfin full sync did not start');
  let completed = false;
  for (let attempt = 0; attempt < 120; attempt++) {
    await sleep(5000);
    const status = checkedStatus(await request('/settings/jellyfin/sync'), selected.Id);
    if (!status.running) {
      if (status.progress > status.total) throw new Error('Invalid Jellyfin scan progress');
      completed = true;
      break;
    }
  }
  if (!completed) throw new Error('Jellyfin full sync exceeded deadline');
  const libraries = (await request('/settings/jellyfin'))?.libraries;
  const ready = one(libraries, item => item.id === selected.Id, 'ready Movies library');
  if (ready?.name !== libraryName || ready.enabled !== true) {
    throw new Error('Configured Movies library did not remain enabled');
  }
  await request('/settings/initialize', 'POST');
}

try {
  await configure();
  console.log('seerr: Jellyfin library sync and declared Arr servers reconciled');
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
