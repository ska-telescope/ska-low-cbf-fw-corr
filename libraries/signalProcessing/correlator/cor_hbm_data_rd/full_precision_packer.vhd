----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: April 2026
-- Design Name: 
-- Module Name: half_precision_packer
-- Description: 
-- 
-- 
-- Half precision will require a pipeline of at least 5 and will wrap around at 9 steps.
--
--
--
----------------------------------------------------------------------------------

library IEEE, correlator_lib, common_lib, spead_lib, signal_processing_common, xpm;

use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use common_lib.common_pkg.ALL;
use xpm.vcomponents.ALL;


entity full_precision_packer is
    port (
        clk                 : in STD_LOGIC;
        reset               : in STD_LOGIC;

        ------------------------------------------------------
        -- data from the picker FSM
        i_sorted_data       : in STD_LOGIC_VECTOR(271 downto 0);
        i_sorted_data_wr    : in STD_LOGIC;

        o_data_valid        : out STD_LOGIC;
        o_data_out          : out STD_LOGIC_VECTOR(511 downto 0)
    );
end full_precision_packer;

architecture Behavioral of full_precision_packer is


begin


end Behavioral;
