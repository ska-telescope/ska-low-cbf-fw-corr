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
----------------------------------------------------------------------------------
library IEEE, correlator_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity inv_rom_top is
    port(
        i_clk : in std_logic;
        i_din : in std_logic_vector(12 downto 0); -- Integer values in the range 0 to 4608
        -- inverse of i_din, as a single precision floating point value, 3 clock latency. 
        -- Divide by 0 gives an output of 0. (not NaN or Inf). 
        o_dout : out std_logic_vector(31 downto 0) 
    );
end inv_rom_top;

architecture Behavioral of inv_rom_top is

    signal rom0_dout, rom1_dout, rom2_dout, rom3_dout, rom4_dout, rom5_dout, rom6_dout, rom7_dout, rom8_dout : std_logic_vector(31 downto 0);
    signal dinDel1, dinDel2 : std_logic_vector(12 downto 0);
    
begin
    
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            dinDel1 <= i_din;
            dinDel2 <= dinDel1;
            case dinDel2(12 downto 9) is
                when "0000" => o_dout <= rom0_dout;
                when "0001" => o_dout <= rom1_dout;
                when "0010" => o_dout <= rom2_dout;
                when "0011" => o_dout <= rom3_dout;
                when "0100" => o_dout <= rom4_dout;
                when "0101" => o_dout <= rom5_dout;
                when "0110" => o_dout <= rom6_dout;
                when "0111" => o_dout <= rom7_dout;
                when "1000" => o_dout <= rom8_dout;
                when others => o_dout <= x"39638e39";  -- 1/4608
            end case;
            
        end if;
    end process;
    
    -- roms have 2 clock latency.
    rom0i : entity correlator_lib.inv_rom0
    port map (
        i_clk  => i_clk,             --  in  std_logic; 
        i_addr => i_din(8 downto 0), --  in  std_logic_vector(8 downto 0); 
        o_data => rom0_dout          --  out std_logic_vector(31 downto 0) 
    );
    rom1i : entity correlator_lib.inv_rom1
    port map (
        i_clk  => i_clk,             --  in  std_logic; 
        i_addr => i_din(8 downto 0), --  in  std_logic_vector(8 downto 0); 
        o_data => rom1_dout          --  out std_logic_vector(31 downto 0) 
    );
    rom2i : entity correlator_lib.inv_rom2
    port map (
        i_clk  => i_clk,             --  in  std_logic; 
        i_addr => i_din(8 downto 0), --  in  std_logic_vector(8 downto 0); 
        o_data => rom2_dout          --  out std_logic_vector(31 downto 0) 
    );
    rom3i : entity correlator_lib.inv_rom3
    port map (
        i_clk  => i_clk,             --  in  std_logic; 
        i_addr => i_din(8 downto 0), --  in  std_logic_vector(8 downto 0); 
        o_data => rom3_dout          --  out std_logic_vector(31 downto 0) 
    );
    rom4i : entity correlator_lib.inv_rom4
    port map (
        i_clk  => i_clk,             --  in  std_logic; 
        i_addr => i_din(8 downto 0), --  in  std_logic_vector(8 downto 0); 
        o_data => rom4_dout          --  out std_logic_vector(31 downto 0) 
    );
    rom5i : entity correlator_lib.inv_rom5
    port map (
        i_clk  => i_clk,             --  in  std_logic; 
        i_addr => i_din(8 downto 0), --  in  std_logic_vector(8 downto 0); 
        o_data => rom5_dout          --  out std_logic_vector(31 downto 0) 
    );
    rom6i : entity correlator_lib.inv_rom6
    port map (
        i_clk  => i_clk,             --  in  std_logic; 
        i_addr => i_din(8 downto 0), --  in  std_logic_vector(8 downto 0); 
        o_data => rom6_dout          --  out std_logic_vector(31 downto 0) 
    );
    rom7i : entity correlator_lib.inv_rom7
    port map (
        i_clk  => i_clk,             --  in  std_logic; 
        i_addr => i_din(8 downto 0), --  in  std_logic_vector(8 downto 0); 
        o_data => rom7_dout          --  out std_logic_vector(31 downto 0) 
    );
    rom8i : entity correlator_lib.inv_rom8
    port map (
        i_clk  => i_clk,             --  in  std_logic; 
        i_addr => i_din(8 downto 0), --  in  std_logic_vector(8 downto 0); 
        o_data => rom8_dout          --  out std_logic_vector(31 downto 0) 
    );
    
    
    
    
end Behavioral;
