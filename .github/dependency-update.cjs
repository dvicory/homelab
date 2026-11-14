// Self-hosted Renovate; only source owners, never generated flake/manifests or release receipts.
// Run locally: RENOVATE_CONFIG_FILE=$PWD/.github/dependency-update.cjs renovate --platform=local
const path = require('node:path');
const owner = 'modules/den/aspects/kubernetes/services/';
const nixSources = '/^modules/(meta|den|flake)/.*\\.nix$/';
const owners = '/^modules\/den\/aspects\/(kubernetes\/services|workloads)\/.*\\.nix$/';
const value = '(?<currentValue>[A-Za-z0-9][A-Za-z0-9_.+-]*)';
const digest = '(?<currentDigest>sha256:[a-f0-9]{64})';
const immutableSourcePrerequisite = 'Immutable SHA pins have no authorized tracking branch: automatic replacement is disabled. The source owner must choose a branch URL (flake.lock still pins the exact commit) or a supported release-tag policy; remote HEAD and ancestry alone do not establish branch authority.';
const customManagers = [];
function manager(files, match, datasource, extra = {}) {
  customManagers.push({ customType: 'regex', managerFilePatterns: [files],
    matchStrings: [match], datasourceTemplate: datasource, ...extra });
}
function image(file, prefix, name, suffix = '') {
  manager(`/^${owner.replaceAll('/', '\\/')}${file.replaceAll('.', '\\.')}$/`,
    prefix + '"' + value + '(?:@' + digest + ')?"' + suffix, 'docker',
    { depNameTemplate: name, versioningTemplate: 'docker' });
}
// Root/channel and floating/branch inputs are refreshed by `nix flake update` in the other job.
// Keep immutable pins mapped, but never interpret an arbitrary SHA as permission to track HEAD.
// git-refs resolves refs without ancestry checks. A postUpgradeTasks failure is only an
// artifact error: Renovate can still publish the original replacement, so reject at lookup.
manager(nixSources, '"github:(?<depName>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(?<currentDigest>[a-f0-9]{40})"',
  'git-refs', { packageNameTemplate: 'https://github.com/{{{depName}}}', currentValueTemplate: 'HEAD',
    depTypeTemplate: 'immutable-source' });
manager(nixSources, '"github:(?<depName>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(?<currentValue>v?[0-9]+\\.[^"/]+)"',
  'github-tags', { versioningTemplate: 'semver-coerced' });
// Full registry references, including the mutable Hermes defaults: propose digest pins, not deployment.
manager(owners, '"(?<depName>(?:docker\\.io|ghcr\\.io|quay\\.io|registry\\.k8s\\.io)/[^":\\s]+):' + value + '(?:@' + digest + ')?"',
  'docker', { versioningTemplate: 'docker',
    autoReplaceStringTemplate: '"{{{depName}}}:{{{newValue}}}{{#if newDigest}}@{{{newDigest}}}{{/if}}"' });
// Literal Nix image attribute sets; no evaluation or generated Kubernetes YAML is needed.
manager(owners, 'repository = "(?<depName>(?:docker\\.io|ghcr\\.io|quay\\.io|registry\\.k8s\\.io)/[^"\\s]+)";\\s+tag = "' + value + '";\\s+digest = "' + digest + '";',
  'docker', { versioningTemplate: 'docker' });
manager(owners, 'repository = "(?<depName>[^"\\s]+)";\\s+tag = "' + value + '@' + digest + '";',
  'docker', { versioningTemplate: 'docker' });
// Chart-specific registry/sha conventions remain in the owner, not a parallel image manifest.
manager(`/^${owner}monitoring/default\\.nix$/`,
  'registry = "(?<registry>[^"\\s]+)";\\s+repository = "(?<repository>[^"\\s]+)";\\s+tag = "' + value + '";\\s+sha = "' + digest + '";',
  'docker', { depNameTemplate: '{{{registry}}}/{{{repository}}}', versioningTemplate: 'docker' });
manager(`/^${owner}monitoring/default\\.nix$/`,
  'registry = "(?<registry>[^"\\s]+)";\\s+repository = "(?<repository>[^"\\s]+)";\\s+tag = "' + value + '";\\s+digest = "' + digest + '";',
  'docker', { depNameTemplate: '{{{registry}}}/{{{repository}}}', versioningTemplate: 'docker' });
image('argocd.nix', 'global\\.image\\.tag = ', 'quay.io/argoproj/argocd');
image('argocd.nix', 'redis\\.image\\.tag = ', 'docker.io/library/redis');
// One shared version: Renovate updates controller/version atomically, and the hook
// refreshes webhook, cainjector, acmesolver and startupapicheck at that same version.
manager(`/^${owner}cert-manager\\.nix$/`,
  'version = "' + value + '";[\\s\\S]*?image "quay\\.io/jetstack/cert-manager-controller" "' + digest + '"',
  'docker', { depNameTemplate: 'quay.io/jetstack/cert-manager-controller', versioningTemplate: 'docker' });
// Reviewed Jellyfin runtime/source/helper releases need a complete coupled owner update.
manager('/^pkgs/by-name/jellyfin-provisioner-image/package\\.nix$/',
  'runtimeImage = "(?<depName>docker\\.io/jellyfin/jellyfin):' + value + '";\\s+runtimeDigest = "' + digest + '";',
  'docker', { versioningTemplate: 'docker' });
// nixhelm-owned charts (charts.*) update with the nixhelm source pin above.
// These three charts are locally owned and carry recursive hashes of Helm's unpacked output.
manager(`/^${owner}retained-storage\\.nix$/`, 'chartVersion = "' + value + '";', 'docker',
  { depNameTemplate: 'ghcr.io/rancher/local-path-provisioner/charts/local-path-provisioner', depTypeTemplate: 'helm-chart', versioningTemplate: 'semver' });
manager(`/^${owner}monitoring/dashboards\\.nix$/`,
  'repo = "oci://ghcr\\.io/grafana-community/helm-charts";\\s+chart = "grafana";\\s+version = "' + value + '";',
  'docker', { depNameTemplate: 'ghcr.io/grafana-community/helm-charts/grafana', depTypeTemplate: 'helm-chart', versioningTemplate: 'semver' });
manager(`/^${owner}monitoring/default\\.nix$/`,
  'repo = "(?<registryUrl>https://prometheus-community\\.github\\.io/helm-charts)";\\s+chart = "(?<depName>kube-state-metrics)";\\s+version = "' + value + '";',
  'helm', { depTypeTemplate: 'helm-chart' });

module.exports = {
  platform: 'github',
  // Renovate is a read-only resolver/postprocessor, never the publisher.
  dryRun: 'full',
  branchPrefix: 'dependency-update/renovate/',
  branchPrefixOld: 'dependency-update/renovate/',
  username: 'github-actions[bot]',
  gitAuthor: 'github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>',
  onboarding: false,
  requireConfig: 'ignored',
  enabledManagers: ['custom.regex'],
  customManagers,
  dependencyDashboard: false,
  vulnerabilityAlerts: { enabled: false },
  labels: [],
  prHourlyLimit: 2,
  prConcurrentLimit: 5,
  automerge: false,
  platformAutomerge: false,
  binarySource: 'global',
  exposeAllEnv: false,
  // Fixed trusted command; dependency names/tags are data, never rendered shell.
  allowedCommands: ['^python3 ' + path.join(__dirname, 'dependency-update.py').replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + ' --prepare-declaration$'],
  postUpgradeTasks: {
    commands: ['python3 ' + path.join(__dirname, 'dependency-update.py') + ' --prepare-declaration'],
    dataFileTemplate: '{{{toJSON (toObject "branch" branchName "base" baseBranch)}}}',
    // The hook exports independently only after success. Upstream catches hook errors
    // and otherwise harvests files anyway, so it must never collect candidate files.
    fileFilters: [],
    executionMode: 'branch',
  },
  packageRules: [
    { matchDepTypes: ['immutable-source'], enabled: false, description: immutableSourcePrerequisite },
    { matchDatasources: ['docker'], pinDigests: true },
    { matchDepTypes: ['helm-chart'], pinDigests: false },
    { matchPackageNames: ['ghcr.io/linuxserver/*'],
      versioning: 'regex:^(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)(?:\\.(?<build>\\d+))?-ls(?<revision>\\d+)$' },
    { matchPackageNames: ['docker.io/envoyproxy/envoy'],
      versioning: 'regex:^(?<compatibility>distroless)-v(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)$' },
    { matchPackageNames: ['docker.io/nikolaik/python-nodejs'],
      versioning: 'regex:^python(?<major>\\d+)\\.(?<minor>\\d+)-nodejs(?<patch>\\d+)$' },
    { matchPackageNames: ['docker.io/jellyfin/jellyfin'], enabled: false,
      description: 'Jellyfin is a coupled reviewed release. Reconcile source/hash, provision patch, k8s assertion and verified helper-release selection manually before canonical generation. Incomplete draft candidates are not exported; verified receipts are never rewritten.' },
  ],
};
