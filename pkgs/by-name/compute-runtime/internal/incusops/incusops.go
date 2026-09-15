package incusops

import (
	"context"
	"errors"
	"fmt"
	"io"
	"time"

	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
)

// ErrUnknownOutcome means the daemon may have completed the operation even
// though this client stopped waiting. Callers must not continue with a
// destructive follow-up when this error is returned.
var ErrUnknownOutcome = errors.New("Incus operation outcome is unknown")

// Wait requires a final server result. The SDK's eventless WaitContext can
// return nil while an operation is still running, so use its wait endpoint
// with a request context and check the returned status.
func Wait(ctx context.Context, server incus.InstanceServer, op incus.Operation) (api.Operation, error) {
	initial := op.Get()
	client := server.(*incus.ProtocolIncus).WithContext(ctx)
	state, _, err := client.GetOperationWait(initial.ID, -1)
	if err == nil && state.StatusCode == api.Success {
		return *state, nil
	}
	if err == nil && state.StatusCode.IsFinal() {
		return *state, fmt.Errorf("Incus operation %s ended %s: %s", initial.ID, state.Status, state.Err)
	}
	if ctx.Err() != nil && initial.MayCancel {
		cancelCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		cancelErr := server.(*incus.ProtocolIncus).WithContext(cancelCtx).DeleteOperation(initial.ID)
		if cancelErr != nil {
			err = fmt.Errorf("%v; cancellation request failed: %w", err, cancelErr)
		}
	}
	return api.Operation{}, fmt.Errorf("Incus operation %s did not reach a known final state (%v): %w", initial.ID, err, ErrUnknownOutcome)
}

// Exec runs a command through Incus's native non-interactive exec API, waits
// for all output streams, and rejects a non-zero remote exit status.
func Exec(ctx context.Context, server incus.InstanceServer, name string, argv []string, stdin io.Reader, stdout, stderr io.Writer) error {
	if server == nil {
		return errors.New("nil Incus server")
	}
	if name == "" {
		return errors.New("empty instance name")
	}
	if len(argv) == 0 || argv[0] == "" {
		return errors.New("empty instance command")
	}

	dataDone := make(chan bool)
	client := server.(*incus.ProtocolIncus).WithContext(ctx)
	op, err := client.ExecInstance(name, api.InstanceExecPost{
		Command:     argv,
		WaitForWS:   true,
		Interactive: false,
	}, &incus.InstanceExecArgs{
		Stdin:    stdin,
		Stdout:   stdout,
		Stderr:   stderr,
		DataDone: dataDone,
	})
	if err != nil {
		return fmt.Errorf("exec %q: %w", argv[0], err)
	}

	state, err := Wait(ctx, server, op)
	if err != nil {
		return fmt.Errorf("exec %q: %w", argv[0], err)
	}

	select {
	case <-dataDone:
	case <-ctx.Done():
		return fmt.Errorf("exec %q output did not finish: %w", argv[0], ErrUnknownOutcome)
	}

	status, err := exitStatus(state)
	if err != nil {
		return fmt.Errorf("exec %q: %w", argv[0], err)
	}
	if status != 0 {
		return fmt.Errorf("exec %q exited with status %d", argv[0], status)
	}

	return nil
}

func exitStatus(operation api.Operation) (int, error) {
	value, ok := operation.Metadata["return"].(float64)
	if !ok || value != float64(int(value)) {
		return 0, errors.New("Incus exec operation did not report a valid remote exit status")
	}
	return int(value), nil
}
