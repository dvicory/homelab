# Runs modules/tests/classify-legacy-media.sh as root in a VM with the media
# group, against the real prepare-luks-storage readers. The build sandbox
# cannot set setgid bits, so the test needs a VM.
{
  lib,
  self,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    let
      test = pkgs.testers.runNixOSTest {
        name = "classify-legacy-media";
        requiredFeatures.kvm = true;
        nodes.machine =
          { pkgs, ... }:
          {
          system.stateVersion = "26.05";
          users.groups.media.gid = 505;
          environment.systemPackages = [
            pkgs.acl
            pkgs.python3
          ];
        };
        testScript = ''
          start_all()
          machine.succeed(
              "PREPARE_LUKS_STORAGE=${self + "/pkgs/by-name/prepare-luks-storage/prepare-luks-storage.sh"} "
              "CLASSIFY_LEGACY_MEDIA=${self + "/pkgs/by-name/classify-legacy-media/classify-legacy-media.sh"} "
              "bash ${./classify-legacy-media.sh} >&2"
          )
        '';
      };
    in
    {
      checks = lib.optionalAttrs (lib.hasSuffix "-linux" system) {
        classify-legacy-media = test // {
          meta = test.meta // {
            hestia.group = "${system}-classify-legacy-media-runtime";
          };
        };
      };
    };
}
