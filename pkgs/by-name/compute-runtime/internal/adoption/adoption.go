package adoption

import (
	"fmt"
	"net/http"
	"sort"
	"strings"

	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
)

// Envelope is the declared Incus preseed envelope: the project, storage pool,
// network and profile that must exist before a compute guest can be created.
type Envelope struct {
	Project        string
	ProjectConfig  api.ConfigMap
	Pool           string
	PoolPath       string
	Network        string
	NetworkConfig  api.ConfigMap
	Profile        string
	ProfileConfig  api.ConfigMap
	ProfileDevices api.DevicesMap
}

// State is the fetched envelope. A nil member means the resource is absent.
type State struct {
	Project *api.Project
	Pool    *api.StoragePool
	Network *api.Network
	Profile *api.Profile
}

// Outcome is the read-only gate result when nothing conflicts.
type Outcome string

const (
	// Absent means at least one declared resource is missing; preseed may
	// create it. Any resource that already exists matches the declaration.
	Absent Outcome = "absent"
	// Matching means every declared resource exists and matches; preseed
	// adopts the envelope without changing it.
	Matching Outcome = "matching"
	// Owned means the project carries the declared owner marker but it or its
	// profile differs from the declaration; preseed applies the declaration.
	Owned Outcome = "owned"
)

// OwnerKey is the project config key whose declared value marks a project
// this host created. Without it, a differing project is someone else's.
const OwnerKey = "user.homelab.owner"

// Decision reports the outcome, the missing resources, and for Owned the
// project and profile differences preseed will overwrite.
type Decision struct {
	Outcome Outcome
	Missing []string
	Drift   []string
}

// ConflictError names an existing resource that does not match the
// declaration. The caller must refuse before any mutation.
type ConflictError struct {
	Resource string
	Mismatch string
}

func (e *ConflictError) Error() string {
	return fmt.Sprintf("existing %s conflicts with the declared envelope (%s); refusing before mutation", e.Resource, e.Mismatch)
}

// Reader is the read-only view of Incus the gate needs. Implementations
// return nil without error when the named resource is absent.
type Reader interface {
	Project(name string) (*api.Project, error)
	StoragePool(name string) (*api.StoragePool, error)
	Network(project, name string) (*api.Network, error)
	Profile(project, name string) (*api.Profile, error)
}

// Gate fetches the current envelope and decides whether preseed may proceed.
func Gate(reader Reader, desired Envelope) (Decision, error) {
	state, err := Fetch(reader, desired)
	if err != nil {
		return Decision{}, err
	}
	return Decide(desired, state)
}

// Fetch reads the declared resources. It skips the profile when the project
// is absent because the profile cannot exist without it.
func Fetch(reader Reader, desired Envelope) (State, error) {
	var state State
	var err error
	if state.Project, err = reader.Project(desired.Project); err != nil {
		return State{}, fmt.Errorf("inspect project %s: %w", desired.Project, err)
	}
	if state.Pool, err = reader.StoragePool(desired.Pool); err != nil {
		return State{}, fmt.Errorf("inspect storage pool %s: %w", desired.Pool, err)
	}
	if state.Network, err = reader.Network(api.ProjectDefaultName, desired.Network); err != nil {
		return State{}, fmt.Errorf("inspect network %s: %w", desired.Network, err)
	}
	if state.Project != nil {
		if state.Profile, err = reader.Profile(desired.Project, desired.Profile); err != nil {
			return State{}, fmt.Errorf("inspect profile %s/%s: %w", desired.Project, desired.Profile, err)
		}
	}
	return state, nil
}

// Decide compares the fetched state with the declaration. It performs no I/O.
func Decide(desired Envelope, state State) (Decision, error) {
	var missing, drift []string
	owned := state.Project != nil && desired.ProjectConfig[OwnerKey] != "" &&
		state.Project.Config[OwnerKey] == desired.ProjectConfig[OwnerKey]

	if state.Project == nil {
		missing = append(missing, "project/"+desired.Project)
	} else {
		changed, undeclared := projectDifferences(state.Project.Config, desired.ProjectConfig)
		if undeclared != "" || (changed != "" && !owned) {
			return Decision{}, &ConflictError{Resource: "project/" + desired.Project, Mismatch: firstOf(undeclared, changed)}
		}
		if changed != "" {
			drift = append(drift, "project/"+desired.Project+": "+changed)
		}
	}

	if state.Pool == nil {
		missing = append(missing, "storage-pool/"+desired.Pool)
	} else if state.Pool.Driver != "dir" {
		return Decision{}, &ConflictError{Resource: "storage-pool/" + desired.Pool, Mismatch: fmt.Sprintf("driver is %q, declared %q", state.Pool.Driver, "dir")}
	} else if source := state.Pool.Config["source"]; source != desired.PoolPath {
		return Decision{}, &ConflictError{Resource: "storage-pool/" + desired.Pool, Mismatch: fmt.Sprintf("source is %q, declared %q", source, desired.PoolPath)}
	}

	networkResource := "network/" + api.ProjectDefaultName + "/" + desired.Network
	if state.Network == nil {
		missing = append(missing, networkResource)
	} else if state.Network.Type != "bridge" {
		return Decision{}, &ConflictError{Resource: networkResource, Mismatch: fmt.Sprintf("type is %q, declared %q", state.Network.Type, "bridge")}
	} else if mismatch := configMismatch(comparableNetworkConfig(state.Network.Config), desired.NetworkConfig); mismatch != "" {
		return Decision{}, &ConflictError{Resource: networkResource, Mismatch: mismatch}
	}

	profileResource := "profile/" + desired.Project + "/" + desired.Profile
	if state.Profile == nil {
		missing = append(missing, profileResource)
	} else {
		changed, undeclared := configDifferences(state.Profile.Config, desired.ProfileConfig, func(string) bool { return true })
		deviceChanged, deviceUndeclared := deviceDifferences(state.Profile.Devices, desired.ProfileDevices)
		changed, undeclared = firstOf(changed, deviceChanged), firstOf(undeclared, deviceUndeclared)
		if undeclared != "" || (changed != "" && !owned) {
			return Decision{}, &ConflictError{Resource: profileResource, Mismatch: firstOf(undeclared, changed)}
		}
		if changed != "" {
			drift = append(drift, profileResource+": "+changed)
		}
	}

	switch {
	case len(missing) != 0:
		return Decision{Outcome: Absent, Missing: missing, Drift: drift}, nil
	case len(drift) != 0:
		return Decision{Outcome: Owned, Drift: drift}, nil
	}
	return Decision{Outcome: Matching}, nil
}

// ProjectConfigMatches accepts undeclared non-security project defaults but
// rejects any restricted.* key the declaration does not carry.
func ProjectConfigMatches(actual, desired api.ConfigMap) bool {
	changed, undeclared := projectDifferences(actual, desired)
	return changed == "" && undeclared == ""
}

// Preseed overlays declared keys and devices onto an existing resource and
// never removes anything, so the gate separates what preseed can apply
// (changed) from what it cannot (undeclared). Undeclared values are always
// a conflict, even on an owned project.
func projectDifferences(actual, desired api.ConfigMap) (changed, undeclared string) {
	return configDifferences(actual, desired, func(key string) bool {
		return key == "restricted" || strings.HasPrefix(key, "restricted.")
	})
}

// configDifferences reports the first declared key that is unset or differs,
// and the first undeclared key the filter cares about.
func configDifferences(actual, desired api.ConfigMap, counts func(string) bool) (changed, undeclared string) {
	for _, key := range sortedKeys(desired) {
		value, ok := actual[key]
		if !ok {
			changed = fmt.Sprintf("config %s is unset, declared %q", key, desired[key])
			break
		}
		if value != desired[key] {
			changed = fmt.Sprintf("config %s is %q, declared %q", key, value, desired[key])
			break
		}
	}
	for _, key := range sortedKeys(actual) {
		if _, declared := desired[key]; !declared && counts(key) {
			undeclared = fmt.Sprintf("config %s is %q but is not declared; preseed cannot remove it", key, actual[key])
			break
		}
	}
	return changed, undeclared
}

func deviceDifferences(actual, desired api.DevicesMap) (changed, undeclared string) {
	names := make([]string, 0, len(desired))
	for name := range desired {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		device, ok := actual[name]
		if !ok {
			changed = fmt.Sprintf("device %s is missing", name)
			break
		}
		if keyChanged, _ := configDifferences(device, desired[name], func(string) bool { return false }); keyChanged != "" {
			changed = fmt.Sprintf("device %s %s", name, keyChanged)
			break
		}
	}
	actualNames := make([]string, 0, len(actual))
	for name := range actual {
		actualNames = append(actualNames, name)
	}
	sort.Strings(actualNames)
	for _, name := range actualNames {
		declared, ok := desired[name]
		if !ok {
			undeclared = fmt.Sprintf("device %s is not declared; preseed cannot remove it", name)
			break
		}
		if _, extra := configDifferences(actual[name], declared, func(string) bool { return true }); extra != "" {
			undeclared = fmt.Sprintf("device %s %s", name, extra)
			break
		}
	}
	return changed, undeclared
}

func firstOf(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func configMismatch(actual, desired api.ConfigMap) string {
	for _, key := range sortedKeys(desired) {
		value, ok := actual[key]
		if !ok {
			return fmt.Sprintf("config %s is unset, declared %q", key, desired[key])
		}
		if value != desired[key] {
			return fmt.Sprintf("config %s is %q, declared %q", key, value, desired[key])
		}
	}
	for _, key := range sortedKeys(actual) {
		if _, declared := desired[key]; !declared {
			return fmt.Sprintf("config %s is %q but is not declared", key, actual[key])
		}
	}
	return ""
}

func comparableNetworkConfig(actual api.ConfigMap) api.ConfigMap {
	comparable := make(api.ConfigMap, len(actual))
	for key, value := range actual {
		if strings.HasPrefix(key, "volatile.") || key == "bridge.hwaddr" {
			continue
		}
		comparable[key] = value
	}
	return comparable
}

func sortedKeys(config api.ConfigMap) []string {
	keys := make([]string, 0, len(config))
	for key := range config {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

type incusReader struct {
	server incus.InstanceServer
}

// NewReader adapts a connected Incus client to the read-only Reader.
func NewReader(server incus.InstanceServer) Reader {
	return incusReader{server: server}
}

func (r incusReader) Project(name string) (*api.Project, error) {
	project, _, err := r.server.GetProject(name)
	if err != nil {
		return nil, absentAsNil(err)
	}
	return project, nil
}

func (r incusReader) StoragePool(name string) (*api.StoragePool, error) {
	pool, _, err := r.server.GetStoragePool(name)
	if err != nil {
		return nil, absentAsNil(err)
	}
	return pool, nil
}

func (r incusReader) Network(project, name string) (*api.Network, error) {
	network, _, err := r.server.UseProject(project).GetNetwork(name)
	if err != nil {
		return nil, absentAsNil(err)
	}
	return network, nil
}

func (r incusReader) Profile(project, name string) (*api.Profile, error) {
	profile, _, err := r.server.UseProject(project).GetProfile(name)
	if err != nil {
		return nil, absentAsNil(err)
	}
	return profile, nil
}

func absentAsNil(err error) error {
	if api.StatusErrorCheck(err, http.StatusNotFound) {
		return nil
	}
	return err
}
