package main

import (
	"encoding/json"
	"io"
	"strconv"
	"strings"
)

// Keep the same fixed-vocabulary boundary as the native API report: no raw
// journal, stderr, kubeconfig, token, arbitrary condition message or unit value
// crosses back to the caller, even when a probe or its JSON decoding fails.
type readinessWitness struct {
	Probe      string               `json:"probe"`
	Completed  bool                 `json:"completed"`
	Markers    []string             `json:"markers,omitempty"`
	Service    map[string]string    `json:"service,omitempty"`
	Conditions []readinessCondition `json:"conditions,omitempty"`
}

type readinessCondition struct {
	Type    string   `json:"type"`
	Status  string   `json:"status"`
	Markers []string `json:"markers,omitempty"`
}

var readinessMarkers = []string{
	"failed to run kubelet", "failed to validate kubelet configuration", "unrecognized feature gate",
	"container runtime is down", "container runtime network not ready", "networkpluginnotready",
	"cni plugin not initialized", "failed to initialize top level qos containers", "failed to create shim task",
	"failed to generate container spec", "failed to create sandbox", "failed to start containerd",
	"failed to load plugin", "failed to register node", "node not found", "connection refused",
	"permission denied", "operation not permitted", "read-only file system", "invalid argument",
	"no space left on device", "certificate signed by unknown authority", "certificate has expired",
	"cgroup", "swap", "user namespace", "setgroups", "oom_score_adj", "apparmor", "seccomp",
	"overlayfs", "userxattr", "nftables", "conntrack", "containerd successfully booted", "starting kubelet",
}

func diagnosticMarkers(content string) []string {
	content = strings.ToLower(content)
	var matches []string
	for _, marker := range readinessMarkers {
		if strings.Contains(content, marker) {
			matches = append(matches, marker)
		}
	}
	return matches
}

func serviceWitness(content string) map[string]string {
	result := map[string]string{}
	for _, line := range strings.Split(content, "\n") {
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch key {
		case "ActiveState", "SubState", "Result":
			switch value {
			case "active", "inactive", "failed", "activating", "deactivating", "running", "dead", "exited", "auto-restart", "start", "start-pre", "start-post", "stop", "stop-sigterm", "success", "exit-code", "signal", "timeout", "core-dump", "oom-kill", "start-limit-hit", "resources", "protocol":
				result[key] = value
			default:
				result[key] = "unknown"
			}
		case "ExecMainCode", "ExecMainStatus", "NRestarts":
			if number, err := strconv.ParseUint(value, 10, 32); err == nil {
				result[key] = strconv.FormatUint(number, 10)
			}
		}
	}
	return result
}

func conditionWitness(content []byte, cri bool) []readinessCondition {
	type condition struct{ Type, Status, Reason, Message string }
	var conditions []condition
	if cri {
		var response struct {
			Status struct {
				Conditions []struct {
					Type            string
					Status          bool
					Reason, Message string
				}
			}
		}
		if json.Unmarshal(content, &response) != nil {
			return nil
		}
		for _, value := range response.Status.Conditions {
			conditions = append(conditions, condition{value.Type, strconv.FormatBool(value.Status), value.Reason, value.Message})
		}
	} else {
		var response struct {
			Items []struct {
				Status struct{ Conditions []condition }
			}
		}
		if json.Unmarshal(content, &response) != nil {
			return nil
		}
		for _, item := range response.Items {
			conditions = append(conditions, item.Status.Conditions...)
		}
	}
	var result []readinessCondition
	for _, value := range conditions {
		switch value.Type {
		case "Ready", "MemoryPressure", "DiskPressure", "PIDPressure", "NetworkUnavailable", "RuntimeReady", "NetworkReady":
		default:
			continue
		}
		status := "unknown"
		switch value.Status {
		case "True", "False", "Unknown", "true", "false":
			status = value.Status
		}
		result = append(result, readinessCondition{value.Type, status, diagnosticMarkers(value.Reason + " " + value.Message)})
	}
	return result
}

type diagnosticBuffer struct{ content []byte }

func (b *diagnosticBuffer) Write(value []byte) (int, error) {
	const limit = 256 * 1024
	if remaining := limit - len(b.content); remaining > 0 {
		b.content = append(b.content, value[:min(len(value), remaining)]...)
	}
	return len(value), nil
}

func collectReadinessWitness(exec func([]string, io.Writer) error) []readinessWitness {
	probes := []struct {
		name string
		argv []string
	}{
		{"k3s-service", []string{"systemctl", "show", "k3s", "--property=ActiveState,SubState,Result,ExecMainCode,ExecMainStatus,NRestarts"}},
		{"k3s-journal", []string{"journalctl", "-u", "k3s", "-b", "--no-pager", "--reverse", "--lines=200", "--output=cat"}},
		{"containerd-log", []string{"tail", "-c", "131072", "/var/lib/rancher/k3s/agent/containerd/containerd.log"}},
		{"node-conditions", []string{"k3s", "kubectl", "--request-timeout=5s", "get", "nodes", "-o", "json"}},
		{"cri-conditions", []string{"k3s", "crictl", "--timeout=5", "info", "-o", "json"}},
	}
	result := make([]readinessWitness, 0, len(probes))
	for _, probe := range probes {
		var output diagnosticBuffer
		err := exec(probe.argv, &output)
		witness := readinessWitness{Probe: probe.name, Completed: err == nil}
		switch probe.name {
		case "k3s-service":
			witness.Service = serviceWitness(string(output.content))
		case "node-conditions", "cri-conditions":
			witness.Conditions = conditionWitness(output.content, probe.name == "cri-conditions")
		default:
			witness.Markers = diagnosticMarkers(string(output.content))
		}
		result = append(result, witness)
	}
	return result
}
