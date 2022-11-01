set time_raw [clock seconds];
set date_string [clock format $time_raw -format "%y%m%d_%H%M%S"]

set proj_dir "$env(RADIOHDL)/build/$env(PERSONALITY)/$env(PERSONALITY)_$env(TARGET_ALVEO)_build_$date_string"
set ARGS_PATH "$env(RADIOHDL)/build/ARGS/correlator"
set DESIGN_PATH "$env(RADIOHDL)/designs/$env(PERSONALITY)"
set RLIBRARIES_PATH "$env(RADIOHDL)/libraries"
set COMMON_PATH "$env(RADIOHDL)/common/libraries"
set DEVICE "xcu55c-fsvh2892-2L-e"
set BOARD "xilinx.com:au55c:part0:1.0"

puts "RADIOHDL directory:"
puts $env(RADIOHDL)

puts "Timeslave IP in submodule"
# RADIOHDL is ENV_VAR for current project REPO. 
set timeslave_repo "$env(RADIOHDL)/pub-timeslave/hw/cores"

# Create the new build directory
puts "Creating build_directory $proj_dir"
file mkdir $proj_dir

# This script sets the project variables
puts "Creating new project: correlator"
cd $proj_dir

set workingDir [pwd]
puts "Working directory:"
puts $workingDir

# WARNING - proj_dir must be relative to workingDir.
# But cannot be empty because args generates tcl with the directory specified as "$proj_dir/"
set proj_dir "../$env(PERSONALITY)_$env(TARGET_ALVEO)_build_$date_string"

create_project $env(PERSONALITY) -part $DEVICE -force
set_property board_part $BOARD [current_project]
set_property target_language VHDL [current_project]
set_property target_simulator XSim [current_project]

############################################################
# Board specific files
############################################################

############################################################
# Timeslave files
############################################################
set_property  ip_repo_paths  $timeslave_repo [current_project]
update_ip_catalog

# only generate this if u55.

# generate_ref design - Instance 1 - U55C TOP PORT.
source $COMMON_PATH/ptp/src/genBD_timeslave.tcl

make_wrapper -files [get_files $workingDir/$env(PERSONALITY).srcs/sources_1/bd/ts/ts.bd] -top
add_files -norecurse $workingDir/$env(PERSONALITY).gen/sources_1/bd/ts/hdl/ts_wrapper.vhd

add_files -fileset sources_1 [glob \
 $COMMON_PATH/ptp/src/CMAC_100G_wrap_w_timeslave.vhd \
]
set_property library Timeslave_CMAC_lib [get_files {\
 */src/CMAC_100G_wrap_w_timeslave.vhd \
}]

add_files -fileset sources_1 [glob \
 $ARGS_PATH/CMAC/cmac/CMAC_cmac_reg_pkg.vhd \
 $ARGS_PATH/CMAC/cmac/CMAC_cmac_reg.vhd \
 $ARGS_PATH/Timeslave/timeslave/Timeslave_timeslave_reg_pkg.vhd \
 $ARGS_PATH/Timeslave/timeslave/Timeslave_timeslave_reg.vhd \
]
set_property library Timeslave_CMAC_lib [get_files {\
 *CMAC/cmac/CMAC_cmac_reg_pkg.vhd \
 *CMAC/cmac/CMAC_cmac_reg.vhd \
 */Timeslave/timeslave/Timeslave_timeslave_reg_pkg.vhd \
 */Timeslave/timeslave/Timeslave_timeslave_reg.vhd \ 
}]

############################################################
# ARGS generated files
############################################################

# This script uses the construct $workingDir/$proj_dir
# So $proj_dir must be relative to $workingDir
# 
source $ARGS_PATH/correlator_bd.tcl

add_files -fileset sources_1 [glob \
$ARGS_PATH/correlator_bus_pkg.vhd \
$ARGS_PATH/correlator_bus_top.vhd \
$ARGS_PATH/correlator/system/correlator_system_reg_pkg.vhd \
$ARGS_PATH/correlator/system/correlator_system_reg.vhd \
]
set_property library correlator_lib [get_files {\
*build/ARGS/correlator/correlator_bus_pkg.vhd \
*build/ARGS/correlator/correlator_bus_top.vhd \
*build/ARGS/correlator/correlator/system/correlator_system_reg_pkg.vhd \
*build/ARGS/correlator/correlator/system/correlator_system_reg.vhd \
}]

############################################################
# Design specific files
############################################################

# verilog version replaced with vhdl version due to problem with black box generation in IP packaging ($DESIGN_PATH/src/verilog/krnl_control_s_axi.v) 

add_files -fileset sources_1 [glob \
$DESIGN_PATH/src/vhdl/u55c/correlator.vhd \
$DESIGN_PATH/src/vhdl/correlator_core.vhd \
$DESIGN_PATH/src/vhdl/cdma_wrapper.vhd \
$DESIGN_PATH/src/vhdl/mac_100g_wrapper.vhd \
$DESIGN_PATH/src/vhdl/krnl_control_axi.vhd \
$DESIGN_PATH/src/vhdl/version_pkg.vhd \ 
]

add_files -fileset sim_1 [glob \
$DESIGN_PATH/src/vhdl/tb_correlatorCore.vhd \
$DESIGN_PATH/src/vhdl/lbus_packet_receive.vhd \
$DESIGN_PATH/src/vhdl/HBM_axi_tbModel.vhd \
]

set_property library correlator_lib [get_files {\
*correlator/src/vhdl/u55c/correlator.vhd \
*correlator/src/vhdl/correlator_core.vhd \
*correlator/src/vhdl/cdma_wrapper.vhd \
*correlator/src/vhdl/mac_100g_wrapper.vhd \
*correlator/src/vhdl/krnl_control_axi.vhd \
*correlator/src/vhdl/tb_correlatorCore.vhd \
*correlator/src/vhdl/lbus_packet_receive.vhd \
*correlator/src/vhdl/HBM_axi_tbModel.vhd \
*correlator/src/vhdl/version_pkg.vhd \
}]

set_property file_type {VHDL 2008} [get_files  $DESIGN_PATH/src/vhdl/u55c/correlator.vhd]
set_property file_type {VHDL 2008} [get_files  $DESIGN_PATH/src/vhdl/correlator_core.vhd]
set_property file_type {VHDL 2008} [get_files  $DESIGN_PATH/src/vhdl/HBM_axi_tbModel.vhd]
#add_files -fileset constrs_1 [ glob $DESIGN_PATH/vivado/vcu128_gemini_dsp.xdc ]

# top level testbench
set_property top tb_correlatorCore [get_filesets sim_1]

# vivado_xci_files: Importing IP to the project
# tcl scripts for ip generation
source $DESIGN_PATH/src/ip/vitisAccelCore.tcl
############################################################

# Technology select package
add_files -fileset sources_1 [glob \
 $RLIBRARIES_PATH/technology/technology_pkg.vhd \
 $RLIBRARIES_PATH/technology/technology_select_pkg.vhd \
 $RLIBRARIES_PATH/technology/mac_100g/tech_mac_100g_pkg.vhd \
]
set_property library technology_lib [get_files {\
 *libraries/technology/technology_pkg.vhd \
 *libraries/technology/technology_select_pkg.vhd \
 *libraries/technology/mac_100g/tech_mac_100g_pkg.vhd \
}]
#############################################################
## IN THE COMMON FILES REPO
# Common

add_files -fileset sources_1 [glob \
 $COMMON_PATH/base/common/src/vhdl/common_reg_r_w.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_reg_r_w_dc.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_pkg.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_str_pkg.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_mem_pkg.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_field_pkg.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_lfsr_sequences_pkg.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_interface_layers_pkg.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_network_layers_pkg.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_network_total_header_pkg.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_components_pkg.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_spulse.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_switch.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_delay.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_ram_crw_crw.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_pipeline.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_count_saturate.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_accumulate.vhd \
]
set_property library common_lib [get_files {\
 *libraries/base/common/src/vhdl/common_reg_r_w.vhd \
 *libraries/base/common/src/vhdl/common_reg_r_w_dc.vhd \
 *libraries/base/common/src/vhdl/common_pkg.vhd \
 *libraries/base/common/src/vhdl/common_str_pkg.vhd \
 *libraries/base/common/src/vhdl/common_mem_pkg.vhd \
 *libraries/base/common/src/vhdl/common_field_pkg.vhd \
 *libraries/base/common/src/vhdl/common_lfsr_sequences_pkg.vhd \
 *libraries/base/common/src/vhdl/common_interface_layers_pkg.vhd \
 *libraries/base/common/src/vhdl/common_network_layers_pkg.vhd \
 *libraries/base/common/src/vhdl/common_network_total_header_pkg.vhd \
 *libraries/base/common/src/vhdl/common_components_pkg.vhd \
 *libraries/base/common/src/vhdl/common_spulse.vhd \
 *libraries/base/common/src/vhdl/common_switch.vhd \
 *libraries/base/common/src/vhdl/common_delay.vhd \
 *libraries/base/common/src/vhdl/common_ram_crw_crw.vhd \
 *libraries/base/common/src/vhdl/common_pipeline.vhd \
 *libraries/base/common/src/vhdl/common_count_saturate.vhd \
 *libraries/base/common/src/vhdl/common_accumulate.vhd \
}]

# AXI4

add_files -fileset sources_1 [glob \
$COMMON_PATH/base/axi4/src/vhdl/axi4_lite_pkg.vhd \
$COMMON_PATH/base/axi4/src/vhdl/axi4_full_pkg.vhd \
$COMMON_PATH/base/axi4/src/vhdl/axi4_stream_pkg.vhd \
$COMMON_PATH/base/axi4/src/vhdl/mem_to_axi4_lite.vhd \
]
set_property library axi4_lib [get_files {\
*libraries/base/axi4/src/vhdl/axi4_lite_pkg.vhd \
*libraries/base/axi4/src/vhdl/axi4_full_pkg.vhd \
*libraries/base/axi4/src/vhdl/axi4_stream_pkg.vhd \
*libraries/base/axi4/src/vhdl/mem_to_axi4_lite.vhd \
}]


#############################################################
# tech memory
# (Used by ARGs)
add_files -fileset sources_1 [glob \
 $RLIBRARIES_PATH/technology/memory/tech_memory_component_pkg.vhd \
 $RLIBRARIES_PATH/technology/memory/tech_memory_ram_cr_cw.vhd \
 $RLIBRARIES_PATH/technology/memory/tech_memory_ram_crw_crw.vhd \
]
set_property library tech_memory_lib [get_files {\
 *libraries/technology/memory/tech_memory_component_pkg.vhd \
 *libraries/technology/memory/tech_memory_ram_cr_cw.vhd \
 *libraries/technology/memory/tech_memory_ram_crw_crw.vhd \
}]

#############################################################
# 100G LFAA decode

add_files -fileset sources_1 [glob \
 $ARGS_PATH/LFAADecode100G/lfaadecode100g/LFAADecode100G_lfaadecode100g_reg_pkg.vhd \
 $ARGS_PATH/LFAADecode100G/lfaadecode100g/LFAADecode100G_lfaadecode100g_reg.vhd \
 $ARGS_PATH/LFAADecode100G/lfaadecode100g/LFAADecode100G_lfaadecode100g_vcstats_ram.vhd \
 $RLIBRARIES_PATH/signalProcessing/LFAADecode100G/src/vhdl/LFAADecodeTop100G.vhd \
 $RLIBRARIES_PATH/signalProcessing/LFAADecode100G/src/vhdl/LFAAProcess100G.vhd \
]
set_property library LFAADecode100G_lib [get_files {\
 *build/ARGS/correlator/LFAADecode100G/lfaadecode100g/LFAADecode100G_lfaadecode100g_reg_pkg.vhd \
 *build/ARGS/correlator/LFAADecode100G/lfaadecode100g/LFAADecode100G_lfaadecode100g_reg.vhd \
 *build/ARGS/correlator/LFAADecode100G/lfaadecode100g/LFAADecode100G_lfaadecode100g_vcstats_ram.vhd \
 *libraries/signalProcessing/LFAADecode100G/src/vhdl/LFAADecodeTop100G.vhd \
 *libraries/signalProcessing/LFAADecode100G/src/vhdl/LFAAProcess100G.vhd \
}]
# test_bench_files
#add_files -fileset sim_1 [glob \
# $RLIBRARIES_PATH/signalProcessing/LFAADecode100G/tb/tb_LFAADecode100G.vhd \
#]
#set_property library LFAADecode100G_lib [get_files {\
# *libraries/signalProcessing/LFAADecode/tb/tb_LFAADecode100G.vhd \
#}]

# tcl scripts for ip generation
source $ARGS_PATH/LFAADecode100G/lfaadecode100g/ip_LFAADecode100G_lfaadecode100g_vcstats_ram.tcl

#############################################################
# Timing Control
add_files -fileset sources_1 [glob \
 $ARGS_PATH/timingControlA/timingcontrola/timingControlA_timingcontrola_reg_pkg.vhd \
 $ARGS_PATH/timingControlA/timingcontrola/timingControlA_timingcontrola_reg.vhd \
 $RLIBRARIES_PATH/signalProcessing/timingControl/src/vhdl/timing_control_atomic.vhd \
]
set_property library timingControl_lib [get_files {\
 *build/ARGS/correlator/timingControlA/timingcontrola/timingControlA_timingcontrola_reg_pkg.vhd \
 *build/ARGS/correlator/timingControlA/timingcontrola/timingControlA_timingcontrola_reg.vhd \
 *libraries/signalProcessing/timingControl/src/vhdl/timing_control_atomic.vhd \
}]

## tcl scripts for ip generation
#source $RLIBRARIES_PATH/signalProcessing/timingControl/ptpclk125.tcl

#############################################################
# PSR Packetiser
# $ARGS_PATH/Packetiser/packetiser/Packetiser_packetiser_param_ram.vhd \
#  *build/ARGS/correlator/Packetiser/packetiser/Packetiser_packetiser_param_ram.vhd \

add_files -fileset sources_1 [glob \
 $ARGS_PATH/Packetiser/packetiser/Packetiser_packetiser_reg_pkg.vhd \
 $ARGS_PATH/Packetiser/packetiser/Packetiser_packetiser_reg.vhd \
 $RLIBRARIES_PATH/signalProcessing/Packetiser100G/src/vhdl/ethernet_pkg.vhd \
 $RLIBRARIES_PATH/signalProcessing/Packetiser100G/src/vhdl/cbfpsrheader_pkg.vhd \
 $RLIBRARIES_PATH/signalProcessing/Packetiser100G/src/vhdl/packet_former.vhd \
 $RLIBRARIES_PATH/signalProcessing/Packetiser100G/src/vhdl/packetiser100G_Top.vhd \
 $RLIBRARIES_PATH/signalProcessing/Packetiser100G/src/vhdl/adder_32_int.vhd \
 $RLIBRARIES_PATH/signalProcessing/Packetiser100G/src/vhdl/packet_player.vhd \
 $RLIBRARIES_PATH/signalProcessing/Packetiser100G/src/vhdl/xpm_fifo_wrapper.vhd \
 $RLIBRARIES_PATH/signalProcessing/Packetiser100G/src/vhdl/test_packet_data_gen.vhd \
 $RLIBRARIES_PATH/signalProcessing/Packetiser100G/src/vhdl/stream_config_wrapper.vhd \
 $RLIBRARIES_PATH/signalProcessing/Packetiser100G/src/vhdl/cmac_args.vhd \
 $RLIBRARIES_PATH/signalProcessing/Packetiser100G/src/vhdl/packet_length_check.vhd \
 $RLIBRARIES_PATH/signalProcessing/Packetiser100G/src/vhdl/packet_former_correlator.vhd \
 $RLIBRARIES_PATH/signalProcessing/Packetiser100G/src/vhdl/packet_length_check_correlator.vhd \
]
set_property library PSR_Packetiser_lib [get_files {\
 *build/ARGS/correlator/Packetiser/packetiser/Packetiser_packetiser_reg_pkg.vhd \
 *build/ARGS/correlator/Packetiser/packetiser/Packetiser_packetiser_reg.vhd \
 *libraries/signalProcessing/Packetiser100G/src/vhdl/ethernet_pkg.vhd \
 *libraries/signalProcessing/Packetiser100G/src/vhdl/cbfpsrheader_pkg.vhd \
 *libraries/signalProcessing/Packetiser100G/src/vhdl/packet_former.vhd \
 *libraries/signalProcessing/Packetiser100G/src/vhdl/packetiser100G_Top.vhd \
 *libraries/signalProcessing/Packetiser100G/src/vhdl/adder_32_int.vhd \
 *libraries/signalProcessing/Packetiser100G/src/vhdl/packet_player.vhd \
 *libraries/signalProcessing/Packetiser100G/src/vhdl/xpm_fifo_wrapper.vhd \
 *libraries/signalProcessing/Packetiser100G/src/vhdl/test_packet_data_gen.vhd \
 *libraries/signalProcessing/Packetiser100G/src/vhdl/stream_config_wrapper.vhd \
 *libraries/signalProcessing/Packetiser100G/src/vhdl/cmac_args.vhd \
 *libraries/signalProcessing/Packetiser100G/src/vhdl/packet_length_check.vhd \ 
 *libraries/signalProcessing/Packetiser100G/src/vhdl/packet_former_correlator.vhd \
 *libraries/signalProcessing/Packetiser100G/src/vhdl/packet_length_check_correlator.vhd \
}]

## tcl scripts for ip generation
source $ARGS_PATH/Packetiser/packetiser/ip_Packetiser_packetiser_param_ram.tcl
source $RLIBRARIES_PATH/signalProcessing/Packetiser100G/src/vhdl/packetiser100G.tcl

#############################################################
# DRP
#  ?? used to include $ARGS_PATH/DRP/drp/DRP_drp_cmac_data_ram.vhd \ but doesn't look like it is used ?
add_files -fileset sources_1 [glob \
 $ARGS_PATH/DRP/drp/DRP_drp_reg_pkg.vhd \
 $ARGS_PATH/DRP/drp/DRP_drp_reg.vhd \
]
set_property library DRP_lib [get_files {\
 *build/ARGS/correlator/DRP/drp/DRP_drp_reg_pkg.vhd \
 *build/ARGS/correlator/DRP/drp/DRP_drp_reg.vhd \
}]

## tcl scripts for ip generation
#source $ARGS_PATH/DRP/drp/ip_DRP_drp_cmac_data_ram.tcl

#############################################################
# Signal_processing_common
add_files -fileset sources_1 [glob \
 $COMMON_PATH/common/src/vhdl/sync.vhd \
 $COMMON_PATH/common/src/vhdl/sync_vector.vhd \
 $COMMON_PATH/common/src/vhdl/s_axi_to_lbus.vhd \
]
set_property library signal_processing_common [get_files {\
 */common/src/vhdl/sync.vhd \
 */common/src/vhdl/sync_vector.vhd \
 */common/src/vhdl/s_axi_to_lbus.vhd \
}]

set_property file_type {VHDL 2008} [get_files  $COMMON_PATH/common/src/vhdl/s_axi_to_lbus.vhd]

#############################################################
# 1st corner turn, between LFAA ingest and filterbanks

add_files -fileset sources_1 [glob \
  $ARGS_PATH/corr_ct1/corr_ct1/corr_ct1_reg_pkg.vhd \
  $ARGS_PATH/corr_ct1/corr_ct1/corr_ct1_reg.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn1/corr_ct1_readout.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn1/corr_ct1_readout_32bit.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn1/corr_ct1_valid.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn1/corr_ct1_top.vhd \
]
set_property library ct_lib [get_files {\
 *build/ARGS/correlator/corr_ct1/corr_ct1/corr_ct1_reg_pkg.vhd \
 *build/ARGS/correlator/corr_ct1/corr_ct1/corr_ct1_reg.vhd \
 *libraries/signalProcessing/cornerturn1/corr_ct1_readout.vhd \
 *libraries/signalProcessing/cornerturn1/corr_ct1_readout_32bit.vhd \
 *libraries/signalProcessing/cornerturn1/corr_ct1_valid.vhd \
 *libraries/signalProcessing/cornerturn1/corr_ct1_top.vhd \
}]

source $RLIBRARIES_PATH/signalProcessing/cornerturn1/corr_ct1.tcl

#############################################################
# output corner turn (between filterbanks and correlator)

add_files -fileset sources_1 [glob \
  $ARGS_PATH/corr_ct2/corr_ct2/corr_ct2_reg_pkg.vhd \
  $ARGS_PATH/corr_ct2/corr_ct2/corr_ct2_reg.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn2/corr_ct2_top.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn2/corr_ct2_din.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn2/corr_ct2_dout.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn2/ones_count6.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn2/ones_count16.vhd \
]

set_property library ct_lib [get_files {\
 *build/ARGS/correlator/corr_ct2/corr_ct2/corr_ct2_reg_pkg.vhd \
 *build/ARGS/correlator/corr_ct2/corr_ct2/corr_ct2_reg.vhd \
 *libraries/signalProcessing/cornerturn2/corr_ct2_top.vhd \
 *libraries/signalProcessing/cornerturn2/corr_ct2_din.vhd \
 *libraries/signalProcessing/cornerturn2/corr_ct2_dout.vhd \
 *libraries/signalProcessing/cornerturn2/ones_count6.vhd \
 *libraries/signalProcessing/cornerturn2/ones_count16.vhd \
}]

set_property file_type {VHDL 2008} [get_files  $RLIBRARIES_PATH/signalProcessing/cornerturn2/corr_ct2_din.vhd]
set_property file_type {VHDL 2008} [get_files  $RLIBRARIES_PATH/signalProcessing/cornerturn2/corr_ct2_top.vhd]


#############################################################
## Correlator filterbank and fine delay

add_files -fileset sources_1 [glob \
  $ARGS_PATH/cor_filterbanks/filterbanks/cor_filterbanks_filterbanks_reg_pkg.vhd \
  $ARGS_PATH/cor_filterbanks/filterbanks/cor_filterbanks_filterbanks_reg.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/FB_top_correlator.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/correlatorFBTop25.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/correlatorFBMem.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/URAMWrapper.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/ShiftandRound.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/fb_DSP25.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/correlatorFFT25wrapper.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/fineDelay.vhd \
]

set_property library filterbanks_lib [get_files {\
  *build/ARGS/correlator/cor_filterbanks/filterbanks/cor_filterbanks_filterbanks_reg_pkg.vhd \
  *build/ARGS/correlator/cor_filterbanks/filterbanks/cor_filterbanks_filterbanks_reg.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/FB_top_correlator.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/correlatorFBTop25.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/correlatorFBMem.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/URAMWrapper.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/ShiftandRound.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/fb_DSP25.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/correlatorFFT25wrapper.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/fineDelay.vhd \
}]

source $RLIBRARIES_PATH/signalProcessing/filterbanks/src/ip/dspAxB.tcl
source $RLIBRARIES_PATH/signalProcessing/filterbanks/src/ip/CorFB_FFT.tcl
source $RLIBRARIES_PATH/signalProcessing/filterbanks/src/ip/CorFB_roms.tcl
source $RLIBRARIES_PATH/signalProcessing/filterbanks/src/ip/fineDelay.tcl

#############################################################
## Correlator
add_files -fileset sources_1 [glob \
  $ARGS_PATH/cor/config/cor_config_reg_pkg.vhd \
  $ARGS_PATH/cor/config/cor_config_reg.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/correlator_top.vhd \
]

set_property library correlator_lib [get_files {\
  *build/ARGS/correlator/cor/config/cor_config_reg_pkg.vhd \
  *build/ARGS/correlator/cor/config/cor_config_reg.vhd \
  *libraries/signalProcessing/correlator/correlator_top.vhd \
}]


#############################################################
# signal processing Top level

add_files -fileset sources_1 [glob \
 $RLIBRARIES_PATH/signalProcessing/DSP_top/src/vhdl/DSP_top_correlator.vhd \
 $RLIBRARIES_PATH/signalProcessing/DSP_top/src/vhdl/DSP_top_pkg.vhd \
]
set_property library DSP_top_lib [get_files  {\
 *libraries/signalProcessing/DSP_top/src/vhdl/DSP_top_correlator.vhd \
 *libraries/signalProcessing/DSP_top/src/vhdl/DSP_top_pkg.vhd \
}]

set_property file_type {VHDL 2008} [get_files  *libraries/signalProcessing/DSP_top/src/vhdl/DSP_top_correlator.vhd]

##############################################################
# Set top
add_files -fileset constrs_1 -norecurse $RLIBRARIES_PATH/../designs/correlator/src/scripts/vitisAccelCoreCon.xdc
set_property PROCESSING_ORDER LATE [get_files vitisAccelCoreCon.xdc]

set_property -name {xsim.compile.xvlog.more_options} -value {-d SIM_SPEED_UP} -objects [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

set_property top correlator [current_fileset]
update_compile_order -fileset sources_1

