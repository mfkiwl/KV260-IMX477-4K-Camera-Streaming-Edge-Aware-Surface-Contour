# PIC1 spatially coherent surface regions

## Windows simulation


Extract this complete revision into its own folder and open Command Prompt in the folder containing `run.cmd`. Use a VHDL-2008 Questa or ModelSim installation with `vsim`, `vcom`, `vlib` and `vmap` on PATH. The host reads and compares images using Python 3.8 or later, Pillow and NumPy.

```cmd
py -3 -m pip install pillow numpy
run.cmd
```

For a first run or a console that stops printing during load, use `run.cmd smoke`. This simulates a 128 × 72 center crop of PIC1, checks all 9,216 captured RGB pixels against the integer model and writes `results/PIC1_smoke_filtered.bmp`. A successful smoke test returns 0. Then run `run.cmd` for the full frame.

Watch for `LOAD START` before elaboration, `LOAD COMPLETE` when the design has loaded, and `TB START` when simulation begins. The bench reports the first input and output handshakes, then accepted input pixels, captured output pixels and completed rows every 32,768 simulated clock cycles. Input can advance while output is still zero as the line buffers fill. If a run remains at `LOAD START`, the VHDL clock has not yet started. The last printed module name by itself does not identify a failed module. The active run prints its transcript path. For troubleshooting, retain the last transcript lines and the output of `vsim -version`.

The launcher reads `images/PIC1.JPG`, compiles the manifest in `rtl/files.f` and captures accepted output pixels into `results/PIC1_filtered.bmp`. It compares all three RGB8 channels at each coordinate with the decoded pixels of `reference/Designer1_PIC1_2048x1152.jpg`. The transcript and the comparison JSON are in `results`. To simulate another image, run `run.cmd "path\to\photo.jpg"`. A corresponding reference can be supplied as `reference/Designer1_<stem>_<width>x<height>.jpg`.

| Exit code | Meaning |
|---|---|
| 0 | The AXI simulation passed and every pixel matched the supplied reference. With a custom image that has no reference, the capture succeeded. |
| 1 | The simulation passed and the BMP was written. One or more RGB triplets differed from the reference. |
| 2 | Image preparation, HDL compilation, simulation or capture failed. |

## Data path

The filter accepts packed AXI4-Stream RGB10, using R[29:20], G[19:10], B[9:0]. The core runs the filters on the top eight bits of each lane, then expands RGB8 to RGB10 by repeating the two high bits. A pixel transfers when TVALID and TREADY are high at the rising clock edge. TUSER marks frame start and TLAST marks line end.

The sector stage chooses a surface RGB value using four overlapping 5 × 5 regions. Two separable three-tap passes at 16-pixel spacing supply broad RGB context. The new `portrait_structure_vote` processes both estimates before the tone quantizer. It uses the signed difference between surface and context in luminance, R−G and G−B. Each pixel carries a tag for the sign and channel with the greatest absolute difference. A zero residual has a neutral tag.

Four axial neighbors at a distance of three pixels and four diagonal neighbors at offsets of seven pixels along each axis vote by matching the center's nonzero tag. Medium structure requires five total votes with at least two from each distance. D is the maximum of the three absolute differences and the camera-derived directional response scaled down by eight.

| Surface class | Selection in priority order | Weight toward the neighboring color |
|---|---|---:|
| Major boundary | D ≥ 18 | 0/16 |
| Supported medium structure | D ≥ 3 and vote passes | 4/16 |
| Fine texture | Remaining pixels with D ≥ 2 | 12/16 |
| Noise | Remaining pixels | 16/16 |

Before averaging, each neighbor’s RGB displacement from the center is clipped to ±10 codes per channel. An accumulated displacement of at least 23 codes in one channel enables the adjustment. The filtered surface drives tone quantization. The original contour guide stays aligned with its center pixel, and the subsequent contour classifier still qualifies a strong seed at 18 using its own directional score. Its gain curve and shadow compositor are shared with the preceding design.

After contour reconstruction, `portrait_region_axis` estimates a local color plane using the near and far median luminances and the RGB average along the most compatible direction. The near and far samples are spaced at two and five pixels. Their agreement weights the chroma correction. Cool midtones with support across both windows extend a highlight, and isolated peaks are attenuated. The local luminance span and a count of warm neighbors qualify the lightening of neutral or cool midtones. This separates a warm-adjacent shadow and limits the effect in olive regions. The same operations apply to every coordinate. All region and color decisions are calculated from streaming pixels. PIC1 was used to choose scalar settings. The JPEG artwork is read by the host comparison software.

Within the existing bright-warm mask, the tone stage uses broad-context luminance plus R−B to distinguish warm planes with similar brightness. An exposure below 93 contributes −5 luma codes, the middle interval contributes zero, and 99 or above contributes +4. The existing mask scales this offset continuously. This adjustment uses two comparisons and the same aligned broad RGB sample as the previous revision.

The final impulse-repair stage also compares the horizontal and vertical neighbor means with the center. When both means are above the center or both are below it, and the four-neighbor span and center excursions are bounded by 48 luminance codes, it applies its existing 6/16 blend toward their RGB mean. The test reuses the existing horizontal and vertical line storage.

## Measured results

Strict decoded RGB equality found **1,797 matching pixels out of 2,359,296 (0.0762%)**. 2,357,499 pixels differed.

| Whole frame | Previous | Revised | Reference |
|---|---:|---:|---:|
| Exact RGB pixels | 1,952 | 1,797 | 2,359,296 |
| Mean absolute channel error | 10.326 | 10.279 | 0.000 |
| Short-fragment edge pixels | 4,790 | 4,277 | 2,803 |
| Isolated dark pixels | 1,873 | 1,330 | 5,847 |
| Connected-contour F1 | 0.444 | 0.401 | 1.000 |

| Native-resolution crop | Fine-scale RMS previous / revised / artwork | Medium-scale RMS previous / revised / artwork | Largest connected flat area % previous / revised / artwork |
|---|---:|---:|---:|
| Cheek | 0.95 / 0.71 / 0.63 | 2.68 / 2.31 / 1.55 | 24.1 / 31.1 / 17.3 |
| Forehead | 0.51 / 0.45 / 0.61 | 1.89 / 1.74 / 1.48 | 31.0 / 18.5 / 17.0 |
| Eye and brow | 1.06 / 0.91 / 0.65 | 3.85 / 3.94 / 3.38 | 4.6 / 2.4 / 4.3 |
| Upper hair | 0.85 / 0.64 / 0.71 | 2.29 / 2.10 / 2.09 | 7.4 / 7.1 / 4.3 |
| Hair highlights | 0.93 / 0.69 / 0.76 | 2.18 / 1.97 / 1.86 | 14.8 / 14.3 / 8.5 |
| Jacket collar | 1.99 / 1.14 / 0.91 | 4.64 / 3.23 / 3.23 | 14.4 / 16.8 / 3.7 |
| Lips and lower face | 2.82 / 2.21 / 0.79 | 5.82 / 5.55 / 3.41 | 0.7 / 1.3 / 3.2 |

The metrics use identical upper-left-origin coordinates for each image. The scale-band RMS values measure how much fine or medium-scale luminance variation is present in the reference-defined surface mask. Connected flat area uses a 5 × 5 RGB range test. Neither statistic measures artistic quality by itself. The PNG includes twelve 1:1 detail crops. The JSON and text summaries give the thresholds, and also report a dedicated brow/eyelid strip and an interior-hair highlight mask.

| Fixed-crop measurement | Previous | Revised | Designer1 |
|---|---:|---:|---:|
| Skin minus brow luminance | 22.68 | 28.79 | 45.01 |
| Skin minus upper-lid luminance | 49.26 | 49.62 | 52.59 |
| Eye row-profile mean absolute error | 12.06 | 8.86 | 0.00 |
| Largest cool highlight in the hair crop (%) | 7.16 | 10.38 | 12.34 |

The eye profile averages luminance across the same 130-pixel strip on each scanline. Its error measures how closely the horizontal layers follow the artwork. The largest connected cheek patch still covers more of the crop than in the artwork. The connected-contour F1 in the whole-frame table records the tradeoff in long-edge placement.

The design passed VHDL-2008 analysis, full-width generic synthesis, and backpressure checks. All 2,359,296 stressed RGB10 output words matched the independent integer model. The continuous-input simulation produced the same BMP. Device utilization, timing and native Windows Questa execution were not measured for this revision.

## Repeat the checks

With NVC or GHDL on PATH, these commands reproduce the stressed capture, model check and five-column crop sheet. Run the second command even when the first returns 1 for an artwork difference. SciPy is needed only for the crop measurements.

```cmd
python sim/run.py --input images/PIC1.JPG --stress --trace results/accepted.u32le
python sim/check_model.py images/PIC1.JPG results/accepted.u32le
py -3 -m pip install scipy
python sim/compare_structure.py --source images/PIC1.JPG --earlier comparison/PIC1_earlier.bmp --prior comparison/PIC1_previous.bmp --new results/PIC1_filtered.bmp --new-label "Coherent regions" --reference reference/Designer1_PIC1_2048x1152.jpg --out results
```

Run `python sim/run.py --compare-only` to recheck the saved BMP. With GHDL and a POSIX shell, `sh sim/synthesize.sh . build/synth` generates Verilog. The delivered synthesis and consecutive-frame checks are summarized in `results/sequence_and_synthesis.txt`. The launcher Tcl also ran in a path containing spaces with NVC executing the simulator commands. Native Windows Questa was unavailable.
