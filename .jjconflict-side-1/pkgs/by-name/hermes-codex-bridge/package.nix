{
  lib,
  python3,
  writeShellApplication,
  codex,
}:
let
  python = python3.withPackages (ps: [ ps.mcp ]);
in
writeShellApplication {
  name = "hermes-codex-bridge";
  runtimeInputs = [
    codex
    python
  ];
  text = ''
    exec python3 ${./hermes_codex_bridge.py}
  '';
  meta = {
    description = "MCP bridge from Hermes to Codex App Server";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "hermes-codex-bridge";
  };
}
