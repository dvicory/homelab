{ config, inputs, ... }:
let
  cluster = config.den.clusters.prod-home;
  compute =
    config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
in
{
  den.aspects.services.retained-runtime.nixos =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      # Only backing/root trust is OS-owned. Per-application identity is read
      # from the compared cluster inventory at each affected container create.
      parent = inputs.self.nixosConfigurations.${cluster.hostName}.config;
      hostSpec = builtins.fromJSON parent.environment.etc."homelab/retained-root.json".text;
      runtime = pkgs.callPackage (inputs.self + "/pkgs/by-name/compute-runtime/package.nix") { };
      hook = pkgs.writeScript "retained-runtime-hook" (
        "#!${pkgs.python3}/bin/python3\n" + builtins.readFile ./retained-runtime-hook.py
      );
      root = hostSpec.root // {
        path = compute.stateGuestPath;
        uid = 0;
        gid = 0;
      };
      fragment = pkgs.writeText "retained-runtime.toml" ''
        [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
          base_runtime_spec = "/run/homelab-retained-runtime/base.json"
        [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
          BinaryName = "${pkgs.runc}/bin/runc"
          SystemdCgroup = true
      '';
      prepare = pkgs.writeText "prepare-retained-runtime.py" ''
        import json
        import pathlib
        import subprocess
        base = pathlib.Path('/run/homelab-retained-runtime')
        base.mkdir(mode=0o700, exist_ok=True)
        spec = json.loads(subprocess.run(
            ['${config.services.k3s.package}/bin/k3s', 'ctr', '--namespace', 'k8s.io', 'oci', 'spec'],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, check=True, timeout=15).stdout)
        if spec.get('hooks'):
            raise ValueError('native baseline already has hooks; compose explicitly')
        # ctr's interactive-shell nofile ceiling is not the CRI container policy.
        spec['process']['rlimits'] = [limit for limit in spec['process'].get('rlimits', [])
                                     if limit['type'] != 'RLIMIT_NOFILE']
        spec['hooks'] = {'createRuntime': [{
            'path': '${hook}', 'args': ['${hook}'], 'timeout': 30}]}
        (base / 'base.json').write_text(json.dumps(spec) + '\n')
      '';
    in
    {
      environment.systemPackages = [
        runtime
        pkgs.coreutils
      ];
      # K3s otherwise chooses cgroupfs in a user namespace, which is not
      # compatible with the mandatory native systemd scope lifetime boundary.
      services.k3s.extraFlags = [ "--kubelet-arg=cgroup-driver=systemd" ];
      environment.etc."homelab/retained-node.json".text = builtins.toJSON {
        version = 1;
        inherit root;
        entries = { };
        k3s = "${config.services.k3s.package}/bin/k3s";
        helper = "${runtime}/bin/retained-directories";
        systemctl = "${pkgs.systemd}/bin/systemctl";
        systemdRun = "${pkgs.systemd}/bin/systemd-run";
        kubeletRoot = "/var/lib/kubelet";
        inventoryNamespace = "local-path-storage";
        inventoryName = "retained-directories";
        inventoryKey = "directories.json";
      };
      # Optional native-runc handlers compose this exact same fixed hook into
      # their own normal baseline; they must not replace this default baseline.
      system.build.retainedRuntimeHook = hook;
      systemd.services.k3s.preStart = lib.mkBefore ''
        ${pkgs.python3}/bin/python3 ${prepare}
        install -d -m 0755 /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d
        ln -sfn ${fragment} /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/91-retained-runtime.toml
      '';
    };
}
