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

type descriptor struct {
	Project  string
	Instance string
	Address  string
	Path     string
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
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return errors.New("another compute lifecycle operation is running")
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)

	manifests, err := OpenManifests(os.Getenv("HOUSEHOLD_BOOTSTRAP_MANIFESTS"))
	if err != nil {
		return err
	}
	if err := manifests.require("namespaces.yaml", "controllers.yaml", "root.yaml"); err != nil {
		return err
	}
	imagePath := strings.TrimSpace(os.Getenv("HOUSEHOLD_KANIDM_IMAGE"))
	if imagePath == "" {
		return errors.New("HOUSEHOLD_KANIDM_IMAGE is required")
	}
	imageInfo, err := os.Stat(imagePath)
	if err != nil || !imageInfo.Mode().IsRegular() {
		return fmt.Errorf("pinned Kanidm image is unavailable: %s", imagePath)
	}
	bootstrapPath := strings.TrimSpace(os.Getenv("HOUSEHOLD_BOOTSTRAP_BIN"))
	if bootstrapPath == "" {
		return errors.New("HOUSEHOLD_BOOTSTRAP_BIN is required")
	}
	bootstrapInfo, err := os.Stat(bootstrapPath)
	if err != nil || !bootstrapInfo.Mode().IsRegular() {
		return fmt.Errorf("bootstrap executable is unavailable: %s", bootstrapPath)
	}

	socket := strings.TrimSpace(os.Getenv("INCUS_SOCKET"))
	if socket == "" {
		socket = "/var/lib/incus/unix.socket"
	}
	tools := NewTools(out, errOut)
	tools.Env = withEnvironment(tools.Env, map[string]string{"INCUS_SOCKET": socket})

	if err := runComputeGuestInspect(ctx, tools.Env, descriptor.Path, lock, errOut); err != nil {
		return errors.New("unable to validate declared compute envelope; refusing before mutation")
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
		return fmt.Errorf("cannot inspect Incus target %s/%s", descriptor.Project, descriptor.Instance)
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

	remoteImage := fmt.Sprintf("/tmp/household-kanidm-provision-%d.tar", os.Getpid())
	imageStaged := false
	var runErr error
	defer func() {
		if imageStaged {
			cleanupErr := projectServer.DeleteInstanceFile(descriptor.Instance, remoteImage)
			if cleanupErr != nil && result == nil {
				result = fmt.Errorf("unable to remove temporary guest image: %w", cleanupErr)
			} else if cleanupErr != nil {
				fmt.Fprintf(errOut, "household-bootstrap-host: warning: unable to remove temporary guest image: %v\n", cleanupErr)
			}
		}
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
		return errors.New("unable to inspect Argo Applications; refusing before mutation")
	}
	if runErr = ensureStagedSecrets(ctx, projectServer, descriptor); runErr != nil {
		return runErr
	}

	fmt.Fprintf(out, "Importing the pinned Kanidm provisioning image into %s/%s.\n", descriptor.Project, descriptor.Instance)
	image, openErr := os.Open(imagePath)
	if openErr != nil {
		return fmt.Errorf("cannot open pinned Kanidm image: %w", openErr)
	}
	imageStaged = true
	// Hide Close from net/http; this function owns the file.
	fileErr := projectServer.CreateInstanceFile(descriptor.Instance, remoteImage, incus.InstanceFileArgs{
		Content:   struct{ io.ReadSeeker }{image},
		UID:       -1,
		GID:       -1,
		Mode:      -1,
		Type:      "file",
		WriteMode: "overwrite",
	})
	closeErr := image.Close()
	if fileErr != nil {
		return fmt.Errorf("cannot stage pinned Kanidm image in guest: %w", fileErr)
	}
	if closeErr != nil {
		return fmt.Errorf("cannot close pinned Kanidm image: %w", closeErr)
	}
	if runErr = execGuestImport(ctx, projectServer, descriptor.Instance, remoteImage, out, errOut); runErr != nil {
		return runErr
	}
	if runErr = projectServer.DeleteInstanceFile(descriptor.Instance, remoteImage); runErr != nil {
		return fmt.Errorf("cannot remove temporary guest image: %w", runErr)
	}
	imageStaged = false

	secretBytes, err := readGuestFile(projectServer, descriptor.Instance, "/srv/secrets/runtime-secrets.yaml")
	if err != nil {
		return errors.New("unable to read staged runtime secrets from guest")
	}
	namespaces, err := SecretNamespaces(ctx, tools, secretBytes)
	if err != nil {
		return err
	}
	if runErr = tools.ApplyFile(ctx, manifests.file("namespaces.yaml"), fieldManager); runErr != nil {
		return runErr
	}
	for _, namespace := range namespaces {
		create, cancel := context.WithTimeout(ctx, 60*time.Second)
		namespaceYAML, createErr := tools.RunKubectl(create, "create", "namespace", namespace, "--dry-run=client", "-o", "yaml")
		cancel()
		if createErr != nil {
			return fmt.Errorf("cannot ensure secret namespace %s", namespace)
		}
		if runErr = tools.ApplyInput(ctx, namespaceYAML, "homelab-runtime-secrets", false); runErr != nil {
			return fmt.Errorf("cannot ensure secret namespace %s", namespace)
		}
	}
	if runErr = tools.ApplyInput(ctx, secretBytes, "homelab-runtime-secrets", true); runErr != nil {
		return errors.New("cannot apply staged runtime secrets")
	}
	if runErr = runBootstrap(ctx, tools.Env, bootstrapPath, "--fresh-cluster", out, errOut); runErr != nil {
		return runErr
	}
	if runErr = runBootstrap(ctx, tools.Env, bootstrapPath, "--check-ready", out, errOut); runErr != nil {
		return runErr
	}
	if runErr = tools.ApplyFile(ctx, manifests.file("root.yaml"), fieldManager); runErr != nil {
		return runErr
	}
	fmt.Fprintln(out, "Argo seed is ready and the canonical root Application was applied. Verify child synchronization before application acceptance.")
	return runErr
}

func loadDescriptor(path string) (descriptor, error) {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return descriptor{}, fmt.Errorf("cannot resolve descriptor: %s", path)
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.Mode().IsRegular() {
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
		return descriptor{}, errors.New("cannot read descriptor")
	}
	defer file.Close()
	var object map[string]any
	decoder := json.NewDecoder(file)
	if err := decoder.Decode(&object); err != nil || object == nil {
		return descriptor{}, errors.New("descriptor must be a JSON object")
	}
	get := func(key string) (string, error) {
		value, ok := object[key].(string)
		if !ok || strings.TrimSpace(value) == "" {
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
	return descriptor{Project: project, Instance: instance, Address: address, Path: resolved}, nil
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
		return err
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
			return inspect.Err()
		}
		return err
	}
	return nil
}

func acquireKubeconfig(ctx context.Context, tools *Tools, server incus.InstanceServer, target descriptor, kubePath string) error {
	reader, _, err := server.GetInstanceFile(target.Instance, "/etc/rancher/k3s/k3s.yaml")
	if err != nil {
		return errors.New("cannot acquire fresh kubeconfig from selected guest")
	}
	raw, err := ReadBytes(reader)
	if err != nil {
		return errors.New("cannot acquire fresh kubeconfig from selected guest")
	}
	parse, cancel := context.WithTimeout(ctx, 30*time.Second)
	encoded, err := tools.RunYQInput(parse, raw, "-o=json", "-N", ".", "-")
	cancel()
	if err != nil {
		return errors.New("guest kubeconfig is invalid")
	}
	output, err := buildHostKubeconfig(encoded, "https://"+target.Address+":6443")
	if err != nil {
		return err
	}
	if err := writePrivateFile(kubePath, output); err != nil {
		return errors.New("cannot store fresh kubeconfig")
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
	if err != nil || info.Mode().Perm() != 0o600 {
		return errors.New("temporary file is not root-private")
	}
	return nil
}

func verifyNodePlacement(ctx context.Context, tools *Tools, manifests Manifests, target descriptor) error {
	inspect, cancel := context.WithTimeout(ctx, 30*time.Second)
	output, err := tools.RunKubectl(inspect, "get", "node", target.Instance, "-o", "json", requestTimeout(25*time.Second))
	cancel()
	if err != nil {
		return fmt.Errorf("Kubernetes target node %s is missing", target.Instance)
	}
	var node map[string]any
	if err := jsonDecoder(output).Decode(&node); err != nil {
		return fmt.Errorf("Kubernetes target node %s is missing", target.Instance)
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

func ensureStagedSecrets(ctx context.Context, server incus.InstanceServer, target descriptor) error {
	check, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	if err := incusops.Exec(check, server, target.Instance, []string{"test", "-s", "/srv/secrets/runtime-secrets.yaml"}, nil, io.Discard, io.Discard); err != nil {
		return errors.New("existing staged runtime secrets are missing from the guest")
	}
	return nil
}

func readGuestFile(server incus.InstanceServer, instance, path string) ([]byte, error) {
	reader, _, err := server.GetInstanceFile(instance, path)
	if err != nil {
		return nil, err
	}
	return ReadBytes(reader)
}

func execGuestImport(ctx context.Context, server incus.InstanceServer, instance, image string, out, errOut io.Writer) error {
	importCtx, cancel := context.WithTimeout(ctx, 30*time.Minute)
	defer cancel()
	if err := incusops.Exec(importCtx, server, instance, []string{"k3s", "ctr", "images", "import", "--local", "--snapshotter", "overlayfs", image}, nil, out, errOut); err != nil {
		return errors.New("cannot import pinned Kanidm provisioning image")
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
		return fmt.Errorf("bootstrap %s failed", mode)
	}
	return nil
}
