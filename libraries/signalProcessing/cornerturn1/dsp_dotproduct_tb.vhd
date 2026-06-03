----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 12/19/2025 04:41:33 PM
-- Design Name: 
-- Module Name: dsp_dotproduct_tb - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity dsp_dotproduct_tb is
--  Port ( );
end dsp_dotproduct_tb;

architecture Behavioral of dsp_dotproduct_tb is

    signal i_clk : std_logic := '0';
    signal testcount : std_logic_vector(23 downto 0) := x"000000";
    signal data8 : std_logic_vector(23 downto 0);
    signal data9 : std_logic_vector(26 downto 0);
    signal accumulate : std_logic := '0';
    signal dot_product : std_logic_vector(23 downto 0);
    
begin
    
    i_clk <= not i_clk after 5ns;
    
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            testcount <= std_logic_vector(unsigned(testcount) + 1);
        end if;
    end process;
    
    accumulate <= testcount(3);
    data8(7 downto 0) <= testcount(7 downto 0);
    data8(15 downto 8) <= "11111111"; --  testcount(15 downto 8);
    data8(23 downto 16) <= testcount(15 downto 8);
    
    data9(8 downto 0) <= testcount(16 downto 8);
    data9(17 downto 9) <= testcount(16 downto 8);
    data9(26 downto 18) <= testcount(16 downto 8);
    
    dpi : entity work.dsp_dotproduct
    port map (
        clk     => i_clk, -- : in std_logic;
        i_data8 => data8, -- : in std_logic_vector(23 downto 0); -- 3 x 8 bit signed values
        i_data9 => data9, -- : in std_logic_vector(26 downto 0); -- 3 x 9 bit signed values
        i_accumulate => accumulate, -- : in std_logic;  -- high to add to the previous dotproduct result, otherwise clear the previous result
        o_dotproduct => dot_product --: out std_logic_vector(23 downto 0) -- Accumulated dot product
    );
    
end Behavioral;
