{
  cacert,
  codexWorkerLane,
  git,
  patchedHermes,
  sandboxAccess,
  runCommand,
}:
runCommand "hermes-agent-patched-check" {
  nativeBuildInputs = [
    git
    patchedHermes.hermesVenv
  ];
} ''
  export PYTHONPATH=${patchedHermes.patchedSource}
  # Nix builders may expose a single-component, read-only HOME such as
  # /homeless-shelter. Native approval tests construct absolute home paths and
  # the detector intentionally ignores degenerate prefixes, so give the test
  # process a writable multi-component home instead.
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME"
  export PYTHONPYCACHEPREFIX=$TMPDIR/pycache
  export RUFF_CACHE_DIR=$TMPDIR/ruff-cache
  # Nix sets SSL_CERT_FILE=/no-cert-file.crt in pure builds. Two upstream
  # prompt-construction tests initialize an OpenAI client and validate the CA
  # path even though they make no network requests.
  export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
  python=${patchedHermes.hermesVenv}/bin/python3
  export HERMES_SANDBOX_ACCESS_SOURCE=${sandboxAccess.testSource}
  test "$(readlink -f ${patchedHermes}/share/hermes-agent/plugins)" = \
    "${patchedHermes.patchedSource}/plugins"

  "$python" -m pytest -q -o cache_dir=$TMPDIR/pytest-cache \
    ${patchedHermes.patchedSource}/tests/tools/test_approval_choice_result.py \
    ${patchedHermes.patchedSource}/tests/tools/test_request_tool_approval.py \
    ${patchedHermes.patchedSource}/tests/tools/test_approval.py \
    ${patchedHermes.patchedSource}/tests/tools/test_command_guards.py \
    ${patchedHermes.patchedSource}/tests/tools/test_execute_code_approval_cluster.py \
    ${patchedHermes.patchedSource}/tests/acp/test_permissions.py \
    ${patchedHermes.patchedSource}/tests/gateway/test_api_server_runs.py \
    ${patchedHermes.patchedSource}/tests/gateway/test_plaintext_approval_routing.py \
    ${patchedHermes.patchedSource}/tests/gateway/test_tui_approval_redaction.py \
    ${patchedHermes.patchedSource}/tests/gateway/test_telegram_approval_buttons.py \
    ${patchedHermes.patchedSource}/tests/gateway/test_slack_approval_buttons.py \
    ${patchedHermes.patchedSource}/tests/hermes_cli/test_worker_lanes.py \
    ${patchedHermes.patchedSource}/tests/hermes_cli/test_worker_lane_discovery.py \
    ${patchedHermes.patchedSource}/tests/hermes_cli/test_explicit_worker_lanes.py \
    ${patchedHermes.patchedSource}/tests/hermes_cli/test_multi_task_inputs.py \
    ${patchedHermes.patchedSource}/tests/hermes_cli/test_input_reclaim_guards.py \
    ${patchedHermes.patchedSource}/tests/hermes_cli/test_kanban_decompose.py \
    ${patchedHermes.patchedSource}/tests/hermes_cli/test_kanban_swarm.py \
    ${patchedHermes.patchedSource}/tests/hermes_cli/test_kanban_cli_dispatch_passthrough.py \
    ${patchedHermes.patchedSource}/tests/hermes_cli/test_kanban_worker_spawn_toolsets.py \
    ${patchedHermes.patchedSource}/tests/tools/test_kanban_tools.py \
    ${patchedHermes.patchedSource}/tests/tools/test_kanban_role_boundaries.py \
    ${patchedHermes.patchedSource}/tests/hermes_state/test_session_md_export.py \
    ${patchedHermes.patchedSource}/tests/tools/test_secure_terminal_scope.py \
    ${patchedHermes.patchedSource}/tests/tools/test_secure_terminal_identity_integration.py \
    ${patchedHermes.patchedSource}/tests/tools/test_file_tools_cwd_resolution.py \
    ${patchedHermes.patchedSource}/tests/tools/test_shared_container_task_id.py \
    ${patchedHermes.patchedSource}/tests/tools/test_terminal_task_cwd.py \
    ${patchedHermes.patchedSource}/tests/tools/test_task_authority_binding.py \
    ${patchedHermes.patchedSource}/tests/tools/test_gondolin_backend.py \
    ${patchedHermes.patchedSource}/tests/tools/test_process_registry.py \
    ${patchedHermes.patchedSource}/tests/gateway/test_session_boundary_security_state.py \
    ${patchedHermes.patchedSource}/tests/gateway/test_kanban_notifier.py \
    ${patchedHermes.patchedSource}/tests/plugins/test_workspace_zero_schema.py \
    ${sandboxAccess.testSource}/tests \
    ${codexWorkerLane.testSource}/tests
  "$python" -m py_compile \
    ${codexWorkerLane}/share/hermes-agent/plugins/codex-worker-lane/__init__.py \
    ${codexWorkerLane}/share/hermes-agent/plugins/codex-worker-lane/worker.py \
    ${sandboxAccess}/share/hermes-agent/plugins/sandbox-access/__init__.py \
    ${patchedHermes.patchedSource}/plugins/workspace-service/__init__.py
  "$python" -m ruff check \
    ${codexWorkerLane.testSource}/__init__.py \
    ${codexWorkerLane.testSource}/worker.py \
    ${codexWorkerLane.testSource}/tests \
    ${sandboxAccess.testSource}/__init__.py \
    ${sandboxAccess.testSource}/tests \
    ${patchedHermes.patchedSource}/plugins/workspace-service/__init__.py \
    ${patchedHermes.patchedSource}/hermes_cli/worker_catalogue.py \
    ${patchedHermes.patchedSource}/tests/hermes_cli/test_explicit_worker_lanes.py \
    ${patchedHermes.patchedSource}/tests/hermes_cli/test_multi_task_inputs.py \
    ${patchedHermes.patchedSource}/tests/hermes_cli/test_input_reclaim_guards.py \
    ${patchedHermes.patchedSource}/tests/plugins/test_workspace_zero_schema.py
  touch $out
''
