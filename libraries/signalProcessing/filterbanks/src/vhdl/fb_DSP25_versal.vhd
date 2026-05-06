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
--
-- This version uses a double rate clock for the DSPs to process two data streams (i_data0 and i_data1) using the same number of DSPs.
-- Some extra delays are added to make the output exactly match the non-versal version.
----------------------------------------------------------------------------------
library IEEE, common_lib, filterbanks_lib, correlator_lib, signal_processing_common;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use common_lib.common_pkg.all;
use signal_processing_common.target_fpga_pkg.ALL;

entity fb_DSP25_versal is
    port(
        clk     : in std_logic;
        clk_2x  : in std_logic;
        i_data0 : in t_slv_16_arr(11 downto 0);
        i_data1 : in t_slv_16_arr(11 downto 0);
        i_coef  : in t_slv_18_arr(11 downto 0);
        o_data0 : out std_logic_vector(24 downto 0);
        o_data1 : out std_logic_vector(24 downto 0)
    );
end fb_DSP25_versal;

architecture Behavioral of fb_DSP25_versal is

    -- DSP with 3 clock latency.
    -- Function is pcout = p = A*B + PCIN
    -- pcout is the dedicated routing to the next DSP in the column. It can only be connected to PCIN in the next DSP.
    -- p is the normal output available to the rest of the fabric.
    component DSP_AxB_plus_PCIN_versal
    port (
        clk   : in std_logic;
        pcin  : in std_logic_vector(57 downto 0);
        a     : in std_logic_vector(26 downto 0);
        b     : in std_logic_vector(17 downto 0);
        pcout : out std_logic_vector(57 downto 0);
        p     : out std_logic_vector(57 downto 0));
    end component;
    
    -- DSP with 3 clock latency, first in the chain has no pcin
    -- Versal versions have a 58 bit wide accumulator.
    component DSP_AxB_versal
    port (
        clk   : in std_logic;
        a     : in std_logic_vector(26 downto 0);
        b     : in std_logic_vector(17 downto 0);
        pcout : out std_logic_vector(57 downto 0);
        p     : out std_logic_vector(44 downto 0));
    end component;
    
    TYPE t_slv_58_arr is array (integer range <>) of std_logic_vector(57 downto 0);
    signal pc58 : t_slv_58_arr(11 downto 0);
    signal dataFull : t_slv_27_arr(11 downto 0);
    signal finalSum : std_logic_vector(57 downto 0);
    
    signal intPart : std_logic_vector(15 downto 0);
    signal fracPart : std_logic_vector(8 downto 0);
    
    signal toggle_clk, toggle_del_clk_x2, clk_n : std_logic := '0';
    
    signal data0_del1, data0_del2, data0_del3, data0_del4, data0_del5, data0_del6 : t_slv_16_arr(11 downto 0);
    signal data1_del1, data1_del2, data1_del3, data1_del4, data1_del5, data1_del6 : t_slv_16_arr(11 downto 0);
    signal coef_del1, coef_del2, coef_del3, coef_del4, coef_del5, coef_del6 : t_slv_18_arr(11 downto 0);
    
    signal coef : t_slv_18_arr(11 downto 0);
    signal data_out_2x : std_logic_vector(24 downto 0);
    
begin
    
    --
    process(clk)
    begin
        if rising_edge(clk) then
            data0_del1 <= i_data0;
            data0_del2 <= data0_del1;
            data0_del3 <= data0_del2;
            data0_del4 <= data0_del3;
            data0_del5 <= data0_del4;
            data0_del6 <= data0_del5;
            
            data1_del1 <= i_data1;
            data1_del2 <= data1_del1;
            data1_del3 <= data1_del2;
            data1_del4 <= data1_del3;
            data1_del5 <= data1_del4;
            data1_del6 <= data1_del5;
            
            coef_del1 <= i_coef;
            coef_del2 <= coef_del1;
            coef_del3 <= coef_del2;
            coef_del4 <= coef_del3;
            coef_del5 <= coef_del4;
            coef_del6 <= coef_del5;
            
        end if;
    end process;
    
    -- Delay the input to match the double rate processing
    -- The input is already staggered on clk, but needs to be staggered on clk_2x :
    --
    --  dataX_i(0) | del1       | del2       | del3       | del4       | del5       | d0a  | d0b |     |      |                                                      <-- 1st tap : use del6
    --             | dataX_i(1) | del1       | del2       | del3       | del4       |      | d1a | d1b |      |                                                      <-- 2nd tap : use del5, del6
    --             |            | dataX_i(2) | del1       | del2       | del3       | del4       | d2a | d2b  |                                                      <-- 3rd tap : use del5
    --             |            |            | dataX_i(3) | del1       | del2       | del3       |     | d3a  | d3b  |     |                                         <-- 4th tap : use del4, del5
    --             |            |            |            | dataX_i(4) | del1       | del2       | del3       | d4a  | d4b |                                         <-- 5th tap : use del4
    --             |            |            |            |            | dataX_i(5) | del1       | del2       |      | d5a | d5b |      |                            <-- 6th tap : use del3, del4
    --             |            |            |            |            |            | dataX_i(6) | del1       | del2       | d6a | d6b  |                            <-- 7th tap : use del3
    --             |            |            |            |            |            |            | dataX_i(7) | del1       |     | d7a  | d7b |      |               <-- 8th tap : use del2, del3
    --             |            |            |            |            |            |            |            | dataX_i(8) | del1       | d8a | d8b  |               <-- 9th tap : use del2
    --             |            |            |            |            |            |            |            |            | dataX_i(9) |     | d9a  | d9b  |     |            |                  <-- 10th tap : use del1, del2
    --             |            |            |            |            |            |            |            |            |            | dataX_i(10)| d10a | d10b|            |                  <-- 11th tap : use del1
    --             |            |            |            |            |            |            |            |            |            |            | dataX_i(11)| d11b |     | a_res | b_res |  <-- 12th tap : use data_i, del1    
    --                                                                                                                                                                                         | data_o 
    --
    -- First filter tap (no pcin)
    dataFull(0) <= data0_del6(0) & "00000000000" when clk_n = '0' else data1_del6(0) & "00000000000";
    coef(0) <= coef_del6(0);
    
    dsp1i : DSP_AxB_versal
    port map (
        clk  => clk_2x,
        a    => dataFull(0),  -- in(26:0)
        b    => coef(0),      -- in(17:0)
        pcout => pc58(0),     -- out(57:0)
        p     => open         -- out(44:0)
    );
    
    -- 2nd filter tap
    dataFull(1) <= data0_del5(1) & "00000000000" when clk_n = '1' else data1_del6(1) & "00000000000";
    coef(1) <= coef_del5(1) when clk_n = '1' else coef_del6(1);
    
    dsp2i : DSP_AxB_plus_PCIN_versal
    port map (
        clk  => clk_2x,
        pcin => pc58(0),     -- in(57:0)
        a    => dataFull(1), -- in(26:0)
        b    => coef(1),       -- in(17:0)
        pcout => pc58(1),    -- out(57:0)
        p     => open        -- out(57:0)
    );
    
    -- 3rd filter tap
    dataFull(2) <= data0_del5(2) & "00000000000" when clk_n = '0' else data1_del5(2) & "00000000000";
    coef(2) <= coef_del5(2);
    
    dsp3i : DSP_AxB_plus_PCIN_versal
    port map (
        clk  => clk_2x,
        pcin => pc58(1),     -- in(57:0)
        a    => dataFull(2), -- in(26:0)
        b    => coef(2),     -- in(17:0)
        pcout => pc58(2),    -- out(57:0)
        p     => open        -- out(57:0)
    );
    
    -- 4th filter tap
    dataFull(3) <= data0_del4(3) & "00000000000" when clk_n = '1' else data1_del5(3) & "00000000000";
    coef(3) <= coef_del4(3) when clk_n = '1' else coef_del5(3);
    
    dsp4i : DSP_AxB_plus_PCIN_versal
    port map (
        clk  => clk_2x,
        pcin => pc58(2),     -- in(57:0)
        a    => dataFull(3), -- in(26:0)
        b    => coef(3),     -- in(17:0)
        pcout => pc58(3),    -- out(57:0)
        p     => open        -- out(57:0)
    );
    
    -- 5th filter tap
    dataFull(4) <= data0_del4(4) & "00000000000" when clk_n = '0' else data1_del4(4) & "00000000000";
    coef(4) <= coef_del4(4);
    
    dsp5i : DSP_AxB_plus_PCIN_versal
    port map (
        clk  => clk_2x,
        pcin => pc58(3),     -- in(57:0)
        a    => dataFull(4), -- in(26:0)
        b    => coef(4),       -- in(17:0)
        pcout => pc58(4),    -- out(57:0)
        p     => open        -- out(57:0)
    );
    
    -- 6th filter tap
    dataFull(5) <= data0_del3(5) & "00000000000" when clk_n = '1' else data1_del4(5) & "00000000000";
    coef(5) <= coef_del3(5) when clk_n = '1' else coef_del4(5);
    
    dsp6i : DSP_AxB_plus_PCIN_versal
    port map (
        clk  => clk_2x,
        pcin => pc58(4),     -- in(57:0)
        a    => dataFull(5), -- in(26:0)
        b    => coef(5),       -- in(17:0)
        pcout => pc58(5),    -- out(57:0)
        p     => open        -- out(57:0)
    );
    
    -- 7th filter tap
    dataFull(6) <= data0_del3(6) & "00000000000" when clk_n = '0' else data1_del3(6) & "00000000000";
    coef(6) <= coef_del3(6);
    
    dsp7i : DSP_AxB_plus_PCIN_versal
    port map (
        clk  => clk_2x,
        pcin => pc58(5),     -- in(57:0)
        a    => dataFull(6), -- in(26:0)
        b    => coef(6),       -- in(17:0)
        pcout => pc58(6),    -- out(57:0)
        p     => open        -- out(57:0)
    );
    
    -- 8th filter tap
    dataFull(7) <= data0_del2(7) & "00000000000" when clk_n = '1' else data1_del3(7) & "00000000000";
    coef(7) <= coef_del2(7) when clk_n = '1' else coef_del3(7);
    
    dsp8i : DSP_AxB_plus_PCIN_versal
    port map (
        clk  => clk_2x,
        pcin => pc58(6),     -- in(57:0)
        a    => dataFull(7), -- in(26:0)
        b    => coef(7),     -- in(17:0)
        pcout => pc58(7),    -- out(57:0)
        p     => open        -- out(57:0)
    );
    
    -- 9th filter tap
    dataFull(8) <= data0_del2(8) & "00000000000" when clk_n = '0' else data1_del2(8) & "00000000000";
    coef(8) <= coef_del2(8);
    
    dsp9i : DSP_AxB_plus_PCIN_versal
    port map (
        clk  => clk_2x,
        pcin => pc58(7),     -- in(57:0)
        a    => dataFull(8), -- in(26:0)
        b    => coef(8),     -- in(17:0)
        pcout => pc58(8),    -- out(57:0)
        p     => open        -- out(57:0)
    );
    
    -- 10th filter tap
    dataFull(9) <= data0_del1(9) & "00000000000" when clk_n = '1' else data1_del2(9) & "00000000000";
    coef(9) <= coef_del1(9) when clk_n = '1' else coef_del2(9);
    
    dsp10i : DSP_AxB_plus_PCIN_versal
    port map (
        clk  => clk_2x,
        pcin => pc58(8),     -- in(57:0)
        a    => dataFull(9), -- in(26:0)
        b    => coef(9),     -- in(17:0)
        pcout => pc58(9),    -- out(57:0)
        p     => open        -- out(57:0)
    );
    
    -- 11th filter tap
    dataFull(10) <= data0_del1(10) & "00000000000" when clk_n = '0' else data1_del1(10) & "00000000000";
    coef(10) <= coef_del1(10);
    
    dsp11i : DSP_AxB_plus_PCIN_versal
    port map (
        clk  => clk_2x,
        pcin => pc58(9),     -- in(57:0)
        a    => dataFull(10), -- in(26:0)
        b    => coef(10),     -- in(17:0)
        pcout => pc58(10),    -- out(57:0)
        p     => open         -- out(57:0)
    );
    
    -- Last filter tap
    dataFull(11) <= i_data0(11) & "00000000000" when clk_n = '1' else data1_del1(11) & "00000000000";
    coef(11) <= i_coef(11) when clk_n = '1' else coef_del1(11);
    dsp12i : DSP_AxB_plus_PCIN_versal
    port map (
        clk  => clk_2x,
        pcin => pc58(10),     -- in(47:0)
        a    => dataFull(11), -- in(26:0)
        b    => coef(11),     -- in(17:0)
        pcout => open,        -- out(47:0)
        p     => finalSum     -- out(47:0)
    );
    
    -- FIR scaling :
    --  The deripple filter scales up by a factor of x128 (maximum output from the deripple filter is about x160)
    --  So largest input data is ~ 160 * 128 = 20480
    --  Largest filter tap is about 76000
    --  Largest possible output of a single multiplication is 76000 * 20480 = 1.56 * 10^9
    --  data_i is additionally scaled up by a factor of 2048 (zero padding above to get "dataFull" from "data_i")
    --  From SPS data to the output of this module, rms scaling :
    --   = (sps data) * (128 (deripple)) * (65536 (this FIR filter)) * (2048 (scale up to left-align)) / (2^19 final scaling below) 
    --   = (sps data) * 2^15
    --
    --  Note : The maximum value for the SPS data is 127, peak values for the filters can scale up by a factor of about 1.5,
    --         so the peak output value is about 1.5 * 127 * 2^15, which fit in the 25 bit output, so it cannot saturate.
    --  
    
    process(clk_2x)
    begin
        if rising_edge(clk_2x) then
            data_out_2x <= finalSum(43 downto 19);
        end if;
    end process;
    
    process(clk)
    begin
        if rising_Edge(clk) then
            o_data0 <= data_out_2x;
            o_data1 <= finalSum(43 downto 19);
        end if;
    end process;
    
    
    ---------------------------------------------------------------------------
    -- signals to control double rate operation for the DSPs
    process(clk)
    begin
        if rising_edge(clk) then
            toggle_clk <= not toggle_clk;
        end if;
    end process;
    
    process(clk_2x)
    begin
        if rising_edge(clk_2x) then
            toggle_del_clk_x2 <= toggle_clk;
            -- clk_n is a signal with the inverted waveform of clk
            clk_n <= toggle_del_clk_x2 xor toggle_clk;
        end if;
    end process;    
    
end Behavioral;
