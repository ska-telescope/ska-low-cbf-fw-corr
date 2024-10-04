----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 09/20/2022 04:27:58 PM
-- Module Name: single_correlator - Behavioral
-- Description: 
--  Includes all logic specific to a single instance of the correlator array (i.e. 16x16 cmac array) :
--    - 16x16 dual-pol stations CMAC array
--    - Long term accumulator
--    - HBM interface and packetiser
----------------------------------------------------------------------------------
library IEEE, correlator_lib, common_lib, spead_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
Library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;
USE common_lib.common_pkg.ALL;
use spead_lib.spead_packet_pkg.ALL;

entity single_correlator is
    generic (
        -- Number of pipeline stages to include between correlator array and HBM interface (since it crosses SLRs)
        g_PIPELINE_STAGES : integer := 2;
        -- Number of samples in most packets. Each sample is 34 bytes of data. 
        -- The last packet in a subarray will typically have less samples, since a given subarray 
        -- does not have any particular total length.
        g_PACKET_SAMPLES_DIV16 : integer   -- Actual number of samples in the packet is this value x16  
    );
    port(
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
        o_cor_ready : out std_logic;  
        -- Each 256 bit word : two time samples, 4 consecutive virtual channels
        -- (31:0) = time 0, virtual channel 0; (63:32) = time 0, virtual channel 1; (95:64) = time 0, virtual channel 2; (127:96) = time 0, virtual channel 3;
        -- (159:128) = time 1, virtual channel 0; (191:160) = time 1, virtual channel 1; (223:192) = time 1, virtual channel 2; (255:224) = time 1, virtual channel 3;
        i_cor_data  : in std_logic_vector(255 downto 0); 
        -- meta data
        i_cor_time    : in std_logic_vector(7 downto 0);  -- Time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
        i_cor_station : in std_logic_vector(11 downto 0); -- First of the 4 virtual channels in i_cor0_data
        -- Options for tileType : 
        --   '0' = Triangle. In this case, all the input data goes to both the row and column memories, and a triangle from the correlation matrix is computed.
        --            For correlation cells on the diagonal, only non-duplicate entries are sent out.
        --   '1' = Rectangle. In this case, the first 256 virtual channels on i_cor0_data go to the column memories, while the next 128 virtual channels go to the row memories.
        --            All correlation products for the rectangle are then computed.
        i_cor_tileType : in std_logic;
        i_cor_valid : in std_logic;  -- i_cor0_data, i_cor0_time, i_cor0_VC, i_cor0_FC and i_cor0_tileType are valid when i_cor0_valid = '1'
        -- i_cor0_last and i_cor0_final go high after a block of data has been sent.
        i_cor_first : in std_logic;  -- This is the first block of data for an integration - i.e. first fine channel, first block of 64 time samples, for this tile
        i_cor_last  : in std_logic;  -- last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
        i_cor_final : in std_logic;  -- Indicates that at the completion of processing the most recent block of correlator data, the integration is complete. i_cor0_tileCount and i_cor0_tileChannel are valid when this is high.   
        -- up to 1024 different tiles; each tile is a subset of the correlation for particular subarray and beam.
        -- Tiles can be triangles or rectangles from the full correlation.
        -- e.g. for 512x512 stations, there will be 4 tiles, consisting of 2 triangles and 2 rectangles.
        --      for 4096x4096 stations, there will be 16 triangles, and 240 rectangles.
        i_cor_tileLocation : in std_logic_vector(9 downto 0);
        i_cor_frameCount   : in std_logic_vector(31 downto 0);
        -- Fine channel being delivered, relative to the start of the data HBM.
        i_cor_tileChannel : in std_logic_vector(23 downto 0);
        
        -- more correlator configuration
        i_cor_tileTotalTimes    : in std_logic_vector(7 downto 0); -- Number of time samples to integrate for this tile.
        i_cor_tiletotalChannels : in std_logic_Vector(4 downto 0); -- Number of frequency channels to integrate for this tile.
        i_cor_rowstations       : in std_logic_vector(8 downto 0); -- Number of stations in the row memories to process; up to 256.
        i_cor_colstations       : in std_logic_vector(8 downto 0); -- Number of stations in the col memories to process; up to 256.        
        i_cor_totalStations     : in std_logic_vector(15 downto 0); -- Total number of stations being processing for this subarray-beam.
        i_cor_subarrayBeam      : in std_logic_vector(7 downto 0);  -- Which entry is this in the subarray-beam table ?
        ---------------------------------------------------------------
        -- Data out to the HBM
        o_HBM_axi_aw      : out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_awready : in  std_logic;
        o_HBM_axi_w       : out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_HBM_axi_wready  : in  std_logic;
        i_HBM_axi_b       : in  t_axi4_full_b;    -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        -- reading from HBM
        o_HBM_axi_ar      : out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_arready : in  std_logic;
        i_HBM_axi_r       : in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_rready  : out std_logic;
        ---------------------------------------------------------------
        -- data out to SPEAD Packetiser
        i_from_spead_pack   : in spead_to_hbm_bus;
        o_to_spead_pack     : out hbm_to_spead_bus;

        i_packetiser_enable : in std_logic;
        
        i_spead_hbm_rd_lite_axi_mosi : in t_axi4_lite_mosi; 
        o_spead_hbm_rd_lite_axi_miso : out t_axi4_lite_miso;
        ---------------------------------------------------------------
        -- Registers
        o_HBM_end   : out std_logic_vector(31 downto 0); -- byte address offset into the HBM buffer where the visibility circular buffer ends.
        o_HBM_errors : out std_logic_vector(3 downto 0);  -- Something has gone wrong.

        o_HBM_curr_rd_addr  : out std_logic_vector(31 downto 0);
        
        ---------------------------------------------------------------
        -- copy of the bus taking data to be written to the HBM.
        -- Used for simulation only, to check against the model data.
        o_tb_data      : out std_logic_vector(255 downto 0);
        o_tb_visValid  : out std_logic; -- o_tb_data is valid visibility data
        o_tb_TCIvalid  : out std_logic; -- i_data is valid TCI & DV data
        o_tb_dcount    : out std_logic_vector(7 downto 0);  -- counts the 256 transfers for one cell of visibilites, or 16 transfers for the centroid data. 
        o_tb_cell      : out std_logic_vector(7 downto 0);  -- in (7:0);  -- a "cell" is a 16x16 station block of correlations
        o_tb_tile      : out std_logic_vector(9 downto 0);  -- a "tile" is a 16x16 block of cells, i.e. a 256x256 station correlation.
        o_tb_channel   : out std_logic_vector(23 downto 0) -- first fine channel index for this correlation.
    );
end single_correlator;

architecture Behavioral of single_correlator is

    signal data_del : t_slv_256_arr(g_PIPELINE_STAGES downto 0);
    signal visValid_del : std_logic_vector(g_PIPELINE_STAGES downto 0);
    signal TCIValid_del : std_logic_vector(g_PIPELINE_STAGES downto 0);
    signal dcount_del : t_slv_8_arr(g_PIPELINE_STAGES downto 0);
    signal cell_del   : t_slv_8_arr(g_PIPELINE_STAGES downto 0);
    signal cellLast_del : std_logic_vector(g_PIPELINE_STAGES downto 0);
    signal tile_del   : t_slv_10_arr(g_PIPELINE_STAGES downto 0);
    signal channel_del : t_slv_24_arr(g_PIPELINE_STAGES downto 0);
    signal totalStations_del : t_slv_16_arr(g_PIPELINE_STAGES downto 0);
    signal subarrayBeam_del : t_slv_8_arr(g_PIPELINE_STAGES downto 0);
    signal HBM_stop    : std_logic_vector(g_PIPELINE_STAGES downto 0);
    
    signal ro_HBM_start_addr : std_logic_vector(31 downto 0);
    signal ro_subarray : std_logic_vector(7 downto 0);
    signal ro_freq_index : std_logic_vector(16 downto 0);
    signal ro_time_ref : std_logic_vector(63 downto 0);
    signal ro_row : std_logic_vector(12 downto 0);
    signal ro_row_count : std_logic_vector(8 downto 0);
    signal ro_valid : std_logic;
    
    component ila_120_16k
    port (
        clk : in std_logic;
        probe0 : in std_logic_vector(119 downto 0)); 
    end component;
    
    signal packetiser_reset : std_logic;
    signal cor_ready_int : std_logic;
    
    signal dbg_i_cor_time : std_logic_vector(7 downto 0);  -- Time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
    signal dbg_i_cor_station : std_logic_vector(11 downto 0); 
    signal dbg_i_cor_valid : std_logic;
    signal dbg_i_cor_first : std_logic;  -- This is the first block of data for an integration - i.e. first fine channel, first block of 64 time samples, for this tile
    signal dbg_i_cor_last  : std_logic;  -- last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
    signal dbg_i_cor_final : std_logic;
    signal dbg_i_cor_frameCount : std_logic_vector(31 downto 0);
    signal dbg_i_cor_tileChannel : std_logic_vector(23 downto 0);
    signal dbg_o_cor_ready : std_logic;
    
    signal dbg_ro_HBM_start_addr : std_logic_vector(31 downto 0); -- (32 bit)
    signal dbg_ro_subarray  : std_logic_vector(3 downto 0);  -- (4 bit)
    signal dbg_ro_freq_index : std_logic_vector(15 downto 0);  -- 
    signal dbg_ro_valid : std_logic;
    signal dbg_ro_valid_del2, dbg_ro_valid_del1 : std_logic;
    signal time_since_f0, f0_clk_count : std_logic_vector(31 downto 0);
    signal freq_index0_repeat, time_since_f0_set : std_logic := '0';
    
begin

    ----------------------------------------------------------------------------------
    -- 1st instance of correlator, long term accumulator, and HBM dump:
    
    o_cor_ready <= cor_ready_int;
    
    cor1i : entity correlator_lib.full_correlator
    port map (
        -- clock used for all data input and output from this module (300 MHz)
        i_axi_clk => i_axi_clk, -- in std_logic;
        i_axi_rst => i_axi_rst, -- in std_logic;
        -- Processing clock used for the correlation (>412.5 MHz)
        i_cor_clk => i_cor_clk, --  in std_logic;
        i_cor_rst => i_cor_rst, --  in std_logic;
        ---------------------------------------------------------------
        -- Data in to the correlator arrays
        --
        -- correlator is ready to receive a new block of data. This will go low once data starts to be received.
        -- A block of data consists of data for 1 fine channel, 64 times, and 256 cells (i.e. 256 stations if on the diagonal, or up to 512 stations if row and column data is different)
        o_cor_ready => cor_ready_int, --  out std_logic;  
        -- Each 256 bit word : two time samples, 4 consecutive virtual channels
        -- (31:0) = time 0, virtual channel 0; (63:32) = time 0, virtual channel 1; (95:64) = time 0, virtual channel 2; (127:96) = time 0, virtual channel 3;
        -- (159:128) = time 1, virtual channel 0; (191:160) = time 1, virtual channel 1; (223:192) = time 1, virtual channel 2; (255:224) = time 1, virtual channel 3;
        i_cor_data  => i_cor_data, -- in (255:0); 
        -- meta data
        i_cor_time  => i_cor_time, -- in (7:0); Time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
        -- Counts the virtual channels in i_cor_data, always in steps of 4, where the value is the first of the 4 virtual channels in i_cor_data
        -- If i_cor_tileType = '0', then up to 256 channels are delivered, with the same channels going to both row and column memories.
        --                          In this case, i_cor_VC_count will run from 0 to 256 in steps of 4.
        -- If i_cor_tileType = '1', then up to 512 channels are delivered, with different channels going to the row and column memories.
        --                          counts 0 to 255 go to the column memories, while counts 256-511 go to the row memories. 
        i_cor_station => i_cor_station, --  in (11:0); 
        -- Options for tileType : 
        --   '0' = Triangle. In this case, all the input data goes to both the row and column memories, and a triangle from the correlation matrix is computed.
        --         The number of 16x16 correlation cells computed will be 
        --   '1' = Rectangle/square. In this case, 
        --            - The first "i_cor_col_stations" virtual channels on i_cor_data go to the column memories,
        --            - The next  "i_cor_row_stations" virtual channels go to the row memories.
        --         All correlation products for the rectangle are then computed.
        i_cor_tileType => i_cor_tileType, -- in std_logic;
        i_cor_valid    => i_cor_valid,    -- in std_logic;  -- i_cor0_data, i_cor0_time, i_cor0_VC, i_cor0_FC and i_cor0_tileType are valid when i_cor0_valid = '1'
        -- i_cor0_last and i_cor0_final go high after a block of data has been sent.
        i_cor_last     => i_cor_last,  -- in std_logic;  -- last word in a block for correlation; Indicates that the correlator can start processing the tile just delivered.
        i_cor_first    => i_cor_first, -- in std_logic;  -- This is the first block of data for an integration - i.e. first fine channel, first block of 64 time samples, for this tile
        i_cor_final    => i_cor_final, -- in std_logic;  -- Indicates that at the completion of processing the most recent block of correlator data, the integration is complete. i_cor_tile and i_cor_tileChannel are valid when this is high.   
        -- up to 1024 different tiles; each tile is a subset of the correlation for particular subarray and beam.
        -- Tiles can be triangles or rectangles/squares from the full correlation.
        -- e.g. for 512x512 stations, there will be 3 tiles, consisting of 2 triangles and 1 square.
        --      for 4096x4096 stations, there will be 16 triangles, and 120 squares.
        i_cor_tile     => i_cor_tileLocation, -- in (9:0); bits 3:0 = tile column, bits 7:4 = tile row, bits 9:8 = "00";
        -- Which block of frequency channels is this tile for ?
        -- This sets the offset within the HBM that the result is written to, relative to the base address which is extracted from registers based on i_cor_tile.
        i_cor_tileChannel       => i_cor_tileChannel,       -- in (23:0);
        i_cor_tileTotalTimes    => i_cor_tileTotalTimes,    -- in (7:0); Number of time samples to integrate for this tile.
        i_cor_tiletotalChannels => i_cor_tileTotalChannels, -- in (4:0); Number of frequency channels to integrate for this tile.
        i_cor_row_stations      => i_cor_rowStations, -- in (8:0); Number of stations in the row memories to process; up to 256.
        i_cor_col_stations      => i_cor_colStations, -- in (8:0); Number of stations in the col memories to process; up to 256.
        i_cor_totalStations     => i_cor_totalStations, -- in (15:0); Total number of stations being processing for this subarray-beam.
        i_cor_subarrayBeam      => i_cor_subarrayBeam,  -- in (7:0);  -- Which entry is this in the subarray-beam table ?
        
        -- Data out to the HBM
        -- o_data is a burst of 16*16*4*8 = 8192 bytes = 256 clocks with 256 bits per clock, for one cell of visibilities, when o_dtype = '0'
        -- When o_dtype = '1', centroid data is being sent as a block of 16*16*2 = 512 bytes = 16 clocks with 256 bits per clock.
        o_data     => data_del(0),     -- out (255:0);
        o_visValid => visValid_del(0), -- out std_logic; o_data is valid visibility data
        o_TCIvalid => TCIValid_del(0), -- out std_logic; o_data is valid TCI & DV data
        o_dcount   => dcount_del(0),   -- out (7:0); Counts the 256 transfers for one cell of visibilites, or 16 transfers for the centroid data. 
        o_cell     => cell_del(0),     -- out (7:0); A "cell" is a 16x16 station block of correlations
        o_cellLast => cellLast_del(0), -- out std_logic; This is the last cell for the tile.
        o_tile     => tile_del(0),     -- out (9:0); A "tile" is a 16x16 block of cells, i.e. a 256x256 station correlation.
        o_channel  => channel_del(0),  -- out (23:0); First fine channel index for this correlation.
        o_totalStations => totalStations_del(0), -- out std_logic_vector(15 downto 0); -- total number of stations in this subarray-beam
        o_subarrayBeam  => subarrayBeam_del(0),  -- out std_logic_vector(7 downto 0);  -- Index into the subarray-beam table.
        
        -- stop sending data; somewhere downstream there is a FIFO that is almost full.
        -- There can be a lag of about 20 clocks between i_stop going high and data stopping.
        i_stop     => HBM_stop(g_PIPELINE_STAGES)  -- in std_logic
    );
    
    
    -- Pipeline stages on the output of the correlator, so the data can pass back across the SLRs to SLR0 where the HBM is.
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            -- From the correlator array to the HBM interface
            data_del(g_PIPELINE_STAGES downto 1)     <= data_del(g_PIPELINE_STAGES-1 downto 0);
            visValid_del(g_PIPELINE_STAGES downto 1) <= visValid_del(g_PIPELINE_STAGES-1 downto 0);
            TCIValid_del(g_PIPELINE_STAGES downto 1) <= TCIValid_del(g_PIPELINE_STAGES-1 downto 0);
            dcount_del(g_PIPELINE_STAGES downto 1)   <= dcount_del(g_PIPELINE_STAGES-1 downto 0);
            cell_del(g_PIPELINE_STAGES downto 1)     <= cell_del(g_PIPELINE_STAGES-1 downto 0);
            cellLast_del(g_PIPELINE_STAGES downto 1) <= cellLast_del(g_PIPELINE_STAGES-1 downto 0);
            tile_del(g_PIPELINE_STAGES downto 1)     <= tile_del(g_PIPELINE_STAGES-1 downto 0);
            channel_del(g_PIPELINE_STAGES downto 1)  <= channel_del(g_PIPELINE_STAGES-1 downto 0);
            totalStations_del(g_PIPELINE_STAGES downto 1) <= totalStations_del(g_PIPELINE_STAGES-1 downto 0);
            subarrayBeam_del(g_PIPELINE_STAGES downto 1)  <= subarrayBeam_del(g_PIPELINE_STAGES-1 downto 0);
            
            -- HBM interface back to the correlator array.
            HBM_stop(g_PIPELINE_STAGES downto 1) <= HBM_stop(g_PIPELINE_STAGES-1 downto 0);
            
        end if;
    end process;   
    
    -- Send to top level for comparision with model data in the testbench
    o_tb_data      <= data_del(g_PIPELINE_STAGES);     -- out (255:0);
    o_tb_visValid  <= visValid_del(g_PIPELINE_STAGES); -- out std_logic; i_data is valid visibility data
    o_tb_TCIvalid  <= TCIValid_del(g_PIPELINE_STAGES); -- out std_logic; i_data is valid TCI & DV data
    o_tb_dcount    <= dcount_del(g_PIPELINE_STAGES);   -- out (7:0); Counts the 256 transfers for one cell of visibilites, or 16 transfers for the centroid data. 
    o_tb_cell      <= cell_del(g_PIPELINE_STAGES);     -- out (7:0); A "cell" is a 16x16 station block of correlations
    o_tb_tile      <= tile_del(g_PIPELINE_STAGES);     -- out (9:0); A "tile" is a 16x16 block of cells, i.e. a 256x256 station correlation.
    o_tb_channel   <= channel_del(g_PIPELINE_STAGES);  --    
    
    
    -- Dump to HBM
    icdump : entity correlator_lib.correlator_HBM
    generic map (
        -- Number of samples in most packets. Each sample is 34 bytes of data. 
        -- The last packet in a subarray will typically have less samples, since a given subarray 
        -- does not have any particular total length.
        g_PACKET_SAMPLES_DIV16 => g_PACKET_SAMPLES_DIV16  -- : integer  
    ) Port map ( 
        i_axi_clk   => i_axi_clk, -- in std_logic;
        i_axi_rst   => i_axi_rst, -- in std_logic;
        ----------------------------------------------------------------------------------------
        -- Data in from the long term accumulator
        i_data      => data_del(g_PIPELINE_STAGES),     -- in (255:0);
        i_visValid  => visValid_del(g_PIPELINE_STAGES), -- in std_logic; i_data is valid visibility data
        i_TCIvalid  => TCIValid_del(g_PIPELINE_STAGES), -- in std_logic; i_data is valid TCI & DV data
        i_dcount    => dcount_del(g_PIPELINE_STAGES),   -- in (7:0);  Counts the 256 transfers for one cell of visibilites, or 16 transfers for the centroid data. 
        i_cell      => cell_del(g_PIPELINE_STAGES),     -- in (7:0);  A "cell" is a 16x16 station block of correlations
        i_cellLast  => cellLast_del(g_PIPELINE_STAGES), -- std_logic; Last cell for this tile.
        i_tile      => tile_del(g_PIPELINE_STAGES),     -- in (9:0);  A "tile" is a 16x16 block of cells, i.e. a 256x256 station correlation.
        i_channel   => channel_del(g_PIPELINE_STAGES),  -- in (23:0); First fine channel index for this correlation.
        i_totalStations => totalStations_del(g_PIPELINE_STAGES),
        i_subarrayBeam => subarrayBeam_del(g_PIPELINE_STAGES),
        -- stop sending data; somewhere downstream there is a FIFO that is almost full.
        -- There can be a lag of about 20 clocks between i_stop going high and data stopping.
        o_stop      => HBM_stop(0),                     --  out std_logic;
        
        -----------------------------------------------------------------------------------------
        -- Status info
        o_HBM_end   => o_HBM_end, -- out (31:0); Byte address offset into the HBM buffer where the visibility circular buffer ends.
        o_errors    => o_HBM_errors,
        -----------------------------------------------------------------------------------------
        -- Readout bus "ro"
        -- Notifies the SPEAD packet generation module that data is available in the HBM to be read out.
        -- This bus is on the i_axi_clk domain (i.e. same clock as the HBM interface).
        
        -- Byte address in HBM of the start of a strip from the visibility matrix.
        -- Start address of the meta data is at (o_HBM_start_addr/16 + 256 Mbytes)
        o_ro_HBM_start_addr => ro_HBM_start_addr, -- out (31:0);
        -- Index of the subarray-beam,
        -- This is the address into the table in the second corner turn. Valid range is 0 up.
        o_ro_subarray => ro_subarray, -- out (7:0);
        -- output frequency index. Count of the frequency channels being generated
        -- by the correlator. Counts from 0.
        o_ro_freq_index => ro_freq_index, -- out (16:0);
        -- Some kind of timestamp. Will be the same for all subarrays within a single 849 ms 
        -- integration time.
        o_ro_time_ref => open, -- out (63:0);
        -- The first of the block of rows in the visibility matrix that is now available for readout.
        -- Counts from 0. 
        -- The number of columns to read out for the first row will be (o_row + 1).
        -- The number of columns to read out for the last row in this strip will be (o_row + o_row_count)
        o_ro_row => ro_row, --  out (12:0);
        -- The number of rows to read out. Valid range is 1 up to 256.
        o_ro_row_count => ro_row_count, -- out (8:0);
        -- valid indicates that the other signals are valid. 
        -- valid will pulse high for 1 clock cycle when a strip of data from the visibility matrix is available.
        o_ro_valid => ro_valid, -- out std_logic;
        -----------------------------------------------------------------------------------------
        -- HBM interface
        -- Write to HBM
        o_axi_aw      => o_HBM_axi_aw,      -- out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_axi_awready => i_HBM_axi_awready, -- in  std_logic;
        o_axi_w       => o_HBM_axi_w,       -- out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_axi_wready  => i_HBM_axi_wready,  -- in  std_logic;
        i_axi_b       => i_HBM_axi_b        -- in  t_axi4_full_b; write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
    );
    

    packetiser_reset <= NOT i_packetiser_enable;

    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            ro_time_ref(63 downto 34) <= (others => '0');
            -- TBD : Fix for 283ms integrations 
            ro_time_ref(33 downto 32) <= "10";
            ro_time_ref(31 downto 0) <= i_cor_frameCount;
        end if;
    end process;


    HBM_reader : entity correlator_lib.correlator_data_reader generic map ( 
        DEBUG_ILA           => FALSE
    )
    Port map ( 
        -- clock used for all data input and output from this module (300 MHz)
        i_axi_clk           => i_axi_clk,
        i_axi_rst           => i_axi_rst,

        i_local_reset       => packetiser_reset,
        
        -- ARGs Debug
        i_spead_hbm_rd_lite_axi_mosi =>  i_spead_hbm_rd_lite_axi_mosi,
        o_spead_hbm_rd_lite_axi_miso => o_spead_hbm_rd_lite_axi_miso,

        -- config of current sub/freq data read
        i_hbm_start_addr    => ro_HBM_start_addr,
                                                                    -- Start address of the meta data is at (i_HBM_start_addr/16 + 256 Mbytes)
        i_sub_array         => ro_subarray,
        i_freq_index        => ro_freq_index,
        i_time_ref          => ro_time_ref,
                            
        i_row               => ro_row,
        i_row_count         => ro_row_count,
        i_data_valid        => ro_valid,

        o_HBM_curr_addr     => o_HBM_curr_rd_addr,

        -- HBM read interface
        o_HBM_axi_ar        => o_HBM_axi_ar,
        i_HBM_axi_arready   => i_HBM_axi_arready,
        i_HBM_axi_r         => i_HBM_axi_r,
        o_HBM_axi_rready    => o_HBM_axi_rready,
        
        -- Packed up Correlator Data.
        i_from_spead_pack   => i_from_spead_pack,
        o_to_spead_pack     => o_to_spead_pack

    );
    
    
    -- ILA
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            dbg_ro_HBM_start_addr <= ro_HBM_start_addr; -- (32 bit)
            dbg_ro_subarray <= ro_subarray(3 downto 0); -- (4 bit)
            dbg_ro_freq_index <= ro_freq_index(15 downto 0); -- 
            dbg_ro_valid <= ro_valid;
            
            dbg_i_cor_time <= i_cor_time; -- in std_logic_vector(7 downto 0);  -- Time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
            dbg_i_cor_station <= i_cor_station; -- : in std_logic_vector(11 downto 0); 
            dbg_i_cor_valid <= i_cor_valid; -- : in std_logic;
            dbg_i_cor_first <= i_cor_first; -- : in std_logic;  -- This is the first block of data for an integration - i.e. first fine channel, first block of 64 time samples, for this tile
            dbg_i_cor_last <= i_cor_last; --   : in std_logic;  -- last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
            dbg_i_cor_final <= i_cor_final; --  : in std_logic;
            dbg_i_cor_frameCount <= i_cor_frameCount; --   : in std_logic_vector(31 downto 0);
            -- Fine channel being delivered, relative to the start of the data HBM.
            dbg_i_cor_tileChannel <= i_cor_tileChannel; -- : in std_logic_vector(23 downto 0);            
            dbg_o_cor_ready <= cor_ready_int; --  out std_logic;
            
            dbg_ro_valid_del1 <= dbg_ro_valid;
            dbg_ro_valid_del2 <= dbg_ro_valid_del1;
            if dbg_ro_valid = '1' and dbg_ro_valid_del1 = '0' and (unsigned(dbg_ro_freq_index) = 0) then
                time_since_f0 <= f0_clk_count;
                time_since_f0_set <= '1';
                f0_clk_count <= (others => '0');
            else
                f0_clk_count <= std_logic_vector(unsigned(f0_clk_count) + 1);
                time_since_f0_set <= '0';
            end if;
            
            -- There should be 849 ms = 254700000 (300MHz) clocks between readouts with freq index 0, assuming a single subarray.
            if time_since_f0_set = '1' and (unsigned(time_since_f0) < 100000000) then
                freq_index0_repeat <= '1';
            else
                freq_index0_repeat <= '0';
            end if;
            
        end if;
    end process;
     
    
    trigger_ila : ila_120_16k
    port map (
        clk => i_axi_clk,   -- IN STD_LOGIC;
        probe0(31 downto 0) => dbg_ro_HBM_start_addr(31 downto 0),
        probe0(47 downto 32) => dbg_ro_freq_index,
        probe0(51 downto 48) => dbg_ro_subarray,
        probe0(52) => dbg_ro_valid,
        probe0(53) => freq_index0_repeat,
        probe0(77 downto 54) => f0_clk_count(31 downto 8),
        probe0(78) => '0',
        probe0(79) => dbg_o_cor_ready,
        probe0(87 downto 80) => dbg_i_cor_time,
        probe0(91 downto 88) => dbg_i_cor_station(3 downto 0),
        probe0(92) => dbg_i_cor_valid,
        probe0(93) => dbg_i_cor_first,
        probe0(94) => dbg_i_cor_last,
        probe0(95) => dbg_i_cor_final,
        probe0(103 downto 96) => dbg_i_cor_frameCount(7 downto 0),
        probe0(119 downto 104) => dbg_i_cor_tileChannel(15 downto 0)
    );
    

    
    
end Behavioral;
