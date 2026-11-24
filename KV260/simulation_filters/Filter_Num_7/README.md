# Filter 5 — Designer1 live portrait RTL

The PIC1 test decodes `images/PIC1.JPG` in VHDL, streams RGB into the synthesizable filter and writes `results/PIC1_filtered.bmp` on accepted AXI transfers. The 2048 × 1152 output retains the source framing. The `designer1_live` profile calculates color from each native filtered pixel and eight surrounding samples. Its fixed coefficients were calibrated on PIC1. It applies the same arithmetic to other camera frames. The final JPEG enters the comparison after the BMP closes.

## PIC1 result and reproduction

`results/PIC1_verification.txt` records the baseline and revised RGB comparisons, the two full-frame simulator runs, the independent raster-model check and the synthesis result. The individual simulator and synthesis logs are in `results/verification/`. `results/PIC1_Designer1_comparison.png` shows corresponding regions in the supplied BMP, revised BMP and reference.

From the extracted project root in Windows Command Prompt with Questa, Python 3, NumPy and Pillow installed, run

```cmd
run.cmd images\PIC1.JPG
```

With GHDL, run

```sh
python sim/run_ghdl.py images/PIC1.JPG --camera-wrapper --stalls
```

Both commands write the BMP, verify its RGB values against the integer model, and compare it with `reference/Designer1_PIC1_2048x1152.jpg`. The exact-artwork check returns exit code 1 when a pixel differs. The simulation and the arithmetic checks have their own results. Recheck a saved capture without rerunning the simulation with `python sim/compare_rgb.py`. Run `python sim/compare_style.py --baseline results/Rev1/PIC1_filtered.bmp` for both captures’ error, PSNR and luminance SSIM. The Rev1 PIC1 BMP is byte-identical to the supplied baseline.

The full-frame capture was also run with NVC 1.23.1 using the following settings. The VHDL testbench defaults to the bundled PIC1 input and output paths.

```sh
nvc --std=2008 --ieee-warnings=off-at-0 -H 512m -a -f sim/sources.txt -e -O3 -gG_CAMERA_WRAPPER=true -gG_COLOR_PROFILE=designer1_live -gG_STALLS=true -gG_DECODED_BMP=build/PIC1_decoded.bmp tb_pic2 -r --exit-severity=error
python tools/check_pixels.py build/PIC1_decoded.bmp results/PIC1_filtered.bmp --jpeg images/PIC1.JPG --designer1 --color-profile designer1_live
python sim/compare_rgb.py
```

The focused `tb/tb_live_camera_modes.vhd` testbench drives four consecutive RGB10 frames with different sizes, bypass settings and output stalls. Compile it after the RTL sources and run `tb_live_camera_modes`.

## Live camera datapath

On the RGB10 camera wrapper, set `surface_contour_select.G_DESIGNER1_LIVE => true` and assert `enable` before the frame starts. Set `G_MAX_WIDTH` and `G_MAX_HEIGHT` to the largest raster used, and supply the active dimensions at SOF. The wrapper carries R10 at bits 29–20, G10 at 19–10 and B10 at 9–0. The working precision is 8 bits per channel. Filtered output fills the upper eight bits of each lane and clears the two low bits. Bypass forwards the input word. The generic defaults to `false` for existing native-filter integrations. The RGB888 `designer_filter_axis` interface selects the same core with `G_COLOR_PROFILE => "designer1_live"` and aligned framing.

Inside `pic2_filter_axis`, the three edge-aware surface passes, tone processing and antialiasing produce native RGB. `axis_designer1_live.vhd` samples the center and the eight outer taps of an 81 × 81 footprint. It averages the eight surrounding RGB triplets. Both the center and the surrounding mean yield luma, R−G and G−B. Forty-nine bounded linear terms operate on the center values and their differences from the surrounding mean. A signed Q7 sum supplies a correction for each channel. A gamut and exposure weight blends the correction back toward the native RGB near the limits. A final 5 × 5 binomial filter samples every second pixel across a 9 × 9 footprint. Large channel differences reduce a neighbor’s influence on the center. The live datapath uses fixed-point arithmetic and line buffers throughout.

The grade and final smoothing windows hold 80 and eight lines of 24-bit pixels, respectively. Together they add 990 KiB of logical line history at width 3840. The grade accepts one window per advancing clock. Padding and AXI backpressure affect frame throughput. The RGB10 wrapper passed GHDL synthesis at 3840 × 2160. Timing closure, device utilization and live board frame rate require a Vivado implementation and hardware measurements.

## Existing full-raster color profiles

The aligned `designer_filter_axis` stream selects one color profile per frame. The native camera filter and the final contour stage run in both profiles. The aligned source-color profile takes brightness and contours from the filtered result and preserves the exact channel differences of the JPEG decoder at the corresponding pixel. This removes the blue and violet casts in skin, neutrals and smooth color ramps. The original Designer1 profile retains the approved look of the three dim portraits.

| Default run | Color profile | Output size |
|---|---|---|
| PIC1 | New `designer1_live` grade | 2048 × 1152 |
| PIC2, PIC3 | Original Designer1 portrait grade | 2048 × 1152 |
| PIC4, PIC5, PIC82, PIC99 | Source color | 2048 × 1152 |

## RTL behavior

`pic2_filter_axis` performs three edge-aware smoothing passes, tone and contour processing, and the native finish. Its tone stage scales channel differences together to preserve hue. `axis_designer1_grade` can then add a second, portrait-specific color treatment. For example, that grade maps a neutral RGB input of `(128, 128, 128)` to `(101, 157, 190)`. In source-color mode its blend weight is zero, so the grade passes all three incoming RGB bytes exactly. `axis_designer1_finish` still smooths surfaces and enhances contours.

In the aligned source-color path, `axis_source_chroma` stores R−G and B−G from each accepted camera pixel. When its corresponding filtered pixel arrives, it reconstructs RGB using those differences and the filtered luma. It limits the common brightness offset to the range that keeps all three channels between 0 and 255. At a saturated color boundary, that limit prioritizes the original hue and RGB channel spacing over the requested brightness change. A neutral input pixel has three equal output channels even if the spatial window straddles a saturated color border. Designer1 pixels pass through this final stage byte for byte.

`G_COLOR_PROFILE` controls the Designer1 path in `designer_filter_axis` and `tb_pic2`. The simulation launchers select `designer1_live` for the bundled aligned PIC1 test and `auto` for other input files unless a profile is supplied. A bare `tb_pic2` instance selects the live profile for aligned RGB and accepts an explicit profile override. The hardware profile is an elaboration setting.

| Setting | Behavior |
|---|---|
| `designer1_live` | Apply the new calibrated camera grade at native dimensions. |
| `auto` (hardware default) | The aligned stream meters the first eight accepted input rows, or the entire frame when shorter. It selects Designer1 when mean luma is at most 80, mean G−B is at least 4 and mean RGB span is at most 32. It selects source color for all other measurements. Explicit portrait framing retains its historical Designer1 grade. |
| `source` | In aligned mode, always use filtered brightness with the exact original R−G and B−G. This also covers frames with unrepresentative first rows, such as letterboxing. In explicitly resampled portrait mode, this setting bypasses the matrix and uses the framed camera-filter RGB. |
| `designer1` | Always apply the original Designer1 matrix and contour finish. |

Meter values use the raw 8-bit RGB stream. Luma is `(5R + 9G + 2B + 8) / 16` with integer division. RGB span is the largest channel minus the smallest. The spatial filter provides the lookahead. A pending decision is held through the start-of-frame transfers at both the grade and the final output stage. Accepted raw beats write the chroma FIFO and accepted filtered beats read it in raster order. Input backpressure prevents overflow and the output holds its data and markers during a stall. The RTL uses no filenames or JPEG metadata.

With the default tap spacings and width 2048, GHDL synthesis inferred an 84,136-word × 18-bit RAM for chroma alignment. The registered reconstruction has four stages. A build forced to `designer1` omits this RAM. Vivado implementation and KV260 timing require a hardware build.

## Run the simulation

Extract the project and run from `Filter_Num_5`. The independent pixel check requires Python 3, NumPy and Pillow. Each run writes `results/<input stem>_filtered.bmp`. The aligned capture uses the full encoded raster in scan order. Display rotations used to show the two portraits upright apply only to the comparison preview.

**Questa on Windows**

```cmd
python -m pip install numpy Pillow
run.cmd images\PIC4.JPG
run.cmd images\PIC5.JPG
run.cmd images\PIC82.jpg
run.cmd images\PIC99.jpg
```

Running `run.cmd` without an argument uses PIC1. The Questa script also accepts an explicit output path and color profile.

```cmd
vsim -c -do "do sim/run_questa.do images/PIC4.JPG build/PIC4_source.bmp source"
```

**GHDL**

```sh
python sim/run_ghdl.py images/PIC4.JPG --aligned --stalls
python sim/run_ghdl.py images/PIC5.JPG --aligned --stalls
python sim/run_ghdl.py images/PIC82.jpg --aligned --stalls
python sim/run_ghdl.py images/PIC99.jpg --aligned --stalls
python tools/check_frame_color.py
```

For an explicit treatment, add `--color-profile source` or `--color-profile designer1`. `--native` captures the native camera pipeline directly. `--portrait` selects the earlier 2048 × 1365 framing for a 2048 × 1152 input. The earlier portrait design notes are in `document/Designer1_portrait_README.md`. The artwork supplied in this archive is the 2048 × 1152 aligned reference.

**NVC**

```sh
mkdir -p build
nvc --std=2008 --ieee-warnings=off-at-0 -H 512m -a -f sim/sources.txt -e -gG_COLOR_PROFILE=auto -gG_INPUT=images/PIC4.JPG -gG_OUTPUT=results/PIC4_filtered.bmp -gG_DECODED_BMP=build/PIC4_decoded.bmp -gG_STALLS=true tb_pic2 -r --exit-severity=error
python tools/check_pixels.py build/PIC4_decoded.bmp results/PIC4_filtered.bmp --designer1 --jpeg images/PIC4.JPG
```

## Verification

The archive retains the earlier captures for the other six pictures. `tools/check_frame_color.py` exercises two opposite profile transitions without reset, with source gaps and output stalls, and checks a grayscale ramp for exact channel equality. `tb/tb_axis_source_chroma.vhd` checks a four-entry FIFO at its full and empty limits, wraparound, clipped luma targets, and frame markers. To run that focused test with GHDL, use the commands below.

```sh
ghdl -a --std=08 rtl/pic2_types.vhd rtl/axis_source_chroma.vhd tb/tb_axis_source_chroma.vhd
ghdl -r --std=08 tb_axis_source_chroma --assert-level=error
```
