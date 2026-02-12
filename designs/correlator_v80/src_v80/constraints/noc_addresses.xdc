#create_noc_connection -source [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/S00_AXI_nmu] -target [get_noc_interfaces i_system_noc/xpm_nsu_mm_inst/M_AXI_nsu]
# Mappings are master to slave
# Args infers a NoC Slave interface

################
## These are all hierarchy mappings, beware when updating code.
## List the noc interfaces use any of the following - 
## join [get_noc_interfaces ] \n
## join [get_noc_interfaces -mode NMU] \n
## join [get_noc_interfaces -mode NSU] \n

################
## These are all heirarchy mappings, beware when updating code.
set nmu_0 [get_noc_interfaces "i_v80_board/top_i/axi_noc_cips/S00_AXI_nmu"]
set system_nsu [get_noc_interfaces "i_correlator_core/i_system_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
set lfaa_1_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/LFAAin/gen_v80_args.i_lfaa_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
set ct_1_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/LFAA_FB_CT/gen_v80_args.i_ct1_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
set fb_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/FBreali.corFB_i/gen_v80_args.i_fb_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
set ct_2_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/ct_cor_out_inst/i_ct2_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
# correlator instances do not have registers instantiated
#set corr_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/correlator_inst/gen_v80_args.i_cor_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
set spead_hbmrd_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/spead_packetiser_top/spead_hbm_rd_noci/xpm_nsu_mm_inst/M_AXI_nsu"]
set spead_0_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/spead_packetiser_top/read_pkt_geni[0].cor_speader/host_interface/gen_v80_args.i_spead_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
set spead_1_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/spead_packetiser_top/read_pkt_geni[1].cor_speader/host_interface/gen_v80_args.i_spead_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
set spead_2_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/spead_packetiser_top/read_pkt_geni[2].cor_speader/host_interface/gen_v80_args.i_spead_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
set spead_3_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/spead_packetiser_top/read_pkt_geni[3].cor_speader/host_interface/gen_v80_args.i_spead_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
set spead_4_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/spead_packetiser_top/read_pkt_geni[4].cor_speader/host_interface/gen_v80_args.i_spead_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
set spead_5_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/spead_packetiser_top/read_pkt_geni[5].cor_speader/host_interface/gen_v80_args.i_spead_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
set dcmac_nsu [get_noc_interfaces "i_dcmac_wrapper/i_port_0_stats/i_dcmac_noc/xpm_nsu_mm_inst/M_AXI_nsu"]

# Base address for the PL region and this is also mapped to BAR 0 - 0x201_0000_0000
# correlator ARGs
#    Including slave ports for correlator_v80: 
# ------------------------------------------------------------------------------------------
#  !! OUT of Date info in comments below
#    system_system at 0x0                       0 - 0x0_FFFF
#    lfaadecode100g_vcstats_ram at 0x4000       1 - 0x1_FFFF
#    lfaadecode100g_statctrl at 0x8000          2 - 0x2_FFFF
#    corr_ct1_polynomial_ram_ram at 0x10000 
#    corr_ct1_config at 0x20000 
#    filterbanks_config at 0x22000 
#    corr_ct2_statctrl at 0x24000 
#    config_setup at 0x26000 
#    spead_sdp_spead_params_ram at 0x28000 
#    spead_sdp_spead_ctrl at 0x2C000 
#    spead_sdp_2_spead_params_ram at 0x30000 
#    spead_sdp_2_spead_ctrl at 0x34000 
#    hbm_rd_debug_hbm_rd_debug at 0x36000 
#    hbm_rd_debug_2_hbm_rd_debug at 0x38000 
# ------------------------------------------------------------------------------------------
#
# use the above list just for ordering of the NSUs
#

########################
# System peripheral = 64K address space
set_property APERTURES [list {0x201_1000_0000:0x201_1001_FFFF}] $system_nsu
set system_conn [create_noc_connection -source $nmu_0 -target $system_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $system_conn
########################
# LFAA is entry 2 and 3 on the list, 128K between NoCs so starts at 128K and covers up to 256K from the base address.
# two 64K addresses, assign 128K
set_property APERTURES [list {0x201_1010_0000:0x201_1017_FFFF}] $lfaa_1_nsu
set lfaa_1_conn [create_noc_connection -source $nmu_0 -target $lfaa_1_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $lfaa_1_conn
########################
# CT_1
set_property APERTURES [list {0x201_1020_0000:0x201_1027_FFFF}] $ct_1_nsu
set ct_1_conn [create_noc_connection -source $nmu_0 -target $ct_1_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $ct_1_conn
########################
# Filterbank
set_property APERTURES [list {0x201_1030_0000:0x201_1037_FFFF}] $fb_nsu
set fb_conn [create_noc_connection -source $nmu_0 -target $fb_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $fb_conn
########################
# CT_2
set_property APERTURES [list {0x201_1040_0000:0x201_1047_FFFF}] $ct_2_nsu
set ct_2_conn [create_noc_connection -source $nmu_0 -target $ct_2_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $ct_2_conn
########################
# Correlator
#set_property APERTURES [list {0x201_1050_0000:0x201_1057_FFFF}] $corr_nsu
#
#set corr_conn [create_noc_connection -source $nmu_0 -target $corr_nsu]
#set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $corr_conn

########################
# Spead HBM read
set_property APERTURES [list {0x201_1050_0000:0x201_1057_FFFF}] $spead_hbmrd_nsu

set spead_hbm_conn [create_noc_connection -source $nmu_0 -target $spead_hbmrd_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $spead_hbm_conn

########################
# SPEAD packetiser 
set_property APERTURES [list {0x201_1060_0000:0x201_1067_FFFF}] $spead_0_nsu
set spead_0_conn [create_noc_connection -source $nmu_0 -target $spead_0_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $spead_0_conn

set_property APERTURES [list {0x201_1070_0000:0x201_1077_FFFF}] $spead_1_nsu
set spead_1_conn [create_noc_connection -source $nmu_0 -target $spead_1_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $spead_1_conn

set_property APERTURES [list {0x201_1080_0000:0x201_1087_FFFF}] $spead_2_nsu
set spead_2_conn [create_noc_connection -source $nmu_0 -target $spead_2_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $spead_2_conn

set_property APERTURES [list {0x201_1090_0000:0x201_1097_FFFF}] $spead_3_nsu
set spead_3_conn [create_noc_connection -source $nmu_0 -target $spead_3_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $spead_3_conn

set_property APERTURES [list {0x201_10A0_0000:0x201_10A7_FFFF}] $spead_4_nsu
set spead_4_conn [create_noc_connection -source $nmu_0 -target $spead_4_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $spead_4_conn

set_property APERTURES [list {0x201_10B0_0000:0x201_10B7_FFFF}] $spead_5_nsu
set spead_5_conn [create_noc_connection -source $nmu_0 -target $spead_5_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $spead_5_conn

#########################
# DCMAC
set_property APERTURES [list {0x201_10C0_0000:0x201_10C7_FFFF}] $dcmac_nsu
set dcmac_conn [create_noc_connection -source $nmu_0 -target $dcmac_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $dcmac_conn


###############################################
# Connect streaming AXI interface from the correlators to the spead packetiser
#  i_correlator_core/dsp_topi/spead_packetiser_top/xpm_nsu_strm_inst/M_AXIS_nsu
#  i_correlator_core/dsp_topi/correlator_geni[0].correlator_wrapperi/xpm_nmu_strm_inst/S_AXIS_nmu
#  i_correlator_core/dsp_topi/correlator_geni[1].correlator_wrapperi/xpm_nmu_strm_inst/S_AXIS_nmu
#  i_correlator_core/dsp_topi/correlator_geni[2].correlator_wrapperi/xpm_nmu_strm_inst/S_AXIS_nmu
#  i_correlator_core/dsp_topi/correlator_geni[3].correlator_wrapperi/xpm_nmu_strm_inst/S_AXIS_nmu
#  i_correlator_core/dsp_topi/correlator_geni[4].correlator_wrapperi/xpm_nmu_strm_inst/S_AXIS_nmu
#  i_correlator_core/dsp_topi/correlator_geni[5].correlator_wrapperi/xpm_nmu_strm_inst/S_AXIS_nmu
set spead_pkt_axis_rx [get_noc_interfaces i_correlator_core/dsp_topi/spead_packetiser_top/xpm_nsu_strm_inst/M_AXIS_nsu]
set cor0_pkt_axis_tx [get_noc_interfaces i_correlator_core/dsp_topi/correlator_geni[0].correlator_wrapperi/xpm_nmu_strm_inst/S_AXIS_nmu]
set cor1_pkt_axis_tx [get_noc_interfaces i_correlator_core/dsp_topi/correlator_geni[1].correlator_wrapperi/xpm_nmu_strm_inst/S_AXIS_nmu]
set cor2_pkt_axis_tx [get_noc_interfaces i_correlator_core/dsp_topi/correlator_geni[2].correlator_wrapperi/xpm_nmu_strm_inst/S_AXIS_nmu]
set cor3_pkt_axis_tx [get_noc_interfaces i_correlator_core/dsp_topi/correlator_geni[3].correlator_wrapperi/xpm_nmu_strm_inst/S_AXIS_nmu]
set cor4_pkt_axis_tx [get_noc_interfaces i_correlator_core/dsp_topi/correlator_geni[4].correlator_wrapperi/xpm_nmu_strm_inst/S_AXIS_nmu]
set cor5_pkt_axis_tx [get_noc_interfaces i_correlator_core/dsp_topi/correlator_geni[5].correlator_wrapperi/xpm_nmu_strm_inst/S_AXIS_nmu]

set cor0_pkt_con [create_noc_connection -source $cor0_pkt_axis_tx -target $spead_pkt_axis_rx]
set_property -dict [list WRITE_BANDWIDTH 10 WRITE_AVERAGE_BURST 16] $cor0_pkt_con
set cor1_pkt_con [create_noc_connection -source $cor1_pkt_axis_tx -target $spead_pkt_axis_rx]
set_property -dict [list WRITE_BANDWIDTH 10 WRITE_AVERAGE_BURST 16] $cor1_pkt_con
set cor2_pkt_con [create_noc_connection -source $cor2_pkt_axis_tx -target $spead_pkt_axis_rx]
set_property -dict [list WRITE_BANDWIDTH 10 WRITE_AVERAGE_BURST 16] $cor2_pkt_con
set cor3_pkt_con [create_noc_connection -source $cor3_pkt_axis_tx -target $spead_pkt_axis_rx]
set_property -dict [list WRITE_BANDWIDTH 10 WRITE_AVERAGE_BURST 16] $cor3_pkt_con
set cor4_pkt_con [create_noc_connection -source $cor4_pkt_axis_tx -target $spead_pkt_axis_rx]
set_property -dict [list WRITE_BANDWIDTH 10 WRITE_AVERAGE_BURST 16] $cor4_pkt_con
set cor5_pkt_con [create_noc_connection -source $cor5_pkt_axis_tx -target $spead_pkt_axis_rx]
set_property -dict [list WRITE_BANDWIDTH 10 WRITE_AVERAGE_BURST 16] $cor5_pkt_con

###############################################

# ADDRESS SPACE TO BE AWARE OF IN TOP BD
# 0x201_0FFF_FFFF for 128M assigned to DDR, this can probably be deleted 
# 0x201_0100_0000 -> 0x201_0104_FFFF Used by design components, possible to remap to higher?

# HBM connections
#i_v80_board/top_i/axi_noc_cips/HBM0_PORT0_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM0_PORT1_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM0_PORT2_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM0_PORT3_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM1_PORT0_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM1_PORT1_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM1_PORT2_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM1_PORT3_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM2_PORT0_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM2_PORT1_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM2_PORT2_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM2_PORT3_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM3_PORT0_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM3_PORT1_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM3_PORT2_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM3_PORT3_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM4_PORT0_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM4_PORT1_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM4_PORT2_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM4_PORT3_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM5_PORT0_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM5_PORT1_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM5_PORT2_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM5_PORT3_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM6_PORT0_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM6_PORT1_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM6_PORT2_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM6_PORT3_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM7_PORT0_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM7_PORT1_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM7_PORT2_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM7_PORT3_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM8_PORT0_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM8_PORT1_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM8_PORT2_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM8_PORT3_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM9_PORT0_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM9_PORT1_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM9_PORT2_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM9_PORT3_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM10_PORT0_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM10_PORT1_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM10_PORT2_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM10_PORT3_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM11_PORT0_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM11_PORT1_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM11_PORT2_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM11_PORT3_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM12_PORT0_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM12_PORT1_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM12_PORT2_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM12_PORT3_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM13_PORT0_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM13_PORT1_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM13_PORT2_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM13_PORT3_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM14_PORT0_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM14_PORT1_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM14_PORT2_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM14_PORT3_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM15_PORT0_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM15_PORT1_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM15_PORT2_hbmc
#i_v80_board/top_i/axi_noc_cips/HBM15_PORT3_hbmc

# HPM port naming convention comes from the example documentation
# However it appears an alternative name for the port_1 below is
# i_v80_board/top_i/axi_noc_cips/inst/MC_hbmc/inst/hbm_st0/I_hbm_chnl0
# and this matches the naming on the NoC diagram and get_noc_interfaces
#
# refer to PG313, v1.1, pages 95-96 for address range to memory controller
#
# Addresses used in the firmware are set in 
# ska-low-cbf-fw-corr/designs/correlator_v80/src_v80/vhdl/target_fpga_pkg.vhd
# As at 12 feb 2026 : 
#    --  Module                        HBM memory size    Address within 32 GByte space
#    --  ------                        ---------------    -----------------------------
#    --  CT1                           9 GBytes           16 to 25 GBytes
#    --  Statistics                    1 GByte            25 to 26 GBytes
#    --  CT2                           16 GBytes          0 to 16  GBytes
#    --  Correlator Visibility buffer  6 GBytes           26 to 32 GBytes

set hbm0G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM0_PORT0_hbmc]
set hbm0G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM0_PORT1_hbmc]
set hbm1G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM0_PORT2_hbmc]
set hbm1G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM0_PORT3_hbmc]
set hbm2G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM1_PORT0_hbmc]
set hbm2G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM1_PORT1_hbmc]
set hbm3G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM1_PORT2_hbmc]
set hbm3G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM1_PORT3_hbmc]
set hbm4G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM2_PORT0_hbmc]
set hbm4G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM2_PORT1_hbmc]
set hbm5G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM2_PORT2_hbmc]
set hbm5G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM2_PORT3_hbmc]
set hbm6G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM3_PORT0_hbmc]
set hbm6G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM3_PORT1_hbmc]
set hbm7G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM3_PORT2_hbmc]
set hbm7G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM3_PORT3_hbmc]
set hbm8G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM4_PORT0_hbmc]
set hbm8G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM4_PORT1_hbmc]
set hbm9G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM4_PORT2_hbmc]
set hbm9G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM4_PORT3_hbmc]
set hbm10G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM5_PORT0_hbmc]
set hbm10G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM5_PORT1_hbmc]
set hbm11G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM5_PORT2_hbmc]
set hbm11G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM5_PORT3_hbmc]
set hbm12G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM6_PORT0_hbmc]
set hbm12G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM6_PORT1_hbmc]
set hbm13G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM6_PORT2_hbmc]
set hbm13G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM6_PORT3_hbmc]
set hbm14G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM7_PORT0_hbmc]
set hbm14G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM7_PORT1_hbmc]
set hbm15G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM7_PORT2_hbmc]
set hbm15G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM7_PORT3_hbmc]
set hbm16G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM8_PORT0_hbmc]
set hbm16G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM8_PORT1_hbmc]
set hbm17G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM8_PORT2_hbmc]
set hbm17G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM8_PORT3_hbmc]
set hbm18G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM9_PORT0_hbmc]
set hbm18G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM9_PORT1_hbmc]
set hbm19G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM9_PORT2_hbmc]
set hbm19G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM9_PORT3_hbmc]
set hbm20G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM10_PORT0_hbmc]
set hbm20G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM10_PORT1_hbmc]
set hbm21G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM10_PORT2_hbmc]
set hbm21G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM10_PORT3_hbmc]
set hbm22G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM11_PORT0_hbmc]
set hbm22G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM11_PORT1_hbmc]
set hbm23G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM11_PORT2_hbmc]
set hbm23G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM11_PORT3_hbmc]
set hbm24G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM12_PORT0_hbmc]
set hbm24G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM12_PORT1_hbmc]
set hbm25G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM12_PORT2_hbmc]
set hbm25G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM12_PORT3_hbmc]
set hbm26G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM13_PORT0_hbmc]
set hbm26G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM13_PORT1_hbmc]
set hbm27G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM13_PORT2_hbmc]
set hbm27G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM13_PORT3_hbmc]
set hbm28G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM14_PORT0_hbmc]
set hbm28G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM14_PORT1_hbmc]
set hbm29G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM14_PORT2_hbmc]
set hbm29G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM14_PORT3_hbmc]
set hbm30G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM15_PORT0_hbmc]
set hbm30G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM15_PORT1_hbmc]
set hbm31G_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM15_PORT2_hbmc]
set hbm31G_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM15_PORT3_hbmc]

######################################
## Statistics write to HBM
set sps_stats_wr [get_noc_interfaces i_correlator_core/HBM_SPS_MONi/vnoc_gen.hbm_noci/S_AXI_nmu]
set hbm_sps_stats [create_noc_connection -source $sps_stats_wr -target $hbm25G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 64] $hbm_sps_stats
## HBM ILA write to HBM - same 1G space as statistics
set hbm_ila_wr [get_noc_interfaces i_correlator_core/dsp_topi/SPS_HBM_ILA/hbm_noc_geni.hbm_noci/S_AXI_nmu]
set hbm_ila_wr0 [create_noc_connection -source $hbm_ila_wr -target $hbm25G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 64] $hbm_ila_wr0
######################################
## Write SPS data to HBM
set hbm_input_1 [get_noc_interfaces i_correlator_core/dsp_topi/SPS_HBM_write0/vnoc_gen.hbm_noci/S_AXI_nmu]
set hbm_conn_sps0_wr0 [create_noc_connection -source $hbm_input_1 -target $hbm16G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 1000 WRITE_AVERAGE_BURST 64] $hbm_conn_sps0_wr0
set hbm_conn_sps0_wr1 [create_noc_connection -source $hbm_input_1 -target $hbm17G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 1000 WRITE_AVERAGE_BURST 64] $hbm_conn_sps0_wr1
set hbm_conn_sps0_wr2 [create_noc_connection -source $hbm_input_1 -target $hbm18G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 1000 WRITE_AVERAGE_BURST 64] $hbm_conn_sps0_wr2
set hbm_conn_sps0_wr3 [create_noc_connection -source $hbm_input_1 -target $hbm19G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 1000 WRITE_AVERAGE_BURST 64] $hbm_conn_sps0_wr3
set hbm_conn_sps0_wr4 [create_noc_connection -source $hbm_input_1 -target $hbm20G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 1000 WRITE_AVERAGE_BURST 64] $hbm_conn_sps0_wr4
set hbm_conn_sps0_wr5 [create_noc_connection -source $hbm_input_1 -target $hbm21G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 1000 WRITE_AVERAGE_BURST 64] $hbm_conn_sps0_wr5
set hbm_conn_sps0_wr6 [create_noc_connection -source $hbm_input_1 -target $hbm22G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 1000 WRITE_AVERAGE_BURST 64] $hbm_conn_sps0_wr6
set hbm_conn_sps0_wr7 [create_noc_connection -source $hbm_input_1 -target $hbm23G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 1000 WRITE_AVERAGE_BURST 64] $hbm_conn_sps0_wr7
set hbm_conn_sps0_wr8 [create_noc_connection -source $hbm_input_1 -target $hbm24G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 1000 WRITE_AVERAGE_BURST 64] $hbm_conn_sps0_wr8

set hbm_input_2 [get_noc_interfaces i_correlator_core/dsp_topi/SPS_HBM_write1/vnoc_gen.hbm_noci/S_AXI_nmu]
set hbm_conn_sps1_wr0 [create_noc_connection -source $hbm_input_2 -target $hbm16G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 1000 WRITE_AVERAGE_BURST 64] $hbm_conn_sps1_wr0
set hbm_conn_sps1_wr1 [create_noc_connection -source $hbm_input_2 -target $hbm17G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 1000 WRITE_AVERAGE_BURST 64] $hbm_conn_sps1_wr1
set hbm_conn_sps1_wr2 [create_noc_connection -source $hbm_input_2 -target $hbm18G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 1000 WRITE_AVERAGE_BURST 64] $hbm_conn_sps1_wr2
set hbm_conn_sps1_wr3 [create_noc_connection -source $hbm_input_2 -target $hbm19G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 1000 WRITE_AVERAGE_BURST 64] $hbm_conn_sps1_wr3
set hbm_conn_sps1_wr4 [create_noc_connection -source $hbm_input_2 -target $hbm20G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 1000 WRITE_AVERAGE_BURST 64] $hbm_conn_sps1_wr4
set hbm_conn_sps1_wr5 [create_noc_connection -source $hbm_input_2 -target $hbm21G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 1000 WRITE_AVERAGE_BURST 64] $hbm_conn_sps1_wr5
set hbm_conn_sps1_wr6 [create_noc_connection -source $hbm_input_2 -target $hbm22G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 1000 WRITE_AVERAGE_BURST 64] $hbm_conn_sps1_wr6
set hbm_conn_sps1_wr7 [create_noc_connection -source $hbm_input_2 -target $hbm23G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 1000 WRITE_AVERAGE_BURST 64] $hbm_conn_sps1_wr7
set hbm_conn_sps1_wr8 [create_noc_connection -source $hbm_input_2 -target $hbm24G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 1000 WRITE_AVERAGE_BURST 64] $hbm_conn_sps1_wr8

#########################################
## Corner Turn 1 read SPS data
set ct1_read_1 [get_noc_interfaces i_correlator_core/dsp_topi/CT1_HBM_read0/hbm_noc_geni.hbm_noci/S_AXI_nmu]
set hbm_ct1_0_rd0 [create_noc_connection -source $ct1_read_1 -target $hbm16G_port0]
set_property -dict [list READ_BANDWIDTH 600 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_ct1_0_rd0
set hbm_ct1_0_rd1 [create_noc_connection -source $ct1_read_1 -target $hbm17G_port0]
set_property -dict [list READ_BANDWIDTH 600 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_ct1_0_rd1
set hbm_ct1_0_rd2 [create_noc_connection -source $ct1_read_1 -target $hbm18G_port0]
set_property -dict [list READ_BANDWIDTH 600 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_ct1_0_rd2
set hbm_ct1_0_rd3 [create_noc_connection -source $ct1_read_1 -target $hbm19G_port0]
set_property -dict [list READ_BANDWIDTH 600 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_ct1_0_rd3
set hbm_ct1_0_rd4 [create_noc_connection -source $ct1_read_1 -target $hbm20G_port0]
set_property -dict [list READ_BANDWIDTH 600 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_ct1_0_rd4
set hbm_ct1_0_rd5 [create_noc_connection -source $ct1_read_1 -target $hbm21G_port0]
set_property -dict [list READ_BANDWIDTH 600 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_ct1_0_rd5
set hbm_ct1_0_rd6 [create_noc_connection -source $ct1_read_1 -target $hbm22G_port0]
set_property -dict [list READ_BANDWIDTH 600 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_ct1_0_rd6
set hbm_ct1_0_rd7 [create_noc_connection -source $ct1_read_1 -target $hbm23G_port0]
set_property -dict [list READ_BANDWIDTH 600 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_ct1_0_rd7
set hbm_ct1_0_rd8 [create_noc_connection -source $ct1_read_1 -target $hbm24G_port0]
set_property -dict [list READ_BANDWIDTH 600 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_ct1_0_rd8

set ct1_read_2 [get_noc_interfaces i_correlator_core/dsp_topi/CT1_HBM_read0/hbm_noc_geni.hbm_noci/S_AXI_nmu]
set hbm_ct1_1_rd0 [create_noc_connection -source $ct1_read_2 -target $hbm16G_port1]
set_property -dict [list READ_BANDWIDTH 600 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_ct1_1_rd0
set hbm_ct1_1_rd1 [create_noc_connection -source $ct1_read_2 -target $hbm17G_port1]
set_property -dict [list READ_BANDWIDTH 600 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_ct1_1_rd1
set hbm_ct1_1_rd2 [create_noc_connection -source $ct1_read_2 -target $hbm18G_port1]
set_property -dict [list READ_BANDWIDTH 600 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_ct1_1_rd2
set hbm_ct1_1_rd3 [create_noc_connection -source $ct1_read_2 -target $hbm19G_port1]
set_property -dict [list READ_BANDWIDTH 600 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_ct1_1_rd3
set hbm_ct1_1_rd4 [create_noc_connection -source $ct1_read_2 -target $hbm20G_port1]
set_property -dict [list READ_BANDWIDTH 600 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_ct1_1_rd4
set hbm_ct1_1_rd5 [create_noc_connection -source $ct1_read_2 -target $hbm21G_port1]
set_property -dict [list READ_BANDWIDTH 600 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_ct1_1_rd5
set hbm_ct1_1_rd6 [create_noc_connection -source $ct1_read_2 -target $hbm22G_port1]
set_property -dict [list READ_BANDWIDTH 600 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_ct1_1_rd6
set hbm_ct1_1_rd7 [create_noc_connection -source $ct1_read_2 -target $hbm23G_port1]
set_property -dict [list READ_BANDWIDTH 600 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_ct1_1_rd7
set hbm_ct1_1_rd8 [create_noc_connection -source $ct1_read_2 -target $hbm24G_port1]
set_property -dict [list READ_BANDWIDTH 600 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_ct1_1_rd8


######################################
# 16GB for CT2 writes
set ct2_wr_1 [get_noc_interfaces i_correlator_core/dsp_topi/ct_cor_out_inst/HBM0i/hbm_noc_geni.hbm_noci/S_AXI_nmu]
set hbm_conn_ct2_0_wr0 [create_noc_connection -source $ct2_wr_1 -target $hbm0G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_0_wr0
set hbm_conn_ct2_0_wr1 [create_noc_connection -source $ct2_wr_1 -target $hbm1G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_0_wr1
set hbm_conn_ct2_0_wr2 [create_noc_connection -source $ct2_wr_1 -target $hbm2G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_0_wr2
set hbm_conn_ct2_0_wr3 [create_noc_connection -source $ct2_wr_1 -target $hbm3G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_0_wr3
set hbm_conn_ct2_0_wr4 [create_noc_connection -source $ct2_wr_1 -target $hbm4G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_0_wr4
set hbm_conn_ct2_0_wr5 [create_noc_connection -source $ct2_wr_1 -target $hbm5G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_0_wr5
set hbm_conn_ct2_0_wr6 [create_noc_connection -source $ct2_wr_1 -target $hbm6G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_0_wr6
set hbm_conn_ct2_0_wr7 [create_noc_connection -source $ct2_wr_1 -target $hbm7G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_0_wr7
set hbm_conn_ct2_0_wr8 [create_noc_connection -source $ct2_wr_1 -target $hbm8G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_0_wr8
set hbm_conn_ct2_0_wr9 [create_noc_connection -source $ct2_wr_1 -target $hbm9G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_0_wr9
set hbm_conn_ct2_0_wr10 [create_noc_connection -source $ct2_wr_1 -target $hbm10G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_0_wr10
set hbm_conn_ct2_0_wr11 [create_noc_connection -source $ct2_wr_1 -target $hbm11G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_0_wr11
set hbm_conn_ct2_0_wr12 [create_noc_connection -source $ct2_wr_1 -target $hbm12G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_0_wr12
set hbm_conn_ct2_0_wr13 [create_noc_connection -source $ct2_wr_1 -target $hbm13G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_0_wr13
set hbm_conn_ct2_0_wr14 [create_noc_connection -source $ct2_wr_1 -target $hbm14G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_0_wr14
set hbm_conn_ct2_0_wr15 [create_noc_connection -source $ct2_wr_1 -target $hbm15G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_0_wr15

set ct2_wr_2 [get_noc_interfaces i_correlator_core/dsp_topi/ct_cor_out_inst/HBM1i/hbm_noc_geni.hbm_noci/S_AXI_nmu]
set hbm_conn_ct2_1_wr0 [create_noc_connection -source $ct2_wr_2 -target $hbm0G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_1_wr0
set hbm_conn_ct2_1_wr1 [create_noc_connection -source $ct2_wr_2 -target $hbm1G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_1_wr1
set hbm_conn_ct2_1_wr2 [create_noc_connection -source $ct2_wr_2 -target $hbm2G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_1_wr2
set hbm_conn_ct2_1_wr3 [create_noc_connection -source $ct2_wr_2 -target $hbm3G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_1_wr3
set hbm_conn_ct2_1_wr4 [create_noc_connection -source $ct2_wr_2 -target $hbm4G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_1_wr4
set hbm_conn_ct2_1_wr5 [create_noc_connection -source $ct2_wr_2 -target $hbm5G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_1_wr5
set hbm_conn_ct2_1_wr6 [create_noc_connection -source $ct2_wr_2 -target $hbm6G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_1_wr6
set hbm_conn_ct2_1_wr7 [create_noc_connection -source $ct2_wr_2 -target $hbm7G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_1_wr7
set hbm_conn_ct2_1_wr8 [create_noc_connection -source $ct2_wr_2 -target $hbm8G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_1_wr8
set hbm_conn_ct2_1_wr9 [create_noc_connection -source $ct2_wr_2 -target $hbm9G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_1_wr9
set hbm_conn_ct2_1_wr10 [create_noc_connection -source $ct2_wr_2 -target $hbm10G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_1_wr10
set hbm_conn_ct2_1_wr11 [create_noc_connection -source $ct2_wr_2 -target $hbm11G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_1_wr11
set hbm_conn_ct2_1_wr12 [create_noc_connection -source $ct2_wr_2 -target $hbm12G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_1_wr12
set hbm_conn_ct2_1_wr13 [create_noc_connection -source $ct2_wr_2 -target $hbm13G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_1_wr13
set hbm_conn_ct2_1_wr14 [create_noc_connection -source $ct2_wr_2 -target $hbm14G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_1_wr14
set hbm_conn_ct2_1_wr15 [create_noc_connection -source $ct2_wr_2 -target $hbm15G_port1]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_1_wr15

######################################
# 16GB for CT2 read interfaces for each correlator instance

set corr_rd_0 [get_noc_interfaces i_correlator_core/dsp_topi/correlator_geni[0].correlator_wrapperi/HBM_readi/hbm_noc_geni.hbm_noci/S_AXI_nmu]
set hbm_conn0_corr_rd_0 [create_noc_connection -source $corr_rd_0 -target $hbm0G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn0_corr_rd_0
set hbm_conn1_corr_rd_0 [create_noc_connection -source $corr_rd_0 -target $hbm1G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn1_corr_rd_0
set hbm_conn2_corr_rd_0 [create_noc_connection -source $corr_rd_0 -target $hbm2G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn2_corr_rd_0
set hbm_conn3_corr_rd_0 [create_noc_connection -source $corr_rd_0 -target $hbm3G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn3_corr_rd_0
set hbm_conn4_corr_rd_0 [create_noc_connection -source $corr_rd_0 -target $hbm4G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn4_corr_rd_0
set hbm_conn5_corr_rd_0 [create_noc_connection -source $corr_rd_0 -target $hbm5G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn5_corr_rd_0
set hbm_conn6_corr_rd_0 [create_noc_connection -source $corr_rd_0 -target $hbm6G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn6_corr_rd_0
set hbm_conn7_corr_rd_0 [create_noc_connection -source $corr_rd_0 -target $hbm7G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn7_corr_rd_0
set hbm_conn8_corr_rd_0 [create_noc_connection -source $corr_rd_0 -target $hbm8G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn8_corr_rd_0
set hbm_conn9_corr_rd_0 [create_noc_connection -source $corr_rd_0 -target $hbm9G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn9_corr_rd_0
set hbm_conn10_corr_rd_0 [create_noc_connection -source $corr_rd_0 -target $hbm10G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn10_corr_rd_0
set hbm_conn11_corr_rd_0 [create_noc_connection -source $corr_rd_0 -target $hbm11G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn11_corr_rd_0
set hbm_conn12_corr_rd_0 [create_noc_connection -source $corr_rd_0 -target $hbm12G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn12_corr_rd_0
set hbm_conn13_corr_rd_0 [create_noc_connection -source $corr_rd_0 -target $hbm13G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn13_corr_rd_0
set hbm_conn14_corr_rd_0 [create_noc_connection -source $corr_rd_0 -target $hbm14G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn14_corr_rd_0
set hbm_conn15_corr_rd_0 [create_noc_connection -source $corr_rd_0 -target $hbm15G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn15_corr_rd_0

set corr_rd_1 [get_noc_interfaces i_correlator_core/dsp_topi/correlator_geni[1].correlator_wrapperi/HBM_readi/vnoc_gen.hbm_noci/S_AXI_nmu]
set hbm_conn0_corr_rd_1 [create_noc_connection -source $corr_rd_1 -target $hbm0G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn0_corr_rd_1
set hbm_conn1_corr_rd_1 [create_noc_connection -source $corr_rd_1 -target $hbm1G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn1_corr_rd_1
set hbm_conn2_corr_rd_1 [create_noc_connection -source $corr_rd_1 -target $hbm2G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn2_corr_rd_1
set hbm_conn3_corr_rd_1 [create_noc_connection -source $corr_rd_1 -target $hbm3G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn3_corr_rd_1
set hbm_conn4_corr_rd_1 [create_noc_connection -source $corr_rd_1 -target $hbm4G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn4_corr_rd_1
set hbm_conn5_corr_rd_1 [create_noc_connection -source $corr_rd_1 -target $hbm5G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn5_corr_rd_1
set hbm_conn6_corr_rd_1 [create_noc_connection -source $corr_rd_1 -target $hbm6G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn6_corr_rd_1
set hbm_conn7_corr_rd_1 [create_noc_connection -source $corr_rd_1 -target $hbm7G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn7_corr_rd_1
set hbm_conn8_corr_rd_1 [create_noc_connection -source $corr_rd_1 -target $hbm8G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn8_corr_rd_1
set hbm_conn9_corr_rd_1 [create_noc_connection -source $corr_rd_1 -target $hbm9G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn9_corr_rd_1
set hbm_conn10_corr_rd_1 [create_noc_connection -source $corr_rd_1 -target $hbm10G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn10_corr_rd_1
set hbm_conn11_corr_rd_1 [create_noc_connection -source $corr_rd_1 -target $hbm11G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn11_corr_rd_1
set hbm_conn12_corr_rd_1 [create_noc_connection -source $corr_rd_1 -target $hbm12G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn12_corr_rd_1
set hbm_conn13_corr_rd_1 [create_noc_connection -source $corr_rd_1 -target $hbm13G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn13_corr_rd_1
set hbm_conn14_corr_rd_1 [create_noc_connection -source $corr_rd_1 -target $hbm14G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn14_corr_rd_1
set hbm_conn15_corr_rd_1 [create_noc_connection -source $corr_rd_1 -target $hbm15G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn15_corr_rd_1

set corr_rd_2 [get_noc_interfaces i_correlator_core/dsp_topi/correlator_geni[2].correlator_wrapperi/HBM_readi/vnoc_gen.hbm_noci/S_AXI_nmu]
set hbm_conn0_corr_rd_2 [create_noc_connection -source $corr_rd_2 -target $hbm0G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn0_corr_rd_2
set hbm_conn1_corr_rd_2 [create_noc_connection -source $corr_rd_2 -target $hbm1G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn1_corr_rd_2
set hbm_conn2_corr_rd_2 [create_noc_connection -source $corr_rd_2 -target $hbm2G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn2_corr_rd_2
set hbm_conn3_corr_rd_2 [create_noc_connection -source $corr_rd_2 -target $hbm3G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn3_corr_rd_2
set hbm_conn4_corr_rd_2 [create_noc_connection -source $corr_rd_2 -target $hbm4G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn4_corr_rd_2
set hbm_conn5_corr_rd_2 [create_noc_connection -source $corr_rd_2 -target $hbm5G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn5_corr_rd_2
set hbm_conn6_corr_rd_2 [create_noc_connection -source $corr_rd_2 -target $hbm6G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn6_corr_rd_2
set hbm_conn7_corr_rd_2 [create_noc_connection -source $corr_rd_2 -target $hbm7G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn7_corr_rd_2
set hbm_conn8_corr_rd_2 [create_noc_connection -source $corr_rd_2 -target $hbm8G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn8_corr_rd_2
set hbm_conn9_corr_rd_2 [create_noc_connection -source $corr_rd_2 -target $hbm9G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn9_corr_rd_2
set hbm_conn10_corr_rd_2 [create_noc_connection -source $corr_rd_2 -target $hbm10G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn10_corr_rd_2
set hbm_conn11_corr_rd_2 [create_noc_connection -source $corr_rd_2 -target $hbm11G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn11_corr_rd_2
set hbm_conn12_corr_rd_2 [create_noc_connection -source $corr_rd_2 -target $hbm12G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn12_corr_rd_2
set hbm_conn13_corr_rd_2 [create_noc_connection -source $corr_rd_2 -target $hbm13G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn13_corr_rd_2
set hbm_conn14_corr_rd_2 [create_noc_connection -source $corr_rd_2 -target $hbm14G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn14_corr_rd_2
set hbm_conn15_corr_rd_2 [create_noc_connection -source $corr_rd_2 -target $hbm15G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn15_corr_rd_2

set corr_rd_3 [get_noc_interfaces i_correlator_core/dsp_topi/correlator_geni[3].correlator_wrapperi/HBM_readi/vnoc_gen.hbm_noci/S_AXI_nmu]
set hbm_conn0_corr_rd_3 [create_noc_connection -source $corr_rd_3 -target $hbm0G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn0_corr_rd_3
set hbm_conn1_corr_rd_3 [create_noc_connection -source $corr_rd_3 -target $hbm1G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn1_corr_rd_3
set hbm_conn2_corr_rd_3 [create_noc_connection -source $corr_rd_3 -target $hbm2G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn2_corr_rd_3
set hbm_conn3_corr_rd_3 [create_noc_connection -source $corr_rd_3 -target $hbm3G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn3_corr_rd_3
set hbm_conn4_corr_rd_3 [create_noc_connection -source $corr_rd_3 -target $hbm4G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn4_corr_rd_3
set hbm_conn5_corr_rd_3 [create_noc_connection -source $corr_rd_3 -target $hbm5G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn5_corr_rd_3
set hbm_conn6_corr_rd_3 [create_noc_connection -source $corr_rd_3 -target $hbm6G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn6_corr_rd_3
set hbm_conn7_corr_rd_3 [create_noc_connection -source $corr_rd_3 -target $hbm7G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn7_corr_rd_3
set hbm_conn8_corr_rd_3 [create_noc_connection -source $corr_rd_3 -target $hbm8G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn8_corr_rd_3
set hbm_conn9_corr_rd_3 [create_noc_connection -source $corr_rd_3 -target $hbm9G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn9_corr_rd_3
set hbm_conn10_corr_rd_3 [create_noc_connection -source $corr_rd_3 -target $hbm10G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn10_corr_rd_3
set hbm_conn11_corr_rd_3 [create_noc_connection -source $corr_rd_3 -target $hbm11G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn11_corr_rd_3
set hbm_conn12_corr_rd_3 [create_noc_connection -source $corr_rd_3 -target $hbm12G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn12_corr_rd_3
set hbm_conn13_corr_rd_3 [create_noc_connection -source $corr_rd_3 -target $hbm13G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn13_corr_rd_3
set hbm_conn14_corr_rd_3 [create_noc_connection -source $corr_rd_3 -target $hbm14G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn14_corr_rd_3
set hbm_conn15_corr_rd_3 [create_noc_connection -source $corr_rd_3 -target $hbm15G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn15_corr_rd_3

set corr_rd_4 [get_noc_interfaces i_correlator_core/dsp_topi/correlator_geni[4].correlator_wrapperi/HBM_readi/vnoc_gen.hbm_noci/S_AXI_nmu]
set hbm_conn0_corr_rd_4 [create_noc_connection -source $corr_rd_4 -target $hbm0G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn0_corr_rd_4
set hbm_conn1_corr_rd_4 [create_noc_connection -source $corr_rd_4 -target $hbm1G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn1_corr_rd_4
set hbm_conn2_corr_rd_4 [create_noc_connection -source $corr_rd_4 -target $hbm2G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn2_corr_rd_4
set hbm_conn3_corr_rd_4 [create_noc_connection -source $corr_rd_4 -target $hbm3G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn3_corr_rd_4
set hbm_conn4_corr_rd_4 [create_noc_connection -source $corr_rd_4 -target $hbm4G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn4_corr_rd_4
set hbm_conn5_corr_rd_4 [create_noc_connection -source $corr_rd_4 -target $hbm5G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn5_corr_rd_4
set hbm_conn6_corr_rd_4 [create_noc_connection -source $corr_rd_4 -target $hbm6G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn6_corr_rd_4
set hbm_conn7_corr_rd_4 [create_noc_connection -source $corr_rd_4 -target $hbm7G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn7_corr_rd_4
set hbm_conn8_corr_rd_4 [create_noc_connection -source $corr_rd_4 -target $hbm8G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn8_corr_rd_4
set hbm_conn9_corr_rd_4 [create_noc_connection -source $corr_rd_4 -target $hbm9G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn9_corr_rd_4
set hbm_conn10_corr_rd_4 [create_noc_connection -source $corr_rd_4 -target $hbm10G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn10_corr_rd_4
set hbm_conn11_corr_rd_4 [create_noc_connection -source $corr_rd_4 -target $hbm11G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn11_corr_rd_4
set hbm_conn12_corr_rd_4 [create_noc_connection -source $corr_rd_4 -target $hbm12G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn12_corr_rd_4
set hbm_conn13_corr_rd_4 [create_noc_connection -source $corr_rd_4 -target $hbm13G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn13_corr_rd_4
set hbm_conn14_corr_rd_4 [create_noc_connection -source $corr_rd_4 -target $hbm14G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn14_corr_rd_4
set hbm_conn15_corr_rd_4 [create_noc_connection -source $corr_rd_4 -target $hbm15G_port0]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn15_corr_rd_4

set corr_rd_5 [get_noc_interfaces i_correlator_core/dsp_topi/correlator_geni[5].correlator_wrapperi/HBM_readi/vnoc_gen.hbm_noci/S_AXI_nmu]
set hbm_conn0_corr_rd_5 [create_noc_connection -source $corr_rd_5 -target $hbm0G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn0_corr_rd_5
set hbm_conn1_corr_rd_5 [create_noc_connection -source $corr_rd_5 -target $hbm1G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn1_corr_rd_5
set hbm_conn2_corr_rd_5 [create_noc_connection -source $corr_rd_5 -target $hbm2G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn2_corr_rd_5
set hbm_conn3_corr_rd_5 [create_noc_connection -source $corr_rd_5 -target $hbm3G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn3_corr_rd_5
set hbm_conn4_corr_rd_5 [create_noc_connection -source $corr_rd_5 -target $hbm4G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn4_corr_rd_5
set hbm_conn5_corr_rd_5 [create_noc_connection -source $corr_rd_5 -target $hbm5G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn5_corr_rd_5
set hbm_conn6_corr_rd_5 [create_noc_connection -source $corr_rd_5 -target $hbm6G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn6_corr_rd_5
set hbm_conn7_corr_rd_5 [create_noc_connection -source $corr_rd_5 -target $hbm7G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn7_corr_rd_5
set hbm_conn8_corr_rd_5 [create_noc_connection -source $corr_rd_5 -target $hbm8G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn8_corr_rd_5
set hbm_conn9_corr_rd_5 [create_noc_connection -source $corr_rd_5 -target $hbm9G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn9_corr_rd_5
set hbm_conn10_corr_rd_5 [create_noc_connection -source $corr_rd_5 -target $hbm10G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn10_corr_rd_5
set hbm_conn11_corr_rd_5 [create_noc_connection -source $corr_rd_5 -target $hbm11G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn11_corr_rd_5
set hbm_conn12_corr_rd_5 [create_noc_connection -source $corr_rd_5 -target $hbm12G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn12_corr_rd_5
set hbm_conn13_corr_rd_5 [create_noc_connection -source $corr_rd_5 -target $hbm13G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn13_corr_rd_5
set hbm_conn14_corr_rd_5 [create_noc_connection -source $corr_rd_5 -target $hbm14G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn14_corr_rd_5
set hbm_conn15_corr_rd_5 [create_noc_connection -source $corr_rd_5 -target $hbm15G_port1]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn15_corr_rd_5

######################################
# 1GB for Visibility buffers for each correlator instance
# Write to HBM

# First correlator core in SLR0, uses hbm noc
set vis_wr_0 [get_noc_interfaces i_correlator_core/dsp_topi/correlator_geni[0].correlator_wrapperi/HBM_writei/hbm_noc_geni.hbm_noci/S_AXI_nmu]
set hbm_conn0_vis_wr [create_noc_connection -source $vis_wr_0 -target $hbm26G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 4200 WRITE_AVERAGE_BURST 64] $hbm_conn0_vis_wr

# remaining correlator cores in SLR1 or SLR2, use vnoc
set vis_wr_1 [get_noc_interfaces i_correlator_core/dsp_topi/correlator_geni[1].correlator_wrapperi/HBM_writei/vnoc_gen.hbm_noci/S_AXI_nmu]
set hbm_conn1_vis_wr [create_noc_connection -source $vis_wr_1 -target $hbm27G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 4200 WRITE_AVERAGE_BURST 64] $hbm_conn1_vis_wr

set vis_wr_2 [get_noc_interfaces i_correlator_core/dsp_topi/correlator_geni[2].correlator_wrapperi/HBM_writei/vnoc_gen.hbm_noci/S_AXI_nmu]
set hbm_conn2_vis_wr [create_noc_connection -source $vis_wr_2 -target $hbm28G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 4200 WRITE_AVERAGE_BURST 64] $hbm_conn2_vis_wr

set vis_wr_3 [get_noc_interfaces i_correlator_core/dsp_topi/correlator_geni[3].correlator_wrapperi/HBM_writei/vnoc_gen.hbm_noci/S_AXI_nmu]
set hbm_conn3_vis_wr [create_noc_connection -source $vis_wr_3 -target $hbm29G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 4200 WRITE_AVERAGE_BURST 64] $hbm_conn3_vis_wr

set vis_wr_4 [get_noc_interfaces i_correlator_core/dsp_topi/correlator_geni[4].correlator_wrapperi/HBM_writei/vnoc_gen.hbm_noci/S_AXI_nmu]
set hbm_conn4_vis_wr [create_noc_connection -source $vis_wr_4 -target $hbm30G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 4200 WRITE_AVERAGE_BURST 64] $hbm_conn4_vis_wr

set vis_wr_5 [get_noc_interfaces i_correlator_core/dsp_topi/correlator_geni[5].correlator_wrapperi/HBM_writei/vnoc_gen.hbm_noci/S_AXI_nmu]
set hbm_conn5_vis_wr [create_noc_connection -source $vis_wr_5 -target $hbm31G_port0]
set_property -dict [list READ_BANDWIDTH 0 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 4200 WRITE_AVERAGE_BURST 64] $hbm_conn5_vis_wr

# Read from HBM
set vis_rd_0 [get_noc_interfaces i_correlator_core/dsp_topi/spead_packetiser_top/read_pkt_geni[0].HBM_readi/vnoc_gen.hbm_noci/S_AXI_nmu]
set hbm_conn0_vis_rd [create_noc_connection -source $vis_rd_0 -target $hbm26G_port1]
set_property -dict [list READ_BANDWIDTH 4200 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn0_vis_rd

set vis_rd_1 [get_noc_interfaces i_correlator_core/dsp_topi/spead_packetiser_top/read_pkt_geni[1].HBM_readi/vnoc_gen.hbm_noci/S_AXI_nmu]
set hbm_conn1_vis_rd [create_noc_connection -source $vis_rd_1 -target $hbm27G_port1]
set_property -dict [list READ_BANDWIDTH 4200 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn1_vis_rd

set vis_rd_2 [get_noc_interfaces i_correlator_core/dsp_topi/spead_packetiser_top/read_pkt_geni[2].HBM_readi/vnoc_gen.hbm_noci/S_AXI_nmu]
set hbm_conn2_vis_rd [create_noc_connection -source $vis_rd_2 -target $hbm28G_port1]
set_property -dict [list READ_BANDWIDTH 4200 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn2_vis_rd

set vis_rd_3 [get_noc_interfaces i_correlator_core/dsp_topi/spead_packetiser_top/read_pkt_geni[3].HBM_readi/vnoc_gen.hbm_noci/S_AXI_nmu]
set hbm_conn3_vis_rd [create_noc_connection -source $vis_rd_3 -target $hbm29G_port1]
set_property -dict [list READ_BANDWIDTH 4200 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn3_vis_rd

set vis_rd_4 [get_noc_interfaces i_correlator_core/dsp_topi/spead_packetiser_top/read_pkt_geni[4].HBM_readi/vnoc_gen.hbm_noci/S_AXI_nmu]
set hbm_conn4_vis_rd [create_noc_connection -source $vis_rd_4 -target $hbm30G_port1]
set_property -dict [list READ_BANDWIDTH 4200 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn4_vis_rd

set vis_rd_5 [get_noc_interfaces i_correlator_core/dsp_topi/spead_packetiser_top/read_pkt_geni[5].HBM_readi/vnoc_gen.hbm_noci/S_AXI_nmu]
set hbm_conn5_vis_rd [create_noc_connection -source $vis_rd_5 -target $hbm31G_port1]
set_property -dict [list READ_BANDWIDTH 4200 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 0 WRITE_AVERAGE_BURST 64] $hbm_conn5_vis_rd

