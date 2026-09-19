use crate::error::{PreserveError, Result};
use crate::model::{
    AdapterVersion, DescribeResult, DestinationRequest, Document, EvidenceState, Integration,
    NativePoint, PointsResult, ProtocolRequest, RestoreReceipt, RestoreResult, Route, RunResult,
    ScratchDestination, State, StatusResult, VerifyResult, PROTOCOL_VERSION, SCHEMA_VERSION,
};
use crate::process::{invoke_adapter, request_id};
use crate::safety::preflight_destination;
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::Path;

const MAX_DOCUMENT_BYTES: usize = 16_777_216;
const BASELINE_OPERATIONS: [&str; 3] = ["describe", "status", "points"];
const CONSISTENCIES: [&str; 5] = ["live", "crash", "filesystem", "application", "database"];

fn consistency_satisfies(achieved: &str, required: &str) -> bool {
    CONSISTENCIES.contains(&achieved)
        && CONSISTENCIES.contains(&required)
        && (required == "live"
            || achieved == required
            || (required == "crash"
                && matches!(achieved, "filesystem" | "application" | "database")))
}

fn missing_baseline(operations: &[String]) -> Vec<&'static str> {
    BASELINE_OPERATIONS
        .iter()
        .filter(|operation| !operations.iter().any(|value| value == *operation))
        .copied()
        .collect()
}

pub fn load_document(path: &Path) -> Result<Document> {
    let bytes = fs::read(path).map_err(|error| {
        PreserveError::new(
            "document-read",
            format!("could not read {}: {error}", path.display()),
        )
    })?;
    if bytes.len() > MAX_DOCUMENT_BYTES {
        return Err(PreserveError::new(
            "document-too-large",
            format!("document exceeded {MAX_DOCUMENT_BYTES} bytes"),
        ));
    }
    let document: Document = serde_json::from_slice(&bytes).map_err(|error| {
        PreserveError::new(
            "document-json",
            format!("could not parse document: {error}"),
        )
    })?;
    validate_document(&document)?;
    Ok(document)
}

pub fn load_receipt(path: &Path) -> Result<RestoreReceipt> {
    let bytes = fs::read(path).map_err(|error| {
        PreserveError::new(
            "receipt-read",
            format!("could not read {}: {error}", path.display()),
        )
    })?;
    serde_json::from_slice(&bytes)
        .map_err(|error| PreserveError::new("receipt-json", format!("invalid receipt: {error}")))
}

pub fn validate_document(document: &Document) -> Result<()> {
    if document.schema_version != SCHEMA_VERSION {
        return Err(PreserveError::new(
            "unsupported-schema-version",
            format!(
                "document schema version {} is unsupported; expected {}",
                document.schema_version, SCHEMA_VERSION
            ),
        ));
    }
    if document.kind != "desired-inventory" && document.kind != "executable-plan" {
        return Err(PreserveError::new(
            "unsupported-document-kind",
            format!("unsupported document kind '{}'", document.kind),
        ));
    }

    let mut states = BTreeSet::new();
    for state in &document.states {
        if !states.insert(&state.state_id) {
            return Err(PreserveError::new(
                "duplicate-state",
                format!("state '{}' appears more than once", state.state_id),
            ));
        }
        let mut routes = BTreeSet::new();
        for route in &state.routes {
            if !routes.insert(&route.route_id) {
                return Err(PreserveError::new(
                    "duplicate-route",
                    format!(
                        "state '{}' contains route '{}' more than once",
                        state.state_id, route.route_id
                    ),
                ));
            }
            if document.kind == "executable-plan" {
                if let Some(target) = &route.target {
                    if target.failure_domain.is_empty() {
                        return Err(PreserveError::new(
                            "empty-failure-domain",
                            format!(
                                "state '{}' route '{}' target '{}' declares no failure domain",
                                state.state_id, route.route_id, target.target_id
                            ),
                        ));
                    }
                }
                if let Some(integration) = &route.integration {
                    if integration.fixture_only && !document.fixture_only {
                        return Err(PreserveError::new(
                            "fixture-only-integration",
                            format!(
                                "state '{}' route '{}' selects fixture-only integration '{}' in a non-fixture document",
                                state.state_id, route.route_id, integration.integration_id
                            ),
                        ));
                    }
                    if integration.native_point_representations.is_empty() {
                        return Err(PreserveError::new(
                            "missing-native-point-representations",
                            format!(
                                "state '{}' route '{}' integration '{}' advertises no native point representations",
                                state.state_id, route.route_id, integration.integration_id
                            ),
                        ));
                    }
                    let missing = missing_baseline(&integration.operations);
                    if !missing.is_empty() {
                        return Err(PreserveError::new(
                            "unsupported-baseline-operation",
                            format!(
                                "state '{}' route '{}' integration '{}' does not declare baseline operations {:?}",
                                state.state_id, route.route_id, integration.integration_id, missing
                            ),
                        ));
                    }
                    route_semantics(state, route)?;
                    route_guaranteed_consistency(state, route)?;
                }
            }
        }
    }
    Ok(())
}

fn state<'a>(document: &'a Document, state_id: &str) -> Result<&'a State> {
    document
        .states
        .iter()
        .find(|state| state.state_id == state_id)
        .ok_or_else(|| {
            PreserveError::new(
                "unknown-state",
                format!("state '{state_id}' is not declared"),
            )
        })
}

fn route<'a>(state: &'a State, route_id: &str) -> Result<&'a Route> {
    state
        .routes
        .iter()
        .find(|route| route.route_id == route_id)
        .ok_or_else(|| {
            PreserveError::new(
                "unknown-route",
                format!("state '{}' has no route '{route_id}'", state.state_id),
            )
            .context(&state.state_id, Some(route_id))
        })
}

fn executable_state<'a>(document: &'a Document, state_id: &str) -> Result<&'a State> {
    if document.kind != "executable-plan" {
        return Err(PreserveError::new(
            "plan-only-document",
            "data operations require an executable-plan document",
        )
        .context(state_id, None));
    }
    let state = state(document, state_id)?;
    if state.mode != "enabled" || !state.operational {
        return Err(PreserveError::new(
            "state-not-operational",
            format!("state '{state_id}' is not enabled and strictly resolved"),
        )
        .context(state_id, None));
    }
    Ok(state)
}

fn executable_route<'a>(state: &'a State, route_id: &str) -> Result<&'a Route> {
    let route = route(state, route_id)?;
    if route.status != "resolved" || route.target.is_none() || route.integration.is_none() {
        return Err(PreserveError::new(
            "route-not-operational",
            format!(
                "state '{}' route '{}' is not strictly resolved",
                state.state_id, route_id
            ),
        )
        .context(&state.state_id, Some(route_id)));
    }
    Ok(route)
}

fn parse_result<T: DeserializeOwned>(value: Value, expected_kind: &str) -> Result<T> {
    let kind = value.get("kind").and_then(Value::as_str);
    if kind != Some(expected_kind) {
        return Err(PreserveError::new(
            "unexpected-adapter-result",
            format!("adapter result kind was {kind:?}, expected '{expected_kind}'"),
        ));
    }
    serde_json::from_value(value).map_err(|error| {
        PreserveError::new(
            "invalid-adapter-result",
            format!("adapter returned an invalid {expected_kind} result: {error}"),
        )
    })
}

fn integration(route: &Route) -> Result<&Integration> {
    route.integration.as_ref().ok_or_else(|| {
        PreserveError::new("missing-integration", "route has no configured integration")
    })
}

fn request(
    state: &State,
    route: &Route,
    operation: &str,
    point: Option<NativePoint>,
    destination: Option<DestinationRequest>,
    receipt: Option<RestoreReceipt>,
) -> Result<ProtocolRequest> {
    let target = route.target.as_ref().ok_or_else(|| {
        PreserveError::new("missing-target", "route has no configured target")
            .context(&state.state_id, Some(&route.route_id))
    })?;
    Ok(ProtocolRequest {
        protocol_version: PROTOCOL_VERSION,
        request_id: request_id(),
        operation: operation.to_owned(),
        state_id: state.state_id.clone(),
        route_id: route.route_id.clone(),
        target_id: target.target_id.clone(),
        point,
        destination,
        owner_payload: route.owner_config.clone().unwrap_or(Value::Null),
        receipt,
    })
}

fn invoke(
    state: &State,
    route: &Route,
    operation: &str,
    point: Option<NativePoint>,
    destination: Option<DestinationRequest>,
    receipt: Option<RestoreReceipt>,
) -> Result<Value> {
    let request = request(state, route, operation, point, destination, receipt)?;
    invoke_adapter(integration(route)?, &request)
        .map_err(|error| error.context(&state.state_id, Some(&route.route_id)))
}

fn describe(state: &State, route: &Route) -> Result<DescribeResult> {
    let result = parse_result(
        invoke(state, route, "describe", None, None, None)?,
        "describe",
    )?;
    let result: DescribeResult = result;
    if result.adapter_version.protocol_version != PROTOCOL_VERSION {
        return Err(PreserveError::new(
            "incompatible-adapter-version",
            format!(
                "adapter '{}' reports protocol version {}, expected {}",
                result.adapter_version.implementation,
                result.adapter_version.protocol_version,
                PROTOCOL_VERSION
            ),
        )
        .context(&state.state_id, Some(&route.route_id)));
    }
    let missing = missing_baseline(&result.capabilities);
    if !missing.is_empty() {
        return Err(PreserveError::new(
            "unsupported-baseline-operation",
            format!(
                "adapter '{}' does not provide baseline operations {:?}",
                result.adapter_version.implementation, missing
            ),
        )
        .context(&state.state_id, Some(&route.route_id)));
    }
    let expected_fixture_only = integration(route)?.fixture_only;
    if result.adapter_version.fixture_only != expected_fixture_only {
        return Err(PreserveError::new(
            "fixture-mismatch",
            format!(
                "adapter '{}' reports fixtureOnly={}, but the manifest integration declares fixtureOnly={}",
                result.adapter_version.implementation,
                result.adapter_version.fixture_only,
                expected_fixture_only
            ),
        )
        .context(&state.state_id, Some(&route.route_id)));
    }
    Ok(result)
}

fn require_capability(
    state: &State,
    route: &Route,
    capability: &str,
    explicit_scratch: bool,
) -> Result<AdapterVersion> {
    let description = describe(state, route)?;
    if !description
        .capabilities
        .iter()
        .any(|value| value == capability)
    {
        return Err(PreserveError::new(
            "unsupported-operation",
            format!("configured adapter does not support '{capability}'"),
        )
        .context(&state.state_id, Some(&route.route_id)));
    }
    if explicit_scratch && !description.explicit_scratch {
        return Err(PreserveError::new(
            "unsafe-restore-capability",
            "configured adapter cannot enforce an explicit scratch destination",
        )
        .context(&state.state_id, Some(&route.route_id)));
    }
    Ok(description.adapter_version)
}

struct RouteSemantics<'a> {
    required_consistency: &'a str,
    route_required_consistency: Option<&'a str>,
    required_fidelity: Vec<&'a str>,
}

fn invalid_semantics(state: &State, route: &Route, detail: String) -> PreserveError {
    PreserveError::new("invalid-semantic-requirements", detail)
        .context(&state.state_id, Some(&route.route_id))
}

fn route_semantics<'a>(state: &State, route: &'a Route) -> Result<RouteSemantics<'a>> {
    let requirements = route
        .semantic_requirements
        .as_ref()
        .and_then(Value::as_object)
        .ok_or_else(|| {
            invalid_semantics(
                state,
                route,
                format!(
                    "state '{}' route '{}' does not declare a semanticRequirements object",
                    state.state_id, route.route_id
                ),
            )
        })?;
    let required_consistency = requirements
        .get("requiredConsistency")
        .and_then(Value::as_str)
        .filter(|value| CONSISTENCIES.contains(value))
        .ok_or_else(|| {
            invalid_semantics(
                state,
                route,
                format!(
                    "state '{}' route '{}' requiredConsistency is missing or unknown",
                    state.state_id, route.route_id
                ),
            )
        })?;
    let route_required_consistency = match requirements.get("routeRequiredConsistency") {
        None | Some(Value::Null) => None,
        Some(value) => Some(
            value
                .as_str()
                .filter(|value| CONSISTENCIES.contains(value))
                .ok_or_else(|| {
                    invalid_semantics(
                        state,
                        route,
                        format!(
                        "state '{}' route '{}' routeRequiredConsistency is not a known consistency",
                        state.state_id, route.route_id
                    ),
                    )
                })?,
        ),
    };
    let required_fidelity = requirements
        .get("requiredFidelity")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            invalid_semantics(
                state,
                route,
                format!(
                    "state '{}' route '{}' requiredFidelity is missing or not an array",
                    state.state_id, route.route_id
                ),
            )
        })?
        .iter()
        .map(|value| {
            value.as_str().ok_or_else(|| {
                invalid_semantics(
                    state,
                    route,
                    format!(
                        "state '{}' route '{}' requiredFidelity contains a non-string value",
                        state.state_id, route.route_id
                    ),
                )
            })
        })
        .collect::<Result<Vec<&'a str>>>()?;
    Ok(RouteSemantics {
        required_consistency,
        route_required_consistency,
        required_fidelity,
    })
}

fn route_guaranteed_consistency<'a>(state: &State, route: &'a Route) -> Result<&'a str> {
    let route_guarantee = route
        .guaranteed_consistency
        .as_deref()
        .filter(|value| CONSISTENCIES.contains(value))
        .ok_or_else(|| {
            invalid_semantics(
                state,
                route,
                format!(
                    "state '{}' route '{}' does not declare a known guaranteedConsistency",
                    state.state_id, route.route_id
                ),
            )
        })?;
    let integration = route.integration.as_ref().ok_or_else(|| {
        invalid_semantics(
            state,
            route,
            format!(
                "state '{}' route '{}' has no integration to guarantee consistency",
                state.state_id, route.route_id
            ),
        )
    })?;
    let integration_guarantee = integration
        .guaranteed_consistency
        .as_deref()
        .filter(|value| CONSISTENCIES.contains(value))
        .ok_or_else(|| {
            invalid_semantics(
                state,
                route,
                format!(
                    "state '{}' route '{}' integration '{}' does not declare a known guaranteedConsistency",
                    state.state_id, route.route_id, integration.integration_id
                ),
            )
        })?;
    if route_guarantee != integration_guarantee {
        return Err(PreserveError::new(
            "inconsistent-integration-guarantee",
            format!(
                "state '{}' route '{}' guarantees '{}' but integration '{}' guarantees '{}'",
                state.state_id,
                route.route_id,
                route_guarantee,
                integration.integration_id,
                integration_guarantee
            ),
        )
        .context(&state.state_id, Some(&route.route_id)));
    }
    Ok(route_guarantee)
}

fn validate_point(state: &State, route: &Route, point: &NativePoint) -> Result<()> {
    let target = route
        .target
        .as_ref()
        .expect("executable route has a target");
    let integration = route
        .integration
        .as_ref()
        .expect("executable route has an integration");
    if point.state_id != state.state_id
        || point.route_id != route.route_id
        || point.target_id != target.target_id
        || point.owner != integration.owner
    {
        return Err(PreserveError::new(
            "point-scope-mismatch",
            format!(
                "native point '{}' does not match state, route, target, and owner scope",
                point.native_id
            ),
        )
        .context(&state.state_id, Some(&route.route_id)));
    }
    let native_kind = point
        .native_representation
        .get("kind")
        .and_then(Value::as_str);
    if !native_kind.is_some_and(|kind| {
        integration
            .native_point_representations
            .iter()
            .any(|representation| representation == kind)
    }) {
        return Err(PreserveError::new(
            "unsupported-point-representation",
            format!(
                "native point '{}' uses representation {native_kind:?}, not advertised by integration '{}'",
                point.native_id, integration.integration_id
            ),
        )
        .context(&state.state_id, Some(&route.route_id)));
    }
    let payload_matches = match (
        &integration.payload_representation,
        &point.payload_representation,
    ) {
        (None, None) => true,
        (Some(expected), Some(actual)) => {
            actual.get("kind").and_then(Value::as_str) == Some(expected.as_str())
        }
        _ => false,
    };
    if !payload_matches {
        return Err(PreserveError::new(
            "unsupported-point-payload",
            format!(
                "native point '{}' payload representation does not match integration '{}'",
                point.native_id, integration.integration_id
            ),
        )
        .context(&state.state_id, Some(&route.route_id)));
    }
    if point.completion != "complete" {
        return Err(PreserveError::new(
            "incomplete-point",
            format!("native point '{}' is not complete", point.native_id),
        )
        .context(&state.state_id, Some(&route.route_id)));
    }
    let semantics = route_semantics(state, route)?;
    let guarantee = route_guaranteed_consistency(state, route)?;
    let mut required_consistencies = vec![semantics.required_consistency, guarantee];
    if let Some(required) = semantics.route_required_consistency {
        required_consistencies.push(required);
    }
    if let Some(unsatisfied) = required_consistencies
        .iter()
        .find(|required| !consistency_satisfies(&point.consistency, required))
    {
        return Err(PreserveError::new(
            "unsupported-point-consistency",
            format!(
                "native point '{}' achieved consistency '{}' does not satisfy '{unsatisfied}'",
                point.native_id, point.consistency
            ),
        )
        .context(&state.state_id, Some(&route.route_id)));
    }
    let required_fidelity: Vec<&str> = semantics
        .required_fidelity
        .into_iter()
        .chain(integration.fidelity_guarantees.iter().map(String::as_str))
        .collect();
    if let Some(missing) = required_fidelity
        .iter()
        .find(|fidelity| !point.fidelity.iter().any(|achieved| achieved == *fidelity))
    {
        return Err(PreserveError::new(
            "unsupported-point-fidelity",
            format!(
                "native point '{}' fidelity evidence lacks '{missing}'",
                point.native_id
            ),
        )
        .context(&state.state_id, Some(&route.route_id)));
    }
    Ok(())
}

fn points_for_route(state: &State, route: &Route) -> Result<Vec<NativePoint>> {
    require_capability(state, route, "points", false)?;
    let result: PointsResult =
        parse_result(invoke(state, route, "points", None, None, None)?, "points")?;
    for point in &result.points {
        validate_point(state, route, point)?;
    }
    Ok(result.points)
}

pub fn plan(document: &Document) -> Result<Value> {
    validate_document(document)?;
    serde_json::to_value(document).map_err(|error| {
        PreserveError::new(
            "plan-serialization",
            format!("could not serialize plan: {error}"),
        )
    })
}

pub fn status(document: &Document, observe: bool) -> Result<Value> {
    validate_document(document)?;
    let mut states = Vec::new();
    for state in &document.states {
        let mut routes = Vec::new();
        for route in &state.routes {
            if observe && document.kind == "executable-plan" && state.operational {
                let route = executable_route(state, &route.route_id)?;
                let observed = require_capability(state, route, "status", false).and_then(|_| {
                    parse_result::<StatusResult>(
                        invoke(state, route, "status", None, None, None)?,
                        "status",
                    )
                });
                match observed {
                    Ok(result) => routes.push(json!({
                        "routeId": route.route_id,
                        "configured": true,
                        "observed": result.catalog_observed,
                        "evidence": result.evidence,
                        "pointCount": result.point_count,
                        "details": result.details
                    })),
                    Err(error) => routes.push(json!({
                        "routeId": route.route_id,
                        "configured": true,
                        "observed": false,
                        "evidence": "failed",
                        "pointCount": Value::Null,
                        "error": error.context(&state.state_id, Some(&route.route_id))
                    })),
                }
            } else {
                routes.push(json!({
                    "routeId": route.route_id,
                    "configured": route.status == "resolved",
                    "observed": false,
                    "evidence": EvidenceState::Configured,
                    "pointCount": Value::Null
                }));
            }
        }
        states.push(json!({
            "stateId": state.state_id,
            "mode": state.mode,
            "operational": state.operational,
            "routes": routes
        }));
    }
    Ok(json!({ "kind": "status", "states": states }))
}

pub fn points(document: &Document, state_id: &str) -> Result<Vec<NativePoint>> {
    let state = executable_state(document, state_id)?;
    let mut points = Vec::new();
    for route in &state.routes {
        let route = executable_route(state, &route.route_id)?;
        points.extend(points_for_route(state, route)?);
    }
    Ok(points)
}

pub fn run(document: &Document, state_id: &str, route_id: &str) -> Result<RunResult> {
    let state = executable_state(document, state_id)?;
    let route = executable_route(state, route_id)?;
    if route.operation.as_deref() != Some("run") {
        return Err(PreserveError::new(
            "unsupported-route-action",
            "run dispatch accepts only the route's fixed owner-level run action",
        )
        .context(state_id, Some(route_id)));
    }
    require_capability(state, route, "run", false)?;
    parse_result(invoke(state, route, "run", None, None, None)?, "run")
}

pub fn restore(
    document: &Document,
    state_id: &str,
    route_id: &str,
    point_id: &str,
    scratch_ref: &str,
    new_name: &str,
    execute: bool,
    receipt_path: Option<&Path>,
) -> Result<Value> {
    let state = executable_state(document, state_id)?;
    let route = executable_route(state, route_id)?;
    let scratch: &ScratchDestination =
        document
            .scratch_destinations
            .get(scratch_ref)
            .ok_or_else(|| {
                PreserveError::new(
                    "unknown-scratch-destination",
                    format!("scratch destination '{scratch_ref}' is not configured"),
                )
                .context(state_id, Some(route_id))
            })?;
    let planned = preflight_destination(state, route, scratch_ref, scratch, new_name)?;
    let adapter_version = require_capability(state, route, "restore", true)?;
    let point = points_for_route(state, route)?
        .into_iter()
        .find(|point| point.native_id == point_id)
        .ok_or_else(|| {
            PreserveError::new(
                "unknown-point",
                format!("native point '{point_id}' was not found on the selected route"),
            )
            .context(state_id, Some(route_id))
        })?;
    if point.completion != "complete" {
        return Err(PreserveError::new(
            "incomplete-point",
            format!("native point '{point_id}' is not complete"),
        )
        .context(state_id, Some(route_id)));
    }
    if !execute {
        return Ok(json!({
            "kind": "restore-preflight",
            "stateId": state_id,
            "routeId": route_id,
            "point": point,
            "destination": planned,
            "mutation": false
        }));
    }

    if let Some(path) = receipt_path {
        if path.exists() {
            return Err(PreserveError::new(
                "receipt-exists",
                format!("receipt {} already exists", path.display()),
            )
            .context(state_id, Some(route_id)));
        }
        if !path.parent().is_some_and(|parent| parent.is_dir()) {
            return Err(PreserveError::new(
                "invalid-receipt-path",
                format!(
                    "receipt {} has no existing parent directory",
                    path.display()
                ),
            )
            .context(state_id, Some(route_id)));
        }
    }
    let destination = preflight_destination(state, route, scratch_ref, scratch, new_name)?;
    let result: RestoreResult = parse_result(
        invoke(
            state,
            route,
            "restore",
            Some(point.clone()),
            Some(destination.clone()),
            None,
        )?,
        "restore",
    )?;
    let receipt = RestoreReceipt {
        schema_version: SCHEMA_VERSION,
        state_id: state_id.to_owned(),
        route_id: route_id.to_owned(),
        target_id: route
            .target
            .as_ref()
            .expect("executable route has a target")
            .target_id
            .clone(),
        integration_id: route
            .integration
            .as_ref()
            .expect("executable route has an integration")
            .integration_id
            .clone(),
        adapter_version,
        producer_provenance: point.producer_provenance.clone(),
        point,
        destination,
        owner_receipt: result.owner_receipt,
    };
    if let Some(path) = receipt_path {
        write_receipt(path, &receipt)?;
    }
    serde_json::to_value(&receipt).map_err(|error| {
        PreserveError::new(
            "receipt-serialization",
            format!("could not serialize restore receipt: {error}"),
        )
    })
}

fn write_receipt(path: &Path, receipt: &RestoreReceipt) -> Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|error| {
            PreserveError::new(
                "receipt-write",
                format!("could not create receipt {}: {error}", path.display()),
            )
        })?;
    serde_json::to_writer_pretty(&mut file, receipt).map_err(|error| {
        PreserveError::new(
            "receipt-write",
            format!("could not write restore receipt: {error}"),
        )
    })?;
    file.write_all(b"\n")
        .and_then(|_| file.sync_all())
        .map_err(|error| {
            PreserveError::new(
                "receipt-write",
                format!("could not finish restore receipt: {error}"),
            )
        })
}

pub fn verify(document: &Document, receipt: RestoreReceipt) -> Result<VerifyResult> {
    if receipt.schema_version != SCHEMA_VERSION {
        return Err(PreserveError::new(
            "unsupported-receipt-version",
            format!(
                "receipt schema version {} is unsupported",
                receipt.schema_version
            ),
        ));
    }
    let state = executable_state(document, &receipt.state_id)?;
    let route = executable_route(state, &receipt.route_id)?;
    let target = route
        .target
        .as_ref()
        .expect("executable route has a target");
    let integration = route
        .integration
        .as_ref()
        .expect("executable route has an integration");
    if target.target_id != receipt.target_id || integration.integration_id != receipt.integration_id
    {
        return Err(PreserveError::new(
            "receipt-scope-mismatch",
            "receipt target or integration does not match the current executable plan",
        )
        .context(&receipt.state_id, Some(&receipt.route_id)));
    }
    validate_point(state, route, &receipt.point)?;
    require_capability(state, route, "verify", false)?;
    let result: VerifyResult = parse_result(
        invoke(
            state,
            route,
            "verify",
            Some(receipt.point.clone()),
            Some(receipt.destination.clone()),
            Some(receipt),
        )?,
        "verify",
    )?;
    if !result.verified || result.evidence != EvidenceState::Verified {
        return Err(PreserveError::new(
            "verification-failed",
            "adapter did not verify the restored result",
        )
        .context(&state.state_id, Some(&route.route_id)));
    }
    Ok(result)
}
