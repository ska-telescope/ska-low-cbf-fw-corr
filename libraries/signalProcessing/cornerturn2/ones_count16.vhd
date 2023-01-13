----------------------------------------------------------------------------------
-- Company:  CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 24.01.2013 22:32:37
-- Module Name: count_ones66 - Behavioral
-- Description: 
--  Count the number of ones in a 16 bit vector.
--  
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ones_count16 is
    port (
        clk : in std_logic;
        i_vec : in std_logic_vector(15 downto 0);
        o_ones_count : out std_logic_vector(5 downto 0)
    );
end ones_count16;

architecture Behavioral of ones_count16 is

    signal v3, one_count_ext0, one_count_ext1, one_count_ext2 : std_logic_vector(5 downto 0);
    signal one_count0, one_count1, one_count2 : std_logic_vector(2 downto 0);
    
begin
    
    process(clk)
    begin
        if rising_edge(clk) then
            o_ones_count <= std_logic_vector(unsigned(one_count_ext0) + unsigned(one_count_ext1) + unsigned(one_count_ext2));
        end if;
    end process;
    
    
    ones_count6_1 : entity work.ones_count6
    port map (
        vec_i  => i_vec(5 downto 0),
        ones_o => one_count0
    );
    one_count_ext0 <= "000" & one_count0;
    
    ones_count6_2 : entity work.ones_count6
    port map (
        vec_i  => i_vec(11 downto 6),
        ones_o => one_count1
    );
    one_count_ext1 <= "000" & one_count1;
    
    v3 <= "00" & i_vec(15 downto 12);
    ones_count6_3 : entity work.ones_count6
    port map (
        vec_i  => v3,
        ones_o => one_count2
    );
    one_count_ext2 <= "000" & one_count2;
    
    
end Behavioral;
