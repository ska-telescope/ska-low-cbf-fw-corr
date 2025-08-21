create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -version 4.1 -module_name axi_bram_ctrl_hbm_read
set_property -dict [list CONFIG.SUPPORTS_NARROW_BURST {0} CONFIG.SINGLE_PORT_BRAM {1} CONFIG.Component_Name {axi_bram_ctrl_spead} CONFIG.READ_LATENCY {3} CONFIG.MEM_DEPTH {16384}] [get_ips axi_bram_ctrl_hbm_read]
create_ip_run [get_ips axi_bram_ctrl_hbm_read]
