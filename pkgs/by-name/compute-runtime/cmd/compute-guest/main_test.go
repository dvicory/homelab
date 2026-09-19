//go:build linux

package main

import (
	"os"
	"path/filepath"
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
