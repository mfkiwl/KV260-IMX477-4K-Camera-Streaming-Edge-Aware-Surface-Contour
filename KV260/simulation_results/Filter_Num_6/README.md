# Filter 5 — exposure-aware color at native camera geometry

`results/PIC1_filtered.bmp` is the supplied 2048 × 1152 reference. A fresh simulation using
the revised RTL reproduced every byte. `results/PIC4_filtered.bmp` and
`results/PIC5_filtered.bmp` are new full-resolution AXI captures. Open
`results/PIC4_PIC5_Color_Comparison.png` for the before-and-after view.

## Reproduce the three color checks

Run these commands from the extracted project directory with Questa, Python, NumPy and Pillow on PATH.

```cmd
vsim -c -do "do sim/run_questa.do images/PIC4.JPG results/PIC4_filtered.bmp"
vsim -c -do "do sim/run_questa.do images/PIC5.JPG results/PIC5_filtered.bmp"
vsim -c -do "do sim/run_questa.do images/PIC1.JPG build/PIC1_regression.bmp"
fc /b results\PIC1_filtered.bmp build\PIC1_regression.bmp
```

The Questa script recompiles the sources, injects stalls and checks every RGB
pixel against the updated independent model. The GHDL equivalents follow.

```sh
python sim/run_ghdl.py images/PIC4.JPG --aligned --stalls
python sim/run_ghdl.py images/PIC5.JPG --aligned --stalls
python sim/run_ghdl.py images/PIC1.JPG --aligned --stalls --output build/PIC1_regression.bmp --reference results/PIC1_filtered.bmp --exact
python tools/check_two_frames.py --aligned
```

## How the grade works

The aligned RGB888 path through `designer_filter_axis` measures the mean raw luma of the
first eight accepted input rows (all rows for a shorter image). These rows already
pass through the spatial filter before the first output window is ready. The RTL queues
the measurement until its filtered start-of-frame arrives, holds the mix for that frame,
and pipelines it with each pixel across ready/valid stalls.

- At a rounded mean of 64 or lower the mix is 0/32, selecting the original calibrated
  grade. From 64 to 96 the blend increases linearly. At 96 and above it is 32/32.
  The decision uses the pixel stream and needs no filename, image ID or frame store.
  The first rows are an exposure estimate. Letterboxing or unusual framing can influence it.
- `axis_designer1_grade` uses a monotone luma curve for the protected response.
  It suppresses the first three levels of channel difference, limits color extremes,
  and reduces chroma in shadows and highlights. Equal input channels give equal output
  channels at full protection. Red-dominant midtones retain warm browns and tans.
  Cyan-dominant cloth moves toward muted green. The final blend adds one enabled
  register stage. SOF, EOL and valid advance together.
- The three surface passes and the contour finish operate at the original sample
  positions. The native-camera-only and optional portrait profiles retain their
  previous color response.

| Frame | Measured mix | Full-frame verification |
|---|---:|---|
| PIC1 | 0/32 | Captured BMP matches the supplied reference byte for byte |
| PIC4 | 32/32 | All 2,359,296 captured RGB pixels match the independent model |
| PIC5 | 32/32 | All 2,359,296 captured RGB pixels match the independent model |

See `results/color_verification.txt` for hashes, stall counts, color metrics and RGB
samples from matching image regions. Other supplied captures are retained as received.

## Image orientation

PIC4 and PIC5 both encode **2048 × 1152** pixels. PIC4 has EXIF orientation 6 and
PIC5 has orientation 8. The old supplied BMPs were rotated for display.
The new `*_filtered.bmp` files are exactly what the testbench writes, in sensor
coordinates. The full-size `*_filtered_upright.png` files show the same pixels at
**1152 × 2048**, rotated clockwise for PIC4 and counterclockwise for PIC5.

## PIC3 geometry

Run `run.cmd` from Windows for the existing PIC3 simulation.


| PIC3 geometry | Uploaded capture | Corrected capture |
|---|---:|---:|
| Input raster | 2048 × 1152 | 2048 × 1152 |
| Output raster | 2048 × 1365 | **2048 × 1152** |
| Output aspect ratio | 1.5004 | **16:9** |
| Output height / input height | 1.1849 | **1.0000** |
| Camera columns represented | 70–1946 | **0–2047** |
| Accepted output pixels | 2,795,520 | **2,359,296** |

## What changed in the RTL

The old Designer1 portrait framing used different sampling steps across the image. For example, it stretched the interval between source rows 1110 and 1151 across output rows 1245 through 1364. Keeping only 1152 lines of that output would still leave cropped columns and displaced features.

The new `G_PORTRAIT_FRAMING` generic defaults to `false` in `designer_filter_axis`. In this mode, `axis_designer_view` forwards each accepted RGB888 pixel, TUSER and TLAST directly to the next stage, and carries TREADY back upstream. The contour finish and BMP writer both use the source dimensions. `pic2_filter_axis`, `axis_designer1_grade` and `axis_designer1_finish` still perform edge-aware smoothing, fixed-point color grading and contour enhancement. The full-raster path introduces no resampling.

| Mode | Source geometry | Use |
|---|---|---|
| Filter 5, pixel aligned | Full input raster | Current PIC3 capture. Set `G_PORTRAIT_FRAMING=false` with `G_LARGE_VIEW=true` and `G_DESIGNER1=true`. |
| Filter 5, Designer1 portrait | 2048 × 1152 input to 2048 × 1365 | Reproduce the earlier PIC1 / Designer1 reference composition. Set `G_PORTRAIT_FRAMING=true`. |
| Camera filter only | Full input raster | Use the GHDL launcher's existing `--native` switch to capture the output before Designer1 grading and finishing. |

## Reproduce PIC3

Run the commands below from the extracted `Filter_Num_5` directory. The VHDL testbench decodes the JPEG, applies input gaps and output backpressure when requested, and writes each accepted output pixel to a top-down 24-bit BMP. The Python regression independently calculates the expected RGB value at each source coordinate.

**Questa on Windows**

```cmd
python -m pip install numpy Pillow
run.cmd
```

The default script compares the result against the pixel-aligned filter model. To apply the same processing to another JPEG, use the Tcl script with explicit paths, for example `vsim -c -do "do sim/run_questa.do images/PIC2.JPG build/PIC2_aligned.bmp"`.

**GHDL**

```sh
python sim/run_ghdl.py images/PIC3.JPG --aligned --stalls
```

**NVC** was used for the delivered output. Create the `build` directory first if invoking NVC directly.

```sh
nvc --std=2008 --ieee-warnings=off-at-0 -H 768m -a -f sim/sources.txt -e -gG_STALLS=true -gG_DECODED_BMP=build/PIC3_decoded.bmp tb_pic2 -r --exit-severity=error
python tools/check_pixels.py build/PIC3_decoded.bmp results/PIC3_filtered.bmp --designer1 --jpeg images/PIC3.JPG
```

## Geometry and archived portrait modes

The testbench checks SOF placement, EOL on every row, pixel count and output stability
under backpressure. The independent model checks RGB at each source coordinate.
The coordinate-stream test is available in `tb/tb_designer_view.vhd`.

The optional `--portrait` mode produces the historical 2048 × 1365 composition described
in `document/Designer1_portrait_README.md`. Use `--aligned` for the PIC1 reference
shipped in this ZIP.
