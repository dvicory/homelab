import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const script = process.argv[2];
if (!script) throw new Error('usage: seerr-credential-boundary.mjs SEERR_SCRIPT');

const requests = [];
const key = 'fixture-seerr-api-key';
let fresh = false;
const server = createServer((request, response) => {
  requests.push({ path: request.url, method: request.method, key: request.headers['x-api-key'] });
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
  const run = () => new Promise(resolve => {
    const child = spawn(process.execPath, [script], {
      env: {
        ...process.env,
        MEDIA_CONFIGURATION_ROOT: join(root, 'configuration'),
        MEDIA_SECRETS_ROOT: join(root, 'secrets'),
        SEERR_STATE_ROOT: join(root, 'seerr-state'),
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stderr = '';
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('close', code => resolve({ code, stderr }));
  });
  const result = await run();
  assert.equal(result.code, 1);
  assert.match(result.stderr, /Seerr Jellyfin host differs/);
  assert(!result.stderr.includes(key));
  assert.deepEqual(requests, [
    { path: '/api/v1/settings/public', method: 'GET', key },
    { path: '/api/v1/settings/jellyfin', method: 'GET', key },
  ]);
  fresh = true;
  requests.length = 0;
  await writeFile(join(root, 'seerr-state', 'settings.json'), JSON.stringify({
    main: { mediaServerType: 4 }, jellyfin: { ip: 'untrusted.example' },
  }));
  const preclaim = await run();
  assert.equal(preclaim.code, 1);
  assert.match(preclaim.stderr, /Cannot verify unclaimed Seerr/);
  assert(!preclaim.stderr.includes(key));
  assert.deepEqual(requests, [{ path: '/api/v1/settings/public', method: 'GET', key }]);
} finally {
  await rm(root, { recursive: true, force: true });
  await new Promise(resolve => server.close(resolve));
}
