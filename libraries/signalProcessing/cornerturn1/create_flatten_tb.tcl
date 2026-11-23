# create_flatten_tb.tcl
#
# Builds a STANDALONE Vivado project for the flatten_tb simulation and runs both
# test modes (impulse and pseudo-random LFSR).
#
# The testbench compares the Xilinx FIR compiler IP (sps_flatten, the U55
# reference implementation) against the custom double-rate implementation
# (sps_flatten_dclk, used on the V80), so the project needs:
#   - common_lib/common_pkg      : array types used by sps_flatten_dclk
#   - ct_lib/dsp_dotproduct      : double-rate dot product DSP
#   - ct_lib/sps_flatten_dclk    : DUT
#   - dsp_macro_AxB_plusC / dsp_macro_AxB_plusPCIn : the Versal DSP macros
#                                  instantiated by sps_flatten_dclk, from
#                                  corr_ct1_v80.tcl.
#   - sps_flatten  (fir_compiler): reference DUT. Parameters are those of
#                                  corr_ct1.tcl (the U55 build) plus the TUSER
#                                  fields the testbench uses to check that the
#                                  tuser side channel is delayed by the same
#                                  number of clocks as the data.
#
# IMPORTANT - the DSP macro pipeline depth is part of the contract.
#   sps_flatten_dclk picks which dsum_delN tap feeds each DSP on each half of
#   the double-rate clock, so it is only correct for one specific DSP macro
#   input-register depth. This repo uses areg_4/breg_4/creg_4 = false (one
#   input register stage, areg_3/breg_3). ska-low-cbf-fw-pss sets those to
#   true, which adds another aclk_x2 of input latency, and its copy of
#   sps_flatten_dclk has different tap selections and an extra dsp9_hold1
#   register to match. The two are NOT interchangeable: compiling this repo's
#   sps_flatten_dclk against the PSS IP configuration (or vice versa) mis-pairs
#   taps with samples and produces a filter that is close but never equal to
#   the reference. Keep the values below in step with corr_ct1_v80.tcl.
#
# The project is built from scratch every time, in its own directory, so what
# is simulated is exactly the files on disk and exactly the IP configured here.
#
# The part is the V80 device, because sps_flatten_dclk instantiates Versal
# DSP58 macros and the testbench clocks come from an MBUFGCE.
#
# Usage (from anywhere):
#   source /tools/Xilinx/2025.1/Vivado/settings64.sh
#   vivado -mode batch -source libraries/signalProcessing/cornerturn1/create_flatten_tb.tcl
# or just run libraries/signalProcessing/cornerturn1/run_flatten_tb.sh

set script_dir [file normalize [file dirname [info script]]]
set root       [file normalize $script_dir/../../..]
set proj_dir   $root/build/corr_flatten_tb

set RLIBRARIES_PATH $root/libraries
set COMMON_PATH     $root/common/libraries

puts "Repo root    : $root"
puts "Project dir  : $proj_dir"

file mkdir $proj_dir
cd $proj_dir

create_project corr_flatten_tb $proj_dir -part xcv80-lsva4737-2MHP-e-S -force
set_property target_language VHDL [current_project]
set_property target_simulator XSim [current_project]

############################################################
# Sources
############################################################

add_files -fileset sources_1 [glob \
  $COMMON_PATH/base/common/src/vhdl/common_pkg.vhd \
]
set_property library common_lib [get_files {\
  *libraries/base/common/src/vhdl/common_pkg.vhd \
}]

add_files -fileset sources_1 [glob \
  $RLIBRARIES_PATH/signalProcessing/cornerturn1/dsp_dotproduct.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn1/sps_flatten_dclk.vhd \
]
set_property library ct_lib [get_files {\
  *libraries/signalProcessing/cornerturn1/dsp_dotproduct.vhd \
  *libraries/signalProcessing/cornerturn1/sps_flatten_dclk.vhd \
}]

############################################################
# IP
############################################################

# Versal DSP macros used by sps_flatten_dclk. Copied verbatim from
# corr_ct1_v80.tcl - see the pipeline-depth note in the header above.
create_ip -name dsp_macro -vendor xilinx.com -library ip -version 1.0 -module_name dsp_macro_AxB_plusC
set_property -dict [list \
  CONFIG.a_binarywidth {0} \
  CONFIG.a_width {9} \
  CONFIG.areg_3 {true} \
  CONFIG.areg_4 {false} \
  CONFIG.breg_3 {true} \
  CONFIG.breg_4 {false} \
  CONFIG.c_width {48} \
  CONFIG.creg_3 {true} \
  CONFIG.creg_4 {false} \
  CONFIG.creg_5 {true} \
  CONFIG.has_pcout {true} \
  CONFIG.mreg_5 {true} \
  CONFIG.p_full_width {49} \
  CONFIG.pipeline_options {Expert} \
  CONFIG.preg_6 {true} \
] [get_ips dsp_macro_AxB_plusC]
create_ip_run [get_ips dsp_macro_AxB_plusC]

create_ip -name dsp_macro -vendor xilinx.com -library ip -version 1.0 -module_name dsp_macro_AxB_plusPCIn
set_property -dict [list \
  CONFIG.a_binarywidth {0} \
  CONFIG.a_width {9} \
  CONFIG.areg_3 {true} \
  CONFIG.areg_4 {false} \
  CONFIG.b_binarywidth {0} \
  CONFIG.b_width {18} \
  CONFIG.breg_3 {true} \
  CONFIG.breg_4 {false} \
  CONFIG.c_binarywidth {0} \
  CONFIG.c_width {48} \
  CONFIG.concat_binarywidth {0} \
  CONFIG.concat_width {48} \
  CONFIG.creg_3 {false} \
  CONFIG.creg_4 {false} \
  CONFIG.creg_5 {false} \
  CONFIG.d_width {18} \
  CONFIG.has_pcout {true} \
  CONFIG.instruction1 {A*B+PCIN} \
  CONFIG.mreg_5 {true} \
  CONFIG.p_binarywidth {0} \
  CONFIG.p_full_width {58} \
  CONFIG.p_width {58} \
  CONFIG.pcin_binarywidth {0} \
  CONFIG.pipeline_options {Expert} \
  CONFIG.preg_6 {true} \
] [get_ips dsp_macro_AxB_plusPCIn]
create_ip_run [get_ips dsp_macro_AxB_plusPCIn]

# Xilinx FIR compiler reference filter. Coefficients and rounding are copied from
# corr_ct1.tcl; S_DATA/M_DATA TUSER are added so the testbench can check the tuser
# side channel as well as the data.
create_ip -name fir_compiler -vendor xilinx.com -library ip -version 7.2 -module_name sps_flatten
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

puts "Synthesising IP..."
launch_runs dsp_macro_AxB_plusC_synth_1 dsp_macro_AxB_plusPCIn_synth_1 sps_flatten_synth_1 -jobs 4
wait_on_runs dsp_macro_AxB_plusC_synth_1 dsp_macro_AxB_plusPCIn_synth_1 sps_flatten_synth_1
puts "IP ready."

############################################################
# Testbench
############################################################

add_files -fileset sim_1 [glob $RLIBRARIES_PATH/signalProcessing/cornerturn1/flatten_tb.vhd]
set_property library ct_lib [get_files *libraries/signalProcessing/cornerturn1/flatten_tb.vhd]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

set simset [get_filesets sim_1]
set_property top     flatten_tb $simset
set_property top_lib ct_lib     $simset

# One launch_simulation of 100 us per mode. flatten_tb prints its PASS/FAIL
# summary at g_REPORT_US, which must be inside that window.
set_property -name {xsim.simulate.runtime} -value {100us} -objects $simset

############################################################
# Run impulse test (g_DATA_SELECT = 0)
############################################################
set_property generic {g_DATA_SELECT=0 g_REPORT_US=98} $simset
puts "=== Running impulse test (g_DATA_SELECT=0) ==="
launch_simulation -simset $simset
close_sim

############################################################
# Run LFSR test (g_DATA_SELECT = 1)
############################################################
set_property generic {g_DATA_SELECT=1 g_REPORT_US=98} $simset
puts "=== Running LFSR test (g_DATA_SELECT=1) ==="
launch_simulation -simset $simset
close_sim

puts "Done."
