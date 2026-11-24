# RGB filter correction for PIC10, PIC11 and the color charts

The corrected AXI4-Stream captures are in `results/PIC10.bmp`, `PIC11.bmp`, `PIC99.bmp` and `PIC82.bmp`. Each contains 2048 × 1152 RGB pixels from the same hardware profile. The second supplied chart is labelled PIC82 in both its JPEG and reference PNG. A separate PIC98 pair was unavailable.

## Reference results

| Image | Original RGB MAE | Corrected RGB MAE | Corrected RGB PSNR | Corrected luma SSIM |
|---|---:|---:|---:|---:|
| PIC10 | 16.042 | 2.352 | 36.00 dB | 0.96305 |
| PIC11 | 19.996 | 2.796 | 34.56 dB | 0.95518 |
| PIC99 | 39.138 | 2.939 | 32.36 dB | 0.96893 |
| PIC82 | 40.982 | 2.163 | 34.36 dB | 0.98759 |

The comparisons use each complete BMP and its corresponding 1280 × 720 reference. The evaluator reduces the BMP once with Pillow Lanczos, then measures eight-bit RGB samples at corresponding coordinates. There is no crop or registration. MAE is the mean absolute error per channel, in levels out of 255. PSNR uses the RGB mean squared error. SSIM uses luma and an 11 × 11 Gaussian window. All four PNG references are approximate matches. In PIC99, 89.05% of corresponding pixels are within ten levels in all three channels and 12,948 of 921,600 agree exactly. Fine facial texture and some narrow chart boundaries still differ.

On PIC99, source pixels within ten levels of white have a median corrected RGB of (243, 213, 135), compared with (245, 214, 136) in the reference. Source pixels within ten levels of green have a corrected median of (0, 202, 90), compared with (0, 205, 93). The greatest difference among the five measured region medians is in the green channel of the red region. Its corrected median is (255, 20, 65) and its reference median is (255, 6, 64). See `results/PIC99_color_regions.csv` for all regions and sample counts.

`results/reference_metrics.csv` records per-channel errors, exact RGB pixel counts and the legacy PIC2 result. The original PIC10, PIC11 and PIC99 BMPs in `results/baseline/` are the submitted files. The PIC82 baseline was simulated with the archived RTL and the supplied PIC82 JPEG.

## Run on Windows with Questa

Extract the entire ZIP. Open CMD in the folder containing `run.cmd`. Each command decodes the specified JPEG in the VHDL testbench, drives the 32-bit RGB10 wrapper with source gaps and output backpressure, then writes the corresponding BMP under `results`.

```cmd
run.cmd PIC99
run.cmd PIC10
run.cmd PIC11
run.cmd PIC82
```

`run.cmd` alone selects PIC99. A path to another 8-bit baseline JPEG can be supplied as the first argument. The script reads the dimensions from the JPEG header. A successful run reports the accepted pixel and EOL counts and checks the VHDL testbench completion flag. The direct VHDL and synthesized-netlist executions recorded in this package used the open-source simulators listed in `results/verification.txt`.

## Run with GHDL

From the same folder, run the following commands. The GHDL launcher uses Python 3. The image checkers additionally require NumPy and Pillow.

```sh
python sim/run_ghdl.py images/PIC99.jpg --wrapper --stalls --decoded-bmp results/PIC99_decoded.bmp
python tools/check_pixels.py results/PIC99_decoded.bmp results/PIC99.bmp --jpeg images/PIC99.jpg
python tools/compare_reference.py results/baseline/PIC99.bmp results/PIC99.bmp --reference images/PIC99_reference.PNG
python tools/check_two_frames.py
```

The first command writes `results/PIC99.bmp`. Replace the JPEG filename to select another input. `--output` selects a specific destination. The VHDL testbench checks stall stability, SOF and EOL positions, RGB10 padding, pixel count and completion. The independent integer checker reconstructs the spatial filter, fixed-point arithmetic, border handling and final RGB output. It compares all 2,359,296 native-size output pixels. The delivered PIC99 BMP comes from GHDL. With identical decoded RGB input, both direct VHDL simulation and the synthesized netlist produce the same BMP. GHDL and NVC rounded five input pixels differently in the original testbench JPEG decoder. The resulting filtered images differ by at most one level on 23 pixels.

For the synthesized-netlist path on a host with GHDL, Verilator, Make and a C++ compiler, run the command below. The helper elaborates the same RTL, decodes the source with the VHDL JPEG reader, synthesizes the wrapper to Verilog and captures its AXI4-Stream output. It writes the decoded input into the build folder.

```sh
python sim/run_netlist.py images/PIC99.jpg --output results/PIC99_netlist.bmp --stalls
```

## RTL change

The original `axis_tone_contour` reduced the correction strength as luma approached 224 or either color difference approached 96. Highlights and saturated colors consequently passed through close to the source, even in regions where the reference calls for a large correction.

The default profile now applies a signed, fixed-point correction across the full input range. All image inputs share the same coefficients. Hardware inputs are the center RGB and twelve neighborhood measurements. These comprise luma, R−G, G−B, broad luma residual, broad mean absolute luma deviation, two broad color-difference residuals, inner luma detail, dark and light ridge responses, fine luma span and outer-ring luma residual.

| RTL | Function |
|---|---|
| `axis_surface_pass` and `axis_surround` | Smooth the input at two scales and compute a broad local color and contrast estimate from the incoming stream. |
| `axis_tone_contour` | Align the center and its broad estimate with the fine window and calculate the twelve measurements. |
| `axis_full_grade`, `grade_affine` and `full_grade_coeffs` | Evaluate two sparse layers of 64 and 32 rectified affine forms and a direct RGB correction. Registered products and adder trees use compile-time coefficients. Each rectifier rounds at ten fractional bits and saturates to 0–4095. The output adds the signed correction to the center, rounds and clips to RGB888. |
| `axis_contour_finish` | Smooth along local contours before the wrapper packs the filtered RGB10 output. |

The coefficients were calibrated offline on spatial training blocks from PIC10, PIC11, PIC82, PIC99 and the project’s PIC9 pair. The table reports full-frame agreement on the supplied references. The hardware evaluates arithmetic for every pixel. It has no color palette, centroid assignment, frame identifier, pixel coordinates in the grade, reference-image input or reference frame ROM. The compile-time coefficients are contained in VHDL. Every valid, data, SOF and EOL register in the new grade advances with the same stall enable.

## Original PIC1-to-PIC2 result

Set the top-level boolean generic `G_LEGACY_PIC2` to `true` to synthesize the original PIC2 portrait response. The default is `false`, which selects the corrected profile in the table. Only the selected color stage is elaborated. In the supplied reconstruction archive, `images/PIC2.JPG` is byte-identical to the original project's `images/PIC1.JPG`. Both filenames are included for reproducibility.

```cmd
run.cmd PIC1 legacy
```

```sh
python sim/run_ghdl.py images/PIC1.JPG --wrapper --stalls --legacy-pic2
```

The legacy rerun produced `results/PIC1_filtered.bmp`. Its SHA-256 matches the earlier PIC1-to-PIC2 project output. Mean RGB error against `PIC2_reference.png` is 2.112 levels, with 36.37 dB RGB PSNR.

## Synthesis and integration

Use the `rtl/` entries from `sim/sources.txt` in order and select VHDL-2008. The board top is `surface_contour_select`. Its default maximum raster is 2048 × 1152. The 4K elaboration uses `G_MAX_WIDTH=3840` and `G_MAX_HEIGHT=2160`. The 32-bit stream carries R10 in bits 29–20, G10 in 19–10 and B10 in 9–0. The core uses the upper eight bits of each lane and clears the two low bits of filtered outputs. `TUSER` marks the first pixel and `TLAST` marks the last pixel of each line. The 24-bit core can be instantiated directly as `pic2_filter_axis`.

GHDL synthesized the default and 4K configurations. It inferred line memories and the context FIFO and reported that it ignores the vendor-specific RAM placement attributes. Target-device utilization, routed timing and on-board frame rate for this revision are unmeasured.
