{
  writeShellApplication,
  age,
  coreutils,
  git,
}:
writeShellApplication {
  name = "install";
  meta.description = "nixos-anywhere install helper";
  runtimeInputs = [
    age
    coreutils
    git
  ];
  text = builtins.readFile ./install.sh;
}
