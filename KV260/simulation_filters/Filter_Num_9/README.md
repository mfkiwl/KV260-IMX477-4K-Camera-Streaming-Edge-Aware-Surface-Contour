# Filter 5 — pixel-aligned camera geometry

Run `run.cmd` from Windows to filter `images/PIC3.JPG` and produce `results/PIC3_filtered.bmp`. The default path keeps the Designer1 color grade and contour finish. Each filtered sample is centered on its original camera position.

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

**NVC** was used for the delivered output. The project already contains a `build` directory.

```sh
nvc --std=2008 --ieee-warnings=off-at-0 -H 768m -a -f sim/sources.txt -e -gG_STALLS=true -gG_DECODED_BMP=build/PIC3_decoded.bmp tb_pic2 -r --exit-severity=error
python tools/check_pixels.py build/PIC3_decoded.bmp results/PIC3_filtered.bmp --designer1 --jpeg images/PIC3.JPG
```

## Verification

- `results/PIC3_aligned_stalled.log` and `results/PIC3_aligned_continuous.log` record the full-frame RTL runs. The testbench checks SOF at the first pixel, EOL at the last pixel of every line, pixel count and held data/markers under backpressure.
- `results/PIC3_coordinate_test.log` records the two-frame coordinate-coded test. Every transmitted coordinate is unique across the two frames. Rerun it after analyzing the project sources with `nvc --std=2008 -a tb/tb_designer_view.vhd -e tb_designer_view -r --exit-severity=error`.
- `results/PIC3_geometry_check.txt` records the independent model result and the hash comparison between stream timing patterns. The model operates on the exact input samples from the JPEG decoder in camera coordinates.

## Retained portrait captures

The supplied `results/PIC1_filtered.bmp` and `results/PIC2_filtered.bmp` are earlier portrait-mode captures. To recreate the supplied PIC1 output in a separate path, run the following command.

```sh
python sim/run_ghdl.py images/PIC1.JPG --portrait --stalls --output build/PIC1_portrait.bmp
```

The matching artwork is `reference/Designer1.jpg`. Its historical similarity measurements and architecture details are in `document/Designer1_portrait_README.md`.
