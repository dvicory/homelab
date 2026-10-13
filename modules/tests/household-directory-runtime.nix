# Packet admission at Kanidm's private HTTPS and LDAPS ports. The real
# application's certificate and credential checks belong to its runtime test.
# This fixture applies the canonical policy, Service and NET_ADMIN-only enforcer
# without changing them, with K3s's embedded policy controller disabled.
{
  config,
  lib,
  self,
  ...
}:
let
  manifests = ../../generated/manifests/prod-home;
  productionK3s = self.nixosConfigurations.compute-1.config.services.k3s;
  k3sPackage = productionK3s.package;
  jellyfinSelector = config.den.clusters.prod-home.routes.jellyfin.backendPodSelector;
  nodeAddress = "10.0.0.10";
in
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        image = pkgs.dockerTools.buildImage {
          name = "homelab/household-directory-stand-in";
          tag = "1";
          copyToRoot = pkgs.buildEnv {
            name = "household-directory-stand-in-root";
            paths = [
              pkgs.busybox
              (pkgs.runCommand "household-directory-stand-in-www" { } ''
                mkdir -p "$out/www"
                echo household-directory > "$out/www/index.html"
              '')
            ];
          };
        };
        # Read generated resources at build time, after the parent regenerates
        # them. Expected callers never come from the policy being tested.
        inputs =
          pkgs.runCommand "household-directory-runtime-inputs"
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

              root, out = map(pathlib.Path, sys.argv[1:])
              resources = [
                  item
                  for path in sorted(root.rglob("*.yaml"))
                  for item in yaml.safe_load_all(path.read_text())
                  if item
              ]
              image = "${image.imageName}:${image.imageTag}"
              selector = json.loads('${builtins.toJSON jellyfinSelector}')

              def resource(kind, namespace, name):
                  return next(item for item in resources if item["kind"] == kind
                              and item["metadata"].get("namespace") == namespace
                              and item["metadata"]["name"] == name)

              def template(namespace, name):
                  item = next(item for item in resources
                              if item["metadata"].get("namespace") == namespace
                              and item["metadata"]["name"] == name
                              and item["kind"] in ("Deployment", "StatefulSet", "Job", "CronJob"))
                  spec = item["spec"]
                  if item["kind"] == "CronJob":
                      spec = spec["jobTemplate"]["spec"]
                  return spec["template"]

              kanidm = template("identity", "kanidm")
              ports = [port for container in kanidm["spec"]["containers"]
                       for port in container.get("ports", [])
                       if port.get("protocol", "TCP") == "TCP"]
              assert {8443, 3636} <= {port["containerPort"] for port in ports}, ports
              jellyfin = template("jellyfin", "jellyfin")["metadata"]["labels"]
              assert selector and selector.items() <= jellyfin.items(), jellyfin
              items, clients = [], {}

              def pod(name, namespace, labels, https=False, ldaps=False, served=None):
                  served = served or [{"containerPort": 9999, "protocol": "TCP"}]
                  numbers = " ".join(str(port["containerPort"]) for port in served)
                  items.append({
                      "apiVersion": "v1", "kind": "Pod",
                      "metadata": {"name": name, "namespace": namespace, "labels": labels},
                      "spec": {
                          "terminationGracePeriodSeconds": 0,
                          "containers": [{
                              "name": "stand-in", "image": image, "imagePullPolicy": "Never",
                              "command": ["sh", "-c", f"for port in {numbers}; do httpd -p $port -h /www; done; exec sleep 2147483647"],
                              "ports": served,
                          }],
                      },
                  })
                  if name != "kanidm":
                      clients[name] = {"namespace": namespace, "8443": https, "3636": ldaps}

              pod("kanidm", "identity", kanidm["metadata"]["labels"], served=ports)
              pod("jellyfin", "jellyfin", jellyfin, ldaps=True)
              # Every required Pod label must match, not just the app name.
              for index, key in enumerate(sorted(selector)):
                  for mode in ("missing", "wrong"):
                      labels = dict(jellyfin)
                      if mode == "missing":
                          labels.pop(key)
                      else:
                          labels[key] = "not-jellyfin"
                      pod(f"jellyfin-{mode}-{index}", "jellyfin", labels)

              namespaces = {"jellyfin", "identity", "gateway", "argocd", "media", "default"}
              for namespace in sorted(namespaces):
                  pod(f"stranger-{namespace}", namespace, {"app.kubernetes.io/name": "stranger"},
                      https=namespace == "identity")
                  if namespace != "jellyfin":
                      pod(f"copied-jellyfin-{namespace}", namespace, jellyfin,
                          https=namespace == "identity")

              gateway = resource("Gateway", "gateway", "household")["metadata"]
              proxy_labels = {
                  "gateway.envoyproxy.io/owning-gateway-name": gateway["name"],
                  "gateway.envoyproxy.io/owning-gateway-namespace": gateway["namespace"],
              }
              pod("gateway-proxy", "gateway", proxy_labels, https=True)
              pod("copied-gateway", "default", proxy_labels)
              for namespace, name in (("argocd", "argocd-server"), ("identity", "kanidm-provision")):
                  labels = template(namespace, name)["metadata"]["labels"]
                  pod(name, namespace, labels, https=True)
                  pod(f"copied-{name}", "default", labels)

              policies = [item for item in resources if item["kind"] == "NetworkPolicy"
                          and item["metadata"].get("namespace") == "identity"]
              assert any(item["metadata"]["name"] == "kanidm-private" for item in policies)
              enforcer = [item for path in sorted((root / "network-policy").glob("*.yaml"))
                          for item in yaml.safe_load_all(path.read_text()) if item]
              assert any(item["kind"] == "DaemonSet" for item in enforcer)

              def save(name, objects):
                  (out / f"{name}.json").write_text(json.dumps({"apiVersion": "v1", "kind": "List", "items": objects}))

              save("namespaces", [{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": namespace}}
                                  for namespace in sorted(namespaces - {"default"})])
              save("stand-ins", items)
              save("services", [resource("Service", "identity", "kanidm")])
              save("policies", policies)
              save("enforcer", enforcer)
              (out / "clients.json").write_text(json.dumps(clients))
              PY
            '';
        test =
          (pkgs.testers.runNixOSTest {
            name = "household-directory-runtime";
            requiredFeatures.kvm = true;
            nodes.cluster = {
              networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
                {
                  address = nodeAddress;
                  prefixLength = 24;
                }
              ];
              networking.firewall.enable = false;
              environment.systemPackages = [ pkgs.nftables pkgs.procps ];
              virtualisation = {
                cores = 4;
                memorySize = 4096;
                diskSize = 8192;
                # Only the canonical enforcer image needs registry access.
                restrictNetwork = false;
              };
              services.k3s = {
                enable = true;
                role = "server";
                package = k3sPackage;
                disable = [ "traefik" "metrics-server" ];
                images = [ k3sPackage.airgap-images image ];
                extraKubeProxyConfig = productionK3s.extraKubeProxyConfig;
                extraFlags = [
                  "--node-ip=${nodeAddress}"
                  "--flannel-iface=eth1"
                  "--disable-network-policy"
                ];
              };
            };
            testScript = ''
              import json
              import re
              import shlex

              kubectl = "${k3sPackage}/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml"
              clients = json.load(open("${inputs}/clients.json"))
              start_all()
              cluster.wait_until_succeeds(f"{kubectl} get --raw=/readyz", timeout=300)
              cluster.succeed(f"{kubectl} apply -f ${inputs}/namespaces.json")
              for namespace in sorted({client["namespace"] for client in clients.values()}):
                  cluster.wait_until_succeeds(f"{kubectl} get serviceaccount default --namespace {namespace}", timeout=60)
              cluster.succeed(f"{kubectl} apply -f ${inputs}/enforcer.json")
              cluster.wait_until_succeeds(
                  f"{kubectl} rollout status daemonset/kube-network-policies --namespace kube-system --timeout=10s",
                  timeout=600,
              )
              cluster.succeed(f"{kubectl} apply -f ${inputs}/stand-ins.json -f ${inputs}/services.json")
              for namespace in sorted({client["namespace"] for client in clients.values()}):
                  cluster.wait_until_succeeds(
                      f"{kubectl} wait --for=condition=Ready pod --all --namespace {namespace} --timeout=10s",
                      timeout=300,
                  )
              pod_ip = cluster.succeed(f"{kubectl} get pod kanidm -n identity -o jsonpath='{{.status.podIP}}'").strip()
              service = json.loads(cluster.succeed(f"{kubectl} get service kanidm -n identity -o json"))
              service_ports = {port["name"]: port["port"] for port in service["spec"]["ports"]}
              targets = {
                  "pod": {8443: (pod_ip, 8443), 3636: (pod_ip, 3636)},
                  "service": {8443: (service["spec"]["clusterIP"], service_ports["https"]),
                              3636: (service["spec"]["clusterIP"], service_ports["ldaps"])},
              }

              def reach(client, target, port):
                  address, destination = targets[target][port]
                  return (f"{kubectl} exec {client} --namespace {clients[client]['namespace']} -- "
                          f"wget -q -O - -T 3 http://{address}:{destination}/")

              with subtest("all negative callers reach both listeners before policy isolation"):
                  for client in clients:
                      for target in targets:
                          for port in (8443, 3636):
                              cluster.wait_until_succeeds(reach(client, target, port), timeout=60)

              cluster.succeed(f"{kubectl} apply -f ${inputs}/policies.json")
              with subtest("only exact Jellyfin labels in its namespace reach LDAPS; HTTPS callers retain admission"):
                  for port in (3636, 8443):
                      for target in targets:
                          # Wait for every deny boundary, not just one early rule.
                          for client, plan in clients.items():
                              if not plan[str(port)]:
                                  cluster.wait_until_fails(reach(client, target, port), timeout=120)
                                  print(f"EVIDENCE refused {plan['namespace']}/{client} -> kanidm {target}:{port}")
                          for client, plan in clients.items():
                              if plan[str(port)]:
                                  cluster.wait_until_succeeds(reach(client, target, port), timeout=60)
                                  assert "household-directory" in cluster.succeed(reach(client, target, port))
                                  print(f"EVIDENCE admitted {plan['namespace']}/{client} -> kanidm {target}:{port}")

              with subtest("the production NET_ADMIN enforcer, not kube-router, decides the packets"):
                  cluster.succeed("nft list table inet kube-network-policies")
                  cluster.succeed("nft list table ip kube-proxy")
                  assert not re.search(r"KUBE-ROUTER|KUBE-POD-FW|KUBE-NWPLCY", cluster.succeed("nft list ruleset"))
                  pid = cluster.succeed("pgrep -o -f '^/bin/netpol'").strip()
                  status = dict(line.split(':', 1) for line in cluster.succeed(f"cat /proc/{pid}/status").splitlines() if ':' in line)
                  assert int(status["CapEff"].strip(), 16) == 1 << 12, status
                  assert status["NoNewPrivs"].strip() == "1", status
                  logs = cluster.succeed(f"{kubectl} logs daemonset/kube-network-policies -n kube-system")
                  assert "Created plugin" in logs and "failed to create NRI plugin" not in logs, logs
                  enforcer = json.loads(cluster.succeed(f"{kubectl} get pods -n kube-system -l app.kubernetes.io/name=kube-network-policies -o json"))["items"][0]["metadata"]["name"]
                  metrics = cluster.succeed(f"{kubectl} get --raw " + shlex.quote(f"/api/v1/namespaces/kube-system/pods/{enforcer}:9080/proxy/metrics"))
                  verdicts = {}
                  for line in metrics.splitlines():
                      match = re.match(r'kube_network_policies_packet_count\{.*verdict="(\w+)".*\} (\S+)', line)
                      if match:
                          verdicts[match[1]] = verdicts.get(match[1], 0) + float(match[2])
                  assert verdicts.get("accept", 0) > 0 and verdicts.get("drop", 0) > 0, verdicts
                  print(f"EVIDENCE NET_ADMIN-only enforcer, nftables kube-proxy, no kube-router; verdicts={verdicts}")
            '';
          }).overrideTestDerivation (_: {
            # Match compute-network-policy-runtime: its digest-pinned enforcer
            # is pulled in the disposable VM; the builder needs sandbox=relaxed.
            __noChroot = true;
          });
      in
      {
        checks.household-directory-runtime = test // {
          meta = test.meta // {
            hestia.group = "${system}-household-directory-runtime";
          };
        };
      }
    );
}
