----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 12/18/2025 12:11:20 PM
-- Design Name: 
-- Module Name: cmac_versal_tb - Behavioral
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
library IEEE, correlator_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use correlator_lib.cmac_pkg.all;

entity cmac_versal_tb is
--  Port ( );
end cmac_versal_tb;

architecture Behavioral of cmac_versal_tb is

    signal row_meta : t_cmac_input_bus;
    signal XX_vld_versal : std_logic;
    signal XX_data_versal : std_logic_vector(47 downto 0);
    signal XX_vld_ultrascale : std_logic;
    signal XX_data_ultrascale : std_logic_vector(47 downto 0);
    
    signal i_row_data, i_col_data : std_logic_Vector(15 downto 0);
    type slv16arr_t is array(31 downto 0) of std_logic_vector(15 downto 0);
    constant test_data : slv16arr_t := (x"1234",x"8181",x"8282",x"7E82", x"ff40",x"0140",x"40ff",x"5FA3",
                                        x"0101",x"007F",x"7F00",x"017F", x"7F01",x"7FFF",x"FF7F",x"7f7f",
                                        x"8100",x"0081",x"8101",x"0181", x"81ff",x"ff81",x"8181",x"7f81",
                                        x"00FF",x"FF00",x"FF01",x"01FF",x"FFFF",x"0000",x"0100",x"0001");
    signal i_clk : std_logic := '0';
    
begin
    
    i_clk <= not i_clk after 5ns;
    
    
    row_meta.rfi <= '0';
    row_meta.sample_cnt <= (others => '0');
    
    process
    begin
        row_meta.vld <= '0'; -- i_valid; -- : in t_cmac_input_bus;              -- .vld, .first, .last, .rfi, .sample_cnt
        row_meta.first <= '1'; -- i_first;
        row_meta.last <= '0'; -- i_last;
        i_row_data <= (others => '0');
        i_col_data <= (others => '0');
        -- takes a while for the DSP component to come up at the start of the simulation !
        wait until rising_edge(i_clk);
        wait until rising_edge(i_clk);
        wait until rising_edge(i_clk);
        wait until rising_edge(i_clk);
        wait until rising_edge(i_clk);
        wait until rising_edge(i_clk);
        wait until rising_edge(i_clk);
        wait until rising_edge(i_clk);
        wait until rising_edge(i_clk);
        wait until rising_edge(i_clk);
        wait until rising_edge(i_clk);
        wait until rising_edge(i_clk);
        wait until rising_edge(i_clk);
        wait until rising_edge(i_clk);
        wait until rising_edge(i_clk);
        wait until rising_edge(i_clk);
        for i in 0 to 31 loop
            for j in 0 to 31 loop
                if j = 0 then
                    row_meta.first <= '1';
                else
                    row_meta.first <= '0';
                end if;
                if j = 31 then
                    row_meta.last <= '1';
                else
                    row_meta.last <= '0';
                end if;
                row_meta.vld <= '1';
                --row_meta.last <= '1';
                i_row_data <= test_data(i);
                i_col_data <= test_data(j);
                wait until rising_edge(i_clk);
            end loop;
        end loop;
        row_meta.vld <= '0';
        wait;
    end process;
    
    cmac_XX : entity correlator_lib.cmac
    generic map (
        g_ACCUM_WIDTH     => 24, -- natural := 24;
        g_SAMPLE_WIDTH    => 8,  -- natural range 1 to 9 := 8;  -- >6 uses two 18b multiplers
        g_CMAC_LATENCY    => 5   -- natural range work.cmac_pkg.c_CMAC_LATENCY to work.cmac_pkg.c_CMAC_LATENCY  -- i.e. 5
    ) port map (
        i_clk       => i_clk, -- in std_logic;
        i_clk_reset => '0',   -- in std_logic;  -- all this does is disable simulation error messages.

        i_row       => row_meta,   -- in t_cmac_input_bus;  only uses .vld, .first and .last
        i_row_real  => i_row_data(7 downto 0),  -- in std_logic_vector(7 downto 0);
        i_row_imag  => i_row_data(15 downto 8), -- in std_logic_vector(7 downto 0);
        
        i_col       => row_meta, --  in t_cmac_input_bus;
        i_col_real  => i_col_data(7 downto 0),  --  in std_logic_vector(7 downto 0);
        i_col_imag  => i_col_data(15 downto 8), --  in std_logic_vector(7 downto 0);

        -- Readout interface. Readout pulses high 5 clocks after i_<col|row>.last
        o_readout_vld  => XX_vld_ultrascale, -- out std_logic;
        o_readout_data => XX_data_ultrascale -- out std_logic_vector((g_ACCUM_WIDTH*2 - 1) downto 0)  -- real part in low g_ACCUM_WIDTH bits, imaginary part in high g_ACCUM_BITS 
    );
    
    cmac_versalXX : entity correlator_lib.cmac_versal
    generic map (
        g_BYPASS_OFFSETS => false
    ) port map (
        i_clk       => i_clk, -- in std_logic;
        i_clk_reset => '0',   -- in std_logic;  -- all this does is disable simulation error messages.

        i_row       => row_meta,   -- in t_cmac_input_bus;  only uses .vld, .first and .last
        i_row_real  => i_row_data(7 downto 0),  -- in std_logic_vector(7 downto 0);
        i_row_imag  => i_row_data(15 downto 8), -- in std_logic_vector(7 downto 0);
        
        i_col       => row_meta, --  in t_cmac_input_bus;
        i_col_real  => i_col_data(7 downto 0),  --  in std_logic_vector(7 downto 0);
        i_col_imag  => i_col_data(15 downto 8), --  in std_logic_vector(7 downto 0);

        -- Readout interface. Readout pulses high 5 clocks after i_<col|row>.last
        o_readout_vld  => XX_vld_versal, -- out std_logic;
        o_readout_data => XX_data_versal -- out std_logic_vector((g_ACCUM_WIDTH*2 - 1) downto 0)  -- real part in low g_ACCUM_WIDTH bits, imaginary part in high g_ACCUM_BITS 
    );
    ----------------------------------------------------------------------

    assert XX_data_ultrascale = XX_data_versal or XX_vld_versal = '0' report "mismatch" severity error;
--    process
--    begin
    
--        wait until rising_edge(i_clk);
        
    
--    end process;

end Behavioral;
