"""Codec and comparison bridge for the single-session Questa Tcl launcher."""
import argparse
import json
import sys
from pathlib import Path

from PIL import Image

from run import sha256, write_comparison


def prepare(source, directory):
    with Image.open(source) as image:
        frame = image.convert("RGB")
    data = frame.tobytes()
    (directory / "source.rgb").write_bytes(data)
    metadata = {"width": frame.width, "height": frame.height, "input_file": source.name,
                "input_file_sha256": sha256(source.read_bytes()), "input_rgb_sha256": sha256(data)}
    (directory / "frame.json").write_text(json.dumps(metadata), encoding="utf-8")
    print(frame.width, frame.height)


def capture(directory, output, reference, log):
    meta = json.loads((directory / "frame.json").read_text(encoding="utf-8"))
    width, height = meta.pop("width"), meta.pop("height")
    if (directory / "axis.passed").read_bytes() != b"1":
        raise ValueError("No successful AXI end-of-test marker")
    data = (directory / "capture.rgb").read_bytes()
    expected = 3 * width * height
    if len(data) != expected:
        raise ValueError(f"Captured {len(data)} bytes, expected {expected}")
    Image.frombytes("RGB", (width, height), data).save(output, format="BMP")
    print(f"Saved {output}")
    if reference is None:
        return 0
    simulation = dict(meta, simulator="Questa/ModelSim (vsim)", stress=False,
                      packing="shift", simulation_log=log.name)
    return write_comparison(output, reference, output.with_name(output.stem + "_comparison.json"),
                            simulation)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prep = commands.add_parser("prepare")
    prep.add_argument("source", type=Path)
    prep.add_argument("directory", type=Path)
    finish = commands.add_parser("capture")
    finish.add_argument("directory", type=Path)
    finish.add_argument("output", type=Path)
    finish.add_argument("log", type=Path)
    finish.add_argument("--reference", type=Path)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.source, args.directory)
        return 0
    return capture(args.directory, args.output, args.reference, args.log)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print(error, file=sys.stderr)
        sys.exit(2)
