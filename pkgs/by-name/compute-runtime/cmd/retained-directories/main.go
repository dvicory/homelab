// retained-directories creates the declared retained directories under the
// compute state root.
//
//	retained-directories ROOT MARKER ENTRIES_JSON
//
// ENTRIES_JSON maps each directory name to its uid, gid, and octal mode.
package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/dvicory/homelab/compute-runtime/internal/retained"
)

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: retained-directories ROOT MARKER ENTRIES_JSON")
		os.Exit(64)
	}
	var entries map[string]retained.Entry
	if err := json.Unmarshal([]byte(os.Args[3]), &entries); err != nil {
		fmt.Fprintf(os.Stderr, "retained-directories: invalid entries: %v\n", err)
		os.Exit(64)
	}
	created, problems := retained.Ensure(os.Args[1], os.Args[2], entries)
	for _, name := range created {
		fmt.Printf("created %s\n", name)
	}
	for _, problem := range problems {
		fmt.Fprintf(os.Stderr, "retained-directories: %v\n", problem)
	}
	if len(problems) != 0 {
		os.Exit(1)
	}
}
