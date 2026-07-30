import { Data, Schema } from "effect";

export const Reason = Schema.Literal(
  "request.invalid",
  "inputs.conflict",
  "inputs.producer_not_ready",
  "inputs.limit",
  "inputs.cross_board",
  "inputs.not_found",
  "policy.denied",
  "policy.indeterminate",
  "policy.approval_required",
  "environment.not_found",
  "environment.tombstoned",
  "environment.stale_generation",
  "authority.conflict",
  "workspace.not_found",
  "workspace.conflict",
  "workspace.stale_lease",
  "workspace.path_forbidden",
  "workspace.failed",
  "run_activation.not_found",
  "run_activation.stale",
  "run_activation.conflict",
  "handoff.not_found",
  "handoff.conflict",
  "handoff.invalid_state",
  "handoff.failed",
  "handoff.reclaim_failed",
  "project_source.not_found",
  "project_source.stale",
  "project_source.conflict",
  "project_source.failed",
  "project_materialization.not_found",
  "project_materialization.conflict",
  "project_materialization.invalid_state",
  "project_materialization.failed",
  "project_materialization.limit",
  "capability.invalid",
  "capability.unsupported",
  "network.resolution_failed",
  "network.address_forbidden",
  "network.capability_inactive",
  "network.protocol_unsupported",
  "network.rebinding_denied",
  "approval.request_suppressed",
  "approval.request_not_found",
  "approval.invalid_state",
  "grant.not_found",
  "environment.capacity",
  "runtime.start_failed",
  "runtime.operation_failed",
  "runtime.terminated",
  "exec.invalid",
  "exec.timeout",
  "exec.output_limit",
  "fs.path_forbidden",
  "fs.not_found",
  "fs.exists",
  "fs.unsafe_type",
  "fs.size_limit",
  "registry.failed",
  "internal.error"
);

export type Reason = typeof Reason.Type;

export class BrokerError extends Data.TaggedError("BrokerError")<{
  readonly reason: Reason;
  readonly message: string;
  readonly details?: Readonly<Record<string, unknown>>;
}> {}

export const brokerError = (
  reason: Reason,
  message: string,
  details?: Readonly<Record<string, unknown>>,
): BrokerError => new BrokerError(details === undefined ? { reason, message } : { reason, message, details });

export const asBrokerError = (error: unknown): BrokerError =>
  error instanceof BrokerError
    ? error
    : brokerError("internal.error", "internal broker failure", {
        error: error instanceof Error ? error.message : String(error),
      });

export const statusFor = (error: BrokerError): number => {
  switch (error.reason) {
    case "request.invalid":
    case "exec.invalid":
    case "fs.path_forbidden":
    case "capability.invalid":
    case "capability.unsupported":
    case "workspace.path_forbidden":
      return 400;
    case "exec.timeout":
      return 408;
    case "policy.denied":
    case "policy.approval_required":
    case "network.address_forbidden":
    case "network.capability_inactive":
    case "network.protocol_unsupported":
    case "network.rebinding_denied":
      return 403;
    case "environment.not_found":
    case "fs.not_found":
    case "approval.request_not_found":
    case "grant.not_found":
    case "workspace.not_found":
    case "run_activation.not_found":
    case "handoff.not_found":
    case "project_source.not_found":
    case "project_materialization.not_found":
      return 404;
    case "environment.tombstoned":
    case "environment.stale_generation":
    case "fs.exists":
    case "authority.conflict":
    case "approval.invalid_state":
    case "workspace.conflict":
    case "workspace.stale_lease":
    case "run_activation.stale":
    case "run_activation.conflict":
    case "handoff.conflict":
    case "handoff.invalid_state":
    case "project_source.stale":
    case "project_source.conflict":
    case "project_materialization.conflict":
    case "project_materialization.invalid_state":
    case "inputs.conflict":
    case "inputs.producer_not_ready":
    case "inputs.cross_board":
    case "inputs.not_found":
      return 409;
    case "inputs.limit":
      return 429;
    case "environment.capacity":
    case "exec.output_limit":
    case "fs.size_limit":
    case "approval.request_suppressed":
    case "project_materialization.limit":
      return 429;
    case "network.resolution_failed":
      return 502;
    case "policy.indeterminate":
    case "runtime.start_failed":
    case "runtime.operation_failed":
    case "runtime.terminated":
    case "registry.failed":
    case "fs.unsafe_type":
    case "internal.error":
    case "workspace.failed":
    case "handoff.failed":
    case "project_source.failed":
    case "project_materialization.failed":
    case "handoff.reclaim_failed":
      return 500;
  }
};

export interface PublicProblem {
  readonly type: `urn:agent-x:gondolin-broker:error:${Reason}`;
  readonly title: Reason;
  readonly status: number;
  readonly detail: string;
  readonly reason: Reason;
  readonly details?: Readonly<Record<string, unknown>>;
}

const exposesDetails = (status: number): boolean => status < 500;

/** RFC 9457 Problem Details with stable broker-specific extension members. */
export const publicProblem = (error: BrokerError): PublicProblem => {
  const status = statusFor(error);
  return {
    type: `urn:agent-x:gondolin-broker:error:${error.reason}`,
    title: error.reason,
    status,
    detail: error.message,
    reason: error.reason,
    ...(error.details === undefined || !exposesDetails(status) ? {} : { details: error.details }),
  };
};

/** Stream failures occur after HTTP headers, so encode only the stable public fields as an event. */
export const publicErrorEvent = (error: BrokerError) => ({
  type: "error" as const,
  reason: error.reason,
  message: error.message,
  ...(error.details === undefined || !exposesDetails(statusFor(error)) ? {} : { details: error.details }),
});
