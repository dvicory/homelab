//go:build linux

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"

	"github.com/dvicory/homelab/compute-runtime/internal/bootstrap"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	if err := bootstrap.RunHost(ctx, os.Args[1:], os.Stdout, os.Stderr); err != nil {
		var usage *bootstrap.UsageError
		if errors.As(err, &usage) {
			os.Exit(usage.Code)
		}
		fmt.Fprintf(os.Stderr, "household-bootstrap-host: %v\n", err)
		os.Exit(1)
	}
}
