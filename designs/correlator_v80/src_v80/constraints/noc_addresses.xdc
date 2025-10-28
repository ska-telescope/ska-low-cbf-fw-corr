#create_noc_connection -source [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/S00_AXI_nmu] -target [get_noc_interfaces i_system_noc/xpm_nsu_mm_inst/M_AXI_nsu]
# Mappings are master to slave
# Args infers a NoC Slave interface

################
## These are all heirarchy mappings, beware when updating code.
set nmu_0 [get_noc_interfaces "i_v80_board/top_i/axi_noc_cips/S00_AXI_nmu"]
set system_nsu [get_noc_interfaces "i_correlator_core/i_system_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
set lfaa_1_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/LFAAin/gen_v80_args.i_lfaa_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
set ct_1_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/LFAA_FB_CT/gen_v80_args.i_ct1_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
set fb_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/FBreali.corFB_i/gen_v80_args.i_fb_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
set ct_2_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/ct_cor_out_inst/gen_v80_args.i_ct2_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
set corr_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/correlator_inst/gen_v80_args.i_cor_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
set spead_1_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/spead_packetiser_top/cor_speader/host_interface/gen_v80_args.i_spead_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
set spead_2_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/spead_packetiser_top/additional_packetiser_gen.cor_speader/host_interface/gen_v80_args.i_spead_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
set spead_hbmrd_1_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/correlator_inst/cor1geni.icor1/HBM_reader/gen_v80_args.i_ct2_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
set spead_hbmrd_2_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/correlator_inst/cor2geni.icor2/HBM_reader/gen_v80_args.i_ct2_noc/xpm_nsu_mm_inst/M_AXI_nsu"]
set dcmac_nsu [get_noc_interfaces "i_dcmac_wrapper/i_port_0_stats/i_dcmac_noc/xpm_nsu_mm_inst/M_AXI_nsu"]

# Base address for the PL region and this is also mapped to BAR 0 - 0x201_0000_0000
# correlator ARGs
#    Including slave ports for correlator_v80: 
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

# use the above list just for ordering of the NSUs
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
set_property APERTURES [list {0x201_1050_0000:0x201_1057_FFFF}] $corr_nsu

set corr_conn [create_noc_connection -source $nmu_0 -target $corr_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $corr_conn
########################
# SPEAD
set_property APERTURES [list {0x201_1060_0000:0x201_1067_FFFF}] $spead_1_nsu

set spead_conn [create_noc_connection -source $nmu_0 -target $spead_1_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $spead_conn
########################
# SPEAD 2
set_property APERTURES [list {0x201_1070_0000:0x201_1077_FFFF}] $spead_2_nsu

set spead_2_conn [create_noc_connection -source $nmu_0 -target $spead_2_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $spead_2_conn
########################
# Spead HBM
set_property APERTURES [list {0x201_1080_0000:0x201_1087_FFFF}] $spead_hbmrd_1_nsu

set spead_hbm_conn [create_noc_connection -source $nmu_0 -target $spead_hbmrd_1_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $spead_hbm_conn
########################
# Spead HBM 2
set_property APERTURES [list {0x201_1090_0000:0x201_1097_FFFF}] $spead_hbmrd_2_nsu

set spead_hbm_2_conn [create_noc_connection -source $nmu_0 -target $spead_hbmrd_2_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $spead_hbm_2_conn
#########################
# DCMAC
set_property APERTURES [list {0x201_10A0_0000:0x201_10A7_FFFF}] $dcmac_nsu

set dcmac_conn [create_noc_connection -source $nmu_0 -target $dcmac_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $dcmac_conn


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

# HPM port naming convention comes from the expample documentation
# However it appears an alternative name for the port_1 below is
# i_v80_board/top_i/axi_noc_cips/inst/MC_hbmc/inst/hbm_st0/I_hbm_chnl0
# and this matches the naming on the NoC diagram and get_noc_interfaces
#
# refer to PG313, v1.1, pages 95-96 for address range to memory controller
#
# the GT for the network connection is on the right hand side on the device map
# assume NoC map is the same, assign LFAA input to the right side as well
# this means HBM14 and 15.

######################################
## HBM LFAA - HBM14 and 15, 3GB
set hbm14_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM14_PORT0_hbmc]
set hbm_input_1 [get_noc_interfaces i_correlator_core/axi_HBM_gen[0].i_hbm_noc/S_AXI_nmu]
set hbm_conn_lfaa_1 [create_noc_connection -source $hbm_input_1 -target $hbm14_port0]
set_property -dict [list READ_BANDWIDTH 4200 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 4200 WRITE_AVERAGE_BURST 64] $hbm_conn_lfaa_1

set hbm14_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM14_PORT2_hbmc]
set hbm_input_1 [get_noc_interfaces i_correlator_core/axi_HBM_gen[0].i_hbm_noc/S_AXI_nmu]
set hbm_conn_lfaa_2 [create_noc_connection -source $hbm_input_1 -target $hbm14_port1]
set_property -dict [list READ_BANDWIDTH 4200 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 4200 WRITE_AVERAGE_BURST 64] $hbm_conn_lfaa_2

set hbm15_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM15_PORT0_hbmc]
set hbm_input_1 [get_noc_interfaces i_correlator_core/axi_HBM_gen[0].i_hbm_noc/S_AXI_nmu]
set hbm_conn_lfaa_3 [create_noc_connection -source $hbm_input_1 -target $hbm15_port0]
set_property -dict [list READ_BANDWIDTH 4200 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 4200 WRITE_AVERAGE_BURST 64] $hbm_conn_lfaa_3

######################################
# 3GB for CT2 - Correlator 1
set hbm2_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM2_PORT0_hbmc]
set hbm_input_ct2_1a [get_noc_interfaces i_correlator_core/axi_HBM_gen[1].i_hbm_noc/S_AXI_nmu]
set hbm_conn_ct2_1a [create_noc_connection -source $hbm_input_ct2_1a -target $hbm2_port0]
set_property -dict [list READ_BANDWIDTH 3250 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 3250 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_1a

set hbm2_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM2_PORT2_hbmc]
set hbm_input_ct2_1b [get_noc_interfaces i_correlator_core/axi_HBM_gen[1].i_hbm_noc/S_AXI_nmu]
set hbm_conn_ct2_1b [create_noc_connection -source $hbm_input_ct2_1b -target $hbm2_port1]
set_property -dict [list READ_BANDWIDTH 3250 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 3250 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_1b

set hbm3_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM3_PORT0_hbmc]
set hbm_input_ct2_1c [get_noc_interfaces i_correlator_core/axi_HBM_gen[1].i_hbm_noc/S_AXI_nmu]
set hbm_conn_ct2_1c [create_noc_connection -source $hbm_input_ct2_1c -target $hbm3_port0]
set_property -dict [list READ_BANDWIDTH 3250 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 3250 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_1c


######################################
# 3GB for CT2 - Correlator 2
set hbm4_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM4_PORT0_hbmc]
set hbm_input_ct2_2a [get_noc_interfaces i_correlator_core/axi_HBM_gen[2].i_hbm_noc/S_AXI_nmu]
set hbm_conn_ct2_2a [create_noc_connection -source $hbm_input_ct2_2a -target $hbm4_port0]
set_property -dict [list READ_BANDWIDTH 3250 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 3250 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_2a

set hbm4_port1 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM4_PORT2_hbmc]
set hbm_input_ct2_2b [get_noc_interfaces i_correlator_core/axi_HBM_gen[2].i_hbm_noc/S_AXI_nmu]
set hbm_conn_ct2_2b [create_noc_connection -source $hbm_input_ct2_2b -target $hbm4_port1]
set_property -dict [list READ_BANDWIDTH 3250 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 3250 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_2b

set hbm5_port0 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM5_PORT0_hbmc]
set hbm_input_ct2_2c [get_noc_interfaces i_correlator_core/axi_HBM_gen[2].i_hbm_noc/S_AXI_nmu]
set hbm_conn_ct2_2c [create_noc_connection -source $hbm_input_ct2_2c -target $hbm5_port0]
set_property -dict [list READ_BANDWIDTH 3250 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 3250 WRITE_AVERAGE_BURST 64] $hbm_conn_ct2_2c


######################################
# 1GB for Corr_1 output
set hbm_port_4 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM8_PORT0_hbmc]
set hbm_input_4 [get_noc_interfaces i_correlator_core/axi_HBM_gen[3].i_hbm_noc/S_AXI_nmu]
set hbm_conn_4 [create_noc_connection -source $hbm_input_4 -target $hbm_port_4]
set_property -dict [list READ_BANDWIDTH 6000 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 6000 WRITE_AVERAGE_BURST 64] $hbm_conn_4

######################################
# 1GB for Corr_2 output
set hbm_port_5 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM10_PORT0_hbmc]
set hbm_input_5 [get_noc_interfaces i_correlator_core/axi_HBM_gen[4].i_hbm_noc/S_AXI_nmu]
set hbm_conn_5 [create_noc_connection -source $hbm_input_5 -target $hbm_port_5]
set_property -dict [list READ_BANDWIDTH 6000 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 6000 WRITE_AVERAGE_BURST 64] $hbm_conn_5

# 4GB for ILA
set hbm_port_6 [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM12_PORT0_hbmc]
set hbm_input_6 [get_noc_interfaces i_correlator_core/axi_HBM_gen[5].i_hbm_noc/S_AXI_nmu]
set hbm_conn_6 [create_noc_connection -source $hbm_input_6 -target $hbm_port_6]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 64 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 64] $hbm_conn_6