use crate::error::{PreserveError, Result};
use crate::model::{DestinationRequest, Route, ScratchDestination, State};
use std::fs;
use std::path::{Component, Path, PathBuf};

fn lexical(path: &Path) -> PathBuf {
    let mut result = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                result.pop();
            }
            other => result.push(other.as_os_str()),
        }
    }
    result
}

fn resolved(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| lexical(path))
}

fn overlaps(left: &Path, right: &Path) -> bool {
    left == right || left.starts_with(right) || right.starts_with(left)
}

fn native_overlaps(left: &str, right: &str) -> bool {
    left == right
        || left
            .strip_prefix(right)
            .is_some_and(|suffix| suffix.starts_with('/'))
        || right
            .strip_prefix(left)
            .is_some_and(|suffix| suffix.starts_with('/'))
}

pub fn preflight_destination(
    state: &State,
    route: &Route,
    capability_ref: &str,
    scratch: &ScratchDestination,
    new_name: &str,
) -> Result<DestinationRequest> {
    let mut components = Path::new(new_name).components();
    if new_name.is_empty()
        || new_name.contains('/')
        || new_name.contains('\\')
        || !matches!(components.next(), Some(Component::Normal(_)))
        || components.next().is_some()
    {
        return Err(PreserveError::new(
            "unsafe-destination-name",
            "scratch destination name must be one ordinary path component",
        )
        .context(&state.state_id, Some(&route.route_id)));
    }
    if !scratch.mount_root.is_absolute() {
        return Err(PreserveError::new(
            "unsafe-scratch-root",
            "scratch mount root must be absolute",
        )
        .context(&state.state_id, Some(&route.route_id)));
    }

    let root = fs::canonicalize(&scratch.mount_root).map_err(|error| {
        PreserveError::new(
            "unavailable-scratch-root",
            format!("could not resolve configured scratch root: {error}"),
        )
        .context(&state.state_id, Some(&route.route_id))
    })?;
    if !root.is_dir() {
        return Err(PreserveError::new(
            "unsafe-scratch-root",
            "configured scratch root is not a directory",
        )
        .context(&state.state_id, Some(&route.route_id)));
    }

    let destination = root.join(new_name);
    if destination.exists() {
        return Err(
            PreserveError::new("destination-exists", "scratch destination already exists")
                .context(&state.state_id, Some(&route.route_id)),
        );
    }
    if destination.parent() != Some(root.as_path()) {
        return Err(PreserveError::new(
            "destination-escape",
            "scratch destination escaped its configured root",
        )
        .context(&state.state_id, Some(&route.route_id)));
    }

    if let Some(source) = state
        .realization
        .as_ref()
        .and_then(|realization| realization.path.as_ref())
    {
        if overlaps(&destination, &resolved(source)) {
            return Err(PreserveError::new(
                "source-alias",
                "scratch destination overlaps the active realization",
            )
            .context(&state.state_id, Some(&route.route_id)));
        }
    }
    let native_locator = format!(
        "{}/{}",
        scratch.native_parent.trim_end_matches('/'),
        new_name
    );
    if let Some(realization) = &state.realization {
        if let Some(locator) = realization.locator.as_str() {
            if native_overlaps(&native_locator, locator) {
                return Err(PreserveError::new(
                    "source-alias",
                    "native scratch destination overlaps the active realization",
                )
                .context(&state.state_id, Some(&route.route_id)));
            }
        }
    }
    Ok(DestinationRequest {
        capability_ref: capability_ref.to_owned(),
        new_name: new_name.to_owned(),
        path: destination,
        native_locator,
    })
}
