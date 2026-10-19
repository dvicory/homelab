# Cluster behaviour that monitoring relies on, checked against compute-1's
# K3s package, disabled components and flags (the embedded network-policy
# controller is off there) and the committed kube-network-policies enforcer,
# whose image the VM pulls from its registry:
# - Egress NetworkPolicy is enforced. The live drill for stopped ingestion
#   (monitoring runbook) blocks VictoriaMetrics' scrapes with an egress-deny
#   policy while its own API keeps answering, and proves nothing if egress
#   rules are ignored. A client pod that also serves HTTP loses its outbound
#   connections to another pod and to a node-local service, keeps answering
#   inbound requests, and regains outbound access when the policy is removed.
# - The kubelet and cAdvisor export the metrics the Watchdog and the OOM
#   rule read, so a K3s upgrade that renames one fails here first.
#
# The VM is not an unprivileged Incus container, as compute-1 is; the live
# drill remains the check of the deployed guest.
{ lib, self, ... }:
let
  compute = self.nixosConfigurations.compute-1.config;
  k3s = compute.services.k3s;
  busybox = "docker.io/rancher/mirrored-library-busybox:1.37.0";
  pod = name: command: {
    apiVersion = "v1";
    kind = "Pod";
    metadata = {
      inherit name;
      namespace = "drill";
      labels.app = name;
    };
    spec = {
      terminationGracePeriodSeconds = 0;
      containers = [
        {
          inherit name command;
          image = busybox;
          imagePullPolicy = "Never";
        }
      ];
    };
  };
  serve = port: [
    "sh"
    "-c"
    "mkdir -p /tmp/w && echo ok > /tmp/w/index.html && exec httpd -f -p ${toString port} -h /tmp/w"
  ];
  manifests = builtins.toJSON {
    apiVersion = "v1";
    kind = "List";
    items = [
      {
        apiVersion = "v1";
        kind = "Namespace";
        metadata.name = "drill";
      }
      (pod "target" (serve 8080))
      (pod "client" (serve 8081))
    ];
  };
  denyEgress = builtins.toJSON {
    apiVersion = "networking.k8s.io/v1";
    kind = "NetworkPolicy";
    metadata = {
      name = "deny-egress";
      namespace = "drill";
    };
    spec = {
      podSelector.matchLabels.app = "client";
      policyTypes = [ "Egress" ];
    };
  };
in
{
  perSystem =
    { pkgs, system, ... }:
    let
      # The enforcer, not K3s's embedded controller, must be what refuses.
      enforcer =
        assert lib.assertMsg (builtins.elem "--disable-network-policy" k3s.extraFlags)
          "compute-1 no longer disables K3s's embedded network-policy controller";
        builtins.toJSON {
          apiVersion = "v1";
          kind = "List";
          items = self.nixidyEnvs.${system}.prod-home.config.applications.network-policy.objects;
        };
      test =
        (pkgs.testers.runNixOSTest {
          name = "monitoring-k3s-runtime";
          requiredFeatures.kvm = true;
          nodes.machine = {
            system.stateVersion = "26.05";
            virtualisation = {
              cores = 2;
              memorySize = 3072;
              diskSize = 4096;
              restrictNetwork = false;
            };
            networking.firewall.enable = false;
            environment.systemPackages = [ pkgs.python3 ];
            environment.etc = {
              "drill/pods.json".text = manifests;
              "drill/deny-egress.json".text = denyEgress;
              "drill/enforcer.json".text = enforcer;
            };
            services.k3s = {
              enable = true;
              role = "server";
              inherit (k3s) package disable extraFlags;
              images = [ k3s.package.airgap-images ];
            };
          };
          testScript = ''
            kubectl = "${k3s.package}/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml"

            def fetch(source, url):
                return f"{kubectl} -n drill exec {source} -- wget -q -T 5 -O- {url}"

            start_all()
            machine.wait_for_unit("k3s.service")
            machine.wait_until_succeeds(f"{kubectl} get node -o name | grep -q node", timeout=300)
            machine.wait_until_succeeds(f"{kubectl} wait --for=condition=Ready node --all --timeout=10s", timeout=300)
            machine.succeed(f"{kubectl} apply --server-side -f /etc/drill/enforcer.json")
            machine.wait_until_succeeds(f"{kubectl} -n kube-system rollout status daemonset/kube-network-policies --timeout=30s", timeout=600)
            # The namespace's default ServiceAccount appears shortly after it.
            machine.wait_until_succeeds(f"{kubectl} apply -f /etc/drill/pods.json", timeout=60)
            machine.wait_until_succeeds(f"{kubectl} -n drill wait --for=condition=Ready pod --all --timeout=10s", timeout=300)
            target = machine.succeed(f"{kubectl} -n drill get pod target -o jsonpath='{{.status.podIP}}'").strip()
            client = machine.succeed(f"{kubectl} -n drill get pod client -o jsonpath='{{.status.podIP}}'").strip()
            node = machine.succeed(f"{kubectl} get node -o jsonpath='{{.items[0].status.addresses[?(@.type==\"InternalIP\")].address}}'").split()[0]
            # A service outside the cluster on the node, like the host exporter.
            machine.succeed("mkdir -p /tmp/w && echo ok > /tmp/w/index.html")
            machine.succeed("systemd-run --unit node-http python3 -m http.server 18080 --directory /tmp/w")
            machine.wait_for_open_port(18080)

            with subtest("the kubelet and cAdvisor export the metrics the rules read"):
                import re
                name = machine.succeed(f"{kubectl} get node -o jsonpath='{{.items[0].metadata.name}}'").strip()
                kubelet = machine.succeed(f"{kubectl} get --raw /api/v1/nodes/{name}/proxy/metrics")
                cadvisor = machine.succeed(f"{kubectl} get --raw /api/v1/nodes/{name}/proxy/metrics/cadvisor")
                for text, metric in ((kubelet, "kubelet_running_pods"), (cadvisor, "machine_cpu_cores"), (cadvisor, "container_oom_events_total")):
                    assert re.search(rf"^{metric}[{{ ]", text, re.M), metric
                print("EVIDENCE kubelet exports kubelet_running_pods; cAdvisor exports machine_cpu_cores and container_oom_events_total")

            with subtest("without a policy the client reaches a pod and the node"):
                machine.wait_until_succeeds(fetch("client", f"http://{target}:8080/"), timeout=60)
                machine.succeed(fetch("client", f"http://{node}:18080/"))

            with subtest("an egress-deny policy blocks the client's outbound connections"):
                machine.succeed(f"{kubectl} apply -f /etc/drill/deny-egress.json")
                machine.wait_until_fails(fetch("client", f"http://{target}:8080/"), timeout=120)
                machine.fail(fetch("client", f"http://{node}:18080/"))
                print("EVIDENCE egress-deny: client to pod and client to node-local service both refused")

            with subtest("the client still answers inbound requests"):
                machine.succeed(fetch("target", f"http://{client}:8081/"))
                print("EVIDENCE egress-deny: inbound requests to the client still answered")

            with subtest("removing the policy restores outbound access"):
                machine.succeed(f"{kubectl} -n drill delete networkpolicy deny-egress")
                machine.wait_until_succeeds(fetch("client", f"http://{target}:8080/"), timeout=120)
                machine.succeed(fetch("client", f"http://{node}:18080/"))
                print("EVIDENCE policy removed: outbound access restored")
          '';
        }).overrideTestDerivation
          (_: {
            # The VM pulls the enforcer image from its registry.
            __noChroot = true;
          });
    in
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        monitoring-k3s-runtime = test // {
          meta = test.meta // {
            hestia.group = "${system}-monitoring-k3s-runtime";
          };
        };
      };
    };
}
