----------------------------------------------------------------------------------
-- Company: CSIRO 
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
--  Average weights for each group of 1024 samples in the correlator filterbank
--  Values are power relative to the power in the channel, 
--  and are scaled by 2^32, so that 0dB corresponds to 2^32.
--  The maximum value returned is 1171075, i.e. needs 21 bits.
--   
----------------------------------------------------------------------------------

library IEEE, dsp_top_lib, filterbanks_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use dsp_top_lib.dsp_top_pkg.all;
use filterbanks_lib.all;

entity RFI_weights is
    port (
        clk         : in std_logic;
        -- data and header in
        i_addr        : in  std_logic_vector(5 downto 0);
        o_RFI_weight  : out std_logic_vector(23 downto 0)
    );
end RFI_weights;

architecture Behavioral of RFI_weights is
    
begin
    
    process(clk)
    begin
        if rising_edge(clk) then
            case i_addr is
                when "000000" => o_RFI_weight <= "000000000000000000000001",
                when "000001" => o_RFI_weight <= "000000000000000000000001",
                when "000010" => o_RFI_weight <= "000000000000000000000001",
                when "000011" => o_RFI_weight <= "000000000000000000000001",
                when "000100" => o_RFI_weight <= "000000000000000000000001",
                when "000101" => o_RFI_weight <= "000000000000000000000001",
                when "000110" => o_RFI_weight <= "000000000000000000000001",
                when "000111" => o_RFI_weight <= "000000000000000000000111",
                when "001000" => o_RFI_weight <= "000000000000000000001011",
                when "001001" => o_RFI_weight <= "000000000000000000000100",
                when "001010" => o_RFI_weight <= "000000000000000001011011",
                when "001011" => o_RFI_weight <= "000000000000000100011110",
                when "001100" => o_RFI_weight <= "000000000000000010100110",
                when "001101" => o_RFI_weight <= "000000000000000011111010",
                when "001110" => o_RFI_weight <= "000000000000100011010110",
                when "001111" => o_RFI_weight <= "000000000000110111100001",
                when "010000" => o_RFI_weight <= "000000000000001100001001",
                when "010001" => o_RFI_weight <= "000000000001101100010011",
                when "010010" => o_RFI_weight <= "000000000110111001010001",
                when "010011" => o_RFI_weight <= "000000000101111100001000",
                when "010100" => o_RFI_weight <= "000000000010001011111101",
                when "010101" => o_RFI_weight <= "000000101011101011110100",
                when "010110" => o_RFI_weight <= "000010100011110011110110",
                when "010111" => o_RFI_weight <= "000100011101110101010100",
                when "011000" => o_RFI_weight <= "000100011101111010000011",
                when "011001" => o_RFI_weight <= "000010100011111100110101",
                when "011010" => o_RFI_weight <= "000000101011110001000000",
                when "011011" => o_RFI_weight <= "000000000010001100011110",
                when "011100" => o_RFI_weight <= "000000000101111011101110",
                when "011101" => o_RFI_weight <= "000000000110111001100010",
                when "011110" => o_RFI_weight <= "000000000001101100100011",
                when "011111" => o_RFI_weight <= "000000000000001100000111",
                when "100000" => o_RFI_weight <= "000000000000110111100000",
                when "100001" => o_RFI_weight <= "000000000000100011011001",
                when "100010" => o_RFI_weight <= "000000000000000011111011",
                when "100011" => o_RFI_weight <= "000000000000000010100101",
                when "100100" => o_RFI_weight <= "000000000000000100011110",
                when "100101" => o_RFI_weight <= "000000000000000001011100",
                when "100110" => o_RFI_weight <= "000000000000000000000100",
                when "100111" => o_RFI_weight <= "000000000000000000001011",
                when "101000" => o_RFI_weight <= "000000000000000000000111",
                when "101001" => o_RFI_weight <= "000000000000000000000001",
                when "101010" => o_RFI_weight <= "000000000000000000000001",
                when "101011" => o_RFI_weight <= "000000000000000000000001",
                when "101100" => o_RFI_weight <= "000000000000000000000001",
                when "101101" => o_RFI_weight <= "000000000000000000000001",
                when "101110" => o_RFI_weight <= "000000000000000000000001",
                when "101111" => o_RFI_weight <= "000000000000000000000001",
                when others   => o_RFI_weight <= "000000000000000000000000",
            end case;
            
        end if;
    end process;
    
end Behavioral;
