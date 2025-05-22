----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 08/17/2022 01:11:32 PM
-- Module Name: vis2fp - Behavioral
-- Description: 
--  Convert visibilities to floating point at the output of the correlator.
--  8 parallel data paths for converting 32 bit integers into 32-bit floats.
--  Also scales by the number of valid samples.
--
--  Operation is  data_in / (valid_samples / total_samples) 
--  where : 
--   data_in       = the real or imaginary part of the visibilities
--   valid_samples = Number of samples accumulated to form this visibility.
--   total_samples = Maximum number of samples that could have been used to form the visibility; i.e. n_channels * n_time_samples.
--     
--  Implemented as   ((1/valid_samples) * total_samples) * data_in
--                      |               |                |
--           inverse via ROM look up. float_x_int.  Xilinx float_x_float ip block
--                                             
--
-- Data Path :
--
--          valid_count                               256 bit data in (8 x 32bit integers)
--        (number of samples accumulated                             |
--         in the correlator, max value                              |
--         is 24*192 = 4608)                                         |
--              |                                                    |
--              |                                                    |
--        ROM look up inverse [3 cycle latency]      8 instances of int2float (xilinx IP)   [7 cycle latency]
--              |                                                    |
--        multiply by max samples [fp32 x Uint13, 4 cycle latency]   |
--              |                                                    |
--              |                                                    |
--              ----------------------------------> 8 instances of floating point multipliers [9 clocks latency]
--                                                                   |
--                                                            256 bit data out
--
--
----------------------------------------------------------------------------------
library IEEE, correlator_lib, common_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
USE common_lib.common_pkg.ALL;

entity vis2fp is
    port(
        i_clk : in std_logic;
        -- data input
        i_valid        : in std_logic;
        i_vis          : in std_logic_vector(255 downto 0);
        i_validSamples : in std_logic_vector(15 downto 0);
        i_Ntimes       : in std_logic_vector(7 downto 0);
        i_Nchannels    : in std_logic_vector(6 downto 0);
        -- Data output, 16 clock latency
        o_vis : out std_logic_vector(255 downto 0);
        o_valid : out std_logic
    );
end vis2fp;

architecture Behavioral of vis2fp is

    signal Ntimes : std_logic_vector(8 downto 0);
    signal Nchannels : std_logic_vector(7 downto 0);
    signal totalSamples_s : signed(16 downto 0);
    signal totalSamples : std_logic_vector(15 downto 0);
    signal validInv_fp32, invScaled_fp32 : std_logic_vector(31 downto 0);

    -- 6 cycle latency
    component int_to_fp32
    port (
        aclk : IN STD_LOGIC;
        s_axis_a_tvalid : IN STD_LOGIC;
        s_axis_a_tdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
        m_axis_result_tvalid : OUT STD_LOGIC;
        m_axis_result_tdata : OUT STD_LOGIC_VECTOR(31 DOWNTO 0));
    end component;
    
    -- 8 cycle latency
    component mult_fp32
    port (
        aclk : IN STD_LOGIC;
        s_axis_a_tvalid : IN STD_LOGIC;
        s_axis_a_tdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
        s_axis_b_tvalid : IN STD_LOGIC;
        s_axis_b_tdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
        m_axis_result_tvalid : OUT STD_LOGIC;
        m_axis_result_tdata : OUT STD_LOGIC_VECTOR(31 DOWNTO 0));
    end component;    
    
    signal vis_fp32 : t_slv_32_arr(7 downto 0);
    signal vis_fp32_valid : std_logic_vector(7 downto 0);
    signal validOut : std_logic_vector(7 downto 0);
    
    signal visDel1 : std_logic_vector(255 downto 0);
    signal validDel1 : std_logic;
    signal validInv_fp32_exp_adjust : std_logic_vector(3 downto 0);
    
begin
    
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            -- Calculate the maximum possible value for valid_samples.
            -- 3 cycle latency, so the output matches the output from the inverse lookup ("inv_rom_top")
            Ntimes <= '0' & i_Ntimes;
            Nchannels <= '0' & i_Nchannels;
            totalSamples_s <= signed(Ntimes) * signed(Nchannels); -- 9 bit x 8 bit
            -- The maximum possible value should be 127 * 192 = 24384, so the top bit of totalSamples must be 0
            totalSamples <= std_logic_vector(totalSamples_s(15 downto 0));
            
            visDel1 <= i_vis;
            validDel1 <= i_valid;
            
        end if;
    end process;
    
    -- 3 cycle latency
    inv_romi : entity correlator_lib.inv_rom_top
    port map (
        i_clk => i_clk,          -- in std_logic;
        i_din => i_validSamples, -- in std_logic_vector(12 downto 0); -- Integer values in the range 0 to 4608
        -- inverse of i_din, as a single precision floating point value, 3 clock latency. 
        -- Divide by 0 gives an output of 0. (not NaN or Inf). 
        o_dout => validInv_fp32, -- out (31:0) floating point result
        o_exp_adjust => validInv_fp32_exp_adjust  -- out std_logic_vector(3 downto 0) -- Amount to subtract from the exponent in o_dout
    );
    
    -- 4 cycle latency
    fp32_x_uinti : entity correlator_lib.fp32_x_Uint
    port map (
        i_clk  => i_clk, --  in std_logic;
        i_fp32 => validInv_fp32, --  in std_logic_vector(31 downto 0);
        i_fp32_exp_adjust => validInv_fp32_exp_adjust, -- in (3:0)
        i_uint => totalSamples(15 downto 0), --  in std_logic_vector(15 downto 0); -- unsigned integer value
        -- 
        o_fp32 => invScaled_fp32 --  out std_logic_vector(31 downto 0) -- 4 cycle latency
    );


    int2fp32_gen : for i in 0 to 7 generate
        
        -- Convert 32 bit integers in i_vis to signal precision floats
        -- 6 cycle latency, needs 1 extra cycle to match the combined latency of inv_romi and fp32_x_uint1
        int2fp32i : int_to_fp32
        port map (
            aclk => i_clk,
            s_axis_a_tvalid => validDel1,
            s_axis_a_tdata => visDel1((32*i + 31) downto (32*i)),
            m_axis_result_tvalid => vis_fp32_valid(i),
            m_axis_result_tdata => vis_fp32(i)
        );
        
        -- 8 cycle latency
        multfp32i : mult_fp32
        port map (
            aclk            => i_clk,
            s_axis_a_tvalid => '1',
            s_axis_a_tdata  => invScaled_fp32,
            s_axis_b_tvalid => vis_fp32_valid(i),
            s_axis_b_tdata  => vis_fp32(i),
            m_axis_result_tvalid => validout(i),
            m_axis_result_tdata => o_vis((32*i + 31) downto (32*i))
        );
        
    end generate;
    
    o_valid <= validOut(0);
    
end Behavioral;
