{ inputs, lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        selected = inputs.self.nixosConfigurations.compute-1.config.services.k3s;
        previous = (import ./_security-baseline.nix { inherit system; }).k3s;
        imageName = "k3s-upgrade-volume-probe";
        image = pkgs.dockerTools.buildLayeredImage {
          name = imageName;
          tag = "fixture";
          contents = [ pkgs.busybox ];
        };
        test =
          assert lib.assertMsg (
            previous.version == "1.35.8+k3s1"
          ) "K3s recovery baseline must match the qualified production release";
          assert lib.assertMsg (lib.versionOlder previous.version selected.package.version)
            "K3s upgrade acceptance requires a genuinely newer selected release";
          pkgs.testers.runNixOSTest {
            name = "k3s-security-upgrade";
            globalTimeout = 30 * 60;
            requiredFeatures.kvm = true;
            nodes.machine = {
              system.stateVersion = "26.05";
              virtualisation = {
                cores = 2;
                memorySize = 4096;
                diskSize = 12288;
                restrictNetwork = true;
              };
              networking.firewall.enable = false;
              environment.systemPackages = [ pkgs.jq ];
              services.k3s = {
                enable = true;
                role = "server";
                package = previous;
                inherit (selected)
                  disable
                  extraFlags
                  extraKubeletConfig
                  extraKubeProxyConfig
                  ;
                images = [
                  previous.airgap-images
                  image
                ];
              };
              specialisation.security-update.configuration.services.k3s = {
                package = lib.mkForce selected.package;
                images = lib.mkForce [
                  selected.package.airgap-images
                  image
                ];
              };
            };
            testScript = ''
              import json
              import shlex

              kubectl = "k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml --request-timeout=10s"
              namespace = "upgrade-qualification"
              marker = "retained-volume-before-upgrade"

              def apply(items):
                  manifest = json.dumps({"apiVersion": "v1", "kind": "List", "items": items})
                  machine.succeed(f"printf %s {shlex.quote(manifest)} | {kubectl} apply -f -")

              def resource(kind, name, namespaced=True):
                  scope = f"-n {namespace}" if namespaced else ""
                  return json.loads(machine.succeed(f"{kubectl} {scope} get {kind} {name} -o json"))

              def ready(version):
                  machine.wait_for_unit("k3s.service")
                  expected = shlex.quote("v" + version)
                  machine.wait_until_succeeds(
                      f"{kubectl} get --raw=/version | jq -e --arg expected {expected} '.gitVersion == $expected'",
                      timeout=300,
                  )
                  machine.wait_until_succeeds(
                      f"{kubectl} wait --for=condition=Ready nodes --all --timeout=10s", timeout=300
                  )

              def probe(name, write=False):
                  command = (
                      f"test ! -e /volume/marker; printf '%s\\n' {marker} > /volume/marker; chmod 0600 /volume/marker"
                      if write else f"test $(cat /volume/marker) = {marker}"
                  )
                  apply([{
                      "apiVersion": "batch/v1", "kind": "Job",
                      "metadata": {"name": name, "namespace": namespace},
                      "spec": {"backoffLimit": 0, "template": {"spec": {
                          "restartPolicy": "Never", "hostNetwork": True, "dnsPolicy": "Default",
                          "automountServiceAccountToken": False,
                          "containers": [{"name": "probe", "image": "${imageName}:fixture",
                              "imagePullPolicy": "Never", "command": ["/bin/sh", "-ec", command],
                              "volumeMounts": [{"name": "retained", "mountPath": "/volume"}]}],
                          "volumes": [{"name": "retained", "persistentVolumeClaim": {"claimName": "retained"}}],
                      }}},
                  }])
                  machine.wait_until_succeeds(
                      f"{kubectl} -n {namespace} wait --for=condition=Complete job/{name} --timeout=10s",
                      timeout=300,
                  )
                  assert machine.succeed("stat -c '%a:%u:%g' /srv/qualification-volume/marker").strip() == "600:0:0"

              def retained():
                  objects = {
                      "namespace": resource("namespace", namespace, False),
                      "configmap": resource("configmap", "retained"),
                      "secret": resource("secret", "retained"),
                      "pv": resource("pv", "qualification-volume", False),
                      "pvc": resource("pvc", "retained"),
                  }
                  assert objects["configmap"]["data"] == {"marker": "before-upgrade"}
                  assert objects["secret"]["data"] == {"marker": "YmVmb3JlLXVwZ3JhZGU="}
                  assert objects["pvc"]["status"]["phase"] == "Bound"
                  return {kind: value["metadata"]["uid"] for kind, value in objects.items()}

              start_all()
              ready("${previous.version}")
              baseline = machine.succeed("readlink -f /run/current-system").strip()
              updated = baseline + "/specialisation/security-update"

              with subtest("old release creates durable cluster objects and a real bound volume"):
                  apply([
                      {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": namespace}},
                      {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "retained", "namespace": namespace},
                          "data": {"marker": "before-upgrade"}},
                      {"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "retained", "namespace": namespace},
                          "stringData": {"marker": "before-upgrade"}},
                      {"apiVersion": "v1", "kind": "PersistentVolume", "metadata": {"name": "qualification-volume"},
                          "spec": {"capacity": {"storage": "32Mi"}, "accessModes": ["ReadWriteOnce"],
                              "storageClassName": "", "persistentVolumeReclaimPolicy": "Retain",
                              "hostPath": {"path": "/srv/qualification-volume", "type": "DirectoryOrCreate"}}},
                      {"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": {"name": "retained", "namespace": namespace},
                          "spec": {"accessModes": ["ReadWriteOnce"], "storageClassName": "",
                              "volumeName": "qualification-volume", "resources": {"requests": {"storage": "32Mi"}}}},
                  ])
                  probe("write-before-upgrade", write=True)
                  identities = retained()
                  ca = machine.succeed("sha256sum /var/lib/rancher/k3s/server/tls/server-ca.crt").split()[0]
                  machine.succeed("systemctl stop k3s.service")
                  machine.succeed("tar --acls --xattrs -cpf /var/tmp/old-k3s-state.tar -C / var/lib/rancher etc/rancher srv/qualification-volume")

              with subtest("selected release preserves cluster identities, credentials and mounted volume data"):
                  machine.succeed(f"{updated}/bin/switch-to-configuration test", timeout=300)
                  ready("${selected.package.version}")
                  assert retained() == identities
                  assert machine.succeed("sha256sum /var/lib/rancher/k3s/server/tls/server-ca.crt").split()[0] == ca
                  probe("read-after-upgrade")

              with subtest("a cold prior-state restore works with the prior release, not an unsupported downgrade"):
                  machine.succeed("systemctl stop k3s.service")
                  machine.succeed("rm -rf /var/lib/rancher /etc/rancher /srv/qualification-volume")
                  machine.succeed("tar --acls --xattrs -xpf /var/tmp/old-k3s-state.tar -C /")
                  machine.succeed(f"{baseline}/bin/switch-to-configuration test", timeout=300)
                  ready("${previous.version}")
                  assert retained() == identities
                  assert machine.succeed("sha256sum /var/lib/rancher/k3s/server/tls/server-ca.crt").split()[0] == ca
                  probe("read-after-cold-restore")
            '';
          };
      in
      {
        checks.k3s-security-upgrade = test // {
          meta = test.meta // {
            hestia.group = "${system}-k3s-security-upgrade";
          };
        };
      }
    );
}
