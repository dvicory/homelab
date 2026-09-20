import { readFileSync } from 'node:fs';

const configurationRoot = process.env.MEDIA_CONFIGURATION_ROOT ?? '/configuration';
const secretsRoot = process.env.MEDIA_SECRETS_ROOT ?? '/secrets';
const requestTimeoutMs = Number(process.env.MEDIA_REQUEST_TIMEOUT_MS ?? 10000);
const readinessTimeoutMs = Number(process.env.MEDIA_READY_TIMEOUT_MS ?? 600000);
if (!Number.isFinite(requestTimeoutMs) || requestTimeoutMs <= 0
  || !Number.isFinite(readinessTimeoutMs) || readinessTimeoutMs <= 0) {
  throw new Error('Invalid media configuration timeout');
}

const policy = JSON.parse(readFileSync(configurationRoot + '/prowlarr.json', 'utf8'));
const secret = name => {
  const value = readFileSync(secretsRoot + '/' + name, 'utf8').replace(/\r?\n$/, '');
  if (!value.trim()) throw new Error('Empty required Secret key: ' + name);
  return value;
};

function api(base, headers = {}) {
  return async (path, method = 'GET', body) => {
    let response;
    try {
      response = await fetch(base + path, {
        method,
        headers: { 'Content-Type': 'application/json', ...headers },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(requestTimeoutMs),
        redirect: 'error',
      });
    } catch {
      throw new Error(method + ' ' + path + ': dependency unreachable');
    }
    if (!response.ok) throw new Error(method + ' ' + path + ': HTTP ' + response.status);
    const text = await response.text();
    try { return text ? JSON.parse(text) : null; }
    catch { throw new Error(method + ' ' + path + ': invalid JSON response'); }
  };
}

function one(items, predicate, label) {
  const matches = items.filter(predicate);
  if (matches.length > 1) throw new Error('Ambiguous managed ' + label);
  return matches[0];
}

// This prefix is reserved for applications owned by the media reconciler.
const managedNamePrefix = 'homelab-';
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

async function waitForReady(request, label, deadline) {
  let delay = 1000;
  while (true) {
    try {
      await request('/system/status');
      return;
    } catch (error) {
      if (/ HTTP (401|403)$/.test(error.message)) {
        throw new Error(label + ' authentication failed');
      }
      if (Date.now() >= deadline) throw new Error(label + ' readiness timeout');
      await sleep(Math.min(delay, deadline - Date.now()));
      delay = Math.min(delay * 2, 10000);
    }
  }
}

async function configure() {
  if (
    !policy.prowlarr
    || typeof policy.prowlarr.url !== 'string'
    || typeof policy.prowlarr.apiSecretKey !== 'string'
    || !Array.isArray(policy.applications)
    || policy.applications.some(desired =>
      typeof desired.name !== 'string'
      || !desired.name.startsWith(managedNamePrefix)
      || typeof desired.implementation !== 'string'
      || typeof desired.baseUrl !== 'string'
      || typeof desired.prowlarrUrl !== 'string'
      || typeof desired.apiSecretKey !== 'string'
      || typeof desired.syncLevel !== 'string'
    )
  ) {
    throw new Error('Invalid Prowlarr reconciliation policy');
  }
  const desiredNames = new Set(policy.applications.map(desired => desired.name));
  if (desiredNames.size !== policy.applications.length) {
    throw new Error('Duplicate desired Prowlarr application name');
  }
  const deadline = Date.now() + readinessTimeoutMs;
  const request = api(policy.prowlarr.url + '/api/v1', {
    'X-Api-Key': secret(policy.prowlarr.apiSecretKey),
  });
  const desiredRequests = policy.applications.map(desired => ({
    desired,
    request: api(desired.baseUrl + '/api/v3', {
      'X-Api-Key': secret(desired.apiSecretKey),
    }),
  }));

  await waitForReady(request, 'Prowlarr', deadline);
  for (const { desired, request: desiredRequest } of desiredRequests) {
    await waitForReady(desiredRequest, desired.name, deadline);
  }

  const applications = await request('/applications');
  if (!Array.isArray(applications)) throw new Error('Invalid Prowlarr applications response');
  const stale = applications.filter(application =>
    typeof application.name === 'string'
    && application.name.startsWith(managedNamePrefix)
    && !desiredNames.has(application.name)
  );

  for (const application of stale) {
    if (!Number.isInteger(application.id)) throw new Error('Managed Prowlarr application has no id');
  }

  const changes = policy.applications.map(desired => {
    const existing = one(
      applications,
      application => application.name === desired.name,
      'Prowlarr application ' + desired.name,
    );
    if (existing) {
      if (!Number.isInteger(existing.id)) throw new Error('Managed Prowlarr application has no id');
      if (existing.implementation !== desired.implementation) {
        throw new Error('Prowlarr application ' + desired.name + ' is not a ' + desired.implementation);
      }
      if (!Array.isArray(existing.fields)) {
        throw new Error('Invalid fields for Prowlarr application ' + desired.name);
      }
    }
    const managed = {
      prowlarrUrl: desired.prowlarrUrl,
      baseUrl: desired.baseUrl,
      apiKey: secret(desired.apiSecretKey),
    };
    const fields = (existing ? existing.fields : [])
      .filter(field => !(field.name in managed))
      .concat(Object.entries(managed).map(([name, value]) => ({ name, value })));
    return {
      existing,
      application: {
        tags: [],
        ...(existing || {}),
        name: desired.name,
        implementation: desired.implementation,
        configContract: desired.implementation + 'Settings',
        syncLevel: desired.syncLevel,
        fields,
      },
    };
  });

  for (const { existing, application } of changes) {
    await request(
      '/applications' + (existing ? '/' + existing.id : ''),
      existing ? 'PUT' : 'POST',
      application,
    );
  }
  for (const application of stale) {
    await request('/applications/' + application.id, 'DELETE');
  }
}

try {
  await configure();
  console.log('prowlarr: declared Arr applications reconciled');
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
