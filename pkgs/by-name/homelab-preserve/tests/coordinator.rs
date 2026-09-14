use homelab_preserve::model::{
    Document, Integration, NativePoint, ProtocolRequest, Route, ScratchDestination, State, Target,
};
use homelab_preserve::process::invoke_adapter;
use homelab_preserve::safety::preflight_destination;
use homelab_preserve::{plan, points, validate_document};
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
    let path = directory.join("adapter");
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
        semantic_requirements: None,
        guaranteed_consistency: None,
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

fn points_adapter(directory: &Path, native_kind: &str, payload: &str) -> PathBuf {
    let point = format!(
        "{{\"stateId\":\"state\",\"routeId\":\"route\",\"targetId\":\"target\",\"owner\":\"fixture-owner\",\"nativeId\":\"point-1\",\"completion\":\"complete\",\"consistency\":\"filesystem\",\"scope\":{{}},\"nativeRepresentation\":{{\"kind\":\"{native_kind}\"}},\"payloadRepresentation\":{payload}}}"
    );
    script(
        directory,
        &format!(
            "request=$(cat)\nid=$(printf '%s' \"$request\" | sed -n 's/.*\"requestId\":\"\\([^\"]*\\)\".*/\\1/p')\nprintf '{{\"protocolVersion\":1,\"requestId\":\"%s\",\"result\":{{\"kind\":\"points\",\"points\":[{point}]}}}}' \"$id\""
        ),
    )
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
