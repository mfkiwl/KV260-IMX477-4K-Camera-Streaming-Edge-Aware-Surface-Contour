# Earlier Designer revision

The following text documents the previous release. Its 2048 × 1365 BMP is now stored as `results/PIC1_filtered_Designer_previous.bmp`. The top-level README describes the current defaults.

# PIC1 to Designer portrait RTL

**The exact RGB comparison fails for both supplied references.** The default run streams all 2,359,296 pixels decoded from `images/PIC1.JPG` through the RTL. It writes `results/PIC1_filtered.bmp` at 2048 × 1365, the native size of the most recent upload, `Designer(1).jpg`. The project stores those exact uploaded JPEG bytes under the requested verification path `images/Designer.jpg`. The archive's original 1536 × 1024 JPEG remains at `results/Designer.jpg`.

| Reference upload | Captured RTL output | Identical RGB pixels | Mean absolute channel error | Maximum channel error | RGB PSNR |
|---|---|---:|---:|---:|---:|
| Designer(1).jpg, 2048 × 1365 | `results/PIC1_filtered.bmp` | 4,159 / 2,795,520 | 10.666430 / 255 | 232 / 255 | 21.3746 dB |
| Designer.jpg, 1536 × 1024 | `results/PIC1_filtered_1536.bmp` | 1,852 / 1,572,864 | 9.301672 / 255 | 221 / 255 | 22.7908 dB |

Open `results/Designer_comparison.png` for aligned views and a native-scale eye detail. The exact comparisons, first differing pixel and decoded RGB hashes are in `results/Designer_exact_rgb.log` and `results/Designer_1536_exact_rgb.log`. The VHDL simulator output and BMP hashes are in `results/Designer_simulation.log`.

The earlier 1536 × 1024 JPEG's embedded C2PA claims identify Azure OpenAI ImageGen and Microsoft watermarking. The newer JPEG supplies a higher-resolution rendering of the scene. The files provide comparison targets. The original rendering state and exact post-processing needed to regenerate their pixels from the photograph are unavailable in the project.

## RTL path

| Stage | Operation |
|---|---|
| `pic2_filter_axis` | Processes all 2048 × 1152 input pixels with the project's three edge-aware surface passes, tone and contour stages, and edge-limited finishing filter. |
| `axis_designer_view` | Samples camera columns 105 through 1946 and rows 1 through 1151. In the 2048-wide profile, output row 1195 samples source row 1066. In the 1536-wide profile, output row 896 samples that row. The remaining camera rows fill the lower portrait. Integer phase accumulators select nearest source centres. The unit accepts each source beat once, holds pixels for horizontal repeats, and uses a single RGB line buffer for repeated rows. |
| `axis_designer_grade` | Applies a scalar brightness curve and a partial eight-code luminance step. Fixed-point arithmetic reconstructs RGB from brightness, R−G, B−G and bounded changes of colour gain. |
| `designer_filter_axis` | Connects the three stages. Both interfaces use RGB888, TVALID/TREADY, TUSER for SOF and TLAST for EOL. `G_LARGE_VIEW=true` selects 2048 × 1365. Setting it to false selects 1536 × 1024. |

The framing and arithmetic coefficients were calibrated on the supplied pair of references. The sole image input to the hardware is the camera RGB stream. The scalar brightness ROM has 256 single-byte entries. The design uses neither palette mapping nor K-means. The native-size RGB10 camera integration continues to use `surface_contour_select`.

## Run the comparison

Run these commands from the extracted `pic2_axis` directory. The VHDL testbench decodes the source JPEG, checks the AXI stream and writes the BMP. The post-simulation check uses Python 3 and Pillow to decode the reference independently.

**Questa on Windows**

```cmd
python -m pip install Pillow
vsim -c -do sim/run_questa.do
```

**GHDL**

```sh
python sim/run_ghdl.py --stalls
```

Both launchers return exit status 1 for a size difference or any unequal RGB channel. The current captures complete successfully and the exact checks return 1. To compare an existing BMP without running the simulator again, use `python sim/compare_rgb.py`. It compares the complete native rasters in top-to-bottom row order.

**NVC**, used for the full-frame runs

```sh
nvc --std=2008 --ieee-warnings=off-at-0 -H 768m -a -f sim/sources.txt -e -gG_STALLS=true tb_pic2 -r --exit-severity=error
python sim/compare_rgb.py
```

To reproduce the earlier 1536 × 1024 result with GHDL, run the following command. It selects the smaller profile and its matching reference.

```sh
python sim/run_ghdl.py --portrait-1536 --stalls --output results/PIC1_filtered_1536.bmp
```

The GHDL launcher defaults to the current portrait profile for the supplied PIC1 and supports other baseline JPEGs with the native filter. Use `--portrait` to apply the current profile to another 2048 × 1152 frame and `--reference` to supply an explicit independent reference for that run.

## Verification results

| Check | Observation |
|---|---|
| Original native-size output | A fresh NVC simulation produced a 2048 × 1152 BMP byte-identical to the project's supplied output. The included native result is `results/PIC1_native.bmp`. |
| Default portrait stream | 2,795,520 output transfers, 1,365 EOL markers and one SOF. Data and sidebands held stable over 1,180,310 stalled output cycles. |
| Continuous versus stalled | The complete BMP file was byte-identical across both runs for each output size. |
| Independent arithmetic check | For both profiles, every RTL output pixel matched the direct coordinate and fixed-point model driven by the native filter result. |
| Two-frame geometry test | Two distinct coordinate-coded frames checked repeated columns, repeated rows, SOF, EOL, backpressure and frame restart for both portrait sizes. |
| HDL synthesis front end | GHDL 5.0.1 produced a Verilog netlist for the complete default portrait top. It inferred a 2048 × 24 line RAM and a 256 × 8 scalar brightness ROM in the added stages. |

To rerun the arithmetic check, install NumPy and Pillow and run the following commands. The first command is optional when using the included native result.

```sh
python sim/run_ghdl.py --native --output results/PIC1_native.bmp
python tools/check_designer_datapath.py results/PIC1_native.bmp results/PIC1_filtered.bmp
python tools/check_designer_datapath.py results/PIC1_native.bmp results/PIC1_filtered_1536.bmp
```

The standalone two-frame geometry test is in `tb/tb_designer_view.vhd`. Analyse it after `sim/sources.txt` and run `tb_designer_view` with `G_LARGE_VIEW` set to true or false.

The arithmetic check establishes implementation agreement. The separate comparisons with each Designer JPEG establish the reported exact-match failures. Historical PIC2 design notes, images and logs refer to the earlier native-size project. Its original README is under `document/PIC2_native_README.md`.
