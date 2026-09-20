package bootstrap

import (
	"bytes"
	"context"
	"errors"
	"io"
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
	for _, invalid := range []string{
		`null`, `[]`,
		strings.Replace(valid, `"PASSWORD"`, `"USER"`, 1),
		strings.Replace(valid, `"Opaque"`, `"kubernetes.io/tls"`, 1),
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

func TestGuestKubeconfigReadRejectsOversize(t *testing.T) {
	if _, err := ReadBytes(io.NopCloser(strings.NewReader(strings.Repeat("x", (1<<20)+1)))); err == nil {
		t.Fatal("accepted oversized guest input")
	}
	data, err := ReadBytes(io.NopCloser(strings.NewReader("small kubeconfig")))
	if err != nil || string(data) != "small kubeconfig" {
		t.Fatalf("bounded read changed payload: %q, %v", data, err)
	}
}
