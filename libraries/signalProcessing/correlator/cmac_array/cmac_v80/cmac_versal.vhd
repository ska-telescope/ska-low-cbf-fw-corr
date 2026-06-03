----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- Create Date: 12/18/2025 10:06:38 AM
-- Module Name: cmac_versal - Behavioral
-- Description: 
--  complex multiply-accumulate for versal devices.
--  Uses 24x24 bit DSP multiplier to do a complex multiply in a single DSP
----------------------------------------------------------------------------------
library ieee, correlator_lib;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use correlator_lib.cmac_pkg.all; -- defines t_cmac_input_bus

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity cmac_versal is
    -- Fixed to 24 bit accumulator, 8 bit input samples, 5 cycle latency
    --    generic (
        --g_ACCUM_WIDTH     : natural := 24;
        --g_SAMPLE_WIDTH    : natural range 1 to 9 := 8;  -- >6 uses two 18b multiplers
        --g_CMAC_LATENCY    : natural range work.cmac_pkg.c_CMAC_LATENCY to work.cmac_pkg.c_CMAC_LATENCY  -- i.e. 5
    --    );
    generic (
        g_BYPASS_OFFSETS : boolean := True
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
        o_readout_data : out std_logic_vector(47 downto 0)  -- real part in low bits 23:0, imaginary part in bits 47:24
    );
end cmac_versal;

architecture Behavioral of cmac_versal is

    --create_ip -name dsp_macro -vendor xilinx.com -library ip -version 1.0 -module_name dsp_mult_24x24
    --set_property -dict [list \
    --  CONFIG.a_binarywidth {0} \
    --  CONFIG.a_width {24} \
    --  CONFIG.areg_3 {true} \
    --  CONFIG.areg_4 {false} \
    --  CONFIG.b_binarywidth {0} \
    --  CONFIG.b_width {24} \
    --  CONFIG.breg_3 {true} \
    --  CONFIG.breg_4 {false} \
    --  CONFIG.c_binarywidth {0} \
    --  CONFIG.c_width {48} \
    --  CONFIG.concat_binarywidth {0} \
    --  CONFIG.concat_width {48} \
    --  CONFIG.creg_3 {false} \
    --  CONFIG.creg_4 {false} \
    --  CONFIG.creg_5 {false} \
    --  CONFIG.d_width {18} \
    --  CONFIG.instruction1 {A*B} \
    --  CONFIG.mreg_5 {true} \
    --  CONFIG.p_binarywidth {0} \
    --  CONFIG.p_full_width {48} \
    --  CONFIG.p_width {48} \
    --  CONFIG.pcin_binarywidth {0} \
    --  CONFIG.pipeline_options {Expert} \
    --  CONFIG.preg_6 {true} \
    --] [get_ips dsp_mult_24x24]
    --generate_target {instantiation_template} [get_files /home/hum089/projects/perentie/corr_latest/ska-low-cbf-fw-corr/build/corr_mult_test/corr_mult_test.srcs/sources_1/ip/dsp_mult_24x24/dsp_mult_24x24.xci]
    component dsp_mult_24x24
    port (
        CLK : IN STD_LOGIC;
        A   : IN STD_LOGIC_VECTOR(23 DOWNTO 0);
        B   : IN STD_LOGIC_VECTOR(23 DOWNTO 0);
        P   : OUT STD_LOGIC_VECTOR(47 DOWNTO 0));
    end component;
    
    signal row_imag, col_imag, col_imag_conj : std_logic_vector(7 downto 0);
    signal dsp_A, dsp_B : std_logic_vector(23 downto 0);
    signal dsp_P : std_logic_vector(47 downto 0);
    signal re_result, im_result : std_logic_vector(15 downto 0);
    signal real_x_real, real_x_imag, imag_x_imag, ii_carry, ri_carry : std_logic_vector(15 downto 0);
    
    signal pipe_col : t_cmac_input_bus_a(3 downto 0);
    signal c5_col : t_cmac_input_bus;
    signal c6_accum_real, c6_accum_imag : signed(23 downto 0);
    signal c6_load_readout : std_logic;
    
begin
    
    P_FLOP_INPUTS : process (i_clk) is
    begin
        if rising_edge(i_clk) then
            pipe_col <= i_col & pipe_col(pipe_col'high downto 1);
        end if;
    end process;
    c5_col <= pipe_col(0);
    
    
    bypass_gen : if g_BYPASS_OFFSETS generate
        dsp_A(23 downto 16) <= i_row_imag;
        dsp_A(15 downto 8) <= i_row_real(7) & i_row_real(7) & i_row_real(7) & i_row_real(7) & i_row_real(7) & i_row_real(7) & i_row_real(7) & i_row_real(7);
        dsp_A(7 downto 0) <= i_row_real;
        
        dsp_B(23 downto 16) <= i_col_imag;
        dsp_B(15 downto 8) <= i_col_real(7) & i_col_real(7) & i_col_real(7) & i_col_real(7) & i_col_real(7) & i_col_real(7) & i_col_real(7) & i_col_real(7);
        dsp_B(7 downto 0) <= i_col_real;
    end generate;
    
    nobypass_gen : if (not g_BYPASS_OFFSETS) generate
        -- Input to the DSP is (2^16 * imag + real)
        -- Need to subtract 1 from the imaginary part if the real part is negative,
        -- and sign extend the real part into bits 15:8
        row_imag <= i_row_imag when i_row_real(7) = '0' else std_logic_vector(signed(i_row_imag) - 1);
        -- negate i_col_imag, since we are multiplying by the complex conjugate
        col_imag_conj <= std_logic_vector(-signed(i_col_imag));
        col_imag <= col_imag_conj when i_col_real(7) = '0' else std_logic_vector(signed(col_imag_conj) - 1);
        
        dsp_A(23 downto 16) <= row_imag;
        dsp_A(15 downto 8) <= i_row_real(7) & i_row_real(7) & i_row_real(7) & i_row_real(7) & i_row_real(7) & i_row_real(7) & i_row_real(7) & i_row_real(7);
        dsp_A(7 downto 0) <= i_row_real;
        
        dsp_B(23 downto 16) <= col_imag;
        dsp_B(15 downto 8) <= i_col_real(7) & i_col_real(7) & i_col_real(7) & i_col_real(7) & i_col_real(7) & i_col_real(7) & i_col_real(7) & i_col_real(7);
        dsp_B(7 downto 0) <= i_col_real;
    end generate;
    
    -- 3 cycle latency
    dspi : dsp_mult_24x24
    port map (
        clk => i_clk,
        A => dsp_A,
        B => dsp_B,
        P => dsp_P
    );
    
    real_x_real <= dsp_P(15 downto 0);
    real_x_imag <= dsp_P(31 downto 16);
    imag_x_imag <= dsp_P(47 downto 32);
    ii_carry <= "000000000000000" & real_x_imag(15);
    ri_carry <= "000000000000000" & real_x_real(15);
    
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            re_result <= std_logic_vector(signed(real_x_real) - signed(imag_x_imag) - signed(ii_carry));
            im_result <= std_logic_vector(signed(real_x_imag) + signed(ri_carry));
        end if;
    end process;
    
    P_ACCUMULATE : process (i_clk) is
        variable v_feedback_real : signed(23 downto 0);
        variable v_feedback_imag : signed(23 downto 0);
    begin
        if rising_edge(i_clk) then
            -- Real Accumulator
            if c5_col.first='1' then
                v_feedback_real := (others => '0');
            else
                v_feedback_real := c6_accum_real;
            end if;
            c6_accum_real <= v_feedback_real + resize(signed(re_result), 24);

            -- Imag Accumulator
            if c5_col.first='1' then
                v_feedback_imag := (others => '0');
            else
                v_feedback_imag := c6_accum_imag;
            end if;
            c6_accum_imag <= v_feedback_imag + resize(signed(im_result), 24);
            
            c6_load_readout <= c5_col.last;
            
        end if;
    end process;
    
    o_readout_data(23 downto 0) <= std_logic_vector(c6_accum_real);
    o_readout_data(47 downto 24) <= std_logic_vector(c6_accum_imag);
    o_readout_vld <= c6_load_readout;
    
end Behavioral;
