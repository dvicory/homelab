{
  writeShellApplication,
  age,
  openssh,
  coreutils,
  git,
  generate-secrets,
  rekey,
}:
writeShellApplication {
  name = "provision-keys";
  meta.description = "Full new-host secrets provisioning pipeline";
  runtimeInputs = [
    age
    openssh
    coreutils
    git
    generate-secrets
    rekey
  ];
  text = builtins.readFile ./provision-keys.sh;
}
