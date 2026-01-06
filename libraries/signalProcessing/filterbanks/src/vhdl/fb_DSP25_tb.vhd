----------------------------------------------------------------------------------
-- Company:  CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 02/04/2025 01:56:24 PM
-- Design Name: 
-- Module Name: flatten_tb - Behavioral
-- Description: 
--  test double clock rate versal implementation of the filterbank FIR filter against the single rate clock version
-- 
----------------------------------------------------------------------------------

library IEEE, common_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use common_lib.common_pkg.all;

entity fb_DSP25_tb is
end fb_DSP25_tb;

architecture Behavioral of fb_DSP25_tb is

    signal clk100in, clk100, clk200 : std_logic := '0';

    component fb_DSP25_versal
    port (
        clk     : in std_logic;
        clk_2x  : in std_logic;
        i_data0 : in t_slv_16_arr(11 downto 0);
        i_data1 : in t_slv_16_arr(11 downto 0);
        i_coef  : in t_slv_18_arr(11 downto 0);
        o_data0 : out std_logic_vector(24 downto 0);
        o_data1 : out std_logic_vector(24 downto 0));
    end component;

    component fb_DSP25
    port (
        clk : in std_logic;
        data_i : in t_slv_16_arr(11 downto 0);
        coef_i : in t_slv_18_arr(11 downto 0);
        data_o : out std_logic_vector(24 downto 0));
    end component;
    
    COMPONENT clk_test_dclk
    PORT (
        clk_in1 : IN STD_LOGIC;
        clk_out1 : OUT STD_LOGIC;
        clk_out2 : OUT STD_LOGIC);
    END COMPONENT;
    
    signal ccount : std_logic_vector(15 downto 0) := x"0000";
    signal dout0_versal, dout1_versal, dout0_singlerate, dout1_singlerate : std_logic_vector(24 downto 0);
    signal din0, din1 : t_slv_16_arr(11 downto 0);
    signal coef : t_slv_18_arr(11 downto 0);
    
begin
    
    clk100in <= not clk100in after 5 ns;
    
    clk100_200 : clk_test_dclk
    PORT MAP (
        clk_in1  => clk100in,
        clk_out1 => clk100,
        clk_out2 => clk200
    );
    
    process(clk100)
    begin
        if rising_Edge(clk100) then
            ccount <= std_logic_vector(unsigned(ccount) + 1);
            
            if unsigned(ccount) < 256 then
                din0 <= (others => (others => '0'));
                din1 <= (others => (others => '0'));
                coef <= (others => (others => '0'));
            else
                din0(0) <= ccount;
                din0(11 downto 1) <= din0(10 downto 0);
                
                din1(0) <= not ccount;
                din1(11 downto 1) <= din1(10 downto 0);
                
                coef(0) <= ccount(0) & ccount(1) & ccount(2) & ccount(3) & ccount(4) & ccount(5) & ccount(6) & ccount(7) & ccount(8) & ccount(9) & ccount(10) & ccount(11) & ccount(12) & ccount(13) & ccount(14) & ccount(15) & "00";
                coef(11 downto 1) <= coef(10 downto 0);
            end if;
            
        end if;
    end process;
    
    dsp25_versali : fb_DSP25_versal
    port map (
        clk     => clk100, -- in std_logic;
        clk_2x  => clk200, -- in std_logic;
        i_data0 => din0, -- in t_slv_16_arr(11 downto 0);
        i_data1 => din1, -- in t_slv_16_arr(11 downto 0);
        i_coef  => coef, -- in t_slv_18_arr(11 downto 0);
        o_data0 => dout0_versal, -- out std_logic_vector(24 downto 0);
        o_data1 => dout1_versal  -- out std_logic_vector(24 downto 0));
    );

    DSP25_singlerate0i : fb_DSP25
    port map (
        clk    => clk100, --  in std_logic;
        data_i => din0, -- in t_slv_16_arr((TAPS-1) downto 0);
        coef_i => coef, -- in t_slv_18_arr((TAPS-1) downto 0);
        data_o => dout0_singleRate --  out std_logic_vector(24 downto 0));
    );

    DSP25_singlerate1i : fb_DSP25
    port map (
        clk    => clk100, --  in std_logic;
        data_i => din1,   -- in t_slv_16_arr((TAPS-1) downto 0);
        coef_i => coef,   -- in t_slv_18_arr((TAPS-1) downto 0);
        data_o => dout1_singleRate --  out std_logic_vector(24 downto 0));
    );
    
    
end Behavioral;
