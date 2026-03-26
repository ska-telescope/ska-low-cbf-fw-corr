----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: March 2026
-- Design Name: 
-- Module Name: float32_to_float16
-- Description: 
-- 
-- 
-- Encoding procedure : 
--
--     Start with the single precision floating point value
--     Divide by 2^14. This can be implemented by subtracting 14 from the exponent of the single precision value (bits 30:23 in the single precision number)
--     Use standard IP to convert single precision to half precision
--
-- Wrap to zero if the subtraction goes negative.
--
-- Used fixed length IP.
----------------------------------------------------------------------------------

library IEEE, correlator_lib, common_lib, spead_lib, signal_processing_common;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
Library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;
USE common_lib.common_pkg.ALL;
library xpm;
use xpm.vcomponents.all;


entity float32_to_float16 is
    port (
        clk                 : in STD_LOGIC;
        reset               : in STD_LOGIC;
        
        i_valid             : in STD_LOGIC;
        i_data_in           : in STD_LOGIC_VECTOR(31 downto 0);

        ------------------------------------------------------

        o_valid             : out STD_LOGIC;
        o_data_out          : out STD_LOGIC_VECTOR(15 downto 0)
    );
end float32_to_float16;

architecture Behavioral of float32_to_float16 is


end Behavioral;
