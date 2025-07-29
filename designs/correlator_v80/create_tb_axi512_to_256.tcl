
set time_raw [clock seconds];
set date_string [clock format $time_raw -format "%y%m%d_%H%M%S"]

set src_dir        [file dirname [file normalize [info script]]]
set design_name     "tb_axi512_to_256"

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
  $COMMON_PATH/common/src/vhdl/axi512_to_256.vhd \
  $COMMON_PATH/common/src/vhdl/axi512_to_256_addr.vhd \
  $COMMON_PATH/common/src/vhdl/rdy_valid_512_to_256_reg_slice.vhd \
  $COMMON_PATH/common/src/vhdl/rdy_valid_reg_slice.vhd \
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
  */common/src/vhdl/axi512_to_256.vhd \
  */common/src/vhdl/axi512_to_256_addr.vhd \
  */common/src/vhdl/rdy_valid_512_to_256_reg_slice.vhd \
  */common/src/vhdl/rdy_valid_reg_slice.vhd \
  }]

  set_property library ethernet_lib [get_files {\
  *ethernet/src/vhdl/ethernet_pkg.vhd \
  *ethernet/src/vhdl/ipv4_chksum.vhd \
  }]

  source $COMMON_PATH/common/src/args_axi_terminus.tcl

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

source $COMMON_PATH/common/src/tb/tb_ip.tcl
##############################################################
# setup sim set for AXI converter for HBM

  puts "Create HBM converter sim ..."

create_fileset -simset sim_hbm_axi

set_property SOURCE_SET sources_1 [get_filesets sim_hbm_axi]

add_files -fileset sim_hbm_axi [glob \
  $COMMON_PATH/common/src/tb/tb_axi512_to_256.vhd \
  $COMMON_PATH/common/src/tb/tb_axi512_to_256.wcfg \
  $COMMON_PATH/common/src/vhdl/sync.vhd \
  $COMMON_PATH/common/src/vhdl/sync_vector.vhd \
  $COMMON_PATH/common/src/vhdl/xpm_sync_fifo_wrapper.vhd \
  $COMMON_PATH/common/src/vhdl/xpm_fifo_wrapper.vhd \
  $COMMON_PATH/common/src/vhdl/memory_tdp_wrapper.vhd \
  $COMMON_PATH/common/src/vhdl/args_axi_terminus.vhd \
  $COMMON_PATH/common/src/vhdl/axi512_to_256.vhd \
  $COMMON_PATH/common/src/vhdl/axi512_to_256_addr.vhd \
  $COMMON_PATH/common/src/vhdl/rdy_valid_512_to_256_reg_slice.vhd \
  $COMMON_PATH/common/src/vhdl/rdy_valid_reg_slice.vhd \
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
  */common/src/vhdl/axi512_to_256.vhd \
  */common/src/vhdl/axi512_to_256_addr.vhd \
  */common/src/vhdl/rdy_valid_512_to_256_reg_slice.vhd \
  */common/src/vhdl/rdy_valid_reg_slice.vhd \
 }]

set_property library ethernet_lib [get_files {\
  *ethernet/src/vhdl/ethernet_pkg.vhd \
  *ethernet/src/vhdl/ipv4_chksum.vhd \
}]

set_property file_type {VHDL 2008} [get_files $COMMON_PATH/common/src/tb/tb_axi512_to_256.vhd]

set_property top tb_axi512_to_256 [get_filesets sim_hbm_axi]
set_property top_lib xil_defaultlib [get_filesets sim_hbm_axi]
update_compile_order -fileset sim_hbm_axi


######################

  puts "--------------------------------------------------------"
  puts "Project Creation script completed, XPR ready to open"
  puts "--------------------------------------------------------"
}

do_aved_create_design
