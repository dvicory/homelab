/**
 * Stable machine-readable reason codes (V3 §13.1, §17).
 *
 * Every denial, failure, and state-loss report carries one of these so the
 * gateway and audit consumers can react without string matching. Codes are
 * namespaced by subsystem and never recycled.
 */
export const REASONS = {
  // protocol
  PROTOCOL_VERSION: "protocol.unsupported_version",
  PROTOCOL_FRAME: "protocol.malformed_frame",
  PROTOCOL_OVERSIZED: "protocol.frame_too_large",
  PROTOCOL_UNKNOWN_OP: "protocol.unknown_operation",
  PROTOCOL_UNKNOWN_FIELD: "protocol.unknown_field",
  PROTOCOL_DUPLICATE_ID: "protocol.duplicate_request_id",
  PROTOCOL_BAD_STATE: "protocol.invalid_state",
  PROTOCOL_BAD_BASE64: "protocol.invalid_base64",

  // policy
  POLICY_MISSING: "policy.missing",
  POLICY_INVALID: "policy.invalid",
  POLICY_VERSION: "policy.unsupported_version",
  POLICY_UNKNOWN_FIELD: "policy.unknown_field",
  POLICY_UNKNOWN_BUNDLE: "policy.unknown_bundle",
  POLICY_UNKNOWN_TEMPLATE: "policy.unknown_template",
  POLICY_UNKNOWN_ASSET: "policy.unknown_asset",
  POLICY_UNKNOWN_ADAPTER: "policy.unknown_adapter",
  POLICY_PAIR_FORBIDDEN: "policy.asset_template_forbidden",
  POLICY_ATTENUATION: "policy.attenuation_violation",

  // network
  NET_HOST_DENIED: "network.host_denied",
  NET_INTERNAL_DENIED: "network.internal_address_denied",
  NET_PROTOCOL_DENIED: "network.protocol_denied",
  NET_PORT_DENIED: "network.port_denied",
  NET_REDIRECT_DENIED: "network.redirect_denied",

  // credentials
  CREDENTIAL_INACTIVE: "credential.capability_inactive",
  CREDENTIAL_TARGET: "credential.target_forbidden",
  CREDENTIAL_ACTION: "credential.action_forbidden",
  CREDENTIAL_UNSUPPORTED: "credential.unsupported_scheme",
  CREDENTIAL_REPLAY: "credential.placeholder_replay",

  // lifecycle
  ENV_EXISTS: "lifecycle.environment_exists",
  ENV_NOT_FOUND: "lifecycle.environment_not_found",
  ENV_TOMBSTONED: "lifecycle.environment_tombstoned",
  ENV_BAD_STATE: "lifecycle.invalid_state",
  STALE_GENERATION: "process.stale_generation",
  PROC_NOT_FOUND: "process.not_found",
  ADMISSION_VMS: "admission.max_vms",
  ADMISSION_STARTS: "admission.start_rate",

  // resources
  RESOURCE_CGROUP: "resource.cgroup_failure",
  RESOURCE_KVM: "resource.kvm_unavailable",
  RESOURCE_OUTPUT: "resource.output_limit",
  RESOURCE_INPUT: "resource.input_limit",
  RESOURCE_ENV: "resource.env_limit",

  // fs
  FS_PATH: "fs.path_forbidden",
  FS_ESCAPE: "fs.mount_escape",
  FS_NOT_FOUND: "fs.not_found",
  FS_EXISTS: "fs.exists",
  FS_TYPE: "fs.unsafe_type",
  FS_LIMIT: "fs.size_limit",

  // grants
  GRANT_UNKNOWN: "grant.unknown_capability",
  GRANT_NOT_GRANTABLE: "grant.not_grantable",
  GRANT_SCOPE: "grant.scope_forbidden",
  GRANT_EXPIRED: "grant.expired",
  GRANT_POLICY_GEN: "grant.stale_policy_generation",

  // internal
  INTERNAL: "internal.error",
  SHUTTING_DOWN: "broker.shutting_down",
} as const;

export type ReasonCode = (typeof REASONS)[keyof typeof REASONS];

/** Error carrying a stable reason code and bounded, log-safe metadata. */
export class BrokerError extends Error {
  readonly reason: ReasonCode;
  readonly details: Record<string, unknown>;

  constructor(reason: ReasonCode, message: string, details: Record<string, unknown> = {}) {
    super(message);
    this.name = "BrokerError";
    this.reason = reason;
    this.details = details;
  }

  /** Structured denial payload for the gateway (V3 §17). Never includes
   * command bodies, headers, URLs with queries, placeholders, or secrets. */
  toTelemetry(): Record<string, unknown> {
    return { reason: this.reason, ...this.details };
  }
}

export function asBrokerError(err: unknown, fallback: string): BrokerError {
  if (err instanceof BrokerError) return err;
  const message = err instanceof Error ? err.message : String(err);
  return new BrokerError(REASONS.INTERNAL, `${fallback}: ${message}`);
}
