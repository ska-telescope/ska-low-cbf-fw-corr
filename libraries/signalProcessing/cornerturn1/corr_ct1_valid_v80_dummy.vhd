----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 29.09.2020 11:24:19 modified jan 2026 for the v80
-- Module Name: corr_ct1_valid_v80 - Behavioral
-- Description: 
--   Valid Memory.
--   Keeps track of which blocks of 8192 bytes in the HBM are valid.
--   9 Gbytes/8192 bytes = 1,179,648 locations.
--   Uses 5 UltraRAMs (5 memories) * (4096 deep) * (64 bits wide) = 1,310,720 bits
--   The memory has two ports. 
--     - "set" and "clear" share one port. Set has priority. 
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
Library xpm;
use xpm.vcomponents.all;

entity corr_ct1_valid_v80 is
    port (
        i_clk  : in std_logic;
        i_rst  : in std_logic;
        o_rstActive : out std_logic; -- high for 20480 clocks after a rising edge on i_rst.
        -- Set valid
        i_setAddr  : in std_logic_vector(20 downto 0); -- 2 million locations possible, equivalent to 16 GByte of HBM, but only 9 GBytes HBM is used, and 1,310,720 is the maximum value allowed for input addresses
        i_setValid : in std_logic;  -- There must be at least one idle clock between set requests.
        o_duplicate : out std_logic;
        -- clear valid
        i_clearAddr : in std_logic_vector(20 downto 0);
        i_clearValid : in std_logic; -- There must be at least one idle clock between clear requests.
        -- Read contents, fixed 5 clock latency
        i_readAddr : in std_logic_vector(20 downto 0);
        o_readData : out std_logic
    );
end corr_ct1_valid_v80;

architecture Behavioral of corr_ct1_valid_v80 is
    
begin
    o_rstActive <= '0';
    o_duplicate <= '0';
    o_readData <= '0';
end Behavioral;

