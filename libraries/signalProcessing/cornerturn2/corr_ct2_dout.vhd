----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: david humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 08/04/2022 09:29:40 AM
-- Module Name: corr_ct2_dout - Behavioral
-- Description: 
--  Readout to the correlator.
-- 
-- Readout Pattern:
--  For subarray = 1:total_subarrays    -- This is handled in the level above; Each new subarray is a read from the subarray-beam table. Once all are done, i_SB_done goes high.
--      For channel_base = 0:channels_to_integrate:total_channels
--          - channels_to_integrate : comes from i_fineIntegrations (from SB table)
--          - total_channels        : comes from i_N_fine (from SB table), the total number of fine channels to use.
--          For time_base = 0:integrations_per_849ms
--              - integrations_per_849ms : comes from i_timeIntegrations (from SB table), "00" = 64 time samples = 3 integrations per 849ms; "01" = 192 time samples = 1 integration per 849 ms
--              For tile_row = 0:total_tile_rows
--                  - total_tile_rows will be determined from i_stations (from SB table).
--                  - total_tile_rows = ceil(i_stations/256). 256 stations per tile.
--                  For tile_col = 0:total_tile_rows   -- Note : number of tile columns = number of tile rows.
--                    ---------------------------------------------------------------------------------------------------------------------------------
--                    | ******************************* Readout All Data for One Long Term Accumulation **********************************************|
--                    |                                                                                                                               |  
--                    | For time = 0:times_per_integration/64                                                                                         |
--                    |     - "time" here only needs 1 step, because each value of "time" corresponds to 64 actual time samples.                      |
--                    |       (2 HBM reads, since HBM data is in contiguous blocks with 32 time samples packed together)                              |
--                    |     - times_per_integration = 64 when i_timeIntegrations = "00", or 192 when i_timeIntegrations = "01".                       |
--                    |       (so time = 0:1 or 0:3)                                                                                                  |
--                    |     For channel = channel_base:(channel_base+channels_to_integrate)                                                           |
--                    |   |---------------------------------------------------------------------------------------------------------------------|     |
--                    |   |************************** Readout All Data for one Load of the correlator row+col memories**************************|     |
--                    |   |     For cur_station = (cur_tileColumn*256):16:(cur_tileColumn*256 + 256)                                            |     |
--                    |   |         Read HBM : 32 time samples, 16 stations                                                                     |     |
--                    |   |         Read HBM : Next 32 time samples, same 16 stations                                                           |     |
--                    |   |          - (Note each HBM read is 2048 bytes. Contiguous 2048 byte blocks in the HBM contain                        |     |
--                    |   |             data for 16 stations and 32 time samples)                                                               |     |
--                    |   |     if (cur_tileColumn != cur_tileRow) then                                                                         |     |
--                    |   |         For station = (cur_tileRow*256) : 16 : (cur_tileRow*256 + 256)                                              |     |
--                    |   |             Read HBM : 32 time samples, 16 stations                                                                 |     |
--                    |   |             Read HBM : Next 32 time samples, same 16 stations                                                       |     |
--                    |   |                                                                                                                     |     |
--                    |   |---------------------------------------------------------------------------------------------------------------------|     |
--                    |-------------------------------------------------------------------------------------------------------------------------------|
--
--
-- In terms of the behaviour of the correlator : 
--  The correlator processes 16x16 stations in a parallel array.
--    - The array internally accumulates across 64 time samples, for a single fine frequency channel. 
--  To process a "tile", (i.e. 256x256 stations), the memories driving the array ("row" and "col" memories)
--  have to be loaded with 64 time samples for all 256 stations, or 512 stations if this tile is not on the diagonal.
--    - Each "row" or "col" memory has data for 16 stations, 64 times, double buffered.
--  A burst of data delivered to the correlator to load the row+col memories contains 64 time samples and 256 or 512 stations:
--    
--
-- HBM addressing:
--  32 bit address needed to address 3 Gbytes:
--  The address of 512-byte blocks of data is calculated by the "get_ct2_HBM_addr" module, which is common to the data input side of the corner turn.
--
-- HBM data ordering :
--  Each 256 bit word in the HBM contains data for :
--     - 2 time samples, 4 consecutive stations
--  16x256 bits = 512 bytes. Each block of 512 bytes in the HBM contains data for :
--     - 32 time samples, 4 consecutive stations
--  4 x 512 bytes = 2048 bytes = size of HBM reads; Each block of 2048 bytes in the HBM contains data for :
--     - 32 time samples, 16 consecutive stations
--
----------------------------------------------------------------------------------

library IEEE, ct_lib, DSP_top_lib, common_lib, axi4_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
USE axi4_lib.axi4_full_pkg.ALL;
Library xpm;
use xpm.vcomponents.all;

entity corr_ct2_dout is
    Generic(
        GENERATE_ILA    : BOOLEAN := FALSE
    );
    Port(
        -- Only uses the 300 MHz clock.
        i_axi_clk   : in std_logic;
        i_start     : in std_logic; -- start reading out data to the correlators
        i_buffer    : in std_logic; -- which of the double buffers to read out ?
        i_frameCount : in std_logic_vector(31 downto 0); -- 849ms frameCount since epoch
        -- data path reset
        i_rst       : in std_logic;
        -- Data from the subarray beam table. After o_SB_req goes high, i_SB_valid will be driven high with requested data from the table on the other busses.
        o_SB_req    : out std_logic;    -- Rising edge gets the parameters for the next subarray-beam to read out.
        o_SB_buffer : out std_logic;    -- which of the two HBM buffers are we reading from
        i_SB        : in  std_logic_vector(6 downto 0); -- which subarray-beam are we currently processing from the subarray-beam table.
        i_SB_valid  : in  std_logic;    -- subarray-beam data below is valid; goes low when o_get_subarray_beam goes high, then goes high again once the parameters are valid.
        i_SB_done   : in std_logic;     -- Indicates that all the subarray beams for this correlator core has been processed.
        i_stations  : in std_logic_vector(15 downto 0);    -- The number of (sub)stations in this subarray-beam
        i_coarseStart : in std_logic_vector(15 downto 0);  -- The first coarse channel in this subarray-beam
        i_outputDisable : in std_logic;
        i_fineStart   : in std_logic_vector(15 downto 0);  -- The first fine channel in this subarray-beam
        i_n_fine      : in std_logic_vector(23 downto 0);  -- The number of fine channels in this subarray-beam
        i_fineIntegrations : in std_logic_vector(6 downto 0);  -- Number of fine channels to integrate
        i_timeIntegrations : in std_logic;                     -- Number of time samples per integration.
        i_HBM_base_addr    : in std_logic_vector(31 downto 0); -- Base address in HBM for this subarray-beam.        
        i_bad_poly    : in std_logic;
        ---------------------------------------------------------------
        -- Data out to the correlator arrays
        --
        -- correlator 0 is ready to receive a new block of data. This will go low once data starts to be received.
        -- A block of data consists of data for 64 times, and up to 512 virtual channels.
        i_cor_ready : in std_logic;  
        -- Each 256 bit word : two time samples, 4 consecutive stations
        --  bits (31:0) = time 0, station o_cor_station; 
        --  bits (63:32) = time 0, station (o_cor_station + 1); 
        --  bits (95:64) = time 0, station (o_cor_station + 2); 
        --  bits (127:96) = time 0, station (o_cor_station + 3);
        --  bits (159:128) = time 1, station o_cor_station; 
        --  bits (191:160) = time 1, station (o_cor_station + 1); 
        --  bits (223:192) = time 1, station (o_cor_station + 2); 
        --  bits (255:224) = time 1, station (o_cor_station + 3);
        o_cor_data  : out std_logic_vector(255 downto 0); 
        -- meta data so o_cor_data goes to the correct place.
        o_cor_time    : out std_logic_vector(7 downto 0); -- time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
        o_cor_station : out std_logic_vector(11 downto 0); -- first of the 4 stations in o_cor0_data
        -- Options for tileType : 
        --   '0' = Triangle. In this case, all the input data goes to both the row and column memories, and a triangle from the correlation matrix is computed.
        --            For correlation cells on the diagonal, only non-duplicate entries are sent out.
        --   '1' = Square. In this case, the first 256 virtual channels on i_cor0_data go to the column memories, while the next 256 virtual channels go to the row memories.
        --            All correlation products for the rectangle are then computed.
        o_cor_tileType : out std_logic;
        o_cor_valid    : out std_logic;  -- i_cor0_data, i_cor0_time, i_cor0_VC, i_cor0_FC and i_cor0_tileType are valid when i_cor0_valid = '1'
        o_cor_frameCount : out std_logic_vector(31 downto 0);
        -- o_cor_last and o_cor_final go high after a block of data has been sent.
        o_cor_first    : out std_logic;  -- This is the first block of data for an integration - i.e. first fine channel, first block of 64 time samples, for this tile
        o_cor_last     : out std_logic;  -- last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
        o_cor_final    : out std_logic;  -- Indicates that at the completion of processing the most recent block of correlator data, the integration is complete. o_cor_tileCount and o_cor_tileChannel are valid when this is high.   
        -- up to 1024 different tiles; each tile is a subset of the correlation for particular subarray and beam.
        -- Tiles can be triangles or rectangles from the full correlation.
        -- A single "tile" is a block of the correlation matrix of up to 256x256 stations
        -- e.g. for 512x512 stations, there will be 4 tiles, consisting of 2 triangles and 2 rectangles.
        --      for 4096x4096 stations, there will be 16 triangles, and 240 rectangles.
        -- bits 9:8 = "00", bits 7:4 = tile row, bits 3:0 = tile column 
        o_cor_tile_location : out std_logic_vector(9 downto 0);
        -- Which entry is this in the subarray-beam table ? 
        o_cor_subarray_beam : out std_logic_vector(7 downto 0);
        -- Total number of stations being processing for this subarray-beam.
        o_cor_totalStations : out std_logic_vector(15 downto 0);
        
        -- Which block of frequency channels is this tile for ?
        -- This isn't actually used anywhere since ultimately data is written to the HBM buffer at the 
        -- output of the correlator in the order in which it is received, but it indicates the first fine channel in the integration 
        -- (relative to the start of the buffer for this subarray-beam).
        o_cor_tileChannel       : out std_logic_vector(23 downto 0); -- 24 bit, so can represent up to 2^24/3456 = 4854 coarse channels.
        o_cor_tileTotalTimes    : out std_logic_vector(7 downto 0); -- Number of time samples to integrate for this tile.
        o_cor_tiletotalChannels : out std_logic_vector(6 downto 0); -- Number of frequency channels to integrate for this tile.
        o_cor_rowstations       : out std_logic_vector(8 downto 0); -- Number of stations in the row memories to process; up to 256.
        o_cor_colstations       : out std_logic_vector(8 downto 0); -- Number of stations in the col memories to process; up to 256. 
        o_cor_badPoly           : out std_logic;  -- No valid polynomial
        ----------------------------------------------------------------
        -- read interfaces for the HBM
        o_HBM_axi_ar      : out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_arready : in  std_logic;
        i_HBM_axi_r       : in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_rready  : out std_logic;
        
        ----------------------------------------------------------------
        -- debug info
        o_ar_fsm_dbg : out std_logic_vector(3 downto 0);
        o_readout_fsm_dbg : out std_logic_vector(3 downto 0);
        o_arFIFO_wr_count : out std_logic_vector(6 downto 0);
        o_dataFIFO_wrCount : out std_logic_vector(9 downto 0);
        o_readout_error       : out std_logic;
        o_recent_start_gap    : out std_logic_vector(31 downto 0);
        o_recent_readout_time : out std_logic_vector(31 downto 0);
        o_min_start_gap       : out std_logic_vector(31 downto 0)
    );
end corr_ct2_dout;

architecture Behavioral of corr_ct2_dout is

    COMPONENT ila_0
    PORT (
        clk : IN STD_LOGIC;
        probe0 : IN STD_LOGIC_VECTOR(191 DOWNTO 0));
    END COMPONENT;

    type ar_fsm_type is (check_arFIFO, get_SB_data, wait_SB_data, set_ar, set_ar2, wait_ar, update_addr, next_fine, next_tile, check_fineBase, next_fineBase, next_timeBase, done, SB_wait1, SB_wait2, SB_wait3);
    signal ar_fsm, ar_fsm_del1 : ar_fsm_type := done;
    signal readBuffer : std_logic := '0';
    
    type readout_fsm_type is (idle, wait_data, send_data, signal_correlator, wait_correlator_ready, wait_correlator_ready1, wait_correlator_ready2, wait_correlator_ready3);
    signal readout_fsm : readout_fsm_type := idle;
    signal cor_valid : std_logic;
    signal sendCount, sendCountDel1 : std_logic_vector(7 downto 0);
    signal readoutTriangle : std_logic;
    signal readoutFineChannel : std_logic_vector(23 downto 0);
    signal readoutTimeGroup : std_logic_vector(3 downto 0);
    signal readoutVCx16 : std_logic_vector(7 downto 0);
    signal readoutKey : std_logic_vector(1 downto 0);
    signal arFIFO_valid, arFIFO_full, arFIFO_rdEn, arFIFO_wrEn : std_logic;
    signal arFIFO_din, arFIFO_dout : std_logic_vector(133 downto 0);
    signal dataFIFO_valid, dataFIFO_rdEn, dataFIFO_wrEn, dataFIFO_full : std_logic;
    signal dataFIFO_dout : std_logic_Vector(255 downto 0);
    signal dataFIFO_rdCount : std_logic_vector(10 downto 0);
    signal dataFIFO_wrCount : std_logic_vector(9 downto 0);
    --
    signal SB_stations : std_logic_vector(15 downto 0); -- 16 bits, the number of (sub)stations in this subarray-beam
    signal SB_coarseStart : std_logic_vector(8 downto 0);  -- The first coarse channel in this subarray-beam
    signal SB_fineStart : std_logic_vector(11 downto 0);    -- The first fine channel in this subarray-beam
    signal SB_n_fine : std_logic_vector(23 downto 0);       -- The number of fine channels in this subarray-beam
    signal SB_fineIntegrations : std_logic_vector(6 downto 0);  -- number of fine channels to integrate
    signal SB_timeIntegrations : std_logic;                     -- 2 bits, number of time samples per integration.
    signal SB_base_addr : std_logic_vector(31 downto 0);        -- 32 bits,
    
    signal cur_skyFrequency : std_logic_vector(8 downto 0);
    signal cur_fineChannel : std_logic_vector(23 downto 0);
    signal cur_fineChannelBase : std_logic_vector(23 downto 0);
    signal cur_correlationChannelCount : std_logic_vector(23 downto 0);
    signal cur_fineChannelOffset : std_logic_vector(6 downto 0);
    signal cur_station, cur_station_plus16 : std_logic_vector(11 downto 0);
    signal cur_timeGroup : std_logic_vector(3 downto 0);
    signal cur_tileColumn, cur_tileColumn_plus1 : std_logic_vector(3 downto 0);  -- Which tile are we currently up to; 256 stations in a tile, so up to 16x256 = 4096 stations altogether 
    signal cur_tileRow  : std_logic_vector(3 downto 0);  --     
    signal cur_TileType : std_logic := '0';
    
    signal HBM_addr_valid : std_logic;
    signal SB_stations_div256, tiles_per_row_minus1 : std_logic_vector(7 downto 0);
    signal get_addr : std_logic;
    
    signal cur_fineChannelOffset_Ext : std_logic_vector(23 downto 0);
    signal HBM_addr, HBM_addr_hold : std_logic_vector(31 downto 0);
    signal HBM_addr_hold_valid, clear_hold : std_logic := '0';
    signal HBM_addr_bad, HBM_fine_high : std_logic := '0';
    signal cur_timeBase : std_logic_vector(3 downto 0) := "0000";
    signal readoutTileLocation : std_logic_vector(7 downto 0);
    signal cur_tileRow_x256, rowStations_remaining : std_logic_vector(15 downto 0);
    signal cur_tileColumn_x256, colStations_remaining : std_logic_vector(15 downto 0);
    signal readoutRowStations, readoutColStations : std_logic_vector(8 downto 0);
    signal readoutTotalChannels : std_logic_vector(6 downto 0);
    signal readoutTimeIntegration : std_logic;
    signal first_req_in_integration : std_logic := '0';
    signal readoutFirst : std_logic;
    signal cur_station_offset_ext : std_logic_vector(22 downto 0);
    signal cur_station_offset : std_logic_vector(1 downto 0);
    signal cur_station_ext, cur_station_offset_x4, up_to_station : unsigned(15 downto 0);
    signal readoutStationOffset : std_logic_vector(1 downto 0);
    signal arFIFO_wr_count : std_logic_vector(6 downto 0);
    signal cor_last_int, cor_first_int : std_logic := '0';
    signal SB_del, SB_SB : std_logic_vector(7 downto 0);
    signal readoutSB : std_logic_vector(7 downto 0);
    signal readoutTotalStations : std_logic_vector(15 downto 0);
    signal readFrameCount : std_logic_vector(31 downto 0);
    signal readoutFrameCount : std_logic_vector(31 downto 0);
    signal ar_fsm_dbg : std_logic_vector(3 downto 0);
    signal readout_fsm_dbg : std_logic_vector(3 downto 0);
    signal readoutBadPoly : std_logic;
    signal SB_badPoly : std_logic;
    signal SB_fineStart_ext, SB_N_fine_plus_SB_fineStart : std_logic_vector(23 downto 0);
    signal SB_outputDisable : std_logic := '0';
    signal readout_error : std_logic := '0';
    signal recent_start_gap, start_gap  : std_logic_vector(31 downto 0) := x"00000000";
    signal recent_readout_time, readout_time : std_logic_vector(31 downto 0) := x"00000000";
    signal start_Del1 : std_logic;
    signal min_start_gap : std_logic_vector(31 downto 0) := x"ffffffff";
    
begin
    
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            o_ar_fsm_dbg <= ar_fsm_dbg;
            o_readout_fsm_dbg <= readout_fsm_dbg;
            o_arFIFO_wr_count <= arFIFO_wr_count;
            o_dataFIFO_wrCount <= dataFIFO_wrCount;
            o_readout_error <= readout_error;
            o_recent_start_gap <= recent_start_gap;
            o_recent_readout_time <= recent_readout_time;
            o_min_start_gap <= min_start_gap;
        end if;
    end process;
    
    hbm_addri : entity ct_lib.get_ct2_HBM_addr
    port map(
        i_axi_clk => i_axi_clk, --  in std_logic;
        -- Values from the Subarray-beam table
        i_SB_HBM_base_Addr => SB_base_addr,   -- in (31:0); -- Base address in HBM for this subarray-beam
        i_SB_coarseStart   => SB_coarseStart, -- in (8:0);  -- First coarse channel for this subarray-beam, x781.25 kHz to get the actual sky frequency 
        i_SB_fineStart     => SB_fineStart,   -- in (11:0); -- First fine channel for this subarray-beam, runs from 0 to 3455
        i_SB_stations      => SB_stations,    -- in (15:0); -- Total number of stations in this subarray-beam
        i_SB_N_fine        => SB_N_fine,      -- in (23:0); -- Total number of fine channels to store for this subarray-beam
        -- Values for this particular block of 512 bytes. Each block of 512 bytes is 4 stations, 32 time samples ((4stations)*(32timesamples)*(2pol)*(1byte)(2(complex)) = 512 bytes)
        i_coarse_channel   => cur_skyFrequency, -- in (8:0);  -- coarse channel for this block, x781.25kHz to get the actual sky frequency (so is comparable to i_SB_coarseStart
        i_fine_channel     => cur_fineChannel,  -- in (23:0); -- fine channel for this block, can go beyond 3455 into subsequent coarse channels
        i_station          => cur_station,      -- in (11:0); -- Index of this station within the subarray
        i_time_block       => cur_timegroup(2 downto 0), -- in (2:0);  -- Which time block this is for; 0 to 5. Each time block is 32 time samples.
        i_buffer           => readBuffer,     -- in std_logic; -- Which half of the buffer to calculate for (each half is 1.5 Gbytes)
        -- All above data is valid, do the calculation.
        i_valid            => get_addr,       -- in std_logic;
        -- Resulting address in the HBM, after 8 cycles latency.
        o_HBM_addr         => HBM_addr,       -- out (31:0);
        o_out_of_range     => HBM_addr_bad,   -- out std_logic; Indicates that the values for (i_coarse_channel, i_fine_channel, i_station, i_time_block) are out of range, and thus o_HBM_addr is not valid.
        o_fine_high        => HBM_fine_high,  -- out std_logic; Indicates that the fine channel selected is higher than the maximum fine channel (i.e. > (i_SB_coarseStart * 3456 + i_SB_fineStart))
        o_valid            => HBM_addr_valid  -- out std_logic; Some fixed number of clock cycles after i_valid.
    );
    
    cur_fineChannelOffset_ext(23 downto 7) <= (others => '0');
    cur_fineChannelOffset_ext(6 downto 0) <= cur_fineChannelOffset;
    cur_fineChannel <= std_logic_vector(unsigned(cur_fineChannelBase) + unsigned(cur_fineChannelOffset_ext));
    
    -- Always read blocks of 512 bytes = 8 x (512 bit) words.
    -- There is data for 4 stations in each 512 byte block in HBM, so 2048 byte reads 
    -- returns data for 4x4=16 stations, i.e. the minimum amount used by the correlator array.
    o_HBM_axi_ar.len <= "00000111";
    o_HBM_axi_ar.addr(39 downto 32) <= "00000000";
    o_HBM_axi_ar.addr(8 downto 0) <= "000000000";  -- All reads are 512 byte aligned.
    
    o_SB_buffer <= readBuffer;
    
    SB_fineStart_ext <= x"000" & SB_fineStart;
    SB_stations_div256 <= SB_stations(15 downto 8);
    cur_tileColumn_plus1 <= std_logic_vector(unsigned(cur_tileColumn) + 1);
    cur_station_offset_ext <= "000000000000000000000" & cur_station_offset;
    
    cur_station_ext         <= unsigned("0000" & cur_station);
    cur_station_offset_x4   <= unsigned("000000000000" & cur_station_offset & "00");
    
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
        
            --up_to_station <= std_logic_vector(unsigned(cur_station_ext) + unsigned(cur_station_offset_x4) + 4);
            up_to_station <= cur_station_ext + cur_station_offset_x4 + 4;
            SB_del <= '0' & i_SB;
            -- The last fine channel relative to the start of the fine channels in coarse channel i_coarseStart
            -- Used to be assigned in the ar_fsm = wait_SB_data state along with the other SB_* signals,
            -- but moved here to improve timing
            SB_N_fine_plus_SB_fineStart <= std_logic_vector(unsigned(SB_n_fine) + unsigned(SB_fineStart_ext)); 
                            
            if i_rst = '1' then
                HBM_addr_hold_valid <= '0';
            elsif HBM_addr_valid = '1' then
                HBM_addr_hold <= HBM_addr;
                HBM_addr_hold_valid <= '1';
            elsif clear_hold = '1' then
                HBM_Addr_hold_valid <= '0';
            end if;
            
            if SB_stations(7 downto 0) = "00000000" then
                tiles_per_row_minus1 <= std_logic_vector(unsigned(SB_stations_div256) - 1);
            else
                tiles_per_row_minus1 <= SB_stations_div256; 
            end if;
            
            if i_start = '1' then
                start_gap <= (others => '0');
                recent_start_gap <= start_gap;
            elsif start_gap(31) = '0' then
                start_gap <= std_logic_vector(unsigned(start_gap) + 1);
            end if;
            
            start_del1 <= i_start;
            if i_rst = '1' then
                min_start_gap <= (others => '1');
            elsif start_del1 = '1' then
                if unsigned(recent_start_gap) < unsigned(min_start_gap) then
                    min_start_gap <= recent_start_gap;
                end if;
            end if;
            
            if i_start = '1' then
                readout_time <= (others => '0');
            elsif ar_fsm = done and ar_fsm_del1 /= done then
                recent_readout_time <= readout_time;
            elsif (ar_fsm /= done) and readout_time(31) = '0' then
                readout_time <= std_logic_vector(unsigned(readout_time) + 1);
            end if;
            
            if i_rst = '1' then
                readout_error <= '0';
            elsif i_start = '1' and ar_fsm /= done then
                readout_error <= '1';
            end if;
            
            if i_rst = '1' then
                ar_fsm <= done;
                o_SB_req <= '0';
                first_req_in_integration <= '1';
                o_HBM_axi_ar.valid <= '0';
                ar_fsm_dbg <= "1101";
            elsif i_start = '1' then
                ar_fsm <= get_SB_data;
                readBuffer <= i_buffer;
                readFrameCount <= i_frameCount;
                o_SB_req <= '0';
                first_req_in_integration <= '1';
                ar_fsm_dbg <= "0000";
            else
                case ar_fsm is
                
                    when get_SB_data =>
                        ar_fsm_dbg <= "0001";
                        o_SB_req <= '1';
                        ar_fsm <= wait_SB_data;
                        clear_hold <= '0';  -- Hold of the output of the address calculation.
                        o_HBM_axi_ar.valid <= '0';
                        get_addr <= '0';
                    
                    when wait_SB_data =>
                        ar_fsm_dbg <= "0010";
                        o_SB_req <= '0';
                        if i_SB_done = '1' then
                            ar_fsm <= done;
                            get_addr <= '0';
                        elsif i_SB_valid = '1' then
                            SB_stations <= i_stations;                    -- 16 bits, the number of (sub)stations in this subarray-beam
                            SB_coarseStart <= i_coarseStart(8 downto 0);  -- The first coarse channel in this subarray-beam
                            SB_fineStart <= i_fineStart(11 downto 0);     -- The first fine channel in this subarray-beam
                            SB_n_fine <= i_n_fine;                        -- 24 bits, the number of fine channels in this subarray-beam
                            SB_fineIntegrations <= i_fineIntegrations; -- 6 bits, number of fine channels to integrate
                            SB_timeIntegrations <= i_timeIntegrations; -- 1 bit, number of time samples per integration.
                            SB_base_addr <= i_HBM_base_addr; -- 32 bits, base address in HBM for this subarray-beam.
                            SB_SB <= SB_del;
                            SB_badPoly <= i_bad_poly;
                            SB_outputDisable <= i_outputDisable;
                            
                            cur_skyFrequency <= i_coarseStart(8 downto 0);
                            cur_fineChannelBase <= "000000000000" & i_fineStart(11 downto 0);
                            cur_correlationChannelCount <= (others => '0');  -- Count of the output correlation channels.
                            cur_fineChannelOffset <= "0000000"; -- counts through the channels that we step through within a single integration
                            cur_station <= (others => '0');    -- The station within the array that we are getting; always starts from 0. 
                            cur_station_offset <= "00";        -- Which group of 4 stations are we up to for the memory request (fsm does 4 requests to get data for up to 16 stations in a burst)
                            cur_tileColumn <= (others => '0'); -- Which tile are we currently up to 
                            cur_tileRow <= (others => '0');    -- 
                            cur_timeBase <= "0000"; -- fixed at "0000" for 849 ms integrations, steps through "0000", "0010", "0100" for 283 ms integrations.
                            cur_TimeGroup <= "0000"; -- steps through "000", "001", "010", "011", "100", "101" for the 6 groups of 32 times, since data in HBM is written in 512 byte blocks with 32 times.
                            
                            ar_fsm <= check_arFIFO;
                            if i_outputDisable = '0' then
                                get_addr <= '1';         -- Get the first address to use
                            else
                                get_addr <= '0';
                            end if;
                        end if;
                        clear_hold <= '0';
                        o_HBM_axi_ar.valid <= '0';
                
                    when check_arFIFO =>
                        ar_fsm_dbg <= "0011";
                        if SB_outputDisable = '1' then
                            -- Do not generate any output from this subarray-beam table entry, 
                            -- move on to the next entry.
                            ar_fsm <= SB_wait1;
                        else
                            -- check there is space in the ar FIFO.
                            -- Up to 4 requests get made at a time, so make sure there is 
                            -- at least 4 slots free in the ar fifo.
                            if (unsigned(arFIFO_wr_count) < 56) then
                                ar_fsm <= set_ar;
                            end if;
                        end if;
                        get_addr <= '0';
                        clear_hold <= '0';
                        o_SB_req <= '0';
                        o_HBM_axi_ar.valid <= '0';
                    
                    when SB_wait1 =>
                        ar_fsm_dbg <= "1110";
                        -- Wait a few clocks for i_SB_done to reflect the new value
                        ar_fsm <= SB_wait2;
                        clear_hold <= '1';
                    
                    when SB_wait2 =>
                        ar_fsm_dbg <= "1110";
                        ar_fsm <= SB_wait3;
                        clear_hold <= '1';
                    
                    when SB_wait3 =>
                        ar_fsm_dbg <= "1110";
                        if (i_SB_done = '1') then
                            ar_fsm <= done;
                        else
                            ar_fsm <= get_SB_data;
                        end if;
                        clear_hold <= '1';
                    
                    when set_ar =>
                        ar_fsm_dbg <= "0100";
                        -- This sets the HBM address for the first 512 byte block in a group of 4 blocks
                        clear_hold <= '1';
                        o_SB_req <= '0';
                        if HBM_addr_valid = '1' then
                            o_HBM_axi_ar.addr(31 downto 9) <= HBM_addr(31 downto 9);
                        elsif HBM_addr_hold_valid = '1' then
                            o_HBM_axi_ar.addr(31 downto 9) <= HBM_addr_hold(31 downto 9);
                        end if;
                        if HBM_addr_valid = '1' or HBM_addr_hold_valid = '1' then
                            ar_fsm <= wait_ar;
                            o_HBM_axi_ar.valid <= '1';                        
                        end if;
                        
                    when wait_ar =>
                        ar_fsm_dbg <= "0101";
                        clear_hold <= '0';
                        o_SB_req <= '0';
                        if i_HBM_axi_arready = '1' then
                            o_HBM_axi_ar.valid <= '0';
                            
                            first_req_in_integration <= '0';
                            cur_station_offset <= std_logic_vector(unsigned(cur_station_offset) + 1);
                            --if (unsigned(SB_stations) > up_to_station) then
                            if (unsigned(SB_stations) > unsigned(up_to_station)) and (unsigned(cur_station_offset) < 3) then
                                ar_fsm <= set_ar2;
                            else
                                ar_fsm <= update_addr;
                            end if;
                        end if;
                    
                    when set_ar2 =>
                        ar_fsm_dbg <= "0110";
                        -- Set the HBM address for (up to) 3 remaining 512-byte blocks.
                        o_HBM_axi_ar.addr(31 downto 9) <= std_logic_vector(unsigned(HBM_addr_hold(31 downto 9)) + unsigned(cur_station_offset_ext));
                        o_HBM_axi_ar.valid <= '1';
                        ar_fsm <= wait_ar;
                        
                    when update_addr =>
                        ar_fsm_dbg <= "0111";
                        --  For subarray = 1:total_subarrays    -- This is handled in the level above; Each new subarray is a read from the subarray-beam table. Once all are done, i_SB_done goes high.
                        --      For cur_fineChannelBase = SB_fineStart:SB_fineIntegrations:(SB_fineStart + SB_N_fine)
                        --          - i.e. Step each block of fine channels that get integrated together.
                        --          For cur_timeBase = 0:integrations_per_849ms
                        --              - integrations_per_849ms : from SB_timeIntegrations, '0' = 64 time samples = 3 integrations per 849ms; '1' = 192 time samples = 1 integration per 849 ms
                        --              For cur_tileRow = 0:tiles_per_row  -- note tiles_per_row=ceil(SB_stations/256)
                        --                  - step through the rows of the visibility matrix in "tiles", i.e. blocks of 256 stations.
                        --                  For cur_tileColumn = 0:tiles_per_row     -- Note : number of tile columns = number of tile rows; correlation matrices are always square
                        --                      - After processing all the tiles in a single row, the output stage can start sending data to SDP. 
                        --             /--      For cur_timeGroup(2:1) = 0:times_per_integration/64  -- e.g. 1 block of 64 times, if 283 ms integrations, or 3 blocks of 64 times if 849 ms integrations.
                        -- One         |            - times_per_integration = 64 when SB_timeIntegrations = '0', or 192 when SB_timeIntegrations = '1'. 
                        -- long        |            For cur_fineChannelOffset = 0:SB_fineIntegrations
                        -- term        |                - Data loaded into the row+col memories for the correlator cell is  :
                        -- integration |                -   - 256 x 256 stations (= 1 "tile"), 
                        --             |                -   - 64 time samples                        
                        --                   /--        For cur_station = (cur_tileColumn*256):16:(cur_tileColumn*256 + 256)
                        --                   |              Read HBM : 32 time samples, 16 stations
                        --    One full       |              Read HBM : Next 32 time samples, same 16 stations
                        --    load of data   |              - (Note each HBM read is 2048 bytes. Contiguous 2048 byte blocks in the HBM contain data for 16 stations and 32 time samples)
                        --    for row+col    |          if (cur_tileColumn != cur_tileRow) then
                        --    memories for   |              For station = (cur_tileRow*256) : 16 : (cur_tileRow*256 + 256)
                        --    the correlator |                  Read HBM : 32 time samples, 16 stations
                        --    cell           |                  Read HBM : Next 32 time samples, same 16 stations 
                        --
                        cur_station_offset <= "00";
                        clear_hold <= '0';
                        o_SB_req <= '0';
                        
                        -- 
                        if cur_timegroup(0) = '0' then -- Get the second block of 32 times
                            cur_timegroup(0) <= '1'; 
                            get_addr <= '1';
                            ar_fsm <= check_arFIFO;
                        else
                            cur_timegroup(0) <= '0';
                            
                            if cur_station(7 downto 0) = "11110000" or (unsigned(cur_station_plus16) >= unsigned(SB_stations)) then
                                -- Each read is 16 stations, so cur_station_plus16 is the number of stations we have read at this point
                                if ((cur_tileRow = cur_tileColumn) or (cur_station(11 downto 8) = cur_tileRow(3 downto 0))) then
                                    -- same data is loaded for row and column memories, or we have just finished loading for the row memories,
                                    -- so now move on to the next fine channel
                                    get_addr <= '0';
                                    cur_station <= cur_tileColumn & "00000000";
                                    ar_fsm <= next_fine;
                                else
                                    -- start loading data for the row memories
                                    cur_station <= cur_tileRow & "00000000";
                                    get_addr <= '1';
                                    ar_fsm <= check_arFIFO;
                                end if;
                            else
                                -- Get data for the next block of 16 stations
                                cur_station <= std_logic_vector(unsigned(cur_station) + 16);
                                get_addr <= '1';
                                ar_fsm <= check_arFIFO;
                            end if;
                        end if;
                        o_HBM_axi_ar.valid <= '0';
                    
                    when next_fine => -- Advance to the next fine channel within a group of fine channels that are being integrated.
                        ar_fsm_dbg <= "1000";
                        -- Advancing to the next fine channel is a separate state to the update_addr state since at this point we have finished a full block of row and col mem data for the correlator. 
                        if (unsigned(cur_fineChannelOffset) = (unsigned(SB_fineIntegrations) - 1)) then
                            cur_fineChannelOffset <= (others => '0');
                            if SB_timeIntegrations = '0' then
                                -- Only integrating over 283 ms = 64 time samples, so the integration is complete
                                ar_fsm <= next_tile;
                            else
                                -- Integrating over 849 ms = 192 time samples.
                                case cur_timeGroup(2 downto 1) is -- bits 2:1 selects which of the three blocks of 283 ms we have just read out.
                                    when "00" => 
                                        cur_timeGroup <= "0010";
                                        get_addr <= '1';
                                        ar_fsm <= check_arFIFO;
                                    when "01" => 
                                        cur_timeGroup <= "0100";
                                        get_addr <= '1';
                                        ar_fsm <= check_arFIFO;
                                    when others => 
                                        -- Just read out the last 283 ms block of data, go on to the next group of fine channels.
                                        cur_timeGroup <= "0000";
                                        get_addr <= '0';
                                        ar_fsm <= next_tile;
                                end case;
                            end if;
                        else
                            ar_fsm <= check_arFIFO;
                            get_addr <= '1';
                            cur_fineChannelOffset <= std_logic_vector(unsigned(cur_fineChannelOffset) + 1);
                        end if;
                        o_HBM_axi_ar.valid <= '0';
                        
                    when next_tile =>
                        ar_fsm_dbg <= "1001";
                        first_req_in_integration <= '1';
                        cur_timeGroup <= cur_timeBase;
                        cur_FineChannelOffset <= (others => '0');
                        
                        if (cur_tileColumn = tiles_per_row_minus1(3 downto 0)) then
                            cur_tileColumn <= (others => '0');
                            cur_station <= "000000000000"; -- i.e. new value of cur_tileColumn & "00000000"
                            if (cur_tileRow = tiles_per_row_minus1(3 downto 0)) then
                                -- Just finished the final tile, go on to the next value of cur_timeBase
                                get_addr <= '0';
                                cur_tileRow <= (others => '0');
                                ar_fsm <= next_timeBase;
                            else
                                get_addr <= '1';
                                cur_tileRow <= std_logic_vector(unsigned(cur_tileRow) + 1);
                                ar_fsm <= check_arFIFO;
                            end if;
                        else
                            cur_tileColumn <= cur_tileColumn_plus1; -- std_logic_vector(unsigned(cur_tileColumn) + 1);
                            cur_station <= cur_tileColumn_plus1 & "00000000"; -- i.e. new value of cur_tileColumn & "00000000"
                            get_addr <= '1';
                            ar_fsm <= check_arFIFO;
                        end if;
                        o_HBM_axi_ar.valid <= '0';
                        
                    when next_timeBase =>
                        ar_fsm_dbg <= "1010";
                        if SB_timeIntegrations = '0' then 
                            -- only integrating over 283 ms, go to the next timebase
                            case cur_timeBase is
                                when "0000" =>
                                    cur_timeBase <= "0010";
                                    cur_timeGroup <= "0010";
                                    get_addr <= '1';
                                    ar_fsm <= check_arFIFO;
                                when "0010" =>
                                    cur_timeBase <= "0100";
                                    cur_timeGroup <= "0100";
                                    get_Addr <= '1';
                                    ar_fsm <= check_arFIFO;
                                when others => -- only other case should be "0100"
                                    cur_timeBase <= "0000";
                                    cur_timeGroup <= "0000";
                                    get_Addr <= '0';
                                    ar_fsm <= next_fineBase;
                            end case;
                        else
                            -- integration was over the full 849 ms, so there is nothing to loop over at this point.
                            get_addr <= '0';
                            ar_fsm <= next_fineBase;
                        end if;
                        o_HBM_axi_ar.valid <= '0';
                        
                    when next_fineBase =>
                        ar_fsm_dbg <= "1011";
                        cur_fineChannelBase <= std_logic_vector(unsigned(cur_fineChannelBase) + unsigned(SB_fineIntegrations));
                        cur_correlationChannelCount <= std_logic_vector(unsigned(cur_correlationChannelCount) + 1);
                        ar_fsm <= check_fineBase;
                        o_HBM_axi_ar.valid <= '0';
                     
                    when check_fineBase =>
                        ar_fsm_dbg <= "1100";
                        if (unsigned(cur_fineChannelBase) >= unsigned(SB_N_fine_plus_SB_fineStart)) then
                            if (i_SB_done = '1') then
                                ar_fsm <= done;
                            else
                                ar_fsm <= get_SB_data;
                            end if;
                            get_Addr <= '0';
                        else
                            get_Addr <= '1';
                            ar_fsm <= check_arFIFO;
                        end if;
                        o_HBM_axi_ar.valid <= '0';
                    
                    when done =>
                        ar_fsm_dbg <= "1101";
                        o_SB_req <= '0';
                        ar_fsm <= done; -- Wait until we get i_start again.
                        o_HBM_axi_ar.valid <= '0';
                        get_addr <= '0';
                        
                end case;
            end if;
            ar_fsm_del1 <= ar_fsm;
            cur_station_plus16 <= std_logic_vector(unsigned(cur_station) + 16);
            
            if cur_tileRow = cur_tileColumn then
                cur_TileType <= '0';
            else
                cur_tileType <= '1';
            end if;
            
            -- FIFO to keep meta data associated with each HBM ar request.
            if (ar_fsm /= set_ar and ar_fsm_del1 = set_ar) or (ar_fsm /= set_ar2 and ar_fsm_del1 = set_ar2) then -- i.e. when we leave the "set_ar" or "set_ar2" state.
                arFIFO_wrEn <= '1';
                arFIFO_din(0) <= cur_TileType; -- 1 bit
                arFIFO_din(24 downto 1)  <= cur_correlationChannelCount(23 downto 0); -- 24 bits, Selects fine channel within the buffer.
                arFIFO_din(28 downto 25) <= cur_timeGroup;   -- 4 bits
                arFIFO_din(36 downto 29) <= cur_station(11 downto 4); -- 8 bits, index of the first of the 16 stations we are getting with this ar request.
                arFIFO_din(37) <= '0';
                arFIFO_din(39 downto 38) <= "00"; -- "00" for normal data, "01" start correlation (end of block for row+col memories), "10" for end of tile = end of integration.
                arFIFO_din(47 downto 40) <= cur_tileRow & cur_tileColumn;
                
                -- Number of stations in the row memories to process for this tile.
                -- 256 for a fully utilised tile, otherwise however many are left to process.
                if (unsigned(rowStations_remaining) > 255) then
                    arFIFO_din(56 downto 48) <= "100000000";
                else
                    arFIFO_din(56 downto 48) <= rowStations_remaining(8 downto 0);
                end if;
                -- Number of stations in the col memories to process for this tile.
                if (unsigned(colStations_remaining) > 255) then
                    arFIFO_din(65 downto 57) <= "100000000";
                else
                    arFIFO_din(65 downto 57) <= colStations_remaining(8 downto 0);
                end if;
                
                arFIFO_din(72 downto 66) <= SB_fineIntegrations;
                arFIFO_din(73) <= SB_timeIntegrations;
                -- first data for a new integration
                arFIFO_din(74) <= first_req_in_integration;
                arFIFO_din(76 downto 75) <= cur_station_offset;
                
                arFIFO_din(92 downto 77) <= SB_stations; -- 16 bit number of stations in this subarray-beam
                arFIFO_din(100 downto 93) <= SB_SB; -- 8 bit index into the subarray-beam table
                arFIFO_din(132 downto 101) <= readFrameCount;
                arFIFO_din(133) <= SB_badPoly;
                
            elsif ar_fsm_del1 = next_fine then
                arFIFO_wrEn <= '1';
                arFIFO_din(38) <= '1';    -- Indicates that a full block of data has been delivered to the correlator, and the correlator has to be run.
                if ar_fsm = next_tile then
                    arFIFO_din(39) <= '1';  -- Indicates that all the time samples and fine channels have been sent, so this is the end of the integration.
                else
                    arFIFO_din(39) <= '0';
                end if;
            else
                arFIFO_wrEn <= '0';
            end if;
            
            rowStations_remaining <= std_logic_vector(unsigned(SB_stations) - unsigned(cur_tileRow_x256));
            colStations_remaining <= std_logic_vector(unsigned(SB_stations) - unsigned(cur_tileColumn_x256));
            
        end if;
    end process;
    
    cur_tileRow_x256 <= "0000" & cur_tileRow & "00000000";
    cur_tileColumn_x256 <= "0000" & cur_tileColumn & "00000000";
    
    
    -- arFIFO is read when data is read out of the dataFIFO in this module, so the number of entries in the 
    -- arFIFO is the number of words that will be in the dataFIFO when all the requests have returned from the HBM.
    -- The dataFIFO has space for 512 words, i.e. 64 ar requests (each ar request is 512 bytes = 8 x 64byte words)
    -- So arFIFO only really needs to be 16 deep.
    arfifoi : xpm_fifo_sync
    generic map (
        CASCADE_HEIGHT => 0,        -- DECIMAL
        DOUT_RESET_VALUE => "0",    -- String
        ECC_MODE => "no_ecc",       -- String
        FIFO_MEMORY_TYPE => "distributed", -- String
        FIFO_READ_LATENCY => 0,     -- DECIMAL
        FIFO_WRITE_DEPTH => 64,     -- DECIMAL
        FULL_RESET_VALUE => 0,      -- DECIMAL
        PROG_EMPTY_THRESH => 10,    -- DECIMAL
        PROG_FULL_THRESH => 10,     -- DECIMAL
        RD_DATA_COUNT_WIDTH => 7,   -- DECIMAL
        READ_DATA_WIDTH => 134,     -- DECIMAL
        READ_MODE => "fwft",        -- String
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "1404", -- String; bit 12 = enable data valid flag, bits 2 and 10 enable read and write data counts
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 134,    -- DECIMAL
        WR_DATA_COUNT_WIDTH => 7    -- DECIMAL
    ) port map (
        almost_empty => open,       -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
        almost_full => open,        -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
        data_valid => arFIFO_valid, -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
        dbiterr => open,            -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
        dout => arFIFO_dout,        -- READ_DATA_WIDTH-bit output: Read Data: The output data bus is driven when reading the FIFO.
        empty => open,              -- 1-bit output: Empty Flag: When asserted, this signal indicates that- the FIFO is empty.
        full => arFIFO_full,        -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full.
        overflow => open,           -- 1-bit output: Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected, because the FIFO is full
        prog_empty => open,         -- 1-bit output: Programmable Empty: This signal is asserted when the number of words in the FIFO is less than or equal to the programmable empty threshold value.
        prog_full => open,          -- 1-bit output: Programmable Full: This signal is asserted when the number of words in the FIFO is greater than or equal to the programmable full threshold value.
        rd_data_count => open,      -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
        rd_rst_busy => open,        -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
        sbiterr => open,            -- 1-bit output: Single Bit Error: Indicates that the ECC decoder detected and fixed a single-bit error.
        underflow => open,          -- 1-bit output: Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected because the FIFO is empty.
        wr_ack => open,             -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.
        wr_data_count => arFIFO_wr_count, -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        wr_rst_busy => open,        -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
        din => arFIFO_din,          -- WRITE_DATA_WIDTH-bit input: Write Data: The input data bus used when writing the FIFO.
        injectdbiterr => '0',       -- 1-bit input: Double Bit Error Injection
        injectsbiterr => '0',       -- 1-bit input: Single Bit Error Injection: 
        rd_en => arFIFO_RdEn,       -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO. 
        rst => i_rst,               -- 1-bit input: Reset: Must be synchronous to wr_clk.
        sleep => '0',               -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
        wr_clk => i_axi_clk,        -- 1-bit input: Write clock: Used for write operation. wr_clk must be a free running clock.
        wr_en => arFIFO_wrEn        -- 1-bit input: Write Enable: 
    );
    
    arFIFO_rdEN <= '1' when readout_fsm = idle else '0';


    datafifoi : xpm_fifo_sync
    generic map (
        CASCADE_HEIGHT => 0,        -- DECIMAL
        DOUT_RESET_VALUE => "0",    -- String
        ECC_MODE => "no_ecc",       -- String
        FIFO_MEMORY_TYPE => "auto", -- String
        FIFO_READ_LATENCY => 1,     -- DECIMAL
        FIFO_WRITE_DEPTH => 512,    -- DECIMAL
        FULL_RESET_VALUE => 0,      -- DECIMAL
        PROG_EMPTY_THRESH => 10,    -- DECIMAL
        PROG_FULL_THRESH => 10,     -- DECIMAL
        RD_DATA_COUNT_WIDTH => 11,  -- DECIMAL  should be = log2(FIFO_READ_DEPTH) + 1
        READ_DATA_WIDTH => 256,     -- DECIMAL
        READ_MODE => "std",         -- String
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "1404", -- String; bit 12 = enable data valid flag, bits 2 and 10 enable read and write data counts
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 512,    -- DECIMAL
        WR_DATA_COUNT_WIDTH => 10   -- DECIMAL
    ) port map (
        almost_empty => open,      -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
        almost_full => open,       -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
        data_valid => dataFIFO_valid, -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
        dbiterr => open,           -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
        dout => dataFIFO_dout,     -- READ_DATA_WIDTH-bit output: Read Data: The output data bus is driven when reading the FIFO.
        empty => open,             -- 1-bit output: Empty Flag: When asserted, this signal indicates that- the FIFO is empty.
        full => dataFIFO_full,     -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full.
        overflow => open,          -- 1-bit output: Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected, because the FIFO is full
        prog_empty => open,        -- 1-bit output: Programmable Empty: This signal is asserted when the number of words in the FIFO is less than or equal to the programmable empty threshold value.
        prog_full => open,         -- 1-bit output: Programmable Full: This signal is asserted when the number of words in the FIFO is greater than or equal to the programmable full threshold value.
        rd_data_count => dataFIFO_rdCount,     -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
        rd_rst_busy => open,       -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
        sbiterr => open,           -- 1-bit output: Single Bit Error: Indicates that the ECC decoder detected and fixed a single-bit error.
        underflow => open,         -- 1-bit output: Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected because the FIFO is empty.
        wr_ack => open,            -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.
        wr_data_count => dataFIFO_wrCount, -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        wr_rst_busy => open,       -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
        din => i_HBM_axi_r.data,       -- WRITE_DATA_WIDTH-bit input: Write Data: The input data bus used when writing the FIFO.
        injectdbiterr => '0',      -- 1-bit input: Double Bit Error Injection
        injectsbiterr => '0',      -- 1-bit input: Single Bit Error Injection: 
        rd_en => dataFIFO_RdEn,    -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO. 
        rst => i_rst,              -- 1-bit input: Reset: Must be synchronous to wr_clk.
        sleep => '0',              -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
        wr_clk => i_axi_clk,       -- 1-bit input: Write clock: Used for write operation. wr_clk must be a free running clock.
        wr_en => dataFIFO_wrEn     -- 1-bit input: Write Enable: 
    );
    
    dataFIFO_rdEn <= '1' when readout_fsm = send_data else '0';
    dataFIFO_wrEn <= i_HBM_axi_r.valid and (not dataFIFO_full);
    o_HBM_axi_rready <= not dataFIFO_full;
    
    -- Readout of the ar fifo and data fifo, send data to the correlator
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            
            if i_rst = '1' then
                readout_fsm <= idle;
                readout_fsm_dbg <= "0000";
            else
                case readout_fsm is
                    when idle =>
                        readout_fsm_dbg <= "0000";
                        if arFIFO_valid = '1' then
                            readoutFrameCount <= arFIFO_dout(132 downto 101);
                            readoutTriangle <= arFIFO_dout(0); -- 1 bit
                            readoutFineChannel <= arFIFO_dout(24 downto 1); -- 24 bits
                            readoutTimeGroup <= arFIFO_dout(28 downto 25);  -- 4 bits
                            readoutVCx16 <= arFIFO_dout(36 downto 29);
                            readoutKey <= arFIFO_dout(39 downto 38); -- "00" for normal data, "01" start correlation (end of block for row+col memories), "10" for end of tile = end of integration.
                            readoutTileLocation <= arFIFO_dout(47 downto 40);
                            readoutRowStations <= arFIFO_dout(56 downto 48);
                            readoutColStations <= arFIFO_dout(65 downto 57);
                            readoutTotalChannels <= arFIFO_dout(72 downto 66);
                            readoutTimeIntegration <= arFIFO_dout(73);
                            readoutFirst <= arFIFO_dout(74);
                            readoutStationOffset <= arFIFO_dout(76 downto 75); -- 4 ar requests to get 16 stations.
                            
                            readoutTotalStations <= arFIFO_dout(92 downto 77);
                            readoutSB <= arFIFO_dout(100 downto 93);
                            readoutBadPoly <= arFIFO_dout(133);
                            
                            if (arFIFO_dout(39 downto 38) = "00") then
                                if (unsigned(dataFIFO_rdCount) >= 64) then
                                    -- each ar request is for 32 x 64-byte words = 2048 bytes; at the read side of the data fifo this is 64 words.
                                    readout_fsm <= send_data;
                                else
                                    readout_fsm <= wait_data;
                                end if;
                            else
                                readout_fsm <= signal_correlator;
                            end if;
                        end if;
                        sendCount <= (others => '0');
                        
                    when wait_data =>
                        readout_fsm_dbg <= "0001";
                        if (unsigned(dataFIFO_rdCount) >= 16) then
                            readout_fsm <= send_data;
                        end if;
                        sendCount <= (others => '0');
                        
                    when send_data =>
                        readout_fsm_dbg <= "0010";
                        sendCount <= std_logic_vector(unsigned(sendCount) + 1);
                        if unsigned(sendCount) = 15 then
                            readout_fsm <= idle;
                        end if;
                    
                    when signal_correlator =>
                        readout_fsm_dbg <= "0011";
                        -- send notification to the correlator to run the correlator, or that the correlation is done.
                        readout_fsm <= wait_correlator_ready1;
                    
                    when wait_correlator_ready1 =>
                        readout_fsm_dbg <= "0100";
                        -- takes a few clocks to notify the correlator that the data is complete,
                        -- and for the correlator to indicate if it is ready for more data or not.
                        readout_fsm <= wait_correlator_ready2;
                    
                    when wait_correlator_ready2 =>
                        readout_fsm_dbg <= "0101";
                        readout_fsm <= wait_correlator_ready3;
                        
                    when wait_correlator_ready3 =>
                        readout_fsm_dbg <= "0110";
                        readout_fsm <= wait_correlator_ready;
                    
                    when wait_correlator_ready =>
                        readout_fsm_dbg <= "0111";
                        if i_cor_ready = '1' then
                            readout_fsm <= idle;
                        end if;
                    
                    when others =>
                        readout_fsm_dbg <= "1111";
                        readout_fsm <= idle;
                end case;
            end if;
            
            
            -- Pipeline stage to ensure data output comes from a register
            if (readout_fsm = send_data) then  -- fifo read enable is high in the send_data state, so dataFIFO_dout will be high one clock later.
                cor_valid <= '1';
            else
                cor_valid <= '0';
            end if;
            o_cor_valid <= cor_valid;
            o_cor_data <= dataFIFO_dout;
            
            sendCountDel1 <= sendCount;
            o_cor_time <= readoutTimeGroup(2 downto 0) & sendCountDel1(3 downto 0) & '0'; -- 8 bit output; time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
            o_cor_station <= readoutVCx16 & readoutStationOffset & "00"; -- 12 bit output; first of the 4 stations in o_cor_data
            o_cor_tileChannel <= readoutFineChannel; -- 24 bit output; Which 226 Hz fine channel is this relative to the start of the subarray-beam buffer.
            o_cor_tile_location <= "00" & readoutTileLocation;  
            o_cor_tileType <= readoutTriangle; -- 1 bit output; '0' for triangle, '1' for a square subset of the correlation matrix.
            o_cor_rowStations <= readoutRowStations;
            o_cor_colStations <= readoutColStations;
            o_cor_tileTotalChannels <= readoutTotalChannels(6 downto 0);
            o_cor_frameCount <= readoutFrameCount;
            if readoutFirst = '1' then 
                cor_first_int <= '1';
            elsif cor_last_int = '1' then
                cor_first_int <= '0';
            end if;
             
            if readout_fsm = signal_correlator and readoutKey(0) = '1' then
                cor_last_int <= '1'; --  out std_logic;  -- last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
            else
                cor_last_int <= '0';
            end if;
            if readout_fsm = signal_correlator and readoutKey(1) = '1' then
                o_cor_final <= '1';  -- Tells the correlator that the integration is complete.
            else
                o_cor_final <= '0';
            end if;
            if readoutTimeIntegration = '0' then
                -- 64 time samples to be integrated.
                o_cor_tileTotalTimes <= x"40";
            else -- 192 time samples to be integrated
                o_cor_tileTotalTimes <= x"C0";
            end if;
            
            -- Which entry is this in the subarray-beam table ? 
            o_cor_subarray_beam <= readoutSB; -- out std_logic_vector(7 downto 0);
            -- Total number of stations being processing for this subarray-beam.
            o_cor_totalStations <= readoutTotalStations; -- out std_logic_vector(15 downto 0);
            o_cor_BadPoly <= readoutBadPoly;
        end if;
    end process;
    
    o_cor_last <= cor_last_int;
    o_cor_first <= cor_first_int;
    
----------------------------------------------------------------------------------------
-- ILA debug

debug_ila : IF GENERATE_ILA GENERATE

    hbm_rd_debug : ila_0 PORT MAP (
        clk                     => i_axi_clk,
        probe0(63 downto 0)     => i_HBM_axi_r.data(63 downto 0),
        probe0(64)              => i_HBM_axi_r.valid,
        probe0(65)              => i_HBM_axi_r.last,
        probe0(67 downto 66)    => i_HBM_axi_r.resp,
    
        probe0(191 downto 68)   => (others => '0')
        );
        
END GENERATE;
        
end Behavioral;
