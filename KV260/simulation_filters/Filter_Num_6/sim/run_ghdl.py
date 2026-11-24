"""Compile the VHDL-2008 project and run its JPEG-to-BMP testbench. The appearance check uses NumPy and Pillow."""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def jpeg_dimensions(path):
    # Read only the SOF0 dimensions to configure the hardware generics.
    # Entropy decoding, color conversion and pixel stimulus are done in VHDL.
    with path.open("rb") as stream:
        if stream.read(2) != b"\xff\xd8":
            raise ValueError(f"{path} is not a JPEG")
        while stream.read(1) == b"\xff":
            mark = stream.read(1)
            while mark == b"\xff":
                mark = stream.read(1)
            if mark in (b"", b"\xda", b"\xd9"):
                break
            length = int.from_bytes(stream.read(2), "big")
            if length < 2:
                break
            if mark == b"\xc0":
                header = stream.read(5)
                if len(header) == 5 and header[0] == 8:
                    return int.from_bytes(header[3:5], "big"), int.from_bytes(header[1:3], "big")
                break
            stream.seek(length - 2, 1)
    raise ValueError(f"{path} needs an 8-bit baseline JPEG (SOF0)")


def run(source, output, build, decoded=None, stalls=False, second=None, second_output=None,
        profile=None, reference=None, exact=False):
    ghdl = shutil.which(os.environ.get("GHDL", "ghdl"))
    if not ghdl:
        raise SystemExit("GHDL is required. Put ghdl on PATH or set GHDL to its executable.")
    source, build = source.resolve(), build.resolve()
    output = (output or ROOT / "results" / f"{source.stem}_filtered.bmp").resolve()
    width, height = jpeg_dimensions(source)
    supplied_pic1 = source == (ROOT / "images/PIC1.JPG").resolve()
    supported_size = (width, height) == (2048, 1152)
    portrait = profile in ("portrait", "portrait-previous", "portrait-1536")
    styled = portrait or profile == "aligned" or (profile is None and supported_size)
    large_view = profile != "portrait-1536"
    designer1 = large_view and profile != "portrait-previous"
    if portrait and not supported_size:
        raise ValueError("The portrait profile requires 2048 x 1152 input")
    if reference is None and portrait and supplied_pic1:
        if designer1:
            reference = ROOT / "reference/Designer1.jpg"
        elif not large_view:
            reference = ROOT / "reference/Designer.jpg"
    args = [f"-gG_DESIGNER1={str(designer1).lower()}", f"-gG_LARGE_VIEW={str(large_view).lower()}", f"-gG_DESIGNER_VIEW={str(styled).lower()}", f"-gG_PORTRAIT_FRAMING={str(portrait).lower()}", f"-gG_INPUT={source}", f"-gG_WIDTH={width}", f"-gG_HEIGHT={height}",
            f"-gG_OUTPUT={output}", f"-gG_STALLS={str(stalls).lower()}"]
    destinations = [output]
    inputs = [source]
    if reference:
        reference = reference.resolve()
        inputs.append(reference)
    check_aligned = styled and not portrait
    if check_aligned and decoded is None:
        decoded = build / f"{source.stem}_decoded.bmp"
    if decoded:
        decoded = decoded.resolve()
        destinations.append(decoded)
        args.append(f"-gG_DECODED_BMP={decoded}")
    if second:
        second = second.resolve()
        inputs.append(second)
        if jpeg_dimensions(second) != (width, height):
            raise ValueError("Back-to-back JPEGs must have the same dimensions")
        second_output = (second_output or output.with_name(output.stem + "_frame2.bmp")).resolve()
        destinations.append(second_output)
        args += [f"-gG_SECOND_JPEG={second}", f"-gG_SECOND_OUTPUT={second_output}"]
    if set(inputs).intersection(destinations) or len(destinations) != len(set(destinations)):
        raise ValueError("Each BMP needs its own path, separate from source and reference images")
    build.mkdir(parents=True, exist_ok=True)
    for dest in destinations:
        dest.parent.mkdir(parents=True, exist_ok=True)
    files = (ROOT / "sim/sources.txt").read_text().splitlines()
    subprocess.run([ghdl, "-a", "--std=08", *[str(ROOT / f) for f in files if f]], cwd=build, check=True)
    subprocess.run([ghdl, "-e", "--std=08", "tb_pic2"], cwd=build, check=True)
    subprocess.run([ghdl, "-r", "--std=08", "tb_pic2", *args, "--assert-level=error"], cwd=build, check=True)
    print(f"RTL output: {output}", flush=True)
    if check_aligned:
        subprocess.run([sys.executable, str(ROOT / "tools/check_pixels.py"), str(decoded), str(output),
                        "--designer1", "--jpeg", str(source)], check=True)
    if reference:
        script = "compare_rgb.py" if exact or not (styled and designer1) else "compare_style.py"
        check = subprocess.run([sys.executable, str(ROOT / "sim" / script), str(output), str(reference)])
        if check.returncode:
            raise SystemExit(check.returncode)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, nargs="?", default=ROOT / "images/PIC3.JPG")
    parser.add_argument("--output", type=Path, help="default: results/<input stem>_filtered.bmp")
    parser.add_argument("--build", type=Path, default=ROOT / "build/ghdl")
    parser.add_argument("--decoded-bmp", type=Path, help="also dump the unfiltered JPEG decoder output")
    parser.add_argument("--stalls", action="store_true", help="insert pseudo-random source gaps and output backpressure")
    parser.add_argument("--second-jpeg", type=Path, help="stream another frame without reset")
    parser.add_argument("--second-output", type=Path)
    profiles = parser.add_mutually_exclusive_group()
    profiles.add_argument("--aligned", action="store_const", dest="profile", const="aligned",
                          help="apply Filter 5 colour and contours at the source geometry")
    profiles.add_argument("--native", action="store_const", dest="profile", const="native",
                          help="use the original, same-size camera filter")
    profiles.add_argument("--portrait", action="store_const", dest="profile", const="portrait",
                          help="apply the 2048 x 1365 Designer portrait profile")
    profiles.add_argument("--portrait-1536", action="store_const", dest="profile", const="portrait-1536",
                          help="apply the earlier 1536 x 1024 Designer portrait profile")
    profiles.add_argument("--portrait-previous", action="store_const", dest="profile", const="portrait-previous",
                          help="use the earlier 2048 x 1365 Designer grade and exact comparator")
    parser.add_argument("--reference", type=Path, help="compare the first output with this independent reference")
    parser.add_argument("--exact", action="store_true", help="require identical decoded RGB pixels")
    opts = parser.parse_args()
    run(opts.input, opts.output, opts.build, opts.decoded_bmp, opts.stalls, opts.second_jpeg, opts.second_output,
        opts.profile, opts.reference, opts.exact)
