----------------------------------------------------------------------------------
-- Company: CSIRO 
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 06/18/2021 11:40:30 AM
-- Module Name: correlator - Behavioral
-- Description: 
--  Correlator. 
--   - Fully parallel "cell" of 16x16 stations
--   - Long term accumulator (LTA) that can process up to 16x16 = 256 cells, i.e. up to 256x256 stations.  
--
--
-- Structure:
--  mult-accumulate for 64 time samples is done using an 16x16 station matrix correlator.
--  After 64 samples have been accumulated, data is copied out to the long term accumulator.
--
--  Flow :
--    - Get data for 
--      - 1 fine channel;
--      - up to 256 stations;
--      - 64 time samples.
--    - Data is stored in the row and column BRAMs, which are double buffered, so new data can be loaded as the current data is being processed.
--    - Data in the row+col BRAMs is sufficient for partial integration of up to 256 cells (each cell is a 16x16 station block, computed in parallel in the correlator array)
--      - Multiple loads of the row/col data are required to integrate across more than 64 time samples and 1 fine channel.
--     
--
-- STRUCTURE:
--   * 16x16 (dual-pol) station correlator array
--   * Input data propagates down and to the right, to the row and column BRAMs.
--   * 64 time samples accumulated within the array
--   * Once every 64 clocks, accumulated values from within the array are read out.
--   * Accumulated values within the array move into a "XX_hold" register, and then shift out to the right.
--   * All rows are read out simultaneously in "visData(X,16)". Visibilities in the array are 24+24 bit integers.
--   * 4 clock cycles are required per station-pair to read out the data; XX, XY, YX, and YY correlations are read out in sequence.
--       - So 4*16 = 64 clocks are required to read out the data from the correlator array.
--   * Long term accumulator converts to 32 +32 bit integers for longer term accumulation.
---  * Long term accumulator readout converts to normalised floating point as required by SDP. 
--
--               
--                           col_bram0                   col_bram1                  col_bram2                             col_bram15
--   data in ------------->  stations 0,16,32... ------> stations 1,17,33,... -----> stations 2,18,34... -------> ... --> stations 15,31,47...
--             |              |                           |                           |                                    |
--            \/             \/                          \/                          \/                                   \/
--        row_bram0  ------> mult(0,0) ----------------> mult(0,1)-----------------> mult(0,2) -----------------> ... --> mult(0,15)                                  --------------------------------- 
--   stations 0,16,32...     | \accumulate 64 times      | \accumulate 64 times      | \accumulate 64 times               | \accumulate 64 times                      | Long Term Accumulator         |
--             |             |  \XX_hold                 |  \XX_hold                 |  \XX_hold                          |  \XX_hold                                 |                               |
--             |             |   \o_visData -------------+-->\o_visdata -------------+-->\o_visdata ------------> ... ----+---\o_visdata ---------> visData(0,16) ----|--> sum --> ultraRAM ->--\     |  
--             |             |                           |                           |                                                                                |     |           |       |     |
--            \/            \/                          \/                          \/                                                                                |     \-----<-----|       |     |
--        row_bram1 -------> mult(1,0) ----------------> mult(1,1) ----------------> mult(1,2) -----------------> ... --> mult(1,15)                                  |                         |     |
--   stations 1,17,33...     | \accumulate 64 times      | \accumulate 64 times      | \accumulate 64 times               | \accumulate 64 times                      |                         |     |
--             |             |  \XX_hold                 |  \XX_hold                 |  \XX_hold                          |  \XX_hold                                 |                         |     |
--             |             |   \o_visData -------------+-->\o_visdata -------------+-->\o_visdata ------------> ... ----+---\o_visdata ---------> visData(1,16) --->|--> sum --> ultraRAM ->-mux    |
--             |             |                           |                           |                                                                   ...          |     |           |       |     |
--            \/            \/                          \/                          \/                                                                                |     \-----<-----|       |     |
--        row_bram2 -------> mult(2,1) -----------------> ...                                                                                                        ...         ...          ...    ...
--   stations 2,18,34...     | \accumulate 64 times                                                                                                                   |                         |     |
--            |              |  \XX_hold                                                                                                                              |                         |     |
--           ...            ...                                                                                                                                       |                         |     |
--        row_bram15                                                                                                                                                  |--> sum --> ultraRAM ->-mux    |
--   stations 15,31, 47                                                                                                                                               |                         |     |
--                                                                                                                                                                    |                        \/     |
--                                                                                                                                                                    |                 fifo to cross |
--                                                                                                                                                                    |                 to i_axi_clk  |
--                                                                                                                                                                    |                        |      |
--                                                                                                                                                                    |                       \/      |
--                                                                                                                                                                    |         convert to normalised |
--                                                                                                                                                                    |            floating point     |
--                                                                                                                                                                    |                       |       |  
--                                                                                                                                                                    |                       |-------|---> o_data        
--                                                                                                                                                                    |                               |
--                                                                                                                                                                    ---------------------------------
--
--
--
----------------------------------------------------------------------------------
library IEEE, correlator_lib, common_lib, xpm;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
library DSP_top_lib;
--USE correlator_lib.correlator_reg_pkg.ALL;
USE common_lib.common_pkg.ALL;
use xpm.vcomponents.all;

Library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;
use correlator_lib.cmac_pkg.all;

entity full_correlator is
    port (
        -- clock used for all data input and output from this module (300 MHz)
        i_axi_clk : in std_logic;
        i_axi_rst : in std_logic;
        -- Processing clock used for the correlation (>412.5 MHz)
        i_cor_clk : in std_logic;
        i_cor_rst : in std_logic;
        ---------------------------------------------------------------
        -- Data in to the correlator arrays
        --
        -- correlator is ready to receive a new block of data. This will go low once data starts to be received.
        -- A block of data consists of data for 1 fine channel, 64 times, and 256 cells (i.e. 256 stations if on the diagonal, or up to 512 stations if row and column data is different)
        o_cor_ready : out std_logic;  
        -- Each 256 bit word : two time samples, 4 consecutive virtual channels
        -- (31:0) = time 0, virtual channel 0; (63:32) = time 0, virtual channel 1; (95:64) = time 0, virtual channel 2; (127:96) = time 0, virtual channel 3;
        -- (159:128) = time 1, virtual channel 0; (191:160) = time 1, virtual channel 1; (223:192) = time 1, virtual channel 2; (255:224) = time 1, virtual channel 3;
        i_cor_data  : in std_logic_vector(255 downto 0); 
        -- meta data
        i_cor_time     : in std_logic_vector(7 downto 0); -- time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
        -- Counts the stations in i_cor_data, always in steps of 4, where the value is the first of the 4 stations in i_cor_data
        -- If i_cor_tileType = '0', then up to 256 stations are delivered, with the same channels going to both row and column memories.
        --                          In this case, i_cor_VC_count will run from 0 to 256 in steps of 4.
        -- If i_cor_tileType = '1', then up to 512 channels are delivered, with different channels going to the row and column memories.
        --                          counts 0 to 255 go to the column memories, while counts 256-511 go to the row memories. 
        i_cor_station : in std_logic_vector(11 downto 0); 
        -- Options for tileType : 
        --   '0' = Triangle. In this case, all the input data goes to both the row and column memories, and a triangle from the correlation matrix is computed.
        --         The number of 16x16 correlation cells computed will be 
        --   '1' = Rectangle/square. In this case, 
        --            - The first "i_cor_col_stations" virtual channels on i_cor_data go to the column memories,
        --            - The next  "i_cor_row_stations" virtual channels go to the row memories.
        --         All correlation products for the rectangle are then computed.
        i_cor_tileType : in std_logic;
        i_cor_valid : in std_logic;  -- i_cor0_data, i_cor0_time, i_cor0_VC, i_cor0_FC and i_cor0_tileType are valid when i_cor0_valid = '1'
        -- i_cor0_last and i_cor0_final go high after a block of data has been sent.
        i_cor_last  : in std_logic;  -- last word in a block for correlation; Indicates that the correlator can start processing the tile just delivered.
        i_cor_first : in std_logic;  -- This is the first block of data for an integration - i.e. first fine channel, first block of 64 time samples, for this tile
        i_cor_final : in std_logic;  -- Indicates that at the completion of processing the most recent block of correlator data, the integration is complete. i_cor_tile and i_cor_tileChannel are valid when this is high.   
        -- up to 1024 different tiles; each tile is a subset of the correlation for particular subarray and beam.
        -- Tiles can be triangles or rectangles/squares from the full correlation.
        -- e.g. for 512x512 stations, there will be 3 tiles, consisting of 2 triangles and 1 square.
        --      for 4096x4096 stations, there will be 16 triangles, and 120 squares.
        -- bits 3:0 = tile column, bits 7:4 = tile row, bits 9:8 = "00";
        i_cor_tile : in std_logic_vector(9 downto 0);
        -- Fine channel, relative to the start of the buffer in HBM
        i_cor_tileChannel : in std_logic_vector(23 downto 0);
        i_cor_tileTotalTimes : in std_logic_vector(7 downto 0);    -- Number of time samples to integrate for this tile.
        i_cor_tiletotalChannels : in std_logic_Vector(4 downto 0); -- Number of frequency channels to integrate for this tile.
        i_cor_row_stations : in std_logic_vector(8 downto 0); -- number of stations in the row memories to process; up to 256.
        i_cor_col_stations : in std_logic_vector(8 downto 0); -- number of stations in the col memories to process; up to 256.
        i_cor_totalStations : in std_logic_vector(15 downto 0); -- Total number of stations being processing for this subarray-beam.
        i_cor_subarrayBeam : in std_logic_vector(7 downto 0);   -- Which entry is this in the subarray-beam table ?
        -- Data out to the HBM
        -- o_data is a burst of 16*16*4*8 = 8192 bytes = 256 clocks with 256 bits per clock, for one cell of visibilities, when o_dtype = '0'
        -- When o_dtype = '1', centroid data is being sent as a block of 16*16*2 = 512 bytes = 16 clocks with 256 bits per clock.
        o_data     : out std_logic_vector(255 downto 0);
        o_visValid : out std_logic;                     -- o_data is valid visibility data
        o_TCIvalid : out std_logic;                     -- o_data is valid TCI & DV data
        o_dcount   : out std_logic_vector(7 downto 0);  -- counts the 256 transfers for one cell of visibilites, or 16 transfers for the centroid data. 
        o_cell     : out std_logic_vector(7 downto 0);  -- a "cell" is a 16x16 station block of correlations
        o_cellLast : out std_logic;                     -- This is the last cell for the tile.
        o_tile     : out std_logic_vector(9 downto 0);  -- a "tile" is a 16x16 block of cells, i.e. a 256x256 station correlation.
        o_channel  : out std_logic_vector(23 downto 0); -- first fine channel index for this correlation.
        o_totalStations : out std_logic_vector(15 downto 0); -- total number of stations in this subarray-beam
        o_subarrayBeam : out std_logic_vector(7 downto 0);   -- Index into the subarray-beam table.
        
        -- stop sending data; somewhere downstream there is a FIFO that is almost full.
        -- There can be a lag of about 20 clocks between i_stop going high and data stopping.
        i_stop     : in std_logic
    );
end full_correlator;

architecture Behavioral of full_correlator is

    attribute dont_touch : string;
    signal colwrDataDel  : t_slv_64_arr(15 downto 0);
    signal rowWrDataDel  : t_slv_64_arr(15 downto 0);
    signal colWrAddrDel  : t_slv_10_arr(15 downto 0);
    signal rowWrAddrDel  : t_slv_10_arr(15 downto 0);
    signal colWrEnDel    : t_slv_1_arr(15 downto 0);
    signal rowWrEnDel    : t_slv_1_arr(15 downto 0);
    signal wrBuffer      : std_logic := '0';
    --type correlator_fsm_type is ( wait_start, run, done);
    --signal correlator_fsm : correlator_fsm_type := done;
    signal buf0_done_axi_clk, buf1_done_axi_clk : std_logic := '0';
    signal buf0Used, buf1Used : std_logic := '0';
    signal axi_to_cor_cdc_din : std_logic_vector(92 downto 0);
    signal tileChannel : std_logic_vector(23 downto 0);
    signal tileTotalTimes    : std_logic_vector(7 downto 0);    -- Number of time samples to integrate for this tile.
    signal tiletotalChannels : std_logic_Vector(4 downto 0);
    
    signal tileCount : std_logic_vector(9 downto 0);
    signal rowStations_minus1 : std_logic_vector(8 downto 0);
    signal colStations_minus1 : std_logic_vector(8 downto 0);
    signal axi_to_cor_src_rcv : std_logic;
    signal axi_to_cor_dest_out : std_logic_vector(92 downto 0);
    signal axi_to_cor_dest_req : std_logic;
    signal axi_to_cor_src_send : std_logic := '0';
    signal cdc_wrBuffer : std_logic;
    signal tileType : std_logic;
    signal tileFirst : std_logic;
    signal tileFinal : std_logic;
    
    signal rowRdAddrDel, colRdAddrDel : t_slv_11_arr(15 downto 0);
    
    type t_slv_17x17_arr32 is array(16 downto 0) of t_slv_32_arr(16 downto 0);
    signal colDataDel : t_slv_17x17_arr32;
    signal rowDataDel : t_slv_17x17_arr32;
    
    type rd_fsm_type is (idle, running, done);
    signal rd_fsm, rd_fsm_del1, rd_fsm_del2, rd_fsm_Del3, rd_fsm_del4 : rd_fsm_type := idle;
    signal buf0_tileCount, buf1_tileCount : std_logic_vector(9 downto 0);
    signal buf0_tileChannel, buf1_tileChannel : std_logic_vector(23 downto 0);
    signal buf0_rowStations_minus1, buf0_colStations_minus1, buf1_rowStations_minus1, buf1_colStations_minus1 : std_logic_vector(7 downto 0);
    signal buf0_tileType, buf1_tileType : std_logic := '0';
    signal buf0_tileTotalTimes, buf1_tileTotalTimes : std_logic_vector(7 downto 0);    -- Number of time samples to integrate for this tile.
    signal buf0_tiletotalChannels, buf1_tiletotalChannels : std_logic_vector(4 downto 0);
    
    signal cor_buf0_used, cor_buf1_used : std_logic := '0';
    signal cur_tileCount, tileDel1, tileDel2, tileDel3, tileDel4 : std_logic_Vector(9 downto 0);
    signal tileDel : t_slv_10_arr(23 downto 0);
    signal cur_tileChannel, channelDel1, channelDel2, channelDel3, channelDel4 : std_logic_vector(23 downto 0);
    signal channelDel : t_slv_24_arr(23 downto 0);
    signal cur_rowStations_minus1 : std_logic_vector(7 downto 0);
    signal cur_colStations_minus1 : std_logic_Vector(7 downto 0);
    signal cur_tileType : std_logic;
    signal cur_buf : std_logic := '0';
    signal corBuf0Done, corBuf1Done : std_logic;
    signal cur_tileFirst, cur_tileFinal : std_logic := '0';
    signal cur_totalTimes : std_logic_vector(7 downto 0);
    signal cur_totalChannels : std_logic_vector(4 downto 0);
    
    signal RdTime, rdTimeDel1, rdTimeDel2, rdTimeDel3, rdTimeDel4 : std_logic_vector(5 downto 0) := "000000";
    signal tileTime, cur_tileTime, buf0_tileTime, buf1_tileTime : std_logic_vector(1 downto 0) := "00";
    signal tileTimeDel1, tileTimeDel2, tileTimeDel3, tileTimeDel4 : std_logic_vector(1 downto 0) := "00";
    signal colRdVC, rowRdVC : std_logic_vector(3 downto 0) := "0000";
    
    type t_metaDel is array(16 downto 0) of t_cmac_input_bus_a(16 downto 0);
    signal rowMetaDel, colMetaDel : t_metaDel;
         
    signal array_visValid, shiftOut : t_slv_17_arr(16 downto 0);
    type t_slv_17x17_arr48 is array(16 downto 0) of t_slv_48_arr(16 downto 0);
    type t_slv_17x17_arr24 is array(16 downto 0) of t_slv_24_arr(16 downto 0);
    signal array_visData :  t_slv_17x17_arr48; -- 48 bit
    signal centroid : t_slv_17x17_arr24;
    signal shiftOutAdv : std_logic_vector(4 downto 0) := "00000";
    signal cell_visOutput, cell_visOutputDel1, cell_visOutputDel2, cell_visOutputDel3 : t_slv_48_arr(15 downto 0);
    signal cell_visOutputDel4, cell_visOutputDel5, cell_visOutputDel6 : t_slv_48_arr(15 downto 0);
    signal cell_centroidOutput, cell_centroidOutputDel1, cell_centroidOutputDel2 : t_slv_24_arr(15 downto 0);
    signal cell_centroidOutputDel3, cell_centroidOutputDel4, cell_centroidOutputDel5, cell_centroidOutputDel6 : t_slv_24_arr(15 downto 0);
    signal buf0_tileFirst, buf0_tileFinal, buf1_tileFirst, buf1_tileFinal : std_logic;
    signal tileFirstDel1, lastCellDel1, tileFirstDel2, lastCellDel2, tileFirstDel3, lastCellDel3, tileFirstDel4, lastCellDel4 : std_logic;
    signal tileFirstDel : std_logic_vector(23 downto 0);
    signal lastCellDel : std_logic_vector(23 downto 0);
    signal cellCount, cellCountDel1, cellCountDel2, cellCountDel3, cellCountDel4 : std_logic_vector(7 downto 0);
    signal cellDel : t_slv_8_arr(23 downto 0);   
    signal cellStartDel1, cellStartDel2, cellStartDel3, cellStartDel4 : std_logic;
    signal cellStartDel : std_logic_vector(23 downto 0);
    
    signal totalTimesDel1, totalTimesDel2, totalTimesDel3, totalTimesDel4 : std_logic_vector(7 downto 0);
    signal totalChannelsDel1, totalChannelsDel2, totalChannelsDel3, totalChannelsDel4 : std_logic_vector(4 downto 0);
    signal totalTimesDel : t_slv_8_arr(23 downto 0);
    signal totalChannelsDel : t_slv_5_arr(23 downto 0); 
    signal LTA_ready, LTA_ready_axi_clk, LTA_ready_hold : std_logic;
    
    signal colBRAMDout, rowBRAMDout : t_slv_32_arr(15 downto 0);
    signal row_invalid, col_invalid : std_logic_vector(15 downto 0);
    signal row_possibly_invalid, col_possibly_invalid : std_logic_vector(17 downto 0);
    signal last_row, last_col : t_slv_4_arr(17 downto 0);
    signal tileTotalStations : std_logic_vector(15 downto 0);
    signal tileSubarrayBeam : std_logic_vector(7 downto 0);
    
    signal buf0_tileTotalStations, buf1_tileTotalStations : std_logic_vector(15 downto 0);
    signal buf0_tileSubarrayBeam, buf1_tileSubarrayBeam : std_logic_vector(7 downto 0);
    
    signal totalStationsDel : t_slv_16_arr(23 downto 0);
    signal subarrayBeamDel  : t_slv_8_arr(23 downto 0);
    signal cur_totalStations : std_logic_vector(15 downto 0);
    signal cur_subarrayBeam : std_logic_vector(7 downto 0);
    signal totalStationsDel1, totalStationsDel2, totalStationsDel3, totalStationsDel4 : std_logic_vector(15 downto 0);
    signal subarrayBeamDel1, subarrayBeamDel2, subarrayBeamDel3, subarrayBeamDel4 : std_logic_vector(7 downto 0);
    
begin
    
    -- Data input pipeline, converts data from the corner turn into write data, address and enable for the row and column memories.
    rc_dini : entity correlator_lib.row_col_dataIn
    port map (
        i_axi_clk => i_axi_clk, -- in std_logic;
        --------------------------------------------------------------------------
        -- Data input from the corner turn
        i_cor_data  => i_cor_data, -- in std_logic_vector(255:0); 
        -- meta data
        i_cor_time  => i_cor_time, -- in std_logic_vector(7 downto 0); -- time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
        -- Counts the virtual channels in i_cor_data, always in steps of 4,where the value is the first of the 4 virtual channels in i_cor_data
        -- If i_cor_tileType = '0', then up to 256 channels are delivered, with the same channels going to both row and column memories.
        --                          In this case, i_cor_VC_count will run from 0 to 256 in steps of 4.
        -- If i_cor_tileType = '1', then up to 512 channels are delivered, with different channels going to the row and column memories.
        --                          counts 0 to 255 go to the column memories, while counts 256-511 go to the row memories. 
        i_cor_station => i_cor_station(8 downto 0), -- in (8:0); 
        -- Options for tileType : 
        --   '0' = Triangle. In this case, all the input data goes to both the row and column memories, and a triangle from the correlation matrix is computed.
        --            For correlation cells on the diagonal, only non-duplicate entries are sent out.
        --   '1' = Rectangle. In this case, the first 256 virtual channels on i_cor0_data go to the column memories, while the next 128 virtual channels go to the row memories.
        --            All correlation products for the rectangle are then computed.
        i_cor_tileType => i_cor_tileType, --  in std_logic;
        i_cor_valid    => i_cor_valid,    -- in std_logic;  -- i_cor0_data, i_cor0_time, i_cor0_VC, i_cor0_FC and i_cor0_tileType are valid when i_cor0_valid = '1'
        i_wrBuffer     => wrBuffer,       -- in std_logic; -- which half of the buffers to write to.
        ----------------------------------------------------------------------------
        -- Control signals to write data to the row and column memories.
        o_colWrData => colWrDataDel, -- out t_slv_64_arr(15:0);
        o_colWrAddr => colWrAddrDel, -- out t_slv_10_arr(15:0);
        o_colWrEn   => colWrEnDel,   -- out t_slv_1_arr(15:0);
        --
        o_rowWrData => rowWrDataDel, -- out t_slv_64_arr(15:0);
        o_rowWrAddr => rowWrAddrDel, -- out t_slv_10_arr(15:0);
        o_rowWrEn   => rowWrEnDel    -- out t_slv_1_arr(15:0)
    );
    
    
    col_ram_gen : for col_ram in 0 to 15 generate
            
        -- Each memory has, double buffered : 
        --   - 64 time samples
        --   - 16 stations
        --   - 2 polarisations = 4 bytes (re+im pol 0, re + im pol 1, one byte per value)
        -- Write side : 300 MHz, 2 dual-pol time samples written at a time.
        --              So 64 bits wide, 1024 deep = (2 [double buffer]) * (16 [stations]) * (32 [groups of 2 time samples])
        --              write address bits (4:0) = time sample
        --                                 (8:5) = station
        --                                 (9)   = double buffer
        -- Read side : >412.5 MHz, 1 dual-pol sample read per clock.
        --              so 32 bits wide x 2048 deep.
        --              read address bits (5:0) = time samples, (9:6) = station, (10) = double buffer.
        col_bram_inst : xpm_memory_sdpram
        generic map (
            ADDR_WIDTH_A => 10,              -- DECIMAL
            ADDR_WIDTH_B => 11,              -- DECIMAL
            AUTO_SLEEP_TIME => 0,            -- DECIMAL
            BYTE_WRITE_WIDTH_A => 64,        -- DECIMAL
            CASCADE_HEIGHT => 0,             -- DECIMAL
            CLOCKING_MODE => "independent_clock", -- String
            ECC_MODE => "no_ecc",            -- String
            MEMORY_INIT_FILE => "none",      -- String
            MEMORY_INIT_PARAM => "0",        -- String
            MEMORY_OPTIMIZATION => "true",   -- String
            MEMORY_PRIMITIVE => "auto",      -- String
            MEMORY_SIZE => 65536,            -- DECIMAL  -- Total bits in the memory; 2048 * 32 = 65536
            MESSAGE_CONTROL => 0,            -- DECIMAL
            READ_DATA_WIDTH_B => 32,         -- DECIMAL
            READ_LATENCY_B => 3,             -- DECIMAL
            READ_RESET_VALUE_B => "0",       -- String
            RST_MODE_A => "SYNC",            -- String
            RST_MODE_B => "SYNC",            -- String
            SIM_ASSERT_CHK => 0,             -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
            USE_EMBEDDED_CONSTRAINT => 0,    -- DECIMAL
            USE_MEM_INIT => 0,               -- DECIMAL
            WAKEUP_TIME => "disable_sleep",  -- String
            WRITE_DATA_WIDTH_A => 64,        -- DECIMAL
            WRITE_MODE_B => "read_first"     -- String
        ) port map (
            dbiterrb => open,                -- 1-bit output: Status signal to indicate double bit error occurrence on the data output of port A.
            doutb => colBRAMDout(col_ram),   -- READ_DATA_WIDTH_B-bit output: Data output for port B read operations.
            sbiterrb => open,                -- 1-bit output: Status signal to indicate single bit error occurrence on the data output of port B.
            addra => colWrAddrDel(col_ram),  -- ADDR_WIDTH_A-bit input: Address for port A write and read operations.
            addrb => colRdAddrDel(col_ram),  -- ADDR_WIDTH_B-bit input: Address for port B write and read operations.
            clka => i_axi_clk,               -- 1-bit input: Clock signal for port A. Also clocks port B when parameter CLOCKING_MODE is "common_clock".
            clkb => i_cor_clk,               -- Unused when parameter CLOCKING_MODE is "common_clock".
            dina => colWrDatadel(col_ram),   -- WRITE_DATA_WIDTH_A-bit input: Data input for port A write operations.
            ena => '1',                 -- 1-bit input: Memory enable signal for port A.
            enb => '1',                 -- 1-bit input: Memory enable signal for port B.
            injectdbiterra => '0',      -- 1-bit input: Controls double bit error injection on input data
            injectsbiterra => '0',      -- 1-bit input: Controls single bit error injection on input data
            regceb => '1',              -- 1-bit input: Clock Enable for the last register stage on the output data path.
            rstb => '0',                -- 1-bit input: Reset signal for the final port B output register
            sleep => '0',               -- 1-bit input: sleep signal to enable the dynamic power saving feature.
            wea => colWrEnDel(col_ram) -- WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-bit input: Write enable vector for port A input data port dina. 
        );
    end generate;
    
    row_ram_gen : for row_ram in 0 to 15 generate
    
        row_bram_inst : xpm_memory_sdpram
        generic map (
            ADDR_WIDTH_A => 10,              -- DECIMAL
            ADDR_WIDTH_B => 11,              -- DECIMAL
            AUTO_SLEEP_TIME => 0,            -- DECIMAL
            BYTE_WRITE_WIDTH_A => 64,        -- DECIMAL
            CASCADE_HEIGHT => 0,             -- DECIMAL
            CLOCKING_MODE => "independent_clock", -- String
            ECC_MODE => "no_ecc",            -- String
            MEMORY_INIT_FILE => "none",      -- String
            MEMORY_INIT_PARAM => "0",        -- String
            MEMORY_OPTIMIZATION => "true",   -- String
            MEMORY_PRIMITIVE => "auto",      -- String
            MEMORY_SIZE => 65536,            -- DECIMAL  -- Total bits in the memory; 2048 * 32 = 65536
            MESSAGE_CONTROL => 0,            -- DECIMAL
            READ_DATA_WIDTH_B => 32,         -- DECIMAL
            READ_LATENCY_B => 3,             -- DECIMAL
            READ_RESET_VALUE_B => "0",       -- String
            RST_MODE_A => "SYNC",            -- String
            RST_MODE_B => "SYNC",            -- String
            SIM_ASSERT_CHK => 0,             -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
            USE_EMBEDDED_CONSTRAINT => 0,    -- DECIMAL
            USE_MEM_INIT => 0,               -- DECIMAL
            WAKEUP_TIME => "disable_sleep",  -- String
            WRITE_DATA_WIDTH_A => 64,        -- DECIMAL
            WRITE_MODE_B => "read_first"     -- String
        ) port map (
            dbiterrb => open,               -- 1-bit output: Status signal to indicate double bit error occurrence on the data output of port A.
            doutb => rowBRAMDout(row_ram),  -- READ_DATA_WIDTH_B-bit output: Data output for port B read operations.
            sbiterrb => open,               -- 1-bit output: Status signal to indicate single bit error occurrence on the data output of port B.
            addra => rowWrAddrDel(row_ram), -- ADDR_WIDTH_A-bit input: Address for port A write and read operations.
            addrb => rowRdAddrDel(row_ram), -- ADDR_WIDTH_B-bit input: Address for port B write and read operations.
            clka => i_axi_clk,              -- 1-bit input: Clock signal for port A. Also clocks port B when parameter CLOCKING_MODE is "common_clock".
            clkb => i_cor_clk,              -- Unused when parameter CLOCKING_MODE is "common_clock".
            dina => rowWrDatadel(row_ram),  -- WRITE_DATA_WIDTH_A-bit input: Data input for port A write operations.
            ena => '1',                 -- 1-bit input: Memory enable signal for port A.
            enb => '1',                 -- 1-bit input: Memory enable signal for port B.
            injectdbiterra => '0',      -- 1-bit input: Controls double bit error injection on input data
            injectsbiterra => '0',      -- 1-bit input: Controls single bit error injection on input data
            regceb => '1',              -- 1-bit input: Clock Enable for the last register stage on the output data path.
            rstb => '0',                -- 1-bit input: Reset signal for the final port B output register
            sleep => '0',               -- 1-bit input: sleep signal to enable the dynamic power saving feature.
            wea => rowWrEnDel(row_ram) -- WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-bit input: Write enable vector for port A input data port dina. 
        );
    
    end generate;    

    -- Trigger processing of the row+col memory data.
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            if i_axi_rst = '1' then
                wrBuffer <= '0';
            elsif i_cor_last = '1' then
                wrBuffer <= not wrBuffer;
            end if;
            
            if ((i_axi_rst = '1') or (buf0_done_axi_clk = '1')) then
                buf0Used <= '0';
            elsif i_cor_last = '1' and wrBuffer = '0' then
                buf0Used <= '1';
            end if;

            if ((i_axi_rst = '1') or (buf1_done_axi_clk = '1')) then
                buf1Used <= '0';
            elsif i_cor_last = '1' and wrBuffer = '1' then
                buf1Used <= '1';
            end if;
            
            if ((LTA_ready_hold = '1') and ((wrBuffer = '0' and buf0Used = '0') or (wrBuffer = '1' and buf1Used = '0'))) then
                o_cor_ready <= '1';
            else
                o_cor_ready <= '0';
            end if;

            if i_cor_last = '1' and i_cor_final = '1' and LTA_ready_axi_clk = '0' then
                LTA_ready_hold <= '0';
            elsif LTA_ready_axi_clk = '1' then
                LTA_ready_hold <= '1';
            end if; 

            -- Signal correlator clock domain that the buffer is done and ready to be processed. 
            if i_cor_last = '1' then
                tileCount <= i_cor_tile; -- 10 bit tile index input
                -- Which block of frequency channels is this tile for ?
                -- This sets the offset within the HBM that the result is written to, relative to the base address which is extracted from registers based on i_cor0_tileCount.
                tileChannel <= i_cor_tileChannel;   -- 24 bits.
                tileTotalStations <= i_cor_totalStations;
                tileSubarrayBeam <= i_cor_subArrayBeam;
                tileTotalTimes <= i_cor_tileTotalTimes; -- in 8 bits; Number of time samples to integrate for this tile.
                tileTotalChannels <= i_cor_tiletotalChannels; -- 5 bits input
                tileTime <= i_cor_time(7 downto 6); -- which block of 64 time samples is this ?
                tileFirst <= i_cor_first;           -- first block of data for this tile;
                tileFinal <= i_cor_final;           -- This is the last block of input data for the integration for this tile.
                rowStations_minus1 <= std_logic_vector(unsigned(i_cor_row_stations) - 1); -- 9 bit value; The number of stations in the row memories to process
                colStations_minus1 <= std_logic_vector(unsigned(i_cor_col_stations) - 1); -- 9 bits
                tileType <= i_cor_tileType;
                cdc_wrBuffer <= wrBuffer;
                axi_to_cor_src_send <= '1';
            elsif axi_to_cor_src_rcv = '1' then
                axi_to_cor_src_send <= '0';
            end if;
            
        end if;
    end process;    
    
    axi_to_cor_cdc_din(9 downto 0) <= tileCount;
    axi_to_cor_cdc_din(33 downto 10) <= tileChannel;
    axi_to_cor_cdc_din(41 downto 34) <= rowStations_minus1(7 downto 0);
    axi_to_cor_cdc_din(49 downto 42) <= colStations_minus1(7 downto 0);
    axi_to_cor_cdc_din(51 downto 50) <= tileTime;
    axi_to_cor_cdc_din(59 downto 52) <= tileTotalTimes;
    axi_to_cor_cdc_din(64 downto 60) <= tileTotalChannels;
    axi_to_cor_cdc_din(65) <= tileType;
    axi_to_cor_cdc_din(66) <= cdc_wrBuffer;
    axi_to_cor_cdc_din(67) <= tileFirst;
    axi_to_cor_cdc_din(68) <= tileFinal;
    axi_to_cor_cdc_din(84 downto 69) <= tileTotalStations;
    axi_to_cor_cdc_din(92 downto 85) <= tileSubarrayBeam;

    xpm_cdc_handshake_inst : xpm_cdc_handshake
    generic map (
        DEST_EXT_HSK => 0,   -- DECIMAL; 0=internal handshake, 1=external handshake
        DEST_SYNC_FF => 4,   -- DECIMAL; range: 2-10
        INIT_SYNC_FF => 1,   -- DECIMAL; 0=disable simulation init values, 1=enable simulation init values
        SIM_ASSERT_CHK => 0, -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        SRC_SYNC_FF => 4,    -- DECIMAL; range: 2-10
        WIDTH => 93           -- DECIMAL; range: 1-1024
    ) port map (
        dest_out => axi_to_cor_dest_out, -- WIDTH-bit output: Input bus (src_in) synchronized to destination clock domain. This output is registered.
        dest_req => axi_to_cor_dest_req, -- 1-bit output: Assertion of this signal indicates that new dest_out data has been received and is ready to be used or captured by the destination logic.
        src_rcv => axi_to_cor_src_rcv,   -- 1-bit output: Acknowledgement from destination logic that src_in has been received. This signal will be deasserted once destination handshake has fully completed, thus completing a full data transfer. This output is registered.
        dest_ack => '0',      -- 1-bit input: optional; required when DEST_EXT_HSK = 1
        dest_clk => i_cor_clk, -- 1-bit input: Destination clock.
        src_clk => i_axi_clk,   -- 1-bit input: Source clock.
        src_in => axi_to_cor_cdc_din,     -- WIDTH-bit input: Input bus that will be synchronized to the destination clock domain.
        src_send => axi_to_cor_src_send  -- 1-bit input: Assertion of this signal allows the src_in bus to be synchronized to the destination clock domain.
    );


    xpm_cdc_pulse1_inst : xpm_cdc_pulse
    generic map (
        DEST_SYNC_FF => 4,   -- DECIMAL; range: 2-10
        INIT_SYNC_FF => 1,   -- DECIMAL; 0=disable simulation init values, 1=enable simulation init values
        REG_OUTPUT => 0,     -- DECIMAL; 0=disable registered output, 1=enable registered output
        RST_USED => 0,       -- DECIMAL; 0=no reset, 1=implement reset
        SIM_ASSERT_CHK => 0  -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
    ) port map (
        dest_pulse => buf0_done_axi_clk, -- 1-bit output: Outputs a pulse the size of one dest_clk period when a pulse transfer is correctly initiated on src_pulse input. 
        dest_clk => i_axi_clk,     -- 1-bit input: Destination clock.
        src_clk => i_cor_clk,       -- 1-bit input: Source clock.
        src_pulse => corBuf0Done,   -- 1-bit input: Rising edge of this signal initiates a pulse transfer to the destination clock domain. 
        src_rst => '0',
        dest_rst => '0'
    );

    xpm_cdc_pulse2_inst : xpm_cdc_pulse
    generic map (
        DEST_SYNC_FF => 4,   -- DECIMAL; range: 2-10
        INIT_SYNC_FF => 1,   -- DECIMAL; 0=disable simulation init values, 1=enable simulation init values
        REG_OUTPUT => 0,     -- DECIMAL; 0=disable registered output, 1=enable registered output
        RST_USED => 0,       -- DECIMAL; 0=no reset, 1=implement reset
        SIM_ASSERT_CHK => 0  -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
    ) port map (
        dest_pulse => buf1_done_axi_clk, -- 1-bit output: Outputs a pulse the size of one dest_clk period when a pulse transfer is correctly initiated on src_pulse input. 
        dest_clk => i_axi_clk,           -- 1-bit input: Destination clock.
        src_clk => i_cor_clk,            -- 1-bit input: Source clock.
        src_pulse => corBuf1Done,  -- 1-bit input: Rising edge of this signal initiates a pulse transfer to the destination clock domain. 
        src_rst => '0',
        dest_rst => '0'
    );
    
    
    process(i_cor_clk)
    begin
        if rising_edge(i_cor_clk) then
            --------------------------------------------------------------------------
            -- Control signals to and from the axi clock domain
            if axi_to_cor_dest_req = '1' then
                if axi_to_cor_dest_out(66) = '0' then  -- input buffer 0 has just been written.
                    buf0_tileCount <= axi_to_cor_dest_out(9 downto 0);
                    buf0_tileChannel <= axi_to_cor_dest_out(33 downto 10);
                    buf0_rowStations_minus1 <= axi_to_cor_dest_out(41 downto 34);
                    buf0_colStations_minus1 <= axi_to_cor_dest_out(49 downto 42);
                    buf0_tileTime <= axi_to_cor_dest_out(51 downto 50);
                    buf0_tileTotalTimes <= axi_to_cor_dest_out(59 downto 52);
                    buf0_tileTotalChannels <= axi_to_cor_dest_out(64 downto 60);
                    buf0_tileType <= axi_to_cor_dest_out(65);
                    buf0_tileFirst <= axi_to_cor_dest_out(67);
                    buf0_tileFinal <= axi_to_cor_dest_out(68);
                    buf0_tileTotalStations <= axi_to_cor_dest_out(84 downto 69);
                    buf0_tileSubarrayBeam <= axi_to_cor_dest_out(92 downto 85);
                else
                    -- Input buffer 1 has just been written.
                    buf1_tileCount <= axi_to_cor_dest_out(9 downto 0);
                    buf1_tileChannel <= axi_to_cor_dest_out(33 downto 10);
                    buf1_rowStations_minus1 <= axi_to_cor_dest_out(41 downto 34);
                    buf1_colStations_minus1 <= axi_to_cor_dest_out(49 downto 42);
                    buf1_tileTime <= axi_to_cor_dest_out(51 downto 50);
                    buf1_tileTotalTimes <= axi_to_cor_dest_out(59 downto 52);
                    buf1_tileTotalChannels <= axi_to_cor_dest_out(64 downto 60);
                    buf1_tileType <= axi_to_cor_dest_out(65);
                    buf1_tileFirst <= axi_to_cor_dest_out(67);
                    buf1_tileFinal <= axi_to_cor_dest_out(68);
                    buf1_tileTotalStations <= axi_to_cor_dest_out(84 downto 69);
                    buf1_tileSubarrayBeam <= axi_to_cor_dest_out(92 downto 85);
                end if;
            end if;
            
            if axi_to_cor_dest_req = '1' and axi_to_cor_dest_out(66) = '0' then
                cor_buf0_used <= '1';
            elsif rd_fsm = done and cur_buf = '0' then
                cor_buf0_used <= '0';
            end if;
            
            if rd_fsm = done and cur_buf = '0' then
                corBuf0Done <= '1';
            else
                corBuf0Done <= '0';
            end if;
            
            if axi_to_cor_dest_req = '1' and axi_to_cor_dest_out(66) = '1' then
                cor_buf1_used <= '1';
            elsif rd_fsm = done and cur_buf = '1' then
                cor_buf1_used <= '0';
            end if;
            
            if rd_fsm = done and cur_buf = '1' then
                corBuf1Done <= '1';
            else
                corBuf1Done <= '0';
            end if;
            
            -------------------------------------------------------------------------
            case rd_fsm is
                when idle =>
                    -- This state machine runs processing of a tile, i.e. correlations for a 256x256 array of stations.
                    -- The state machine will be triggered multiple times for the same tile to integrate across all 192 time samples and e.g. 24 frequency channels.
                    if cor_buf0_used = '1' or cor_buf1_used = '1' then
                        rd_fsm <= running;
                    end if;
                    if cor_buf0_used = '1' then
                        cur_tileCount <= buf0_tileCount;
                        cur_tileChannel <= buf0_tileChannel;
                        cur_totalStations <= buf0_tileTotalStations;
                        cur_subarrayBeam <= buf0_tileSubarrayBeam;
                        cur_rowStations_minus1 <= buf0_rowStations_minus1;
                        cur_colStations_minus1 <= buf0_colStations_minus1;
                        cur_tileType <= buf0_tileType;
                        cur_totalTimes <= buf0_tileTotalTimes;
                        cur_totalChannels <= buf0_tileTotalChannels;
                        cur_tileTime <= buf0_tileTime;
                        cur_tileFirst <= buf0_tilefirst;
                        cur_tileFinal <= buf0_tileFinal;
                        cur_buf <= '0';
                    elsif cor_buf1_used = '1' then
                        cur_tileCount <= buf1_tileCount;
                        cur_tileChannel <= buf1_tileChannel;
                        cur_totalStations <= buf1_tileTotalStations;
                        cur_subarrayBeam <= buf1_tileSubarrayBeam;
                        cur_rowStations_minus1 <= buf1_rowStations_minus1;
                        cur_colStations_minus1 <= buf1_colStations_minus1;
                        -- "cells" is the number of blocks of 16x16 stations to do.
                        -- 0 to 15 colstations_minus1 --> number of cells = 1 (cell 0)
                        -- 17 to 32 colStations -->  number of cells = 2 (cells 0 and 1)
                        -- etc.
                        cur_tileType <= buf1_tileType;
                        cur_totalTimes <= buf1_tileTotalTimes;
                        cur_totalChannels <= buf1_tileTotalChannels;
                        cur_tileTime <= buf1_tileTime;
                        cur_tileFirst <= buf1_tileFirst;
                        cur_tileFinal <= buf1_tileFinal;
                        cur_buf <= '1';
                    end if;
                    -- row and col memory read address : bits (5:0) = time samples, (9:6) = station, (10) = double buffer.
                    RdTime <= "000000";
                    -- colRdVC and rowRdVC refer to the group of 16 stations that are being processed in the current cell.
                    -- The station within the group doesn't need to be selected because they are distributed across the different BRAMs. 
                    colRdVC <= "0000";  
                    rowRdVC <= "0000";
                    -- count of which cell we are currently up to processing in this tile. Counts 0 to (up to) 255.
                    cellCount <= "00000000";
                    
                when running => 
                    RdTime <= std_logic_vector(unsigned(RdTime) + 1);
                    if (rdTime = "111111") then
                        cellCount <= std_logic_vector(unsigned(cellCount) + 1);
                        if cur_tileType = '0' then -- triangle
                            -- say 16 stations, then colStations = "000010000", and stop when colRdVC = 0, i.e. only do one 16x16 correlator cell.
                            --if colRdVC = cur_colStations_minus1(7 downto 4) then
                            if colRdVC = rowRdVC then -- triangle, so once the column = row, go to the next row
                                colRdVC <= "0000";
                                rowRdVC <= std_logic_vector(unsigned(rowRdVC) + 1);
                                if rowRdVC = cur_rowStations_minus1(7 downto 4) then
                                    rd_fsm <= done;
                                end if;
                            else
                                colRdVC <= std_logic_vector(unsigned(colRdVC) + 1);
                            end if;
                        else 
                            -- rectangle or square.
                            -- Process all 16 cells in the column then go to the next row.
                            if colRdVC = "1111" then
                                colRdVC <= "0000";
                                rowRdVC <= std_logic_vector(unsigned(rowRdVC) + 1);
                                if rowRdVC = cur_rowStations_minus1(7 downto 4) then
                                    rd_fsm <= done;
                                end if;
                            else
                                colRdVC <= std_logic_vector(unsigned(colRdVC) + 1);
                            end if;
                        end if;
                    end if;
                
                when done =>
                    -- notify that we have processed all the data in the input buffer
                    rd_fsm <= idle;
                    
                when others =>
                    rd_fsm <= idle;
                
            end case;
            
            colRdAddrDel(0)(10) <= cur_buf;
            colRdAddrDel(0)(9 downto 6) <= colRdVC;
            colRdAddrDel(0)(5 downto 0) <= rdTime;
            
            if (cur_tileType = '0' and (colRdVC = cur_colStations_minus1(7 downto 4))) then
                -- triangle, and last block of 16 columns
                col_possibly_invalid(0) <= '1';
            else
                col_possibly_invalid(0) <= '0';
            end if;
            last_col(0) <= cur_colStations_minus1(3 downto 0);
            
            col_possibly_invalid(17 downto 1) <= col_possibly_invalid(16 downto 0);
            last_col(17 downto 1) <= last_col(16 downto 0);
            
            if (cur_tileType = '0' and (rowRdVC = cur_rowStations_minus1(7 downto 4))) then
                -- triangle, and last block of 16 rows
                row_possibly_invalid(0) <= '1';
            else
                row_possibly_invalid(0) <= '0';
            end if;
            last_row(0) <= cur_rowStations_minus1(3 downto 0);
            
            row_possibly_invalid(17 downto 1) <= row_possibly_invalid(16 downto 0);
            last_row(17 downto 1) <= last_row(16 downto 0);
            
            rowRdAddrDel(0)(10) <= cur_buf;
            rowRdAddrDel(0)(9 downto 6) <= rowRdVC;
            rowRdAddrDel(0)(5 downto 0) <= rdTime;
            
            colRdAddrDel(15 downto 1) <= colRdAddrDel(14 downto 0);
            rowRdAddrDel(15 downto 1) <= rowRdAddrDel(14 downto 0);
            
            rd_fsm_del1 <= rd_fsm; -- rd_fsm_del1 aligns with colRdAddrDel(0), rowRdAddrDel(0), i.e. when rd_fsm_del1 = running, there is a valid address to the (first) row and column memories.
            rdTimeDel1 <= rdTime;
            tileTimeDel1 <= cur_tileTime;
            tileFirstDel1 <= cur_tileFirst;
            tileDel1 <= cur_tileCount;
            channelDel1 <= cur_tileChannel;
            totalStationsDel1 <= cur_totalStations;
            subarrayBeamDel1 <= cur_subarrayBeam;
            
            totalTimesDel1 <= cur_totalTimes;
            totalChannelsDel1 <= cur_totalChannels;
            if ((cur_tileFinal = '1') and (rd_fsm = running) and (colRdVC = cur_colStations_minus1(7 downto 4)) and (rowRdVC = cur_rowStations_minus1(7 downto 4))) then
                lastCellDel1  <= '1';
            else
                lastCellDel1 <= '0';
            end if;
            if ((rd_fsm = running) and (rdTime = "000000")) then
                cellStartDel1 <= '1';
            else
                cellStartDel1 <= '0';
            end if;
            cellCountDel1 <= cellCount;

            --
            rd_fsm_del2 <= rd_fsm_del1;
            rdTimeDel2 <= rdTimeDel1;
            tileTimeDel2 <= tileTimeDel1;
            tileFirstDel2 <= tileFirstDel1;
            lastCellDel2 <= lastCellDel1;
            cellCountDel2 <= cellCountDel1;
            cellStartDel2 <= cellStartDel1;
            tileDel2 <= tileDel1;
            channelDel2 <= channelDel1;
            totalStationsDel2 <= totalStationsDel1;
            subarrayBeamDel2 <= subarrayBeamDel1;
            
            totalTimesDel2 <= totalTimesDel1;
            totalChannelsDel2 <= totalChannelsDel1;
            
            --
            rd_fsm_del3 <= rd_fsm_del2;
            rdTimeDel3 <= rdTimeDel2;
            tileTimeDel3 <= tileTimeDel2;
            tileFirstDel3 <= tileFirstDel2;
            lastCellDel3 <= lastCellDel2;
            cellCountDel3 <= cellCountDel2;
            cellStartDel3 <= cellStartDel2;
            tileDel3 <= tileDel2;
            channelDel3 <= channelDel2;
            totalTimesDel3 <= totalTimesDel2;
            totalChannelsDel3 <= totalChannelsDel2;
            totalStationsDel3 <= totalStationsDel2;
            subarrayBeamDel3 <= subarrayBeamDel2;
            
            -- rd_fsm_del4 aligns with the data output from the first row and col memories, 
            -- i.e. colBRAMDout, rowBRAMDout(0), since there is a 3 cycle read latency for the memories.
            rd_fsm_del4 <= rd_fsm_del3;
            rdTimeDel4 <= rdTimeDel3;
            tileTimeDel4 <= tileTimeDel3;
            
            tileFirstDel4 <= tileFirstDel3;
            lastCellDel4 <= lastCellDel3;
            cellCountDel4 <= cellCountDel3;
            cellStartDel4 <= cellStartDel3;
            tileDel4 <= tileDel3;
            channelDel4 <= channelDel3;
            totalTimesDel4 <= totalTimesDel3;
            totalChannelsDel4 <= totalChannelsDel3;
            totalStationsDel4 <= totalStationsDel3;
            subarrayBeamDel4 <= subarrayBeamDel3;
            
        end if;
    end process;            
    
    
    process(i_cor_clk)
    begin
        if rising_edge(i_cor_clk) then
           
            --
            if (rd_fsm_del4 = running) then
                colMetaDel(0)(0).vld <= '1';
                rowMetaDel(0)(0).vld <= '1';
            else
                colMetaDel(0)(0).vld <= '0';
                rowMetaDel(0)(0).vld <= '0';
            end if;
            
            if rdTimeDel4 = "000000" then
                colMetaDel(0)(0).first <= '1';
                rowMetaDel(0)(0).first <= '1';
            else
                colMetaDel(0)(0).first <= '0';
                rowMetaDel(0)(0).first <= '0';
            end if;
            
            if rdTimeDel4 = "111111" then
                colMetaDel(0)(0).last <= '1';
                rowMetaDel(0)(0).last <= '1';
                shiftOutAdv(0) <= '1';
                -- These control signals only get updated at the end of the 64 time samples being sent into the correlator cell.
                tileFirstDel(0) <= tileFirstDel4;
                lastCellDel(0) <= lastCellDel4;
                cellDel(0) <= cellCountDel4;
                cellStartDel(0) <= '1';  -- cellStartDel(0) aligns with the data going into the first cmac;
                tileDel(0) <= tileDel4;
                channelDel(0) <= channelDel4;
                totalTimesDel(0) <= totalTimesDel4;
                totalChannelsDel(0) <= totalChannelsDel4;
                totalStationsDel(0) <= totalStationsDel4;
                subarrayBeamDel(0) <= subarrayBeamDel4;
            else
                colMetaDel(0)(0).last <= '0';
                rowMetaDel(0)(0).last <= '0';
                shiftOutAdv(0) <= '0';
                cellStartDel(0) <= '0';
            end if;
            
            --
            totalTimesDel(23 downto 1) <= totalTimesDel(22 downto 0);
            totalChannelsDel(23 downto 1) <= totalChannelsDel(22 downto 0);
            tileDel(23 downto 1) <= tileDel(22 downto 0);
            channelDel(23 downto 1) <= channelDel(22 downto 0);
            cellStartDel(23 downto 1) <= cellStartDel(22 downto 0); -- data going to the LTA will be about 16 + 4 clocks later 
            tileFirstDel(23 downto 1) <= tileFirstDel(22 downto 0);
            lastCellDel(23 downto 1) <= lastCellDel(22 downto 0);
            cellDel(23 downto 1) <= cellDel(22 downto 0);
            totalStationsDel(23 downto 1) <= totalStationsDel(22 downto 0);
            subarrayBeamDel(23 downto 1) <= subarrayBeamDel(22 downto 0);
            
            rowMetaDel(0)(0).sample_cnt(5 downto 0) <= rdTimeDel4;
            rowMetaDel(0)(0).sample_cnt(7 downto 6) <= tileTimeDel4;
            colMetaDel(0)(0).sample_cnt(5 downto 0) <= rdTimeDel4;
            colMetaDel(0)(0).sample_cnt(7 downto 6) <= tileTimeDel4;

            -- First entry in the shift out pipeline needs to align with valid data in the first cmac_quad.
            -- So 5 cycle latency here:
            shiftOutAdv(4 downto 1) <= shiftOutAdv(3 downto 0);
            shiftOut(0)(0) <= shiftOutAdv(4); -- 5 cycles = 4 in shiftOutAdv pipeline, then 1 to get shiftOut(0)(0)

        end if;
    end process;            
    
    -- The next two generate statements were initially written using a for loop within a process, 
    -- but that triggered a vivado simulator bug. 
    -- The simulator can't handle for loops inside a process, in the case where 
    -- only part of an array signal is assigned.
    first_row_copy : for col in 0 to 15 generate
        
        process(i_cor_clk)
        begin
            if rising_edge(i_cor_clk) then
                colMetaDel(0)(col+1).vld <= colMetaDel(0)(col).vld;
                colMetaDel(0)(col+1).first <= colMetaDel(0)(col).first;
                colMetaDel(0)(col+1).last <= colMetaDel(0)(col).last;
                colMetaDel(0)(col+1).sample_cnt <= colMetaDel(0)(col).sample_cnt;
                
                if (col_possibly_invalid(col+2) = '1' and 
                    (col > unsigned(last_col(col+2)))) then
                    -- column is out of range for the correlation.
                    -- +2 in above indeces to account for memory read latency.
                    col_invalid(col) <= '1';
                else
                    col_invalid(col) <= '0';
                end if;
                
                -- Convert flagged samples (i.e. values of -128) to zeros so they don't contribute
                -- to the integration, and mark them as flagged in the meta data.
                if (colBRAMDout(col)(7 downto 0) = "10000000" or
                    colBRAMDout(col)(15 downto 8) = "10000000" or 
                    colBRAMDout(col)(23 downto 16) = "10000000" or 
                    colBRAMDout(col)(31 downto 24) = "10000000" or
                    col_invalid(col) = '1') then
                    -- If real or imaginary in either polarisation is flagged, then the sample is bad.
                    colDataDel(0)(col) <= (others => '0');
                    colMetaDel(0)(col).rfi <= '1';
                else
                    colDataDel(0)(col) <= colBRAMDout(col);
                    colMetaDel(0)(col).rfi <= '0';
                end if;
                
            end if;
        end process;
         
    end generate;
    
    first_col_copy : for row in 0 to 15 generate

        array_visValid(row)(0) <= '0';
        array_visData(row)(0) <= (others => '0');
        process(i_cor_clk)
        begin
            if rising_edge(i_cor_clk) then
                
                rowMetaDel(row+1)(0).vld <= rowMetaDel(row)(0).vld;
                rowMetaDel(row+1)(0).first <= rowMetaDel(row)(0).first;
                rowMetaDel(row+1)(0).last <= rowMetaDel(row)(0).last;
                rowMetaDel(row+1)(0).sample_cnt <= rowMetaDel(row)(0).sample_cnt;
                shiftOut(row+1)(0) <= shiftOut(row)(0);
                
                if (row_possibly_invalid(row+2) = '1' and 
                    (row > unsigned(last_row(row+2)))) then
                    -- row is out of range for the correlation.
                    -- +2 in above indeces to account for memory read latency.
                    row_invalid(row) <= '1';
                else
                    row_invalid(row) <= '0';
                end if;                
                
                if (rowBRAMDout(row)(7 downto 0) = "10000000" or
                    rowBRAMDout(row)(15 downto 8) = "10000000" or 
                    rowBRAMDout(row)(23 downto 16) = "10000000" or 
                    rowBRAMDout(row)(31 downto 24) = "10000000" or
                    row_invalid(row) = '1') then
                    -- If real or imaginary in either polarisation is flagged, then the sample is bad.
                    rowDataDel(row)(0) <= (others => '0');
                    rowMetaDel(row)(0).rfi <= '1';
                else
                    rowDataDel(row)(0) <= rowBRAMDout(row);
                    rowMetaDel(row)(0).rfi <= '0';
                end if;
                
            end if;
        end process;
        
    end generate;
    
    -- The multiplier array:
    row_mult_gen : for row_mult in 0 to 15 generate
        col_mult_gen : for col_mult in 0 to 15 generate
            
            cmultsi : entity correlator_lib.cmac_quad_wrapper
            port map(
                i_clk => i_cor_clk, --  in std_logic;
                -- Source data : Referring to the diagram in the comments at the top of this file:
                --   column data comes from the column memory, and propagates downward - i.e. to the next row.
                --   row data propagates to the right, i.e. to the next column
                i_col_data => colDataDel(row_mult)(col_mult), -- in (31:0); (7:0) = pol 0 real, (15:8) = pol 0 imaginary, (23:16) = pol 1 real, (31:24) = pol 1 imaginary.
                i_col_meta => colMetaDel(row_mult)(col_mult), -- in t_cmac_input_bus; .valid, .first, .last, .rfi, .sample_cnt
                i_row_data => rowDataDel(row_mult)(col_mult), -- in (31:0); (7:0) = pol 0 real, (15:8) = pol 0 imaginary, (23:16) = pol 1 real, (31:24) = pol 1 imaginary.
                i_row_meta => rowMetaDel(row_mult)(col_mult), -- in t_cmac_input_bus; .valid, .first, .last, .rfi, .sample_cnt
                -- pipelined source data
                o_col_data => colDataDel(row_mult + 1)(col_mult), -- out (31:0); (7:0) = pol 0 real, (15:8) = pol 0 imaginary, (23:16) = pol 1 real, (31:24) = pol 1 imaginary.
                o_col_meta => colMetaDel(row_mult + 1)(col_mult), -- out t_cmac_input_bus;  .valid, .first, .last, .rfi, .sample_cnt
                o_row_data => rowDataDel(row_mult)(col_mult + 1), -- out (31:0); (7:0) = pol 0 real, (15:8) = pol 0 imaginary, (23:16) = pol 1 real, (31:24) = pol 1 imaginary.
                o_row_meta => rowMetaDel(row_mult)(col_mult + 1), -- out t_cmac_input_bus; .valid, .first, .last, .rfi, .sample_cnt
                -- Output data
                -- Output is a burst of 4 clocks, with (1) Col pol0 - row pol0, (2) col pol0 - row pol1, (3) col pol1 - row pol 0, (4) col pol 1 - row pol 1
                -- Centroid data is valid in the first output clock.
                i_shiftOut => shiftOut(row_mult)(col_mult),     -- in std_logic; Indicates that data should be shifted out on the o_visData and o_centroid busses
                o_shiftOut => shiftOut(row_mult)(col_mult + 1), -- out std_logic; Indicates the next quad in the pipeline should send its data.
                
                i_visValid => array_visValid(row_mult)(col_mult),
                i_visData  => array_visData(row_mult)(col_mult),  -- in (47:0); Input from upstream quad
                i_centroid => centroid(row_mult)(col_mult), -- in (23:0);
                
                o_visValid => array_visValid(row_mult)(col_mult + 1), -- out std_logic; o_visData is valid.
                o_visData  => array_visData(row_mult)(col_mult + 1), -- out (47:0); Visibility data, 23:0 = real, 47:24 = imaginary.
                o_centroid => centroid(row_mult)(col_mult + 1) -- out (23:0); (7:0) = samples accumulated, (23:8) = centroid sum.
            );
            
        end generate;
        
        -- map the output from a 2D to a 1D array for input to the long term accumulator 
        cell_visOutput(row_mult) <= array_visData(row_mult)(16);
        cell_centroidOutput(row_mult) <= centroid(row_mult)(16);
        
    end generate;
    
    process(i_cor_clk)
    begin
        if rising_edge(i_cor_clk) then
            cell_visOutputDel1 <= cell_visOutput;
            cell_visOutputDel2 <= cell_visOutputDel1;
            cell_visOutputDel3 <= cell_visOutputDel2;
            cell_visOutputDel4 <= cell_visOutputDel3;
            cell_visOutputDel5 <= cell_visOutputDel4;
            cell_visOutputDel6 <= cell_visOutputDel5;
            
            cell_centroidOutputDel1 <= cell_centroidOutput;
            cell_centroidOutputDel2 <= cell_centroidOutputDel1;
            cell_centroidOutputDel3 <= cell_centroidOutputDel2;
            cell_centroidOutputDel4 <= cell_centroidOutputDel3;
            cell_centroidOutputDel5 <= cell_centroidOutputDel4;
            cell_centroidOutputDel6 <= cell_centroidOutputDel5;
            
        end if;
    end process;
    
    
    -----------------------------------------------------------------------------------
    -- Long term accumulator
    
    LTAi : entity correlator_lib.LTA_top
    port map ( 
        i_clk => i_cor_clk,
        i_rst => i_cor_rst, -- in std_logic;  -- resets selection of read and write buffers, should not be needed unless something goes very wrong.
        ----------------------------------------------------------------------------------------
        -- Write side interface : 
        i_cell    => cellDel(22),    -- in (7:0); 16x16 = 256 possible different cells being accumulated in the ultraRAM buffer at a time.
        -- i_valid can be high continuously, i_cellStart indicates the start of the burst of 64 clocks for a particular cell.
        i_cellStart => cellStartDel(22), -- in std_logic; 
        i_tile    => tileDel(22),    -- in (9:0);  tile index, passed to the output.
        i_channel => channelDel(22), -- in (23:0); first fine channel index for this correlation
        i_totalStations => totalStationsDel(22), -- in (15:0);
        i_subarrayBeam => subarrayBeamDel(22),   -- in (7:0);
        -- first time this cell is being written to, so just write, don't accumulate with existing value.
        -- i_tile and i_channel are captured when i_first = '1', i_cellStart = '1' and i_wrCell = 0, 
        i_first   => tileFirstDel(22), -- in std_logic; 
        i_last    => lastCellDel(22),  -- in std_logic;  This is the last integration for the last cell; after this, the buffers switch and the completed cells are read out.
        i_totalTimes => totalTimesDel(22), -- in (7:0);  Total time samples being integrated, e.g. 192. 
        i_totalChannels => totalChannelsDel(22), -- in (4:0);  Number of channels integrated, typically 24.
        -- valid goes high for a burst of 64 clocks, to get all the data from the correlation array.
        i_valid     => array_visValid(0)(16), -- in std_logic; -- indicates valid data, 4 clocks in advance of i_data. Needed since there is a long latency on the ultraRAM reads.
        -- 16 parrallel data streams with 3+3 byte visibilities from the correlation array. 
        -- i_data_del4(0) has a 4 cycle latency from the other write input control signals
        -- i_data_del4(k) has a 4+k cycle latency;
        i_data_del6 => cell_visOutputDel6, -- in t_slv_48_arr(15:0);
        i_centroid_del6 => cell_centroidOutputDel6, -- in t_slv_24_arr(15:0);  bits 7:0 = samples accumulated, bis 23:8 = time sample sum.
        o_ready => LTA_ready, -- out std_logic; -- if low, don't start a new tile.
        ----------------------------------------------------------------------------------------
        -- Data output 
        -- 256 bit bus on 300 MHz clock.
        i_axi_clk => i_axi_clk, -- in std_logic;
        -- o_data is a burst of 16*16*4*8 = 8192 bytes = 256 clocks with 256 bits per clock, for one cell of visibilities, when o_dtype = '0'
        -- When o_dtype = '1', centroid data is being sent as a block of 16*16*2 = 512 bytes = 16 clocks with 256 bits per clock.
        o_data     => o_data,     -- out std_logic_vector(255 downto 0);
        o_visValid => o_visValid, -- out std_logic;                   -- o_data is valid visibility data
        o_TCIvalid => o_TCIValid, -- out std_logic;                   -- o_data is valid TCI & DV data
        o_dcount   => o_dcount,   -- out (7:0); Counts the 256 transfers for one cell of visibilites, or 16 transfers for the centroid data. 
        o_cell     => o_cell,     -- out (7:0); A "cell" is a 16x16 station block of correlations
        o_cellLast => o_cellLast, -- out std_logic; This is the last cell for the tile.
        o_tile     => o_tile,     -- out (9:0); A "tile" is a 16x16 block of cells, i.e. a 256x256 station correlation.
        o_channel  => o_channel,  -- out (23:0); First fine channel index for this correlation.
        o_totalStations => o_totalStations, -- out (15:0); Total number of stations in the correlation
        o_subarrayBeam => o_subarrayBeam,   -- out (7:0); Index into the subarray-beam table.
        -- stop sending data; somewhere downstream there is a FIFO that is almost full.
        -- There can be a lag of about 20 clocks between i_stop going high and data stopping.
        i_stop     => i_stop      -- in std_logic 
    );
    
    xpm_cdc_single_inst : xpm_cdc_single
    generic map (
        DEST_SYNC_FF => 4,   -- DECIMAL; range: 2-10
        INIT_SYNC_FF => 0,   -- DECIMAL; 0=disable simulation init values, 1=enable simulation init values
        SIM_ASSERT_CHK => 0, -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        SRC_INPUT_REG => 1   -- DECIMAL; 0=do not register input, 1=register input
    ) port map (
        dest_out => LTA_ready_axi_clk, -- 1-bit output: src_in synchronized to the destination clock domain. This output is registered.
        dest_clk => i_axi_clk, -- 1-bit input: Clock signal for the destination clock domain.
        src_clk => i_cor_clk,   -- 1-bit input: optional; required when SRC_INPUT_REG = 1
        src_in => LTA_ready      -- 1-bit input: Input signal to be synchronized to dest_clk domain.
    );
    
    
    
end Behavioral;
