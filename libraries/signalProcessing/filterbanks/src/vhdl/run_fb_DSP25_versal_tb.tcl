# run_fb_DSP25_versal_tb.tcl
#
# Adds fb_DSP25_versal_tb to the existing v80_ct1_tb project and runs it.
# The project already has fb_DSP25_versal, DSP_AxB_versal, DSP_AxB_plus_PCIN_versal,
# MBUFGCE and all Versal simulation libraries set up.
#
# fb_DSP25.vhd is added here since it is not in the V80 project by default
# (only the dummy version is).  On a Versal target fb_DSP25 uses the same
# DSP_AxB_versal IPs as fb_DSP25_versal, so the comparison is meaningful.
#
# Usage (from repo root):
#   source /tools/Xilinx/2025.1/Vitis/settings64.sh
#   vivado -mode batch -source libraries/signalProcessing/filterbanks/src/vhdl/run_fb_DSP25_versal_tb.tcl

set root  [file normalize [file dirname [info script]]/../../../../..]
set proj  $root/build/v80_ct1_tb/v80_ct1_tb_top.xpr
set fbsrc $root/libraries/signalProcessing/filterbanks/src/vhdl
set tbsrc $fbsrc/fb_DSP25_versal_tb.vhd
set fb25  $fbsrc/fb_DSP25.vhd

open_project $proj

set simset [get_filesets sim_ct1]

# ---------------------------------------------------------------------------
# Add fb_DSP25.vhd to the design sources if not already present.
# The V80 project normally uses fb_DSP25_dummy; we need the real version so
# the reference filter performs an actual computation.
# ---------------------------------------------------------------------------
if {[get_files $fb25 -quiet] eq ""} {
    add_files -norecurse $fb25
    set_property library filterbanks_lib [get_files $fb25]
    puts "Added fb_DSP25.vhd to filterbanks_lib"
} else {
    puts "fb_DSP25.vhd already in project"
}
# Ensure the dummy is disabled in simulation (it may be auto-disabled already)
foreach f [get_files *fb_DSP25_dummy.vhd -quiet] {
    set_property used_in_simulation false $f
}

# ---------------------------------------------------------------------------
# Add testbench to sim_ct1, disabling the stale ct1_v80_tb so its errors
# don't block compilation.
# ---------------------------------------------------------------------------
foreach f [get_files -of_objects $simset] {
    if {[string match "*ct1_v80_tb.vhd" $f]} {
        set_property used_in_simulation false $f
    }
}

if {[get_files -of_objects $simset $tbsrc -quiet] eq ""} {
    add_files -fileset $simset -norecurse $tbsrc
}
set tb_file [get_files -of_objects $simset $tbsrc]
set_property library            filterbanks_lib $tb_file
set_property used_in_synthesis  false           $tb_file
set_property used_in_simulation true            $tb_file

set_property top     fb_DSP25_versal_tb [get_filesets $simset]
set_property top_lib filterbanks_lib    [get_filesets $simset]
set_property generic {}                 [get_filesets $simset]

set_property -name {xsim.simulate.runtime} -value {50us} -objects $simset

puts "=== Running fb_DSP25_versal_tb ==="
launch_simulation -simset $simset
run 50us
close_sim

puts "Done."
