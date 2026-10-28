# Node-owned artifacts, not a runtime wrapper. CRI still applies the pod's
# ordinary user, groups, capabilities, no-new-privileges and mount options.
{
  pkgs,
  driverEnvironment,
  dispatcher,
  k3s,
  retainedRuntimeHook ? null,
}:
let
  closure = pkgs.closureInfo {
    rootPaths = [
      driverEnvironment
      dispatcher
    ];
  };
  # Retained Jellyfin 12.1 image loader inventory: VA searches this directory;
  # its libmfx-gen.so and .so.1.2 links resolve to the .so.1.2.17 file.
  # Do not mount the parent lib directory or replace image libc/the ELF loader.
  entrypoints = pkgs.writeText "i915-native-image-entrypoints.json" (
    builtins.toJSON [
      {
        source = "${driverEnvironment}/lib/dri/iHD_drv_video.so";
        destination = "/usr/lib/jellyfin-ffmpeg/lib/dri/iHD_drv_video.so";
      }
      {
        source = "${driverEnvironment}/lib/dri/virtio_gpu_drv_video.so";
        destination = "/usr/lib/jellyfin-ffmpeg/lib/dri/virtio_gpu_drv_video.so";
      }
      {
        source = "${driverEnvironment}/lib/libmfx-gen.so.1.2";
        destination = "/usr/lib/jellyfin-ffmpeg/lib/libmfx-gen.so.1.2.17";
      }
      {
        source = "${driverEnvironment}/etc/OpenCL/vendors/rusticl.icd";
        destination = "/etc/OpenCL/vendors/rusticl.icd";
      }
    ]
  );
  # A selected handler must retain the node producer's native admission hook.
  # Keep its host-side closure separate from the driver binds exposed to apps.
  retainedHook = pkgs.lib.optionalString (retainedRuntimeHook != null) (
    "spec.setdefault(\"hooks\", {}).setdefault(\"createRuntime\", []).append("
    + builtins.toJSON {
      path = "${retainedRuntimeHook}";
      args = [ "${retainedRuntimeHook}" ];
      timeout = 30;
    }
    + ")\n"
  );
in
pkgs.runCommand "i915-native-k3s-runtime-spec"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    mkdir -p "$out"
    # Invoke the exact ctr embedded in the installed k3s, without unpacking its
    # outer launcher in the build sandbox. It needs no daemon or root privilege.
    ${k3s.k3sBundle}/bin/ctr --namespace k8s.io oci spec --platform linux/amd64 > "$out/baseline.json"
    ${pkgs.python3}/bin/python3 - "$out" ${closure}/store-paths ${entrypoints} <<'PY'
    import copy
    import json
    import pathlib
    import sys

    output, closure_file, entrypoint_file = map(pathlib.Path, sys.argv[1:])
    baseline = json.loads((output / "baseline.json").read_text())
    spec = copy.deepcopy(baseline)
    # CRI normally removes ctr's incidental nofile limit of 1024. A custom baseline
    # skips that normalizer; keep the same inherited service/workload semantics.
    spec["process"].pop("rlimits", None)
    # Keep the ordinary deny-all rule before the narrowly scoped GPU allowance.
    deny_all = {"allow": False, "access": "rwm"}
    assert spec["linux"]["resources"]["devices"] == [deny_all]

    paths = closure_file.read_text().splitlines()
    assert paths and len(paths) == len(set(paths))
    roots = set(paths)
    mounts = []
    for path in paths:
        source = pathlib.Path(path)
        assert str(source.parent) == "/nix/store" and source.exists()
        mounts.append({"source": path, "destination": path})
    for entry in json.loads(entrypoint_file.read_text()):
        source = pathlib.Path(entry["source"]).resolve(strict=True)
        assert source.is_file()
        assert any(str(source).startswith(root + "/") for root in roots)
        mounts.append({"source": str(source), "destination": entry["destination"]})
    # The normally linked dispatcher uses the guest's normal driver-link path.
    # This is the finite bundle, not a mount of the host's store or /run.
    mounts.append({
        "source": "${driverEnvironment}", "destination": "/run/opengl-driver"
    })
    for mount in mounts:
        mount.update(type="bind", options=["bind", "ro", "nosuid", "nodev"])
    assert len({mount["destination"] for mount in mounts}) == len(mounts)
    assert not {mount["destination"] for mount in baseline["mounts"]} & {
        mount["destination"] for mount in mounts
    }
    ${retainedHook}spec["mounts"].extend(mounts)
    spec["linux"]["resources"]["devices"].append({
        "allow": True, "type": "c", "major": 226, "minor": 128, "access": "rw"
    })
    (output / "config.json").write_text(json.dumps(spec, indent=2) + "\n")
    # Keep the exact finite closure rooted with the baseline, even though the
    # canonical paths otherwise occur only as generated JSON strings.
    (output / "store-paths").write_text("\n".join(paths) + "\n")
    PY
  ''
