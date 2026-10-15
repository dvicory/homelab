"""Monitoring boundaries, checked against the native nixidy output."""
import json
from pathlib import Path
import re
import sys

import yaml

root = Path(sys.argv[1])
inputs = json.loads(Path(sys.argv[2]).read_text())
routes = inputs["routes"]
has_grafana = "grafana" in routes


def objects(application):
    return [obj for path in sorted((root / application).glob("*.yaml"))
            for obj in yaml.safe_load_all(path.read_text()) if obj]


def find(items, kind, name):
    return next(obj for obj in items if obj["kind"] == kind and obj["metadata"]["name"] == name)


monitoring = objects("monitoring")
retained = objects("monitoring-retained")
identity = objects("identity")
gateway = objects("identity-gateway")
applications = {obj["metadata"]["name"]: obj for obj in objects("apps") if obj["kind"] == "Application"}


def wave(obj):
    return int(obj["metadata"].get("annotations", {}).get("argocd.argoproj.io/sync-wave", "0"))


def data(name):
    return find(monitoring, "ConfigMap", name)["data"]


def quantity(value, units):
    text = str(value)
    for unit, scale in units.items():
        if text.endswith(unit):
            return int(text[:-len(unit)]) * scale
    return int(text)


pod_specs = [obj["spec"]["template"]["spec"] for obj in monitoring
             if obj["kind"] in ("Deployment", "StatefulSet", "DaemonSet")]
containers = [c for spec in pod_specs for c in spec.get("initContainers", []) + spec["containers"]]
scrape_jobs = json.loads(data("victoriametrics-scrape")["scrape.json"])["scrape_configs"]
job_names = {job["job_name"] for job in scrape_jobs}
blackbox = next(job for job in scrape_jobs if job["job_name"] == "blackbox")
probed_routes = [target["labels"]["route"] for target in blackbox["static_configs"]]
rules = [rule for group in json.loads(data("vmalert-rules")["rules.json"])["groups"] for rule in group["rules"]]
source_down_jobs = {rule["labels"]["job"] for rule in rules if rule.get("alert") == "TelemetrySourceDown"}
policies = [obj for obj in monitoring if obj["kind"] == "NetworkPolicy"]
vm = find(monitoring, "Deployment", "victoriametrics")["spec"]["template"]["spec"]
volumes = {v["name"]: v for v in vm["volumes"]}
pv = find(retained, "PersistentVolume", "monitoring-metrics")["spec"]
ksm_args = find(monitoring, "Deployment", "kube-state-metrics")["spec"]["template"]["spec"]["containers"][0]["args"]
ksm_resources = next(arg.removeprefix("--resources=").split(",") for arg in ksm_args if arg.startswith("--resources="))


def selects(policy, selector):
    match = policy["spec"]["podSelector"].get("matchLabels", {})
    return bool(match) and all(selector.get(key) == value for key, value in match.items())

gateway_peer = {
    "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "gateway"}},
    "podSelector": {"matchLabels": {"gateway.envoyproxy.io/owning-gateway-name": "household"}},
}



checks = dict(inputs["hostChecks"])
checks.update({
    "a non-monitoring Application syncs at wave 5 or later, where a degraded monitoring child could block it":
        all(name in ("monitoring", "monitoring-retained") or wave(app) < 5 for name, app in applications.items()),
    "a monitoring Application syncs before wave 5":
        all(wave(applications[name]) >= 5 for name in ("monitoring", "monitoring-retained")),
    "a route serves a monitoring Service other than Grafana, or Grafana's route is not an administrator route":
        all(route["namespace"] != "monitoring" or route["service"] == "grafana" for route in routes.values())
        and (not has_grafana or routes["grafana"]["auth"] == "admin"),
    "a declared route has no endpoint probe": sorted(probed_routes) == sorted(routes),
    "a scrape job has no TelemetrySourceDown alert": job_names <= source_down_jobs,
    "a Watchdog core source is not scraped": {"kubelet", "cadvisor", "kube-state-metrics", "host-node"} <= job_names,
    "a monitoring image is not pinned as tag@digest":
        all(re.fullmatch(r"[^@ ]+:[^@ ]+@sha256:[0-9a-f]{64}", c["image"]) for c in containers),
    "a monitoring chart has no pinned version and hash":
        all(chart["hash"] is not None and re.fullmatch(r".*-[0-9]+\.[0-9]+\.[0-9]+", chart["name"]) for chart in inputs["charts"]),
    "VictoriaMetrics does not store only on the static local volume of its retained path":
        volumes["storage"].get("persistentVolumeClaim", {}).get("claimName") == "monitoring-metrics"
        and pv.get("local", {}).get("path") == inputs["metricsPath"]
        and pv["storageClassName"] == ""
        and find(retained, "PersistentVolumeClaim", "monitoring-metrics")["spec"]["volumeName"] == "monitoring-metrics",
    "VictoriaMetrics can start without the persistent state root's marker":
        volumes["state-marker"].get("hostPath") == {"path": inputs["markerPath"], "type": "File"},
    "a monitoring volume creates its host path":
        all(v.get("hostPath", {}).get("type") != "DirectoryOrCreate" for spec in pod_specs for v in spec.get("volumes", [])),
    "a monitoring container has no CPU or memory limit, or the total exceeds 3 CPU and 3.5Gi":
        all("cpu" in c.get("resources", {}).get("limits", {}) and "memory" in c.get("resources", {}).get("limits", {}) for c in containers)
        and sum(quantity(c["resources"]["limits"]["cpu"], {"m": 1}) if str(c["resources"]["limits"]["cpu"]).endswith("m")
                else int(c["resources"]["limits"]["cpu"]) * 1000 for c in containers) <= 3000
        and sum(quantity(c["resources"]["limits"]["memory"], {"Ki": 1024, "Mi": 1024**2, "Gi": 1024**3}) for c in containers) <= 3584 * 1024**2,
    "the monitoring namespace has no default-deny ingress policy":
        find(monitoring, "NetworkPolicy", "default-deny-ingress")["spec"] == {"podSelector": {}, "policyTypes": ["Ingress"]},
    "a monitoring Service is selected by no NetworkPolicy":
        all(any(selects(policy, service["spec"]["selector"]) for policy in policies) for service in monitoring if service["kind"] == "Service"),
    "something other than the Gateway may reach Grafana":
        not has_grafana or [rule["from"] for rule in find(monitoring, "NetworkPolicy", "grafana")["spec"]["ingress"]] == [[gateway_peer]],
    "kube-state-metrics exports Secrets or ConfigMaps, or its RBAC can write":
        "pods" in ksm_resources and not {"secrets", "configmaps"}.intersection(ksm_resources)
        and all(set(rule["verbs"]) <= {"get", "list", "watch"} for rule in find(monitoring, "ClusterRole", "kube-state-metrics")["rules"]),
    "Alertmanager does not start without its delivery credentials":
        next(v for v in find(monitoring, "Deployment", "alertmanager")["spec"]["template"]["spec"]["volumes"] if v["name"] == "delivery").get("secret", {}).get("optional", False),
    "the monitoring Namespace is not created before identity publishes into it":
        any(obj["kind"] == "Namespace" and obj["metadata"]["name"] == "monitoring" for obj in objects("identity-retained"))
        and wave(applications["identity-retained"]) < wave(applications["identity"]),
})

if has_grafana:
    provision = find(identity, "ConfigMap", "kanidm-provision")["data"]
    clients = [client for client in json.loads(provision["clients.json"]) if client["name"] == "grafana"]
    oauth = json.loads(provision["state.json"])["systems"]["oauth2"]["grafana"]
    grafana = find(monitoring, "Deployment", "grafana")["spec"]["template"]["spec"]
    env = next(c for c in grafana["containers"] if c["name"] == "grafana").get("env", [])
    password = next((e for e in env if e["name"] == "GF_SECURITY_ADMIN_PASSWORD"), {})
    volume = next((v for v in grafana["volumes"] if v["name"] == "admin-password"), {})
    security = find(gateway, "SecurityPolicy", "grafana-admin")
    http_route = find(gateway, "HTTPRoute", "grafana")
    grafana_ini = data("grafana").get("grafana.ini", "")
    dashboards = data("grafana-dashboards")
    checks.update({
        "the Gateway's backend policy admits more than the Gateway proxy to Grafana":
            all(rule.get("from") and all(
                all(expected["matchLabels"].items() <= peer.get(selector, {}).get("matchLabels", {}).items()
                    for selector, expected in gateway_peer.items())
                for peer in rule["from"])
                for rule in find(gateway, "NetworkPolicy", "gateway-grafana-backend-ingress")["spec"]["ingress"]),
        "Grafana's administrator password is stored rather than generated in memory at Pod start":
            password.get("value", "") == "$__file{/run/grafana-admin/password}"
            and volume.get("emptyDir", {}).get("medium", "") == "Memory" and len(grafana.get("initContainers", [])) == 1,
        "Grafana grants access other than through Kanidm sign-in by the administrator group":
            all(line in grafana_ini for line in [
                "client_id = grafana", "use_pkce = true", "role_attribute_strict = true",
                f"role_attribute_path = contains(groups[*], '{inputs['adminGroup']}') && 'Admin' || ''",
                "disable_login_form = true", "[auth.basic]\nenabled = false", "[auth.anonymous]\nenabled = false",
                "client_secret = $__file{/etc/secrets/grafana-oidc/client-secret}",
            ]),
        "Kanidm does not offer Grafana once, with both the entrance and Grafana callbacks":
            len(clients) == 1 and oauth["displayName"] == "Grafana"
            and all(f"https://{host}{path}" in oauth["originUrl"] for host in routes["grafana"]["hostnames"]
                    for path in ("/oauth2/callback", "/login/generic_oauth")),
        "identity does not publish Grafana's client secret into the monitoring namespace":
            {"namespace": "monitoring", "name": "grafana-oidc", "key": "client-secret", "labels": {}} in clients[0]["secrets"],
        "Grafana's route can sync before its entrance sign-in":
            security["spec"]["oidc"]["clientID"] == "grafana"
            and security["spec"]["targetRefs"] == [{"group": "gateway.networking.k8s.io", "kind": "HTTPRoute", "name": "grafana"}]
            and security["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"] == "-1"
            and http_route["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"] == "0",
        "Kanidm's NetworkPolicy does not admit Grafana's token exchange":
            any(peer.get("namespaceSelector", {}).get("matchLabels", {}).get("kubernetes.io/metadata.name") == "monitoring"
                and peer.get("podSelector", {}).get("matchLabels") == routes["grafana"]["backendPodSelector"]
                for rule in find(identity, "NetworkPolicy", "kanidm-private")["spec"]["ingress"] for peer in rule.get("from", [])),
        "a provisioned dashboard is not valid JSON": all(isinstance(json.loads(text), dict) for text in dashboards.values()),
        "Grafana provisions dashboards beyond the minimal set": sorted(dashboards) == [
            "homelab-overview.json", "k8s-resources-namespace.json", "k8s-resources-pod.json", "node-exporter-full.json",
        ],
    })

failures = sorted(name for name, passed in checks.items() if not passed)
assert not failures, "Monitoring contract checks failed:\n- " + "\n- ".join(failures)
print(f"monitoring contracts: {len(checks)} assertions passed against {root}")
