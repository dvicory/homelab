// Package retained validates retained identities and performs explicitly confirmed
// single-directory provisioning or adoption. Validation never changes state.
//
// The root ledger prevents provisioning a previously reserved or established
// leaf, even after its declaration is removed. Losing the entire root also loses
// that ledger: a fresh, explicitly confirmed root provision is an operator
// authorization boundary, not a recovery action suitable for automatic replay.
// The ledger belongs to the declared trusted root UID/GID (including mapped host
// owners) with mode 0444. Application directories contain no helper-owned files.
// Linux statx mount IDs, procfs, directory fsync/flock, and atomic no-replace
// rename support are required. Unsupported platforms and filesystems fail closed.
package retained

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"unicode"
)

const (
	Version      = 1
	MaxSpecBytes = 1 << 20
	maxEntries   = 4096
)

// Source identifies a filesystem and a subtree within it, not a host pathname.
type Source struct {
	FSType string `json:"fsType"`
	Name   string `json:"name"`
	Root   string `json:"root"`
}

type Root struct {
	ID     string `json:"id"`
	Path   string `json:"path"`
	Marker string `json:"marker"`
	Source Source `json:"source"`
	UID    int    `json:"uid"`
	GID    int    `json:"gid"`
	Mode   string `json:"mode"`
}

type Entry struct {
	ID   string `json:"id"`
	UID  int    `json:"uid"`
	GID  int    `json:"gid"`
	Mode string `json:"mode"`
}

type Spec struct {
	Version int              `json:"version"`
	Root    Root             `json:"root"`
	Entries map[string]Entry `json:"entries"`
}

// Keep malformed sibling declarations invalid without making them a dependency
// of the selected entry. Root fields and the entries object remain mandatory.
func (s *Spec) UnmarshalJSON(data []byte) error {
	var document struct {
		Version int                        `json:"version"`
		Root    Root                       `json:"root"`
		Entries map[string]json.RawMessage `json:"entries"`
	}
	if err := decodeObject(data, &document); err != nil {
		return err
	}
	*s = Spec{Version: document.Version, Root: document.Root}
	if document.Entries == nil {
		return nil
	}
	if len(document.Entries) > maxEntries {
		return errors.New("too many retained entry declarations")
	}
	s.Entries = make(map[string]Entry, len(document.Entries))
	for name, raw := range document.Entries {
		var entry Entry
		if err := decodeObject(raw, &entry); err != nil {
			entry = Entry{UID: -1, GID: -1}
		}
		s.Entries[name] = entry
	}
	return nil
}

// Missing owners must not silently become the privileged owner zero.
func (r *Root) UnmarshalJSON(data []byte) error {
	type plain Root
	value := plain{UID: -1, GID: -1}
	if err := decodeObject(data, &value); err != nil {
		return err
	}
	*r = Root(value)
	return nil
}

func (e *Entry) UnmarshalJSON(data []byte) error {
	type plain Entry
	value := plain{UID: -1, GID: -1}
	if err := decodeObject(data, &value); err != nil {
		return err
	}
	*e = Entry(value)
	return nil
}

// ParseSpec bounds input, rejects ambiguous JSON and unknown root fields, and
// checks the root contract. Entry schema and semantics are enforced only when
// that entry is used; malformed siblings cannot gate a different application's mount.
func ParseSpec(reader io.Reader) (Spec, error) {
	var spec Spec
	if err := readJSON(reader, MaxSpecBytes, &spec); err != nil {
		return spec, fmt.Errorf("invalid retained spec: %w", err)
	}
	if err := spec.checkRoot(); err != nil {
		return spec, err
	}
	return spec, nil
}

func readJSON(reader io.Reader, limit int64, value any) error {
	data, err := io.ReadAll(io.LimitReader(reader, limit+1))
	if err != nil {
		return err
	}
	if int64(len(data)) > limit {
		return errors.New("JSON exceeds size limit")
	}
	// encoding/json otherwise accepts duplicate keys; required owner fields
	// separately use negative sentinels so null cannot become privileged zero.
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := scanJSON(decoder, 0); err != nil {
		return err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return errors.New("expected exactly one JSON object")
	}
	return decodeObject(data, value)
}

func decodeObject(data []byte, value any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	return decoder.Decode(value)
}

func scanJSON(decoder *json.Decoder, depth int) error {
	if depth > 16 {
		return errors.New("JSON nesting exceeds limit")
	}
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	if token == nil && depth == 0 {
		return errors.New("expected a JSON object")
	}
	delim, compound := token.(json.Delim)
	if !compound {
		if depth == 0 {
			return errors.New("expected a JSON object")
		}
		return nil
	}
	switch delim {
	case '{':
		keys := make(map[string]bool)
		for decoder.More() {
			key, err := decoder.Token()
			if err != nil {
				return err
			}
			name, ok := key.(string)
			if !ok || keys[name] {
				return fmt.Errorf("duplicate or invalid JSON key %q", key)
			}
			keys[name] = true
			if err := scanJSON(decoder, depth+1); err != nil {
				return err
			}
		}
	case '[':
		if depth == 0 {
			return errors.New("expected a JSON object")
		}
		for decoder.More() {
			if err := scanJSON(decoder, depth+1); err != nil {
				return err
			}
		}
	default:
		return errors.New("unexpected JSON delimiter")
	}
	_, err = decoder.Token()
	return err
}

func (s Spec) checkRoot() error {
	if s.Version != Version {
		return fmt.Errorf("unsupported retained spec version %d", s.Version)
	}
	if s.Entries == nil || len(s.Entries) > maxEntries {
		return errors.New("entries must be an object with at most 4096 declarations")
	}
	r := s.Root
	if !identity(r.ID) || !absolute(r.Path) || r.Path == "/" || !basename(r.Marker) {
		return errors.New("root requires an identity, canonical absolute non-root path, and marker basename")
	}
	if err := r.Source.check(); err != nil {
		return fmt.Errorf("root source: %w", err)
	}
	mode, err := metadata(r.UID, r.GID, r.Mode)
	if err != nil {
		return fmt.Errorf("root metadata: %w", err)
	}
	if mode&0o022 != 0 {
		return errors.New("root must not be group- or other-writable: its ledger is trusted")
	}
	return nil
}

func (s Spec) entry(name string) (Entry, error) {
	entry, ok := s.Entries[name]
	if !ok || !basename(name) || name == s.Root.Marker {
		return Entry{}, fmt.Errorf("%q is not a declared single entry name", name)
	}
	if !identity(entry.ID) || entry.ID == s.Root.ID {
		return Entry{}, errors.New("entry requires its own nonempty identity")
	}
	if _, err := metadata(entry.UID, entry.GID, entry.Mode); err != nil {
		return Entry{}, fmt.Errorf("entry %s metadata: %w", name, err)
	}
	return entry, nil
}

func identity(value string) bool {
	return len(value) > 0 && len(value) <= 256 && !strings.ContainsFunc(value, unicode.IsSpace) && !strings.ContainsFunc(value, unicode.IsControl)
}

func basename(value string) bool {
	return value != "" && value != "." && value != ".." && len(value) <= 255 && !strings.ContainsAny(value, "/\x00") && !strings.ContainsFunc(value, unicode.IsControl) && !strings.HasPrefix(value, ".retained-write-")
}

func absolute(value string) bool {
	return filepath.IsAbs(value) && filepath.Clean(value) == value && !strings.ContainsAny(value, "\x00\n\r")
}

func (source Source) check() error {
	if source.FSType == "" || len(source.FSType) > 128 || strings.ContainsFunc(source.FSType, unicode.IsSpace) || source.Name == "" || len(source.Name) > 4096 || strings.ContainsAny(source.Name, "\x00\n\r") || !absolute(source.Root) {
		return errors.New("fsType, filesystem name, and canonical absolute filesystem-relative root are required")
	}
	return nil
}

func metadata(uid, gid int, value string) (uint32, error) {
	if uid < 0 || gid < 0 || uint64(uid) >= 1<<32-1 || uint64(gid) >= 1<<32-1 {
		return 0, errors.New("uid and gid must be nonnegative usable 32-bit owners")
	}
	if len(value) < 3 || len(value) > 4 || strings.ContainsAny(value, "+- ") {
		return 0, fmt.Errorf("invalid octal mode %q", value)
	}
	mode, err := strconv.ParseUint(value, 8, 12)
	if err != nil || mode > 0o777 {
		return 0, fmt.Errorf("invalid mode %q; special bits are not supported", value)
	}
	return uint32(mode), nil
}

func entrySource(root Source, name string) Source {
	root.Root = filepath.Join(root.Root, name)
	return root
}

func names(entries map[string]Entry) []string {
	result := make([]string, 0, len(entries))
	for name := range entries {
		result = append(result, name)
	}
	sort.Strings(result)
	return result
}

// RootLedger keeps removed declarations and pending operations. A pending
// identity is not valid state and cannot be replayed as fresh provisioning.
// The ledger binds the root and established leaves to their filesystem inodes;
// copied receipt bytes alone cannot establish a replacement directory. Device
// numbers are deliberately not persisted because they can change across boots.
// Generation-bearing export handles distinguish recycled inode numbers.
// UID/GID and directory mode are checked live against the local Spec rather than
// persisted here: a host and its user namespace share this one ledger while
// observing different owner numbers for the same physical directory and files.
type RootLedger struct {
	Version int                         `json:"version"`
	ID      string                      `json:"id"`
	Inode   uint64                      `json:"inode"`
	Object  ObjectIdentity              `json:"object"`
	Source  Source                      `json:"source"`
	Entries map[string]EstablishedEntry `json:"entries"`
}

type EstablishedEntry struct {
	ID     string         `json:"id"`
	Inode  uint64         `json:"inode"`
	Object ObjectIdentity `json:"object"`
	State  string         `json:"state"`
}

type ObjectIdentity struct {
	Type   int32  `json:"type"`
	Handle []byte `json:"handle"`
}

func (object ObjectIdentity) valid() bool {
	return object.Type > 0 && object.Type < 255 && len(object.Handle) > 0 && len(object.Handle) <= 128
}

func (object ObjectIdentity) equal(other ObjectIdentity) bool {
	return object.Type == other.Type && bytes.Equal(object.Handle, other.Handle)
}

func newLedger(root Root, inode uint64) RootLedger {
	return RootLedger{Version: Version, ID: root.ID, Inode: inode, Source: root.Source, Entries: make(map[string]EstablishedEntry)}
}
