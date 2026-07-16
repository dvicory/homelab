{
  codexWorkerLane,
  patchedHermes,
  runCommand,
}:
runCommand "hermes-worker-lane-check" { } ''
  export PYTHONPATH=${patchedHermes.workerLanesSource}
  export PYTHONPYCACHEPREFIX=$TMPDIR/pycache
  python=${patchedHermes.hermesVenv}/bin/python3

  "$python" -m pytest -q -o cache_dir=$TMPDIR/pytest-cache \
    ${patchedHermes.workerLanesSource}/tests/hermes_cli/test_worker_lanes.py \
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
