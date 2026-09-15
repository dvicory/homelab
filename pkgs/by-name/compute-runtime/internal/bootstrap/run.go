package bootstrap

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"time"
)

const fieldManager = "argocd-controller"

const usageText = `Usage:
  household-bootstrap --status
  household-bootstrap --fresh-cluster
  household-bootstrap --retry-jobs
  household-bootstrap --check-ready

--status         Read-only report of declared controllers and bootstrap Jobs.
--fresh-cluster  Apply the Argo namespace, CRDs and controllers without pruning or Git.
--retry-jobs     Recreate only declared terminal Failed hook Jobs.
--check-ready    Block until the declared node, controllers and Jobs are ready.
`

type UsageError struct {
	Code int
	Text string
}

func (e *UsageError) Error() string { return e.Text }

func Run(ctx context.Context, args []string, out, errOut io.Writer) error {
	if len(args) == 1 && args[0] == "--help" {
		_, _ = io.WriteString(out, usageText)
		return nil
	}
	if len(args) != 1 {
		_, _ = io.WriteString(errOut, usageText)
		return &UsageError{Code: 2, Text: "exactly one bootstrap mode is required"}
	}

	manifests, err := OpenManifests(os.Getenv("HOUSEHOLD_BOOTSTRAP_MANIFESTS"))
	if err != nil {
		return err
	}
	tools := NewTools(out, errOut)
	switch args[0] {
	case "--status":
		return Status(ctx, tools, manifests)
	case "--fresh-cluster":
		return FreshCluster(ctx, tools, manifests)
	case "--retry-jobs":
		return RetryJobs(ctx, tools, manifests)
	case "--check-ready":
		return CheckReady(ctx, tools, manifests)
	default:
		_, _ = io.WriteString(errOut, usageText)
		return &UsageError{Code: 2, Text: "unknown bootstrap mode"}
	}
}

func FreshCluster(ctx context.Context, tools *Tools, manifests Manifests) error {
	if err := manifests.require("namespaces.yaml", "crds.yaml", "controllers.yaml", "pre-install.yaml", "pre-install-jobs.yaml"); err != nil {
		return err
	}
	if err := tools.CheckArgo(ctx); err != nil {
		return err
	}
	if err := tools.ApplyFile(ctx, manifests.file("namespaces.yaml"), fieldManager); err != nil {
		return err
	}
	if err := tools.ApplyFile(ctx, manifests.file("crds.yaml"), fieldManager); err != nil {
		return err
	}

	deadline := time.Now().Add(180 * time.Second)
	for {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return errors.New("timed out waiting for all Argo CRDs to become Established")
		}
		request := remaining
		if request > 25*time.Second {
			request = 25 * time.Second
		}
		inspect, cancel := context.WithTimeout(ctx, request)
		objects, err := tools.RunKubectl(inspect, "get", "--request-timeout="+requestTimeoutValue(request), "-f", manifests.file("crds.yaml"), "-o", "json")
		cancel()
		if err != nil {
			return err
		}
		established, err := allEstablished(objects)
		if err != nil {
			return fmt.Errorf("cannot inspect Argo CRD status: %w", err)
		}
		if established {
			break
		}
		if err := sleepContext(ctx, time.Second); err != nil {
			return err
		}
	}
	fmt.Fprintln(tools.Out, "All Argo CRDs are established.")

	if manifests.present("pre-install.yaml") {
		if err := tools.ApplyFile(ctx, manifests.file("pre-install.yaml"), fieldManager); err != nil {
			return err
		}
		if manifests.present("pre-install-jobs.yaml") {
			wait, cancel := context.WithTimeout(ctx, 610*time.Second)
			err := tools.RunKubectlPrint(wait, "wait", "--for=condition=Complete", "--timeout=600s", "-f", manifests.file("pre-install-jobs.yaml"))
			cancel()
			if err != nil {
				return err
			}
		}
	}

	for attempt := 1; attempt <= 60; attempt++ {
		apply, cancel := context.WithTimeout(ctx, 35*time.Second)
		err := tools.ApplyFile(apply, manifests.file("controllers.yaml"), fieldManager)
		cancel()
		if err == nil {
			fmt.Fprintln(tools.Out, "Argo seed applied, not yet ready. Run household-bootstrap --check-ready, then apply the canonical root Application.")
			return nil
		}
		if attempt == 60 {
			break
		}
		if err := sleepContext(ctx, 5*time.Second); err != nil {
			return err
		}
	}
	return errors.New("Argo seed failed to converge")
}

func requestTimeoutValue(duration time.Duration) string {
	seconds := int64(duration / time.Second)
	if seconds < 1 {
		seconds = 1
	}
	return fmt.Sprintf("%ds", seconds)
}

type retryTarget struct {
	Namespace string
	Name      string
}

func retryableJob(object map[string]any) (bool, error) {
	if object == nil {
		return false, errors.New("Job is missing")
	}
	active, valid := intField(mapField(object, "status"), "active", 0)
	if !valid || active != 0 {
		return false, errors.New("Job has active pods or unknown activity")
	}
	_, failed := conditionTrue(object, "Failed")
	_, complete := conditionTrue(object, "Complete")
	if failed == complete {
		return false, errors.New("Job has no unambiguous terminal condition")
	}
	if failed && !hookPolicy(stringField(mapField(mapField(object, "metadata"), "annotations"), "argocd.argoproj.io/hook-delete-policy"), "BeforeHookCreation") {
		return false, errors.New("failed Job lacks BeforeHookCreation")
	}
	return failed, nil
}

func RetryJobs(ctx context.Context, tools *Tools, manifests Manifests) error {
	if err := manifests.require("jobs.yaml"); err != nil {
		return err
	}
	if err := tools.CheckArgo(ctx); err != nil {
		return err
	}
	declared, err := manifests.resources(ctx, tools, "jobs.yaml")
	if err != nil {
		return err
	}
	var targets []retryTarget
	for _, resource := range declared {
		if resource.Kind != "Job" || !hookPolicy(annotation(resource, "argocd.argoproj.io/hook-delete-policy"), "BeforeHookCreation") {
			continue
		}
		object, err := getJob(ctx, tools, resource.Namespace, resource.Name)
		if err != nil {
			return fmt.Errorf("unable to inspect declared Job %s/%s; refusing retry", resource.Namespace, resource.Name)
		}
		retry, err := retryableJob(object)
		if err != nil {
			return fmt.Errorf("declared Job %s/%s: %w; refusing retry", resource.Namespace, resource.Name, err)
		}
		if retry {
			targets = append(targets, retryTarget{Namespace: resource.Namespace, Name: resource.Name})
		}
	}
	if len(targets) == 0 {
		fmt.Fprintln(tools.Out, "No declared terminal Failed Jobs require retry.")
		return nil
	}

	for _, target := range targets {
		if err := tools.CheckArgo(ctx); err != nil {
			return err
		}
		object, err := getJob(ctx, tools, target.Namespace, target.Name)
		if err != nil {
			return fmt.Errorf("unable to recheck declared Job %s/%s; refusing retry", target.Namespace, target.Name)
		}
		retry, err := retryableJob(object)
		if err != nil || !retry {
			return fmt.Errorf("declared Job %s/%s is no longer a retryable terminal Failed Job; refusing retry", target.Namespace, target.Name)
		}
		selected, err := selectedJob(ctx, tools, manifests, target.Namespace, target.Name)
		if err != nil || len(bytes.TrimSpace(selected)) == 0 {
			return fmt.Errorf("declared Job %s/%s could not be selected; refusing retry", target.Namespace, target.Name)
		}
		fmt.Fprintf(tools.Out, "Retrying terminal Failed Job %s/%s.\n", target.Namespace, target.Name)
		remove, cancel := context.WithTimeout(ctx, 150*time.Second)
		_, err = tools.RunKubectl(remove, "delete", "job", target.Name, "--namespace", target.Namespace, "--cascade=foreground", "--wait=true", "--timeout=120s")
		cancel()
		if err != nil {
			return err
		}
		if err := tools.ApplyInput(ctx, selected, fieldManager, false); err != nil {
			return err
		}
	}
	fmt.Fprintln(tools.Out, "Declared terminal Failed Jobs were recreated; run household-bootstrap --status or --check-ready.")
	return nil
}

func getJob(ctx context.Context, tools *Tools, namespace, name string) (map[string]any, error) {
	inspect, cancel := context.WithTimeout(ctx, 30*time.Second)
	output, err := tools.RunKubectl(inspect, "get", "job", name, "--namespace", namespace, "--ignore-not-found", "-o", "json", requestTimeout(25*time.Second))
	cancel()
	if err != nil {
		return nil, err
	}
	if len(bytes.TrimSpace(output)) == 0 {
		return nil, nil
	}
	var object map[string]any
	decoder := jsonDecoder(output)
	if err := decoder.Decode(&object); err != nil {
		return nil, err
	}
	return object, nil
}

func CheckReady(ctx context.Context, tools *Tools, manifests Manifests) error {
	if err := manifests.require("readiness.yaml", "operator-readiness.yaml", "persistent-jobs.yaml"); err != nil {
		return err
	}
	fmt.Fprintln(tools.Err, "Readiness prerequisites: stage all declared runtime credentials through agenix.")
	fmt.Fprintln(tools.Err, "This command checks the replacement node and Argo seed only. Native")
	fmt.Fprintln(tools.Err, "first-run enrollment and application acceptance remain separate checks.")

	wait, cancel := context.WithTimeout(ctx, 190*time.Second)
	err := tools.RunKubectlPrint(wait, "wait", "--for=condition=Ready", "nodes", "--all", "--timeout=180s")
	cancel()
	if err != nil {
		return err
	}
	wait, cancel = context.WithTimeout(ctx, 610*time.Second)
	err = tools.RunKubectlPrint(wait, "rollout", "status", "--timeout=600s", "-f", manifests.file("readiness.yaml"))
	cancel()
	if err != nil {
		return err
	}
	if manifests.present("operator-readiness.yaml") {
		wait, cancel = context.WithTimeout(ctx, 610*time.Second)
		err = tools.RunKubectlPrint(wait, "wait", "--for=condition=Available", "--timeout=600s", "-f", manifests.file("operator-readiness.yaml"))
		cancel()
		if err != nil {
			return err
		}
	}
	if manifests.present("persistent-jobs.yaml") {
		wait, cancel = context.WithTimeout(ctx, 610*time.Second)
		err = tools.RunKubectlPrint(wait, "wait", "--for=condition=Complete", "--timeout=600s", "-f", manifests.file("persistent-jobs.yaml"))
		cancel()
		if err != nil {
			return err
		}
	}
	fmt.Fprintln(tools.Out, "Replacement node and Argo seed are ready. Apply the canonical root Application next.")
	return nil
}

func jsonDecoder(data []byte) *json.Decoder {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	return decoder
}

func ReadBytes(reader io.ReadCloser) ([]byte, error) {
	defer reader.Close()
	return io.ReadAll(reader)
}
