# PIC1 live contour reconstruction

## Windows simulation

Extract the complete project and open Command Prompt in the folder containing `run.cmd`. Use a VHDL-2008 Questa or ModelSim installation with `vsim`, `vcom`, `vlib` and `vmap` on PATH. The host reads and compares images using Python 3.8 or later, Pillow and NumPy.

```cmd
py -3 -m pip install pillow numpy
run.cmd
```

The launcher reads `images/PIC1.JPG`, compiles the manifest in `rtl/files.f` and captures accepted output pixels into `results/PIC1_filtered.bmp`. It compares all three RGB8 channels at each coordinate with the decoded pixels of `reference/Designer1_PIC1_2048x1152.jpg`. The transcript and the comparison JSON are in `results`. To simulate another image, run `run.cmd "path\to\photo.jpg"`. A corresponding reference can be supplied as `reference/Designer1_<stem>_<width>x<height>.jpg`.

| Exit code | Meaning |
|---|---|
| 0 | The AXI simulation passed and every pixel matched the supplied reference. With a custom image that has no reference, the capture succeeded. |
| 1 | The simulation passed and the BMP was written. One or more RGB triplets differed from the reference. |
| 2 | Image preparation, HDL compilation, simulation or capture failed. |

## Live pixel computation

The supplied Rev159 Word guide describes the multi-scale surface filter and its raster interface. The stylizer PDFs and the latest image notes informed the use of independent surface and contour measurements.

The input is 32-bit AXI4-Stream RGB10 with R in [29:20], G in [19:10] and B in [9:0]. The core uses the high eight bits per channel. It packs each output lane as the eight-bit result followed by its two high bits. `TUSER` marks frame start and `TLAST` marks line end. Active dimensions default to 2048 × 1152 and can be set at elaboration. The sender must honor `TREADY` during normal transfers and border flushing.

| Stage | Computation from incoming pixels |
|---|---|
| Surface and context | Two three-tap range-gated passes suppress small noise. A separate 2- and 6-pixel directional measurement guides a 9 × 9 Kuwahara-style sector selector. Its four 5 × 5 quadrants supply local RGB color. Spacing-16 passes supply surrounding color. |
| Base tone | The surface, surrounding luminance, live channel differences and positive/negative directional evidence drive the local tone and existing 16-code band spacing. Range-limited finishing at spacings 1, 2 and 4 preserves moderate transitions. |
| Stroke seeds | Sample the finished luminance on two 3 × 3 stencils with spacings 3 and 12. For horizontal, vertical and both diagonal tangents, compare the center strip with both flanks. A step needs the same gradient polarity at both scales. Tangential variation reduces its score. A dark groove below both flanks at both scales supplies an independent seed. Each orientation keeps six bits. |
| Across the stroke | Compare the directional seed with the two seeds three pixels away along its normal. A peak survives. A stronger neighboring peak attenuates the center. |
| Along the stroke | For each orientation, look three pixels in both tangent directions. A seed needs support from at least one neighbor. Two supporting neighbors can bridge a weak center by up to eight seed codes. The strongest of the four linked scores controls coverage. |
| Medium regions | Find the median luminance of nine live RGB samples at spacing 3 and choose an actual RGB triplet carrying that luminance. The center wins ties. Blend toward that color when the RGB difference is moderate. Preserve more of a well-supported stroke. The measured yellow-green chroma permits stronger consolidation in jacket-like regions. |
| Ink and highlights | A dead band suppresses weak evidence. Above it, the ink gain increases in successive ranges, with a ceiling. Surface-to-surround difference and local exposure control which side receives ink. A small 3 × 3 coverage filter smooths the ink mask. The composite removes more red than blue on qualified dark strokes and can lift the brighter side of a shadow. |
| Output | Remove a moderate single-pixel excursion when all four axial neighbors agree. Frame markers and RGB stay aligned and stable under backpressure. |

The stencil and center memories hold a rolling history of the incoming frame. The HDL uses the same arithmetic and thresholds at every coordinate. The designer JPEG and the two previous BMPs are inputs to comparison software. The spatial settings were selected on PIC1. Local orientation support can connect short gaps. It cannot reconstruct a strand or feature that follows a different path in the artwork.

## Verified comparison

**2,214 of 2,359,296 RGB pixels matched (0.0938%).** The reference differed at 2,357,082 coordinates.

| Whole-frame metric | Filtered (4) | Filtered (5) | Linked contours |
|---|---:|---:|---:|
| Exact RGB pixels | 928 | 2,130 | 2,214 |
| RGB mean absolute channel error | 10.729 | 10.428 | 10.559 |
| RGB PSNR (dB) | 22.762 | 22.804 | 22.486 |
| Edge precision | 0.575 | 0.525 | 0.534 |
| Edge recall | 0.345 | 0.477 | 0.515 |
| Edge F1 | 0.431 | 0.500 | 0.524 |
| Connected contour F1 | 0.364 | 0.454 | 0.472 |

The edge metrics use thinned Sobel edges at the original coordinates and a two-pixel match tolerance. Connected contour F1 further restricts each image to eight-connected components containing at least 24 edge centers. Flat area is the fraction of 5 × 5 neighborhoods spanning at most four codes in every channel. The twelve-crop sheet and the full measurement definitions are in `results`.

| Region | Edge F1 (5) | Edge F1 new | Connected F1 (5) | Connected F1 new | Flat % (5) | Flat % new | Flat % Designer1 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Whole frame | 0.500 | 0.524 | 0.454 | 0.472 | 62.65 | 63.01 | 55.39 |
| Eye and brow | 0.523 | 0.591 | 0.428 | 0.514 | 17.48 | 16.92 | 19.86 |
| Upper hair | 0.477 | 0.533 | 0.365 | 0.419 | 32.94 | 34.85 | 21.76 |
| Forehead | 0.307 | 0.392 | 0.100 | 0.331 | 64.63 | 66.79 | 51.46 |
| Ear | 0.584 | 0.600 | 0.525 | 0.552 | 21.42 | 20.93 | 20.23 |
| Nose and nostrils | 0.472 | 0.517 | 0.462 | 0.506 | 23.70 | 25.14 | 34.43 |
| Lips and lower face | 0.256 | 0.346 | 0.162 | 0.269 | 16.21 | 14.79 | 17.54 |
| Hair highlights | 0.352 | 0.421 | 0.226 | 0.262 | 45.51 | 47.08 | 29.22 |
| Cheek | 0.226 | 0.271 | 0.225 | 0.204 | 64.05 | 66.48 | 57.21 |
| Jacket collar | 0.388 | 0.428 | 0.358 | 0.390 | 10.77 | 15.04 | 18.75 |
| Jaw and chin | 0.284 | 0.285 | 0.121 | 0.172 | 33.47 | 32.63 | 38.57 |
| Chair logo | 0.768 | 0.781 | 0.762 | 0.768 | 50.46 | 52.86 | 53.80 |
| Background | 0.000 | 0.000 | 0.000 | 0.000 | 89.12 | 88.90 | 92.99 |

The eyes and mouth retain the photographic geometry. The artwork has a more distinct iris and eyelid, longer blue hair strokes and larger contiguous color patches at the collar. Extra interior lines are still visible across the nose.

NVC accepted 2,359,296 input and output transfers in 2,853,072 testbench cycles. The test inserted 208,555 source-gap cycles and counted 311,859 stalled output cycles. Every accepted 32-bit word matched the independent integer model. The continuous simulation through the launcher Tcl produced a byte-identical BMP. GHDL performed generic synthesis at 2048 × 1152. Device utilization and post-route timing require a board-specific implementation.

## Repeat the checks

With NVC or GHDL on PATH, these commands reproduce the stressed capture, model check and five-column crop sheet. Run the second command even when the first returns 1 for an artwork difference. SciPy is needed only for the crop measurements.

```cmd
python sim/run.py --input images/PIC1.JPG --stress --trace results/accepted.u32le
python sim/check_model.py images/PIC1.JPG results/accepted.u32le
py -3 -m pip install scipy
python sim/compare_structure.py --source images/PIC1.JPG --earlier comparison/PIC1_earlier.bmp --prior comparison/PIC1_previous.bmp --new results/PIC1_filtered.bmp --new-label "Linked contours" --reference reference/Designer1_PIC1_2048x1152.jpg --out results
```

Run `python sim/run.py --compare-only` to recheck the saved BMP. With GHDL and a POSIX shell, `sh sim/synthesize.sh . build/synth` generates Verilog. The delivered synthesis and two-frame checks are summarized in `results/sequence_and_synthesis.txt`. The launcher Tcl also ran in a path containing spaces with NVC executing the simulator commands. Native Windows Questa was unavailable.
