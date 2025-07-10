----------------------------------------------------------------------------------
-- Company: CSIRO 
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 06/18/2021 11:40:30 AM
-- Module Name: correlator - Behavioral
-- Description: 
--  Top level for the actual correlator.
-- 
-- Structure
--  mult-accumulate is done using two 32x32 matrix correlators.
--  Each 32x32 matrix correlator can process 512 dual-pol stations for 1 LFAA coarse channel, with a 412.5 MHz minimum clock speed.
--  32 = 16 stations x 2 polarisations.
--  The following is for a single 32x32 matrix correlator :
--
--  Flow :
--   - Get data for up to 512 stations and 64 time samples.
--      - i.e. all the data for 1 fine channel for about 1/3 of a second (= minimum integration time).
--        256 stations in each of the row and col memories, can be the same 256 stations, or different 256 stations.
--      - Each sample is 16+16 = 32 bits, (dual-pol stations, 8+8 bit complex per polarisation), so the memory required for this is :
--        (256 stations) * (64 times) * (4 bytes) = 65536 kBytes
--      - The actual memory required is 4x this : 
--         - x2 for double buffering, so data can be loaded as it is being used.
--         - x2 since data is stored in row and column memories to feed to the matrix correlator.
--      - So there is 128 kBytes in the row memories (and another 128 kbytes in the column memories)
--         - 128 kBytes = 32 BRAMs  (So total memory in row + col rams is 64 BRAMs)
--         - 32 BRAMs split into 16 pieces = 2 BRAMs per piece
--            - The write side of each row or column memory is (64 bits wide) x (1024 deep)
--                - 64 bits wide = sufficient for 2 time samples, each dual pol complex 8+8 bit.
--                - 1024 deep = (2 double buffered) * (16 stations) * (32 lots of 2 times)
--                  (note 16 stations per BRAM block, 16 BRAM blocks per make up all column memories, so 16x16=256 stations stored in the memories) 
--            - The read side is (32 bits wide) x (2048 deep)
--                - 32 bits = 1 dual-pol time sample
--                - 2048 deep = (2 double buffered) * (16 stations) * (64 times)
--      - Loading data :
--         - For the full correlation, the number of clocks to use the data in the memory is :
--            - (64 times) x (Number of correlation cells)
--            - Each correlation cell is a (32 port)x(32 port) block from the full correlation.
--            - For 1024 ports, there are 32*33/2 = 528 correlation cells.
--            - Process 1/3 of these cells before reloading, so the number of clocks between switching the double buffer in the memory is
--              - (64 times) * (176) = 11264 clocks (@ about 400 MHz).
--              - NOTE : Process 1/3 of the cells so that the mid-term accumulator can sit in ultraRAM.
--                       Loading the data 3 times is feasible because the total data rate into HBM for 2 coarse channels, 512 stations, is only 25 Gbit/sec, so 3x = 75 Gbit/sec is achievable.
--         - Loading the buffers requires getting 128 kBytes from HBM
--            - 128 kBytes in 11264 clocks = 12 bytes/(400 MHz clock) = 16 bytes / 300 MHz clock
--            - So data from the HBM can be delivered in 16 byte words, using most clock cycles.
--         - A single 512-bit HBM word from the corner turn contains:
--            - 4 stations * 2 pol * (2 bytes/sample) * (4 time samples)
--            - Each block of 4 BRAMs holds data for one of those 4 stations in a HBM word.
--            - So write side of each memory block must be wide enough for 4 time samples
--              - i.e. 1 station * 2 pol * 2 bytes/sample * 4 time samples = 16 bytes wide
--                So write side of each block of 4 BRAMs is (128 bits wide) x (1024 deep)
--
--   - Process this data (64 time samples, all ports, 1 fine channel, 1/3 of the total correlation cells) :
--      - The 32x32 matrix correlator processes 32x32 squares of the ACM at a time.
--      - 1024 ports = 32*32 ports, so there are 32*33/2 = 528 32x32 ACM squares to process.
--      - Each 32x32 correlation cell takes 64 clocks, since there are 64 time samples to process in the BRAMs that feed it.
--         - So we need (528 cells)*(64 clocks per cell)*(3456 fine channels per coarse) = 116785152 clocks to process 64 time samples
--         - 64 time samples = 128 LFAA packets = 283.11552 ms of data.
--         - So we need at least 116785152 clocks in 283.11552 ms = 412.5 MHz minimum clock speed.
--         
--      - Use 24 bit accumulator (24 bit real + 24 bit imaginary):
--          8 bit x 8 bit = 16 bit, accumulate 64 times -> 22 bits.
--    - 64 clocks to get the data out of the correlator array (i.e. the time it takes to do one correlation cell).
--      - 1024 elements in the array, so read 16 samples per clock.
--      - use 32+32 bit integers, so 8 bytes per sample, so data rate out is 16*8 = 128 bytes per clock @ 412.5 MHz = 422 Gbit/sec.
--      - Accumulate more time or fine channels in an ultraRAM buffer
--      
--    - ultraRAM accumulation buffer :
--      - Holds 1/4 of a full correlation.
--         - Number of tiles of the 16x16 array to cover 256 stations is 16*17/2 = 136
--         - Data for one tile = 32*32*(8 bytes) = 8192 bytes.
--      - 136 * 8192 = 1114112 bytes = 34 ultraRAMs (exactly).
--      - Accumulation buffer is double buffered, so it can be dumped to HBM while new data is coming in,
--      - So it needs 68 ultraRAMs.
--      - Needs to be split into 16 pieces, so we can process 16 samples at a time from the CMAC array
--         - Total number of 8-byte samples in the CMAC array is 32*32 = 1024
--         - clocked out in 64 clocks
--         - So the long term accumulator needs to process 16 (8-byte samples) per clock
--      - Double buffering has to be implemented in separate memories, since we have to do read-modify-write on one buffer, while reading to HBM from the other buffer.
--      - So it is made up of 32 memories; for each memory:
--         - Depth = 136*1024 / 16 = 8704, width = 64 bits.
--         - This is exactly 2 ultraRAMs + 1 BRAM.
--      - We also need 2 bytes for number of samples accumulated, and 3 bytes for time centroid sum
--         - Use 72 bit wide memories, gives an extra 4 bytes for every 4 visibilities. Steal an extra 2 bits from each visibility by using 31 bit integers.
--         - So centroid sum and samples accumulated fit in the same memories.
--   - Other Notes : 
--      - If we calculated the complete ACM at one go, we would have to store 1024*1025/2 = 524800 correlation products,
--        Taking into account double buffering, this is 524800 * (8 bytes) * (2 buffers) / (32768 bytes/ultram) = 257 ultraRAMs.
--        There are only 320 ultraRAMs per SLR, so this may be possible but is getting tight.
--      - Could also do 1/2 the ACM at one go, which would need 128 ultraRAMs for the buffer. This could be simpler to implement ?
--        It also reduces the rate at which data must be loaded into the array to just under 8 bytes/(400 MHz clock)
--
--        But !!!! Also need to calculate and store weights to account for RFI !!!!! This will use extra ultraRAMs.
--
-- STRUCTURE:
--   This level instantiates
--    - Register interface, which is used for monitoring only.
--    - Two instances of "single_correlator"
--    
--   A single_correlator instance uses 
--      - 2048 DSPs, using ultrascale+ DSPs to implement a complex MAC in 2 DSPs.
--      - 128 ultraRAMs for the long term accumulator.
--      - One HBM interface to dump data to
--   Each single_correlator instance includes:
--      - The thing which does all the correlation calculations.
--        This part is designed to be placed in a single super logic region:
--         - A 32x32 station correlator array. Note each station is dual-pol.
--         - A long term accumulator ("LTA_top.vhd"), which can hold data for a 256x256 station correlation. 
--      - Module to write to HBM.
--      - Packetiser (reads from HBM and generates SPEAD packets).
----------------------------------------------------------------------------------
library IEEE, correlator_lib, common_lib, xpm, spead_lib;
library axi4_lib, DSP_top_lib, noc_lib;

use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use correlator_lib.cor_config_reg_pkg.ALL;
use common_lib.common_pkg.ALL;
use xpm.vcomponents.all;
use axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;
use spead_lib.spead_packet_pkg.ALL;
use correlator_lib.target_fpga_pkg.ALL;


entity correlator_top is
    generic (
        g_CORRELATORS : integer := 2;
        g_PACKET_SAMPLES_DIV16 : integer := 2
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
        -- correlator 0 is ready to receive a new block of data. This will go low once data starts to be received.
        -- A block of data consists of data for 64 times, and up to 512 virtual channels.
        o_cor0_ready : out std_logic;  
        -- Each 256 bit word : two time samples, 4 consecutive virtual channels
        -- (31:0) = time 0, virtual channel 0; (63:32) = time 0, virtual channel 1; (95:64) = time 0, virtual channel 2; (127:96) = time 0, virtual channel 3;
        -- (159:128) = time 1, virtual channel 0; (191:160) = time 1, virtual channel 1; (223:192) = time 1, virtual channel 2; (255:224) = time 1, virtual channel 3;
        i_cor0_data  : in std_logic_vector(255 downto 0); 
        -- meta data
        i_cor0_time : in std_logic_vector(7 downto 0); -- time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
        i_cor0_station : in std_logic_vector(11 downto 0); -- first of the 4 virtual channels in i_cor0_data
        -- Options for tileType : 
        --   '0' = Triangle. In this case, all the input data goes to both the row and column memories, and a triangle from the correlation matrix is computed.
        --            For correlation cells on the diagonal, only non-duplicate entries are sent out.
        --   '1' = Square. In this case, the first 256 virtual channels on i_cor0_data go to the column memories, while the next 256 virtual channels go to the row memories.
        --            All correlation products for the rectangle are then computed.
        i_cor0_tileType : in std_logic;
        i_cor0_valid : in std_logic;  -- i_cor0_data, i_cor0_time, i_cor0_VC, i_cor0_FC and i_cor0_tileType are valid when i_cor0_valid = '1'
        -- i_cor0_last and i_cor0_final go high after a block of data has been sent.
        i_cor0_first  : in std_logic;  -- This is the first block of data for an integration - i.e. first fine channel, first block of 64 time samples, for this tile
        i_cor0_last  : in std_logic;  -- last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
        i_cor0_final : in std_logic;  -- Indicates that at the completion of processing the most recent block of correlator data, the integration is complete. i_cor0_tileCount and i_cor0_tileChannel are valid when this is high.   
        -- up to 1024 different tiles; each tile is a subset of the correlation for particular subarray and beam.
        -- Tiles can be triangles or rectangles from the full correlation.
        -- e.g. for 512x512 stations, there will be 4 tiles, consisting of 2 triangles and 2 rectangles.
        --      for 4096x4096 stations, there will be 16 triangles, and 240 rectangles.
        i_cor0_tileLocation : in std_logic_vector(9 downto 0);
        i_cor0_frameCount   : in std_logic_vector(31 downto 0);
        -- Which block of frequency channels is this tile for ?
        -- This sets the offset within the HBM that the result is written to, relative to the base address which is extracted from registers based on i_cor0_tileCount.
        i_cor0_tileChannel : in std_logic_vector(23 downto 0);
        i_cor0_tileTotalTimes    : in std_logic_vector(7 downto 0); -- Number of time samples to integrate for this tile.
        i_cor0_tiletotalChannels : in std_logic_vector(6 downto 0); -- Number of frequency channels to integrate for this tile.
        i_cor0_rowstations       : in std_logic_vector(8 downto 0); -- Number of stations in the row memories to process; up to 256.
        i_cor0_colstations       : in std_logic_vector(8 downto 0); -- Number of stations in the col memories to process; up to 256.
        i_cor0_totalStations     : in std_logic_vector(15 downto 0); -- Total number of stations being processing for this subarray-beam.
        i_cor0_subarrayBeam      : in std_logic_vector(7 downto 0);  -- Which entry is this in the subarray-beam table ?
        i_cor0_badPoly           : in std_logic;  -- no valid polynomials for some or all of the station data.
        i_cor0_tableSelect       : in std_logic;
        -- Data out to the HBM
        o_cor0_axi_aw      : out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_cor0_axi_awready : in  std_logic;
        o_cor0_axi_w       : out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_cor0_axi_wready  : in  std_logic;
        i_cor0_axi_b       : in  t_axi4_full_b;    -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        -- reading from HBM
        o_cor0_axi_ar      : out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_cor0_axi_arready : in  std_logic;
        i_cor0_axi_r       : in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_cor0_axi_rready  : out std_logic;
        
        ---------------------------------------------------------------------
        -- second correlator. See comments above for first correlator for information about the signals.
        o_cor1_ready : out std_logic;
        i_cor1_data  : in std_logic_vector(255 downto 0); 
        i_cor1_time    : in std_logic_vector(7 downto 0);  -- Time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
        i_cor1_station : in std_logic_vector(11 downto 0); -- First of the 4 stations in o_cor0_data
        i_cor1_tileType : in std_logic; -- which correlator triangle is this data for ? 0 to 3 for modes that don't use substations.
        i_cor1_valid : in std_logic;
        i_cor1_first : in std_logic;
        i_cor1_last  : in std_logic;  -- last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
        i_cor1_final : in std_logic;  -- Indicates that at the completion of processing the last block of correlator data, the integration is complete.    
        i_cor1_tileLocation : in std_logic_vector(9 downto 0);
        i_cor1_frameCount   : in std_logic_vector(31 downto 0);
        i_cor1_tileChannel : in std_logic_vector(23 downto 0);
        i_cor1_tileTotalTimes    : in std_logic_vector(7 downto 0); -- Number of time samples to integrate for this tile.
        i_cor1_tiletotalChannels : in std_logic_vector(6 downto 0); -- Number of frequency channels to integrate for this tile.
        i_cor1_rowstations       : in std_logic_vector(8 downto 0); -- number of stations in the row memories to process; up to 256.
        i_cor1_colstations       : in std_logic_vector(8 downto 0); -- number of stations in the col memories to process; up to 256. 
        i_cor1_totalStations     : in std_logic_vector(15 downto 0); -- Total number of stations being processing for this subarray-beam.
        i_cor1_subarrayBeam      : in std_logic_vector(7 downto 0);  -- Which entry is this in the subarray-beam table ?
        i_cor1_badPoly           : in std_logic;  -- no valid polynomials for some or all of the station data.
        i_cor1_tableSelect       : in std_logic;
        -- Data out to the HBM
        o_cor1_axi_aw      : out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_cor1_axi_awready : in  std_logic;
        o_cor1_axi_w       : out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_cor1_axi_wready  : in  std_logic;
        i_cor1_axi_b       : in  t_axi4_full_b;    -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        -- reading from HBM
        o_cor1_axi_ar      : out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_cor1_axi_arready : in  std_logic;
        i_cor1_axi_r       : in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_cor1_axi_rready  : out std_logic;

        ------------------------------------------------------------------        
        -- spead packet interface
        i_from_spead_pack       : in t_spead_to_hbm_bus_array(1 downto 0);
        o_to_spead_pack         : out t_hbm_to_spead_bus_array(1 downto 0);

        i_packetiser_enable     : in std_logic_vector(1 downto 0);
        
        -- Output HBM
        i_spead_hbm_rd_lite_axi_mosi : in t_axi4_lite_mosi_arr(1 downto 0);
        o_spead_hbm_rd_lite_axi_miso : out t_axi4_lite_miso_arr(1 downto 0);
        ------------------------------------------------------------------
        -- Registers AXI Lite Interface (uses i_axi_clk)
        i_axi_mosi : in t_axi4_lite_mosi;
        o_axi_miso : out t_axi4_lite_miso;
        
        ------------------------------------------------------------------
        -- Data output to the packetiser
        o_packet0_dout  : out std_logic_vector(255 downto 0);
        o_packet0_valid : out std_logic;
        i_packet0_ready : in std_logic;
        
        o_packet1_dout : out std_logic_vector(255 downto 0);
        o_packet1_valid : out std_logic;
        i_packet1_ready : in std_logic;
        
        ---------------------------------------------------------------
        -- Copy of the bus taking data to be written to the HBM,
        -- for the first correlator instance.
        -- Used for simulation only, to check against the model data.
        o_tb_data      : out std_logic_vector(255 downto 0);
        o_tb_visValid  : out std_logic; -- o_tb_data is valid visibility data
        o_tb_TCIvalid  : out std_logic; -- i_data is valid TCI & DV data
        o_tb_dcount    : out std_logic_vector(7 downto 0);  -- counts the 256 transfers for one cell of visibilites, or 16 transfers for the centroid data. 
        o_tb_cell      : out std_logic_vector(7 downto 0);  -- in (7:0);  -- a "cell" is a 16x16 station block of correlations
        o_tb_tile      : out std_logic_vector(9 downto 0);  -- a "tile" is a 16x16 block of cells, i.e. a 256x256 station correlation.
        o_tb_channel   : out std_logic_vector(23 downto 0); -- first fine channel index for this correlation.
        --
        o_freq_index0_repeat : out std_logic
        
    );
end correlator_top;

architecture Behavioral of correlator_top is
    
    signal config_rw : t_setup_rw;
    signal config_ro : t_setup_ro;
    
    signal cor0_HBM_start : std_logic_vector(31 downto 0); -- Byte address offset into the HBM buffer where the visibility circular buffer starts.
    signal cor0_HBM_end   : std_logic_vector(31 downto 0); -- byte address offset into the HBM buffer where the visibility circular buffer ends.
    signal cor0_HBM_cells : std_logic_vector(15 downto 0);
    signal cor1_HBM_start : std_logic_vector(31 downto 0); -- Byte address offset into the HBM buffer where the visibility circular buffer starts.
    signal cor1_HBM_end   : std_logic_vector(31 downto 0); -- byte address offset into the HBM buffer where the visibility circular buffer ends.
    signal cor1_HBM_cells : std_logic_vector(15 downto 0);
    signal cor0_HBM_errors, cor1_HBM_errors : std_logic_vector(3 downto 0);

    signal cor0_HBM_curr_rd_base    : std_logic_vector(31 downto 0);
    signal cor1_HBM_curr_rd_base    : std_logic_vector(31 downto 0);
    
    signal noc_wren                 : STD_LOGIC;
    signal noc_rden                 : STD_LOGIC;
    signal noc_wr_adr               : STD_LOGIC_VECTOR(17 DOWNTO 0);
    signal noc_wr_dat               : STD_LOGIC_VECTOR(31 DOWNTO 0);
    signal noc_rd_adr               : STD_LOGIC_VECTOR(17 DOWNTO 0);
    signal noc_rd_dat               : STD_LOGIC_VECTOR(31 DOWNTO 0);
    signal noc_rd_dat_mux           : STD_LOGIC_VECTOR(31 DOWNTO 0);
    signal dummy                    : STD_LOGIC;

begin
    
    -- First correlator instance
    cor1geni : if (g_CORRELATORS > 0) generate
        icor1 : entity correlator_lib.single_correlator
        generic map (
            g_PIPELINE_STAGES => 2, -- integer
            g_PACKET_SAMPLES_DIV16  => g_PACKET_SAMPLES_DIV16
        ) port map (
            -- clock used for all data input and output from this module (300 MHz)
            i_axi_clk => i_axi_clk, -- in std_logic;
            i_axi_rst => i_axi_rst, -- in std_logic;
            -- Processing clock used for the correlation (>412.5 MHz)
            i_cor_clk => i_cor_clk, -- in std_logic;
            i_cor_rst => i_cor_rst, -- in std_logic;
            ---------------------------------------------------------------
            -- Data in to the correlator arrays
            --
            -- correlator 0 is ready to receive a new block of data. This will go low once data starts to be received.
            -- A block of data consists of data for 64 times, and up to 512 virtual channels.
            o_cor_ready => o_cor0_ready, -- out std_logic;  
            -- Each 256 bit word : two time samples, 4 consecutive virtual channels
            -- (31:0) = time 0, virtual channel 0; (63:32) = time 0, virtual channel 1; (95:64) = time 0, virtual channel 2; (127:96) = time 0, virtual channel 3;
            -- (159:128) = time 1, virtual channel 0; (191:160) = time 1, virtual channel 1; (223:192) = time 1, virtual channel 2; (255:224) = time 1, virtual channel 3;
            i_cor_data  => i_cor0_data, --  in std_logic_vector(255 downto 0); 
            -- Counts the virtual channels in i_cor_data, always in steps of 4, where the value is the first of the 4 virtual channels in i_cor_data
            -- If i_cor_tileType = '0', then up to 256 channels are delivered, with the same channels going to both row and column memories.
            --                          In this case, i_cor_VC_count will run from 0 to 256 in steps of 4.
            -- If i_cor_tileType = '1', then up to 512 channels are delivered, with different channels going to the row and column memories.
            --                          counts 0 to 255 go to the column memories, while counts 256-511 go to the row memories. 
            i_cor_station => i_cor0_station, -- in std_logic_vector(8 downto 0); -- first of the 4 virtual channels in i_cor0_data
            i_cor_time    => i_cor0_time,    -- in std_logic_vector(7 downto 0); -- time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
            -- Options for tileType : 
            --   '0' = Triangle. In this case, all the input data goes to both the row and column memories, and a triangle from the correlation matrix is computed.
            --            For correlation cells on the diagonal, only non-duplicate entries are sent out.
            --   '1' = Rectangle. In this case, the first 256 virtual channels on i_cor0_data go to the column memories, while the next 128 virtual channels go to the row memories.
            --            All correlation products for the rectangle are then computed.
            i_cor_tileType => i_cor0_tileType, --  in std_logic;
            i_cor_valid    => i_cor0_valid,    --  in std_logic; i_cor0_data, i_cor0_time, i_cor0_VC, i_cor0_FC and i_cor0_tileType are valid when i_cor0_valid = '1'
            -- i_cor0_last and i_cor0_final go high after a block of data has been sent.
            i_cor_first    => i_cor0_first,    -- in std_logic; This is the first block of data for an integration - i.e. first fine channel, first block of 64 time samples, for this tile
            i_cor_last     => i_cor0_last,     -- in std_logic; Last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
            i_cor_final    => i_cor0_final,    -- in std_logic; Indicates that at the completion of processing the most recent block of correlator data, the integration is complete. i_cor0_tileCount and i_cor0_tileChannel are valid when this is high.   
            -- TileLocation bits 3:0 = tile column, bits 7:4 = tile row. Each tile is 256x256 stations.
            -- Tiles can be triangles or squares from the full correlation.
            -- e.g. for 512x512 stations, there will be 4 tiles, consisting of 2 triangles and 1 square.
            --      for 4096x4096 stations, there will be 16 triangles, and 120 squares.
            i_cor_tileLocation => i_cor0_tileLocation, --  in (9:0); bits 3:0 = tile column, bits 7:4 = tile row, bits 9:8 = "00";
            i_cor_frameCount   => i_cor0_frameCount, -- in (31:0);
            -- Which block of frequency channels is this tile for ?
            -- This sets the offset within the HBM that the result is written to, relative to the base address which is extracted from registers based on i_cor0_tileCount.
            i_cor_tileChannel => i_cor0_tileChannel, --  in (23:0);
            i_cor_tileTotalTimes    => i_cor0_tileTotalTimes,    -- in (7:0) Number of time samples to integrate for this tile.
            i_cor_tiletotalChannels => i_cor0_tileTotalChannels, -- in (6:0) Number of frequency channels to integrate for this tile.
            i_cor_rowstations       => i_cor0_rowStations,       -- in (8:0) Number of stations in the row memories to process; up to 256.
            i_cor_colstations       => i_cor0_colStations,       -- in (8:0) Number of stations in the col memories to process; up to 256.
            i_cor_totalStations     => i_cor0_totalStations,     -- in (15:0); Total number of stations being processing for this subarray-beam.
            i_cor_subarrayBeam      => i_cor0_subarrayBeam,      -- in (7:0);  Which entry is this in the subarray-beam table ?
            i_cor_badPoly           => i_cor0_badPoly,           -- in std_logic;
            i_cor_tableSelect       => i_cor0_tableSelect,       -- in std_logic;
            ---------------------------------------------------------------
            -- Data out to the HBM
            o_HBM_axi_aw      => o_cor0_axi_aw,      -- out t_axi4_full_addr; write address bus (.valid, .addr(39:0), .len(7:0))
            i_HBM_axi_awready => i_cor0_axi_awready, -- in  std_logic;
            o_HBM_axi_w       => o_cor0_axi_w,       -- out t_axi4_full_data; w data bus (.valid, .data(511:0), .last, .resp(1:0))
            i_HBM_axi_wready  => i_cor0_axi_wready,  -- in  std_logic;
            i_HBM_axi_b       => i_cor0_axi_b,       -- in  t_axi4_full_b; write response bus (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
            -- reading from HBM
            o_HBM_axi_ar      => o_cor0_axi_ar,      -- out t_axi4_full_addr; read address bus (.valid, .addr(39:0), .len(7:0))
            i_HBM_axi_arready => i_cor0_axi_arready, -- in  std_logic;
            i_HBM_axi_r       => i_cor0_axi_r,       -- in  t_axi4_full_data; r data bus (.valid, .data(511:0), .last, .resp(1:0))
            o_HBM_axi_rready  => o_cor0_axi_rready,  -- out std_logic;
            ---------------------------------------------------------------
            -- data out to SPEAD Packetiser        
            i_from_spead_pack   => i_from_spead_pack(0),
            o_to_spead_pack     => o_to_spead_pack(0),
    
            i_packetiser_enable => i_packetiser_enable(0),
            
            -- ARGs Debug
            i_spead_hbm_rd_lite_axi_mosi => i_spead_hbm_rd_lite_axi_mosi(0),
            o_spead_hbm_rd_lite_axi_miso => o_spead_hbm_rd_lite_axi_miso(0),
            ---------------------------------------------------------------
            -- Registers
            o_HBM_end           => cor0_HBM_end,    -- out (31:0); -- Byte address offset into the HBM buffer where the visibility circular buffer ends.
            o_HBM_errors        => cor0_HBM_errors, -- out (3:0)  -- Number of cells currently in the circular buffer.
            o_HBM_curr_rd_addr  => cor0_HBM_curr_rd_base,
            ---------------------------------------------------------------
            -- copy of the bus taking data to be written to the HBM.
            -- Used for simulation only, to check against the model data.
            o_tb_data      => o_tb_data,     -- out (255:0);
            o_tb_visValid  => o_tb_visValid, -- out std_logic; -- o_tb_data is valid visibility data
            o_tb_TCIvalid  => o_tb_TCIvalid, -- out std_logic; -- i_data is valid TCI & DV data
            o_tb_dcount    => o_tb_dcount,   -- out (7:0);  -- counts the 256 transfers for one cell of visibilites, or 16 transfers for the centroid data. 
            o_tb_cell      => o_tb_cell,     -- out (7:0);  -- in (7:0);  -- a "cell" is a 16x16 station block of correlations
            o_tb_tile      => o_tb_tile,     -- out (9:0);  -- a "tile" is a 16x16 block of cells, i.e. a 256x256 station correlation.
            o_tb_channel   => o_tb_channel,   -- out (23:0) -- first fine channel index for this correlation.
            --
            o_freq_index0_repeat => o_freq_index0_repeat -- out std_logic
        );
    end generate;
    
    nocor1geni : if (g_CORRELATORS < 1) generate
        cor0_HBM_start <= (others => '0');
        cor0_HBM_end <= (others => '0');
        cor0_HBM_cells <= (others => '0');
        o_packet0_dout <= (others => '0');
        o_packet0_valid <= '0';
        o_cor0_axi_aw.valid <= '0';
        o_cor0_axi_aw.addr <= (others => '0');
        o_cor0_axi_aw.len <= (others => '0');
        o_cor0_axi_w.valid <= '0';
        o_cor0_axi_w.data <= (others => '0');
        o_cor0_axi_w.last <= '0';
        o_cor0_axi_ar.valid <= '0';
        o_cor0_axi_ar.addr <= (others => '0');
        o_cor0_axi_ar.len <= (others => '0');
        o_cor0_axi_rready <= '0';
        o_cor0_ready <= '1';
    end generate;
    
    cor2geni : if (g_CORRELATORS > 1) generate
        icor2 : entity correlator_lib.single_correlator
        generic map (
            g_PIPELINE_STAGES => 3, -- integer
            g_PACKET_SAMPLES_DIV16  => g_PACKET_SAMPLES_DIV16
        ) port map (
            -- clock used for all data input and output from this module (300 MHz)
            i_axi_clk => i_axi_clk, -- in std_logic;
            i_axi_rst => i_axi_rst, -- in std_logic;
            -- Processing clock used for the correlation (>412.5 MHz)
            i_cor_clk => i_cor_clk, -- in std_logic;
            i_cor_rst => i_cor_rst, -- in std_logic;
            ---------------------------------------------------------------
            -- Data in to the correlator arrays
            --
            -- correlator 0 is ready to receive a new block of data. This will go low once data starts to be received.
            -- A block of data consists of data for 64 times, and up to 512 virtual channels.
            o_cor_ready => o_cor1_ready, -- out std_logic;  
            -- Each 256 bit word : two time samples, 4 consecutive virtual channels
            -- (31:0) = time 0, virtual channel 0; (63:32) = time 0, virtual channel 1; (95:64) = time 0, virtual channel 2; (127:96) = time 0, virtual channel 3;
            -- (159:128) = time 1, virtual channel 0; (191:160) = time 1, virtual channel 1; (223:192) = time 1, virtual channel 2; (255:224) = time 1, virtual channel 3;
            i_cor_data     => i_cor1_data, --  in std_logic_vector(255 downto 0); 
            i_cor_time     => i_cor1_time,  -- in std_logic_vector(7 downto 0); -- time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
            i_cor_station  => i_cor1_station,  -- in std_logic_vector(8 downto 0); -- first of the 4 virtual channels in i_cor0_data
            i_cor_tileType => i_cor1_tileType, -- in std_logic;
            i_cor_valid    => i_cor1_valid,    -- in std_logic;  -- i_cor0_data, i_cor0_time, i_cor0_VC, i_cor0_FC and i_cor0_tileType are valid when i_cor0_valid = '1'
            i_cor_first    => i_cor1_first,    -- in std_logic;  -- This is the first block of data for an integration - i.e. first fine channel, first block of 64 time samples, for this tile
            i_cor_last     => i_cor1_last,     -- in std_logic;  -- last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
            i_cor_final    => i_cor1_final,    -- in std_logic;  -- Indicates that at the completion of processing the most recent block of correlator data, the integration is complete. i_cor0_tileCount and i_cor0_tileChannel are valid when this is high.   
            i_cor_tileLocation => i_cor1_tileLocation, --  in (9:0); bits 3:0 = tile column, bits 7:4 = tile row, bits 9:8 = "00";
            i_cor_frameCount => i_cor1_frameCount, -- in (31:0);
            -- Which block of frequency channels is this tile for ?
            -- This sets the offset within the HBM that the result is written to, relative to the base address which is extracted from registers based on i_cor0_tileCount.
            i_cor_tileChannel       => i_cor1_tileChannel,       -- in (23:0);
            i_cor_tileTotalTimes    => i_cor1_tileTotalTimes,    -- in (7:0) -- Number of time samples to integrate for this tile.
            i_cor_tiletotalChannels => i_cor1_tileTotalChannels, -- in (6:0) -- Number of frequency channels to integrate for this tile.
            i_cor_rowstations       => i_cor1_rowStations,       -- in (8:0); -- number of stations in the row memories to process; up to 256.
            i_cor_colstations       => i_cor1_colStations,       -- in (8:0); -- number of stations in the col memories to process; up to 256.  
            i_cor_totalStations     => i_cor1_totalStations,     -- in (15:0); Total number of stations being processing for this subarray-beam.
            i_cor_subarrayBeam      => i_cor1_subarrayBeam,      -- in (7:0);  Which entry is this in the subarray-beam table ?
            i_cor_badPoly           => i_cor1_badPoly,           -- in std_logic;
            i_cor_tableSelect       => i_cor1_tableSelect,       -- in std_logic;
            ---------------------------------------------------------------
            -- Data out to the HBM
            o_HBM_axi_aw      => o_cor1_axi_aw, --  out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
            i_HBM_axi_awready => i_cor1_axi_awready, -- in  std_logic;
            o_HBM_axi_w       => o_cor1_axi_w,      -- out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
            i_HBM_axi_wready  => i_cor1_axi_wready, -- in  std_logic;
            i_HBM_axi_b       => i_cor1_axi_b,      -- in  t_axi4_full_b;    -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
            -- reading from HBM
            o_HBM_axi_ar      => o_cor1_axi_ar,      -- out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
            i_HBM_axi_arready => i_cor1_axi_arready, -- in  std_logic;
            i_HBM_axi_r       => i_cor1_axi_r,       -- in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
            o_HBM_axi_rready  => o_cor1_axi_rready,  -- out std_logic;
            ---------------------------------------------------------------
            -- data out to SPEAD Packetiser        
            i_from_spead_pack   => i_from_spead_pack(1),
            o_to_spead_pack     => o_to_spead_pack(1),

            i_packetiser_enable => i_packetiser_enable(1),
            
                    -- ARGs Debug
            i_spead_hbm_rd_lite_axi_mosi => i_spead_hbm_rd_lite_axi_mosi(1),
            o_spead_hbm_rd_lite_axi_miso => o_spead_hbm_rd_lite_axi_miso(1),
            ---------------------------------------------------------------
            -- Registers
            o_HBM_end           => cor1_HBM_end,     -- out (31:0); Byte address offset into the HBM buffer where the visibility circular buffer ends.
            o_HBM_errors        => cor1_HBM_errors, -- out (3:0); Number of cells currently in the circular buffer.
            o_HBM_curr_rd_addr  => cor1_HBM_curr_rd_base,
            ---------------------------------------------------------------
            -- copy of the bus taking data to be written to the HBM.
            -- Used for simulation only, to check against the model data.
            o_tb_data      => open, -- out (255:0);
            o_tb_visValid  => open, -- out std_logic; -- o_tb_data is valid visibility data
            o_tb_TCIvalid  => open, -- out std_logic; -- i_data is valid TCI & DV data
            o_tb_dcount    => open, -- out (7:0);  -- counts the 256 transfers for one cell of visibilites, or 16 transfers for the centroid data. 
            o_tb_cell      => open, -- out (7:0);  -- in (7:0);  -- a "cell" is a 16x16 station block of correlations
            o_tb_tile      => open, -- out (9:0);  -- a "tile" is a 16x16 block of cells, i.e. a 256x256 station correlation.
            o_tb_channel   => open  -- out (23:0) -- first fine channel index for this correlation.
        );
    end generate;
    
    nocor2geni : if (g_CORRELATORS < 2) generate
        cor1_HBM_start <= (others => '0');
        cor1_HBM_end <= (others => '0');
        cor1_HBM_cells <= (others => '0');
        o_packet1_dout <= (others => '0');
        o_packet1_valid <= '0';
        o_cor1_axi_aw.valid <= '0';
        o_cor1_axi_aw.addr <= (others => '0');
        o_cor1_axi_aw.len <= (others => '0');
        o_cor1_axi_w.valid <= '0';
        o_cor1_axi_w.data <= (others => '0');
        o_cor1_axi_w.last <= '0';
        o_cor1_axi_ar.valid <= '0';
        o_cor1_axi_ar.addr <= (others => '0');
        o_cor1_axi_ar.len <= (others => '0');
        o_cor1_axi_rready <= '0';
        o_cor1_ready <= '1';
    end generate;
    
--    ----------------------------------------------------------------
--    -- Registers
--    --
-- ARGS U55
gen_u55_arg : IF (C_TARGET_DEVICE = "U55") GENERATE    
    i_correlator_reg : entity correlator_lib.cor_config_reg
    port map (
        MM_CLK          => i_axi_clk,  -- in std_logic;
        MM_RST          => i_axi_rst,  -- in std_logic;
        SLA_IN          => i_axi_mosi, -- in t_axi4_lite_mosi;
        SLA_OUT         => o_axi_miso, -- out t_axi4_lite_miso;
        SETUP_FIELDS_RW => config_rw,  -- out t_setup_rw;
        SETUP_FIELDS_RO => config_ro   -- in  t_setup_ro
    );

END GENERATE;


-- ARGS Gaskets for V80
gen_v80_args : IF (C_TARGET_DEVICE = "V80") GENERATE
    i_cor_noc : entity noc_lib.args_noc
    generic map (
        G_DEBUG => FALSE
    )
    port map ( 
        i_clk       => i_axi_clk,
        i_rst       => i_axi_rst,
    
        noc_wren    => noc_wren,
        noc_rden    => noc_rden,
        noc_wr_adr  => noc_wr_adr,
        noc_wr_dat  => noc_wr_dat,
        noc_rd_adr  => noc_rd_adr,
        noc_rd_dat  => noc_rd_dat_mux
    );

    i_cor_args : entity correlator_lib.cor_config_versal
    port map (
        MM_CLK          => i_axi_clk,  -- in std_logic;
        MM_RST          => i_axi_rst,  -- in std_logic;
        
        noc_wren        => noc_wren,
        noc_rden        => noc_rden,
        noc_wr_adr      => noc_wr_adr,
        noc_wr_dat      => noc_wr_dat,
        noc_rd_adr      => noc_rd_adr,
        noc_rd_dat      => noc_rd_dat_mux,
        
        SETUP_FIELDS_RW => config_rw,  -- out t_setup_rw;
        SETUP_FIELDS_RO => config_ro   -- in  t_setup_ro
    );
    
END GENERATE;
    
    config_ro.cor0_HBM_start <= cor0_HBM_curr_rd_base; --(others => '0'); -- TODO - should come from the SPEAD packet readout module
    config_ro.cor0_HBM_end <= cor0_HBM_end;
    config_ro.cor0_HBM_size <= (others => '0'); -- TODO - calculate from cor0_HBM_end and cor0_HBM_start
    
    config_ro.cor1_HBM_start <= cor1_HBM_curr_rd_base; --(others => '0'); -- TODO - should come from the SPEAD packet readout module
    config_ro.cor1_HBM_end <= cor1_HBM_end;
    config_ro.cor1_HBM_size <= (others => '0'); -- TODO - calculate from cor0_HBM_end and cor0_HBM_start
    
    dummy <= config_rw.full_reset;
    
end Behavioral;
