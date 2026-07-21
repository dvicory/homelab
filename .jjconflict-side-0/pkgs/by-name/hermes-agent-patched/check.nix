{
  cacert,
  codexWorkerLane,
  patchedHermes,
  runCommand,
}:
runCommand "hermes-agent-patched-check" { } ''
  export PYTHONPATH=${patchedHermes.patchedSource}
  export PYTHONPYCACHEPREFIX=$TMPDIR/pycache
  # Nix sets SSL_CERT_FILE=/no-cert-file.crt in pure builds. Two upstream
  # prompt-construction tests initialize an OpenAI client and validate the CA
  # path even though they make no network requests.
  export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
  python=${patchedHermes.hermesVenv}/bin/python3

  "$python" -m pytest -q -o cache_dir=$TMPDIR/pytest-cache \
    ${patchedHermes.patchedSource}/tests/hermes_cli/test_worker_lanes.py \
    ${patchedHermes.patchedSource}/tests/hermes_cli/test_worker_lane_discovery.py \
    ${patchedHermes.patchedSource}/tests/hermes_cli/test_kanban_worker_spawn_toolsets.py \
    ${patchedHermes.patchedSource}/tests/tools/test_kanban_tools.py \
    ${patchedHermes.patchedSource}/tests/tools/test_secure_terminal_scope.py \
    ${patchedHermes.patchedSource}/tests/tools/test_secure_terminal_identity_integration.py \
    ${patchedHermes.patchedSource}/tests/tools/test_gondolin_backend.py \
    ${codexWorkerLane.testSource}/tests
  "$python" -m py_compile \
    ${codexWorkerLane}/share/hermes-agent/plugins/codex-worker-lane/__init__.py \
    ${codexWorkerLane}/share/hermes-agent/plugins/codex-worker-lane/worker.py
  "$python" -m ruff check \
    ${codexWorkerLane.testSource}/__init__.py \
    ${codexWorkerLane.testSource}/worker.py \
    ${codexWorkerLane.testSource}/tests
  touch $out
''
