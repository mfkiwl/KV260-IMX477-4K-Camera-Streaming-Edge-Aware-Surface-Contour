"""Check the frame color decision, grayscale fidelity and back-to-back AXI stalls."""
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory)
        y, x = np.indices((27, 43))
        value = 20 + (x + 2*y) % 36
        dim = np.stack((value + 8, value + 10, value), axis=-1)
        Image.fromarray(dim.astype(np.uint8)).save(path / "dim.jpg", quality=100, subsampling=0)
        ramp = (255*x // (x.shape[1]-1)).astype(np.uint8)
        Image.fromarray(ramp).save(path / "ramp.jpg", quality=100)
        driver = [sys.executable, str(ROOT / "sim/run_ghdl.py")]

        def capture(name, output, *options):
            subprocess.run(driver + [f"{name}.jpg", "--aligned", "--build", "build",
                                     "--output", str(output), *options], cwd=path, check=True)

        capture("dim", "portrait.bmp", "--color-profile", "designer1")
        capture("ramp", "neutral.bmp", "--color-profile", "source")
        for first, second in (("dim", "ramp"), ("ramp", "dim")):
            capture(first, f"{first}_auto.bmp", "--stalls", "--second-jpeg", f"{second}.jpg",
                    "--second-output", f"{second}_next.bmp")
            for name, suffix in ((first, "auto"), (second, "next")):
                expected = "portrait" if name == "dim" else "neutral"
                if (path / f"{name}_{suffix}.bmp").read_bytes() != (path / f"{expected}.bmp").read_bytes():
                    raise SystemExit(f"Frame profile mismatch for {name} in {first} to {second}")

        neutral = np.asarray(Image.open(path / "neutral.bmp"))
        if not np.all(neutral == neutral[..., :1]):
            raise SystemExit("A neutral ramp acquired unequal RGB channels")
        print("PASS: both profile transitions matched their forced references under stalls.")
        print(f"PASS: all {ramp.size} grayscale output pixels have R=G=B.")


if __name__ == "__main__":
    main()
