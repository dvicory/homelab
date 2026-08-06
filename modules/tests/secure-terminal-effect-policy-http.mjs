import fs from "node:fs"
import http from "node:http"

const policyDoc = JSON.parse(fs.readFileSync(process.env.GONDOLIN_EFFECT_POLICY, "utf8"))
if (JSON.stringify(policyDoc.grantPolicy.allowedScopes) !== JSON.stringify(["once", "task"])) {
  throw new Error(`unexpected QA grant scopes: ${JSON.stringify(policyDoc.grantPolicy.allowedScopes)}`)
}
if (!/^[0-9a-f]{64}$/.test(policyDoc.policyDigest)) {
  throw new Error("rendered policy digest is not a full SHA-256 value")
}
const capturePolicy = policyDoc.policy.statements.find(
  (candidate) =>
    candidate.resources.includes("task-run:*") &&
    candidate.actions.includes("workspace.capture"),
)
const artifactPolicy = policyDoc.policy.statements.find(
  (candidate) =>
    candidate.resources.includes("handoff:*") &&
    candidate.actions.includes("workspace.artifact.read"),
)
if (!capturePolicy || !artifactPolicy) throw new Error("QA policy omitted workspace handoff actions")
if (JSON.stringify(capturePolicy.actions) !== JSON.stringify(["workspace.capture"])) {
  throw new Error(`unexpected capture actions: ${JSON.stringify(capturePolicy.actions)}`)
}
if (JSON.stringify(artifactPolicy.actions) !== JSON.stringify(["workspace.artifact.read"])) {
  throw new Error(`unexpected artifact-read actions: ${JSON.stringify(artifactPolicy.actions)}`)
}
const expectedHandoffLimits = {
  maxLogicalBytes: 67108864,
  maxEntries: 8192,
  maxFileBytes: 16777216,
  maxPathBytes: 1024,
}
for (const [name, value] of Object.entries(expectedHandoffLimits)) {
  for (const [label, statement] of [["capture", capturePolicy], ["artifact read", artifactPolicy]]) {
    if (statement.limits?.[name] !== value) {
      throw new Error(`unexpected ${label} handoff limit ${name}: ${statement.limits?.[name]}`)
    }
  }
}
const projectWorkspace = policyDoc.projectWorkspace
if (!projectWorkspace) throw new Error("QA policy omitted the broker-project workspace catalogue")
if (projectWorkspace.provider !== "broker-project") {
  throw new Error(`unexpected Project provider: ${projectWorkspace.provider}`)
}
if (!/^[0-9a-f]{64}$/.test(projectWorkspace.providerRevisions?.["broker-project"] ?? "")) {
  throw new Error("broker-project provider revision is not a full SHA-256 value")
}
if (!/^[0-9a-f]{64}$/.test(projectWorkspace.sourceRevisions?.homelab ?? "")) {
  throw new Error("homelab source revision is not a full SHA-256 value")
}
const homelabSource = projectWorkspace.sources?.homelab
if (!homelabSource) throw new Error("QA policy omitted the homelab Project source")
if (homelabSource.upstream !== "https://github.com/dvicory/homelab.git") {
  throw new Error(`unexpected homelab upstream: ${homelabSource.upstream}`)
}
if (homelabSource.credential?.adapter !== "github-token" ||
    homelabSource.credential?.secretRef !== "hermes-terminal-github") {
  throw new Error("homelab credential must be a logical github-token reference")
}
const projectText = JSON.stringify(projectWorkspace)
for (const forbidden of ["github_pat_", "ghp_", "gho_", "/run/agenix", "/nix/store"]) {
  if (projectText.includes(forbidden)) {
    throw new Error(`Project catalogue leaks credential material or host paths: ${forbidden}`)
  }
}
const expectedMaterializationLimits = {
  maxSourceBytes: 2147483648,
  maxEntries: 65536,
  maxFileBytes: 268435456,
  maxPathBytes: 1024,
  deadlineMs: 600000,
  maxProjectWorkspaces: 16,
  maxStorageBytes: 8589934592,
  retentionMs: 604800000,
}
for (const [name, value] of Object.entries(expectedMaterializationLimits)) {
  if (projectWorkspace.limits?.[name] !== value) {
    throw new Error(`unexpected materialization limit ${name}: ${projectWorkspace.limits?.[name]}`)
  }
}
const resolvePolicy = policyDoc.policy.statements.find(
  (candidate) =>
    candidate.resources.includes("project-source:*") &&
    candidate.actions.includes("project.source.resolve"),
)
const resultPolicy = policyDoc.policy.statements.find(
  (candidate) =>
    candidate.resources.includes("task-run:*") &&
    candidate.actions.includes("project.result.read"),
)
if (!resolvePolicy || !resultPolicy) {
  throw new Error("QA policy omitted Project source/result control actions")
}
if (JSON.stringify(resolvePolicy.actions) !== JSON.stringify(["project.source.resolve"])) {
  throw new Error(`unexpected resolve actions: ${JSON.stringify(resolvePolicy.actions)}`)
}
for (const [name, value] of Object.entries(expectedMaterializationLimits)) {
  if (resolvePolicy.limits?.[name] !== value) {
    throw new Error(`unexpected resolve statement limit ${name}: ${resolvePolicy.limits?.[name]}`)
  }
}
for (const field of [
  "manifest",
  "contentDigest",
  "workspace_outputs",
  "workspaceOutputs",
  "sharedSpool",
  "spool",
]) {
  if (Object.hasOwn(policyDoc, field) ||
      [capturePolicy, artifactPolicy].some((statement) =>
        Object.hasOwn(statement, field) || Object.hasOwn(statement.limits ?? {}, field))) {
    throw new Error(`legacy or unsupported handoff policy field is present: ${field}`)
  }
}
// The Hermes endpoint client also accepts https:// URLs; this check intentionally
// exercises the local broker UDS topology configured by the Nix module.

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

const control = async (route, payload) => {
  const response = await request(
    process.env.GONDOLIN_EFFECT_CONTROL_SOCKET,
    route,
    "POST",
    payload,
  )
  const body = JSON.parse(response.body)
  return { ...response, body }
}

const executionHealth = await request(process.env.GONDOLIN_EFFECT_SOCKET, "/v1/health")
const controlHealth = await request(process.env.GONDOLIN_EFFECT_CONTROL_SOCKET, "/v1/health")
if (executionHealth.status !== 200 || JSON.parse(executionHealth.body).plane !== "execution") {
  throw new Error("execution health response is not ok")
}
if (controlHealth.status !== 200 || JSON.parse(controlHealth.body).plane !== "control") {
  throw new Error("control health response is not ok")
}

// Exercise the packaged broker process, not an in-memory service harness.
const proactiveKey = "nix-proactive-access-check"
const publicCapability = (host) => ({
  version: 1,
  kind: "network-origin",
  scheme: "https",
  host,
  ports: [443],
  addressMode: "public",
})
const dynamicAccess = await control("/v1/control/access/prepare", {
  environmentKey: proactiveKey,
  capabilities: [publicCapability("1.1.1.1")],
  requestedScope: "task",
})
if (dynamicAccess.status !== 200 || dynamicAccess.body.state !== "pending") {
  throw new Error(`proactive public access was not prepared for approval: ${JSON.stringify(dynamicAccess)}`)
}
const proactiveAuthority = await control("/v1/control/authority/status", {
  environmentKey: proactiveKey,
})
if (
  proactiveAuthority.status !== 200 ||
  proactiveAuthority.body.profile !== "hermes-qa" ||
  proactiveAuthority.body.executor !== policyDoc.defaultExecutor ||
  proactiveAuthority.body.authorityClass !== policyDoc.defaultAuthorityClass ||
  proactiveAuthority.body.policyDigest !== policyDoc.policyDigest ||
  Object.hasOwn(proactiveAuthority.body, "generation")
) {
  throw new Error(`proactive preparation created an invalid authority or VM: ${JSON.stringify(proactiveAuthority)}`)
}

const approved = await control("/v1/control/access/decide", {
  requestId: dynamicAccess.body.requestId,
  decision: "approve",
  scope: "task",
  principal: "paired-user",
})
if (approved.status !== 200 || approved.body.state !== "approved" || approved.body.grantIds.length !== 1) {
  throw new Error(`dynamic public access was not activated: ${JSON.stringify(approved)}`)
}
const grantId = approved.body.grantIds[0]
const listed = await control("/v1/control/grants/list", { environmentKey: proactiveKey })
if (
  listed.status !== 200 ||
  listed.body.length !== 1 ||
  listed.body[0].grantId !== grantId ||
  listed.body[0].state !== "active"
) {
  throw new Error(`active task grant was not isolated and listable: ${JSON.stringify(listed)}`)
}

const isolatedKey = "nix-isolated-access-check"
const isolated = await control("/v1/control/access/prepare", {
  environmentKey: isolatedKey,
  capabilities: [publicCapability("1.1.1.1")],
  requestedScope: "task",
})
if (isolated.status !== 200 || isolated.body.state !== "pending") {
  throw new Error(`another authority inherited a task grant: ${JSON.stringify(isolated)}`)
}
const denied = await control("/v1/control/access/decide", {
  requestId: isolated.body.requestId,
  decision: "deny",
  principal: "paired-user",
})
if (denied.status !== 200 || denied.body.state !== "denied") {
  throw new Error(`access denial was not recorded: ${JSON.stringify(denied)}`)
}
const suppressed = await control("/v1/control/access/prepare", {
  environmentKey: isolatedKey,
  capabilities: [publicCapability("1.1.1.1")],
  requestedScope: "task",
})
if (suppressed.status < 400 || suppressed.body.reason !== "approval.request_suppressed") {
  throw new Error(`denial cooldown did not suppress a duplicate request: ${JSON.stringify(suppressed)}`)
}

const privateAccess = await control("/v1/control/access/prepare", {
  environmentKey: "nix-private-access-check",
  capabilities: [{
    version: 1,
    kind: "network-origin",
    scheme: "http",
    host: "172.27.50.17",
    ports: [22],
    addressMode: "pinned-private",
  }],
  requestedScope: "task",
})
if (
  privateAccess.status !== 200 ||
  privateAccess.body.state !== "pending" ||
  JSON.stringify(privateAccess.body.capabilities[0].pinnedAddresses) !== JSON.stringify(["172.27.50.17"])
) {
  throw new Error(`private access was not pinned for explicit approval: ${JSON.stringify(privateAccess)}`)
}
await control("/v1/control/access/decide", {
  requestId: privateAccess.body.requestId,
  decision: "deny",
  principal: "paired-user",
})

const revoked = await control("/v1/control/grants/revoke", {
  grantId,
  principal: "paired-user",
})
if (revoked.status !== 200 || revoked.body.state !== "revoked") {
  throw new Error(`live grant revocation failed: ${JSON.stringify(revoked)}`)
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
const conversationKey = "nix-conversation-check"
const acquired = await request(
  process.env.GONDOLIN_EFFECT_CONTROL_SOCKET,
  "/v1/control/workspaces/acquire",
  "POST",
  { environmentKey: conversationKey },
)
if (acquired.status !== 200) {
  throw new Error(`conversation workspace acquisition failed: ${acquired.status} ${acquired.body}`)
}
const acquiredBody = JSON.parse(acquired.body)
const bound = await request(
  process.env.GONDOLIN_EFFECT_CONTROL_SOCKET,
  "/v1/control/authority/bind",
  "POST",
  {
    environmentKey: conversationKey,
    authorityClass: "default",
    workspaceId: acquiredBody.workspace.workspaceId,
    workspaceLeaseId: acquiredBody.lease.leaseId,
  },
)
if (bound.status !== 200) {
  throw new Error(`conversation authority binding failed: ${bound.status} ${bound.body}`)
}
const authority = await request(
  process.env.GONDOLIN_EFFECT_CONTROL_SOCKET,
  "/v1/control/authority/status",
  "POST",
  { environmentKey: conversationKey },
)
if (authority.status !== 200) {
  throw new Error(`conversation authority status failed: ${authority.status} ${authority.body}`)
}
const authorityBody = JSON.parse(authority.body)
if (
  authorityBody.authorityClass !== "default" ||
  authorityBody.workspaceId !== acquiredBody.workspace.workspaceId ||
  authorityBody.workspaceLeaseId !== acquiredBody.lease.leaseId
) {
  throw new Error(`conversation authority does not match its acquired workspace: ${authority.body}`)
}
const handoffRoutes = [
  "/v1/control/workspace-handoffs/capture",
  "/v1/control/workspace-handoffs/artifacts/read",
  "/v1/control/project-sources/resolve",
  "/v1/control/project-workspaces/results/read",
]
for (const route of handoffRoutes) {
  const response = await request(process.env.GONDOLIN_EFFECT_CONTROL_SOCKET, route, "POST", {})
  if (response.status !== 400) throw new Error(`handoff route is missing or accepted an invalid request: ${route}`)
}

// Every newly activated broker workspace exposes the three-plane layout.
import path from "node:path"
const workspaceDataRoot = path.join(
  process.env.GONDOLIN_EFFECT_STATE_DIR,
  "workspaces",
  "data",
  acquiredBody.workspace.workspaceId,
)
for (const plane of ["work", "inputs", "output"]) {
  if (!fs.statSync(path.join(workspaceDataRoot, plane)).isDirectory()) {
    throw new Error(`workspace is missing the ${plane} plane`)
  }
}
if (
  fs.readFileSync(path.join(workspaceDataRoot, ".broker-workspace-layout"), "utf8") !==
  "three-plane:v1"
) {
  throw new Error("workspace layout marker is missing or stale")
}

// A broker-project activation without a ready materialization is rejected
// before any sandbox authority is published.
const projectKey = "nix-project-check"
const projectAcquire = await request(
  process.env.GONDOLIN_EFFECT_CONTROL_SOCKET,
  "/v1/control/workspaces/acquire",
  "POST",
  { environmentKey: projectKey },
)
if (projectAcquire.status !== 200) {
  throw new Error(`project workspace acquisition failed: ${projectAcquire.status} ${projectAcquire.body}`)
}
const projectAcquireBody = JSON.parse(projectAcquire.body)
const zeroRevision = "0".repeat(64)
const activateWithoutMaterialization = await request(
  process.env.GONDOLIN_EFFECT_CONTROL_SOCKET,
  "/v1/control/task-runs/activate",
  "POST",
  {
    environmentKey: projectKey,
    taskId: "b4:task:t1:1",
    runId: "b4:task:t1:1:r1",
    workspaceId: projectAcquireBody.workspace.workspaceId,
    workspaceLeaseId: projectAcquireBody.lease.leaseId,
    catalogueRevision: zeroRevision,
    lane: "codex",
    laneRevision: zeroRevision,
    permission: "workspace-write",
    workspaceProvider: "broker-project",
    authorityClass: "codex",
    policyRevision: zeroRevision,
    project: "homelab",
    projectRevision: zeroRevision,
    sourceGeneration: zeroRevision,
  },
)
if (activateWithoutMaterialization.status !== 409) {
  throw new Error(
    `broker-project activation without a ready materialization was not rejected: ${activateWithoutMaterialization.status} ${activateWithoutMaterialization.body}`,
  )
}
const scratchWithProject = await request(
  process.env.GONDOLIN_EFFECT_CONTROL_SOCKET,
  "/v1/control/task-runs/activate",
  "POST",
  {
    environmentKey: conversationKey,
    taskId: "b4:task:t1:2",
    runId: "b4:task:t1:2:r1",
    workspaceId: acquiredBody.workspace.workspaceId,
    workspaceLeaseId: acquiredBody.lease.leaseId,
    catalogueRevision: zeroRevision,
    lane: "research",
    laneRevision: zeroRevision,
    permission: "workspace-write",
    workspaceProvider: "broker-scratch",
    authorityClass: "default",
    policyRevision: zeroRevision,
    project: "homelab",
    projectRevision: zeroRevision,
    sourceGeneration: zeroRevision,
  },
)
if (scratchWithProject.status !== 409) {
  throw new Error(
    `scratch activation carrying Project authority was not rejected: ${scratchWithProject.status} ${scratchWithProject.body}`,
  )
}
const unknownSource = await request(
  process.env.GONDOLIN_EFFECT_CONTROL_SOCKET,
  "/v1/control/project-sources/resolve",
  "POST",
  {
    repositoryId: "missing",
    project: "homelab",
    projectRevision: zeroRevision,
    sourceRevision: zeroRevision,
  },
)
if (unknownSource.status !== 404) {
  throw new Error(
    `unknown Project source was not rejected: ${unknownSource.status} ${unknownSource.body}`,
  )
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
