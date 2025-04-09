#create_noc_connection -source [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/S00_AXI_nmu] -target [get_noc_interfaces i_system_noc/xpm_nsu_mm_inst/M_AXI_nsu]
# Mappings are master to slave
# Args infers a NoC Slave interface

#set nmu_0 [get_noc_interfaces "i_v80_board/top_i/axi_noc_cips/S00_AXI_nmu"]
#set test_nsu [get_noc_interfaces "test_comp/i_system_noc/xpm_nsu_mm_inst/M_AXI_nsu"]

#set_property APERTURES [list {0x201_0000_0000:0x201_0000_FFFF}] $test_nsu

#set args_system [create_noc_connection -source $nmu_0 -target $test_nsu]
#set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 4] $args_system


# HBM connections
#HBM Ports
#set hbm_port [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM0_PORT0_hbmc]
#set hbm_input [get_noc_interfaces test_comp/i_hbm_noc/S_AXI_nmu]
#set hbm_test [create_noc_connection -source $hbm_input -target $hbm_port]

