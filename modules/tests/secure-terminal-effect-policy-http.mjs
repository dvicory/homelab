import fs from "node:fs"
import http from "node:http"

const policyDoc = JSON.parse(fs.readFileSync(process.env.GONDOLIN_EFFECT_POLICY, "utf8"))
if (JSON.stringify(policyDoc.grantPolicy.allowedScopes) !== JSON.stringify(["once", "task"])) {
  throw new Error(`unexpected QA grant scopes: ${JSON.stringify(policyDoc.grantPolicy.allowedScopes)}`)
}
if (!/^[0-9a-f]{64}$/.test(policyDoc.policyDigest)) {
  throw new Error("rendered policy digest is not a full SHA-256 value")
}
const handoff = policyDoc.policy.statements.find(
  (candidate) =>
    candidate.resources.includes("task-run:*") &&
    candidate.actions.includes("workspace.publish") &&
    candidate.actions.includes("workspace.import"),
)
if (!handoff) throw new Error("QA policy omitted workspace handoff actions")
const expectedRevisionLimits = {
  maxLogicalBytes: 67108864,
  maxEntries: 8192,
  maxFileBytes: 16777216,
  maxPathBytes: 1024,
}
for (const [name, value] of Object.entries(expectedRevisionLimits)) {
  if (handoff.limits?.[name] !== value) {
    throw new Error(`unexpected workspace revision limit ${name}: ${handoff.limits?.[name]}`)
  }
}

const request = (socketPath, route, method = "GET", payload) =>
  new Promise((resolve, reject) => {
    const encoded = payload === undefined ? undefined : Buffer.from(JSON.stringify(payload))
    const req = http.request(
      {
        socketPath,
        path: route,
        method,
        headers:
          encoded === undefined
            ? {}
            : {
                "content-type": "application/json",
                "content-length": String(encoded.byteLength),
              },
      },
      (response) => {
        const chunks = []
        response.on("data", (chunk) => chunks.push(chunk))
        response.on("end", () =>
          resolve({
            status: response.statusCode,
            body: Buffer.concat(chunks).toString("utf8"),
          }),
        )
      },
    )
    req.on("error", reject)
    if (encoded !== undefined) req.write(encoded)
    req.end()
  })

const executionHealth = await request(process.env.GONDOLIN_EFFECT_SOCKET, "/v1/health")
const controlHealth = await request(process.env.GONDOLIN_EFFECT_CONTROL_SOCKET, "/v1/health")
if (executionHealth.status !== 200 || JSON.parse(executionHealth.body).plane !== "execution") {
  throw new Error("execution health response is not ok")
}
if (controlHealth.status !== 200 || JSON.parse(controlHealth.body).plane !== "control") {
  throw new Error("control health response is not ok")
}

const escapedControl = await request(
  process.env.GONDOLIN_EFFECT_SOCKET,
  "/v1/control/authority/status",
  "POST",
  { environmentKey: "nix-check" },
)
const escapedExecution = await request(
  process.env.GONDOLIN_EFFECT_CONTROL_SOCKET,
  "/v1/environments/ensure",
  "POST",
  { environmentKey: "nix-check" },
)
if (escapedControl.status !== 404 || escapedExecution.status !== 404) {
  throw new Error("execution/control routes are not isolated")
}

for (const lane of ["default", "codex"]) {
  const resource = `worklane:${lane}:environment:*`
  const statement = policyDoc.policy.statements.find(
    (candidate) =>
      candidate.actions.includes("environment.ensure") && candidate.resources.includes(resource),
  )
  if (!statement) throw new Error(`missing ensure authority for ${lane}`)
  const obligations = statement.obligations?.filter(
    (obligation) => obligation.kind === "network",
  ) ?? []
  if (obligations.length !== 1) {
    throw new Error(`expected exactly one network obligation for ${lane}`)
  }
  const networkId = obligations[0].bundleId
  if (!networkId.startsWith(`worklane:${lane}:`) || !policyDoc.networkPolicies[networkId]) {
    throw new Error(`network obligation is not content-bound for ${lane}`)
  }
}

const policyFor = (lane) => {
  const statement = policyDoc.policy.statements.find((candidate) =>
    candidate.resources.includes(`worklane:${lane}:environment:*`),
  )
  return policyDoc.networkPolicies[statement.obligations[0].bundleId]
}
const defaultHosts = new Set(policyFor("default").destinations.map((item) => item.host))
for (const host of ["github.com", "registry.npmjs.org", "pypi.org", "cache.nixos.org"]) {
  if (!defaultHosts.has(host)) throw new Error(`default lane missing reviewed host ${host}`)
}
const codexHosts = new Set(policyFor("codex").destinations.map((item) => item.host))
if (!codexHosts.has("github.com") || !codexHosts.has("pypi.org")) {
  throw new Error("codex lane missing its reviewed network bundles")
}
if (codexHosts.has("cache.nixos.org")) {
  throw new Error("codex lane exceeded its network maximum")
}
