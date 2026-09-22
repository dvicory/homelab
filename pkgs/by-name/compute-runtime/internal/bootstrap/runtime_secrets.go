package bootstrap

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
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
	secretNamespace     = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`)
	secretName          = regexp.MustCompile(`^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$`)
	secretKey           = regexp.MustCompile(`^[a-zA-Z0-9._-]+$`)
	secretType          = regexp.MustCompile(`^(Opaque|kubernetes[.]io/tls)$`)
	inventorySecretType = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]*$`)
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
		if result[i].Namespace != result[j].Namespace {
			return result[i].Namespace < result[j].Namespace
		}
		return result[i].Name < result[j].Name
	})
	return result, nil
}

func runtimeSecretInventory(secrets []runtimeSecret) []byte {
	if len(secrets) == 0 {
		return nil
	}
	ordered := append([]runtimeSecret(nil), secrets...)
	sort.Slice(ordered, func(i, j int) bool {
		if ordered[i].Namespace != ordered[j].Namespace {
			return ordered[i].Namespace < ordered[j].Namespace
		}
		return ordered[i].Name < ordered[j].Name
	})
	lines := make([]string, len(ordered))
	for i, secret := range ordered {
		keys := append([]string(nil), secret.Keys...)
		sort.Strings(keys)
		lines[i] = strings.Join([]string{
			secret.Namespace,
			secret.Name,
			secret.Type,
			strings.Join(keys, ","),
		}, "\t")
	}
	return []byte(strings.Join(lines, "\n") + "\n")
}

func runtimeSecretInventoryHash(secrets []runtimeSecret) string {
	digest := sha256.Sum256(runtimeSecretInventory(secrets))
	return hex.EncodeToString(digest[:])
}

func parseRuntimeSecretInventory(raw []byte) ([]runtimeSecret, error) {
	if len(raw) == 0 {
		return nil, nil
	}
	text := string(raw)
	if !strings.HasSuffix(text, "\n") {
		return nil, errors.New("runtime Secret inventory is not newline-terminated")
	}
	lines := strings.Split(strings.TrimSuffix(text, "\n"), "\n")
	result := make([]runtimeSecret, 0, len(lines))
	seenSecrets := make(map[string]struct{}, len(lines))
	for _, line := range lines {
		fields := strings.Split(line, "\t")
		if len(fields) != 4 {
			return nil, errors.New("runtime Secret inventory has invalid metadata")
		}
		namespace, name, typeName := fields[0], fields[1], fields[2]
		if len(namespace) > 63 || !secretNamespace.MatchString(namespace) ||
			len(name) > 253 || !secretName.MatchString(name) ||
			!inventorySecretType.MatchString(typeName) {
			return nil, errors.New("runtime Secret inventory has invalid metadata")
		}
		id := namespace + "/" + name
		if _, ok := seenSecrets[id]; ok {
			return nil, errors.New("runtime Secret inventory has duplicate Secrets")
		}
		seenSecrets[id] = struct{}{}
		keys := strings.Split(fields[3], ",")
		seen := make(map[string]struct{}, len(keys))
		for i, key := range keys {
			if len(key) > 253 || !secretKey.MatchString(key) ||
				(i > 0 && keys[i-1] >= key) {
				return nil, errors.New("runtime Secret inventory has invalid keys")
			}
			if _, ok := seen[key]; ok {
				return nil, errors.New("runtime Secret inventory has duplicate keys")
			}
			seen[key] = struct{}{}
		}
		result = append(result, runtimeSecret{
			Namespace: namespace,
			Name:      name,
			Type:      typeName,
			Keys:      keys,
		})
	}
	if string(runtimeSecretInventory(result)) != text {
		return nil, errors.New("runtime Secret inventory is not canonical")
	}
	return result, nil
}

func verifyRuntimeSecretInventory(expected []runtimeSecret, staged []byte) error {
	actual, err := parseRuntimeSecretInventory(staged)
	if err != nil {
		return err
	}
	if string(runtimeSecretInventory(expected)) != string(runtimeSecretInventory(actual)) {
		return errors.New("staged runtime Secret inventory does not match descriptor")
	}
	return nil
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

func runtimeSecretGenerationCommand(generation string) []string {
	return []string{
		"/bin/sh", "-c",
		`test "$(cat /var/lib/homelab-runtime-secrets/applied-generation 2>/dev/null)" = "$1"`,
		"runtime-secret-generation", generation,
	}
}

func waitRuntimeSecretGeneration(
	ctx context.Context,
	generation string,
	probe func(context.Context, string) error,
) error {
	for {
		request, cancel := context.WithTimeout(ctx, 15*time.Second)
		err := probe(request, generation)
		cancel()
		if err == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("waiting for runtime Secret generation %s: %w", generation, ctx.Err())
		case <-time.After(2 * time.Second):
		}
	}
}

func runtimeGenerationID(yaml, names []byte) string {
	yamlDigest := sha256.Sum256(yaml)
	namesDigest := sha256.Sum256(names)
	input := hex.EncodeToString(yamlDigest[:]) + "\n" + hex.EncodeToString(namesDigest[:]) + "\n"
	generation := sha256.Sum256([]byte(input))
	return hex.EncodeToString(generation[:])
}

func parseRuntimeGenerationMarker(marker []byte) (string, string, string, error) {
	text := string(marker)
	if !strings.HasSuffix(text, "\n") || strings.Count(text, "\n") != 1 {
		return "", "", "", errors.New("runtime Secret generation marker is malformed")
	}
	fields := strings.Split(strings.TrimSuffix(text, "\n"), " ")
	if len(fields) != 3 ||
		!strings.HasPrefix(fields[0], "generation=") ||
		!strings.HasPrefix(fields[1], "yaml-sha256=") ||
		!strings.HasPrefix(fields[2], "names-sha256=") {
		return "", "", "", errors.New("runtime Secret generation marker is malformed")
	}
	generation := strings.TrimPrefix(fields[0], "generation=")
	yamlDigest := strings.TrimPrefix(fields[1], "yaml-sha256=")
	namesDigest := strings.TrimPrefix(fields[2], "names-sha256=")
	for _, value := range []string{generation, yamlDigest, namesDigest} {
		if len(value) != sha256.Size*2 {
			return "", "", "", errors.New("runtime Secret generation marker is malformed")
		}
		if _, err := hex.DecodeString(value); err != nil || strings.ToLower(value) != value {
			return "", "", "", errors.New("runtime Secret generation marker is malformed")
		}
	}
	return generation, yamlDigest, namesDigest, nil
}

func verifyRuntimeGeneration(marker, yaml, names []byte) (string, error) {
	generation, yamlDigest, namesDigest, err := parseRuntimeGenerationMarker(marker)
	if err != nil {
		return "", err
	}
	actualYAML := sha256.Sum256(yaml)
	actualNames := sha256.Sum256(names)
	if yamlDigest != hex.EncodeToString(actualYAML[:]) || namesDigest != hex.EncodeToString(actualNames[:]) {
		return "", errors.New("runtime Secret generation checksum does not match")
	}
	if generation != runtimeGenerationID(yaml, names) {
		return "", errors.New("runtime Secret generation ID does not match staged files")
	}
	return generation, nil
}

func readRuntimeGeneration(root string) (string, error) {
	marker, err := os.ReadFile(filepath.Join(root, "runtime-secrets.commit"))
	if err != nil {
		return "", fmt.Errorf("read runtime Secret generation marker: %w", err)
	}
	yaml, err := os.ReadFile(filepath.Join(root, "runtime-secrets.yaml"))
	if err != nil {
		return "", fmt.Errorf("read staged runtime Secret YAML: %w", err)
	}
	names, err := os.ReadFile(filepath.Join(root, "runtime-secrets.names"))
	if err != nil {
		return "", fmt.Errorf("read staged runtime Secret inventory: %w", err)
	}
	return verifyRuntimeGeneration(marker, yaml, names)
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
