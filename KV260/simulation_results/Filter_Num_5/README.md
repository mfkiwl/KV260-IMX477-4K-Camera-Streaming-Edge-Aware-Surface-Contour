# Filter 5 — full-raster color correction

The aligned `designer_filter_axis` stream selects one color profile per frame. The native camera filter and the final contour stage run in both profiles. The aligned source-color profile takes brightness and contours from the filtered result and preserves the exact channel differences of the JPEG decoder at the corresponding pixel. This removes the blue and violet casts in skin, neutrals and smooth color ramps. The original Designer1 profile retains the approved look of the three dim portraits.

| Default run | Color profile | Output size |
|---|---|---|
| PIC1, PIC2, PIC3 | Designer1 portrait grade | 2048 × 1152 |
| PIC4, PIC5, PIC82, PIC99 | Source color | 2048 × 1152 |

## RTL behavior

`pic2_filter_axis` performs three edge-aware smoothing passes, tone and contour processing, and the native finish. Its tone stage scales channel differences together to preserve hue. `axis_designer1_grade` can then add a second, portrait-specific color treatment. For example, that grade maps a neutral RGB input of `(128, 128, 128)` to `(101, 157, 190)`. In source-color mode its blend weight is zero, so the grade passes all three incoming RGB bytes exactly. `axis_designer1_finish` still smooths surfaces and enhances contours.

In the aligned source-color path, `axis_source_chroma` stores R−G and B−G from each accepted camera pixel. When its corresponding filtered pixel arrives, it reconstructs RGB using those differences and the filtered luma. It limits the common brightness offset to the range that keeps all three channels between 0 and 255. At a saturated color boundary, that limit prioritizes the original hue and RGB channel spacing over the requested brightness change. A neutral input pixel has three equal output channels even if the spatial window straddles a saturated color border. Designer1 pixels pass through this final stage byte for byte.

`G_COLOR_PROFILE` controls the Designer1 path in `designer_filter_axis` and `tb_pic2`.

| Setting | Behavior |
|---|---|
| `auto` (default) | The aligned stream meters the first eight accepted input rows, or the entire frame when shorter. It selects Designer1 when mean luma is at most 80, mean G−B is at least 4 and mean RGB span is at most 32. It selects source color for all other measurements. Explicit portrait framing retains its historical Designer1 grade. |
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

Running `run.cmd` without an argument uses PIC3. The Questa script also accepts an explicit output path and color profile.

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

For an explicit treatment, add `--color-profile source` or `--color-profile designer1`. `--native` captures the native camera pipeline directly. `--portrait` selects the earlier 2048 × 1365 framing for a 2048 × 1152 input. The original portrait reference and design notes are in `reference/Designer1.jpg` and `document/Designer1_portrait_README.md`.

**NVC**

```sh
mkdir -p build
nvc --std=2008 --ieee-warnings=off-at-0 -H 512m -a -f sim/sources.txt -e -gG_INPUT=images/PIC4.JPG -gG_OUTPUT=results/PIC4_filtered.bmp -gG_DECODED_BMP=build/PIC4_decoded.bmp -gG_STALLS=true tb_pic2 -r --exit-severity=error
python tools/check_pixels.py build/PIC4_decoded.bmp results/PIC4_filtered.bmp --designer1 --jpeg images/PIC4.JPG
```

## Verification

`results/color_regression.txt` records the seven full-frame RTL runs, comparisons with the supplied good captures, independent pixel checks, and measurements on neutral and colored source pixels. `tools/check_frame_color.py` exercises two opposite profile transitions without reset, with source gaps and output stalls, and checks a grayscale ramp for exact channel equality. `tb/tb_axis_source_chroma.vhd` checks a four-entry FIFO at its full and empty limits, wraparound, clipped luma targets, and frame markers. To run that focused test with GHDL, use the commands below.

```sh
ghdl -a --std=08 rtl/pic2_types.vhd rtl/axis_source_chroma.vhd tb/tb_axis_source_chroma.vhd
ghdl -r --std=08 tb_axis_source_chroma --assert-level=error
```
