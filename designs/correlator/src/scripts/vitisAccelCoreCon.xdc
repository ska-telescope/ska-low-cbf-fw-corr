# The GT processing clock
# get_clocks -of_objects [get_cells -hierarchical *accumulators_rx*]
# The provided processing clock
#get_clocks -of_objects [get_cells -hierarchical *system_reg*]

# Need to set processing order to LATE for these constraints to work.

set_max_delay -datapath_only -from [get_clocks -of_objects [get_cells -hierarchical *accumulators_rx*]] -to [get_clocks -of_objects [get_cells -hierarchical *system_reg*]] 10.0
set_max_delay -datapath_only -from [get_clocks -of_objects [get_cells -hierarchical *system_reg*]] -to [get_clocks -of_objects [get_cells -hierarchical *accumulators_rx*]] 10.0

#add_cells_to_pblock pblock_dynamic_SLR0 [get_cells [list level0_i/ulp/perentie0/inst/vcore/dsp_topi/BFCT]]
#add_cells_to_pblock pblock_dynamic_SLR0 [get_cells [list level0_i/ulp/perentie0/inst/vcore/dsp_topi/BFCT/aximux]]

#create_pblock pblock_hbmslr
#resize_pblock pblock_hbmslr -add SLR0:SLR0
#add_cells_to_pblock pblock_hbmslr [get_cells -hierarchical *beamGen[0].bfinst]
#add_cells_to_pblock pblock_hbmslr [get_cells -hierarchical *beamGen[1].bfinst]
#add_cells_to_pblock pblock_hbmslr [get_cells -hierarchical *beamGen[2].bfinst]
#add_cells_to_pblock pblock_hbmslr [get_cells -hierarchical *beamGen[3].bfinst]
#add_cells_to_pblock pblock_hbmslr [get_cells -hierarchical *beamGen[4].bfinst]
#add_cells_to_pblock pblock_hbmslr [get_cells -hierarchical *beamGen[5].bfinst]
#add_cells_to_pblock pblock_hbmslr [get_cells -hierarchical *beamGen[6].bfinst]
#add_cells_to_pblock pblock_hbmslr [get_cells -hierarchical *beamGen[7].bfinst]
#add_cells_to_pblock pblock_hbmslr [get_cells -hierarchical *beamGen[8].bfinst]
#add_cells_to_pblock pblock_hbmslr [get_cells -hierarchical *beamGen[9].bfinst]
#add_cells_to_pblock pblock_hbmslr [get_cells -hierarchical *beamGen[10].bfinst]
#add_cells_to_pblock pblock_hbmslr [get_cells -hierarchical *beamGen[11].bfinst]
#add_cells_to_pblock pblock_hbmslr [get_cells -hierarchical *beamGen[12].bfinst]
#add_cells_to_pblock pblock_hbmslr [get_cells -hierarchical *beamGen[13].bfinst]
#add_cells_to_pblock pblock_hbmslr [get_cells -hierarchical *beamGen[14].bfinst]
#add_cells_to_pblock pblock_hbmslr [get_cells -hierarchical *beamGen[15].bfinst]
#add_cells_to_pblock pblock_hbmslr [get_cells -hierarchical *beamGen[16].bfinst]
#add_cells_to_pblock pblock_hbmslr [get_cells -hierarchical *beamGen[17].bfinst]

#create_pblock pblock_otherslr
#resize_pblock pblock_otherslr -add SLR1:SLR1
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[18].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[19].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[20].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[21].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[22].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[23].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[24].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[25].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[26].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[27].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[28].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[29].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[30].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[31].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[32].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[33].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[34].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[35].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[36].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[37].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[38].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[39].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[40].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[41].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[42].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[43].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[44].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[45].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[46].bfinst]
#add_cells_to_pblock pblock_otherslr [get_cells -hierarchical *beamGen[47].bfinst]

#level0_i/ulp/perentie0/inst/vcore/dsp_topi/BFi/beamGen[0].bfinst
#get_cells -hierarchical *beamGen[0].bfinst
# ? or [get_cells [list level0_i/ulp/perentie0/inst/vcore/dsp_topi/BFCT]]
