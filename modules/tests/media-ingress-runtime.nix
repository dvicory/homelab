# Behaviour test: who reaches the media apps that have no login of their own.
#
# Radarr, Sonarr, Prowlarr and SABnzbd trust the Gateway's central sign-in
# and ask for no login, so any pod that reaches their port can use the UI.
# A K3s node, whose embedded policy controller enforces NetworkPolicy,
# applies every committed NetworkPolicy in the media namespace. Stand-in pods
# carry the pod labels of the committed media workloads and listen on the
# app ports; a Gateway proxy stand-in carries the proxy's labels. The test
# shows that the Gateway proxy and each declared client reach their apps,
# that every other pod, in media or elsewhere, is refused, and that a
# cluster administrator's port-forward still works for recovery.
#
# All images are local, so the test needs no registry access.
{
  lib,
  self,
  ...
}:
let
  manifests = ../../generated/manifests/prod-home;
  k3sPackage = self.nixosConfigurations.compute-1.config.services.k3s.package;
  nodeAddress = "10.0.0.10";
  # App ports, as in the media aspects.
  servers = {
    radarr = 7878;
    sonarr = 8989;
    prowlarr = 9696;
    sabnzbd = 8080;
  };
  # The declared in-cluster clients of each app, besides the Gateway proxy.
  # media-contracts derives the same matrix from the media configuration.
  declared = {
    radarr = [
      "media-configarr"
      "prowlarr"
      "seerr"
      "media-config-seerr"
    ];
    sonarr = [
      "media-configarr"
      "prowlarr"
      "seerr"
      "media-config-seerr"
    ];
    prowlarr = [
      "media-configarr"
      "radarr"
      "sonarr"
    ];
    sabnzbd = [
      "radarr"
      "sonarr"
    ];
  };
in
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        image = pkgs.dockerTools.buildImage {
          name = "homelab/media-ingress-stand-in";
          tag = "1";
          copyToRoot = pkgs.buildEnv {
            name = "media-ingress-stand-in-root";
            paths = [
              pkgs.busybox
              (pkgs.runCommand "media-ingress-stand-in-www" { } ''
                mkdir -p "$out/www"
                echo stand-in > "$out/www/index.html"
              '')
            ];
          };
        };
        # Stand-in pods with the committed workload pod labels, and the
        # committed media NetworkPolicies, as kubectl Lists.
        inputs =
          pkgs.runCommand "media-ingress-inputs"
            {
              nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) ];
            }
            ''
              mkdir "$out"
              python - ${manifests} "$out" <<'PY'
              import json
              import pathlib
              import sys
              import yaml

              root, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
              servers = json.loads('${builtins.toJSON servers}')
              image = "${image.imageName}:${image.imageTag}"
              resources = [
                  item
                  for path in sorted(root.rglob("*.yaml"))
                  for item in yaml.safe_load_all(path.read_text())
                  if item
              ]

              def pod(name, namespace, labels, port):
                  return {
                      "apiVersion": "v1",
                      "kind": "Pod",
                      "metadata": {"name": name, "namespace": namespace, "labels": labels},
                      "spec": {
                          "terminationGracePeriodSeconds": 0,
                          "containers": [{
                              "name": "stand-in",
                              "image": image,
                              "imagePullPolicy": "Never",
                              "command": ["httpd", "-f", "-p", str(port), "-h", "/www"],
                          }],
                      },
                  }

              pods = {}
              for item in resources:
                  if item["metadata"].get("namespace") != "media":
                      continue
                  spec = item.get("spec", {})
                  if item["kind"] == "CronJob":
                      spec = spec["jobTemplate"]["spec"]
                  elif item["kind"] not in ("Deployment", "StatefulSet", "Job"):
                      continue
                  name = item["metadata"]["name"]
                  labels = spec["template"]["metadata"]["labels"]
                  assert pods.get(name, labels) == labels, name
                  pods[name] = labels
              assert set(servers) | {"seerr", "media-configarr", "media-config-seerr"} <= set(pods), sorted(pods)
              items = [pod(name, "media", labels, servers.get(name, 9999)) for name, labels in sorted(pods.items())]
              items += [
                  pod("stranger", "media", {"app.kubernetes.io/name": "stranger"}, 9999),
                  pod("outsider", "default", {"app.kubernetes.io/name": "outsider"}, 9999),
                  pod("gateway-proxy", "gateway", {
                      "gateway.envoyproxy.io/owning-gateway-name": "household",
                      "gateway.envoyproxy.io/owning-gateway-namespace": "gateway",
                  }, 9999),
              ]
              (out / "stand-ins.json").write_text(json.dumps({"apiVersion": "v1", "kind": "List", "items": items}))
              (out / "names.json").write_text(json.dumps({item["metadata"]["name"]: item["metadata"]["namespace"] for item in items}))
              policies = [
                  item for item in resources
                  if item["kind"] == "NetworkPolicy" and item["metadata"]["namespace"] == "media"
              ]
              assert policies
              (out / "policies.json").write_text(json.dumps({"apiVersion": "v1", "kind": "List", "items": policies}))
              print("policies:", sorted(item["metadata"]["name"] for item in policies))
              PY
            '';
        test = pkgs.testers.runNixOSTest {
          name = "media-ingress-runtime";
          requiredFeatures.kvm = true;
          nodes.cluster = {
            networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
              {
                address = nodeAddress;
                prefixLength = 24;
              }
            ];
            networking.firewall.enable = false;
            virtualisation = {
              cores = 4;
              memorySize = 4096;
              diskSize = 8192;
            };
            services.k3s = {
              enable = true;
              role = "server";
              package = k3sPackage;
              disable = [
                "traefik"
                "metrics-server"
              ];
              images = [
                k3sPackage.airgap-images
                image
              ];
              extraFlags = [
                "--node-ip=${nodeAddress}"
                "--flannel-iface=eth1"
              ];
            };
          };
          testScript = ''
            import json

            kubectl = "${k3sPackage}/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml"
            servers = json.loads('${builtins.toJSON servers}')
            declared = json.loads('${builtins.toJSON declared}')
            names = json.loads(open("${inputs}/names.json").read())

            start_all()
            cluster.wait_until_succeeds(f"{kubectl} get --raw=/readyz", timeout=300)
            cluster.succeed(f"{kubectl} create namespace media")
            cluster.succeed(f"{kubectl} create namespace gateway")
            cluster.wait_until_succeeds(f"{kubectl} get serviceaccount default --namespace media", timeout=60)
            cluster.wait_until_succeeds(f"{kubectl} get serviceaccount default --namespace gateway", timeout=60)
            cluster.succeed(f"{kubectl} apply -f ${inputs}/stand-ins.json")
            for namespace in sorted(set(names.values())):
                cluster.wait_until_succeeds(
                    f"{kubectl} wait --for=condition=Ready pod --all --namespace {namespace} --timeout=10s",
                    timeout=300,
                )
            address = {
                server: cluster.succeed(
                    f"{kubectl} get pod {server} --namespace media -o jsonpath='{{.status.podIP}}'"
                ).strip()
                for server in servers
            }

            def reach(client, server):
                return (
                    f"{kubectl} exec {client} --namespace {names[client]} -- "
                    f"wget -q -O /dev/null -T 3 http://{address[server]}:{servers[server]}/"
                )

            with subtest("without the media policies, every pod reaches every app"):
                for server in servers:
                    cluster.wait_until_succeeds(reach("stranger", server), timeout=120)
                    cluster.succeed(reach("outsider", server))

            cluster.succeed(f"{kubectl} apply -f ${inputs}/policies.json")

            with subtest("a media pod that is not a declared client is refused at each app port"):
                for server in servers:
                    cluster.wait_until_fails(reach("stranger", server), timeout=120)

            with subtest("the Gateway proxy and each declared client reach their apps"):
                for server, clients in declared.items():
                    for client in ["gateway-proxy"] + clients:
                        cluster.wait_until_succeeds(reach(client, server), timeout=60)
                        print(f"EVIDENCE admitted {client} -> {server}:{servers[server]}")

            with subtest("every other pod, in media or elsewhere, is refused"):
                for server, clients in declared.items():
                    for client in sorted(set(names) - set(clients) - {"gateway-proxy", server}):
                        cluster.fail(reach(client, server))
                        print(f"EVIDENCE refused {client} -> {server}:{servers[server]}")

            # The recovery path when the Gateway or Kanidm is down: a cluster
            # administrator's port-forward enters the pod's own network
            # namespace, so the policies do not block it.
            with subtest("a cluster administrator's port-forward still reaches each app"):
                for offset, (server, port) in enumerate(sorted(servers.items())):
                    local = 18000 + offset
                    cluster.succeed(
                        f"systemd-run --unit=forward-{server} "
                        f"{kubectl} port-forward --address 127.0.0.1 --namespace media pod/{server} {local}:{port}"
                    )
                    cluster.wait_until_succeeds(f"${pkgs.curl}/bin/curl -sSf http://127.0.0.1:{local}/", timeout=60)
                    print(f"EVIDENCE port-forward reaches {server}:{port}")
          '';
        };
      in
      {
        checks.media-ingress-runtime = test // {
          meta = test.meta // {
            hestia.group = "${system}-media-ingress-runtime";
          };
        };
      }
    );
}
