package bootstrap

// These tests read the real generated bootstrap bundle named by
// HOUSEHOLD_BOOTSTRAP_MANIFESTS, so they exercise the Jobs and controllers the
// charts actually render. The household-bootstrap-generated check supplies the
// bundle and sets HOUSEHOLD_BOOTSTRAP_REQUIRE_BUNDLE so they cannot skip there.

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func generatedBundle(t *testing.T) (Manifests, *Tools) {
	t.Helper()
	dir := os.Getenv("HOUSEHOLD_BOOTSTRAP_MANIFESTS")
	if dir == "" {
		if os.Getenv("HOUSEHOLD_BOOTSTRAP_REQUIRE_BUNDLE") != "" {
			t.Fatal("HOUSEHOLD_BOOTSTRAP_MANIFESTS is required")
		}
		t.Skip("HOUSEHOLD_BOOTSTRAP_MANIFESTS is unset; the household-bootstrap-generated check runs this test")
	}
	manifests, err := OpenManifests(dir)
	if err != nil {
		t.Fatal(err)
	}
	return manifests, NewTools(io.Discard, io.Discard)
}

func bundleResources(t *testing.T, manifests Manifests, tools *Tools, name string) []Resource {
	t.Helper()
	if !manifests.present(name) {
		return nil
	}
	resources, err := manifests.resources(context.Background(), tools, name)
	if err != nil {
		t.Fatal(err)
	}
	return resources
}

func withStatus(raw map[string]any, status map[string]any) map[string]any {
	object := make(map[string]any, len(raw)+1)
	for key, value := range raw {
		object[key] = value
	}
	object["status"] = status
	return object
}

// healthyObject returns the declared object as a healthy cluster reports it,
// or nil when Kubernetes would already have deleted it.
func healthyObject(resource Resource) map[string]any {
	spec := mapField(resource.Raw, "spec")
	switch resource.Kind {
	case "Deployment", "StatefulSet":
		replicas, _ := intField(spec, "replicas", 1)
		return withStatus(resource.Raw, map[string]any{"readyReplicas": replicas})
	case "DaemonSet":
		return withStatus(resource.Raw, map[string]any{"desiredNumberScheduled": 1, "numberReady": 1})
	case "Prometheus", "Alertmanager":
		object := withStatus(resource.Raw, map[string]any{"conditions": []any{
			map[string]any{"type": "Available", "status": "True", "observedGeneration": 1},
		}})
		metadata := make(map[string]any)
		for key, value := range mapField(resource.Raw, "metadata") {
			metadata[key] = value
		}
		metadata["generation"] = 1
		object["metadata"] = metadata
		return object
	case "Job":
		if _, collected := spec["ttlSecondsAfterFinished"]; collected {
			return nil
		}
		completions, _ := intField(spec, "completions", 1)
		return withStatus(resource.Raw, map[string]any{
			"succeeded":  completions,
			"conditions": []any{map[string]any{"type": "Complete", "status": "True"}},
		})
	}
	return withStatus(resource.Raw, map[string]any{})
}

// clusterTools answers `kubectl get KIND NAME --namespace NS` from objects
// written under a state directory, the way the API server answers for a
// cluster in that state.
func clusterTools(t *testing.T, state string) *Tools {
	t.Helper()
	stub := filepath.Join(t.TempDir(), "kubectl")
	script := `#!/bin/sh
[ "$1" = get ] || { echo "unexpected kubectl call: $*" >&2; exit 1; }
kind=$2 name=$3 ns=default
shift 3
while [ $# -gt 0 ]; do
  case $1 in --namespace) ns=$2; shift ;; esac
  shift
done
file="$BOOTSTRAP_TEST_STATE/$kind/$ns/$name.json"
if [ -f "$file" ]; then cat "$file"; fi
`
	if err := os.WriteFile(stub, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	tools := NewTools(io.Discard, io.Discard)
	tools.KubectlPath = stub
	tools.Env = append(os.Environ(), "BOOTSTRAP_TEST_STATE="+state)
	return tools
}

func writeClusterObject(t *testing.T, state string, resource Resource, object map[string]any) string {
	t.Helper()
	dir := filepath.Join(state, strings.ToLower(resource.Kind), resource.Namespace)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(object)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, resource.Name+".json")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// After bootstrap finishes, Kubernetes deletes Jobs that set
// ttlSecondsAfterFinished. --status must still report such a cluster healthy,
// and must still fail when a declared controller is actually missing.
func TestStatusOnHealthyClusterAfterJobCollection(t *testing.T) {
	manifests, parser := generatedBundle(t)
	state := t.TempDir()
	var controllerFile string
	collected := 0
	for _, name := range []string{"readiness.yaml", "operator-readiness.yaml", "jobs.yaml"} {
		for _, resource := range bundleResources(t, manifests, parser, name) {
			object := healthyObject(resource)
			if object == nil {
				collected++
				continue
			}
			path := writeClusterObject(t, state, resource, object)
			if name == "readiness.yaml" && controllerFile == "" {
				controllerFile = path
			}
		}
	}
	t.Logf("%d TTL-managed Jobs already collected", collected)

	if err := Status(context.Background(), clusterTools(t, state), manifests); err != nil {
		t.Fatalf("--status on a healthy cluster: %v", err)
	}

	if controllerFile == "" {
		t.Fatal("the bundle declares no controllers to check")
	}
	if err := os.Remove(controllerFile); err != nil {
		t.Fatal(err)
	}
	if err := Status(context.Background(), clusterTools(t, state), manifests); err == nil {
		t.Fatal("--status passed with a declared controller missing")
	}
}

// Every Job that bootstrap runs and waits on must be recoverable with
// --retry-jobs when it fails.
func TestRetryJobsCoversGeneratedBootstrapJobs(t *testing.T) {
	manifests, parser := generatedBundle(t)
	declared := make(map[string]Resource)
	for _, resource := range bundleResources(t, manifests, parser, "jobs.yaml") {
		declared[resource.Namespace+"/"+resource.Name] = resource
	}
	waited := bundleResources(t, manifests, parser, "pre-install-jobs.yaml")
	if len(waited) == 0 {
		t.Fatal("the bundle declares no bootstrap Jobs")
	}
	failed := map[string]any{"conditions": []any{map[string]any{"type": "Failed", "status": "True"}}}
	for _, job := range waited {
		key := job.Namespace + "/" + job.Name
		resource, ok := declared[key]
		if !ok {
			t.Errorf("%s: bootstrap waits on a Job that --retry-jobs cannot find in jobs.yaml", key)
			continue
		}
		if !retryCandidate(resource) {
			t.Errorf("%s: --retry-jobs does not consider this Job", key)
			continue
		}
		if retry, err := retryableJob(withStatus(resource.Raw, failed)); err != nil || !retry {
			t.Errorf("%s: failed Job not retryable: retry=%v err=%v", key, retry, err)
		}
	}
}
