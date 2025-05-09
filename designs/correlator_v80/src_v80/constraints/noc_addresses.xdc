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
set_property APERTURES [list {0x201_0000_0000:0x201_0000_FFFF}] $system_nsu

set system_conn [create_noc_connection -source $nmu_0 -target $system_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $system_conn
########################
# LFAA is entry 2 and 3 on the list, 128K between NoCs so starts at 128K and covers up to 256K from the base address.
# two 64K addresses, assign 128K
set_property APERTURES [list {0x201_0002_0000:0x201_0003_FFFF}] $lfaa_1_nsu

set lfaa_1_conn [create_noc_connection -source $nmu_0 -target $lfaa_1_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $lfaa_1_conn
########################
# CT_1
set_property APERTURES [list {0x201_0004_0000:0x201_0005_FFFF}] $ct_1_nsu

set ct_1_conn [create_noc_connection -source $nmu_0 -target $ct_1_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $ct_1_conn
########################
# Filterbank
set_property APERTURES [list {0x201_0006_0000:0x201_0007_FFFF}] $fb_nsu

set fb_conn [create_noc_connection -source $nmu_0 -target $fb_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $fb_conn
########################
# CT_2
set_property APERTURES [list {0x201_0008_0000:0x201_0009_FFFF}] $ct_2_nsu

set ct_2_conn [create_noc_connection -source $nmu_0 -target $ct_2_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $ct_2_conn
########################
# Correlator
set_property APERTURES [list {0x201_000A_0000:0x201_000B_FFFF}] $corr_nsu

set corr_conn [create_noc_connection -source $nmu_0 -target $corr_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $corr_conn
########################
# SPEAD
set_property APERTURES [list {0x201_000C_0000:0x201_000D_FFFF}] $spead_1_nsu

set spead_conn [create_noc_connection -source $nmu_0 -target $spead_1_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $spead_conn
########################
# SPEAD 2
set_property APERTURES [list {0x201_000E_0000:0x201_000F_FFFF}] $spead_2_nsu

set spead_2_conn [create_noc_connection -source $nmu_0 -target $spead_2_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $spead_2_conn
########################
# Spead HBM
set_property APERTURES [list {0x201_0010_0000:0x201_0011_FFFF}] $spead_hbmrd_1_nsu

set spead_hbm_conn [create_noc_connection -source $nmu_0 -target $spead_hbmrd_1_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $spead_hbm_conn
########################
# Spead HBM 2
set_property APERTURES [list {0x201_0012_0000:0x201_0013_FFFF}] $spead_hbmrd_2_nsu

set spead_hbm_2_conn [create_noc_connection -source $nmu_0 -target $spead_hbmrd_2_nsu]
set_property -dict [list READ_BANDWIDTH 40 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 40 WRITE_AVERAGE_BURST 4] $spead_hbm_2_conn


# ADDRESS SPACE TO BE AWARE OF IN TOP BD
# 0x201_0FFF_FFFF for 128M assigned to DDR, this can probably be deleted 
# 0x201_0100_0000 -> 0x201_0104_FFFF Used by design components, possible to remap to higher?

# HBM connections
#HBM Ports
#set hbm_port [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/HBM0_PORT0_hbmc]
#set hbm_input [get_noc_interfaces test_comp/i_hbm_noc/S_AXI_nmu]
#set hbm_test [create_noc_connection -source $hbm_input -target $hbm_port]

