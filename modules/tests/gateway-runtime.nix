# Behaviour test: the household entrance as a client reaches it.
#
# A K3s node runs the Envoy Gateway CRDs and controller from the committed
# prod-home manifests and the entrance objects rendered by the gateway aspect
# (GatewayClass, EnvoyProxy, Gateway, ClientTrafficPolicy and, for trusted
# edges, the origin NetworkPolicy). Separate client machines connect through
# the NodePort, as the host DNAT does in production. Only the backend behind
# the Gateway and its TLS key are test-local.
#
# Images come from their registries: the controller and proxy are pinned by
# digest in the manifests, and containerd resolves digest references only
# against registry manifests.
{
  config,
  lib,
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
  entranceKinds = [
    "GatewayClass"
    "EnvoyProxy"
    "Gateway"
    "ClientTrafficPolicy"
    "NetworkPolicy"
  ];
  entranceObjects =
    inventory:
    lib.filter
      (
        object:
        lib.elem object.kind entranceKinds
        && (object.kind != "NetworkPolicy" || object.metadata.name == "private-origin")
      )
      (gateway.k8s-manifests {
        cluster = inventory;
        computeResources.instance = instance;
        charts = { };
        inherit lib;
      }).applications.gateway.objects;
  trustedCluster = lib.recursiveUpdate cluster {
    ingress = {
      mode = "trustedEdges";
      trustedProxyCIDRs = [ "${peerAddress}/32" ];
    };
  };
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
        direct = list "gateway-direct" (entranceObjects cluster);
        trusted = list "gateway-trusted-edges" (entranceObjects trustedCluster);
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
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              name = "origin";
              namespace = "gateway";
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
              namespace = "gateway";
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
          {
            apiVersion = "gateway.networking.k8s.io/v1";
            kind = "HTTPRoute";
            metadata = {
              name = "origin";
              namespace = "gateway";
            };
            spec = {
              parentRefs = [ { name = "household"; } ];
              hostnames = [ "origin.test" ];
              rules = [
                {
                  backendRefs = [
                    {
                      name = "origin";
                      port = 8080;
                    }
                  ];
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
                  environment.systemPackages = [ pkgs.openssl ];
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
                    disable = [ "traefik" ];
                    images = [
                      k3sPackage.airgap-images
                      originImage
                    ];
                    extraFlags = [
                      "--node-ip=${nodeAddress}"
                      "--flannel-iface=eth1"
                    ];
                  };
                };
              peer = client peerAddress;
              stranger = client strangerAddress;
            };
            testScript = ''
              import json
              import time

              kubectl = "${k3sPackage}/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml"
              resolve = "--resolve origin.test:${nodePort}:${nodeAddress}"
              url = "https://origin.test:${nodePort}"

              def request(path, headers=""):
                  return f"curl -ksS --max-time 5 {headers} {resolve} '{url}/{path}'"

              def access_log(path):
                  # Envoy flushes file access logs periodically, not per request.
                  logs = ""
                  for _ in range(30):
                      logs = cluster.succeed(
                          f"{kubectl} logs --namespace gateway -c envoy --tail=-1 "
                          "-l gateway.envoyproxy.io/owning-gateway-name=household"
                      )
                      entries = [json.loads(line) for line in logs.splitlines() if line.startswith("{")]
                      matches = [entry for entry in entries if entry.get("path") == f"/{path}"]
                      if matches:
                          assert "query-secret" not in logs, "a query string reached the access log"
                          return matches[-1]
                      time.sleep(1)
                  raise AssertionError(f"no access log entry for /{path}; log tail:\n{logs[-2000:]}")

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

              cluster.succeed(
                  "openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=origin.test "
                  "-addext subjectAltName=DNS:origin.test -keyout /tmp/tls.key -out /tmp/tls.crt"
              )
              cluster.succeed(
                  f"{kubectl} create secret tls gateway-tls --namespace gateway "
                  "--cert=/tmp/tls.crt --key=/tmp/tls.key"
              )
              cluster.succeed(f"{kubectl} apply -f ${origin}")
              cluster.succeed(f"{kubectl} apply -f ${direct}")

              with subtest("a direct client reaches the origin through the NodePort"):
                  stranger.wait_until_succeeds(
                      request("index.html") + " | grep -qx origin", timeout=900
                  )

              with subtest("direct mode logs the connecting address and a fresh request ID, without the query"):
                  stranger.succeed(
                      request("direct-probe?token=query-secret",
                          "-H 'X-Forwarded-For: 198.51.100.9' -H 'X-Request-ID: client-supplied'",
                      )
                  )
                  entry = access_log("direct-probe")
                  assert entry["client"] == "${strangerAddress}", entry
                  assert entry["request_id"] not in ("", "-", None, "client-supplied"), entry

              cluster.succeed(f"{kubectl} apply -f ${trusted}")

              with subtest("clients that are not trusted edges cannot reach the origin"):
                  stranger.wait_until_fails(request("blocked-probe"), timeout=120)

              # The refusal above shows the origin policy is enforced, so the
              # trusted edge must now pass through it.
              with subtest("a trusted edge reaches the origin through the enforced policy"):
                  peer.wait_until_succeeds(request("trusted-probe") + " | grep -qx origin", timeout=120)

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
