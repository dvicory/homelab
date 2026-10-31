// retained-directories validates retained state without mutation. Creating or
// adopting one root or entry requires a separate, explicitly confirmed command.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/dvicory/homelab/compute-runtime/internal/retained"
)

const usage = "usage: retained-directories validate --spec PATH [--root | --entry NAME]\n       retained-directories provision|adopt --spec PATH (--root | --entry NAME) --confirm ID\nPATH '-' reads a version-1 JSON spec from stdin"

type result struct {
	Version   int    `json:"version"`
	Operation string `json:"operation"`
	RootID    string `json:"rootId"`
	Scope     string `json:"scope"`
	Entry     string `json:"entry,omitempty"`
	ID        string `json:"id"`
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	fail := func(code int, err any) int {
		fmt.Fprintf(stderr, "retained-directories: %v\n", err)
		return code
	}
	if len(args) == 0 || (args[0] != "validate" && args[0] != "provision" && args[0] != "adopt") {
		return fail(64, usage)
	}
	operation := args[0]
	flags := flag.NewFlagSet(operation, flag.ContinueOnError)
	flags.SetOutput(stderr)
	path := flags.String("spec", "", "version-1 JSON spec path, or - for stdin")
	root := flags.Bool("root", false, "select only the root")
	entry := flags.String("entry", "", "select one declared entry")
	confirm := flags.String("confirm", "", "exact selected identity")
	if err := flags.Parse(args[1:]); err != nil {
		return 64
	}
	present := make(map[string]bool)
	flags.Visit(func(value *flag.Flag) { present[value.Name] = true })
	if flags.NArg() != 0 || *path == "" || (*root && present["entry"]) || (present["entry"] && *entry == "") || (present["root"] && !*root) {
		return fail(64, usage)
	}
	if operation == "validate" {
		if present["confirm"] {
			return fail(64, "validate does not accept --confirm")
		}
	} else if (!*root && *entry == "") || !present["confirm"] || *confirm == "" {
		return fail(64, usage)
	}
	reader := stdin
	if *path != "-" {
		file, err := os.Open(*path)
		if err != nil {
			return fail(64, err)
		}
		defer file.Close()
		reader = file
	}
	spec, err := retained.ParseSpec(reader)
	if err != nil {
		return fail(64, err)
	}
	switch operation {
	case "validate":
		if *root {
			err = retained.ValidateRoot(spec)
		} else {
			err = retained.Validate(spec, *entry)
		}
	case "provision":
		err = retained.Provision(spec, *entry, *confirm)
	case "adopt":
		err = retained.Adopt(spec, *entry, *confirm)
	}
	if err != nil {
		return fail(1, err)
	}
	receipt := result{Version: 1, Operation: operation, RootID: spec.Root.ID, Scope: "all", ID: spec.Root.ID}
	if *root {
		receipt.Scope = "root"
	} else if *entry != "" {
		receipt.Scope = "entry"
		receipt.Entry = *entry
		receipt.ID = spec.Entries[*entry].ID
	}
	if err := json.NewEncoder(stdout).Encode(receipt); err != nil {
		return fail(1, err)
	}
	return 0
}
