use crate::error::{PreserveError, Result};
use crate::model::{Integration, ProtocolRequest, ProtocolResponse, PROTOCOL_VERSION};
use command_group::{CommandGroup, GroupChild};
#[cfg(unix)]
use command_group::{Signal, UnixChildExt};
use serde_json::Value;
use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MAX_REQUEST_BYTES: usize = 1_048_576;
const MAX_STDERR_BYTES: usize = 65_536;

fn terminate_group(child: &mut GroupChild) {
    #[cfg(unix)]
    {
        let _ = child.signal(Signal::SIGTERM);
        let deadline = Instant::now() + Duration::from_millis(250);
        while Instant::now() < deadline {
            match child.try_wait() {
                Ok(Some(_)) | Err(_) => break,
                Ok(None) => thread::sleep(Duration::from_millis(10)),
            }
        }
    }
    let _ = child.kill();
    let _ = child.wait();
}

fn read_bounded(mut reader: impl Read, limit: usize) -> std::result::Result<Vec<u8>, String> {
    let mut bytes = Vec::new();
    reader
        .by_ref()
        .take((limit + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|error| error.to_string())?;
    if bytes.len() > limit {
        return Err(format!("output exceeded {limit} bytes"));
    }
    Ok(bytes)
}

pub fn request_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!("{}-{nanos}", std::process::id())
}

pub fn invoke_adapter(integration: &Integration, request: &ProtocolRequest) -> Result<Value> {
    if integration.protocol_version != PROTOCOL_VERSION {
        return Err(PreserveError::new(
            "unsupported-adapter-version",
            format!(
                "integration '{}' requires protocol version {}, but this coordinator supports {}",
                integration.integration_id, integration.protocol_version, PROTOCOL_VERSION
            ),
        ));
    }
    if integration.max_response_bytes == 0 || integration.max_response_bytes > 16_777_216 {
        return Err(PreserveError::new(
            "invalid-response-limit",
            "adapter response limit must be between 1 and 16777216 bytes",
        ));
    }
    if !integration.adapter.is_absolute() {
        return Err(PreserveError::new(
            "invalid-adapter-path",
            format!(
                "configured adapter for integration '{}' is not an absolute path",
                integration.integration_id
            ),
        ));
    }

    let encoded = serde_json::to_vec(request).map_err(|error| {
        PreserveError::new(
            "request-serialization",
            format!("could not serialize adapter request: {error}"),
        )
    })?;
    if encoded.len() > MAX_REQUEST_BYTES {
        return Err(PreserveError::new(
            "request-too-large",
            format!("adapter request exceeded {MAX_REQUEST_BYTES} bytes"),
        ));
    }

    let mut command = Command::new(&integration.adapter);
    command
        .arg("protocol")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.group_spawn().map_err(|error| {
        PreserveError::new(
            "adapter-start",
            format!(
                "could not start configured adapter for integration '{}': {error}",
                integration.integration_id
            ),
        )
    })?;

    let stdout = child.inner().stdout.take().ok_or_else(|| {
        PreserveError::new("adapter-pipe", "configured adapter stdout was unavailable")
    })?;
    let stderr = child.inner().stderr.take().ok_or_else(|| {
        PreserveError::new("adapter-pipe", "configured adapter stderr was unavailable")
    })?;
    let stdin = child.inner().stdin.take().ok_or_else(|| {
        PreserveError::new("adapter-pipe", "configured adapter stdin was unavailable")
    })?;
    let response_limit = integration.max_response_bytes;
    let stdout_reader = thread::spawn(move || read_bounded(stdout, response_limit));
    let stderr_reader = thread::spawn(move || read_bounded(stderr, MAX_STDERR_BYTES));
    let stdin_writer = thread::spawn(move || {
        let mut stdin = stdin;
        stdin.write_all(&encoded).map_err(|error| {
            PreserveError::new(
                "adapter-input",
                format!("could not write adapter request: {error}"),
            )
        })
    });

    let deadline = Instant::now() + Duration::from_secs(integration.timeout_seconds);
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
            Ok(None) => {
                terminate_group(&mut child);
                let _ = stdout_reader.join();
                let _ = stderr_reader.join();
                let _ = stdin_writer.join();
                return Err(PreserveError::new(
                    "adapter-timeout",
                    format!(
                        "configured adapter timed out after {} seconds and was cancelled",
                        integration.timeout_seconds
                    ),
                ));
            }
            Err(error) => {
                terminate_group(&mut child);
                let _ = stdout_reader.join();
                let _ = stderr_reader.join();
                let _ = stdin_writer.join();
                return Err(PreserveError::new(
                    "adapter-wait",
                    format!("could not wait for configured adapter: {error}"),
                ));
            }
        }
    };

    let _ = child.kill();

    let write_result = stdin_writer
        .join()
        .map_err(|_| PreserveError::new("adapter-input", "adapter stdin writer panicked"))?;
    if let Err(error) = write_result {
        let _ = stdout_reader.join();
        let _ = stderr_reader.join();
        return Err(error);
    }

    let stdout = stdout_reader
        .join()
        .map_err(|_| PreserveError::new("adapter-output", "adapter stdout reader panicked"))?
        .map_err(|message| PreserveError::new("adapter-output", message))?;
    let stderr = stderr_reader
        .join()
        .map_err(|_| PreserveError::new("adapter-output", "adapter stderr reader panicked"))?
        .map_err(|message| PreserveError::new("adapter-output", message))?;

    if !status.success() {
        return Err(PreserveError::new(
            "adapter-exit",
            format!(
                "configured adapter exited unsuccessfully with {} stderr bytes",
                stderr.len()
            ),
        ));
    }

    let response: ProtocolResponse = serde_json::from_slice(&stdout).map_err(|error| {
        PreserveError::new(
            "malformed-adapter-response",
            format!("configured adapter returned invalid or truncated JSON: {error}"),
        )
    })?;
    if response.protocol_version != PROTOCOL_VERSION {
        return Err(PreserveError::new(
            "incompatible-protocol-version",
            format!(
                "adapter returned protocol version {}, expected {}",
                response.protocol_version, PROTOCOL_VERSION
            ),
        ));
    }
    if response.request_id != request.request_id {
        return Err(PreserveError::new(
            "request-id-mismatch",
            "adapter response requestId did not match the request",
        ));
    }

    match (response.result, response.error) {
        (Some(result), None) => Ok(result),
        (None, Some(error)) => Err(PreserveError::new(
            format!("adapter-{}", error.code),
            error.message,
        )),
        _ => Err(PreserveError::new(
            "invalid-adapter-envelope",
            "adapter response must contain exactly one of result or error",
        )),
    }
}
