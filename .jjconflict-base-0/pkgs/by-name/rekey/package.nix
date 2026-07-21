{
  writeShellApplication,
  age,
  coreutils,
  git,
}:
writeShellApplication {
  name = "rekey";
  meta.description = "Rekey all agenix secrets for all hosts";
  runtimeInputs = [
    age
    coreutils
    git
  ];
  text = builtins.readFile ./rekey.sh;
}
