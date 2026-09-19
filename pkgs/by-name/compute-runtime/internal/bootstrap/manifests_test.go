package bootstrap

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestReportTreatsMissingResourceAsUnavailable(t *testing.T) {
	dir := t.TempDir()
	manifest := filepath.Join(dir, "readiness.yaml")
	if err := os.WriteFile(manifest, []byte("declared\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	yq := filepath.Join(dir, "yq")
	if err := os.WriteFile(yq, []byte("#!/bin/sh\nprintf '%s\\n' '{\"kind\":\"Deployment\",\"metadata\":{\"name\":\"controller\",\"namespace\":\"system\"}}'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	kubectl := filepath.Join(dir, "kubectl")
	if err := os.WriteFile(kubectl, []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}

	var output bytes.Buffer
	tools := NewTools(&output, io.Discard)
	tools.YQPath = yq
	tools.KubectlPath = kubectl

	unavailable, err := (Manifests{Dir: dir}).report(context.Background(), tools, "readiness.yaml")
	if err != nil {
		t.Fatal(err)
	}
	if unavailable != 1 || !strings.Contains(output.String(), "MISSING Deployment system/controller") {
		t.Fatalf("unavailable=%d output=%q", unavailable, output.String())
	}
}

func TestSecretNamespacesRejectsAnyMissingNamespace(t *testing.T) {
	valid := []byte("{\"kind\":\"Secret\",\"metadata\":{\"namespace\":\"jellyfin\"}}\n{\"kind\":\"Secret\",\"metadata\":{\"namespace\":\"identity\"}}\n")
	namespaces, err := secretNamespacesFromJSON(valid)
	if err != nil || !reflect.DeepEqual(namespaces, []string{"identity", "jellyfin"}) {
		t.Fatalf("namespaces=%v err=%v", namespaces, err)
	}
	missing := []byte("{\"kind\":\"Secret\",\"metadata\":{\"namespace\":\"jellyfin\"}}\n{\"kind\":\"Secret\",\"metadata\":{}}\n")
	if _, err := secretNamespacesFromJSON(missing); err == nil {
		t.Fatal("accepted a staged Secret without an explicit namespace")
	}
}
