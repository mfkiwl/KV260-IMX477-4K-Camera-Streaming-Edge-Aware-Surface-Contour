"""Simulate a GHDL-synthesized VHDL top with Verilator and the VHDL JPEG decoder."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

from run_ghdl import ROOT, jpeg_dimensions


def run(args):
    ghdl = shutil.which(os.environ.get("GHDL", "ghdl"))
    verilator = shutil.which(os.environ.get("VERILATOR", "verilator"))
    if not ghdl or not verilator:
        raise SystemExit("Put GHDL and Verilator on PATH, or set GHDL and VERILATOR.")
    source = args.input.resolve()
    width, height = jpeg_dimensions(source)
    profile = "legacy" if args.legacy_pic2 else "full"
    build = args.build.resolve() / f"{width}x{height}_{profile}"
    build.mkdir(parents=True, exist_ok=True)
    suffix = "_filtered.bmp" if args.legacy_pic2 else ".bmp"
    output = (args.output or ROOT / "results" / (source.stem + suffix)).resolve()
    decoded = build / (source.stem + "_decoded.bmp")
    if output == decoded or output == source:
        raise ValueError("Output must have its own file path")
    output.parent.mkdir(parents=True, exist_ok=True)
    rtl = [ROOT / line for line in (ROOT / "sim/sources.txt").read_text().splitlines() if line.startswith("rtl/")]
    decoder = [ROOT / "tb" / f for f in ("jpeg_reader_pkg.vhd", "bmp_writer_pkg.vhd", "decode_frame.vhd")]

    def execute(argv, **kwargs):
        subprocess.run(argv, cwd=build, check=True, **kwargs)

    execute([ghdl, "-a", "--std=08", *rtl, *decoder])
    execute([ghdl, "-e", "--std=08", "decode_frame"])
    execute([ghdl, "-r", "--std=08", "decode_frame", f"-gG_INPUT={source}", f"-gG_OUTPUT={decoded}"])
    with (build / "wrapper.v").open("w") as netlist:
        execute([ghdl, "synth", "--std=08", "--no-formal", "--out=verilog", f"-gG_MAX_WIDTH={width}",
                 f"-gG_MAX_HEIGHT={height}", f"-gG_LEGACY_PIC2={str(args.legacy_pic2).lower()}",
                 "surface_contour_select"], stdout=netlist)
    execute([verilator, "--cc", "--exe", "--build", "-j", str(args.jobs), "--output-split", "3500",
             "--output-split-cfuncs", "100", "-Wno-fatal", "-Wno-WIDTH", "-Wno-CASEINCOMPLETE",
             "--top-module", "surface_contour_select", "wrapper.v", ROOT / "tb/netlist_frame.cpp"])
    execute([build / "obj_dir/Vsurface_contour_select", decoded, output] + (["--stalls"] if args.stalls else []))
    print(f"Output {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, nargs="?", default=ROOT / "images/PIC99.jpg")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--build", type=Path, default=ROOT / "build/netlist")
    parser.add_argument("--jobs", type=int, choices=range(1, 33), default=2, metavar="1..32")
    parser.add_argument("--legacy-pic2", action="store_true")
    parser.add_argument("--stalls", action="store_true")
    run(parser.parse_args())
