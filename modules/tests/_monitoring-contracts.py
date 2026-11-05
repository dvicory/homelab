"""Monitoring boundaries, checked against the native nixidy output."""
from configparser import ConfigParser
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
published_routes = [obj["metadata"]["name"] for obj in objects("gateway") + gateway
                    if obj["kind"] == "HTTPRoute"]
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
vm_deployment = find(monitoring, "Deployment", "victoriametrics")["spec"]
vm = vm_deployment["template"]["spec"]
vm_container = next(c for c in vm["containers"] if c["name"] == "victoriametrics")
vm_security = vm.get("securityContext", {}) | vm_container.get("securityContext", {})
volumes = {v["name"]: v for v in vm["volumes"]}
pv = find(retained, "PersistentVolume", "monitoring-metrics")["spec"]
ksm_args = find(monitoring, "Deployment", "kube-state-metrics")["spec"]["template"]["spec"]["containers"][0]["args"]
ksm_resources = next(arg.removeprefix("--resources=").split(",") for arg in ksm_args if arg.startswith("--resources="))


checks = dict(inputs["hostChecks"])
checks.update({
    "a non-monitoring Application syncs at wave 5 or later, where a degraded monitoring child could block it":
        all(name in ("monitoring", "monitoring-retained") or wave(app) < 5 for name, app in applications.items()),
    "a monitoring Application syncs before wave 5":
        all(wave(applications[name]) >= 5 for name in ("monitoring", "monitoring-retained")),
    "a route serves a monitoring Service other than Grafana, or Grafana's route is not an administrator route":
        all(route["namespace"] != "monitoring" or route["service"] == "grafana" for route in routes.values())
        and (not has_grafana or (routes["grafana"]["auth"] == "admin"
             and routes["grafana"]["manageBackendIngress"] and not routes["grafana"]["sameNamespaceIngress"])),
    "endpoint probes do not match published HTTP routes": sorted(probed_routes) == sorted(published_routes),
    "a scrape job has no TelemetrySourceDown alert": job_names <= source_down_jobs,
    "a Watchdog core source is not scraped": {"kubelet", "cadvisor", "kube-state-metrics", "host-node"} <= job_names,
    "a monitoring image is not pinned as tag@digest":
        all(re.fullmatch(r"[^@ ]+:[^@ ]+@sha256:[0-9a-f]{64}", c["image"]) for c in containers),
    "VictoriaMetrics no longer has one non-overlapping retained-store writer":
        vm_deployment.get("replicas", 1) == 1 and vm_deployment["strategy"]["type"] == "Recreate"
        and len(vm["containers"]) == 1
        and vm_security.get("runAsNonRoot", False)
        and vm_security.get("runAsUser") == inputs["metricsOwner"]["uid"]
        and vm_security.get("runAsGroup") == inputs["metricsOwner"]["gid"],
    "VictoriaMetrics has lost its narrowly bound read-only discovery credentials":
        vm["serviceAccountName"] == "victoriametrics"
        and not find(monitoring, "ServiceAccount", "victoriametrics").get("automountServiceAccountToken", True)
        and all(set(rule["verbs"]) <= {"get", "list", "watch"} and set(rule["resources"]) <= {"nodes", "nodes/metrics"}
                for rule in find(monitoring, "ClusterRole", "monitoring-victoriametrics")["rules"])
        and find(monitoring, "ClusterRoleBinding", "monitoring-victoriametrics")["roleRef"]["name"] == "monitoring-victoriametrics"
        and find(monitoring, "ClusterRoleBinding", "monitoring-victoriametrics")["subjects"] == [
            {"kind": "ServiceAccount", "name": "victoriametrics", "namespace": "monitoring"}],
    "VictoriaMetrics scrape configuration is not projected read-only":
        volumes["scrape"]["configMap"]["name"] == "victoriametrics-scrape"
        and any(mount["name"] == "scrape" and mount["mountPath"] == "/etc/victoriametrics" and mount.get("readOnly")
                for mount in vm_container["volumeMounts"]),
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
    container = next(c for c in grafana["containers"] if c["name"] == "grafana")
    env = container.get("env", [])
    password = next((e for e in env if e["name"] == "GF_SECURITY_ADMIN_PASSWORD"), {})
    grafana_volumes = {v["name"]: v for v in grafana["volumes"]}
    security = find(gateway, "SecurityPolicy", "grafana-admin")
    grafana_ini = ConfigParser(interpolation=None)
    grafana_ini.read_string(data("grafana").get("grafana.ini", ""))
    oauth_config = grafana_ini["auth.generic_oauth"]
    dashboards = data("grafana-dashboards")
    checks.update({
        "Grafana does not seed its disposable database from the managed password file":
            any(mount.get("readOnly") and password.get("value") == f"$__file{{{mount['mountPath']}/admin-password}}"
                and grafana_volumes[mount["name"]].get("secret", {}).get("secretName") == "grafana-admin"
                for mount in container["volumeMounts"])
            and any(mount["mountPath"] == "/var/lib/grafana" and "emptyDir" in grafana_volumes[mount["name"]]
                    for mount in container["volumeMounts"])
            and not any(obj["kind"] == "Secret" and obj["metadata"]["name"] == "grafana" for obj in monitoring),
        "Grafana grants access other than through Kanidm sign-in by the administrator group":
            oauth_config.getboolean("enabled") and oauth_config.getboolean("use_pkce")
            and oauth_config.getboolean("use_refresh_token") and oauth_config.getboolean("auto_login")
            and oauth_config.getboolean("role_attribute_strict")
            and not oauth_config.getboolean("allow_assign_grafana_admin")
            and oauth_config["client_id"] == "grafana"
            and oauth_config["role_attribute_path"] == f"contains(groups[*], '{inputs['adminGroup']}') && 'Admin' || ''"
            and oauth_config["client_secret"] == "$__file{/etc/secrets/grafana-oidc/client-secret}"
            and grafana_ini["security"]["secret_key"] == "$__file{/etc/secrets/grafana-admin/secret-key}"
            and grafana_ini["security"].getboolean("cookie_secure")
            and not grafana_ini["users"].getboolean("allow_sign_up")
            and grafana_ini["auth"].getboolean("disable_login_form")
            and not grafana_ini["auth"].get("oauth_auto_login")
            and not grafana_ini["auth.basic"].getboolean("enabled")
            and not grafana_ini["auth.anonymous"].getboolean("enabled"),
        "Kanidm does not offer Grafana once, with both the entrance and Grafana callbacks":
            len(clients) == 1
            and all(f"https://{host}{path}" in oauth["originUrl"] for host in routes["grafana"]["hostnames"]
                    for path in ("/oauth2/callback", "/login/generic_oauth")),
        "identity does not publish Grafana's client secret into the monitoring namespace":
            {"namespace": "monitoring", "name": "grafana-oidc", "key": "client-secret", "labels": {}} in clients[0]["secrets"],
        "Grafana's entrance does not use its central sign-in client and HTTPRoute":
            security["spec"]["oidc"]["clientID"] == "grafana"
            and security["spec"]["targetRefs"] == [{"group": "gateway.networking.k8s.io", "kind": "HTTPRoute", "name": "grafana"}],
        "Kanidm's NetworkPolicy does not admit Grafana's token exchange":
            any(peer.get("namespaceSelector", {}).get("matchLabels", {}).get("kubernetes.io/metadata.name") == "monitoring"
                and peer.get("podSelector", {}).get("matchLabels") == routes["grafana"]["backendPodSelector"]
                for rule in find(identity, "NetworkPolicy", "kanidm-private")["spec"]["ingress"] for peer in rule.get("from", [])),
        "a provisioned dashboard is not valid JSON": all(isinstance(json.loads(text), dict) for text in dashboards.values()),
    })

failures = sorted(name for name, passed in checks.items() if not passed)
assert not failures, "Monitoring contract checks failed:\n- " + "\n- ".join(failures)
print(f"monitoring contracts: {len(checks)} assertions passed against {root}")
