package bootstrap

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"text/template"
)

func TestRuntimeSecretInventoryAndReadiness(t *testing.T) {
	valid := `{"first":{"namespace":"media","name":"credentials","key":"USER","type":"Opaque"},"second":{"namespace":"media","name":"credentials","key":"PASSWORD","type":"Opaque"}}`
	secrets, err := declaredRuntimeSecrets([]byte(valid))
	if err != nil || len(secrets) != 1 {
		t.Fatalf("grouping inventory: %v, %v", secrets, err)
	}
	tls := `{"certificate":{"namespace":"gateway","name":"gateway-tls","key":"tls.crt","type":"kubernetes.io/tls"},"key":{"namespace":"gateway","name":"gateway-tls","key":"tls.key","type":"kubernetes.io/tls"}}`
	tlsSecrets, err := declaredRuntimeSecrets([]byte(tls))
	if err != nil || len(tlsSecrets) != 1 || tlsSecrets[0].Type != "kubernetes.io/tls" {
		t.Fatalf("TLS inventory: %v, %v", tlsSecrets, err)
	}
	for _, invalid := range []string{
		`null`, `[]`,
		strings.Replace(valid, `"PASSWORD"`, `"USER"`, 1),
		strings.Replace(valid, `"type":"Opaque"`, `"type":"kubernetes.io/tls"`, 1),
		strings.Replace(valid, `"media"`, `"media/other"`, 1),
		strings.Replace(valid, `"PASSWORD"`, `""`, 1),
	} {
		if _, err := declaredRuntimeSecrets([]byte(invalid)); err == nil {
			t.Fatalf("accepted invalid Secret inventory: %s", invalid)
		}
	}
	command := secretReadyCommand(secrets[0])
	predicate, err := template.New("readiness").Parse(strings.TrimPrefix(command[len(command)-1], "go-template="))
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name     string
		typeName string
		data     map[string]string
		ready    bool
	}{
		{"complete with application-owned extra", "Opaque", map[string]string{"USER": "private-user", "PASSWORD": "private-password", "EXTRA": "private-extra"}, true},
		{"missing key", "Opaque", map[string]string{"USER": "private-user"}, false},
		{"empty key", "Opaque", map[string]string{"USER": "private-user", "PASSWORD": ""}, false},
		{"wrong type", "kubernetes.io/tls", map[string]string{"USER": "private-user", "PASSWORD": "private-password"}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var output bytes.Buffer
			if err := predicate.Execute(&output, map[string]any{"type": tc.typeName, "data": tc.data}); err != nil {
				t.Fatal(err)
			}
			if (output.String() == "ready") != tc.ready || strings.Contains(output.String(), "private-") {
				t.Fatalf("invalid readiness result %q", output.String())
			}
		})
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	err = waitRuntimeSecrets(ctx, secrets, func(context.Context, runtimeSecret) error { return errors.New("private-native-error") })
	if !errors.Is(err, context.Canceled) || strings.Contains(err.Error(), "private-native-error") {
		t.Fatalf("failed probe accepted or native error disclosed: %v", err)
	}
}

func TestRuntimeSecretInventoryBinding(t *testing.T) {
	expected := []runtimeSecret{
		{Namespace: "media", Name: "credentials", Type: "Opaque", Keys: []string{"PASSWORD", "USER"}},
		{Namespace: "ops", Name: "tokens", Type: "Opaque", Keys: []string{"TOKEN"}},
	}
	copySecrets := func(secrets []runtimeSecret) []runtimeSecret {
		return append([]runtimeSecret(nil), secrets...)
	}
	cases := []struct {
		name     string
		expected []runtimeSecret
		actual   []runtimeSecret
		wantErr  bool
	}{
		{"exact match", expected, expected, false},
		{"extra Secret", expected, append(copySecrets(expected), runtimeSecret{
			Namespace: "ops",
			Name:      "extra",
			Type:      "Opaque",
			Keys:      []string{"TOKEN"},
		}), true},
		{"missing Secret", expected, expected[:1], true},
		{"key mismatch", expected, []runtimeSecret{
			{Namespace: "media", Name: "credentials", Type: "Opaque", Keys: []string{"PASSWORD", "TOKEN"}},
			expected[1],
		}, true},
		{"type mismatch", expected, []runtimeSecret{
			{Namespace: "media", Name: "credentials", Type: "kubernetes.io/tls", Keys: []string{"PASSWORD", "USER"}},
			expected[1],
		}, true},
		{"stale declaration", append(copySecrets(expected), runtimeSecret{
			Namespace: "media",
			Name:      "stale",
			Type:      "Opaque",
			Keys:      []string{"TOKEN"},
		}), expected, true},
		{"empty inventory", nil, nil, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := verifyRuntimeSecretInventory(tc.expected, runtimeSecretInventory(tc.actual))
			if (err != nil) != tc.wantErr {
				t.Fatalf("inventory verification error = %v, want error %t", err, tc.wantErr)
			}
		})
	}
}

func TestRuntimeGenerationBinding(t *testing.T) {
	yaml := []byte("apiVersion: v1\n")
	names := []byte("media\tshared\tOpaque\tPASSWORD,USER\n")
	yamlDigest := sha256.Sum256(yaml)
	namesDigest := sha256.Sum256(names)
	marker := []byte(fmt.Sprintf(
		"generation=%s yaml-sha256=%s names-sha256=%s\n",
		runtimeGenerationID(yaml, names),
		hex.EncodeToString(yamlDigest[:]),
		hex.EncodeToString(namesDigest[:]),
	))
	if generation, err := verifyRuntimeGeneration(marker, yaml, names); err != nil || generation != runtimeGenerationID(yaml, names) {
		t.Fatalf("valid generation rejected: %q, %v", generation, err)
	}
	if _, err := verifyRuntimeGeneration(marker, yaml, []byte("media\tother\tOpaque\tPASSWORD,USER\n")); err == nil {
		t.Fatal("accepted a generation with a modified desired inventory")
	}
	root := t.TempDir()
	for name, data := range map[string][]byte{
		"runtime-secrets.commit": marker,
		"runtime-secrets.yaml":   yaml,
		"runtime-secrets.names":  names,
	} {
		if err := os.WriteFile(filepath.Join(root, name), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if generation, err := readRuntimeGeneration(root); err != nil || generation != runtimeGenerationID(yaml, names) {
		t.Fatalf("snapshot generation rejected: %q, %v", generation, err)
	}
}

func TestRuntimeGenerationAcknowledgment(t *testing.T) {
	for _, names := range [][]byte{nil, []byte("media\tshared\tOpaque\tPASSWORD,USER\n")} {
		generation := runtimeGenerationID([]byte("apiVersion: v1\n"), names)
		for _, tc := range []struct {
			name string
			ack  string
			want bool
		}{
			{"missing", "", false},
			{"stale", runtimeGenerationID([]byte("previous generation\n"), names), false},
			{"exact", generation, true},
		} {
			t.Run(fmt.Sprintf("inventory-%d/%s", len(names), tc.name), func(t *testing.T) {
				root := t.TempDir()
				if tc.ack != "" {
					if err := os.WriteFile(filepath.Join(root, "applied-generation"), []byte(tc.ack+"\n"), 0o600); err != nil {
						t.Fatal(err)
					}
				}
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				err := waitRuntimeSecretGeneration(ctx, generation, func(probe context.Context, requested string) error {
					command := runtimeSecretGenerationCommand(requested)
					// Relocate only the guest filesystem path; execute the production acknowledgment predicate.
					command[2] = strings.ReplaceAll(command[2], "/var/lib/homelab-runtime-secrets/applied-generation", `"$ACK_ROOT/applied-generation"`)
					cmd := exec.CommandContext(probe, command[0], command[1:]...)
					cmd.Env = append(os.Environ(), "ACK_ROOT="+root)
					err := cmd.Run()
					cancel()
					return err
				})
				if tc.want {
					if err != nil {
						t.Fatalf("exact acknowledgment rejected: %v", err)
					}
				} else if !errors.Is(err, context.Canceled) {
					t.Fatalf("%s acknowledgment completed readiness: %v", tc.name, err)
				}
			})
		}
	}
}

func TestGuestKubeconfigReadRejectsOversize(t *testing.T) {
	if _, err := ReadBytes(io.NopCloser(strings.NewReader(strings.Repeat("x", (1<<20)+1)))); err == nil {
		t.Fatal("accepted oversized guest input")
	}
	data, err := ReadBytes(io.NopCloser(strings.NewReader("small kubeconfig")))
	if err != nil || string(data) != "small kubeconfig" {
		t.Fatalf("bounded read changed payload: %q, %v", data, err)
	}
}
