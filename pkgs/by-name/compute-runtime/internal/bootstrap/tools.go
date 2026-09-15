package bootstrap

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"
)

// Tools runs the native kubectl and yq programs. Their output is captured by
// default so structured callers can inspect it without ever echoing manifests.
type Tools struct {
	Out io.Writer
	Err io.Writer
	Env []string

	KubectlPath string
	YQPath      string
}

func NewTools(out, errOut io.Writer) *Tools {
	if out == nil {
		out = io.Discard
	}
	if errOut == nil {
		errOut = io.Discard
	}
	return &Tools{Out: out, Err: errOut, Env: os.Environ()}
}

func (t *Tools) command(ctx context.Context, name string, args []string, stdin io.Reader, extraEnv map[string]string, printOutput bool) ([]byte, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if _, hasDeadline := ctx.Deadline(); !hasDeadline {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, 10*time.Minute)
		defer cancel()
	}
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdin = stdin
	cmd.Env = withEnvironment(t.Env, extraEnv)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return nil, fmt.Errorf("%s %s: %w", name, strings.Join(args, " "), ctx.Err())
		}
		// Do not include subprocess output: kubectl/yq may have echoed a
		// credential-bearing object while reporting an error.
		return nil, fmt.Errorf("%s %s: %w", name, strings.Join(args, " "), err)
	}
	if printOutput && stdout.Len() != 0 {
		_, _ = t.Out.Write(stdout.Bytes())
	}
	return stdout.Bytes(), nil
}

func withEnvironment(base []string, extra map[string]string) []string {
	if len(extra) == 0 {
		return base
	}
	values := make(map[string]string, len(base)+len(extra))
	for _, value := range base {
		key, _, ok := strings.Cut(value, "=")
		if ok {
			values[key] = value
		}
	}
	for key, value := range extra {
		values[key] = key + "=" + value
	}
	result := make([]string, 0, len(values))
	for _, value := range values {
		result = append(result, value)
	}
	return result
}

func (t *Tools) kubectl(ctx context.Context, stdin io.Reader, printOutput bool, args ...string) ([]byte, error) {
	name := t.KubectlPath
	if name == "" {
		name = "kubectl"
	}
	return t.command(ctx, name, args, stdin, nil, printOutput)
}

func (t *Tools) yq(ctx context.Context, stdin io.Reader, extraEnv map[string]string, args ...string) ([]byte, error) {
	name := t.YQPath
	if name == "" {
		name = "yq"
	}
	return t.command(ctx, name, args, stdin, extraEnv, false)
}

func (t *Tools) RunKubectl(ctx context.Context, args ...string) ([]byte, error) {
	return t.kubectl(ctx, nil, false, args...)
}

func (t *Tools) RunKubectlInput(ctx context.Context, input []byte, args ...string) ([]byte, error) {
	return t.kubectl(ctx, bytes.NewReader(input), false, args...)
}

func (t *Tools) RunKubectlPrint(ctx context.Context, args ...string) error {
	_, err := t.kubectl(ctx, nil, true, args...)
	return err
}

func (t *Tools) RunYQ(ctx context.Context, args ...string) ([]byte, error) {
	return t.yq(ctx, nil, nil, args...)
}

func (t *Tools) RunYQInput(ctx context.Context, input []byte, args ...string) ([]byte, error) {
	return t.yq(ctx, bytes.NewReader(input), nil, args...)
}

func (t *Tools) RunYQEnv(ctx context.Context, env map[string]string, args ...string) ([]byte, error) {
	return t.yq(ctx, nil, env, args...)
}

func (t *Tools) ApplyFile(ctx context.Context, path, manager string) error {
	return t.RunKubectlPrint(ctx, "apply", "--server-side", "--field-manager="+manager, "-f", path)
}

func (t *Tools) ApplyInput(ctx context.Context, input []byte, manager string, forceConflicts bool) error {
	args := []string{"apply", "--server-side"}
	if forceConflicts {
		args = append(args, "--force-conflicts")
	}
	args = append(args, "--field-manager="+manager, "-f", "-")
	_, err := t.kubectl(ctx, bytes.NewReader(input), true, args...)
	return err
}

func (t *Tools) CheckArgo(ctx context.Context) error {
	inspect, cancel := context.WithTimeout(ctx, 30*time.Second)
	crd, err := t.RunKubectl(inspect, "get", "crd", "applications.argoproj.io", "--ignore-not-found", "-o", "name")
	cancel()
	if err != nil {
		return errors.New("unable to inspect Argo Applications; refusing static operation")
	}
	if len(bytes.TrimSpace(crd)) == 0 {
		return nil
	}

	inspect, cancel = context.WithTimeout(ctx, 30*time.Second)
	applications, err := t.RunKubectl(inspect, "get", "applications.argoproj.io", "--all-namespaces", "-o", "name")
	cancel()
	if err != nil {
		return errors.New("unable to inspect Argo Applications; refusing static operation")
	}
	if len(bytes.TrimSpace(applications)) != 0 {
		return errors.New("refusing static operation while Argo Applications exist")
	}
	return nil
}

func requestTimeout(d time.Duration) string {
	if d <= 0 {
		d = time.Second
	}
	return "--request-timeout=" + d.Truncate(time.Second).String()
}
