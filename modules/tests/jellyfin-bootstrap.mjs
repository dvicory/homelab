import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const bootstrap = fs.readFileSync(process.argv[2], "utf8").replace(
  'import fs from "node:fs";',
  "const fs = testFs;"
);

async function exercise({ existing = false, keyFailure = false, logoutFailure = false, starting = false } = {}) {
  let keys = existing ? [{ AppName: "Jellarr", AccessToken: "jellarr-key" }] : [];
  let created = 0;
  let loggedOut = 0;
  let output;
  let healthChecks = 0;
  let healthy = false;
  const reply = (status, body = null) => ({
    ok: status >= 200 && status < 300,
    status,
    text: async () => body === null ? "" : JSON.stringify(body),
  });
  const fetch = async (url, options = {}) => {
    const path = new URL(url).pathname;
    if (path === "/health") {
      const body = starting && healthChecks++ === 0 ? "Degraded" : "Healthy";
      healthy = body === "Healthy";
      return { ...reply(200), text: async () => body };
    }
    if (path === "/Users/AuthenticateByName") {
      assert.equal(healthy, true, "authentication waits for native Healthy, not Degraded HTTP 200");
      return reply(200, { AccessToken: "admin-session" });
    }
    assert.equal(options.headers.Authorization,
      'MediaBrowser Client="homelab-jellarr-bootstrap", Device="Kubernetes Job", DeviceId="jellarr-bootstrap", Version="1", Token="admin-session"');
    assert.equal(options.headers["X-Emby-Token"], undefined);
    if (path === "/Sessions/Logout") {
      loggedOut += 1;
      return reply(logoutFailure ? 500 : 204);
    }
    assert.equal(path, "/Auth/Keys");
    if (keyFailure) return reply(503);
    if (options.method === "POST") {
      assert.equal(new URL(url).searchParams.get("app"), "Jellarr");
      created += 1;
      keys = [{ AppName: "Jellarr", AccessToken: "jellarr-key" }];
      return reply(204);
    }
    return reply(200, { Items: keys });
  };
  const testFs = {
    readFileSync: () => "password\n",
    writeFileSync: (path, contents, options) => {
      assert.equal(path, "/run/jellarr/api-key");
      assert.equal(options.mode, 0o400);
      output = contents;
    },
  };
  const run = vm.runInNewContext(`(async () => { ${bootstrap} })()`, {
    testFs, fetch, URL, process: { env: { JELLYFIN_URL: "http://jellyfin.local" } },
    setTimeout,
  });
  if (keyFailure) await assert.rejects(run, /Jellyfin API request failed: 503/);
  else await run;
  assert.equal(created, existing || keyFailure ? 0 : 1);
  assert.equal(output, keyFailure ? undefined : "jellarr-key\n");
  assert.equal(loggedOut, 1, "temporary administrator session is logged out on success and failure");
  if (starting) assert.equal(healthChecks, 2, "the native degraded response is not mistaken for application readiness");
}

await exercise();
await exercise({ existing: true, logoutFailure: true });
await exercise({ keyFailure: true, logoutFailure: true });
await exercise({ starting: true });
