//go:build linux

package bootstrap

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestBuildHostKubeconfigUsesOnlyCertificateMaterial(t *testing.T) {
	raw := []byte(`{
		"clusters":[{"cluster":{"certificate-authority-data":"ca","proxy-url":"http://guest-proxy"}}],
		"users":[{"user":{"client-certificate-data":"certificate","client-key-data":"key","exec":{"command":"/bin/sh"}}}],
		"contexts":[{"name":"guest","context":{"cluster":"guest","user":"guest"}}],
		"current-context":"guest"
	}`)
	output, err := buildHostKubeconfig(raw, "https://10.210.0.10:6443")
	if err != nil {
		t.Fatal(err)
	}
	var actual map[string]any
	if err := json.Unmarshal(output, &actual); err != nil {
		t.Fatal(err)
	}
	expected := map[string]any{
		"apiVersion": "v1",
		"kind":       "Config",
		"clusters": []any{map[string]any{
			"name": "compute",
			"cluster": map[string]any{
				"server":                     "https://10.210.0.10:6443",
				"certificate-authority-data": "ca",
			},
		}},
		"users": []any{map[string]any{
			"name": "compute",
			"user": map[string]any{
				"client-certificate-data": "certificate",
				"client-key-data":         "key",
			},
		}},
		"contexts": []any{map[string]any{
			"name": "compute",
			"context": map[string]any{
				"cluster": "compute",
				"user":    "compute",
			},
		}},
		"current-context": "compute",
	}
	if !reflect.DeepEqual(actual, expected) {
		t.Fatalf("unsafe or unexpected host kubeconfig: %#v", actual)
	}

	raw = []byte(`{
		"clusters":[{"cluster":{"certificate-authority-data":"ca"}}],
		"users":[
			{"user":{"client-certificate-data":"certificate","client-key-data":"key"}},
			{"user":{"exec":{"command":"/bin/sh"}}}
		]
	}`)
	if _, err := buildHostKubeconfig(raw, "https://10.210.0.10:6443"); err == nil {
		t.Fatal("accepted an ambiguous guest kubeconfig with an executable secondary identity")
	}
}
