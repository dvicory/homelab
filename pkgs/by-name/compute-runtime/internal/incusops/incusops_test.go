package incusops

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
)

func TestWaitOutcome(t *testing.T) {
	for _, tc := range []struct {
		name                     string
		status                   api.StatusCode
		blocked, failed, unknown bool
	}{
		{"completed", api.Success, false, false, false},
		{"failed", api.Failure, false, true, false},
		{"still running", api.Running, false, true, true},
		{"deadline with cancellation", api.Running, true, true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cancelled := make(chan struct{}, 1)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				state := api.Operation{ID: "operation", StatusCode: tc.status, MayCancel: tc.blocked}
				response := map[string]any{"type": "sync", "status": "Success", "status_code": 200, "metadata": state}
				switch r.Method {
				case http.MethodPost:
					state.StatusCode = api.Running
					response["metadata"] = state
					response["type"] = "async"
					response["operation"] = "/1.0/operations/operation"
				case http.MethodDelete:
					cancelled <- struct{}{}
				case http.MethodGet:
					if tc.blocked {
						<-r.Context().Done()
						return
					}
				}
				_ = json.NewEncoder(w).Encode(response)
			}))
			defer func() {
				server.CloseClientConnections()
				server.Close()
			}()
			client, err := incus.ConnectIncus(server.URL, &incus.ConnectionArgs{SkipGetServer: true, SkipGetEvents: true})
			if err != nil {
				t.Fatal(err)
			}
			defer client.Disconnect()
			op, _, err := client.RawOperation(http.MethodPost, "/instances", nil, "")
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
			defer cancel()
			result := make(chan error, 1)
			go func() {
				_, err := Wait(ctx, client, op)
				result <- err
			}()
			select {
			case err := <-result:
				if (err != nil) != tc.failed || errors.Is(err, ErrUnknownOutcome) != tc.unknown {
					t.Fatalf("err=%v; want failed=%v unknown=%v", err, tc.failed, tc.unknown)
				}
			case <-time.After(2 * time.Second):
				t.Fatal("operation wait ignored its request deadline")
			}
			if tc.blocked {
				select {
				case <-cancelled:
				default:
					t.Fatal("timed-out cancellable operation was not cancelled")
				}
			}
		})
	}
}
