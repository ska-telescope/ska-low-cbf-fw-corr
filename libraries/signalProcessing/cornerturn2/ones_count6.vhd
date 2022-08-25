----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 24.01.2013 22:38:12
-- Module Name: ones_count6 - Behavioral
-- Description: 
--  Count the number of 1's in a 6 bit vector
-- 
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity ones_count6 is
   port (
      vec_i  : in  std_logic_vector(5 downto 0);
      ones_o : out std_logic_vector(2 downto 0)
   );
end ones_count6;

architecture Behavioral of ones_count6 is

begin

   with vec_i select
   ones_o <=
      "000" when "000000",
      "001" when "000001",
      "001" when "000010",
      "010" when "000011",
      "001" when "000100",
      "010" when "000101",
      "010" when "000110",
      "011" when "000111",
      "001" when "001000",
      "010" when "001001",
      "010" when "001010",
      "011" when "001011",
      "010" when "001100",
      "011" when "001101",
      "011" when "001110",
      "100" when "001111",
      "001" when "010000",
      "010" when "010001",
      "010" when "010010",
      "011" when "010011",
      "010" when "010100",
      "011" when "010101",
      "011" when "010110",
      "100" when "010111",
      "010" when "011000",
      "011" when "011001",
      "011" when "011010",
      "100" when "011011",
      "011" when "011100",
      "100" when "011101",
      "100" when "011110",
      "101" when "011111",
      "001" when "100000",
      "010" when "100001",
      "010" when "100010",
      "011" when "100011",
      "010" when "100100",
      "011" when "100101",
      "011" when "100110",
      "100" when "100111",
      "010" when "101000",
      "011" when "101001",
      "011" when "101010",
      "100" when "101011",
      "011" when "101100",
      "100" when "101101",
      "100" when "101110",
      "101" when "101111",
      "010" when "110000",
      "011" when "110001",
      "011" when "110010",
      "100" when "110011",
      "011" when "110100",
      "100" when "110101",
      "100" when "110110",
      "101" when "110111",
      "011" when "111000",
      "100" when "111001",
      "100" when "111010",
      "101" when "111011",
      "100" when "111100",
      "101" when "111101",
      "101" when "111110",
      "110" when others;


end Behavioral;
