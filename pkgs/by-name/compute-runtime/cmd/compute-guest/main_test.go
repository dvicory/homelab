//go:build linux

package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/lxc/incus/v7/shared/api"
)

func TestEffectiveIDMap(t *testing.T) {
	uid, gid, err := parseEffectiveIDMap(`[{"Isuid":true,"Isgid":true,"Nsid":0,"Hostid":1000000,"Maprange":65536}]`)
	if err != nil || len(uid) != 1 || len(gid) != 1 || uid[0] != (idRange{nsid: 0, hostid: 1000000, rangeN: 65536}) || gid[0] != uid[0] {
		t.Fatalf("valid combined UID/GID allocation: uid=%v gid=%v err=%v", uid, gid, err)
	}
	for name, raw := range map[string]string{
		"null identity":           `[{"Isuid":true,"Isgid":true,"Nsid":null,"Hostid":1000000,"Maprange":65536}]`,
		"null type":               `[{"Isuid":null,"Isgid":true,"Nsid":0,"Hostid":1000000,"Maprange":65536},{"Isuid":true,"Isgid":false,"Nsid":0,"Hostid":1000000,"Maprange":65536}]`,
		"overflowing host range":  `[{"Isuid":true,"Isgid":true,"Nsid":0,"Hostid":9223372036854775807,"Maprange":2}]`,
		"overflowing guest range": `[{"Isuid":true,"Isgid":true,"Nsid":9223372036854775807,"Hostid":1000000,"Maprange":2}]`,
		"missing GID allocation":  `[{"Isuid":true,"Isgid":false,"Nsid":0,"Hostid":1000000,"Maprange":65536}]`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, _, err := parseEffectiveIDMap(raw); err == nil {
				t.Fatal("invalid effective mapping must refuse lifecycle mutation")
			}
		})
	}
}

func TestProjectConfigMatches(t *testing.T) {
	desired := map[string]string{
		"features.images":               "true",
		"restricted":                    "true",
		"restricted.devices.gpu":        "block",
		"restricted.devices.disk.paths": "/srv/identity",
	}
	actual := map[string]string{
		"features.images":               "true",
		"features.profiles":             "true",
		"restricted":                    "true",
		"restricted.devices.gpu":        "block",
		"restricted.devices.disk.paths": "/srv/identity",
	}
	if !projectConfigMatches(actual, desired) {
		t.Fatal("non-security project defaults should be accepted")
	}
	actual["restricted.devices.proxy"] = "allow"
	if projectConfigMatches(actual, desired) {
		t.Fatal("undeclared project permissions must be rejected")
	}
	delete(actual, "restricted.devices.proxy")
	actual["restricted.devices.gpu"] = "allow"
	if projectConfigMatches(actual, desired) {
		t.Fatal("changed project restrictions must be rejected")
	}
}

func TestIDMapOverlapIncludesIdentityRows(t *testing.T) {
	desired := []idRange{
		{hostid: 505, rangeN: 1},
		{hostid: 1000000, rangeN: 65536},
	}
	if !overlapsAnyHostRange(idRange{hostid: 505, rangeN: 1}, desired) {
		t.Fatal("identity-mapped capability collision was missed")
	}
	if overlapsAnyHostRange(idRange{hostid: 600, rangeN: 1}, desired) {
		t.Fatal("unrelated host ID was reported as overlapping")
	}
	if !allocationCovers(subordinateAllocation{owner: "root", base: 500, count: 10}, desired[0]) {
		t.Fatal("covering subordinate allocation was rejected")
	}
}

func TestCollisionIDMap(t *testing.T) {
	current := `[{"Isuid":true,"Isgid":true,"Nsid":0,"Hostid":1000000,"Maprange":65536}]`
	for _, tc := range []struct {
		name       string
		instance   api.Instance
		comparable bool
		fails      bool
	}{
		{"current map", api.Instance{InstancePut: api.InstancePut{Config: map[string]string{"volatile.idmap.current": current}}}, true, false},
		{"next map", api.Instance{InstancePut: api.InstancePut{Config: map[string]string{"volatile.idmap.next": current}}}, true, false},
		{"privileged", api.Instance{ExpandedConfig: map[string]string{"security.privileged": "true"}, Status: "Running"}, false, false},
		{"never started", api.Instance{Status: "Stopped"}, false, false},
		{"active without map", api.Instance{Status: "Running"}, false, true},
		{"VM filesystem map", api.Instance{Type: string(api.InstanceTypeVM), ExpandedConfig: map[string]string{"raw.idmap": "both 1000000-1065535 0-65535"}}, true, false},
		{"VM without filesystem map", api.Instance{Type: string(api.InstanceTypeVM), Status: "Running"}, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, comparable, err := collisionIDMap(tc.instance)
			if comparable != tc.comparable || (err != nil) != tc.fails {
				t.Fatalf("comparable=%v err=%v", comparable, err)
			}
		})
	}
}

func TestLifecycleLockIsPrivate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "compute.lock")
	if err := os.WriteFile(path, nil, 0o666); err != nil {
		t.Fatal(err)
	}
	lock, err := openLifecycleLock(path, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	info, err := lock.Stat()
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("lock mode=%#o", info.Mode().Perm())
	}
}

func TestNodesReady(t *testing.T) {
	for _, tc := range []struct {
		name  string
		input string
		ready bool
	}{
		{"empty cluster", `{"items":[]}`, false},
		{"ready node", `{"items":[{"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}`, true},
		{"one unready node", `{"items":[{"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"status":{"conditions":[{"type":"Ready","status":"False"}]}}]}`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ready, err := nodesReady([]byte(tc.input))
			if err != nil || ready != tc.ready {
				t.Fatalf("ready=%v err=%v; want ready=%v", ready, err, tc.ready)
			}
		})
	}
}

func TestBackendBoundary(t *testing.T) {
	for _, backend := range []api.InstanceType{api.InstanceTypeContainer, api.InstanceTypeVM} {
		t.Run(string(backend), func(t *testing.T) {
			spec := descriptor{Backend: backend, Profile: "compute", Config: api.ConfigMap{}, Devices: api.DevicesMap{}}
			instance := &api.Instance{Type: string(backend), InstancePut: api.InstancePut{Profiles: []string{"compute"}}, ExpandedDevices: api.DevicesMap{}}
			if err := checkInstance(spec, instance); err != nil {
				t.Fatal(err)
			}
			if backend == api.InstanceTypeContainer {
				instance.Type = string(api.InstanceTypeVM)
			} else {
				instance.Type = string(api.InstanceTypeContainer)
			}
			if err := checkInstance(spec, instance); err == nil {
				t.Fatal("cross-backend instance must refuse mutation")
			}
			bundle := t.TempDir()
			if err := os.WriteFile(filepath.Join(bundle, "backend"), []byte(backend), 0o400); err != nil {
				t.Fatal(err)
			}
			if err := checkBundleBackend(bundle, backend); err != nil {
				t.Fatal(err)
			}
			if err := checkBundleBackend(bundle, api.InstanceType(instance.Type)); err == nil {
				t.Fatal("cross-backend bundle must refuse mutation before deletion")
			}
		})
	}
	if _, err := imageRootfs(""); err == nil {
		t.Fatal("missing backend must not silently choose a guest type")
	}
}

func TestVMFilesystemIDMap(t *testing.T) {
	uid, gid, err := parseRawIDMap("uid 1000000-1065535 0-65535\ngid 1000000-1000504 0-504\ngid 505 505\ngid 1000506-1065535 506-65535")
	if err != nil || !reflect.DeepEqual(uid, []idRange{{nsid: 0, hostid: 1000000, rangeN: 65536}}) || !reflect.DeepEqual(gid, []idRange{
		{nsid: 0, hostid: 1000000, rangeN: 505},
		{nsid: 505, hostid: 505, rangeN: 1},
		{nsid: 506, hostid: 1000506, rangeN: 65030},
	}) {
		t.Fatalf("VM map lost the media capability hole: uid=%v gid=%v err=%v", uid, gid, err)
	}
	for _, raw := range []string{"", "both 100-101 0", "both 4294967296 0", "both 10-9 0-1", "other 1 1"} {
		if _, _, err := parseRawIDMap(raw); err == nil {
			t.Fatalf("invalid VM map accepted: %q", raw)
		}
	}
}

func TestCombinedVMFilesystemIDMap(t *testing.T) {
	uid, gid, err := parseRawIDMap("both 1000000-1065535 0-65535")
	if err != nil || len(uid) != 1 || !reflect.DeepEqual(uid, gid) || uid[0] != (idRange{nsid: 0, hostid: 1000000, rangeN: 65536}) {
		t.Fatalf("combined VM filesystem map: uid=%v gid=%v err=%v", uid, gid, err)
	}
}

func TestSingleKindVMFilesystemCollision(t *testing.T) {
	for _, tc := range []struct {
		raw     string
		overlap bool
	}{
		{"uid 2000000 1000", false},
		{"uid 2000000-2000000 1000-1000", false},
		{"uid 1000000 1000", true},
		{"gid 2000000 1000", false},
		{"gid 505 1000", true},
	} {
		uid, gid, err := parseRawIDMap(tc.raw)
		if err != nil || len(uid)+len(gid) != 1 {
			t.Fatalf("valid single-kind map %q rejected: %v", tc.raw, err)
		}
		desired := []idRange{{hostid: 1000000, rangeN: 65536}}
		ranges := uid
		if len(gid) != 0 {
			ranges = gid
			desired = append(desired, idRange{hostid: 505, rangeN: 1})
		}
		if overlapsAnyHostRange(ranges[0], desired) != tc.overlap {
			t.Fatalf("wrong collision decision for %q", tc.raw)
		}
	}
}
