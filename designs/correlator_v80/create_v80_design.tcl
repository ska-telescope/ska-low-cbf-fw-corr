
set time_raw [clock seconds];
set date_string [clock format $time_raw -format "%y%m%d_%H%M%S"]

set src_dir        [file dirname [file normalize [info script]]]
set design_name     "v80_top"
set bd_name         "top"

proc do_aved_create_design { } { 
  global bd_name
  global src_dir
  global design_name
  global date_string

  # # create_project script puts us at GITREPO/build/v80
  # set proj_dir "build_$date_string"
  # puts "This project is created in $proj_dir"
  # # make current build directory
  # file mkdir $proj_dir
  # cd $proj_dir
  set proj_dir [pwd]
  puts "Project directory is $proj_dir"

  # create Repo base mapping
  cd "../../"
  set REPO_BASE [pwd]
  puts "Repo path is $REPO_BASE"  

  cd $proj_dir

  # create common mapping
  cd "../../common"
  set COMMON [pwd]
  puts "Common path is $COMMON"  
  
  # create common/libraries mapping
  cd "libraries/"
  set COMMON_PATH [pwd]
  puts "Common Library path is $COMMON_PATH"
  
  # create a design folder mapping
  cd "../../designs/correlator_v80"
  set DESIGN_PATH [pwd]
  puts "Design path is $DESIGN_PATH"
  
  # create a design folder mapping
  cd $proj_dir
  cd "../"
  set BUILD_PATH [pwd]
  puts "Build path is $BUILD_PATH"

  # create a Repo LIBRARIES_PATH mapping
  cd "../libraries"
  set RLIBRARIES_PATH [pwd]
  puts "Repo Libraries path is $RLIBRARIES_PATH"

  # create a Repo ARGS mapping
  set ARGS_PATH "$BUILD_PATH/ARGS/correlator_v80"
  puts "ARGs path is $ARGS_PATH"

  # set to project working dir
  cd $proj_dir

  # Create the project targeting its part
  create_project $design_name -part xcv80-lsva4737-2MHP-e-S -force
  set_property target_language VHDL [current_project]
  set_property target_simulator XSim [current_project]

  # Set project IP repositories
  set_property ip_repo_paths "$COMMON/v80_infra/iprepo" [current_project]
  update_ip_catalog

  # ----------------------------------------
  # Add base files
  add_files -fileset sources_1 [glob \
  $DESIGN_PATH/src_v80/vhdl/v80_top.vhd \
  ]

  set_property file_type {VHDL 2008} [get_files  *src_v80/vhdl/v80_top.vhd]

  source $COMMON/v80_infra/src/v80_ip.tcl

  # ----------------------------------------
  # V80 - BD - Create block diagram
  create_bd_design  ${bd_name}
  current_bd_design ${bd_name}

  # Add base to block diagram
  source "$COMMON/v80_infra/src/top_bd/create_bd_design.tcl"
  create_root_design ""

  # Write the block diagram wrapper and set it as design top
  add_files -norecurse [make_wrapper -files [get_files "${bd_name}.bd"] -top]

  # ----------------------------------------
  # Add DCMAC BD
  source $COMMON_PATH/DCMAC/dcmac_two_100g_bd.tcl
  add_files -norecurse [make_wrapper -files [get_files "dcmac_two_100g_bd.bd"] -top]

  add_files -fileset sources_1 [glob \
    $COMMON_PATH/DCMAC/dcmac_syncer_reset.sv \
    $COMMON_PATH/DCMAC/dcmac_wrapper.vhd \
    $COMMON_PATH/DCMAC/packet_player.vhd \
    $COMMON_PATH/DCMAC/segment_to_saxi.vhd \
    $COMMON_PATH/DCMAC/versal_dcmac_pkg.vhd \
    $COMMON_PATH/DCMAC/dcmac_config.vhd \
    $COMMON_PATH/DCMAC/dcmac_port_stats.vhd \
  ]

  set_property library versal_dcmac_lib [get_files {\
    */DCMAC/dcmac_syncer_reset.sv \
    */DCMAC/dcmac_wrapper.vhd \
    */DCMAC/packet_player.vhd \
    */DCMAC/segment_to_saxi.vhd \
    */DCMAC/versal_dcmac_pkg.vhd \
    */DCMAC/dcmac_config.vhd \
    */DCMAC/dcmac_port_stats.vhd \
  }]

  set_property file_type {VHDL 2008} [get_files $COMMON_PATH/DCMAC/versal_dcmac_pkg.vhd]
  set_property file_type {VHDL 2008} [get_files $COMMON_PATH/DCMAC/dcmac_wrapper.vhd]
  set_property file_type {VHDL 2008} [get_files $COMMON_PATH/DCMAC/packet_player.vhd]
  set_property file_type {VHDL 2008} [get_files $COMMON_PATH/DCMAC/segment_to_saxi.vhd]

  source $COMMON_PATH/DCMAC/dcmac_ip.tcl

  # ----------------------------------------
  # Technology select package
  add_files -fileset sources_1 [glob \
  $COMMON_PATH/base/technology/technology_pkg.vhd \
  $COMMON_PATH/base/technology/technology_select_pkg.vhd \
  ]
  set_property library technology_lib [get_files {\
  */technology/technology_pkg.vhd \
  */technology/technology_select_pkg.vhd \
  }]

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
  }]

  set_property library ethernet_lib [get_files {\
  *ethernet/src/vhdl/ethernet_pkg.vhd \
  *ethernet/src/vhdl/ipv4_chksum.vhd \
  }]

  source $COMMON_PATH/common/src/args_axi_terminus.tcl

  #############################################################
  ## NOC
  # source $COMMON_PATH/NOC/args_fl/args_fl.tcl
  # add_files -norecurse [make_wrapper -files [get_files "args_fl.bd"] -top]

  # source $COMMON_PATH/NOC/args_l/args_l.tcl
  # add_files -norecurse [make_wrapper -files [get_files "args_l.bd"] -top]

  add_files -fileset sources_1 [glob \
    $COMMON_PATH/NOC/args_noc.vhd \
  ]
  set_property library noc_lib [get_files {\
    */NOC/args_noc.vhd \
  }]

  source $COMMON_PATH/NOC/noc_ip.tcl

  # This file will need to be tailored to each personality
  add_files -fileset constrs_1 -norecurse "$DESIGN_PATH/src_v80/constraints/noc_addresses.xdc"
  set_property USED_IN {synthesis_pre} [get_files "$DESIGN_PATH/src_v80/constraints/noc_addresses.xdc"]
  
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
  # Design Specific files
  add_files -fileset sources_1 [glob \
    $ARGS_PATH/correlator/system/correlator_system_reg_pkg.vhd \
    $ARGS_PATH/correlator/system/correlator_system_reg_versal.vhd \
    $DESIGN_PATH/src_v80/vhdl/correlator_core.vhd \
    $DESIGN_PATH/src_v80/vhdl/version_pkg.vhd \
    $DESIGN_PATH/src_v80/vhdl/target_fpga_pkg.vhd \
    $BUILD_PATH/build_details_pkg.vhd \
  ]

  set_property library correlator_lib [get_files {\
    */correlator_system_reg_pkg.vhd \
    */correlator_system_reg_versal.vhd \
    */correlator_core.vhd \
    */version_pkg.vhd \
    */target_fpga_pkg.vhd \
    */build_details_pkg.vhd \
  }]

set_property file_type {VHDL 2008} [get_files  $DESIGN_PATH/src_v80/vhdl/correlator_core.vhd]

source $DESIGN_PATH/src_v80/ip/correlator.tcl


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


#############################################################
# 100G LFAA decode

source $COMMON_PATH/LFAA_decode_100G/LFAADecode.tcl

add_files -fileset sources_1 [glob \
 $ARGS_PATH/LFAADecode100G/lfaadecode100g/LFAADecode100G_lfaadecode100g_reg_pkg.vhd \
 $ARGS_PATH/LFAADecode100G/lfaadecode100g/LFAADecode100G_lfaadecode100g_reg_versal.vhd \
 $ARGS_PATH/LFAADecode100G/lfaadecode100g/LFAADecode100G_lfaadecode100g_reg.vhd \
 $COMMON_PATH/LFAA_decode_100G/src/vhdl/LFAADecodeTop100G.vhd \
 $COMMON_PATH/LFAA_decode_100G/src/vhdl/LFAAProcess100G.vhd \
 $COMMON_PATH/LFAA_decode_100G/src/vhdl/LFAA_decode_axi_bram_wrapper.vhd \
]
set_property library LFAADecode100G_lib [get_files {\
 *LFAADecode100G_lfaadecode100g_reg_pkg.vhd \
 *LFAADecode100G_lfaadecode100g_reg_versal.vhd \
 *LFAADecode100G_lfaadecode100g_reg.vhd \
 *LFAA_decode_100G/src/vhdl/LFAADecodeTop100G.vhd \
 *LFAA_decode_100G/src/vhdl/LFAAProcess100G.vhd \
 *LFAA_decode_100G/src/vhdl/LFAA_decode_axi_bram_wrapper.vhd \
}]

add_files -fileset sources_1 [glob \
 $COMMON_PATH/LFAA_decode_100G/src/vhdl/vc_table_tb.mem \
]

##############################################################
# Add SPS SPEAD
add_files -fileset sources_1 [glob \
 $COMMON_PATH/spead_sps/src/spead_sps_packet_pkg.vhd \
]
set_property library spead_sps_lib [get_files {\
 *libraries/spead_sps/src/spead_sps_packet_pkg.vhd \
}]

#############################################################
# SPEAD
  puts "Add SPEAD files ..."
add_files -fileset sources_1 [glob \
 $ARGS_PATH/hbm_read/hbm_rd_debug/hbm_read_hbm_rd_debug_reg_pkg.vhd \
 $ARGS_PATH/hbm_read/hbm_rd_debug/hbm_read_hbm_rd_debug_reg.vhd \
 $ARGS_PATH/hbm_read/hbm_rd_debug/hbm_read_hbm_rd_debug_reg_versal.vhd \
 $ARGS_PATH/spead/spead_sdp/spead_spead_sdp_reg_pkg.vhd \
 $ARGS_PATH/spead/spead_sdp/spead_spead_sdp_reg_versal.vhd \
 $ARGS_PATH/spead/spead_sdp/spead_spead_sdp_reg.vhd \
 $COMMON_PATH/Packetiser100G/src/vhdl/cbfpsrheader_pkg.vhd \
 $COMMON_PATH/spead/src/spead_packet_pkg.vhd \
 $COMMON_PATH/spead/src/spead_packet.vhd \
 $COMMON_PATH/spead/src/spead_registers.vhd \
 $COMMON_PATH/spead/src/spead_top.vhd \
 $COMMON_PATH/spead/src/memory_tdp_spead.vhd \
 $COMMON_PATH/spead/src/spead_axi_bram_wrapper.vhd \
 $COMMON_PATH/spead/src/spead_init_memspace.vhd \
]

set_property library spead_lib [get_files {\
 *spead/spead_sdp/spead_spead_sdp_reg_pkg.vhd \
 *spead/spead_sdp/spead_spead_sdp_reg_versal.vhd \
 *spead/spead_sdp/spead_spead_sdp_reg.vhd \
 *hbm_read/hbm_rd_debug/hbm_read_hbm_rd_debug_reg_pkg.vhd \
 *hbm_read/hbm_rd_debug/hbm_read_hbm_rd_debug_reg.vhd \
 *hbm_read/hbm_rd_debug/hbm_read_hbm_rd_debug_reg_versal.vhd \
 *libraries/Packetiser100G/src/vhdl/cbfpsrheader_pkg.vhd \
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

#############################################################
# 1st corner turn, between LFAA ingest and filterbanks

  puts "Add CT1 files ..."

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
 *corr_ct1/corr_ct1/corr_ct1_reg_pkg.vhd \
 *corr_ct1/corr_ct1/corr_ct1_reg.vhd \
 *corr_ct1/corr_ct1/corr_ct1_reg_versal.vhd \
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

source $RLIBRARIES_PATH/signalProcessing/cornerturn1/corr_ct1_v80.tcl

#############################################################
## Correlator filterbank and fine delay

  puts "Add Filterbank files ..."

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
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/BRAMWrapper.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/URAM64wrapper.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/ShiftandRound.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/fb_DSP25.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/correlatorFFT25wrapper.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/vhdl/fineDelay.vhd \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/xpm_init/correlatorFIRTaps1.mem \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/xpm_init/correlatorFIRTaps2.mem \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/xpm_init/correlatorFIRTaps3.mem \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/xpm_init/correlatorFIRTaps4.mem \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/xpm_init/correlatorFIRTaps5.mem \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/xpm_init/correlatorFIRTaps6.mem \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/xpm_init/correlatorFIRTaps7.mem \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/xpm_init/correlatorFIRTaps8.mem \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/xpm_init/correlatorFIRTaps9.mem \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/xpm_init/correlatorFIRTaps10.mem \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/xpm_init/correlatorFIRTaps11.mem \
  $RLIBRARIES_PATH/signalProcessing/filterbanks/src/xpm_init/correlatorFIRTaps12.mem \
]

set_property library filterbanks_lib [get_files {\
  *cor_filterbanks/filterbanks/cor_filterbanks_filterbanks_reg_pkg.vhd \
  *cor_filterbanks/filterbanks/cor_filterbanks_filterbanks_reg.vhd \
  *cor_filterbanks/filterbanks/cor_filterbanks_filterbanks_reg_versal.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/FB_top_correlator.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/FB_top_correlator_dummy.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/correlatorFBTop25.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/correlatorFBTop_dummy.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/correlatorFBMem.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/URAMWrapper.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/BRAMWrapper.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/URAM64wrapper.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/ShiftandRound.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/fb_DSP25.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/correlatorFFT25wrapper.vhd \
  *libraries/signalProcessing/filterbanks/src/vhdl/fineDelay.vhd \
}]

source $RLIBRARIES_PATH/signalProcessing/filterbanks/src/ip/dspAxB_versal.tcl
source $RLIBRARIES_PATH/signalProcessing/filterbanks/src/ip/CorFB_FFT.tcl
source $RLIBRARIES_PATH/signalProcessing/filterbanks/src/ip/fineDelay.tcl

#############################################################
# output corner turn (between filterbanks and correlator)

  puts "Add CT2 files ..."

add_files -fileset sources_1 [glob \
  $ARGS_PATH/corr_ct2/corr_ct2/corr_ct2_reg_pkg.vhd \
  $ARGS_PATH/corr_ct2/corr_ct2/corr_ct2_reg.vhd \
  $ARGS_PATH/corr_ct2/corr_ct2/corr_ct2_reg_versal.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn2/corr_ct2_top.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn2/corr_ct2_din.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn2/corr_ct2_dout.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn2/corr_ct2_bad_poly_mem.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn2/ones_count6.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn2/ones_count16.vhd \
  $RLIBRARIES_PATH/signalProcessing/cornerturn2/get_ct2_HBM_addr.vhd \
]

set_property library ct_lib [get_files {\
 *corr_ct2/corr_ct2/corr_ct2_reg_pkg.vhd \
 *corr_ct2/corr_ct2/corr_ct2_reg.vhd \
 *corr_ct2/corr_ct2/corr_ct2_reg_versal.vhd \
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
## Correlator

  puts "Add Correlator files ..."

add_files -fileset sources_1 [glob \
  $ARGS_PATH/cor/config/cor_config_reg_pkg.vhd \
  $ARGS_PATH/cor/config/cor_config_reg.vhd \
  $ARGS_PATH/cor/config/cor_config_reg_versal.vhd \
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
]

set_property library correlator_lib [get_files {\
  *cor/config/cor_config_reg_pkg.vhd \
  *cor/config/cor_config_reg.vhd \
  *cor/config/cor_config_reg_versal.vhd \
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
}]

set_property file_type {VHDL 2008} [get_files  $RLIBRARIES_PATH/signalProcessing/correlator/cor_hbm_data_rd/correlator_data_reader.vhd]
set_property file_type {VHDL 2008} [get_files  $RLIBRARIES_PATH/signalProcessing/correlator/cor_hbm_data_rd/cor_rd_HBM_queue_manager.vhd]
set_property file_type {VHDL 2008} [get_files  $COMMON_PATH/spead/src/spead_registers.vhd]

source $RLIBRARIES_PATH/signalProcessing/correlator/LTA.tcl

##############################################################
# setup sim set for SPEAD

  puts "Create DCMAC SIM ..."

create_fileset -simset sim_dcmac

set_property SOURCE_SET sources_1 [get_filesets sim_dcmac]

add_files -fileset sim_dcmac [glob \
$DESIGN_PATH/src_v80/tb/tb_correlatorCore.vhd \
$DESIGN_PATH/src_v80/tb/HBM_axi_tbModel.vhd \
$DESIGN_PATH/src_v80/tb/tb_correlatorCore_behav.wcfg \
]

set_property library correlator_lib [get_files {\
 */src_v80/tb/HBM_axi_tbModel.vhd \
}]

set_property file_type {VHDL 2008} [get_files  $DESIGN_PATH/src_v80/tb/HBM_axi_tbModel.vhd]
#set_property file_type {VHDL 2008} [get_files  $DESIGN_PATH/src_v80/tb/tb_correlatorCore.vhd]

set_property top tb_correlatorCore [get_filesets sim_dcmac]
set_property top_lib xil_defaultlib [get_filesets sim_dcmac]
update_compile_order -fileset sim_dcmac

######################
## NoC is not supported in VHDL simulation in 2024.2, need to deactivate these files from sim
set_property used_in_simulation false [get_files  $REPO_BASE/designs/correlator_v80/src_v80/vhdl/v80_top.vhd]
set_property used_in_simulation false [get_files  $REPO_BASE/build/v80/v80_top.gen/sources_1/bd/top/hdl/top_wrapper.vhd]
set_property used_in_simulation false [get_files  $REPO_BASE/build/v80/v80_top.srcs/sources_1/bd/top/top.bd]

  #############################################################
  # ----------------------------------------
  # update compile and set top of design

  puts "Updating project settings ..."

  update_compile_order -fileset sources_1
  update_compile_order -fileset sim_1
  set_property top v80_top [current_fileset]

  # ----------------------------------------
  # Add constraint and hook files
  add_files -fileset constrs_1 -norecurse "$COMMON/v80_infra/constraints/impl.xdc"
  add_files -fileset constrs_1 -norecurse "$COMMON/v80_infra/constraints/impl.pins.xdc"
  add_files -fileset utils_1   -norecurse "$COMMON/v80_infra/constraints/opt.post.tcl"
  add_files -fileset utils_1   -norecurse "$COMMON/v80_infra/constraints/place.pre.tcl"
  add_files -fileset utils_1   -norecurse "$COMMON/v80_infra/constraints/write_device_image.pre.tcl"

  set_property -dict { used_in_synthesis false    processing_order NORMAL } [get_files *impl.xdc]
  set_property -dict { used_in_synthesis false    processing_order NORMAL } [get_files *impl.pins.xdc]

  set_property STEPS.OPT_DESIGN.TCL.POST         [get_files *opt.post.tcl]                [get_runs impl_1]
  set_property STEPS.PLACE_DESIGN.TCL.PRE        [get_files *place.pre.tcl]               [get_runs impl_1]
  set_property STEPS.WRITE_DEVICE_IMAGE.TCL.PRE  [get_files *write_device_image.pre.tcl]  [get_runs impl_1]

  set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]



  puts "--------------------------------------------------------"
  puts "Project Creation script completed, XPR ready to open"
  puts "--------------------------------------------------------"
}

do_aved_create_design
