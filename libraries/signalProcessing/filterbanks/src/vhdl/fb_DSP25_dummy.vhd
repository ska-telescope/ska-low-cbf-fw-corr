----------------------------------------------------------------------------------
-- Company: CSIRO - CASS 
-- Engineer: David Humphrey
-- 
-- Create Date: 15.11.2018 14:15:15
-- Module Name: fb_DSP - Behavioral
-- Description: 
--  FIR filter.
--  Input is assumed staggered by 1 clock (e.g. sample 9 arrives 9 clocks after sample 1), so that 
--  the adders in the DSPs can be used for the adder tree in the FIR filter.
--
-- From the DSP guide, UG579, on designing for low power (page 59) -
--  * Use the M register.
--  * Use the cascade paths between DSPs
--  * Put operands in the most significant bits, tie the lower bits to zero.
--  * If a multiplier input is a constant, it should go on the B input. (although this does not apply here, since inputs are not constants)
--
-- Latency is 3 clocks from the last data sample (or TAPS + 3 clocks from the first data sample).
----------------------------------------------------------------------------------
library IEEE, common_lib, filterbanks_lib, correlator_lib, signal_processing_common;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use common_lib.common_pkg.all;
use signal_processing_common.target_fpga_pkg.ALL;

entity fb_DSP25 is
    generic (
        TAPS : integer := 12  -- The module instantiates this number of DSP
    );
    port(
        clk : in std_logic;
        data_i : in t_slv_16_arr((TAPS-1) downto 0);
        coef_i : in t_slv_18_arr((TAPS-1) downto 0);
        data_o : out std_logic_vector(24 downto 0)
    );
end fb_DSP25;

architecture Behavioral of fb_DSP25 is
    
begin

    data_o <= (others => '0');
    
end Behavioral;
