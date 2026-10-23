//go:build linux

package retained

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"golang.org/x/sys/unix"
)

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func testSpec(t *testing.T, establishRoot bool) Spec {
	t.Helper()
	parent, err := filepath.EvalSymlinks(t.TempDir())
	must(t, err)
	fd, err := openDirectory(parent)
	must(t, err)
	source, _, err := sourceOf(fd)
	unix.Close(fd)
	must(t, err)
	spec := Spec{
		Version: Version,
		Root:    Root{ID: "root-stable", Path: filepath.Join(parent, "state"), Marker: ".homelab-state-root", Source: entrySource(source, "state"), UID: os.Getuid(), GID: os.Getgid(), Mode: "0755"},
		Entries: map[string]Entry{
			"app":     {ID: "app-stable", UID: os.Getuid(), GID: os.Getgid(), Mode: "0700"},
			"sibling": {ID: "sibling-stable", UID: os.Getuid(), GID: os.Getgid(), Mode: "0750"},
		},
	}
	if establishRoot {
		must(t, Provision(spec, "", spec.Root.ID))
	}
	return spec
}

func tree(t *testing.T, root string) map[string]string {
	t.Helper()
	result := make(map[string]string)
	must(t, filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		var stat unix.Stat_t
		if err := unix.Lstat(path, &stat); err != nil {
			return err
		}
		value := fmt.Sprintf("%d:%d:%o:%d:%d:%d", stat.Uid, stat.Gid, stat.Mode, stat.Ino, stat.Mtim.Sec, stat.Mtim.Nsec)
		if entry.Type().IsRegular() {
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			value += ":" + string(data)
		} else if entry.Type()&os.ModeSymlink != 0 {
			target, err := os.Readlink(path)
			if err != nil {
				return err
			}
			value += ":" + target
		}
		result[path] = value
		return nil
	}))
	return result
}

func unchanged(t *testing.T, spec Spec, operation func() error, wantError bool) {
	t.Helper()
	before := tree(t, filepath.Dir(spec.Root.Path))
	err := operation()
	if (err != nil) != wantError {
		t.Fatalf("operation error %v, wantError %v", err, wantError)
	}
	if after := tree(t, filepath.Dir(spec.Root.Path)); !reflect.DeepEqual(before, after) {
		t.Fatalf("operation mutated state\nbefore: %v\nafter: %v", before, after)
	}
}

func ledgerOf(t *testing.T, spec Spec) RootLedger {
	t.Helper()
	fd, err := openDirectory(spec.Root.Path)
	must(t, err)
	defer unix.Close(fd)
	var ledger RootLedger
	must(t, readLedger(fd, spec.Root, &ledger))
	return ledger
}

func saveLedger(t *testing.T, spec Spec, ledger RootLedger) {
	t.Helper()
	fd, err := openDirectory(spec.Root.Path)
	must(t, err)
	defer unix.Close(fd)
	must(t, writeLedger(fd, spec.Root, &ledger, true))
}

func TestValidationNeverCreatesOrRepairsState(t *testing.T) {
	spec := testSpec(t, false)
	unchanged(t, spec, func() error { return Validate(spec, "app") }, true)
	must(t, Provision(spec, "", spec.Root.ID))
	unchanged(t, spec, func() error { return Validate(spec, "app") }, true)
	must(t, os.Mkdir(filepath.Join(spec.Root.Path, "app"), 0o700))
	unchanged(t, spec, func() error { return Validate(spec, "app") }, true)
	contents, err := os.ReadDir(filepath.Join(spec.Root.Path, "app"))
	must(t, err)
	if len(contents) != 0 {
		t.Fatal("validation wrote application state")
	}
}

func TestProvisionRequiresExactConfirmationAndCreatesOneScope(t *testing.T) {
	spec := testSpec(t, false)
	unchanged(t, spec, func() error { return Provision(spec, "", "wrong") }, true)
	must(t, Provision(spec, "", spec.Root.ID))
	must(t, ValidateRoot(spec))
	if _, err := os.Lstat(filepath.Join(spec.Root.Path, "app")); !os.IsNotExist(err) {
		t.Fatal("root provisioning also created an app")
	}
	unchanged(t, spec, func() error { return Provision(spec, "app", spec.Root.ID) }, true)
	old := unix.Umask(0o077)
	defer unix.Umask(old)
	must(t, Provision(spec, "app", spec.Entries["app"].ID))
	must(t, Validate(spec, "app"))
	if _, err := os.Lstat(filepath.Join(spec.Root.Path, "sibling")); !os.IsNotExist(err) {
		t.Fatal("app provisioning also created its sibling")
	}
	var stat unix.Stat_t
	must(t, unix.Lstat(filepath.Join(spec.Root.Path, spec.Root.Marker), &stat))
	if stat.Mode&0o7777 != 0o444 || int(stat.Uid) != spec.Root.UID || int(stat.Gid) != spec.Root.GID || stat.Nlink != 1 {
		t.Fatalf("untrusted root ledger metadata: %+v", stat)
	}
	contents, err := os.ReadDir(filepath.Join(spec.Root.Path, "app"))
	must(t, err)
	if len(contents) != 0 {
		t.Fatal("provisioned leaf is not genuinely empty for application initialization")
	}
	unchanged(t, spec, func() error { return Provision(spec, "", spec.Root.ID) }, true)
	unchanged(t, spec, func() error { return Provision(spec, "app", spec.Entries["app"].ID) }, true)
}

func TestSelectedValidationDoesNotGateOnSiblings(t *testing.T) {
	spec := testSpec(t, true)
	must(t, Provision(spec, "app", spec.Entries["app"].ID))
	ledger := ledgerOf(t, spec)
	ledger.Entries["sibling"] = EstablishedEntry{ID: spec.Entries["sibling"].ID, State: "pending"}
	saveLedger(t, spec, ledger)
	spec.Entries["sibling"] = Entry{ID: "bad-sibling", UID: -1, GID: -1, Mode: "2777"}
	unchanged(t, spec, func() error { return Validate(spec, "app") }, false)
	unchanged(t, spec, func() error { return Validate(spec, "") }, true)
	unchanged(t, spec, func() error { return ValidateRoot(spec) }, false)
}

func TestAdoptRequiresMatchingExistingMetadataAndPreservesContent(t *testing.T) {
	spec := testSpec(t, false)
	must(t, os.Mkdir(spec.Root.Path, 0o700))
	unchanged(t, spec, func() error { return Provision(spec, "", spec.Root.ID) }, true)
	unchanged(t, spec, func() error { return Adopt(spec, "", spec.Root.ID) }, true)
	must(t, os.Chmod(spec.Root.Path, 0o755))
	must(t, os.Chown(spec.Root.Path, spec.Root.UID, spec.Root.GID))
	unchanged(t, spec, func() error { return ValidateRoot(spec) }, true)
	must(t, Adopt(spec, "", spec.Root.ID))
	path := filepath.Join(spec.Root.Path, "app")
	must(t, os.Mkdir(path, 0o755))
	must(t, os.Chmod(path, 0o755))
	must(t, os.Chown(path, spec.Entries["app"].UID, spec.Entries["app"].GID))
	must(t, os.WriteFile(filepath.Join(path, "database"), []byte("retained data"), 0o600))
	unchanged(t, spec, func() error { return Adopt(spec, "app", spec.Entries["app"].ID) }, true)
	must(t, os.Chmod(path, 0o700))
	unchanged(t, spec, func() error { return Provision(spec, "app", spec.Entries["app"].ID) }, true)
	before := tree(t, path)
	must(t, Adopt(spec, "app", spec.Entries["app"].ID))
	if after := tree(t, path); !reflect.DeepEqual(before, after) {
		t.Fatal("adoption changed existing application content or metadata")
	}
	unchanged(t, spec, func() error { return Adopt(spec, "app", spec.Entries["app"].ID) }, false)
	must(t, Validate(spec, "app"))
}

func TestEstablishedLedgerSurvivesRemovedDeclarationsAndRefusesLostLeafReplay(t *testing.T) {
	spec := testSpec(t, true)
	entry := spec.Entries["app"]
	must(t, Provision(spec, "app", entry.ID))
	must(t, os.RemoveAll(filepath.Join(spec.Root.Path, "app")))
	delete(spec.Entries, "app")
	delete(spec.Entries, "sibling")
	must(t, Validate(spec, ""))
	if ledgerOf(t, spec).Entries["app"].ID != entry.ID {
		t.Fatal("removed declaration discarded the established identity")
	}
	spec.Entries["app"] = entry
	unchanged(t, spec, func() error { return Validate(spec, "app") }, true)
	unchanged(t, spec, func() error { return Provision(spec, "app", entry.ID) }, true)
	unchanged(t, spec, func() error { return Adopt(spec, "app", entry.ID) }, true)
	entry.ID = "replacement-identity"
	spec.Entries["app"] = entry
	unchanged(t, spec, func() error { return Provision(spec, "app", entry.ID) }, true)
}

func TestPendingProvisionFailsClosedAndExplicitAdoptRecovers(t *testing.T) {
	for _, directoryExists := range []bool{false, true} {
		t.Run(fmt.Sprint(directoryExists), func(t *testing.T) {
			spec := testSpec(t, true)
			entry := spec.Entries["app"]
			path := filepath.Join(spec.Root.Path, "app")
			if directoryExists {
				must(t, os.Mkdir(path, 0o700))
				must(t, os.Chown(path, entry.UID, entry.GID))
			}
			ledger := ledgerOf(t, spec)
			ledger.Entries["app"] = EstablishedEntry{ID: entry.ID, State: "pending"}
			saveLedger(t, spec, ledger)
			unchanged(t, spec, func() error { return Provision(spec, "app", entry.ID) }, true)
			unchanged(t, spec, func() error { return Validate(spec, "app") }, true)
			if !directoryExists {
				unchanged(t, spec, func() error { return Adopt(spec, "app", entry.ID) }, true)
				must(t, os.Mkdir(path, 0o700))
				must(t, os.Chown(path, entry.UID, entry.GID))
			}
			must(t, os.WriteFile(filepath.Join(path, "database"), []byte("recovered data"), 0o600))
			before := tree(t, path)
			must(t, Adopt(spec, "app", entry.ID))
			must(t, Validate(spec, "app"))
			if after := tree(t, path); !reflect.DeepEqual(before, after) {
				t.Fatal("explicit recovery wrote application files or changed their metadata")
			}
		})
	}
}

func TestAdoptCannotOverwriteConflictingLedgerIdentities(t *testing.T) {
	spec := testSpec(t, true)
	entry := spec.Entries["app"]
	must(t, Provision(spec, "app", entry.ID))
	entry.ID = "new-identity"
	spec.Entries["app"] = entry
	unchanged(t, spec, func() error { return Adopt(spec, "app", entry.ID) }, true)
	root := spec.Root
	spec.Root.ID = "new-root-identity"
	unchanged(t, spec, func() error { return Adopt(spec, "", spec.Root.ID) }, true)
	spec.Root = root
	duplicate := spec.Entries["sibling"]
	duplicate.ID = "app-stable"
	spec.Entries["sibling"] = duplicate
	unchanged(t, spec, func() error { return Provision(spec, "sibling", duplicate.ID) }, true)
}

func TestValidationRefusesSymlinksFilesAndMetadataWithoutMutation(t *testing.T) {
	for _, problem := range []string{"root symlink", "ancestor symlink", "entry symlink", "entry file", "ledger symlink", "root mode", "root owner", "entry mode", "entry owner", "ledger mode", "ledger hardlink", "missing ledger", "oversized ledger"} {
		t.Run(problem, func(t *testing.T) {
			spec := testSpec(t, true)
			must(t, Provision(spec, "app", spec.Entries["app"].ID))
			app := filepath.Join(spec.Root.Path, "app")
			marker := filepath.Join(spec.Root.Path, spec.Root.Marker)
			switch problem {
			case "root symlink":
				must(t, os.Rename(spec.Root.Path, spec.Root.Path+"-saved"))
				must(t, os.Symlink(spec.Root.Path+"-saved", spec.Root.Path))
			case "ancestor symlink":
				alias := filepath.Join(filepath.Dir(spec.Root.Path), "alias")
				must(t, os.Symlink(spec.Root.Path, alias))
				spec.Root.Path = filepath.Join(alias, "app")
			case "entry symlink":
				must(t, os.Rename(app, app+"-saved"))
				must(t, os.Symlink(app+"-saved", app))
			case "entry file":
				must(t, os.RemoveAll(app))
				must(t, os.WriteFile(app, []byte("not a directory"), 0o700))
			case "ledger symlink":
				must(t, os.Rename(marker, marker+"-saved"))
				must(t, os.Symlink(marker+"-saved", marker))
			case "root mode":
				must(t, os.Chmod(spec.Root.Path, 0o700))
			case "root owner":
				spec.Root.UID++
			case "entry mode":
				must(t, os.Chmod(app, 0o755))
			case "entry owner":
				entry := spec.Entries["app"]
				entry.UID++
				spec.Entries["app"] = entry
			case "ledger mode":
				must(t, os.Chmod(marker, 0o644))
			case "ledger hardlink":
				must(t, os.Link(marker, marker+"-linked"))
			case "missing ledger":
				must(t, os.Remove(marker))
			case "oversized ledger":
				must(t, os.Chmod(marker, 0o600))
				must(t, os.WriteFile(marker, []byte(strings.Repeat("x", MaxSpecBytes+1)), 0o600))
				must(t, os.Chmod(marker, 0o444))
			}
			// The ancestor alias changes the parent spelling; snapshot the real
			// root's parent so the nofollow test itself never walks an alias.
			parent := filepath.Dir(app)
			before := tree(t, filepath.Dir(parent))
			if err := Validate(spec, "app"); err == nil {
				t.Fatal("accepted unsafe retained state")
			}
			if err := Provision(spec, "app", spec.Entries["app"].ID); err == nil {
				t.Fatal("provision accepted preexisting unsafe retained state")
			}
			if err := Adopt(spec, "app", spec.Entries["app"].ID); err == nil {
				t.Fatal("adopt accepted conflicting retained state")
			}
			if after := tree(t, filepath.Dir(parent)); !reflect.DeepEqual(before, after) {
				t.Fatal("validation modified unsafe state")
			}
		})
	}
}

func TestFilesystemTypeNameAndSubtreeMustMatchExactly(t *testing.T) {
	for _, coordinate := range []string{"filesystem", "name", "subtree"} {
		t.Run(coordinate, func(t *testing.T) {
			spec := testSpec(t, true)
			must(t, Provision(spec, "app", spec.Entries["app"].ID))
			switch coordinate {
			case "filesystem":
				spec.Root.Source.FSType += "-wrong"
			case "name":
				spec.Root.Source.Name += "-wrong"
			case "subtree":
				spec.Root.Source.Root += "-wrong"
			}
			unchanged(t, spec, func() error { return Validate(spec, "app") }, true)
			unchanged(t, spec, func() error { return Adopt(spec, "", spec.Root.ID) }, true)
			unchanged(t, spec, func() error { return Provision(spec, "sibling", spec.Entries["sibling"].ID) }, true)
		})
	}
	spec := testSpec(t, false)
	spec.Root.Source.Root += "-wrong"
	unchanged(t, spec, func() error { return Provision(spec, "", spec.Root.ID) }, true)
}

func TestMountIdentityUsesBindSubtreeAndRejectsReadonlyOrUnknownMount(t *testing.T) {
	input := "41 1 0:9 / /persist rw - btrfs /dev/state rw\n" +
		"42 1 0:9 /different/subtree /retained rw - btrfs /dev/state rw\n" +
		"43 1 0:9 /correct /readonly ro - btrfs /dev/state rw\n" +
		"44 1 0:9 /with\\040space /space rw - zfs tank/state rw\n" +
		"45 1 0:4 net:[4026532423] /run/netns/cni-fixture rw - nsfs nsfs rw\n" +
		"46 1 0:9 /old//deleted /unrelated rw - btrfs /dev/state rw\n" +
		"47 1 0:9 /with\\012newline /newline rw - btrfs /dev/state rw\n"
	mounts, err := parseMounts(strings.NewReader(input))
	must(t, err)
	actual, id, err := sourceAt(mounts, 42, "/retained/app")
	must(t, err)
	if id != 42 || actual != (Source{FSType: "btrfs", Name: "/dev/state", Root: "/different/subtree/app"}) {
		t.Fatalf("bind subtree collapsed to a pathname: %+v %d", actual, id)
	}
	if actual == (Source{FSType: "btrfs", Name: "/dev/state", Root: "/app"}) {
		t.Fatal("accepted a different bind source subtree")
	}
	for _, test := range []struct {
		id   uint64
		path string
	}{{43, "/readonly/app"}, {45, "/run/netns/cni-fixture"}, {46, "/unrelated"}, {47, "/newline"},
		{99, "/retained/app"}, {42, "/elsewhere/app"}} {
		if _, _, err := sourceAt(mounts, test.id, test.path); err == nil {
			t.Fatalf("accepted mount %d path %s", test.id, test.path)
		}
	}
	space, _, err := sourceAt(mounts, 44, "/space/app")
	must(t, err)
	if space.Root != "/with space/app" {
		t.Fatalf("mountinfo escape lost: %+v", space)
	}
	if _, err := parseMounts(strings.NewReader("42 malformed\n")); err == nil {
		t.Fatal("accepted malformed mountinfo")
	}
}

func TestMountIdentityRejectsAmbiguousSelectedRows(t *testing.T) {
	valid := "42 1 0:9 /app /retained rw - btrfs /dev/state rw\n"
	unusable := "42 1 0:9 /old//deleted /unrelated rw - btrfs /dev/state rw\n"
	for _, input := range []string{valid + unusable, unusable + valid, valid + valid} {
		mounts, err := parseMounts(strings.NewReader(input))
		must(t, err)
		if _, _, err := sourceAt(mounts, 42, "/retained"); err == nil {
			t.Fatal("accepted an ambiguous selected mount identity")
		}
	}
}

func TestLedgerUsesDeclaredTrustedMappedRootOwner(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("distinct mapped UID/GID ownership requires root")
	}
	spec := testSpec(t, false)
	spec.Root.UID, spec.Root.GID = 1000000, 1000000
	entry := spec.Entries["app"]
	entry.UID, entry.GID = 1001000, 1001000
	spec.Entries["app"] = entry
	must(t, Provision(spec, "", spec.Root.ID))
	must(t, Provision(spec, "app", entry.ID))
	must(t, Validate(spec, "app"))
	path := filepath.Join(spec.Root.Path, spec.Root.Marker)
	var stat unix.Stat_t
	must(t, unix.Lstat(path, &stat))
	if stat.Uid != uint32(spec.Root.UID) || stat.Gid != uint32(spec.Root.GID) || stat.Uid == uint32(entry.UID) {
		t.Fatalf("root ledger was given to the application: %+v", stat)
	}
	must(t, unix.Chown(path, entry.UID, entry.GID))
	unchanged(t, spec, func() error { return Validate(spec, "app") }, true)
}

func TestLedgerPublicationNeverClobbersAnExistingName(t *testing.T) {
	spec := testSpec(t, true)
	path := filepath.Join(spec.Root.Path, spec.Root.Marker)
	before, err := os.ReadFile(path)
	must(t, err)
	fd, err := openDirectory(spec.Root.Path)
	must(t, err)
	defer unix.Close(fd)
	foreign := ledgerOf(t, spec)
	foreign.ID = "conflicting-identity"
	if err := writeLedger(fd, spec.Root, &foreign, false); err == nil {
		t.Fatal("ledger publication replaced an existing name")
	}
	after, err := os.ReadFile(path)
	must(t, err)
	if string(before) != string(after) {
		t.Fatal("ledger collision overwrote existing content")
	}
	contents, err := os.ReadDir(spec.Root.Path)
	must(t, err)
	if len(contents) != 1 || contents[0].Name() != spec.Root.Marker {
		t.Fatal("failed publication left temporary state behind")
	}
	must(t, ValidateRoot(spec))
}

func TestRootAdoptionNeverOverwritesLegacyOrMalformedMarkers(t *testing.T) {
	spec := testSpec(t, false)
	must(t, os.Mkdir(spec.Root.Path, 0o755))
	must(t, os.Chmod(spec.Root.Path, 0o755))
	must(t, os.Chown(spec.Root.Path, spec.Root.UID, spec.Root.GID))
	path := filepath.Join(spec.Root.Path, spec.Root.Marker)
	must(t, os.WriteFile(path, []byte("old-creating-helper-marker\n"), 0o444))
	must(t, os.Chmod(path, 0o444))
	unchanged(t, spec, func() error { return ValidateRoot(spec) }, true)
	unchanged(t, spec, func() error { return Adopt(spec, "", spec.Root.ID) }, true)
}

func copyTestLedger(t *testing.T, source, destination string, root Root) {
	t.Helper()
	data, err := os.ReadFile(source)
	must(t, err)
	must(t, os.WriteFile(destination, data, 0o600))
	must(t, os.Chown(destination, root.UID, root.GID))
	must(t, os.Chmod(destination, 0o444))
}

func TestLedgerRejectsSameSourceSamePathReplacementLeaf(t *testing.T) {
	spec := testSpec(t, true)
	entry := spec.Entries["app"]
	must(t, Provision(spec, "app", entry.ID))
	before := ledgerOf(t, spec)
	path := filepath.Join(spec.Root.Path, "app")
	must(t, os.WriteFile(filepath.Join(path, "database"), []byte("original retained data"), 0o600))
	original, replacement := path+"-original", path+"-replacement"
	must(t, os.Mkdir(replacement, 0o700))
	must(t, os.Chown(replacement, entry.UID, entry.GID))
	must(t, os.Rename(path, original))
	must(t, os.Rename(replacement, path))
	unchanged(t, spec, func() error { return Validate(spec, "app") }, true)
	unchanged(t, spec, func() error { return Provision(spec, "app", entry.ID) }, true)
	unchanged(t, spec, func() error { return Adopt(spec, "app", "wrong-confirmation") }, true)

	// Returning the original physical object restores validity without rewriting
	// identities or the root ledger, despite an empty replacement having occupied it.
	must(t, os.Rename(path, replacement))
	must(t, os.Rename(original, path))
	unchanged(t, spec, func() error { return Validate(spec, "app") }, false)
	if after := ledgerOf(t, spec); !reflect.DeepEqual(before, after) {
		t.Fatal("returning the original leaf changed its ledger")
	}

	// A separately confirmed adoption can authorize an operator-restored object
	// with matching stable ledger IDs, metadata, and source coordinates.
	must(t, os.Rename(path, original))
	must(t, os.Rename(replacement, path))
	must(t, os.WriteFile(filepath.Join(path, "database"), []byte("operator-restored data"), 0o600))
	must(t, Adopt(spec, "app", entry.ID))
	must(t, Validate(spec, "app"))
	after := ledgerOf(t, spec)
	if after.ID != before.ID || after.Inode != before.Inode || after.Entries["app"].ID != before.Entries["app"].ID || after.Entries["app"].Inode == 0 || after.Entries["app"].Inode == before.Entries["app"].Inode {
		t.Fatal("explicit adoption did not rebind only the restored leaf inode")
	}
	data, err := os.ReadFile(filepath.Join(path, "database"))
	must(t, err)
	if string(data) != "operator-restored data" {
		t.Fatal("explicit adoption changed restored content")
	}
}

func TestCopiedLedgerCannotEstablishSameSourceSamePathReplacementRoot(t *testing.T) {
	spec := testSpec(t, true)
	must(t, Provision(spec, "app", spec.Entries["app"].ID))
	must(t, Provision(spec, "sibling", spec.Entries["sibling"].ID))
	before := ledgerOf(t, spec)
	path := spec.Root.Path
	must(t, os.WriteFile(filepath.Join(path, "app", "database"), []byte("original retained data"), 0o600))
	original, replacement := path+"-original", path+"-replacement"
	must(t, os.Mkdir(replacement, 0o755))
	must(t, os.Chmod(replacement, 0o755))
	must(t, os.Chown(replacement, spec.Root.UID, spec.Root.GID))
	copyTestLedger(t, filepath.Join(path, spec.Root.Marker), filepath.Join(replacement, spec.Root.Marker), spec.Root)
	app := filepath.Join(replacement, "app")
	must(t, os.Mkdir(app, 0o700))
	must(t, os.Chown(app, spec.Entries["app"].UID, spec.Entries["app"].GID))
	must(t, os.Rename(path, original))
	must(t, os.Rename(replacement, path))
	unchanged(t, spec, func() error { return ValidateRoot(spec) }, true)
	unchanged(t, spec, func() error { return Validate(spec, "app") }, true)
	unchanged(t, spec, func() error { return Provision(spec, "", spec.Root.ID) }, true)
	unchanged(t, spec, func() error { return Adopt(spec, "", "wrong-confirmation") }, true)

	must(t, os.Rename(path, replacement))
	must(t, os.Rename(original, path))
	unchanged(t, spec, func() error { return Validate(spec, "") }, false)
	if after := ledgerOf(t, spec); !reflect.DeepEqual(before, after) {
		t.Fatal("returning the original root changed its ledger")
	}

	must(t, os.Rename(path, original))
	must(t, os.Rename(replacement, path))
	must(t, Adopt(spec, "", spec.Root.ID))
	must(t, ValidateRoot(spec))
	after := ledgerOf(t, spec)
	if after.ID != before.ID || after.Inode == 0 || after.Inode == before.Inode || !reflect.DeepEqual(after.Entries, before.Entries) {
		t.Fatal("root adoption did not preserve all existing leaf identities and inodes")
	}
	unchanged(t, spec, func() error { return Validate(spec, "app") }, true)
	must(t, Adopt(spec, "app", spec.Entries["app"].ID))
	must(t, Validate(spec, "app"))
	unchanged(t, spec, func() error { return Validate(spec, "") }, true)
}
