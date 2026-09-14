use homelab_preserve::{
    load_document, load_receipt, plan, points, restore, run, status, verify, PreserveError, Result,
};
use serde::Serialize;
use serde_json::Value;
use std::path::{Path, PathBuf};

struct Cli {
    manifest: PathBuf,
    json: bool,
    command: Vec<String>,
}

fn usage() -> &'static str {
    "usage: homelab-preserve --manifest <path> [--json] <plan|status|points|run|restore|verify> ..."
}

fn parse_cli() -> Result<Cli> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        println!("{}", usage());
        std::process::exit(0);
    }
    let json = if let Some(index) = args.iter().position(|arg| arg == "--json") {
        args.remove(index);
        true
    } else {
        false
    };
    let manifest_index = args
        .iter()
        .position(|arg| arg == "--manifest")
        .ok_or_else(|| {
            PreserveError::new("usage", format!("--manifest is required; {}", usage()))
        })?;
    if manifest_index + 1 >= args.len() {
        return Err(PreserveError::new("usage", "--manifest requires a path"));
    }
    let manifest = PathBuf::from(args.remove(manifest_index + 1));
    args.remove(manifest_index);
    if args.is_empty() {
        return Err(PreserveError::new("usage", usage()));
    }
    Ok(Cli {
        manifest,
        json,
        command: args,
    })
}

fn flag_value(args: &[String], flag: &str) -> Result<String> {
    let index = args
        .iter()
        .position(|arg| arg == flag)
        .ok_or_else(|| PreserveError::new("usage", format!("{flag} is required")))?;
    args.get(index + 1)
        .filter(|value| !value.starts_with("--"))
        .cloned()
        .ok_or_else(|| PreserveError::new("usage", format!("{flag} requires a value")))
}

fn reject_unknown_flags(args: &[String], allowed: &[&str]) -> Result<()> {
    for arg in args {
        if arg.starts_with("--") && !allowed.contains(&arg.as_str()) {
            return Err(PreserveError::new(
                "usage",
                format!("unrecognized flag '{arg}'; {}", usage()),
            ));
        }
    }
    Ok(())
}

fn print_json<T: Serialize>(value: &T) -> Result<()> {
    let output = serde_json::to_string_pretty(value).map_err(|error| {
        PreserveError::new(
            "output-json",
            format!("could not serialize output: {error}"),
        )
    })?;
    println!("{output}");
    Ok(())
}

fn text(value: &Value) -> String {
    value
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| value.to_string())
}

fn print_issues(indent: &str, issues: Option<&Vec<Value>>) {
    if let Some(issues) = issues {
        for issue in issues {
            let code = issue.get("code").and_then(Value::as_str).unwrap_or("issue");
            let message = issue.get("message").and_then(Value::as_str).unwrap_or("");
            println!("{indent}issue {code}: {message}");
        }
    }
}

fn print_plan(value: &Value) {
    let kind = value.get("kind").and_then(Value::as_str).unwrap_or("plan");
    let states = value
        .get("states")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    println!("{kind}: {states} state(s)");
    if let Some(entries) = value.get("states").and_then(Value::as_array) {
        for state in entries {
            let id = state
                .get("stateId")
                .and_then(Value::as_str)
                .unwrap_or("<unknown>");
            let mode = state
                .get("mode")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let operational = state
                .get("operational")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            println!("- {id}: mode={mode}, operational={operational}");
            print_issues("    ", state.get("issues").and_then(Value::as_array));
            if let Some(routes) = state.get("routes").and_then(Value::as_array) {
                for route in routes {
                    let route_id = route
                        .get("routeId")
                        .and_then(Value::as_str)
                        .unwrap_or("<unknown>");
                    let status = route
                        .get("status")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown");
                    let target = route.get("target").map_or("none".to_owned(), |target| {
                        format!(
                            "{} {}",
                            target
                                .get("targetId")
                                .and_then(Value::as_str)
                                .unwrap_or("<none>"),
                            target
                                .get("failureDomain")
                                .map_or("{}".to_owned(), |domain| domain.to_string())
                        )
                    });
                    let integration = route
                        .get("integration")
                        .and_then(|integration| integration.get("integrationId"))
                        .and_then(Value::as_str)
                        .unwrap_or("<none>");
                    println!("    route {route_id}: status={status}");
                    println!("      target: {target}");
                    println!("      integration: {integration}");
                    if let Some(requirements) = route.get("semanticRequirements") {
                        let required = requirements
                            .get("requiredConsistency")
                            .map_or("<none>".to_owned(), |v| text(v));
                        let guaranteed = route
                            .get("guaranteedConsistency")
                            .map_or("<none>".to_owned(), |v| text(v));
                        let fidelity = requirements
                            .get("requiredFidelity")
                            .map_or("[]".to_owned(), |v| v.to_string());
                        println!("      consistency: required={required}, guaranteed={guaranteed}");
                        println!("      fidelity: {fidelity}");
                    }
                    let payload = route
                        .get("payloadRepresentation")
                        .map_or("none".to_owned(), |v| text(v));
                    let native = route
                        .get("nativePointRepresentations")
                        .map_or("[]".to_owned(), |v| v.to_string());
                    println!("      payload representation: {payload}");
                    println!("      native point representations: {native}");
                    print_issues("      ", route.get("issues").and_then(Value::as_array));
                }
            }
        }
    }
}

fn print_status(value: &Value) {
    if let Some(states) = value.get("states").and_then(Value::as_array) {
        for state in states {
            let state_id = state
                .get("stateId")
                .and_then(Value::as_str)
                .unwrap_or("<unknown>");
            if let Some(routes) = state.get("routes").and_then(Value::as_array) {
                for route in routes {
                    let route_id = route
                        .get("routeId")
                        .and_then(Value::as_str)
                        .unwrap_or("<unknown>");
                    let evidence = route
                        .get("evidence")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown");
                    let observed = route
                        .get("observed")
                        .and_then(Value::as_bool)
                        .unwrap_or(false);
                    println!("{state_id} {route_id}: evidence={evidence}, observed={observed}");
                }
            }
        }
    }
}

fn execute(cli: &Cli) -> Result<()> {
    let document = load_document(&cli.manifest)?;
    let command = cli.command[0].as_str();
    match command {
        "plan" => {
            if cli.command.len() != 1 {
                return Err(PreserveError::new("usage", "plan takes no arguments"));
            }
            let result = plan(&document)?;
            if cli.json {
                print_json(&result)
            } else {
                print_plan(&result);
                Ok(())
            }
        }
        "status" => {
            reject_unknown_flags(&cli.command[1..], &["--observe"])?;
            if cli.command[1..].iter().any(|arg| !arg.starts_with("--")) {
                return Err(PreserveError::new(
                    "usage",
                    format!("status accepts only --observe; {}", usage()),
                ));
            }
            let observe = cli.command.iter().any(|arg| arg == "--observe");
            let result = status(&document, observe)?;
            if cli.json {
                print_json(&result)
            } else {
                print_status(&result);
                Ok(())
            }
        }
        "points" => {
            reject_unknown_flags(&cli.command[1..], &[])?;
            if cli.command.len() != 2 {
                return Err(PreserveError::new(
                    "usage",
                    format!("points requires exactly one state ID; {}", usage()),
                ));
            }
            let state_id = &cli.command[1];
            let result = points(&document, state_id)?;
            if cli.json {
                print_json(&result)
            } else {
                for point in result {
                    println!(
                        "{} {} {} {}",
                        point.state_id, point.route_id, point.target_id, point.native_id
                    );
                    for (key, value) in point.producer_provenance {
                        println!("  provenance {key}={value}");
                    }
                }
                Ok(())
            }
        }
        "run" => {
            reject_unknown_flags(&cli.command[1..], &["--route"])?;
            if cli.command.len() != 4
                || cli.command[1].starts_with('-')
                || cli.command[2] != "--route"
                || cli.command[3].starts_with('-')
            {
                return Err(PreserveError::new(
                    "usage",
                    format!("run requires exactly <state> --route <route>; {}", usage()),
                ));
            }
            let state_id = &cli.command[1];
            let route_id = &cli.command[3];
            let result = run(&document, state_id, route_id)?;
            if cli.json {
                print_json(&result)
            } else {
                println!("{} {}: {:?}", state_id, route_id, result.evidence);
                Ok(())
            }
        }
        "restore" => {
            reject_unknown_flags(
                &cli.command[1..],
                &["--from", "--point", "--to", "--execute", "--receipt"],
            )?;
            let state_id = cli
                .command
                .get(1)
                .filter(|arg| !arg.starts_with('-'))
                .ok_or_else(|| PreserveError::new("usage", "restore requires a state ID"))?;
            let route_id = flag_value(&cli.command, "--from")?;
            let point_id = flag_value(&cli.command, "--point")?;
            let to = flag_value(&cli.command, "--to")?;
            let (scratch_ref, new_name) = to.split_once(':').ok_or_else(|| {
                PreserveError::new("usage", "--to must be <scratch-capability>:<new-name>")
            })?;
            let execute = cli.command.iter().any(|arg| arg == "--execute");
            let receipt = if cli.command.iter().any(|arg| arg == "--receipt") {
                Some(PathBuf::from(flag_value(&cli.command, "--receipt")?))
            } else {
                None
            };
            let mut expected_len = 8;
            if execute {
                expected_len += 1;
            }
            if receipt.is_some() {
                expected_len += 2;
            }
            if cli.command.len() != expected_len {
                return Err(PreserveError::new(
                    "usage",
                    format!("restore accepts no additional arguments; {}", usage()),
                ));
            }
            if execute && receipt.is_none() {
                return Err(PreserveError::new(
                    "usage",
                    "executing restore requires --receipt <new-path>",
                ));
            }
            let result = restore(
                &document,
                state_id,
                &route_id,
                &point_id,
                scratch_ref,
                new_name,
                execute,
                receipt.as_deref(),
            )?;
            if cli.json {
                print_json(&result)
            } else if execute {
                println!("restored {state_id} point {point_id}; receipt written");
                Ok(())
            } else {
                println!("restore preflight passed; no mutation performed");
                Ok(())
            }
        }
        "verify" => {
            reject_unknown_flags(&cli.command[1..], &[])?;
            if cli.command.len() != 2 {
                return Err(PreserveError::new(
                    "usage",
                    format!("verify requires exactly one receipt path; {}", usage()),
                ));
            }
            let receipt_path = &cli.command[1];
            let receipt = load_receipt(Path::new(receipt_path))?;
            let result = verify(&document, receipt)?;
            if cli.json {
                print_json(&result)
            } else {
                println!("verified scope={}", result.scope);
                Ok(())
            }
        }
        _ => Err(PreserveError::new(
            "usage",
            format!("unknown command '{command}'; {}", usage()),
        )),
    }
}

fn main() {
    let cli = match parse_cli() {
        Ok(cli) => cli,
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(2);
        }
    };
    if let Err(error) = execute(&cli) {
        if cli.json {
            let envelope = serde_json::json!({ "error": error });
            eprintln!(
                "{}",
                serde_json::to_string(&envelope).unwrap_or_else(|_| "{\"error\":{}}".to_owned())
            );
        } else {
            eprintln!("error [{}]: {}", error.code, error.message);
        }
        std::process::exit(1);
    }
}
