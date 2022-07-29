----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: 31.10.2021 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
--
-- ARGS to local RAM wrapper.
--
-- 
----------------------------------------------------------------------------------

library IEEE, axi4_lib, xpm, PSR_Packetiser_lib, common_lib, signal_processing_common;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use PSR_Packetiser_lib.ethernet_pkg.ALL;
use PSR_Packetiser_lib.CbfPsrHeader_pkg.ALL;
use xpm.vcomponents.all;
USE common_lib.common_pkg.ALL;
library technology_lib;
USE technology_lib.tech_mac_100g_pkg.ALL;
use axi4_lib.axi4_stream_pkg.ALL;
use axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.ALL;
USE PSR_Packetiser_lib.Packetiser_packetiser_reg_pkg.ALL;

library UNISIM;
use UNISIM.VComponents.all;

entity cmac_args is
    Generic (
    
        g_NUMBER_OF_STREAMS                 : integer := 3
    
    );
    Port ( 
    
        -- ARGS interface
        -- MACE clock is 300 MHz
        i_MACE_clk                          : in std_logic;
        i_MACE_rst                          : in std_logic;
        
        i_packetiser_clk                    : in std_logic;
        i_packetiser_clk_rst                : in std_logic := '0';
        
        i_PSR_packetiser_Lite_axi_mosi      : in t_axi4_lite_mosi; 
        o_PSR_packetiser_Lite_axi_miso      : out t_axi4_lite_miso;     
        
        i_PSR_packetiser_full_axi_mosi      : in  t_axi4_full_mosi;
        o_PSR_packetiser_full_axi_miso      : out t_axi4_full_miso;
        
        o_packet_stream_ctrl                : out packetiser_stream_ctrl;
        
        i_packet_stream_stats               : in t_packetiser_stats((g_NUMBER_OF_STREAMS-1) downto 0);
                
        o_packet_config                     : out packetiser_config_in;  
        i_packet_config_out                 : in packetiser_config_out 

    );
end cmac_args;

architecture rtl of cmac_args is
COMPONENT axi_bram_ctrl_packetiser100G IS
  PORT (
    s_axi_aclk : IN STD_LOGIC;
    s_axi_aresetn : IN STD_LOGIC;
    s_axi_awaddr : IN STD_LOGIC_VECTOR(14 DOWNTO 0);
    s_axi_awlen : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
    s_axi_awsize : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
    s_axi_awburst : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
    s_axi_awlock : IN STD_LOGIC;
    s_axi_awcache : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
    s_axi_awprot : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
    s_axi_awvalid : IN STD_LOGIC;
    s_axi_awready : OUT STD_LOGIC;
    s_axi_wdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
    s_axi_wstrb : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
    s_axi_wlast : IN STD_LOGIC;
    s_axi_wvalid : IN STD_LOGIC;
    s_axi_wready : OUT STD_LOGIC;
    s_axi_bresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
    s_axi_bvalid : OUT STD_LOGIC;
    s_axi_bready : IN STD_LOGIC;
    s_axi_araddr : IN STD_LOGIC_VECTOR(14 DOWNTO 0);
    s_axi_arlen : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
    s_axi_arsize : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
    s_axi_arburst : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
    s_axi_arlock : IN STD_LOGIC;
    s_axi_arcache : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
    s_axi_arprot : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
    s_axi_arvalid : IN STD_LOGIC;
    s_axi_arready : OUT STD_LOGIC;
    s_axi_rdata : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    s_axi_rresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
    s_axi_rlast : OUT STD_LOGIC;
    s_axi_rvalid : OUT STD_LOGIC;
    s_axi_rready : IN STD_LOGIC;
    bram_rst_a : OUT STD_LOGIC;
    bram_clk_a : OUT STD_LOGIC;
    bram_en_a : OUT STD_LOGIC;
    bram_we_a : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
    bram_addr_a : OUT STD_LOGIC_VECTOR(14 DOWNTO 0);
    bram_wrdata_a : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    bram_rddata_a : IN STD_LOGIC_VECTOR(31 DOWNTO 0)
  );
END COMPONENT; 

constant stat_vector            : integer := (g_NUMBER_OF_STREAMS*4)-1;

signal bram_rst                 : STD_LOGIC;
signal bram_clk                 : STD_LOGIC;
signal bram_en                  : STD_LOGIC;
signal bram_we_byte             : STD_LOGIC_VECTOR(3 DOWNTO 0);
signal bram_addr                : STD_LOGIC_VECTOR(14 DOWNTO 0);
signal bram_wrdata              : STD_LOGIC_VECTOR(31 DOWNTO 0);
signal bram_rddata              : STD_LOGIC_VECTOR(31 DOWNTO 0);

signal packet_registers         : t_packetiser_ctrl_rw;

signal packet_stats             : t_packetiser_ctrl_ro;

signal MACE_rst_n               : std_logic;

signal stat_vectors             : t_slv_32_arr(stat_vector downto 0);

signal stat_vectors_cdc         : t_slv_32_arr(stat_vector downto 0);

begin

MACE_rst_n  <= NOT i_MACE_rst;

ARGS_AXI_BRAM : axi_bram_ctrl_packetiser100G
PORT MAP (
    s_axi_aclk      => i_MACE_clk,
    s_axi_aresetn   => MACE_rst_n, -- in std_logic;
    s_axi_awaddr    => i_PSR_packetiser_full_axi_mosi.awaddr(14 downto 0),
    s_axi_awlen     => i_PSR_packetiser_full_axi_mosi.awlen,
    s_axi_awsize    => i_PSR_packetiser_full_axi_mosi.awsize,
    s_axi_awburst   => i_PSR_packetiser_full_axi_mosi.awburst,
    s_axi_awlock    => i_PSR_packetiser_full_axi_mosi.awlock ,
    s_axi_awcache   => i_PSR_packetiser_full_axi_mosi.awcache,
    s_axi_awprot    => i_PSR_packetiser_full_axi_mosi.awprot,
    s_axi_awvalid   => i_PSR_packetiser_full_axi_mosi.awvalid,
    s_axi_awready   => o_PSR_packetiser_full_axi_miso.awready,
    s_axi_wdata     => i_PSR_packetiser_full_axi_mosi.wdata(31 downto 0),
    s_axi_wstrb     => i_PSR_packetiser_full_axi_mosi.wstrb(3 downto 0),
    s_axi_wlast     => i_PSR_packetiser_full_axi_mosi.wlast,
    s_axi_wvalid    => i_PSR_packetiser_full_axi_mosi.wvalid,
    s_axi_wready    => o_PSR_packetiser_full_axi_miso.wready,
    s_axi_bresp     => o_PSR_packetiser_full_axi_miso.bresp,
    s_axi_bvalid    => o_PSR_packetiser_full_axi_miso.bvalid,
    s_axi_bready    => i_PSR_packetiser_full_axi_mosi.bready ,
    s_axi_araddr    => i_PSR_packetiser_full_axi_mosi.araddr(14 downto 0),
    s_axi_arlen     => i_PSR_packetiser_full_axi_mosi.arlen,
    s_axi_arsize    => i_PSR_packetiser_full_axi_mosi.arsize,
    s_axi_arburst   => i_PSR_packetiser_full_axi_mosi.arburst,
    s_axi_arlock    => i_PSR_packetiser_full_axi_mosi.arlock ,
    s_axi_arcache   => i_PSR_packetiser_full_axi_mosi.arcache,
    s_axi_arprot    => i_PSR_packetiser_full_axi_mosi.arprot,
    s_axi_arvalid   => i_PSR_packetiser_full_axi_mosi.arvalid,
    s_axi_arready   => o_PSR_packetiser_full_axi_miso.arready,
    s_axi_rdata     => o_PSR_packetiser_full_axi_miso.rdata(31 downto 0),
    s_axi_rresp     => o_PSR_packetiser_full_axi_miso.rresp,
    s_axi_rlast     => o_PSR_packetiser_full_axi_miso.rlast,
    s_axi_rvalid    => o_PSR_packetiser_full_axi_miso.rvalid,
    s_axi_rready    => i_PSR_packetiser_full_axi_mosi.rready,

    bram_rst_a      => bram_rst,
    bram_clk_a      => bram_clk,
    bram_en_a       => bram_en,     --: OUT STD_LOGIC;
    bram_we_a       => bram_we_byte,     --: OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
    bram_addr_a     => bram_addr,   --: OUT STD_LOGIC_VECTOR(14 DOWNTO 0);
    bram_wrdata_a   => bram_wrdata, --: OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    bram_rddata_a   => bram_rddata  --: IN STD_LOGIC_VECTOR(31 DOWNTO 0)
  );
  
ARGS_register_Packetiser : entity PSR_Packetiser_lib.Packetiser_packetiser_reg 
    
    PORT MAP (
        -- AXI Lite signals, 300 MHz Clock domain
        MM_CLK                          => i_MACE_clk,
        MM_RST                          => i_MACE_rst,
        
        SLA_IN                          => i_PSR_packetiser_lite_axi_mosi,
        SLA_OUT                         => o_PSR_packetiser_lite_axi_miso,

        PACKETISER_CTRL_FIELDS_RW       => packet_registers,
        
        PACKETISER_CTRL_FIELDS_RO       => packet_stats
        
        );
        
    
o_packet_stream_ctrl.instruct           <= packet_registers.control_vector;

o_packet_config.config_data_clk         <= bram_clk;
o_packet_config.config_data             <= bram_wrdata;
o_packet_config.config_data_addr        <= bram_addr;
o_packet_config.config_data_wr          <= bram_we_byte(3) AND bram_we_byte(2) AND bram_we_byte(1) AND bram_we_byte(0);  
o_packet_config.config_data_en          <= bram_en;

bram_rddata <= i_packet_config_out.config_data_out;




packet_gen : for i in 0 to (stat_vector) GENERATE
    
    stat_sync : entity signal_processing_common.sync_vector
        generic map (
            WIDTH => 32
        )
        Port Map ( 
            clock_a_rst => i_packetiser_clk_rst,
            Clock_a     => i_packetiser_clk,
            Clock_b     => i_MACE_clk,
            data_in     => stat_vectors(i),
            data_out    => stat_vectors_cdc(i)
        );
        
END GENERATE;

    
stat_vectors(0) <= i_packet_stream_stats(0).valid_packets;
stat_vectors(1) <= i_packet_stream_stats(0).invalid_packets;
stat_vectors(2) <= i_packet_stream_stats(0).disregarded_packets;
stat_vectors(3) <= i_packet_stream_stats(0).packets_sent_to_cmac;

stat_vectors(4) <= i_packet_stream_stats(1).valid_packets; 
stat_vectors(5) <= i_packet_stream_stats(1).invalid_packets;
stat_vectors(6) <= i_packet_stream_stats(1).disregarded_packets;
stat_vectors(7) <= i_packet_stream_stats(1).packets_sent_to_cmac;

stat_vectors(8) <= i_packet_stream_stats(2).valid_packets;
stat_vectors(9) <= i_packet_stream_stats(2).invalid_packets;
stat_vectors(10) <= i_packet_stream_stats(2).disregarded_packets;
stat_vectors(11) <= i_packet_stream_stats(2).packets_sent_to_cmac;


packet_stats.stats_packets_rx_sig_proc_valid        <= stat_vectors_cdc(0);
packet_stats.stats_packets_rx_sig_proc_invalid      <= stat_vectors_cdc(1);
packet_stats.stats_packets_rx_sm_off				<= stat_vectors_cdc(2);
packet_stats.stats_packets_rx_sig_proc              <= stat_vectors_cdc(3);

packet_stats.stats_2_packets_rx_sig_proc_valid      <= stat_vectors_cdc(4); 
packet_stats.stats_2_packets_rx_sig_proc_invalid    <= stat_vectors_cdc(5);
packet_stats.stats_2_packets_rx_sm_off              <= stat_vectors_cdc(6);
packet_stats.stats_2_packets_rx_sig_proc			<= stat_vectors_cdc(7);

packet_stats.stats_3_packets_rx_sig_proc_valid      <= stat_vectors_cdc(8);
packet_stats.stats_3_packets_rx_sig_proc_invalid    <= stat_vectors_cdc(9);
packet_stats.stats_3_packets_rx_sm_off              <= stat_vectors_cdc(10);
packet_stats.stats_3_packets_rx_sig_proc            <= stat_vectors_cdc(11);


end rtl;
