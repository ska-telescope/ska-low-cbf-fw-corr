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
--   * 16x16 station correlator array
--   * input data propagates down and to the right, to the row and column BRAMs.
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
    generic (
        --
        g_CT1_N27BLOCKS_PER_FRAME : integer := 24 -- Number nominal value is 24, corresponding to 24 * 27 = 648 CODIF packets = 21 ms corner turn 
    );
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
        -- Counts the virtual channels in i_cor_data, always in steps of 4,where the value is the first of the 4 virtual channels in i_cor_data
        -- If i_cor_tileType = '0', then up to 256 channels are delivered, with the same channels going to both row and column memories.
        --                          In this case, i_cor_VC_count will run from 0 to 256 in steps of 4.
        -- If i_cor_tileType = '1', then up to 512 channels are delivered, with different channels going to the row and column memories.
        --                          counts 0 to 255 go to the column memories, while counts 256-511 go to the row memories. 
        i_cor_VC_count : in std_logic_vector(8 downto 0); 
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
        i_cor_last  : in std_logic;  -- last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
        i_cor_first : in std_logic;  -- This is the first block of data for an integration - i.e. first fine channel, first block of 64 time samples.
        i_cor_final : in std_logic;  -- Indicates that at the completion of processing the most recent block of correlator data, the integration is complete. i_cor_tile and i_cor_tileChannel are valid when this is high.   
        -- up to 1024 different tiles; each tile is a subset of the correlation for particular subarray and beam.
        -- Tiles can be triangles or rectangles/squares from the full correlation.
        -- e.g. for 512x512 stations, there will be 3 tiles, consisting of 2 triangles and 1 square.
        --      for 4096x4096 stations, there will be 16 triangles, and 120 squares.
        i_cor_tile : in std_logic_vector(9 downto 0);
        -- Which block of frequency channels is this tile for ?
        -- This sets the offset within the HBM that the result is written to, relative to the base address which is extracted from registers based on i_cor_tile.
        i_cor_tileChannel : in std_logic_vector(11 downto 0);
        i_cor_row_stations : in std_logic_vector(8 downto 0); -- number of stations in the row memories to process; up to 256.
        i_cor_col_stations : in std_logic_vector(8 downto 0); -- number of stations in the col memories to process; up to 256.
        
        -- Data out to the HBM
        -- o_data is a burst of 16*16*4*8 = 8192 bytes = 256 clocks with 256 bits per clock, for one cell of visibilities, when o_dtype = '0'
        -- When o_dtype = '1', centroid data is being sent as a block of 16*16*2 = 512 bytes = 16 clocks with 256 bits per clock.
        o_data     : out std_logic_vector(255 downto 0);
        o_visValid : out std_logic;                     -- o_data is valid visibility data
        o_TCIvalid : out std_logic;                     -- o_data is valid TCI & DV data
        o_dcount   : out std_logic_vector(7 downto 0);  -- counts the 256 transfers for one cell of visibilites, or 16 transfers for the centroid data. 
        o_cell     : out std_logic_vector(7 downto 0);  -- a "cell" is a 16x16 station block of correlations
        o_tile     : out std_logic_vector(9 downto 0);  -- a "tile" is a 16x16 block of cells, i.e. a 256x256 station correlation.
        o_channel  : out std_logic_vector(15 downto 0); -- first fine channel index for this correlation.
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
    signal axi_to_cor_cdc_din : std_logic_vector(43 downto 0);
    signal tileChannel : std_logic_vector(11 downto 0);
    signal tileCount : std_logic_vector(9 downto 0);
    signal rowStations_minus1 : std_logic_vector(8 downto 0);
    signal colStations_minus1 : std_logic_vector(8 downto 0);
    signal axi_to_cor_src_rcv : std_logic;
    signal axi_to_cor_dest_out : std_logic_vector(41 downto 0);
    signal axi_to_cor_dest_req : std_logic;
    signal axi_to_cor_src_send : std_logic;
    signal cdc_wrBuffer : std_logic;
    signal tileType : std_logic;
    signal tileFirst : std_logic;
    signal tileFinal : std_logic;
    
    signal rowRdAddrDel, colRdAddrDel : t_slv_11_arr(15 downto 0);
    
    type t_slv_17x17_arr32 is array(16 downto 0) of t_slv_32_arr(16 downto 0);
    signal colDoutDel : t_slv_17x17_arr32;
    signal rowDoutDel : t_slv_17x17_arr32;
    
    type rd_fsm_type is (idle, running, done);
    signal rd_fsm, rd_fsm_del1, rd_fsm_del2, rd_fsm_Del3, rd_fsm_del4 : rd_fsm_type := idle;
    signal buf0_tileCount, buf1_tileCount : std_logic_vector(9 downto 0);
    signal buf0_tileChannel, buf1_tileChannel : std_logic_vector(11 downto 0);
    signal buf0_rowStations_minus1, buf0_colStations_minus1, buf1_rowStations_minus1, buf1_colStations_minus1 : std_logic_vector(8 downto 0);
    signal buf0_tileType, buf1_tileType : std_logic := '0';
    
    signal cor_buf0_used, cor_buf1_used : std_logic;
    signal cur_tileCount : std_logic_Vector(9 downto 0);
    signal cur_tileChannel : std_logic_vector(11 downto 0);
    signal cur_rowStations_minus1 : std_logic_vector(8 downto 0);
    signal cur_colStations_minus1 : std_logic_Vector(8 downto 0);
    signal cur_tileType : std_logic;
    signal cur_buf : std_logic := '0';
    signal corBuf0Done, corBuf1Done : std_logic;
    signal cur_tileFirst, cur_tileFinal : std_logic;
    
    signal RdTime, rdTimeDel1, rdTimeDel2, rdTimeDel3 : std_logic_vector(5 downto 0) := "000000";
    signal tileTime, cur_tileTime, buf0_tileTime, buf1_tileTime : std_logic_vector(1 downto 0) := "00";
    signal tileTimeDel1, tileTimeDel2, tileTimeDel3 : std_logic_vector(1 downto 0) := "00";
    signal colRdVC, rowRdVC : std_logic_vector(3 downto 0) := "0000";
    
    type t_metaDel is array(16 downto 0) of t_cmac_input_bus_a(16 downto 0);
    signal rowMetaDel, colMetaDel : t_metaDel;
         
    signal visValid, shiftOut : t_slv_17_arr(15 downto 0);
    type t_slv_17x17_arr48 is array(16 downto 0) of t_slv_48_arr(16 downto 0);
    type t_slv_17x17_arr24 is array(16 downto 0) of t_slv_24_arr(16 downto 0);
    signal visData :  t_slv_17x17_arr48; -- 48 bit
    signal centroid : t_slv_17x17_arr24;
    signal shiftOutAdv : std_logic_vector(5 downto 0) := "000000";
    signal cell_visOutput : t_slv_48_arr(15 downto 0);
    signal cell_centroidOutput : t_slv_24_arr(15 downto 0);
    signal buf0_tileFirst, buf0_tileFinal, buf1_tileFirst, buf1_tileFinal : std_logic;
    
begin
    
    -- Data input pipeline, converts data from the corner turn into write data, address and enable for the row and column memories.
    rc_dini : entity correlator_lib.row_col_dataIn
    port map (
        i_axi_clk => i_axi_clk, -- in std_logic;
        --------------------------------------------------------------------------
        -- Data input from the corner turn
        i_cor_data  => i_cor_data, -- in std_logic_vector(255 downto 0); 
        -- meta data
        i_cor_time  => i_cor_time, -- in std_logic_vector(7 downto 0); -- time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
        -- Counts the virtual channels in i_cor_data, always in steps of 4,where the value is the first of the 4 virtual channels in i_cor_data
        -- If i_cor_tileType = '0', then up to 256 channels are delivered, with the same channels going to both row and column memories.
        --                          In this case, i_cor_VC_count will run from 0 to 256 in steps of 4.
        -- If i_cor_tileType = '1', then up to 512 channels are delivered, with different channels going to the row and column memories.
        --                          counts 0 to 255 go to the column memories, while counts 256-511 go to the row memories. 
        i_cor_VC_count => i_cor_VC_count, -- in std_logic_vector(8 downto 0); 
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
        o_colWrData => colWrDataDel, -- out t_slv_64_arr(15 downto 0);
        o_colWrAddr => colWrAddrDel, -- out t_slv_10_arr(15 downto 0);
        o_colWrEn   => colWrEnDel,   -- out t_slv_1_arr(15 downto 0);
        --
        o_rowWrData => rowWrDataDel, -- out t_slv_64_arr(15 downto 0);
        o_rowWrAddr => rowWrAddrDel, -- out t_slv_10_arr(15 downto 0);
        o_rowWrEn   => rowWrEnDel    -- out t_slv_1_arr(15 downto 0)
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
            dbiterrb => open,                    -- 1-bit output: Status signal to indicate double bit error occurrence on the data output of port A.
            doutb => colDoutDel(0)(col_ram), -- READ_DATA_WIDTH_B-bit output: Data output for port B read operations.
            sbiterrb => open,                    -- 1-bit output: Status signal to indicate single bit error occurrence on the data output of port B.
            addra => colWrAddrDel(col_ram),  -- ADDR_WIDTH_A-bit input: Address for port A write and read operations.
            addrb => colRdAddrDel(col_ram),  -- ADDR_WIDTH_B-bit input: Address for port B write and read operations.
            clka => i_axi_clk,                   -- 1-bit input: Clock signal for port A. Also clocks port B when parameter CLOCKING_MODE is "common_clock".
            clkb => i_cor_clk,                   -- Unused when parameter CLOCKING_MODE is "common_clock".
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
            READ_DATA_WIDTH_B => 32,        -- DECIMAL
            READ_LATENCY_B => 3,             -- DECIMAL
            READ_RESET_VALUE_B => "0",       -- String
            RST_MODE_A => "SYNC",            -- String
            RST_MODE_B => "SYNC",            -- String
            SIM_ASSERT_CHK => 0,             -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
            USE_EMBEDDED_CONSTRAINT => 0,    -- DECIMAL
            USE_MEM_INIT => 0,               -- DECIMAL
            WAKEUP_TIME => "disable_sleep",  -- String
            WRITE_DATA_WIDTH_A => 64,       -- DECIMAL
            WRITE_MODE_B => "read_first"     -- String
        ) port map (
            dbiterrb => open,                    -- 1-bit output: Status signal to indicate double bit error occurrence on the data output of port A.
            doutb => rowDoutDel(row_ram)(0), -- READ_DATA_WIDTH_B-bit output: Data output for port B read operations.
            sbiterrb => open,                    -- 1-bit output: Status signal to indicate single bit error occurrence on the data output of port B.
            addra => rowWrAddrDel(row_ram),  -- ADDR_WIDTH_A-bit input: Address for port A write and read operations.
            addrb => rowRdAddrDel(row_ram),  -- ADDR_WIDTH_B-bit input: Address for port B write and read operations.
            clka => i_axi_clk,                   -- 1-bit input: Clock signal for port A. Also clocks port B when parameter CLOCKING_MODE is "common_clock".
            clkb => i_cor_clk,                   -- Unused when parameter CLOCKING_MODE is "common_clock".
            dina => rowWrDatadel(row_ram),   -- WRITE_DATA_WIDTH_A-bit input: Data input for port A write operations.
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
            
            if ((wrBuffer = '0' and buf0Used = '0') or (wrBuffer = '1' and buf1Used = '0')) then
                o_cor_ready <= '1';
            else
                o_cor_ready <= '0';
            end if;

            -- Signal correlator clock domain that the buffer is done and ready to be processed. 
            if i_cor_last = '1' then
                tileCount <= i_cor_tile; -- 10 bit tile index input
                -- Which block of frequency channels is this tile for ?
                -- This sets the offset within the HBM that the result is written to, relative to the base address which is extracted from registers based on i_cor0_tileCount.
                tileChannel <= i_cor_tileChannel;   -- in std_logic_vector(11 downto 0);
                tileTime <= i_cor_time(7 downto 6); -- which block of 64 time samples is this ?
                tileFirst <= i_cor_first;           -- first block of data for this tile;
                tileFinal <= i_cor_final;           -- This is the last block of input data for the integration for this tile.
                rowStations_minus1 <= std_logic_vector(unsigned(i_cor_row_stations) - 1); --  : in std_logic_vector(8 downto 0); -- number of stations in the row memories to process
                colStations_minus1 <= std_logic_vector(unsigned(i_cor_col_stations) - 1); --  : in std_logic_vector(8 downto 0);
                tileType <= i_cor_tileType;
                cdc_wrBuffer <= wrBuffer;
                axi_to_cor_src_send <= '1';
            elsif axi_to_cor_src_rcv = '1' then
                axi_to_cor_src_send <= '0';
            end if;
            
            
        end if;
    end process;    
    
    axi_to_cor_cdc_din(9 downto 0) <= tileCount;
    axi_to_cor_cdc_din(21 downto 10) <= tileChannel;
    axi_to_cor_cdc_din(29 downto 22) <= rowStations_minus1(7 downto 0);
    axi_to_cor_cdc_din(37 downto 30) <= colStations_minus1(7 downto 0);
    axi_to_cor_cdc_din(39 downto 38) <= tileTime;
    axi_to_cor_cdc_din(40) <= tileType;
    axi_to_cor_cdc_din(41) <= cdc_wrBuffer;
    axi_to_cor_cdc_din(42) <= tileFirst;
    axi_to_cor_cdc_din(43) <= tileFinal;
    
    xpm_cdc_handshake_inst : xpm_cdc_handshake
    generic map (
        DEST_EXT_HSK => 0,   -- DECIMAL; 0=internal handshake, 1=external handshake
        DEST_SYNC_FF => 4,   -- DECIMAL; range: 2-10
        INIT_SYNC_FF => 1,   -- DECIMAL; 0=disable simulation init values, 1=enable simulation init values
        SIM_ASSERT_CHK => 0, -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        SRC_SYNC_FF => 4,    -- DECIMAL; range: 2-10
        WIDTH => 44           -- DECIMAL; range: 1-1024
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
                if axi_to_cor_dest_out(41) = '0' then  -- input buffer 0 has just been written.
                    buf0_tileCount <= axi_to_cor_dest_out(9 downto 0);
                    buf0_tileChannel <= axi_to_cor_dest_out(21 downto 10);
                    buf0_rowStations_minus1 <= axi_to_cor_dest_out(29 downto 22);
                    buf0_colStations_minus1 <= axi_to_cor_dest_out(37 downto 30);
                    buf0_tileTime <= axi_to_cor_dest_out(39 downto 38);
                    buf0_tileType <= axi_to_cor_dest_out(40);
                    buf0_tileFirst <= axi_to_cor_dest_out(42);
                    buf0_tileFinal <= axi_to_cor_dest_out(43);
                else
                    -- Input buffer 1 has just been written.
                    buf1_tileCount <= axi_to_cor_dest_out(9 downto 0);
                    buf1_tileChannel <= axi_to_cor_dest_out(21 downto 10);
                    buf1_rowStations_minus1 <= axi_to_cor_dest_out(29 downto 22);
                    buf1_colStations_minus1 <= axi_to_cor_dest_out(37 downto 30);
                    buf1_tileTime <= axi_to_cor_dest_out(39 downto 38);
                    buf1_tileType <= axi_to_cor_dest_out(40);
                    buf1_tileFirst <= axi_to_cor_dest_out(42);
                    buf1_tileFinal <= axi_to_cor_dest_out(43);
                end if;
            end if;
            
            if axi_to_cor_dest_req = '1' and axi_to_cor_dest_out(41) = '0' then
                cor_buf0_used <= '1';
            elsif rd_fsm = done and cur_buf = '0' then
                cor_buf0_used <= '0';
            end if;
            
            if rd_fsm = done and cur_buf = '0' then
                corBuf0Done <= '1';
            else
                corBuf0Done <= '0';
            end if;
            
            if axi_to_cor_dest_req = '1' and axi_to_cor_dest_out(41) = '1' then
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
                    if cor_buf0_used = '1' or cor_buf1_used = '1' then
                        rd_fsm <= running;
                    end if;
                    if cor_buf0_used = '1' then
                        cur_tileCount <= buf0_tileCount;
                        cur_tileChannel <= buf0_tileChannel;
                        cur_rowStations_minus1 <= buf0_rowStations_minus1;
                        cur_colStations_minus1 <= buf0_colStations_minus1;
                        cur_tileType <= buf0_tileType;
                        cur_tileTime <= buf0_tileTime;
                        cur_tileFirst <= buf0_tilefirst;
                        cur_tileFinal <= buf0_tileFinal;
                        cur_buf <= '0';
                    elsif cor_buf1_used = '1' then
                        cur_tileCount <= buf1_tileCount;
                        cur_tileChannel <= buf1_tileChannel;
                        cur_rowStations_minus1 <= buf1_rowStations_minus1;
                        cur_colStations_minus1 <= buf1_colStations_minus1;
                        -- "cells" is the number of blocks of 16x16 stations to do.
                        -- 0 to 15 colstations_minus1 --> number of cells = 1 (cell 0)
                        -- 17 to 32 colStations -->  number of cells = 2 (cells 0 and 1)
                        -- etc.
                        cur_tileType <= buf1_tileType;
                        cur_tileTime <= buf1_tileTime;
                        cur_tileFirst <= buf1_tileFirst;
                        cur_tileFinal <= buf1_tileFinal;
                        cur_buf <= '1';
                    end if;
                    -- row and col memory read address : bits (5:0) = time samples, (9:6) = station, (10) = double buffer.
                    RdTime <= "000000";
                    colRdVC <= "0000";
                    rowRdVC <= "0000";
                    
                when running => 
                    RdTime <= std_logic_vector(unsigned(RdTime) + 1);
                    if (rdTime = "111111") then
                        if cur_tileType = '0' then -- triangle
                            -- say 16 stations, then colStations = "000010000", and stop when colRdVC = 0, i.e. only do one 16x16 correlator cell.
                            if colRdVC = cur_colStations_minus1(7 downto 4) then
                                colRdVC <= "0000";
                                rowRdVC <= std_logic_vector(unsigned(rowRdVC) + 1);
                                if rowRdVC = cur_rowStations_minus1(7 downto 4) then
                                    rd_fsm <= done;
                                end if;
                            else
                                colRdVC <= std_logic_vector(unsigned(colRdVC) + 1);
                            end if;
                        else -- rectangle or square.
                            if colRdVC = cur_colStations_minus1(7 downto 4) then
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
            
            rowRdAddrDel(0)(10) <= cur_buf;
            rowRdAddrDel(0)(9 downto 6) <= rowRdVC;
            rowRdAddrDel(0)(5 downto 0) <= rdTime;
            
            colRdAddrDel(15 downto 1) <= colRdAddrDel(14 downto 0);
            rowRdAddrDel(15 downto 1) <= rowRdAddrDel(14 downto 0);
            
            rd_fsm_del1 <= rd_fsm; -- rd_fsm_del1 aligns with colRdAddrDel(0), rowRdAddrDel(0), i.e. when rd_fsm_del1 = running, there is a valid address to the (first) row and column memories.
            rdTimeDel1 <= rdTime;
            tileTimeDel1 <= cur_tileTime;
            tileFirstDel1 <= cur_tileFirst;
            if ((cur_tileFinal = '1') and (rd_fsm = running) and (colRdVC = cur_colStations_minus1(7 downto 4)) and (rowRdVC = cur_rowStations_minus1(7 downto 4))) then
                lastCellDel1  <= '1';
            else
                lastCellDel1 <= '0';
            end if;
            
            rd_fsm_del2 <= rd_fsm_del1;
            rdTimeDel2 <= rdTimeDel1;
            tileTimeDel2 <= tileTimeDel1;
            tileFirstDel2 <= tileFirstDel1;
            lastCellDel2 <= lastCellDel1;
            
            rd_fsm_del3 <= rd_fsm_del2;
            rdTimeDel3 <= rdTimeDel2;
            tileTimeDel3 <= tileTimeDel2;
            tileFirstDel3 <= tileFirstDel2;
            lastCellDel3 <= lastCellDel2;

            rd_fsm_del4 <= rd_fsm_del3;  -- rd_fsm_del4 aligns with the data output from the first row and col memories, i.e. colDoutDel(0), rowDoutDel(0), since 3 cycle read latency for the memories.            
            if (rd_fsm_del3 = running) then
                colMetaDel(0)(0).vld <= '1';
                rowMetaDel(0)(0).vld <= '1';
            else
                colMetaDel(0)(0).vld <= '0';
                rowMetaDel(0)(0).vld <= '0';
            end if;
            
            if rdTimeDel3 = "000000" then
                colMetaDel(0)(0).first <= '1';
                rowMetaDel(0)(0).first <= '1';
            else
                colMetaDel(0)(0).first <= '0';
                rowMetaDel(0)(0).first <= '0';
            end if;
            
            if rdTimeDel3 = "111111" then
                colMetaDel(0)(0).last <= '1';
                rowMetaDel(0)(0).last <= '1';
                shiftOutAdv(0) <= '1';
            else
                colMetaDel(0)(0).last <= '0';
                rowMetaDel(0)(0).last <= '0';
                shiftOutAdv(0) <= '0';
            end if;
            
            tileFirstDel(0) <= tileFirstDel3;
            lastCellDel(0) <= lastCellDel3;
            
            tileFirstDel(15 downto 1) <= tileFirstDel(14 downto 0);
            lastCellDel(15 downto 1) <= lastCellDel(14 downto 0);
            
            rowMetaDel(0)(0).sample_cnt(5 downto 0) <= rdTimeDel3;
            rowMetaDel(0)(0).sample_cnt(7 downto 6) <= tileTimeDel3;
            colMetaDel(0)(0).sample_cnt(5 downto 0) <= rdTimeDel3;
            colMetaDel(0)(0).sample_cnt(7 downto 6) <= tileTimeDel3;

            -- First entry in the shift out pipeline needs to align with valid data in the first cmac_quad.
            -- So 5 cycle latency here:
            shiftOutAdv(5 downto 1) <= shiftOutAdv(4 downto 0);
            shiftOut(0)(0) <= shiftOutAdv(5);

            -- Have to copy the fields individually, since the .rfi field is generated separately.
            for row in 1 to 15 loop
                rowMetaDel(row)(0).vld <= rowMetaDel(row - 1)(0).vld;
                rowMetaDel(row)(0).first <= rowMetaDel(row - 1)(0).first;
                rowMetaDel(row)(0).last <= rowMetaDel(row - 1)(0).last;
                rowMetaDel(row)(0).sample_cnt <= rowMetaDel(row - 1)(0).sample_cnt;
                shiftOut(row)(0) <= shiftOut(row - 1)(0);
            end loop;
            for col in 1 to 15 loop
                colMetaDel(0)(col).vld <= colMetaDel(0)(col - 1).vld;
                colMetaDel(0)(col).first <= colMetaDel(0)(col - 1).first;
                colMetaDel(0)(col).last <= colMetaDel(0)(col - 1).last;
                colMetaDel(0)(col).sample_cnt <= colMetaDel(0)(col - 1).sample_cnt;
            end loop;
                        
        end if;
    end process;
    
    rfi_gen : for row_or_col in 0 to 15 generate
        colMetaDel(row_or_col)(0).rfi <= '1' when colDoutDel(row_or_col)(0) = "10000000" else '0';
        rowMetaDel(0)(row_or_col).rfi <= '1' when rowDoutDel(0)(row_or_col) = "10000000" else '0';
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
                i_col_data => colDoutDel(row_mult)(col_mult), -- in std_logic_vector(31 downto 0); -- (7:0) = pol 0 real, (15:8) = pol 0 imaginary, (23:16) = pol 1 real, (31:24) = pol 1 imaginary.
                i_col_meta => colMetaDel(row_mult)(col_mult), -- in t_cmac_input_bus;              -- .valid, .first, .last, .rfi, .sample_cnt
                i_row_data => rowDoutDel(row_mult)(col_mult), -- in std_logic_vector(31 downto 0); -- (7:0) = pol 0 real, (15:8) = pol 0 imaginary, (23:16) = pol 1 real, (31:24) = pol 1 imaginary.
                i_row_meta => rowMetaDel(row_mult)(col_mult), -- in t_cmac_input_bus;              -- .valid, .first, .last, .rfi, .sample_cnt
                -- pipelined source data
                o_col_data => colDoutDel(row_mult + 1)(col_mult),  -- out std_logic_vector(31 downto 0); -- (7:0) = pol 0 real, (15:8) = pol 0 imaginary, (23:16) = pol 1 real, (31:24) = pol 1 imaginary.
                o_col_meta => colMetaDel(row_mult + 1)(col_mult), -- out t_cmac_input_bus;              -- .valid, .first, .last, .rfi, .sample_cnt
                o_row_data => rowDoutDel(row_mult)(col_mult + 1), -- out std_logic_vector(31 downto 0); -- (7:0) = pol 0 real, (15:8) = pol 0 imaginary, (23:16) = pol 1 real, (31:24) = pol 1 imaginary.
                o_row_meta => rowMetaDel(row_mult)(col_mult + 1), -- out t_cmac_input_bus;              -- .valid, .first, .last, .rfi, .sample_cnt
                -- Output data
                -- Output is a burst of 4 clocks, with (1) Col pol0 - row pol0, (2) col pol0 - row pol1, (3) col pol1 - row pol 0, (4) col pol 1 - row pol 1
                -- Centroid data is valid in the first output clock.
                i_shiftOut => shiftOut(row_mult)(col_mult), -- in std_logic;   -- indicates that data should be shifted out on the o_visData and o_centroid busses
                o_shiftOut => shiftOut(row_mult)(col_mult + 1), -- out std_logic;  -- indicates the next quad in the pipeline should send its data.
                
                i_visValid => visValid(row_mult)(col_mult),
                i_visData  => visData(row_mult)(col_mult), -- in std_logic_vector(47 downto 0);  -- input from upstream quad
                i_centroid => centroid(row_mult)(col_mult), -- in std_logic_vector(23 downto 0); --
                
                o_visValid => visValid(row_mult)(col_mult + 1), -- out std_logic;  -- o_visData is valid.
                o_visData  => visData(row_mult)(col_mult + 1), -- out std_logic_vector(47 downto 0); -- Visibility data, 23:0 = real, 47:24 = imaginary.
                o_centroid => centroid(row_mult)(col_mult + 1)  -- out std_logic_vector(23 downto 0) -- (7:0) = samples accumulated, (23:8) = centroid sum.
            );
            
        end generate;
        
        -- map the output from a 2D to a 1D array for input to the long term accumulator 
        cell_visOutput(row_mult) <= visData(row_mult)(16);
        cell_centroidOutput(row_mult) <= centroid(row_mult)(16);
        
    end generate;
    
    
    
    -----------------------------------------------------------------------------------
    -- Long term accumulator
    
    LTAi : entity correlator_lib.LTA_top
    port map ( 
        i_clk => i_cor_clk,
        i_rst => i_cor_rst, -- in std_logic;  -- resets selection of read and write buffers, should not be needed unless something goes very wrong.
        -- Which buffer is used for read + write ?
        --  i_bufSelect : in std_logic;
        ----------------------------------------------------------------------------------------
        -- Write side interface : 
        i_cell    => , -- in std_logic_vector(7 downto 0); -- 16x16 = 256 possible different cells being accumulated in the ultraRAM buffer at a time.
        -- i_valid can be high continuously, i_cellStart indicates the start of the burst of 64 clocks for a particular cell.
        i_cellStart => , -- in std_logic; 
        i_tile    => , -- in std_logic_vector(9 downto 0); -- tile index, passed to the output.
        i_channel => , -- in std_logic_vector(15 downto 0); -- first fine channel index for this correlation
        -- first time this cell is being written to, so just write, don't accumulate with existing value.
        -- i_tile and i_channel are captured when i_first = '1', i_cellStart = '1' and i_wrCell = 0, 
        i_first   => , -- in std_logic; 
        i_last    => , -- in std_logic; -- This is the last integration for the last cell; after this, the buffers switch and the completed cells are read out.
        i_totalTimes => , -- in std_logic_vector(7 downto 0);    -- Total time samples being integrated, e.g. 192. 
        i_totalChannels => , --  in std_logic_vector(4 downto 0); -- Number of channels integrated, typically 24.
        -- valid goes high for a burst of 64 clocks, to get all the data from the correlation array.
        i_valid     => rowMetaDel(0)(15).vld, -- in std_logic; -- indicates valid data, 4 clocks in advance of i_data. Needed since there is a long latency on the ultraRAM reads.
        -- 16 parrallel data streams with 3+3 byte visibilities from the correlation array. 
        -- i_data_del4(0) has a 4 cycle latency from the other write input control signals
        -- i_data_del4(k) has a 4+k cycle latency;
        i_data_del4 => cell_visOutput, -- in t_slv_48_arr(15 downto 0);
        i_centroid_del4 => cell_centroidOutput, -- in t_slv_24_arr(15 downto 0); -- bits 7:0 = samples accumulated, bis 23:8 = time sample sum.
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
        o_dcount   => o_dcount,   -- out std_logic_vector(7 downto 0); -- counts the 256 transfers for one cell of visibilites, or 16 transfers for the centroid data. 
        o_cell     => o_cell,     -- out std_logic_vector(7 downto 0);  -- a "cell" is a 16x16 station block of correlations
        o_tile     => o_tile,     -- out std_logic_vector(9 downto 0);  -- a "tile" is a 16x16 block of cells, i.e. a 256x256 station correlation.
        o_channel  => o_channel,  -- out std_logic_vector(15 downto 0); -- first fine channel index for this correlation.
        -- stop sending data; somewhere downstream there is a FIFO that is almost full.
        -- There can be a lag of about 20 clocks between i_stop going high and data stopping.
        i_stop     => i_stop      -- in std_logic 
    );
    
    
end Behavioral;
