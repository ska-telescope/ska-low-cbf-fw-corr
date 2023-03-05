# The GT processing clock
# get_clocks -of_objects [get_cells -hierarchical *accumulators_rx*]
# The provided processing clock
#get_clocks -of_objects [get_cells -hierarchical *system_reg*]

# Need to set processing order to LATE for these constraints to work.

set_max_delay -datapath_only -from [get_clocks -of_objects [get_cells -hierarchical *accumulators_rx*]] -to [get_clocks -of_objects [get_cells -hierarchical *system_reg*]] 10.0
set_max_delay -datapath_only -from [get_clocks -of_objects [get_cells -hierarchical *system_reg*]] -to [get_clocks -of_objects [get_cells -hierarchical *accumulators_rx*]] 10.0

#add_cells_to_pblock pblock_dynamic_SLR0 [get_cells [list level0_i/ulp/perentie0/inst/vcore/dsp_topi/BFCT]]
#add_cells_to_pblock pblock_dynamic_SLR0 [get_cells [list level0_i/ulp/perentie0/inst/vcore/dsp_topi/BFCT/aximux]]

add_cells_to_pblock pblock_dynamic_SLR0 [get_cells -hierarchical *LFAAin]
add_cells_to_pblock pblock_dynamic_SLR0 [get_cells -hierarchical *LFAA_FB_CT]
add_cells_to_pblock pblock_dynamic_SLR0 [get_cells -hierarchical *corFB_i]
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
