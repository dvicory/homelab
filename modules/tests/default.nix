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
  # Restarting a storage unit on a secret change would close or unmount a live
  # volume; unlock secrets apply on the next unlock.
  integrationAssertions.secret-restarts-spare-storage =
    let
      isStorageUnit =
        unit:
        lib.hasPrefix "gocryptfs-" unit
        || lib.hasPrefix "systemd-cryptsetup@" unit
        || lib.hasPrefix "mergerfs-" unit
        || lib.hasSuffix ".mount" unit;
      restartTargets = lib.concatMap (
        host:
        lib.concatMap (req: req.restartUnits) (builtins.attrValues (host.config.secretRequests or { }))
      ) (builtins.attrValues self.nixosConfigurations);
    in
    !(builtins.any isStorageUnit restartTargets);
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
  integrationAssertions.media-pool-revision-b =
    let
      mediaPath = "/mnt/storage-clear/media4";
      mergerfs = import ../den/aspects/services/_mergerfs.nix { inherit lib; };
      pool = hvnConfig.systemd.services.${mergerfs.serviceNameFor "/srv/media/data"};
      # The unit systemd's fstab generator creates for the mountpoint, computed
      # here with the NixOS escaping helper rather than copied from the host.
      mediaMountUnit = "${self.nixosConfigurations.hvn-hyp1._module.args.utils.escapeSystemdPath mediaPath}.mount";
    in
    elem mediaMountUnit pool.requires
    && elem mediaMountUnit pool.bindsTo
    && hasAttr mediaPath hvnConfig.fileSystems;
  integrationAssertions.hermes-secure-terminal =
    hasAttr "hermes-qa-broker" hvnConfig.systemd.services
    && hasAttr "hermes-qa-broker-execution" hvnConfig.systemd.sockets
    && hasAttr "hermes-qa-broker-control" hvnConfig.systemd.sockets
    && !(hasAttr "hermes-prod-broker" hvnConfig.systemd.services);
  securityAssertions.runtime-secret-source-names = runtimeSecretSourceNames;
  # cert-manager is the sole writer of the TLS Secrets; no runtime Secret may
  # stage them and the Cloudflare token must be operator-supplied (agenix edit,
  # not generated).
  securityAssertions.runtime-secret-certificate-ownership =
    let
      runtimeSecrets = config.flake.clusterResources.prod-home.runtimeSecrets;
      tlsSecrets = [
        {
          namespace = "gateway";
          name = "gateway-tls";
        }
        {
          namespace = "identity";
          name = "kanidm-tls";
        }
      ];
      token = runtimeSecrets."cert-manager--cloudflare-api-token--api-token" or null;
    in
    builtins.all (entry: entry.type != "kubernetes.io/tls") (builtins.attrValues runtimeSecrets)
    && builtins.all (
      tls:
      builtins.all (entry: !(entry.namespace == tls.namespace && entry.name == tls.name)) (
        builtins.attrValues runtimeSecrets
      )
    ) tlsSecrets
    && token != null
    && token.namespace == "cert-manager"
    && token.name == "cloudflare-api-token"
    && token.key == "api-token"
    && (token.generator or null) == null;

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
          configurations = import ./_compute-configurations.nix {
            inherit self lib;
            system = pkgs.stdenv.hostPlatform.system;
            hostName = config.den.clusters.prod-home.hostName;
          };
          guest = configurations.guest.config;
          service = guest.systemd.services.kubernetes-runtime-secrets;
          k3sPackage = guest.services.k3s.package;
          k3s = "${k3sPackage}/bin/k3s";
          test = pkgs.testers.runNixOSTest {
            name = "runtime-secret-k3s";
            requiredFeatures.kvm = true;
            nodes.machine = {
              system.stateVersion = "26.05";
              virtualisation.memorySize = 2048;
              virtualisation.cores = 2;
              virtualisation.diskSize = 8192;
              systemd.tmpfiles.rules = [ "d /srv/secrets 0700 root root -" ];
              services.k3s = {
                enable = true;
                role = "server";
                package = k3sPackage;
                disable = [ "traefik" ];
                images = [ k3sPackage.airgap-images ];
              };
              systemd.services.kubernetes-runtime-secrets = {
                # ExecStart is the evaluated production script, not a fixture
                # wrapper. Keep its dependencies, condition, retries and state.
                inherit (service)
                  description
                  wantedBy
                  after
                  requires
                  unitConfig
                  serviceConfig
                  environment
                  path
                  ;
                # The evaluated path already contains NixOS's default entries.
                enableDefaultPath = false;
              };
            };
            testScript = ''
              import hashlib
              import json
              import shlex

              start_all()
              kubectl = "${k3s} kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml --context default --request-timeout=10s"
              machine.wait_until_succeeds(f"{kubectl} get --raw=/readyz", timeout=180)
              machine.succeed(f"{kubectl} create namespace media")
              unit = "kubernetes-runtime-secrets.service"
              state = "/var/lib/homelab-runtime-secrets"

              def write_file(path, content):
                  machine.succeed(f"printf %s {shlex.quote(content)} > {shlex.quote(path)}")

              def stage(resources, *, complete=True):
                  yaml = "\n---\n".join(json.dumps(resource, sort_keys=True) for resource in resources)
                  yaml = yaml + "\n" if yaml else ""
                  names = "".join(sorted(
                      f"media\t{item['metadata']['name']}\t{item['type']}\t{','.join(sorted(item['data']))}\n"
                      for item in resources
                  ))
                  yaml_hash = hashlib.sha256(yaml.encode()).hexdigest()
                  names_hash = hashlib.sha256(names.encode()).hexdigest()
                  generation = hashlib.sha256(f"{yaml_hash}\n{names_hash}\n".encode()).hexdigest()
                  write_file("/srv/secrets/runtime-secrets.yaml", yaml)
                  if complete:
                      write_file("/srv/secrets/runtime-secrets.names", names)
                  else:
                      machine.succeed("rm /srv/secrets/runtime-secrets.names")
                  # Publish last: consumption must refuse an incomplete delivery.
                  write_file("/srv/secrets/runtime-secrets.commit",
                             f"generation={generation} yaml-sha256={yaml_hash} names-sha256={names_hash}\n")
                  return generation

              def tls_secret(name, certificate="Y2VydA=="):
                  return {
                      "apiVersion": "v1",
                      "kind": "Secret",
                      "metadata": {
                          "name": name,
                          "namespace": "media",
                          "labels": {"homelab.danielvicory/runtime-secret": "true"},
                      },
                      "type": "kubernetes.io/tls",
                      "data": {"tls.crt": certificate, "tls.key": "a2V5"},
                  }

              def get_secret(name):
                  return json.loads(machine.succeed(f"{kubectl} get secret {name} --namespace media -o json"))

              def assert_ack(generation):
                  assert machine.succeed(f"cat {state}/applied-generation") == generation + "\n"

              # Real unit startup consumes the delivered files through its
              # production ExecStart/PATH and creates the systemd state directory.
              initial = stage([tls_secret("tls"), tls_secret("sole-tls")])
              machine.succeed("test ! -e /var/lib/homelab-runtime-secrets/applied-generation")
              machine.succeed(f"systemctl restart {unit}")
              assert_ack(initial)
              shared = get_secret("tls")
              sole = get_secret("sole-tls")
              for resource in (shared, sole):
                  assert resource["type"] == "kubernetes.io/tls"
                  assert resource["data"] == {"tls.crt": "Y2VydA==", "tls.key": "a2V5"}
              owned = machine.succeed(f"cat {state}/owned")
              assert sorted(owned.splitlines()) == sorted(
                  f"media\t{item['metadata']['name']}\t{item['metadata']['uid']}"
                  for item in (shared, sole)
              )
              machine.succeed(
                  f"test $(stat -c %a {state}) = 700 && "
                  f"test $(stat -c %a {state}/applied-generation) = 600"
              )

              incomplete = stage([tls_secret("tls", "bmV3")], complete=False)
              assert incomplete != initial
              machine.fail(f"systemctl restart {unit}")
              machine.succeed(
                  f"test $(systemctl show {unit} --property=ExecMainStatus --value) -ne 0 && "
                  f"test $(systemctl show {unit} --property=Result --value) = exit-code"
              )
              assert_ack(initial)
              assert machine.succeed(f"cat {state}/owned") == owned
              assert get_secret("tls") == shared and get_secret("sole-tls") == sole
              # Cancel the production on-failure retry while repairing delivery.
              machine.succeed(f"systemctl stop {unit}")

              # After repaired delivery, the same real unit succeeds again and
              # acknowledges the exact generation. Same-UID shared and sole-owner
              # TLS retirement API behavior is covered by the native
              # runtime-secret-matching-uid-* scenarios in verify-kubernetes-api.
              empty = stage([])
              machine.succeed(f"systemctl restart {unit}")
              assert_ack(empty)
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
