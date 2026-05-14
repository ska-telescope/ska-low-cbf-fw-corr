create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -version 4.1 -module_name axi_bram_ctrl_hbm_read
set_property -dict [list CONFIG.SUPPORTS_NARROW_BURST {0} CONFIG.SINGLE_PORT_BRAM {1} CONFIG.Component_Name {axi_bram_ctrl_spead} CONFIG.READ_LATENCY {3} CONFIG.MEM_DEPTH {16384}] [get_ips axi_bram_ctrl_hbm_read]
create_ip_run [get_ips axi_bram_ctrl_hbm_read]

create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name float32_float16_ip
set_property -dict [list \
  CONFIG.A_Precision_Type {Single} \
  CONFIG.C_A_Exponent_Width {8} \
  CONFIG.C_A_Fraction_Width {24} \
  CONFIG.C_Mult_Usage {No_Usage} \
  CONFIG.C_Rate {1} \
  CONFIG.C_Result_Exponent_Width {5} \
  CONFIG.C_Result_Fraction_Width {11} \
  CONFIG.Operation_Type {Float_to_float} \
  CONFIG.Result_Precision_Type {Half} \
  CONFIG.C_Latency {3} \
  CONFIG.Flow_Control {NonBlocking} \
  CONFIG.Has_RESULT_TREADY {false} \
] [get_ips float32_float16_ip]
create_ip_run [get_ips float32_float16_ip]