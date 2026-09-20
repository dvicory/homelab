package adoption

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
)

func declared() Envelope {
	return Envelope{
		Project:       "compute",
		ProjectConfig: api.ConfigMap{"restricted": "true", "restricted.devices.gpu": "block", "features.images": "true"},
		Pool:          "incus-compute",
		PoolPath:      "/var/lib/incus-storage-pools/incus-compute",
		Network:       "incus-compute",
		NetworkConfig: api.ConfigMap{"ipv4.address": "10.210.0.1/24", "ipv4.nat": "true"},
		Profile:       "compute-1",
		ProfileConfig: api.ConfigMap{"security.privileged": "false", "limits.cpu": "4"},
		ProfileDevices: api.DevicesMap{
			"root": {"type": "disk", "path": "/", "pool": "incus-compute"},
			"eth0": {"type": "nic", "network": "incus-compute", "name": "eth0"},
		},
	}
}

func matchingState(desired Envelope) State {
	project := &api.Project{Name: desired.Project}
	project.Config = api.ConfigMap{"features.profiles": "true"}
	for key, value := range desired.ProjectConfig {
		project.Config[key] = value
	}
	pool := &api.StoragePool{Name: desired.Pool, Driver: "dir"}
	pool.Config = api.ConfigMap{"source": desired.PoolPath, "volatile.initial_source": desired.PoolPath}
	network := &api.Network{Name: desired.Network, Type: "bridge"}
	network.Config = api.ConfigMap{"bridge.hwaddr": "10:66:6a:00:00:01", "volatile.bridge.hwaddr": "10:66:6a:00:00:01"}
	for key, value := range desired.NetworkConfig {
		network.Config[key] = value
	}
	profile := &api.Profile{Name: desired.Profile}
	profile.Config = cloneConfig(desired.ProfileConfig)
	profile.Devices = api.DevicesMap{}
	for name, device := range desired.ProfileDevices {
		profile.Devices[name] = cloneConfig(device)
	}
	return State{Project: project, Pool: pool, Network: network, Profile: profile}
}

func cloneConfig(config map[string]string) map[string]string {
	clone := make(map[string]string, len(config))
	for key, value := range config {
		clone[key] = value
	}
	return clone
}

func TestDecide(t *testing.T) {
	desired := declared()
	for _, tc := range []struct {
		name     string
		state    func(State) State
		outcome  Outcome
		missing  []string
		conflict string
	}{
		{
			name:    "absent envelope",
			state:   func(State) State { return State{} },
			outcome: Absent,
			missing: []string{"project/compute", "storage-pool/incus-compute", "network/default/incus-compute", "profile/compute/compute-1"},
		},
		{
			name:    "matching envelope",
			state:   func(s State) State { return s },
			outcome: Matching,
		},
		{
			name: "matching project without its profile",
			state: func(s State) State {
				s.Profile = nil
				return s
			},
			outcome: Absent,
			missing: []string{"profile/compute/compute-1"},
		},
		{
			name: "project restriction changed",
			state: func(s State) State {
				s.Project.Config["restricted.devices.gpu"] = "allow"
				return s
			},
			conflict: "project/compute",
		},
		{
			name: "undeclared project permission",
			state: func(s State) State {
				s.Project.Config["restricted.devices.proxy"] = "allow"
				return s
			},
			conflict: "project/compute",
		},
		{
			name: "same-name pool with another driver",
			state: func(s State) State {
				s.Pool.Driver = "zfs"
				return s
			},
			conflict: "storage-pool/incus-compute",
		},
		{
			name: "same-name pool at another source",
			state: func(s State) State {
				s.Pool.Config["source"] = "/elsewhere"
				return s
			},
			conflict: "storage-pool/incus-compute",
		},
		{
			name: "same-name network of another type",
			state: func(s State) State {
				s.Network.Type = "macvlan"
				return s
			},
			conflict: "network/default/incus-compute",
		},
		{
			name: "network address changed",
			state: func(s State) State {
				s.Network.Config["ipv4.address"] = "10.99.0.1/24"
				return s
			},
			conflict: "network/default/incus-compute",
		},
		{
			name: "undeclared network setting",
			state: func(s State) State {
				s.Network.Config["ipv6.address"] = "auto"
				return s
			},
			conflict: "network/default/incus-compute",
		},
		{
			name: "profile privilege changed",
			state: func(s State) State {
				s.Profile.Config["security.privileged"] = "true"
				return s
			},
			conflict: "profile/compute/compute-1",
		},
		{
			name: "profile device added",
			state: func(s State) State {
				s.Profile.Devices["extra"] = map[string]string{"type": "disk", "source": "/", "path": "/host"}
				return s
			},
			conflict: "profile/compute/compute-1",
		},
		{
			name: "conflict reported before missing resources",
			state: func(s State) State {
				s.Pool = nil
				s.Profile.Config["limits.cpu"] = "64"
				return s
			},
			conflict: "profile/compute/compute-1",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			decision, err := Decide(desired, tc.state(matchingState(desired)))
			if tc.conflict != "" {
				var conflict *ConflictError
				if !errors.As(err, &conflict) {
					t.Fatalf("decision=%+v err=%v; want conflict on %s", decision, err, tc.conflict)
				}
				if conflict.Resource != tc.conflict || conflict.Mismatch == "" {
					t.Fatalf("conflict=%+v; want resource %s with a named mismatch", conflict, tc.conflict)
				}
				if !strings.Contains(err.Error(), tc.conflict) || !strings.Contains(err.Error(), "refusing before mutation") {
					t.Fatalf("error %q does not name the resource and the refusal", err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if decision.Outcome != tc.outcome || !reflect.DeepEqual(decision.Missing, tc.missing) {
				t.Fatalf("decision=%+v; want outcome %s missing %v", decision, tc.outcome, tc.missing)
			}
		})
	}
}

func TestProjectConfigMatches(t *testing.T) {
	desired := api.ConfigMap{
		"features.images":               "true",
		"restricted":                    "true",
		"restricted.devices.gpu":        "block",
		"restricted.devices.disk.paths": "/srv/identity",
	}
	actual := api.ConfigMap{
		"features.images":               "true",
		"features.profiles":             "true",
		"restricted":                    "true",
		"restricted.devices.gpu":        "block",
		"restricted.devices.disk.paths": "/srv/identity",
	}
	if !ProjectConfigMatches(actual, desired) {
		t.Fatal("non-security project defaults should be accepted")
	}
	actual["restricted.devices.proxy"] = "allow"
	if ProjectConfigMatches(actual, desired) {
		t.Fatal("undeclared project permissions must be rejected")
	}
	delete(actual, "restricted.devices.proxy")
	actual["restricted.devices.gpu"] = "allow"
	if ProjectConfigMatches(actual, desired) {
		t.Fatal("changed project restrictions must be rejected")
	}
}

type recordingReader struct {
	state State
	fail  error
	calls []string
}

func (r *recordingReader) Project(name string) (*api.Project, error) {
	r.calls = append(r.calls, "Project:"+name)
	return r.state.Project, r.fail
}

func (r *recordingReader) StoragePool(name string) (*api.StoragePool, error) {
	r.calls = append(r.calls, "StoragePool:"+name)
	return r.state.Pool, r.fail
}

func (r *recordingReader) Network(project, name string) (*api.Network, error) {
	r.calls = append(r.calls, "Network:"+project+"/"+name)
	return r.state.Network, r.fail
}

func (r *recordingReader) Profile(project, name string) (*api.Profile, error) {
	r.calls = append(r.calls, "Profile:"+project+"/"+name)
	return r.state.Profile, r.fail
}

func TestGateOnlyReads(t *testing.T) {
	desired := declared()
	full := []string{"Project:compute", "StoragePool:incus-compute", "Network:default/incus-compute", "Profile:compute/compute-1"}
	for _, tc := range []struct {
		name     string
		state    State
		calls    []string
		outcome  Outcome
		conflict string
	}{
		{"absent envelope", State{}, full[:3], Absent, ""},
		{"matching envelope", matchingState(desired), full, Matching, ""},
		{
			"conflicting envelope",
			func() State {
				s := matchingState(desired)
				s.Pool.Driver = "btrfs"
				return s
			}(),
			full, "", "storage-pool/incus-compute",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reader := &recordingReader{state: tc.state}
			decision, err := Gate(reader, desired)
			if !reflect.DeepEqual(reader.calls, tc.calls) {
				t.Fatalf("calls=%v; want exactly the read-only queries %v", reader.calls, tc.calls)
			}
			if tc.conflict != "" {
				var conflict *ConflictError
				if !errors.As(err, &conflict) || conflict.Resource != tc.conflict {
					t.Fatalf("decision=%+v err=%v; want conflict on %s", decision, err, tc.conflict)
				}
				return
			}
			if err != nil || decision.Outcome != tc.outcome {
				t.Fatalf("decision=%+v err=%v; want %s", decision, err, tc.outcome)
			}
		})
	}
}

func TestGateRefusesOnReadFailure(t *testing.T) {
	reader := &recordingReader{fail: errors.New("socket unavailable")}
	if _, err := Gate(reader, declared()); err == nil || !strings.Contains(err.Error(), "inspect project compute") {
		t.Fatalf("err=%v; want the failed read to be named", err)
	}
	if len(reader.calls) != 1 {
		t.Fatalf("calls=%v; want inspection to stop at the first failed read", reader.calls)
	}
}

type fakeIncusAPI struct {
	desired Envelope
	state   State
	writes  int
}

func (f *fakeIncusAPI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		f.writes++
		http.Error(w, "mutations are not allowed", http.StatusMethodNotAllowed)
		return
	}

	var metadata any
	found := true
	switch r.URL.Path {
	case "/1.0/projects/" + f.desired.Project:
		if f.state.Project == nil {
			found = false
		} else {
			metadata = f.state.Project
		}
	case "/1.0/storage-pools/" + f.desired.Pool:
		if f.state.Pool == nil {
			found = false
		} else {
			metadata = f.state.Pool
		}
	case "/1.0/networks/" + f.desired.Network:
		if f.state.Network == nil {
			found = false
		} else {
			metadata = f.state.Network
		}
	case "/1.0/profiles/" + f.desired.Profile:
		if f.state.Profile == nil {
			found = false
		} else {
			metadata = f.state.Profile
		}
	default:
		found = false
	}
	if !found {
		writeFakeIncusResponse(w, http.StatusNotFound, nil)
		return
	}
	writeFakeIncusResponse(w, http.StatusOK, metadata)
}

func writeFakeIncusResponse(w http.ResponseWriter, status int, metadata any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	statusText := "Success"
	if status != http.StatusOK {
		statusText = "Failure"
	}
	_ = json.NewEncoder(w).Encode(map[string]any{
		"type":        "sync",
		"status":      statusText,
		"status_code": status,
		"metadata":    metadata,
	})
}

func TestGateWithFakeClient(t *testing.T) {
	desired := declared()
	conflictState := matchingState(desired)
	conflictState.Pool.Driver = "btrfs"
	for _, tc := range []struct {
		name        string
		state       State
		want        Outcome
		missing     []string
		conflicting bool
	}{
		{
			name:    "absent envelope",
			state:   State{},
			want:    Absent,
			missing: []string{"project/compute", "storage-pool/incus-compute", "network/default/incus-compute"},
		},
		{name: "matching envelope", state: matchingState(desired), want: Matching},
		{name: "conflicting envelope", state: conflictState, conflicting: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			fake := &fakeIncusAPI{desired: desired, state: tc.state}
			httpServer := httptest.NewServer(fake)
			defer httpServer.Close()
			client, err := incus.ConnectIncus(httpServer.URL, &incus.ConnectionArgs{
				SkipGetServer: true,
				SkipGetEvents: true,
			})
			if err != nil {
				t.Fatal(err)
			}
			defer client.Disconnect()

			decision, err := Gate(NewReader(client), desired)
			if fake.writes != 0 {
				t.Fatalf("fake Incus client observed %d mutation requests", fake.writes)
			}
			if tc.conflicting {
				var conflict *ConflictError
				if !errors.As(err, &conflict) || conflict.Resource != "storage-pool/incus-compute" {
					t.Fatalf("decision=%+v err=%v; want a storage-pool conflict", decision, err)
				}
				return
			}
			if err != nil || decision.Outcome != tc.want || !reflect.DeepEqual(decision.Missing, tc.missing) {
				t.Fatalf("decision=%+v err=%v; want %s missing %v", decision, err, tc.want, tc.missing)
			}
		})
	}
}
