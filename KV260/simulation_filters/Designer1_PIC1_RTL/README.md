# Live edge-aware surface and contour filter

## Run on Windows

Extract the complete ZIP. In the project directory that contains `run.cmd`, open Command Prompt with your licensed Questa or ModelSim VHDL-2008 installation on PATH. The launcher uses `vsim`, `vcom`, `vlib` and `vmap`. Image decoding and comparison use Python 3.8 or later, Pillow and NumPy. Install the Python packages once if needed.

```cmd
py -3 -m pip install pillow numpy
run.cmd
```

The included `run.cmd` is byte-identical to the uploaded launcher. Its target, `sim/run_questa.do`, creates a temporary simulation library, compiles `rtl/files.f` in order, streams `images/PIC1.JPG` through the DUT, and captures `results/PIC1_filtered.bmp`. The testbench writes pixels only on accepted master transfers. The host then compares the saved BMP with the decoded `reference/Designer1_PIC1_2048x1152.jpg`.

**Expected result on the supplied frame:** the AXI test passes, the BMP is saved, and the artwork equality check returns **1**. The strict check returns **0** when every RGB triplet matches. Code **2** reports a processing, simulation or verification error. The transcript and JSON comparison appear alongside the BMP. If the terminal cannot find `vsim`, open a simulator command prompt or add the directory containing `vsim.exe` to PATH.

To run another source, pass its path, with quotes around paths containing spaces.

```cmd
run.cmd "images\PIC2.JPG"
```

This writes `results/PIC2_filtered.bmp` when PIC2.JPG is supplied. To score a different scene, place its reference in `reference/` with the name `Designer1_<input stem>_<width>x<height>.jpg`. Without that reference the launcher saves the new capture and returns success after the AXI checks.

## Design

The synthesizable top is `axis_portrait_filter`. It computes its output from the input frame. The hardware contains no trained projection, coefficient image, pixel lookup palette, or K-means stage. Every arithmetic operation below is applied across the entire raster. The scalar design settings control distance, smoothing, exposure and tint. The photograph/reference pair was used to select among hand-designed alternatives, and the accuracy below applies to this frame.

| Stage | Calculation on live pixels |
|---|---|
| AXI input | Accept a pixel on a rising edge with TVALID and TREADY high. R10, G10 and B10 occupy bits 29–20, 19–10 and 9–0. The filter uses the upper eight bits of each lane internally. G_WIDTH and G_HEIGHT give the active raster dimensions and default to 2048 and 1152. |
| Edge-aware smoothing | Use horizontal and vertical three-tap passes at spacings 1, 2, 4 and 8. A neighbor contributes when its maximum channel difference from the center is within the scale's threshold. A rejected or missing tap takes the center value. The center has double weight. |
| Broad neighborhood | Compute a second centered horizontal/vertical average at spacing 16. Carry the smoothed center and AXI markers with the neighborhood through both passes. |
| Local contrast and color | Compute luma and channel differences from both the center and neighborhood. Blend chroma most strongly where their lumas agree. Emphasize warm red and yellow regions, tint low-chroma shadows teal, and compress highlights with scalar arithmetic. |
| Contour and shading | Darken the center if its broad neighborhood is sufficiently brighter. Blend a rounded luma value with continuous luma to soften color bands. Chroma stays continuous. |
| AXI output | Clamp RGB to eight bits and expand each channel to ten by repeating its two high bits. Hold the data and SOF/EOL markers together under backpressure. |

The input must supply correctly framed raster video and honor `s_axis_tready` during internal border processing. Frame coordinates address the delayed stream samples. Line stores contain incoming pixels.

## Verification against Designer1

| Full-frame comparison | Result |
|---|---:|
| Exact RGB matches | 967 / 2,359,296 (0.0410%) |
| Pixels that differ | 2,358,329 |
| All three channels within 5 codes of the reference | 477,574 (20.24%) |
| Mean absolute channel error | 10.8507 / 255 |
| Maximum absolute channel error | 224 / 255 |
| RGB PSNR | 22.9316 dB |

At pixel (0, 0), measured from the top left, the simulated RGB value was (6, 49, 59) and the artwork value was (25, 57, 68). The side-by-side PNG shows the input, output and reference with a registered eye crop. The output preserves the photograph's eye geometry and has softer eyebrows than the illustrated reference.

NVC ran the full VHDL frame with source gaps and sink backpressure. Every accepted 32-bit stream word was independently checked. GHDL performed generic synthesis. Windows Questa was unavailable here. The launcher Tcl flow was exercised with NVC standing in for the simulator commands. FPGA utilization and post-route timing require a Vivado implementation.

## Alternative simulation and independent checks

With NVC or GHDL on PATH, the following commands run the packaged arithmetic independently of the Questa launcher. Execute the second command after the expected exit code 1 from the first.

```cmd
python sim/run.py --input images/PIC1.JPG --stress --trace results/accepted.u32le
python sim/check_model.py images/PIC1.JPG results/accepted.u32le
```

To rescore the delivered BMP without running a simulator, use `python sim/run.py --compare-only`. The full-frame JSON includes input, output and reference hashes as well as channel errors. On a system with a POSIX shell and GHDL, `sh sim/synthesize.sh . build/synth` reproduces the synthesis check. The included PIC1.JPG and PIC1.bmp decode to identical RGB pixels with the recorded decoder.
