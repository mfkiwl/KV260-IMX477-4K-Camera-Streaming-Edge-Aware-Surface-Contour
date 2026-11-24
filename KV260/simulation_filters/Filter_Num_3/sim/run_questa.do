# From the pic2_axis folder: vsim -c -do sim/run_questa.do
onerror {quit -code 1}
set profile 3
set jpeg PIC1
if {[info exists ::env(DESIGNER_PROFILE)]} {set profile $::env(DESIGNER_PROFILE)}
if {[info exists ::env(DESIGNER_INPUT)]} {set jpeg $::env(DESIGNER_INPUT)}
if {$profile ni {2 3}} {error "DESIGNER_PROFILE must be 2 or 3"}
if {[file extension $jpeg] eq "" && [file dirname $jpeg] eq "."} {set jpeg [file join images ${jpeg}.JPG]}
set stem [file rootname [file tail $jpeg]]
if {![file isfile $jpeg]} {error "JPEG does not exist: $jpeg"}
if {[auto_execok python] ne ""} {
    set py [list python]
} elseif {[auto_execok py] ne ""} {
    set py [list py -3]
} else {
    set py [list python3]
}
lassign [exec {*}$py -c {import sys; from PIL import Image; print(*Image.open(sys.argv[1]).size)} $jpeg] width height
if {$profile eq "2" && ($width != 2048 || $height != 1152)} {error "Profile 2 artwork framing requires a 2048 x 1152 input"}
file mkdir build results
set lib [file normalize build/questa]
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory $lib]} {vlib $lib}
vmap work $lib
set handle [open sim/sources.txt r]
set files [split [string trim [read $handle]] "\n"]
close $handle
foreach file $files {vcom -2008 -work work [string trim $file]}
set bmp results/${stem}_filtered.bmp
if {$profile eq "2"} {set bmp results/${stem}_filtered_Designer2.bmp}
set decoded build/${stem}_decoded_${profile}.bmp
transcript file results/${stem}_profile${profile}_questa.log
vsim -onfinish stop -gG_STALLS=true -gG_DESIGNER_VIEW=true -gG_PROFILE=$profile -gG_WIDTH=$width -gG_HEIGHT=$height -gG_INPUT=$jpeg -gG_OUTPUT=$bmp -gG_DECODED_BMP=$decoded -voptargs=+acc work.tb_pic2
set BreakOnAssertion 2
run -all
if {[string trim [examine -radix binary sim:/tb_pic2/capture_complete] "'"] ne "1"} {
    echo "FAIL: incomplete AXI frame"
    quit -code 1
}
set check [list {*}$py tools/check_designer.py --profile $profile --decoded $decoded --actual $bmp]
set pic1 [expr {[file normalize $jpeg] eq [file normalize images/PIC1.JPG]}]
if {$pic1 && $profile eq "3"} {lappend check --golden reference/PIC1_filtered.bmp}
set failed [catch {exec {*}$check 2>@1} message]
echo $message
if {$failed} {quit -code 1}
if {$pic1} {
    set failed [catch {exec {*}$py sim/compare.py $bmp images/Designer${profile}.jpg 2>@1} message]
    echo $message
    if {$failed} {quit -code 1}
}
quit -code 0
