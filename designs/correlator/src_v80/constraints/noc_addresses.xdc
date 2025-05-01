#create_noc_connection -source [get_noc_interfaces i_v80_board/top_i/axi_noc_cips/S00_AXI_nmu] -target [get_noc_interfaces i_system_noc/xpm_nsu_mm_inst/M_AXI_nsu]
# Mappings are master to slave
# Args infers a NoC Slave interface

################
## These are all heirarchy mappings, beware when updating code.
set nmu_0 [get_noc_interfaces "i_v80_board/top_i/axi_noc_cips/S00_AXI_nmu"]

set lfaa_1_nsu [get_noc_interfaces "i_correlator_core/dsp_topi/LFAAin/gen_v80_args.i_lfaa_noc/xpm_nsu_mm_inst/M_AXI_nsu"]

set system_nsu [get_noc_interfaces "i_correlator_core/i_system_noc/xpm_nsu_mm_inst/M_AXI_nsu"]

# Base address for the PL region and this is also mapped to BAR 0 - 0x201_0000_0000
# correlator ARGs
#    Including slave ports for correlator:
#    system_system at 0x0                           0 - 0xFFFF
#    vitis_shared_vitis_shared_ram at 0x8000        1 - 0x1_FFFF
#    lfaadecode100g_vcstats_ram at 0x10000          2 - 0x2_FFFF
#    lfaadecode100g_statctrl at 0x14000             3 -
#    corr_ct1_polynomial_ram_ram at 0x20000
#    corr_ct1_config at 0x30000
#    filterbanks_config at 0x32000
#    corr_ct2_statctrl at 0x34000
#    config_setup at 0x36000
#    spead_sdp_spead_params_ram at 0x38000
#    spead_sdp_spead_ctrl at 0x3C000
#    spead_sdp_2_spead_params_ram at 0x40000
#    spead_sdp_2_spead_ctrl at 0x44000
#    hbm_rd_debug_hbm_rd_debug at 0x46000
#    hbm_rd_debug_2_hbm_rd_debug at 0x48000
#    cmac_cmac_stats_interface at 0x4A000
#    timeslave_timeslave_space_ram at 0x50000
#    timeslave_timeslave_scheduler at 0x60000
# use the above list just for ordering of the NSUs

########################
# System peripheral = 64K address space
set_property APERTURES [list {0x201_0000_0000:0x201_0000_FFFF}] $system_nsu

set system_conn [create_noc_connection -source $nmu_0 -target $system_nsu]
set_property -dict [list READ_BANDWIDTH 400 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 400 WRITE_AVERAGE_BURST 4] $system_conn


########################
# LFAA is entry 3 and 4 on the list, so starts at 128K and covers up to 256K from the base address.
# two 64K addresses, assign 128K
set_property APERTURES [list {0x201_0002_0000:0x201_0003_FFFF}] $lfaa_1_nsu

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

