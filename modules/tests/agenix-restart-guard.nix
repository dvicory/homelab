# Behaviour test: agenix restartUnits restart consumers only when the secret's
# content changes.
#
# The VM runs the restart units that the agenix aspect generates for
# hvn-hyp1's crowdsec enrollment key, unchanged, against a stub
# crowdsec.service. Real agenix would need an age identity and an encrypted
# fixture, so a small script stands in for agenix activation. It follows
# agenix's own sequence: new generation directory, `ln -sfT`, remove the old
# generation, then chown.
{
  lib,
  self,
  ...
}:
let
  hvnConfig = self.nixosConfigurations.hvn-hyp1.config;
  hvnSystem = hvnConfig.nixpkgs.hostPlatform.system;

  secretName = "crowdsec-enrollmentKey";
  unitName = "agenix-restart-${secretName}";
  secretPath = hvnConfig.age.secrets.${secretName}.path;
  generatedPath = hvnConfig.systemd.paths.${unitName};
  generatedService = hvnConfig.systemd.services.${unitName};
in
{
  perSystem =
    { pkgs, system, ... }:
    let
      test = pkgs.testers.runNixOSTest {
        name = "agenix-restart-guard";
        requiredFeatures.kvm = true;

        nodes.machine =
          { pkgs, ... }:
          let
            activate = pkgs.writeShellScriptBin "fake-agenix-activate" ''
              set -eu
              content="$1"
              gen="$(readlink /run/agenix || true)"
              gen="''${gen##*/}"
              gen="''${gen:-0}"
              next=$((gen + 1))
              mkdir -p /run/agenix.d/$next
              printf '%s' "$content" > /run/agenix.d/$next/${secretName}.tmp
              mv -f /run/agenix.d/$next/${secretName}.tmp /run/agenix.d/$next/${secretName}
              ln -sfT /run/agenix.d/$next /run/agenix
              if [ "$gen" -gt 0 ]; then rm -rf /run/agenix.d/$gen; fi
              # agenixChown runs on every activation, after the swap. Even a
              # no-op chown emits IN_ATTRIB on the file the path unit watches.
              chown root:root /run/agenix.d/$next/${secretName}
            '';
          in
          {
            system.stateVersion = "26.05";
            environment.systemPackages = [ activate ];

            # Stand in for agenix activation before systemd starts units.
            system.activationScripts.fakeAgenix.text = ''
              if [ ! -e /run/agenix ]; then
                ${activate}/bin/fake-agenix-activate initial
              fi
            '';

            # The units hvn-hyp1 deploys, copied field by field.
            systemd.paths.${unitName} = {
              inherit (generatedPath) wantedBy pathConfig;
            };
            systemd.services.${unitName} = {
              inherit (generatedService)
                description
                wantedBy
                after
                serviceConfig
                ;
            };

            # Stub consumer that counts its starts.
            systemd.services.crowdsec = {
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                ExecStartPre = "${pkgs.bash}/bin/sh -c 'echo start >> /run/consumer-starts'";
                ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
              };
            };
          };

        testScript = ''
          unit = "${unitName}.service"
          assert "${secretPath}" == "/run/agenix/${secretName}"

          def starts():
              return int(machine.succeed("wc -l < /run/consumer-starts").strip())

          def runs():
              return int(machine.succeed(
                  f"journalctl -b -u {unit} -o cat | grep -c '^agenix-restart:' || true"
              ).strip())

          def activate(content):
              before = runs()
              machine.succeed(f"fake-agenix-activate {content}")
              machine.wait_until_succeeds(
                  f"test $(journalctl -b -u {unit} -o cat | grep -c '^agenix-restart:') -gt {before}",
                  timeout=30,
              )
              machine.wait_until_succeeds(f"! systemctl is-active --quiet {unit}", timeout=30)

          machine.wait_for_unit("multi-user.target")
          machine.wait_for_unit("crowdsec.service")
          machine.wait_for_unit("${unitName}.path")

          # Boot records a baseline without restarting anything.
          machine.wait_until_succeeds("test -s /run/agenix-restart/${secretName}.sha256", timeout=30)
          machine.succeed("test \"$(stat -c %a /run/agenix-restart)\" = 700")
          machine.succeed("test \"$(stat -c %a /run/agenix-restart/${secretName}.sha256)\" = 600")
          assert starts() == 1, f"boot restarted the consumer: {starts()} starts"

          # Two activations with unchanged content fire the path unit but do
          # not restart the consumer.
          activate("initial")
          activate("initial")
          assert starts() == 1, f"unchanged secret restarted the consumer: {starts()} starts"
          machine.succeed(f"journalctl -b -u {unit} -o cat | grep -q 'content unchanged'")

          # Rotation restarts the consumer once.
          activate("rotated")
          machine.wait_until_succeeds("test $(wc -l < /run/consumer-starts) -eq 2", timeout=30)

          # The new content becomes the baseline.
          activate("rotated")
          assert starts() == 2, f"repeat of rotated secret restarted the consumer: {starts()} starts"
        '';
      };
    in
    {
      checks = lib.optionalAttrs (system == hvnSystem) {
        agenix-restart-guard = test // {
          # The "runtime" group suffix keeps this KVM test off hosted runners.
          meta = test.meta // {
            hestia.group = "${system}-agenix-runtime";
          };
        };
      };
      legacyPackages = lib.optionalAttrs (system == hvnSystem) {
        agenix-restart-guard-test = test;
      };
    };
}
