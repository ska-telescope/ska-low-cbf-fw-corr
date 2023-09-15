----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 08.08.2023 
-- Module Name: corr_div3 - Behavioral
-- Description: 
--   divide by 3, returning both integer and remainder part.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
Library xpm;
use xpm.vcomponents.all;

entity corr_div3 is
    port (
        i_clk  : in std_logic;
        -- Input
        i_din  : in std_logic_vector(40 downto 0); 
        i_valid : in std_logic;
        -- Output - XX clock latency
        o_quotient : out std_logic_vector(41 downto 0);
        o_remainder : out std_logic_vector(1 downto 0); 
        o_valid : out std_logic
    );
end corr_div3;

architecture Behavioral of corr_div3 is
    
    signal dividend, divisor, quotient : std_logic_vector(41 downto 0);
    signal divCount : std_logic_vector(3 downto 0);
    signal divRunning : std_logic;
    
    signal dtb : unsigned(5 downto 0);
    
    constant c_three : std_logic_vector(47 downto 0) := x"0C0000000000";
    constant c_six : std_logic_vector(47 downto 0) := x"180000000000";
    constant c_nine : std_logic_vector(47 downto 0) := x"900000000000";
    constant c_twelve : std_logic_vector(47 downto 0) := x"c00000000000";
    constant c_fifteen : std_logic_vector(47 downto 0) := x"f00000000000";
    
begin
    
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_valid = '1' then
                dividend <= '0' & i_din;
                
                divCount <= "1010";  -- 10 steps in the division.
                divRunning <= '1';
                quotient <= (others => '0');
                o_valid <= '0';
            elsif divRunning = '1' then
                
                -- dtb = dividend top bits; Select new top bits after subtracting off a multiple of 3, and shifting by 4 bits
                if (dtb=0  or dtb=3  or dtb=6  or dtb=9 or  dtb=12 or dtb=15 or dtb=18 or dtb=21 or dtb=24 or dtb=27 or dtb=30 or
                    dtb=33 or dtb=36 or dtb=39 or dtb=42 or dtb=45 or dtb=48 or dtb=51 or dtb=54 or dtb=57 or dtb=60 or dtb=63) then
                    dividend(41 downto 40) <= "00";
                elsif (dtb=1 or dtb=4  or dtb=7 or dtb=10 or dtb=13 or dtb=16 or dtb=19 or dtb=22 or dtb=25 or dtb=28 or dtb=31 or
                       dtb=34 or dtb=37 or dtb=40 or dtb=43 or dtb=46 or dtb=49 or dtb=52 or dtb=55 or dtb=58 or dtb=61) then
                    dividend(41 downto 40) <= "01";
                else
                    dividend(41 downto 40) <= "10";
                end if;
                dividend(39 downto 4) <= dividend(35 downto 0);
                dividend(3 downto 0) <= "0000";
                
                if (dtb=0 or dtb=1 or dtb=2) then
                    quotient(3 downto 0) <= "0000";
                elsif (dtb=3 or dtb=4 or dtb=5) then
                    quotient(3 downto 0) <= "0001";
                elsif (dtb=6 or dtb=7 or dtb=8) then
                    quotient(3 downto 0) <= "0010";
                elsif (dtb=9 or dtb=10 or dtb=11) then
                    quotient(3 downto 0) <= "0011";
                elsif (dtb=12 or dtb=13 or dtb=14) then
                    quotient(3 downto 0) <= "0100";
                elsif (dtb=15 or dtb=16 or dtb=17) then
                    quotient(3 downto 0) <= "0101";
                elsif (dtb=18 or dtb=19 or dtb=20) then
                    quotient(3 downto 0) <= "0110";
                elsif (dtb=21 or dtb=22 or dtb=23) then
                    quotient(3 downto 0) <= "0111";
                elsif (dtb=24 or dtb=25 or dtb=26) then
                    quotient(3 downto 0) <= "1000";
                elsif (dtb=27 or dtb=28 or dtb=29) then
                    quotient(3 downto 0) <= "1001";
                elsif (dtb=30 or dtb=31 or dtb=32) then
                    quotient(3 downto 0) <= "1010";
                elsif (dtb=33 or dtb=34 or dtb=35) then
                    quotient(3 downto 0) <= "1011";                    
                elsif (dtb=36 or dtb=37 or dtb=38) then
                    quotient(3 downto 0) <= "1100";
                elsif (dtb=39 or dtb=40 or dtb=41) then
                    quotient(3 downto 0) <= "1101";
                elsif (dtb=42 or dtb=43 or dtb=44) then
                    quotient(3 downto 0) <= "1110";
                elsif (dtb=45 or dtb=46 or dtb=47) then
                    quotient(3 downto 0) <= "1111";
                end if;
                
                quotient(41 downto 4) <= quotient(37 downto 0);
                
                divCount <= std_logic_vector(unsigned(divCount) - 1);
                if (unsigned(divCount) = 0) then
                    divRunning <= '0';
                    o_valid <= '1';
                    o_quotient <= quotient;
                    o_remainder <= dividend(41 downto 40);
                else
                    o_valid <= '0';
                end if;
            else
                o_valid <= '0';
                o_quotient <= (others => '0');
                o_remainder <= (others => '0');
            end if;

        end if;
    end process;    
    
    dtb <= unsigned(dividend(41 downto 36));
    
    
end Behavioral;

