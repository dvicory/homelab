//go:build linux

package main

import (
	"testing"
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
