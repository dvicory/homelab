{
  writeShellApplication,
  age,
  openssh,
  coreutils,
  git,
}:
writeShellApplication {
  name = "generate-secrets";
  meta.description = "Generate agenix secrets (boot keys) for a host";
  runtimeInputs = [
    age
    openssh
    coreutils
    git
  ];
  text = builtins.readFile ./generate-secrets.sh;
}
