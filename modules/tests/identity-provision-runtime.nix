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
# The Kanidm image comes from its registry by digest, so the builder must
# permit __noChroot (sandbox = relaxed).
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
in
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        provisionImage = self.packages.${system}.kanidm-provision-image;
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
                    provisionImage
                  ];
                };
              };
            testScript = ''
              import json
              import shlex
              import time

              kubectl = "${k3sPackage}/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml"
              identity = "${manifests}/identity"
              callbacks = sorted(json.loads(${builtins.toJSON (builtins.toJSON argocdCallbacks)}))
              gateway_callbacks = sorted(json.loads(${builtins.toJSON (builtins.toJSON gatewayCallbacks)}))
              # One client per administrator route. Argo CD's Gateway sign-in and
              # its own sign-in share client argocd, which publishes to both Secrets.
              scopes = {"argocd": ["email", "groups_name", "homelab_admin", "openid", "profile"]}
              clients = sorted(scopes)
              secrets = [
                  ("argocd", dict(namespace="gateway", name="oidc-argocd", key="client-secret")),
                  ("argocd", dict(namespace="argocd", name="argocd-kanidm-oidc", key="clientSecret")),
              ]
              provisioner = "system:serviceaccount:identity:kanidm-provision"

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
                      assert found["scope_maps"] == {"homelab-admin": scopes[client]}, (client, found)
                      assert found["sup_scope_maps"] == [], (client, found)
                      assert found["strict_redirect"] == ["true"], (client, found)
                  assert state["clients"]["argocd"]["redirects"] == sorted(gateway_callbacks + callbacks), state["clients"]["argocd"]

              def run_job(expect):
                  cluster.succeed(f"{kubectl} delete job --namespace identity kanidm-provision --ignore-not-found --wait")
                  cluster.succeed(f"{kubectl} apply -f /root/job.json")
                  attempts = []
                  deadline = time.time() + 720
                  while time.time() < deadline:
                      status = json.loads(cluster.succeed(
                          f"{kubectl} get job --namespace identity kanidm-provision --output json"
                      ))["status"]
                      ended = {c["type"] for c in status.get("conditions", []) if c["status"] == "True"}
                      # Failed attempts' logs. The Job writes no credentials to its log.
                      _, previous = cluster.execute(
                          f"{kubectl} logs --namespace identity -l job-name=kanidm-provision --previous --tail=5 2>/dev/null"
                      )
                      previous = previous.strip()
                      # kubectl reports a running container's absent previous log as an error line.
                      if previous and not previous.startswith("unable to retrieve") and previous not in attempts:
                          attempts.append(previous)
                      if ended & {"Complete", "Failed"}:
                          evidence(f"job-{expect}-failed-attempts", [a.splitlines() for a in attempts])
                          assert expect in ended, f"Job ended {sorted(ended)}, expected {expect}"
                          return "\n".join(attempts)
                      time.sleep(5)
                  raise AssertionError(f"Job did not reach {expect}")

              start_all()
              cluster.wait_until_succeeds(f"{kubectl} get --raw=/readyz", timeout=300)

              # Platform pieces production supplies outside the identity Application.
              cluster.succeed(f"{kubectl} apply -f ${manifests}/identity-retained")
              cluster.succeed(f"{kubectl} create namespace gateway")
              cluster.succeed(f"{kubectl} create namespace argocd")
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
                      assert probe("create-client", name=leftover, landing=gateway_callbacks[0]) is True
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
                  assert "Kanidm client Secret publication for argocd failed" in logs, logs
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
            '';
          }).overrideTestDerivation
            (_: {
              # Registry pull of the digest-pinned Kanidm image.
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
