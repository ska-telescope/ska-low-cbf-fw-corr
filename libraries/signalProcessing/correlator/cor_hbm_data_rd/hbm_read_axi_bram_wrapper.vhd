----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: 20/03/2023
-- Design Name: 
-- Module Name: hbm_read_axi_bram_wrapper
--  
-- Description: 
--      Created to deal with verbose creation of mappings when compiling in Vitis
----------------------------------------------------------------------------------

library IEEE, spead_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
Library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;


entity hbm_read_axi_bram_wrapper is
    Port ( 
        i_clk                    : in std_logic;
        i_rst                    : in std_logic;

        bram_rst                 : out std_logic;
        bram_clk                 : out std_logic;
        bram_en                  : out std_logic;
        bram_we_byte             : out std_logic_vector(3 DOWNTO 0);
        bram_addr                : out std_logic_vector(15 DOWNTO 0);
        bram_wrdata              : out std_logic_vector(31 DOWNTO 0);
        bram_rddata              : in std_logic_vector(31 DOWNTO 0);

        i_spead_full_axi_mosi    : in  t_axi4_full_mosi;
        o_spead_full_axi_miso    : out t_axi4_full_miso

    );
end hbm_read_axi_bram_wrapper;

architecture Behavioral of hbm_read_axi_bram_wrapper is

component axi_bram_ctrl_hbm_read is
    Port ( 
        s_axi_aclk : in STD_LOGIC;
        s_axi_aresetn : in STD_LOGIC;
        s_axi_awaddr : in STD_LOGIC_VECTOR ( 15 downto 0 );
        s_axi_awlen : in STD_LOGIC_VECTOR ( 7 downto 0 );
        s_axi_awsize : in STD_LOGIC_VECTOR ( 2 downto 0 );
        s_axi_awburst : in STD_LOGIC_VECTOR ( 1 downto 0 );
        s_axi_awlock : in STD_LOGIC;
        s_axi_awcache : in STD_LOGIC_VECTOR ( 3 downto 0 );
        s_axi_awprot : in STD_LOGIC_VECTOR ( 2 downto 0 );
        s_axi_awvalid : in STD_LOGIC;
        s_axi_awready : out STD_LOGIC;
        s_axi_wdata : in STD_LOGIC_VECTOR ( 31 downto 0 );
        s_axi_wstrb : in STD_LOGIC_VECTOR ( 3 downto 0 );
        s_axi_wlast : in STD_LOGIC;
        s_axi_wvalid : in STD_LOGIC;
        s_axi_wready : out STD_LOGIC;
        s_axi_bresp : out STD_LOGIC_VECTOR ( 1 downto 0 );
        s_axi_bvalid : out STD_LOGIC;
        s_axi_bready : in STD_LOGIC;
        s_axi_araddr : in STD_LOGIC_VECTOR ( 15 downto 0 );
        s_axi_arlen : in STD_LOGIC_VECTOR ( 7 downto 0 );
        s_axi_arsize : in STD_LOGIC_VECTOR ( 2 downto 0 );
        s_axi_arburst : in STD_LOGIC_VECTOR ( 1 downto 0 );
        s_axi_arlock : in STD_LOGIC;
        s_axi_arcache : in STD_LOGIC_VECTOR ( 3 downto 0 );
        s_axi_arprot : in STD_LOGIC_VECTOR ( 2 downto 0 );
        s_axi_arvalid : in STD_LOGIC;
        s_axi_arready : out STD_LOGIC;
        s_axi_rdata : out STD_LOGIC_VECTOR ( 31 downto 0 );
        s_axi_rresp : out STD_LOGIC_VECTOR ( 1 downto 0 );
        s_axi_rlast : out STD_LOGIC;
        s_axi_rvalid : out STD_LOGIC;
        s_axi_rready : in STD_LOGIC;
        bram_rst_a : out STD_LOGIC;
        bram_clk_a : out STD_LOGIC;
        bram_en_a : out STD_LOGIC;
        bram_we_a : out STD_LOGIC_VECTOR ( 3 downto 0 );
        bram_addr_a : out STD_LOGIC_VECTOR ( 15 downto 0 );
        bram_wrdata_a : out STD_LOGIC_VECTOR ( 31 downto 0 );
        bram_rddata_a : in STD_LOGIC_VECTOR ( 31 downto 0 )
    );
end component;

signal clk                      : std_logic;
signal reset                    : std_logic;
signal reset_n                  : std_logic;

begin

    clk                         <= i_clk;
    reset                       <= i_rst;
    reset_n                     <= NOT i_rst;

Spead_memspace : axi_bram_ctrl_hbm_read
    PORT MAP (
        s_axi_aclk      => clk,
        s_axi_aresetn   => reset_n, -- in std_logic;
        s_axi_awaddr    => i_spead_full_axi_mosi.awaddr(15 downto 0),
        s_axi_awlen     => i_spead_full_axi_mosi.awlen,
        s_axi_awsize    => i_spead_full_axi_mosi.awsize,
        s_axi_awburst   => i_spead_full_axi_mosi.awburst,
        s_axi_awlock    => i_spead_full_axi_mosi.awlock ,
        s_axi_awcache   => i_spead_full_axi_mosi.awcache,
        s_axi_awprot    => i_spead_full_axi_mosi.awprot,
        s_axi_awvalid   => i_spead_full_axi_mosi.awvalid,
        s_axi_awready   => o_spead_full_axi_miso.awready,
        s_axi_wdata     => i_spead_full_axi_mosi.wdata(31 downto 0),
        s_axi_wstrb     => i_spead_full_axi_mosi.wstrb(3 downto 0),
        s_axi_wlast     => i_spead_full_axi_mosi.wlast,
        s_axi_wvalid    => i_spead_full_axi_mosi.wvalid,
        s_axi_wready    => o_spead_full_axi_miso.wready,
        s_axi_bresp     => o_spead_full_axi_miso.bresp,
        s_axi_bvalid    => o_spead_full_axi_miso.bvalid,
        s_axi_bready    => i_spead_full_axi_mosi.bready ,
        s_axi_araddr    => i_spead_full_axi_mosi.araddr(15 downto 0),
        s_axi_arlen     => i_spead_full_axi_mosi.arlen,
        s_axi_arsize    => i_spead_full_axi_mosi.arsize,
        s_axi_arburst   => i_spead_full_axi_mosi.arburst,
        s_axi_arlock    => i_spead_full_axi_mosi.arlock ,
        s_axi_arcache   => i_spead_full_axi_mosi.arcache,
        s_axi_arprot    => i_spead_full_axi_mosi.arprot,
        s_axi_arvalid   => i_spead_full_axi_mosi.arvalid,
        s_axi_arready   => o_spead_full_axi_miso.arready,
        s_axi_rdata     => o_spead_full_axi_miso.rdata(31 downto 0),
        s_axi_rresp     => o_spead_full_axi_miso.rresp,
        s_axi_rlast     => o_spead_full_axi_miso.rlast,
        s_axi_rvalid    => o_spead_full_axi_miso.rvalid,
        s_axi_rready    => i_spead_full_axi_mosi.rready,
    
        bram_rst_a      => bram_rst,
        bram_clk_a      => bram_clk,
        bram_en_a       => bram_en,
        bram_we_a       => bram_we_byte,
        bram_addr_a     => bram_addr,   
        bram_wrdata_a   => bram_wrdata, 
        bram_rddata_a   => bram_rddata  
    );        

end Behavioral;
