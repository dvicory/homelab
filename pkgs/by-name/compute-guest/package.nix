{
  writeShellApplication,
  python3,
  incus,
  openssh,
  nix,
  util-linux,
}:
writeShellApplication {
  name = "compute-guest";
  runtimeInputs = [
    python3
    incus
    openssh
    nix
    util-linux
  ];
  text = ''
    exec python3 ${./compute-guest.py} "$@"
  '';
  meta.description = "Serialized lifecycle operations for a Nix-declared compute guest";
}
