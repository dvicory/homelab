package bootstrap

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"
)

type runtimeSecret struct {
	Namespace string
	Name      string
	Type      string
	Keys      []string
}

var (
	secretNamespace = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`)
	secretName      = regexp.MustCompile(`^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$`)
	secretKey       = regexp.MustCompile(`^[a-zA-Z0-9._-]+$`)
	secretType      = regexp.MustCompile(`^[A-Za-z0-9./-]+$`)
)

func declaredRuntimeSecrets(raw json.RawMessage) ([]runtimeSecret, error) {
	var entries map[string]struct {
		Namespace string
		Name      string
		Key       string
		Type      string
	}
	if err := json.Unmarshal(raw, &entries); err != nil || entries == nil {
		return nil, errors.New("descriptor runtimeSecrets must be an explicit object")
	}
	groups := make(map[string]*runtimeSecret)
	seen := make(map[string]bool)
	for _, entry := range entries {
		if len(entry.Namespace) > 63 || !secretNamespace.MatchString(entry.Namespace) ||
			len(entry.Name) > 253 || !secretName.MatchString(entry.Name) ||
			len(entry.Key) > 253 || !secretKey.MatchString(entry.Key) || !secretType.MatchString(entry.Type) {
			return nil, errors.New("descriptor has invalid runtime Secret metadata")
		}
		id := entry.Namespace + "/" + entry.Name
		if seen[id+"/"+entry.Key] {
			return nil, fmt.Errorf("duplicate runtime Secret key in %s", id)
		}
		seen[id+"/"+entry.Key] = true
		group := groups[id]
		if group == nil {
			group = &runtimeSecret{Namespace: entry.Namespace, Name: entry.Name, Type: entry.Type}
			groups[id] = group
		}
		if group.Type != entry.Type {
			return nil, fmt.Errorf("inconsistent runtime Secret type in %s", id)
		}
		group.Keys = append(group.Keys, entry.Key)
	}
	result := make([]runtimeSecret, 0, len(groups))
	for _, group := range groups {
		sort.Strings(group.Keys)
		result = append(result, *group)
	}
	sort.Slice(result, func(i, j int) bool {
		return result[i].Namespace+"/"+result[i].Name < result[j].Namespace+"/"+result[j].Name
	})
	return result, nil
}

// Evaluate the readiness predicate inside the guest. Neither Secret values nor
// native kubectl diagnostics cross back to the host; only the exit status does.
func secretReadyCommand(secret runtimeSecret) []string {
	conditions := []string{fmt.Sprintf("(eq .type %q)", secret.Type)}
	for _, key := range secret.Keys {
		conditions = append(conditions, fmt.Sprintf("(index .data %q)", key))
	}
	template := "{{if and " + strings.Join(conditions, " ") + "}}ready{{end}}"
	return []string{
		"/bin/sh", "-c", `test "$(k3s kubectl "$@" 2>/dev/null)" = ready`, "secret-readiness",
		"--kubeconfig", "/etc/rancher/k3s/k3s.yaml", "--request-timeout=10s",
		"get", "secret", secret.Name, "--namespace", secret.Namespace, "-o", "go-template=" + template,
	}
}

func waitRuntimeSecrets(ctx context.Context, secrets []runtimeSecret, probe func(context.Context, runtimeSecret) error) error {
	for {
		ready := true
		for _, secret := range secrets {
			request, cancel := context.WithTimeout(ctx, 15*time.Second)
			err := probe(request, secret)
			cancel()
			if err != nil {
				ready = false
				break
			}
		}
		if ready {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("waiting for declared runtime Secret types and keys: %w", ctx.Err())
		case <-time.After(2 * time.Second):
		}
	}
}
