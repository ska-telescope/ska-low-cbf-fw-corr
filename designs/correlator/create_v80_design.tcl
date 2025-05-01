
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

  # create common mapping
  cd "../../common"
  set COMMON [pwd]
  puts "Common path is $COMMON"  
  
  # create common/libraries mapping
  cd "libraries/"
  set COMMON_PATH [pwd]
  puts "Common Library path is $COMMON_PATH"
  
  # create a design folder mapping
  cd "../../designs/correlator"
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
    $BUILD_PATH/ARGS/correlator/correlator/system/correlator_system_reg_pkg.vhd \
    $BUILD_PATH/ARGS/correlator/correlator/system/correlator_system_reg_versal.vhd \
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
 $BUILD_PATH/ARGS/correlator/LFAADecode100G/lfaadecode100g/LFAADecode100G_lfaadecode100g_reg_pkg.vhd \
 $BUILD_PATH/ARGS/correlator/LFAADecode100G/lfaadecode100g/LFAADecode100G_lfaadecode100g_reg_versal.vhd \
 $COMMON_PATH/LFAA_decode_100G/src/vhdl/LFAADecodeTop100G.vhd \
 $COMMON_PATH/LFAA_decode_100G/src/vhdl/LFAAProcess100G.vhd \
 $COMMON_PATH/LFAA_decode_100G/src/vhdl/LFAA_decode_axi_bram_wrapper.vhd \
]
set_property library LFAADecode100G_lib [get_files {\
 *LFAADecode100G_lfaadecode100g_reg_pkg.vhd \
 *LFAADecode100G_lfaadecode100g_reg_versal.vhd \
 *LFAA_decode_100G/src/vhdl/LFAADecodeTop100G.vhd \
 *LFAA_decode_100G/src/vhdl/LFAAProcess100G.vhd \
 *LFAA_decode_100G/src/vhdl/LFAA_decode_axi_bram_wrapper.vhd \
}]

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

add_files -fileset sources_1 [glob \
  $COMMON_PATH/spead/src/spead_packet_pkg.vhd \
]

set_property library spead_lib [get_files {\
  *libraries/spead/src/spead_packet_pkg.vhd \
}]





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
