----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 02/04/2025 01:33:19 PM
-- Module Name: flattening_wrapper - Behavioral
-- Description: 
--   Flattening filter. 
--   The filter is 31 taps.
--   First frame after i_sof needs an extra 31 samples to preload the FIR filter. 
-- 
----------------------------------------------------------------------------------

library IEEE, common_lib, DSP_top_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use common_lib.common_pkg.ALL;
use DSP_top_lib.DSP_top_pkg.all;

entity flattening_wrapper is
    port (
        clk : in std_logic;
        -----------------------------------------------------------
        -- Data in
        i_sof     : in std_logic;
        i_sofFull : in std_logic;
        i_data    : in t_slv_32_arr(3 downto 0);
        i_valid   : in std_logic;
        -- flatten select :
        --  "00" = identity filter
        --  "01" = Compensate for TPM 16d filter
        --  "10" = Compensate for TPM 18a filter
        i_flatten_select : in std_logic_vector(1 downto 0); 
        -----------------------------------------------------------
        -- Data out
        o_HPol0   : out t_slv_16_arr(1 downto 0);
        o_VPol0   : out t_slv_16_arr(1 downto 0);
        o_HPol1   : out t_slv_16_arr(1 downto 0);
        o_VPol1   : out t_slv_16_arr(1 downto 0);
        o_HPol2   : out t_slv_16_arr(1 downto 0);
        o_VPol2   : out t_slv_16_arr(1 downto 0);
        o_HPol3   : out t_slv_16_arr(1 downto 0);
        o_Vpol3   : out t_slv_16_arr(1 downto 0);
        o_valid   : out std_logic;
        o_sof     : out std_logic;
        o_sofFull : out std_logic
    );
end flattening_wrapper;

architecture Behavioral of flattening_wrapper is
    
    -- Symmetric FIR filter IP is created in corr_ct1.tcl
    -- Properties:

    --create_ip -name fir_compiler -vendor xilinx.com -library ip -version 7.2 -module_name sps_flatten
    --set_property -dict [list \
    --  CONFIG.CoefficientVector \
    --{0,  0, 0,    0,  0,   0,   0,   0,  0,    0,   0,    0,   0,    0,   0,     0,    0,     0,    0,     0,    0,     0,    0,     0, 65536,     0,    0,     0,    0,     0,    0,     0,    0,     0,    0,    0,   0,    0,   0,    0,  0,   0,  0,   0,  0,   0,  0,  0, 0, \
    -- 3, -6, 10, -16, 24, -34,  46, -61, 98, -128, 173, -229, 300, -387, 488,  -621, 1881, -1705, 2110, -2498, 2861, -3172, 3411, -3562, 69172, -3562, 3411, -3172, 2861, -2498, 2110, -1705, 1881,  -621,  488, -387, 300, -229, 173, -128, 98, -61, 46, -34, 24, -16, 10, -6, 3, \
    -- 1, -2, 4,   -7, 12, -21,  36, -51, 78, -111, 155, -213, 284, -362, 652, -1263, 1209, -1653, 1944, -2288, 2583, -2843, 3040, -3165, 68751, -3165, 3040, -2843, 2583, -2288, 1944, -1653, 1209, -1263,  652, -362, 284, -213, 155, -111, 78, -51, 36, -21, 12,  -7,  4, -2, 1} \
    --  CONFIG.Coefficient_Fractional_Bits {0} \
    --  CONFIG.Coefficient_Sets {3} \
    --  CONFIG.Coefficient_Sign {Signed} \
    --  CONFIG.Coefficient_Structure {Inferred} \
    --  CONFIG.Coefficient_Width {18} \
    --  CONFIG.Component_Name {sps_flatten} \
    --  CONFIG.Data_Fractional_Bits {0} \
    --  CONFIG.Data_Width {8} \
    --  CONFIG.Output_Rounding_Mode {Full_Precision} \
    --  CONFIG.Quantization {Integer_Coefficients} \
    --  CONFIG.Clock_Frequency {300.0} \
    --  CONFIG.Sample_Frequency {300} \
    --  CONFIG.Filter_Architecture {Systolic_Multiply_Accumulate} \
    --  CONFIG.Output_Rounding_Mode {Convergent_Rounding_to_Even} \
    --  CONFIG.Output_Width {16} \
    --] [get_ips sps_flatten]
    --create_ip_run [get_ips sps_flatten]    
     
    --
    -- The filter taps scale the total power across the band by 65536
    -- For the 16d filter, sum(abs(FIR taps)) = 116820
    -- For the 18a filter, sum(abs(FIR taps)) = 112705
    -- i.e. the filter can potentially scale up pathological input data by a factor of
    --  116820/65536 = 1.78
    --
    -- With 16 bit output, an input pulse value of 64 leads to an output value of 
    -- ... -230 8521 -230 ...
    -- So the output is scaled up by a factor of 128  
    -- (64 * 128 = 8192, peak of the impulse response is a bit higher)
    -- For 8 bit data at the input, we want
    --  128 -> 16384, so that there is some headroom since the filter can produce larger values at the output than the input.
    -- Max range for a 16 bit value is +/- 32767, so with 128 at the input mapping to 16384, we will use a range of +/- 1.78 * 16384 = +/- 29164
    --
    constant c_FIR_TAPS : integer := 49; -- Number of FIR taps used in the filter
    
    component sps_flatten
    port (
        aclk               : in std_logic;
        s_axis_data_tvalid : in std_logic;
        s_axis_data_tready : out std_logic;
        s_axis_data_tdata  : in std_logic_vector(7 downto 0);
        -- single bit of configuration data, '0' to select compensation, '1' for pass through
        s_axis_config_tvalid : in  std_logic;
        s_axis_config_tready : out std_logic;
        s_axis_config_tdata  : in  std_logic_vector(7 downto 0); -- 0x0 for identity, 0x1 TPM 16d filter, 0x2 for TPM 18a filter.
        -- Output
        m_axis_data_tvalid : out std_logic;
        m_axis_data_tdata  : out std_logic_vector(15 downto 0));
    end component;
    
    signal readoutData : t_slv_64_arr(3 downto 0);
    signal output_count : std_logic_vector(5 downto 0);
    signal drop_samples : std_logic := '0';
    signal valid_out    : std_logic_vector(15 downto 0);
    signal data_zeroed  : t_slv_32_arr(3 downto 0);
    signal config_tdata : std_logic_vector(7 downto 0);
    signal sof_del, sofFull_del : std_logic_vector(c_FIR_TAPS-4 downto 0) := (others => '0');
    
begin
    
    process(clk)
    begin
        if rising_edge(clk) then
            -- For the first packet after start of frame, we get an extra g_SAMPLES_TO_DROP samples 
            -- to initialise the state of the filter, and we have to drop the first 
            -- 30 samples from the output of the filter.
            if sof_del(c_FIR_TAPS-4) = '1' then
                drop_samples <= '1';
            elsif unsigned(output_count) > (c_FIR_TAPS-3) then
                -- comparison with c_FIR_TAPS-3 because its a few clocks behind 
                drop_samples <= '0'; 
            end if;
            
            if sof_del(c_FIR_TAPS-4) = '1' then
                -- Count the samples after the start of frame so we can drop the 
                -- first 30 of them.
                output_count <= (others => '0');
            elsif valid_out(0) = '1' and unsigned(output_count) < 63 then
                -- This only counts to 63, as we only need to know for the first 30 samples.
                output_count <= std_logic_vector(unsigned(output_count) + 1);
            end if;
            
            config_tdata <= "000000" & i_flatten_select;
            
            sof_del((c_FIR_TAPS-4) downto 1) <= sof_del((c_FIR_TAPS-5) downto 0);
            sofFull_del((c_FIR_TAPS-4) downto 1) <= sofFull_del((c_FIR_TAPS-5) downto 0);
            
        end if;
    end process;
    
    sof_del(0) <= i_sof;
    sofFull_del(0) <= i_sofFull;

    o_sof <= sof_del(c_FIR_TAPS-4);
    o_sofFull <= sofFull_del(c_FIR_TAPS-4);
    
    fgen1 : for i in 0 to 3 generate
        fgen2 : for j in 0 to 3 generate
        
            data_zeroed(i)(j*8+7 downto j*8) <= x"00" when i_data(i)((j*8 + 7) downto j*8) = "10000000" else i_data(i)((j*8 + 7) downto j*8);
            
            si : sps_flatten
            port map (
                aclk => clk,
                s_axis_data_tvalid => i_valid,
                s_axis_data_tready => open,
                s_axis_data_tdata => data_zeroed(i)((j*8 + 7) downto j*8),
                --
                s_axis_config_tvalid => '1', -- in  std_logic;
                s_axis_config_tready => open, -- out std_logic;
                s_axis_config_tdata  => config_tdata, -- in (7:0); 0x0 for ripple compensation filter, 0x1 for identity filter (pass-through) with the same gain.
                --
                m_axis_data_tvalid => valid_out(i*4 + j),
                m_axis_data_tdata => readoutData(i)((j*16+15) downto j*16)
            );
        end generate;
    end generate;
    
    o_valid <= '1' when valid_out(0) = '1' and drop_samples = '0' else '0';
    o_HPol0(0) <= readoutData(0)(15 downto 0);  -- 8 bit real part
    o_HPol0(1) <= readoutData(0)(31 downto 16); -- 8 bit imaginary part
    o_VPol0(0) <= readoutData(0)(47 downto 32); -- 8 bit real part
    o_VPol0(1) <= readoutData(0)(63 downto 48); -- 8 bit imaginary part
    o_HPol1(0) <= readoutData(1)(15 downto 0);  -- 8 bit real part
    o_HPol1(1) <= readoutData(1)(31 downto 16); -- 8 bit imaginary part
    o_VPol1(0) <= readoutData(1)(47 downto 32); -- 8 bit real part
    o_VPol1(1) <= readoutData(1)(63 downto 48); -- 8 bit imaginary part
    o_HPol2(0) <= readoutData(2)(15 downto 0);  -- 8 bit real part
    o_HPol2(1) <= readoutData(2)(31 downto 16); -- 8 bit imaginary part
    o_VPol2(0) <= readoutData(2)(47 downto 32); -- 8 bit real part
    o_VPol2(1) <= readoutData(2)(63 downto 48); -- 8 bit imaginary part
    o_HPol3(0) <= readoutData(3)(15 downto 0);  -- 8 bit real part
    o_HPol3(1) <= readoutData(3)(31 downto 16); -- 8 bit imaginary part
    o_VPol3(0) <= readoutData(3)(47 downto 32); -- 8 bit real part
    o_VPol3(1) <= readoutData(3)(63 downto 48); -- 8 bit imaginary part    
    
end Behavioral;
