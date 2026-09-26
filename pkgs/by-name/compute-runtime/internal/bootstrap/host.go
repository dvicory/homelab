//go:build linux

package bootstrap

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"github.com/dvicory/homelab/compute-runtime/internal/incusops"
	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
)

const hostUsage = `Usage: household-bootstrap-host DESCRIPTOR --confirm INSTANCE

Deliver the Argo seed to an existing Running Incus guest, then hand off to Git reconciliation.
The command never creates/deletes guests, publishes Git, changes host configuration, or generates credentials.
`

var safeName = regexp.MustCompile(`^[a-zA-Z0-9_-]+$`)

const runtimeSecretStagePath = "/run/homelab-compute/secrets"

type descriptor struct {
	Project        string
	Instance       string
	Address        string
	Path           string
	RuntimeSecrets []runtimeSecret
}

func stageCurrentRuntimeSecrets(ctx context.Context, secrets []runtimeSecret) (string, error) {
	stage, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	unit := "compute-stage-secrets-current@" + runtimeSecretInventoryHash(secrets) + ".service"
	command := exec.CommandContext(stage, "systemctl", "restart", "--wait", unit)
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	if err := command.Run(); err != nil {
		if stage.Err() != nil {
			return "", fmt.Errorf("stage runtime Secrets timed out: %w", stage.Err())
		}
		return "", fmt.Errorf("stage runtime Secrets: %w", err)
	}
	generation, err := readRuntimeGeneration(runtimeSecretStagePath)
	if err != nil {
		return "", fmt.Errorf("verify staged runtime Secrets: %w", err)
	}
	staged, err := os.ReadFile(filepath.Join(runtimeSecretStagePath, "runtime-secrets.names"))
	if err != nil {
		return "", fmt.Errorf("verify staged runtime Secrets: read inventory: %w", err)
	}
	if err := verifyRuntimeSecretInventory(secrets, staged); err != nil {
		return "", fmt.Errorf("verify staged runtime Secrets: %w", err)
	}
	return generation, nil
}

func RunHost(ctx context.Context, args []string, out, errOut io.Writer) (result error) {
	if len(args) == 1 && args[0] == "--help" {
		_, _ = io.WriteString(out, hostUsage)
		return nil
	}
	if len(args) != 3 || args[1] != "--confirm" {
		_, _ = io.WriteString(errOut, hostUsage)
		return &UsageError{Code: 2, Text: "usage: household-bootstrap-host DESCRIPTOR --confirm INSTANCE"}
	}
	if os.Geteuid() != 0 {
		return errors.New("run as root on the physical Linux Incus host")
	}

	descriptor, err := loadDescriptor(args[0])
	if err != nil {
		return err
	}
	if args[2] != descriptor.Instance {
		return fmt.Errorf("explicit acknowledgment required: --confirm %s", descriptor.Instance)
	}
	if !safeName.MatchString(descriptor.Project) || !safeName.MatchString(descriptor.Instance) {
		return errors.New("invalid project or instance name")
	}

	lockPath := filepath.Join("/run/lock", "compute-"+descriptor.Project+"-"+descriptor.Instance+".lock")
	lock, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return fmt.Errorf("cannot open lifecycle lock: %w", err)
	}
	defer lock.Close()
	if err := lock.Chmod(0o600); err != nil {
		return fmt.Errorf("cannot secure lifecycle lock: %w", err)
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return errors.New("another compute lifecycle operation is running")
	}

	manifests, err := OpenManifests(os.Getenv("HOUSEHOLD_BOOTSTRAP_MANIFESTS"))
	if err != nil {
		return err
	}
	if err := manifests.require("namespaces.yaml", "controllers.yaml", "root.yaml"); err != nil {
		return err
	}
	bootstrapPath := strings.TrimSpace(os.Getenv("HOUSEHOLD_BOOTSTRAP_BIN"))
	if bootstrapPath == "" {
		return errors.New("HOUSEHOLD_BOOTSTRAP_BIN is required")
	}
	bootstrapInfo, err := os.Stat(bootstrapPath)
	if err != nil {
		return fmt.Errorf("bootstrap executable is unavailable: %w", err)
	}
	if !bootstrapInfo.Mode().IsRegular() {
		return fmt.Errorf("bootstrap executable is unavailable: %s", bootstrapPath)
	}

	socket := strings.TrimSpace(os.Getenv("INCUS_SOCKET"))
	if socket == "" {
		socket = "/var/lib/incus/unix.socket"
	}
	tools := NewTools(out, errOut)
	tools.Env = withEnvironment(tools.Env, map[string]string{"INCUS_SOCKET": socket})

	if err := runComputeGuestInspect(ctx, tools.Env, descriptor.Path, lock, errOut); err != nil {
		return fmt.Errorf("unable to validate declared compute envelope; refusing before mutation: %w", err)
	}
	connectionCtx, connectionCancel := context.WithCancel(ctx)
	server, err := incus.ConnectIncusUnixWithContext(connectionCtx, socket, &incus.ConnectionArgs{
		HTTPClient:    &http.Client{Timeout: 30 * time.Minute},
		SkipGetEvents: true,
	})
	if err != nil {
		connectionCancel()
		return fmt.Errorf("cannot connect to local Incus socket: %w", err)
	}
	defer connectionCancel()
	defer server.Disconnect()
	projectServer := server.UseProject(descriptor.Project)

	instances, err := projectServer.GetInstances(api.InstanceTypeAny)
	if err != nil {
		return fmt.Errorf("cannot inspect Incus target %s/%s: %w", descriptor.Project, descriptor.Instance, err)
	}
	matching := 0
	for _, instance := range instances {
		if instance.Name != descriptor.Instance {
			continue
		}
		matching++
		if instance.Status != "Running" {
			return fmt.Errorf("target %s/%s must already exist and be Running", descriptor.Project, descriptor.Instance)
		}
	}
	if matching != 1 {
		return fmt.Errorf("target %s/%s must already exist and be Running", descriptor.Project, descriptor.Instance)
	}

	tmp, err := os.MkdirTemp("", "household-bootstrap-")
	if err != nil {
		return fmt.Errorf("cannot create root-private temporary directory: %w", err)
	}
	if err := verifyPrivateDirectory(tmp); err != nil {
		_ = os.RemoveAll(tmp)
		return err
	}

	var runErr error
	defer func() {
		if cleanupErr := os.RemoveAll(tmp); cleanupErr != nil && result == nil {
			result = fmt.Errorf("unable to remove temporary files: %w", cleanupErr)
		}
	}()
	kubePath := filepath.Join(tmp, "kubeconfig")
	if runErr = acquireKubeconfig(ctx, tools, projectServer, descriptor, kubePath); runErr != nil {
		return runErr
	}
	tools.Env = withEnvironment(tools.Env, map[string]string{"KUBECONFIG": kubePath})
	if runErr = verifyNodePlacement(ctx, tools, manifests, descriptor); runErr != nil {
		return runErr
	}
	if runErr = tools.CheckArgo(ctx); runErr != nil {
		return runErr
	}
	runtimeGeneration, err := stageCurrentRuntimeSecrets(ctx, descriptor.RuntimeSecrets)
	if err != nil {
		return err
	}

	if runErr = tools.ApplyFile(ctx, manifests.file("namespaces.yaml"), fieldManager); runErr != nil {
		return runErr
	}
	seenNamespaces := make(map[string]bool)
	for _, secret := range descriptor.RuntimeSecrets {
		namespace := secret.Namespace
		if seenNamespaces[namespace] {
			continue
		}
		seenNamespaces[namespace] = true
		create, cancel := context.WithTimeout(ctx, 60*time.Second)
		namespaceYAML, createErr := tools.RunKubectl(create, "create", "namespace", namespace, "--dry-run=client", "-o", "yaml")
		cancel()
		if createErr != nil {
			return fmt.Errorf("cannot ensure secret namespace %s: %w", namespace, createErr)
		}
		if runErr = tools.ApplyInput(ctx, namespaceYAML, "homelab-runtime-secrets", false); runErr != nil {
			return fmt.Errorf("cannot ensure secret namespace %s: %w", namespace, runErr)
		}
	}
	restart, restartCancel := context.WithTimeout(ctx, 2*time.Minute)
	runErr = incusops.Exec(
		restart,
		projectServer,
		descriptor.Instance,
		[]string{"systemctl", "restart", "kubernetes-runtime-secrets.service"},
		nil,
		io.Discard,
		io.Discard,
	)
	restartCancel()
	if runErr != nil {
		return fmt.Errorf("cannot reconcile staged runtime Secrets: %w", runErr)
	}
	wait, cancel := context.WithTimeout(ctx, 5*time.Minute)
	runErr = waitRuntimeSecretGeneration(wait, runtimeGeneration, func(probe context.Context, generation string) error {
		return incusops.Exec(
			probe,
			projectServer,
			descriptor.Instance,
			runtimeSecretGenerationCommand(generation),
			nil,
			io.Discard,
			io.Discard,
		)
	})
	if runErr == nil {
		runErr = waitRuntimeSecrets(wait, descriptor.RuntimeSecrets, func(probe context.Context, secret runtimeSecret) error {
			return incusops.Exec(probe, projectServer, descriptor.Instance, secretReadyCommand(secret), nil, io.Discard, io.Discard)
		})
	}
	cancel()
	if runErr != nil {
		return runErr
	}
	if runErr = runBootstrap(ctx, tools.Env, bootstrapPath, "--fresh-cluster", out, errOut); runErr != nil {
		return runErr
	}
	if runErr = runBootstrap(ctx, tools.Env, bootstrapPath, "--check-ready", out, errOut); runErr != nil {
		return runErr
	}
	// Argo creates the default AppProject before the bootstrap restricts it.
	if runErr = tools.RunKubectlPrint(ctx, "apply", "--server-side", "--force-conflicts", "--field-manager="+fieldManager, "-f", manifests.file("root.yaml")); runErr != nil {
		return runErr
	}
	fmt.Fprintln(out, "Argo seed is ready and the canonical root Application was applied. Verify child synchronization before application acceptance.")
	return runErr
}

func loadDescriptor(path string) (descriptor, error) {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return descriptor{}, fmt.Errorf("cannot resolve descriptor %s: %w", path, err)
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return descriptor{}, fmt.Errorf("cannot stat descriptor: %w", err)
	}
	if !info.Mode().IsRegular() {
		return descriptor{}, errors.New("descriptor is not a regular file")
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); !ok || stat.Uid != 0 {
		return descriptor{}, errors.New("descriptor must be root-owned")
	}
	if info.Mode().Perm()&0o22 != 0 {
		return descriptor{}, errors.New("descriptor must not be writable by group or other users")
	}
	file, err := os.Open(resolved)
	if err != nil {
		return descriptor{}, fmt.Errorf("cannot read descriptor: %w", err)
	}
	defer file.Close()
	var object map[string]json.RawMessage
	decoder := json.NewDecoder(file)
	if err := decoder.Decode(&object); err != nil {
		return descriptor{}, fmt.Errorf("descriptor must be a JSON object: %w", err)
	}
	if object == nil {
		return descriptor{}, errors.New("descriptor must be a JSON object")
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return descriptor{}, errors.New("descriptor contains trailing JSON")
	}
	get := func(key string) (string, error) {
		var value string
		if err := json.Unmarshal(object[key], &value); err != nil || strings.TrimSpace(value) == "" {
			return "", fmt.Errorf("descriptor has no %s", key)
		}
		return value, nil
	}
	project, err := get("project")
	if err != nil {
		return descriptor{}, err
	}
	instance, err := get("instance")
	if err != nil {
		return descriptor{}, err
	}
	address, err := get("address")
	if err != nil {
		return descriptor{}, err
	}
	secrets, err := declaredRuntimeSecrets(object["runtimeSecrets"])
	if err != nil {
		return descriptor{}, err
	}
	return descriptor{Project: project, Instance: instance, Address: address, Path: resolved, RuntimeSecrets: secrets}, nil
}

func verifyPrivateDirectory(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("cannot inspect temporary directory: %w", err)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != 0 || info.Mode().Perm() != 0o700 || !info.IsDir() {
		return errors.New("temporary directory is not root-private")
	}
	return nil
}

func runComputeGuestInspect(ctx context.Context, env []string, spec string, lock *os.File, errOut io.Writer) error {
	path, err := exec.LookPath("compute-guest")
	if err != nil {
		return fmt.Errorf("locate compute-guest: %w", err)
	}
	inspect, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(inspect, path, "--spec", spec, "--lock-fd", "3", "inspect")
	cmd.Env = env
	cmd.ExtraFiles = []*os.File{lock}
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	if err := cmd.Run(); err != nil {
		if inspect.Err() != nil {
			return fmt.Errorf("compute-guest inspect: %w", inspect.Err())
		}
		return fmt.Errorf("compute-guest inspect: %w", err)
	}
	return nil
}

func acquireKubeconfig(ctx context.Context, tools *Tools, server incus.InstanceServer, target descriptor, kubePath string) error {
	reader, _, err := server.GetInstanceFile(target.Instance, "/etc/rancher/k3s/k3s.yaml")
	if err != nil {
		return fmt.Errorf("cannot acquire fresh kubeconfig from selected guest: %w", err)
	}
	raw, err := ReadBytes(reader)
	if err != nil {
		return fmt.Errorf("cannot acquire fresh kubeconfig from selected guest: %w", err)
	}
	parse, cancel := context.WithTimeout(ctx, 30*time.Second)
	encoded, err := tools.RunYQInput(parse, raw, "-o=json", "-N", ".", "-")
	cancel()
	if err != nil {
		return fmt.Errorf("guest kubeconfig is invalid: %w", err)
	}
	output, err := buildHostKubeconfig(encoded, "https://"+target.Address+":6443")
	if err != nil {
		return err
	}
	if err := writePrivateFile(kubePath, output); err != nil {
		return fmt.Errorf("cannot store fresh kubeconfig: %w", err)
	}
	return nil
}

func buildHostKubeconfig(raw []byte, endpoint string) ([]byte, error) {
	var input struct {
		Clusters []struct {
			Cluster struct {
				CertificateAuthorityData string `json:"certificate-authority-data"`
			} `json:"cluster"`
		} `json:"clusters"`
		Users []struct {
			User struct {
				ClientCertificateData string `json:"client-certificate-data"`
				ClientKeyData         string `json:"client-key-data"`
			} `json:"user"`
		} `json:"users"`
	}
	if err := json.Unmarshal(raw, &input); err != nil || len(input.Clusters) != 1 || len(input.Users) != 1 {
		return nil, errors.New("guest kubeconfig must contain exactly one embedded cluster identity")
	}
	ca := input.Clusters[0].Cluster.CertificateAuthorityData
	certificate := input.Users[0].User.ClientCertificateData
	key := input.Users[0].User.ClientKeyData
	if strings.TrimSpace(ca) == "" || strings.TrimSpace(certificate) == "" || strings.TrimSpace(key) == "" {
		return nil, errors.New("guest kubeconfig lacks embedded CA/client identity")
	}
	safe := map[string]any{
		"apiVersion": "v1",
		"kind":       "Config",
		"clusters": []any{map[string]any{
			"name": "compute",
			"cluster": map[string]string{
				"server":                     endpoint,
				"certificate-authority-data": ca,
			},
		}},
		"users": []any{map[string]any{
			"name": "compute",
			"user": map[string]string{
				"client-certificate-data": certificate,
				"client-key-data":         key,
			},
		}},
		"contexts": []any{map[string]any{
			"name": "compute",
			"context": map[string]string{
				"cluster": "compute",
				"user":    "compute",
			},
		}},
		"current-context": "compute",
	}
	output, err := json.MarshalIndent(safe, "", "  ")
	if err != nil {
		return nil, errors.New("cannot construct host kubeconfig")
	}
	return append(output, '\n'), nil
}

func writePrivateFile(path string, data []byte) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	_, writeErr := file.Write(data)
	closeErr := file.Close()
	if writeErr != nil {
		return writeErr
	}
	if closeErr != nil {
		return closeErr
	}
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("cannot inspect temporary file: %w", err)
	}
	if info.Mode().Perm() != 0o600 {
		return errors.New("temporary file is not root-private")
	}
	return nil
}

func verifyNodePlacement(ctx context.Context, tools *Tools, manifests Manifests, target descriptor) error {
	inspect, cancel := context.WithTimeout(ctx, 30*time.Second)
	output, err := tools.RunKubectl(inspect, "get", "node", target.Instance, "-o", "json", requestTimeout(25*time.Second))
	cancel()
	if err != nil {
		return fmt.Errorf("Kubernetes target node %s is missing: %w", target.Instance, err)
	}
	var node map[string]any
	if err := jsonDecoder(output).Decode(&node); err != nil {
		return fmt.Errorf("Kubernetes target node %s is missing: %w", target.Instance, err)
	}
	metadata := mapField(node, "metadata")
	if stringField(metadata, "name") != target.Instance || stringField(mapField(metadata, "labels"), "kubernetes.io/hostname") != target.Instance {
		return fmt.Errorf("Kubernetes target node does not match declared placement: %s", target.Instance)
	}
	declared, err := DeclaredNodes(ctx, tools, manifests)
	if err != nil {
		return err
	}
	for _, nodeName := range declared {
		if nodeName != target.Instance {
			return fmt.Errorf("bootstrap artifact declares node %s, not %s", nodeName, target.Instance)
		}
	}
	return nil
}

func runBootstrap(ctx context.Context, env []string, path, mode string, out, errOut io.Writer) error {
	phase, cancel := context.WithTimeout(ctx, 30*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(phase, path, mode)
	cmd.Env = env
	cmd.Stdout = out
	cmd.Stderr = errOut
	if err := cmd.Run(); err != nil {
		if phase.Err() != nil {
			return fmt.Errorf("bootstrap %s timed out: %w", mode, phase.Err())
		}
		return fmt.Errorf("bootstrap %s failed: %w", mode, err)
	}
	return nil
}
