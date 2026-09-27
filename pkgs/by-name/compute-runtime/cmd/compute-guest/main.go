//go:build linux

package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"

	"github.com/dvicory/homelab/compute-runtime/internal/adoption"
	"github.com/dvicory/homelab/compute-runtime/internal/incusops"
)

const (
	incusSocket       = "/var/lib/incus/unix.socket"
	defaultSpec       = "/etc/homelab/compute.json"
	lifecycleLockDir  = "/run/lock"
	readinessBudget   = 240 * time.Second
	operationTimeout  = 180 * time.Second
	imageTimeout      = 1800 * time.Second
	nativeCommandTime = 180 * time.Second
)

var (
	validName = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)
	errHelp   = errors.New("help")
)

const usage = "usage: compute-guest [--spec PATH] [--bundle PATH] [--confirm NAME] [--lock-fd FD] adopt|inspect|create|replace"

type cliArgs struct {
	spec      string
	operation string
	bundle    string
	confirm   string
	lockFD    *int
}

type descriptor struct {
	Project       string                `json:"project"`
	Instance      string                `json:"instance"`
	Profile       string                `json:"profile"`
	Pool          string                `json:"pool"`
	Network       string                `json:"network"`
	Address       string                `json:"address"`
	ProjectConfig api.ConfigMap         `json:"projectConfig"`
	PoolPath      string                `json:"poolPath"`
	NetworkConfig api.ConfigMap         `json:"networkConfig"`
	Config        api.ConfigMap         `json:"config"`
	Devices       api.DevicesMap        `json:"devices"`
	RequiredPaths []requiredPath        `json:"requiredPaths"`
	IdentityPath  string                `json:"identityPath"`
	PublicKey     string                `json:"publicKey"`
	IDMapBase     int64                 `json:"idmapBase"`
	IDMapSize     int64                 `json:"idmapSize"`
	IDMap         map[string][]idMapRow `json:"idmap"`
}

type requiredPath struct {
	Path     string  `json:"path"`
	UID      *int64  `json:"uid"`
	GID      *int64  `json:"gid"`
	Mode     *string `json:"mode"`
	ReadOnly *bool   `json:"readOnly"`
}

type idMapRow struct {
	NSID   int64 `json:"nsid"`
	HostID int64 `json:"hostid"`
	Range  int64 `json:"range"`
}

type idRange struct {
	nsid   int64
	hostid int64
	rangeN int64
}

type subordinateAllocation struct {
	owner string
	base  int64
	count int64
}

type descriptorData struct {
	spec descriptor
	raw  map[string]any
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		if errors.Is(err, errHelp) {
			fmt.Fprintln(os.Stdout, usage)
			return
		}
		fmt.Fprintf(os.Stderr, "compute-guest: %v\n", err)
		os.Exit(1)
	}
}

func run(argv []string) error {
	args, err := parseArgs(argv)
	if err != nil {
		return err
	}
	if os.Geteuid() != 0 {
		return errors.New("run on the physical host as root; do not run against a remote Incus context")
	}

	descriptorData, err := loadDescriptor(args.spec)
	if err != nil {
		return err
	}
	spec := descriptorData.spec
	if !validName.MatchString(spec.Project) || !validName.MatchString(spec.Instance) {
		return errors.New("descriptor has an invalid project or instance name")
	}

	lockPath := filepath.Join(lifecycleLockDir, "compute-"+spec.Project+"-"+spec.Instance+".lock")
	lock, err := openLifecycleLock(lockPath, args.lockFD)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return fmt.Errorf("cannot acquire lifecycle lock: %w", err)
	}
	if args.lockFD == nil {
		defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	}
	socket := strings.TrimSpace(os.Getenv("INCUS_SOCKET"))
	if socket == "" {
		socket = incusSocket
	}
	server, err := incus.ConnectIncusUnixWithContext(context.Background(), socket, &incus.ConnectionArgs{
		HTTPClient:    &http.Client{Timeout: 30 * time.Minute},
		SkipGetEvents: true,
	})
	if err != nil {
		return fmt.Errorf("connect to local Incus: %w", err)
	}
	defer server.Disconnect()

	projectServer := server.UseProject(spec.Project)
	if args.operation == "adopt" {
		decision, err := checkAdoption(server, spec)
		if err != nil {
			return err
		}
		fmt.Printf("declared Incus envelope adoption check: %s", decision.Outcome)
		if len(decision.Missing) != 0 {
			fmt.Printf(" (missing %s)", strings.Join(decision.Missing, ", "))
		}
		fmt.Println()
		return nil
	}
	instance, err := inspectEnvelope(server, projectServer, spec)
	if err != nil {
		return err
	}
	if args.operation == "inspect" {
		output := map[string]any{"desired": descriptorData.raw, "instance": instance}
		encoded, err := json.MarshalIndent(output, "", "  ")
		if err != nil {
			return fmt.Errorf("encode inspection result: %w", err)
		}
		fmt.Println(string(encoded))
		return nil
	}
	if args.bundle == "" {
		return errors.New("--bundle is required")
	}
	selected, err := validateBundle(args.bundle)
	if err != nil {
		return err
	}
	if args.operation == "replace" && args.confirm != spec.Instance {
		return fmt.Errorf("explicit acknowledgment required: --confirm %s", spec.Instance)
	}
	if args.operation == "replace" && instance == nil {
		return errors.New("instance is absent; use create with a declared bundle")
	}
	oldReference := ""
	if instance != nil {
		oldReference = instance.Config["user.homelab.bundle"]
	}
	if args.operation == "create" && instance != nil {
		if oldReference == "" {
			return errors.New("existing instance has unknown image provenance; use replace")
		}
		if selected != oldReference {
			return errors.New("creation cannot update an existing instance; use replace")
		}
		fmt.Printf("%s/%s already exists and conforms; its root was preserved.\n", spec.Project, spec.Instance)
		return nil
	}

	if err := retainBundle(spec, selected); err != nil {
		return err
	}
	fingerprint, err := importImage(projectServer, selected)
	if err != nil {
		return err
	}
	if err := lifecycle(projectServer, spec, instance, selected, fingerprint); err != nil {
		if !errors.Is(err, incusops.ErrUnknownOutcome) {
			if cleanupErr := stopIfRunning(projectServer, spec.Instance); cleanupErr != nil {
				fmt.Fprintf(os.Stderr, "compute-guest: failed to stop guest after lifecycle error: %v\n", cleanupErr)
			}
		}
		return err
	}
	return nil
}

func parseArgs(argv []string) (cliArgs, error) {
	args := cliArgs{spec: defaultSpec}
	var positional []string
	options := true
	for i := 0; i < len(argv); i++ {
		arg := argv[i]
		if options && (arg == "-h" || arg == "--help") {
			return cliArgs{}, errHelp
		}
		if options && arg == "--" {
			options = false
			continue
		}
		if options && strings.HasPrefix(arg, "--") {
			name, value, hasValue := strings.Cut(arg, "=")
			if name == "--help" && !hasValue {
				return cliArgs{}, errHelp
			}
			if !hasValue {
				if i+1 >= len(argv) {
					return cliArgs{}, fmt.Errorf("option %s requires a value", name)
				}
				value = argv[i+1]
				i++
			}
			switch name {
			case "--spec":
				args.spec = value
			case "--bundle":
				args.bundle = value
			case "--confirm":
				args.confirm = value
			case "--lock-fd":
				fd, err := strconv.Atoi(value)
				if err != nil || fd < 0 {
					return cliArgs{}, fmt.Errorf("invalid --lock-fd %q", value)
				}
				args.lockFD = &fd
			case "--help":
				return cliArgs{}, errHelp
			default:
				return cliArgs{}, fmt.Errorf("unknown option %s", name)
			}
			continue
		}
		if options && strings.HasPrefix(arg, "-") {
			return cliArgs{}, fmt.Errorf("unknown option %s", arg)
		}
		positional = append(positional, arg)
	}
	if len(positional) != 1 || (positional[0] != "adopt" && positional[0] != "inspect" && positional[0] != "create" && positional[0] != "replace") {
		return cliArgs{}, errors.New("operation must be one of adopt, inspect, create, replace")
	}
	args.operation = positional[0]
	return args, nil
}

func loadDescriptor(path string) (descriptorData, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return descriptorData{}, fmt.Errorf("cannot resolve descriptor: %s: %w", path, err)
	}
	resolved, err := filepath.EvalSymlinks(absolute)
	if err != nil {
		return descriptorData{}, fmt.Errorf("cannot resolve descriptor: %s: %w", path, err)
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return descriptorData{}, fmt.Errorf("cannot stat descriptor: %w", err)
	}
	if !info.Mode().IsRegular() {
		return descriptorData{}, errors.New("descriptor is not a regular file")
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || st.Uid != 0 {
		return descriptorData{}, errors.New("descriptor must be root-owned")
	}
	if st.Mode&0o22 != 0 {
		return descriptorData{}, errors.New("descriptor must not be writable by group or other users")
	}
	content, err := os.ReadFile(resolved)
	if err != nil {
		return descriptorData{}, fmt.Errorf("read descriptor: %w", err)
	}
	var raw map[string]any
	if err := json.Unmarshal(content, &raw); err != nil {
		return descriptorData{}, fmt.Errorf("descriptor is not a JSON object: %w", err)
	}
	if raw == nil {
		return descriptorData{}, errors.New("descriptor must be a JSON object")
	}
	var spec descriptor
	if err := json.Unmarshal(content, &spec); err != nil {
		return descriptorData{}, fmt.Errorf("decode descriptor: %w", err)
	}
	return descriptorData{spec: spec, raw: raw}, nil
}

func inspectEnvelope(server, projectServer incus.InstanceServer, spec descriptor) (*api.Instance, error) {
	missing, err := checkPreseed(server, spec)
	if err != nil {
		return nil, err
	}
	if len(missing) != 0 {
		return nil, fmt.Errorf("declared Incus envelope is incomplete: %s", strings.Join(missing, ", "))
	}
	instance, err := currentInstance(projectServer, spec.Instance)
	if err != nil {
		return nil, err
	}
	if err := checkInstance(spec, instance); err != nil {
		return nil, err
	}
	if err := checkIDMap(server, spec, instance); err != nil {
		return nil, err
	}
	if err := checkRequiredPaths(spec); err != nil {
		return nil, err
	}
	if err := checkIdentity(spec); err != nil {
		return nil, err
	}
	return instance, nil
}

func checkAdoption(server incus.InstanceServer, spec descriptor) (adoption.Decision, error) {
	return adoption.Gate(adoption.NewReader(server), adoption.Envelope{
		Project:        spec.Project,
		ProjectConfig:  spec.ProjectConfig,
		Pool:           spec.Pool,
		PoolPath:       spec.PoolPath,
		Network:        spec.Network,
		NetworkConfig:  spec.NetworkConfig,
		Profile:        spec.Profile,
		ProfileConfig:  spec.Config,
		ProfileDevices: spec.Devices,
	})
}

func checkPreseed(server incus.InstanceServer, spec descriptor) ([]string, error) {
	decision, err := checkAdoption(server, spec)
	if err != nil {
		return nil, err
	}
	return decision.Missing, nil
}

func projectConfigMatches(actual, desired api.ConfigMap) bool {
	return adoption.ProjectConfigMatches(actual, desired)
}

func currentInstance(server incus.InstanceServer, name string) (*api.Instance, error) {
	instances, err := server.GetInstances(api.InstanceTypeAny)
	if err != nil {
		return nil, fmt.Errorf("inspect instance %s: %w", name, err)
	}
	for i := range instances {
		if instances[i].Name == name {
			return &instances[i], nil
		}
	}
	return nil, nil
}

func checkInstance(spec descriptor, instance *api.Instance) error {
	if instance == nil {
		return nil
	}
	actual := make(api.ConfigMap)
	for key, value := range instance.ExpandedConfig {
		if strings.HasPrefix(key, "volatile.") || strings.HasPrefix(key, "image.") || key == "user.homelab.bundle" {
			continue
		}
		actual[key] = value
	}
	if instance.Type != string(api.InstanceTypeContainer) || !reflect.DeepEqual(instance.Profiles, []string{spec.Profile}) || !reflect.DeepEqual(actual, spec.Config) || !reflect.DeepEqual(instance.ExpandedDevices, spec.Devices) {
		return errors.New("existing instance has incompatible effective configuration; refusing mutation")
	}
	return nil
}

func checkRequiredPaths(spec descriptor) error {
	if len(spec.RequiredPaths) == 0 {
		return errors.New("Nix descriptor has no required host paths")
	}
	for _, entry := range spec.RequiredPaths {
		if entry.UID == nil || entry.GID == nil || entry.Mode == nil {
			return errors.New("malformed required host path metadata")
		}
		mode, err := strconv.ParseUint(*entry.Mode, 8, 32)
		if err != nil || mode > 0o7777 {
			return errors.New("malformed required host path metadata")
		}
		if !filepath.IsAbs(entry.Path) {
			return fmt.Errorf("required host path is not an existing directory: %s", entry.Path)
		}
		info, err := os.Stat(entry.Path)
		if err != nil || !info.IsDir() {
			return fmt.Errorf("required host path is not an existing directory: %s", entry.Path)
		}
		st, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			return fmt.Errorf("cannot inspect required host path: %s", entry.Path)
		}
		if int64(st.Uid) != *entry.UID || int64(st.Gid) != *entry.GID {
			return fmt.Errorf("unexpected required path identity: %s; never repair by recursive chown", entry.Path)
		}
		if uint64(st.Mode&0o7777) != mode {
			return fmt.Errorf("unexpected required path mode: %s; never repair permissions", entry.Path)
		}
		if entry.ReadOnly != nil {
			output, err := runNative(context.Background(), nativeCommandTime, "findmnt", "-n", "-o", "VFS-OPTIONS", "-M", entry.Path)
			if err != nil {
				return err
			}
			readOnly := false
			for _, option := range strings.Split(strings.TrimSpace(output), ",") {
				if option == "ro" {
					readOnly = true
					break
				}
			}
			if readOnly != *entry.ReadOnly {
				state := "writable"
				if *entry.ReadOnly {
					state = "read-only"
				}
				return fmt.Errorf("required host path is not mounted %s: %s", state, entry.Path)
			}
		}
	}
	return nil
}

func checkIdentity(spec descriptor) error {
	if strings.TrimSpace(spec.PublicKey) == "" {
		return errors.New("guest public identity is not provisioned in the host declaration")
	}
	public, err := runNative(context.Background(), nativeCommandTime, "ssh-keygen", "-y", "-f", filepath.Join(spec.IdentityPath, "ssh_host_ed25519_key"))
	if err != nil {
		return err
	}
	actualFields := strings.Fields(public)
	expectedFields := strings.Fields(spec.PublicKey)
	if len(actualFields) < 2 || len(expectedFields) < 2 || actualFields[0] != expectedFields[0] || actualFields[1] != expectedFields[1] {
		return errors.New("staged guest private key does not match the declared public identity")
	}
	return nil
}

func checkIDMap(server incus.InstanceServer, spec descriptor, instance *api.Instance) error {
	if spec.IDMapBase <= 0 || spec.IDMapSize <= 0 || spec.IDMapBase > int64(^uint64(0)>>1)-spec.IDMapSize {
		return errors.New("Nix descriptor has an invalid ID map")
	}
	expectedUID, err := desiredIDMap(spec, "uid")
	if err != nil {
		return err
	}
	expectedGID, err := desiredIDMap(spec, "gid")
	if err != nil {
		return err
	}
	if instance != nil {
		raw, ok := instance.Config["volatile.idmap.current"]
		if !ok {
			raw, ok = instance.ExpandedConfig["volatile.idmap.current"]
		}
		if !ok || raw == "" {
			return errors.New("existing instance has no valid effective ID map; refusing mutation")
		}
		uidRanges, gidRanges, err := parseEffectiveIDMap(raw)
		if err != nil {
			return fmt.Errorf("existing instance has no valid effective ID map; refusing mutation: %w", err)
		}
		if !reflect.DeepEqual(uidRanges, expectedUID) || !reflect.DeepEqual(gidRanges, expectedGID) {
			return errors.New("existing instance has incompatible effective ID map; refusing mutation")
		}
	}

	desiredByPath := map[string][]idRange{
		"/etc/subuid": expectedUID,
		"/etc/subgid": expectedGID,
	}
	for allocationPath, desired := range desiredByPath {
		allocations, err := readSubordinateAllocations(allocationPath)
		if err != nil {
			return err
		}
		for _, row := range desired {
			covered := false
			for _, allocation := range allocations {
				if allocation.owner == "root" && allocationCovers(allocation, row) {
					covered = true
					break
				}
			}
			if !covered {
				return fmt.Errorf("root lacks subordinate coverage for host IDs %d-%d in %s", row.hostid, row.hostid+row.rangeN-1, allocationPath)
			}
		}
		for _, allocation := range allocations {
			if allocation.owner == "root" {
				continue
			}
			candidate := idRange{hostid: allocation.base, rangeN: allocation.count}
			if overlapsAnyHostRange(candidate, desired) {
				return fmt.Errorf("declared ID map overlaps another owner in %s", allocationPath)
			}
		}
	}

	allInstances, err := server.GetInstancesAllProjects(api.InstanceTypeContainer)
	if err != nil {
		return fmt.Errorf("inspect all Incus instances for ID-map collisions: %w", err)
	}
	for _, other := range allInstances {
		if other.Project == spec.Project && other.Name == spec.Instance {
			continue
		}
		raw, comparable, err := collisionIDMap(other)
		if err != nil {
			return fmt.Errorf("inspect effective ID map for %s/%s: %w", other.Project, other.Name, err)
		}
		if !comparable {
			continue
		}
		otherUID, otherGID, err := parseEffectiveIDMap(raw)
		if err != nil {
			return fmt.Errorf("inspect effective ID map for %s/%s: %w", other.Project, other.Name, err)
		}
		for _, row := range otherUID {
			if overlapsAnyHostRange(row, expectedUID) {
				return fmt.Errorf("UID map overlaps %s/%s", other.Project, other.Name)
			}
		}
		for _, row := range otherGID {
			if overlapsAnyHostRange(row, expectedGID) {
				return fmt.Errorf("GID map overlaps %s/%s", other.Project, other.Name)
			}
		}
	}
	return nil
}

func collisionIDMap(instance api.Instance) (string, bool, error) {
	if instance.Config["security.privileged"] == "true" || instance.ExpandedConfig["security.privileged"] == "true" {
		return "", false, nil
	}
	for _, key := range []string{"volatile.idmap.current", "volatile.idmap.next"} {
		if raw := instance.Config[key]; raw != "" {
			return raw, true, nil
		}
		if raw := instance.ExpandedConfig[key]; raw != "" {
			return raw, true, nil
		}
	}
	if instance.Status == "Stopped" {
		return "", false, nil
	}
	return "", false, errors.New("missing ID map on active unprivileged instance")
}

func allocationCovers(allocation subordinateAllocation, row idRange) bool {
	return allocation.base <= row.hostid && allocation.base+allocation.count >= row.hostid+row.rangeN
}

func overlapsAnyHostRange(candidate idRange, desired []idRange) bool {
	for _, row := range desired {
		if candidate.hostid < row.hostid+row.rangeN && row.hostid < candidate.hostid+candidate.rangeN {
			return true
		}
	}
	return false
}

func parseEffectiveIDMap(raw string) ([]idRange, []idRange, error) {
	rows, err := parseAllIDMapRows(raw)
	if err != nil {
		return nil, nil, err
	}
	var uidRanges, gidRanges []idRange
	var encoded []map[string]json.RawMessage
	if err := json.Unmarshal([]byte(raw), &encoded); err != nil {
		return nil, nil, err
	}
	for index, entry := range encoded {
		isUID, err := rawBool(entry["Isuid"])
		if err != nil {
			return nil, nil, fmt.Errorf("row %d Isuid: %w", index, err)
		}
		isGID, err := rawBool(entry["Isgid"])
		if err != nil {
			return nil, nil, fmt.Errorf("row %d Isgid: %w", index, err)
		}
		row := rows[index]
		if isUID {
			uidRanges = append(uidRanges, row)
		}
		if isGID {
			gidRanges = append(gidRanges, row)
		}
	}
	if len(uidRanges) == 0 || len(gidRanges) == 0 {
		return nil, nil, errors.New("ID map has no UID or GID rows")
	}
	sort.Slice(uidRanges, func(i, j int) bool { return lessIDRange(uidRanges[i], uidRanges[j]) })
	sort.Slice(gidRanges, func(i, j int) bool { return lessIDRange(gidRanges[i], gidRanges[j]) })
	return uidRanges, gidRanges, nil
}

func parseAllIDMapRows(raw string) ([]idRange, error) {
	var encoded []map[string]json.RawMessage
	if err := json.Unmarshal([]byte(raw), &encoded); err != nil {
		return nil, err
	}
	rows := make([]idRange, 0, len(encoded))
	maxInt64 := int64(^uint64(0) >> 1)
	for index, entry := range encoded {
		isUID, err := rawBool(entry["Isuid"])
		if err != nil {
			return nil, fmt.Errorf("row %d Isuid: %w", index, err)
		}
		isGID, err := rawBool(entry["Isgid"])
		if err != nil {
			return nil, fmt.Errorf("row %d Isgid: %w", index, err)
		}
		if !isUID && !isGID {
			return nil, fmt.Errorf("row %d maps neither UID nor GID", index)
		}
		nsid, err := rawInt(entry["Nsid"])
		if err != nil {
			return nil, fmt.Errorf("row %d Nsid: %w", index, err)
		}
		hostid, err := rawInt(entry["Hostid"])
		if err != nil {
			return nil, fmt.Errorf("row %d Hostid: %w", index, err)
		}
		rangeN, err := rawInt(entry["Maprange"])
		if err != nil {
			return nil, fmt.Errorf("row %d Maprange: %w", index, err)
		}
		if nsid < 0 || hostid < 0 || rangeN <= 0 || nsid > maxInt64-rangeN || hostid > maxInt64-rangeN {
			return nil, fmt.Errorf("row %d has invalid ID range", index)
		}
		rows = append(rows, idRange{nsid: nsid, hostid: hostid, rangeN: rangeN})
	}
	return rows, nil
}

func desiredIDMap(spec descriptor, kind string) ([]idRange, error) {
	rows := spec.IDMap[kind]
	if len(rows) == 0 {
		return nil, errors.New("Nix descriptor carries no expected ID map")
	}
	result := make([]idRange, 0, len(rows))
	for _, row := range rows {
		result = append(result, idRange{nsid: row.NSID, hostid: row.HostID, rangeN: row.Range})
	}
	sort.Slice(result, func(i, j int) bool { return lessIDRange(result[i], result[j]) })
	return result, nil
}

func lessIDRange(left, right idRange) bool {
	if left.nsid != right.nsid {
		return left.nsid < right.nsid
	}
	if left.hostid != right.hostid {
		return left.hostid < right.hostid
	}
	return left.rangeN < right.rangeN
}

func rawBool(raw json.RawMessage) (bool, error) {
	if len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return false, errors.New("missing boolean")
	}
	var value bool
	if err := json.Unmarshal(raw, &value); err != nil {
		return false, err
	}
	return value, nil
}

func rawInt(raw json.RawMessage) (int64, error) {
	if len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return 0, errors.New("missing integer")
	}
	var value int64
	if err := json.Unmarshal(raw, &value); err != nil {
		return 0, err
	}
	return value, nil
}

func readSubordinateAllocations(path string) ([]subordinateAllocation, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	var allocations []subordinateAllocation
	for lineNumber, line := range strings.Split(string(content), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Split(line, ":")
		if len(fields) != 3 {
			return nil, fmt.Errorf("malformed subordinate allocation at %s:%d", path, lineNumber+1)
		}
		base, err := strconv.ParseInt(fields[1], 10, 64)
		if err != nil || base < 0 {
			return nil, fmt.Errorf("malformed subordinate allocation at %s:%d", path, lineNumber+1)
		}
		count, err := strconv.ParseInt(fields[2], 10, 64)
		if err != nil || count < 0 || base > int64(^uint64(0)>>1)-count {
			return nil, fmt.Errorf("malformed subordinate allocation at %s:%d", path, lineNumber+1)
		}
		allocations = append(allocations, subordinateAllocation{owner: fields[0], base: base, count: count})
	}
	return allocations, nil
}

func openLifecycleLock(path string, inheritedFD *int) (*os.File, error) {
	if inheritedFD == nil {
		file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0o600)
		if err != nil {
			return nil, fmt.Errorf("open lifecycle lock: %w", err)
		}
		if err := file.Chmod(0o600); err != nil {
			file.Close()
			return nil, fmt.Errorf("secure lifecycle lock: %w", err)
		}
		return file, nil
	}
	var inherited syscall.Stat_t
	if err := syscall.Fstat(*inheritedFD, &inherited); err != nil {
		return nil, fmt.Errorf("invalid inherited lifecycle lock: %w", err)
	}
	expectedInfo, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("invalid inherited lifecycle lock: %w", err)
	}
	expected, ok := expectedInfo.Sys().(*syscall.Stat_t)
	if !ok || inherited.Dev != expected.Dev || inherited.Ino != expected.Ino {
		return nil, errors.New("inherited descriptor is not the selected lifecycle lock")
	}
	dup, err := syscall.Dup(*inheritedFD)
	if err != nil {
		return nil, fmt.Errorf("invalid inherited lifecycle lock: %w", err)
	}
	file := os.NewFile(uintptr(dup), path)
	if err := file.Chmod(0o600); err != nil {
		file.Close()
		return nil, fmt.Errorf("secure inherited lifecycle lock: %w", err)
	}
	return file, nil
}

func validateBundle(path string) (string, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("cannot resolve bundle: %w", err)
	}
	resolved, err := filepath.EvalSymlinks(absolute)
	if err != nil {
		return "", fmt.Errorf("cannot resolve bundle: %w", err)
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", fmt.Errorf("cannot stat bundle: %w", err)
	}
	if !info.IsDir() {
		return "", errors.New("bundle must be an immutable Nix store output")
	}
	relative, err := filepath.Rel("/nix/store", resolved)
	if err != nil || relative == "." || relative == ".." || strings.HasPrefix(relative, ".."+string(os.PathSeparator)) {
		return "", errors.New("bundle must be an immutable Nix store output")
	}
	for _, member := range []string{"metadata.tar.xz", "rootfs.tar.xz", "system"} {
		if _, err := os.Stat(filepath.Join(resolved, member)); err != nil {
			return "", fmt.Errorf("incomplete bundle: %s", member)
		}
	}
	return resolved, nil
}

func retainBundle(spec descriptor, bundle string) error {
	roots := "/nix/var/nix/gcroots/homelab-compute"
	if err := os.MkdirAll(roots, 0o700); err != nil {
		return fmt.Errorf("create bundle GC-root directory: %w", err)
	}
	digest := sha256.Sum256([]byte(bundle))
	root := filepath.Join(roots, spec.Project+"-"+spec.Instance+"-"+hex.EncodeToString(digest[:]))
	_, err := runNative(context.Background(), 180*time.Second, "nix-store", "--add-root", root, "--realise", bundle)
	return err
}

func importImage(server incus.InstanceServer, bundle string) (string, error) {
	digest := sha256.New()
	for _, member := range []string{"metadata.tar.xz", "rootfs.tar.xz"} {
		file, err := os.Open(filepath.Join(bundle, member))
		if err != nil {
			return "", fmt.Errorf("open image member %s: %w", member, err)
		}
		_, copyErr := io.CopyBuffer(digest, file, make([]byte, 1024*1024))
		closeErr := file.Close()
		if copyErr != nil {
			return "", fmt.Errorf("hash image member %s: %w", member, copyErr)
		}
		if closeErr != nil {
			return "", fmt.Errorf("close image member %s: %w", member, closeErr)
		}
	}
	fingerprint := hex.EncodeToString(digest.Sum(nil))
	images, err := server.GetImages()
	if err != nil {
		return "", fmt.Errorf("inspect Incus images: %w", err)
	}
	for _, image := range images {
		if image.Fingerprint == fingerprint {
			return fingerprint, nil
		}
	}

	metadata, err := os.Open(filepath.Join(bundle, "metadata.tar.xz"))
	if err != nil {
		return "", fmt.Errorf("open image metadata: %w", err)
	}
	defer metadata.Close()
	rootfs, err := os.Open(filepath.Join(bundle, "rootfs.tar.xz"))
	if err != nil {
		return "", fmt.Errorf("open image rootfs: %w", err)
	}
	defer rootfs.Close()
	op, err := server.CreateImage(api.ImagesPost{Filename: "metadata.tar.xz"}, &incus.ImageCreateArgs{
		MetaFile:   metadata,
		MetaName:   "metadata.tar.xz",
		RootfsFile: rootfs,
		RootfsName: "rootfs.tar.xz",
		Type:       "container",
	})
	if err != nil {
		return "", fmt.Errorf("import image: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), imageTimeout)
	defer cancel()
	if _, err := incusops.Wait(ctx, server, op); err != nil {
		return "", fmt.Errorf("import image: %w", err)
	}
	return fingerprint, nil
}

func lifecycle(projectServer incus.InstanceServer, spec descriptor, instance *api.Instance, bundle, fingerprint string) error {
	if instance != nil {
		if err := stopIfRunning(projectServer, spec.Instance); err != nil {
			return err
		}
		current, err := currentInstance(projectServer, spec.Instance)
		if err != nil {
			return err
		}
		if current != nil && current.Status == "Running" {
			return errors.New("instance is still running; refusing deletion")
		}
		op, err := projectServer.DeleteInstance(spec.Instance)
		if err != nil {
			return fmt.Errorf("delete instance: %w", err)
		}
		if err := waitOperation(projectServer, op, operationTimeout, "delete instance"); err != nil {
			return err
		}
	}

	op, err := projectServer.CreateInstance(api.InstancesPost{
		InstancePut: api.InstancePut{
			Config:   api.ConfigMap{"user.homelab.bundle": bundle},
			Profiles: []string{spec.Profile},
		},
		Name: spec.Instance,
		Source: api.InstanceSource{
			Type:        "image",
			Fingerprint: fingerprint,
		},
		Type:  api.InstanceTypeContainer,
		Start: false,
	})
	if err != nil {
		return fmt.Errorf("initialize instance: %w", err)
	}
	if err := waitOperation(projectServer, op, imageTimeout, "initialize instance"); err != nil {
		return err
	}

	op, err = projectServer.UpdateInstanceState(spec.Instance, api.InstanceStatePut{Action: "start"}, "")
	if err != nil {
		return fmt.Errorf("start instance: %w", err)
	}
	if err := waitOperation(projectServer, op, operationTimeout, "start instance"); err != nil {
		return err
	}
	if err := waitReady(projectServer, spec.Instance); err != nil {
		return err
	}

	fmt.Printf("%s/%s: guest management and K3s are ready.\n", spec.Project, spec.Instance)
	return nil
}

func stopIfRunning(server incus.InstanceServer, name string) error {
	instance, err := currentInstance(server, name)
	if err != nil {
		return err
	}
	if instance == nil || instance.Status != "Running" {
		return nil
	}
	op, err := server.UpdateInstanceState(name, api.InstanceStatePut{Action: "stop", Timeout: 120}, "")
	if err != nil {
		return fmt.Errorf("stop instance: %w", err)
	}
	if err := waitOperation(server, op, operationTimeout, "stop instance"); err != nil {
		return err
	}
	instance, err = currentInstance(server, name)
	if err != nil {
		return err
	}
	if instance != nil && instance.Status == "Running" {
		return errors.New("instance remained running after graceful stop; refusing deletion")
	}
	return nil
}

func waitOperation(server incus.InstanceServer, op incus.Operation, timeout time.Duration, action string) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	if _, err := incusops.Wait(ctx, server, op); err != nil {
		return fmt.Errorf("%s: %w", action, err)
	}
	return nil
}

func waitReady(server incus.InstanceServer, name string) error {
	deadline := time.Now().Add(readinessBudget)
	layer := "guest management"
	var lastErr error
	for time.Now().Before(deadline) {
		layer = "guest management and K3s service"
		var managementOutput, managementError bytes.Buffer
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		err := incusops.Exec(ctx, server, name, []string{"systemctl", "is-active", "sshd", "k3s"}, strings.NewReader(""), &managementOutput, &managementError)
		cancel()
		if err != nil {
			lastErr = err
			sleepReadiness(deadline)
			continue
		}

		layer = "Kubernetes node readiness"
		var nodeOutput, nodeError bytes.Buffer
		ctx, cancel = context.WithTimeout(context.Background(), 20*time.Second)
		err = incusops.Exec(ctx, server, name, []string{"k3s", "kubectl", "--request-timeout=15s", "get", "nodes", "-o", "json"}, strings.NewReader(""), &nodeOutput, &nodeError)
		cancel()
		if err != nil {
			lastErr = err
			sleepReadiness(deadline)
			continue
		}
		ready, err := nodesReady(nodeOutput.Bytes())
		if err != nil {
			lastErr = err
			sleepReadiness(deadline)
			continue
		}
		if ready {
			return nil
		}
		lastErr = errors.New("Kubernetes node list has no all-Ready nodes")
		sleepReadiness(deadline)
	}
	if lastErr == nil {
		lastErr = errors.New("readiness probes did not complete")
	}
	return fmt.Errorf("readiness failed at %s: %w; the guest was stopped and retained inputs were not removed", layer, lastErr)
}

func sleepReadiness(deadline time.Time) {
	remaining := time.Until(deadline)
	if remaining <= 0 {
		return
	}
	if remaining > 2*time.Second {
		remaining = 2 * time.Second
	}
	time.Sleep(remaining)
}

func nodesReady(content []byte) (bool, error) {
	var response struct {
		Items []struct {
			Status struct {
				Conditions []struct {
					Type   string `json:"type"`
					Status string `json:"status"`
				} `json:"conditions"`
			} `json:"status"`
		} `json:"items"`
	}
	if err := json.Unmarshal(content, &response); err != nil {
		return false, fmt.Errorf("decode Kubernetes node list: %w", err)
	}
	if len(response.Items) == 0 {
		return false, nil
	}
	for _, item := range response.Items {
		found := false
		for _, condition := range item.Status.Conditions {
			if condition.Type == "Ready" && condition.Status == "True" {
				found = true
				break
			}
		}
		if !found {
			return false, nil
		}
	}
	return true, nil
}

func runNative(parent context.Context, timeout time.Duration, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	command := exec.CommandContext(ctx, name, args...)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		detail := strings.TrimSpace(stderr.String())
		if detail != "" {
			return "", fmt.Errorf("%s failed: %w: %s", name, err, detail)
		}
		return "", fmt.Errorf("%s failed: %w", name, err)
	}
	return strings.TrimSpace(stdout.String()), nil
}
