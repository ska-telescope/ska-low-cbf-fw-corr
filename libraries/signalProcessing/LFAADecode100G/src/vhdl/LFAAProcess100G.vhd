----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey
-- 
-- Create Date: 23.04.2019 22:26:05
-- Module Name: LFAAProcess - Behavioral
-- Project Name: Perentie
-- Description: 
--  Takes in LFAA data from the 40GE interface, decodes it, finds the matching virtual channel,
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
--use ctc_lib.ctc_pkg.all;
use DSP_top_lib.DSP_top_pkg.all;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use axi4_lib.axi4_stream_pkg.ALL;
use axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.ALL;
use xpm.vcomponents.all;
use LFAADecode100G_lib.LFAADecode100G_lfaadecode100g_reg_pkg.ALL;

entity LFAAProcess100G is
    port(
        -- Data in from the 100GE MAC        
        -- 4 parallel segments of 128 bits each
        --  TYPE t_lbus_sosi IS RECORD  -- Source Out and Sink In
        --   data       : STD_LOGIC_VECTOR(511 DOWNTO 0);                -- Data bus
        --   valid      : STD_LOGIC_VECTOR(3 DOWNTO 0);    -- Data segment enable
        --   eop        : STD_LOGIC_VECTOR(3 DOWNTO 0);    -- End of packet
        --   sop        : STD_LOGIC_VECTOR(3 DOWNTO 0);    -- Start of packet
        --   error      : STD_LOGIC_VECTOR(3 DOWNTO 0);    -- Error flag, indicates data has an error
        --   empty      : t_empty_arr(c_lbus_data_w/c_segment_w-1 DOWNTO 0);         -- Number of bytes empty in the segment
        i_eth100_rx_sosi   : in t_lbus_sosi;
        i_data_clk         : in std_logic;     -- 322 MHz for 100GE MAC
        i_data_rst         : in std_logic;
        ----------------------------------------------------------------------------------
        -- Data out to the memory interface; This is the wdata portion of the AXI full bus.
        i_ap_clk        : in  std_logic;  -- Shared memory clock used to access the HBM.
        o_axi_w         : out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0)) => o_m01_axi_w,    -- w data bus (.wvalid, .wdata, .wlast)
        i_axi_wready    : in std_logic;
        -- Only the header data goes to the corner turn. Uses the shared memory clock (i_ap_clk)
        o_virtualChannel : out std_logic_vector(15 downto 0); -- Single number which incorporates both the channel and station.
        o_packetCount    : out std_logic_vector(31 downto 0);
        o_valid          : out std_logic;
        -----------------------------------------------------------------------------------
        -- miscellaneous
        i_my_mac           : in std_logic_vector(47 downto 0); -- MAC address for this board; incoming packets from the 100GE interface are filtered using this.
        i_wallTime         : in std_logic_vector(63 downto 0); -- 64 bit time in units of nanoseconds. 
        --i_time_sec         : in std_logic_vector(31 downto 0); -- Current time in this clock domain; 32 bit second count
        --i_time_frac        : in std_logic_vector(26 downto 0); -- Count in units of 8ns; only use 64 ns steps (drop the low 3 bits in this module) 
        -- Interface to the registers
        i_reg_rw           : in t_statctrl_rw;
        o_reg_count        : out t_statctrl_count;
        -- Virtual channel table memory in the registers
        o_searchAddr       : out std_logic_vector(11 downto 0); -- read address to the VCTable_ram in the registers.
        i_VCTable_rd_data  : in std_logic_vector(31 downto 0); -- read data from VCTable_ram in the registers; assumed valid 2 clocks after searchAddr.
        -- Virtual channel stats in the registers.
        o_statsWrData      : out std_logic_vector(31 downto 0);
        o_statsWE          : out std_logic;
        o_statsAddr        : out std_logic_vector(12 downto 0);  -- 8 words of info per virtual channel, 768 virtual channels, 8*768 = 6144 deep.
        i_statsRdData      : in std_logic_vector(31 downto 0);
        -- debug
        o_dbg              : out std_logic_vector(13 downto 0)
    );
end LFAAProcess100G;

architecture Behavioral of LFAAProcess100G is

    -- relevant fields extracted from the .tuser field of the input data_rx_sosi (which comes from the 40GE MAC)
    -- data_rx_sosi.tuser has two sets of these groups of signals, one data_rx_sosi.tdata(63:0), and one for data_rx_sosi.tdata(127:64) 
    type t_tuser_segment is record
        ena : std_logic;
        sop : std_logic;
        eop : std_logic;
        mty : std_logic_vector(3 downto 0);
        err : std_logic;
    end record;
    
    signal tuserSeg0, tuserSeg1, tuserSeg0Del, tuserSeg1Del : t_tuser_segment;
    
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
    
    signal actualValues : t_field_values;
    signal fieldMatch : std_logic_vector(29 downto 0) := (others => '1');
    signal allFieldsMatch : std_logic := '0';
    
    signal dataSeg0Del : std_logic_vector(63 downto 0);
    signal dataSeg1Del : std_logic_vector(63 downto 0);
    signal dataAligned : std_logic_vector(511 downto 0);
    signal dataAlignedValid : std_logic;
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
    
    signal bufWE : std_logic_vector(0 downto 0);
    signal bufWrCount : std_logic_vector(9 downto 0);
    signal bufDin : std_logic_vector(511 downto 0);
    signal bufWrAddr, bufRdAddr : std_logic_vector(8 downto 0);
    signal data_clk_vec : std_logic_vector(0 downto 0);
    signal bufDout : std_logic_vector(511 downto 0);
    signal bufDinErr : std_logic := '0';
    signal bufDinEOP : std_logic := '0';
    signal bufDinGoodLength : std_logic := '0';
    
    signal searchAddr, searchAddrDel1, searchAddrDel2 : std_logic_vector(15 downto 0);
    signal searchRunning, searchRunningDel1, searchRunningDel2, searchRunningDel3 : std_logic;
    
    signal VirtualChannel : std_logic_vector(10 downto 0);
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
    signal searchMax, searchMin, searchInterval : std_logic_vector(15 downto 0);
    signal upperIntervalCenter, lowerIntervalCenter : std_logic_vector(15 downto 0);
    type lookup_fsm_type is (search_failure, search_success, wait_rd_VC1, wait_rd_VC2, wait_rd_VC3, check_rd_data, wait_rd3, wait_rd2, wait_rd1, start, idle);
    signal lookup_fsm : lookup_fsm_type;
    signal VCTableMatch : std_logic;
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
    signal packet_gt_table : std_logic := '0';
    
    signal eth100_rx_sosi   : t_lbus_sosi;
    signal tableSelect : std_logic := '0';
    
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
            
            -----------------------------------------------------------------------------------------------
            -- Once we have captured the header information, trigger searching of the virtual channel table
            -- Since we only have 128 clocks to search the virtual channel table, a binary search is used.
            -- Entries in the virtual channel table are sorted by station and channel
            -- Start the search in the middle of the table, then search the middle of the higher or lower interval
            -- until the interval has a size of 1. This means we find the matching entry (if it exists) with
            -- log2(i_totalVirtualChannels) reads from the table.
            if rx_fsm = start_lookup then
                lookup_fsm <= start;
                searchDone <= '0';
                searchRunning <= '1';
            else
                case lookup_fsm is
                    when idle =>
                        if rx_fsm = start_lookup then
                            lookup_fsm <= start;
                        else
                            lookup_fsm <= idle;
                        end if;
                        -- update in the idle state so the table is consistent while searching it.
                        tableSelect <= i_reg_rw.table_select;
                        searchRunning <= '0';
                    
                    when start =>
                        virtualChannel <= (others => '1');
                        searchDone <= '0';
                        NoMatch <= '0';
                        searchRunning <= '1';
                        searchMin <= (others => '0');
                        searchMax <= std_logic_vector(unsigned(totalVirtualChannels) - 1);
                        searchAddr <= "000000" & totalVirtualChannels(10 downto 1);
                        lookup_fsm <= wait_rd1;
     
                    when wait_rd1 =>  -- "seachAddr", the address to the virtual channel table in the registers, is valid in this state.
                        searchInterval <= std_logic_vector(unsigned(searchMax) - unsigned(searchMin));
                        lookup_fsm <= wait_rd2;
                    
                    when wait_rd2 => -- vc table data arrives in this state
                        lookup_fsm <= wait_rd3;
                    
                    when wait_rd3 => -- vctable_rd_data_del1 valid
                        lookup_fsm <= check_rd_data;
                        
                    when check_rd_data => -- packet_gt_table is valid in this state.
                        if (VCTableMatch = '1') then  -- found a matching entry
                            lookup_fsm <= search_success;
                        elsif (unsigned(searchInterval) = 0) then
                            lookup_fsm <= search_failure; -- search interval is size 0, but no match, so there is no matching entry in the table.
                        else
                            -- virtual channels are sorted according to the values in the table;
                            -- The values in the table are made up of :                       
                            --
                            -- bits 2:0   = substation_id
                            -- bits 12:3  = station_id,
                            -- bits 16:13 = beam_id,
                            -- bits 25:17 = frequency_id
                            -- bits 30:26 = subarray_id
                            -- bit  31    = set to '1' to indicate this entry is invalid
                            --
                            -- The values in the table must be sorted by the table contents, so e.g :
                            -- for two frequencies of 100 and 101, and 3 stations of 5,10 and 12, the order will be
                            --  0 - station 5, channel 100 \
                            --  1 - station 10, channel 100 \
                            --  2 - station 12, channel 100 \
                            --  3 - station 5, channel 101 \
                            --  4 - station 10, channel 101 \
                            --  5 - station 12, channel 101 \ 
                            -- 
                            -- Searching the table works by binary search, i.e. halving the search interval at each step,    
                            -- using the fact that the table is sorted.
                            -- 
                            if packet_gt_table = '1' then
                                -- try the upper half of the current interval
                                searchMin <= std_logic_vector(unsigned(searchAddr) + 1);
                                searchMax <= searchMax;
                                searchAddr <= "000000" & upperIntervalCenter(10 downto 1); -- = (searchAddr + 1 + searchMax) / 2
                            else
                                -- try the lower half of the current interval
                                searchMin <= searchMin;
                                searchMax <= std_logic_vector(unsigned(searchAddr) - 1);
                                searchAddr <= "000000" & lowerIntervalCenter(10 downto 1); -- = (searchMin + searchAddr - 1) / 2
                            end if;
                            lookup_fsm <= wait_rd1;
                        end if;
                    
                    when search_success =>
                        lookup_fsm <= wait_rd_VC1;
                        
                    when wait_rd_VC1 =>
                        lookup_fsm <= wait_rd_VC2;
                        
                    when wait_rd_VC2 =>
                        lookup_fsm <= wait_rd_VC3;
                        
                    when wait_rd_VC3 =>
                        -- The virtual channel to be assigned to this packet is read from the second word in the virtual channel table.
                        virtualChannel <= i_VCTable_rd_data(9 downto 0); 
                        searchDone <= '1';
                        NoMatch <= '0';
                        lookup_fsm <= idle;
                    
                    when search_failure =>
                        searchDone <= '1';
                        NoMatch <= '1';
                        lookup_fsm <= idle;

                    when others =>
                        lookup_fsm <= idle;
                end case;
            end if;
            
            VCTable_rd_data_del1 <= i_VCTable_rd_data;
            
            if (VCTable_rd_data_del1 = VirtualSearch) then
                VCTableMatch <= '1';
            else
                VCTableMatch <= '0';
            end if;
            
            if (unsigned(VirtualSearch) > unsigned(VCTable_rd_data_del1)) then
                packet_gt_table <= '1';  -- current packet being examined is further on in the table than the table value just read.
            else
                packet_gt_table <= '0';
            end if;
            
            ------------------------------------------------------------------------------------------------
            -- Packet Ingest FSM
            case rx_fsm is
                when idle =>
                    badEthPacket <= '0';   -- When the ethernet interface reports an error
                    nonSPEADPacket <= '0'; -- No errors, but either the wrong length, or not SPEAD
                    badIPUDPPacket <= '0'; -- Error in the UDP or IP headers
                    goodPacket <= '0';     -- Good SPEAD packet
                    noVirtualChannel <= '0'; -- Didn't find a matching virtual channel
                    rx_fsm_dbg <= "0000";
                    if dataAlignedSOP = '1' then
                        rx_fsm <= frame_start;
                    end if;
                    
                when frame_start =>
                    rx_fsm_dbg <= "0001";
                    goodPacket <= '0';
                    badEthPacket <= '0';
                    badIPUDPPacket <= '0';
                    -- Wait until we have captured all the header information, then start the lookup process
                    if dataAlignedEOP = '1' and dataAlignedSOP = '0' then
                        rx_fsm <= idle;
                        nonSPEADPacket <= '1';
                    elsif dataAlignedCount(9 downto 0) = "0000001010" and dataAlignedValid = '1' then
                        -- Waiting until dataAlignedCount is 10 ensures that the stats_fsm state machine from the previous packet is finished. 
                        rx_fsm <= start_lookup;
                        nonSPEADPacket <= '0';
                    else
                        nonSPEADPacket <= '0';
                    end if;
                    
                when start_lookup =>
                    rx_fsm_dbg <= "0010";
                    goodPacket <= '0';
                    badIPUDPPacket <= '0';
                    if dataAlignedSOP = '1' then
                        rx_fsm <= frame_start;
                        nonSPEADPacket <= '1';
                        badEthPacket <= '0';
                    elsif dataAlignedEOP = '1' then
                        rx_fsm <= idle;
                        if dataAlignedErr = '1' then
                            badEthPacket <= '1';
                            nonSPEADPacket <= '0';
                        else
                            nonSPEADPacket <= '1';
                            badEthPacket <= '0';
                        end if;
                    else
                        nonSPEADPacket <= '0';
                        badEthPacket <= '0';
                        rx_fsm <= wait_lookup;
                    end if;
                
                when wait_lookup =>
                    rx_fsm_dbg <= "0011";
                    goodPacket <= '0';
                    badIPUDPPacket <= '0';
                    if dataAlignedSOP = '1' then
                        rx_fsm <= frame_start;
                        badEthPacket <= '0';
                        nonSPEADPacket <= '1';
                    elsif dataAlignedEOP = '1' then
                        rx_fsm <= idle;
                        if dataAlignedErr = '1' then
                            badEthPacket <= '1';
                            nonSPEADPacket <= '0';
                        else
                            nonSPEADPacket <= '1';
                            badEthPacket <= '0';
                        end if;
                        noVirtualChannel <= '0';
                    elsif searchDone = '1' then
                        if NoMatch = '1' then
                            rx_fsm <= idle;
                            noVirtualChannel <= '1';
                            nonSPEADPacket <= '0';
                        elsif allFieldsMatch = '0' then
                            rx_fsm <= idle;
                            nonSPEADPacket <= '1';
                            noVirtualChannel <= '0';
                        else
                            nonSPEADPacket <= '0';
                            noVirtualChannel <= '0';
                            rx_fsm <= set_header;
                        end if;
                    end if;
                
                when set_header =>
                    rx_fsm_dbg <= "0100";
                    goodPacket <= '0';
                    badIPUDPPacket <= '0';
                    if dataAlignedSOP = '1' then
                        rx_fsm <= frame_start;
                        nonSPEADPacket <= '1';
                        badEthPacket <= '0';
                    elsif dataAlignedEOP = '1' then
                        rx_fsm <= idle;
                        if dataAlignedErr = '1' then
                            badEthPacket <= '1';
                            nonSPEADPacket <= '0';
                        else
                            nonSPEADPacket <= '1';
                            badEthPacket <= '0';
                        end if;
                    else
                        nonSPEADPacket <= '0';
                        badEthPacket <= '0';
                        rx_fsm <= wait_done;
                    end if;
                    if wrBufSel = "00" then
                        HdrBuf0.packet_count <= actualValues(c_packet_counter)(31 downto 0);
                        HdrBuf0.virtual_channel <= "000000" & virtualChannel;                -- 16 bits allocated in the header for the virtual channel.
                        HdrBuf0.channel_frequency <= actualValues(c_frequency_id_index)(15 downto 0);
                        HdrBuf0.station_id <= actualValues(c_station_id_index)(15 downto 0);
                    elsif wrBufSel = "01" then
                        HdrBuf1.packet_count <= actualValues(c_packet_counter)(31 downto 0);
                        HdrBuf1.virtual_channel <= "000000" & virtualChannel;
                        HdrBuf1.channel_frequency <= actualValues(c_frequency_id_index)(15 downto 0);
                        HdrBuf1.station_id <= actualValues(c_station_id_index)(15 downto 0);
                    elsif wrBufSel = "10" then
                        HdrBuf2.packet_count <= actualValues(c_packet_counter)(31 downto 0);
                        HdrBuf2.virtual_channel <= "000000" & virtualChannel;
                        HdrBuf2.channel_frequency <= actualValues(c_frequency_id_index)(15 downto 0);
                        HdrBuf2.station_id <= actualValues(c_station_id_index)(15 downto 0);
                    elsif wrBufSel = "11" then
                        HdrBuf3.packet_count <= actualValues(c_packet_counter)(31 downto 0);
                        HdrBuf3.virtual_channel <= "000000" & virtualChannel;
                        HdrBuf3.channel_frequency <= actualValues(c_frequency_id_index)(15 downto 0);
                        HdrBuf3.station_id <= actualValues(c_station_id_index)(15 downto 0);
                    end if;
                    
                when wait_done =>
                    badIPUDPPacket <= '0';
                    rx_fsm_dbg <= "0101";
                    if bufDinEOP = '1' then
                        if (bufDinGoodLength = '1' and bufDinErr = '0') then 
                            -- Good frame received - correct length, no errors.
                            wrBufSel <= std_logic_vector(unsigned(wrBufSel) + 1);
                            goodPacket <= '1';
                            badEthPacket <= '0';
                            nonSPEADPacket <= '0';
                        else
                            goodPacket <= '0';
                            if bufDinErr = '1' then
                                badEthPacket <= '1';
                                nonSPEADPacket <= '0';
                            else
                                nonSPEADPacket <= '1';
                                badEthPacket <= '0';
                            end if;
                        end if;
                        if dataAlignedSOP = '1' then
                            rx_fsm <= frame_start;
                        else
                            rx_fsm <= idle;
                        end if;
                    elsif dataAlignedSOP = '1' then
                        rx_fsm <= frame_start;
                        goodPacket <= '0';
                        badEthPacket <= '0';
                        nonSPEADPacket <= '1';
                    else
                        goodPacket <= '0';
                        badEthPacket <= '0';
                        nonSPEADPacket <= '0';
                    end if;
                
                when others =>
                    rx_fsm <= idle;
            end case;
            
            -- Output the header information to the corner turn, which uses it to generate write addresses to the HBM
            wrBufSelDel1 <= wrBufSel;
            if goodPacket = '1' then  
                headerValid <= '1';
                if wrBufSelDel1 = "00" then
                    headerVirtualChannel <= HdrBuf0.virtual_channel;
                    headerPacketCount <= HdrBuf0.packet_count;
                elsif wrBufSelDel1 = "01" then
                    headerVirtualChannel <= HdrBuf1.virtual_channel;
                    headerPacketCount <= HdrBuf1.packet_count;
                elsif wrBufSelDel1 = "10" then
                    headerVirtualChannel <= HdrBuf2.virtual_channel;
                    headerPacketCount <= HdrBuf2.packet_count;
                else
                    headerVirtualChannel <= HdrBuf3.virtual_channel;
                    headerPacketCount <= HdrBuf3.packet_count;
                end if;
            else
                headerValid <= '0';
            end if;
            
            -------------------------------------------------------------------------------------------------
            -- Channel Statistics FSM
            -- Writes to the VC_stats memory in the registers module.
            -- For each virtual channel and station, the stats memory has
            --   0. channel + nof_contributing antennas,
            --   1. most recent packet count            
            --   2. out of order count, fractional time
            --   3. Unix time
            --
            -- The state machine runs through linearly from "idle" to the end doing the following things
            --  idle               - wait until the search of the virtual channel table completes successfully.
            --  wait_good_packet   - Wait until the end of the ethernet frame so we know that we have received a good packet.
            --  get_packet_count   - read the previous packet count for this virtual channel
            --  check_packet_count - Compare previous with current packet count to see if it is out of order (should be previous value + 1)
            --  rd_out_of_order_count - read old count of out of order packets
            --  rd_out_of_order_count1
            --  rd_out_of_order_count2 - account for read latency of the memory. 
            --  wr_packet_count       - write the most recent packet count (stats memory address = VC*4 + 1)
            --  wr_out_of_order_count - write the new out_of_order_count in bits(7:0), and the fractional time for the packet reception in bits(31:8) (stats memory address = VC*4 + 2)
            --  wr_channel            - write SPEAD logical_channel (bits(15:0)) and SPEAD nof_contributing_antennas (bits(31:16)) (stats memory address = VC*4 + 0)
            --  wr_UNIXTime           - write the UNIX time for the packet reception (stats memory address = VC*4 + 3)
            --  
            case stats_fsm is
                when idle =>
                    stats_fsm_dbg <= "0000";
                    -- in this state, we wait for the lookup of the virtual channel to complete,
                    -- then grab the relevant information and go on to waiting to verify that this is a good SPEAD packet.
                    if rx_fsm = wait_lookup and searchDone = '1' and NoMatch = '0' then
                        stats_fsm <= wait_good_packet;
                        statsBaseAddr <= VirtualChannelx8; -- address to read in the stats memory
                        statsNewPacketCount <= actualValues(c_packet_counter)((c_fieldmatch_loc(c_packet_counter).bytes*8 - 1) downto 0);
                        statsSPEADLogicalChannel <= actualValues(c_SPEAD_logical_channel)((c_fieldmatch_loc(c_SPEAD_logical_channel).bytes*8 - 1) downto 0);
                        statsNOFAntennas <= actualValues(c_nof_antennas)((c_fieldmatch_loc(c_nof_antennas).bytes*8 - 1) downto 0);
                        
                        statsTimestamp(47 downto 16) <= actualValues(c_timestamp_high)(31 downto 0);  -- 4 high bytes
                        statsTimestamp(15 downto 0) <= actualValues(c_timestamp_low)(15 downto 0);     -- 2 low bytes
                        statsSyncTime(47 downto 0) <= actualValues(c_sync_time)(47 downto 0);
                        
                        statsSOPTime <= SOPTime;
                        
                    end if;
                    packetCountOutOfOrder <= '0';
                    statsWE <= '0';
                    
                when wait_good_packet => -- Note that if the packet is good, then this should take at least 10s of clock cycles.
                    stats_fsm_dbg <= "0001";
                    statsAddr <= std_logic_vector(unsigned(statsBaseaddr) + 1);  -- read the most recent packet number for this virtual channel
                    if goodPacket = '1' then
                        stats_fsm <= get_packet_count; 
                    elsif rx_fsm = idle or badEthPacket = '1' or nonSPEADPacket = '1' or badIPUDPPacket = '1' then
                        stats_fsm <= idle;
                    end if;
                   
                when get_packet_count => -- old packet count is in VCstats_ram_out.rd_dat in this state, since statsAddr has been held for many clocks.
                    stats_fsm_dbg <= "0010";
                    stats_fsm <= check_packet_count;
                    oldPacketCount <= i_statsRdData;
                    
                when check_packet_count =>
                    stats_fsm_dbg <= "0011";
                    if statsNewPacketCount /= std_logic_vector(unsigned(oldPacketCount) + 1) then
                        packetCountOutOfOrder <= '1';
                    else
                        packetCountOutOfOrder <= '0';
                    end if;
                    stats_fsm <= rd_out_of_order_count0;
                    statsAddr <= std_logic_vector(unsigned(statsBaseaddr) + 2); -- offset 2 in the 4 stats words per virtual channel = number of out of order packets.
                
                when rd_out_of_order_count0 =>
                    stats_fsm_dbg <= "0100";
                    stats_fsm <= rd_out_of_order_count1;
             
                when rd_out_of_order_count1 =>
                    stats_fsm_dbg <= "0101";
                    stats_fsm <= rd_out_of_order_count2;
                
                when rd_out_of_order_count2 =>
                    stats_fsm_dbg <= "0110";
                    oldOutOfOrderCount <= i_statsRdData(31 downto 28);
                    stats_fsm <= wr_out_of_order_count;

                when wr_out_of_order_count =>   -- out of order count is at address offset 2
                    stats_fsm_dbg <= "0111";
                    stats_fsm <= wr_packet_count;
                    -- statsAddr is unchanged from the read of the out of order count, at <base for this virtual channel>+1
                    statsAddr <= std_logic_vector(unsigned(statsBaseaddr) + 2);
                    if packetCountOutOfOrder = '1' then
                        statsWrData(31 downto 28) <= std_logic_vector(unsigned(oldOutOfOrderCount) + 1);
                    else
                        statsWrData(31 downto 28) <= oldOutOfOrderCount;
                    end if;
                    statsWrData(27 downto 0) <= statsSOPTime(31 downto 4); -- Recorded value is in units of 16 ns
                    statsWE <= '1';
                    
                when wr_packet_count =>   -- packet count is at address offset 1
                    stats_fsm_dbg <= "1000";
                    stats_fsm <= wr_channel;
                    statsAddr <= std_logic_vector(unsigned(statsBaseaddr) + 1);
                    statsWrData <= statsNewPacketCount;
                    statsWE <= '1';
                    
                when wr_channel =>   -- channel is at address offset 0
                    stats_fsm_dbg <= "1001";
                    stats_fsm <= wr_UNIXTime;
                    statsAddr <= statsBaseaddr;
                    statsWrData <= statsNOFAntennas & statsSPEADLogicalChannel;
                    statsWE <= '1';
                
                when wr_UNIXTime =>  -- UNIX time is at address offset 3
                    stats_fsm_dbg <= "1010";
                    stats_fsm <= wr_timestampLow;
                    statsAddr <= std_logic_vector(unsigned(statsBaseaddr) + 3);
                    statsWrData <= statsSOPTime(63 downto 32);
                    statsWE   <= '1';
                
                when wr_timestampLow =>
                    stats_fsm_dbg <= "1011";
                    stats_fsm <= wr_timestampHigh;
                    statsAddr <= std_logic_vector(unsigned(statsBaseaddr) + 4);
                    statsWrData <= statsTimestamp(31 downto 0);
                    statsWE   <= '1';
                
                when wr_timestampHigh =>
                    stats_fsm_dbg <= "1100";
                    stats_fsm <= wr_synctimeLow;
                    statsAddr <= std_logic_vector(unsigned(statsBaseaddr) + 5);
                    statsWrData <= x"0000" & statsTimestamp(47 downto 32);
                    statsWE   <= '1';
                
                when wr_synctimeLow =>
                    stats_fsm_dbg <= "1101";
                    stats_fsm <= wr_synctimeHigh;
                    statsAddr <= std_logic_vector(unsigned(statsBaseaddr) + 6);
                    statsWrData <= statsSyncTime(31 downto 0);
                    statsWE   <= '1';
                
                when wr_synctimeHigh =>
                    stats_fsm_dbg <= "1110";
                    stats_fsm <= idle;
                    statsAddr <= std_logic_vector(unsigned(statsBaseaddr) + 7);
                    statsWrData <= x"0000" & statsSyncTime(47 downto 32);
                    statsWE   <= '1';
                
                when others =>
                    stats_fsm <= idle;
            end case;
            
            
            -------------------------------------------------------------------------------------------------
            -- Packet readout to the FIFO
            -- Note this is only triggered if the input packet was good, so there cannot be errors here.
            
            if goodPacket = '1' and wrBufSelDel1 = "00" then
                bufUsed(0) <= '1';
            elsif tx_fsm = next_buffer and rdBufSel = "00" then
                bufUsed(0) <= '0';
            end if;
            if goodPacket = '1' and wrBufSelDel1 = "01" then
                bufUsed(1) <= '1';
            elsif tx_fsm = next_buffer and rdBufSel = "01" then
                bufUsed(1) <= '0';
            end if;
            if goodPacket = '1' and wrBufSelDel1 = "10" then
                bufUsed(2) <= '1';
            elsif tx_fsm = next_buffer and rdBufSel = "10" then
                bufUsed(2) <= '0';
            end if;
            if goodPacket = '1' and wrBufSelDel1 = "11" then
                bufUsed(3) <= '1';
            elsif tx_fsm = next_buffer and rdBufSel = "11" then
                bufUsed(3) <= '0';
            end if;
            
            case tx_fsm is
                when idle =>
                    tx_fsm_dbg <= "0000";
                    if bufUsed(0) = '1' then 
                        rdBufSel <= "00";
                    elsif bufUsed(1) = '1' then
                        rdBufSel <= "01";
                    elsif bufUsed(2) = '1' then
                        rdBufSel <= "10";
                    elsif bufUsed(3) = '1' then
                        rdBufSel <= "11";
                    end if;
                    if bufUsed /= "0000" then
                        tx_fsm <= send_data;
                    end if;
                    txCount <= (others => '0'); -- Note - 128 transfers in each output packet.
                
                when send_data => -- Copy data from the buffer into the output fifo 
                    tx_fsm_dbg <= "0001";
                    if (unsigned(txCount) = 127) then -- done transfer to the FIFO, go back to idle to wait for the next buffer.
                        tx_fsm <= next_buffer;
                    elsif (unsigned(wdFIFO_wrDataCount) > 15) then
                        tx_fsm <= send_wait;
                    end if;
                    txCount <= std_logic_vector(unsigned(txCount) + 1);
                
                when next_buffer =>
                    -- go to the next buffer, if it is used, otherwise go back to idle
                    tx_fsm_dbg <= "0010";
                    if rdBufSel = "00" and bufUsed(1) = '1' then
                        rdBufSel <= "01";
                        tx_fsm <= send_data;
                    elsif rdBufSel = "01" and bufUsed(2) = '1' then
                        rdBufSel <= "10";
                        tx_fsm <= send_data;
                    elsif rdBufSel = "10" and bufUsed(3) = '1' then
                        rdBufSel <= "11";
                        tx_fsm <= send_data;
                    elsif rdBufSel = "11" and bufUsed(0) = '1' then
                        rdBufSel <= "00";
                        tx_fsm <= send_data;
                    else
                        tx_fsm <= idle;
                    end if;
                    
                when send_wait => -- Output fifo is full, so wait until there is space.
                    tx_fsm_dbg <= "0011";
                    if (unsigned(wdFIFO_wrDataCount) < 16) then
                        tx_fsm <= send_data;
                    end if;
                    
                when others =>
                    tx_fsm <= idle;
            end case;
            
            tx_fsm_del1 <= tx_fsm;
            tx_fsm_del2 <= tx_fsm_del1;
            
            if tx_fsm_del2 = send_data then
                wdFIFO_wrEn <= '1';
            else
                wdFIFO_wrEn <= '0';
            end if;
            
            goodPacket_dbg <= goodPacket;
            nonSPEADPacket_dbg <= nonSPEADPacket;
            
        end if;
    end process;
    
    upperIntervalCenter <= std_logic_vector(unsigned(searchAddr) + unsigned(searchMax) + 1);
    lowerIntervalCenter <= std_logic_vector(unsigned(searchAddr) + unsigned(searchMin) - 1);
    
    -- From the registers yaml file : 
    --  bits 2:0   = substation_id, 
    --  bits 12:3  = station_id,    
    --  bits 16:13 = beam_id, 
    --  bits 25:17 = frequency_id  
    --  bits 30:26 = subarray_id 
    --  bit  31    = set to '1' to indicate this entry is invalid 
    VirtualSearch(2 downto 0) <= actualValues(c_substation_id_index)(2 downto 0);
    VirtualSearch(12 downto 3) <= actualValues(c_station_id_index)(9 downto 0);
    VirtualSearch(16 downto 13) <= actualValues(c_beam_id_index)(3 downto 0);
    VirtualSearch(25 downto 17) <= actualValues(c_frequency_id_index)(8 downto 0);
    VirtualSearch(30 downto 26) <= actualValues(c_subarray_id_index)(4 downto 0);
    VirtualSearch(31) <= '0';
    
    virtualChannelx8 <= virtualChannel(9 downto 0) & "000";
    
    bufWrAddr <= wrBufSel & bufWrCount(6 downto 0); -- Buffer is 512 deep x 64 bytes wide, one packet is 128 deep x 64 wide = 8192 bytes.
    bufRdAddr <= rdBufSel & txCount(6 downto 0);
    
    o_reg_count.spead_packet_count <= goodPacket;
    o_reg_count.nonspead_packet_count <= nonSPEADPacket;
    o_reg_count.badethernetframes <= badEthPacket;
    o_reg_count.badipudpframes <= badIPUDPPacket;
    o_reg_count.novirtualchannelcount <= noVirtualChannel;
    
    -- Search address : 
    --   bit 0 selects either table data or the virtual channel that this table entry will use.
    --   Top bit selects which version of the table to use.
    o_searchAddr(11 downto 1) <= tableSelect & searchAddr(9 downto 0); 
    o_searchAddr(0) <= '1' when lookup_fsm = search_success else '0'; -- Odd indexed words in the virtual channel table are the virtual channel; get the virtual channel after finding a match in the table.
    o_statsAddr <= statsAddr;
    o_statsWE <= statsWE;
    o_statsWrData <= statsWrData;
    -----------------------------------------------------------------------------
    -- Capture the data part of the packet
    ----------------------------------------------------------------------------- 
    -- Data is quad buffered. This is the smallest buffer we can make efficiently, since the minimum depth for a block ram is 512.
    -- Each buffer uses 1/4 of the memory (128 entries). Note 512 x 128 bits = 8192 bytes = data part of an input packet.
    -- xpm_memory_sdpram: Simple Dual Port RAM
    -- Xilinx Parameterized Macro, Version 2017.4
    xpm_memory_sdpram_inst : xpm_memory_sdpram
    generic map (    
        -- Common module generics
        MEMORY_SIZE             => 262144,          -- Total memory size in bits; 512 x 512 = 262144
        MEMORY_PRIMITIVE        => "block",         --string; "auto", "distributed", "block" or "ultra" ;
        CLOCKING_MODE           => "independent_clock", --string; "common_clock", "independent_clock" 
        MEMORY_INIT_FILE        => "none",         --string; "none" or "<filename>.mem" 
        MEMORY_INIT_PARAM       => "",             --string;
        USE_MEM_INIT            => 0,              --integer; 0,1
        WAKEUP_TIME             => "disable_sleep",--string; "disable_sleep" or "use_sleep_pin" 
        MESSAGE_CONTROL         => 0,              --integer; 0,1
        ECC_MODE                => "no_ecc",       --string; "no_ecc", "encode_only", "decode_only" or "both_encode_and_decode" 
        AUTO_SLEEP_TIME         => 0,              --Do not Change
        USE_EMBEDDED_CONSTRAINT => 0,              --integer: 0,1
        MEMORY_OPTIMIZATION     => "true",          --string; "true", "false" 
    
        -- Port A module generics
        WRITE_DATA_WIDTH_A      => 512,             --positive integer
        BYTE_WRITE_WIDTH_A      => 512,             --integer; 8, 9, or WRITE_DATA_WIDTH_A value
        ADDR_WIDTH_A            => 9,              --positive integer
    
        -- Port B module generics
        READ_DATA_WIDTH_B       => 512,            --positive integer
        ADDR_WIDTH_B            => 9,              --positive integer
        READ_RESET_VALUE_B      => "0",            --string
        READ_LATENCY_B          => 3,              --non-negative integer
        WRITE_MODE_B            => "no_change")    --string; "write_first", "read_first", "no_change" 
    port map (
        -- Common module ports
        sleep                   => '0',
        -- Port A (Write side)
        clka                    => i_data_clk,  -- clock from the 100GE core; 322 MHz
        ena                     => '1',
        wea                     => bufWE,
        addra                   => bufWrAddr,
        dina                    => bufDin_LE,
        injectsbiterra          => '0',
        injectdbiterra          => '0',
        -- Port B (read side)
        clkb                    => i_data_clk,  -- This goes to a dual clock fifo to meet the external interface clock to connect to the HBM at 300 MHz.
        rstb                    => '0',
        enb                     => '1',
        regceb                  => '1',
        addrb                   => bufRdAddr,
        doutb                   => bufDout,
        sbiterrb                => open,
        dbiterrb                => open
    );

    -- reorder the input data to be little endian; 
    -- i.e. first byte in bits(7:0), next byte in bits(15:8) etc.
    littleEndianGen : for i in 0 to 63 generate
        bufDin_LE((i*8+7) downto (i*8)) <= bufDin((512 - i*8 - 1) downto (512 - i*8 - 8));
    end generate;

    ----------------------------------------------------------
    -- first word fall through FIFO to meet the AXI requirements for stalling for the output data
    -- Also to cross the clock domain.

    xpm_fifo_async_inst : xpm_fifo_async
    generic map (
        CDC_SYNC_STAGES => 2,       -- DECIMAL
        DOUT_RESET_VALUE => "0",    -- String
        ECC_MODE => "no_ecc",       -- String
        FIFO_MEMORY_TYPE => "distributed", -- String
        FIFO_READ_LATENCY => 0,     -- DECIMAL
        FIFO_WRITE_DEPTH => 32,   -- DECIMAL
        FULL_RESET_VALUE => 0,      -- DECIMAL
        PROG_EMPTY_THRESH => 10,    -- DECIMAL
        PROG_FULL_THRESH => 10,     -- DECIMAL
        RD_DATA_COUNT_WIDTH => 6,   -- DECIMAL
        READ_DATA_WIDTH => 512,      -- DECIMAL
        READ_MODE => "fwft",         -- String
        RELATED_CLOCKS => 0,        -- DECIMAL
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "1404", -- String. bit 2 and bit 10 enables write data count and read data count, bit 12 enables the "data_valid" output
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 512,     -- DECIMAL
        WR_DATA_COUNT_WIDTH => 6    -- DECIMAL
    )
    port map (
        almost_empty => open,       -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
        almost_full => open,        -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
        data_valid => o_axi_w.valid, -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
        dbiterr => open,            -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
        dout => o_axi_w.data,        -- READ_DATA_WIDTH-bit output: Read Data.
        empty => wdFIFO_empty,      -- 1-bit output: Empty Flag: When asserted, this signal indicates that the FIFO is empty. 
        full => wdFIFO_full,  -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full. 
        overflow => open,     -- 1-bit output: Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected, because the FIFO is full.
        prog_empty => open,   -- 1-bit output: Programmable Empty: 
        prog_full => open,    -- 1-bit output: Programmable Full
        rd_data_count => wdFIFO_rdDataCount, -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
        rd_rst_busy => open,  -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
        sbiterr => open,      -- 1-bit output: Single Bit Error: Indicates that the ECC decoder detected and fixed a single-bit error.
        underflow => open,    -- 1-bit output: Underflow: Indicates that the read request (rd_en).
        wr_ack => open,       -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock succeeded.
        wr_data_count => wdFIFO_wrDataCount, -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        wr_rst_busy => open,  -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO is busy with reset
        din => bufDout,       -- WRITE_DATA_WIDTH-bit input: Write Data.
        injectdbiterr => '0', -- 1-bit input: Double Bit Error Injection: Injects a double bit error.
        injectsbiterr => '0', -- 1-bit input: Single Bit Error Injection
        rd_clk => i_ap_clk,   -- 1-bit input: Read clock: Used for read operation.
        rd_en => wdFIFO_rdEn, -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO.
        rst => i_data_rst,    -- 1-bit input: Reset: Must be synchronous to wr_clk.
        sleep => '0',         -- 1-bit input: Dynamic power saving
        wr_clk => i_data_clk, -- 1-bit input: Write clock
        wr_en => wdFIFO_WrEn  -- 1-bit input: Write Enable 
    );
    
    wdFIFO_wrRst <= '0';
    wdFIFO_rdEn <= i_axi_wready and (not wdFIFO_empty);
    
    -- transfer reset to the i_ap_clk domain
    xpm_cdc_pulse_inst : xpm_cdc_pulse
    generic map (
        DEST_SYNC_FF => 3,   -- DECIMAL; range: 2-10
        INIT_SYNC_FF => 0,   -- DECIMAL; 0=disable simulation init values, 1=enable simulation init values
        REG_OUTPUT => 1,     -- DECIMAL; 0=disable registered output, 1=enable registered output
        RST_USED => 0,       -- DECIMAL; 0=no reset, 1=implement reset
        SIM_ASSERT_CHK => 0  -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
    )
    port map (
        dest_pulse => ap_clk_rst, -- 1-bit output: Outputs a pulse the size of one dest_clk period when a pulse transfer is correctly initiated on src_pulse input. 
        dest_clk   => i_ap_clk,   -- 1-bit input: Destination clock.
        dest_rst   => '0',        -- 1-bit input: optional; required when RST_USED = 1
        src_clk    => i_data_clk, -- 1-bit input: Source clock.
        src_pulse  => i_data_rst, -- 1-bit input: Rising edge of this signal initiates a pulse transfer to the destination clock domain.
        src_rst    => '0'         -- 1-bit input: optional; required when RST_USED = 1
    );
    
    process(i_ap_clk)
    begin
        if rising_edge(i_ap_clk) then
            if (ap_clk_rst = '1') then
                wdataCount <= "000";
            elsif wdFIFO_rdEn = '1' then
                wdataCount <= std_logic_vector(unsigned(wdataCount) + 1);
            end if;
            -- There are always 8 beats per burst, so last goes high every 8 outputs
            if wdataCount = "110" then
                o_axi_w.last <= '1';
            else
                o_axi_w.last <= '0';
            end if;
        end if;
    end process;
    
    ----------------------------------------------------------------------------------
    -- Put the header information out on i_ap_clk
    
    process(i_data_clk)
    begin
        if rising_edge(i_data_clk) then
            if i_data_rst = '1' then
                hdrCDC_src_send <= '0';
            elsif hdrCDC_src_rcv = '0' and headerValid = '1' then
                hdrCDC_src_send <= '1';
            elsif hdrCDC_src_rcv = '1' then
                hdrCDC_src_send <= '0';
            end if;
        end if;
    end process;
    
    
    hdrCDC_src_in(47 downto 32) <= headerVirtualChannel;
    hdrCDC_src_in(31 downto 0) <= headerPacketCount;
    
    xpm_cdc_handshake_inst : xpm_cdc_handshake
    generic map (
        DEST_EXT_HSK => 0,   -- DECIMAL; 0=internal handshake, 1=external handshake
        DEST_SYNC_FF => 4,   -- DECIMAL; range: 2-10
        INIT_SYNC_FF => 0,   -- DECIMAL; 0=disable simulation init values, 1=enable simulation init values
        SIM_ASSERT_CHK => 0, -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        SRC_SYNC_FF => 4,    -- DECIMAL; range: 2-10
        WIDTH => 48           -- DECIMAL; range: 1-1024
    )
    port map (
        dest_out => hdrCDC_dest_out, -- WIDTH-bit output: Input bus (src_in) synchronized to destination clock domain. This output is registered.
        dest_req => o_valid, -- 1-bit output: Assertion of this signal indicates that new dest_out data has been
                            -- received and is ready to be used or captured by the destination logic. When
                            -- DEST_EXT_HSK = 1, this signal will deassert once the source handshake
                            -- acknowledges that the destination clock domain has received the transferred
                            -- data. When DEST_EXT_HSK = 0, this signal asserts for one clock period when
                            -- dest_out bus is valid. This output is registered.
      src_rcv => hdrCDC_src_rcv,   -- 1-bit output: Acknowledgement from destination logic that src_in has been
                            -- received. This signal will be deasserted once destination handshake has fully
                            -- completed, thus completing a full data transfer. This output is registered.
      dest_ack => '1',   -- 1-bit input: optional; required when DEST_EXT_HSK = 1
      dest_clk => i_ap_clk,   -- 1-bit input: Destination clock.
      src_clk => i_data_clk,  -- 1-bit input: Source clock.
      src_in => hdrCDC_src_in,     -- WIDTH-bit input: Input bus that will be synchronized to the destination clock domain.
      src_send => hdrCDC_src_send  -- 1-bit input: Assertion of this signal allows the src_in bus to be synchronized
                            -- to the destination clock domain. This signal should only be asserted when
                            -- src_rcv is deasserted, indicating that the previous data transfer is complete.
                            -- This signal should only be deasserted once src_rcv is asserted, acknowledging
                            -- that the src_in has been received by the destination logic.
    );
    
    o_virtualChannel <= hdrCDC_dest_out(47 downto 32);
    o_packetCount <= hdrCDC_dest_out(31 downto 0);
    
    
    ----------------------------------------------------------------------------
    --
--    ilaLFAAProcess : ila_beamData
--    port map (
--        clk => i_data_clk, --  in std_logic;
--        probe0(0)  => dataAlignedEOP, -- : in std_logic_vector(119 downto 0)
--        probe0(1) => allFieldsMatch,
--        probe0(2) => searchRunning,
--        probe0(3) => bufDinGoodLength,
--        probe0(4) => searchDone,
--        probe0(5) => NoMatch,
--        probe0(6) => bufDinEOP,
--        probe0(7) => bufDinErr,
--        probe0(8) => VCTableMatch,
--        probe0(12 downto 9) => rx_fsm_dbg, --  4 bits,
--        probe0(13) => noVirtualChannel,
--        probe0(23 downto 14) => virtualChannel,     --  10 bits
--        probe0(33 downto 24) => packetStationID,    --  10 bits
--        probe0(42 downto 34) => packetFrequencyID,  --  9 bits
--        probe0(119 downto 43) => (others => '0')    -- 
--    );
    
end Behavioral;

