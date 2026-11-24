# PIC1 medium-scale region preservation

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

The sector stage chooses a surface RGB value using four overlapping 5 × 5 regions. Two separable three-tap passes at 16-pixel spacing supply broad RGB context. The `portrait_structure_vote` processes both estimates before the tone quantizer. It uses the signed difference between surface and context in luminance, R−G and G−B. Each pixel carries a tag for the sign and channel with the greatest absolute difference. A zero residual has a neutral tag.

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

## Medium-scale region preservation

The vote stencil now reads 25 sector-surface luminance samples. Each axis uses offsets −7, −3, 0, +3 and +7 pixels. The inner 3 × 3 mean uses nine samples at −3, 0 and +3. The full 5 × 5 mean covers the same center and includes the eight mixed near/far positions. Both means use quarter-code luminance, (R + 2G + B), with nearest-integer rounding. The two averages cover a 7 × 7 and a 15 × 15 pixel footprint respectively.

If the signed difference between those means and the displacement from the broad context to the inner mean point in the same direction, the tone stage can move the broad RGB toward the inner surface. The eligible absolute difference is 2 through 40 quarter-codes. The exposure weight and directional weight restrict the correction to a maximum of three RGB8 codes per channel. This can place neighboring surfaces into different tone bands. The original broad context still supplies the separate contour guide.

In the tone stage, broad R−B above 34 codes gently compresses the two opponent-color differences on warm highlights. In olive midtones, the broad G−B and R−G differences and the signed surface-to-context luminance difference guide local color separation. Both corrections use the camera-derived context at the center pixel.

The region stage uses the RGB along its most compatible local direction and the luminance ranks at radii 2 and 5. Mixed warm neighborhoods can preserve an intermediate brown surface between two darker bands. For dark blue regions, the logic also considers the brightest sample in the larger window and the green/blue balance along that local direction. A spatially quiet region receives no blue-band adjustment.

At the output, peaks or troughs supported by both axial comparisons use a 7/16 blend when the center and neighboring luminances lie within 64 codes. A remaining isolated excursion of 3 to 28 codes can move up to eight codes toward the nearest neighboring luminance. The same signed adjustment applies to all three channels before clipping. The original 6/16 blend still applies to a bounded warm surface outside this peak test.

## Measured results

The simulated BMP matched 1,776 of 2,359,296 decoded Designer1 pixels exactly (0.0753%). 2,357,520 differed. Both the stalled and continuous full-frame simulations produced SHA-256 `25ece340c7bd5f5b534e7c2aaf260c7cc4e49318dd957b78ff9dd399c6f32811` for the BMP.

| Whole frame | Previous | This revision | Designer1 |
|---|---:|---:|---:|
| Exact RGB pixels | 1,797 | 1,776 | 2,359,296 |
| Mean absolute channel error | 10.279 | 9.979 | 0.000 |
| Edge centers in short fragments | 4,277 | 4,143 | 2,803 |
| Isolated dark centers | 1,330 | 1,298 | 5,847 |
| Long-contour placement F1 | 0.401 | 0.400 | 1.000 |

| Same-coordinate measurement | Previous | This revision | Designer1 |
|---|---:|---:|---:|
| Skin minus eyebrow luminance | 28.79 | 32.65 | 45.01 |
| Skin minus upper eyelid luminance | 49.62 | 49.72 | 52.59 |
| Eye row-profile mean absolute error | 8.86 | 7.78 | 0.00 |
| Largest connected cool highlight in the side-hair crop (%) | 10.38 | 12.15 | 12.34 |
| Side-hair highlight area F1 | 0.626 | 0.692 | 1.000 |
| Connected side-hair highlights | 2 | 3 | 4 |
| Skin gap above the brighter eye band, median over columns | 24.52 | 24.83 | 44.79 |
| Cheek largest connected flat area (%) | 31.1 | 22.3 | 17.3 |
| Jacket collar largest connected flat area (%) | 16.8 | 9.5 | 3.7 |
| Forehead largest connected flat area (%) | 18.5 | 19.0 | 17.0 |

Each flat-area percentage uses the largest eight-connected set of pixels whose local 5 × 5 per-channel ranges are at most four codes. The medium patch overlap in the JSON measures agreement with the artwork on patch size, location and local contrast polarity. The comparison image shows the same coordinates in every column. The reference was used to choose scalar settings and evaluate PIC1. All spatial and color decisions in the hardware are computed from incoming camera pixels.

The largest smooth region in the cheek crop is smaller, while the reference still places its boundaries differently. The lip and lower-face crop has RGB MAE 18.62 in this revision and 17.45 in the prior capture. The eye strip reports both an average brow–skin contrast and a per-column gap so improvement in one does not mask local merging.

The testbench verified all 2,359,296 accepted RGB10 output words against the integer model under backpressure. GHDL synthesized the 2048 × 1152 design. The directed VHDL testbench `sim/tb_medium_context.vhd` and `results/sequence_and_synthesis.txt` include the window, polarity and stall checks. Device resource mapping, post-route timing and native Windows Questa execution were not measured.



## Repeat the checks

With NVC or GHDL on PATH, these commands reproduce the stressed capture, model check and five-column crop sheet. Run the second command even when the first returns 1 for an artwork difference. SciPy is needed only for the crop measurements.

```cmd
python sim/run.py --input images/PIC1.JPG --stress --trace results/accepted.u32le
python sim/check_model.py images/PIC1.JPG results/accepted.u32le
py -3 -m pip install scipy
python sim/compare_structure.py --source images/PIC1.JPG --earlier comparison/PIC1_earlier.bmp --prior comparison/PIC1_previous.bmp --new results/PIC1_filtered.bmp --new-label "Medium region preservation" --reference reference/Designer1_PIC1_2048x1152.jpg --out results
```

Run `python sim/run.py --compare-only` to recheck the saved BMP. With GHDL and a POSIX shell, `sh sim/synthesize.sh . build/synth` generates Verilog. The delivered synthesis and consecutive-frame checks are summarized in `results/sequence_and_synthesis.txt`. The launcher Tcl also ran in a path containing spaces with NVC executing the simulator commands. Native Windows Questa was unavailable.
