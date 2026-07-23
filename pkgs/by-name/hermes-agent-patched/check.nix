{
  cacert,
  codexWorkerLane,
  patchedHermes,
  sandboxAccess,
  runCommand,
}:
runCommand "hermes-agent-patched-check" { } ''
  export PYTHONPATH=${patchedHermes.patchedSource}
  export PYTHONPYCACHEPREFIX=$TMPDIR/pycache
  export RUFF_CACHE_DIR=$TMPDIR/ruff-cache
  # Nix sets SSL_CERT_FILE=/no-cert-file.crt in pure builds. Two upstream
  # prompt-construction tests initialize an OpenAI client and validate the CA
  # path even though they make no network requests.
  export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
  python=${patchedHermes.hermesVenv}/bin/python3
  test "$(readlink -f ${patchedHermes}/share/hermes-agent/plugins)" = \
    "${patchedHermes.patchedSource}/plugins"

  "$python" -m pytest -q -o cache_dir=$TMPDIR/pytest-cache \
    ${patchedHermes.patchedSource}/tests/hermes_cli/test_worker_lanes.py \
    ${patchedHermes.patchedSource}/tests/hermes_cli/test_worker_lane_discovery.py \
    ${patchedHermes.patchedSource}/tests/hermes_cli/test_kanban_worker_spawn_toolsets.py \
    ${patchedHermes.patchedSource}/tests/tools/test_kanban_tools.py \
    ${patchedHermes.patchedSource}/tests/tools/test_secure_terminal_scope.py \
    ${patchedHermes.patchedSource}/tests/tools/test_secure_terminal_identity_integration.py \
    ${patchedHermes.patchedSource}/tests/tools/test_task_authority_binding.py \
    ${patchedHermes.patchedSource}/tests/tools/test_approval_choice_result.py \
    ${patchedHermes.patchedSource}/tests/gateway/test_approval_permanent_choices.py \
    ${patchedHermes.patchedSource}/tests/gateway/test_telegram_approval_buttons.py \
    ${patchedHermes.patchedSource}/tests/tools/test_gondolin_backend.py \
    ${patchedHermes.patchedSource}/tests/plugins/test_workspace_service.py \
    ${patchedHermes.patchedSource}/tests/plugins/test_workspace_kanban.py \
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
    ${patchedHermes.patchedSource}/tests/plugins/test_workspace_service.py \
    ${patchedHermes.patchedSource}/tests/plugins/test_workspace_kanban.py
  touch $out
''
