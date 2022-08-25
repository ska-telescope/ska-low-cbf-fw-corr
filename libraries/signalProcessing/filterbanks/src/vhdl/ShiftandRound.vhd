----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 15.01.2020 12:00:27
-- Module Name: ShiftandRound - Behavioral
-- Description: 
--  Takes a 35 bit value, shifts right by 0 to 31 bits, saturates and applies convergent rounding to get a 16 bit result.  
--  Three cycle latency.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ShiftandRound is
    Port(
        i_clk   : in std_logic;
        i_shift : in std_logic_vector(4 downto 0);
        i_data  : in std_logic_vector(34 downto 0);
        o_data16 : out std_logic_vector(15 downto 0);  -- 3 cycle latency
        o_data8  : out std_logic_vector(7 downto 0);   -- 4 cycle latency
        -- statistics on the amplitude of o_data8
        o_overflow : out std_logic;      -- 4 cycle latency, aligns with o_data8
        o_64_127   : out std_logic;      -- output is in the range 64 to 127
        o_32_63    : out std_logic;      -- output is in the range 32 to 64.
        o_16_31    : out std_logic;      -- output is in the range 16 to 32.
        o_0_15     : out std_logic       -- output is in the range 0 to 15
     );
end ShiftandRound;

architecture Behavioral of ShiftandRound is

    signal saturated : std_logic;
    signal lowZero : std_logic;
    signal shift43 : std_logic_vector(15 downto 0);
    signal scaled : std_logic_vector(15 downto 0);
    signal roundup : std_logic;
    signal rounded : std_logic_vector(15 downto 0);
    signal data8 : std_logic_vector(7 downto 0);
    signal signbitDel1, signbitDel2, saturatedDel2, saturatedDel3 : std_logic;

begin


    process(i_clk)
    begin
        if rising_edge(i_clk) then
            --------------------------------------------------------------------
            -- Scale by i_shift(4:3).
            if i_shift(4 downto 3) = "00" then 
                -- shift is 0 to 7, so the final shift will keep bits somewhere in the range (7:0) to (14:7)
                shift43 <= i_data(14 downto 0) & '0';  -- single low order bit is kept for rounding.
                if i_data(34 downto 14) = "000000000000000000000" or i_data(34 downto 14) = "111111111111111111111" then
                    saturated <= '0';
                else
                    saturated <= '1';
                end if;
                lowZero <= '1'; -- Discarded low order bits are all zero. (in this case there are no discarded bits).
                
            elsif i_shift(4 downto 3) = "01" then 
                -- shift is 8 to 15, so the final shift will keep bits somewhere in the range (15:8) to (22:15)
                shift43 <= i_data(22 downto 7);
                if i_data(34 downto 22) = "0000000000000" or i_data(34 downto 22) = "1111111111111" then
                    saturated <= '0';
                else
                    saturated <= '1';
                end if;
                if i_data(6 downto 0) = "0000000" then
                    lowZero <= '1';
                else
                    lowZero <= '0';
                end if;
                
            elsif i_shift(4 downto 3) = "10" then
                -- shift is 16 to 23, so the final shift will keep bits somewhere in the range (23:16) to (30:23)
                shift43 <= i_data(30 downto 15);
                if i_data(34 downto 30) = "00000" or i_data(34 downto 30) = "11111" then
                    saturated <= '0';
                else
                    saturated <= '1';
                end if;
                if i_data(14 downto 0) = "000000000000000" then
                    lowZero <= '1';
                else
                    lowZero <= '0';
                end if;
                
            else 
                -- shift is 24 to 32, so the final shift will keep bits somewhere in the range (31:24) to (34:31)
                -- Choose the bits and sign extend to 16 bits. 
                shift43 <= i_data(34) & i_data(34) & i_data(34) & i_data(34) & i_data(34 downto 23);
                saturated <= '0';
                if i_data(22 downto 0) = "00000000000000000000000" then
                    lowZero <= '1';
                else
                    lowZero <= '0';
                end if;
                
            end if;
            signbitDel1 <= i_data(34);
            
            ----------------------------------------------
            -- Scale by i_shift(2:0), and calculate the convergent rounding.
            if i_shift(2 downto 0) = "000" then
                scaled <= shift43(15) & shift43(15 downto 1);
                if (shift43(0) = '1' and (lowZero = '0' or (lowZero = '1' and shift43(1) = '1'))) then 
                    roundUp <= '1';
                else
                    roundUp <= '0';
                end if;
            elsif i_shift(2 downto 0) = "001" then
                scaled <= shift43(15) & shift43(15) & shift43(15 downto 2);
                if (shift43(1) = '1' and (lowZero = '0' or (lowZero = '1' and shift43(0) = '0' and shift43(2) = '1'))) then 
                    roundUp <= '1';
                else
                    roundUp <= '0';
                end if;                
            elsif i_shift(2 downto 0) = "010" then
                scaled <= shift43(15) & shift43(15) & shift43(15) & shift43(15 downto 3);
                if (shift43(2) = '1' and (lowZero = '0' or (lowZero = '1' and shift43(1 downto 0) = "00" and shift43(3) = '1'))) then 
                    roundUp <= '1';
                else
                    roundUp <= '0';
                end if;
            elsif i_shift(2 downto 0) = "011" then
                scaled <= shift43(15) & shift43(15) & shift43(15) & shift43(15) & shift43(15 downto 4);
                if (shift43(3) = '1' and (lowZero = '0' or (lowZero = '1' and shift43(2 downto 0) = "000" and shift43(4) = '1'))) then 
                    roundUp <= '1';
                else
                    roundUp <= '0';
                end if;
            elsif i_shift(2 downto 0) = "100" then
                scaled <= shift43(15) & shift43(15) & shift43(15) & shift43(15) & shift43(15) & shift43(15 downto 5);
                if (shift43(4) = '1' and (lowZero = '0' or (lowZero = '1' and shift43(3 downto 0) = "0000" and shift43(5) = '1'))) then 
                    roundUp <= '1';
                else
                    roundUp <= '0';
                end if;
            elsif i_shift(2 downto 0) = "101" then
                scaled <= shift43(15) & shift43(15) & shift43(15) & shift43(15) & shift43(15) & shift43(15) & shift43(15 downto 6);
                if (shift43(5) = '1' and (lowZero = '0' or (lowZero = '1' and shift43(4 downto 0) = "00000" and shift43(6) = '1'))) then 
                    roundUp <= '1';
                else
                    roundUp <= '0';
                end if;                
            elsif i_shift(2 downto 0) = "110" then
                scaled <= shift43(15) & shift43(15) & shift43(15) & shift43(15) & shift43(15) & shift43(15) & shift43(15) & shift43(15 downto 7);
                if (shift43(6) = '1' and (lowZero = '0' or (lowZero = '1' and shift43(5 downto 0) = "000000" and shift43(7) = '1'))) then 
                    roundUp <= '1';
                else
                    roundUp <= '0';
                end if;
            else -- i_shift(2 downto 0) = "111"
                scaled <= shift43(15) & shift43(15) & shift43(15) & shift43(15) & shift43(15) & shift43(15) & shift43(15) & shift43(15) & shift43(15 downto 8);
                if (shift43(7) = '1' and (lowZero = '0' or (lowZero = '1' and shift43(6 downto 0) = "0000000" and shift43(7) = '1'))) then 
                    roundUp <= '1';
                else
                    roundUp <= '0';
                end if;                
            end if;
            
            signbitDel2 <= signbitDel1;
            saturatedDel2 <= saturated;
            
            ----------------------------------------------------
            -- Apply convergent rounding
            -- "scaled" is in the range -16384 to 16383, so adding 1 cannot result in overflow.
            if saturatedDel2 = '1' or scaled = "0011111111111111" then
                if signbitDel2 = '1' then
                    rounded <= "1100000000000000";
                else
                    rounded <= "0011111111111111";
                end if;
                saturatedDel3 <= '1';
            else
                if roundUp = '1' then
                    rounded <= std_logic_vector(unsigned(scaled) + 1);
                else
                    rounded <= scaled;
                end if;
                saturatedDel3 <= '0';
            end if;
            
            ------------------------------------------------------
            -- take the result back to 8 bits, marking any overflows as 0x80
            if ((signed(rounded) > 127) or (signed(rounded) < -127) or saturatedDel3 = '1') then
                data8 <= "10000000";
                o_overflow <= '1';
                o_64_127 <= '0';
                o_32_63 <= '0';
                o_16_31 <= '0';
                o_0_15 <= '0';
            else
                data8 <= rounded(7 downto 0);
                o_overflow <= '0';
                if rounded(7 downto 6) = "01" or rounded(7 downto 6) = "10" then
                    o_64_127 <= '1';
                    o_32_63 <= '0';
                    o_16_31 <= '0';
                    o_0_15 <= '0';
                elsif rounded(7 downto 5) = "001" or rounded(7 downto 5) = "110" then
                    o_64_127 <= '0';
                    o_32_63 <= '1';
                    o_16_31 <= '0';
                    o_0_15 <= '0';
                elsif rounded(7 downto 4) = "0001" or rounded(7 downto 4) = "1110" then
                    o_64_127 <= '0';
                    o_32_63 <= '0';
                    o_16_31 <= '1';
                    o_0_15 <= '0';
                else
                    o_64_127 <= '0';
                    o_32_63 <= '0';
                    o_16_31 <= '0';
                    o_0_15 <= '1';
                end if;
            end if;
            
        end if;
    end process;

    o_data16 <= rounded;
    o_data8 <= data8;

end Behavioral;
