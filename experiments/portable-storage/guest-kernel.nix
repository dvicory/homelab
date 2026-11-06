# Disposable guest only. Never imported by the fleet flake or production modules.
# Backport: https://github.com/torvalds/linux/commit/34b5c4a6e4fb9dbb3f9d87f3b0fb0372105c8302
# The patch is a real diff of upstream v6.18.49 fs/fuse/{dir,file}.c after
# applying that exact upstream change; only hunk locations/context differ.
# The default pair uses the same stable package/configuration. A supplied upstream
# fixedKernel keeps the guest userspace unchanged when testing a stock upgrade.
# Cache/mmap settings belong to the disposable host attachment, not a fleet default.
# Build backportSource first and inspect its log for any offset/fuzz before backports.
{
  nixpkgs ?
    let
      lock = builtins.fromJSON (builtins.readFile ../../flake.lock);
      input = lock.nodes.${lock.nodes.root.inputs.nixpkgs}.locked;
    in
    builtins.fetchTarball {
      inherit (input) url;
      sha256 = input.narHash;
    },
  fixedKernel ? null,
}:
let
  system = "x86_64-linux";
  pkgs = import nixpkgs { inherit system; };
  workloads = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [
      ./filesystem_workload.py
      ./sqlite_workload.py
      ./postgres_workload.py
    ];
  };
  baseKernel = pkgs.linuxPackages_6_18.kernel;
  fixCommit = "34b5c4a6e4fb9dbb3f9d87f3b0fb0372105c8302";
  upstreamPatch = pkgs.fetchurl {
    url = "https://github.com/torvalds/linux/commit/${fixCommit}.patch";
    hash = "sha256-wewo5o1OOaXU4tL571/7uHM5ItenSBMKE9u7N7O3ngw=";
  };
  backportSource = pkgs.applyPatches {
    name = "linux-${baseKernel.version}-fuse-partial-eof-source";
    src = baseKernel.src;
    patches = [ ./fuse-partial-eof-6.18.49.patch ];
    patchFlags = [
      "-p1"
      "--fuzz=0"
    ];
  };
  repairedKernel =
    if fixedKernel != null then
      fixedKernel
    else
      baseKernel.override { argsOverride.src = backportSource; };
  guest =
    fixed:
    let
      evaluated = import (pkgs.path + "/nixos/lib/eval-config.nix") {
        inherit system;
        modules = [
          (pkgs.path + "/nixos/modules/virtualisation/incus-virtual-machine.nix")
          ({ ... }: {
            networking.hostName = "vfq-guest";
            system.stateVersion = "26.05";
            boot.kernelPackages =
              if fixed then pkgs.linuxPackagesFor repairedKernel else pkgs.linuxPackages_6_18;
            boot.kernelModules = [ "virtiofs" ];
            virtualisation.incus.agent.enable = true;
            services.openssh.enable = false;
            users.users.root.initialHashedPassword = "!";
            users.groups.vfq.gid = 1000;
            users.users.vfq = {
              isNormalUser = true;
              uid = 1000;
              group = "vfq";
            };
            # Create the underlay without changing a payload mounted before tmpfiles.
            systemd.tmpfiles.rules = [ "d /srv/vfq :0700 :root :root -" ];
            environment.systemPackages = [
              pkgs.python3
              pkgs.postgresql_18
              pkgs.sqlite
              pkgs.acl
            ];
            environment.etc."vfq".source = workloads;
            documentation.enable = false;
            documentation.nixos.enable = false;
            system.installer.channel.enable = false;
          })
        ];
      };
      inherit (evaluated) config;
    in
    {
      inherit config;
      inherit (config.system.build) metadata qemuImage toplevel;
      kernel = config.boot.kernelPackages.kernel;
      source = if fixed then repairedKernel.src else baseKernel.src;
      metadataFile = "${config.system.build.metadata}/tarball/${config.image.fileName}";
      imageFile = "${config.system.build.qemuImage}/nixos.qcow2";
    };
in
assert baseKernel.version == "6.18.49";
{
  inherit upstreamPatch backportSource fixCommit;
  unfixed = guest false;
  fixed = guest true;
}
