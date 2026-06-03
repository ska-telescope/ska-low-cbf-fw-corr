----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (Dave.humphrey@csiro.au)
-- 
-- Create Date: 12/17/2025 02:18:32 PM
-- Module Name: v80_test_top - Behavioral 
-- Description: 
--   test synthesis and place and route of cmac
----------------------------------------------------------------------------------
library IEEE, correlator_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use correlator_lib.cmac_pkg.all;

entity v80_test_top is
    Port ( 
        i_clk : in std_logic;
        i_row_data : in std_logic_Vector(15 downto 0);
        i_col_data : in std_logic_Vector(15 downto 0);
        i_valid : in std_logic;
        i_first : in std_logic;
        i_last : in std_logic;
        o_XX_vld : out std_logic;
        o_XX_data : out std_logic_vector(47 downto 0)
    );
end v80_test_top;

architecture Behavioral of v80_test_top is

    signal row_meta : t_cmac_input_bus;
    signal XX_vld_versal : std_logic;
    signal XX_data_versal : std_logic_vector(47 downto 0);
        
begin
    
    -----------------------------------------------------------------
    -- 51 LUTs, 2 DSPs
    
    row_meta.vld <= i_valid; -- : in t_cmac_input_bus;              -- .vld, .first, .last, .rfi, .sample_cnt
    row_meta.first <= i_first;
    row_meta.last <= i_last;
    row_meta.rfi <= '0';
    row_meta.sample_cnt <= (others => '0');

--    cmac_XX : entity correlator_lib.cmac
--    generic map (
--        g_ACCUM_WIDTH     => 24, -- natural := 24;
--        g_SAMPLE_WIDTH    => 8,  -- natural range 1 to 9 := 8;  -- >6 uses two 18b multiplers
--        g_CMAC_LATENCY    => 5   -- natural range work.cmac_pkg.c_CMAC_LATENCY to work.cmac_pkg.c_CMAC_LATENCY  -- i.e. 5
--    ) port map (
--        i_clk       => i_clk, -- in std_logic;
--        i_clk_reset => '0',   -- in std_logic;  -- all this does is disable simulation error messages.

--        i_row       => row_meta,   -- in t_cmac_input_bus;  only uses .vld, .first and .last
--        i_row_real  => i_row_data(7 downto 0),  -- in std_logic_vector(7 downto 0);
--        i_row_imag  => i_row_data(15 downto 8), -- in std_logic_vector(7 downto 0);
        
--        i_col       => row_meta, --  in t_cmac_input_bus;
--        i_col_real  => i_col_data(7 downto 0),  --  in std_logic_vector(7 downto 0);
--        i_col_imag  => i_col_data(15 downto 8), --  in std_logic_vector(7 downto 0);

--        -- Readout interface. Readout pulses high 5 clocks after i_<col|row>.last
--        o_readout_vld  => o_XX_vld, -- out std_logic;
--        o_readout_data => o_XX_data -- out std_logic_vector((g_ACCUM_WIDTH*2 - 1) downto 0)  -- real part in low g_ACCUM_WIDTH bits, imaginary part in high g_ACCUM_BITS 
--    );
    
    --------------------------------------------------------------
    -- 95 LUTs, 84 FF, 1 DSP
    cmac_versalXX : entity correlator_lib.cmac_versal
    port map (
        i_clk       => i_clk, -- in std_logic;
        i_clk_reset => '0',   -- in std_logic;  -- all this does is disable simulation error messages.

        i_row       => row_meta,   -- in t_cmac_input_bus;  only uses .vld, .first and .last
        i_row_real  => i_row_data(7 downto 0),  -- in std_logic_vector(7 downto 0);
        i_row_imag  => i_row_data(15 downto 8), -- in std_logic_vector(7 downto 0);
        
        i_col       => row_meta, --  in t_cmac_input_bus;
        i_col_real  => i_col_data(7 downto 0),  --  in std_logic_vector(7 downto 0);
        i_col_imag  => i_col_data(15 downto 8), --  in std_logic_vector(7 downto 0);

        -- Readout interface. Readout pulses high 5 clocks after i_<col|row>.last
        o_readout_vld  => XX_vld_versal, -- out std_logic;
        o_readout_data => XX_data_versal -- out std_logic_vector((g_ACCUM_WIDTH*2 - 1) downto 0)  -- real part in low g_ACCUM_WIDTH bits, imaginary part in high g_ACCUM_BITS 
    );
    o_XX_vld <= XX_vld_versal;
    o_XX_data <= XX_data_versal;
    ----------------------------------------------------------------------

end Behavioral;
