----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: Nov 2020
-- Design Name: Atomic COTS
-- Module Name: packetizer100G_Top - RTL
-- Target Devices: Alveo U50 
-- Tool Versions: 2021.1
-- 
-- 
-- This module will take the output product from the signal processing chain.
-- generate a UDP IPv4 packet that will be fed into the 100G Ethernet interface.
--
-- Source data is arriving at 400MHz
-- Emptying into the Ethernet HARD ip at 322 MHz
-- 

--Required to make the full ethernet frame except interpacket gap and final crc
--All this information can be referenced from
--SKA1 CSP Correlator and Beamformer to Pulsar Engine Interface Control Document 
--Xilinx Docs PG203 - Ultrascale+ Devices Integrated 100G Ethernet subsystem

-- PST packet type
-- LOW PST = 6334 bytes.
-- subtract 4 bytes which are CRC done automatically by 100G core.
-- 6330 - 14 Ethernet - 20 IPv4 - 8 UDP - 96 UDP header = 6192
-- 6192 bytes on 64 bit data interface = 774 writes
-- 48 bytes(6 writes) are realtive weight, rest is data.
-- data into the packet is 64 bits

-- Correlator packet type
-- 14 Ethernet + 20 IPv4 + 8 UDP = 42 bytes
-- 16 byte header       = 1 write
-- 6912 data payload    = 432 writes
-- 6970 bytes total
-- data into the packet is 128 bits

library IEEE, axi4_lib, technology_lib, PSR_Packetiser_lib, signal_processing_common, xil_defaultlib, xpm, common_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use xpm.vcomponents.all;
use PSR_Packetiser_lib.ethernet_pkg.ALL;
use PSR_Packetiser_lib.CbfPsrHeader_pkg.ALL;
use axi4_lib.axi4_stream_pkg.ALL;
use axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.ALL;
use common_lib.common_pkg.ALL;

USE technology_lib.tech_mac_100g_pkg.ALL;
USE PSR_Packetiser_lib.Packetiser_packetiser_reg_pkg.ALL;


library UNISIM;
use UNISIM.VComponents.all;

entity psr_packetiser100G_Top is
    Generic (
        CMAC_IS_LBUS            : BOOLEAN := TRUE;
        
        g_PST_beamformer_version: STD_LOGIC_VECTOR(15 DOWNTO 0) := x"0014";
        g_DEBUG_ILA             : BOOLEAN := FALSE;
        ARGS_RAM                : BOOLEAN := FALSE;
        g_TB_RUNNING            : BOOLEAN := FALSE;
        g_PSN_BEAM_REGISTERS    : INTEGER := 16;        -- number of BEAMS EXPECTED TO PASS THROUGH THE PACKETISER.
        RESET_INTERNAL          : BOOLEAN := TRUE;
        
        Number_of_stream        : INTEGER := 3;         -- MAX 3
            
        packet_type             : INTEGER := 3          -- 0 - Pass through, 1 - CODIF, 2 - LFAA, 3 - PST, 4 - PSS, 5 - Correlator
                                                        -- PST and Correlator only supported at this time.
    
    );
    Port ( 
        -- ~322 MHz
        i_cmac_clk                      : in std_logic;
        i_cmac_rst                      : in std_logic; -- we are assuming currently that all Ethernet will be point to point so if the RX is locked we will transmit.
        
        -- ~400 MHz
        i_packetiser_clk                : in std_logic;
        i_packetiser_rst                : in std_logic;
        
        -- LBUS to CMAC
        o_data_to_transmit                  : out t_lbus_sosi;
        i_data_to_transmit_ctl              : in t_lbus_siso;
        
        -- AXI to CMAC interface to be implemented
        o_tx_axis_tdata                     : OUT STD_LOGIC_VECTOR(511 downto 0);
        o_tx_axis_tkeep                     : OUT STD_LOGIC_VECTOR(63 downto 0);
        o_tx_axis_tvalid                    : OUT STD_LOGIC;
        o_tx_axis_tlast                     : OUT STD_LOGIC;
        o_tx_axis_tuser                     : OUT STD_LOGIC;
        i_tx_axis_tready                    : in STD_LOGIC;

        
        -- signals from signal processing/HBM/the moon/etc
        packet_stream_ctrl                  : in packetiser_stream_ctrl;
        
        packet_stream_stats                 : out t_packetiser_stats(2 downto 0);
                
        packet_stream                       : in t_packetiser_stream_in(2 downto 0);
        packet_stream_out                   : out t_packetiser_stream_out(2 downto 0);
        
        packet_config_in_stream_1           : in packetiser_config_in;
        packet_config_in_stream_2           : in packetiser_config_in;
        packet_config_in_stream_3           : in packetiser_config_in; 
         
        packet_config_stream_1              : out std_logic_vector(31 downto 0);
        packet_config_stream_2              : out std_logic_vector(31 downto 0);
        packet_config_stream_3              : out std_logic_vector(31 downto 0)
        
    
    );
end psr_packetiser100G_Top;

architecture RTL of psr_packetiser100G_Top is

constant FIFO_CACHE_DEPTH   : integer := 1024;

COMPONENT ila_0
PORT (
    clk : IN STD_LOGIC;
    probe0 : IN STD_LOGIC_VECTOR(191 DOWNTO 0));
END COMPONENT;

COMPONENT ila_1
PORT (
    clk : IN STD_LOGIC;
    probe0 : IN STD_LOGIC_VECTOR(575 DOWNTO 0)
    );
END COMPONENT;


signal clock_400_rst            : std_logic := '1';

signal power_up_rst_clock_400   : std_logic_vector(31 downto 0) := c_ones_dword;

signal arb_sel_count            : integer range 0 to 2;

signal data_to_player_wr_sel_d  : STD_LOGIC;

signal bytes_to_transmit_sel    : STD_LOGIC_VECTOR(13 downto 0);     -- 
signal data_to_player_sel       : STD_LOGIC_VECTOR(511 downto 0);
signal data_to_player_wr_sel    : STD_LOGIC;
signal data_to_player_rdy_sel   : STD_LOGIC;

-- HARD CODE THIS TO A MAX OF 3 INPUT PIPES, does not engage with number of streams generic.
signal fifo_data_used           : t_slv_11_arr(2 downto 0)  := ((others => '0'), (others => '0'), (others => '0'));

signal stream_select            : STD_LOGIC_VECTOR(2 downto 0);
signal stream_select_prev       : STD_LOGIC_VECTOR(2 downto 0);

signal stream_pending           : STD_LOGIC_VECTOR(2 downto 0);
signal stream_pending_cache     : STD_LOGIC_VECTOR(2 downto 0);
-----------------------------------------------------------------------

type arbiter_statemachine is (IDLE, DATA, FINISH, HAND_OFF, TEST_MODE);
signal arbiter_sm : arbiter_statemachine;

signal bytes_to_transmit        : t_slv_14_arr((Number_of_stream-1) downto 0);
signal data_to_player           : t_slv_512_arr((Number_of_stream-1) downto 0);
signal data_to_player_wr        : STD_LOGIC_VECTOR((Number_of_stream-1) downto 0);
signal data_to_player_rdy       : STD_LOGIC_VECTOR((Number_of_stream-1) downto 0);

signal invalid_packet           : STD_LOGIC_VECTOR((Number_of_stream-1) downto 0);

signal stream_enable            : STD_LOGIC_VECTOR((Number_of_stream-1) downto 0);

signal MAC_locked_clk400        : std_logic;

signal packet_former_reset      : std_logic;

signal o_data_to_transmit_int   : t_lbus_sosi;

signal checked_data             : t_packetiser_stream_in((Number_of_stream-1) downto 0);
signal to_checked_data          : t_packetiser_stream_out((Number_of_stream-1) downto 0);

signal packet_config_out        : t_packetiser_config_out(2 downto 0);
signal packetiser_config_in     : t_packetiser_config_in(2 downto 0);

signal packetlength_reset       : std_logic_vector(2 downto 0);
signal packetformer_reset       : std_logic_vector(2 downto 0);

signal packetiser_control       : t_packetiser_stream_ctrl(2 downto 0);

signal testmode                 : std_logic_vector(2 downto 0);

begin

------------------------------------------------------------------------------------

packet_config_stream_1  <= packet_config_out(0).config_data_out;
packet_config_stream_2  <= packet_config_out(1).config_data_out;
packet_config_stream_3  <= packet_config_out(2).config_data_out;

packetiser_config_in(0) <= packet_config_in_stream_1;
packetiser_config_in(1) <= packet_config_in_stream_2;
packetiser_config_in(2) <= packet_config_in_stream_3;

------------------------------------------------------------------------------------
-- POWER UP RESETS, might move this to higher level but it is node specific ATM.
reset_proc_clk400: process(i_packetiser_clk)
begin
    if rising_edge(i_packetiser_clk) then
        -- power up reset logic
        if power_up_rst_clock_400(31) = '1' then
            power_up_rst_clock_400(31 downto 0) <= power_up_rst_clock_400(30 downto 0) & '0';
            clock_400_rst   <= '1';
        else
            clock_400_rst   <= '0';
        end if;
    end if;
end process;


-- retime the 100G enable to fold into reset for 400 MHZ CD of the packetiser.
xpm_cdc_pulse_inst : xpm_cdc_single
generic map (
    DEST_SYNC_FF    => 4,   
    INIT_SYNC_FF    => 1,   
    SRC_INPUT_REG   => 1,   
    SIM_ASSERT_CHK  => 0    
)
port map (
    dest_clk        => i_packetiser_clk,   
    dest_out        => MAC_locked_clk400,         
    src_clk         => i_cmac_clk,    
    src_in          => i_cmac_rst
);


fanout_proc : process(i_packetiser_clk)
begin
    if rising_edge(i_packetiser_clk) then
        packet_former_reset     <= clock_400_rst OR (MAC_locked_clk400);
        
        packetlength_reset      <= packet_former_reset & packet_former_reset & packet_former_reset;
        packetformer_reset      <= packet_former_reset & packet_former_reset & packet_former_reset;

        
    end if;
end process;


fanout_proc_args : process(packet_config_in_stream_1.config_data_clk)
begin
    if rising_edge(packet_config_in_stream_1.config_data_clk) then
        packetiser_control(0)   <= packet_stream_ctrl;
        packetiser_control(1)   <= packet_stream_ctrl;
        packetiser_control(2)   <= packet_stream_ctrl;
        
    end if;
end process;

------------------------------------------------------------------------------------
-- GENERATE BASED ON STREAMS, 3 for PST.

packet_gen : for i in 0 to (Number_of_stream-1) GENERATE
------------------------------------------------------------------------------------
    PST_type_gen : if (packet_type = 3) GENERATE

        PST_injest : entity PSR_Packetiser_lib.packet_length_check 
            generic map (
                FIFO_CACHE_DEPTH                => FIFO_CACHE_DEPTH
            )
            port map( 
                i_clk400                        => i_packetiser_clk,
                i_reset_400                     => packetlength_reset(i), --packet_former_reset,
                
                o_invalid_packet                => invalid_packet(i),
                i_stream_enable                 => stream_enable(i),
                i_wr_to_cmac                    => data_to_player_wr(i),
                
                o_fifo_data_used                => fifo_data_used(i),
                
                o_stats                         => packet_stream_stats(i),
            
                i_packetiser_data_in            => packet_stream(i),
                o_packetiser_data_out           => packet_stream_out(i),
                
                o_packetiser_data_to_former     => checked_data(i),
                i_packetiser_data_to_former     => to_checked_data(i)
                
            );
        
        
        ------------------------------------------------------------------------------------
        
        PST_packetiser : entity PSR_Packetiser_lib.packet_former generic map(
                g_INSTANCE                  => i,
                g_DEBUG_ILA                 =>  FALSE,
                g_TEST_PACKET_GEN           =>  TRUE,
                g_LBUS_CMAC                 => CMAC_IS_LBUS,
                g_LE_DATA_SWAPPING          =>  TRUE,           -- True for PST.
                
                g_PST_beamformer_version    => g_PST_beamformer_version,
                
                g_PSN_BEAM_REGISTERS        =>  16,
                METADATA_HEADER_BYTES       =>  96,
                WEIGHT_CHAN_SAMPLE_BYTES    =>  6192      -- 6192 for LOW PST, 4626 for LOW PSS
            
            )
            Port map ( 
                i_clk400                => i_packetiser_clk,
                i_reset_400             => packetformer_reset(i), --packet_former_reset,
                
                ---------------------------
                -- Stream interface
                i_packetiser_data_in    => checked_data(i),
                o_packetiser_data_out   => to_checked_data(i),
            
                i_packetiser_reg_in     => packetiser_config_in(i), --packet_config,
                o_packetiser_reg_out    => packet_config_out(i),
                
                i_packetiser_ctrl       => packetiser_control(i), --packet_stream_ctrl,
                
                o_testmode              => testmode(i),
        
        
                -- Aligned packet for transmitting
                o_bytes_to_transmit     => bytes_to_transmit(i), 
                o_data_to_player        => data_to_player(i),
                o_data_to_player_wr     => data_to_player_wr(i),
                i_data_to_player_rdy    => data_to_player_rdy(i),
            
                -- debug
                o_stream_enable         => stream_enable(i)
            
            );
    END GENERATE;
    
    
    Correlator_type_gen : if (packet_type = 5) GENERATE

        Correlator_injest : entity PSR_Packetiser_lib.packet_length_check_correlator 
            generic map (
                FIFO_CACHE_DEPTH                => FIFO_CACHE_DEPTH
            )
            port map( 
                i_clk400                        => i_packetiser_clk,
                i_reset_400                     => packetlength_reset(i), --packet_former_reset,
                
                o_invalid_packet                => invalid_packet(i),
                i_stream_enable                 => stream_enable(i),
                i_wr_to_cmac                    => data_to_player_wr(i),
                
                o_fifo_data_used                => fifo_data_used(i),
                
                o_stats                         => packet_stream_stats(i),
            
                i_packetiser_data_in            => packet_stream(i),
                o_packetiser_data_out           => packet_stream_out(i),
                
                o_packetiser_data_to_former     => checked_data(i),
                i_packetiser_data_to_former     => to_checked_data(i)
                
            );
        
        
        ------------------------------------------------------------------------------------
        
        Correlator_packetiser : entity PSR_Packetiser_lib.packet_former_correlator generic map(
                g_INSTANCE                  => i,
                g_DEBUG_ILA                 => FALSE,
                g_TEST_PACKET_GEN           => FALSE,
                g_LBUS_CMAC                 => CMAC_IS_LBUS,
                g_LE_DATA_SWAPPING          => FALSE
            
            )
            Port map ( 
                i_clk400                => i_packetiser_clk,
                i_reset_400             => packetformer_reset(i), --packet_former_reset,
                
                ---------------------------
                -- Stream interface
                i_packetiser_data_in    => checked_data(i),
                o_packetiser_data_out   => to_checked_data(i),
            
                i_packetiser_reg_in     => packetiser_config_in(i), --packet_config,
                o_packetiser_reg_out    => packet_config_out(i),
                
                i_packetiser_ctrl       => packetiser_control(i), --packet_stream_ctrl,
        
        
                -- Aligned packet for transmitting
                o_bytes_to_transmit     => bytes_to_transmit(i), 
                o_data_to_player        => data_to_player(i),
                o_data_to_player_wr     => data_to_player_wr(i),
                i_data_to_player_rdy    => data_to_player_rdy(i),
            
                -- debug
                o_stream_enable         => stream_enable(i)
            
            );
    END GENERATE;    
    
    ---------------------------------------------------------------------------------------------------------
    -- V1
    --data_to_player_rdy(i)   <=  '1' when data_to_player_rdy_sel = '1' AND arb_sel_count = i else
    --                         '0';
    
    
    data_to_player_rdy(i)   <=  '1' when data_to_player_rdy_sel = '1' AND stream_select(i) = '1' else
                                '0';


END GENERATE;
---------------------------------------------------------------------------------------------------------------------------------------
-- Simple round robin access = v1
-- Assume that PST is providing data at a constant, repeatable rate and pattern from each of the 3 pipelines.
-- it will be as simple as move from one pipe to the next intially.

-- arbiter SM is V2 that will take from the stream with the most pending.
-- needed for unbalanced pipelines
--signal fifo_data_used           : t_slv_10_arr((Number_of_stream-1) downto 0);
--signal stream_select            : STD_LOGIC_VECTOR((Number_of_stream-1) downto 0);

--type arbiter_statemachine is (IDLE, DATA, FINISH, HAND_OFF);
--signal arbiter_sm : arbiter_statemachine;

packetiser_arb_proc : process (i_packetiser_clk)
begin
    if rising_edge(i_packetiser_clk) then
        if packet_former_reset = '1' then
            arb_sel_count           <= 0;
            data_to_player_wr_sel   <= '0';
            stream_select           <= "001";
            stream_select_prev      <= "001";
            stream_pending          <= "000";
            stream_pending_cache    <= "000";
            arbiter_sm              <= IDLE;
        else
            data_to_player_wr_sel_d <= data_to_player_wr_sel;
            
-- V1            
--            if (data_to_player_wr_sel_d = '1' and data_to_player_wr_sel = '0') OR (invalid_packet(arb_sel_count) = '1') then
--                if arb_sel_count = (Number_of_stream-1) then
--                    arb_sel_count <= 0;
--                else
--                    arb_sel_count <= arb_sel_count + 1;
--                end if;
--            end if;
---------------------------
-- V2
            -- assume that if there is at least 64 words that one packet is almost ready to go. bit 9 -> 6
            stream_pending(0) <= (fifo_data_used(0)(9) OR fifo_data_used(0)(8) OR fifo_data_used(0)(7) OR fifo_data_used(0)(6));
            stream_pending(1) <= (fifo_data_used(1)(9) OR fifo_data_used(1)(8) OR fifo_data_used(1)(7) OR fifo_data_used(1)(6));
            stream_pending(2) <= (fifo_data_used(2)(9) OR fifo_data_used(2)(8) OR fifo_data_used(2)(7) OR fifo_data_used(2)(6));
            
   
--            case arbiter_sm is
            
--                when IDLE => 
--                    if ((stream_pending(0) = '1') OR (stream_pending(1) = '1') OR (stream_pending(2) = '1')) then
--                        arbiter_sm              <= HAND_OFF;
--                        stream_pending_cache    <= stream_pending;
--                    elsif testmode(0) = '1' then
--                        arbiter_sm              <= TEST_MODE;
--                        arb_sel_count <= 0;
--                        stream_select <= "001";
--                    end if;
                
--                when HAND_OFF =>
--                    -- if all are pending assume the previous might have happened and move to next one.
--                    if stream_pending_cache = "111" then
--                        stream_select   <= stream_select_prev(1 downto 0) & stream_select_prev(2);
                        
--                    elsif stream_pending_cache(0) = '1' then
--                        if ((stream_pending_cache(2) = '1') OR (stream_pending_cache(1) = '1')) AND stream_select_prev = "001" then
--                            stream_select   <= stream_pending_cache(2 downto 1) & '0';
--                    else
--                            stream_select   <= "001";
--                    end if;
                        
--                    elsif stream_pending_cache(1) = '1' then
--                        if ((stream_pending_cache(2) = '1') OR (stream_pending_cache(0) = '1')) AND stream_select_prev = "010" then
--                            stream_select   <= stream_pending_cache(2) & '0' & stream_pending_cache(0);
--                        else
--                            stream_select   <= "010";
--                        end if;
            
--                    elsif stream_pending_cache(2) = '1' then
--                        if ((stream_pending_cache(1) = '1') OR (stream_pending_cache(0) = '1')) AND stream_select_prev = "100" then
--                            stream_select   <= '0' & stream_pending_cache(1 downto 0);
--                        else
--                            stream_select   <= "100";
--                        end if;
                    
--                    end if;
--                    arbiter_sm <= DATA;
                
--                when DATA =>
--                    if stream_select = "001" then
--                        arb_sel_count <= 0;
--                    elsif stream_select = "010" then
--                        arb_sel_count <= 1;
--                    elsif stream_select = "100" then
--                        arb_sel_count <= 2;
--                    end if;
                    
--                    if (data_to_player_wr_sel_d = '1' and data_to_player_wr_sel = '0') OR (invalid_packet(arb_sel_count) = '1') then
                    
--                        arbiter_sm          <= FINISH;
--                        stream_select       <= "000";
--                        stream_select_prev  <= stream_select;
--                    end if;
                
--                when FINISH => 
--                    arbiter_sm <= IDLE;
                    
--                when TEST_MODE =>
--                    -- round robin, assumes all pipes go into test.
--                    if (data_to_player_wr_sel_d = '1' and data_to_player_wr_sel = '0') then
--                        if arb_sel_count = (Number_of_stream-1) then
--                            arb_sel_count <= 0;
--                            stream_select <= "001";
--                        else
--                            arb_sel_count <= arb_sel_count + 1;
--                            stream_select <= stream_select(1 downto 0) & stream_select(2);
--                        end if;
--                    end if;
                    
--                    if testmode(0) = '0' AND (data_to_player_wr_sel_d = '0' and data_to_player_wr_sel = '0') then
--                            arbiter_sm    <= FINISH;
--                    end if;
                
                
--                when OTHERS =>
--                    arbiter_sm <= IDLE;
--            end case;
            
            arb_sel_count <= 0;
            
            bytes_to_transmit_sel   <= bytes_to_transmit(arb_sel_count);
            data_to_player_sel      <= data_to_player(arb_sel_count);
            data_to_player_wr_sel   <= data_to_player_wr(arb_sel_count);
            --data_to_player_rdy_sel  <= data_to_player_rdy(arb_sel_count);

        end if;
    end if;
end process;

---------------------------------------------------------------------------------------------------------------------------------------


playout : entity PSR_Packetiser_lib.packet_player 
    generic map(
        LBUS_TO_CMAC_INUSE      => CMAC_IS_LBUS,      -- FUTURE WORK to IMPLEMENT AXI
        PLAYER_CDC_FIFO_DEPTH   => 256        -- FIFO is 512 Wide, 9KB packets = 73728 bits, 512 * 256 = 131072, 256 depth allows ~1.88 9K packets, we are target packets sizes smaller than this.
    )
    port map ( 
        i_clk400                => i_packetiser_clk,
        i_reset_400             => packet_former_reset,
    
        i_cmac_clk              => i_cmac_clk,
        i_cmac_clk_rst          => i_cmac_rst,
        
        i_bytes_to_transmit     => bytes_to_transmit_sel,
        i_data_to_player        => data_to_player_sel,
        i_data_to_player_wr     => data_to_player_wr_sel,
        o_data_to_player_rdy    => data_to_player_rdy_sel,
        
        o_cmac_ready            => open,
        
        -- streaming AXI to CMAC
        o_tx_axis_tdata         => o_tx_axis_tdata,
        o_tx_axis_tkeep         => o_tx_axis_tkeep,
        o_tx_axis_tvalid        => o_tx_axis_tvalid,
        o_tx_axis_tlast         => o_tx_axis_tlast,
        o_tx_axis_tuser         => o_tx_axis_tuser,
        i_tx_axis_tready        => i_tx_axis_tready,
    
        -- LBUS to CMAC
        o_data_to_transmit      => o_data_to_transmit_int,
        i_data_to_transmit_ctl  => i_data_to_transmit_ctl
    );
	
	o_data_to_transmit         <= o_data_to_transmit_int;
---------------------------------------------------------------------------------------------------------------------------------------
-- ILA for debugging
packetiser_top_debug : IF g_DEBUG_ILA GENERATE

    packetiser_ila : ila_0
    port map (
        clk                     => i_packetiser_clk, 
        probe0(127 downto 0)    => data_to_player(0)(127 downto 0), 
        probe0(128)             => data_to_player_wr(0), 
        probe0(142 downto 129)  => bytes_to_transmit(0),
        probe0(143)             => data_to_player_rdy(0), 
        probe0(191 downto 144)  => (others => '0')
    );
    
    CMAC_ila : ila_0
    port map (
        clk                     => i_cmac_clk, 
        probe0(0)               => i_data_to_transmit_ctl.ready,
        probe0(1)               => i_data_to_transmit_ctl.overflow,
        probe0(2)               => i_data_to_transmit_ctl.underflow,
        probe0(3)               => '0',
        probe0(7 downto 4)      => o_data_to_transmit_int.sop,
        probe0(11 downto 8)     => o_data_to_transmit_int.eop,
        probe0(15 downto 12)    => o_data_to_transmit_int.empty(0),
        probe0(19 downto 16)    => o_data_to_transmit_int.empty(1),
        probe0(23 downto 20)    => o_data_to_transmit_int.empty(2),
        probe0(27 downto 24)    => o_data_to_transmit_int.empty(3),
        probe0(28)              => '0', 
        probe0(29)              => o_data_to_transmit_int.valid(0),
        probe0(30)              => o_data_to_transmit_int.valid(1),
        probe0(31)              => o_data_to_transmit_int.valid(2),
        probe0(32)              => o_data_to_transmit_int.valid(3),
        probe0(33)              => '0',
        probe0(161 downto 34)   => o_data_to_transmit_int.data(127 downto 0),                 
        probe0(191 downto 162)  => (others => '0')
    );
end generate;
    
end RTL;
