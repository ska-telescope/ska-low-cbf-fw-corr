create_ip -name blk_mem_gen -vendor xilinx.com -library ip -version 8.4 -module_name packetiser_bram_1024d_32w_tdp
set_property -dict [list CONFIG.Component_Name {packetiser_bram_1024d_32w_tdp} CONFIG.Memory_Type {True_Dual_Port_RAM} CONFIG.Write_Width_A {32} CONFIG.Write_Depth_A {1024} CONFIG.Read_Width_A {32} CONFIG.Operating_Mode_A {NO_CHANGE} CONFIG.Write_Width_B {32} CONFIG.Read_Width_B {32} CONFIG.Enable_B {Use_ENB_Pin} CONFIG.Register_PortA_Output_of_Memory_Primitives {true} CONFIG.Register_PortB_Output_of_Memory_Primitives {true} CONFIG.Port_B_Clock {100} CONFIG.Port_B_Write_Rate {50} CONFIG.Port_B_Enable_Rate {100}] [get_ips packetiser_bram_1024d_32w_tdp]
create_ip_run [get_ips packetiser_bram_1024d_32w_tdp]

create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -version 4.1 -module_name axi_bram_ctrl_packetiser100G
set_property -dict [list CONFIG.SUPPORTS_NARROW_BURST {0} CONFIG.SINGLE_PORT_BRAM {1} CONFIG.Component_Name {axi_bram_ctrl_packetiser100G} CONFIG.READ_LATENCY {3}] [get_ips axi_bram_ctrl_packetiser100G]
create_ip_run [get_ips axi_bram_ctrl_packetiser100G]