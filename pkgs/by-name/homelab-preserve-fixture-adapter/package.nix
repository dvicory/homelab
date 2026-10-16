{
  lib,
  python3,
  writeTextFile,
}:
writeTextFile {
  name = "homelab-preserve-fixture-adapter";
  destination = "/bin/homelab-preserve-fixture-adapter";
  executable = true;
  text = "#!${python3}/bin/python3\n${builtins.readFile ./adapter.py}";
  meta = {
    description = "Test-only lifecycle-owner adapter for homelab-preserve conformance";
    mainProgram = "homelab-preserve-fixture-adapter";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
