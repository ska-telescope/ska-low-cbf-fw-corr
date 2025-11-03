set time_raw [clock seconds];
set date_string [clock format $time_raw -format "%y%m%d_%H%M%S"]

set proj_dir "$env(RADIOHDL)/build/$env(PERSONALITY)/$env(PERSONALITY)_$env(TARGET_ALVEO)_build_$date_string"
set ARGS_PATH "$env(RADIOHDL)/build/ARGS/correlator"
set DESIGN_PATH "$env(RADIOHDL)/designs/$env(PERSONALITY)"
set RLIBRARIES_PATH "$env(RADIOHDL)/libraries"
set COMMON_PATH "$env(RADIOHDL)/common/libraries"
set BUILD_PATH "$env(RADIOHDL)/build"
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

  # generate Timeslave BD - Instance 1 - U55C TOP PORT.
  # based on Vitis version.
  if { $env(VITIS_VERSION) == "2021.2" } {
    source $COMMON_PATH/ptp/src/genBD_timeslave.tcl
  } else {
    # 2022.2
    source $COMMON_PATH/ptp/src/ts_$env(VITIS_VERSION).tcl
  }

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

# removed $DESIGN_PATH/src/vhdl/mac_100g_wrapper.vhd, now uses timeslave wrapper

# verilog version replaced with vhdl version due to problem with black box generation in IP packaging ($DESIGN_PATH/src/verilog/krnl_control_s_axi.v) 

add_files -fileset sources_1 [glob \
$DESIGN_PATH/src/vhdl/u55c/correlator.vhd \
$DESIGN_PATH/src/vhdl/correlator_core.vhd \
$DESIGN_PATH/src/vhdl/cdma_wrapper.vhd \
$DESIGN_PATH/src/vhdl/krnl_control_axi.vhd \
$DESIGN_PATH/src/vhdl/version_pkg.vhd \
$DESIGN_PATH/src/vhdl/target_fpga_pkg.vhd \
$COMMON_PATH/hbm_axi_reset_handler/hbm_axi_reset_handler.vhd \
$COMMON_PATH/hbm_axi_reset_handler/eth_disable.vhd \
$BUILD_PATH/build_details_pkg.vhd \
]

add_files -fileset sim_1 [glob \
$DESIGN_PATH/src/vhdl/tb_correlatorCore.vhd \
$DESIGN_PATH/src/vhdl/HBM_axi_tbModel.vhd \
]

set_property library correlator_lib [get_files {\
*correlator/src/vhdl/u55c/correlator.vhd \
*correlator/src/vhdl/correlator_core.vhd \
*correlator/src/vhdl/cdma_wrapper.vhd \
*correlator/src/vhdl/krnl_control_axi.vhd \
*correlator/src/vhdl/tb_correlatorCore.vhd \
*correlator/src/vhdl/lbus_packet_receive.vhd \
*correlator/src/vhdl/HBM_axi_tbModel.vhd \
*correlator/src/vhdl/version_pkg.vhd \
*hbm_axi_reset_handler/hbm_axi_reset_handler.vhd \
*hbm_axi_reset_handler/eth_disable.vhd \
*/build_details_pkg.vhd \
}]

set_property file_type {VHDL 2008} [get_files  $DESIGN_PATH/src/vhdl/u55c/correlator.vhd]
set_property file_type {VHDL 2008} [get_files  $DESIGN_PATH/src/vhdl/correlator_core.vhd]
set_property file_type {VHDL 2008} [get_files  $DESIGN_PATH/src/vhdl/HBM_axi_tbModel.vhd]

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
 $COMMON_PATH/base/common/src/vhdl/common_pkg.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_str_pkg.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_mem_pkg.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_field_pkg.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_lfsr_sequences_pkg.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_interface_layers_pkg.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_network_layers_pkg.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_network_total_header_pkg.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_components_pkg.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_ram_crw_crw.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_pipeline.vhd \
 $COMMON_PATH/base/common/src/vhdl/common_accumulate.vhd \
]
set_property library common_lib [get_files {\
 *libraries/base/common/src/vhdl/common_reg_r_w.vhd \
 *libraries/base/common/src/vhdl/common_pkg.vhd \
 *libraries/base/common/src/vhdl/common_str_pkg.vhd \
 *libraries/base/common/src/vhdl/common_mem_pkg.vhd \
 *libraries/base/common/src/vhdl/common_field_pkg.vhd \
 *libraries/base/common/src/vhdl/common_lfsr_sequences_pkg.vhd \
 *libraries/base/common/src/vhdl/common_interface_layers_pkg.vhd \
 *libraries/base/common/src/vhdl/common_network_layers_pkg.vhd \
 *libraries/base/common/src/vhdl/common_network_total_header_pkg.vhd \
 *libraries/base/common/src/vhdl/common_components_pkg.vhd \
 *libraries/base/common/src/vhdl/common_ram_crw_crw.vhd \
 *libraries/base/common/src/vhdl/common_pipeline.vhd \
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

source $COMMON_PATH/LFAA_decode_100G/LFAADecode.tcl

add_files -fileset sources_1 [glob \
 $ARGS_PATH/LFAADecode100G/lfaadecode100g/LFAADecode100G_lfaadecode100g_reg_pkg.vhd \
 $ARGS_PATH/LFAADecode100G/lfaadecode100g/LFAADecode100G_lfaadecode100g_reg.vhd \
 $COMMON_PATH/LFAA_decode_100G/src/vhdl/LFAADecodeTop100G.vhd \
 $COMMON_PATH/LFAA_decode_100G/src/vhdl/LFAAProcess100G.vhd \
 $COMMON_PATH/LFAA_decode_100G/src/vhdl/LFAA_decode_axi_bram_wrapper.vhd \
]
set_property library LFAADecode100G_lib [get_files {\
 *LFAADecode100G/lfaadecode100g/LFAADecode100G_lfaadecode100g_reg_pkg.vhd \
 *LFAADecode100G/lfaadecode100g/LFAADecode100G_lfaadecode100g_reg.vhd \
 *LFAA_decode_100G/src/vhdl/LFAADecodeTop100G.vhd \
 *LFAA_decode_100G/src/vhdl/LFAAProcess100G.vhd \
 *LFAA_decode_100G/src/vhdl/LFAA_decode_axi_bram_wrapper.vhd \
}]

#############################################################
# SPS input packet statistics
add_files -fileset sources_1 [glob \
 $COMMON_PATH/sps_stats/sqr_8bit.vhd \
 $COMMON_PATH/sps_stats/stats_ones_count16.vhd \
 $COMMON_PATH/sps_stats/stats_ones_count6.vhd \
 $COMMON_PATH/sps_stats/sps_stats_pkg.vhd \
 $COMMON_PATH/sps_stats/stats_hbm_write.vhd \
 $COMMON_PATH/sps_stats/stats_summary.vhd \
 $COMMON_PATH/sps_stats/stats_isort_mem.vhd \
 $COMMON_PATH/sps_stats/stats_msort.vhd \
 $COMMON_PATH/sps_stats/stats_main_ref_mem.vhd \
 $COMMON_PATH/sps_stats/stats_main_table_mem.vhd \
 $COMMON_PATH/sps_stats/sps_statistics_top.vhd \
]
set_property library stats_lib [get_files {\
 *sps_stats/sqr_8bit.vhd \
 *sps_stats/stats_ones_count16.vhd \
 *sps_stats/stats_ones_count6.vhd \
 *sps_stats/stats_hbm_write.vhd \
 *sps_stats/stats_summary.vhd \
 *sps_stats/stats_isort_mem.vhd \
 *sps_stats/stats_msort.vhd \
 *sps_stats/sps_stats_pkg.vhd \
 *sps_stats/stats_main_ref_mem.vhd \
 *sps_stats/stats_main_table_mem.vhd \
 *sps_stats/sps_statistics_top.vhd \
}]

#############################################################
# SPEAD

add_files -fileset sources_1 [glob \
 $ARGS_PATH/hbm_read/hbm_rd_debug/hbm_read_hbm_rd_debug_reg_pkg.vhd \
 $ARGS_PATH/hbm_read/hbm_rd_debug/hbm_read_hbm_rd_debug_reg.vhd \
 $ARGS_PATH/spead/spead_sdp/spead_spead_sdp_reg_pkg.vhd \
 $ARGS_PATH/spead/spead_sdp/spead_spead_sdp_reg.vhd \
 $COMMON_PATH/Packetiser100G/src/vhdl/cbfpsrheader_pkg.vhd \
 $COMMON_PATH/Packetiser100G/src/vhdl/packet_player.vhd \
 $COMMON_PATH/spead/src/spead_packet_pkg.vhd \
 $COMMON_PATH/spead/src/spead_packet.vhd \
 $COMMON_PATH/spead/src/spead_registers.vhd \
 $COMMON_PATH/spead/src/spead_top.vhd \
 $COMMON_PATH/spead/src/memory_tdp_spead.vhd \
 $COMMON_PATH/spead/src/spead_axi_bram_wrapper.vhd \
 $COMMON_PATH/spead/src/spead_init_memspace.vhd \
]

set_property library spead_lib [get_files {\
 *build/ARGS/correlator/spead/spead_sdp/spead_spead_sdp_reg_pkg.vhd \
 *build/ARGS/correlator/spead/spead_sdp/spead_spead_sdp_reg.vhd \
 *build/ARGS/correlator/hbm_read/hbm_rd_debug/hbm_read_hbm_rd_debug_reg_pkg.vhd \
 *build/ARGS/correlator/hbm_read/hbm_rd_debug/hbm_read_hbm_rd_debug_reg.vhd \
 *libraries/Packetiser100G/src/vhdl/cbfpsrheader_pkg.vhd \
 *libraries/Packetiser100G/src/vhdl/packet_player.vhd \
 *libraries/Packetiser100G/src/vhdl/xpm_fifo_wrapper.vhd \
 *libraries/spead/src/spead_packet_pkg.vhd \
 *libraries/spead/src/spead_packet.vhd \
 *libraries/spead/src/spead_registers.vhd \
 *libraries/spead/src/spead_top.vhd \
 *libraries/spead/src/memory_tdp_spead.vhd \
 *libraries/spead/src/spead_axi_bram_wrapper.vhd \
 *libraries/spead/src/spead_init_memspace.vhd \
}]

set_property file_type {VHDL 2008} [get_files $COMMON_PATH/spead/src/spead_registers.vhd]

set_property file_type {VHDL 2008} [get_files $COMMON_PATH/Packetiser100G/src/vhdl/cbfpsrheader_pkg.vhd]

## tcl scripts for ip generation
source $COMMON_PATH/spead/spead.tcl

add_files -fileset sources_1 [glob \
 $COMMON_PATH/spead/src/dest_ip_preload.mem \
 $COMMON_PATH/spead/src/dest_udp_preload_one.mem \
 $COMMON_PATH/spead/src/dest_udp_preload_two.mem \
 $COMMON_PATH/spead/src/no_of_freq_chan_preload_one.mem \
 $COMMON_PATH/spead/src/no_of_freq_chan_preload_two.mem \
 $COMMON_PATH/spead/src/init_mem_preload.mem \
 $COMMON_PATH/spead/src/heap_size_preload.mem \
 $COMMON_PATH/spead/src/heap_counter_preload.mem \
]

##############################################################
# setup sim set for SPS SPEAD
add_files -fileset sources_1 [glob \
 $COMMON_PATH/spead_sps/src/spead_sps_packet_pkg.vhd \
]
set_property library spead_sps_lib [get_files {\
 *libraries/spead_sps/src/spead_sps_packet_pkg.vhd \
}]

#############################################################
## NOC

add_files -fileset sources_1 [glob \
  $COMMON_PATH/NOC/args_noc_dummy.vhd \
]
set_property library noc_lib [get_files {\
  */NOC/args_noc_dummy.vhd \
}]

#############################################################
# Signal_processing_common
add_files -fileset sources_1 [glob \
 $COMMON_PATH/common/src/vhdl/sync.vhd \
 $COMMON_PATH/common/src/vhdl/sync_vector.vhd \
 $COMMON_PATH/common/src/vhdl/xpm_sync_fifo_wrapper.vhd \
 $COMMON_PATH/common/src/vhdl/xpm_fifo_wrapper.vhd \
 $COMMON_PATH/common/src/vhdl/memory_tdp_wrapper.vhd \
 $COMMON_PATH/common/src/vhdl/args_axi_terminus.vhd \
 $COMMON_PATH/ethernet/src/vhdl/ethernet_pkg.vhd \
 $COMMON_PATH/ethernet/src/vhdl/ipv4_chksum.vhd \
]
set_property library signal_processing_common [get_files {\
 */common/src/vhdl/sync.vhd \
 */common/src/vhdl/sync_vector.vhd \
 */common/src/vhdl/xpm_sync_fifo_wrapper.vhd \
 */common/src/vhdl/xpm_fifo_wrapper.vhd \
 */common/src/vhdl/memory_tdp_wrapper.vhd \
 */common/src/vhdl/args_axi_terminus.vhd \
 */target_fpga_pkg.vhd \
}]

set_property library ethernet_lib [get_files {\
*ethernet/src/vhdl/ethernet_pkg.vhd \
*ethernet/src/vhdl/ipv4_chksum.vhd \
}]

source $COMMON_PATH/common/src/args_axi_terminus.tcl

#############################################################
# 1st corner turn, between LFAA ingest and filterbanks
# Note the versal version of the register block is needed to prevent the simulator failing

add_files -fileset sources_1 [glob \
  $ARGS_PATH/corr_ct1/corr_ct1/corr_ct1_reg_pkg.vhd \
  $ARGS_PATH/corr_ct1/corr_ct1/corr_ct1_reg.vhd \
  $ARGS_PATH/corr_ct1/corr_ct1/corr_ct1_reg_versal.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn1/poly_eval.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn1/flattening_wrapper.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn1/corr_ct1_readout.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn1/corr_ct1_readout_32bit.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn1/corr_ct1_valid.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn1/poly_axi_bram_wrapper.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn1/corr_ct1_top.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn1/corr_div3.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn1/hbm_ila.vhd \
]
set_property library ct_lib [get_files {\
 *build/ARGS/correlator/corr_ct1/corr_ct1/corr_ct1_reg_pkg.vhd \
 *build/ARGS/correlator/corr_ct1/corr_ct1/corr_ct1_reg.vhd \
 *build/ARGS/correlator/corr_ct1/corr_ct1/corr_ct1_reg_versal.vhd \
 *libraries/signalProcessing/cornerturn1/poly_eval.vhd \
 *libraries/signalProcessing/cornerturn1/flattening_wrapper.vhd \
 *libraries/signalProcessing/cornerturn1/poly_axi_bram_wrapper.vhd \
 *libraries/signalProcessing/cornerturn1/corr_ct1_readout.vhd \
 *libraries/signalProcessing/cornerturn1/corr_ct1_readout_32bit.vhd \
 *libraries/signalProcessing/cornerturn1/corr_ct1_valid.vhd \
 *libraries/signalProcessing/cornerturn1/corr_ct1_top.vhd \
 *libraries/signalProcessing/cornerturn1/corr_div3.vhd \
 *libraries/signalProcessing/cornerturn1/hbm_ila.vhd \
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
  $RLIBRARIES_PATH/signalProcessing/cornerturn2/corr_ct2_bad_poly_mem.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn2/ones_count6.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn2/ones_count16.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn2/get_ct2_HBM_addr.vhd \
]

set_property library ct_lib [get_files {\
 *build/ARGS/correlator/corr_ct2/corr_ct2/corr_ct2_reg_pkg.vhd \
 *build/ARGS/correlator/corr_ct2/corr_ct2/corr_ct2_reg.vhd \
 *libraries/signalProcessing/cornerturn2/corr_ct2_top.vhd \
 *libraries/signalProcessing/cornerturn2/corr_ct2_din.vhd \
 *libraries/signalProcessing/cornerturn2/corr_ct2_dout.vhd \
 *libraries/signalProcessing/cornerturn2/corr_ct2_bad_poly_mem.vhd \
 *libraries/signalProcessing/cornerturn2/ones_count6.vhd \
 *libraries/signalProcessing/cornerturn2/ones_count16.vhd \
 *libraries/signalProcessing/cornerturn2/get_ct2_HBM_addr.vhd \
}]

set_property file_type {VHDL 2008} [get_files  $RLIBRARIES_PATH/signalProcessing/cornerturn2/corr_ct2_din.vhd]
set_property file_type {VHDL 2008} [get_files  $RLIBRARIES_PATH/signalProcessing/cornerturn2/corr_ct2_top.vhd]
set_property file_type {VHDL 2008} [get_files  $RLIBRARIES_PATH/signalProcessing/cornerturn2/get_ct2_HBM_addr.vhd]


#############################################################
## Correlator filterbank and fine delay

add_files -fileset sources_1 [glob \
  $ARGS_PATH/cor_filterbanks/filterbanks/cor_filterbanks_filterbanks_reg_pkg.vhd \
  $ARGS_PATH/cor_filterbanks/filterbanks/cor_filterbanks_filterbanks_reg.vhd \
  $ARGS_PATH/cor_filterbanks/filterbanks/cor_filterbanks_filterbanks_reg_versal.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/FB_top_correlator.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/FB_top_correlator_dummy.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/correlatorFBTop25.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/correlatorFBTop_dummy.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/correlatorFBMem.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/URAMWrapper.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/URAM64wrapper.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/ShiftandRound.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/fb_DSP25.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/correlatorFFT25wrapper.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/fineDelay.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/RFI_weights.vhd \
]

set_property library filterbanks_lib [get_files {\
  *build/ARGS/correlator/cor_filterbanks/filterbanks/cor_filterbanks_filterbanks_reg_pkg.vhd \
  *build/ARGS/correlator/cor_filterbanks/filterbanks/cor_filterbanks_filterbanks_reg.vhd \
  *build/ARGS/correlator/cor_filterbanks/filterbanks/cor_filterbanks_filterbanks_reg_versal.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/FB_top_correlator.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/FB_top_correlator_dummy.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/correlatorFBTop25.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/correlatorFBTop_dummy.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/correlatorFBMem.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/URAMWrapper.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/URAM64wrapper.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/ShiftandRound.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/fb_DSP25.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/correlatorFFT25wrapper.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/fineDelay.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/RFI_weights.vhd \
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
  $RLIBRARIES_PATH/signalProcessing/correlator/single_correlator.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/full_correlator.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/correlator_HBM.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/LTA_urams.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/row_col_dataIn.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/LTA_top.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/centroid_divider.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/vis2fp.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/dv_tci_mem.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/sqrt_rom.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/fp32_x_Uint.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/inv_rom_top.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/inv_rom0.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/inv_rom1.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/inv_rom2.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/inv_rom3.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/inv_rom4.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/inv_rom5.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/inv_rom6.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/inv_rom7.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/inv_rom8.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/cmac_quad_wrapper.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/cmac_array/cmac_quad/cmac/cmac.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/cmac_array/cmac_quad/cmac/mult_add.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/cmac_array/cmac_quad/cmac/mult_add_dsp.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/cmac_array/cmac_quad/cmac/cmac_pkg.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/cor_hbm_data_rd/correlator_data_reader.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/cor_hbm_data_rd/cor_rd_HBM_queue_manager.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/cor_hbm_data_rd/cor_rd_meta_mem.vhd \
  $RLIBRARIES_PATH/signalProcessing/correlator/cor_hbm_data_rd/hbm_read_axi_bram_wrapper.vhd \
]

set_property library correlator_lib [get_files {\
  *build/ARGS/correlator/cor/config/cor_config_reg_pkg.vhd \
  *build/ARGS/correlator/cor/config/cor_config_reg.vhd \
  *libraries/signalProcessing/correlator/correlator_top.vhd \
  *libraries/signalProcessing/correlator/single_correlator.vhd \
  *libraries/signalProcessing/correlator/full_correlator.vhd \
  *libraries/signalProcessing/correlator/correlator_HBM.vhd \
  *libraries/signalProcessing/correlator/LTA_urams.vhd \
  *libraries/signalProcessing/correlator/row_col_dataIn.vhd \
  *libraries/signalProcessing/correlator/LTA_top.vhd \
  *libraries/signalProcessing/correlator/centroid_divider.vhd \
  *libraries/signalProcessing/correlator/vis2fp.vhd \
  *libraries/signalProcessing/correlator/dv_tci_mem.vhd \
  *libraries/signalProcessing/correlator/sqrt_rom.vhd \
  *libraries/signalProcessing/correlator/fp32_x_Uint.vhd \
  *libraries/signalProcessing/correlator/inv_rom_top.vhd \
  *libraries/signalProcessing/correlator/inv_rom0.vhd \
  *libraries/signalProcessing/correlator/inv_rom1.vhd \
  *libraries/signalProcessing/correlator/inv_rom2.vhd \
  *libraries/signalProcessing/correlator/inv_rom3.vhd \
  *libraries/signalProcessing/correlator/inv_rom4.vhd \
  *libraries/signalProcessing/correlator/inv_rom5.vhd \
  *libraries/signalProcessing/correlator/inv_rom6.vhd \
  *libraries/signalProcessing/correlator/inv_rom7.vhd \
  *libraries/signalProcessing/correlator/inv_rom8.vhd \
  *libraries/signalProcessing/correlator/cmac_quad_wrapper.vhd \
  *libraries/signalProcessing/correlator/cmac_array/cmac_quad/cmac/cmac.vhd \
  *libraries/signalProcessing/correlator/cmac_array/cmac_quad/cmac/mult_add.vhd \
  *libraries/signalProcessing/correlator/cmac_array/cmac_quad/cmac/mult_add_dsp.vhd \
  *libraries/signalProcessing/correlator/cmac_array/cmac_quad/cmac/cmac_pkg.vhd \
  *libraries/signalProcessing/correlator/cor_hbm_data_rd/correlator_data_reader.vhd \
  *libraries/signalProcessing/correlator/cor_hbm_data_rd/cor_rd_HBM_queue_manager.vhd \
  *signalProcessing/correlator/cor_hbm_data_rd/cor_rd_meta_mem.vhd \
  *signalProcessing/correlator/cor_hbm_data_rd/hbm_read_axi_bram_wrapper.vhd \
}]

set_property file_type {VHDL 2008} [get_files  $RLIBRARIES_PATH/signalProcessing/correlator/cor_hbm_data_rd/correlator_data_reader.vhd]
set_property file_type {VHDL 2008} [get_files  $RLIBRARIES_PATH/signalProcessing/correlator/cor_hbm_data_rd/cor_rd_HBM_queue_manager.vhd]
set_property file_type {VHDL 2008} [get_files  $COMMON_PATH/spead/src/spead_registers.vhd]

source $RLIBRARIES_PATH/signalProcessing/correlator/LTA.tcl
source $RLIBRARIES_PATH/signalProcessing/correlator/cor_hbm_data_rd/hbm_read.tcl

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
# timeslave causes simulation problems in vivado, remove it from the simulation.
set_property used_in_simulation false [get_files  *common/libraries/ptp/src/CMAC_100G_wrap_w_timeslave.vhd]
set_property used_in_simulation false [get_files  *correlator.gen/sources_1/bd/ts/hdl/ts_wrapper.vhd]
set_property used_in_simulation false [get_files  *correlator.srcs/sources_1/bd/ts/ts.bd]
set_property used_in_simulation false [get_files  *designs/correlator/src/vhdl/u55c/correlator.vhd]
set_property used_in_simulation false [get_files  *correlator/Timeslave/timeslave/Timeslave_timeslave_reg.vhd]

##############################################################
# Set top
add_files -fileset constrs_1 -norecurse $RLIBRARIES_PATH/../designs/correlator/src/scripts/vitisAccelCoreCon.xdc
set_property PROCESSING_ORDER LATE [get_files vitisAccelCoreCon.xdc]

set_property -name {xsim.compile.xvlog.more_options} -value {-d SIM_SPEED_UP} -objects [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

set_property top correlator [current_fileset]
update_compile_order -fileset sources_1

##############################################################
# setup sim set for SPEAD
create_fileset -simset sim_cor_read_spead

set_property SOURCE_SET sources_1 [get_filesets sim_cor_read_spead]

add_files -fileset sim_cor_read_spead [glob \
$RLIBRARIES_PATH/signalProcessing/correlator/tb/tb_cor_spead.vhd \
$DESIGN_PATH/src/vhdl/HBM_axi_tbModel.vhd \
$RLIBRARIES_PATH/signalProcessing/correlator/cor_hbm_data_rd/correlator_data_reader.vhd \
$RLIBRARIES_PATH/signalProcessing/correlator/cor_hbm_data_rd/cor_rd_HBM_queue_manager.vhd \
$RLIBRARIES_PATH/signalProcessing/correlator/tb/tb_cor_spead_behav.wcfg \
]

add_files -fileset sim_cor_read_spead [glob \
 $ARGS_PATH/hbm_read/hbm_rd_debug/hbm_read_hbm_rd_debug_reg_pkg.vhd \
 $ARGS_PATH/hbm_read/hbm_rd_debug/hbm_read_hbm_rd_debug_reg.vhd \
 $ARGS_PATH/hbm_read/hbm_rd_debug/hbm_read_hbm_rd_debug_reg_versal.vhd \
 $ARGS_PATH/spead/spead_sdp/spead_spead_sdp_reg_pkg.vhd \
 $ARGS_PATH/spead/spead_sdp/spead_spead_sdp_reg.vhd \
 $ARGS_PATH/spead/spead_sdp/spead_spead_sdp_reg_versal.vhd \
 $COMMON_PATH/Packetiser100G/src/vhdl/cbfpsrheader_pkg.vhd \
 $COMMON_PATH/Packetiser100G/src/vhdl/packet_player.vhd \
 $COMMON_PATH/spead/src/spead_packet_pkg.vhd \
 $COMMON_PATH/spead/src/spead_packet.vhd \
 $COMMON_PATH/spead/src/spead_registers.vhd \
 $COMMON_PATH/spead/src/spead_top.vhd \
 $COMMON_PATH/spead/src/memory_tdp_spead.vhd \
 $COMMON_PATH/spead/src/spead_axi_bram_wrapper.vhd \
]
set_property library spead_lib [get_files {\
 *build/ARGS/correlator/spead/spead_sdp/spead_spead_sdp_reg_pkg.vhd \
 *build/ARGS/correlator/spead/spead_sdp/spead_spead_sdp_reg.vhd \
 *spead/spead_sdp/spead_spead_sdp_reg_versal.vhd \
 *build/ARGS/correlator/hbm_read/hbm_rd_debug/hbm_read_hbm_rd_debug_reg_pkg.vhd \
 *build/ARGS/correlator/hbm_read/hbm_rd_debug/hbm_read_hbm_rd_debug_reg.vhd \
 *hbm_read/hbm_rd_debug/hbm_read_hbm_rd_debug_reg_versal.vhd \
 *libraries/Packetiser100G/src/vhdl/cbfpsrheader_pkg.vhd \
 *libraries/Packetiser100G/src/vhdl/packet_player.vhd \
 *libraries/spead/src/spead_packet_pkg.vhd \
 *libraries/spead/src/spead_packet.vhd \
 *libraries/spead/src/spead_registers.vhd \
 *libraries/spead/src/spead_top.vhd \
 *libraries/spead/src/memory_tdp_spead.vhd \
 *libraries/spead/src/spead_axi_bram_wrapper.vhd \
}]

add_files -fileset sim_cor_read_spead [glob \
 $COMMON_PATH/common/src/vhdl/xpm_sync_fifo_wrapper.vhd \
 $COMMON_PATH/common/src/vhdl/xpm_fifo_wrapper.vhd \
 $COMMON_PATH/common/src/vhdl/memory_tdp_wrapper.vhd \
 $COMMON_PATH/ethernet/src/vhdl/ethernet_pkg.vhd \
]
set_property library signal_processing_common [get_files {\
 */common/src/vhdl/xpm_sync_fifo_wrapper.vhd \
 */common/src/vhdl/xpm_fifo_wrapper.vhd \
 */common/src/vhdl/memory_tdp_wrapper.vhd \
}]

set_property library ethernet_lib [get_files {\
*ethernet/src/vhdl/ethernet_pkg.vhd \
}]

set_property library spead_lib [get_files {\
 */signalProcessing/correlator/tb/tb_cor_spead.vhd \
}]

set_property library correlator_lib [get_files {\
 */src/vhdl/HBM_axi_tbModel.vhd \
}]

set_property library correlator_lib [get_files {\
 */signalProcessing/correlator/cor_hbm_data_rd/correlator_data_reader.vhd \
 */signalProcessing/correlator/cor_hbm_data_rd/cor_rd_HBM_queue_manager.vhd \
}]

set_property file_type {VHDL 2008} [get_files  $DESIGN_PATH/src/vhdl/HBM_axi_tbModel.vhd]
set_property file_type {VHDL 2008} [get_files  $RLIBRARIES_PATH/signalProcessing/correlator/tb/tb_cor_spead.vhd]
set_property file_type {VHDL 2008} [get_files  $RLIBRARIES_PATH/signalProcessing/correlator/cor_hbm_data_rd/correlator_data_reader.vhd]
set_property file_type {VHDL 2008} [get_files  $RLIBRARIES_PATH/signalProcessing/correlator/cor_hbm_data_rd/cor_rd_HBM_queue_manager.vhd]
set_property file_type {VHDL 2008} [get_files  $COMMON_PATH/spead/src/spead_registers.vhd]

set_property top tb_cor_spead [get_filesets sim_cor_read_spead]
set_property top_lib xil_defaultlib [get_filesets sim_cor_read_spead]
update_compile_order -fileset sim_cor_read_spead

# End of SPEAD SIM setup
##############################################################

############################################################
# create riviera sim set
# create_fileset -simset sim_riv
# set_property SOURCE_SET sources_1 [get_filesets sim_riv]

# add_files -fileset sim_riv [glob \
# $DESIGN_PATH/src/vhdl/HBM_axi_tbModel.vhd \
# $DESIGN_PATH/src/vhdl/tb_correlatorCore.vhd \
# ]

# set_property file_type {VHDL 2008} [get_files  $DESIGN_PATH/src/vhdl/HBM_axi_tbModel.vhd]
# update_compile_order -fileset sim_riv

# set_property library correlator_lib [get_files {\
#  */src/vhdl/HBM_axi_tbModel.vhd \
#  */src/vhdl/tb_correlatorCore.vhd \
# }]


# # top level testbench
# set_property top tb_correlatorCore [get_filesets sim_riv]

# set_property target_simulator Riviera [current_project]
# set_property -name {riviera.simulate.asim.more_options} -value {-ieee_nowarn} -objects [get_filesets sim_riv]
# set_property -name {riviera.compile.vhdl_syntax} -value {2008} -objects [get_filesets sim_riv]
# set_property -name {riviera.compile.vhdl_relax} -value {true} -objects [get_filesets sim_riv]
# set_property -name {riviera.simulate.runtime} -value {2000us} -objects [get_filesets sim_riv]
# set_property simulator_language VHDL [current_project]


