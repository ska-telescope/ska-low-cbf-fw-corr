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
-- -------------------------------------------------------------------------------
-- Pipelining :
--              
--  Delay line  | dsum_del1   |          Extra Delay
--  Index       | Index       | 0     | _del2 | 3     | 4     | 5     | 6     | 7     | 8     | 9     | 10    | 11            | 12            |
--                            |       |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |       |       |  <= double rate clock
--  --------------------------------------------------------------------------------------------------------------------------------------------  
--  0           | 0 (=0+48)   | DSP0                  |       |       |       |       |       |       |       |               |               |
--  1           | 1 (=1+47)   | DSP0                  |       |       |       |       |       |       |       |               |               |
--  2           | 2 (=2+46)   | DSP0                  |       |       |       |       |       |       |       |               |               |
--  3           | 3 (=3+45)   | DSP0                  |       |       |       |       |       |       |       |               |               |
--  4           | 4 (=4+44)   | DSP0                  |       |       |       |       |       |       |       |               |               |
--  5           | 5 (=5+43)   | DSP0 ------------------->\    |       |       |       |       |       |       |               |               |
--  6           | 6 (=6+42)   | DSP1                  |  |    |       |       |       |       |       |       |               |               |
--  7           | 7 (=7+41)   | DSP1                  |  |    |       |       |       |       |       |       |               |               |
--  8           | 8 (=8+40)   | DSP1 ------------------>-+---->DSP01_sum      |       |       |       |       |               |               |
--  9           | 9 (=9+39)   |       |       |       |       | DSP2  |       |       |       |       |       |               |               |
--  10          | 10 (=10+38) |       |       |       |       |   | DSP2  |   |       |       |       |       |               |               |
--  11          | 11 (=11+37) |       |       |       |       |   | DSP3  |   |       |       |       |       |               |               |
--  12          | 12 (=12+36) |       |       |       |       |       | DSP3  |       |       |       |       |               |               |
--  13          | 13 (=13+35) |       |       |       |       |       | DSP4  |       |       |       |       |               |               |
--  14          | 14 (=14+34) |       |       |       |       |       |   | DSP4  |   |       |       |       |               |               |
--  15          | 15 (=15+33) |       |       |       |       |       |   | DSP5  |   |       |       |       |               |               |
--  16          | 16 (=16+32) |       |       |       |       |       |       | DSP5  |       |       |       |               |               |
--  17          | 17 (=17+31) |       |       |       |       |       |       | DSP6  |       |       |       |               |               |
--  18          | 18 (=18+30) |       |       |       |       |       |       |   | DSP6  |   |       |       |               |               |
--  19          | 19 (=19+29) |       |       |       |       |       |       |   | DSP7  |   |       |       |               |               |
--  20          | 20 (=20+28) |       |       |       |       |       |       |       | DSP7  |       |       |               |               |
--  21          | 21 (=21+27) |       |       |       |       |       |       |       | DSP8  |       |       |               |               |
--  22          | 22 (=22+26) |       |       |       |       |       |       |       |   | DSP8  |   |   |   |               |               |
--  23          | 23 (=23+25) |       |       |       |       |       |       |       |   | DSP9 -------------->DSP9_hold0->\ |               |
--  24          | 24 (=24)    |       |       |       |       |       |       |       |       | DSP9 ---------->DSP9_hold1--+-> final_sum     |
--  25          |             |       |       |       |       |       |       |       |       |   |   |   |   |       |       |               |
--  26          |
--  ...
--  47          |
--  48          |
--  
--  
----------------------------------------------------------------------------------
library IEEE, common_lib, ct_lib;
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
        s_axis_config_tdata : in std_logic_vector(7 downto 0); -- 3 filters available
        --
        m_axis_data_tvalid : out std_logic; --
        m_axis_data_tdata  : out std_logic_vector(15 downto 0); --
        m_axis_data_tuser  : out std_logic_vector(0 downto 0) -- 
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
    --                          | NOTE: dot product DSPs can only use |
    --                          |       8-bit coefficients            |
    signal ftap : t_slv_18_arr(24 downto 0);
    
    signal delay_line : t_slv_8_arr(48 downto 0) := (others => (others => '0'));
    signal dsum, dsum_del1, dsum_del2, dsum_del3, dsum_del4, dsum_del5, dsum_del6, dsum_del7, dsum_del8, dsum_del9 : t_slv_9_arr(24 downto 0) := (others => (others => '0'));
    
    signal toggle_aclk : std_logic := '0';
    signal toggle_del_aclk_x2 : std_logic := '0';
    signal aclk_n : std_logic;
    signal dsp0_data8, dsp1_data8 : std_logic_vector(23 downto 0);
    signal dsp0_data9, dsp1_data9 : std_logic_vector(26 downto 0);
    signal dsp0_dot_product_final, dsp0_dot_product_del1 : std_logic_vector(23 downto 0);
    signal dsp0_dot_product, dsp1_dot_product, dsp01_sum : std_logic_vector(23 downto 0);
    signal dsp01_sum_sel : std_logic_vector(47 downto 0);
    signal pcout_dsp2, pcout_dsp3, pcout_dsp4, pcout_dsp5, pcout_dsp6, pcout_dsp7, pcout_dsp8 : std_logic_vector(57 downto 0);
    signal dsum_dsp2, dsum_dsp3, dsum_dsp4, dsum_dsp5, dsum_dsp6, dsum_dsp7, dsum_dsp8, dsum_dsp9 : std_logic_vector(8 downto 0);
    signal ftap_dsp2, ftap_dsp3, ftap_dsp4, ftap_dsp5, ftap_dsp6, ftap_dsp7, ftap_dsp8, ftap_dsp9 : std_logic_vector(17 downto 0);
    signal p_dsp9 : std_logic_vector(57 downto 0);
    signal dsp9_hold0, dsp9_hold0_adv, dsp9_hold1, final_sum : std_logic_vector(31 downto 0);
    signal s_axis_data_tvalid_del, s_axis_data_tuser_del : std_logic_vector(15 downto 0) := (others => '0');    
    signal final_sum_16bit : std_logic_vector(15 downto 0);
    signal m_axis_data_tdata_pre_delay : std_logic_vector(15 downto 0);
    signal m_axis_data_tvalid_pre_delay : std_logic;
    signal m_axis_data_tuser_pre_delay : std_logic;
    signal m_axis_data_tdata_delay : t_slv_16_arr(20 downto 0);
    signal m_axis_data_tvalid_delay, m_axis_data_tuser_delay : std_logic_vector(20 downto 0);
    
    -- 3 clock latency, result is A*B + C
    --create_ip -name dsp_macro -vendor xilinx.com -library ip -version 1.0 -module_name dsp_macro_AxB_plusC
    --set_property -dict [list \
    --  CONFIG.a_binarywidth {0} \
    --  CONFIG.a_width {9} \
    --  CONFIG.areg_3 {true} \
    --  CONFIG.areg_4 {false} \
    --  CONFIG.breg_3 {true} \
    --  CONFIG.breg_4 {false} \
    --  CONFIG.c_width {48} \
    --  CONFIG.creg_3 {true} \
    --  CONFIG.creg_4 {false} \
    --  CONFIG.creg_5 {true} \
    --  CONFIG.has_pcout {true} \
    --  CONFIG.mreg_5 {true} \
    --  CONFIG.p_full_width {49} \
    --  CONFIG.pipeline_options {Expert} \
    --  CONFIG.preg_6 {true} \
    --] [get_ips dsp_macro_AxB_plusC]
    component dsp_macro_AxB_plusC
    port (
        CLK   : IN STD_LOGIC;
        A     : IN STD_LOGIC_VECTOR(8 DOWNTO 0);
        B     : IN STD_LOGIC_VECTOR(17 DOWNTO 0);
        C     : IN STD_LOGIC_VECTOR(47 DOWNTO 0);
        PCOUT : OUT STD_LOGIC_VECTOR(57 DOWNTO 0);
        P     : OUT STD_LOGIC_VECTOR(48 DOWNTO 0));
    end component;
    
    -- 3 clock latency, result is A*B + PCIn
    --create_ip -name dsp_macro -vendor xilinx.com -library ip -version 1.0 -module_name dsp_macro_AxB_plusPCIn
    --set_property -dict [list \
    --  CONFIG.a_binarywidth {0} \
    --  CONFIG.a_width {9} \
    --  CONFIG.areg_3 {true} \
    --  CONFIG.areg_4 {false} \
    --  CONFIG.b_binarywidth {0} \
    --  CONFIG.b_width {18} \
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
    --  CONFIG.has_pcout {true} \
    --  CONFIG.instruction1 {A*B+PCIN} \
    --  CONFIG.mreg_5 {true} \
    --  CONFIG.p_binarywidth {0} \
    --  CONFIG.p_full_width {58} \
    --  CONFIG.p_width {58} \
    --  CONFIG.pcin_binarywidth {0} \
    --  CONFIG.pipeline_options {Expert} \
    --  CONFIG.preg_6 {true} \
    --] [get_ips dsp_macro_AxB_plusPCIn]
    component dsp_macro_AxB_plusPCIn
    port (
        CLK   : IN STD_LOGIC;
        PCIN  : IN STD_LOGIC_VECTOR(57 DOWNTO 0);
        A     : IN STD_LOGIC_VECTOR(8 DOWNTO 0);
        B     : IN STD_LOGIC_VECTOR(17 DOWNTO 0);
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
            
            dsum_del1 <= dsum;
            dsum_del2 <= dsum_del1;
            dsum_del3 <= dsum_del2;
            dsum_del4 <= dsum_del3;
            dsum_del5 <= dsum_del4;
            dsum_del6 <= dsum_del5;
            dsum_del7 <= dsum_del6;
            dsum_del8 <= dsum_del7;
            dsum_del9 <= dsum_del8;
            
            for i in 0 to 24 loop
                if s_axis_config_tdata(1 downto 0) = "00" then
                    ftap(i) <= std_logic_vector(to_signed(ftaps0(i), 18));
                elsif s_axis_config_tdata(1 downto 0) = "01" then
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
    dsum(24) <= std_logic_vector(resize(signed(delay_line(24)),9));
    
    --------------------------------------------------------------------------------
    -- DSPs
    -- First DSP, double rate dot product for the first 6 coefficients
    dsp0_data8(7 downto 0) <= ftap(24)(7 downto 0) when aclk_n = '0' else ftap(21)(7 downto 0);
    dsp0_data8(15 downto 8) <= ftap(23)(7 downto 0) when aclk_n = '0' else ftap(20)(7 downto 0);
    dsp0_data8(23 downto 16) <= ftap(22)(7 downto 0) when aclk_n = '0' else ftap(19)(7 downto 0);
    
    dsp0_data9(8 downto 0) <= dsum_del1(0) when aclk_n = '0' else dsum_del1(3);
    dsp0_data9(17 downto 9) <= dsum_del1(1) when aclk_n = '0' else dsum_del1(4);
    dsp0_data9(26 downto 18) <= dsum_del1(2) when aclk_n = '0' else dsum_del1(5);
    
    dsp0i : entity ct_lib.dsp_dotproduct
    port map (
        clk     => aclk_x2,     -- in std_logic;
        i_data8 => dsp0_data8,  -- in (23:0); 3 x 8 bit signed values
        i_data9 => dsp0_data9,  -- in (26:0); 3 x 9 bit signed values
        i_accumulate => aclk_n, -- in std_logic; High to add to the previous dotproduct result, otherwise clear the previous result
        o_dotproduct => dsp0_dot_product -- out (23:0); Accumulated dot product, 3 clock latency
    );
    
    process(aclk_x2)
    begin
        if rising_edge(aclk_x2) then
            dsp0_dot_product_del1 <= dsp0_dot_product(23 downto 0);
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
    
    dsp1_data9(8 downto 0) <= dsum_del1(6);
    dsp1_data9(17 downto 9) <= dsum_del1(7);
    dsp1_data9(26 downto 18) <= dsum_del1(8);
    
    dsp1i : entity ct_lib.dsp_dotproduct
    port map (
        clk => aclk,
        i_data8 => dsp1_data8, -- in (23:0); 3 x 8 bit signed values
        i_data9 => dsp1_data9, -- in (26:0); 3 x 9 bit signed values
        i_accumulate => '0',   -- in std_logic; High to add to the previous dotproduct result, otherwise clear the previous result
        o_dotproduct => dsp1_dot_product -- out (23:0); Accumulated dot product, 3 clock latency
    );
    
    process(aclk)
    begin
        if rising_edge(aclk) then
            -- Add the outputs of the two dot product DSPs
            dsp01_sum <= std_logic_vector(signed(dsp0_dot_product_final) + signed(dsp1_dot_product));
        end if;
    end process;    
    
    -- 
    dsum_dsp2 <= dsum_del5(9) when aclk_n = '0' else dsum_del5(10);
    ftap_dsp2 <= ftap(15) when aclk_n = '0' else ftap(14);
    dsp01_sum_sel <= std_logic_vector(resize(signed(dsp01_sum),48)) when aclk_n = '0' else (others => '0');
    dsp2i : dsp_macro_AxB_plusC
    port map (
        clk   => aclk_x2, -- in std_logic;
        A     => dsum_dsp2, -- in (8:0)
        B     => ftap_dsp2, -- in (17:0);
        C     => dsp01_sum_sel, -- in (47:0);
        PCOUT => pcout_dsp2, -- out (57:0);
        P     => open -- out (48:0)
    );
    
    dsum_dsp3 <= dsum_del5(11) when aclk_n = '1' else dsum_del6(12);
    ftap_dsp3 <= ftap(13) when aclk_n = '1' else ftap(12);
    dsp3i : dsp_macro_AxB_plusPCIn
    port map (
        clk   => aclk_x2,    -- in std_logic;
        PCIN  => pcout_dsp2, -- in (57:0);
        A     => dsum_dsp3,  -- in (8:0);
        B     => ftap_dsp3,  -- in (17:0);
        PCOUT => pcout_dsp3, -- out (57:0);
        P     => open  -- out (57:0)
    );
    
    dsum_dsp4 <= dsum_del6(13) when aclk_n = '0' else dsum_del6(14);
    ftap_dsp4 <= ftap(11) when aclk_n = '0' else ftap(10);
    dsp4i : dsp_macro_AxB_plusPCIn
    port map (
        clk   => aclk_x2,    -- in std_logic;
        PCIN  => pcout_dsp3, -- in (57:0);
        A     => dsum_dsp4,  -- in (8:0);
        B     => ftap_dsp4,  -- in (17:0);
        PCOUT => pcout_dsp4, -- out (57:0);
        P     => open  -- out (57:0)
    );

    dsum_dsp5 <= dsum_del6(15) when aclk_n = '1' else dsum_del7(16);
    ftap_dsp5 <= ftap(9) when aclk_n = '1' else ftap(8);
    dsp5i : dsp_macro_AxB_plusPCIn
    port map (
        clk   => aclk_x2,    -- in std_logic;
        PCIN  => pcout_dsp4, -- in (57:0);
        A     => dsum_dsp5,  -- in (8:0);
        B     => ftap_dsp5,  -- in (17:0);
        PCOUT => pcout_dsp5, -- out (57:0);
        P     => open  -- out (57:0)
    );

    dsum_dsp6 <= dsum_del7(17) when aclk_n = '0' else dsum_del7(18);
    ftap_dsp6 <= ftap(7) when aclk_n = '0' else ftap(6);
    dsp6i : dsp_macro_AxB_plusPCIn
    port map (
        clk   => aclk_x2,    -- in std_logic;
        PCIN  => pcout_dsp5, -- in (57:0);
        A     => dsum_dsp6,  -- in (8:0);
        B     => ftap_dsp6,  -- in (17:0);
        PCOUT => pcout_dsp6, -- out (57:0);
        P     => open  -- out (57:0)
    );
    
    dsum_dsp7 <= dsum_del7(19) when aclk_n = '1' else dsum_del8(20);
    ftap_dsp7 <= ftap(5) when aclk_n = '1' else ftap(4);
    dsp7i : dsp_macro_AxB_plusPCIn
    port map (
        clk   => aclk_x2,    -- in std_logic;
        PCIN  => pcout_dsp6, -- in (57:0);
        A     => dsum_dsp7,  -- in (8:0);
        B     => ftap_dsp7,  -- in (17:0);
        PCOUT => pcout_dsp7, -- out (57:0);
        P     => open  -- out (57:0)
    );    

    dsum_dsp8 <= dsum_del8(21) when aclk_n = '0' else dsum_del8(22);
    ftap_dsp8 <= ftap(3) when aclk_n = '0' else ftap(2);
    dsp8i : dsp_macro_AxB_plusPCIn
    port map (
        clk   => aclk_x2,    -- in std_logic;
        PCIN  => pcout_dsp7, -- in (57:0);
        A     => dsum_dsp8,  -- in (8:0);
        B     => ftap_dsp8,  -- in (17:0);
        PCOUT => pcout_dsp8, -- out (57:0);
        P     => open  -- out (57:0)
    );
    
    dsum_dsp9 <= dsum_del8(23) when aclk_n = '1' else dsum_del9(24);
    ftap_dsp9 <= ftap(1) when aclk_n = '1' else ftap(0);
    dsp9i : dsp_macro_AxB_plusPCIn
    port map (
        clk   => aclk_x2,    -- in std_logic;
        PCIN  => pcout_dsp8, -- in (57:0);
        A     => dsum_dsp9,  -- in (8:0);
        B     => ftap_dsp9,  -- in (17:0);
        PCOUT => open, -- out (57:0);
        P     => p_dsp9  -- out (57:0)
    );
    
    process(aclk_x2)
    begin
        if rising_edge(aclk_x2) then
            dsp9_hold0_adv <= p_dsp9(31 downto 0);
        end if;
    end process;
    
    process(aclk)
    begin
        if rising_edge(aclk) then
            dsp9_hold0 <= dsp9_hold0_adv;
            dsp9_hold1 <= p_dsp9(31 downto 0);
            
            final_sum <= std_logic_vector(signed(dsp9_hold0) + signed(dsp9_hold1));
            
            -- convergent round to even, scaling by 1/512
            if ((final_sum(8 downto 0) = "100000000" and final_sum(9) = '1') or 
                (final_sum(8) = '1' and final_sum(7 downto 0) /= "00000000")) then
                m_axis_data_tdata_pre_delay <= std_logic_vector(signed(final_sum_16bit) + 1);
            else
                m_axis_data_tdata_pre_delay <= final_sum_16bit;
            end if;
            
            s_axis_data_tvalid_del(0) <= s_axis_data_tvalid;
            s_axis_data_tuser_del(0) <= s_axis_data_tuser(0);
            
            s_axis_data_tvalid_del(15 downto 1) <= s_axis_data_tvalid_del(14 downto 0);
            s_axis_data_tuser_del(15 downto 1) <= s_axis_data_tuser_del(14 downto 0);
            
            m_axis_data_tvalid_pre_delay <= s_axis_data_tvalid_del(12);
            m_axis_data_tuser_pre_delay <= s_axis_data_tuser_del(12);
            
            -- Delay outputs by 22 clocks to match the latency of the equivalent Xilinx component
            m_axis_data_tdata_delay(0) <= m_axis_data_tdata_pre_delay;
            m_axis_data_tvalid_delay(0) <= m_axis_data_tvalid_pre_delay;
            m_axis_data_tuser_delay(0) <= m_axis_data_tuser_pre_delay;
           
            m_axis_data_tdata_delay(20 downto 1) <= m_axis_data_tdata_delay(19 downto 0);
            m_axis_data_tvalid_delay(20 downto 1) <= m_axis_data_tvalid_delay(19 downto 0);
            m_axis_data_tuser_delay(20 downto 1) <= m_axis_data_tuser_delay(19 downto 0);
            
            m_axis_data_tdata <= m_axis_data_tdata_delay(20);
            m_axis_data_tvalid <= m_axis_data_tvalid_delay(20);
            m_axis_data_tuser(0) <= m_axis_data_tuser_delay(20);
            
        end if;
    end process;
    
    final_sum_16bit <= final_sum(24 downto 9);
    
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
