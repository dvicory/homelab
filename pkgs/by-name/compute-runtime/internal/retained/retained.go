// Package retained creates declared retained directories under the compute
// state root.
//
// Nothing is created unless the root carries its marker, which exists only on
// the persistent side of the state root. A missing directory is created with
// its declared owner and mode. An existing directory must already match; a
// mismatch is reported, never repaired, and nothing is changed recursively.
package retained

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
)

// Entry is one declared retained directory, relative to the state root.
type Entry struct {
	UID  int    `json:"uid"`
	GID  int    `json:"gid"`
	Mode string `json:"mode"`
}

// Ensure creates or checks every entry. It returns the names it created and
// every problem it found; the caller fails if any problem is returned.
func Ensure(root, marker string, entries map[string]Entry) ([]string, []error) {
	if err := checkRoot(root, marker); err != nil {
		return nil, []error{err}
	}
	names := make([]string, 0, len(entries))
	for name := range entries {
		names = append(names, name)
	}
	sort.Strings(names)

	var created []string
	var problems []error
	for _, name := range names {
		made, err := ensure(root, marker, name, entries[name])
		if err != nil {
			problems = append(problems, fmt.Errorf("%s: %w", name, err))
		} else if made {
			created = append(created, name)
		}
	}
	return created, problems
}

func checkRoot(root, marker string) error {
	info, err := os.Lstat(root)
	if err != nil || !info.IsDir() {
		return fmt.Errorf("state root %s is not a directory; creating nothing", root)
	}
	info, err = os.Lstat(filepath.Join(root, marker))
	if err != nil || !info.Mode().IsRegular() {
		return fmt.Errorf("state root marker %s is missing; creating nothing", filepath.Join(root, marker))
	}
	return nil
}

func ensure(root, marker, name string, entry Entry) (bool, error) {
	if name == "" || name == "." || name == ".." || name == marker || strings.ContainsRune(name, '/') {
		return false, errors.New("not a single directory name")
	}
	mode, err := strconv.ParseUint(entry.Mode, 8, 32)
	if err != nil || mode > 0o777 {
		return false, fmt.Errorf("invalid mode %q; setuid, setgid, and sticky are not supported", entry.Mode)
	}
	if entry.UID < 0 || entry.GID < 0 {
		return false, errors.New("invalid owner")
	}
	perm := fs.FileMode(mode)
	path := filepath.Join(root, name)

	info, err := os.Lstat(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		if err := os.Mkdir(path, 0o700); err != nil {
			return false, err
		}
		// Mkdir applies the umask; set the exact mode before giving it away.
		if err := os.Chmod(path, perm); err != nil {
			return false, err
		}
		if err := os.Lchown(path, entry.UID, entry.GID); err != nil {
			return false, err
		}
		if err := matches(path, entry, mode); err != nil {
			return false, fmt.Errorf("created, but %w", err)
		}
		return true, nil
	case err != nil:
		return false, err
	case info.Mode()&fs.ModeSymlink != 0:
		return false, errors.New("is a symlink; refusing")
	case !info.IsDir():
		return false, errors.New("is not a directory")
	}
	return false, matches(path, entry, mode)
}

func matches(path string, entry Entry, mode uint64) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return errors.New("cannot read owner")
	}
	actual := uint64(st.Mode & 0o7777)
	if int(st.Uid) != entry.UID || int(st.Gid) != entry.GID || actual != mode {
		return fmt.Errorf("is %d:%d %04o, declared %d:%d %04o; not repairing",
			st.Uid, st.Gid, actual, entry.UID, entry.GID, mode)
	}
	return nil
}
