# Disposable upstream-FUSE diagnostic; not imported by the fleet flake.
let
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  input = lock.nodes.${lock.nodes.root.inputs.nixpkgs}.locked;
  nixpkgs = builtins.fetchTarball {
    inherit (input) url;
    sha256 = input.narHash;
  };
  pkgs = import nixpkgs { system = "x86_64-linux"; };
  kernel = import ./lts-virtiofs-kernel.nix;
  probe = pkgs.stdenv.mkDerivation {
    pname = "fuse-eof-probe";
    version = "1";
    src = ../experiments/portable-storage/eof-probe.c;
    dontUnpack = true;
    buildPhase = ''
      runHook preBuild
      $CC -O2 -Wall -Wextra -pthread "$src" -o eof-probe
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 eof-probe "$out/bin/eof-probe"
      runHook postInstall
    '';
  };
  fuseModule = import ../experiments/portable-storage/fuse-module.nix {
    inherit pkgs kernel;
    patches = [ ../experiments/portable-storage/fuse-direct-io-eof.patch ];
  };
  diagnostic = pkgs.testers.runNixOSTest {
    name = "fuse-direct-eof-diagnostic";
    globalTimeout = 5 * 60;
    requiredFeatures.kvm = true;
    qemu.forceAccel = true;
    nodes.machine = {
      boot.kernelPackages = pkgs.linuxPackagesFor kernel;
      boot.kernelModules = [ "fuse" ];
      virtualisation.memorySize = 1024;
      virtualisation.cores = 2;
      environment.systemPackages = [ probe ];
      virtualisation.additionalPaths = [ fuseModule ];
    };
    testScript = ''
      import json

      machine.start()
      machine.wait_for_unit("multi-user.target")
      assert machine.succeed("uname -r").strip() == "6.18.62"
      observations = {}
      expected_cases = {
          "write_extend": 0,
          "ftruncate_extend": 0,
          "fallocate_extend": 0,
          "extend_into_eof_page_preserves_data": 0,
      }
      for variant in ("stock", "candidate"):
          if variant == "candidate":
              machine.succeed("if mountpoint -q /sys/fs/fuse/connections; then umount /sys/fs/fuse/connections; fi")
              machine.succeed("modprobe -r fuse; test ! -d /sys/module/fuse")
              machine.succeed("insmod ${fuseModule}/lib/modules/6.18.62/extra/fuse.ko")
              machine.succeed("udevadm settle; test -c /dev/fuse")
              metadata = machine.succeed("modinfo ${fuseModule}/lib/modules/6.18.62/extra/fuse.ko")
              (driver.out_dir / "candidate-module.log").write_text(metadata)
          observations[variant] = {}
          for mode in ("cached", "direct-mmap", "cached-odirect"):
              status, output = machine.execute(f"timeout 60 eof-probe {mode}")
              print(output)
              (driver.out_dir / f"{variant}-{mode}.log").write_text(output)
              cases = {}
              for line in output.splitlines():
                  if line.startswith("case=") and " result=" in line:
                      fields = dict(part.split("=", 1) for part in line.split())
                      cases[fields["case"]] = int(fields["exit"])
              expected = dict(expected_cases)
              if variant == "stock" and mode == "direct-mmap":
                  expected["write_extend"] = 1
              elif variant == "stock" and mode == "cached-odirect":
                  assert cases.get("write_extend") in (0, 1), (mode, cases)
                  expected["write_extend"] = cases["write_extend"]
              assert cases == expected, (variant, mode, status, cases, expected)
              assert status == max(expected.values()), (variant, mode, status)
              observations[variant][mode] = {"exit": status, "cases": cases}
      (driver.out_dir / "observations.json").write_text(json.dumps(observations, indent=2) + "\n")
      machine.shutdown()
    '';
  };
in
assert kernel.drvPath == "/nix/store/wq6fwwa4vdsj5wvz66sm6fbp35b036wp-linux-6.18.62.drv";
{
  inherit
    kernel
    probe
    fuseModule
    diagnostic
    ;
}
