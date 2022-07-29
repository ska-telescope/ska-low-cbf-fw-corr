----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: 18.10.2021
-- Design Name: 
-- Module Name: packet_player - rtl
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
--  play out packet data from 400 MHz to the ~322 MHz for the CMAC.
--  This will support the LBUS or AXI interface to the CMAC.
-- 
-- PLAYER_CDC_FIFO_DEPTH -  FIFO is 512 Wide, 9KB packets = 73728 bits, 
--                          512 * 256 = 131072, 256 depth allows ~1.88 9K packets, 
--                          we are target packets sizes smaller than this.
--                          This will consume 4 x 36K BRAMS.
--
-- General behaviour will be, the packet will wait to be cached in the FIFO before being flushed to CMAC.
-- The trigger for this flush will be the des-assertion of the write signal on incoming data side.
-- Therefore it is assumed that data is shunted to the player as continuous block.
--
-- The player will be able to have 2 packet pending or 1 playing and 1 pending, 
-- it will indicate not ready in this state.
-- once it drops to 1 packet playing or 1 packet pending then it will become ready again.
--  Distributed under the terms of the CSIRO Open Source Software Licence Agreement
--  See the file LICENSE for more info.
----------------------------------------------------------------------------------


library IEEE, xpm, PSR_Packetiser_lib, common_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use PSR_Packetiser_lib.ethernet_pkg.ALL;
use PSR_Packetiser_lib.CbfPsrHeader_pkg.ALL;
use xpm.vcomponents.all;
USE common_lib.common_pkg.ALL;
library technology_lib;
USE technology_lib.tech_mac_100g_pkg.ALL;

library UNISIM;
use UNISIM.VComponents.all;

entity packet_player is
    Generic (
        g_DEBUG_ILA             : BOOLEAN := FALSE;
        LBUS_TO_CMAC_INUSE      : BOOLEAN := TRUE;      -- FUTURE WORK to IMPLEMENT AXI
        PLAYER_CDC_FIFO_DEPTH   : INTEGER := 512        -- FIFO is 512 Wide, 9KB packets = 73728 bits, 512 * 256 = 131072, 256 depth allows ~1.88 9K packets, we are target packets sizes smaller than this.
    );
    Port ( 
        i_clk400                : IN STD_LOGIC;
        i_reset_400             : IN STD_LOGIC;
    
        i_cmac_clk              : IN STD_LOGIC;
        i_cmac_clk_rst          : IN STD_LOGIC;
        
        i_bytes_to_transmit     : IN STD_LOGIC_VECTOR(13 downto 0);     -- 
        i_data_to_player        : IN STD_LOGIC_VECTOR(511 downto 0);
        i_data_to_player_wr     : IN STD_LOGIC;
        o_data_to_player_rdy    : OUT STD_LOGIC;
        
        o_cmac_ready            : OUT STD_LOGIC;
        
        -- traffic stats
        o_time_between_packets_largest  : OUT STD_LOGIC_VECTOR(15 downto 0);
        o_bytes_transmitted_last_hsec   : OUT STD_LOGIC_VECTOR(31 downto 0);
    
        -- streaming AXI to CMAC
        o_tx_axis_tdata         : OUT STD_LOGIC_VECTOR(511 downto 0);
        o_tx_axis_tkeep         : OUT STD_LOGIC_VECTOR(63 downto 0);
        o_tx_axis_tvalid        : OUT STD_LOGIC;
        o_tx_axis_tlast         : OUT STD_LOGIC;
        o_tx_axis_tuser         : OUT STD_LOGIC;
        i_tx_axis_tready        : in STD_LOGIC;
        
        -- LBUS to CMAC
        o_data_to_transmit      : out t_lbus_sosi;
        i_data_to_transmit_ctl  : in t_lbus_siso
    );
end packet_player;

architecture rtl of packet_player is

signal ethernet_frame_DC_fifo_data      : std_logic_vector(511 downto 0);
signal ethernet_frame_DC_fifo_q         : std_logic_vector(511 downto 0);
signal ethernet_frame_DC_fifo_rd        : std_logic;
signal ethernet_frame_DC_fifo_wr        : std_logic;
signal ethernet_frame_DC_fifo_empty     : std_logic;
signal ethernet_frame_DC_fifo_full      : std_logic;
signal ethernet_frame_DC_fifo_q_valid   : std_logic;
-- signal ethernet_frame_DC_fifo_rd_count  : std_logic_vector(7 downto 0);
-- signal ethernet_frame_DC_fifo_wr_count  : std_logic_vector(7 downto 0);
signal ethernet_frame_DC_fifo_rd_count  : std_logic_vector(8 downto 0);
signal ethernet_frame_DC_fifo_wr_count  : std_logic_vector(8 downto 0);

signal meta_data_fifo_data              : std_logic_vector(13 downto 0);
signal meta_data_fifo_q                 : std_logic_vector(13 downto 0);
signal meta_data_fifo_rd                : std_logic;
signal meta_data_fifo_wr                : std_logic;
signal meta_data_fifo_empty             : std_logic;
signal meta_data_fifo_full              : std_logic;
signal meta_data_fifo_q_valid           : std_logic;
-- signal meta_data_fifo_rd_count          : std_logic_vector(3 downto 0);
-- signal meta_data_fifo_wr_count          : std_logic_vector(3 downto 0);
signal meta_data_fifo_rd_count          : std_logic_vector(4 downto 0);
signal meta_data_fifo_wr_count          : std_logic_vector(4 downto 0);

signal data_to_transmit_int             : t_lbus_sosi;

signal packet_ready                     : std_logic_vector(4 downto 0);
signal trigger_packet                   : std_logic := '0';
signal streaming                        : std_logic;

signal Bytes_to_stream                  : std_logic_vector(13 downto 0);
signal Bytes_modulo_64                  : std_logic;

signal end_of_packet_quad               : std_logic_vector(3 downto 0);
signal end_of_packet_bytes              : std_logic_vector(3 downto 0);

signal bytes_to_transmit_d1             : STD_LOGIC_VECTOR(13 downto 0); 

signal hold_off                         : std_logic_vector(3 downto 0);

type mac_streaming_statemachine is (IDLE, PREP, DATA, FINISH);
signal mac_streaming_sm : mac_streaming_statemachine;

signal data_wr_d1 : std_logic;
signal data_wr_d2 : std_logic;

signal stats_interval                   : integer := 0;
signal bytes_transmitted_last_hsec      : std_logic_vector(31 downto 0);
signal byte_increment                   : std_logic_vector(31 downto 0);

signal time_between_packets             : std_logic_vector(15 downto 0);
signal time_between_packets_largest     : std_logic_vector(15 downto 0);

type stat_statemachine is (IDLE, CALC);
signal stat_sm : stat_statemachine;

signal sop : std_logic;

signal first_time, compare_vectors, vectors_equal, vectors_not_equal, ethernet_frame_DC_fifo_rd_prev : std_logic;
signal first_packet_golden_data : std_logic_vector(511 downto 0); 

signal tx_axis_tvalid_int               : std_logic;
signal tx_axis_tkeep_int                : STD_LOGIC_VECTOR(63 downto 0);
signal tx_axis_tlast_int                : STD_LOGIC;

signal valid_bytes                      : STD_LOGIC_VECTOR(15 downto 0);
    
COMPONENT ila_0
PORT (
    clk : IN STD_LOGIC;
    probe0 : IN STD_LOGIC_VECTOR(191 DOWNTO 0));
END COMPONENT;


begin


-- notify packet complete to MAC Clock Domain
notify_process : process(i_clk400)
begin
    if rising_edge(i_clk400) then
        if i_reset_400 = '1' then
            packet_ready            <= "00000";
            data_wr_d1              <= '0';
            data_wr_d2              <= '0';
            o_data_to_player_rdy    <= '0';
        else
            data_wr_d1 <= i_data_to_player_wr;
            data_wr_d2 <= data_wr_d1;

            -- Fall edge of packet burst, now trigger 
            if data_wr_d1 = '0' and data_wr_d2 = '1' then
                packet_ready    <= "11111";
            else
                packet_ready    <= packet_ready(3 downto 0) & '0';
            end if;

            -- leading edge of packet, cache the bytes.
            if i_data_to_player_wr = '1' and data_wr_d1 = '0' then
                bytes_to_transmit_d1 <= i_bytes_to_transmit;
            end if;

            if (meta_data_fifo_wr_count(1) = '1') then
                o_data_to_player_rdy <= '0';
            else
                o_data_to_player_rdy <= '1';
            end if;

        end if;
    end if;
end process;




meta_data_fifo_data         <= bytes_to_transmit_d1;
-- only write the bytes at the end, this is used as a trigger
meta_data_fifo_wr           <= (NOT data_wr_d1) AND data_wr_d2;

ethernet_frame_DC_fifo_data <= i_data_to_player;
ethernet_frame_DC_fifo_wr   <= i_data_to_player_wr;     


xpm_cdc_pulse_inst : xpm_cdc_single
    generic map (
        DEST_SYNC_FF    => 4,   
        INIT_SYNC_FF    => 1,   
        SRC_INPUT_REG   => 1,   
        SIM_ASSERT_CHK  => 0    
    )
    port map (
        dest_clk        => i_cmac_clk,   
        dest_out        => trigger_packet,         
        src_clk         => i_clk400,    
        src_in          => packet_ready(4)
    );

---------------------------------------------------------------------------------------------------------------------------------------

meta_data_fifo : entity PSR_Packetiser_lib.xpm_fifo_wrapper
    Generic map (
        FIFO_DEPTH      => 16,
        DATA_WIDTH      => 14
    )
    Port Map ( 
        fifo_reset      => i_reset_400,
        -- RD    
        fifo_rd_clk     => i_cmac_clk,
        fifo_rd         => meta_data_fifo_rd,
        fifo_q          => meta_data_fifo_q,
        fifo_q_valid    => meta_data_fifo_q_valid,
        fifo_empty      => meta_data_fifo_empty,
        fifo_rd_count   => meta_data_fifo_rd_count,
        -- WR        
        fifo_wr_clk     => i_clk400,
        fifo_wr         => meta_data_fifo_wr,
        fifo_data       => meta_data_fifo_data,
        fifo_full       => meta_data_fifo_full,
        fifo_wr_count   => meta_data_fifo_wr_count
    );
    
-- first word fall through FIFO
-- Also to cross the clock domain.
-- contains the full packet, header + data.

ethernet_frame_DC_fifo : entity PSR_Packetiser_lib.xpm_fifo_wrapper
    Generic map (
        FIFO_DEPTH      => PLAYER_CDC_FIFO_DEPTH,
        DATA_WIDTH      => 512
    )
    Port Map ( 
        fifo_reset      => i_reset_400,
        -- RD    
        fifo_rd_clk     => i_cmac_clk,
        fifo_rd         => ethernet_frame_DC_fifo_rd,
        fifo_q          => ethernet_frame_DC_fifo_q,
        fifo_q_valid    => ethernet_frame_DC_fifo_q_valid,
        fifo_empty      => ethernet_frame_DC_fifo_empty,
        fifo_rd_count   => ethernet_frame_DC_fifo_rd_count,
        -- WR        
        fifo_wr_clk     => i_clk400,
        fifo_wr         => ethernet_frame_DC_fifo_wr,
        fifo_data       => ethernet_frame_DC_fifo_data,
        fifo_full       => ethernet_frame_DC_fifo_full,
        fifo_wr_count   => ethernet_frame_DC_fifo_wr_count
    );
    

---------------------------------------------
-- stream packet out to mac interface
LBUS_GEN : IF LBUS_TO_CMAC_INUSE GENERATE
    o_data_to_transmit              <= data_to_transmit_int;
    
    data_to_transmit_int.data       <= ethernet_frame_DC_fifo_q;
    data_to_transmit_int.valid(0)   <= i_data_to_transmit_ctl.ready AND streaming;
    
    data_to_transmit_int.valid(1)   <= (data_to_transmit_int.eop(1) or data_to_transmit_int.eop(2) or data_to_transmit_int.eop(3)) AND data_to_transmit_int.valid(0) when mac_streaming_sm = FINISH
                                       else data_to_transmit_int.valid(0);
    data_to_transmit_int.valid(2)   <= (data_to_transmit_int.eop(2) or data_to_transmit_int.eop(3)) AND data_to_transmit_int.valid(0) when mac_streaming_sm = FINISH
                                       else data_to_transmit_int.valid(0);
    data_to_transmit_int.valid(3)   <= (data_to_transmit_int.eop(3)) AND data_to_transmit_int.valid(0) when mac_streaming_sm = FINISH
                                       else data_to_transmit_int.valid(0);
    
    data_to_transmit_int.error      <= "0000";
    
    ethernet_frame_DC_fifo_rd       <= data_to_transmit_int.valid(0);
    
    --t_lbus_sosi IS RECORD  -- Source Out and Sink In
    --data       : STD_LOGIC_VECTOR(c_lbus_data_w-1 DOWNTO 0);     
    --valid      : STD_LOGIC_VECTOR(c_lbus_data_w/c_segment_w-1 DOWNTO 0);    -- Data segment enable
    --eop        : STD_LOGIC_VECTOR(c_lbus_data_w/c_segment_w-1 DOWNTO 0);    -- End of packet
    --sop        : STD_LOGIC_VECTOR(c_lbus_data_w/c_segment_w-1 DOWNTO 0);    -- Start of packet
    --error      : STD_LOGIC_VECTOR(c_lbus_data_w/c_segment_w-1 DOWNTO 0);    -- Error flag, indicates data has an error
    --empty
    --i_data_to_transmit_ctl.ready
    --i_data_to_transmit_ctl.overflow   .. only use if trying to write while ready is de-asserted.
    --i_data_to_transmit_ctl.underflow
END GENERATE;
    
STREAMING_GEN : IF (NOT LBUS_TO_CMAC_INUSE) GENERATE
    -- streaming AXI to CMAC
    o_tx_axis_tdata             <= ethernet_frame_DC_fifo_q;
    o_tx_axis_tkeep             <= tx_axis_tkeep_int;
    
    o_tx_axis_tlast             <= tx_axis_tlast_int;
    
    o_tx_axis_tuser             <= '0';     -- always good packet being sent.

    tx_axis_tvalid_int          <= i_tx_axis_tready AND streaming;
    ethernet_frame_DC_fifo_rd   <= tx_axis_tvalid_int;
--    i_tx_axis_tready        : in STD_LOGIC;

    o_tx_axis_tvalid            <= tx_axis_tvalid_int;
    
END GENERATE;


max_tx_proc : process(i_cmac_clk)
begin
    if rising_edge(i_cmac_clk) then
    
        if i_cmac_clk_rst = '1' then
            streaming                       <= '0';
            mac_streaming_sm                <= IDLE;

            data_to_transmit_int.sop        <= "0000";
            data_to_transmit_int.eop        <= "0000";
            -- EMPTY flag indicates how many INVALID bytes in that segment and is literal.
            data_to_transmit_int.empty(0)   <= x"0";
            data_to_transmit_int.empty(1)   <= x"0";
            data_to_transmit_int.empty(2)   <= x"0";
            data_to_transmit_int.empty(3)   <= x"0";
            hold_off                        <= x"0";
            meta_data_fifo_rd               <= '0';
            end_of_packet_quad              <= x"0";
            
            tx_axis_tlast_int               <= '0';
            tx_axis_tkeep_int               <= x"0000000000000000";     -- always sending all 16 bytes.
        else
        
            case mac_streaming_sm is
                when IDLE => 
                    if meta_data_fifo_empty = '0' then
                        mac_streaming_sm    <= PREP;
                        
                        Bytes_to_stream     <= meta_data_fifo_q;
                        Bytes_modulo_64     <= meta_data_fifo_q(5) or meta_data_fifo_q(4) or meta_data_fifo_q(3) or meta_data_fifo_q(2) or meta_data_fifo_q(1) or meta_data_fifo_q(0);
                    end if;
                    
                    streaming                       <= '0';
                    data_to_transmit_int.empty(0)   <= x"0";
                    data_to_transmit_int.empty(1)   <= x"0";
                    data_to_transmit_int.empty(2)   <= x"0";
                    data_to_transmit_int.empty(3)   <= x"0"; 
                    hold_off                        <= x"0";
                    
                
                when PREP =>
                    -- LBUS End of Packet, every 16 there is a jump to new 128 quad
                    -- evauate which 128 bit quad the work will end in
                    if Bytes_modulo_64 = '0' then
                        end_of_packet_quad  <= "1000";
                    elsif Bytes_to_stream(5 downto 4) = "00" then
                        end_of_packet_quad  <= "0001";
                    elsif Bytes_to_stream(5 downto 4) = "01" then
                        end_of_packet_quad  <= "0010";
                    elsif Bytes_to_stream(5 downto 4) = "10" then
                        end_of_packet_quad  <= "0100";
                    else
                        end_of_packet_quad  <= "1000";
                    end if;
                    -- evauate how many invalid bytes    
                    end_of_packet_bytes <= std_logic_vector(16 - unsigned(Bytes_to_stream(3 downto 0)));

                    data_to_transmit_int.sop        <= "0001";
                    data_to_transmit_int.eop        <= "0000";
                    
                    tx_axis_tkeep_int               <= x"FFFFFFFFFFFFFFFF";     -- always sending all 16 bytes.
                   
                    if Bytes_to_stream(3 downto 0) = x"0" then
                        valid_bytes <=  x"FFFF";
                    elsif Bytes_to_stream(3 downto 0) = x"1" then
                        valid_bytes <=  x"0001";
                    elsif Bytes_to_stream(3 downto 0) = x"2" then
                        valid_bytes <=  x"0003";
                    elsif Bytes_to_stream(3 downto 0) = x"3" then
                        valid_bytes <=  x"0007";
                    elsif Bytes_to_stream(3 downto 0) = x"4" then
                        valid_bytes <=  x"000F";
                    elsif Bytes_to_stream(3 downto 0) = x"5" then
                        valid_bytes <=  x"001F";
                    elsif Bytes_to_stream(3 downto 0) = x"6" then
                        valid_bytes <=  x"003F";
                    elsif Bytes_to_stream(3 downto 0) = x"7" then
                        valid_bytes <=  x"007F";
                    elsif Bytes_to_stream(3 downto 0) = x"8" then
                        valid_bytes <=  x"00FF";
                    elsif Bytes_to_stream(3 downto 0) = x"9" then
                        valid_bytes <=  x"01FF";
                    elsif Bytes_to_stream(3 downto 0) = x"A" then
                        valid_bytes <=  x"03FF";
                    elsif Bytes_to_stream(3 downto 0) = x"B" then
                        valid_bytes <=  x"07FF";
                    elsif Bytes_to_stream(3 downto 0) = x"C" then
                        valid_bytes <=  x"0FFF";
                    elsif Bytes_to_stream(3 downto 0) = x"D" then
                        valid_bytes <=  x"1FFF";
                    elsif Bytes_to_stream(3 downto 0) = x"E" then
                        valid_bytes <=  x"3FFF";
                    elsif Bytes_to_stream(3 downto 0) = x"F" then
                        valid_bytes <=  x"7FFF";           
                    end if;
                    
                    streaming           <= '1';
                    mac_streaming_sm    <= DATA;
                                    
                when DATA =>
                    -- need to check this for modulo 64 byte packet lengths and add logic.
                    if Bytes_to_stream(13 downto 6) = x"01" and ethernet_frame_DC_fifo_rd = '1' then

                        data_to_transmit_int.eop            <= end_of_packet_quad;
                        tx_axis_tlast_int                   <= '1';
                        
                        if end_of_packet_quad(0) = '1' then
                            data_to_transmit_int.empty(0)   <= end_of_packet_bytes;
                            tx_axis_tkeep_int               <= x"000000000000" & valid_bytes;
                        elsif end_of_packet_quad(1) = '1' then
                            data_to_transmit_int.empty(1)   <= end_of_packet_bytes;
                            tx_axis_tkeep_int               <= x"00000000" & valid_bytes & x"FFFF";
                        elsif end_of_packet_quad(2) = '1' then
                            data_to_transmit_int.empty(2)   <= end_of_packet_bytes;
                            tx_axis_tkeep_int               <= x"0000" & valid_bytes & x"FFFFFFFF";
                        else
                            data_to_transmit_int.empty(3)   <= end_of_packet_bytes;
                            tx_axis_tkeep_int               <= valid_bytes & x"FFFFFFFFFFFF";
                        end if;    
                        
                        mac_streaming_sm                    <= FINISH;   
                        -- advance
                        meta_data_fifo_rd                   <= '1';
                        Bytes_to_stream                     <= std_logic_vector(unsigned(Bytes_to_stream) - 64);                     
                    elsif ethernet_frame_DC_fifo_rd = '1' then
                        data_to_transmit_int.sop            <= "0000";
                        Bytes_to_stream                     <= std_logic_vector(unsigned(Bytes_to_stream) - 64);

                    end if;
                    
                when FINISH =>
                    meta_data_fifo_rd                   <= '0';
                    
                    if streaming = '0' then
                        hold_off                            <= std_logic_vector(unsigned(hold_off) + 1);
                    end if;
                    
                    if hold_off(1) = '1' then
                        mac_streaming_sm                <= IDLE;
                    end if;
                        
                    if ethernet_frame_DC_fifo_rd = '1' then
                        streaming                       <= '0';
                        data_to_transmit_int.eop        <= x"0";
                        data_to_transmit_int.empty(0)   <= x"0";
                        data_to_transmit_int.empty(1)   <= x"0";
                        data_to_transmit_int.empty(2)   <= x"0";
                        data_to_transmit_int.empty(3)   <= x"0"; 
                        
                        tx_axis_tlast_int               <= '0';
                        tx_axis_tkeep_int               <= x"0000000000000000";  
                    end if;
                    
                when others => mac_streaming_sm <= IDLE;
            end case;

        end if;
    end if;
end process;


debug_gen : IF g_DEBUG_ILA GENERATE
-----------------------------------------------------------------------------------------------------

    -- Capture read transactions from the fifo
    u_cmac_fifo_rd_ila : ila_0
    port map (
        clk => i_cmac_clk,
        probe0(31 downto 0) => first_packet_golden_data(31 downto 0),
        probe0(63 downto 32) => ethernet_frame_DC_fifo_q(31 downto 0),
        probe0(64) => ethernet_frame_DC_fifo_rd, 
        probe0(65) => vectors_equal, 
        probe0(66) => vectors_not_equal, 
        probe0(67) => compare_vectors,
        probe0(68) => first_time, 
        probe0(69) => sop,
        probe0(70) => ethernet_frame_DC_fifo_empty,
        probe0(79 downto 71) => ethernet_frame_DC_fifo_rd_count, 
        probe0(80) => ethernet_frame_DC_fifo_q_valid,
        --probe0(84 downto 81) => data_to_transmit_int.sop,  
        
        probe0(94 downto 81)    => Bytes_to_stream,
        probe0(95)              => streaming,
        probe0(99 downto 96)    => hold_off,
        probe0(103 DOWNTO 100)  => data_to_transmit_int.eop,
        probe0(104)              => i_data_to_transmit_ctl.ready,
        probe0(105)              => i_data_to_transmit_ctl.overflow,
        probe0(106)              => i_data_to_transmit_ctl.underflow,
        
        probe0(110 DOWNTO 107)  => data_to_transmit_int.empty(0),
        probe0(114 DOWNTO 111)  => data_to_transmit_int.empty(1), 
        probe0(118 DOWNTO 115)  => data_to_transmit_int.empty(2),  
        probe0(122 DOWNTO 119)  => data_to_transmit_int.empty(3),                   
        probe0(191 downto 123)  => (others =>'0')
    );


    -- Capture wr transactions into the fifo
    u_cmac_fifo_wr_ila : ila_0
    port map (
        clk => i_clk400,
        probe0(31 downto 0)         => ethernet_frame_DC_fifo_data(31 downto 0),
        probe0(63 downto 32)        => (others=>'0'),
        probe0(64)                  => ethernet_frame_DC_fifo_wr, 
        probe0(65)                  => ethernet_frame_DC_fifo_full, 
        probe0(66)                  => ethernet_frame_DC_fifo_empty,
        probe0(75 downto 67)        => ethernet_frame_DC_fifo_wr_count, 
        probe0(191 downto 76)       => (others =>'0')
    );

END GENERATE;

end rtl;