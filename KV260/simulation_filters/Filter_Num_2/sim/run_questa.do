# From the project root run vsim -c -do sim/run_questa.do, or use run.cmd.
onerror {quit -code 1}
if {![file exists sim/sources.txt]} {
    cd [file normalize [file join [file dirname [info script]] ..]]
}

proc stream_byte {fd} {
    if {[binary scan [read $fd 1] c value] != 1} {error "Truncated JPEG header"}
    return [expr {$value & 255}]
}

proc jpeg_dimensions {name} {
    set fd [open $name rb]
    if {[stream_byte $fd] != 255 || [stream_byte $fd] != 216} {close $fd; error "Invalid JPEG header"}
    while {[stream_byte $fd] == 255} {
        set tag [stream_byte $fd]
        while {$tag == 255} {set tag [stream_byte $fd]}
        if {$tag == 217 || $tag == 218} {break}
        set length [expr {256*[stream_byte $fd]+[stream_byte $fd]}]
        if {$length < 2} {break}
        if {$tag == 192} {
            set bits [stream_byte $fd]
            set height [expr {256*[stream_byte $fd]+[stream_byte $fd]}]
            set width [expr {256*[stream_byte $fd]+[stream_byte $fd]}]
            close $fd
            if {$bits != 8 || $width < 1 || $height < 1} {error "Unsupported JPEG dimensions or precision"}
            return [list $width $height]
        }
        seek $fd [expr {$length-2}] current
    }
    close $fd
    error "Expected an 8-bit baseline JPEG"
}

set name PIC99
if {[info exists env(PIC2_INPUT)] && $env(PIC2_INPUT) ne ""} {set name $env(PIC2_INPUT)}
set source $name
if {![file isfile $source]} {
    set source ""
    set stem [file rootname [file tail $name]]
    foreach candidate [glob -nocomplain -directory images *] {
        if {[string equal -nocase [file rootname [file tail $candidate]] $stem] &&
            [string tolower [file extension $candidate]] in {.jpg .jpeg}} {
            set source $candidate
            break
        }
    }
}
if {![file isfile $source]} {error "Input JPEG not found: $name"}
lassign [jpeg_dimensions $source] width height
set stem [file rootname [file tail $source]]
set legacy false
if {[info exists env(PIC2_PROFILE)] && $env(PIC2_PROFILE) ne ""} {
    if {![string equal -nocase $env(PIC2_PROFILE) legacy]} {error "Use legacy to select the original PIC2 grade"}
    set legacy true
}
set output [file join results "${stem}.bmp"]
if {$legacy} {set output [file join results "${stem}_filtered.bmp"]}

file mkdir build results
set lib [file normalize build/questa]
if {![file isdirectory $lib]} {vlib $lib}
if {![file exists modelsim.ini]} {vmap -c}
vmap work $lib
set fd [open sim/sources.txt r]
set sources [split [string trim [read $fd]] "\n"]
close $fd
foreach src $sources {vcom -2008 -work work [string trim $src]}
vsim -onfinish stop -voptargs=+acc -gG_STALLS=true -gG_RGB10_WRAPPER=true \
    -gG_INPUT=$source -gG_OUTPUT=$output -gG_WIDTH=$width -gG_HEIGHT=$height -gG_LEGACY_PIC2=$legacy work.tb_pic2
set BreakOnAssertion 2
run -all
if {[string trim [examine -radix binary sim:/tb_pic2/test_passed] "'"] ne "1"} {
    echo "FAIL: testbench did not complete"
    quit -code 1
}
echo "PASS: $output"
quit -code 0
