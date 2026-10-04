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
let fresh = false;
const server = createServer((request, response) => {
  requests.push({ path: request.url, method: request.method });
  const body = request.url === '/api/v1/settings/public'
    ? { mediaServerType: fresh ? 4 : 2, initialized: !fresh }
    : request.url === '/api/v1/settings/jellyfin'
      ? { ip: 'untrusted.example', port: 8096, useSsl: false, urlBase: '' }
      : null;
  response.writeHead(body ? 200 : 404, { 'content-type': 'application/json' }).end(JSON.stringify(body));
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const root = await mkdtemp(join(tmpdir(), 'seerr-credential-boundary-'));
try {
  await mkdir(join(root, 'configuration'));
  await mkdir(join(root, 'secrets'));
  await mkdir(join(root, 'seerr-state'));
  await writeFile(join(root, 'secrets', 'SEERR_API_KEY'), key);
  await writeFile(join(root, 'configuration', 'seerr.json'), JSON.stringify({
    seerr: { url: `http://127.0.0.1:${server.address().port}` },
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
  assert.equal(preclaim.retainedSettingsReads, 1, 'initial delivery must inspect the retained Jellyfin host');
  assert.equal(preclaim.credentialReads, 0, 'an unclaimed hostile host is refused before reading administrator credentials');
  assert(!preclaim.output.includes(key));
  assert(requests.every(request => request.method === 'GET'), 'preclaim host refusal sends no mutations');
  assert(!requests.some(request => request.path.startsWith('/api/v1/auth/')), 'preclaim host refusal sends no authentication requests');
} finally {
  await rm(root, { recursive: true, force: true });
  await new Promise(resolve => server.close(resolve));
}
