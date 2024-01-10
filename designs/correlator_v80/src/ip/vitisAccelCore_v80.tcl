create_ip -name axi_cdma -vendor xilinx.com -library ip -version 4.1 -module_name axi_cdma_0
set_property -dict [list CONFIG.C_INCLUDE_SF {1} CONFIG.C_INCLUDE_SG {0} CONFIG.C_ADDR_WIDTH {32}] [get_ips axi_cdma_0]
create_ip_run [get_ips axi_cdma_0]

#create_ip -name cmac_usplus -vendor xilinx.com -library ip -version 3.1 -module_name cmac_usplus_0
#set_property -dict [list CONFIG.CMAC_CAUI4_MODE {1} CONFIG.NUM_LANES {4x25} CONFIG.GT_REF_CLK_FREQ {161.1328125} CONFIG.TX_FLOW_CONTROL {0} CONFIG.RX_FLOW_CONTROL {0} CONFIG.CMAC_CORE_SELECT {CMACE4_X0Y3} CONFIG.GT_GROUP_SELECT {X0Y28~X0Y31} CONFIG.LANE1_GT_LOC {X0Y28} CONFIG.LANE2_GT_LOC {X0Y29} CONFIG.LANE3_GT_LOC {X0Y30} CONFIG.LANE4_GT_LOC {X0Y31} CONFIG.LANE5_GT_LOC {NA} CONFIG.LANE6_GT_LOC {NA} CONFIG.LANE7_GT_LOC {NA} CONFIG.LANE8_GT_LOC {NA} CONFIG.LANE9_GT_LOC {NA} CONFIG.LANE10_GT_LOC {NA} CONFIG.RX_GT_BUFFER {1} CONFIG.GT_RX_BUFFER_BYPASS {0} CONFIG.INCLUDE_RS_FEC {1} CONFIG.ADD_GT_CNRL_STS_PORTS {1} CONFIG.INS_LOSS_NYQ {20} CONFIG.RX_EQ_MODE {DFE}] [get_ips cmac_usplus_0]
#create_ip_run [get_ips cmac_usplus_0]

# 128Kbyte BRAM with AXI interface to use as external memory for the testbench.
# create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -version 4.1 -module_name axi_bram_ctrl_0
# set_property -dict [list CONFIG.SINGLE_PORT_BRAM {1} CONFIG.BMG_INSTANCE {INTERNAL} CONFIG.MEM_DEPTH {32768}] [get_ips axi_bram_ctrl_0]
# create_ip_run [get_ips axi_bram_ctrl_0]

# 1MByte BRAM with 512 bit AXI interface to use as HBM external memory for the testbench
#create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -version 4.1 -module_name axi_bram_ctrl_1mbyte
#set_property -dict [list CONFIG.DATA_WIDTH {512} CONFIG.ECC_TYPE {0} CONFIG.Component_Name {axi_bram_ctrl_1mbyte} CONFIG.BMG_INSTANCE {INTERNAL} CONFIG.MEM_DEPTH {16384}] [get_ips axi_bram_ctrl_1mbyte]
#set_property -dict [list CONFIG.READ_LATENCY {6}] [get_ips axi_bram_ctrl_1mbyte]
#create_ip_run [get_ips axi_bram_ctrl_1mbyte]

# 1 MByte BRAM with 256 bit AXI interface to use as HBM external memory for the testbench
#create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -version 4.1 -module_name axi_bram_ctrl_1Mbyte256bit
#set_property -dict [list CONFIG.DATA_WIDTH {256} CONFIG.ECC_TYPE {0} CONFIG.Component_Name {axi_bram_ctrl_1Mbyte256bit} CONFIG.BMG_INSTANCE {INTERNAL} CONFIG.MEM_DEPTH {32768} CONFIG.READ_LATENCY {1}] [get_ips axi_bram_ctrl_1Mbyte256bit]
#create_ip_run [get_ips axi_bram_ctrl_1Mbyte256bit]

# AXI protocol checker
#create_ip -name axi_protocol_checker -vendor xilinx.com -library ip -version 2.0 -module_name axi_protocol_checker_256
#set_property -dict [list CONFIG.DATA_WIDTH {256} CONFIG.MAX_RD_BURSTS {64} CONFIG.MAX_WR_BURSTS {32} CONFIG.MAX_CONTINUOUS_WTRANSFERS_WAITS {500} CONFIG.MAX_CONTINUOUS_RTRANSFERS_WAITS {500} CONFIG.Component_Name {axi_protocol_checker_256}] [get_ips axi_protocol_checker_256]
#create_ip_run [get_ips axi_protocol_checker_256]

create_ip -name axi_protocol_checker -vendor xilinx.com -library ip -version 2.0 -module_name axi_protocol_checker_512
set_property -dict [list CONFIG.DATA_WIDTH {512} CONFIG.MAX_RD_BURSTS {64} CONFIG.MAX_WR_BURSTS {32} CONFIG.MAX_CONTINUOUS_WTRANSFERS_WAITS {500} CONFIG.MAX_CONTINUOUS_RTRANSFERS_WAITS {500} CONFIG.Component_Name {axi_protocol_checker_512}] [get_ips axi_protocol_checker_512]
create_ip_run [get_ips axi_protocol_checker_512]

# AXI memory interface for the shared memory in the testbench
create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -version 4.1 -module_name axi_bram_RegisterSharedMem
set_property -dict [list CONFIG.SINGLE_PORT_BRAM {1} CONFIG.Component_Name {axi_bram_RegisterSharedMem} CONFIG.MEM_DEPTH {32768}] [get_ips axi_bram_RegisterSharedMem]
create_ip_run [get_ips axi_bram_RegisterSharedMem]

# Versal parts replace ila with axis_ila
#create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_0
#set_property -dict [list CONFIG.C_PROBE0_WIDTH {192} CONFIG.C_DATA_DEPTH {2048}] [get_ips ila_0]
#create_ip_run [get_ips ila_0]
create_ip -name axis_ila -vendor xilinx.com -library ip -version 1.2 -module_name ila_0
set_property -dict [list \
  CONFIG.C_DATA_DEPTH {2048} \
  CONFIG.C_PROBE0_WIDTH {192} \
] [get_ips ila_0]
create_ip_run [get_ips ila_0]

# Generate other clocks from the 300MHz input clock
#create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 -module_name clk_gen100MHz
#set_property -dict [list CONFIG.Component_Name {clk_gen100MHz} CONFIG.PRIM_SOURCE {Global_buffer} CONFIG.PRIM_IN_FREQ {100.000} CONFIG.USE_LOCKED {false} CONFIG.USE_RESET {false} CONFIG.CLKIN1_JITTER_PS {33.330000000000005} CONFIG.MMCM_CLKFBOUT_MULT_F {4.000} CONFIG.MMCM_CLKIN1_PERIOD {3.333} CONFIG.MMCM_CLKIN2_PERIOD {10.0} CONFIG.CLKOUT1_JITTER {101.475} CONFIG.CLKOUT1_PHASE_ERROR {77.836}] [get_ips clk_gen100MHz]
#set_property -dict [list \
#  CONFIG.CLKOUT2_USED {true} \
#  CONFIG.CLK_OUT1_PORT {clk100_out} \
#  CONFIG.CLK_OUT2_PORT {clk425_out} \
#  CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {425.000} \
#  CONFIG.MMCM_CLKFBOUT_MULT_F {12.750} \
#  CONFIG.MMCM_CLKOUT0_DIVIDE_F {12.750} \
#  CONFIG.MMCM_CLKOUT1_DIVIDE {3} \
#  CONFIG.NUM_OUT_CLKS {2} \
#  CONFIG.CLKOUT1_JITTER {110.145} \
#  CONFIG.CLKOUT1_PHASE_ERROR {83.270} \
#  CONFIG.CLKOUT2_JITTER {84.783} \
#  CONFIG.CLKOUT2_PHASE_ERROR {83.270} \
#] [get_ips clk_gen100MHz]

#create_ip_run [get_ips clk_gen100MHz]

# Cannot generate both 400 and 450 MHz clock from a 300 MHz clock in the same mmcm
#create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 -module_name clk_gen400MHz
#set_property -dict [list CONFIG.Component_Name {gen_clk400} CONFIG.PRIM_IN_FREQ {100.000} CONFIG.CLK_OUT1_PORT {clk400_out} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {400.000} CONFIG.USE_LOCKED {false} CONFIG.USE_RESET {false} CONFIG.CLKIN1_JITTER_PS {33.330000000000005} CONFIG.MMCM_CLKFBOUT_MULT_F {4.000} CONFIG.MMCM_CLKIN1_PERIOD {3.333} CONFIG.MMCM_CLKIN2_PERIOD {10.0} CONFIG.MMCM_CLKOUT0_DIVIDE_F {3.000} CONFIG.CLKOUT1_JITTER {77.334} CONFIG.CLKOUT1_PHASE_ERROR {77.836}] [get_ips clk_gen400MHz]
#create_ip_run [get_ips clk_gen400MHz]

# 512 bit wide AXI register slice, 64 bit address
create_ip -name axi_register_slice -vendor xilinx.com -library ip -version 2.1 -module_name axi_reg_slice512_LLFFL
set_property -dict [list CONFIG.ADDR_WIDTH {64} CONFIG.DATA_WIDTH {512} CONFIG.REG_W {1} CONFIG.Component_Name {axi_reg_slice512_LLFFL}] [get_ips axi_reg_slice512_LLFFL]
set_property -dict [list CONFIG.HAS_LOCK {0} CONFIG.HAS_CACHE {0} CONFIG.HAS_REGION {0} CONFIG.HAS_QOS {0} CONFIG.HAS_PROT {0} CONFIG.REG_AW {1} CONFIG.REG_AR {1}] [get_ips axi_reg_slice512_LLFFL]
create_ip_run [get_ips axi_reg_slice512_LLFFL]


