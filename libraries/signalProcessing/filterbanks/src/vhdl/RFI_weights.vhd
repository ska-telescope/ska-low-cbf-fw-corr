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
        i_addr        : in  std_logic_vector(6 downto 0);
        o_RFI_weight  : out std_logic_vector(21 downto 0)
    );
end RFI_weights;

architecture Behavioral of RFI_weights is
    
begin
    
    process(clk)
    begin
        if rising_edge(clk) then


            case i_addr is
                when "0000000" => o_RFI_weight <= "0000000000000000000001";
                when "0000001" => o_RFI_weight <= "0000000000000000000001";
                when "0000010" => o_RFI_weight <= "0000000000000000000001";
                when "0000011" => o_RFI_weight <= "0000000000000000000001";
                when "0000100" => o_RFI_weight <= "0000000000000000000001";
                when "0000101" => o_RFI_weight <= "0000000000000000000001";
                when "0000110" => o_RFI_weight <= "0000000000000000000001";
                when "0000111" => o_RFI_weight <= "0000000000000000000001";
                when "0001000" => o_RFI_weight <= "0000000000000000000001";
                when "0001001" => o_RFI_weight <= "0000000000000000000001";
                when "0001010" => o_RFI_weight <= "0000000000000000000001";
                when "0001011" => o_RFI_weight <= "0000000000000000000001";
                when "0001100" => o_RFI_weight <= "0000000000000000000001";
                when "0001101" => o_RFI_weight <= "0000000000000000000010";
                when "0001110" => o_RFI_weight <= "0000000000000000000101";
                when "0001111" => o_RFI_weight <= "0000000000000000001001";
                when "0010000" => o_RFI_weight <= "0000000000000000001100";
                when "0010001" => o_RFI_weight <= "0000000000000000001010";
                when "0010010" => o_RFI_weight <= "0000000000000000000011";
                when "0010011" => o_RFI_weight <= "0000000000000000000110";
                when "0010100" => o_RFI_weight <= "0000000000000000101110";
                when "0010101" => o_RFI_weight <= "0000000000000010001001";
                when "0010110" => o_RFI_weight <= "0000000000000011111110";
                when "0010111" => o_RFI_weight <= "0000000000000100111110";
                when "0011000" => o_RFI_weight <= "0000000000000011111010";
                when "0011001" => o_RFI_weight <= "0000000000000001010001";
                when "0011010" => o_RFI_weight <= "0000000000000000100100";
                when "0011011" => o_RFI_weight <= "0000000000000111010000";
                when "0011100" => o_RFI_weight <= "0000000000011000001111";
                when "0011101" => o_RFI_weight <= "0000000000101110011101";
                when "0011110" => o_RFI_weight <= "0000000000111100000001";
                when "0011111" => o_RFI_weight <= "0000000000110011000000";
                when "0100000" => o_RFI_weight <= "0000000000010101101111";
                when "0100001" => o_RFI_weight <= "0000000000000010100011";
                when "0100010" => o_RFI_weight <= "0000000000101010100111";
                when "0100011" => o_RFI_weight <= "0000000010101110000000";
                when "0100100" => o_RFI_weight <= "0000000101101110111001";
                when "0100101" => o_RFI_weight <= "0000001000000011101001";
                when "0100110" => o_RFI_weight <= "0000000111101100100001";
                when "0100111" => o_RFI_weight <= "0000000100001011110000";
                when "0101000" => o_RFI_weight <= "0000000000100011000011";
                when "0101001" => o_RFI_weight <= "0000000011110100110111";
                when "0101010" => o_RFI_weight <= "0000010110111110001111";
                when "0101011" => o_RFI_weight <= "0001000000011001011010";
                when "0101100" => o_RFI_weight <= "0001111111001000010110";
                when "0101101" => o_RFI_weight <= "0011001000011111010111";
                when "0101110" => o_RFI_weight <= "0100001010010011000111";
                when "0101111" => o_RFI_weight <= "0100110001010111100000";
                when "0110000" => o_RFI_weight <= "0100110001011010000101";
                when "0110001" => o_RFI_weight <= "0100001010011010000001";
                when "0110010" => o_RFI_weight <= "0011001000101000011111";
                when "0110011" => o_RFI_weight <= "0001111111010001001011";
                when "0110100" => o_RFI_weight <= "0001000000100000000010";
                when "0110101" => o_RFI_weight <= "0000010111000001111101";
                when "0110110" => o_RFI_weight <= "0000000011110110000101";
                when "0110111" => o_RFI_weight <= "0000000000100010110110";
                when "0111000" => o_RFI_weight <= "0000000100001011001100";
                when "0111001" => o_RFI_weight <= "0000000111101100010000";
                when "0111010" => o_RFI_weight <= "0000001000000011110011";
                when "0111011" => o_RFI_weight <= "0000000101101111010001";
                when "0111100" => o_RFI_weight <= "0000000010101110010101";
                when "0111101" => o_RFI_weight <= "0000000000101010110010";
                when "0111110" => o_RFI_weight <= "0000000000000010100011";
                when "0111111" => o_RFI_weight <= "0000000000010101101011";
                when "1000000" => o_RFI_weight <= "0000000000110010111101";
                when "1000001" => o_RFI_weight <= "0000000000111100000010";
                when "1000010" => o_RFI_weight <= "0000000000101110100000";
                when "1000011" => o_RFI_weight <= "0000000000011000010010";
                when "1000100" => o_RFI_weight <= "0000000000000111010001";
                when "1000101" => o_RFI_weight <= "0000000000000000100100";
                when "1000110" => o_RFI_weight <= "0000000000000001010001";
                when "1000111" => o_RFI_weight <= "0000000000000011111010";
                when "1001000" => o_RFI_weight <= "0000000000000100111110";
                when "1001001" => o_RFI_weight <= "0000000000000011111110";
                when "1001010" => o_RFI_weight <= "0000000000000010001001";
                when "1001011" => o_RFI_weight <= "0000000000000000101110";
                when "1001100" => o_RFI_weight <= "0000000000000000000110";
                when "1001101" => o_RFI_weight <= "0000000000000000000010";
                when "1001110" => o_RFI_weight <= "0000000000000000001010";
                when "1001111" => o_RFI_weight <= "0000000000000000001100";
                when "1010000" => o_RFI_weight <= "0000000000000000001001";
                when "1010001" => o_RFI_weight <= "0000000000000000000101";
                when "1010010" => o_RFI_weight <= "0000000000000000000010";
                when "1010011" => o_RFI_weight <= "0000000000000000000001";
                when "1010100" => o_RFI_weight <= "0000000000000000000001";
                when "1010101" => o_RFI_weight <= "0000000000000000000001";
                when "1010110" => o_RFI_weight <= "0000000000000000000001";
                when "1010111" => o_RFI_weight <= "0000000000000000000001";
                when "1011000" => o_RFI_weight <= "0000000000000000000001";
                when "1011001" => o_RFI_weight <= "0000000000000000000001";
                when "1011010" => o_RFI_weight <= "0000000000000000000001";
                when "1011011" => o_RFI_weight <= "0000000000000000000001";
                when "1011100" => o_RFI_weight <= "0000000000000000000001";
                when "1011101" => o_RFI_weight <= "0000000000000000000001";
                when "1011110" => o_RFI_weight <= "0000000000000000000001";
                when "1011111" => o_RFI_weight <= "0000000000000000000001";
                when others    => o_RFI_weight <= "0000000000000000000000";
            end case;
            
        end if;
    end process;
    
end Behavioral;
