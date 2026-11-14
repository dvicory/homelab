# Behaviour test: the Kanidm provisioning Job against a real Kanidm and a real
# Kubernetes API.
#
# A K3s node runs the committed prod-home identity manifests: Kanidm, the
# provisioning ConfigMap, ServiceAccount, Roles and RoleBindings, and the
# client Secrets that GitOps declares without data. The Job runs as its own
# ServiceAccount, with only the generated RBAC. Test-local pieces are the
# Kanidm TLS certificate, its CA (the Job trusts it through SSL_CERT_FILE,
# because production trusts a public CA), and the recovered idm_admin
# password. identity-provision-runtime.py reads Kanidm without printing any
# credential.
#
# Registry-only A exercises the reviewed selected helper. Source B imports the
# actual current-source producer archive into the same disposable K3s node.
# It neither publishes an image nor changes production selection.
{
  config,
  lib,
  self,
  ...
}:
let
  cluster = config.den.clusters."prod-home";
  domain = builtins.head cluster.routes.idm.hostnames;
  compute =
    config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
  inherit (compute) instance;
  stateDir = compute.retainedPaths.identity-kanidm.guestPath;
  argocdCallbacks = map (
    hostname: "https://${hostname}/auth/callback"
  ) cluster.routes.argocd.hostnames;
  gatewayCallbacks = map (
    hostname: "https://${hostname}/oauth2/callback"
  ) cluster.routes.argocd.hostnames;
  manifests = ../../generated/manifests/prod-home;
  k3sPackage = self.nixosConfigurations.${instance}.config.services.k3s.package;
  identityAspect =
    (import ../den/aspects/kubernetes/services/identity.nix {
      inherit config lib;
      inputs.self = self;
    }).den.aspects.kubernetes.services.identity;
  renderIdentity =
    inventory:
    (identityAspect.k8s-manifests {
      cluster = inventory;
      inherit lib;
      computeResources = compute;
    }).applications.identity.objects;
  identityObjects = renderIdentity cluster;
  rolloutDirectoryPort =
    if cluster.settings.kubernetes.services.identity.directory.port == 3637 then 3638 else 3637;
  rolloutObjects = renderIdentity (
    lib.recursiveUpdate cluster {
      settings.kubernetes.services.identity.directory.port = rolloutDirectoryPort;
    }
  );
  # Synthetic native application input only: no application aspect or route.
  fixtureObjects =
    group: scopes: publicClient:
    map (
      object:
      if object.kind == "ConfigMap" && object.metadata.name == "kanidm-provision" then
        let
          state = builtins.fromJSON object.data."state.json";
          clients = builtins.fromJSON object.data."clients.json";
        in
        object
        // {
          data = object.data // {
            "state.json" = builtins.toJSON (
              lib.recursiveUpdate state {
                groups.${group} = {
                  members = [ ];
                  overwriteMembers = false;
                };
                systems.oauth2 = {
                  fixture-native = {
                    displayName = "Synthetic native application";
                    public = false;
                    originUrl = [ "https://native.example.test/callback" ];
                    originLanding = "https://native.example.test/";
                    allowInsecureClientDisablePkce = false;
                    preferShortUsername = true;
                    scopeMaps = { };
                    supplementaryScopeMaps = { };
                    removeOrphanedClaimMaps = true;
                  };
                }
                // lib.optionalAttrs publicClient {
                  fixture-native-public = {
                    displayName = "Synthetic public native application";
                    public = true;
                    originUrl = [ "https://public-native.example.test/callback" ];
                    originLanding = "https://public-native.example.test/";
                    allowInsecureClientDisablePkce = false;
                    preferShortUsername = true;
                    scopeMaps = { };
                    supplementaryScopeMaps = { };
                    removeOrphanedClaimMaps = true;
                  };
                };
              }
            );
            "clients.json" = builtins.toJSON (
              clients
              ++ [
                {
                  name = "fixture-native";
                  eligibleGroup = group;
                  inherit scopes;
                  secrets = [
                    {
                      namespace = "identity";
                      name = "fixture-native-oidc";
                      key = "clientSecret";
                    }
                  ];
                }
              ]
              ++ lib.optional publicClient {
                name = "fixture-native-public";
                public = true;
                eligibleGroup = group;
                inherit scopes;
                secrets = [ ];
              }
            );
          };
        }
      else
        object
    ) identityObjects
    # Reuse the renderer's name-scoped publication resources for the fixture.
    ++
      map
        (
          object:
          object
          // {
            metadata = {
              namespace = "identity";
              name =
                if object.kind == "Secret" then
                  "fixture-native-oidc"
                else
                  "kanidm-client-secret-fixture-native-oidc";
            };
          }
          // lib.optionalAttrs (object.kind == "Role") {
            rules = map (rule: rule // { resourceNames = [ "fixture-native-oidc" ]; }) object.rules;
          }
          // lib.optionalAttrs (object.kind == "RoleBinding") {
            roleRef = object.roleRef // {
              name = "kanidm-client-secret-fixture-native-oidc";
            };
          }
        )
        (
          lib.filter (
            object:
            object.metadata.namespace == "argocd"
            && builtins.elem object.metadata.name [
              "argocd-kanidm-oidc"
              "kanidm-client-secret-argocd-kanidm-oidc"
            ]
          ) identityObjects
        );
in
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        manifestSet =
          name: objects:
          pkgs.linkFarm name (
            map (object: {
              name = "${object.kind}-${object.metadata.name}.yaml";
              path = pkgs.writeText "${object.kind}-${object.metadata.name}.json" (builtins.toJSON object);
            }) objects
          );
        sourceManifests = manifestSet "identity-source-b-manifests" identityObjects;
        rolloutManifests = manifestSet "identity-config-rollout-manifests" (
          lib.filter (
            object:
            builtins.elem object.kind [
              "Deployment"
              "Service"
            ]
            || (object.kind == "ConfigMap" && object.data ? "server.toml")
          ) rolloutObjects
        );
        privateManifests = manifestSet "identity-private-b-manifests" (
          fixtureObjects "fixture-native-users" [
            "openid"
            "profile"
            "email"
          ] false
        );
        publicManifests = manifestSet "identity-public-b-manifests" (
          fixtureObjects "fixture-native-users" [
            "openid"
            "profile"
            "email"
          ] true
        );
        replacementManifests = manifestSet "identity-private-b-replacement-manifests" (
          fixtureObjects "fixture-native-replacement" [
            "openid"
            "profile"
          ] false
        );
        imageB = self.packages.${system}.kanidm-provision-image;
        # Test-only: trust the test CA. Everything else is the committed Job.
        trustJob = pkgs.writeText "trust-test-ca.jq" ''
          .spec.template.spec.containers[0].env += [{name: "SSL_CERT_FILE", value: "/test-trust/ca.crt"}]
          | .spec.template.spec.containers[0].volumeMounts += [{name: "test-trust", mountPath: "/test-trust", readOnly: true}]
          | .spec.template.spec.volumes += [{name: "test-trust", configMap: {name: "test-trust"}}]
        '';
        leafExtensions = pkgs.writeText "kanidm-leaf.ext" ''
          basicConstraints = CA:FALSE
          keyUsage = critical, digitalSignature
          extendedKeyUsage = serverAuth
          subjectKeyIdentifier = hash
          authorityKeyIdentifier = keyid
          subjectAltName = DNS:${domain}, DNS:kanidm.identity.svc.cluster.local
        '';
        test =
          (pkgs.testers.runNixOSTest {
            name = "identity-provision-runtime";
            requiredFeatures.kvm = true;
            nodes.cluster =
              { pkgs, ... }:
              {
                networking.hostName = lib.mkForce instance;
                networking.firewall.enable = false;
                # The probe reaches Kanidm through a port-forward on loopback.
                networking.hosts."127.0.0.1" = [ domain ];
                environment.systemPackages = [
                  pkgs.curl
                  pkgs.jq
                  pkgs.openssl
                  pkgs.python3
                ];
                systemd.tmpfiles.rules = [ "d ${stateDir} 0700 1000 1000 -" ];
                virtualisation = {
                  cores = 4;
                  memorySize = 4096;
                  diskSize = 8192;
                  restrictNetwork = false;
                  vlans = [ ];
                };
                services.k3s = {
                  enable = true;
                  role = "server";
                  package = k3sPackage;
                  disable = [ "traefik" ];
                  images = [
                    k3sPackage.airgap-images
                  ];
                };
              };
            testScript = ''
              import json
              import shlex
              import time
              import hashlib
              import tarfile

              kubectl = "${k3sPackage}/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml"
              identity = "${manifests}/identity"
              callbacks = sorted(json.loads(${builtins.toJSON (builtins.toJSON argocdCallbacks)}))
              gateway_callbacks = sorted(json.loads(${builtins.toJSON (builtins.toJSON gatewayCallbacks)}))
              provisioner = "system:serviceaccount:identity:kanidm-provision"
              private_identity = "${privateManifests}"
              replacement_identity = "${replacementManifests}"
              public_identity = "${publicManifests}"
              source_identity = "${sourceManifests}"
              archive_reference = "${imageB.imageReference}"

              def evidence(label, value):
                  print(f"EVIDENCE {label} {json.dumps(value, sort_keys=True)}")

              def probe(command, **arguments):
                  return json.loads(cluster.succeed(
                      f"python3 ${./identity-provision-runtime.py} ${domain} {shlex.quote(kubectl)} "
                      f"{command} {shlex.quote(json.dumps(arguments))}"
                  ))

              def argo_apply(path):
                  # Argo CD applies the identity Application with ServerSideApply=true.
                  cluster.succeed(
                      f"{kubectl} apply --server-side --field-manager=argocd-controller --force-conflicts -f {path}"
                  )

              def secret(namespace, name):
                  return json.loads(cluster.succeed(
                      f"{kubectl} get secret --namespace {namespace} {name} --output json"
                  ))

              def digests():
                  # Hashes of the published values, for equality checks only.
                  return {
                      spec["name"]: cluster.succeed(
                          f"{kubectl} get secret --namespace {spec['namespace']} {spec['name']} --output json "
                          f"| jq -er --arg key {spec['key']} '.data[$key]' | sha256sum"
                      ).split()[0]
                      for _, spec in secrets
                  }

              def managers(namespace, name):
                  found = json.loads(cluster.succeed(
                      f"{kubectl} get secret --namespace {namespace} {name} --show-managed-fields --output json"
                  ))
                  return {
                      entry["manager"]: json.dumps(entry.get("fieldsV1", {}))
                      for entry in found["metadata"].get("managedFields", [])
                  }

              def assert_published():
                  for client, spec in secrets:
                      published = secret(spec["namespace"], spec["name"])
                      keys = sorted(published.get("data", {}))
                      assert keys == [spec["key"]], (client, keys)
                      assert published["type"] == "Opaque", (client, published["type"])
                      assert probe("secret-matches", client=client, namespace=spec["namespace"],
                                   name=spec["name"], key=spec["key"]) is True, f"{client} Secret differs from Kanidm"
                  labels = secret("argocd", "argocd-kanidm-oidc")["metadata"].get("labels", {})
                  assert labels.get("app.kubernetes.io/part-of") == "argocd", labels

              def assert_kanidm(members):
                  state = probe("state", clients=clients)
                  evidence("kanidm-state", state)
                  assert state["members"] == members, state["members"]
                  assert state["credential_type_minimum"] == ["mfa"], state["credential_type_minimum"]
                  assert state["registered"] == clients, state["registered"]
                  for client in clients:
                      found = state["clients"][client]
                      assert found["scope_maps"] == {eligibility[client]: scopes[client]}, (client, found)
                      assert found["sup_scope_maps"] == [], (client, found)
                      assert found["strict_redirect"] == ["true"], (client, found)
                  assert state["clients"]["argocd"]["redirects"] == sorted(gateway_callbacks + callbacks), state["clients"]["argocd"]

              last_job_execution = {}

              def run_job(expect):
                  cluster.succeed(f"{kubectl} delete job --namespace identity kanidm-provision --ignore-not-found --wait")
                  job = json.loads(cluster.succeed(f"{kubectl} apply -f /root/job.json --output json"))
                  uid = job["metadata"]["uid"]
                  image = next(c["image"] for c in job["spec"]["template"]["spec"]["containers"] if c["name"] == "provision")
                  last_job_execution.clear()
                  attempts, observed = [], set()
                  deadline = time.monotonic() + 720
                  while time.monotonic() < deadline:
                      job = json.loads(cluster.succeed(
                          f"{kubectl} get job --namespace identity kanidm-provision --output json"
                      ))
                      assert job["metadata"]["uid"] == uid, "owned Job was replaced"
                      pods = json.loads(cluster.succeed(
                          f"{kubectl} get pods --namespace identity -l job-name=kanidm-provision --output json"
                      ))["items"]
                      pods = [pod for pod in pods if any(
                          owner.get("controller") and owner["kind"] == "Job" and owner["uid"] == uid
                          for owner in pod["metadata"].get("ownerReferences", [])
                      )]
                      refused = []
                      for pod in pods:
                          container = next(c for c in pod["spec"]["containers"] if c["name"] == "provision")
                          assert container["image"] == image, container
                          for status in pod["status"].get("containerStatuses", []):
                              if status["name"] != "provision":
                                  continue
                              for slot in ("state", "lastState"):
                                  terminated = status.get(slot, {}).get("terminated")
                                  if not terminated or terminated["exitCode"] == 0:
                                      continue
                                  if expect == "Failed":
                                      assert terminated["exitCode"] not in (126, 127), terminated
                                      assert terminated.get("reason") != "OOMKilled" and not terminated.get("signal"), terminated
                                  if terminated["exitCode"] == 1:
                                      refused.append(dict(pod_uid=pod["metadata"]["uid"], **terminated))
                                  if terminated["containerID"] not in observed:
                                      observed.add(terminated["containerID"])
                                      code, output = cluster.execute(
                                          f"{kubectl} logs --namespace identity {pod['metadata']['name']} "
                                          "--container provision --tail=5 "
                                          + ("--previous" if slot == "lastState" else "")
                                      )
                                      if code == 0 and output.strip():
                                          attempts.append(output.strip())
                      ended = {c["type"] for c in job.get("status", {}).get("conditions", []) if c["status"] == "True"}
                      if expect == "Failed" and refused:
                          # Observe the owned helper's actual refusal, not the
                          # controller's exponential retry-budget exhaustion.
                          last_job_execution.update(uid=uid, pods=pods)
                          evidence("owned-helper-refusal", dict(job_uid=uid, executions=refused))
                          cluster.succeed(
                              f"{kubectl} delete job --namespace identity kanidm-provision "
                              "--cascade=foreground --wait --timeout=120s"
                          )
                          return "\n".join(attempts)
                      if ended & {"Complete", "Failed"}:
                          assert expect == "Complete" and "Complete" in ended, (expect, ended)
                          last_job_execution.update(uid=uid, pods=pods)
                          evidence("job-complete-failed-attempts", [a.splitlines() for a in attempts])
                          return "\n".join(attempts)
                      time.sleep(5)
                  raise AssertionError(f"Job did not reach {expect}")

              start_all()
              cluster.wait_until_succeeds(f"{kubectl} get --raw=/readyz", timeout=300)

              # Platform pieces production supplies outside the identity Application.
              cluster.succeed(f"{kubectl} apply -f ${manifests}/identity-retained")
              cluster.succeed(f"{kubectl} create namespace gateway")
              cluster.succeed(f"{kubectl} create namespace argocd")
              cluster.succeed(f"{kubectl} apply -f ${manifests}/homarr-retained/Namespace-portal.yaml")
              cluster.succeed(
                  "umask 077 && mkdir -p /root/pki && cd /root/pki && "
                  "openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 "
                  "-subj /CN=identity-test-ca -addext basicConstraints=critical,CA:TRUE "
                  "-addext keyUsage=critical,keyCertSign,cRLSign -keyout ca.key -out ca.crt && "
                  "openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes "
                  "-subj /CN=${domain} -keyout tls.key -out tls.csr && "
                  "openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 2 "
                  "-extfile ${leafExtensions} -out leaf.crt && cat leaf.crt ca.crt > tls.crt"
              )
              cluster.succeed(
                  f"{kubectl} create secret tls kanidm-tls --namespace identity "
                  "--cert=/root/pki/tls.crt --key=/root/pki/tls.key"
              )
              cluster.succeed(
                  f"{kubectl} create configmap test-trust --namespace identity --from-file=ca.crt=/root/pki/ca.crt"
              )
              cluster.wait_until_succeeds(
                  f"{kubectl} rollout status deployment/coredns --namespace kube-system --timeout=10s", timeout=300
              )
              cluster.succeed(f"{kubectl} apply -f ${manifests}/cluster-dns/ConfigMap-coredns-custom.yaml")
              cluster.succeed(f"{kubectl} rollout restart deployment/coredns --namespace kube-system")

              # The identity Application, except its PostSync Job.
              for path in cluster.succeed(f"ls {identity}").split():
                  if path != "Job-kanidm-provision.yaml":
                      argo_apply(f"{identity}/{path}")
              cluster.wait_until_succeeds(
                  f"{kubectl} rollout status deployment/kanidm --namespace identity --timeout=10s", timeout=900
              )

              # First-ever bootstrap: recover idm_admin, as the operator does.
              cluster.succeed(
                  f"umask 077 && {kubectl} exec --namespace identity deployment/kanidm -- "
                  "/sbin/kanidmd scripting recover-account idm_admin -c /etc/kanidm/server.toml 2>/dev/null "
                  "| jq -Rr 'fromjson? | select(.status == \"ok\") | .output' > /root/idm-admin-password && "
                  "test -s /root/idm-admin-password"
              )
              cluster.succeed(
                  f"{kubectl} create secret generic kanidm-provision --namespace identity "
                  "--from-file=idm-admin-password=/root/idm-admin-password"
              )
              cluster.succeed(
                  "systemd-run --unit=kanidm-forward --property=Restart=always "
                  f"{kubectl} port-forward --address 127.0.0.1 --namespace identity service/kanidm 443:443"
              )
              cluster.wait_until_succeeds("curl -sSf --cacert /root/pki/ca.crt https://${domain}/status", timeout=120)
              cluster.succeed(
                  f"{kubectl} create --dry-run=client --output json -f {identity}/Job-kanidm-provision.yaml "
                  "| jq -f ${trustJob} > /root/job.json"
              )
              members = sorted(json.loads(json.loads(cluster.succeed(
                  f"{kubectl} get configmap --namespace identity kanidm-provision --output json"
              ))["data"]["members.json"]))
              assert members, "the committed state declares no administrators"
              # One client per administrator route, as the committed manifests
              # declare. Argo CD's Gateway sign-in and its own sign-in share
              # client argocd, which publishes to both of its Secrets.
              declared = json.loads(json.loads(cluster.succeed(
                  f"{kubectl} get configmap --namespace identity kanidm-provision --output json"
              ))["data"]["clients.json"])
              scopes = {client["name"]: sorted(client["scopes"]) for client in declared}
              eligibility = {client["name"]: client["eligibleGroup"] for client in declared}
              clients = sorted(scopes)
              secrets = [
                  (client["name"], {key: target[key] for key in ("namespace", "name", "key")})
                  for client in declared for target in client["secrets"]
              ]
              assert scopes.get("argocd") == ["email", "groups_name", "homelab_admin", "openid", "profile"], scopes
              assert ("argocd", dict(namespace="argocd", name="argocd-kanidm-oidc", key="clientSecret")) in secrets, secrets

              with subtest("the provisioner can patch only its declared Secrets and create none"):
                  for _, spec in secrets:
                      cluster.fail(f"{kubectl} auth can-i create secrets --namespace {spec['namespace']} --as={provisioner}")
                      cluster.succeed(
                          f"{kubectl} auth can-i patch secret/{spec['name']} --namespace {spec['namespace']} --as={provisioner}"
                      )

              with subtest("1: the Job publishes each client secret into its declared Secrets and removes undeclared clients"):
                  # The previous release's shared client, and a hand-made one using
                  # the `.` that Kanidm names allow.
                  for leftover in ("household-admin", "hand.made"):
                      probe("create-client", name=leftover, landing=gateway_callbacks[0])
                  assert probe("registered") == ["hand.made", "household-admin"]
                  run_job("Complete")
                  assert_published()
                  assert_kanidm(members)
                  first = digests()
                  # A later Argo CD sync of the declared Secrets keeps the data.
                  argo_apply(f"{identity}/Secret-oidc-argocd.yaml")
                  argo_apply(f"{identity}/Secret-argocd-kanidm-oidc.yaml")
                  assert_published()
                  assert digests() == first

              with subtest("3: a second run succeeds and changes nothing"):
                  run_job("Complete")
                  assert_published()
                  assert_kanidm(members)
                  assert digests() == first

              with subtest("4: a Secret the old Job created and Argo CD adopted keeps working"):
                  cluster.succeed(f"{kubectl} delete secret --namespace gateway oidc-argocd")
                  cluster.succeed(
                      "printf '%s' '{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"name\":\"oidc-argocd\","
                      "\"namespace\":\"gateway\"},\"type\":\"Opaque\",\"data\":{\"client-secret\":\"c3RhbGU=\"}}' "
                      f"| {kubectl} apply --server-side --field-manager=identity-provisioner -f -"
                  )
                  argo_apply(f"{identity}/Secret-oidc-argocd.yaml")
                  before = managers("gateway", "oidc-argocd")
                  evidence("migration-managers-before", sorted(before))
                  assert '"f:client-secret"' in before["identity-provisioner"], before
                  assert '"f:type"' in before["argocd-controller"], before
                  run_job("Complete")
                  assert_published()
                  assert digests() == first
                  after = managers("gateway", "oidc-argocd")
                  assert '"f:client-secret"' in after["identity-provisioner"], after
                  argo_apply(f"{identity}/Secret-oidc-argocd.yaml")
                  assert_published()

              with subtest("2: without its declared Secret the Job fails, creates nothing and grants nothing"):
                  cluster.succeed(f"{kubectl} delete secret --namespace argocd argocd-kanidm-oidc")
                  logs = run_job("Failed")
                  cluster.fail(f"{kubectl} get secret --namespace argocd argocd-kanidm-oidc")
                  state = probe("state", clients=clients)
                  evidence("no-create-members", state["members"])
                  assert state["members"] == [], state["members"]
                  evidence("no-create-log", logs.strip().splitlines())

              with subtest("restoring the declared Secret restores the grant"):
                  argo_apply(f"{identity}/Secret-argocd-kanidm-oidc.yaml")
                  run_job("Complete")
                  assert_published()
                  assert_kanidm(members)

              with subtest("5: the Gateway and Argo CD both sign an administrator in through client argocd"):
                  gateway, argocd = probe("oidc-groups", person=members[0], client="argocd", requests=[
                      dict(redirect=gateway_callbacks[0], scopes=["openid", "profile", "email", "homelab_admin"]),
                      dict(redirect=callbacks[0], scopes=["openid", "profile", "email", "groups_name"]),
                  ])
                  evidence("gateway-id-token", gateway)
                  evidence("argocd-id-token", argocd)
                  for claims in (gateway, argocd):
                      assert claims["iss"] == "https://${domain}/oauth2/openid/argocd", claims
                      assert claims["aud"] in ("argocd", ["argocd"]), claims
                  assert "homelab-admin" in argocd["groups"], argocd
                  assert all("@" not in group for group in argocd["groups"]), argocd

              # A above remains the reviewed registry executable. B is the
              # actual source producer archive, imported without publication.
              with subtest("source B: bind the imported executable to its producer archive"):
                  with open("${imageB}", "rb") as archive:
                      archive_sha256 = hashlib.file_digest(archive, "sha256").hexdigest()
                  with tarfile.open("${imageB}") as archive:
                      manifest_file = archive.extractfile("manifest.json")
                      assert manifest_file is not None, "producer archive has no manifest"
                      inventory = json.load(manifest_file)
                      assert len(inventory) == 1, inventory
                      assert archive_reference in inventory[0]["RepoTags"], inventory
                      config_file = archive.extractfile(inventory[0]["Config"])
                      assert config_file is not None, "producer archive has no referenced config"
                      config_bytes = config_file.read()
                      config_digest = "sha256:" + hashlib.sha256(config_bytes).hexdigest()
                      assert json.loads(config_bytes)["architecture"] == "amd64"
                  cluster.succeed(
                      "${k3sPackage}/bin/k3s ctr --address /run/k3s/containerd/containerd.sock "
                      "--namespace k8s.io images import ${imageB}"
                  )
                  # Kubelet keys cached pull authorization by config digest and
                  # repository. A and B can share a config digest, so give B a
                  # source-only tag in A's repository. Never forbids a registry fallback.
                  registry_image = next(
                      container["image"] for container in last_job_execution["pods"][0]["spec"]["containers"]
                      if container["name"] == "provision"
                  )
                  private_reference = (
                      registry_image.split("@", 1)[0] + ":source-" + archive_reference.rsplit(":", 1)[1]
                  )
                  cluster.succeed(
                      "${k3sPackage}/bin/k3s ctr --address /run/k3s/containerd/containerd.sock "
                      f"--namespace k8s.io images tag {shlex.quote('docker.io/' + archive_reference)} "
                      f"{shlex.quote(private_reference)}"
                  )
                  imported = json.loads(cluster.succeed(
                      f"${k3sPackage}/bin/k3s crictl inspecti --output json {shlex.quote(private_reference)}"
                  ))["status"]
                  assert imported["id"] == config_digest, imported
                  evidence("current-source-B", dict(
                      source_path="${self}",
                      source_revision=json.loads(${
                        builtins.toJSON (builtins.toJSON (self.rev or self.dirtyRev or null))
                      }),
                      source_nar_hash=json.loads(${builtins.toJSON (builtins.toJSON (self.narHash or null))}),
                      producer_drv="${builtins.unsafeDiscardStringContext imageB.drvPath}", archive="${imageB}",
                      archive_sha256=archive_sha256, reference=private_reference, config_digest=config_digest,
                  ))

              def select_private(path):
                  # Real rendered RBAC and empty Secrets. Only the disposable
                  # Job selects the source executable and the test CA.
                  for filename in cluster.succeed(f"ls {path}").split():
                      if filename != "Job-kanidm-provision.yaml":
                          argo_apply(f"{path}/{filename}")
                  job = json.loads(cluster.succeed(
                      f"{kubectl} create --dry-run=client --output json -f {path}/Job-kanidm-provision.yaml "
                      "| jq -f ${trustJob}"
                  ))
                  container = job["spec"]["template"]["spec"]["containers"][0]
                  assert container["image"] != private_reference, container["image"]
                  container["image"] = private_reference
                  container["imagePullPolicy"] = "Never"
                  cluster.succeed("umask 077; printf %s " + shlex.quote(json.dumps(job)) + " > /root/job.json")
                  data = json.loads(cluster.succeed(
                      f"{kubectl} get configmap --namespace identity kanidm-provision --output json"
                  ))["data"]
                  selected = json.loads(data["clients.json"])
                  selected_scopes = {client["name"]: sorted(client["scopes"]) for client in selected}
                  selected_secrets = [
                      (client["name"], {key: target[key] for key in ("namespace", "name", "key")})
                      for client in selected for target in client["secrets"]
                  ]
                  return selected, selected_scopes, selected_secrets

              def assert_private_exit(expected):
                  pods = last_job_execution["pods"]
                  assert pods, "no source helper Pod"
                  # A completed Job can retain unsuccessful Pod attempts.
                  exits = []
                  successful = False
                  for pod in pods:
                      container = next(c for c in pod["spec"]["containers"] if c["name"] == "provision")
                      assert container["image"] == private_reference and container["imagePullPolicy"] == "Never", container
                      status = next((s for s in pod["status"].get("containerStatuses", [])
                                     if s["name"] == "provision"), None)
                      if status is None:
                          continue
                      terminated = [slot["terminated"]["exitCode"] for slot in
                                    (status.get("state", {}), status.get("lastState", {})) if "terminated" in slot]
                      if not terminated:
                          continue
                      exits.extend(terminated)
                      running_image = json.loads(cluster.succeed(
                          "${k3sPackage}/bin/k3s crictl inspecti --output json " + shlex.quote(status["imageID"])
                      ))["status"]
                      assert running_image["id"] == config_digest, running_image
                      if (pod["status"].get("phase") == "Succeeded"
                              and status.get("state", {}).get("terminated", {}).get("exitCode") == 0):
                          successful = True
                  assert expected in exits, (expected, exits)
                  if expected == 0:
                      assert successful, "no successful source helper Pod"
                  else:
                      assert 0 not in exits, exits
                  evidence("source-B-native-exits", dict(expected=expected, observed=exits))

              def assert_private(selected):
                  state = probe("state", clients=clients)
                  assert state["members"] == members, state
                  assert state["credential_type_minimum"] == ["mfa"], state
                  assert state["registered"] == clients, state
                  for client in selected:
                      found = state["clients"][client["name"]]
                      assert found["scope_maps"] == {client["eligibleGroup"]: sorted(client["scopes"])}, found
                      assert found["sup_scope_maps"] == [], found
                      assert found["strict_redirect"] == ["true"], found
                  assert state["clients"]["argocd"]["redirects"] == sorted(gateway_callbacks + callbacks), state
                  assert_private_exit(0)
                  evidence("source-B-kanidm-policy", state)

              original_clients, original_secrets = clients, secrets
              with subtest("source B: independent eligibility grants only invited ordinary identities"):
                  selected, scopes, secrets = select_private(private_identity)
                  clients = sorted(scopes)
                  native = next(client for client in selected if client["name"] == "fixture-native")
                  target = native["secrets"][0]
                  for verb in ("create", "delete", "list"):
                      cluster.fail(f"{kubectl} auth can-i {verb} secrets --namespace identity --as={provisioner}")
                  cluster.fail(f"{kubectl} auth can-i patch secret/unrelated --namespace identity --as={provisioner}")
                  cluster.succeed(
                      f"{kubectl} auth can-i patch secret/{target['name']} --namespace identity --as={provisioner}"
                  )
                  run_job("Complete")
                  assert_published()
                  assert_private(selected)
                  private_first = digests()
                  assert all(private_first[spec["name"]] == first[spec["name"]] for _, spec in original_secrets)
                  private_published = secret(target["namespace"], target["name"])["data"]
                  probe("prepare-private", group=native["eligibleGroup"])
                  probe("stale-maps", client="fixture-native",
                        groups=["homelab-admin", "fixture-native-outsiders"])
                  run_job("Complete")
                  assert_private(selected)
                  assert_published()
                  assert digests() == private_first
                  native_request = dict(client="fixture-native", redirect="https://native.example.test/callback",
                                        scopes=native["scopes"], published=target)
                  claims = probe("private-oauth", person="fixture-invited", **native_request)
                  for person in ("fixture-uninvited", members[0]):
                      assert probe("private-oauth", person=person, allowed=False, **native_request) == {"denied": True}
                  assert probe("private-oauth", person="fixture-invited", client="argocd",
                               redirect=callbacks[0], scopes=["openid", "groups_name"], allowed=False) == {"denied": True}
                  evidence("source-B-native-ordinary-user", claims)

              with subtest("source B: a public client needs S256 PKCE, exact callback and eligibility, not a Secret"):
                  def publication_boundary():
                      resources = json.loads(cluster.succeed(
                          f"{kubectl} get secrets,roles,rolebindings --namespace identity --output json"
                      ))["items"]
                      return {
                          (item["kind"], item["metadata"]["name"]): dict(
                              uid=item["metadata"]["uid"],
                              **{key: item[key] for key in ("data", "rules", "roleRef", "subjects") if key in item},
                          ) for item in resources
                      }

                  publication_before = publication_boundary()
                  selected, scopes, secrets = select_private(public_identity)
                  clients = sorted(scopes)
                  public = next(client for client in selected if client["name"] == "fixture-native-public")
                  for verb in ("get", "patch"):
                      cluster.fail(
                          f"{kubectl} auth can-i {verb} secret/fixture-native-public-oidc "
                          f"--namespace identity --as={provisioner}"
                      )
                  cluster.fail(f"{kubectl} auth can-i create secrets --namespace identity --as={provisioner}")
                  cluster.fail(f"{kubectl} get secret --namespace identity fixture-native-public-oidc")
                  run_job("Complete")
                  assert_private(selected)
                  assert_published()
                  assert digests() == private_first
                  assert publication_boundary() == publication_before, "public client changed Secrets or publication authority"
                  probe("public-client", client=public["name"])
                  public_redirect = "https://public-native.example.test/callback"
                  public_request = dict(client=public["name"], public=True,
                                        redirect=public_redirect,
                                        scopes=public["scopes"])
                  public_claims = probe("private-oauth", person="fixture-invited", **public_request)
                  denied = {
                      "ineligible": probe("private-oauth", person="fixture-uninvited",
                                          allowed=False, **public_request),
                      "no_pkce": probe("private-oauth", person="fixture-invited", allowed=False,
                                       denied_status=400, pkce=False, **public_request),
                      "wrong_callback": probe("private-oauth", person="fixture-invited", allowed=False,
                                              denied_status=400,
                                              **(public_request | {"redirect": public_redirect + "/wrong"})),
                  }
                  cluster.fail(f"{kubectl} get secret --namespace identity fixture-native-public-oidc")
                  evidence("source-B-public-native", dict(claims=public_claims, denied=denied,
                                                         basic_secret=None, publication_target=None))
                  # Keep every later confidential/publication and selected-A
                  # case on its original declaration; reconcile away only ours.
                  selected, scopes, secrets = select_private(private_identity)
                  clients = sorted(scopes)
                  run_job("Complete")
                  assert_private(selected)
                  assert_published()
                  assert digests() == private_first

              with subtest("Home accepts household and administrator sign-in, not arbitrary identities"):
                  consumer = json.loads(cluster.succeed(
                      f"{kubectl} create --dry-run=client --output json "
                      "-f ${manifests}/homarr/StatefulSet-homarr.yaml"
                  ))
                  container = next(c for c in consumer["spec"]["template"]["spec"]["containers"] if c["name"] == "main")
                  env = {entry["name"]: entry for entry in container["env"]}
                  client_secret = env["AUTH_OIDC_CLIENT_SECRET"]["valueFrom"]["secretKeyRef"]
                  request = dict(
                      client=env["AUTH_OIDC_CLIENT_ID"]["value"],
                      scopes=env["AUTH_OIDC_SCOPE_OVERWRITE"]["value"].split(),
                      published=dict(namespace=consumer["metadata"]["namespace"],
                                     name=client_secret["name"], key=client_secret["key"]),
                  )
                  # Household membership is UI-managed and must survive reconciliation.
                  probe("invite-replacement", group="${cluster.settings.kubernetes.services.identity.householdGroup}")
                  for executable in ("published A", "source B"):
                      with subtest(f"{executable}: Home authorization follows the configured consumer"):
                          if executable == "published A":
                              cluster.succeed(
                                  f"{kubectl} create --dry-run=client --output json "
                                  f"-f {private_identity}/Job-kanidm-provision.yaml "
                                  "| jq -f ${trustJob} > /root/job.json"
                              )
                          else:
                              selected, scopes, secrets = select_private(private_identity)
                              clients = sorted(scopes)
                          # Each executable must revoke a real stale outsider grant,
                          # not inherit the previous executable's reconciled policy.
                          probe("stale-maps", client=request["client"], groups=["fixture-native-outsiders"])
                          run_job("Complete")
                          if executable == "published A":
                              assert last_job_execution["pods"], "no selected helper Pod"
                              for pod in last_job_execution["pods"]:
                                  container = next(c for c in pod["spec"]["containers"] if c["name"] == "provision")
                                  assert container["image"] == registry_image, container
                          else:
                              assert_private_exit(0)
                          for hostname in json.loads(${builtins.toJSON (builtins.toJSON cluster.routes.home.hostnames)}):
                              request["redirect"] = f"https://{hostname}/api/auth/callback/oidc"
                              for person, group in (
                                  (members[0], "${cluster.settings.kubernetes.services.identity.adminGroup}"),
                                  ("fixture-replacement", "${cluster.settings.kubernetes.services.identity.householdGroup}"),
                              ):
                                  claims = probe("private-oauth", person=person, **request)
                                  groups = claims[env["AUTH_OIDC_GROUPS_ATTRIBUTE"]["value"]]
                                  assert group in groups and all("@" not in name for name in groups), claims
                                  assert claims["iss"] == env["AUTH_OIDC_ISSUER"]["value"], claims
                              assert probe("private-oauth", person="fixture-uninvited",
                                           allowed=False, **request) == {"denied": True}
                          assert probe("private-oauth", person="fixture-replacement", client="argocd",
                                       redirect=callbacks[0], scopes=["openid", "groups_name"],
                                       allowed=False) == {"denied": True}

              with subtest("source B: entity reconciliation failure cannot retain eligibility"):
                  configmap = json.loads(cluster.succeed(
                      f"{kubectl} get configmap --namespace identity kanidm-provision --output json"
                  ))
                  configmap["data"]["state.json"] = "{"
                  cluster.succeed(
                      "printf %s " + shlex.quote(json.dumps(configmap))
                      + f" | {kubectl} apply --server-side --field-manager=argocd-controller --force-conflicts -f -"
                  )
                  logs = run_job("Failed")
                  assert_private_exit(1)
                  assert probe("private-oauth", person="fixture-invited", allowed=False, **native_request) == {"denied": True}
                  failed = probe("state", clients=clients)
                  assert failed["members"] == [], failed
                  assert all(found["scope_maps"] == {} and found["sup_scope_maps"] == []
                             for found in failed["clients"].values()), failed
                  assert secret(target["namespace"], target["name"])["data"] == private_published
                  selected, scopes, secrets = select_private(private_identity)
                  run_job("Complete")
                  assert_private(selected)
                  probe("private-oauth", person="fixture-invited", **native_request)

              with subtest("source B: early publication failure revokes old and stale grants"):
                  probe("stale-maps", client="fixture-native", groups=["fixture-native-outsiders"])
                  probe("private-oauth", person="fixture-uninvited", **native_request)
                  selected, scopes, secrets = select_private(replacement_identity)
                  replacement = next(client for client in selected if client["name"] == "fixture-native")
                  assert [client["name"] for client in selected].index("argocd") < [client["name"] for client in selected].index("fixture-native")
                  # Name-scoped RBAC cannot create the missing earlier Secret.
                  cluster.succeed(f"{kubectl} delete secret --namespace argocd argocd-kanidm-oidc")
                  logs = run_job("Failed")
                  assert_private_exit(1)
                  cluster.fail(f"{kubectl} get secret --namespace argocd argocd-kanidm-oidc")
                  request = native_request | {"scopes": replacement["scopes"]}
                  for person in ("fixture-invited", "fixture-uninvited"):
                      assert probe("private-oauth", person=person, allowed=False, **request) == {"denied": True}
                  failed = probe("state", clients=clients)
                  assert failed["members"] == [], failed
                  assert failed["credential_type_minimum"] == ["mfa"], failed
                  assert failed["clients"]["fixture-native"]["scope_maps"] == {}, failed
                  assert failed["clients"]["fixture-native"]["sup_scope_maps"] == [], failed
                  assert secret(target["namespace"], target["name"])["data"] == private_published
                  assert probe("private-oauth", person=members[0], client="argocd", redirect=callbacks[0],
                               scopes=["openid", "groups_name"], allowed=False) == {"denied": True}
                  probe("private-preserved", replacement_invited=False)
                  evidence("source-B-early-failure", dict(state=failed, log=logs.strip().splitlines()))

              with subtest("source B: restored declaration grants only replacement eligibility and reduced scopes"):
                  argo_apply(f"{replacement_identity}/Secret-argocd-kanidm-oidc.yaml")
                  run_job("Complete")
                  assert_private(selected)
                  assert_published()
                  assert digests() == private_first
                  request = native_request | {"scopes": replacement["scopes"]}
                  assert probe("private-oauth", person="fixture-invited", allowed=False, **request) == {"denied": True}
                  probe("invite-replacement", group=replacement["eligibleGroup"])
                  probe("private-oauth", person="fixture-replacement", **request)
                  assert probe("private-oauth", person="fixture-replacement", allowed=False,
                               **(request | {"scopes": ["openid", "profile", "email"]})) == {"denied": True}
                  for person in ("fixture-uninvited", members[0]):
                      assert probe("private-oauth", person=person, allowed=False, **request) == {"denied": True}
                  probe("stale-maps", client="fixture-native", groups=["fixture-native-users"])
                  run_job("Complete")
                  assert_private(selected)
                  assert probe("private-oauth", person="fixture-invited", allowed=False, **request) == {"denied": True}
                  probe("private-oauth", person="fixture-replacement", **request)
                  assert digests() == private_first
                  admin_claims = probe("private-oauth", person=members[0], client="argocd",
                                       redirect=callbacks[0], scopes=["openid", "profile", "email", "groups_name"])
                  assert "homelab-admin" in admin_claims["groups"], admin_claims

              with subtest("source B: deselection revokes the orphan even if earlier publication fails"):
                  selected, scopes, secrets = select_private(source_identity)
                  cluster.succeed(f"{kubectl} delete secret --namespace argocd argocd-kanidm-oidc")
                  run_job("Failed")
                  assert_private_exit(1)
                  failed = probe("state", clients=clients)
                  assert "fixture-native" in failed["registered"], failed
                  assert failed["clients"]["fixture-native"]["scope_maps"] == {}, failed
                  assert failed["clients"]["fixture-native"]["sup_scope_maps"] == [], failed
                  assert probe("private-oauth", person="fixture-replacement", allowed=False, **request) == {"denied": True}
                  probe("private-preserved")
                  argo_apply(f"{source_identity}/Secret-argocd-kanidm-oidc.yaml")
                  clients = original_clients
                  run_job("Complete")
                  assert_private_exit(0)
                  assert_kanidm(members)
                  assert_published()
                  assert digests() == first
                  probe("private-preserved")
                  assert secret(target["namespace"], target["name"])["data"] == private_published

              with subtest("server configuration: missing publication blocks replacement, adoption and resync preserve state"):
                  # Privileged disposable SSA simulation, not real Argo CD
                  # authorization, pruning, reconciliation or production availability.
                  # Render only a different LDAPS port; never rewrite the TOML.
                  rollout = "${rolloutManifests}"
                  with open(f"{rollout}/Deployment-kanidm.yaml") as handle:
                      desired = json.load(handle)
                  desired_pod = desired["spec"]["template"]["spec"]
                  desired_container, = (c for c in desired_pod["containers"] if c["name"] == "kanidm")
                  desired_mount, = (m for m in desired_container["volumeMounts"] if m["mountPath"] in desired_container["args"])
                  desired_volume, = (v for v in desired_pod["volumes"] if v["name"] == desired_mount["name"])
                  config_name = desired_volume["configMap"]["name"]
                  config_path = f"{rollout}/ConfigMap-{config_name}.yaml"
                  with open(config_path) as handle:
                      desired_config = json.load(handle)

                  def server_snapshot():
                      deployment = json.loads(cluster.succeed(
                          f"{kubectl} get deployment --namespace identity kanidm --output json"
                      ))
                      pod, = json.loads(cluster.succeed(
                          f"{kubectl} get pods --namespace identity -l app.kubernetes.io/name=kanidm --output json"
                      ))["items"]
                      status, = (c for c in pod["status"]["containerStatuses"] if c["name"] == "kanidm")
                      assert status["ready"] and "running" in status["state"], status
                      owner, = (o for o in pod["metadata"]["ownerReferences"] if o.get("controller") and o["kind"] == "ReplicaSet")
                      return pod, dict(
                          generation=deployment["metadata"]["generation"], replica_set_uid=owner["uid"],
                          pod_uid=pod["metadata"]["uid"], container_id=status["containerID"],
                          restarts=status["restartCount"],
                      )

                  def server_runtime(pod, snapshot):
                      container_id = snapshot["container_id"].removeprefix("containerd://")
                      runtime = json.loads(cluster.succeed(
                          "${k3sPackage}/bin/k3s crictl inspect --output json " + shlex.quote(container_id)
                      ))
                      assert runtime["status"]["state"] == "CONTAINER_RUNNING", runtime["status"]["state"]
                      assert runtime["status"]["labels"]["io.kubernetes.pod.uid"] == pod["metadata"]["uid"]
                      assert runtime["status"]["metadata"]["name"] == "kanidm"
                      pid = runtime["info"]["pid"]
                      assert type(pid) is int and pid > 0, pid
                      return container_id, pid

                  def storage_identity(pod):
                      container, = (c for c in pod["spec"]["containers"] if c["name"] == desired_container["name"])
                      mounted_volumes = {mount["name"] for mount in container["volumeMounts"]}
                      claim, = (volume["persistentVolumeClaim"]["claimName"] for volume in pod["spec"]["volumes"]
                                if volume["name"] in mounted_volumes and "persistentVolumeClaim" in volume)
                      pvc = json.loads(cluster.succeed(
                          f"{kubectl} get pvc --namespace {shlex.quote(pod['metadata']['namespace'])} {shlex.quote(claim)} --output json"
                      ))
                      pv = json.loads(cluster.succeed(
                          f"{kubectl} get pv {shlex.quote(pvc['spec']['volumeName'])} --output json"
                      ))
                      assert pvc["status"]["phase"] == "Bound" and pv["status"]["phase"] == "Bound"
                      return dict(pvc_uid=pvc["metadata"]["uid"], pv_uid=pv["metadata"]["uid"],
                                  volume=pvc["spec"]["volumeName"])

                  old_pod, old_identity = server_snapshot()
                  old_container_id, old_pid = server_runtime(old_pod, old_identity)
                  old_volume, = (v for v in old_pod["spec"]["volumes"] if v["name"] == desired_mount["name"])
                  old_config_name = old_volume["configMap"]["name"]
                  old_config = json.loads(cluster.succeed(
                      f"{kubectl} get configmap --namespace identity {old_config_name} --output json"
                  ))
                  storage_before = storage_identity(old_pod)
                  state_before = probe("state", clients=clients)
                  credentials_before = digests()
                  credential_targets = [(s["namespace"], s["name"]) for _, s in secrets]
                  credential_targets.append(("identity", "kanidm-provision"))
                  secret_uids = {(namespace, name): secret(namespace, name)["metadata"]["uid"]
                                 for namespace, name in credential_targets}
                  probe("private-preserved")
                  missing_config = f"{kubectl} get configmap --namespace identity {config_name} --ignore-not-found --output json"
                  assert cluster.succeed(missing_config).strip() == ""

                  # Withhold the new required map while the old revision remains
                  # available. Recreate must stop the writer without our deleting it.
                  argo_apply(f"{rollout}/Deployment-kanidm.yaml")
                  cluster.succeed(
                      f"{kubectl} wait --namespace identity --for=delete pod/{old_pod['metadata']['name']} --timeout=180s"
                  )
                  cluster.wait_until_fails(f"test -e /proc/{old_pid}/exe", timeout=120)
                  running = json.loads(cluster.succeed("${k3sPackage}/bin/k3s crictl ps --output json"))["containers"]
                  assert all(c["id"] != old_container_id
                             and c.get("labels", {}).get("io.kubernetes.pod.uid") != old_identity["pod_uid"]
                             for c in running), "old database writer is still running"
                  pod_query = f"{kubectl} get pods --namespace identity -l app.kubernetes.io/name=kanidm --output json"
                  cluster.wait_until_succeeds(pod_query + " | jq -e '.items | length == 1'", timeout=120)
                  pending, = json.loads(cluster.succeed(pod_query))["items"]
                  pending_uid = pending["metadata"]["uid"]
                  assert pending_uid != old_identity["pod_uid"]
                  event_query = (
                      f"{kubectl} get events --namespace identity --field-selector involvedObject.uid={pending_uid} --output json"
                  )
                  cluster.wait_until_succeeds(
                      event_query + " | jq -e --arg config " + shlex.quote(config_name)
                      + " 'any(.items[]; .reason == \"FailedMount\" and (.message | contains($config)) "
                      "and (.message | ascii_downcase | contains(\"not found\")))'", timeout=180
                  )
                  failed_mounts = [
                      dict(reason=e["reason"], message=e["message"], pod_uid=e["involvedObject"]["uid"])
                      for e in json.loads(cluster.succeed(event_query))["items"]
                      if e.get("reason") == "FailedMount" and config_name in e.get("message", "")
                      and "not found" in e.get("message", "").lower()
                  ]
                  assert failed_mounts, "missing native failed-publication witness"
                  pending, = json.loads(cluster.succeed(pod_query))["items"]
                  assert pending["metadata"]["uid"] == pending_uid
                  for status in pending["status"].get("containerStatuses", []):
                      assert not status.get("containerID") and status.get("restartCount", 0) == 0, status
                      assert not status.get("lastState") and not ({"running", "terminated"} & status.get("state", {}).keys()), status
                  assert cluster.succeed(missing_config).strip() == ""
                  retained_config = json.loads(cluster.succeed(
                      f"{kubectl} get configmap --namespace identity {old_config_name} --output json"
                  ))
                  assert retained_config["metadata"]["uid"] == old_config["metadata"]["uid"]
                  assert retained_config["data"] == old_config["data"]
                  evidence("config-publication-blocked", dict(
                      old=old_identity, pending_pod_uid=pending_uid, missing_config=config_name,
                      old_writer_stopped=True, failed_mounts=failed_mounts,
                  ))

                  # Kubelet must unblock this same Pod when the actual rendered
                  # map appears; no manual restart or replacement is allowed.
                  argo_apply(config_path)
                  argo_apply(f"{rollout}/Service-kanidm.yaml")
                  cluster.succeed(f"{kubectl} rollout status deployment/kanidm --namespace identity --timeout=300s")
                  new_pod, new_identity = server_snapshot()
                  assert new_identity["pod_uid"] == pending_uid
                  assert new_identity["container_id"] != old_identity["container_id"]
                  _, new_pid = server_runtime(new_pod, new_identity)
                  mounted = cluster.succeed("cat " + shlex.quote(f"/proc/{new_pid}/root{desired_mount['mountPath']}"))
                  assert mounted == desired_config["data"][desired_mount["subPath"]], "running container has stale server configuration"
                  old_container, = (c for c in old_pod["spec"]["containers"] if c["name"] == "kanidm")
                  old_port, = (p["containerPort"] for p in old_container["ports"] if p["name"] == "ldaps")
                  new_port, = (p["containerPort"] for p in desired_container["ports"] if p["name"] == "ldaps")
                  listening = set()
                  for protocol in ("tcp", "tcp6"):
                      for row in cluster.succeed(f"cat /proc/{new_pid}/net/{protocol}").splitlines()[1:]:
                          fields = row.split()
                          if fields[3] == "0A":
                              listening.add(int(fields[1].rsplit(":", 1)[1], 16))
                  assert new_port in listening and old_port not in listening, listening
                  cluster.wait_until_succeeds("curl -sSf --cacert /root/pki/ca.crt https://${domain}/status", timeout=120)
                  assert storage_identity(new_pod) == storage_before
                  assert probe("state", clients=clients) == state_before
                  assert digests() == credentials_before
                  assert_published()
                  assert {(namespace, name): secret(namespace, name)["metadata"]["uid"]
                          for namespace, name in credential_targets} == secret_uids
                  probe("private-preserved")

                  for path in (config_path, f"{rollout}/Deployment-kanidm.yaml", f"{rollout}/Service-kanidm.yaml"):
                      argo_apply(path)
                  deadline = time.monotonic() + 30
                  observations = 0
                  while time.monotonic() < deadline:
                      _, observed = server_snapshot()
                      assert observed == new_identity, (new_identity, observed)
                      observations += 1
                      time.sleep(2)
                  evidence("config-adopted-and-resync-stable", dict(
                      current=new_identity, storage=storage_before, ldap_port=new_port,
                      mounted_bytes=len(mounted.encode()), unchanged_observations=observations,
                      state_preserved=True, credentials_preserved=True, publication_identities_preserved=True,
                  ))

              with subtest("clean up disposable private identity fixtures"):
                  # Delete only test-owned identities and publication resources.
                  probe("cleanup-private")
                  cluster.succeed(
                      f"{kubectl} delete secret --namespace identity fixture-native-oidc && "
                      f"{kubectl} delete role,rolebinding --namespace identity kanidm-client-secret-fixture-native-oidc"
                  )
                  cluster.succeed("rm -f /root/private-identity-credentials.json")
            '';
          }).overrideTestDerivation
            (_: {
              # Registry pulls of the digest-pinned server and helper.
              __noChroot = true;
            });
      in
      {
        checks.identity-provision-runtime = test // {
          meta = test.meta // {
            hestia.group = "${system}-identity-runtime";
          };
        };
      }
    );
}
