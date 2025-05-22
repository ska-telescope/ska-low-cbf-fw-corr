----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 08/17/2022 02:52:53 PM
-- Module Name: inv_rom_top - Behavioral
-- Description: 
--   rom to look up the inverse for an integer input.
--   Output is a single precision floating point value.
--   The roms are written by python script "create_inv_roms.py"
--
-- For standard visibilites and narrower zooms, the input value will be <= 4608
-- For these values, the result is exact to FP32 precision
-- For values above 4608, the input is scaled down by a power of 2 so that it is 
-- in the range 2048 to 4095
-- If there is no RFI, then the input value will be a multiple of 64, as there are 
-- 64 or 192 time samples per integration. So the inverse returned will be exact (to FP32 precision) 
-- for the no-RFI case. If there is RFI, then the fraction of data (FD) meta data is only 
-- an 8 bit value anyway, so a small loss of precision in this inverse is ok. 
----------------------------------------------------------------------------------
library IEEE, correlator_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity inv_rom_top is
    port(
        i_clk : in std_logic;
        i_din : in std_logic_vector(15 downto 0); -- Integer values in the range 0 to 24384
        -- inverse of i_din, as a single precision floating point value, 3 clock latency. 
        -- Divide by 0 gives an output of 0. (not NaN or Inf). 
        o_dout : out std_logic_vector(31 downto 0);
        -- Amount to adjust the exponent in the FP32 value by.
        -- This is here to allow the adjust to occur after the next register stage to aid timing.
        -- This can only be non-zero when i_din > 4608
        o_exp_adjust : out std_logic_vector(3 downto 0) -- Amount to subtract from the exponent in o_dout
    );
end inv_rom_top;

architecture Behavioral of inv_rom_top is

    signal rom0_dout, rom1_dout, rom2_dout, rom3_dout, rom4_dout, rom5_dout, rom6_dout, rom7_dout, rom8_dout : std_logic_vector(31 downto 0);
    signal dinDel1 : std_logic_vector(15 downto 0);
    signal rom_select_del1, rom_select_del2 : std_logic_vector(3 downto 0);
    signal lookup_addr : std_logic_vector(8 downto 0);
    signal use_unshifted, use_unshifted_del1 : std_logic;
    signal din_shifted : std_logic_vector(10 downto 0);
    signal shifted_select : std_logic_vector(1 downto 0);
    signal exp_adjust : std_logic_vector(3 downto 0);
    
begin
    
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            dinDel1 <= i_din;
            use_unshifted_del1 <= use_unshifted;
            shifted_select <= din_shifted(10 downto 9);
            
            if use_unshifted_del1 = '1' then
                rom_select_del2 <= dinDel1(12 downto 9);
                exp_adjust <= "0000";
            else
                rom_select_del2 <= "01" & shifted_select;
                -- amount to adjust the exponent in the resulting floating point value by.
                -- Example : If the actual value we are calculating the inverse of is 10000
                -- then we use the lookup table on 10000/4 = 2500
                -- So the value in o_dout = 1/2500 = 0.0004, but the true value is 0.0001
                -- So we have to subtract log2(4) = 2 from the exponent in o_dout to get the correct value.
                if dinDel1(14 downto 12) = "001" then
                    exp_adjust <= "0001";
                elsif dinDel1(14 downto 13) = "01" then
                    exp_adjust <= "0010";
                else
                    exp_adjust <= "0011";
                end if;
            end if;
            
            case rom_select_del2 is
                when "0000" => o_dout <= rom0_dout;
                when "0001" => o_dout <= rom1_dout;
                when "0010" => o_dout <= rom2_dout;
                when "0011" => o_dout <= rom3_dout;
                when "0100" => o_dout <= rom4_dout;  --\ 
                when "0101" => o_dout <= rom5_dout;  -- |
                when "0110" => o_dout <= rom6_dout;  -- |-- if input > 4608, it is shifted such that only these cases are used.
                when "0111" => o_dout <= rom7_dout;  --/
                when "1000" => o_dout <= rom8_dout;  
                when others => o_dout <= x"39638e39";  -- 1/4608, largest possible value for a standard visibility (24 * 192 = 4608)
            end case;
            o_exp_adjust <= exp_adjust;
            
        end if;
    end process;
    
    -- Shift to fit in the range 2048 to 4095
    -- 4096 = x1000,
    -- 4608 = 0x1200,  bits 14:9 = 001001
    -- 8192 = 0x2000, 
    -- 16384 = 0x4000,
    -- Assumes top bit is '0', i.e. i_din < 32768
    use_unshifted <= '1' when unsigned(i_din) <= 4608 else '0';
    din_shifted <= 
        i_din(11 downto 1) when i_din(14 downto 12) = "001" else  -- 4096 to 8191
        i_din(12 downto 2) when i_din(14 downto 13) = "01" else -- 8192 to 16383
        i_din(13 downto 3); -- 16384 to 32767
    
    lookup_addr <= i_din(8 downto 0) when use_unshifted = '1' else din_shifted(8 downto 0);
    
    -- roms have 2 clock latency.
    rom0i : entity correlator_lib.inv_rom0
    port map (
        i_clk  => i_clk,       -- in  std_logic; 
        i_addr => lookup_addr, -- in  (8:0); 
        o_data => rom0_dout    -- out (31:0) 
    );
    rom1i : entity correlator_lib.inv_rom1
    port map (
        i_clk  => i_clk,        -- in std_logic; 
        i_addr => lookup_addr,  -- in (8:0); 
        o_data => rom1_dout     -- out(31:0)
    );
    rom2i : entity correlator_lib.inv_rom2
    port map (
        i_clk  => i_clk,        -- in  std_logic; 
        i_addr => lookup_addr,  -- in (8:0); 
        o_data => rom2_dout     -- out (31:0) 
    );
    rom3i : entity correlator_lib.inv_rom3
    port map (
        i_clk  => i_clk,        -- in std_logic; 
        i_addr => lookup_addr,  -- in (8:0); 
        o_data => rom3_dout     -- out (31:0) 
    );
    rom4i : entity correlator_lib.inv_rom4
    port map (
        i_clk  => i_clk,        -- in  std_logic; 
        i_addr => lookup_addr,  -- in (8:0); 
        o_data => rom4_dout     -- out (31:0) 
    );
    rom5i : entity correlator_lib.inv_rom5
    port map (
        i_clk  => i_clk,        -- in std_logic; 
        i_addr => lookup_addr,  -- in (8:0); 
        o_data => rom5_dout     -- out (31:0) 
    );
    rom6i : entity correlator_lib.inv_rom6
    port map (
        i_clk  => i_clk,        -- in std_logic; 
        i_addr => lookup_addr,  -- in (8:0); 
        o_data => rom6_dout     -- out (31:0) 
    );
    rom7i : entity correlator_lib.inv_rom7
    port map (
        i_clk  => i_clk,        -- in std_logic; 
        i_addr => lookup_addr,  -- in (8:0); 
        o_data => rom7_dout     -- out (31:0) 
    );
    rom8i : entity correlator_lib.inv_rom8
    port map (
        i_clk  => i_clk,        -- in std_logic; 
        i_addr => lookup_addr,  -- in (8:0); 
        o_data => rom8_dout     -- out (31:0) 
    );
    
end Behavioral;
