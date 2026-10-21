"""Execute Intel's unchanged official sample with a pinned public SqueezeNet model.

A Python return-profile hook observes the official sample's completed results and
compiled-model device property. It does not replace any OpenVINO API or inference.
"""
import argparse
import hashlib
import importlib.util
from pathlib import Path
import sys

import numpy as np


PINS = {
    "model": "dec81a8684617770b3cf13fadc1d92565d1d453d23935fc6388b792d99c992bd",
    "sample": "7fe509f9667008b60ca4bb496fb306503e045e67492bc70cbe9f94d47e89fd1a",
    "image": "f3f87bb8ab3c26c7ecfd3ac60421d7f32b0503d1d6c5baf8bac42ed93d86351a",
}


def check(gpu, cpu, devices):
    if not devices or any(device not in ("GPU", "GPU.0") for device in devices):
        raise RuntimeError(f"Official sample did not execute exclusively on GPU.0: {devices!r}")
    if gpu.size != 1000 or gpu.shape != cpu.shape or not np.isfinite(gpu).all() or not np.isfinite(cpu).all():
        raise RuntimeError("Invalid public-model output")
    if np.ptp(cpu) < 0.1:
        raise RuntimeError("Degenerate classification reference")
    np.testing.assert_allclose(gpu, cpu, rtol=0.05, atol=0.01)
    if int(np.argmax(gpu)) != 258 or int(np.argmax(cpu)) != 258:
        raise RuntimeError("Public dog image must classify as ImageNet class 258 (Samoyed)")


def execute_sample(sample, model, image, device):
    spec = importlib.util.spec_from_file_location("official_hello_classification", sample)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    observed = {}

    def observe(frame, event, argument):
        if frame.f_code is module.main.__code__ and event == "return" and argument == 0:
            compiled = frame.f_locals["compiled_model"]
            observed["devices"] = list(compiled.get_property("EXECUTION_DEVICES"))
            observed["output"] = np.array(next(iter(frame.f_locals["results"].values())), copy=True)
        return None

    old_argv = sys.argv
    sys.argv = [str(sample), str(model), str(image), device]
    print("OFFICIAL_SAMPLE_COMMAND", sys.executable, *sys.argv, flush=True)
    try:
        sys.setprofile(observe)
        status = module.main()
    finally:
        sys.setprofile(None)
        sys.argv = old_argv
    if status != 0 or "output" not in observed:
        raise RuntimeError(f"Official sample failed on {device}: status={status}")
    print(f"official_sample_requested={device} execution_devices={observed['devices']!r}", flush=True)
    return observed["output"], observed["devices"]


def run(args):
    import cv2
    import openvino as ov

    for kind in PINS:
        path = getattr(args, kind)
        if hashlib.sha256(path.read_bytes()).hexdigest() != PINS[kind]:
            raise RuntimeError(f"Pinned {kind} hash mismatch: {path}")
    args.output_dir.mkdir(parents=True, exist_ok=False)
    # Standard ImageNet resize/center-crop. Keep original pinned weights; attach
    # Caffe BGR mean preprocessing as a derived IR consumed by the sample.
    image = cv2.imread(str(args.image))
    h, w = image.shape[:2]
    resized = cv2.resize(image, (round(w * 256 / min(h, w)), round(h * 256 / min(h, w))))
    h, w = resized.shape[:2]
    image_path = args.output_dir / "dog-center-crop.png"
    if not cv2.imwrite(str(image_path), resized[(h - 224) // 2:(h + 224) // 2, (w - 224) // 2:(w + 224) // 2]):
        raise RuntimeError("Could not write prepared input image")
    core = ov.Core()
    model = core.read_model(str(args.model))
    ppp = ov.preprocess.PrePostProcessor(model)
    ppp.input().tensor().set_layout(ov.Layout("NCHW"))
    ppp.input().model().set_layout(ov.Layout("NCHW"))
    ppp.input().preprocess().mean([103.939, 116.779, 123.68])
    prepared_model = args.output_dir / "squeezenet-imagenet.xml"
    ov.serialize(ppp.build(), str(prepared_model))
    print(f"openvino_version={ov.get_version()} public_model_sha256={PINS['model']}", flush=True)
    # CPU is a separately requested reference, never an inference fallback.
    cpu, cpu_devices = execute_sample(args.sample, prepared_model, image_path, "CPU")
    if cpu_devices != ["CPU"]:
        raise RuntimeError(f"Unexpected reference execution devices: {cpu_devices!r}")
    np.save(args.output_dir / "cpu-output.npy", cpu)
    if int(np.argmax(cpu)) != 258:
        raise RuntimeError("CPU reference does not classify the public dog as Samoyed")
    if args.reference_only:
        print(f"CPU REFERENCE ONLY top1={int(np.argmax(cpu))}; GPU acceptance NOT RUN", flush=True)
        return
    gpu, devices = execute_sample(args.sample, prepared_model, image_path, "GPU.0")
    np.save(args.output_dir / "gpu-output.npy", gpu)
    check(gpu, cpu, devices)
    print(f"PASS official OpenVINO hello_classification: public SqueezeNet, 1000 checked outputs, GPU.0 only, top1={int(np.argmax(gpu))}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path)
    parser.add_argument("--image", type=Path)
    parser.add_argument("--sample", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--reference-only", action="store_true", help="CPU preparation only; never GPU acceptance")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        values = np.arange(1000, dtype=np.float32)
        values[258] = 2000
        check(values * .99, values, ["GPU.0"])
        for devices in ([], ["CPU"], ["GPU.0", "CPU"]):
            try:
                check(values, values, devices)
            except RuntimeError:
                pass
            else:
                raise RuntimeError("Device oracle accepted fallback")
        corrupt = values.copy()
        corrupt[12] += 50  # Preserve top-1: every score, not just the label, matters.
        try:
            check(corrupt, values, ["GPU.0"])
        except AssertionError:
            pass
        else:
            raise RuntimeError("Output oracle accepted corruption")
        print("PASS official-sample observation oracle only; no inference or GPU used")
    else:
        if any(getattr(args, option) is None for option in ("model", "image", "sample", "output_dir")):
            parser.error("--model --image --sample --output-dir are required")
        run(args)
