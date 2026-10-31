//go:build !linux

package retained

import (
	"os"
	"testing"
)

func TestUnsupportedPlatformNeverCreatesState(t *testing.T) {
	root := t.TempDir() + "/absent"
	spec := Spec{Version: Version, Root: Root{ID: "root-stable", Path: root}, Entries: map[string]Entry{}}
	for _, operation := range []func() error{
		func() error { return ValidateRoot(spec) },
		func() error { return Validate(spec, "") },
		func() error { return Provision(spec, "", spec.Root.ID) },
		func() error { return Adopt(spec, "", spec.Root.ID) },
	} {
		if err := operation(); err == nil {
			t.Fatal("accepted state without trusted Linux mount identity")
		}
	}
	if _, err := os.Lstat(root); !os.IsNotExist(err) {
		t.Fatalf("unsupported platform created state: %v", err)
	}
}
