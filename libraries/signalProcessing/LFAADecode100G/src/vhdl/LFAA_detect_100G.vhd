----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey
-- 
-- Create Date: 23.04.2019 22:26:05
-- Module Name: LFAAProcess - Behavioral
-- Project Name: Perentie
-- Description: 
--  Takes in LFAA data from the 100GE interface, decodes it, finds the matching virtual channel,
-- and outputs the packet to downstream modules.
-- 
-- The input bus is 512 bits wide, with a 322 MHz clock.
-- The output bus is 512 bits wide, on the 300 MHz clock - the same clock as is used for the external memory.
-- 512 bits x 300 MHz = 153 Gbit/sec.
-- Packets have a data part of 8192 bytes, so at 512 bits wide (=64 bytes) there are
-- 128 clocks for the data part.
-- Note : 64 bytes = 16 dual-pol samples. 
--
--
--  Sample data captured from 100G core :
--
-- TRIGGER, eth100_rx_sosi[data][511:0],                                                         eth100_rx_sosi[valid][3:0],eth100_rx_sosi[eop][3:0],eth100_rx_sosi[error][3:0], empty][0][3:0],[empty][1][3:0], [empty][2][3:0], [empty][3][3:0], sop][3:0]
--trigger                data                                                                                                          valid eop error empty0 empty1 empty2 empty 3  sop
-- 0,00000000000000000000000000000000 0002d552767d20500000000000000000 20642e8640004011d7ec0a0a00010a0a 506b4b603020506b4bc40ed008004500, 0,  0,    0,   0,      0,     0,     0,     1,
-- 1,000880010069000006b9800400000000 0002d552767d205038ab530402060000 20642e8640004011d7ec0a0a00010a0a 506b4b603020506b4bc40ed008004500, f,  0,    0,   0,      0,     0,     0,     1,
-- 0,00000000000000000000000000000000 00aab001010100020100b30000000000 00009011000007ea8ed4b00000000001 0000902700005e6f53e596000000b583, 0,  0,    0,   0,      0,     0,     0,     0,
-- 0,00000000000000000000000000000000 00aab001010100020100b30000000000 00009011000007ea8ed4b00000000001 0000902700005e6f53e596000000b583, f,  0,    0,   0,      0,     0,     0,     0,
-- 0,00000000000000000000000000000000 00000000000000000000000000000000 00000000000000000000000000000000 00000000000000000000000000000000, f,  0,    0,   0,      0,     0,     0,     0,
--
-- In this example, we have:
--  - destination MAC Address = 0x506b4b603020
--  - Source MAC Address      = 0x506b4bc40ed0
--  - ethertype               = 0x0800          (=IPv4)
--  - IPv4 header:
--      - first 2 bytes = 0x4500
--      - total Length  = 0x2064  (= 8292 = [8192 data bytes] + [72 bytes SPEAD header] + [20 bytes IPv4 header] + [8 bytes UDP header])
--   etc.
--  The total number of bytes before the data starts = 6+6+2+20+8+72 = 114.
--  Since 114 = 7*16 + 2, there are 8 x 128-bit segments in the header, with the data part starting at byte 3 in the 8th segment.
----------------------------------------------------------------------------------

library IEEE, axi4_lib, xpm, LFAADecode100G_lib, ctc_lib, dsp_top_lib;
library technology_lib;
USE technology_lib.tech_mac_100g_pkg.ALL;
use DSP_top_lib.DSP_top_pkg.all;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use axi4_lib.axi4_stream_pkg.ALL;
use axi4_lib.axi4_lite_pkg.ALL;
use xpm.vcomponents.all;
use LFAADecode100G_lib.LFAADecode100G_lfaadecode100g_reg_pkg.ALL;

entity LFAA_detect_100G is
    port(
        -- Data in from the 100GE MAC        
        -- LBUS interface
        i_eth100_rx_sosi        : in t_lbus_sosi;

        -- Stream AXI interface to 100G CMAC
        i_RX_100G_m_axis_tdata  : in STD_LOGIC_VECTOR ( 511 downto 0 );
        i_RX_100G_m_axis_tkeep  : in STD_LOGIC_VECTOR ( 63 downto 0 );
        i_RX_100G_m_axis_tlast  : in STD_LOGIC;
        i_RX_100G_m_axis_tvalid : in STD_LOGIC;
        i_RX_100G_m_axis_tready : out STD_LOGIC;

        i_data_clk              : in std_logic;     -- 322 MHz for 100GE MAC
        i_data_rst              : in std_logic;
        ----------------------------------------------------------------------------------
        -- Data out to the 3 pipelines
        bufWE               : out std_logic_vector(0 downto 0);
        bufWrCount          : out std_logic_vector(9 downto 0);
        bufDin              : out std_logic_vector(511 downto 0);
        bufWrAddr           : out std_logic_vector(8 downto 0);
        bufRdAddr           : out std_logic_vector(8 downto 0);
        bufDout             : out std_logic_vector(511 downto 0);
        bufDinErr           : out std_logic := '0';
        bufDinEOP           : out std_logic := '0';
        bufDinGoodLength    : out std_logic := '0';
        -----------------------------------------------------------------------------------
        -- miscellaneous

        -- debug
        o_dbg              : out std_logic_vector(13 downto 0)
    );
end LFAA_detect_100G;

architecture Behavioral of LFAA_detect_100G is

    -- Define a type to match fields in the data coming in
    constant fieldsToMatch : natural := 30;
    
    type t_field_match is record
        wordCount  : std_logic_vector(2 downto 0); -- which 128-bit word (= LBUS "segment") the field should match to. This will always be in the first 8 128-bit words.
        byteOffset : natural; -- where in the 128-bit word the relevant bits should sit
        bytes      : natural;  -- How many bits we are checking
        expected   : std_logic_vector(47 downto 0); -- Value we expect for a valid SPEAD packet
        check      : std_logic;   -- Whether we should check against the expected value or not
    end record;
    
    type t_field_values is array(0 to (fieldsToMatch-1)) of std_logic_vector(47 downto 0);
    type t_field_match_loc_array is array(0 to (fieldsToMatch-1)) of t_field_match;

    -- Alignments - Data in can start in any of 4 different 128 bit segments.
    -- An initial alignment shifts packets so that all packets have an alignment of 0.
    --  IPv4 header will have an offset of +14 bytes (assuming 2 bytes for ethertype)
    --  UDP header will have an offset of +34 bytes (2*16+2)
    --  SPEAD header will have an offset of +42 bytes (2*16+10) 
    --  Data part will have an offset of +114 bytes   (7*16 + 2)
    --  The data is 8192 bytes = 512 * 16, so the total number of words is 520, with only 2 bytes valid in the final word. 
    -- Note all SPEAD IDs listed in the comments below exclude the msb, which is '1' ( = immediate) for all except for sample_offset (SPEAD ID 0x3300)
    --
    -- A note on byte order from the 40GE core -
    --  Bytes are sent so that the first byte in the ethernet frame is bits(7:0), second byte is bits(15:8) etc.
    -- So e.g. for a first data word with bits(127:0) = 0x00450008201D574B6B50FFEEDDCCBBAA, we have
    --  destination MAC address = AA:BB:CC:DD:EE:FF
    --  Source MAC address = 50:6B:4B:57:1D:20
    --  Ethertype = "0800"
    --  IPv4 header byte 0 = 0x45
    --  IPv4 DSCP/ECN field = 0x0
    
    -- Total header is 114 bytes, so fits in the first two 512 bit words.
    constant c_fieldmatch_loc : t_field_match_loc_array := 
        ((wordCount => "000", byteOffset => 0, bytes => 6,  expected => x"000000000000", check => '0'), -- 0. Destination MAC address, first 6 bytes of the frame.
         (wordCount => "000", byteOffset => 12, bytes => 2, expected => x"000000000800", check => '1'), -- 1. Ethertype field at byte 12 should be 0x0800 for IPv4 packets
         (wordCount => "000", byteOffset => 14, bytes => 1, expected => x"000000000045", check => '1'), -- 2. Version and header length fields of the IPv4 header, at byte 14. should be x45.
         (wordCount => "001", byteOffset => 0, bytes => 2,  expected => x"000000002064", check => '1'), -- 3. Total Length from the IPv4 header. Should be 20 (IPv4) + 8 (UDP) + 72 (SPEAD) + 8192 (Data) = 8292 = x2064
         (wordCount => "001", byteOffset => 7, bytes=> 1,   expected => x"000000000011", check => '1'), -- 4. Protocol field from the IPv4 header, Should be 0x11 (UDP).
         (wordCount => "010", byteOffset => 4, bytes => 2,  expected => x"000000000000", check => '0'), -- 5. Destination UDP port - expected value to be configured via MACE
         (wordCount => "010", byteOffset => 6, bytes => 2,  expected => x"000000002050", check => '1'), -- 6. UDP length. Should be 8 (UDP) + 72 (SPEAD) + 8192 (Data) = x2050
         (wordCount => "010", byteOffset => 10, bytes => 2, expected => x"000000005304", check => '1'), -- 7. First 2 bytes of the SPEAD header, should be 0x53 ("MAGIC"), 0x04 ("Version")
         (wordCount => "010", byteOffset => 12, bytes => 2, expected => x"000000000206", check => '1'), -- 8. Bytes 3 and 4 of the SPEAD header, should be 0x02 ("ItemPointerWidth"), 0x06 ("HeapAddrWidht")
         (wordCount => "011", byteOffset => 0, bytes => 2,  expected => x"000000000008", check => '1'), -- 9. Bytes 7 and 8 of the SPEAD header, should be 0x00 and 0x08 ("Number of Items")
         (wordCount => "011", byteOffset => 2, bytes => 2,  expected => x"000000008001", check => '1'), -- 10. SPEAD ID 0x0001 = "heap_counter" field, should be 0x8001.
         (wordCount => "011", byteOffset => 4, bytes => 2,  expected => x"000000000000", check => '0'), -- 11. Logical Channel ID
         (wordCount => "011", byteOffset => 6, bytes => 4,  expected => x"000000000000", check => '0'), -- 12. Packet Counter 
         (wordCount => "011", byteOffset => 10, bytes => 2, expected => x"000000008004", check => '1'), -- 13. SPEAD ID 0x0004 = "pkt_len" (data for this SPEAD ID is ignored)
         (wordCount => "100", byteOffset => 2, bytes => 2,  expected => x"000000009027", check => '1'), -- 14. SPEAD ID 0x1027 = "sync_time"
         (wordCount => "100", byteOffset => 4, bytes => 6,  expected => x"000000000000", check => '0'),    -- 15. sync time in seconds from UNIX epoch
         (wordCount => "100", byteOffset => 10, bytes => 2, expected => x"000000009600", check => '1'), -- 16. SPEAD ID 0x1600 = timestamp, time in nanoseconds after "sync_time"
         (wordCount => "100", byteOffset => 12, bytes => 4, expected => x"000000000000", check => '0'),    -- 17. first 4 bytes of timestamp
         (wordCount => "101", byteoffset => 0, bytes => 2,  expected => x"000000000000", check => '0'),    -- 18. Last 2 bytes of the timestamp
         (wordCount => "101", byteoffset => 2, bytes => 2,  expected => x"000000009011", check => '1'), -- 19. SPEAD ID 0x1011 = center_freq
         (wordCount => "101", byteoffset => 4, bytes => 6,  expected => x"000000000000", check => '0'),     -- 20. center_frequency in Hz
         (wordCount => "101", byteoffset => 10, bytes => 2, expected => x"00000000b000", check => '1'), -- 21. SPEAD ID 0x3000 = csp_channel_info
         (wordCount => "101", byteoffset => 14, bytes => 2, expected => x"000000000000", check => '0'),    -- 22. beam_id
         (wordCount => "110", byteoffset => 0, bytes => 2,  expected => x"000000000000", check => '0'),    -- 23. frequency_id
         (wordCount => "110", byteoffset => 2, bytes => 2,  expected => x"00000000b001", check => '1'), -- 24. SPEAD ID 0x3001 = csp_antenna_info
         (wordCount => "110", byteoffset => 4, bytes => 1,  expected => x"000000000000", check => '0'),    -- 25. substation_id
         (wordCount => "110", byteoffset => 5, bytes => 1,  expected => x"000000000000", check => '0'),    -- 26. subarray_id
         (wordCount => "110", byteoffset => 6, bytes => 2,  expected => x"000000000000", check => '0'),    -- 27. station_id
         (wordCount => "110", byteoffset => 8, bytes => 2,  expected => x"000000000000", check => '0'),    -- 28. nof_contributing_antennas
         (wordCount => "110", byteoffset => 10, bytes => 2, expected => x"000000003300", check => '0')  -- 29. SPEAD ID 0x3300 = sample_offset. top bit is not set since this is "indirect" even though it is a null pointer.
    );
    
    -- For data coming in, capture the following fields to registers, and use them to look up the virtual channel from the table in the registers.
    --  - frequency_id, 9 bits, SPEAD ID 0x3000
    --  - beam_id, 4 bits, SPEAD ID 0x3000
    --  - substation_id, 3 bits, SPEAD ID 0x3001
    --  - subarray_id, 5 bits, SPEAD ID 0x3001
    --  - station_id, 10 bits, SPEAD ID 0x3001
    constant c_frequency_id_index : natural := 23;  -- 23rd field in c_fieldmatch_loc
    constant c_beam_id_index : natural := 22;
    constant c_substation_id_index : natural := 25;
    constant c_subarray_id_index : natural := 26;
    constant c_station_id_index : natural := 27;
    constant c_packet_counter : natural := 12;
    
    constant c_SPEAD_logical_channel : natural := 11;
    constant c_nof_antennas : natural := 28;
    constant c_timestamp_high : natural := 17;  -- 4 high bytes
    constant c_timestamp_low : natural := 18;   -- 2 low bytes
    constant c_sync_time : natural := 15; -- sync time, 6 bytes.
    
    --signal expectedValues : t_field_values;  -- some expected values are constants drawn from c_fieldmatch_loc.expected, others are set via MACE.
    signal actualValues : t_field_values;
    signal fieldMatch : std_logic_vector(29 downto 0) := (others => '1');
    signal allFieldsMatch : std_logic := '0';
    
    signal dataSeg0Del : std_logic_vector(63 downto 0);
    signal dataSeg1Del : std_logic_vector(63 downto 0);
    signal dataAligned : std_logic_vector(511 downto 0);
    signal dataAlignedValid : std_logic;
    --signal dataAlignedmty : std_logic_vector(3 downto 0) := "0000";
    signal dataAlignedEOP : std_logic := '0';
    
    signal rxActive : std_logic := '0';  -- we are receiving a frame.
    signal rxCount : std_logic_vector(9 downto 0) := (others => '0'); -- which 128 bit word we are up to.
    signal dataAlignedCount : std_logic_vector(9 downto 0) := (others => '0');
    signal rxAlign : std_logic_vector(1 downto 0) := "00"; 
    
    signal txCount : std_logic_vector(8 downto 0) := (others => '0');
    type t_tx_fsm is (idle, send_data, next_buffer, send_wait);
    signal tx_fsm, tx_fsm_del1, tx_fsm_del2 : t_tx_fsm := idle;
    type t_rx_fsm is (idle, frame_start, start_lookup, wait_lookup, set_header, wait_done);
    signal rx_fsm : t_rx_fsm := idle;
    type t_stats_fsm is (idle, wait_good_packet, get_packet_count, check_packet_count, rd_out_of_order_count0, rd_out_of_order_count1, rd_out_of_order_count2, wr_out_of_order_count, wr_packet_count, wr_channel, wr_UNIXTime, wr_timestampLow, wr_timestampHigh, wr_synctimeLow, wr_synctimeHigh);
    signal stats_fsm : t_stats_fsm := idle;
    
    signal HdrBuf0 : t_ctc_input_header;
    signal HdrBuf1 : t_ctc_input_header;
    signal HdrBuf2 : t_ctc_input_header;
    signal HdrBuf3 : t_ctc_input_header;
    
    signal data_out_int : std_logic_vector(127 downto 0);
    signal valid_out_int : std_logic;
    
    signal wrBufSel : std_logic_vector(1 downto 0) := "00";
    signal rdBufSel : std_logic_vector(1 downto 0) := "00";
    signal rxSOP : std_logic := '0';
    signal dataAligned2byte : std_logic_vector(15 downto 0);
    signal dataAlignedErr : std_logic;
    
    --signal bufWE : std_logic_vector(0 downto 0);
    --signal bufWrCount : std_logic_vector(9 downto 0);
    --signal bufDin : std_logic_vector(511 downto 0);
    --signal bufWrAddr, bufRdAddr : std_logic_vector(8 downto 0);
    --signal bufDout : std_logic_vector(511 downto 0);
    --signal bufDinErr : std_logic := '0';
    --signal bufDinEOP : std_logic := '0';
    --signal bufDinGoodLength : std_logic := '0';
    
    signal searchAddr, searchAddrDel1, searchAddrDel2 : std_logic_vector(15 downto 0);
    signal searchRunning, searchRunningDel1, searchRunningDel2, searchRunningDel3 : std_logic;
    
    signal VirtualChannel : std_logic_vector(9 downto 0);
    signal searchDone : std_logic;
    signal NoMatch : std_logic;
    signal VirtualSearch : std_logic_vector(31 downto 0);
    
    signal badEthPacket, nonSPEADPacket, badIPUDPPacket, goodPacket, noVirtualChannel : std_logic := '0';
    
    signal statsAddr : std_logic_vector(12 downto 0);
    signal statsBaseAddr : std_logic_Vector(12 downto 0);
    signal virtualChannelx8 : std_logic_vector(12 downto 0);  -- 8 x 32bit entries in the stats ram in the registers per virtual channel.
    signal statsWrData, statsNewPacketCount : std_logic_vector(31 downto 0) := x"00000000";
    signal statsNOFAntennas, statsSPEADLogicalChannel : std_logic_vector(15 downto 0);
    signal packetCountOutOfOrder : std_logic := '0';
    signal oldPacketCount : std_logic_vector(31 downto 0);
    signal oldOutOfOrderCount : std_logic_vector(3 downto 0);
    signal statsWE : std_logic := '0';
    
    signal dataAlignedSOP : std_logic := '0';
    signal statsSOPTime : std_logic_vector(63 downto 0);
    signal SOPTime : std_logic_vector(63 downto 0);
    signal tx_fsm_dbg, stats_fsm_dbg, rx_fsm_dbg : std_logic_vector(3 downto 0);
    signal goodPacket_dbg : std_logic;
    signal nonSPEADPacket_dbg : std_logic;
    signal VCTable_rd_data_del1 : std_logic_vector(31 downto 0);
    signal rxAlignOld : std_logic_vector(1 downto 0) := "00";
    signal statsTimestamp, statsSyncTime : std_logic_vector(47 downto 0);
    signal bufDin_LE : std_logic_vector(511 downto 0);

    signal dataDel : t_lbus_sosi;
    signal VCTableStationID : std_logic_vector(9 downto 0);
    signal VCTableFrequencyID : std_logic_vector(8 downto 0);
    signal searchMax, searchMin, searchInterval : std_logic_vector(15 downto 0);
    signal upperIntervalCenter, lowerIntervalCenter : std_logic_vector(15 downto 0);
    type lookup_fsm_type is (search_failure, search_success, check_rd_data, wait_rd3, wait_rd2, wait_rd1, start, idle);
    signal lookup_fsm : lookup_fsm_type;
    signal VCTableMatch : std_logic;
    signal stationID_gt_table, stationID_eq_table, frequencyID_gt_table : std_logic;
    signal packetStationID : std_logic_vector(9 downto 0);
    signal packetFrequencyID : std_logic_vector(8 downto 0);
    signal wdFIFO_empty : std_logic;
    signal wdFIFO_full : std_logic;
    signal wdFIFO_wrRst : std_logic;
    signal wdFIFO_rdDataCount : std_logic_vector(5 downto 0);
    signal wdFIFO_rdEn : std_logic;
    signal wrBufSelDel1 : std_logic_vector(1 downto 0) := "00";
    signal bufUsed : std_logic_vector(3 downto 0) := "0000";
    signal wdFIFO_wrDataCount : std_logic_vector(5 downto 0);
    signal wdFIFO_wrEn : std_logic;
    signal wdataCount : std_logic_vector(2 downto 0) := "000";
    signal ap_clk_rst : std_logic := '0';
    
    signal headerValid : std_logic;
    signal headerVirtualChannel : std_logic_vector(15 downto 0);
    signal headerPacketCount : std_logic_vector(31 downto 0);
    signal hdrCDC_dest_out : std_logic_vector(47 downto 0) := (others => '0');
    signal hdrCDC_src_send : std_logic := '0';
    signal hdrCDC_src_in : std_logic_vector(47 downto 0) := (others => '0');
    signal hdrCDC_src_rcv : std_logic := '0';
    signal totalVirtualChannels : std_logic_vector(15 downto 0);
    signal frequencyID_eq_table : std_logic := '0';
    
    signal eth100_rx_sosi   : t_lbus_sosi;
    
    component ila_beamData
    port (
        clk : in std_logic;
        probe0 : in std_logic_vector(119 downto 0)); 
    end component;
    
begin
    
    o_dbg <= nonSPEADPacket_dbg & goodPacket_dbg & rx_fsm_dbg & stats_fsm_dbg & tx_fsm_dbg;
   
    -- For data coming in from the 40G MAC, the only fields that are used are
    --  data_rx_sosi.tdata
    --  data_rx_sosi.tuser
    --  data_rx_sosi.tvalid
    -- segment 0 relates to data_rx_sosi.tdata(63:0)
    
    --  TYPE t_lbus_sosi IS RECORD  -- Source Out and Sink In
    --   data       : STD_LOGIC_VECTOR(511 DOWNTO 0);                -- Data bus
    --   valid      : STD_LOGIC_VECTOR(3 DOWNTO 0);    -- Data segment enable
    --   eop        : STD_LOGIC_VECTOR(3 DOWNTO 0);    -- End of packet
    --   sop        : STD_LOGIC_VECTOR(3 DOWNTO 0);    -- Start of packet
    --   error      : STD_LOGIC_VECTOR(3 DOWNTO 0);    -- Error flag, indicates data has an error
    --   empty      : t_empty_arr(c_lbus_data_w/c_segment_w-1 DOWNTO 0);         -- Number of bytes empty in the segment
    -- i_eth100_rx_sosi   : in t_lbus_sosi;
    
    ------------------------------------------------------------------------------
    -- Capture and validate all the packet headers (MAC, IPv4, UDP, SPEAD)
    ------------------------------------------------------------------------------
    -- These fields go direct to the output packet header:
    --  - channel frequency. 9 bit value. Sky frequency = channel frequency * 781.25 hKHz = frequency_id as above (i.e. from SPEAD ID 0x3000)
    --  - station_id - 1, (Subtract 1 from station_id so it becomes a 9 bit value)
    --  - Packet count, from SPEAD ID 0x1
    
    
    totalVirtualChannels <= i_reg_rw.total_channels;
    
    process(i_data_clk, i_data_rst)
        variable allFieldsMatchv : std_logic := '0';
    begin
        
        eth100_rx_sosi <= i_eth100_rx_sosi;
        
        if i_data_rst = '1' then
            wrBufSel <= "00";
            rx_fsm <= idle;
        elsif rising_edge(i_data_clk) then
            -- Align the input so that start of packet is always in the first 128 bits
            if eth100_rx_sosi.valid(0) = '1' then -- if any segments are valid, then segment 0 must be valid.
                dataDel <= eth100_rx_sosi;
            end if;
            -- find where the start of packet occurs. If there is more than one start of packet, take the last one, 
            -- since the others must be short packets.
            if eth100_rx_sosi.sop(3) = '1' and eth100_rx_sosi.valid(3) = '1' then
                rxCount <= (others => '0'); -- which 512 bit word we are up to.
                rxAlign <= "11";   -- Start of packet occurred on segment 3.
                rxSOP <= '1';
            elsif eth100_rx_sosi.sop(2) = '1' and eth100_rx_sosi.valid(2) = '1' then
                rxCount <= (others => '0'); -- which 512 bit word we are up to.
                rxAlign <= "10";   -- Start of packet occurred on segment 2.
                rxSOP <= '1';
            elsif eth100_rx_sosi.sop(1) = '1' and eth100_rx_sosi.valid(1) = '1' then
                rxCount <= (others => '0'); -- which 512 bit word we are up to.
                rxAlign <= "01";   -- Start of packet occurred on segment 1.
                rxSOP <= '1';
            elsif eth100_rx_sosi.sop(0) = '1' and eth100_rx_sosi.valid(0) = '1' then
                rxCount <= (others => '0');
                rxAlign <= "00";   -- start of packet occurred on segment 0 
                rxSOP <= '1';
            elsif eth100_rx_sosi.valid(0) = '1' then
                rxCount <= std_logic_vector(unsigned(rxCount) + 1);
                rxSOP <= '0';
            else
                rxSOP <= '0';
            end if;
            
            -- Next pipeline stage; build the 64 byte data, aligned with the sof at byte 0. 
            -- Since dataDel is only loaded when valid = '1', we only
            -- need to check eth100_rx_sosi.valid and start of frame to determine when dataAligned is valid.
            -- dataAligned is only used to capture the header information. 
            -- dataAligned has the first byte in bits 511:504, 2nd byte in bits 503:496, etc.
            if rxAlign = "00" then
                dataAligned <= dataDel.data(127 downto 0) & dataDel.data(255 downto 128) & dataDel.data(383 downto 256) & dataDel.data(511 downto 384);
                dataAlignedValid <= dataDel.valid(0);
                if dataDel.eop(0) = '1' then -- dataAlignedmty = empty for the whole 16 bytes
                    dataAlignedEOP <= '1';
                    dataAlignedErr <= dataDel.error(0);
                elsif dataDel.eop(1) = '1' then
                    dataAlignedEOP <= '1';
                    dataAlignedErr <= dataDel.error(1);
                elsif dataDel.eop(2) = '1' then
                    dataAlignedEOP <= '1';
                    dataAlignedErr <= dataDel.error(2);    
                elsif dataDel.eop(3) = '1' then
                    dataAlignedEOP <= '1';
                    dataAlignedErr <= dataDel.error(3);
                else
                    dataAlignedEOP <= '0';
                    dataAlignedErr <= '0';
                end if;
            elsif rxAlign = "01" then
                dataAligned <= dataDel.data(255 downto 128) & dataDel.data(383 downto 256) & dataDel.data(511 downto 384) & eth100_rx_sosi.data(127 downto 0);
                dataAlignedValid <= dataDel.valid(1);
                if dataDel.eop(1) = '1' then -- dataAlignedmty = empty for the whole 16 bytes
                    dataAlignedEOP <= '1';
                    dataAlignedErr <= dataDel.error(1);
                elsif dataDel.eop(2) = '1' then
                    dataAlignedEOP <= '1';
                    dataAlignedErr <= dataDel.error(2);
                elsif dataDel.eop(3) = '1' then
                    dataAlignedEOP <= '1';
                    dataAlignedErr <= dataDel.error(3);    
                elsif eth100_rx_sosi.eop(0) = '1' then
                    dataAlignedEOP <= '1';
                    dataAlignedErr <= eth100_rx_sosi.error(0);
                else
                    dataAlignedEOP <= '0';
                    dataAlignedErr <= '0';
                end if;
            elsif rxAlign = "10" then
                dataAligned <= dataDel.data(383 downto 256) & dataDel.data(511 downto 384) & eth100_rx_sosi.data(127 downto 0) & eth100_rx_sosi.data(255 downto 128);
                dataAlignedValid <= dataDel.valid(2);
                if dataDel.eop(2) = '1' then -- dataAlignedmty = empty for the whole 16 bytes
                    dataAlignedEOP <= '1';
                    dataAlignedErr <= dataDel.error(2);
                elsif dataDel.eop(3) = '1' then
                    dataAlignedEOP <= '1';
                    dataAlignedErr <= dataDel.error(3);
                elsif eth100_rx_sosi.eop(0) = '1' then
                    dataAlignedEOP <= '1';
                    dataAlignedErr <= eth100_rx_sosi.error(0);    
                elsif eth100_rx_sosi.eop(1) = '1' then
                    dataAlignedEOP <= '1';
                    dataAlignedErr <= eth100_rx_sosi.error(1);
                else
                    dataAlignedEOP <= '0';
                    dataAlignedErr <= '0';
                end if;
            else -- rxAlign = "11"
                dataAligned <= dataDel.data(511 downto 384) & eth100_rx_sosi.data(127 downto 0) & eth100_rx_sosi.data(255 downto 128)  & eth100_rx_sosi.data(383 downto 256);
                dataAlignedValid <= dataDel.valid(3);
                if dataDel.eop(3) = '1' then -- dataAlignedmty = empty for the whole 16 bytes
                    dataAlignedEOP <= '1';
                    dataAlignedErr <= dataDel.error(3);
                elsif eth100_rx_sosi.eop(0) = '1' then
                    dataAlignedEOP <= '1';
                    dataAlignedErr <= eth100_rx_sosi.error(0);
                elsif eth100_rx_sosi.eop(1) = '1' then
                    dataAlignedEOP <= '1';
                    dataAlignedErr <= eth100_rx_sosi.error(1);    
                elsif eth100_rx_sosi.eop(2) = '1' then
                    dataAlignedEOP <= '1';
                    dataAlignedErr <= eth100_rx_sosi.error(2);
                else
                    dataAlignedEOP <= '0';
                    dataAlignedErr <= '0';
                end if;
            end if;
            dataAlignedSOP <= rxSOP;
            dataAlignedCount <= rxCount;
            
            
            -- Data portion of the packet is written to the buffer, with an appropriate alignment for the data.
            -- Note that, if the first 128 bit segment is segment 1, then packet data starts in the 3rd byte of the 8th segment.
            -- This arranges the bytes so that the first byte of data is in bufDin(511:504), second byte in bufDin(503:496) etc to the 64th byte of data in bufDin(7:0)
            if (((unsigned(rxCount) = 1) and eth100_rx_sosi.valid(0) = '1' and rxAlign = "00") or
                ((unsigned(rxCount) > 1) and eth100_rx_sosi.valid(0) = '1' and rxAlignOld = "00")) then
                -- Counting 128 bit segments from 1, then, for rxCount = 1,
                -- dataDel           contains segments 5, 6, 7, 8
                -- eth100_rx_sosi  contains segments 9, 10, 11, 12
                bufDin <= dataDel.data(495 downto 384) & eth100_rx_sosi.data(127 downto 0) & eth100_rx_sosi.data(255 downto 128) & eth100_rx_sosi.data(383 downto 256) & eth100_rx_sosi.data(511 downto 496);
                bufWE(0) <= '1';
                if (unsigned(rxCount) = 1) then
                    bufWrCount <= (others => '0');
                    rxAlignOld <= rxAlign;
                else
                    bufWrCount <= std_logic_vector(unsigned(bufWrCount) + 1);
                end if;
                if (dataDel.eop(3) = '1' or eth100_rx_sosi.eop(0) = '1' or eth100_rx_sosi.eop(1) = '1' or eth100_rx_sosi.eop(2) = '1' or eth100_rx_sosi.eop(3) = '1') then
                    bufDinEOP <= '1';
                    bufDinErr <= dataDel.error(3) or eth100_rx_sosi.error(0) or eth100_rx_sosi.error(1) or eth100_rx_sosi.error(2) or eth100_rx_sosi.error(3);
                    if ((unsigned(bufWrCount) = 126) and eth100_rx_sosi.eop(3) = '1' and eth100_rx_sosi.empty(3) = "1110") then
                        bufDinGoodLength <= '1'; -- bufWrCount will be 127 in the next cycle; 128 x 512 bit words = 128 x 64 bytes = 8192 bytes = the full data part of the packet.
                    else
                        bufDinGoodLength <= '0';
                    end if;
                else
                    bufDinEOP <= '0';
                    bufDinErr <= '0';
                    bufDinGoodLength <= '0';
                end if;
            elsif (((unsigned(rxCount) = 2) and eth100_rx_sosi.valid(0) = '1' and rxAlign = "01") or
                   ((unsigned(rxCount) > 2) and eth100_rx_sosi.valid(0) = '1' and rxAlignOld = "01")) then
                -- Counting 128 bit segments from 1, then when rxCount = 2, previous cycles included segments [1,2,3], [4,5,6,7]
                -- dataDel           contains segments 8, 9, 10, 11
                -- eth100_rx_sosi  contains segments 12, 13, 14, 15
                bufDin <= dataDel.data(111 downto 0) & dataDel.data(255 downto 128) & dataDel.data(383 downto 256) & dataDel.data(511 downto 384) & eth100_rx_sosi.data(127 downto 112);
                bufWE(0) <= '1';
                if (unsigned(rxCount) = 2) then
                    bufWrCount <= (others => '0');
                    rxAlignOld <= rxAlign;
                else
                    bufWrCount <= std_logic_vector(unsigned(bufWrCount) + 1);
                end if;
                if (dataDel.eop(0) = '1' or dataDel.eop(1) = '1' or dataDel.eop(2) = '1' or dataDel.eop(3) = '1' or eth100_rx_sosi.eop(0) = '1') then
                    bufDinEOP <= '1';
                    bufDinErr <= dataDel.error(0) or dataDel.error(1) or dataDel.error(2) or dataDel.error(3) or eth100_rx_sosi.error(0);
                    if ((unsigned(bufWrCount) = 126) and eth100_rx_sosi.eop(0) = '1' and eth100_rx_sosi.empty(0) = "1110") then
                        bufDinGoodLength <= '1'; -- bufWrCount will be 127 in the next cycle; 128 x 512 bit words = 128 x 64 bytes = 8192 bytes = the full data part of the packet.
                    else
                        bufDinGoodLength <= '0';
                    end if;
                else
                    bufDinEOP <= '0';
                    bufDinErr <= '0';
                    bufDinGoodLength <= '0';
                end if;
            elsif (((unsigned(rxCount) = 2) and eth100_rx_sosi.valid(0) = '1' and rxAlign = "10") or
                   ((unsigned(rxCount) > 2) and eth100_rx_sosi.valid(0) = '1' and rxAlignOld = "10")) then
                -- Counting 128 bit segments from 1, then (rxCount = 2, so previous segments were [1, 2], [3, 4, 5, 6])
                -- dataDel           contains segments 7, 8, 9, 10
                -- eth100_rx_sosi  contains segments 11, 12, 13, 14
                bufDin <= dataDel.data(239 downto 128) & dataDel.data(383 downto 256) & dataDel.data(511 downto 384) & eth100_rx_sosi.data(127 downto 0) & eth100_rx_sosi.data(255 downto 240);
                bufWE(0) <= '1';
                if (unsigned(rxCount) = 2) then
                    bufWrCount <= (others => '0');
                    rxAlignOld <= rxAlign;
                else
                    bufWrCount <= std_logic_vector(unsigned(bufWrCount) + 1);
                end if;
                if (dataDel.eop(1) = '1' or dataDel.eop(2) = '1' or dataDel.eop(3) = '1' or eth100_rx_sosi.eop(0) = '1' or eth100_rx_sosi.eop(1) = '1') then
                    bufDinEOP <= '1';
                    bufDinErr <= dataDel.error(1) or dataDel.error(2) or dataDel.error(3) or eth100_rx_sosi.error(0) or eth100_rx_sosi.error(1);
                    if ((unsigned(bufWrCount) = 126) and eth100_rx_sosi.eop(1) = '1' and eth100_rx_sosi.empty(1) = "1110") then
                        bufDinGoodLength <= '1'; -- bufWrCount will be 127 in the next cycle; 128 x 512 bit words = 128 x 64 bytes = 8192 bytes = the full data part of the packet.
                    else
                        bufDinGoodLength <= '0';
                    end if;
                else
                    bufDinEOP <= '0';
                    bufDinErr <= '0';
                    bufDinGoodLength <= '0';
                end if;
            elsif (((unsigned(rxCount) = 2) and eth100_rx_sosi.valid(0) = '1' and rxAlign = "11") or 
                   ((unsigned(rxCount) > 2) and eth100_rx_sosi.valid(0) = '1' and rxAlignOld = "11")) then
                -- Counting 128 bit segments from 1, then (rxCount = 2, so previous segments were [1], [2, 3, 4, 5]
                -- dataDel           contains segments 6, 7, 8, 9
                -- eth100_rx_sosi  contains segments 10, 11, 12, 13
                bufDin <= dataDel.data(367 downto 256) & dataDel.data(511 downto 384) & eth100_rx_sosi.data(127 downto 0) & eth100_rx_sosi.data(255 downto 128) & eth100_rx_sosi.data(383 downto 368);
                bufWE(0) <= '1';
                if (unsigned(rxCount) = 2) then
                    bufWrCount <= (others => '0');
                    rxAlignOld <= rxAlign;
                else
                    bufWrCount <= std_logic_vector(unsigned(bufWrCount) + 1);
                end if;
                if (dataDel.eop(2) = '1' or dataDel.eop(3) = '1' or eth100_rx_sosi.eop(0) = '1' or eth100_rx_sosi.eop(1) = '1' or eth100_rx_sosi.eop(2) = '1') then
                    bufDinEOP <= '1';
                    bufDinErr <= dataDel.error(2) or dataDel.error(3) or eth100_rx_sosi.error(0) or eth100_rx_sosi.error(1) or eth100_rx_sosi.error(2);
                    if ((unsigned(bufWrCount) = 126) and eth100_rx_sosi.eop(2) = '1' and eth100_rx_sosi.empty(2) = "1110") then
                        bufDinGoodLength <= '1'; -- bufWrCount will be 127 in the next cycle; 128 x 512 bit words = 128 x 64 bytes = 8192 bytes = the full data part of the packet.
                    else
                        bufDinGoodLength <= '0';
                    end if;
                else
                    bufDinEOP <= '0';
                    bufDinErr <= '0';
                    bufDinGoodLength <= '0';
                end if;
            else
                bufWE(0) <= '0';
                bufDinEOP <= '0';
                bufDinErr <= '0';
                bufDinGoodLength <= '0';
            end if;
            
            ------------------------------------------------------------------------------------------------
            -- Capture all the relevant fields in the headers 
            -- Example entry in c_fieldmatch_loc
            --   (wordCount => "000", byteOffset => 12, bytes => 2, expected => x"000000000800", check => '1')
            -- wordCount is in units of 128 bits. dataAligned is 512 bits. So wordCount(1:0) is the 128 bit word within dataAligned.
            for i in 0 to (fieldsToMatch-1) loop
                if ((dataAlignedCount(9 downto 1) = "000000000") and 
                    (dataAlignedCount(0) = c_fieldmatch_loc(i).wordcount(2)) and 
                    (dataAlignedValid = '1')) then
                    -- Copy the bytes into the actualValues array
                    for j in 0 to (c_fieldmatch_loc(i).bytes-1) loop
                        actualValues(i)(((j+1) * 8 - 1) downto (j*8)) <=
                            dataAligned( 512 - (to_integer(unsigned(c_fieldmatch_loc(i).wordCount(1 downto 0))) * 128 + c_fieldmatch_loc(i).byteOffset * 8 + c_fieldmatch_loc(i).bytes * 8) + (j+1)*8-1 downto
                                         512 - (to_integer(unsigned(c_fieldmatch_loc(i).wordCount(1 downto 0))) * 128 + c_fieldmatch_loc(i).byteOffset * 8 + c_fieldmatch_loc(i).bytes * 8) + j*8);
                    end loop;
                end if;
            end loop;
            
            if dataAlignedSOP = '1' then
                SOPTime <= i_wallTime;
            end if;
            
            ------------------------------------------------------------------------------------------------
            -- Check all the relevant fields in the headers
            for i in 0 to (fieldsToMatch-1) loop
                if c_fieldmatch_loc(i).check = '1' then
                    if (actualValues(i)((c_fieldmatch_loc(i).bytes*8 - 1) downto 0) = c_fieldmatch_loc(i).expected((c_fieldmatch_loc(i).bytes*8 - 1) downto 0)) then
                        fieldMatch(i) <= '1';
                    else
                        fieldMatch(i) <= '0';
                    end if;
                else
                    fieldMatch(i) <= '1';
                end if;
            end loop;
            
            allFieldsMatchv := '1';
            for i in 0 to (fieldsToMatch-1) loop
                if fieldMatch(i) = '0' then
                    allFieldsMatchv := '0';
                end if;
            end loop;
            allFieldsMatch <= allFieldsMatchv;
            

    
end Behavioral;

