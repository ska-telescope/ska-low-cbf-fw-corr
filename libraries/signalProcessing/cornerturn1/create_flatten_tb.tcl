# create_flatten_tb.tcl
#
# Adds the flatten_tb simulation to the existing v80_ct1_tb Vivado project.
# That project already has MBUFGCE, DSP58, glbl and all Versal simulation
# libraries configured correctly.  The only extra piece needed here is the
# sps_flatten Xilinx FIR compiler IP (U55 reference), which does not exist
# in the V80 project by default.
#
# IP parameters are taken verbatim from corr_ct1.tcl (the U55 full project).
#
# Usage (from repo root):
#   source /tools/Xilinx/2025.1/Vitis/settings64.sh
#   vivado -mode batch -source libraries/signalProcessing/cornerturn1/create_flatten_tb.tcl

set root    [file normalize [file dirname [info script]]/../../..]
set proj    $root/build/v80_ct1_tb/v80_ct1_tb_top.xpr
set tbsrc   $root/libraries/signalProcessing/cornerturn1/flatten_tb.vhd

open_project $proj

set simset [get_filesets sim_ct1]

# ---------------------------------------------------------------------------
# Add sps_flatten FIR compiler IP if it is not already in the project.
# Parameters from corr_ct1.tcl (U55 full project).
# ---------------------------------------------------------------------------
if {[get_ips sps_flatten -quiet] eq ""} {
    create_ip -name fir_compiler -vendor xilinx.com -library ip -version 7.2 \
              -module_name sps_flatten
    set_property -dict [list \
      CONFIG.CoefficientVector \
    {0,  0, 0,    0,  0,   0,   0,   0,  0,    0,   0,    0,   0,    0,   0,     0,    0,     0,    0,     0,    0,     0,    0,     0, 65536,     0,    0,     0,    0,     0,    0,     0,    0,     0,    0,    0,   0,    0,   0,    0,  0,   0,  0,   0,  0,   0,  0,  0, 0, \
     3, -6, 10, -16, 24, -34,  46, -61, 98, -128, 173, -229, 300, -387, 488,  -621, 1881, -1705, 2110, -2498, 2861, -3172, 3411, -3562, 69172, -3562, 3411, -3172, 2861, -2498, 2110, -1705, 1881,  -621,  488, -387, 300, -229, 173, -128, 98, -61, 46, -34, 24, -16, 10, -6, 3, \
     1, -2, 4,   -7, 12, -21,  36, -51, 78, -111, 155, -213, 284, -362, 652, -1263, 1209, -1653, 1944, -2288, 2583, -2843, 3040, -3165, 68751, -3165, 3040, -2843, 2583, -2288, 1944, -1653, 1209, -1263,  652, -362, 284, -213, 155, -111, 78, -51, 36, -21, 12,  -7,  4, -2, 1} \
      CONFIG.Coefficient_Fractional_Bits {0} \
      CONFIG.Coefficient_Sets {3} \
      CONFIG.Coefficient_Sign {Signed} \
      CONFIG.Coefficient_Structure {Inferred} \
      CONFIG.Coefficient_Width {18} \
      CONFIG.Component_Name {sps_flatten} \
      CONFIG.Data_Fractional_Bits {0} \
      CONFIG.Data_Width {8} \
      CONFIG.Output_Rounding_Mode {Full_Precision} \
      CONFIG.Quantization {Integer_Coefficients} \
      CONFIG.Clock_Frequency {300.0} \
      CONFIG.Sample_Frequency {300} \
      CONFIG.Filter_Architecture {Systolic_Multiply_Accumulate} \
      CONFIG.Output_Rounding_Mode {Convergent_Rounding_to_Even} \
      CONFIG.Output_Width {16} \
      CONFIG.M_DATA_Has_TUSER {User_Field} \
      CONFIG.S_DATA_Has_TUSER {User_Field} \
    ] [get_ips sps_flatten]
    create_ip_run [get_ips sps_flatten]
    puts "Created sps_flatten IP — synthesising..."
    launch_runs sps_flatten_synth_1
    wait_on_run sps_flatten_synth_1
    generate_target simulation [get_ips sps_flatten]
    puts "sps_flatten ready."
} else {
    puts "sps_flatten IP already present."
}

# ---------------------------------------------------------------------------
# Add flatten_tb to the simulation fileset, disabling the stale ct1_v80_tb
# so its compile errors do not block the new testbench.
# ---------------------------------------------------------------------------
foreach f [get_files -of_objects $simset] {
    if {[string match "*ct1_v80_tb.vhd" $f]} {
        set_property used_in_simulation false $f
        puts "Temporarily disabled: $f"
    }
}

add_files -fileset $simset -norecurse $tbsrc
set tb_file [get_files -of_objects $simset $tbsrc]
set_property library            ct_lib $tb_file
set_property used_in_synthesis  false  $tb_file
set_property used_in_simulation true   $tb_file

set_property top     flatten_tb [get_filesets $simset]
set_property top_lib ct_lib     [get_filesets $simset]

set_property -name {xsim.simulate.runtime} -value {50us} -objects $simset

# ---------------------------------------------------------------------------
# Run impulse test (g_DATA_SELECT = 0)
# ---------------------------------------------------------------------------
set_property generic {g_DATA_SELECT=0} $simset
puts "=== Running impulse test (g_DATA_SELECT=0) ==="
launch_simulation -simset $simset
run 50us
close_sim

# ---------------------------------------------------------------------------
# Run LFSR test (g_DATA_SELECT = 1)
# ---------------------------------------------------------------------------
set_property generic {g_DATA_SELECT=1} $simset
puts "=== Running LFSR test (g_DATA_SELECT=1) ==="
launch_simulation -simset $simset
run 50us
close_sim

puts "Done."
