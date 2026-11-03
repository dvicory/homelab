package retained

import (
	"strings"
	"testing"
)

const specJSON = `{"version":1,"root":{"id":"root-stable","path":"/retained","marker":".homelab-state-root","source":{"fsType":"btrfs","name":"/dev/mapper/state","root":"/retained"},"uid":0,"gid":0,"mode":"0755"},"entries":{"app":{"id":"app-stable","uid":1000,"gid":1000,"mode":"0700"}}}`

func TestParseSpecRequiresBoundedUnambiguousCompleteRoot(t *testing.T) {
	valid, err := ParseSpec(strings.NewReader(specJSON))
	if err != nil || valid.Entries["app"].ID != "app-stable" {
		t.Fatalf("valid spec: %+v %v", valid, err)
	}
	for name, input := range map[string]string{
		"size":             specJSON + strings.Repeat(" ", MaxSpecBytes),
		"duplicate":        strings.Replace(specJSON, `"version":1`, `"version":1,"version":1`, 1),
		"nested duplicate": strings.Replace(specJSON, `"fsType":"btrfs"`, `"fsType":"btrfs","fsType":"zfs"`, 1),
		"unknown":          strings.Replace(specJSON, `"version":1`, `"version":1,"optionalSource":true`, 1),
		"nested unknown":   strings.Replace(specJSON, `"fsType":"btrfs"`, `"fsType":"btrfs","optional":true`, 1),
		"null":             strings.Replace(specJSON, `"uid":0`, `"uid":null`, 1),
		"missing owner":    strings.Replace(specJSON, `"uid":0,`, "", 1),
		"missing entries":  strings.Replace(specJSON, `,"entries":{"app":{"id":"app-stable","uid":1000,"gid":1000,"mode":"0700"}}`, "", 1),
		"trailing":         specJSON + `{}`,
		"version":          strings.Replace(specJSON, `"version":1`, `"version":2`, 1),
		"relative root":    strings.Replace(specJSON, `"path":"/retained"`, `"path":"retained"`, 1),
		"unclean root":     strings.Replace(specJSON, `"path":"/retained"`, `"path":"/retained/../retained"`, 1),
		"marker path":      strings.Replace(specJSON, `"marker":".homelab-state-root"`, `"marker":"../marker"`, 1),
		"optional source":  strings.Replace(specJSON, `"fsType":"btrfs"`, `"fsType":""`, 1),
		"relative subtree": strings.Replace(specJSON, `"root":"/retained"`, `"root":"retained"`, 1),
		"writable root":    strings.Replace(specJSON, `"mode":"0755"`, `"mode":"0775"`, 1),
		"array":            `[]`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := ParseSpec(strings.NewReader(input)); err == nil {
				t.Fatal("accepted an invalid or ambiguous spec")
			}
		})
	}
}

func TestEntryDeclarationChecksOnlySelectedScope(t *testing.T) {
	spec, err := ParseSpec(strings.NewReader(specJSON))
	if err != nil {
		t.Fatal(err)
	}
	spec.Entries["broken"] = Entry{ID: "broken", UID: -1, GID: -1, Mode: "2770"}
	if _, err := spec.entry("app"); err != nil {
		t.Fatalf("unrelated declaration gated app: %v", err)
	}
	for _, name := range []string{"", ".", "..", "../escape", "a/b", spec.Root.Marker} {
		spec.Entries[name] = spec.Entries["app"]
		if _, err := spec.entry(name); err == nil {
			t.Fatalf("accepted declared unsafe name %q", name)
		}
	}
	for _, name := range []string{"missing", "broken"} {
		if _, err := spec.entry(name); err == nil {
			t.Fatalf("accepted %q", name)
		}
	}
	for _, mode := range []string{"2770", "0888", "+700", "-700", "700 ", "0o700", "7"} {
		entry := spec.Entries["app"]
		entry.Mode = mode
		spec.Entries["app"] = entry
		if _, err := spec.entry("app"); err == nil {
			t.Fatalf("accepted mode %q", mode)
		}
	}
}

func TestMalformedSiblingJSONDoesNotGateSelectedEntry(t *testing.T) {
	for _, declaration := range []string{
		`null`,
		`[]`,
		`{"id":"broken","uid":"not-an-owner","gid":0,"mode":"0700"}`,
		`{"id":"broken","uid":0,"gid":0,"mode":"0700","unknown":true}`,
	} {
		input := strings.Replace(specJSON, `"entries":{`, `"entries":{"broken":`+declaration+`,`, 1)
		spec, err := ParseSpec(strings.NewReader(input))
		if err != nil {
			t.Fatalf("malformed sibling gated parsing: %v", err)
		}
		if _, err := spec.entry("app"); err != nil {
			t.Fatalf("malformed sibling gated selected entry: %v", err)
		}
		if _, err := spec.entry("broken"); err == nil {
			t.Fatalf("accepted selected malformed declaration: %s", declaration)
		}
	}
}
