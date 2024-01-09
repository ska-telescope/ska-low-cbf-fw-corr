#set ip_name "ip_LFAADecode100G_lfaadecode100g_vcstats_bram"
#if {$ip_name ni [get_ips]} { 
#create_ip -name blk_mem_gen -vendor xilinx.com -library ip -module_name ip_LFAADecode100G_lfaadecode100g_vcstats_bram -dir "$proj_dir/"
#set_property -dict [list CONFIG.Memory_Type {True_Dual_Port_RAM} \
# CONFIG.Enable_32bit_Address {false} \
# CONFIG.Write_Depth_A {8192} \
# CONFIG.Fill_Remaining_Memory_Locations {true} \
# CONFIG.Remaining_Memory_Locations {0} \
# CONFIG.Use_Byte_Write_Enable {true} \
# CONFIG.Byte_Size {8} \
# CONFIG.Write_Width_A {32} \
# CONFIG.Write_Width_B {32} \
# CONFIG.Read_Width_A {32} \
# CONFIG.Read_Width_B {32} \
# CONFIG.Enable_B {Use_ENB_Pin} \
# CONFIG.Register_PortB_Output_of_Memory_Primitives {true} \
# CONFIG.Use_RSTA_Pin {true} \
# CONFIG.Use_RSTB_Pin {true} \
# CONFIG.Port_B_Clock {100} \
# CONFIG.Port_B_Write_Rate {50} \
# CONFIG.Port_B_Enable_Rate {100} \
#] [get_ips ip_LFAADecode100G_lfaadecode100g_vcstats_bram]
#}

create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -version 4.1 -module_name ip_LFAADecode100G_lfaadecode100g_vcstats_axi_a -dir "$proj_dir/"
set_property -dict [list CONFIG.DATA_WIDTH {32} \
 CONFIG.SINGLE_PORT_BRAM {1} \
 CONFIG.MEM_DEPTH {8192} \
 CONFIG.ECC_TYPE {0} \
 CONFIG.READ_LATENCY {2} \
] [get_ips ip_LFAADecode100G_lfaadecode100g_vcstats_axi_a]


#create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -version 4.1 -module_name ip_LFAADecode100G_lfaadecode100g_vcstats_axi_b -dir "$proj_dir/"
#set_property -dict [list CONFIG.DATA_WIDTH {32} \
# CONFIG.SINGLE_PORT_BRAM {1} \
# CONFIG.MEM_DEPTH {8192} \
# CONFIG.ECC_TYPE {0} \
# CONFIG.READ_LATENCY {2} \
#] [get_ips ip_LFAADecode100G_lfaadecode100g_vcstats_axi_b]
#}
