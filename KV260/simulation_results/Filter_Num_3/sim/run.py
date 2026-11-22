"""Run the VHDL JPEG-to-BMP bench and check every output pixel in raster order."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

from PIL import Image

from compare import report

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sim", choices=("nvc", "ghdl"), default="ghdl")
    parser.add_argument("--profile", type=int, choices=(2, 3), default=3)
    parser.add_argument("--input", type=Path, default=ROOT/"images/PIC1.JPG", help="JPEG path or bundled image stem")
    parser.add_argument("--output", type=Path, help="optional BMP output path")
    parser.add_argument("--continuous", action="store_true", help="disable source gaps and sink stalls")
    parser.add_argument("--native", action="store_true", help="capture the camera filter alone at the JPEG dimensions")
    parser.add_argument("--dump-input", action="store_true", help="also save the JPEG decoder output BMP")
    args = parser.parse_args()
    if args.native and args.profile != 3:
        parser.error("--native uses the camera raster; omit --profile 2")
    jpeg = args.input
    if not jpeg.suffix and jpeg.parent == Path("."):
        jpeg = ROOT / "images" / (jpeg.name + ".JPG")
    jpeg = jpeg.resolve()
    if not jpeg.is_file():
        parser.error(f"Input JPEG does not exist: {jpeg}")
    with Image.open(jpeg) as image:
        width, height = image.size
    if args.profile == 2 and (width, height) != (2048, 1152):
        parser.error("Profile 2 artwork framing requires a 2048 x 1152 input")
    stem = jpeg.stem
    mode = "native" if args.native else f"profile{args.profile}"
    tag = f"{stem}_{mode}" + ("_continuous" if args.continuous else "")
    simulator = shutil.which(os.environ.get(args.sim.upper(), args.sim))
    if not simulator:
        parser.error(f"Put {args.sim} on PATH or set {args.sim.upper()} to its executable")
    build = ROOT / "build" / f"{args.sim}_{tag}"
    build.mkdir(parents=True, exist_ok=True)
    results = ROOT / "results"
    results.mkdir(exist_ok=True)
    suffix = "_native_baseline" if args.native else ("_filtered" if args.profile == 3 else "_filtered_Designer2")
    output = args.output.resolve() if args.output else results / f"{stem}{suffix}.bmp"
    output.parent.mkdir(parents=True, exist_ok=True)
    decoded = (results if args.dump_input else build) / f"{stem}_decoded.bmp"
    source_files = [ROOT / line for line in (ROOT / "sim/sources.txt").read_text().splitlines() if line]
    generics = [f"-gG_PROFILE={args.profile}", f"-gG_STALLS={str(not args.continuous).lower()}",
                f"-gG_INPUT={jpeg}", f"-gG_OUTPUT={output}", f"-gG_DECODED_BMP={decoded}"]
    generics.extend([f"-gG_WIDTH={width}", f"-gG_HEIGHT={height}",
                     f"-gG_DESIGNER_VIEW={str(not args.native).lower()}"])
    if args.sim == "nvc":
        commands = [[simulator, "--std=2008", "--ieee-warnings=off-at-0", "-H", "768m",
                     "-a", *source_files, "-e", *generics, "tb_pic2", "-r", "--exit-severity=error"]]
    else:
        commands = [[simulator, "-a", "--std=08", *source_files],
                    [simulator, "-e", "--std=08", "tb_pic2"],
                    [simulator, "-r", "--std=08", "tb_pic2", *generics, "--assert-level=error"]]
    logfile = results / f"{tag}_simulation.log"
    with logfile.open("w", encoding="utf-8") as stream:
        for command in commands:
            completed = subprocess.run(command, cwd=build, stdout=stream, stderr=subprocess.STDOUT)
            if completed.returncode:
                stream.flush()
                raise SystemExit(logfile.read_text(errors="replace")[-4500:] + f"\nSee {logfile}")
    log = logfile.read_text(errors="replace")
    if "AXI capture PASS" not in log:
        raise SystemExit(f"The VHDL sink did not report a complete frame. See {logfile}")
    print(log.strip(), flush=True)
    if args.native:
        check = [ROOT/"tools/check_pixels.py", decoded, output, "--jpeg", jpeg]
    else:
        check = [ROOT/"tools/check_designer.py", "--profile", str(args.profile),
                 "--decoded", decoded, "--actual", output]
    bundled_pic1 = jpeg == (ROOT / "images/PIC1.JPG").resolve()
    if bundled_pic1 and not args.native and args.profile == 3:
        check.extend(["--golden", ROOT / "reference/PIC1_filtered.bmp"])
    result = subprocess.run([sys.executable, *check], cwd=ROOT, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    (results / f"{tag}_pixel_check.log").write_text(result.stdout, encoding="utf-8")
    print(result.stdout, end="")
    if result.returncode:
        raise SystemExit(result.returncode)
    if bundled_pic1:
        report(output, ROOT / "images" / f"Designer{args.profile}.jpg")


if __name__ == "__main__":
    main()
