create_ip -name axis_ila -vendor xilinx.com -library ip -version 1.3 -module_name ila_0
set_property -dict [list CONFIG.C_PROBE0_WIDTH {192} CONFIG.C_DATA_DEPTH {2048}] [get_ips ila_0]
create_ip_run [get_ips ila_0]

create_ip -name axis_ila -vendor xilinx.com -library ip -version 1.3 -module_name ila_8k
set_property -dict [list CONFIG.C_PROBE0_WIDTH {192} CONFIG.C_DATA_DEPTH {8192}] [get_ips ila_8k]
create_ip_run [get_ips ila_8k]

create_ip -name axis_ila -vendor xilinx.com -library ip -version 1.3 -module_name ila_beamData
set_property -dict [list CONFIG.C_PROBE0_WIDTH {120} CONFIG.C_DATA_DEPTH {8192}] [get_ips ila_beamData]
create_ip_run [get_ips ila_beamData]

create_ip -name axis_ila -vendor xilinx.com -library ip -version 1.3 -module_name ila_120_16k
set_property -dict [list CONFIG.C_PROBE0_WIDTH {120} CONFIG.C_DATA_DEPTH {16384}] [get_ips ila_120_16k]
create_ip_run [get_ips ila_120_16k]

create_ip -name clk_wizard -vendor xilinx.com -library ip -version 1.0 -module_name clk_mmcm_425
set_property -dict [list \
  CONFIG.CLKOUT_DRIVES {BUFG,BUFG,BUFG,BUFG,BUFG,BUFG,BUFG} \
  CONFIG.CLKOUT_DYN_PS {None,None,None,None,None,None,None} \
  CONFIG.CLKOUT_GROUPING {Auto,Auto,Auto,Auto,Auto,Auto,Auto} \
  CONFIG.CLKOUT_MATCHED_ROUTING {false,false,false,false,false,false,false} \
  CONFIG.CLKOUT_PORT {clk_out1,clk_out2,clk_out3,clk_out4,clk_out5,clk_out6,clk_out7} \
  CONFIG.CLKOUT_REQUESTED_DUTY_CYCLE {50.000,50.000,50.000,50.000,50.000,50.000,50.000} \
  CONFIG.CLKOUT_REQUESTED_OUT_FREQUENCY {425.00,400,100.000,100.000,100.000,100.000,100.000} \
  CONFIG.CLKOUT_REQUESTED_PHASE {0.000,0.000,0.000,0.000,0.000,0.000,0.000} \
  CONFIG.CLKOUT_USED {true,false,false,false,false,false,false} \
  CONFIG.PRIM_SOURCE {Global_buffer} \
] [get_ips clk_mmcm_425]
create_ip_run [get_ips clk_mmcm_425]

create_ip -name clk_wizard -vendor xilinx.com -library ip -version 1.0 -module_name clk_mmcm_400
set_property -dict [list \
  CONFIG.CLKOUT_DRIVES {BUFG,BUFG,BUFG,BUFG,BUFG,BUFG,BUFG} \
  CONFIG.CLKOUT_DYN_PS {None,None,None,None,None,None,None} \
  CONFIG.CLKOUT_GROUPING {Auto,Auto,Auto,Auto,Auto,Auto,Auto} \
  CONFIG.CLKOUT_MATCHED_ROUTING {false,false,false,false,false,false,false} \
  CONFIG.CLKOUT_PORT {clk_out1,clk_out2,clk_out3,clk_out4,clk_out5,clk_out6,clk_out7} \
  CONFIG.CLKOUT_REQUESTED_DUTY_CYCLE {50.000,50.000,50.000,50.000,50.000,50.000,50.000} \
  CONFIG.CLKOUT_REQUESTED_OUT_FREQUENCY {400.00,100.000,100.000,100.000,100.000,100.000,100.000} \
  CONFIG.CLKOUT_REQUESTED_PHASE {0.000,0.000,0.000,0.000,0.000,0.000,0.000} \
  CONFIG.CLKOUT_USED {true,false,false,false,false,false,false} \
  CONFIG.PRIM_SOURCE {Global_buffer} \
] [get_ips clk_mmcm_400]
create_ip_run [get_ips clk_mmcm_400]