# The GT processing clock
# get_clocks -of_objects [get_cells -hierarchical *accumulators_rx*]
# The provided processing clock
#get_clocks -of_objects [get_cells -hierarchical *system_reg*]

# Need to set processing order to LATE for these constraints to work.

set_max_delay -datapath_only -from [get_clocks -of_objects [get_cells -hierarchical *accumulators_rx*]] -to [get_clocks -of_objects [get_cells -hierarchical *system_reg*]] 10.0
set_max_delay -datapath_only -from [get_clocks -of_objects [get_cells -hierarchical *system_reg*]] -to [get_clocks -of_objects [get_cells -hierarchical *accumulators_rx*]] 10.0


add_cells_to_pblock pblock_dynamic_SLR0 [get_cells -hierarchical *LFAAin]
add_cells_to_pblock pblock_dynamic_SLR0 [get_cells -hierarchical *LFAA_FB_CT]
add_cells_to_pblock pblock_dynamic_SLR0 [get_cells -hierarchical *corFB_i]

add_cells_to_pblock pblock_dynamic_SLR1 [get_cells -hierarchical *u_100G_port_a]


add_cells_to_pblock pblock_dynamic_SLR1 [get_cells -hier -filter {NAME =~ */cor1geni.icor1/cor1i/row_mult_gen[*].col_mult_gen[*].cmultsi}]
##add_cells_to_pblock pblock_dynamic_SLR1 [get_cells -hierarchical */cor1geni.icor1/cor1i]
# Add HBM read and packetiser for Correlator Instance 1 to SLR0, closest to HBM.
add_cells_to_pblock pblock_dynamic_SLR1 [get_cells -hier -filter {NAME =~ */cor1geni.icor1/HBM_reader}]
add_cells_to_pblock pblock_dynamic_SLR1 [get_cells -hier -filter {NAME =~ */cor2geni.icor2/HBM_reader}]
add_cells_to_pblock pblock_dynamic_SLR1 [get_cells -hier -filter {NAME =~ */spead_packetiser_top}]

#add_cells_to_pblock pblock_dynamic_SLR2 [get_cells -hier -filter {NAME =~ */cor2geni.icor2/cor1i/row_mult_gen[*].col_mult_gen[*].cmultsi}]

# HBM interface components
# LFAA In / CT1 / FB
add_cells_to_pblock pblock_dynamic_SLR0 [get_cells -hier -filter {NAME =~ */axi_HBM_gen[0].hbm_resetter}]
add_cells_to_pblock pblock_dynamic_SLR0 [get_cells -hier -filter {NAME =~ */axi_HBM_gen[0].gen_axi_slice_reg.HBM_reg_slice}]

# HBM single slr crossing constraint
add_cells_to_pblock pblock_dynamic_SLR0 [get_cells -hier -filter {NAME =~ */axi_HBM_gen[1].gen_axi_slice_1SLR.HBM_reg_slice*slr_master*}]
add_cells_to_pblock pblock_dynamic_SLR1 [get_cells -hier -filter {NAME =~ */axi_HBM_gen[1].gen_axi_slice_1SLR.HBM_reg_slice*slr_slave*}]

# Spead Packetiser 1
add_cells_to_pblock pblock_dynamic_SLR0 [get_cells -hier -filter {NAME =~ */axi_HBM_gen[3].gen_axi_slice_1SLR.HBM_reg_slice*slr_master*}]
add_cells_to_pblock pblock_dynamic_SLR1 [get_cells -hier -filter {NAME =~ */axi_HBM_gen[3].gen_axi_slice_1SLR.HBM_reg_slice*slr_slave*}]
# Spead Packetiser 2
add_cells_to_pblock pblock_dynamic_SLR0 [get_cells -hier -filter {NAME =~ */axi_HBM_gen[4].gen_axi_slice_1SLR.HBM_reg_slice*slr_master*}]
add_cells_to_pblock pblock_dynamic_SLR1 [get_cells -hier -filter {NAME =~ */axi_HBM_gen[4].gen_axi_slice_1SLR.HBM_reg_slice*slr_slave*}]

# HBM 0 - LFAA/CT1
# HBM 1 - Ct2/Corr1
# HBM 2 - Ct2/Corr2
# HBM 3 - Corr1 Packetiser
# HBM 4 - Corr2 Packetiser
# HBM 5 - Stats

########################################################################################################################
## Time constraints if there is only 1 x 100G with TS on the top QSFP port.
## Timeslave IP constraints.. derived from reference design

set_max_delay 10.0 -datapath_only -from [get_clocks enet_refclk_p[0]] -to [get_clocks sysclk100] 
set_max_delay 3.0 -datapath_only -from [get_clocks enet_refclk_p[0]] -to [get_clocks txoutclk_out[0]] 
 
set_max_delay 3.0 -datapath_only -from [get_clocks rxoutclk_out[0]] -to [get_clocks enet_refclk_p[0]] 
set_max_delay 3.0 -datapath_only -from [get_clocks rxoutclk_out[0]] -to [get_clocks txoutclk_out[0]] 
set_max_delay 3.0 -datapath_only -from [get_clocks sysclk100] -to [get_clocks enet_refclk_p[0]] 
set_max_delay 3.0 -datapath_only -from [get_clocks sysclk100] -to [get_clocks txoutclk_out[0]] 
 
set_max_delay 3.0 -datapath_only -from [get_clocks txoutclk_out[0]] -to [get_clocks rxoutclk_out[0]]

## ts - 1st instantiation of 100G and Timeslave. ... these seem to cover CDC of PTP and PPS.
set_max_delay 3.0 -datapath_only -from [get_clocks clk_300_ts_clk_wiz_0_0] -to [get_clocks rxoutclk_out[0]] 
set_max_delay 3.0 -datapath_only -from [get_clocks clk_300_ts_clk_wiz_0_0] -to [get_clocks txoutclk_out[0]] 

set_max_delay 3.0 -datapath_only -from [get_clocks rxoutclk_out[0]] -to [get_clocks clk_300_ts_clk_wiz_0_0] 
set_max_delay 3.0 -datapath_only -from [get_clocks txoutclk_out[0]] -to [get_clocks clk_300_ts_clk_wiz_0_0]

## PTP ARGs clock
#set_max_delay 3.0 -datapath_only -from [get_clocks clk_300_ts_clk_wiz_0_0] -to [get_clocks clk_kernel_unbuffered]
#set_max_delay 3.0 -datapath_only -from [get_clocks clk_kernel_unbuffered] -to [get_clocks clk_300_ts_clk_wiz_0_0]
