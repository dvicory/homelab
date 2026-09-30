package retained

import (
	"os"
	"path/filepath"
	"reflect"
	"syscall"
	"testing"
)

const marker = ".homelab-state-root"

func stateRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	// New directories inherit the parent's group on BSD-derived systems.
	if err := os.Lchown(root, os.Getuid(), os.Getgid()); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, marker), []byte("compute-1\n"), 0o444); err != nil {
		t.Fatal(err)
	}
	return root
}

func self(mode string) Entry {
	return Entry{UID: os.Getuid(), GID: os.Getgid(), Mode: mode}
}

func modeOf(t *testing.T, path string) os.FileMode {
	t.Helper()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	return info.Mode()
}

func TestCreatesMissingDirectoriesWithTheDeclaredMode(t *testing.T) {
	root := stateRoot(t)
	old := syscall.Umask(0o077)
	defer syscall.Umask(old)

	created, problems := Ensure(root, marker, map[string]Entry{"jellyfin-config": self("0750")})
	if len(problems) != 0 {
		t.Fatal(problems)
	}
	if !reflect.DeepEqual(created, []string{"jellyfin-config"}) {
		t.Fatalf("created %v", created)
	}
	if got := modeOf(t, filepath.Join(root, "jellyfin-config")).Perm(); got != 0o750 {
		t.Fatalf("jellyfin-config mode %o, want 750 despite the umask", got)
	}
}

func TestRejectsSpecialModeBits(t *testing.T) {
	root := stateRoot(t)
	_, problems := Ensure(root, marker, map[string]Entry{"shared": self("2770")})
	if len(problems) != 1 {
		t.Fatalf("problems %v, want the setgid mode rejected", problems)
	}
	if _, err := os.Lstat(filepath.Join(root, "shared")); !os.IsNotExist(err) {
		t.Fatal("created a directory with an unsupported mode")
	}
}

func TestLeavesAMatchingDirectoryAlone(t *testing.T) {
	root := stateRoot(t)
	path := filepath.Join(root, "kanidm")
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, "db"), []byte("data"), 0o600); err != nil {
		t.Fatal(err)
	}
	created, problems := Ensure(root, marker, map[string]Entry{"kanidm": self("0700")})
	if len(problems) != 0 || len(created) != 0 {
		t.Fatalf("created %v problems %v", created, problems)
	}
	if data, err := os.ReadFile(filepath.Join(path, "db")); err != nil || string(data) != "data" {
		t.Fatalf("existing content changed: %q %v", data, err)
	}
}

func TestReportsButDoesNotRepairAMismatch(t *testing.T) {
	root := stateRoot(t)
	path := filepath.Join(root, "radarr")
	if err := os.Mkdir(path, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o755); err != nil {
		t.Fatal(err)
	}
	_, problems := Ensure(root, marker, map[string]Entry{"radarr": self("0700")})
	if len(problems) != 1 {
		t.Fatalf("problems %v, want one mismatch", problems)
	}
	if got := modeOf(t, path).Perm(); got != 0o755 {
		t.Fatalf("mode was changed to %o", got)
	}
}

func TestRefusesSymlinksAndFiles(t *testing.T) {
	root := stateRoot(t)
	target := t.TempDir()
	if err := os.Chmod(target, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(root, "linked")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "file"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	created, problems := Ensure(root, marker, map[string]Entry{
		"linked": self("0700"),
		"file":   self("0700"),
		"fresh":  self("0700"),
	})
	if len(problems) != 2 {
		t.Fatalf("problems %v, want the symlink and the file", problems)
	}
	if !reflect.DeepEqual(created, []string{"fresh"}) {
		t.Fatalf("created %v; one bad entry must not stop the others", created)
	}
	if got := modeOf(t, target).Perm(); got != 0o755 {
		t.Fatalf("symlink target mode changed to %o", got)
	}
}

func TestCreatesNothingWithoutTheMarker(t *testing.T) {
	for name, setup := range map[string]func(root string) error{
		"missing": func(string) error { return nil },
		"symlink": func(root string) error {
			elsewhere := filepath.Join(t.TempDir(), marker)
			if err := os.WriteFile(elsewhere, nil, 0o444); err != nil {
				return err
			}
			return os.Symlink(elsewhere, filepath.Join(root, marker))
		},
	} {
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			if err := setup(root); err != nil {
				t.Fatal(err)
			}
			created, problems := Ensure(root, marker, map[string]Entry{"kanidm": self("0700")})
			if len(problems) != 1 || len(created) != 0 {
				t.Fatalf("created %v problems %v", created, problems)
			}
			if _, err := os.Lstat(filepath.Join(root, "kanidm")); !os.IsNotExist(err) {
				t.Fatalf("kanidm exists without the marker: %v", err)
			}
		})
	}
}

func TestRejectsNamesOutsideTheRoot(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "state")
	if err := os.Mkdir(root, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, marker), nil, 0o444); err != nil {
		t.Fatal(err)
	}
	_, problems := Ensure(root, marker, map[string]Entry{
		"../escape": self("0700"),
		"a/b":       self("0700"),
		marker:      self("0700"),
	})
	if len(problems) != 3 {
		t.Fatalf("problems %v, want all three names rejected", problems)
	}
	if _, err := os.Lstat(filepath.Join(parent, "escape")); !os.IsNotExist(err) {
		t.Fatal("created a directory outside the state root")
	}
}
