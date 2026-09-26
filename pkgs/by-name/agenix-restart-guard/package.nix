{
  lib,
  writeShellApplication,
  coreutils,
  systemd,
}:
writeShellApplication {
  name = "agenix-restart-guard";
  meta = {
    description = "Restart units only when a decrypted agenix secret's content changes";
    platforms = lib.platforms.linux;
  };
  runtimeInputs = [
    coreutils
    systemd
  ];
  text = builtins.readFile ./agenix-restart-guard.sh;
}
