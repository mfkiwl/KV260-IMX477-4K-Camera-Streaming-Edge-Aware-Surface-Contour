# Designer1 RGB10 AXI4-Stream portrait filter

`results/PIC1.bmp` is the 2048 × 1152 capture from `tb_pic1`. The exact comparison with the decoded Designer1 artwork fails. The measured pixel counts and channel errors are in `results/pixel_comparison.txt`. The output retains the eye and hair geometry of the input photograph, while the reference contains drawn contours in those regions.

## Run the simulation

Use Python 3 with NumPy and Pillow, and NVC or GHDL with VHDL-2008 support. From the extracted project directory run the following command. The launcher prefers NVC if it is on `PATH` and can also be directed with `--sim ghdl` or `--sim nvc`.

```sh
python sim/run.py --check-model --require-exact
```

The VHDL testbench opens `images/PIC1.JPG`, decodes the JPEG, drives the AXI slave, and writes `results/PIC1.bmp` from accepted master transfers. The launcher uses the JPEG header to set the frame dimensions. With `--check-model`, it also checks every 30-bit output word against an independent NumPy raster implementation. `--require-exact` gives a nonzero exit status when even one RGB8 pixel differs from the artwork. The captured BMP is written before the comparison. Run `python sim/run.py --check-model` to use the AXI and arithmetic checks as the exit criterion and still print the artwork comparison.

For an existing Questa installation, the package includes a VHDL-only simulation script. Run it from the project directory. The commands verified in this release used NVC and GHDL.

```sh
vsim -c -do sim/questa.do
python sim/compare.py results/PIC1.bmp images/Designer1_PIC1_2048x1152.jpg
```

For another baseline JPEG use `python sim/run.py --input images/other.JPG --output results/other.bmp`. Add `--reference path/to/reference.jpg` to compare against another target. Use `--no-stalls` for a continuously ready sink. `sim/sources.txt` gives the VHDL compilation order. The JPEG reader and BMP writer can be used without Python in a VHDL simulator.

## FPGA interface

The synthesis top is `designer1_axis_rgb10` in `rtl/designer1_axis_rgb10.vhd`. Analyze the `rtl/` entries of the manifest for synthesis. Set `FRAME_WIDTH` and `FRAME_HEIGHT` to the active video dimensions before synthesis. They default to 2048 and 1152. The reset, `aresetn`, is synchronous and active low. The first accepted pixel after reset must carry SOF to start processing.

| Port or parameter | Behavior |
|---|---|
| `s_axis_tdata`, `m_axis_tdata` | R10 occupies bits 29–20, G10 bits 19–10, and B10 bits 9–0. `DATA_WIDTH` defaults to 32. Higher output bits are zero. |
| `tvalid`, `tready` | A rising edge transfers one pixel when both are high. An output stall holds the valid pixel, SOF and EOL stable. |
| `tuser` | One pulse on the first accepted pixel of each frame. |
| `tlast` | One pulse on the last accepted pixel of each active line. |
| `PIXEL_RAM_STYLE` | The large packed pixel delay has a `ram_style` attribute. The default is `"auto"`. |

The input must provide correctly marked raster-order frames of the configured size and honor `s_axis_tready`. The core uses line storage and accepts successive frames. It deasserts input ready while generating border samples and draining a frame. The color arithmetic uses all ten input bits. For the supplied 8-bit JPEG stimulus the testbench places each byte in bits 9–2 of its color lane. The BMP contains the upper eight bits of each accepted output lane.

## Processing stages

| RTL module | Operation |
|---|---|
| `portrait_sdp_ram` | Synchronous one-read, one-write memory used by the pixel delay, tile accumulators and line windows. |
| `portrait_tile_context` | Computes mean RGB and horizontal texture in 4 × 4, 16 × 16 and 64 × 64 tiles. Four neighboring tile values are interpolated at each pixel. Gradient features describe local luminance and red-minus-green changes. Partial tiles use their actual sample counts. |
| `designer1_axis_rgb10` | Aligns the original pixel with the three spatial scales, builds 27 features, and adds the predicted RGB correction to the finest interpolated color. The spatial feature extractor uses 98 rows of lookahead. |
| `portrait_projection` and `portrait_coefficients` | Three pipelined fixed-point affine projections with 48 and 24 rectified hidden units and three signed output corrections. One coefficient set is shared across the image and across frames. |
| `portrait_range_smooth` | Four range-weighted 3 × 3 passes sample neighbors at distances of 1, 4, 8 and 20 pixels. Similar colors contribute more to the average. Neighbor contributions decrease at color and luminance boundaries. Each pass replicates its frame borders. |

The coefficients were fitted offline using samples from the supplied PIC1/reference pair. Every output color is calculated from the current video. The design uses neither palette mapping nor K-means. The reference JPEG is used for offline calibration and scoring. It is outside the testbench stimulus path and the synthesizable design.

## Verification scope

The self-checking testbench tests input gaps and downstream backpressure, validates the positions of SOF and EOL, and checks for extra or missing output beats and stability during stalls. `results/verification.txt` records the final simulator and synthesis results. Synthesis was checked with GHDL. Vivado implementation, KV260 resource use, post-route clock timing and physical camera throughput have yet to be measured.
