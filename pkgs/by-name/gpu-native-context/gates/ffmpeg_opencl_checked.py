"""Run the real FFmpeg OpenCL transpose filter and compare every output byte."""
import argparse
from pathlib import Path
import subprocess


def run_command(command, log):
    print("COMMAND", *command, flush=True)
    with log.open("w") as output:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=60)
    print(log.read_text(), flush=True)
    result.check_returncode()


def run(ffmpeg, destination, reference_only=False):
    destination.mkdir(parents=True, exist_ok=False)
    # Four distinct, non-symmetric YUV420P frames, no codecs or application data needed.
    raw = bytes((i * 37 + i // 97) % 256 for i in range(128 * 96 * 3 // 2 * 4))
    source = destination / "input.yuv"
    source.write_bytes(raw)
    cpu = destination / "cpu-transpose.yuv"
    gpu = destination / "gpu-transpose.yuv"
    common = [ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "verbose", "-y"]
    input_args = ["-f", "rawvideo", "-pixel_format", "yuv420p", "-video_size", "128x96", "-framerate", "1", "-i", str(source)]
    output_args = ["-frames:v", "4", "-an", "-pix_fmt", "yuv420p", "-f", "rawvideo"]
    run_command(common + input_args + ["-vf", "transpose=clock"] + output_args + [str(cpu)], destination / "cpu.log")
    reference = cpu.read_bytes()
    if len(reference) != len(raw) or reference == raw:
        raise RuntimeError("Invalid CPU transpose reference")
    if reference_only:
        print(f"CPU REFERENCE ONLY: four transposed frames, {len(reference)} bytes; GPU acceptance NOT RUN", flush=True)
        return
    # Normal ICD discovery; standard filters must uniquely select Rusticl's GPU.
    # Never accept a CPU device or a different backend at platform index zero.
    run_command(common + ["-init_hw_device", "opencl=ocl:,platform_name=rusticl,device_type=gpu", "-filter_hw_device", "ocl"] + input_args +
                ["-vf", "hwupload,transpose_opencl=dir=clock,hwdownload,format=yuv420p"] + output_args + [str(gpu)],
                destination / "gpu.log")
    actual = gpu.read_bytes()
    if actual != reference:
        raise RuntimeError("OpenCL transpose differs from the independent CPU reference")
    print(f"PASS real FFmpeg OpenCL transpose: four 128x96 -> 96x128 frames, {len(actual)} exact checked bytes", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--reference-only", action="store_true", help="CPU preparation only; never GPU acceptance")
    args = parser.parse_args()
    if args.output_dir is None:
        parser.error("--output-dir is required")
    run(args.ffmpeg, args.output_dir, args.reference_only)
