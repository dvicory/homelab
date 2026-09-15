use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

const PROTOCOL_VERSION: u32 = 1;
const MAX_REQUEST_BYTES: usize = 1_048_576;
const OWNER: &str = "zfs-reference";
const NATIVE_KIND: &str = "openzfs.snapshot";
const RECEIVER_POOL: &str = "receiver";

const PROP_STATE_ID: &str = "org.homelab.preserve:state-id";
const PROP_CAPTURE_ID: &str = "org.homelab.preserve:capture-id";
const PROP_SOURCE_GUID: &str = "org.homelab.preserve:source-guid";
const PROP_COMPLETE: &str = "org.homelab.preserve:complete";

#[derive(Debug)]
struct Failure {
    code: &'static str,
    message: String,
}

type Result<T> = std::result::Result<T, Failure>;

fn fail<T>(code: &'static str, message: impl Into<String>) -> Result<T> {
    Err(Failure {
        code,
        message: message.into(),
    })
}

fn valid_dataset_component(component: &str) -> bool {
    !component.is_empty()
        && component
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.' | ':'))
}

fn dataset_components(name: &str) -> Option<Vec<String>> {
    if name.is_empty() {
        return None;
    }
    let parts: Vec<String> = name.split('/').map(str::to_owned).collect();
    if parts.iter().all(|part| valid_dataset_component(part)) {
        Some(parts)
    } else {
        None
    }
}

fn dataset_within(root: &[String], ds: &[String]) -> bool {
    ds.len() >= root.len() && ds[..root.len()] == root[..]
}

fn datasets_overlap(left: &[String], right: &[String]) -> bool {
    dataset_within(left, right) || dataset_within(right, left)
}

fn direct_child_name(parent: &str, dataset: &str) -> Option<String> {
    let prefix = format!("{parent}/");
    let rest = dataset.strip_prefix(&prefix)?;
    if valid_dataset_component(rest) {
        Some(rest.to_owned())
    } else {
        None
    }
}

fn clean_absolute_path(raw: &str) -> Option<PathBuf> {
    let path = Path::new(raw);
    if !path.is_absolute() {
        return None;
    }
    let mut result = PathBuf::new();
    for component in path.components() {
        match component {
            Component::RootDir => result.push(component.as_os_str()),
            Component::Normal(part) => result.push(part),
            _ => return None,
        }
    }
    Some(result)
}

fn valid_new_name(name: &str) -> bool {
    !name.is_empty() && !name.contains('/') && !name.contains('\\') && valid_dataset_component(name)
}

fn zfs_output(args: &[String]) -> Result<String> {
    let output = Command::new("zfs")
        .args(args)
        .output()
        .map_err(|error| Failure {
            code: "zfs-invoke",
            message: format!("could not start zfs: {error}"),
        })?;
    if !output.status.success() {
        return fail(
            "zfs-command",
            format!(
                "zfs {} failed: {}",
                args.join(" "),
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        );
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn dataset_exists(name: &str) -> Result<bool> {
    let output = Command::new("zfs")
        .args(["list", "-H", "-o", "name", name])
        .output()
        .map_err(|error| Failure {
            code: "zfs-invoke",
            message: format!("could not start zfs: {error}"),
        })?;
    if output.status.success() {
        return Ok(true);
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    if stderr.contains("dataset does not exist") {
        return Ok(false);
    }
    fail(
        "zfs-command",
        format!("could not inspect '{name}': {}", stderr.trim()),
    )
}

fn snapshot_names(dataset: &str) -> Result<Vec<String>> {
    let out = zfs_output(&[
        "list".to_owned(),
        "-H".to_owned(),
        "-r".to_owned(),
        "-t".to_owned(),
        "snapshot".to_owned(),
        "-o".to_owned(),
        "name".to_owned(),
        dataset.to_owned(),
    ])?;
    Ok(out
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_owned)
        .collect())
}

fn zfs_props(name: &str, props: &[&str]) -> Result<BTreeMap<String, String>> {
    let out = zfs_output(&[
        "get".to_owned(),
        "-H".to_owned(),
        "-o".to_owned(),
        "property,value".to_owned(),
        props.join(","),
        name.to_owned(),
    ])?;
    let mut map = BTreeMap::new();
    for line in out.lines() {
        let mut parts = line.splitn(2, '\t');
        if let (Some(prop), Some(value)) = (parts.next(), parts.next()) {
            map.insert(prop.to_owned(), value.to_owned());
        }
    }
    Ok(map)
}

fn zfs_prop(name: &str, prop: &str) -> Result<String> {
    zfs_props(name, &[prop])?
        .remove(prop)
        .filter(|value| value != "-")
        .ok_or_else(|| Failure {
            code: "zfs-property",
            message: format!("{name} has no usable '{prop}' property"),
        })
}

fn zfs_set(name: &str, prop: &str, value: &str) -> Result<()> {
    zfs_output(&["set".to_owned(), format!("{prop}={value}"), name.to_owned()]).map(|_| ())
}

fn receive_args(destination: &str, mountpoint: &str, canmount: &str) -> Vec<String> {
    vec![
        "receive".to_owned(),
        "-u".to_owned(),
        "-o".to_owned(),
        format!("mountpoint={mountpoint}"),
        "-o".to_owned(),
        format!("canmount={canmount}"),
        "-o".to_owned(),
        "sharenfs=off".to_owned(),
        "-o".to_owned(),
        "sharesmb=off".to_owned(),
        "-o".to_owned(),
        "acltype=posix".to_owned(),
        "-o".to_owned(),
        "xattr=sa".to_owned(),
        destination.to_owned(),
    ]
}

fn send_receive(snapshot: &str, destination: &str, mountpoint: &str, canmount: &str) -> Result<()> {
    let mut send = Command::new("zfs")
        .args(["send", snapshot])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| Failure {
            code: "zfs-invoke",
            message: format!("could not start zfs send: {error}"),
        })?;
    let stdout = send.stdout.take().ok_or_else(|| Failure {
        code: "zfs-invoke",
        message: "zfs send stdout was unavailable".to_owned(),
    })?;
    let receive = Command::new("zfs")
        .args(receive_args(destination, mountpoint, canmount))
        .stdin(stdout)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| Failure {
            code: "zfs-invoke",
            message: format!("could not start zfs receive: {error}"),
        })?;
    let send_status = send.wait_with_output().map_err(|error| Failure {
        code: "zfs-invoke",
        message: format!("could not wait for zfs send: {error}"),
    })?;
    let receive_status = receive.wait_with_output().map_err(|error| Failure {
        code: "zfs-invoke",
        message: format!("could not wait for zfs receive: {error}"),
    })?;
    if !send_status.status.success() {
        return fail(
            "zfs-send",
            format!(
                "zfs send {snapshot} failed: {}",
                String::from_utf8_lossy(&send_status.stderr).trim()
            ),
        );
    }
    if !receive_status.status.success() {
        return fail(
            "zfs-receive",
            format!(
                "zfs receive {destination} failed: {}",
                String::from_utf8_lossy(&receive_status.stderr).trim()
            ),
        );
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Role {
    Local,
    Replica,
}

struct ZfsReference {
    role: Role,
    source_dataset: String,
    source_mount_root: PathBuf,
    receiver_root: String,
    scratch_root: String,
    scratch_mount_root: PathBuf,
    simulate_receive_failure: bool,
}

fn string_field<'a>(object: &'a Map<String, Value>, key: &str) -> Result<&'a str> {
    object
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| Failure {
            code: "invalid-config",
            message: format!("native.zfsReference requires string '{key}'"),
        })
}

fn parse_config(request: &Value) -> Result<ZfsReference> {
    let reference = request
        .get("ownerPayload")
        .and_then(|payload| payload.get("native"))
        .and_then(|native| native.get("zfsReference"))
        .and_then(Value::as_object)
        .ok_or_else(|| Failure {
            code: "missing-config",
            message: "owner payload requires native.zfsReference".to_owned(),
        })?;

    const ALLOWED: [&str; 9] = [
        "referenceOnly",
        "role",
        "sourceRoot",
        "sourceDataset",
        "sourceMountRoot",
        "receiverRoot",
        "scratchRoot",
        "scratchMountRoot",
        "simulateReceiveFailure",
    ];
    for key in reference.keys() {
        if !ALLOWED.contains(&key.as_str()) {
            return fail(
                "unknown-config-key",
                format!("native.zfsReference key '{key}' is not part of the reference wiring"),
            );
        }
    }

    if reference.get("referenceOnly").and_then(Value::as_bool) != Some(true) {
        return fail(
            "not-reference-only",
            "native.zfsReference.referenceOnly must be true; this adapter is a conformance fixture",
        );
    }
    let role = match string_field(reference, "role")? {
        "local" => Role::Local,
        "replica" => Role::Replica,
        other => {
            return fail(
                "invalid-role",
                format!("native.zfsReference.role '{other}' is not 'local' or 'replica'"),
            )
        }
    };
    let simulate_receive_failure = reference
        .get("simulateReceiveFailure")
        .and_then(Value::as_bool)
        .ok_or_else(|| Failure {
            code: "invalid-config",
            message: "native.zfsReference requires boolean 'simulateReceiveFailure'".to_owned(),
        })?;

    let source_root = string_field(reference, "sourceRoot")?.to_owned();
    let source_dataset = string_field(reference, "sourceDataset")?.to_owned();
    let receiver_root = string_field(reference, "receiverRoot")?.to_owned();
    let scratch_root = string_field(reference, "scratchRoot")?.to_owned();

    let source_root_parts = dataset_components(&source_root).ok_or_else(|| Failure {
        code: "invalid-config",
        message: format!("sourceRoot '{source_root}' is not a valid dataset name"),
    })?;
    let source_dataset_parts = dataset_components(&source_dataset).ok_or_else(|| Failure {
        code: "invalid-config",
        message: format!("sourceDataset '{source_dataset}' is not a valid dataset name"),
    })?;
    let receiver_parts = dataset_components(&receiver_root).ok_or_else(|| Failure {
        code: "invalid-config",
        message: format!("receiverRoot '{receiver_root}' is not a valid dataset name"),
    })?;
    let scratch_parts = dataset_components(&scratch_root).ok_or_else(|| Failure {
        code: "invalid-config",
        message: format!("scratchRoot '{scratch_root}' is not a valid dataset name"),
    })?;

    if !dataset_within(&source_root_parts, &source_dataset_parts) {
        return fail(
            "config-ancestry",
            format!("sourceDataset '{source_dataset}' is outside sourceRoot '{source_root}'"),
        );
    }
    if receiver_parts.first().map(String::as_str) != Some(RECEIVER_POOL) {
        return fail(
            "config-ancestry",
            format!("receiverRoot '{receiver_root}' is outside pool root '{RECEIVER_POOL}'"),
        );
    }
    if scratch_parts.first().map(String::as_str) != Some(RECEIVER_POOL) {
        return fail(
            "config-ancestry",
            format!("scratchRoot '{scratch_root}' is outside pool root '{RECEIVER_POOL}'"),
        );
    }
    for (left_name, left, right_name, right) in [
        (
            "sourceRoot",
            &source_root_parts,
            "receiverRoot",
            &receiver_parts,
        ),
        (
            "sourceRoot",
            &source_root_parts,
            "scratchRoot",
            &scratch_parts,
        ),
        (
            "receiverRoot",
            &receiver_parts,
            "scratchRoot",
            &scratch_parts,
        ),
    ] {
        if datasets_overlap(left, right) {
            return fail(
                "config-ancestry",
                format!("{left_name} and {right_name} dataset roots overlap"),
            );
        }
    }

    let source_mount_root = clean_absolute_path(string_field(reference, "sourceMountRoot")?)
        .ok_or_else(|| Failure {
            code: "invalid-config",
            message: "sourceMountRoot must be a normalized absolute path".to_owned(),
        })?;
    let scratch_mount_root = clean_absolute_path(string_field(reference, "scratchMountRoot")?)
        .ok_or_else(|| Failure {
            code: "invalid-config",
            message: "scratchMountRoot must be a normalized absolute path".to_owned(),
        })?;

    Ok(ZfsReference {
        role,
        source_dataset,
        source_mount_root,
        receiver_root,
        scratch_root,
        scratch_mount_root,
        simulate_receive_failure,
    })
}

fn expect_props(name: &str, checks: &[(&str, &str)]) -> Result<()> {
    let props: Vec<&str> = checks.iter().map(|(prop, _)| *prop).collect();
    let got = zfs_props(name, &props).map_err(|error| Failure {
        code: error.code,
        message: format!("could not inspect {name}: {}", error.message),
    })?;
    for (prop, want) in checks {
        match got.get(*prop).map(String::as_str) {
            Some(actual) if actual == *want => {}
            other => {
                return fail(
                    "hostile-properties",
                    format!("{name} property {prop} is {other:?}, expected '{want}'"),
                )
            }
        }
    }
    Ok(())
}

fn preflight_source(config: &ZfsReference) -> Result<()> {
    expect_props(
        &config.source_dataset,
        &[
            (
                "mountpoint",
                config.source_mount_root.to_str().unwrap_or(""),
            ),
            ("sharenfs", "off"),
            ("sharesmb", "off"),
            ("acltype", "posix"),
            ("xattr", "sa"),
        ],
    )
}

fn preflight_receiver(config: &ZfsReference) -> Result<()> {
    expect_props(
        &config.receiver_root,
        &[
            ("mountpoint", "none"),
            ("canmount", "off"),
            ("sharenfs", "off"),
            ("sharesmb", "off"),
        ],
    )
}

fn preflight_scratch(config: &ZfsReference) -> Result<()> {
    expect_props(
        &config.scratch_root,
        &[
            (
                "mountpoint",
                config.scratch_mount_root.to_str().unwrap_or(""),
            ),
            ("sharenfs", "off"),
            ("sharesmb", "off"),
        ],
    )
}

fn iso8601(epoch_seconds: u64) -> String {
    let days = epoch_seconds / 86_400;
    let secs = epoch_seconds % 86_400;
    let z = days as i64 + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let year = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { year + 1 } else { year };
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        secs / 3600,
        (secs % 3600) / 60,
        secs % 60
    )
}

fn point_from_snapshot(
    request: &Value,
    snapshot_name: &str,
    props: &BTreeMap<String, String>,
) -> Option<Value> {
    if props.get(PROP_COMPLETE).map(String::as_str) != Some("on") {
        return None;
    }
    if props.get(PROP_STATE_ID).map(String::as_str)
        != request.get("stateId").and_then(Value::as_str)
    {
        return None;
    }
    let present = |key: &str| -> Option<&String> {
        props
            .get(key)
            .filter(|value| !value.is_empty() && value.as_str() != "-")
    };
    let guid = present("guid")?.clone();
    let capture_id = present(PROP_CAPTURE_ID)?.clone();
    if present(PROP_SOURCE_GUID) != Some(&guid) {
        return None;
    }
    let creation = props
        .get("creation")
        .cloned()
        .unwrap_or_else(|| "0".to_owned());
    let captured_at = creation
        .parse::<u64>()
        .map(iso8601)
        .unwrap_or_else(|_| creation.clone());
    let dataset = snapshot_name.split('@').next().unwrap_or(snapshot_name);
    Some(json!({
        "stateId": request.get("stateId"),
        "routeId": request.get("routeId"),
        "targetId": request.get("targetId"),
        "owner": OWNER,
        "nativeId": guid,
        "captureId": capture_id,
        "capturedAt": captured_at,
        "retainedAt": captured_at,
        "completion": "complete",
        "consistency": "filesystem",
        "scope": {"kind": "single-zfs-dataset", "recursive": false},
        "nativeRepresentation": {"kind": NATIVE_KIND, "name": snapshot_name},
        "payloadRepresentation": null,
        "verification": [{"kind": "zfs-native-property-check", "status": "passed"}],
        "producerProvenance": {},
        "ownerProvenance": {
            "zfs.name": snapshot_name,
            "zfs.dataset": dataset,
            "zfs.guid": guid,
            "zfs.creation": creation,
            "zfs.captureId": capture_id,
            "zfs.sourceGuid": guid,
        },
    }))
}

fn discover_points(config: &ZfsReference, request: &Value) -> Result<Vec<Value>> {
    let names: Vec<String> = match config.role {
        Role::Local => {
            if !dataset_exists(&config.source_dataset)? {
                return Ok(Vec::new());
            }
            snapshot_names(&config.source_dataset)?
                .into_iter()
                .filter(|name| name.starts_with(&format!("{}@", config.source_dataset)))
                .collect()
        }
        Role::Replica => {
            if !dataset_exists(&config.receiver_root)? {
                return Ok(Vec::new());
            }
            snapshot_names(&config.receiver_root)?
                .into_iter()
                .filter(|name| {
                    name.split('@')
                        .next()
                        .and_then(|ds| direct_child_name(&config.receiver_root, ds))
                        .is_some()
                })
                .collect()
        }
    };
    let wanted = [
        "guid",
        "creation",
        PROP_STATE_ID,
        PROP_CAPTURE_ID,
        PROP_SOURCE_GUID,
        PROP_COMPLETE,
    ];
    let mut points = Vec::new();
    for name in names {
        let props = zfs_props(&name, &wanted)?;
        if let Some(point) = point_from_snapshot(request, &name, &props) {
            points.push(point);
        }
    }
    Ok(points)
}

fn request_str<'a>(request: &'a Value, key: &str) -> Result<&'a str> {
    request
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| Failure {
            code: "invalid-request",
            message: format!("request requires string '{key}'"),
        })
}

fn handle_describe() -> Value {
    json!({
        "kind": "describe",
        "adapterVersion": {
            "protocolVersion": PROTOCOL_VERSION,
            "implementation": "homelab-preserve-zfs-reference",
            "implementationVersion": env!("CARGO_PKG_VERSION"),
            "fixtureOnly": true,
        },
        "capabilities": ["describe", "status", "points", "run", "restore", "verify"],
        "explicitScratch": true,
    })
}

fn handle_status(config: &ZfsReference, request: &Value) -> Result<Value> {
    let observed = match config.role {
        Role::Local => dataset_exists(&config.source_dataset)?,
        Role::Replica => dataset_exists(&config.receiver_root)?,
    };
    let points = if observed {
        discover_points(config, request)?
    } else {
        Vec::new()
    };
    Ok(json!({
        "kind": "status",
        "evidence": if observed { "observed" } else { "configured" },
        "catalogObserved": observed,
        "pointCount": points.len(),
        "details": {
            "role": if config.role == Role::Local { "local" } else { "replica" },
            "empty": observed && points.is_empty(),
        },
    }))
}

fn handle_points(config: &ZfsReference, request: &Value) -> Result<Value> {
    Ok(json!({
        "kind": "points",
        "points": discover_points(config, request)?,
    }))
}

fn capture_name() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!("preserve-{nanos}-{}", std::process::id())
}

fn handle_run(config: &ZfsReference, request: &Value) -> Result<Value> {
    preflight_source(config)?;
    preflight_receiver(config)?;

    let capture = capture_name();
    let snapshot = format!("{}@{}", config.source_dataset, capture);
    zfs_output(&["snapshot".to_owned(), snapshot.clone()])?;

    let state_id = request_str(request, "stateId")?;
    let guid = zfs_prop(&snapshot, "guid")?;
    zfs_set(&snapshot, PROP_STATE_ID, state_id)?;
    zfs_set(&snapshot, PROP_CAPTURE_ID, &capture)?;
    zfs_set(&snapshot, PROP_SOURCE_GUID, &guid)?;
    zfs_set(&snapshot, PROP_COMPLETE, "on")?;

    let receiver_child = format!("{}/{}", config.receiver_root, capture);
    if config.simulate_receive_failure {
        send_receive(&snapshot, &receiver_child, "none", "off")?;
        let received = format!("{receiver_child}@{capture}");
        zfs_set(&received, PROP_STATE_ID, state_id)?;
        zfs_set(&received, PROP_CAPTURE_ID, &capture)?;
        zfs_set(&received, PROP_SOURCE_GUID, &guid)?;
        return fail(
            "injected-receive-failure",
            format!("fixture receive failure left {receiver_child} without a complete point"),
        );
    }

    send_receive(&snapshot, &receiver_child, "none", "off")?;
    let received = format!("{receiver_child}@{capture}");
    let received_guid = zfs_prop(&received, "guid")?;
    if received_guid != guid {
        return fail(
            "guid-mismatch",
            format!("received snapshot guid {received_guid} does not match source guid {guid}"),
        );
    }
    zfs_set(&received, PROP_STATE_ID, state_id)?;
    zfs_set(&received, PROP_CAPTURE_ID, &capture)?;
    zfs_set(&received, PROP_SOURCE_GUID, &guid)?;
    zfs_set(&received, PROP_COMPLETE, "on")?;

    Ok(json!({
        "kind": "run",
        "evidence": "retained",
        "details": {
            "nativeId": guid,
            "captureId": capture,
            "sourceSnapshot": snapshot,
            "receiverDataset": receiver_child,
        },
    }))
}

fn validated_destination(config: &ZfsReference, request: &Value) -> Result<(String, PathBuf)> {
    let destination = request.get("destination").ok_or_else(|| Failure {
        code: "invalid-request",
        message: "request requires a scratch destination".to_owned(),
    })?;
    let new_name = destination
        .get("newName")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if !valid_new_name(new_name) {
        return fail(
            "unsafe-destination-name",
            "scratch destination name must be one safe dataset component",
        );
    }
    let native_locator = destination
        .get("nativeLocator")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let expected_locator = format!("{}/{new_name}", config.scratch_root);
    if native_locator != expected_locator {
        return fail(
            "destination-ancestry",
            format!("native destination '{native_locator}' is not a direct child of configured scratchRoot"),
        );
    }
    let native_locator = expected_locator;
    let path = PathBuf::from(
        destination
            .get("path")
            .and_then(Value::as_str)
            .unwrap_or_default(),
    );
    let expected_path = config.scratch_mount_root.join(new_name);
    if path != expected_path {
        return fail(
            "destination-ancestry",
            format!(
                "destination path {} is not a direct child of configured scratchMountRoot",
                path.display()
            ),
        );
    }
    Ok((native_locator, path))
}

fn fresh_destination(config: &ZfsReference, request: &Value) -> Result<(String, PathBuf)> {
    let (native_locator, path) = validated_destination(config, request)?;
    if dataset_exists(&native_locator)? {
        return fail(
            "destination-exists",
            format!("native destination '{native_locator}' already exists"),
        );
    }
    if path.exists() {
        return fail(
            "destination-exists",
            format!("destination path {} already exists", path.display()),
        );
    }
    Ok((native_locator, path))
}

fn selected_snapshot(config: &ZfsReference, request: &Value) -> Result<String> {
    let point = request.get("point").ok_or_else(|| Failure {
        code: "invalid-request",
        message: "request requires the selected native point".to_owned(),
    })?;
    let native_id = point
        .get("nativeId")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let capture_id = point.get("captureId").and_then(Value::as_str);
    for candidate in discover_points(config, request)? {
        if candidate.get("nativeId").and_then(Value::as_str) == Some(native_id)
            && candidate.get("captureId").and_then(Value::as_str) == capture_id
        {
            return Ok(candidate["nativeRepresentation"]["name"]
                .as_str()
                .unwrap_or_default()
                .to_owned());
        }
    }
    fail(
        "unknown-point",
        format!("native point '{native_id}' is not a complete point on this route"),
    )
}

fn handle_restore(config: &ZfsReference, request: &Value) -> Result<Value> {
    let snapshot = selected_snapshot(config, request)?;
    let (native_locator, path) = fresh_destination(config, request)?;
    match config.role {
        Role::Local => preflight_source(config)?,
        Role::Replica => preflight_receiver(config)?,
    }
    preflight_scratch(config)?;

    let (final_locator, final_path) = fresh_destination(config, request)?;
    if final_locator != native_locator || final_path != path {
        return fail(
            "destination-changed",
            "scratch destination changed between preflight and receive",
        );
    }
    send_receive(
        &snapshot,
        &native_locator,
        path.to_str().unwrap_or_default(),
        "noauto",
    )?;
    zfs_output(&["mount".to_owned(), native_locator.clone()])?;

    let guid = zfs_prop(&snapshot, "guid")?;
    let capture_id = request
        .get("point")
        .and_then(|point| point.get("captureId"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    zfs_set(
        &native_locator,
        PROP_STATE_ID,
        request_str(request, "stateId")?,
    )?;
    zfs_set(&native_locator, PROP_CAPTURE_ID, capture_id)?;
    zfs_set(&native_locator, PROP_SOURCE_GUID, &guid)?;
    zfs_set(&native_locator, PROP_COMPLETE, "on")?;

    let snapshot_part = snapshot.split('@').nth(1).unwrap_or_default();
    Ok(json!({
        "kind": "restore",
        "ownerReceipt": {
            "restoredDataset": native_locator,
            "restoredSnapshot": format!("{native_locator}@{snapshot_part}"),
            "sourceGuid": guid,
            "captureId": capture_id,
            "expectedPath": path,
        },
    }))
}

fn handle_verify(config: &ZfsReference, request: &Value) -> Result<Value> {
    let (native_locator, path) = validated_destination(config, request)?;
    if !dataset_exists(&native_locator)? {
        return fail(
            "verify-missing",
            format!("restored dataset '{native_locator}' does not exist"),
        );
    }
    let receipt = request.get("receipt").ok_or_else(|| Failure {
        code: "invalid-request",
        message: "verify requires the restore receipt".to_owned(),
    })?;
    let receipt_locator = receipt
        .get("destination")
        .and_then(|dest| dest.get("nativeLocator"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    if receipt_locator != native_locator {
        return fail(
            "receipt-mismatch",
            "receipt destination does not match the verified scratch dataset",
        );
    }
    let restored_snapshot = receipt
        .get("ownerReceipt")
        .and_then(|owner| owner.get("restoredSnapshot"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    let expected_prefix = format!("{native_locator}@");
    if !restored_snapshot.starts_with(&expected_prefix) {
        return fail(
            "receipt-mismatch",
            "receipt restored snapshot is not on the verified scratch dataset",
        );
    }

    let props = zfs_props(
        &native_locator,
        &[
            "mountpoint",
            PROP_STATE_ID,
            PROP_CAPTURE_ID,
            PROP_SOURCE_GUID,
            PROP_COMPLETE,
        ],
    )?;
    if props.get("mountpoint").map(String::as_str) != path.to_str() {
        return fail(
            "verify-mountpoint",
            format!("{native_locator} is not mounted at {}", path.display()),
        );
    }
    if props.get(PROP_COMPLETE).map(String::as_str) != Some("on") {
        return fail(
            "verify-incomplete",
            format!("{native_locator} is not a complete restored dataset"),
        );
    }
    let point = request.get("point").cloned().unwrap_or(Value::Null);
    if props.get(PROP_STATE_ID).map(String::as_str) != Some(request_str(request, "stateId")?) {
        return fail("verify-scope", "restored dataset state identity differs");
    }
    if props.get(PROP_SOURCE_GUID).map(String::as_str)
        != point.get("nativeId").and_then(Value::as_str)
    {
        return fail(
            "verify-scope",
            "restored dataset source guid does not match the verified point",
        );
    }
    if props.get(PROP_CAPTURE_ID).map(String::as_str)
        != point.get("captureId").and_then(Value::as_str)
    {
        return fail(
            "verify-scope",
            "restored dataset capture id does not match the verified point",
        );
    }

    let diff = zfs_output(&["diff".to_owned(), restored_snapshot.to_owned()])?;
    let divergence: Vec<&str> = diff
        .lines()
        .filter(|line| !line.trim().is_empty())
        .collect();
    let verified = divergence.is_empty();
    Ok(json!({
        "kind": "verify",
        "verified": verified,
        "evidence": if verified { "verified" } else { "failed" },
        "scope": "single-zfs-dataset",
        "details": {
            "dataset": native_locator,
            "snapshot": restored_snapshot,
            "divergentEntries": divergence,
        },
    }))
}

fn dispatch(request: &Value) -> Result<Value> {
    match request_str(request, "operation")? {
        "describe" => Ok(handle_describe()),
        "status" => handle_status(&parse_config(request)?, request),
        "points" => handle_points(&parse_config(request)?, request),
        "run" => handle_run(&parse_config(request)?, request),
        "restore" => handle_restore(&parse_config(request)?, request),
        "verify" => handle_verify(&parse_config(request)?, request),
        other => fail(
            "unsupported-operation",
            format!("operation '{other}' is not part of protocol version {PROTOCOL_VERSION}"),
        ),
    }
}

fn protocol() -> i32 {
    let mut raw = Vec::new();
    let request_id = match std::io::stdin()
        .by_ref()
        .take((MAX_REQUEST_BYTES + 1) as u64)
        .read_to_end(&mut raw)
    {
        Ok(_) if raw.len() > MAX_REQUEST_BYTES => {
            respond(
                "unknown",
                None,
                Some(("request-too-large", "request too large".to_owned())),
            );
            return 0;
        }
        Ok(_) => match serde_json::from_slice::<Value>(&raw) {
            Ok(request) => {
                let id = request
                    .get("requestId")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown")
                    .to_owned();
                match request.get("protocolVersion").and_then(Value::as_u64) {
                    Some(version) if version == PROTOCOL_VERSION as u64 => match dispatch(&request)
                    {
                        Ok(result) => respond(&id, Some(result), None),
                        Err(failure) => respond(&id, None, Some((failure.code, failure.message))),
                    },
                    _ => respond(
                        &id,
                        None,
                        Some((
                            "incompatible-version",
                            format!("expected protocol version {PROTOCOL_VERSION}"),
                        )),
                    ),
                }
            }
            Err(error) => respond(
                "unknown",
                None,
                Some((
                    "malformed-request",
                    format!("invalid request JSON: {error}"),
                )),
            ),
        },
        Err(error) => respond(
            "unknown",
            None,
            Some(("request-read", format!("could not read request: {error}"))),
        ),
    };
    let _ = request_id;
    0
}

fn respond(request_id: &str, result: Option<Value>, error: Option<(&str, String)>) {
    let mut response = Map::new();
    response.insert("protocolVersion".to_owned(), json!(PROTOCOL_VERSION));
    response.insert("requestId".to_owned(), json!(request_id));
    match (result, error) {
        (Some(value), None) => {
            response.insert("result".to_owned(), value);
        }
        (None, Some((code, message))) => {
            response.insert(
                "error".to_owned(),
                json!({"code": code, "message": message}),
            );
        }
        _ => {
            response.insert(
                "error".to_owned(),
                json!({"code": "internal", "message": "adapter produced no result"}),
            );
        }
    }
    println!(
        "{}",
        serde_json::to_string(&Value::Object(response)).unwrap_or_default()
    );
}

fn main() {
    match std::env::args().nth(1).as_deref() {
        Some("protocol") => std::process::exit(protocol()),
        _ => {
            eprintln!("usage: homelab-preserve-zfs-reference protocol");
            std::process::exit(2);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config_value(overrides: &[(&str, Value)]) -> Value {
        let mut reference = serde_json::Map::new();
        reference.insert("referenceOnly".to_owned(), json!(true));
        reference.insert("role".to_owned(), json!("local"));
        reference.insert("sourceRoot".to_owned(), json!("source"));
        reference.insert("sourceDataset".to_owned(), json!("source/state"));
        reference.insert("sourceMountRoot".to_owned(), json!("/source"));
        reference.insert("receiverRoot".to_owned(), json!("receiver/copies"));
        reference.insert("scratchRoot".to_owned(), json!("receiver/scratch"));
        reference.insert("scratchMountRoot".to_owned(), json!("/restore"));
        reference.insert("simulateReceiveFailure".to_owned(), json!(false));
        for (key, value) in overrides {
            if value.is_null() {
                reference.remove(*key);
            } else {
                reference.insert((*key).to_owned(), value.clone());
            }
        }
        json!({"ownerPayload": {"native": {"zfsReference": Value::Object(reference)}}})
    }

    fn parse(overrides: &[(&str, Value)]) -> Result<ZfsReference> {
        parse_config(&config_value(overrides))
    }

    #[test]
    fn valid_config_parses() {
        let config = parse(&[]).expect("fixture config parses");
        assert_eq!(config.role, Role::Local);
        assert!(!config.simulate_receive_failure);
    }

    #[test]
    fn replica_role_parses() {
        let config = parse(&[("role", json!("replica"))]).expect("replica role parses");
        assert_eq!(config.role, Role::Replica);
    }

    #[test]
    fn rejects_missing_reference_config() {
        let request = json!({"ownerPayload": {"native": {}}});
        assert!(parse_config(&request).is_err());
    }

    #[test]
    fn rejects_reference_only_false() {
        assert!(parse(&[("referenceOnly", json!(false))]).is_err());
    }

    #[test]
    fn rejects_unknown_authority_keys() {
        assert!(parse(&[("adminDataset", json!("other/root"))]).is_err());
    }

    #[test]
    fn rejects_unknown_role() {
        assert!(parse(&[("role", json!("admin"))]).is_err());
    }

    #[test]
    fn rejects_source_dataset_outside_root() {
        assert!(parse(&[("sourceDataset", json!("elsewhere/state"))]).is_err());
    }

    #[test]
    fn ancestry_is_component_wise() {
        assert!(parse(&[("sourceDataset", json!("source/state/child"))]).is_ok());
        assert!(parse(&[("sourceRoot", json!("sourceX"))]).is_err());
        assert!(parse(&[("sourceDataset", json!("sourceX/state"))]).is_err());
    }

    #[test]
    fn rejects_receiver_and_scratch_outside_pool() {
        assert!(parse(&[("receiverRoot", json!("elsewhere/copies"))]).is_err());
        assert!(parse(&[("scratchRoot", json!("elsewhere/scratch"))]).is_err());
    }

    #[test]
    fn rejects_overlapping_roots() {
        assert!(parse(&[("scratchRoot", json!("receiver/copies/inside"))]).is_err());
        assert!(parse(&[("receiverRoot", json!("receiver"))]).is_err());
        assert!(parse(&[("scratchRoot", json!("receiver/copies"))]).is_err());
    }

    #[test]
    fn rejects_relative_and_traversing_mount_roots() {
        assert!(parse(&[("sourceMountRoot", json!("relative/source"))]).is_err());
        assert!(parse(&[("scratchMountRoot", json!("/restore/../escape"))]).is_err());
    }

    #[test]
    fn direct_child_names_are_exact() {
        assert_eq!(
            direct_child_name("receiver/copies", "receiver/copies/one"),
            Some("one".to_owned())
        );
        assert_eq!(
            direct_child_name("receiver/copies", "receiver/copies"),
            None
        );
        assert_eq!(
            direct_child_name("receiver/copies", "receiver/copies/a/b"),
            None
        );
        assert_eq!(
            direct_child_name("receiver/copies", "other/copies/one"),
            None
        );
    }

    #[test]
    fn new_names_are_component_safe() {
        assert!(valid_new_name("scratch-1"));
        assert!(!valid_new_name("../escape"));
        assert!(!valid_new_name("a/b"));
        assert!(!valid_new_name("a\\b"));
        assert!(!valid_new_name(""));
    }

    #[test]
    fn receive_arguments_are_minimal_and_safe() {
        let args = receive_args("receiver/scratch/one", "/restore/one", "noauto");
        assert!(args.contains(&"-u".to_owned()));
        assert!(args.contains(&"mountpoint=/restore/one".to_owned()));
        assert!(args.contains(&"canmount=noauto".to_owned()));
        assert!(args.contains(&"sharenfs=off".to_owned()));
        assert!(args.contains(&"sharesmb=off".to_owned()));
        assert!(args.contains(&"acltype=posix".to_owned()));
        assert!(args.contains(&"xattr=sa".to_owned()));
        for forbidden in ["-F", "-d", "-e", "-i", "-I", "-s"] {
            assert!(
                !args.contains(&forbidden.to_owned()),
                "unexpected flag {forbidden}"
            );
        }
    }

    #[test]
    fn point_filter_requires_complete_matching_props() {
        let request = json!({"stateId": "fixture/state", "routeId": "r", "targetId": "t"});
        let mut props = BTreeMap::new();
        props.insert("guid".to_owned(), "123".to_owned());
        props.insert("creation".to_owned(), "1700000000".to_owned());
        props.insert(PROP_COMPLETE.to_owned(), "on".to_owned());
        props.insert(PROP_STATE_ID.to_owned(), "fixture/state".to_owned());
        props.insert(PROP_CAPTURE_ID.to_owned(), "cap-1".to_owned());
        props.insert(PROP_SOURCE_GUID.to_owned(), "123".to_owned());
        let point = point_from_snapshot(&request, "source/state@cap-1", &props)
            .expect("complete matching snapshot becomes a point");
        assert_eq!(point["nativeId"], "123");
        assert_eq!(point["captureId"], "cap-1");
        assert_eq!(point["nativeRepresentation"]["kind"], NATIVE_KIND);
        assert_eq!(point["ownerProvenance"]["zfs.captureId"], "cap-1");
        assert_eq!(point["ownerProvenance"]["zfs.sourceGuid"], "123");

        let mut incomplete = props.clone();
        incomplete.insert(PROP_COMPLETE.to_owned(), "off".to_owned());
        assert!(point_from_snapshot(&request, "source/state@cap-1", &incomplete).is_none());

        let mut other_state = props.clone();
        other_state.insert(PROP_STATE_ID.to_owned(), "other/state".to_owned());
        assert!(point_from_snapshot(&request, "source/state@cap-1", &other_state).is_none());
    }

    #[test]
    fn point_filter_rejects_missing_or_mismatched_mapping() {
        let request = json!({"stateId": "fixture/state", "routeId": "r", "targetId": "t"});
        let mut props = BTreeMap::new();
        props.insert("guid".to_owned(), "123".to_owned());
        props.insert("creation".to_owned(), "1700000000".to_owned());
        props.insert(PROP_COMPLETE.to_owned(), "on".to_owned());
        props.insert(PROP_STATE_ID.to_owned(), "fixture/state".to_owned());
        props.insert(PROP_CAPTURE_ID.to_owned(), "cap-1".to_owned());
        props.insert(PROP_SOURCE_GUID.to_owned(), "123".to_owned());

        let mut no_capture = props.clone();
        no_capture.remove(PROP_CAPTURE_ID);
        assert!(point_from_snapshot(&request, "source/state@cap-1", &no_capture).is_none());

        let mut unset_capture = props.clone();
        unset_capture.insert(PROP_CAPTURE_ID.to_owned(), "-".to_owned());
        assert!(point_from_snapshot(&request, "source/state@cap-1", &unset_capture).is_none());

        let mut no_source_guid = props.clone();
        no_source_guid.remove(PROP_SOURCE_GUID);
        assert!(point_from_snapshot(&request, "source/state@cap-1", &no_source_guid).is_none());

        let mut unset_source_guid = props.clone();
        unset_source_guid.insert(PROP_SOURCE_GUID.to_owned(), "-".to_owned());
        assert!(point_from_snapshot(&request, "source/state@cap-1", &unset_source_guid).is_none());

        let mut mismatched = props.clone();
        mismatched.insert(PROP_SOURCE_GUID.to_owned(), "999".to_owned());
        assert!(point_from_snapshot(&request, "source/state@cap-1", &mismatched).is_none());
    }

    #[test]
    fn overlap_compares_whole_components() {
        let parts = |name: &str| dataset_components(name).unwrap();
        assert!(datasets_overlap(&parts("a"), &parts("a/b")));
        assert!(datasets_overlap(&parts("a/b"), &parts("a")));
        assert!(datasets_overlap(&parts("a"), &parts("a")));
        assert!(!datasets_overlap(&parts("a"), &parts("ab")));
        assert!(!datasets_overlap(&parts("a/b"), &parts("a/c")));
        assert!(!datasets_overlap(
            &parts("source"),
            &parts("receiver/copies")
        ));
    }

    #[test]
    fn absolute_paths_must_be_normalized() {
        assert_eq!(
            clean_absolute_path("/restore"),
            Some(PathBuf::from("/restore"))
        );
        assert_eq!(
            clean_absolute_path("/restore/child"),
            Some(PathBuf::from("/restore/child"))
        );
        assert_eq!(clean_absolute_path("relative/root"), None);
        assert_eq!(clean_absolute_path("/restore/../escape"), None);
        assert_eq!(clean_absolute_path(""), None);
    }

    #[test]
    fn iso8601_formats_unix_seconds() {
        assert_eq!(iso8601(0), "1970-01-01T00:00:00Z");
        assert_eq!(iso8601(1_700_000_000), "2023-11-14T22:13:20Z");
        assert_eq!(iso8601(951_827_393), "2000-02-29T12:29:53Z");
    }
}
