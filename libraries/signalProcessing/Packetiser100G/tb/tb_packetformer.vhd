----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: Oct 2021
-- Design Name: TB_packetformer
-- 
-- 
-- test bench written to be used in Vivado
-- 
--
library IEEE,technology_lib, PSR_Packetiser_lib, signal_processing_common, axi4_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use PSR_Packetiser_lib.ethernet_pkg.ALL;
use PSR_Packetiser_lib.CbfPsrHeader_pkg.ALL;
use axi4_lib.axi4_stream_pkg.ALL;
use axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.ALL;

USE technology_lib.tech_mac_100g_pkg.ALL;

entity tb_packet_former is
--  Port ( );
end tb_packet_former;

architecture Behavioral of tb_packet_former is


signal clock_300 : std_logic := '0';    -- 3.33ns
signal clock_400 : std_logic := '0';    -- 2.50ns
signal clock_322 : std_logic := '0';

signal testCount            : integer   := 0;
signal testCount_300        : integer   := 0;
signal testCount_clk100G    : integer   := 0;

signal clock_400_rst        : std_logic := '1';
signal clock_300_rst        : std_logic := '1';
signal i_clk400_rst         : std_logic := '1';

signal power_up_rst_clock_400   : std_logic_vector(31 downto 0) := c_ones_dword;
signal power_up_rst_clock_300   : std_logic_vector(31 downto 0) := c_ones_dword;
signal power_up_rst_clock_322   : std_logic_vector(31 downto 0) := c_ones_dword;

signal i_clk400                 : std_logic;

signal test_count               : integer := 0;


begin

--clock_300 <= not clock_300 after 3.33 ns;
--clock_322 <= not clock_322 after 3.11 ns;

clock_400 <= not clock_400 after 2.50 ns;


i_clk400        <= clock_400;


-------------------------------------------------------------------------------------------------------------
-- powerup resets for SIM
test_runner_proc_clk300: process(clock_300)
begin
    if rising_edge(clock_300) then
        -- power up reset logic
        if power_up_rst_clock_300(31) = '1' then
            power_up_rst_clock_300(31 downto 0) <= power_up_rst_clock_300(30 downto 0) & '0';
            clock_300_rst   <= '1';
            testCount_300   <= 0;
        else
            clock_300_rst   <= '0';
            testCount_300   <= testCount_300 + 1;
            

        end if;

    end if;
end process;

test_runner_proc_clk400: process(clock_400)
begin
    if rising_edge(clock_400) then
        -- power up reset logic
        if power_up_rst_clock_400(31) = '1' then
            power_up_rst_clock_400(31 downto 0) <= power_up_rst_clock_400(30 downto 0) & '0';
            testCount           <= 0;
            clock_400_rst       <= '1';
        else
            testCount       <= testCount + 1;
            clock_400_rst   <= '0';
         
        end if;
    end if;
end process;

-------------------------------------------------------------------------------------------------------------

dut_stim_proc : process(clock_400)
begin
    if rising_edge(clock_400) then

        if testCount = 0 then
            i_clk400_rst <= '1';
        elsif testCount = 10 then
            i_clk400_rst <= '0';
        end if;
    end if;
end process;

--- DUT/UUT
DUT : entity PSR_Packetiser_lib.packet_former generic map(
        g_DEBUG_ILA                 =>  FALSE,
        g_TEST_PACKET_GEN           =>  TRUE,
        
        g_LE_DATA_SWAPPING          =>  FALSE,
        
        g_PSN_BEAM_REGISTERS        =>  16,
        METADATA_HEADER_BYTES       =>  96,
        WEIGHT_CHAN_SAMPLE_BYTES    =>  6192      -- 6192 for LOW PST, 4626 for LOW PSS
    
    )
    Port map ( 
        i_clk400                => i_clk400,
        i_reset_400             => i_clk400_rst,
        
        ---------------------------
        -- Stream interface
        i_packetiser_data_in    => null_packetiser_stream_in,
        o_packetiser_data_out   => open,
    
        i_packetiser_reg_in     => null_packetiser_config_in,
        o_packetiser_reg_out    => open,
        
        i_packetiser_ctrl       => null_packetiser_stream_ctrl,


        -- Aligned packet for transmitting
        o_bytes_to_transmit     => open, 
        o_data_to_player        => open,
        o_data_to_player_wr     => open,
    
        -- debug
        o_dbg_ILA_trigger       => open
    
    );






end Behavioral;
