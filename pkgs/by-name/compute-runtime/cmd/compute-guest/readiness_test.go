package main

import (
	"encoding/json"
	"errors"
	"io"
	"strings"
	"testing"
)

func TestReadinessWitnessNeverRetainsGuestText(t *testing.T) {
	const secret = "K10private-token::server:must-not-be-logged"
	calls := 0
	witness := collectReadinessWitness(func(argv []string, output io.Writer) error {
		calls++
		var text string
		switch argv[0] {
		case "systemctl":
			text = "ActiveState=activating\nSubState=auto-restart\nResult=" + secret + "\nExecMainStatus=1\nNRestarts=17\nEnvironment=" + secret
		case "journalctl":
			text = "Failed to run Kubelet: permission denied " + secret
		case "tail":
			text = "failed to load plugin: operation not permitted " + strings.Repeat(secret, 20000)
		case "k3s":
			if argv[1] == "kubectl" {
				text = `{"items":[{"metadata":{"name":"` + secret + `"},"status":{"conditions":[{"type":"Ready","status":"False","reason":"` + secret + `","message":"container runtime network not ready: cni plugin not initialized ` + secret + `"},{"type":"` + secret + `","status":"True"}]}}]}`
			} else {
				text = `{"status":{"conditions":[{"type":"RuntimeReady","status":false,"reason":"` + secret + `","message":"connection refused ` + secret + `"}]},"config":{"credential":"` + secret + `"}}`
			}
		}
		_, _ = io.WriteString(output, text)
		return errors.New(secret)
	})
	encoded, err := json.Marshal(witness)
	if err != nil {
		t.Fatal(err)
	}
	text := string(encoded)
	if calls != 5 || strings.Contains(text, secret) || strings.Contains(text, "Environment") {
		t.Fatalf("unbounded or sensitive witness: calls=%d %s", calls, text)
	}
	for _, expected := range []string{"failed to run kubelet", "permission denied", "operation not permitted", "cni plugin not initialized", "connection refused", `"ExecMainStatus":"1"`, `"NRestarts":"17"`, `"Result":"unknown"`, `"status":"False"`, `"status":"false"`} {
		if !strings.Contains(text, expected) {
			t.Fatalf("missing fixed diagnostic %q: %s", expected, text)
		}
	}
	for _, value := range witness {
		if value.Completed {
			t.Fatal("failed probe marked completed")
		}
	}
	if conditionWitness([]byte(secret), false) != nil || conditionWitness([]byte(secret), true) != nil {
		t.Fatal("malformed condition JSON must not pass through")
	}
}
