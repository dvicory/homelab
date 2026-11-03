//go:build !linux

package retained

import (
	"errors"
	"os"
	"strings"
	"testing"
)

func TestUnsupportedPlatformNeverCreatesState(t *testing.T) {
	root := t.TempDir() + "/absent"
	spec, err := ParseSpec(strings.NewReader(specJSON))
	if err != nil {
		t.Fatal(err)
	}
	spec.Root.Path = root
	for _, operation := range []func() error{
		func() error { return ValidateRoot(spec) },
		func() error { return Validate(spec, "") },
		func() error { return Provision(spec, "", spec.Root.ID) },
		func() error { return Adopt(spec, "", spec.Root.ID) },
	} {
		if err := operation(); !errors.Is(err, errPlatform) {
			t.Fatalf("unsupported platform returned %v", err)
		}
	}
	if _, err := os.Lstat(root); !os.IsNotExist(err) {
		t.Fatalf("unsupported platform created state: %v", err)
	}
}
