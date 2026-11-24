# Directional surface reconstruction for live RGB10 video

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

## Signal path

`axis_portrait_filter` accepts one packed RGB10 pixel per transfer, with R in bits 29:20, G in 19:10 and B in 9:0. TUSER identifies the first pixel and TLAST the end of each row. A transfer takes place on a rising edge with TVALID and TREADY asserted. The arithmetic operates on RGB8 and extends each channel back to ten bits by repeating its two most significant bits.

A separable edge-aware filter and a sector filter estimate the surface color. Broad context comes from two three-tap filters spaced 16 pixels apart. The structure vote compares each surface pixel with this context in luminance and the R−G and G−B differences. Neighbors at spacing 3 and 7 vote on the dominant signed difference. Strong boundaries protect their surface value. Supported medium differences preserve color separation during subsequent flattening. Smaller responses receive more smoothing. A parallel sideband carries the original contour evidence through the same stalls and padding cycles.

The tone stage colors the surface, horizontal and vertical finishing passes consolidate nearby tones, and contour reconstruction uses the separate guide. The region stage reads near and far luminance ranks and an RGB estimate from the most compatible local direction. The final stage corrects short, isolated excursions. The hardware uses the incoming RGB stream and line buffers. The source JPEG is the test stimulus, and the host uses the Designer1 JPEG exclusively for measurement during a simulation run. The scalar settings were developed on PIC1.

## Changes in this revision

**Warm surface boundaries.** The structure-vote stage compares the opposing sides of a local patch horizontally and vertically. Each side is a three-sample weighted luminance estimate measured at both 3 and 7 pixels. A consistent contrast sign at both distances lets a supported warm surface follow the nearer side by at most four RGB8 codes. The broad green–blue difference limits this shift to zero at 12 codes or below, half at 13 and full at 14 or above. The broad context receives one quarter of that signed adjustment. A single dark center in an otherwise flat neighborhood supplies no such vote.

**Dark hair and other low-chroma shadows.** The tone stage retains quarter-code luminance when it compares a sector-selected surface with the broader neighborhood. Under low-chroma, low-exposure conditions, the signed local relief controls a bounded luminance adjustment and up to two extra codes of green–blue separation. This reveals blue shading already present in the live surface. The contour gain and stroke reconstruction use their existing equations.

**Eye layers and red surfaces.** The output region stage forms a 3 × 3 binomial RGB average from the existing stencil at five-pixel spacing. The difference between its broad luminance and an upper-flank average helps distinguish a shadow, a warm intermediate band and a highlight. The weights depend on broad RGB, local contrast and exposure. A separate red–green versus green–blue test preserves red pigment in the lips. For the opponent-color exposure weights, the region stage blends one part center RGB with three parts RGB from the most compatible local direction. A short chroma fluctuation therefore has less influence on the color decision. Actual center luminance still drives the spatial comparison. These computations have no eye or mouth coordinate inputs.

**Olive clothing.** Before the finishing passes, a bounded common RGB offset follows the signed sector-to-context luminance difference when the live color supports an olive surface. At spacing two and four, a pair of flanks that agree in all three channels can pull a small intervening color excursion toward their mean. The finishing logic checks both the source guide and the rendered green–blue difference before applying the merge.

## Verified comparison

1,747 of 2,359,296 RGB triplets matched the decoded Designer1 JPEG at the same coordinate (0.0740%). The BMP differed at 2,357,549 pixels. The resulting SHA-256 is `4a199020397ba0700c85dbaf4a627bd164d8628598f02bb749a02f38463405cc`.

| Measurement | Previous RTL | Revised RTL | Designer1 |
|---|---:|---:|---:|
| Identical RGB pixels | 1,776 | 1,747 | 2,359,296 |
| Mean absolute error per 8-bit channel | 9.979 | 9.941 | 0.000 |
| Lips and lower-face mean absolute error | 18.62 | 17.90 | 0.00 |
| Skin gap above the brighter of brow and eyelid, median over columns | 24.83 | 33.10 | 44.79 |
| Skin minus brow luminance, mean | 32.65 | 37.48 | 45.01 |
| Upper/lower lip opponent-color absolute error | 16.64 | 9.48 | 0.00 |
| Mean skin minus upper-eyelid luma | 49.72 | 50.22 | 52.59 |
| Eye row-profile absolute error | 7.78 | 7.03 | 0.00 |
| Side-hair highlight coverage (%) | 18.03 | 19.65 | 17.21 |
| Side-hair highlight overlap F1 | 0.692 | 0.685 | 1.000 |
| Second eye skin gap, median over columns | 10.26 | 17.77 | 37.07 |
| Crown highlight coverage (%) | 7.24 | 10.23 | 16.42 |
| Cheek largest connected flat area (%) | 22.35 | 17.94 | 17.29 |
| Cheek signed medium-region overlap (IoU) | 0.115 | 0.114 | 1.000 |
| Cheek tiny signed region area, % of selected surface | 0.328 | 0.210 | 0.201 |
| Forehead largest connected flat area (%) | 19.00 | 17.67 | 17.03 |
| Forehead signed medium-region overlap (IoU) | 0.159 | 0.178 | 1.000 |
| Forehead tiny signed region area, % of selected surface | 0.200 | 0.308 | 0.360 |
| Jacket collar largest connected flat area (%) | 9.45 | 11.26 | 3.74 |
| Jacket collar signed medium-region overlap (IoU) | 0.181 | 0.207 | 1.000 |
| Jacket collar tiny signed region area, % of selected surface | 0.929 | 0.760 | 1.558 |
| Whole-frame edge pixels in short fragments | 4,143 | 4,065 | 2,803 |
| Whole-frame isolated dark centers | 1,298 | 1,156 | 5,847 |

Eye profiles use display-coded RGB8 luma weighted by 0.2126, 0.7152 and 0.0722. The RTL uses (R + 2G + B)/4 for its luminance estimate. Flat areas use an eight-connected mask of pixels whose 5 × 5 per-channel range is at most four codes. Signed region overlap measures the placement of medium-size light and dark patches against the artwork. See `results/structure_summary.txt` and `structure_metrics.json` for definitions, crop coordinates and additional measurements. The comparison image shows matching coordinates across all versions.

The revised image has 4,065 edge pixels in short fragments, compared with 4,143 previously. Side-hair highlight coverage is 19.7% versus 17.2% in the artwork. The crown and the eye improve on their regional measurements, while the artwork shows longer curved hair strokes and a clearer boundary between the brow and the eye.

## RTL checks

NVC ran the complete 2048 × 1152 frame with continuous transfers and with input gaps and output backpressure. The two BMPs were byte-identical. All 2,359,296 accepted RGB10 output words matched the integer model in the stalled run. GHDL synthesized the complete 2048 × 1152 RTL to Verilog. The directed and mixed-frame checks are recorded in `results/sequence_and_synthesis.txt`. Device placement, routing, achievable clock rate and resource utilization were not measured. The Windows launcher is included for Questa/ModelSim. Its Tcl control flow was exercised on Linux with NVC executing the VHDL.

Relocated input test passed. A 512 x 384 crop starting at source (1007, 239) was decoded once from PIC1 and re-simulated with NVC as a separate, stalled AXI frame. With 80 pixels excluded along each boundary, all 78,848 interior RGB triplets reproduced their corresponding full-frame RTL outputs at a different position in the stream.

## Repeat the checks

With NVC or GHDL on PATH, these commands reproduce the stressed capture, model check and five-column crop sheet. Run the second command even when the first returns 1 for an artwork difference. SciPy is needed only for the crop measurements.

```cmd
python sim/run.py --input images/PIC1.JPG --stress --trace results/accepted.u32le
python sim/check_model.py images/PIC1.JPG results/accepted.u32le
py -3 -m pip install scipy
python sim/compare_structure.py --source images/PIC1.JPG --earlier comparison/PIC1_earlier.bmp --prior comparison/PIC1_previous.bmp --new results/PIC1_filtered.bmp --new-label "Directional surface regions" --reference reference/Designer1_PIC1_2048x1152.jpg --out results
```

Run `python sim/run.py --compare-only` to compare the saved BMP. With GHDL and a POSIX shell, `sh sim/synthesize.sh . build/synth` generates the full-size Verilog netlist.
