# Run from a shell with: vsim -c -do sim/questa.do
onerror {quit -code 1}
set root [file normalize [file join [file dirname [info script]] ..]]
set build [file join $root build questa]
file mkdir $build
file mkdir [file join $root results]
cd $build
if {![file exists work]} {vlib work}
vmap work [file join $build work]
set manifest [open [file join $root sim sources.txt] r]
while {[gets $manifest path] >= 0} {
    if {[string trim $path] ne ""} {vcom -2008 -work work [file join $root $path]}
}
close $manifest
set pic [file join $root images PIC2.JPG]
set bmp [file join $root results PIC2.bmp]
vsim -onfinish exit -gG_INPUT=$pic -gG_OUTPUT=$bmp work.tb_pic1
run -all
