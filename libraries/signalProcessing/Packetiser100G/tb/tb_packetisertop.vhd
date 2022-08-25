----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: Nov 2020
-- Design Name: tb_packetisertop
-- 
-- Target Devices: +US
-- 
-- test bench written to be used in Vivado
-- project and waveview view also provided, tb_packetiser.xpr for Vivado 2020.1
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

entity tb_packetisertop is
--  Port ( );
end tb_packetisertop;

architecture Behavioral of tb_packetisertop is


signal clock_300 : std_logic := '0';    -- 3.33ns
signal clock_400 : std_logic := '0';    -- 2.50ns
signal clock_322 : std_logic := '0';

signal testCount            : integer   := 0;
signal testCount_300        : integer   := 0;
signal testCount_322        : integer   := 0;

signal clock_400_rst        : std_logic := '1';
signal clock_300_rst        : std_logic := '1';
signal clock_322_rst        : std_logic := '1';

signal i_clk400_rst         : std_logic := '1';

signal power_up_rst_clock_400   : std_logic_vector(31 downto 0) := c_ones_dword;
signal power_up_rst_clock_300   : std_logic_vector(31 downto 0) := c_ones_dword;
signal power_up_rst_clock_322   : std_logic_vector(31 downto 0) := c_ones_dword;

signal i_clk400                 : std_logic;

signal test_count               : integer := 0;

signal bytes_to_transmit        : STD_LOGIC_VECTOR(13 downto 0);     -- 
signal data_to_player           : STD_LOGIC_VECTOR(511 downto 0);
signal data_to_player_wr        : STD_LOGIC;
signal data_to_player_rdy       : STD_LOGIC;

signal o_data_to_transmit      : t_lbus_sosi;
signal i_data_to_transmit_ctl  : t_lbus_siso;

signal packetiser_ctrl          : packetiser_stream_ctrl;
signal packetiser_config        : packetiser_config_in;

begin

clock_300 <= not clock_300 after 3.33 ns;
clock_322 <= not clock_322 after 3.11 ns;

clock_400 <= not clock_400 after 2.50 ns;


i_clk400        <= clock_400;

packetiser_config.config_data_clk <= clock_300;

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

test_runner_proc_clk322: process(clock_322)
begin
    if rising_edge(clock_322) then
        -- power up reset logic
        if power_up_rst_clock_322(31) = '1' then
            power_up_rst_clock_322(31 downto 0) <= power_up_rst_clock_322(30 downto 0) & '0';
            clock_322_rst   <= '1';
            testCount_322   <= 0;
        else
            clock_322_rst   <= '0';
            testCount_322   <= testCount_322 + 1;
            

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

args_stim_proc : process(clock_300)
begin
    if rising_edge(clock_300) then

        if (testCount_300 = 0) then-- OR (testCount_300 = 200) or (testCount_300 = 400) then
            packetiser_ctrl.instruct(3 downto 0) <= x"0";
        elsif (testCount_300 = 10) or (testCount_300 = 210) or (testCount_300 = 410) then
            packetiser_ctrl.instruct(3 downto 0) <= x"7";
            
        end if;
    end if;
end process;
 



cmac_emulator : process(clock_322)
begin
    if rising_edge(clock_322) then
        if (testCount_322 > 15) then
            if testCount_322 = 200 or testCount_322 = 250 then
                i_data_to_transmit_ctl.ready <= '0';
            else    
                i_data_to_transmit_ctl.ready <= '1';
            end if;
        else
            i_data_to_transmit_ctl.ready        <= '0';   
            i_data_to_transmit_ctl.overflow     <= '0';
            i_data_to_transmit_ctl.underflow    <= '0';     
        end if;
    end if;
end process;

--- DUT/UUT
DUT_1 : entity PSR_Packetiser_lib.packet_former generic map(
        g_DEBUG_ILA                 =>  FALSE,
        g_TEST_PACKET_GEN           =>  TRUE,
        
        g_LE_DATA_SWAPPING          =>  FALSE,
        
        g_PSN_BEAM_REGISTERS        =>  16,
        METADATA_HEADER_BYTES       =>  96,
        WEIGHT_CHAN_SAMPLE_BYTES    =>  6192      -- 6192 for LOW PST, 4626 for LOW PSS
    
    )
    Port map ( 
        i_clk400                => clock_300,
        i_reset_400             => clock_300_rst,
        
        ---------------------------
        -- Stream interface
        i_packetiser_data_in    => null_packetiser_stream_in,
        o_packetiser_data_out   => open,
    
        i_packetiser_reg_in     => packetiser_config,
        o_packetiser_reg_out    => open,
        
        i_packetiser_ctrl       => packetiser_ctrl,


        -- Aligned packet for transmitting
        o_bytes_to_transmit     => bytes_to_transmit, 
        o_data_to_player        => data_to_player,
        o_data_to_player_wr     => data_to_player_wr,
        i_data_to_player_rdy    => data_to_player_rdy,
    
        -- debug
        o_dbg_ILA_trigger       => open
    
    );


DUT_2 : entity PSR_Packetiser_lib.packet_player 
    generic map(
        LBUS_TO_CMAC_INUSE      => TRUE,      -- FUTURE WORK to IMPLEMENT AXI
        PLAYER_CDC_FIFO_DEPTH   => 256        -- FIFO is 512 Wide, 9KB packets = 73728 bits, 512 * 256 = 131072, 256 depth allows ~1.88 9K packets, we are target packets sizes smaller than this.
    )
    port map ( 
        i_clk400                => clock_300,
        i_reset_400             => clock_300_rst,
    
        i_cmac_clk              => clock_322,
        i_cmac_clk_rst          => clock_322_rst,
        
        i_bytes_to_transmit     => bytes_to_transmit,
        i_data_to_player        => data_to_player,
        i_data_to_player_wr     => data_to_player_wr,
        o_data_to_player_rdy    => data_to_player_rdy,
        
        o_cmac_ready            => open,
    
        -- LBUS to CMAC
        o_data_to_transmit      => o_data_to_transmit,
        i_data_to_transmit_ctl  => i_data_to_transmit_ctl
    );



end Behavioral;
