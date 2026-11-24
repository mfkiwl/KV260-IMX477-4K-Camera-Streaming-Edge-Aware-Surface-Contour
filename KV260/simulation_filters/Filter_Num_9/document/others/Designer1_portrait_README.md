# Archived PIC1 portrait revision

The following text describes the delivery before the full-raster PIC3 correction. Use the current project README for file paths, default framing and launch commands.

# PIC1 to Designer1 portrait filter

The default VHDL-2008 testbench streams `images/PIC1.JPG` through `designer_filter_axis` and captures `results/PIC1_filtered.bmp` directly from accepted AXI4-Stream output transfers. The original camera frame is 2048 × 1152. The RTL produces the 2048 × 1365 framing of `images/Designer1.jpg`. The reference JPEG is used for offline calibration and the post-simulation comparison. All output pixels are computed from the camera stream using line buffers and fixed-point arithmetic.

## Result on the supplied portrait

| Capture compared with Designer1.jpg | Mean absolute RGB error, 0–255 | RGB PSNR | Luminance SSIM |
|---|---:|---:|---:|
| Previous 2048 × 1365 RTL | 32.837650 | 16.105774 dB | 0.809983 |
| Designer1 RTL | **9.212275** | **22.818121 dB** | **0.880347** |

Both captures were compared at their native coordinates. The calculation covers all 2,795,520 pixels with no post-capture crop, warp, or color adjustment. SSIM uses BT.709 luma, an 11 × 11 Gaussian window with σ = 1.5, population moments, and valid window centers. The earlier capture is included as `results/PIC1_filtered_Designer_previous.bmp`.

The framing, blue-green shadows, warm facial shading and olive jacket follow the reference. The photographic eyelids and brow have softer edges. The illustration also draws individual hair strands and collar marks differently. Exactly 2,375 output pixels have the same RGB triplet as the JPEG. The coefficients and framing were calibrated on this portrait. Open `results/Designer1_comparison.png` for the full frames and native-scale eye and collar details.

## RTL signal path

| AXI4-Stream stage | Operation |
|---|---|
| `pic2_filter_axis` | Three edge-aware surface passes at tap spacings 1, 3 and 6 smooth the camera frame. The existing tone/contour and color-limited finishing stages supply the native RGB888 stream. |
| `axis_designer_view` | Horizontal and vertical integer phase accumulators select source pixel centers. The output columns 0, 700 and 2047 sample camera columns 70, 736 and 1946. Output rows 0, 1245 and 1364 sample camera rows 0, 1110 and 1151. Each interval uses nearest-center rounding. A one-row RAM supports repeated output rows. |
| `axis_designer1_grade` | A scalar exposure curve operates on luma. A fixed-point matrix applies continuous corrections from the incoming R−G and G−B differences and their products with shadow and highlight weights. Extreme exposure or chroma fades the correction back toward incoming RGB. This grade uses no RGB palette or K-means. |
| `axis_designer1_finish` | A 5 × 5 window with three-pixel tap spacing spans 13 × 13 output pixels. Eight inner neighbors contribute to smoothing according to maximum channel distance. Four opposing outer pairs identify the strongest transition and narrow dark ridges. The output darkens or lightens the transition within fixed bounds. |
| `designer_filter_axis` | Portrait top. Both interfaces are RGB888 with R at bits 23–16, G at 15–8 and B at 7–0. TUSER marks start of frame and TLAST marks end of line. A transfer occurs on a rising edge with TVALID and TREADY high. |

The portrait top uses `G_LARGE_VIEW=true` and `G_DESIGNER1=true` by default. The `surface_contour_select` entity is the separate, native-raster RGB10 camera path. The reported metrics and stream checks apply to the RGB888 portrait top. FPGA placement, timing closure and board output are outside the simulation evidence for this revision.

## Reproduce the capture

Run from the extracted `pic2_axis` directory. Python comparisons require NumPy and Pillow.

**Questa on Windows**

```cmd
python -m pip install numpy Pillow
vsim -c -do sim/run_questa.do
```

**NVC**, used for the delivered capture

```sh
nvc --std=2008 --ieee-warnings=off-at-0 -H 768m -a -f sim/sources.txt -e -gG_STALLS=true tb_pic2 -r --exit-severity=error
python sim/compare_style.py --baseline results/PIC1_filtered_Designer_previous.bmp
python tools/check_designer1_datapath.py
```

**GHDL**

```sh
python sim/run_ghdl.py --stalls
```

The default comparison reports similarity measurements and fails on invalid or mismatched rasters. To require exact equality of decoded RGB pixels, run `python sim/compare_rgb.py` or use `--exact` with the GHDL launcher. Exact equality with the artwork fails for this capture.

## Simulation checks

| Check | Observed result |
|---|---|
| NVC 1.23.1, continuous stream | 2,359,296 input pixels, 2,795,520 output pixels, 1 SOF, 1,365 EOL markers |
| Input gaps and output backpressure | Same frame counts. Data and markers stayed stable across 1,180,769 stalled output cycles. The BMP is byte-identical to the continuous capture. |
| Pixel arithmetic | A separate integer model used the native-filter simulation result as input. It agreed with the portrait RTL for all 2,795,520 output pixels. |
| Two frames through the framing stage | Two distinct coordinate-coded frames verified pixel selection, horizontal and vertical repeats, frame restart and marker alignment under backpressure. |
| Final BMP SHA-256 | `4ebabd9f896c31b75b10255dc781a8234670f1dc6179bf10de16cdd7e4d302d4` |

The simulator logs and numerical reports are in `results/Designer1_*.log` and `results/Designer1_similarity.txt`. To regenerate the native frame for the independent model, run `python sim/run_ghdl.py --native --output results/PIC1_native.bmp`.

## Earlier profiles

`--portrait-previous` selects the earlier 2048 × 1365 Designer profile in the GHDL launcher. `--portrait-1536` selects the earlier 1536 × 1024 profile. Give each its own `--output` path when retaining the current capture. The rationale and historical results for those profiles are in `document/Designer_previous_README.md`. The native camera filter design is documented in `document/PIC2_native_README.md`.
