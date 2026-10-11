{
  lib,
  python3,
  runCommand,
}:
let
  script = ./host_telemetry.py;
in
runCommand "host-telemetry"
  {
    meta = {
      description = "Write ZFS and SMART status as node_exporter textfile metrics";
      mainProgram = "host-telemetry";
      platforms = lib.platforms.linux;
    };
    passthru.tests = runCommand "host-telemetry-tests" { nativeBuildInputs = [ python3 ]; } ''
      cp -r ${./.} source
      chmod -R u+w source
      cd source
      python3 -W error::ResourceWarning test_host_telemetry.py
      touch $out
    '';
  }
  ''
    mkdir -p $out/bin
    {
      echo '#!${lib.getExe python3}'
      cat ${script}
    } > $out/bin/host-telemetry
    chmod 0755 $out/bin/host-telemetry
  ''
