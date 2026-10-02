# Behaviour test: the household entrance as a client reaches it.
#
# A K3s node runs the Envoy Gateway CRDs and controller from the committed
# prod-home manifests and the resources rendered by the gateway/identity aspects.
# Separate clients connect through the NodePort, as host DNAT does in production.
# The plain origin, ephemeral Kanidm storage, and synthetic TLS/CA are test-local;
# production BackendTLSPolicy still uses System trust, with the fixture CA mounted
# into the isolated proxy's system bundle.
#
# Images come from their registries: the controller and proxy are pinned by
# digest in the manifests, and containerd resolves digest references only
# against registry manifests.
{
  config,
  lib,
  inputs,
  self,
  ...
}:
let
  cluster = config.den.clusters."prod-home";
  gateway =
    (import ../den/aspects/kubernetes/services/gateway.nix { }).den.aspects.kubernetes.services.gateway;
  nodeAddress = "10.0.0.10";
  peerAddress = "10.0.0.11";
  strangerAddress = "10.0.0.20";
  nodePort = toString cluster.ingress.nodePort;
  instance = "compute-1";
  fixtureCluster = cluster // {
    routes = lib.getAttrs [ "argocd" "idm" ] cluster.routes // {
      origin = {
        namespace = "origin";
        service = "origin";
        port = 8080;
        auth = "native";
        exposure = "public";
        backendPodSelector.app = "origin";
        hostnames = [ "origin.test" ];
        pathPrefix = "/";
        backendTLS = false;
        backendHostname = null;
        timeouts = null;
      };
    };
  };
  renderGateway = inventory: gateway.k8s-manifests {
    cluster = inventory;
    computeResources = config.flake.clusterResources.prod-home // { inherit instance; };
    charts = { };
    inherit lib;
  };
  entranceObjects = inventory: map
    (object: if object.kind == "EnvoyProxy" then lib.recursiveUpdate object {
      spec.provider.kubernetes.envoyDeployment = {
        pod.volumes = [ {
          name = "fixture-ca";
          configMap.name = "fixture-ca";
        } ];
        container.volumeMounts = [ {
          name = "fixture-ca";
          mountPath = "/etc/ssl/certs/ca-certificates.crt";
          subPath = "ca-certificates.crt";
          readOnly = true;
        } ];
      };
    } else object)
    (renderGateway inventory).applications.gateway.objects;
  identity = (import ../den/aspects/kubernetes/services/identity.nix {
    inherit config inputs lib;
  }).den.aspects.kubernetes.services.identity;
  renderIdentity = phase: identity.k8s-manifests {
    cluster = lib.recursiveUpdate fixtureCluster {
      settings.kubernetes.services.identity.phase = phase;
    };
    computeResources = config.flake.clusterResources.prod-home // { inherit instance; };
    inherit lib;
  };
  identityObjects = map
    (object: if object.kind == "Deployment" then lib.recursiveUpdate object {
      spec.template.spec = {
        securityContext.fsGroup = 1000;
        volumes = map (volume: if volume.name == "data" then {
          name = "data";
          emptyDir = { };
        } else volume) object.spec.template.spec.volumes;
      };
    } else object)
    (renderIdentity "initial").applications.identity.objects;
  trustedCluster = lib.recursiveUpdate fixtureCluster {
    ingress = {
      mode = "trustedEdges";
      trustedProxyCIDRs = [ "${peerAddress}/32" ];
    };
  };
  normalCluster = lib.recursiveUpdate trustedCluster {
    settings.kubernetes.services.identity.phase = "normal";
  };
  applicationObjects = application:
    if application ? content then application.content.objects else application.objects;
  provisionObjects = map
    (object: if object.kind == "Job" then lib.recursiveUpdate object {
      spec.template.spec = {
        containers = map (container: container // {
          env = container.env ++ [ { name = "SSL_CERT_FILE"; value = "/fixture-ca/ca.crt"; } ];
          volumeMounts = container.volumeMounts ++ [ {
            name = "fixture-ca"; mountPath = "/fixture-ca"; readOnly = true;
          } ];
        }) object.spec.template.spec.containers;
        volumes = object.spec.template.spec.volumes ++ [ {
          name = "fixture-ca"; configMap.name = "fixture-ca";
        } ];
      };
    } else object)
    (lib.filter (object: lib.elem object.metadata.name [
      "kanidm-provision" "kanidm-client-secret"
    ]) (renderIdentity "normal").applications.identity.objects);
  provisionConfig = builtins.head (lib.filter (object: object.kind == "ConfigMap") provisionObjects);
  administrator = builtins.head (builtins.fromJSON provisionConfig.data."members.json");
  manifests = ../../generated/manifests/prod-home;
  k3sPackage = self.nixosConfigurations.compute-1.config.services.k3s.package;
in
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        list =
          name: objects:
          pkgs.writeText "${name}.json" (
            builtins.toJSON {
              apiVersion = "v1";
              kind = "List";
              items = objects;
            }
          );
        direct = list "gateway-direct" (entranceObjects fixtureCluster);
        trusted = list "gateway-trusted-edges" (entranceObjects trustedCluster);
        nativeIdentity = list "gateway-test-kanidm" identityObjects;
        provisionImage = self.packages.${system}.kanidm-provision-image;
        provision = list "gateway-test-identity-provision" provisionObjects;
        adminRoutes = list "gateway-test-admin-routes"
          (applicationObjects (renderGateway normalCluster).applications.identity-gateway);
        adminPolicies = list "gateway-test-admin-policies"
          (applicationObjects (renderIdentity "normal").applications.identity-gateway);
        identityDNS = list "gateway-test-identity-dns" [ {
          apiVersion = "v1";
          kind = "ConfigMap";
          metadata = { name = "coredns-custom"; namespace = "kube-system"; };
          data = (renderIdentity "normal").applications.cluster-dns.resources.configMaps.coredns-custom.data;
        } ];
        browserPython = pkgs.python3.withPackages (ps: [ ps.playwright ]);
        adminOrigin = list "gateway-test-admin-origin" [
          { apiVersion = "v1"; kind = "Namespace"; metadata.name = "argocd"; }
          {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = { name = "origin"; namespace = "argocd"; };
            spec = {
              selector.matchLabels = cluster.routes.argocd.backendPodSelector;
              template = {
                metadata.labels = cluster.routes.argocd.backendPodSelector;
                spec.containers = [ {
                  name = "origin";
                  image = "${originImage.imageName}:${originImage.imageTag}";
                  imagePullPolicy = "Never";
                  ports = [ { containerPort = 8080; } ];
                } ];
              };
            };
          }
          {
            apiVersion = "v1";
            kind = "Service";
            metadata = {
              name = cluster.routes.argocd.service;
              namespace = cluster.routes.argocd.namespace;
            };
            spec = {
              selector = cluster.routes.argocd.backendPodSelector;
              ports = [ { port = cluster.routes.argocd.port; targetPort = 8080; } ];
            };
          }
        ];
        probes = [
          "index.html"
          "direct-probe"
          "trusted-probe"
          "blocked-probe"
        ];
        originImage = pkgs.dockerTools.buildImage {
          name = "homelab/gateway-test-origin";
          tag = "1";
          copyToRoot = pkgs.buildEnv {
            name = "gateway-test-origin-root";
            paths = [
              pkgs.busybox
              (pkgs.runCommand "gateway-test-origin-www" { } ''
                mkdir -p "$out/www"
                for probe in ${lib.escapeShellArgs probes}; do
                  echo origin > "$out/www/$probe"
                done
              '')
            ];
          };
          config.Cmd = [
            "httpd"
            "-f"
            "-p"
            "8080"
            "-h"
            "/www"
          ];
        };
        origin = list "gateway-test-origin" [
          {
            apiVersion = "v1";
            kind = "Namespace";
            metadata.name = "origin";
          }
          {
            apiVersion = "v1";
            kind = "Namespace";
            metadata.name = "identity";
          }
          {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              name = "origin";
              namespace = "origin";
            };
            spec = {
              selector.matchLabels.app = "origin";
              template = {
                metadata.labels.app = "origin";
                spec.containers = [
                  {
                    name = "origin";
                    image = "${originImage.imageName}:${originImage.imageTag}";
                    imagePullPolicy = "Never";
                    ports = [ { containerPort = 8080; } ];
                  }
                ];
              };
            };
          }
          {
            apiVersion = "v1";
            kind = "Service";
            metadata = {
              name = "origin";
              namespace = "origin";
            };
            spec = {
              selector.app = "origin";
              ports = [
                {
                  port = 8080;
                  targetPort = 8080;
                }
              ];
            };
          }
        ];
        address = ip: {
          networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
            {
              address = ip;
              prefixLength = 24;
            }
          ];
        };
        client =
          ip:
          { pkgs, ... }:
          {
            imports = [ (address ip) ];
            environment.systemPackages = [ pkgs.curl ];
          };
        test =
          (pkgs.testers.runNixOSTest {
            name = "gateway-runtime";
            requiredFeatures.kvm = true;
            nodes = {
              cluster =
                { pkgs, ... }:
                {
                  imports = [ (address nodeAddress) ];
                  networking.hostName = lib.mkForce instance;
                  networking.firewall.enable = false;
                  environment.systemPackages = [ pkgs.openssl pkgs.python3 ];
                  virtualisation = {
                    cores = 4;
                    memorySize = 4096;
                    diskSize = 8192;
                    restrictNetwork = false;
                  };
                  services.k3s = {
                    enable = true;
                    role = "server";
                    package = k3sPackage;
                    disable = [ "traefik" "metrics-server" ];
                    images = [
                      k3sPackage.airgap-images
                      originImage
                      provisionImage
                    ];
                    extraFlags = [
                      "--node-ip=${nodeAddress}"
                      "--flannel-iface=eth1"
                    ];
                  };
                };
              peer = { pkgs, ... }: {
                imports = [ (client peerAddress) ];
                virtualisation.memorySize = 2048;
                users.users.tester.isNormalUser = true;
                networking.hosts."127.0.0.1" =
                  cluster.routes.idm.hostnames ++ cluster.routes.argocd.hostnames;
                environment.systemPackages = [ browserPython pkgs.chromium pkgs.nssTools ];
                systemd.services.canonical-gateway = {
                  wantedBy = [ "multi-user.target" ];
                  after = [ "network-online.target" ];
                  serviceConfig.ExecStart =
                    "${pkgs.socat}/bin/socat TCP-LISTEN:443,bind=127.0.0.1,reuseaddr,fork TCP:${nodeAddress}:${nodePort}";
                };
              };
              stranger = client strangerAddress;
            };
            testScript = ''
              import json
              import shlex
              import time

              kubectl = "${k3sPackage}/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml"

              idm_host = "${builtins.head cluster.routes.idm.hostnames}"
              admin_host = "${builtins.head cluster.routes.argocd.hostnames}"

              def request(path, headers="", host="origin.test"):
                  return (
                      f"curl -ksS --max-time 5 {headers} "
                      f"--resolve {host}:${nodePort}:${nodeAddress} "
                      f"'https://{host}:${nodePort}/{path}'"
                  )

              def patch(resource, name, namespace, spec):
                  cluster.succeed(
                      f"{kubectl} patch {resource} {name} -n {namespace} --type=merge "
                      f"-p {shlex.quote(json.dumps({'spec': spec}))}"
                  )

              def reconciled(resource, name, namespace, expected, timeout=120,
                             ancestor=("gateway.networking.k8s.io", "Gateway", "household", "gateway")):
                  # Do not let a condition from an earlier generation or another
                  # controller/parent masquerade as reconciliation of this input.
                  last = {}
                  for _ in range(timeout):
                      last = json.loads(cluster.succeed(
                          f"{kubectl} get {resource} {name} -n {namespace} -o json"
                      ))
                      generation = last["metadata"]["generation"]
                      status = last.get("status", {})
                      if resource == "httproute":
                          owners = status.get("parents", [])
                          ref_key = "parentRef"
                      elif resource in ("backendtlspolicy", "clienttrafficpolicy", "securitypolicy", "envoyproxy"):
                          owners = status.get("ancestors", [])
                          ref_key = "ancestorRef"
                      else:
                          owners = [status]
                          ref_key = None
                      for owner in owners:
                          if ref_key:
                              # EnvoyProxy's own ancestor schema has no controllerName;
                              # Gateway API policy/route statuses do, and must match it.
                              ref = owner.get(ref_key, {})
                              # Envoy can omit a policy ancestor's namespace; use
                              # its known consumer, not the policy's own namespace.
                              default_namespace = namespace if ref_key == "parentRef" else ancestor[3]
                              if (
                                  (resource != "envoyproxy" and owner.get("controllerName") != "gateway.envoyproxy.io/gatewayclass-controller")
                                  or ref.get("name") != ancestor[2]
                                  or ref.get("kind", "Gateway") != ancestor[1]
                                  or ref.get("group", "gateway.networking.k8s.io") != ancestor[0]
                                  or ref.get("namespace", default_namespace) != ancestor[3]
                              ):
                                  continue
                          conditions = {c["type"]: c for c in owner.get("conditions", [])}
                          if all(
                              conditions.get(kind, {}).get("observedGeneration") == generation
                              and conditions[kind]["status"] == value
                              and (reason is None or conditions[kind].get("reason") == reason)
                              for kind, (value, reason) in expected.items()
                          ):
                              return last
                      time.sleep(1)
                  raise AssertionError(f"{resource}/{namespace}/{name} did not reconcile: {last.get('status')}")

              accepted = {"Accepted": ("True", None)}
              route_ready = {**accepted, "ResolvedRefs": ("True", None)}

              def idm_status(expected, request_id):
                  command = request(
                      "status", f"-H 'X-Request-ID: {request_id}'", idm_host
                  ) + " -o /tmp/idm-response -w '%{http_code}'"
                  peer.wait_until_succeeds(
                      f"test \"$({command})\" = {expected}", timeout=120
                  )
                  entry = access_log("status", request_id, expected)
                  assert str(entry["status"]) == str(expected), entry
                  return entry

              def access_log(path, request_id=None, status=None):
                  # Envoy flushes file access logs periodically, not per request.
                  logs = ""
                  for _ in range(30):
                      logs = cluster.succeed(
                          f"{kubectl} logs --namespace gateway -c envoy --tail=-1 "
                          "-l gateway.envoyproxy.io/owning-gateway-name=household"
                      )
                      entries = [json.loads(line) for line in logs.splitlines() if line.startswith("{")]
                      matches = [
                          entry for entry in entries
                          if entry.get("path") == f"/{path}"
                          and (request_id is None or entry.get("request_id") == request_id)
                          and (status is None or str(entry.get("status")) == str(status))
                      ]
                      if matches:
                          markers = ("query-secret", "bearer-secret", "cookie-secret", "callback-secret")
                          leaked = [marker for marker in markers if marker in logs]
                          fields = sorted({
                              key for entry in entries for key, value in entry.items()
                              if any(marker in str(value) for marker in leaked)
                          })
                          outside_access_log = any(
                              marker in line for line in logs.splitlines() if not line.startswith("{")
                              for marker in leaked
                          )
                          assert not leaked, (
                              "sensitive request data reached Envoy logs: "
                              f"synthetic_markers={leaked}, access_fields={fields}, "
                              f"outside_access_log={outside_access_log}"
                          )
                          return matches[-1]
                      time.sleep(1)
                  raise AssertionError(f"no matching access log entry for /{path}")

              start_all()
              cluster.wait_until_succeeds(f"{kubectl} get --raw=/readyz", timeout=300)
              cluster.succeed(f"{kubectl} apply -f ${manifests}/gateway-retained")
              cluster.succeed(f"{kubectl} apply --server-side -f ${manifests}/gateway-crds")
              cluster.wait_until_succeeds(
                  f"{kubectl} wait --for=condition=Established --timeout=10s "
                  "crd/gateways.gateway.networking.k8s.io crd/envoyproxies.gateway.envoyproxy.io "
                  "crd/clienttrafficpolicies.gateway.envoyproxy.io",
                  timeout=120,
              )
              cluster.succeed(f"{kubectl} apply --server-side -f ${manifests}/gateway-controller")
              cluster.wait_until_succeeds(
                  f"{kubectl} rollout status deployment/envoy-gateway --namespace gateway --timeout=10s",
                  timeout=900,
              )

              cluster.succeed(f"{kubectl} apply -f ${origin}")
              cluster.succeed(
                  "openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=fixture-ca "
                  "-addext basicConstraints=critical,CA:TRUE "
                  "-addext keyUsage=critical,keyCertSign,cRLSign "
                  "-keyout /tmp/ca.key -out /tmp/ca.crt"
              )
              cluster.succeed(
                  f"openssl req -new -newkey rsa:2048 -nodes -subj /CN={idm_host} "
                  "-keyout /tmp/idm.key -out /tmp/idm.csr && "
                  f"printf 'subjectAltName=DNS:{idm_host}\\nextendedKeyUsage=serverAuth\\n' > /tmp/idm.ext && "
                  "openssl x509 -req -in /tmp/idm.csr -CA /tmp/ca.crt -CAkey /tmp/ca.key "
                  "-CAcreateserial -days 1 -extfile /tmp/idm.ext -out /tmp/idm.crt && "
                  "chmod 0644 /tmp/idm.key"
              )
              cluster.succeed(
                  f"{kubectl} create configmap fixture-ca -n gateway "
                  "--from-file=ca-certificates.crt=/tmp/ca.crt"
              )
              cluster.succeed(
                  f"{kubectl} create configmap fixture-ca -n identity --from-file=ca.crt=/tmp/ca.crt"
              )
              cluster.succeed(
                  "openssl req -new -newkey rsa:2048 -nodes -subj /CN=origin.test "
                  "-keyout /tmp/tls.key -out /tmp/tls.csr && "
                  f"printf 'subjectAltName=DNS:origin.test,DNS:{idm_host},DNS:{admin_host}\\n"
                  "extendedKeyUsage=serverAuth\\n' > /tmp/gateway.ext && "
                  "openssl x509 -req -in /tmp/tls.csr -CA /tmp/ca.crt -CAkey /tmp/ca.key "
                  "-CAcreateserial -days 1 -extfile /tmp/gateway.ext -out /tmp/tls.crt"
              )
              cluster.succeed(
                  f"{kubectl} create secret tls gateway-tls --namespace gateway "
                  "--cert=/tmp/tls.crt --key=/tmp/tls.key"
              )
              cluster.succeed(
                  f"{kubectl} create secret tls kanidm-tls -n identity "
                  "--cert=/tmp/idm.crt --key=/tmp/idm.key"
              )
              cluster.succeed(f"{kubectl} apply -f ${nativeIdentity}")
              cluster.wait_until_succeeds(
                  f"{kubectl} rollout status deployment/kanidm -n identity --timeout=10s",
                  timeout=900,
              )
              cluster.succeed(f"{kubectl} apply -f ${direct}")
              reconciled("gatewayclass", "envoy", "gateway", accepted, timeout=900)
              reconciled("gateway", "household", "gateway", {
                  **accepted, "Programmed": ("True", None)
              }, timeout=900)
              reconciled("envoyproxy", "household", "gateway", accepted)
              reconciled("clienttrafficpolicy", "trusted-edges", "gateway", accepted)
              reconciled("httproute", "origin", "gateway", route_ready)
              reconciled("httproute", "idm", "gateway", route_ready)
              reconciled("backendtlspolicy", "idm", "identity", accepted)

              with subtest("a direct client reaches the origin through the NodePort"):
                  stranger.wait_until_succeeds(
                      request("index.html") + " | grep -qx origin", timeout=900
                  )

              with subtest("direct mode logs the connecting address and a fresh request ID, without the query"):
                  stranger.succeed(
                      request("direct-probe?token=query-secret",
                          "-H 'X-Forwarded-For: 198.51.100.9' -H 'X-Request-ID: client-supplied' "
                          "-H 'Authorization: Bearer bearer-secret' -H 'Cookie: session=cookie-secret'",
                      )
                  )
                  entry = access_log("direct-probe")
                  assert entry["client"] == "${strangerAddress}", entry
                  assert str(entry["status"]) == "200", entry
                  assert entry["request_id"] not in ("", "-", None, "client-supplied"), entry

              cluster.succeed(f"{kubectl} apply -f ${trusted}")
              reconciled("clienttrafficpolicy", "trusted-edges", "gateway", accepted)

              with subtest("clients that are not trusted edges cannot reach the origin"):
                  stranger.wait_until_fails(request("blocked-probe"), timeout=120)

              # The refusal above shows the origin policy is enforced, so the
              # trusted edge must now pass through it.
              with subtest("a trusted edge reaches the origin through the enforced policy"):
                  peer.wait_until_succeeds(request("trusted-probe") + " | grep -qx origin", timeout=120)
                  for _ in range(3):
                      stranger.fail(request("blocked-probe"))

              with subtest("a trusted edge's forwarded address and request ID are honoured"):
                  for attempt in range(30):
                      request_id = f"edge-request-{attempt}"
                      peer.succeed(
                          request(
                              "trusted-probe",
                              f"-H 'X-Forwarded-For: 198.51.100.7' -H 'X-Request-ID: {request_id}'",
                          )
                      )
                      entry = access_log("trusted-probe")
                      if entry["client"] == "198.51.100.7" and entry["request_id"] == request_id:
                          break
                      time.sleep(1)
                  else:
                      raise AssertionError(f"trusted-edge metadata was not honoured: {entry}")

              with subtest("the native HTTPS identity backend is trusted through its production TLS policy"):
                  idm_status(200, "tls-good")

              with subtest("a missing cross-namespace grant is reconciled and fails real traffic"):
                  before = reconciled("httproute", "idm", "gateway", route_ready)
                  cluster.succeed(f"{kubectl} delete referencegrant gateway-idm -n identity")
                  patch("httproute", "idm", "gateway", {
                      "rules": [{**before["spec"]["rules"][0],
                                 "timeouts": {"request": "16s", "backendRequest": "15s"}}]
                  })
                  after = reconciled("httproute", "idm", "gateway", {
                      **accepted, "ResolvedRefs": ("False", "RefNotPermitted")
                  })
                  assert after["metadata"]["generation"] > before["metadata"]["generation"]
                  idm_status(500, "grant-missing")
                  cluster.succeed(f"{kubectl} apply -f ${trusted}")
                  reconciled("httproute", "idm", "gateway", route_ready)
                  idm_status(200, "grant-restored")

              with subtest("an accepted TLS policy with the wrong hostname fails the actual handshake"):
                  before = reconciled("backendtlspolicy", "idm", "identity", accepted)
                  patch("backendtlspolicy", "idm", "identity", {
                      "validation": {"hostname": "wrong.test"}
                  })
                  after = reconciled("backendtlspolicy", "idm", "identity", accepted)
                  assert after["metadata"]["generation"] > before["metadata"]["generation"]
                  entry = idm_status(503, "tls-wrong-name")
                  assert "UF" in entry["response_flags"] and entry["upstream"] not in ("", "-", None), entry
                  cluster.succeed(f"{kubectl} apply -f ${trusted}")
                  reconciled("backendtlspolicy", "idm", "identity", accepted)
                  idm_status(200, "tls-name-restored")

              with subtest("an untrusted signing CA fails although the hostname and controller status are valid"):
                  cluster.succeed(
                      "openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=untrusted-ca "
                      "-addext basicConstraints=critical,CA:TRUE "
                      "-addext keyUsage=critical,keyCertSign,cRLSign "
                      "-keyout /tmp/wrong-ca.key -out /tmp/wrong-ca.crt && "
                      "openssl x509 -req -in /tmp/idm.csr -CA /tmp/wrong-ca.crt -CAkey /tmp/wrong-ca.key "
                      "-CAcreateserial -days 1 -extfile /tmp/idm.ext -out /tmp/untrusted-idm.crt"
                  )
                  for certificate, code, request_id in (
                      ("/tmp/untrusted-idm.crt", 503, "tls-wrong-ca"),
                      ("/tmp/idm.crt", 200, "tls-ca-restored"),
                  ):
                      cluster.succeed(
                          f"{kubectl} create secret tls kanidm-tls -n identity "
                          f"--cert={certificate} --key=/tmp/idm.key --dry-run=client -o yaml | "
                          f"{kubectl} apply -f -"
                      )
                      cluster.succeed(f"{kubectl} rollout restart deployment/kanidm -n identity")
                      cluster.wait_until_succeeds(
                          f"{kubectl} rollout status deployment/kanidm -n identity --timeout=10s",
                          timeout=180,
                      )
                      reconciled("httproute", "idm", "gateway", route_ready)
                      reconciled("backendtlspolicy", "idm", "identity", accepted)
                      entry = idm_status(code, request_id)
                      if code == 503:
                          assert "UF" in entry["response_flags"] and entry["upstream"] not in ("", "-", None), entry

              with subtest("the production Kanidm provisioner publishes native client credentials and MFA grants"):
                  # Recovery touches this disposable server's admin socket only.
                  # Secret values go straight to private files, never driver output.
                  cluster.succeed(
                      f"umask 077; {kubectl} exec deployment/kanidm -n identity -- "
                      "/sbin/kanidmd scripting recover-account idm_admin -c /etc/kanidm/server.toml "
                      "> /tmp/identity-recovery.json 2>/tmp/identity-recovery.log"
                  )
                  extraction = (
                      "import json,pathlib; p=pathlib.Path('/tmp/identity-recovery.json'); "
                      "r=json.loads(p.read_text()); assert r['status']=='ok'; "
                      "pathlib.Path('/tmp/idm-admin-password').write_text(r['output'])"
                  )
                  cluster.succeed("umask 077; python3 -c " + shlex.quote(extraction))
                  cluster.succeed(
                      f"{kubectl} create secret generic kanidm-provision -n identity "
                      "--from-file=idm-admin-password=/tmp/idm-admin-password"
                  )
                  cluster.succeed(f"{kubectl} apply -f ${identityDNS}")
                  cluster.succeed(f"{kubectl} rollout restart deployment/coredns -n kube-system")
                  cluster.wait_until_succeeds(
                      f"{kubectl} rollout status deployment/coredns -n kube-system --timeout=10s",
                      timeout=120,
                  )
                  # Go's discovery client uses its normal verified system roots.
                  # This changes only the isolated controller's trust input, not
                  # production images, OIDC settings or certificate validation.
                  controller_trust = {"spec": {"template": {"spec": {
                      "volumes": [{"name": "fixture-ca", "configMap": {"name": "fixture-ca"}}],
                      "containers": [{
                          "name": "envoy-gateway",
                          "env": [{"name": "SSL_CERT_FILE", "value": "/fixture-ca/ca-certificates.crt"}],
                          "volumeMounts": [{"name": "fixture-ca", "mountPath": "/fixture-ca", "readOnly": True}],
                      }],
                  }}}}
                  cluster.succeed(
                      f"{kubectl} patch deployment envoy-gateway -n gateway --type=strategic "
                      f"-p {shlex.quote(json.dumps(controller_trust))}"
                  )
                  cluster.wait_until_succeeds(
                      f"{kubectl} rollout status deployment/envoy-gateway -n gateway --timeout=10s",
                      timeout=180,
                  )
                  cluster.succeed(f"{kubectl} apply -f ${provision}")
                  cluster.wait_until_succeeds(
                      f"{kubectl} wait --for=condition=Complete job/kanidm-provision -n identity --timeout=10s",
                      timeout=600,
                  )
                  cluster.succeed(f"{kubectl} apply -f ${adminOrigin}")
                  cluster.succeed(f"{kubectl} apply -f ${adminPolicies}")
                  cluster.succeed(f"{kubectl} apply -f ${adminRoutes}")
                  reconciled("httproute", "argocd", "gateway", route_ready)
                  reconciled("backendtlspolicy", "kanidm-oidc-tls", "identity", accepted,
                             ancestor=("gateway.envoyproxy.io", "SecurityPolicy", "argocd-admin", "gateway"))
                  reconciled("securitypolicy", "argocd-admin", "gateway", accepted)

              with subtest("anonymous and spoofed identities cannot bypass the real OIDC filter"):
                  for headers in (
                      "",
                      "-H 'Authorization: Bearer bearer-secret'",
                      "-H 'Cookie: BearerToken=cookie-secret; OauthHMAC=cookie-secret'",
                      "-H 'X-Forwarded-User: ${administrator}' -H 'X-Auth-Request-User: ${administrator}'",
                  ):
                      peer.wait_until_succeeds(
                          "test \"$(" + request("index.html?token=query-secret", headers, admin_host)
                          + " -o /tmp/denied-response -w '%{http_code}')\" = 302",
                          timeout=120,
                      )
                      peer.fail("grep -qx origin /tmp/denied-response")
                  peer.succeed(
                      "test \"$(" + request("oauth2/callback?code=callback-secret&state=invalid", host=admin_host)
                      + " -o /tmp/callback-response -w '%{http_code}')\" = 401"
                  )
                  peer.fail("grep -qx origin /tmp/callback-response")

              with subtest("real verified passkeys allow an administrator and deny an equally authenticated nonmember"):
                  peer.wait_for_unit("canonical-gateway.service")
                  cluster.succeed(
                      "install -m 0600 /tmp/identity-recovery.json /tmp/shared/identity-recovery.json && "
                      "install -m 0644 /tmp/ca.crt /tmp/shared/fixture-ca.crt"
                  )
                  peer.succeed(
                      "install -m 0600 -o tester /tmp/shared/identity-recovery.json /home/tester/identity-recovery.json && "
                      "install -m 0644 -o tester /tmp/shared/fixture-ca.crt /home/tester/fixture-ca.crt && "
                      "rm -f /tmp/shared/identity-recovery.json /tmp/shared/fixture-ca.crt"
                  )
                  for nss_dir in ("/home/tester/.pki/nssdb", "/home/tester/.local/share/pki/nssdb"):
                      peer.succeed(f"install -d -m 0700 -o tester {nss_dir}")
                      peer.succeed(
                          "su -s /bin/sh tester -c " + shlex.quote(
                              f"certutil -N -d sql:{nss_dir} --empty-password && "
                              f"certutil -A -d sql:{nss_dir} -n fixture-ca -t 'C,,' "
                              "-i /home/tester/fixture-ca.crt"
                          )
                      )
                  browser_command = " ".join(shlex.quote(value) for value in (
                      "${browserPython}/bin/python3",
                      "${./_gateway-runtime/authorization.py}",
                      f"https://{idm_host}", f"https://{admin_host}", "${administrator}",
                      "/home/tester/identity-recovery.json", "/home/tester/fixture-ca.crt",
                      "${pkgs.chromium}/bin/chromium", "/home/tester/gateway-auth-results",
                  ))
                  try:
                      peer.succeed(
                          "su -s /bin/sh tester -c " + shlex.quote("umask 077; " + browser_command),
                          timeout=360,
                      )
                      # Fence the actual code callback before taking a log snapshot,
                      # so delayed file flushing cannot make a leaking path pass.
                      access_log("oauth2/callback", status=302)
                      cluster.succeed(
                          f"umask 077; {kubectl} logs -n gateway -c envoy --tail=-1 "
                          "-l gateway.envoyproxy.io/owning-gateway-name=household "
                          "> /tmp/shared/gateway-auth-access.log"
                      )
                      peer.succeed(
                          "install -m 0600 -o tester /tmp/shared/gateway-auth-access.log "
                          "/home/tester/gateway-auth-access.log && rm /tmp/shared/gateway-auth-access.log"
                      )
                      log_check = (
                          "import json,pathlib; root=pathlib.Path('/home/tester'); "
                          "secrets=json.loads((root/'gateway-auth-results/sensitive.json').read_text()); "
                          "logs=(root/'gateway-auth-access.log').read_text(); "
                          "assert all(value not in logs for value in secrets), 'native OIDC credentials reached access logs'"
                      )
                      peer.succeed("python3 -c " + shlex.quote(log_check))
                      access_log("oauth2/callback", status=401)
                  finally:
                      # Only sanitized final surfaces/results become test artifacts.
                      for filename in ("result.json", "administrator.png", "nonmember-denied.png"):
                          source = f"/home/tester/gateway-auth-results/{filename}"
                          if peer.execute(f"test -f {source}")[0] == 0:
                              peer.copy_from_machine(source, "gateway-authorization")
                      peer.succeed(
                          "rm -f /home/tester/identity-recovery.json /home/tester/gateway-auth-access.log "
                          "/home/tester/gateway-auth-results/sensitive.json "
                          "/tmp/shared/identity-recovery.json /tmp/shared/gateway-auth-access.log"
                      )
                      cluster.succeed(
                          f"{kubectl} delete secret kanidm-provision -n identity && "
                          "rm -f /tmp/identity-recovery.json /tmp/idm-admin-password /tmp/identity-recovery.log"
                      )
            '';
          }).overrideTestDerivation
            (_: {
              # Registry pulls of the pinned controller and proxy images.
              # Builders must permit this with sandbox = relaxed.
              __noChroot = true;
            });
      in
      {
        checks.gateway-runtime = test // {
          meta = test.meta // {
            hestia.group = "${system}-gateway-acceptance";
          };
        };
      }
    );
}
