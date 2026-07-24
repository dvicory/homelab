import fs from "node:fs"
import { pathToFileURL } from "node:url"

const brokerLib = process.env.HERMES_GONDOLIN_BROKER_LIB
if (!brokerLib) throw new Error("HERMES_GONDOLIN_BROKER_LIB is required")

const { parsePolicy, composePolicy } = await import(
  pathToFileURL(`${brokerLib}/policy.js`).href
)
const { resolveAssetBuildIds } = await import(
  pathToFileURL(`${brokerLib}/config.js`).href
)

const raw = JSON.parse(fs.readFileSync(process.env.POLICY_JSON, "utf8"))
if ("workspaceRevisionLimits" in raw.floor) {
  throw new Error("Effect-only workspace revision limits leaked into the legacy policy floor")
}
const policy = resolveAssetBuildIds(parsePolicy(raw))

const checks = [
  [{ profile: "hermes-qa" }, "general", "project"],
  [{ profile: "hermes-qa", template: "research" }, "general", "research"],
  [{ profile: "hermes-qa", template: "offline", asset: "general" }, "general", "offline"],
  [{ profile: "hermes-qa", template: "offline" }, "minimal", "offline"],
  [{ profile: "hermes-qa", worklane: "codex" }, "general", "project"],
  [{ profile: "hermes-qa", worklane: "codex", template: "offline" }, "minimal", "offline"],
]
for (const [request, asset, template] of checks) {
  const effective = composePolicy(policy, request)
  if (effective.assetName !== asset || effective.templateName !== template) {
    throw new Error(
      `compose ${JSON.stringify(request)} -> ${effective.assetName}/${effective.templateName}, want ${asset}/${template}`,
    )
  }
  if (typeof effective.policyHash !== "string" || effective.policyHash.length !== 64) {
    throw new Error("policyHash missing from effective policy")
  }
}

if (policy.floor.maxVms <= 0 || policy.floor.maxFrameBytes <= 0) {
  throw new Error("floor bounds missing")
}
for (const [name, bundle] of Object.entries(policy.bundles)) {
  for (const flag of ["allowWebSockets", "allowConnect", "allowRawTcp", "allowSsh"]) {
    if (bundle[flag]) throw new Error(`bundle ${name} lifts floor via ${flag}`)
  }
}

const text = fs.readFileSync(process.env.POLICY_JSON, "utf8")
for (const needle of ["ghp_", "github_pat_", "BEGIN PRIVATE", "BEGIN OPENSSH"]) {
  if (text.includes(needle)) throw new Error(`secret-like content in policy: ${needle}`)
}

console.log("policy golden: parse + compose + floor invariants OK")
