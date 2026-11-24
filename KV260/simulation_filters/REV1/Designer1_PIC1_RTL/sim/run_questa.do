# Invoked by run.cmd from the directory containing rtl, images, and results.
# ModelSim's "do" command supplies its first macro argument as the variable 1.
proc portrait_python {} {
    if {$::tcl_platform(platform) eq "windows"} {
        set candidates {{py -3} {python} {python3}}
    } else {
        set candidates {{python3} {python}}
    }
    foreach candidate $candidates {
        if {[auto_execok [lindex $candidate 0]] ne "" &&
            ![catch {exec {*}$candidate -c {import sys, PIL, numpy; assert sys.version_info >= (3,8)}}]} {
            return $candidate
        }
    }
    error {Python 3 with Pillow and NumPy is required. Install with: py -3 -m pip install pillow numpy}
}

proc portrait_simulate {root source default_image smoke scratch_var loaded_var} {
    upvar 1 $scratch_var scratch $loaded_var loaded
    if {![file exists $source]} {
        if {[file pathtype $source] eq "relative" && [file exists [file join $root images $source]]} {
            set source [file join $root images $source]
        } else {
            error "Input image does not exist: $source"
        }
    }
    set source [file normalize $source]
    set python [portrait_python]
    set io [file join $root sim questa_io.py]
    set stem [file rootname [file tail $source]]
    if {$smoke} {append stem "_smoke"}
    set result_dir [file join $root results]
    file mkdir $result_dir
    set out [file join $result_dir "${stem}_filtered.bmp"]
    set log [file join $result_dir "${stem}_filtered_simulation.log"]
    transcript file $log
    transcript on
    # Use a new directory so stale bytes or an old compiled design cannot pass a failed run.
    set scratch [string trim [exec {*}$python -c {import tempfile; print(tempfile.mkdtemp(prefix="portrait-questa-"))}]]
    set prepare_args {}
    if {$smoke} {set prepare_args [list --smoke]}
    set dims [string trim [exec {*}$python $io prepare $source $scratch {*}$prepare_args]]
    if {![regexp {^([1-9][0-9]*) ([1-9][0-9]*)$} $dims _ width height]} {
        error "Unexpected decoder response: $dims"
    }
    set ref [file join $root reference "Designer1_${stem}_${width}x${height}.jpg"]
    if {$default_image && !$smoke} {
        set ref [file join $root reference Designer1_PIC1_2048x1152.jpg]
        if {![file isfile $ref]} {error "Missing reference image: $ref"}
    }
    set ref_args {}
    if {!$smoke && [file isfile $ref]} {set ref_args [list --reference $ref]}
    puts "Input: $source ($width x $height)"
    cd $scratch
    vmap -c
    set ini [file join $scratch modelsim.ini]
    vlib work
    vmap -modelsimini $ini work [file join $scratch work]
    set manifest [open [file join $root rtl files.f] r]
    set entries [split [read $manifest] "\n"]
    close $manifest
    foreach entry $entries {
        set filename [string trim [lindex [split $entry "#"] 0]]
        if {$filename ne ""} {vcom -modelsimini $ini -2008 -work work [file join $root rtl $filename]}
    }
    vcom -modelsimini $ini -2008 -work work [file join $root sim tb_axis_portrait_filter.vhd]
    puts "LOAD START $width x $height. Transcript: $log"
    flush stdout
    set load_start [clock seconds]
    vsim -modelsimini $ini -onfinish stop -gG_WIDTH=$width -gG_HEIGHT=$height \
        -gG_SHIFT=true -gG_RETURN_TO_TCL=true work.tb_axis_portrait_filter
    set loaded 1
    puts "LOAD COMPLETE after [expr {[clock seconds]-$load_start}] seconds. Starting clock."
    flush stdout
    # Severity 'error' or 'failure' stops the test. A verified test closes and
    # marks its capture before the gated testbench clock stops naturally.
    set ::BreakOnAssertion 2
    run -all
    if {![file exists [file join $scratch axis.passed]]} {error "AXI simulation did not pass"}
    set status [catch {exec {*}$python $io capture $scratch $out $log {*}$ref_args 2>@1} msg info]
    if {$status} {
        set code [dict get $info -errorcode]
        if {[lindex $code 0] eq "CHILDSTATUS" && [lindex $code 2] == 1} {
            # Tcl appends this generic line to a nonzero child exit. The Python
            # output above it gives the exact mismatch count.
            regsub {\nchild process exited abnormally$} $msg {} msg
            puts $msg
            return 1
        }
        error "Capture or verification failed: $msg"
    }
    if {$msg ne ""} {puts $msg}
    return 0
}

set portrait_root [file normalize [pwd]]
set portrait_default [expr {![info exists 1] || [set 1] eq ""}]
set portrait_smoke [expr {!$portrait_default && [string equal -nocase [set 1] smoke]}]
if {$portrait_default || $portrait_smoke} {
    set portrait_source [file join $portrait_root images PIC1.JPG]
} else {
    set portrait_source [set 1]
}
set portrait_scratch ""
set portrait_loaded 0
onerror {quit -force -code 2}
onbreak {quit -force -code 2}
if {[catch {portrait_simulate $portrait_root $portrait_source $portrait_default $portrait_smoke portrait_scratch portrait_loaded} portrait_status]} {
    puts stderr "Simulation error: $portrait_status"
    set portrait_status 2
}
if {$portrait_loaded} {catch {quit -sim}}
cd $portrait_root
if {$portrait_scratch ne ""} {catch {file delete -force $portrait_scratch}}
quit -force -code $portrait_status
