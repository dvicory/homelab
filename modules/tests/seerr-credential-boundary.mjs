import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const script = process.argv[2];
if (!script) throw new Error('usage: seerr-credential-boundary.mjs SEERR_SCRIPT');

const requests = [];
const credentialObserver = 'data:text/javascript,' + encodeURIComponent(`
  import fs from 'node:fs';
  import { syncBuiltinESMExports } from 'node:module';
  const readFileSync = fs.readFileSync;
  fs.readFileSync = (path, ...args) => {
    if (path === '/var/run/secrets/kubernetes.io/serviceaccount/token') {
      process.send({ credentialRead: true });
    }
    if (path === process.env.SEERR_STATE_ROOT + '/settings.json') {
      process.send({ retainedSettingsRead: true });
    }
    return readFileSync(path, ...args);
  };
  syncBuiltinESMExports();
`);
const key = 'fixture-seerr-api-key';
const apiSecretKey = 'SEERR_KEY_FIXTURE';
let fresh = false;
let healthy = false;
let libraries = [];
let failure = '';
let fullSyncStarted = false;
let initialized = 0;
const folders = [
  { Id: 'movies', Name: 'Movies', Type: 'CollectionFolder', CollectionType: 'movies' },
  { Id: 'shows', Name: 'Shows', Type: 'CollectionFolder', CollectionType: 'tvshows' },
  { Id: 'music', Name: 'Music', Type: 'CollectionFolder', CollectionType: 'music' },
];
const server = createServer(async (request, response) => {
  let text = '';
  for await (const chunk of request) text += chunk;
  const body = text ? JSON.parse(text) : undefined;
  requests.push({ path: request.url, method: request.method, body });
  const reply = (status, value) => response.writeHead(status, { 'content-type': 'application/json' }).end(JSON.stringify(value));
  if (healthy && request.url === '/Library/MediaFolders') {
    return reply(request.headers.authorization?.includes('Token="jellyfin-token"') ? 200 : 401, { Items: folders });
  }
  if (request.headers['x-api-key'] !== key) return reply(401, null);
  if (!healthy) {
    const value = request.url === '/api/v1/settings/public'
      ? { mediaServerType: fresh ? 4 : 2, initialized: !fresh }
      : request.url === '/api/v1/settings/jellyfin'
        ? { ip: 'untrusted.example', port: 8096, useSsl: false, urlBase: '' }
        : null;
    return reply(value ? 200 : 404, value);
  }
  const route = request.method + ' ' + request.url;
  switch (route) {
    case 'GET /api/v1/settings/public':
      return reply(200, { mediaServerType: 2, initialized: true });
    case 'GET /api/v1/auth/me':
      return reply(200, { id: 1 });
    case 'GET /api/v1/settings/jellyfin':
      return reply(200, { ip: '127.0.0.1', port: server.address().port, useSsl: false, urlBase: '', apiKey: 'jellyfin-token', libraries });
    case 'POST /api/v1/settings/jellyfin':
    case 'POST /api/v1/settings/main':
      return reply(200, body);
    case 'POST /api/v1/settings/jellyfin/library/sync':
      // Upstream 3.5 refreshes metadata but preserves existing enabled flags.
      libraries = folders.map(folder => ({
        id: folder.Id, name: folder.Name, type: { movies: 'movie', tvshows: 'show', music: 'artist' }[folder.CollectionType],
        enabled: libraries.find(library => library.id === folder.Id)?.enabled ?? false,
      }));
      if (failure === 'missing') libraries = libraries.filter(library => library.id !== 'shows');
      if (failure === 'duplicate') libraries.push({ ...libraries[0] });
      return reply(200, libraries);
    case 'GET /api/v1/settings/jellyfin/library':
      // Unlike the old API, reads never change library flags.
      return reply(200, libraries);
    case 'POST /api/v1/settings/jellyfin/sync':
      fullSyncStarted = true;
      if (!libraries.every(library => library.enabled === ['movies', 'shows'].includes(library.id))) return reply(409, null);
      return reply(200, { running: true, progress: 0, total: 2, libraries });
    case 'GET /api/v1/settings/jellyfin/sync':
      return reply(200, { running: false, progress: 2, total: 2, libraries });
    case 'POST /api/v1/settings/initialize':
      if (!fullSyncStarted) return reply(409, null);
      initialized += 1;
      return reply(200, {});
  }
  if (request.method === 'PUT' && request.url.startsWith('/api/v1/settings/jellyfin/library/')) {
    const id = decodeURIComponent(request.url.split('/').at(-1));
    const library = libraries.find(library => library.id === id);
    if (failure === 'put') return reply(403, null);
    if (!library) return reply(404, null);
    if (typeof body?.enabled !== 'boolean') return reply(400, null);
    library.enabled = body.enabled;
    return reply(200, failure === 'acknowledgement' ? { ...library, enabled: !body.enabled } : library);
  }
  return reply(404, null);
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const root = await mkdtemp(join(tmpdir(), 'seerr-credential-boundary-'));
try {
  await mkdir(join(root, 'configuration'));
  await mkdir(join(root, 'secrets'));
  await mkdir(join(root, 'seerr-state'));
  await writeFile(join(root, 'secrets', apiSecretKey), key);
  await writeFile(join(root, 'configuration', 'seerr.json'), JSON.stringify({
    seerr: { url: `http://127.0.0.1:${server.address().port}`, apiSecretKey },
    jellyfin: {
      ip: 'jellyfin.media.svc', port: 8096, useSsl: false, urlBase: '',
      username: 'admin', namespace: 'jellyfin', secret: { name: 'administrator', key: 'password' },
    },
  }));
  const run = (initialOwner = false) => new Promise(resolve => {
    const child = spawn(process.execPath, ['--import', credentialObserver, script], {
      env: {
        ...process.env,
        MEDIA_CONFIGURATION_ROOT: join(root, 'configuration'),
        MEDIA_SECRETS_ROOT: join(root, 'secrets'),
        SEERR_STATE_ROOT: join(root, 'seerr-state'),
        SEERR_INITIAL_OWNER: initialOwner ? 'true' : '',
      },
      stdio: ['ignore', 'pipe', 'pipe', 'ipc'],
    });
    let output = '';
    let credentialReads = 0;
    let retainedSettingsReads = 0;
    child.stdout.on('data', chunk => { output += chunk; });
    child.stderr.on('data', chunk => { output += chunk; });
    child.on('message', message => {
      if (message.credentialRead) credentialReads += 1;
      if (message.retainedSettingsRead) retainedSettingsReads += 1;
    });
    child.on('close', code => resolve({ code, output, credentialReads, retainedSettingsReads }));
  });
  const result = await run();
  assert.equal(result.code, 1);
  assert(requests.some(request => request.path === '/api/v1/settings/jellyfin'), 'producer must encounter the hostile configured host');
  assert.equal(result.credentialReads, 0, 'a claimed hostile host is refused before reading administrator credentials');
  assert(!result.output.includes(key));
  assert(requests.every(request => request.method === 'GET'), 'host refusal sends no mutations');
  assert(!requests.some(request => request.path.startsWith('/api/v1/auth/')), 'host refusal sends no authentication requests');
  fresh = true;
  requests.length = 0;
  // Steady-state delivery cannot claim an owner when Seerr is unclaimed.
  const steady = await run();
  assert.equal(steady.code, 1);
  assert(requests.some(request => request.path === '/api/v1/settings/public'), 'producer must encounter the unclaimed server');
  assert.equal(steady.credentialReads, 0, 'steady-state delivery cannot read administrator credentials');
  assert.equal(steady.retainedSettingsReads, 0, 'steady-state delivery cannot inspect unclaimed retained settings');
  assert(!steady.output.includes(key));
  assert(requests.every(request => request.method === 'GET'), 'steady-state refusal sends no mutations');
  assert(!requests.some(request => request.path.startsWith('/api/v1/auth/')), 'steady-state refusal sends no authentication requests');
  requests.length = 0;
  await writeFile(join(root, 'seerr-state', 'settings.json'), JSON.stringify({
    main: { mediaServerType: 4 }, jellyfin: { ip: 'untrusted.example' },
  }));
  const preclaim = await run(true);
  assert.equal(preclaim.code, 1);
  assert(requests.some(request => request.path === '/api/v1/settings/public'), 'producer must encounter the unclaimed server');
  assert(preclaim.retainedSettingsReads > 0, 'initial delivery must inspect the retained Jellyfin host');
  assert.equal(preclaim.credentialReads, 0, 'an unclaimed hostile host is refused before reading administrator credentials');
  assert(!preclaim.output.includes(key));
  assert(requests.every(request => request.method === 'GET'), 'preclaim host refusal sends no mutations');
  assert(!requests.some(request => request.path.startsWith('/api/v1/auth/')), 'preclaim host refusal sends no authentication requests');
  // Exercise the helper end-to-end against a stateful Seerr 3.5 API contract.
  healthy = true;
  await writeFile(join(root, 'configuration', 'seerr.json'), JSON.stringify({
    seerr: { url: `http://127.0.0.1:${server.address().port}`, apiSecretKey, applicationUrl: 'https://requests.example' },
    jellyfin: {
      ip: '127.0.0.1', port: server.address().port, useSsl: false, urlBase: '',
      username: 'admin', namespace: 'jellyfin', secret: { name: 'administrator', key: 'password' },
      libraries: [{ name: 'Movies', collectionType: 'movies' }, { name: 'Shows', collectionType: 'tvshows' }],
    },
    arr: {},
  }));
  const reset = () => {
    requests.length = 0;
    libraries = [
      { id: 'movies', enabled: false }, { id: 'shows', enabled: true }, { id: 'music', enabled: true },
    ];
    fullSyncStarted = false;
    initialized = 0;
  };
  reset();
  const reconciled = await run();
  assert.equal(reconciled.code, 0, reconciled.output);
  assert.equal(reconciled.credentialReads, 0, 'steady-state library reconciliation cannot read administrator credentials');
  assert.deepEqual(libraries.map(({ id, enabled }) => ({ id, enabled })), [
    { id: 'movies', enabled: true }, { id: 'shows', enabled: true }, { id: 'music', enabled: false },
  ], 'new API must enable exactly the declared libraries, including disabling undeclared ones');
  assert.equal(initialized, 1, 'initialization follows successful full sync');
  assert.deepEqual(requests.filter(request => request.method === 'PUT').map(({ path, body }) => ({ path, body })), [
    { path: '/api/v1/settings/jellyfin/library/movies', body: { enabled: true } },
    { path: '/api/v1/settings/jellyfin/library/music', body: { enabled: false } },
  ]);
  requests.length = 0;
  const repeated = await run();
  assert.equal(repeated.code, 0, repeated.output);
  assert(!requests.some(request => request.method === 'PUT'), 'unchanged flags need no repeated writes');
  libraries.find(library => library.id === 'shows').enabled = false;
  requests.length = 0;
  const drifted = await run();
  assert.equal(drifted.code, 0, drifted.output);
  assert.deepEqual(requests.filter(request => request.method === 'PUT').map(request => request.body), [{ enabled: true }], 'a later run repairs flag drift');
  for (const mode of ['missing', 'duplicate', 'put', 'acknowledgement']) {
    reset();
    failure = mode;
    const rejected = await run();
    assert.equal(rejected.code, 1, mode + ': ' + rejected.output);
    assert.equal(rejected.credentialReads, 0, mode + ': administrator credential boundary remains intact');
    assert.equal(fullSyncStarted, false, mode + ': bad library results cannot start a full sync');
    assert.equal(initialized, 0, mode + ': partial failure cannot initialize Seerr');
    assert(!rejected.output.includes(key), mode + ': errors cannot disclose the API key');
    if (['missing', 'duplicate'].includes(mode)) assert(!requests.some(request => request.method === 'PUT'), mode + ': validate discovery before changing flags');
  }
} finally {
  await rm(root, { recursive: true, force: true });
  await new Promise(resolve => server.close(resolve));
}
