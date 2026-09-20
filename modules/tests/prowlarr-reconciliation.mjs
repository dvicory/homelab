import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer } from 'node:http';

const script = process.argv[2];
if (!script) throw new Error('usage: prowlarr-reconciliation.mjs RENDERED_PROWLARR_SCRIPT');

async function fakeApi({ kind, key, applications = [], ready = true }) {
  const state = { applications, mutations: [], applicationReads: 0 };
  const server = createServer(async (request, response) => {
    if (request.headers['x-api-key'] !== key) {
      response.writeHead(401).end();
      return;
    }
    if (request.url.endsWith('/system/status')) {
      response.writeHead(ready ? 200 : 503, { 'content-type': 'application/json' })
        .end(JSON.stringify({ version: 'fixture' }));
      return;
    }
    if (kind !== 'prowlarr' || !request.url.includes('/applications')) {
      response.writeHead(404).end();
      return;
    }
    if (request.method === 'GET' && request.url === '/api/v1/applications') {
      state.applicationReads += 1;
      response.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify(state.applications));
      return;
    }
    const body = await new Promise(resolve => {
      const chunks = [];
      request.on('data', chunk => chunks.push(chunk));
      request.on('end', () => resolve(chunks.length ? JSON.parse(Buffer.concat(chunks)) : null));
    });
    state.mutations.push({ method: request.method, url: request.url, body });
    if (body?.forceSave !== undefined) throw new Error('fixture observed forceSave');
    const match = request.url.match(/^\/api\/v1\/applications\/(\d+)$/);
    if (request.method === 'POST' && request.url === '/api/v1/applications') {
      state.applications.push({ ...body, id: Math.max(0, ...state.applications.map(item => item.id)) + 1 });
    } else if (request.method === 'PUT' && match) {
      const index = state.applications.findIndex(item => item.id === Number(match[1]));
      state.applications[index] = { ...body, id: Number(match[1]) };
    } else if (request.method === 'DELETE' && match) {
      state.applications = state.applications.filter(item => item.id !== Number(match[1]));
    } else {
      response.writeHead(404).end();
      return;
    }
    response.writeHead(200, { 'content-type': 'application/json' }).end('{}');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return {
    state,
    url: `http://127.0.0.1:${server.address().port}`,
    close: () => new Promise(resolve => server.close(resolve)),
  };
}

async function run(scriptPath, policy, secrets) {
  const root = await mkdtemp(join(tmpdir(), 'prowlarr-fixture-'));
  await mkdir(join(root, 'configuration'));
  await mkdir(join(root, 'secrets'));
  await writeFile(join(root, 'configuration', 'prowlarr.json'), JSON.stringify(policy));
  await Promise.all(Object.entries(secrets).map(([name, value]) => writeFile(join(root, 'secrets', name), value)));
  const result = await new Promise(resolve => {
    const child = spawn(process.execPath, [scriptPath], {
      env: {
        ...process.env,
        MEDIA_CONFIGURATION_ROOT: join(root, 'configuration'),
        MEDIA_SECRETS_ROOT: join(root, 'secrets'),
        MEDIA_REQUEST_TIMEOUT_MS: '50',
        MEDIA_READY_TIMEOUT_MS: '150',
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('close', code => resolve({ code, stdout, stderr }));
  });
  await rm(root, { recursive: true, force: true });
  return result;
}

const prowlarrKey = 'fixture-prowlarr-key';
const radarrKey = 'fixture-radarr-key';
const sonarrKey = 'fixture-sonarr-key';

const failedProwlarr = await fakeApi({ kind: 'prowlarr', key: prowlarrKey });
const failedRadarr = await fakeApi({ kind: 'radarr', key: radarrKey });
const failedSonarr = await fakeApi({ kind: 'sonarr', key: sonarrKey, ready: false });
try {
  const failed = await run(script, {
    prowlarr: { url: failedProwlarr.url, apiSecretKey: 'PROWLARR_API_KEY' },
    applications: [
      { name: 'homelab-radarr', implementation: 'Radarr', baseUrl: failedRadarr.url, apiSecretKey: 'RADARR_API_KEY', prowlarrUrl: failedProwlarr.url, syncLevel: 'fullSync' },
      { name: 'homelab-sonarr', implementation: 'Sonarr', baseUrl: failedSonarr.url, apiSecretKey: 'SONARR_API_KEY', prowlarrUrl: failedProwlarr.url, syncLevel: 'fullSync' },
    ],
  }, {
    PROWLARR_API_KEY: prowlarrKey,
    RADARR_API_KEY: radarrKey,
    SONARR_API_KEY: sonarrKey,
  });
  assert.equal(failed.code, 1);
  assert.equal(failedProwlarr.state.applicationReads, 0);
  assert.deepEqual(failedProwlarr.state.mutations, []);
  assert(!failed.stderr.includes(prowlarrKey));
  assert(!failed.stderr.includes(radarrKey));
  assert(!failed.stderr.includes(sonarrKey));
} finally {
  await Promise.all([failedProwlarr.close(), failedRadarr.close(), failedSonarr.close()]);
}

const owned = {
  id: 1,
  name: 'homelab-radarr',
  implementation: 'Radarr',
  fields: [
    { name: 'prowlarrUrl', value: 'old' },
    { name: 'baseUrl', value: 'old' },
    { name: 'apiKey', value: 'old' },
    { name: 'customField', value: 'preserve' },
  ],
  tags: [7],
};
const stale = { id: 2, name: 'homelab-retired', implementation: 'Sonarr', fields: [], tags: [] };
const ui = { id: 3, name: 'manual-ui-entry', implementation: 'Other', fields: [], tags: [] };
const goodProwlarr = await fakeApi({ kind: 'prowlarr', key: prowlarrKey, applications: [owned, stale, ui] });
const goodRadarr = await fakeApi({ kind: 'radarr', key: radarrKey });
const goodSonarr = await fakeApi({ kind: 'sonarr', key: sonarrKey });
try {
  const good = await run(script, {
    prowlarr: { url: goodProwlarr.url, apiSecretKey: 'PROWLARR_API_KEY' },
    applications: [
      { name: 'homelab-radarr', implementation: 'Radarr', baseUrl: goodRadarr.url, apiSecretKey: 'RADARR_API_KEY', prowlarrUrl: goodProwlarr.url, syncLevel: 'fullSync' },
      { name: 'homelab-sonarr', implementation: 'Sonarr', baseUrl: goodSonarr.url, apiSecretKey: 'SONARR_API_KEY', prowlarrUrl: goodProwlarr.url, syncLevel: 'fullSync' },
    ],
  }, {
    PROWLARR_API_KEY: prowlarrKey,
    RADARR_API_KEY: radarrKey,
    SONARR_API_KEY: sonarrKey,
  });
  assert.equal(good.code, 0, good.stderr);
  assert.deepEqual(goodProwlarr.state.applications.map(item => item.name).sort(), [
    'homelab-radarr',
    'homelab-sonarr',
    'manual-ui-entry',
  ]);
  const updated = goodProwlarr.state.applications.find(item => item.name === 'homelab-radarr');
  assert.equal(updated.fields.find(field => field.name === 'customField').value, 'preserve');
  assert.equal(updated.fields.find(field => field.name === 'baseUrl').value, goodRadarr.url);
  assert.equal(goodProwlarr.state.mutations.filter(item => item.method === 'DELETE').length, 1);
  assert(goodProwlarr.state.mutations.some(item => item.method === 'POST'));
  assert(goodProwlarr.state.mutations.every(item => !item.body?.forceSave));
} finally {
  await Promise.all([goodProwlarr.close(), goodRadarr.close(), goodSonarr.close()]);
}
