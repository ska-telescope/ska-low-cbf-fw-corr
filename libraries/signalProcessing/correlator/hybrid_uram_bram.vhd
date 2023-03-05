----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 08/12/2022 03:31:05 PM
-- Module Name: hybrid_uram_bram - Behavioral 
-- Description: 
--   Memory for the long term accumulator.
--   Constructed from 128 ultraRAMs total.
--   Consists of 32 separate memories, each with 4 ultraRAMs. 
--   Each group of 4 urams is 16384 deep x 72 bits wide.
--   This allows simultaneous read and write from one memory, and read from the other memory.
--   On readout, 
----------------------------------------------------------------------------------
library IEEE, common_lib, xpm;
use IEEE.STD_LOGIC_1164.ALL;
USE common_lib.common_pkg.ALL;
use xpm.vcomponents.all;
use IEEE.NUMERIC_STD.ALL;

entity LTA_urams is
    port( 
        i_clk : in std_logic;
        -- Which buffer is used for read + write ?
        i_bufSelect : in std_logic;
        -- 
        i_wrAddr : in t_slv()
    );
end LTA_urams;

architecture Behavioral of LTA_urams is

begin


end Behavioral;
