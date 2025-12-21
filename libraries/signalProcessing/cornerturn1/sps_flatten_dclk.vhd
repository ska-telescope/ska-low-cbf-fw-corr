----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 12/18/2025 09:42:50 PM
-- Module Name: sps_flatten_dclk - Behavioral
-- Description: 
--   derippling filter, with DSPs running at double the clock speed to reduce DSP usage.
-- Comparison :
--   Xilinx IP DSP filter : 794 FF, 458 LUTs (59 Logic, 399 Memory), 25 DSPs
--
----------------------------------------------------------------------------------
library IEEE, common_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use common_lib.common_pkg.ALL;

entity sps_flatten_dclk is
    Port (
        aclk    : in std_logic;
        aclk_x2 : in std_logic; -- synchronous clock at double the speed of aclk
        s_axis_data_tvalid : in std_logic;
        s_axis_data_tdata  : in std_logic_vector(7 downto 0); --
        s_axis_data_tuser  : in std_logic_vector(0 downto 0); -- 
        --
        s_axis_config_tdata : in std_logic_vector(1 downto 0); -- 3 filters available
        --
        m_axis_data_tvalid : out std_logic; --
        m_axis_data_tdata  : out std_logic_vector(15 downto 0); --
        m_axis_data_tuser  : out std_logic
    );
end sps_flatten_dclk;

architecture Behavioral of sps_flatten_dclk is

    -- constants to hold half the filter + the central value
    -- Filters are assumed to be symmetric
    type ftap_t is array(24 downto 0) of integer;
    constant ftaps0 : ftap_t := (0,  0,  0,   0,  0,   0,   0,   0,  0,    0,    0,    0,    0,    0,   0,     0,    0,     0,    0,     0,    0,     0,    0,     0, 65536);
    constant ftaps1 : ftap_t := (3, -6, 10, -16, 24, -34,  46, -61, 98, -128,  173, -229,  300, -387, 488,  -621, 1881, -1705, 2110, -2498, 2861, -3172, 3411, -3562, 69172);
    constant ftaps2 : ftap_t := (1, -2,  4,  -7, 12, -21,  36, -51, 78, -111,  155, -213,  284, -362, 652, -1263, 1209, -1653, 1944, -2288, 2583, -2843, 3040, -3165, 68751);
    -- 10 DSP total :           | 1 DSP                  |1 DSP       |1 DSP      |1 DSP      |1 DSP     |1 DSP       |1 DSP       |1 DSP       |1 DSP       |1 DSP        |
    --                          | double rate            |single rate |double rate|
    --                          | use 8x9bit dot product |dot product |           |
    signal ftap : t_slv_18_arr(24 downto 0);
    
    
    signal delay_line : t_slv_8_arr(48 downto 0);
    signal dsum, dsum_reg : t_slv_9_arr(24 downto 0);
    
    signal toggle_aclk : std_logic := '0';
    signal toggle_del_aclk_x2 : std_logic := '0';
    signal aclk_n : std_logic;
    
    signal dsp0_data8, dsp1_data8 : std_logic_vector(23 downto 0);
    signal dsp0_data9, dsp1_data9 : std_logic_vector(26 downto 0);
    signal dsp0_dot_product_final, dsp0_dot_product_del1 : std_logic_vector(19 downto 0);
    signal dsp0_dot_product, dsp1_dot_product : std_logic_vector(23 downto 0);
    
    --create_ip -name dsp_macro -vendor xilinx.com -library ip -version 1.0 -module_name dsp_macro_B_x_ApD_pPCIN
    --set_property -dict [list \
    --  CONFIG.a_binarywidth {0} \
    --  CONFIG.a_width {8} \
    --  CONFIG.areg_3 {true} \
    --  CONFIG.areg_4 {true} \
    --  CONFIG.b_binarywidth {0} \
    --  CONFIG.b_width {18} \
    --  CONFIG.breg_3 {true} \
    --  CONFIG.breg_4 {true} \
    --  CONFIG.c_binarywidth {0} \
    --  CONFIG.c_width {48} \
    --  CONFIG.concat_binarywidth {0} \
    --  CONFIG.concat_width {48} \
    --  CONFIG.creg_3 {false} \
    --  CONFIG.creg_4 {false} \
    --  CONFIG.creg_5 {false} \
    --  CONFIG.d_binarywidth {0} \
    --  CONFIG.d_width {8} \
    --  CONFIG.dreg_3 {true} \
    --  CONFIG.has_pcout {true} \
    --  CONFIG.instruction1 {B*(A+D)+PCIN} \
    --  CONFIG.mreg_5 {true} \
    --  CONFIG.p_binarywidth {0} \
    --  CONFIG.p_full_width {58} \
    --  CONFIG.p_width {58} \
    --  CONFIG.pcin_binarywidth {0} \
    --  CONFIG.preg_6 {true} \
    --] [get_ips dsp_macro_B_x_ApD_pPCIN]
    --generate_target {instantiation_template} [get_files /home/hum089/projects/perentie/corr_latest/ska-low-cbf-fw-corr/build/v80/v80_top.srcs/sources_1/ip/dsp_macro_B_x_ApD_pPCIN/dsp_macro_B_x_ApD_pPCIN.xci]
    component dsp_macro_B_x_ApD_pPCIN
    port (
        CLK   : IN STD_LOGIC;
        PCIN  : IN STD_LOGIC_VECTOR(57 DOWNTO 0);
        A     : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        B     : IN STD_LOGIC_VECTOR(17 DOWNTO 0);
        D     : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        PCOUT : OUT STD_LOGIC_VECTOR(57 DOWNTO 0);
        P     : OUT STD_LOGIC_VECTOR(57 DOWNTO 0));
    end component;
    
begin
    
    process(aclk)
    begin
        if rising_edge(aclk) then
            if s_axis_data_tvalid = '1' then
                delay_line(0) <= s_axis_data_tdata;
                delay_line(48 downto 1) <= delay_line(47 downto 0);
            end if;
            
            dsum_reg <= dsum;
            
            for i in 0 to 24 loop
                if s_axis_config_tdata = "00" then
                    ftap(i) <= std_logic_vector(to_signed(ftaps0(i), 18));
                elsif s_axis_config_tdata = "01" then
                    ftap(i) <= std_logic_vector(to_signed(ftaps1(i), 18));
                else
                    ftap(i) <= std_logic_vector(to_signed(ftaps2(i), 18));
                end if;
            end loop;
        end if;
    end process;

    -- symmetric filter, add values on opposite sides of the center
    dsum_gen : for i in 0 to 23 generate
        dsum(i) <= std_logic_vector(resize(signed(delay_line(i)),9) + resize(signed(delay_line(48-i)),9));
    end generate;
    dsum(24) <= std_logic_vector(resize(signed(delay_line(24)),9)); -- center value
    
    --------------------------------------------------------------------------------
    -- DSPs
    -- First DSP, double rate dot product for the first 6 coefficients
    dsp0_data8(7 downto 0) <= ftap(24)(7 downto 0) when aclk_n = '0' else ftap(21)(7 downto 0);
    dsp0_data8(15 downto 8) <= ftap(23)(7 downto 0) when aclk_n = '0' else ftap(20)(7 downto 0);
    dsp0_data8(23 downto 16) <= ftap(22)(7 downto 0) when aclk_n = '0' else ftap(19)(7 downto 0);
    
    dsp0_data9(8 downto 0) <= dsum(0) when aclk_n = '0' else dsum(3);
    dsp0_data9(17 downto 9) <= dsum(1) when aclk_n = '0' else dsum(4);
    dsp0_data9(26 downto 18) <= dsum(2) when aclk_n = '0' else dsum(5);
    
    dp0i : entity work.dsp_dotproduct
    port map (
        clk     => aclk_x2, -- : in std_logic;
        i_data8 => dsp0_data8, -- : in std_logic_vector(23 downto 0); -- 3 x 8 bit signed values
        i_data9 => dsp0_data9, -- : in std_logic_vector(26 downto 0); -- 3 x 9 bit signed values
        i_accumulate => aclk_n, -- in std_logic;  -- high to add to the previous dotproduct result, otherwise clear the previous result
        o_dotproduct => dsp0_dot_product -- out std_logic_vector(23 downto 0) -- Accumulated dot product
    );
    
    process(aclk_x2)
    begin
        if rising_edge(aclk_x2) then
            dsp0_dot_product_del1 <= dsp0_dot_product(19 downto 0);
        end if;
    end process;
    
    process(aclk)
    begin
        if rising_edge(aclk) then
            -- extra register to align the output with the other single rate dot product DSP
            dsp0_dot_product_final <= dsp0_dot_product_del1;
        end if;
    end process;
    
    -- Second DSP, single rate dot product
    dsp1_data8(7 downto 0)  <= ftap(18)(7 downto 0);
    dsp1_data8(15 downto 8) <= ftap(17)(7 downto 0);
    dsp1_data8(23 downto 16) <= ftap(16)(7 downto 0);
    
    dsp1_data9(8 downto 0) <= dsum(6);
    dsp1_data9(17 downto 9) <= dsum(7);
    dsp1_data9(26 downto 18) <= dsum(8);
    
    dp1i : entity work.dsp_dotproduct
    port map (
        clk => aclk,
        i_data8 => dsp1_data8, -- in std_logic_vector(23 downto 0); -- 3 x 8 bit signed values
        i_data9 => dsp1_data9, -- in std_logic_vector(26 downto 0); -- 3 x 9 bit signed values
        i_accumulate => '0',   -- in std_logic; High to add to the previous dotproduct result, otherwise clear the previous result
        o_dotproduct => dsp1_dot_product -- out std_logic_vector(23 downto 0) -- Accumulated dot product
    );
    
    -- Remaining DSPs, double rate multipliers
    dspdri : for i in 0 to 7 generate
        
        
        
        
    end generate;
    
    
    
    
    
    
    
    
    
    ---------------------------------------------------------------------------
    -- Double rate operation for the DSPs
    process(aclk)
    begin
        if rising_edge(aclk) then
            toggle_aclk <= not toggle_aclk;
        end if;
    end process;
    
    process(aclk_x2)
    begin
        if rising_edge(aclk_x2) then
            toggle_del_aclk_x2 <= toggle_aclk;
            -- aclk_n is a signal with the inverted waveform of aclk
            aclk_n <= toggle_del_aclk_x2 xor toggle_aclk;
        end if;
    end process;
    
end Behavioral;
