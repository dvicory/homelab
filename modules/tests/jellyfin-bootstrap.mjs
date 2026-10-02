import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const bootstrap = fs.readFileSync(process.argv[2], "utf8").replace(
  'import fs from "node:fs";',
  "const fs = testFs;"
);

async function exercise({ keyFailure = false, logoutFailure = false } = {}) {
  let loggedOut = 0;
  let wroteKey = false;
  const keyFailureError = new Error("fixture key acquisition failure");
  const reply = (status, body = null) => ({
    ok: status >= 200 && status < 300,
    status,
    text: async () => body === null ? "" : JSON.stringify(body),
  });
  const fetch = async (url) => {
    const path = new URL(url).pathname;
    if (path === "/health") return reply(200);
    if (path === "/Users/AuthenticateByName") return reply(200, { AccessToken: "admin-session" });
    if (path === "/Sessions/Logout") {
      loggedOut += 1;
      return reply(logoutFailure ? 500 : 204);
    }
    if (path === "/Auth/Keys") {
      if (keyFailure) throw keyFailureError;
      return reply(200, {
        Items: [{ AppName: "Jellarr", AccessToken: "jellarr-key" }],
      });
    }
    return reply(404);
  };
  const testFs = {
    readFileSync: () => "password\n",
    writeFileSync: (_path, _contents, options) => {
      assert.equal(options.mode, 0o400);
      wroteKey = true;
    },
  };
  const run = vm.runInNewContext(`(async () => { ${bootstrap} })()`, {
    testFs, fetch, URL, process: { env: { JELLYFIN_URL: "http://jellyfin.local" } },
    setTimeout,
  });
  if (keyFailure) {
    await assert.rejects(run, error => error === keyFailureError);
    assert.equal(wroteKey, false, "failed key acquisition must not expose a credential file");
  } else await run;
  assert.equal(loggedOut, 1, "temporary administrator session is logged out on success and failure");
}

await exercise();
await exercise({ logoutFailure: true });
await exercise({ keyFailure: true, logoutFailure: true });
