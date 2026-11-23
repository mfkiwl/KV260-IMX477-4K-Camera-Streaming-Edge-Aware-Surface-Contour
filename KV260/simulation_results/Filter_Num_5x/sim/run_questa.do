# Run from Filter_Num_5 with: vsim -c -do sim/run_questa.do
# Optional: vsim -c -do "do sim/run_questa.do images/PIC2.JPG results/PIC2_filtered.bmp"
onerror {quit -code 1}
if {![file exists sim/sources.txt]} {
    cd [file normalize [file join [file dirname [info script]] ..]]
}
if {![file exists sim/sources.txt]} {
    echo "Start Questa from the extracted Filter_Num_5 directory."
    quit -code 1
}
set input images/PIC3.JPG
if {[info exists 1]} {set input [set 1]}
set stem [file rootname [file tail $input]]
set output [file join results "${stem}_filtered.bmp"]
if {[info exists 2]} {set output [set 2]}
set decoded [file join build "${stem}_decoded.bmp"]
if {[file normalize $input] eq [file normalize $output] ||
    [file normalize $input] eq [file normalize $decoded] ||
    [file normalize $output] eq [file normalize $decoded]} {
    echo "The input JPEG, decoder dump and filtered BMP require distinct paths."
    quit -code 1
}
file mkdir build [file dirname $output]
set lib [file normalize build/questa_filter5_aligned]
if {![file isdirectory $lib]} {vlib $lib}
vmap work $lib
set fd [open sim/sources.txt r]
set sources [split [string trim [read $fd]] "\n"]
close $fd
foreach src $sources {
    vcom -2008 -work work [string trim $src]
}
if {[auto_execok python] ne ""} {
    set py [list python]
} elseif {[auto_execok py] ne ""} {
    set py [list py -3]
} elseif {[auto_execok python3] ne ""} {
    set py [list python3]
} else {
    echo "Python 3, NumPy and Pillow are required for the geometry regression."
    quit -code 2
}
# Read source dimensions for elaboration. All stimulus pixels are decoded by VHDL.
set dimensions [exec {*}$py -c {from PIL import Image; import sys; im=Image.open(sys.argv[1]); print(*im.size)} $input]
lassign $dimensions width height
vsim -onfinish stop -voptargs=+acc -gG_STALLS=true -gG_DESIGNER_VIEW=true -gG_DESIGNER1=true \
    -gG_PORTRAIT_FRAMING=false -gG_WIDTH=$width -gG_HEIGHT=$height \
    -gG_INPUT=$input -gG_OUTPUT=$output -gG_DECODED_BMP=$decoded work.tb_pic2
set BreakOnAssertion 2
run -all
if {[string trim [examine -radix binary sim:/tb_pic2/capture_complete] "'"] ne "1"} {
    echo "FAIL: testbench did not complete"
    quit -code 1
}
# Independently calculate the Filter 5 RGB value at every source coordinate.
set status [catch {exec {*}$py tools/check_pixels.py $decoded $output --designer1 --jpeg $input 2>@1} message options]
echo $message
if {$status} {
    set reason [dict get $options -errorcode]
    if {[lindex $reason 0] eq "CHILDSTATUS"} {quit -code [lindex $reason 2]}
    quit -code 2
}
quit -code 0
