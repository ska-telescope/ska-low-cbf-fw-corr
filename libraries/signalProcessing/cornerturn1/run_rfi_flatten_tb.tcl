# run_rfi_flatten_tb.tcl
# Runs rfi_flatten_tb in the existing v80_ct1_tb Vivado project.
#
# The existing ct1_v80_tb.vhd has stale port connections that cause compile
# errors; we temporarily disable it from simulation, add rfi_flatten_tb.vhd,
# run, then restore everything.
#
# Usage (from repo root):
#   source /tools/Xilinx/2025.1/Vitis/settings64.sh
#   vivado -mode batch -source libraries/signalProcessing/cornerturn1/run_rfi_flatten_tb.tcl

set root  [file normalize [file dirname [info script]]/../../..]
set proj  $root/build/v80_ct1_tb/v80_ct1_tb_top.xpr
set tbsrc $root/libraries/signalProcessing/cornerturn1/rfi_flatten_tb.vhd

open_project $proj

set simset [get_filesets sim_ct1]

# Disable all existing simulation-top files that have compile errors so they
# don't block building rfi_flatten_tb.
foreach f [get_files -of_objects $simset] {
    if {[string match "*ct1_v80_tb.vhd" $f]} {
        set_property used_in_simulation false $f
        puts "Disabled: $f"
    }
}

# Add rfi_flatten_tb to the fileset.
add_files -fileset $simset -norecurse $tbsrc
set tb_file [get_files -of_objects $simset $tbsrc]
set_property library            ct_lib $tb_file
set_property used_in_synthesis  false  $tb_file
set_property used_in_simulation true   $tb_file

# Point simulation at the new top.
set_property top     rfi_flatten_tb [get_filesets $simset]
set_property top_lib ct_lib         [get_filesets $simset]

# Compile and run.
launch_simulation -simset $simset
run 25us
close_sim

puts "Done."
