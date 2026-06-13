{
  writeShellApplication,
  age,
  coreutils,
  git,
  gnugrep,
  yq-go,
}:
writeShellApplication {
  name = "sops-to-agenix";
  meta.description = "Migrate sops secrets to agenix format";
  runtimeInputs = [
    age
    coreutils
    git
    gnugrep
    yq-go
  ];
  text = builtins.readFile ./sops-to-agenix.sh;
}
