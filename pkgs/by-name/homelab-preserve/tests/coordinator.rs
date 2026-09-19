use homelab_preserve::model::{
    Document, Integration, NativePoint, ProtocolRequest, RestoreReceipt, Route, ScratchDestination,
    State, Target,
};
use homelab_preserve::process::invoke_adapter;
use homelab_preserve::safety::preflight_destination;
use homelab_preserve::{plan, points, status, validate_document, verify};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static TEMP_ID: AtomicU64 = AtomicU64::new(0);

fn temporary(name: &str) -> PathBuf {
    let id = TEMP_ID.fetch_add(1, Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!(
        "homelab-preserve-{name}-{}-{id}",
        std::process::id()
    ));
    fs::create_dir_all(&path).unwrap();
    path
}

fn script(directory: &Path, body: &str) -> PathBuf {
    let id = TEMP_ID.fetch_add(1, Ordering::Relaxed);
    let path = directory.join(format!("adapter-{id}"));
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_owned());
    fs::write(&path, format!("#!{shell}\n{body}\n")).unwrap();
    let mut permissions = fs::metadata(&path).unwrap().permissions();
    permissions.set_mode(0o700);
    fs::set_permissions(&path, permissions).unwrap();
    path
}

fn integration(adapter: PathBuf) -> Integration {
    Integration {
        integration_id: "fixture".to_owned(),
        owner: "fixture-owner".to_owned(),
        adapter,
        protocol_version: 1,
        timeout_seconds: 2,
        max_response_bytes: 1024,
        fixture_only: true,
        operations: vec![
            "describe".to_owned(),
            "status".to_owned(),
            "points".to_owned(),
            "run".to_owned(),
            "restore".to_owned(),
            "verify".to_owned(),
        ],
        fidelity_guarantees: vec!["posix-filesystem".to_owned()],
        guaranteed_consistency: Some("filesystem".to_owned()),
        native_point_representations: vec!["fixture-directory/v1".to_owned()],
        payload_representation: None,
        extra: BTreeMap::new(),
    }
}

fn request() -> ProtocolRequest {
    ProtocolRequest {
        protocol_version: 1,
        request_id: "request-1".to_owned(),
        operation: "status".to_owned(),
        state_id: "state".to_owned(),
        route_id: "route".to_owned(),
        target_id: "target".to_owned(),
        point: None,
        destination: None,
        owner_payload: Value::Null,
        receipt: None,
    }
}

fn state(source: Option<PathBuf>) -> State {
    State {
        state_id: "state".to_owned(),
        mode: "enabled".to_owned(),
        operational: true,
        realization: Some(homelab_preserve::model::Realization {
            kind: "filesystem".to_owned(),
            owner: json!({"kind": "host", "id": "fixture"}),
            locator: json!("source/state"),
            path: source,
            boundary: json!({"recursive": false}),
            access: Vec::new(),
            physical_backing: None,
            extra: BTreeMap::new(),
        }),
        slot_id: None,
        policy_id: None,
        routes: Vec::new(),
        issues: Vec::new(),
        extra: BTreeMap::new(),
    }
}

fn route() -> Route {
    Route {
        route_id: "route".to_owned(),
        obligation_id: "state::route".to_owned(),
        target: Some(Target {
            target_id: "target".to_owned(),
            failure_domain: BTreeMap::from([("domain".to_owned(), "one".to_owned())]),
            extra: BTreeMap::new(),
        }),
        integration: None,
        operation: Some("run".to_owned()),
        owner_config: None,
        eligible_integrations: Vec::new(),
        semantic_requirements: Some(json!({
            "requiredConsistency": "filesystem",
            "routeRequiredConsistency": null,
            "requiredFidelity": ["posix-filesystem"]
        })),
        guaranteed_consistency: Some("filesystem".to_owned()),
        payload_representation: None,
        native_point_representations: Vec::new(),
        status: "resolved".to_owned(),
        issues: Vec::new(),
        extra: BTreeMap::new(),
    }
}

#[test]
fn opaque_namespaced_provenance_round_trips() {
    let raw = json!({
        "stateId": "state",
        "routeId": "route",
        "targetId": "target",
        "owner": "fixture-owner",
        "nativeId": "point-1",
        "completion": "complete",
        "consistency": "filesystem",
        "fidelity": ["posix-filesystem"],
        "scope": {"kind": "tree"},
        "nativeRepresentation": {"kind": "fixture-directory/v1"},
        "payloadRepresentation": null,
        "producerProvenance": {
            "app.version": "2.1",
            "postgresql.serverVersion": 16,
            "schema.format": {"major": 4, "features": ["a", "b"]}
        },
        "futureOptionalField": {"ignored": true}
    });
    let point: NativePoint = serde_json::from_value(raw).unwrap();
    assert_eq!(point.producer_provenance["app.version"], "2.1");
    assert_eq!(point.producer_provenance["postgresql.serverVersion"], 16);
    assert_eq!(point.native_representation["kind"], "fixture-directory/v1");
    assert!(point.payload_representation.is_none());
    let encoded = serde_json::to_value(point).unwrap();
    assert_eq!(encoded["producerProvenance"]["schema.format"]["major"], 4);
    assert_eq!(
        encoded["nativeRepresentation"]["kind"],
        "fixture-directory/v1"
    );
    assert!(encoded["payloadRepresentation"].is_null());
    assert_eq!(encoded["futureOptionalField"]["ignored"], true);
}

#[test]
fn unsupported_document_version_is_rejected() {
    let document = Document {
        schema_version: 2,
        kind: "executable-plan".to_owned(),
        fixture_only: false,
        states: Vec::new(),
        scratch_destinations: BTreeMap::new(),
        extra: BTreeMap::new(),
    };
    assert_eq!(
        validate_document(&document).unwrap_err().code,
        "unsupported-schema-version"
    );
}

#[test]
fn executable_plan_enforces_fixture_only_boundaries() {
    let mut executable = state(None);
    executable.routes.push(Route {
        integration: Some(integration(PathBuf::from(
            "/configured/adapter/does-not-exist",
        ))),
        ..route()
    });
    let document = Document {
        schema_version: 1,
        kind: "executable-plan".to_owned(),
        fixture_only: false,
        states: vec![executable.clone()],
        scratch_destinations: BTreeMap::new(),
        extra: BTreeMap::new(),
    };
    assert_eq!(
        validate_document(&document).unwrap_err().code,
        "fixture-only-integration"
    );

    let fixture_document = Document {
        fixture_only: true,
        ..document
    };
    assert!(validate_document(&fixture_document).is_ok());

    let mut production = executable.clone();
    production.routes[0].integration = Some(Integration {
        fixture_only: false,
        ..integration(PathBuf::from("/configured/adapter/does-not-exist"))
    });
    let production_document = Document {
        schema_version: 1,
        kind: "executable-plan".to_owned(),
        fixture_only: false,
        states: vec![production],
        scratch_destinations: BTreeMap::new(),
        extra: BTreeMap::new(),
    };
    assert!(validate_document(&production_document).is_ok());

    let mut unadvertised = executable;
    unadvertised.routes[0]
        .integration
        .as_mut()
        .unwrap()
        .native_point_representations = Vec::new();
    let unadvertised_document = Document {
        fixture_only: true,
        states: vec![unadvertised],
        ..production_document
    };
    assert_eq!(
        validate_document(&unadvertised_document).unwrap_err().code,
        "missing-native-point-representations"
    );

    let mut domainless = executable_document(integration(PathBuf::from(
        "/configured/adapter/does-not-exist",
    )));
    domainless.states[0].routes[0]
        .target
        .as_mut()
        .unwrap()
        .failure_domain = BTreeMap::new();
    assert_eq!(
        validate_document(&domainless).unwrap_err().code,
        "empty-failure-domain"
    );
}

#[test]
fn planning_never_invokes_an_adapter() {
    let mut planned_state = state(None);
    planned_state.mode = "plan-only".to_owned();
    planned_state.operational = false;
    planned_state.routes.push(Route {
        integration: Some(integration(PathBuf::from(
            "/configured/adapter/does-not-exist",
        ))),
        ..route()
    });
    let document = Document {
        schema_version: 1,
        kind: "desired-inventory".to_owned(),
        fixture_only: true,
        states: vec![planned_state],
        scratch_destinations: BTreeMap::new(),
        extra: BTreeMap::new(),
    };
    assert!(plan(&document).is_ok());
}

#[test]
fn incompatible_adapter_version_is_rejected_before_spawn() {
    let mut configured = integration(PathBuf::from("/configured/adapter/does-not-exist"));
    configured.protocol_version = 2;
    assert_eq!(
        invoke_adapter(&configured, &request()).unwrap_err().code,
        "unsupported-adapter-version"
    );
}

#[test]
fn adapter_process_failures_are_bounded_and_structured() {
    let directory = temporary("process");

    let valid = script(
        &directory,
        "cat >/dev/null\nprintf '%s' '{\"protocolVersion\":1,\"requestId\":\"request-1\",\"result\":{\"kind\":\"status\"}}'",
    );
    assert_eq!(
        invoke_adapter(&integration(valid), &request()).unwrap()["kind"],
        "status"
    );

    let malformed = script(&directory, "cat >/dev/null\nprintf '{'");
    assert_eq!(
        invoke_adapter(&integration(malformed), &request())
            .unwrap_err()
            .code,
        "malformed-adapter-response"
    );

    let failed = script(&directory, "cat >/dev/null\nexit 7");
    assert_eq!(
        invoke_adapter(&integration(failed), &request())
            .unwrap_err()
            .code,
        "adapter-exit"
    );

    let oversized = script(
        &directory,
        "cat >/dev/null\ni=0; while [ \"$i\" -lt 200 ]; do printf x; i=$((i + 1)); done",
    );
    let mut limited = integration(oversized);
    limited.max_response_bytes = 64;
    assert_eq!(
        invoke_adapter(&limited, &request()).unwrap_err().code,
        "adapter-output"
    );

    let sleeping = script(&directory, "cat >/dev/null\nsleep 10");
    let mut timed = integration(sleeping);
    timed.timeout_seconds = 0;
    assert_eq!(
        invoke_adapter(&timed, &request()).unwrap_err().code,
        "adapter-timeout"
    );

    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn destination_preflight_rejects_unsafe_and_aliasing_paths() {
    let directory = temporary("safety");
    let scratch_root = directory.join("scratch");
    fs::create_dir(&scratch_root).unwrap();
    let scratch = ScratchDestination {
        native_parent: "scratch/root".to_owned(),
        mount_root: scratch_root.clone(),
    };

    let safe_state = state(Some(directory.join("active")));
    let safe_route = route();
    let planned =
        preflight_destination(&safe_state, &safe_route, "scratch", &scratch, "rehearsal").unwrap();
    assert_eq!(
        planned.path,
        fs::canonicalize(&scratch_root).unwrap().join("rehearsal")
    );

    assert_eq!(
        preflight_destination(&safe_state, &safe_route, "scratch", &scratch, "../escape")
            .unwrap_err()
            .code,
        "unsafe-destination-name"
    );

    fs::create_dir(scratch_root.join("existing")).unwrap();
    assert_eq!(
        preflight_destination(&safe_state, &safe_route, "scratch", &scratch, "existing")
            .unwrap_err()
            .code,
        "destination-exists"
    );

    let source_alias = state(Some(scratch_root.clone()));
    assert_eq!(
        preflight_destination(
            &source_alias,
            &safe_route,
            "scratch",
            &scratch,
            "source-child",
        )
        .unwrap_err()
        .code,
        "source-alias"
    );

    fs::remove_dir_all(directory).unwrap();
}

fn executable_document(integration: Integration) -> Document {
    let mut executable = state(None);
    executable.routes.push(Route {
        integration: Some(integration),
        ..route()
    });
    Document {
        schema_version: 1,
        kind: "executable-plan".to_owned(),
        fixture_only: true,
        states: vec![executable],
        scratch_destinations: BTreeMap::new(),
        extra: BTreeMap::new(),
    }
}

const FULL_CAPABILITIES: &str =
    "[\"describe\",\"status\",\"points\",\"run\",\"restore\",\"verify\"]";

fn describe_result(capabilities: &str) -> String {
    format!(
        "{{\"protocolVersion\":1,\"requestId\":\"%s\",\"result\":{{\"kind\":\"describe\",\"adapterVersion\":{{\"protocolVersion\":1,\"implementation\":\"test-adapter\",\"implementationVersion\":\"0.1.0\",\"fixtureOnly\":true}},\"capabilities\":{capabilities},\"explicitScratch\":true}}}}"
    )
}

fn op_adapter(directory: &Path, op_results: &[(&str, &str)]) -> PathBuf {
    let mut body = String::from(
        "request=$(cat)\nid=$(printf '%s' \"$request\" | sed -n 's/.*\"requestId\":\"\\([^\"]*\\)\".*/\\1/p')\n",
    );
    for (operation, result) in op_results {
        body.push_str(&format!(
            "case \"$request\" in *'\"operation\":\"{operation}\"'*) printf '{result}' \"$id\"; exit 0;; esac\n"
        ));
    }
    script(directory, &body)
}

fn point_json(route_id: &str, capture_id: &str, consistency: &str, fidelity: &str) -> String {
    format!(
        "{{\"stateId\":\"state\",\"routeId\":\"{route_id}\",\"targetId\":\"target\",\"owner\":\"fixture-owner\",\"nativeId\":\"point-1\",\"captureId\":\"{capture_id}\",\"completion\":\"complete\",\"consistency\":\"{consistency}\",\"fidelity\":{fidelity},\"scope\":{{}},\"nativeRepresentation\":{{\"kind\":\"fixture-directory/v1\"}},\"payloadRepresentation\":null}}"
    )
}

fn points_adapter(directory: &Path, native_kind: &str, payload: &str) -> PathBuf {
    let point = format!(
        "{{\"stateId\":\"state\",\"routeId\":\"route\",\"targetId\":\"target\",\"owner\":\"fixture-owner\",\"nativeId\":\"point-1\",\"completion\":\"complete\",\"consistency\":\"filesystem\",\"fidelity\":[\"posix-filesystem\"],\"scope\":{{}},\"nativeRepresentation\":{{\"kind\":\"{native_kind}\"}},\"payloadRepresentation\":{payload}}}"
    );
    let describe = describe_result(FULL_CAPABILITIES);
    let points = format!(
        "{{\"protocolVersion\":1,\"requestId\":\"%s\",\"result\":{{\"kind\":\"points\",\"points\":[{point}]}}}}"
    );
    op_adapter(directory, &[("describe", &describe), ("points", &points)])
}

#[test]
fn point_representations_are_checked_against_the_integration() {
    let directory = temporary("representations");

    let wrong_native = points_adapter(&directory, "wrong/v1", "null");
    let document = executable_document(integration(wrong_native));
    assert_eq!(
        points(&document, "state").unwrap_err().code,
        "unsupported-point-representation"
    );

    let expected_payload = points_adapter(&directory, "fixture-directory/v1", "null");
    let mut configured = integration(expected_payload);
    configured.payload_representation = Some("fixture-payload/v1".to_owned());
    let document = executable_document(configured);
    assert_eq!(
        points(&document, "state").unwrap_err().code,
        "unsupported-point-payload"
    );

    let unexpected_payload = points_adapter(
        &directory,
        "fixture-directory/v1",
        "{\"kind\":\"fixture-payload/v1\"}",
    );
    let document = executable_document(integration(unexpected_payload));
    assert_eq!(
        points(&document, "state").unwrap_err().code,
        "unsupported-point-payload"
    );

    let matching = points_adapter(
        &directory,
        "fixture-directory/v1",
        "{\"kind\":\"fixture-payload/v1\"}",
    );
    let mut configured = integration(matching);
    configured.payload_representation = Some("fixture-payload/v1".to_owned());
    let document = executable_document(configured);
    assert_eq!(points(&document, "state").unwrap().len(), 1);

    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn baseline_operations_are_required_on_document_and_adapter() {
    let mut declared = integration(PathBuf::from("/configured/adapter/does-not-exist"));
    declared.operations = vec!["describe".to_owned(), "status".to_owned()];
    let document = executable_document(declared);
    assert_eq!(
        validate_document(&document).unwrap_err().code,
        "unsupported-baseline-operation"
    );
}

#[test]
fn executable_routes_require_valid_semantics_and_guarantees() {
    let adapter = || PathBuf::from("/configured/adapter/does-not-exist");
    let invalid = "invalid-semantic-requirements";

    let mut missing_semantics = executable_document(integration(adapter()));
    missing_semantics.states[0].routes[0].semantic_requirements = None;
    assert_eq!(
        validate_document(&missing_semantics).unwrap_err().code,
        invalid
    );

    let mut malformed = executable_document(integration(adapter()));
    malformed.states[0].routes[0].semantic_requirements = Some(json!("not-an-object"));
    assert_eq!(validate_document(&malformed).unwrap_err().code, invalid);

    let mut unknown_required = executable_document(integration(adapter()));
    unknown_required.states[0].routes[0].semantic_requirements =
        Some(json!({"requiredConsistency": "mystery", "requiredFidelity": []}));
    assert_eq!(
        validate_document(&unknown_required).unwrap_err().code,
        invalid
    );

    let mut malformed_fidelity = executable_document(integration(adapter()));
    malformed_fidelity.states[0].routes[0].semantic_requirements = Some(json!({
        "requiredConsistency": "filesystem",
        "requiredFidelity": ["posix-filesystem", 7]
    }));
    assert_eq!(
        validate_document(&malformed_fidelity).unwrap_err().code,
        invalid
    );

    let mut missing_route_guarantee = executable_document(integration(adapter()));
    missing_route_guarantee.states[0].routes[0].guaranteed_consistency = None;
    assert_eq!(
        validate_document(&missing_route_guarantee)
            .unwrap_err()
            .code,
        invalid
    );

    let mut unknown_guarantee = executable_document(integration(adapter()));
    unknown_guarantee.states[0].routes[0].guaranteed_consistency = Some("mystery".to_owned());
    assert_eq!(
        validate_document(&unknown_guarantee).unwrap_err().code,
        invalid
    );

    let mut missing_integration_guarantee = executable_document(integration(adapter()));
    missing_integration_guarantee.states[0].routes[0]
        .integration
        .as_mut()
        .unwrap()
        .guaranteed_consistency = None;
    assert_eq!(
        validate_document(&missing_integration_guarantee)
            .unwrap_err()
            .code,
        invalid
    );

    let mut disagreement = executable_document(integration(adapter()));
    disagreement.states[0].routes[0].guaranteed_consistency = Some("crash".to_owned());
    assert_eq!(
        validate_document(&disagreement).unwrap_err().code,
        "inconsistent-integration-guarantee"
    );
}

#[test]
fn point_consistency_and_fidelity_must_satisfy_the_route() {
    let directory = temporary("point-evidence");

    let adapter_for = |consistency: &str, fidelity: &str| {
        let describe = describe_result(FULL_CAPABILITIES);
        let points_result = format!(
            "{{\"protocolVersion\":1,\"requestId\":\"%s\",\"result\":{{\"kind\":\"points\",\"points\":[{}]}}}}",
            point_json("route", "capture-1", consistency, fidelity)
        );
        op_adapter(
            &directory,
            &[("describe", &describe), ("points", &points_result)],
        )
    };

    let required = |route: &mut Route| {
        route.guaranteed_consistency = Some("filesystem".to_owned());
        route.semantic_requirements = Some(json!({
            "requiredConsistency": "filesystem",
            "routeRequiredConsistency": null,
            "requiredFidelity": ["posix-filesystem"]
        }));
    };

    let mut satisfied = executable_document(integration(adapter_for(
        "filesystem",
        "[\"posix-filesystem\",\"zfs-dataset\"]",
    )));
    required(&mut satisfied.states[0].routes[0]);
    assert_eq!(points(&satisfied, "state").unwrap().len(), 1);

    let mut weak = executable_document(integration(adapter_for("live", "[\"posix-filesystem\"]")));
    required(&mut weak.states[0].routes[0]);
    assert_eq!(
        points(&weak, "state").unwrap_err().code,
        "unsupported-point-consistency"
    );

    let mut unknown = executable_document(integration(adapter_for(
        "unknown-level",
        "[\"posix-filesystem\"]",
    )));
    required(&mut unknown.states[0].routes[0]);
    assert_eq!(
        points(&unknown, "state").unwrap_err().code,
        "unsupported-point-consistency"
    );

    let mut missing_fidelity = executable_document(integration(adapter_for(
        "filesystem",
        "[\"other-fidelity\"]",
    )));
    required(&mut missing_fidelity.states[0].routes[0]);
    assert_eq!(
        points(&missing_fidelity, "state").unwrap_err().code,
        "unsupported-point-fidelity"
    );

    let mut incomplete = executable_document(integration(adapter_for(
        "filesystem",
        "[\"posix-filesystem\"]",
    )));
    required(&mut incomplete.states[0].routes[0]);
    let describe = describe_result(FULL_CAPABILITIES);
    let incomplete_result = format!(
        "{{\"protocolVersion\":1,\"requestId\":\"%s\",\"result\":{{\"kind\":\"points\",\"points\":[{}]}}}}",
        point_json("route", "capture-1", "filesystem", "[\"posix-filesystem\"]")
            .replace("\"completion\":\"complete\"", "\"completion\":\"partial\"")
    );
    let incomplete_adapter = op_adapter(
        &directory,
        &[("describe", &describe), ("points", &incomplete_result)],
    );
    incomplete.states[0].routes[0].integration = Some(integration(incomplete_adapter));
    assert_eq!(
        points(&incomplete, "state").unwrap_err().code,
        "incomplete-point"
    );

    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn adapter_failures_do_not_leak_stderr_into_errors() {
    let directory = temporary("stderr-safety");
    let leaky = script(
        &directory,
        "cat >/dev/null\necho 'token=secret-value' >&2\nexit 7",
    );
    let error = invoke_adapter(&integration(leaky), &request()).unwrap_err();
    assert_eq!(error.code, "adapter-exit");
    assert!(!error.message.contains("secret-value"));

    fs::remove_dir_all(directory).unwrap();
}

#[cfg(unix)]
#[test]
fn timeout_terminates_the_whole_adapter_process_group() {
    let directory = temporary("process-group");
    let leader_pid = directory.join("leader.pid");
    let descendant_pid = directory.join("descendant.pid");
    let group_adapter = script(
        &directory,
        &format!(
            "echo $$ > \"{}\"\nsleep 300 &\necho $! > \"{}\"\ncat >/dev/null\nwait\n",
            leader_pid.display(),
            descendant_pid.display()
        ),
    );

    fn alive(pid: &str) -> bool {
        std::process::Command::new("ps")
            .args(["-p", pid])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
    }

    let started = std::time::Instant::now();
    let mut timed = integration(group_adapter);
    timed.timeout_seconds = 3;
    let error = invoke_adapter(&timed, &request()).unwrap_err();
    assert_eq!(error.code, "adapter-timeout");
    assert!(started.elapsed() < std::time::Duration::from_secs(30));

    let pid_deadline = started + std::time::Duration::from_secs(30);
    while (!leader_pid.exists() || !descendant_pid.exists())
        && std::time::Instant::now() < pid_deadline
    {
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    let leader = fs::read_to_string(&leader_pid).unwrap().trim().to_owned();
    let descendant = fs::read_to_string(&descendant_pid)
        .unwrap()
        .trim()
        .to_owned();
    let deadline = started + std::time::Duration::from_secs(30);
    while (alive(&leader) || alive(&descendant)) && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    assert!(!alive(&leader), "adapter leader {leader} survived timeout");
    assert!(
        !alive(&descendant),
        "adapter descendant {descendant} survived group termination"
    );

    fs::remove_dir_all(directory).unwrap();
}

fn two_route_document(first: PathBuf, second: PathBuf, second_status: &str) -> Document {
    let mut executable = state(None);
    executable.routes.push(Route {
        integration: Some(integration(first)),
        ..route()
    });
    executable.routes.push(Route {
        route_id: "route-stale".to_owned(),
        integration: Some(integration(second)),
        status: second_status.to_owned(),
        ..route()
    });
    Document {
        schema_version: 1,
        kind: "executable-plan".to_owned(),
        fixture_only: true,
        states: vec![executable],
        scratch_destinations: BTreeMap::new(),
        extra: BTreeMap::new(),
    }
}

#[test]
fn independent_routes_keep_separate_point_evidence() {
    let directory = temporary("route-evidence");
    let describe = describe_result(FULL_CAPABILITIES);

    let first_points = format!(
        "{{\"protocolVersion\":1,\"requestId\":\"%s\",\"result\":{{\"kind\":\"points\",\"points\":[{}]}}}}",
        point_json("route", "capture-a", "filesystem", "[\"posix-filesystem\"]")
            .replace(
                "\"nativeId\":\"point-1\"",
                "\"nativeId\":\"point-a\",\"capturedAt\":\"2026-01-01T00:00:00Z\""
            )
    );
    let second_points = format!(
        "{{\"protocolVersion\":1,\"requestId\":\"%s\",\"result\":{{\"kind\":\"points\",\"points\":[{}]}}}}",
        point_json("route-stale", "capture-b", "filesystem", "[\"posix-filesystem\"]")
            .replace(
                "\"nativeId\":\"point-1\"",
                "\"nativeId\":\"point-b\",\"capturedAt\":\"2026-02-02T00:00:00Z\""
            )
    );
    let second_directory = directory.join("second");
    fs::create_dir(&second_directory).unwrap();
    let first = op_adapter(
        &directory,
        &[("describe", &describe), ("points", &first_points)],
    );
    let second = op_adapter(
        &second_directory,
        &[("describe", &describe), ("points", &second_points)],
    );

    let document = two_route_document(first, second, "resolved");
    let listed = points(&document, "state").unwrap();
    assert_eq!(listed.len(), 2);
    let first_point = listed
        .iter()
        .find(|point| point.route_id == "route")
        .unwrap();
    let second_point = listed
        .iter()
        .find(|point| point.route_id == "route-stale")
        .unwrap();
    assert_eq!(first_point.capture_id.as_deref(), Some("capture-a"));
    assert_eq!(second_point.capture_id.as_deref(), Some("capture-b"));
    assert_eq!(
        first_point.captured_at.as_deref(),
        Some("2026-01-01T00:00:00Z")
    );
    assert_eq!(
        second_point.captured_at.as_deref(),
        Some("2026-02-02T00:00:00Z")
    );

    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn failed_routes_stay_independently_represented() {
    let directory = temporary("route-failure");
    let describe = describe_result(FULL_CAPABILITIES);
    let observed_status = "{\"protocolVersion\":1,\"requestId\":\"%s\",\"result\":{\"kind\":\"status\",\"evidence\":\"observed\",\"catalogObserved\":true,\"pointCount\":2,\"details\":null}}".to_owned();
    let first = op_adapter(
        &directory,
        &[("describe", &describe), ("status", &observed_status)],
    );
    let second_directory = directory.join("second");
    fs::create_dir(&second_directory).unwrap();
    let second = script(
        &second_directory,
        &format!(
            "request=$(cat)\ncase \"$request\" in *'\"operation\":\"status\"'*) exit 7;; esac\nid=$(printf '%s' \"$request\" | sed -n 's/.*\"requestId\":\"\\([^\"]*\\)\".*/\\1/p')\nprintf '{describe}' \"$id\"\n"
        ),
    );

    let document = two_route_document(first, second, "resolved");
    let report = status(&document, true).unwrap();
    let routes = report["states"][0]["routes"].as_array().unwrap();
    assert_eq!(routes.len(), 2);
    let resolved_route = routes
        .iter()
        .find(|route| route["routeId"] == "route")
        .unwrap();
    let failed_route = routes
        .iter()
        .find(|route| route["routeId"] == "route-stale")
        .unwrap();
    assert_eq!(resolved_route["configured"], true);
    assert_eq!(resolved_route["observed"], true);
    assert_eq!(resolved_route["evidence"], "observed");
    assert_eq!(resolved_route["pointCount"], 2);
    assert_eq!(failed_route["configured"], true);
    assert_eq!(failed_route["observed"], false);
    assert_eq!(failed_route["evidence"], "failed");
    assert_eq!(failed_route["pointCount"], Value::Null);
    assert_eq!(failed_route["error"]["code"], "adapter-exit");
    assert_eq!(failed_route["error"]["stateId"], "state");
    assert_eq!(failed_route["error"]["routeId"], "route-stale");

    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn point_evidence_does_not_verify_restored_content() {
    let directory = temporary("verify-evidence");
    let describe = describe_result(FULL_CAPABILITIES);
    let failed_verify =
        "{\"protocolVersion\":1,\"requestId\":\"%s\",\"result\":{\"kind\":\"verify\",\"verified\":false,\"evidence\":\"failed\",\"scope\":\"fixture-content\"}}".to_owned();
    let adapter = op_adapter(
        &directory,
        &[("describe", &describe), ("verify", &failed_verify)],
    );

    let mut document = executable_document(integration(adapter));
    document.states[0].routes[0].guaranteed_consistency = Some("filesystem".to_owned());
    document.states[0].routes[0].semantic_requirements = Some(json!({
        "requiredConsistency": "filesystem",
        "requiredFidelity": ["posix-filesystem"]
    }));

    let receipt: RestoreReceipt = serde_json::from_value(json!({
        "schemaVersion": 1,
        "stateId": "state",
        "routeId": "route",
        "targetId": "target",
        "integrationId": "fixture",
        "adapterVersion": {
            "protocolVersion": 1,
            "implementation": "test-adapter",
            "implementationVersion": "0.1.0",
            "fixtureOnly": true
        },
        "point": {
            "stateId": "state",
            "routeId": "route",
            "targetId": "target",
            "owner": "fixture-owner",
            "nativeId": "point-1",
            "captureId": "capture-1",
            "completion": "complete",
            "consistency": "filesystem",
            "fidelity": ["posix-filesystem"],
            "scope": {},
            "nativeRepresentation": {"kind": "fixture-directory/v1"},
            "payloadRepresentation": null,
            "verification": [{"kind": "owner-native-check", "status": "passed"}]
        },
        "destination": {
            "capabilityRef": "scratch",
            "newName": "rehearsal",
            "path": "/scratch/rehearsal",
            "nativeLocator": "scratch/root/rehearsal"
        }
    }))
    .unwrap();

    assert_eq!(
        verify(&document, receipt).unwrap_err().code,
        "verification-failed"
    );

    fs::remove_dir_all(directory).unwrap();
}
