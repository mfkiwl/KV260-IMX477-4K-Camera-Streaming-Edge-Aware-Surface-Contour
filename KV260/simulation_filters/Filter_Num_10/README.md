# Edge-preserving painterly filter in VHDL

The PNG in `results/PIC1_filtered.png` is a lossless copy of the RGB10 board-wrapper simulation output in `results/PIC1_filtered.bmp`. The 2048 × 1152 input is `images/PIC1.JPG`. Open `results/PIC1_painterly_comparison.png` for the decoded input, the previous RTL output and the refined output, with matching native-pixel crops.

## Filter and integration

The implementation integrates the arithmetic from `document/source.pdf` into the existing five AXI4-Stream stages. Each output color comes from the original RGB samples. The old luminance snapping was removed. The lookup tables encode scalar filter weights, reciprocal normalization, shadow lift and ink strength. No palette mapping or K-means is used.

| RTL stage | Tap spacing | Default settings | Operation |
| --- | ---: | --- | --- |
| Surface pass 1 | 1 | Sigma 14, base center cap 16/256 | Four overlapping 3 × 3 binomial quadrant means. Quartic weights favor homogeneous neighborhoods. Near and far opposing pairs detect narrow bright or dark strokes supported by a neighboring pixel along the tangent. |
| Surface pass 2 | 2 | Sigma 12, base center cap 24/256 | Extends the smoothing radius. When all quadrants cross a strong feature, the pass retains more of the center. |
| Surface pass 3 | 4 | Sigma 10, base center cap 40/256 | Smooths broad shading while protecting features that fall between the coarse taps. |
| Tone and contour | 1 | Ink ramp 22–68, strength 204/256, shadow lift 14, chroma gain 288/256 | Computes nine 3 × 3 Scharr responses within a single 5 × 5 window. Links magnitudes along the tangent, attenuates flanks across the normal, and retains dark valleys. Multiplies all three tone-adjusted channels by one ink factor. |
| Contour finish | 1 | Tangent clamp 36, surface clamp 18, blend ramp 16–48 | Re-estimates direction on the inked image. Crossfades a five-tap binomial along the stroke with a color-limited 3 × 3 surface polish. |

The extra stroke protection addresses a failure observed with a narrow test line and the unmodified PDF equations. On the fine pass, a line must show contrast on both sides across its normal and similar luminance at a neighboring tangent sample. On the two coarser passes, the best quadrant score controls the additional center retention. Both weights rise gradually, to a maximum of 248/256. The base center caps in the table apply to the PDF's original residual term.

The milder shadow lift produces a darker portrait than the original RTL. The control values are in `rtl/pic2_filter_axis.vhd`, `rtl/pic2_painterly_pkg.vhd` and the processing-stage generics. The PDF math is retimed to 8, 7 and 5 enabled arithmetic cycles for each surface pass, the contour stage and the finish, respectively. Window fill and border flush add raster-dependent delay. A blocked stage holds its data and framing together.

## Reproduce in Windows Questa

From the extracted project directory, run the following in CMD. Questa must be on the path.

```cmd
vsim -c -do sim/run_questa.do
```

The script compiles the VHDL-2008 files in `sim/sources.txt`. It runs the RGB10 wrapper with randomized source gaps and output backpressure and writes `results/PIC1_filtered.bmp`. It checks the testbench completion flag before reporting success.

## Reproduce with GHDL

From the same directory, with GHDL and Python 3 installed, run the following commands. Pixel comparison and the directed checks also require NumPy and Pillow.

```sh
python sim/run_ghdl.py --rgb10 --stalls --decoded-bmp results/PIC1_decoded.bmp
python tools/check_pixels.py results/PIC1_decoded.bmp results/PIC1_filtered.bmp --jpeg images/PIC1.JPG
python tools/check_two_frames.py
python tools/check_contours.py
```

The JPEG decoder, filter and BMP capture run in VHDL. The checker independently computes the 2-D result from the decoder's actual pixels, including all borders. A different 8-bit baseline JPEG can be supplied as the launcher's first argument, followed by `--output` and a new BMP path. Image dimensions are read from its header. The VHDL reader supports single-scan grayscale and YCbCr with 4:4:4, 4:2:2 or 4:2:0 sampling. It uses JPEG raster orientation and ignores EXIF transforms.

The full-frame run recorded here used NVC 1.23.1. The following commands repeat it from the project root.

```sh
mkdir -p build/nvc results
nvc --std=2008 --work=work:build/nvc -a -f sim/sources.txt
nvc --std=2008 --work=work:build/nvc -H 512m -e -O3 -g G_USE_RGB10=true -g G_STALLS=true -g G_DECODED_BMP=results/PIC1_decoded.bmp tb_pic2
nvc --std=2008 --work=work:build/nvc -H 512m --ieee-warnings=off-at-0 -r tb_pic2 --exit-severity=error
```

## Hardware interface

`surface_contour_select` is the board-facing top. Its 32-bit ports carry R10 in bits 29–20, G10 in bits 19–10 and B10 in bits 9–0. `dimensions(15 downto 0)` supplies width and `dimensions(31 downto 16)` supplies height. The filter arms on an enabled SOF, takes the high eight bits of each channel and zero-pads the filtered result back to RGB10. The RGB888 core is `pic2_filter_axis`. SOF is `TUSER`, and EOL is `TLAST`.

For Vivado, add the VHDL-2008 sources from `rtl/` in the order in `sim/sources.txt` up to and including `surface_contour_select.vhd`. The nested `rtl.zip` contains the same eight source files. Set the existing wrapper's maximum dimensions to suit the stream. The five windows store 36 rows of RGB888 history at the default spacings. At width 3840, this represents 405 KiB before memory packing and horizontal taps. The windows accept one interior pixel per enabled clock and can backpressure the source during edge replication.

## Verification results

| Test | Result |
| --- | --- |
| 2048 × 1152 portrait through the RGB10 board wrapper | 2,359,296 accepted pixels, 1,152 EOLs, one SOF and 998,680 stalled output cycles. The testbench checked output stability, RGB10 padding, framing and the final pixel count. |
| Full RGB888 core with continuous input and ready output | Its BMP was byte-identical to the stalled RGB10 wrapper output. |
| Independent spatial model | Every R, G and B value matched across the full portrait, including all four borders. |
| Two consecutive 43 × 27 frames | Color and grayscale frames matched the model with stalls. The second frame matched its standalone rendering and all 1,161 grayscale pixels remained neutral. |
| Curved-edge test through the RGB10 wrapper | All 90,112 output pixels matched the model. The shading and line measurements are below. |
| GHDL synthesis front end | Generated a netlist for `surface_contour_select` at 3840 × 2160 maximum dimensions. GHDL inferred line memories and reported that it ignores Vivado's `ram_style` attribute. Vivado placement, resource use, routed timing and KV260 video performance require hardware-tool verification for this revision. |

The controlled frame has a noisy gray ramp, a sinusoidal step, and a separate two-pixel dark stroke. Measurements use the central 488 columns. RMS shading variation measures the residual after fitting a straight line to the gray ramp. On the step, an ink sample must be at least 10 gray levels darker than the nearby dark-side plateau and within three pixels of the known boundary. The two-pixel stroke must be at least 15 levels below its local background and within two pixels of its known centerline.

| Measurement | Decoded input | Previous RTL | Refined RTL |
| --- | ---: | ---: | ---: |
| Ramp RMS, 8-bit gray levels | 3.070 | 0.845 | 0.397 |
| Columns with ink on the step | 1/488 | 260/488 | 488/488 |
| Longest gap in the step's ink | 301 columns | 37 columns | 0 columns |
| Columns retaining the two-pixel stroke | 488/488 | 107/488 | 488/488 |

See `results/verification/` for simulation, synthesis and pixel-check logs, and `results/curve_test/` for the actual test images. The original project documentation and additional example images are included. Earlier measurements and the previous portrait output are grouped under `results/previous/`.
