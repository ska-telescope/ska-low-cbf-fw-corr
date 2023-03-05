-------------------------------------------------------------------------------
-- Title      : 9b Complex Multiply Accumulate
-- Project    : 
-------------------------------------------------------------------------------
-- File       : cmac.vhd
-- Author     : William Kamp  <william.kamp@aut.ac.nz>
-- Company    : 
-- Created    : 2016-07-22
-- Last update: 2018-07-20
-- Platform   : 
-- Standard   : VHDL'2008
-------------------------------------------------------------------------------
-- Description: Implements the kernel of a complex multiply accumulate function,
--              a node in the systolic array correlator.
--
--              The kernel performs one complex multiply and accumulate per cycle.
--
--              The 'last' flag on the column input bus dumps the accumulators to
--              the readout and resets to zero for the next accumulation.
--              The complex conjugate of the accumulation can also be dumped to
--              the readout bus, either before or after, and only when i_col.auto_corr = '1'.
---------------------------------------------------------------------------------
-- Copyright (c) 2016 
-------------------------------------------------------------------------------
-- Revisions  :
-- Date        Version  Author  Description
-- 2017-03-06  1.0      will    Created
-- 2019-09-16  2.0p     nabel   Ported to Perentie
-------------------------------------------------------------------------------
library ieee, correlator_lib;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use correlator_lib.cmac_pkg.all;                  -- t_cmac_input_bus

entity cmac is

    generic (
        g_ACCUM_WIDTH     : natural := 24;
        g_SAMPLE_WIDTH    : natural range 1 to 9 := 8;  -- >6 uses two 18b multiplers
        g_CMAC_LATENCY    : natural range work.cmac_pkg.c_CMAC_LATENCY to work.cmac_pkg.c_CMAC_LATENCY  -- i.e. 5
    );
    port (
        i_clk       : in std_logic;
        i_clk_reset : in std_logic;  -- all this does is disable simulation error messages.

        i_row : in t_cmac_input_bus;
        i_row_real : in std_logic_vector(7 downto 0);
        i_row_imag : in std_logic_vector(7 downto 0);
        
        i_col : in t_cmac_input_bus;
        i_col_real : in std_logic_vector(7 downto 0);
        i_col_imag : in std_logic_vector(7 downto 0);

        -- Readout interface, Loaded by i_<col|row>.last
        o_readout_vld  : out std_logic;
        o_readout_data : out std_logic_vector((g_ACCUM_WIDTH*2 - 1) downto 0)  -- real part in low g_ACCUM_WIDTH bits, imaginary part in high g_ACCUM_BITS 
    );
end entity cmac;

architecture ultrascale of cmac is
    
    constant c_MULT_WIDTH    : natural := (g_SAMPLE_WIDTH) + (g_SAMPLE_WIDTH - 1) + 1;
    constant c_DSP_PIPELINE_CYCLES : natural := g_CMAC_LATENCY-1;  -- 5 - 1, i.e. 4
    
    -- Pipelines for the DSP block.
    signal pipe_col : t_cmac_input_bus_a(c_DSP_PIPELINE_CYCLES-1 downto 0);
    signal c5_col : t_cmac_input_bus;
    
    signal c5_prod_imag  : signed(c_MULT_WIDTH-1 downto 0);  -- 16 bit for 8 bit samples.
    signal c5_prod_real  : signed(c_MULT_WIDTH-1 downto 0);
    signal c5_carry_real : std_logic;
    signal c5_carry_imag : std_logic;
    
    signal c6_accum_real : signed(g_ACCUM_WIDTH-1 downto 0);
    signal c6_accum_imag : signed(g_ACCUM_WIDTH-1 downto 0);
    signal c6_accum      : signed(c6_accum_real'length+c6_accum_imag'length-1 downto 0);
    signal c6_accum_conj : signed(c6_accum'range);
    
    signal c6_load_readout : std_logic;
    signal c6_auto_mode    : std_logic;
    signal c6_load_readout_delay : std_logic;
    signal c6_auto_mode_delay    : std_logic;
    
begin  -- architecture rtl    

    P_FLOP_INPUTS : process (i_clk) is
    begin
        if rising_edge(i_clk) then
            pipe_col <= i_col & pipe_col(pipe_col'high downto 1);
        end if;
    end process;
    c5_col   <= pipe_col(0);

    E_MULT_ADD: ENTITY correlator_lib.mult_add
    GENERIC MAP (
        g_DSP_PIPELINE_CYCLES => c_DSP_PIPELINE_CYCLES,     
        g_BIT_WIDTH           => g_SAMPLE_WIDTH
    ) PORT MAP (
        i_clk   => i_clk,
        i_vld   => '1',
        i_a_re  => signed(i_row_real), -- i_row.data(g_SAMPLE_WIDTH*1-1 downto g_SAMPLE_WIDTH*0), 
        i_a_im  => signed(i_row_imag), -- i_row.data(g_SAMPLE_WIDTH*3-1 downto g_SAMPLE_WIDTH*2),
        i_b_re  => signed(i_col_real), -- i_col.data(g_SAMPLE_WIDTH*1-1 downto g_SAMPLE_WIDTH*0),
        i_b_im  => signed(i_col_imag), -- i_col.data(g_SAMPLE_WIDTH*3-1 downto g_SAMPLE_WIDTH*2),
        o_p_vld => open,
        o_p_re  => c5_prod_real,
        o_p_im  => c5_prod_imag
    );

    c5_carry_real <= c5_prod_imag(c5_prod_imag'HIGH); -- correction if imaginary was negative
    c5_carry_imag <= '0';
    
    P_ACCUMULATE : process (i_clk) is
        variable v_feedback_real : signed(c6_accum_real'range);
        variable v_accum_real    : signed(c6_accum_real'high+1 downto 0);
        variable v_feedback_imag : signed(c6_accum_imag'range);
        variable v_accum_imag    : signed(c6_accum_imag'high+1 downto 0);
    begin
        if rising_edge(i_clk) then
            -- Real Accumulator
            if c5_col.first='1' then
                v_feedback_real := (others => '0');
            else
                v_feedback_real := c6_accum_real;
            end if;
            v_accum_real  := (v_feedback_real & '1') + (resize(c5_prod_real, c6_accum_real'length) & c5_carry_real);
            c6_accum_real <= v_accum_real(v_accum_real'high downto 1);

            -- Imag Accumulator
            if c5_col.first='1' then
                v_feedback_imag := (others => '0');
            else
                v_feedback_imag := c6_accum_imag;
            end if;
            v_accum_imag  := (v_feedback_imag & '1') + (resize(c5_prod_imag, c6_accum_imag'length) & c5_carry_imag);

            c6_accum_imag <= v_accum_imag(v_accum_imag'high downto 1);

        end if;
    end process;

--------------------------------------------------------------------------------------------------------------------
-- Readout
--------------------------------------------------------------------------------------------------------------------

    P_READOUT_VLD : process (i_clk) is
    begin  -- process
        if rising_edge(i_clk) then
            c6_load_readout <= c5_col.last;
        end if;
    end process;
    
    o_readout_data(g_ACCUM_WIDTH-1 downto 0) <= std_logic_vector(c6_accum_real);
    o_readout_data(2*g_ACCUM_WIDTH - 1 downto g_ACCUM_WIDTH) <= std_logic_vector(c6_accum_imag);
    o_readout_vld <= c6_load_readout;
    
    -- synthesis translate_off
    P_CHECK_INPUT : process (i_clk) is
    begin
        if rising_edge(i_clk) then
            if not i_clk_reset='1' then
                assert i_row.vld = i_col.vld
                    report "Row and Column data must be vaild at exactly the same time."
                    severity error;
                assert i_row.last = i_col.last
                    report "Row and Column data packets must end at exactly the same time."
                    severity error;
            end if;
        end if;
    end process;
    -- synthesis translate_on

end architecture ultrascale;

