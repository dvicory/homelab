package bootstrap

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

type Manifests struct {
	Dir string
}

func OpenManifests(dir string) (Manifests, error) {
	if strings.TrimSpace(dir) == "" {
		return Manifests{}, errors.New("HOUSEHOLD_BOOTSTRAP_MANIFESTS is required")
	}
	info, err := os.Stat(dir)
	if err != nil {
		return Manifests{}, fmt.Errorf("cannot inspect bootstrap manifests: %w", err)
	}
	if !info.IsDir() {
		return Manifests{}, errors.New("HOUSEHOLD_BOOTSTRAP_MANIFESTS must name a directory")
	}
	return Manifests{Dir: dir}, nil
}

func (m Manifests) file(name string) string {
	return filepath.Join(m.Dir, name)
}

func (m Manifests) require(names ...string) error {
	for _, name := range names {
		path := m.file(name)
		info, err := os.Stat(path)
		if err != nil {
			return fmt.Errorf("bootstrap artifact is incomplete: %s", name)
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("bootstrap artifact is incomplete: %s", name)
		}
	}
	return nil
}

func (m Manifests) present(name string) bool {
	info, err := os.Stat(m.file(name))
	return err == nil && info.Mode().IsRegular() && info.Size() > 0
}

type Resource struct {
	Raw       map[string]any
	Kind      string
	Name      string
	Namespace string
}

func (m Manifests) resources(ctx context.Context, tools *Tools, name string) ([]Resource, error) {
	output, err := tools.RunYQ(ctx, "-o=json", "-N", ".", m.file(name))
	if err != nil {
		return nil, fmt.Errorf("cannot parse bootstrap artifact %s: %w", name, err)
	}
	if len(bytes.TrimSpace(output)) == 0 {
		return nil, nil
	}
	decoder := json.NewDecoder(bytes.NewReader(output))
	decoder.UseNumber()
	resources := make([]Resource, 0)
	for {
		var item any
		err := decoder.Decode(&item)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("cannot parse bootstrap artifact %s: %w", name, err)
		}
		object, ok := item.(map[string]any)
		if !ok || object == nil {
			continue
		}
		kind, _ := object["kind"].(string)
		metadata, _ := object["metadata"].(map[string]any)
		if metadata == nil {
			continue
		}
		resourceName, _ := metadata["name"].(string)
		if kind == "" || resourceName == "" {
			continue
		}
		namespace, _ := metadata["namespace"].(string)
		if namespace == "" {
			namespace = "default"
		}
		resources = append(resources, Resource{Raw: object, Kind: kind, Name: resourceName, Namespace: namespace})
	}
	return resources, nil
}

func mapField(object map[string]any, key string) map[string]any {
	value, _ := object[key].(map[string]any)
	return value
}

func stringField(object map[string]any, key string) string {
	value, _ := object[key].(string)
	return value
}

func intField(object map[string]any, key string, fallback int64) (int64, bool) {
	value, ok := object[key]
	if !ok || value == nil {
		return fallback, true
	}
	switch value := value.(type) {
	case json.Number:
		parsed, err := value.Int64()
		return parsed, err == nil
	case float64:
		return int64(value), value == float64(int64(value))
	case int:
		return int64(value), true
	case string:
		parsed, err := strconv.ParseInt(value, 10, 64)
		return parsed, err == nil
	default:
		return fallback, false
	}
}

func conditionTrue(object map[string]any, conditionType string) (map[string]any, bool) {
	status := mapField(object, "status")
	conditions, _ := status["conditions"].([]any)
	for _, item := range conditions {
		condition, ok := item.(map[string]any)
		if !ok || stringField(condition, "type") != conditionType || stringField(condition, "status") != "True" {
			continue
		}
		return condition, true
	}
	return nil, false
}

func objectState(kind string, object map[string]any) (state, details string) {
	spec := mapField(object, "spec")
	status := mapField(object, "status")
	switch kind {
	case "Deployment", "StatefulSet":
		desired, desiredOK := intField(spec, "replicas", 1)
		ready, readyOK := intField(status, "readyReplicas", 0)
		if desiredOK && readyOK && desired >= 0 && ready == desired {
			state = "READY"
		} else {
			state = "NOT_READY"
		}
		details = fmt.Sprintf("%d/%d ready", ready, desired)
	case "DaemonSet":
		desired, desiredOK := intField(status, "desiredNumberScheduled", 0)
		ready, readyOK := intField(status, "numberReady", 0)
		if desiredOK && readyOK && desired > 0 && ready == desired {
			state = "READY"
		} else {
			state = "NOT_READY"
		}
		details = fmt.Sprintf("%d/%d ready", ready, desired)
	case "Prometheus", "Alertmanager":
		state = "NOT_READY"
		generation, generationOK := intField(mapField(object, "metadata"), "generation", -1)
		available, availableOK := conditionTrue(object, "Available")
		observed, observedOK := intField(available, "observedGeneration", -2)
		if availableOK && generationOK && observedOK && observed == generation {
			state = "READY"
		}
		details = stringField(available, "reason")
	case "Job":
		desired, _ := intField(spec, "completions", 1)
		succeeded, _ := intField(status, "succeeded", 0)
		if _, ok := conditionTrue(object, "Complete"); ok {
			state = "READY"
		} else if _, ok := conditionTrue(object, "Failed"); ok {
			state = "FAILED"
		} else {
			state = "NOT_READY"
		}
		details = fmt.Sprintf("%d/%d succeeded", succeeded, desired)
	default:
		state = "UNKNOWN"
		details = "unsupported declared kind"
	}
	return state, details
}

func (m Manifests) report(ctx context.Context, tools *Tools, name string) (int, error) {
	resources, err := m.resources(ctx, tools, name)
	if err != nil {
		return 0, err
	}
	unavailable := 0
	for _, declared := range resources {
		inspect, cancel := context.WithTimeout(ctx, 30*time.Second)
		objectOutput, getErr := tools.RunKubectl(inspect, "get", strings.ToLower(declared.Kind), declared.Name, "--namespace", declared.Namespace, "--ignore-not-found", "-o", "json", requestTimeout(25*time.Second))
		cancel()
		if getErr != nil {
			fmt.Fprintf(tools.Out, "  UNAVAILABLE %s %s/%s\n", declared.Kind, declared.Namespace, declared.Name)
			unavailable = 1
			continue
		}
		if len(bytes.TrimSpace(objectOutput)) == 0 {
			fmt.Fprintf(tools.Out, "  MISSING %s %s/%s\n", declared.Kind, declared.Namespace, declared.Name)
			unavailable = 1
			continue
		}
		var object map[string]any
		decoder := json.NewDecoder(bytes.NewReader(objectOutput))
		decoder.UseNumber()
		if decoder.Decode(&object) != nil || stringField(mapField(object, "metadata"), "name") != declared.Name {
			fmt.Fprintf(tools.Out, "  UNAVAILABLE %s %s/%s\n", declared.Kind, declared.Namespace, declared.Name)
			unavailable = 1
			continue
		}
		state, details := objectState(declared.Kind, object)
		fmt.Fprintf(tools.Out, "  %s %s %s/%s (%s)\n", state, declared.Kind, declared.Namespace, declared.Name, details)
	}
	return unavailable, nil
}

func Status(ctx context.Context, tools *Tools, manifests Manifests) error {
	if err := manifests.require("readiness.yaml", "operator-readiness.yaml", "jobs.yaml"); err != nil {
		return err
	}
	unavailable := 0
	fmt.Fprintln(tools.Out, "Declared controllers:")
	if manifests.present("readiness.yaml") {
		if value, err := manifests.report(ctx, tools, "readiness.yaml"); err != nil {
			return err
		} else {
			unavailable |= value
		}
	} else {
		fmt.Fprintln(tools.Out, "  (none declared)")
	}
	if manifests.present("operator-readiness.yaml") {
		if value, err := manifests.report(ctx, tools, "operator-readiness.yaml"); err != nil {
			return err
		} else {
			unavailable |= value
		}
	}
	fmt.Fprintln(tools.Out, "Declared bootstrap Jobs:")
	if manifests.present("jobs.yaml") {
		if value, err := manifests.report(ctx, tools, "jobs.yaml"); err != nil {
			return err
		} else {
			unavailable |= value
		}
	} else {
		fmt.Fprintln(tools.Out, "  (none declared)")
	}
	fmt.Fprintln(tools.Out, "Missing TTL-managed Helm Jobs may have been collected; their completion history is not retained.")
	if unavailable != 0 {
		return errors.New("one or more declared resources were unavailable")
	}
	return nil
}

func hookPolicy(policy string, wanted string) bool {
	for _, token := range strings.Split(policy, ",") {
		if strings.TrimSpace(token) == wanted {
			return true
		}
	}
	return false
}

func annotation(resource Resource, name string) string {
	metadata := mapField(resource.Raw, "metadata")
	return stringField(mapField(metadata, "annotations"), name)
}

func selectedJob(ctx context.Context, tools *Tools, manifests Manifests, namespace, name string) ([]byte, error) {
	return tools.RunYQEnv(ctx, map[string]string{"namespace": namespace, "name": name}, "-o=yaml", "-N", "select(.kind == \"Job\" and (.metadata.namespace // \"default\") == strenv(namespace) and .metadata.name == strenv(name))", manifests.file("jobs.yaml"))
}

func DeclaredNodes(ctx context.Context, tools *Tools, manifests Manifests) ([]string, error) {
	var values []string
	for _, expression := range []string{
		"select(.spec.template.spec.nodeSelector.\"kubernetes.io/hostname\" != null) | .spec.template.spec.nodeSelector.\"kubernetes.io/hostname\"",
		".. | select(tag == \"!!map\" and .key == \"kubernetes.io/hostname\") | .values[]",
	} {
		output, err := tools.RunYQ(ctx, "-r", "-N", expression, manifests.file("controllers.yaml"))
		if err != nil {
			return nil, errors.New("unable to inspect declared node placement")
		}
		values = append(values, strings.Split(string(output), "\n")...)
	}
	seen := make(map[string]struct{})
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" {
			seen[value] = struct{}{}
		}
	}
	result := make([]string, 0, len(seen))
	for value := range seen {
		result = append(result, value)
	}
	sort.Strings(result)
	return result, nil
}

func resourcesFromJSON(data []byte) ([]map[string]any, error) {
	var value any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	if object, ok := value.(map[string]any); ok {
		if items, ok := object["items"].([]any); ok {
			result := make([]map[string]any, 0, len(items))
			for _, item := range items {
				if resource, ok := item.(map[string]any); ok {
					result = append(result, resource)
				}
			}
			return result, nil
		}
		return []map[string]any{object}, nil
	}
	return nil, errors.New("Kubernetes response is not an object")
}

func allEstablished(data []byte) (bool, error) {
	resources, err := resourcesFromJSON(data)
	if err != nil {
		return false, err
	}
	if len(resources) == 0 {
		return false, nil
	}
	for _, resource := range resources {
		if _, ok := conditionTrue(resource, "Established"); !ok {
			return false, nil
		}
	}
	return true, nil
}

func sleepContext(ctx context.Context, duration time.Duration) error {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
