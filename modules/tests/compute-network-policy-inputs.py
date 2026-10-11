"""Build the inputs of checks.compute-network-policy-runtime.

From the committed prod-home manifests this writes, as kubectl Lists:

  namespaces.json  every namespace a stand-in or policy lives in
  policies.json    every committed NetworkPolicy
  stand-ins.json   one Pod per committed workload, with the workload's pod
                   labels and container ports, serving HTTP on each TCP port;
                   plus a Gateway proxy, a stranger in media and an outsider
  filler.json      a Deployment, at zero replicas, of extra Pods that
                   committed policies select; the scenario scales it to
                   the node's Pod limit
  plan.json        stand-in names and namespaces, the policy-selected
                   stand-ins, the filler, and the probe rows

Run at build time only.
"""

import argparse
import json
import pathlib

import yaml

WORKLOADS = ("Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob")
GATEWAY_PROXY_LABELS = {
    "gateway.envoyproxy.io/owning-gateway-name": "household",
    "gateway.envoyproxy.io/owning-gateway-namespace": "gateway",
}
FILLER_NAMESPACE = "media"
FILLER_LIKE = "radarr"
# Representative boundaries: Kanidm's private policy, a Gateway backend
# policy and the media caller boundary, plus an unpoliced control pair.
PROBES = [
    ("gateway-proxy", "kanidm", 8443, True),
    ("argocd-server", "kanidm", 8443, True),
    ("outsider", "kanidm", 8443, False),
    ("stranger", "kanidm", 8443, False),
    ("gateway-proxy", "radarr", 7878, True),
    ("prowlarr", "radarr", 7878, True),
    ("stranger", "radarr", 7878, False),
    ("outsider", "sabnzbd", 8080, False),
    ("radarr", "sabnzbd", 8080, True),
    ("outsider", "stranger", 9999, True),
]


def list_of(items):
    return {"apiVersion": "v1", "kind": "List", "items": items}


def pod_template(item):
    spec = item["spec"]
    if item["kind"] == "CronJob":
        spec = spec["jobTemplate"]["spec"]
    return spec["template"]


def ports_of(template):
    seen = {}
    for container in template["spec"].get("containers", []):
        for port in container.get("ports", []):
            if port.get("protocol", "TCP") != "TCP":
                continue
            entry = {"containerPort": port["containerPort"], "protocol": "TCP"}
            if "name" in port:
                entry["name"] = port["name"]
            seen.setdefault(port["containerPort"], entry)
    return sorted(seen.values(), key=lambda port: port["containerPort"])


def container(image, ports):
    numbers = " ".join(str(port["containerPort"]) for port in ports)
    return {
        "name": "stand-in",
        "image": image,
        "imagePullPolicy": "Never",
        "command": [
            "sh",
            "-c",
            f"for port in {numbers}; do httpd -p $port -h /www; done; exec sleep 2147483647",
        ],
        "ports": ports,
    }


def pod(name, namespace, labels, ports, image):
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {"name": name, "namespace": namespace, "labels": labels},
        "spec": {"terminationGracePeriodSeconds": 0, "containers": [container(image, ports)]},
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("manifests", type=pathlib.Path)
    parser.add_argument("out", type=pathlib.Path)
    parser.add_argument("--image", required=True)
    args = parser.parse_args()

    resources = [
        item
        for path in sorted(args.manifests.rglob("*.yaml"))
        for item in yaml.safe_load_all(path.read_text())
        if item
    ]
    policies = [item for item in resources if item["kind"] == "NetworkPolicy"]
    assert policies, "no committed NetworkPolicy"

    services = [item for item in resources if item["kind"] == "Service"]

    def service_ports(namespace, labels):
        """Numeric target ports of the Services that select these labels;
        several app charts declare no containerPort."""
        result = []
        for service in services:
            selector = service["spec"].get("selector")
            if service["metadata"].get("namespace") != namespace or not selector:
                continue
            if selector.items() <= labels.items():
                for port in service["spec"].get("ports", []):
                    target = port.get("targetPort", port["port"])
                    if isinstance(target, int) and port.get("protocol", "TCP") == "TCP":
                        result.append({"containerPort": target, "protocol": "TCP"})
        return result

    workloads = {}
    for item in resources:
        if item["kind"] not in WORKLOADS:
            continue
        template = pod_template(item)
        if template["spec"].get("hostNetwork"):
            continue
        key = (item["metadata"]["namespace"], item["metadata"]["name"])
        labels = template.get("metadata", {}).get("labels", {})
        ports = {port["containerPort"]: port for port in service_ports(key[0], labels)}
        ports.update({port["containerPort"]: port for port in ports_of(template)})
        entry = (labels, sorted(ports.values(), key=lambda port: port["containerPort"]))
        # A CronJob and its first-run Job share a name and pod template.
        assert workloads.get(key, entry) == entry, key
        workloads[key] = entry

    stand_ins = [
        pod(name, namespace, labels, ports or [{"containerPort": 9999, "protocol": "TCP"}], args.image)
        for (namespace, name), (labels, ports) in sorted(workloads.items())
    ]
    control = [{"containerPort": 9999, "protocol": "TCP"}]
    stand_ins += [
        pod("gateway-proxy", "gateway", GATEWAY_PROXY_LABELS, control, args.image),
        pod("stranger", "media", {"app.kubernetes.io/name": "stranger"}, control, args.image),
        pod("outsider", "default", {"app.kubernetes.io/name": "outsider"}, control, args.image),
    ]
    names = {item["metadata"]["name"]: item["metadata"]["namespace"] for item in stand_ins}
    assert len(names) == len(stand_ins), "stand-in names must be unique"
    served = {
        item["metadata"]["name"]: [port["containerPort"] for port in item["spec"]["containers"][0]["ports"]]
        for item in stand_ins
    }
    for client, server, port, _ in PROBES:
        assert client in names and server in names, (client, server)
        assert port in served[server], (server, port, served[server])

    def selecting(namespace, labels):
        """Committed policies whose podSelector selects these pod labels."""
        result = []
        for policy in policies:
            selector = policy["spec"]["podSelector"]
            assert "matchExpressions" not in selector, policy["metadata"]["name"]
            if policy["metadata"]["namespace"] == namespace and selector.get("matchLabels", {}).items() <= labels.items():
                result.append(policy["metadata"]["name"])
        return result

    selected_stand_ins = sorted(
        item["metadata"]["name"]
        for item in stand_ins
        if selecting(item["metadata"]["namespace"], item["metadata"]["labels"])
    )
    labels, ports = workloads[(FILLER_NAMESPACE, FILLER_LIKE)]
    selected = selecting(FILLER_NAMESPACE, labels)
    assert selected, "filler Pods must be selected by a committed policy"
    filler = {
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {"name": "policy-filler", "namespace": FILLER_NAMESPACE},
        "spec": {
            "replicas": 0,
            "selector": {"matchLabels": labels},
            "template": {
                "metadata": {"labels": labels},
                "spec": {"terminationGracePeriodSeconds": 0, "containers": [container(args.image, ports)]},
            },
        },
    }

    namespaces = sorted(
        {item["metadata"]["namespace"] for item in stand_ins + policies} - {"default"}
    )
    (args.out / "namespaces.json").write_text(
        json.dumps(list_of([{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": name}} for name in namespaces]))
    )
    (args.out / "policies.json").write_text(json.dumps(list_of(policies)))
    (args.out / "stand-ins.json").write_text(json.dumps(list_of(stand_ins)))
    (args.out / "filler.json").write_text(json.dumps(filler))
    (args.out / "plan.json").write_text(
        json.dumps(
            {
                "names": names,
                "selected": selected_stand_ins,
                "filler": {"name": "policy-filler", "namespace": FILLER_NAMESPACE, "selectedBy": selected},
                "probes": [
                    {"client": c, "server": s, "port": p, "admitted": a} for c, s, p, a in PROBES
                ],
            },
            indent=2,
        )
    )
    print("policies:", len(policies), "stand-ins:", len(stand_ins), "filler selected by:", selected)


if __name__ == "__main__":
    main()
