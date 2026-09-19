use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::PathBuf;

pub const SCHEMA_VERSION: u32 = 1;
pub const PROTOCOL_VERSION: u32 = 1;

fn protocol_version() -> u32 {
    PROTOCOL_VERSION
}

fn timeout_seconds() -> u64 {
    30
}

fn max_response_bytes() -> usize {
    1_048_576
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Document {
    pub schema_version: u32,
    pub kind: String,
    #[serde(default)]
    pub fixture_only: bool,
    #[serde(default)]
    pub states: Vec<State>,
    #[serde(default)]
    pub scratch_destinations: BTreeMap<String, ScratchDestination>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    pub state_id: String,
    pub mode: String,
    #[serde(default)]
    pub operational: bool,
    #[serde(default)]
    pub slot_id: Option<String>,
    #[serde(default)]
    pub policy_id: Option<String>,
    #[serde(default)]
    pub realization: Option<Realization>,
    #[serde(default)]
    pub routes: Vec<Route>,
    #[serde(default)]
    pub issues: Vec<Value>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Realization {
    pub kind: String,
    pub owner: Value,
    pub locator: Value,
    #[serde(default)]
    pub path: Option<PathBuf>,
    #[serde(default)]
    pub boundary: Value,
    #[serde(default)]
    pub access: Vec<Value>,
    #[serde(default)]
    pub physical_backing: Option<Value>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Route {
    pub route_id: String,
    pub obligation_id: String,
    #[serde(default)]
    pub target: Option<Target>,
    #[serde(default)]
    pub integration: Option<Integration>,
    #[serde(default)]
    pub operation: Option<String>,
    #[serde(default)]
    pub owner_config: Option<Value>,
    #[serde(default)]
    pub eligible_integrations: Vec<String>,
    #[serde(default)]
    pub semantic_requirements: Option<Value>,
    #[serde(default)]
    pub guaranteed_consistency: Option<String>,
    #[serde(default)]
    pub payload_representation: Option<String>,
    #[serde(default)]
    pub native_point_representations: Vec<String>,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub issues: Vec<Value>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    pub target_id: String,
    #[serde(default)]
    pub failure_domain: BTreeMap<String, String>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Integration {
    pub integration_id: String,
    pub owner: String,
    pub adapter: PathBuf,
    #[serde(default = "protocol_version")]
    pub protocol_version: u32,
    #[serde(default = "timeout_seconds")]
    pub timeout_seconds: u64,
    #[serde(default = "max_response_bytes")]
    pub max_response_bytes: usize,
    #[serde(default)]
    pub fixture_only: bool,
    #[serde(default)]
    pub operations: Vec<String>,
    #[serde(default)]
    pub fidelity_guarantees: Vec<String>,
    #[serde(default)]
    pub guaranteed_consistency: Option<String>,
    #[serde(default)]
    pub native_point_representations: Vec<String>,
    #[serde(default)]
    pub payload_representation: Option<String>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScratchDestination {
    pub native_parent: String,
    pub mount_root: PathBuf,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum EvidenceState {
    Configured,
    Observed,
    Captured,
    Retained,
    Restored,
    Verified,
    Failed,
    Unknown,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct NativePoint {
    pub state_id: String,
    pub route_id: String,
    pub target_id: String,
    pub owner: String,
    pub native_id: String,
    #[serde(default)]
    pub capture_id: Option<String>,
    #[serde(default)]
    pub captured_at: Option<String>,
    #[serde(default)]
    pub retained_at: Option<String>,
    pub completion: String,
    pub consistency: String,
    pub fidelity: Vec<String>,
    pub scope: Value,
    pub native_representation: Value,
    #[serde(default)]
    pub payload_representation: Option<Value>,
    #[serde(default)]
    pub verification: Vec<Value>,
    #[serde(default)]
    pub producer_provenance: BTreeMap<String, Value>,
    #[serde(default)]
    pub owner_provenance: Value,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AdapterVersion {
    pub protocol_version: u32,
    pub implementation: String,
    pub implementation_version: String,
    #[serde(default)]
    pub fixture_only: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DescribeResult {
    pub kind: String,
    pub adapter_version: AdapterVersion,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(default)]
    pub explicit_scratch: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusResult {
    pub kind: String,
    pub evidence: EvidenceState,
    pub catalog_observed: bool,
    pub point_count: usize,
    #[serde(default)]
    pub details: Value,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PointsResult {
    pub kind: String,
    #[serde(default)]
    pub points: Vec<NativePoint>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunResult {
    pub kind: String,
    pub evidence: EvidenceState,
    #[serde(default)]
    pub details: Value,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RestoreResult {
    pub kind: String,
    #[serde(default)]
    pub owner_receipt: Value,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VerifyResult {
    pub kind: String,
    pub verified: bool,
    pub evidence: EvidenceState,
    pub scope: String,
    #[serde(default)]
    pub details: Value,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DestinationRequest {
    pub capability_ref: String,
    pub new_name: String,
    pub path: PathBuf,
    pub native_locator: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProtocolRequest {
    pub protocol_version: u32,
    pub request_id: String,
    pub operation: String,
    pub state_id: String,
    pub route_id: String,
    pub target_id: String,
    #[serde(default)]
    pub point: Option<NativePoint>,
    #[serde(default)]
    pub destination: Option<DestinationRequest>,
    #[serde(default)]
    pub owner_payload: Value,
    #[serde(default)]
    pub receipt: Option<RestoreReceipt>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AdapterError {
    pub code: String,
    pub message: String,
    #[serde(default)]
    pub details: Value,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProtocolResponse {
    pub protocol_version: u32,
    pub request_id: String,
    #[serde(default)]
    pub result: Option<Value>,
    #[serde(default)]
    pub error: Option<AdapterError>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RestoreReceipt {
    pub schema_version: u32,
    pub state_id: String,
    pub route_id: String,
    pub target_id: String,
    pub integration_id: String,
    pub adapter_version: AdapterVersion,
    pub point: NativePoint,
    pub destination: DestinationRequest,
    #[serde(default)]
    pub owner_receipt: Value,
    #[serde(default)]
    pub producer_provenance: BTreeMap<String, Value>,
}
