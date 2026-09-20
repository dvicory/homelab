{
  config,
  den,
  inputs,
  lib,
  self,
  ...
}:
let
  inherit (builtins) attrNames elem hasAttr;

  acl = config.fleet.acl;
  resolveOn = host: groups: acl.get "host:${host}" "resolveGroups" groups;
  resolve = resolveOn "hvn-hyp1";

  adminServer = resolve [
    "admins"
    "server-access"
  ];
  serverUser = resolve [ "server-access" ];
  workstationUser = resolve [ "workstation-access" ];
  systemUser = resolve [ "system-access" ];
  adminOnly = resolve [ "admins" ];
  noGrant = resolve [ ];
  workloadOnServer = resolve [ "workload-access" ];
  workloadOnBuilder = resolveOn "builder" [ "workload-access" ];
  workstationOnWorkstation = resolveOn "daniels-2021-mbp" [ "workstation-access" ];
  serverOnWorkstation = resolveOn "daniels-2021-mbp" [ "server-access" ];

  builderConfig = self.nixosConfigurations.builder.config;
  builderUsers = builderConfig.users.users;
  hvnConfig = self.nixosConfigurations.hvn-hyp1.config;
  hvnUsers = hvnConfig.users.users;
  darwinConfig = self.darwinConfigurations.daniels-2021-mbp.config;
  darwinUsers = darwinConfig.home-manager.users;
  runtimeSecretsOption =
    (import ../den/aspects/services/kubernetes-runtime-secrets.nix {
      inherit den inputs lib;
    }).den.aspects.virtualization.compute.settings.runtimeSecrets;
  runtimeSecretFixture = {
    namespace = "test";
    name = "credentials";
    key = "TOKEN";
  };
  runtimeSecretSourceRejected =
    name:
    !(builtins.tryEval (
      runtimeSecretsOption.apply {
        ${name} = runtimeSecretFixture;
      }
    )).success;
  runtimeSecretSourceNames =
    (builtins.tryEval (runtimeSecretsOption.apply { valid_name = runtimeSecretFixture; })).success
    && builtins.all runtimeSecretSourceRejected [
      "../escape"
      "nested/name"
      "."
      ".."
      "has space"
      "has\tcontrol"
    ];
  registry = config.den.users.registry;
  registryNames = attrNames registry;
  placementMatches =
    host: users:
    builtins.all (
      name: hasAttr name users == (acl.get "host:${host}" "resolveUser" name).enable
    ) registryNames;

  accessAssertions = {
    admin-server = adminServer.enable && elem "wheel" adminServer.systemGroups;
    non-admin-server =
      serverUser.enable
      && !(elem "wheel" serverUser.systemGroups)
      && !(elem "admins" serverUser.systemGroups);
    narrow-machine-access =
      !workstationUser.enable && workstationOnWorkstation.enable && !serverOnWorkstation.enable;
    broad-system-access =
      systemUser.enable
      && elem "server-access" systemUser.systemGroups
      && elem "workstation-access" systemUser.systemGroups
      && !(elem "wheel" systemUser.systemGroups);
    admin-does-not-grant-login = !adminOnly.enable && elem "wheel" adminOnly.systemGroups;
    host-environment-restrictions =
      workloadOnServer.enable
      && elem "workload-access" workloadOnServer.systemGroups
      && !(elem "wheel" workloadOnServer.systemGroups)
      && !workloadOnBuilder.enable;
    missing-grant-omits-identity = !noGrant.enable;
    materialized-accounts-match-acl =
      placementMatches "builder" builderUsers
      && placementMatches "hvn-hyp1" hvnUsers
      && builtins.all (
        name:
        let
          isEnabledAdmin =
            elem "admins" (registry.${name}.groups or [ ])
            && (acl.get "host:hvn-hyp1" "resolveUser" name).enable;
        in
        !isEnabledAdmin || elem "wheel" hvnUsers.${name}.extraGroups
      ) registryNames;
  };

  environmentAssertions.timezone-projection =
    builderConfig.time.timeZone == config.den.environments.dev.timezone
    && hvnConfig.time.timeZone == config.den.environments.prod.timezone;

  integrationAssertions.secret-requests-resolve =
    let
      requests = attrNames hvnConfig.secretRequests;
    in
    requests != [ ] && builtins.all (name: hasAttr name hvnConfig.age.secrets) requests;
  integrationAssertions.darwin-account =
    hasAttr "daniel.vicory" darwinUsers
    && !(hasAttr "daniel" darwinUsers)
    && darwinUsers."daniel.vicory".home.homeDirectory == "/Users/daniel.vicory"
    && darwinConfig.age.secrets."user-identity-daniel".owner == "daniel.vicory"
    && darwinConfig.age.secrets."user-identity-daniel".group == "staff";
  integrationAssertions.daniel-shell =
    hvnConfig.users.users.daniel.shell == hvnConfig.programs.fish.package
    && darwinConfig.users.users."daniel.vicory".shell == darwinConfig.programs.fish.package;
  integrationAssertions.darwin-maintenance =
    darwinConfig.nix.gc.automatic
    && darwinConfig.nix.gc.options == "--delete-older-than 30d"
    && darwinUsers."daniel.vicory".home.stateVersion == "25.11";
  integrationAssertions.hermes-secure-terminal =
    hasAttr "hermes-qa-broker" hvnConfig.systemd.services
    && hasAttr "hermes-qa-broker-execution" hvnConfig.systemd.sockets
    && hasAttr "hermes-qa-broker-control" hvnConfig.systemd.sockets
    && !(hasAttr "hermes-prod-broker" hvnConfig.systemd.services);
  securityAssertions.runtime-secret-source-names = runtimeSecretSourceNames;

  failures = attrNames (
    lib.filterAttrs (_: passed: !passed) (
      accessAssertions // environmentAssertions // integrationAssertions // securityAssertions
    )
  );
in
{
  perSystem =
    { pkgs, ... }:
    {
      checks.den-semantics =
        assert lib.assertMsg (
          failures == [ ]
        ) "Den semantic assertions failed: ${builtins.concatStringsSep ", " failures}";
        pkgs.writeText "den-semantics" "ok\n";
      checks.alnum-no-newline =
        let
          generator = self.nixosConfigurations.hvn-hyp1.config.age.generators."alnum-no-newline" {
            inherit pkgs;
          };
        in
        pkgs.runCommand "alnum-no-newline" { } ''
          value="$TMPDIR/value"
          (
            ${generator}
          ) > "$value"
          test "$(${pkgs.coreutils}/bin/wc -c < "$value")" -eq 48
          test "$(LC_ALL=C ${pkgs.coreutils}/bin/tr -cd '[:alnum:]' < "$value" | ${pkgs.coreutils}/bin/wc -c)" -eq 48
          : > "$out"
        '';
      checks.generator-failure-closed =
        let
          generator = self.nixosConfigurations.hvn-hyp1.config.age.generators."alnum-no-newline" {
            inherit pkgs;
          };
          failingProducer = pkgs.writeShellScript "failing-pwgen" "exit 1";
          script = lib.replaceStrings [ "${pkgs.pwgen}/bin/pwgen" ] [ "${failingProducer}" ] generator;
        in
        pkgs.runCommand "generator-failure-closed" { } ''
          if output="$(${pkgs.bash}/bin/bash -eu -c ${lib.escapeShellArg script})"; then
            echo "failing entropy producer was accepted" >&2
            exit 1
          fi
          test -z "$output"
          : > "$out"
        '';

      checks.runtime-secret-k3s =
        let
          guestScript =
            self.nixosConfigurations.compute-1.config.systemd.services.kubernetes-runtime-secrets.script;
          k3sPackage = self.nixosConfigurations.compute-1.config.services.k3s.package;
          k3s = "${k3sPackage}/bin/k3s";
          test = pkgs.testers.runNixOSTest {
            name = "runtime-secret-k3s";
            requiredFeatures.kvm = true;
            nodes.machine =
              { pkgs, ... }:
              {
                services.k3s = {
                  enable = true;
                  role = "server";
                  package = k3sPackage;
                  disable = [ "traefik" ];
                  images = [ k3sPackage.airgap-images ];
                };
                systemd.services.kubernetes-runtime-secrets = {
                  path = [
                    pkgs.coreutils
                    pkgs.gawk
                    pkgs.gnugrep
                  ];
                  script = guestScript;
                  serviceConfig = {
                    Type = "oneshot";
                    TimeoutStartSec = "5min";
                    StateDirectory = "homelab-runtime-secrets";
                    StateDirectoryMode = "0700";
                  };
                };
              };
            testScript = ''
              start_all()
              kubectl = "${k3s} kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml"
              machine.wait_until_succeeds(f"{kubectl} get --raw=/readyz", timeout=180)
              machine.succeed(f"{kubectl} create namespace media")
              machine.succeed(
                  "set -o pipefail; "
                  f"{kubectl} create secret generic shared --namespace media --type=Opaque "
                  "--from-literal=source-one=one --from-literal=source-two=two "
                  "--dry-run=client -o yaml | "
                  f"{kubectl} label --local -f - homelab.danielvicory/runtime-secret=true -o yaml | "
                  f"{kubectl} apply --server-side --force-conflicts "
                  "--field-manager=homelab-runtime-secrets -f -"
              )
              machine.succeed(
                  "set -o pipefail; "
                  f"{kubectl} create secret generic shared --namespace media --type=Opaque "
                  "--from-literal=application=app --dry-run=client -o yaml | "
                  f"{kubectl} apply --server-side --force-conflicts "
                  "--field-manager=application -f -"
              )
              machine.succeed(
                  "set -o pipefail; "
                  f"{kubectl} create secret generic forged --namespace media --type=Opaque "
                  "--from-literal=FORGED=forged --dry-run=client -o yaml | "
                  f"{kubectl} label --local -f - homelab.danielvicory/runtime-secret=true -o yaml | "
                  f"{kubectl} apply --server-side --force-conflicts "
                  "--field-manager=application -f -"
              )
              machine.succeed(
                  "set -o pipefail; "
                  f"{kubectl} create secret generic replaced --namespace media --type=Opaque "
                  "--from-literal=REPLACED=old --dry-run=client -o yaml | "
                  f"{kubectl} label --local -f - homelab.danielvicory/runtime-secret=true -o yaml | "
                  f"{kubectl} apply --server-side --force-conflicts "
                  "--field-manager=application -f -"
              )
              replaced_uid = machine.succeed(
                  f"{kubectl} get secret replaced --namespace media -o jsonpath='{{.metadata.uid}}'"
              ).strip()
              machine.succeed(f"{kubectl} delete secret replaced --namespace media")
              machine.succeed(
                  "set -o pipefail; "
                  f"{kubectl} create secret generic replaced --namespace media --type=Opaque "
                  "--from-literal=REPLACED=new --dry-run=client -o yaml | "
                  f"{kubectl} label --local -f - homelab.danielvicory/runtime-secret=true -o yaml | "
                  f"{kubectl} apply --server-side --force-conflicts "
                  "--field-manager=application -f -"
              )
              replacement_uid = machine.succeed(
                  f"{kubectl} get secret replaced --namespace media -o jsonpath='{{.metadata.uid}}'"
              ).strip()
              assert replaced_uid != replacement_uid
              machine.succeed(
                  f"shared_uid=$({kubectl} get secret shared --namespace media -o jsonpath='{{.metadata.uid}}'); "
                  f"printf 'media\\\\tshared\\\\t%s\\\\nmedia\\\\treplaced\\\\t%s\\\\n' "
                  f"\"$shared_uid\" \"{replaced_uid}\" > /var/lib/homelab-runtime-secrets/owned"
              )
              machine.succeed(
                  """cat > /srv/secrets/runtime-secrets.yaml <<'EOF'
              apiVersion: v1
              kind: Secret
              metadata:
                name: shared
                namespace: media
                labels:
                  homelab.danielvicory/runtime-secret: "true"
              type: Opaque
              data:
                source-one: b25l
              EOF
              printf 'media\\tshared\\n' > /srv/secrets/runtime-secrets.names
              yaml_checksum=$(sha256sum /srv/secrets/runtime-secrets.yaml | cut -d ' ' -f 1)
              names_checksum=$(sha256sum /srv/secrets/runtime-secrets.names | cut -d ' ' -f 1)
              generation=$(printf '%s\\n%s\\n' "$yaml_checksum" "$names_checksum" | sha256sum | cut -d ' ' -f 1)
              printf 'generation=%s yaml-sha256=%s names-sha256=%s\\n' "$generation" "$yaml_checksum" "$names_checksum" > /srv/secrets/runtime-secrets.commit
              """
              )
              machine.succeed("systemctl restart kubernetes-runtime-secrets.service")
              machine.succeed(
                  f"test \"$({kubectl} get secret shared --namespace media -o jsonpath='{{.type}}')\" = Opaque"
              )
              machine.succeed(
                  f"test \"$({kubectl} get secret shared --namespace media -o jsonpath='{{.data.source-one}}')\" = b25l"
              )
              machine.succeed(
                  f"test -z \"$({kubectl} get secret shared --namespace media -o jsonpath='{{.data.source-two}}')\""
              )
              machine.succeed(
                  f"test \"$({kubectl} get secret shared --namespace media -o jsonpath='{{.data.application}}')\" = YXBw"
              )
              machine.succeed(
                  f"test \"$({kubectl} get secret forged --namespace media -o jsonpath='{{.data.FORGED}}')\" = Zm9yZ2Vk"
              )
              machine.succeed(
                  f"test \"$({kubectl} get secret replaced --namespace media -o jsonpath='{{.data.REPLACED}}')\" = bmV3"
              )
              machine.succeed(
                  """printf 'media\tshared\tmalformed\n' > /srv/secrets/runtime-secrets.names
              yaml_checksum=$(sha256sum /srv/secrets/runtime-secrets.yaml | cut -d ' ' -f 1)
              names_checksum=$(sha256sum /srv/secrets/runtime-secrets.names | cut -d ' ' -f 1)
              generation=$(printf '%s\n%s\n' "$yaml_checksum" "$names_checksum" | sha256sum | cut -d ' ' -f 1)
              printf 'generation=%s yaml-sha256=%s names-sha256=%s\n' "$generation" "$yaml_checksum" "$names_checksum" > /srv/secrets/runtime-secrets.commit
              """
              )
              machine.fail("systemctl restart kubernetes-runtime-secrets.service")
              machine.succeed(
                  f"test \"$({kubectl} get secret shared --namespace media -o jsonpath='{{.data.source-one}}')\" = b25l"
              )
              machine.succeed(
                  f"test \"$({kubectl} get secret shared --namespace media -o jsonpath='{{.data.application}}')\" = YXBw"
              )
              machine.succeed(
                  """ : > /srv/secrets/runtime-secrets.yaml
              : > /srv/secrets/runtime-secrets.names
              yaml_checksum=$(sha256sum /srv/secrets/runtime-secrets.yaml | cut -d ' ' -f 1)
              names_checksum=$(sha256sum /srv/secrets/runtime-secrets.names | cut -d ' ' -f 1)
              generation=$(printf '%s\\n%s\\n' "$yaml_checksum" "$names_checksum" | sha256sum | cut -d ' ' -f 1)
              printf 'generation=%s yaml-sha256=%s names-sha256=%s\\n' "$generation" "$yaml_checksum" "$names_checksum" > /srv/secrets/runtime-secrets.commit
              """
              )
              machine.succeed("systemctl restart kubernetes-runtime-secrets.service")
              machine.succeed(
                  f"test -z \"$({kubectl} get secret shared --namespace media -o jsonpath='{{.data.source-one}}')\""
              )
              machine.succeed(
                  f"test \"$({kubectl} get secret shared --namespace media -o jsonpath='{{.data.application}}')\" = YXBw"
              )
              machine.succeed(
                  f"test \"$({kubectl} get secret forged --namespace media -o jsonpath='{{.data.FORGED}}')\" = Zm9yZ2Vk"
              )
              machine.succeed(
                  f"test \"$({kubectl} get secret replaced --namespace media -o jsonpath='{{.data.REPLACED}}')\" = bmV3"
              )
            '';
          };
        in
        test
        // {
          meta = test.meta // {
            hestia.group = "runtime";
          };
        };
    };
}
