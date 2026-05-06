----------------------------------------------------------------------------------
-- Company:  CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 09/06/2023 11:33:47 PM
-- Module Name: poly_axi_bram_wrapper_v80 - Behavioral
-- Description:
--  Interface axi full to a block of ultraRAMs to hold the polynomial coeficients.
--  2 separate memories :
--   -----------------------------------------------------------------------------
--   Polynomials:
--     (2 buffers) * (3072 polynomials) * (10 words/polynomial) * (8 bytes/word) = 
--     480 kBytes = 61440 * 8 bytes
--                = 122880 * 4 bytes
--     Base address is 0x0
--     Valid addresses of 4-byte words range from 0x0 to x1DFFF
--   -----------------------------------------------------------------------------
--   RFI Thresholds:
--    (3072 virtual channels) * (4 bytes) = 12288 bytes
--    Base address is 491520 = 0x78000              (byte address)
--                    491520/4 = 122880 = 0x1E000   (4-byte address)
--                    491520/8 = 61440  = 0xF000    (8-byte address)
--    Range of valid NOC (4-byte word) addresses is 0x1E000 to 0x1EC00 
-- ---------------------------------------------------------------------
--  19 bit byte address = 524288 bytes of address space
-- 
----------------------------------------------------------------------------------
library IEEE, common_lib, correlator_lib, signal_processing_common;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
Library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;
use common_lib.common_pkg.ALL;
use signal_processing_common.target_fpga_pkg.ALL;
Library xpm;
use xpm.vcomponents.all;

entity poly_axi_bram_wrapper_v80 is
    port (
        i_clk : in std_logic;
        i_rst : in std_logic;
        -------------------------------------------------------
        -- Block ram interface for access by the rest of the module
        -- Memory is 20480 x 8 byte words
        -- read latency 3 clocks
        i_bram_addr       : in std_logic_vector(15 downto 0); -- 16 bit address of 8-byte words (= 19 bit byte address)
        o_bram_rddata     : out std_logic_vector(63 downto 0);
        -- 4096 x 4-byte words for the RFI threshold
        i_RFI_bram_addr   : in  std_logic_vector(11 downto 0);
        o_RFI_bram_rddata : out std_logic_vector(31 downto 0);
        ------------------------------------------------------
        noc_wren   : IN STD_LOGIC;
        noc_wr_adr : IN STD_LOGIC_VECTOR(17 DOWNTO 0); -- This is a 4-byte address from the NOC
        noc_wr_dat : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
        noc_rd_dat : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
        ------------------------------------------------------
        -- debug
        o_dbg_wrEn : out std_logic;
        o_dbg_wrAddr : out std_logic_vector(14 downto 0) 
    );
end poly_axi_bram_wrapper_v80;

architecture Behavioral of poly_axi_bram_wrapper_v80 is
    
begin
    
    o_bram_rddata <= (others => '0');
    o_RFI_bram_rddata <= (others => '0');
    noc_rd_dat <= (others => '0');
    o_dbg_wrEn <= '0';
    o_dbg_wrAddr <= (others => '0');
    
end Behavioral;
