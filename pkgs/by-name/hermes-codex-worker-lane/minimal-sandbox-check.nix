{
  bash,
  bubblewrap,
  coreutils,
  findutils,
  lib,
  python,
  python3,
  pythonPath,
  runCommand,
  workerSource,
}:
let
  runtimePath = lib.makeBinPath [
    bash
    coreutils
    findutils
    python3
  ];
in
runCommand "hermes-codex-minimal-sandbox" { } ''
  task="$TMPDIR/task"
  codexHome="$TMPDIR/codex-home"
  workerResult="$TMPDIR/worker-result"
  forbidden="$TMPDIR/forbidden/secret"

  mkdir -p \
    "$task/work" \
    "$task/inputs" \
    "$task/output" \
    "$codexHome" \
    "$workerResult" \
    "$(dirname "$forbidden")"
  printf 'immutable-input\n' > "$task/inputs/input.txt"
  printf 'must-not-be-visible\n' > "$forbidden"
  chmod 0444 "$task/inputs/input.txt"

  cat > "$workerResult/inside-test.sh" <<'INSIDE'
  #!/bin/bash
  set -euo pipefail
  forbidden=$1
  nested_bwrap=$2

  test "$(pwd -P)" = /workspace/work
  test "$(readlink /proc/self/cwd)" = /workspace/work
  test "$(python3 -c 'import os; print(os.getcwd())')" = /workspace/work
  test -z "''${HERMES_SANDBOX_AUTHORITY_BINDING+x}"
  test -c /dev/full
  "$nested_bwrap" --ro-bind / / --dev-bind /dev/full /dev/full /bin/bash -c :
  test "$(cat /workspace/inputs/input.txt)" = immutable-input
  if touch /workspace/inputs/mutation 2>/dev/null; then
    echo "inputs plane was writable" >&2
    exit 1
  fi
  printf 'work-ok\n' > /workspace/work/work-canary
  printf 'output-ok\n' > /workspace/output/output-canary
  printf 'result-ok\n' > /run/codex-worker/result-canary

  test ! -e "$forbidden"
  test ! -e /home/hermes/.hermes
  test ! -e /run/secrets
  test ! -e /workspace/inputs/mutation
  if touch /nix/store/hermes-write-canary 2>/dev/null; then
    echo "/nix/store was writable" >&2
    exit 1
  fi

  pid_count=$(find /proc -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '/proc/[0-9]+' | wc -l)
  test "$pid_count" -le 8
  INSIDE
  chmod 0555 "$workerResult/inside-test.sh"

  cat > "$TMPDIR/launch.py" <<'PYTHON'
  import importlib.util
  import os
  from pathlib import Path

  spec = importlib.util.spec_from_file_location("codex_worker", os.environ["WORKER_SOURCE"])
  assert spec is not None and spec.loader is not None
  worker = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(worker)

  command = worker._broker_codex_command(
      ["/bin/bash", "/run/codex-worker/inside-test.sh", os.environ["FORBIDDEN_PATH"], os.environ["NESTED_BWRAP"]],
      Path(os.environ["WORKSPACE"]),
      Path(os.environ["WORKER_RESULT"]),
      "workspace-write",
  )
  os.execv(command[0], command)
  PYTHON

  export PYTHONPATH=${pythonPath}
  export WORKER_SOURCE=${workerSource}/worker.py
  export WORKSPACE="$task/work"
  export WORKER_RESULT="$workerResult"
  export FORBIDDEN_PATH="$forbidden"
  export NESTED_BWRAP=${lib.getExe bubblewrap}
  export BWRAP_EXECUTABLE=${lib.getExe bubblewrap}
  export BASH_EXECUTABLE=${lib.getExe bash}
  export ENV_EXECUTABLE=${lib.getExe' coreutils "env"}
  export CODEX_RUNTIME_PATH=${runtimePath}
  export HERMES_SANDBOX_AUTHORITY_BINDING=must-not-reach-codex
  export CODEX_HOME="$codexHome"
  export SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
  ${python}/bin/python "$TMPDIR/launch.py"

  test "$(cat "$task/work/work-canary")" = work-ok
  test "$(cat "$task/output/output-canary")" = output-ok
  test "$(cat "$workerResult/result-canary")" = result-ok
  test ! -e "$task/inputs/mutation"
  touch "$out"
''
