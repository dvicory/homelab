{
  config,
  den,
  lib,
  ...
}:
{
  perSystem =
    { pkgs, ... }:
    let
      secrets = den.aspects.services.kubernetes-runtime-secrets.nixos {
        host = config.den.hosts.x86_64-linux.hvn-hyp1;
        inherit lib pkgs;
      };
      normalizer = secrets.system.build.normalize-runtime-secret;
    in
    {
      checks.runtime-secret-newlines =
        pkgs.runCommand "runtime-secret-newlines"
          { nativeBuildInputs = [ pkgs.python3 pkgs.kubectl ]; }
          ''
            python3 - ${normalizer} <<'PY'
            import base64
            import json
            from pathlib import Path
            import subprocess
            import sys

            cases = {
                "unchanged": (b"token", b"token"),
                "lf": (b"token\n", b"token"),
                "crlf": (b"token\r\n", b"token"),
                "mixed-endings": (b"token\n\r\n\n", b"token"),
                "embedded-newlines": (b"first\r\nsecond\n", b"first\r\nsecond"),
                "spaces": (b" token \t\r\n", b" token \t"),
                "lone-cr": (b"token\r", b"token\r"),
                "binary": (b"\x00\xff\nvalue\r\n", b"\x00\xff\nvalue"),
                "empty-after-trimming": (b"\r\n\n", b""),
            }
            arguments = ["kubectl", "create", "secret", "generic", "normalized",
                         "--dry-run=client", "-o", "json"]
            for name, (original, expected) in cases.items():
                path = Path(name).resolve()
                path.write_bytes(original)
                subprocess.run([sys.argv[1], str(path)], check=True)
                assert path.read_bytes() == expected, name
                arguments.append(f"--from-file={name}={path}")
            published = json.loads(subprocess.check_output(arguments))
            assert {key: base64.b64decode(value) for key, value in published["data"].items()} == {
                name: expected for name, (_, expected) in cases.items()
            }
            print("Trailing LF/CRLF removed; embedded newlines, spaces and binary bytes preserved in Secret publication.")
            PY
            touch "$out"
          '';
    };
}
