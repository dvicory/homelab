{
  lib,
  ...
}:
{
  # The access model depends on the pooling layer honouring a supplemental
  # capability group: a workload holds its own user and primary group and gets
  # the storage capability alongside them. mergerfs before 2.42.0 resolved
  # entitlements from the host group database instead, so this behaviour is the
  # actual contract and is worth asserting rather than only version-pinning.
  #
  # The three cases below are exactly the ones measured on 2.40.2 (denied) and
  # 2.42.0 (allowed) when the constraint was found.
  perSystem =
    { pkgs, system, ... }:
    let
      test = pkgs.testers.runNixOSTest {
        name = "mergerfs-capability";

        nodes.machine =
          { pkgs, ... }:
          {
            system.stateVersion = "26.05";

            virtualisation = {
              cores = 2;
              memorySize = 2048;
              diskSize = 4096;
            };

            environment.systemPackages = [
              pkgs.mergerfs
              pkgs.util-linux
            ];

            boot.supportedFilesystems = [
              "fuse"
              "fuse.mergerfs"
            ];
          };

        testScript = ''
          start_all()
          machine.wait_for_unit("multi-user.target")

          machine.succeed("mkdir -p /srv/b0 /srv/b1 /srv/pool")
          machine.succeed("mergerfs -o use_ino,category.create=mfs,allow_other /srv/b0:/srv/b1 /srv/pool")
          machine.succeed("mountpoint -q /srv/pool")

          # A storage capability owned by the fleet, materialized as a real group.
          machine.succeed("groupadd -g 505 media")
          machine.succeed("mkdir -p /srv/pool/library")
          machine.succeed("chown root:media /srv/pool/library")
          machine.succeed("chmod 2770 /srv/pool/library")

          # The contract: the capability works when held only supplementally, and
          # what such a process writes belongs to the capability group.
          machine.succeed("setpriv --reuid 6100 --regid 6100 --groups 505 -- touch /srv/pool/library/supplemental")
          machine.succeed("test \"$(stat -c %g /srv/pool/library/supplemental)\" = 505")

          # A process whose primary group is the capability may also write.
          machine.succeed("setpriv --reuid 6200 --regid 505 --groups 505 -- touch /srv/pool/library/primary")
          machine.succeed("test \"$(stat -c %g /srv/pool/library/primary)\" = 505")

          # Without the capability nothing may be written. Root is deliberately
          # not part of this: at host level it has CAP_DAC_OVERRIDE and is not
          # constrained by the mode, which is why the corresponding check lives
          # with the compute boundary instead.
          machine.fail("setpriv --reuid 6300 --regid 6300 --groups 6300 -- touch /srv/pool/library/without")

          # Ingest depends on hardlinks being real, so the pool must not silently
          # satisfy them by copying.
          machine.succeed(
              "setpriv --reuid 6100 --regid 6100 --groups 505 -- sh -c"
              " 'printf x > /srv/pool/library/src && ln /srv/pool/library/src /srv/pool/library/dst'"
          )
          machine.succeed("test \"$(stat -c %h /srv/pool/library/src)\" -eq 2")
          machine.succeed(
              "test \"$(stat -c %i /srv/pool/library/src)\" = \"$(stat -c %i /srv/pool/library/dst)\""
          )
        '';
      };
    in
    {
      # Run locally on a Linux host; CI provides one.
      legacyPackages.mergerfs-capability-test = test;
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        mergerfs-capability = test // {
          meta = test.meta // {
            hestia.group = "${system}-mergerfs-runtime";
          };
        };
      };
    };
}
