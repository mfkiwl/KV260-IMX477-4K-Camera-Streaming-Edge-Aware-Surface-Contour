# PIC1 medium-scale surface segmentation

## Windows simulation

If Questa 2024.1 reports `vcom-1576` at line 63 of `portrait_region_axis.vhd`, replace `rtl/portrait_region_axis.vhd` with the copy in this project. It names the local variable `structure_strength`. Run `run.cmd smoke` from the project folder, then `run.cmd` for PIC1.

Extract the complete project and open Command Prompt in the folder containing `run.cmd`. Use a VHDL-2008 Questa or ModelSim installation with `vsim`, `vcom`, `vlib` and `vmap` on PATH. The host reads and compares images using Python 3.8 or later, Pillow and NumPy.

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

## Live RGB10 data path

The source stream carries R[29:20], G[19:10] and B[9:0]. The filter processes the high eight bits of each channel. Each output lane repeats its top two bits in the low positions. The core transfers pixels on `TVALID` and `TREADY`, with `TUSER` marking frame start and `TLAST` marking line end.

| Signal | Formation and use |
|---|---|
| Surface color S | Two range-gated three-tap passes remove fine noise. A 9 × 9 sector selector estimates the center's region color from four overlapping 5 × 5 quadrants. A second branch supplies broad RGB context from horizontal and vertical three-tap passes at 16-pixel spacing. |
| Medium structure M | Compare S to that broad context in luminance, R−G and G−B. A bounded structure weight controls how much surrounding color can pull the local luminance toward its own band. It also controls the contribution of intermediate luminance bands. Warm midtones and dark regions use this information to separate neighboring surfaces. |
| Contour E | An independent classifier measures directional light and dark structure. Later, directional agreement on finished luminance qualifies strong contour seeds at spacings 3 and 6. The strong threshold is 18. Nearby seeds contribute coverage and the darkest supported flank supplies the shadow color. Changing the surface can change where this classifier fires. |
| Band placement | The base luminance band is 16 codes wide. M can admit an intermediate eight-code band. On bright warm surfaces the rounded broad-context exposure supplies a further correction of up to four codes. In neutral shadows the signed surface-to-context difference controls the local shadow level. |
| Region consolidation | Existing neighborhoods at radii 2 and 5 provide eight neighbors each. Clip each neighbor's luminance difference from the center to ±14, subtract the two neighborhood means and halve the bounded result. Apply the correction with live warm- and cool-color weights. A locally unsupported dark center can borrow the median neighbor color. |
| Final warm surfaces | Repair isolated axial excursions first. On a warm pixel above luminance 80, when the four axial neighbors span at most 32 codes and stay within 32 codes of the center, blend 6/16 toward their RGB mean. The last stage reuses the existing line buffers. |
| Output | Clamp all channels to RGB8 and repack them into the AXI4-Stream RGB10 output word. |

All weights come from scalar arithmetic on the current camera stream. The same logic runs at every coordinate. The source JPEG, previous captures and Designer1 artwork are host-side simulation assets. PIC1 was used to select the scalar settings.

## Measured results

The strict decoded-RGB comparison found **1,952 exact pixels out of 2,359,296 (0.0827%)**. 2,357,344 pixels differed.

| Whole frame | Previous directional RTL | This RTL | Designer1 |
|---|---:|---:|---:|
| Exact RGB pixels | 1,945 | 1,952 | 2,359,296 |
| Mean absolute RGB channel error | 10.465 | 10.326 | 0.000 |
| Edge centers in short fragments | 4,667 | 4,790 | 2,803 |
| Isolated dark pixels | 1,832 | 1,873 | 5,847 |
| Connected-contour F1 | 0.418 | 0.444 | 1.000 |
| 12-pixel surface-transition F1 | 0.379 | 0.407 | 1.000 |

| Region | Largest flat area % previous / new / reference | Medium flat areas previous / new / reference | RGB channel MAE previous / new |
|---|---:|---:|---:|
| Eye and brow | 6.1 / 4.6 / 4.3 | 23 / 20 / 36 | 17.49 / 16.30 |
| Upper hair | 9.9 / 7.4 / 4.3 | 15 / 20 / 29 | 14.27 / 13.66 |
| Hair highlights | 21.1 / 14.8 / 8.5 | 16 / 20 / 22 | 13.43 / 13.10 |
| Forehead | 37.1 / 31.0 / 17.0 | 8 / 9 / 20 | 8.67 / 8.47 |
| Cheek | 57.0 / 24.1 / 17.3 | 9 / 16 / 18 | 6.55 / 6.59 |
| Jacket collar | 14.5 / 14.4 / 3.7 | 34 / 24 / 51 | 11.91 / 11.83 |
| Lips and lower face | 3.3 / 0.7 / 3.2 | 22 / 32 / 51 | 17.48 / 17.61 |
| Nose and nostrils | 10.1 / 5.6 / 4.5 | 15 / 24 / 40 | 15.57 / 15.50 |
| Ear | 7.5 / 7.5 / 8.4 | 16 / 18 / 30 | 19.89 / 19.91 |


Each detail crop contains 320 × 176 pixels at identical coordinates. A pixel belongs to a flat interior if all three channels vary by at most four codes in its 5 × 5 neighborhood. Medium flat areas are eight-connected components of 32 to 1,024 such pixels. They measure region fragmentation and merging. The detail sheet allows direct inspection of shape and placement. The JSON report defines the contour and 12-pixel transition measurements.

All 2,359,296 accepted output words from the stressed NVC simulation matched the independent RGB10 integer model. Continuous input produced a byte-identical BMP. GHDL synthesized the VHDL at the full raster width. Device resource utilization and post-route timing require implementation for a specific FPGA.
 
## Repeat the checks

With NVC or GHDL on PATH, these commands reproduce the stressed capture, model check and five-column crop sheet. Run the second command even when the first returns 1 for an artwork difference. SciPy is needed only for the crop measurements.

```cmd
python sim/run.py --input images/PIC1.JPG --stress --trace results/accepted.u32le
python sim/check_model.py images/PIC1.JPG results/accepted.u32le
py -3 -m pip install scipy
python sim/compare_structure.py --source images/PIC1.JPG --earlier comparison/PIC1_earlier.bmp --prior comparison/PIC1_previous.bmp --new results/PIC1_filtered.bmp --new-label "Medium-scale surfaces" --reference reference/Designer1_PIC1_2048x1152.jpg --out results
```

Run `python sim/run.py --compare-only` to recheck the saved BMP. With GHDL and a POSIX shell, `sh sim/synthesize.sh . build/synth` generates Verilog. The delivered synthesis and two-frame checks are summarized in `results/sequence_and_synthesis.txt`. The launcher Tcl also ran in a path containing spaces with NVC executing the simulator commands. Native Windows Questa was unavailable.
