package bootstrap

import (
	"encoding/json"
	"testing"
)

func TestReadinessDecisions(t *testing.T) {
	for _, tc := range []struct {
		name, kind, input, want string
	}{
		{"stale availability", "Prometheus", `{"metadata":{"generation":2},"status":{"conditions":[{"type":"Available","status":"True","observedGeneration":1}]}}`, "NOT_READY"},
		{"current availability", "Prometheus", `{"metadata":{"generation":2},"status":{"conditions":[{"type":"Available","status":"True","observedGeneration":2}]}}`, "READY"},
		{"success count without completion", "Job", `{"status":{"succeeded":1}}`, "NOT_READY"},
		{"failed job", "Job", `{"status":{"conditions":[{"type":"Failed","status":"True"}]}}`, "FAILED"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var object map[string]any
			if err := json.Unmarshal([]byte(tc.input), &object); err != nil {
				t.Fatal(err)
			}
			if state, _ := objectState(tc.kind, object); state != tc.want {
				t.Fatalf("state=%s; want %s", state, tc.want)
			}
		})
	}
}

func TestRetryEligibility(t *testing.T) {
	for _, tc := range []struct {
		name, input   string
		retry, refuse bool
	}{
		{"failed retryable hook", `{"metadata":{"annotations":{"argocd.argoproj.io/hook-delete-policy":"HookSucceeded, BeforeHookCreation"}},"status":{"conditions":[{"type":"Failed","status":"True"}]}}`, true, false},
		{"completed job left alone", `{"status":{"conditions":[{"type":"Complete","status":"True"}]}}`, false, false},
		{"active failed job", `{"status":{"active":1,"conditions":[{"type":"Failed","status":"True"}]}}`, false, true},
		{"failed job without hook policy", `{"status":{"conditions":[{"type":"Failed","status":"True"}]}}`, false, true},
		{"missing job", `null`, false, true},
		{"nonterminal job", `{"status":{}}`, false, true},
		{"conflicting terminal conditions", `{"status":{"conditions":[{"type":"Complete","status":"True"},{"type":"Failed","status":"True"}]}}`, false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var object map[string]any
			if err := json.Unmarshal([]byte(tc.input), &object); err != nil {
				t.Fatal(err)
			}
			retry, err := retryableJob(object)
			if retry != tc.retry || (err != nil) != tc.refuse {
				t.Fatalf("retry=%v err=%v; want retry=%v refuse=%v", retry, err, tc.retry, tc.refuse)
			}
		})
	}
}
