"""Simulate an RGB frame, then independently compare the saved BMP to a reference."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import numpy as np
import PIL
from PIL import Image, features

ROOT = Path(__file__).resolve().parents[1]
TOP = "tb_axis_portrait_filter"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def compare(output_path, reference_path):
    with Image.open(output_path) as image:
        actual = np.asarray(image.convert("RGB"))
    with Image.open(reference_path) as image:
        target = np.asarray(image.convert("RGB"))
    if actual.shape != target.shape:
        raise ValueError(f"Image dimensions differ: output {actual.shape}, reference {target.shape}")
    height, width, _ = actual.shape
    differences = actual.astype(np.int16) - target.astype(np.int16)
    absolute = np.abs(differences)
    unequal = np.any(differences != 0, axis=2)
    count = int(np.count_nonzero(unequal))
    pixels = width * height
    mse = float(np.mean(np.square(differences, dtype=np.float64)))
    first = None
    if count:
        y, x = divmod(int(unequal.argmax()), width)
        first = {"x": x, "y": y, "output_rgb": actual[y, x].tolist(),
                 "reference_rgb": target[y, x].tolist()}
    return {
        "exact_match": count == 0,
        "width": width, "height": height, "total_pixels": pixels,
        "exact_rgb_pixels": pixels - count, "different_rgb_pixels": count,
        "exact_percent": 100 * (pixels - count) / pixels,
        "mean_absolute_channel_error": float(absolute.mean()),
        "mean_absolute_error_by_channel_rgb": absolute.mean(axis=(0, 1)).tolist(),
        "maximum_absolute_channel_error": int(absolute.max()),
        "rmse": math.sqrt(mse),
        "psnr_db": 10 * math.log10(255**2 / mse) if mse else "infinite",
        "first_difference": first,
        "output_file": output_path.name,
        "output_file_sha256": sha256(output_path.read_bytes()),
        "output_rgb_sha256": sha256(actual.tobytes()),
        "reference_file": reference_path.name,
        "reference_file_sha256": sha256(reference_path.read_bytes()),
        "reference_rgb_sha256": sha256(target.tobytes()),
        "pillow": PIL.__version__,
        "libjpeg_turbo": features.version_feature("libjpeg_turbo"),
    }


def run_simulator(simulator, files, width, height, args, work, log_path):
    executable = shutil.which(simulator)
    if executable is None:
        raise FileNotFoundError(f"{simulator} was not found on PATH")
    executable = str(Path(executable).resolve())
    settings = [f"G_WIDTH={width}", f"G_HEIGHT={height}", f"G_STRESS={str(args.stress).lower()}",
                f"G_SHIFT={str(args.packing == 'shift').lower()}", f"G_TRACE={str(args.trace is not None).lower()}"]
    if simulator == "nvc":
        base = [executable, "--std=2008", "-H", "512m"]
        generics = [arg for setting in settings for arg in ("-g", setting)]
        commands = [base + ["-a", *files], base + ["-e", *generics, TOP],
                    base + ["-r", TOP]]
    else:
        generics = ["-g" + setting for setting in settings]
        commands = [[executable, "-a", "--std=08", *files],
                    [executable, "-e", "--std=08", TOP],
                    [executable, "-r", "--std=08", TOP, *generics, "--assert-level=error"]]
    version = subprocess.check_output([executable, "--version"], text=True).splitlines()[0]
    with log_path.open("w", encoding="utf-8") as log:
        print(version, file=log)
        print(" ".join(settings), file=log)
        for command in commands:
            process = subprocess.run(command, cwd=work, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True, errors="replace")
            log.write(process.stdout)
            print(process.stdout, end="")
            if process.returncode:
                raise RuntimeError(f"Simulator failed with exit {process.returncode}. Log: {log_path}")
    return version


def simulate(args):
    with Image.open(args.input) as image:
        frame = image.convert("RGB")
    width, height = frame.size
    rtl = ROOT / "rtl"
    files = []
    for line in (rtl / "files.f").read_text(encoding="utf-8").splitlines():
        name = line.partition("#")[0].strip()
        if name:
            files.append(str((rtl / name).resolve(strict=True)))
    files.append(str(ROOT / "sim" / (TOP + ".vhd")))
    simulator = args.simulator
    if simulator == "auto":
        simulator = "nvc" if shutil.which("nvc") else "ghdl"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    log_path = args.output.with_name(args.output.stem + "_simulation.log")
    with tempfile.TemporaryDirectory(prefix="portrait-sim-") as directory:
        work = Path(directory)
        rgb = frame.tobytes()
        (work / "source.rgb").write_bytes(rgb)
        version = run_simulator(simulator, files, width, height, args, work, log_path)
        capture = (work / "capture.rgb").read_bytes()
        if len(capture) != width * height * 3:
            raise ValueError(f"Capture has {len(capture)} bytes, expected {width * height * 3}")
        output = Image.frombytes("RGB", frame.size, capture)
        output.save(args.output, format="BMP")
        if args.trace:
            trace = work / "capture.u32le"
            if trace.stat().st_size != width * height * 4:
                raise ValueError("Unexpected packed output trace size")
            args.trace.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(trace, args.trace)
    return {"input_file": args.input.name, "input_file_sha256": sha256(args.input.read_bytes()),
            "input_rgb_sha256": sha256(rgb), "simulator": version, "stress": args.stress,
            "packing": args.packing, "simulation_log": log_path.name}


def write_comparison(output, reference, report_path, simulation=None):
    report = compare(output, reference)
    if simulation:
        report["simulation"] = simulation
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"Exact RGB pixels: {report['exact_rgb_pixels']:,}/{report['total_pixels']:,}. "
          f"Mean absolute channel error: {report['mean_absolute_channel_error']:.4f}.")
    print(f"{'PASS' if report['exact_match'] else 'FAIL'} pixel equality. Report: {report_path}")
    return 0 if report["exact_match"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=ROOT / "images/PIC1.bmp")
    parser.add_argument("--reference", type=Path,
                        default=ROOT / "reference/Designer1_PIC1_2048x1152.jpg")
    parser.add_argument("--output", type=Path, default=ROOT / "results/PIC1_filtered.bmp")
    parser.add_argument("--report", type=Path, help="default: <output stem>_comparison.json")
    parser.add_argument("--simulator", choices=("auto", "nvc", "ghdl"), default="auto")
    parser.add_argument("--packing", choices=("replicate", "shift"), default="shift",
                        help="RGB8 to RGB10 per channel: repeat the top two bits or shift left by two")
    parser.add_argument("--trace", type=Path,
                        help="save each accepted 32-bit output word in little-endian order")
    parser.add_argument("--stress", action="store_true", help="insert input gaps and output stalls")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--no-reference", action="store_true",
                       help="only simulate and save the BMP; omit the exact-match check")
    modes.add_argument("--compare-only", action="store_true", help="compare an existing BMP")
    args = parser.parse_args()
    simulation = {} if args.compare_only else simulate(args)
    if args.no_reference:
        print(f"Saved {args.output}")
        return 0
    suffix = "_recheck.json" if args.compare_only else "_comparison.json"
    path = args.report or args.output.with_name(args.output.stem + suffix)
    return write_comparison(args.output, args.reference, path, simulation)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print(error, file=sys.stderr)
        sys.exit(2)
