//go:build linux

package retained

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

// Validate checks the root and either one selected entry or every declaration.
// It takes no lock and opens no file for writing.
func Validate(spec Spec, entry string) error {
	if err := spec.checkRoot(); err != nil {
		return err
	}
	fd, err := openDirectory(spec.Root.Path)
	if err != nil {
		return fmt.Errorf("root: %w", err)
	}
	defer unix.Close(fd)
	ledger, err := validateRoot(fd, spec.Root)
	if err != nil {
		return err
	}
	selected := []string{entry}
	if entry == "" {
		selected = names(spec.Entries)
	}
	for _, name := range selected {
		declaration, err := spec.entry(name)
		if err != nil {
			return err
		}
		if err := validateEntry(fd, spec.Root, ledger, name, declaration); err != nil {
			return fmt.Errorf("entry %s: %w", name, err)
		}
	}
	return nil
}

// ValidateRoot checks only the root, for exports without a guest app inventory.
func ValidateRoot(spec Spec) error {
	if err := spec.checkRoot(); err != nil {
		return err
	}
	fd, err := openDirectory(spec.Root.Path)
	if err != nil {
		return err
	}
	defer unix.Close(fd)
	_, err = validateRoot(fd, spec.Root)
	return err
}

// Provision creates exactly one absent directory. Empty entry selects the root.
// An existing or previously reserved entry is never repaired or recreated.
func Provision(spec Spec, entry, confirm string) error {
	return operate(spec, entry, confirm, false)
}

// Adopt records exactly one existing, matching directory. Empty entry selects
// the root. It is also the explicit recovery operation for a pending identity.
// With the same confirmed identity, adoption can explicitly rebind a restored
// physical inode after its source, metadata, and trusted ledger identity match.
func Adopt(spec Spec, entry, confirm string) error {
	return operate(spec, entry, confirm, true)
}

func operate(spec Spec, name, confirm string, adopt bool) error {
	if err := spec.checkRoot(); err != nil {
		return err
	}
	id := spec.Root.ID
	var entry Entry
	if name != "" {
		var err error
		entry, err = spec.entry(name)
		if err != nil {
			return err
		}
		id = entry.ID
	}
	if confirm != id {
		return errors.New("confirmation must exactly match the selected identity")
	}
	parent, err := openDirectory(filepath.Dir(spec.Root.Path))
	if err != nil {
		return fmt.Errorf("root parent: %w", err)
	}
	defer unix.Close(parent)
	// ponytail: the parent-directory flock serializes explicit operations for
	// this root; use a dedicated trusted lock only if sibling-root contention matters.
	if err := unix.Flock(parent, unix.LOCK_EX); err != nil {
		return fmt.Errorf("locking explicit operation: %w", err)
	}
	defer unix.Flock(parent, unix.LOCK_UN)
	base := filepath.Base(spec.Root.Path)
	if name == "" {
		return operateRoot(parent, base, spec.Root, adopt)
	}
	rootFD, err := openChild(parent, base)
	if err != nil {
		return fmt.Errorf("root: %w", err)
	}
	defer unix.Close(rootFD)
	if err := unix.Flock(rootFD, unix.LOCK_EX); err != nil {
		return err
	}
	defer unix.Flock(rootFD, unix.LOCK_UN)
	ledger, err := validateRoot(rootFD, spec.Root)
	if err != nil {
		return err
	}
	return operateEntry(rootFD, spec.Root, &ledger, name, entry, adopt)
}

func operateRoot(parent int, base string, root Root, adopt bool) error {
	fd, err := openChild(parent, base)
	if !adopt {
		if err == nil {
			unix.Close(fd)
			return errors.New("root already exists; provision never adopts or repairs existing state")
		}
		if !errors.Is(err, unix.ENOENT) {
			return err
		}
		source, _, err := sourceOf(parent)
		if err != nil {
			return err
		}
		if entrySource(source, base) != root.Source {
			return errors.New("absent root would be created on the wrong filesystem or subtree")
		}
		if err := unix.Mkdirat(parent, base, 0o700); err != nil {
			return err
		}
		if err := unix.Fsync(parent); err != nil {
			return fmt.Errorf("root directory created but parent sync failed; recover with explicit adopt: %w", err)
		}
		fd, err = openChild(parent, base)
		if err != nil {
			return err
		}
		defer unix.Close(fd)
		if err := unix.Flock(fd, unix.LOCK_EX); err != nil {
			return err
		}
		defer unix.Flock(fd, unix.LOCK_UN)
		if err := setNewMetadata(fd, root.UID, root.GID, root.Mode); err != nil {
			return fmt.Errorf("root partially provisioned; not accepted: %w", err)
		}
	} else {
		if err != nil {
			return fmt.Errorf("adopt requires an existing root: %w", err)
		}
		defer unix.Close(fd)
		if err := unix.Flock(fd, unix.LOCK_EX); err != nil {
			return err
		}
		defer unix.Flock(fd, unix.LOCK_UN)
	}
	inode, err := matchDirectory(fd, root.UID, root.GID, root.Mode)
	if err != nil {
		return fmt.Errorf("root metadata: %w", err)
	}
	if err := matchSource(fd, root.Source, 0); err != nil {
		return fmt.Errorf("root source: %w", err)
	}
	var existing RootLedger
	err = readLedger(fd, root, &existing)
	if err == nil {
		if !adopt {
			return errors.New("new root unexpectedly contains a ledger; refusing")
		}
		if err := checkLedger(existing, root); err != nil {
			return err
		}
		if existing.Inode == inode {
			return nil
		}
		existing.Inode = inode
		return writeLedger(fd, root, &existing, true)
	}
	if !errors.Is(err, unix.ENOENT) {
		return fmt.Errorf("existing root ledger cannot be adopted or overwritten: %w", err)
	}
	ledger := newLedger(root, inode)
	return writeLedger(fd, root, &ledger, false)
}

func operateEntry(rootFD int, root Root, ledger *RootLedger, name string, entry Entry, adopt bool) error {
	known, reserved := ledger.Entries[name]
	if reserved && known.ID != entry.ID {
		return errors.New("ledger has a conflicting entry identity; never overwriting")
	}
	for other, record := range ledger.Entries {
		if other != name && record.ID == entry.ID {
			return errors.New("entry identity is already reserved for another name")
		}
	}
	if !adopt && reserved {
		return errors.New("entry identity is already reserved or established; refusing replay after possible state loss")
	}
	var inode uint64
	fd, err := openChild(rootFD, name)
	if !adopt {
		if err == nil {
			unix.Close(fd)
			return errors.New("entry already exists; provision never adopts or repairs existing state")
		}
		if !errors.Is(err, unix.ENOENT) {
			return err
		}
	} else {
		if err != nil {
			return fmt.Errorf("adopt requires an existing entry; restore lost data before adoption: %w", err)
		}
		defer unix.Close(fd)
		inode, err = checkEntryDirectory(rootFD, fd, root, name, entry)
		if err != nil {
			return err
		}
		if reserved && known.State == "established" && known.Inode == inode {
			return nil
		}
	}
	if len(ledger.Entries) >= maxEntries && !reserved {
		return errors.New("established ledger is full; identities are never discarded")
	}
	// Reserve durably before mkdir or adopting a physical inode. A crash, even before
	// mkdir, cannot authorize fresh empty state on the next provision attempt.
	ledger.Entries[name] = EstablishedEntry{ID: entry.ID, Inode: inode, State: "pending"}
	if err := writeLedger(rootFD, root, ledger, true); err != nil {
		return fmt.Errorf("reserving entry identity: %w", err)
	}
	if !adopt {
		if err := unix.Mkdirat(rootFD, name, 0o700); err != nil {
			return fmt.Errorf("identity is pending; explicit recovery required: %w", err)
		}
		if err := unix.Fsync(rootFD); err != nil {
			return fmt.Errorf("entry is pending; parent sync failed: %w", err)
		}
		fd, err = openChild(rootFD, name)
		if err != nil {
			return err
		}
		defer unix.Close(fd)
		if err := setNewMetadata(fd, entry.UID, entry.GID, entry.Mode); err != nil {
			return fmt.Errorf("entry is pending; metadata creation failed: %w", err)
		}
	}
	inode, err = checkEntryDirectory(rootFD, fd, root, name, entry)
	if err != nil {
		return err
	}
	if adopt {
		if err := unix.Fsync(fd); err != nil {
			return fmt.Errorf("entry is pending; directory sync failed: %w", err)
		}
	}
	ledger.Entries[name] = EstablishedEntry{ID: entry.ID, Inode: inode, State: "established"}
	if err := writeLedger(rootFD, root, ledger, true); err != nil {
		return fmt.Errorf("entry establishment sync failed; explicit adopt may be required: %w", err)
	}
	return validateEntry(rootFD, root, *ledger, name, entry)
}

func validateRoot(fd int, root Root) (RootLedger, error) {
	var ledger RootLedger
	inode, err := matchDirectory(fd, root.UID, root.GID, root.Mode)
	if err != nil {
		return ledger, fmt.Errorf("root metadata: %w", err)
	}
	if err := matchSource(fd, root.Source, 0); err != nil {
		return ledger, fmt.Errorf("root source: %w", err)
	}
	if err := readLedger(fd, root, &ledger); err != nil {
		return ledger, fmt.Errorf("root ledger: %w", err)
	}
	if err := checkLedger(ledger, root); err != nil {
		return ledger, err
	}
	if ledger.Inode != inode {
		return ledger, errors.New("root inode differs from its ledger; copied markers cannot establish replacement state")
	}
	return ledger, nil
}

func checkLedger(ledger RootLedger, root Root) error {
	if ledger.Version != Version || ledger.ID != root.ID || ledger.Inode == 0 || ledger.Source != root.Source || ledger.Entries == nil || len(ledger.Entries) > maxEntries {
		return errors.New("root ledger conflicts with the declared root identity or source")
	}
	ids := make(map[string]bool, len(ledger.Entries))
	for name, entry := range ledger.Entries {
		if !basename(name) || name == root.Marker || !identity(entry.ID) || entry.ID == root.ID || ids[entry.ID] || (entry.State != "pending" && entry.State != "established") || (entry.State == "established" && entry.Inode == 0) {
			return errors.New("root ledger contains an invalid or conflicting established identity")
		}
		ids[entry.ID] = true
	}
	return nil
}

func validateEntry(rootFD int, root Root, ledger RootLedger, name string, entry Entry) error {
	record, exists := ledger.Entries[name]
	if !exists || record.ID != entry.ID || record.State != "established" {
		return errors.New("entry identity is not established; explicit provision or adopt is required")
	}
	fd, err := openChild(rootFD, name)
	if err != nil {
		return fmt.Errorf("established directory is unavailable; never recreating it: %w", err)
	}
	defer unix.Close(fd)
	inode, err := checkEntryDirectory(rootFD, fd, root, name, entry)
	if err != nil {
		return err
	}
	if record.Inode != inode {
		return errors.New("entry inode differs from its established ledger; refusing replacement state")
	}
	return nil
}

func checkEntryDirectory(rootFD, fd int, root Root, name string, entry Entry) (uint64, error) {
	inode, err := matchDirectory(fd, entry.UID, entry.GID, entry.Mode)
	if err != nil {
		return 0, err
	}
	_, mountID, err := sourceOf(rootFD)
	if err != nil {
		return 0, err
	}
	return inode, matchSource(fd, entrySource(root.Source, name), mountID)
}

func openDirectory(path string) (int, error) {
	if !absolute(path) {
		return -1, errors.New("directory path must be canonical and absolute")
	}
	fd, err := unix.Open("/", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return -1, err
	}
	if path == "/" {
		return fd, nil
	}
	for _, component := range strings.Split(strings.TrimPrefix(path, "/"), "/") {
		next, err := openChild(fd, component)
		unix.Close(fd)
		if err != nil {
			return -1, err
		}
		fd = next
	}
	return fd, nil
}

func openChild(parent int, name string) (int, error) {
	return unix.Openat(parent, name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
}

func matchDirectory(fd, uid, gid int, value string) (uint64, error) {
	mode, err := metadata(uid, gid, value)
	if err != nil {
		return 0, err
	}
	var stat unix.Stat_t
	if err := unix.Fstat(fd, &stat); err != nil {
		return 0, err
	}
	if stat.Mode&unix.S_IFMT != unix.S_IFDIR || stat.Uid != uint32(uid) || stat.Gid != uint32(gid) || stat.Mode&0o7777 != mode || stat.Ino == 0 {
		return 0, fmt.Errorf("directory is %d:%d %04o, declared %d:%d %04o; not repairing", stat.Uid, stat.Gid, stat.Mode&0o7777, uid, gid, mode)
	}
	return stat.Ino, nil
}

func setNewMetadata(fd, uid, gid int, value string) error {
	mode, err := metadata(uid, gid, value)
	if err != nil {
		return err
	}
	if err := unix.Fchown(fd, uid, gid); err != nil {
		return err
	}
	if err := unix.Fchmod(fd, mode); err != nil {
		return err
	}
	return unix.Fsync(fd)
}

func readLedger(parent int, root Root, ledger *RootLedger) error {
	fd, err := unix.Openat(parent, root.Marker, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return err
	}
	file := os.NewFile(uintptr(fd), root.Marker)
	defer file.Close()
	var stat unix.Stat_t
	if err := unix.Fstat(fd, &stat); err != nil {
		return err
	}
	if stat.Mode&unix.S_IFMT != unix.S_IFREG || stat.Mode&0o7777 != 0o444 || stat.Uid != uint32(root.UID) || stat.Gid != uint32(root.GID) || stat.Nlink != 1 || stat.Size <= 0 || stat.Size > MaxSpecBytes {
		return errors.New("ledger must be a bounded single-link regular file owned by the trusted root owner with mode 0444")
	}
	return readJSON(file, MaxSpecBytes, ledger)
}

// A new ledger is renamed without replacing a name. Updates replace only a
// validated trusted ledger while the explicit-operation lock is held.
func writeLedger(parent int, root Root, ledger *RootLedger, replace bool) error {
	data, err := json.Marshal(ledger)
	if err != nil {
		return err
	}
	if len(data) > MaxSpecBytes {
		return errors.New("ledger exceeds size limit")
	}
	if replace {
		var existing RootLedger
		if err := readLedger(parent, root, &existing); err != nil {
			return err
		}
		if err := checkLedger(existing, root); err != nil {
			return err
		}
	}
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		return err
	}
	temporary := ".retained-write-" + hex.EncodeToString(random[:])
	fd, err := unix.Openat(parent, temporary, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0o600)
	if err != nil {
		return err
	}
	defer unix.Unlinkat(parent, temporary, 0)
	file := os.NewFile(uintptr(fd), temporary)
	defer file.Close()
	if _, err := file.Write(data); err != nil {
		return err
	}
	if err := unix.Fchown(fd, root.UID, root.GID); err != nil {
		return err
	}
	if err := unix.Fchmod(fd, 0o444); err != nil {
		return err
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if replace {
		if err := unix.Renameat(parent, temporary, parent, root.Marker); err != nil {
			return err
		}
	} else {
		if err := unix.Renameat2(parent, temporary, parent, root.Marker, unix.RENAME_NOREPLACE); err != nil {
			return fmt.Errorf("atomic no-clobber ledger publication requires renameat2 RENAME_NOREPLACE: %w", err)
		}
	}
	return unix.Fsync(parent)
}

type mountRecord struct {
	ID       uint64
	Root     string
	Point    string
	FSType   string
	Name     string
	ReadOnly bool
}

func parseMounts(reader io.Reader) ([]mountRecord, error) {
	limited := &io.LimitedReader{R: reader, N: 4<<20 + 1}
	scanner := bufio.NewScanner(limited)
	scanner.Buffer(make([]byte, 4096), 65536)
	var result []mountRecord
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		separator := -1
		for i, field := range fields {
			if field == "-" {
				separator = i
				break
			}
		}
		if separator < 6 || len(fields) < separator+4 {
			return nil, errors.New("malformed mountinfo record")
		}
		id, err := strconv.ParseUint(fields[0], 10, 64)
		if err != nil || id == 0 {
			return nil, errors.New("invalid mountinfo mount id")
		}
		root, err := mountUnescape(fields[3])
		if err != nil {
			return nil, err
		}
		point, err := mountUnescape(fields[4])
		if err != nil {
			return nil, err
		}
		name, err := mountUnescape(fields[separator+2])
		if err != nil {
			return nil, errors.New("invalid mountinfo coordinates")
		}
		options := "," + fields[5] + "," + fields[separator+3] + ","
		result = append(result, mountRecord{ID: id, Root: root, Point: point, FSType: fields[separator+1], Name: name, ReadOnly: strings.Contains(options, ",ro,")})
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if limited.N <= 0 {
		return nil, errors.New("mountinfo exceeds size limit")
	}
	return result, nil
}

func mountUnescape(value string) (string, error) {
	var result strings.Builder
	for i := 0; i < len(value); i++ {
		if value[i] != '\\' {
			result.WriteByte(value[i])
			continue
		}
		if i+3 >= len(value) {
			return "", errors.New("invalid mountinfo escape")
		}
		escape := value[i+1 : i+4]
		decoded := byte(0)
		switch escape {
		case "040":
			decoded = ' '
		case "011":
			decoded = '\t'
		case "012":
			decoded = '\n'
		case "134":
			decoded = '\\'
		default:
			return "", errors.New("invalid mountinfo escape")
		}
		result.WriteByte(decoded)
		i += 3
	}
	return result.String(), nil
}

func sourceOf(fd int) (Source, uint64, error) {
	var stat unix.Statx_t
	if err := unix.Statx(fd, "", unix.AT_EMPTY_PATH|unix.AT_SYMLINK_NOFOLLOW, unix.STATX_MNT_ID, &stat); err != nil || stat.Mask&unix.STATX_MNT_ID == 0 {
		return Source{}, 0, errors.New("Linux statx mount identity support is required")
	}
	var filesystem unix.Statfs_t
	if err := unix.Fstatfs(fd, &filesystem); err != nil {
		return Source{}, 0, err
	}
	if filesystem.Flags&unix.ST_RDONLY != 0 {
		return Source{}, 0, errors.New("retained filesystem is read-only")
	}
	file, err := os.Open("/proc/self/mountinfo")
	if err != nil {
		return Source{}, 0, err
	}
	defer file.Close()
	mounts, err := parseMounts(file)
	if err != nil {
		return Source{}, 0, err
	}
	path, err := os.Readlink("/proc/self/fd/" + strconv.Itoa(fd))
	if err != nil || !absolute(path) || strings.HasSuffix(path, " (deleted)") {
		return Source{}, 0, errors.New("cannot locate the pinned directory in its mounted filesystem")
	}
	return sourceAt(mounts, stat.Mnt_id, path)
}

func sourceAt(mounts []mountRecord, mountID uint64, path string) (Source, uint64, error) {
	var selected *mountRecord
	for i := range mounts {
		if mounts[i].ID == mountID {
			if selected != nil {
				return Source{}, 0, errors.New("pinned directory's mount identity is ambiguous")
			}
			selected = &mounts[i]
		}
	}
	if selected == nil {
		return Source{}, 0, errors.New("pinned directory's mount is absent from mountinfo")
	}
	// Other mounts can legitimately have unusable roots (for example
	// /old//deleted). Never normalize or discard the selected identity.
	if selected.FSType == "nsfs" || !absolute(selected.Root) || !absolute(selected.Point) {
		return Source{}, 0, errors.New("invalid retained mount coordinates")
	}
	if selected.ReadOnly {
		return Source{}, 0, errors.New("retained mount is read-only")
	}
	relative, err := filepath.Rel(selected.Point, path)
	if err != nil || relative == ".." || strings.HasPrefix(relative, "../") {
		return Source{}, 0, errors.New("pinned directory is outside its reported mount")
	}
	source := Source{FSType: selected.FSType, Name: selected.Name, Root: filepath.Join(selected.Root, relative)}
	if err := source.check(); err != nil {
		return Source{}, 0, err
	}
	return source, selected.ID, nil
}

func matchSource(fd int, expected Source, sameMount uint64) error {
	actual, mountID, err := sourceOf(fd)
	if err != nil {
		return err
	}
	if actual != expected || (sameMount != 0 && sameMount != mountID) {
		return fmt.Errorf("filesystem source mismatch: got %+v, declared %+v; refusing", actual, expected)
	}
	return nil
}
