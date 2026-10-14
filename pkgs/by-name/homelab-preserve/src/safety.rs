use crate::error::{PreserveError, Result};
use crate::model::{
    DestinationRequest, ProtectedRealization, ProtectedTarget, Realization, Route,
    ScratchDestination, State, TargetBoundaries,
};
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
    for ancestor in path.ancestors() {
        if let Ok(mut base) = fs::canonicalize(ancestor) {
            for component in path
                .strip_prefix(ancestor)
                .expect("path ancestor")
                .components()
            {
                match component {
                    Component::CurDir => {}
                    Component::ParentDir => {
                        base.pop();
                    }
                    other => base.push(other.as_os_str()),
                }
            }
            return base;
        }
    }
    lexical(path)
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

pub(crate) fn usable_realization(realization: &Realization) -> bool {
    let path = realization.path.as_ref();
    if path.is_some_and(|path| !path.is_absolute()) {
        return false;
    }
    if matches!(realization.kind.as_str(), "filesystem" | "host-filesystem") {
        return path.is_some();
    }
    // Opaque objects are not native fences. Only an explicit authoritative path
    // or the supported string-native locator can authorize a comparison.
    path.is_some() || realization.locator.as_str().is_some_and(|value| !value.is_empty())
}

pub(crate) fn valid_target_boundaries(boundaries: &TargetBoundaries) -> bool {
    boundaries.paths.iter().all(|path| path.is_absolute())
        && boundaries.native_locators.iter().all(|locator| !locator.is_empty())
        && (boundaries.native_locators.is_empty()
            || boundaries.native_namespace.as_deref().is_some_and(|value| !value.is_empty()))
}

pub(crate) fn nonempty_target_boundaries(boundaries: &TargetBoundaries) -> bool {
    !boundaries.paths.is_empty() || !boundaries.native_locators.is_empty()
}

pub fn preflight_destination(
    protected_realizations: &[ProtectedRealization],
    protected_targets: &[ProtectedTarget],
    state: &State,
    route: &Route,
    capability_ref: &str,
    scratch: &ScratchDestination,
    new_name: &str,
) -> Result<DestinationRequest> {
    let destination = authorize_destination(
        protected_realizations,
        protected_targets,
        state,
        route,
        capability_ref,
        scratch,
        new_name,
    )?;
    if destination.path.try_exists().map_err(|error| {
        PreserveError::new(
            "destination-inspect",
            format!("could not inspect destination: {error}"),
        )
        .context(&state.state_id, Some(&route.route_id))
    })? || fs::symlink_metadata(&destination.path).is_ok()
    {
        return Err(
            PreserveError::new("destination-exists", "scratch destination already exists")
                .context(&state.state_id, Some(&route.route_id)),
        );
    }
    Ok(destination)
}

pub(crate) fn authorize_destination(
    protected_realizations: &[ProtectedRealization],
    protected_targets: &[ProtectedTarget],
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
    if resolved(&destination) != destination {
        return Err(PreserveError::new(
            "destination-escape",
            "scratch destination escaped its configured root",
        )
        .context(&state.state_id, Some(&route.route_id)));
    }

    let native_locator = format!(
        "{}/{}",
        scratch.native_parent.trim_end_matches('/'),
        new_name
    );
    let native_namespace = route
        .target_boundaries
        .as_ref()
        .and_then(|boundaries| boundaries.native_namespace.as_deref())
        .filter(|namespace| !namespace.is_empty());
    for protected in protected_realizations {
        let realization = &protected.realization;
        if !usable_realization(realization) {
            return Err(PreserveError::new(
                "unusable-protected-realization",
                format!("State '{}' lacks a comparable authoritative source fence", protected.state_id),
            )
            .context(&state.state_id, Some(&route.route_id)));
        }
        if let Some(source) = &realization.path {
            if overlaps(&destination, &resolved(source)) {
                return Err(PreserveError::new(
                    "source-alias",
                    format!(
                        "scratch destination overlaps active State '{}'",
                        protected.state_id
                    ),
                )
                .context(&state.state_id, Some(&route.route_id)));
            }
        }
        if let Some(locator) = realization.locator.as_str() {
            if native_overlaps(&native_locator, locator) {
                return Err(PreserveError::new(
                    "source-alias",
                    format!(
                        "native scratch destination overlaps active State '{}'",
                        protected.state_id
                    ),
                )
                .context(&state.state_id, Some(&route.route_id)));
            }
        }
    }
    for protected in protected_targets {
        let boundaries = protected.target_boundaries.as_ref()
            .filter(|boundaries| nonempty_target_boundaries(boundaries))
            .ok_or_else(|| PreserveError::new(
                "missing-target-boundaries",
                format!(
                    "State '{}' Route '{}' Target '{}' lacks owner-resolved retained destination fences",
                    protected.state_id, protected.route_id, protected.target_id
                ),
            ).context(&state.state_id, Some(&route.route_id)))?;
        if boundaries.paths.iter().any(|path| !path.is_absolute())
            || boundaries.native_locators.iter().any(|locator| locator.is_empty())
        {
            return Err(PreserveError::new(
                "invalid-target-boundaries",
                "retained Target fences require absolute paths and nonempty native locators",
            ).context(&state.state_id, Some(&route.route_id)));
        }
        for path in &boundaries.paths {
            if overlaps(&destination, &resolved(path)) {
                return Err(PreserveError::new(
                    "target-alias",
                    format!(
                        "scratch destination overlaps retained Target on State '{}' Route '{}'",
                        protected.state_id, protected.route_id
                    ),
                )
                .context(&state.state_id, Some(&route.route_id)));
            }
        }
        if !boundaries.native_locators.is_empty()
            && (native_namespace.is_none()
                || boundaries.native_namespace.as_deref().is_none_or(str::is_empty))
        {
            return Err(PreserveError::new(
                "unknown-native-namespace",
                "native scratch destination cannot be checked against retained Target fences",
            )
            .context(&state.state_id, Some(&route.route_id)));
        }
        if boundaries.native_namespace.is_some()
            && boundaries.native_namespace.as_deref() == native_namespace
        {
            for locator in &boundaries.native_locators {
                if native_overlaps(&native_locator, locator) {
                    return Err(PreserveError::new(
                        "target-alias",
                        format!(
                            "native scratch destination overlaps retained Target on State '{}' Route '{}'",
                            protected.state_id, protected.route_id
                        ),
                    )
                    .context(&state.state_id, Some(&route.route_id)));
                }
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
