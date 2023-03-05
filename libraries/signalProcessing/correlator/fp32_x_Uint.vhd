----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 08/18/2022 11:36:22 AM
-- Module Name: fp32_x_Uint - Behavioral
-- Description: 
--  Multiply a single precision floating point value by an unsigned integer.
-- 
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity fp32_x_Uint is
    port(
        i_clk : in std_logic;
        i_fp32 : in std_logic_vector(31 downto 0);
        i_uint : in std_logic_vector(12 downto 0); -- unsigned integer value
        -- 
        o_fp32 : out std_logic_vector(31 downto 0) -- 4 cycle latency
    );
end fp32_x_Uint;

architecture Behavioral of fp32_x_Uint is

    signal sign_in, sign_del1, sign_del2, sign_del3, sign_out : std_logic;
    signal exp_in : std_logic_vector(7 downto 0);
    signal frac_in : std_logic_vector(24 downto 0);
    signal uint_in : std_logic_vector(13 downto 0);

    signal frac_x_uint : signed(38 downto 0);
    signal frac_x_uint_del1 : std_logic_vector(37 downto 0);

    signal shifted1 : std_logic_vector(26 downto 0);
    signal exp_step1 : std_logic_vector(3 downto 0);

    signal frac_out : std_logic_vector(22 downto 0);
    signal exp_del1, exp_del2, exp_del3, exp_out : std_logic_vector(7 downto 0);
    
begin

    sign_in <= i_fp32(31);
    exp_in <= i_fp32(30 downto 23);
    frac_in <= "01" & i_fp32(22 downto 0);
    uint_in <= '0' & i_uint;

    process(i_clk)
    begin
        if rising_edge(i_clk) then
            
            frac_x_uint <= signed(frac_in) * signed(uint_in);  
            exp_del1 <= exp_in;
            sign_del1 <= sign_in;
            
            frac_x_uint_del1 <= std_logic_vector(frac_x_uint(37 downto 0)); -- maximum possible value is 2^24 * 8191 = 38 bits
            exp_del2 <= exp_del1;
            sign_del2 <= sign_del1;
            
            -- find the shift required.
            -- frac_in had a 1 in bit 23, so we only need to search from there.
            if frac_x_uint_del1(37 downto 34) /= "0000" then
                exp_del3 <= std_logic_vector(unsigned(exp_del2) + 14); -- exponent needs to be increased by 14 if there is a '1' in frac_x_uint_del1(37)
                shifted1 <= frac_x_uint_del1(37 downto 11);
            elsif frac_x_uint_del1(33 downto 30) /= "0000" then
                exp_del3 <= std_logic_vector(unsigned(exp_del2) + 10);
                shifted1 <= frac_x_uint_del1(33 downto 7);
            elsif frac_x_uint_del1(29 downto 26) /= "0000" then
                exp_del3 <= std_logic_vector(unsigned(exp_del2) + 6);
                shifted1 <= frac_x_uint_del1(29 downto 3);
            else
                exp_del3 <= std_logic_vector(unsigned(exp_del2) + 2);
                shifted1 <= frac_x_uint_del1(25 downto 0) & '0';
            end if;
            sign_del3 <= sign_del2;
            
            --
            sign_out <= sign_del3;
            if shifted1(26) = '1' then
                exp_out <= exp_del3; 
                frac_out <= shifted1(25 downto 3);
            elsif shifted1(25) = '1' then
                exp_out <= std_logic_vector(unsigned(exp_del3) - 1);
                frac_out <= shifted1(24 downto 2);
            elsif shifted1(24) = '1' then
                exp_out <= std_logic_vector(unsigned(exp_del3) - 2);
                frac_out <= shifted1(23 downto 1);
            else
                exp_out <= std_logic_vector(unsigned(exp_del3) - 3);            
                frac_out <= shifted1(22 downto 0);
            end if;
            
        end if;    
    end process;

    o_fp32(31) <= sign_out;
    o_fp32(30 downto 23) <= exp_out;
    o_fp32(22 downto 0) <= frac_out;

end Behavioral;
