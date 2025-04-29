#create_noc_connection -source [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/S00_AXI_nmu] -target [get_noc_interfaces i_system_noc/xpm_nsu_mm_inst/M_AXI_nsu]
# Mappings are master to slave
# Args infers a NoC Slave interface

set nmu_0 [get_noc_interfaces "i_v80_board/top_i/axi_noc_cips/S00_AXI_nmu"]
set lfaa_1_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/LFAAin/gen_v80_args.i_lfaa_noc/xpm_nsu_mm_inst/M_AXI_nsu"]

# two 64K addresses, assign 128K
set_property APERTURES [list {0x201_0000_0000:0x201_0001_FFFF}] $lfaa_1_nsu

set lfaa_1_conn [create_noc_connection -source $nmu_0 -target $lfaa_1_nsu]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 4] $lfaa_1_conn

# ADDRESS SPACE TO BE AWARE OF IN TOP BD
# 0x201_0FFF_FFFF for 128M assigned to DDR, this can probably be deleted 
# 0x201_0100_0000 -> 0x201_0104_FFFF Used by design components, possible to remap to higher?

# HBM connections
#HBM Ports
#set hbm_port [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM0_PORT0_hbmc]
#set hbm_input [get_noc_interfaces test_comp/i_hbm_noc/S_AXI_nmu]
#set hbm_test [create_noc_connection -source $hbm_input -target $hbm_port]

