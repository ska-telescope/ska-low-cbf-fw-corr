----------------------------------------------------------------------------------
-- Company: CSIRO 
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: Jan 2026 (based on earlier u55c version)
-- Module Name: correlator_top_v80 - Behavioral
-- Description: 
--  Top level for a single correlator core
-- 
-- Structure
--  mult-accumulate is done using a 32x32 matrix correlators.
--  The 32x32 matrix correlator can process 512 dual-pol stations for 1 LFAA coarse channel, with a 412.5 MHz minimum clock speed.
--  32 = 16 stations x 2 polarisations.
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
--      - Also calculates and stores weights to account for RFI
--
-- STRUCTURE:
--   This level instantiates
--    - corr_ct2_dout_v80, which read data from the HBM
--    - an instance of "single_correlator"
--    - Register interface, which is used for monitoring only.
--   
--    
--   A single_correlator instance uses 
--      - 1024 DSPs, using versal DSPs to implement a complex MAC in 1 DSP.
--      - 128 ultraRAMs for the long term accumulator.
--      - One HBM interface to dump data to
--   Each single_correlator instance includes:
--      - The thing which does all the correlation calculations.
--        This part is designed to be placed in a single super logic region:
--         - A 32x32 station correlator array. Note each station is dual-pol.
--         - A long term accumulator ("LTA_top.vhd"), which can hold data for a 256x256 station correlation. 
--      - Module to write to HBM.
--
--
--
--      - Packetiser (reads from HBM and generates SPEAD packets).
----------------------------------------------------------------------------------
library IEEE, correlator_lib, common_lib, xpm, spead_lib, ct_lib;
library axi4_lib, DSP_top_lib, noc_lib, signal_processing_common;

use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use correlator_lib.cor_config_reg_pkg.ALL;
use common_lib.common_pkg.ALL;
use xpm.vcomponents.all;
use axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;
use spead_lib.spead_packet_pkg.ALL;
use signal_processing_common.target_fpga_pkg.ALL;


entity correlator_top_v80 is
    generic (
        g_CORRELATOR_INSTANCE : integer   -- unique ID for this correlator instance
    );
    port (
        -- clock used for all data input and output from this module (300 MHz)
        i_axi_clk : in std_logic;
        i_axi_rst : in std_logic;
        -- Processing clock used for the correlation (>412.5 MHz)
        i_cor_clk : in std_logic;
        i_cor_rst : in std_logic;
        ---------------------------------------------------------------------------
        -- AXI stream input with packets of control data from corner turn 2
        i_cor_cfg_data  : in std_logic_vector(7 downto 0);
        i_cor_cfg_first : in std_logic;
        i_cor_cfg_last  : in std_logic;
        i_cor_cfg_valid : in std_logic;
        ---------------------------------------------------------------------------
        -- 256 bit wide memory interface
        -- Read from HBM to go to the correlator
        o_HBM_axi_ar      : out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_arready : in  std_logic;
        i_HBM_axi_r       : in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_rready  : out std_logic;
        -- write to HBM at the output of the correlator
        o_HBM_axi_aw      : out t_axi4_full_addr; -- write address bus (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_awready : in  std_logic;
        o_HBM_axi_w       : out t_axi4_full_data; -- w data bus (.valid, .data(511:0), .last, .resp(1:0))
        i_HBM_axi_wready  : in  std_logic;
        i_HBM_axi_b       : in  t_axi4_full_b; -- write response bus (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        ---------------------------------------------------------------
        -- Readout bus tells the packetiser what to do
        o_ro_data : out std_logic_vector(127 downto 0);
        o_ro_valid : out std_logic;
        i_ro_stall : in std_logic;
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
end correlator_top_v80;

architecture Behavioral of correlator_top_v80 is
    
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
    
    signal cor_ready : std_logic;
    signal cor_data : std_logic_vector(255 downto 0);
    signal cor_time : std_logic_vector(7 downto 0); --  Time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
    signal cor_station : std_logic_vector(11 downto 0); --First of the 4 virtual channels in o_cor0_data
    signal cor_valid : std_logic;
    signal cor_frameCount : std_logic_vector(31 downto 0);
    signal cor_last : std_logic;  -- Last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
    signal cor_final : std_logic; -- Indicates that at the completion of processing the last block of correlator data, the integration is complete.
    signal cor_tileType : std_logic;
    signal cor_first : std_logic;  -- This is the first block of data for an integration - i.e. first fine channel, first block of 64 time samples, for this tile
    signal cor_tileLocation : std_logic_vector(9 downto 0);
    signal cor_tileChannel  : std_logic_vector(23 downto 0);
    signal cor_tileTotalTimes : std_logic_vector(7 downto 0);  --Number of time samples to integrate for this tile.
    signal cor_tileTotalChannels : std_logic_vector(6 downto 0); -- Number of frequency channels to integrate for this tile.
    signal cor_rowStations : std_logic_vector(8 downto 0); -- Number of stations in the row memories to process; up to 256.
    signal cor_colStations : std_logic_vector(8 downto 0); -- Number of stations in the col memories to process; up to 256.
    signal cor_subarrayBeam : std_logic_vector(7 downto 0); -- Which entry is this in the subarray-beam table ? 
    signal cor_totalStations : std_logic_vector(15 downto 0); -- Total number of stations being processing for this subarray-beam.
    signal cor_badPoly : std_logic;        -- out std_logic; No valid polynomial for some of the data in the subarray-beam
    signal cor_tableSelect : std_logic;
    
    signal cfg_mem_select_wr : std_logic := '0';
    signal cfg_mem_select_rd : std_logic := '0';
    signal cfg_wr_addr : std_logic_vector(10 downto 0);
    signal SB_wr_addr : std_logic_vector(9 downto 0);
    
    signal total_subarray_beams_hold : std_logic_vector(7 downto 0);
    signal cfg_word_wr_en : std_logic_vector(0 downto 0);
    signal cfg_word : std_logic_vector(31 downto 0) := x"00000000";
    signal readout_tableSelect : std_logic := '0';
    signal total_subarray_beams : std_logic_vector(7 downto 0);
    signal readout_start : std_logic;
    signal SB_rd_data : std_logic_vector(31 downto 0);
    signal SB_rd_addr : std_logic_vector(9 downto 0);
    signal dout_SB_done : std_logic := '1';
    signal cur_readout_SB : std_logic_vector(6 downto 0);
    type t_SB_rd_fsm is (idle, get_dout_rd1, get_dout_rd2, get_dout_rd3, get_dout_rd4);
    signal SB_rd_fsm : t_SB_rd_fsm := idle;
    signal SB_rd_fsm_del1, SB_rd_fsm_del2, SB_rd_fsm_del3 : t_SB_rd_fsm := idle;
    signal dout_SB_req, dout_SB_req_d0 : std_logic := '0';
    signal SB_rd_fsm_dbg : std_logic_vector(3 downto 0);
    signal dout_SB_stations : std_logic_vector(15 downto 0);
    signal dout_SB_coarseStart : std_logic_vector(15 downto 0);
    signal dout_SB_outputDisable : std_logic;
    signal dout_SB_fineStart : std_logic_vector(15 downto 0);
    signal dout_SB_n_fine : std_logic_vector(23 downto 0);
    signal dout_SB_fineIntegrations : std_logic_vector(6 downto 0);
    signal dout_SB_timeIntegrations : std_logic;
    signal dout_SB_valid : std_logic;
    signal dout_SB_HBM_base_addr : std_logic_vector(31 downto 0);
    signal dout_SB_bad_poly : std_logic;
    
    signal dout_ar_fsm_dbg : std_logic_vector(3 downto 0);
    signal dout_readout_fsm_dbg : std_logic_vector(3 downto 0);
    signal dout_arFIFO_wr_count : std_logic_vector(6 downto 0);
    signal dout_dataFIFO_wrCount : std_logic_vector(9 downto 0);
    signal dout_readout_error  : std_logic;
    signal dout_recent_start_gap : std_logic_vector(31 downto 0);
    signal dout_recent_readout_time : std_logic_vector(31 downto 0);
    signal dout_min_start_gap : std_logic_vector(31 downto 0);
    signal packet_first_bytes_count : std_logic_vector(2 downto 0);
    signal readout_buffer_hold, readout_buffer : std_logic;
    signal readout_frameCount_hold, readout_frameCount : std_logic_vector(31 downto 0);
    signal axi_rst_del2, axi_rst_del1 : std_logic;
    
begin
    
    -------------------------------------------------------------
    -- Get instructions from corner turn 2
    -- subarray beam table and bad poly data
    -- A single packet comes in at the start of every 849ms frame.
    -- At the completion of the packet (i_cor_cfg_last = '1'), the correlator processes all the instructions for the full frame.
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            
            if i_cor_cfg_valid = '1' and i_cor_cfg_first = '1' then
                readout_buffer_hold <= i_cor_cfg_data(0);
                cfg_word_wr_en(0) <= '0';
                -- Data is double buffered in the memory, write data to the cfg_mem_select half, 
                -- then switch to that half for readout
                cfg_mem_select_wr <= not cfg_mem_select_wr; 
                packet_first_bytes_count <= "000";
            elsif i_cor_cfg_valid = '1' and (unsigned(packet_first_bytes_count) < 5) then
                packet_first_bytes_count <= std_logic_vector(unsigned(packet_first_bytes_count) + 1);
                if packet_first_bytes_count(2 downto 0) = "000" then
                    readout_frameCount_hold(7 downto 0) <= i_cor_cfg_data;
                elsif packet_first_bytes_count(2 downto 0) = "001" then
                    readout_frameCount_hold(15 downto 8) <= i_cor_cfg_data;
                elsif packet_first_bytes_count(2 downto 0) = "010" then
                    readout_frameCount_hold(23 downto 16) <= i_cor_cfg_data;
                elsif packet_first_bytes_count(2 downto 0) = "011" then
                    readout_frameCount_hold(31 downto 24) <= i_cor_cfg_data;
                else
                    total_subarray_beams_hold <= i_cor_cfg_data;
                end if;
                cfg_word_wr_en(0) <= '0';
                cfg_wr_addr <= (others => '0');
            elsif i_cor_cfg_valid = '1' then
                cfg_wr_addr <= std_logic_vector(unsigned(cfg_wr_addr) + 1);
                if cfg_wr_addr(1 downto 0) = "00" then
                    cfg_word(7 downto 0) <= i_cor_cfg_data;
                elsif cfg_wr_addr(1 downto 0) = "01" then
                    cfg_word(15 downto 8) <= i_cor_cfg_data;
                elsif cfg_wr_addr(1 downto 0) = "10" then
                    cfg_word(23 downto 16) <= i_cor_cfg_data;
                else
                    cfg_word(31 downto 24) <= i_cor_cfg_data;
                end if;
                if cfg_wr_addr(1 downto 0) = "11" then
                    cfg_word_wr_en(0) <= '1';
                else
                    cfg_word_wr_en(0) <= '0';
                end if;
            else
                cfg_word_wr_en(0) <= '0';
            end if;
            
            if i_cor_cfg_valid = '1' and i_cor_cfg_last = '1' then
                -- trigger readout 
                readout_tableSelect <= cfg_mem_select_wr;
                total_subarray_beams <= total_subarray_beams_hold;
                readout_buffer <= readout_buffer_hold;
                readout_framecount <= readout_frameCount_hold;
                readout_start <= '1';
            else
                readout_start <= '0';
            end if;
            
        end if;
    end process;
    
    SB_wr_addr(9) <= cfg_mem_select_wr;
    SB_wr_addr(8 downto 0) <= cfg_wr_addr(10 downto 2);
    -- memory to hold the configuration data
    -- 2 buffers * 128 entries * 4 words each = 1024 deep (x 32 bits wide)
    -- xpm_memory_sdpram: Simple Dual Port RAM
    -- Xilinx Parameterized Macro, version 2025.1
    xpm_memory_sdpram_inst : xpm_memory_sdpram
    generic map (
        ADDR_WIDTH_A => 10,               -- DECIMAL
        ADDR_WIDTH_B => 10,               -- DECIMAL
        AUTO_SLEEP_TIME => 0,            -- DECIMAL
        BYTE_WRITE_WIDTH_A => 32,        -- DECIMAL
        CASCADE_HEIGHT => 0,             -- DECIMAL
        CLOCKING_MODE => "common_clock", -- String
        ECC_BIT_RANGE => "7:0",          -- String
        ECC_MODE => "no_ecc",            -- String
        ECC_TYPE => "none",              -- String
        IGNORE_INIT_SYNTH => 0,          -- DECIMAL
        MEMORY_INIT_FILE => "none",      -- String
        MEMORY_INIT_PARAM => "0",        -- String
        MEMORY_OPTIMIZATION => "true",   -- String
        MEMORY_PRIMITIVE => "auto",      -- String
        MEMORY_SIZE => 32768,             -- DECIMAL 1024 * 32 = 32768
        MESSAGE_CONTROL => 0,            -- DECIMAL
        RAM_DECOMP => "auto",            -- String
        READ_DATA_WIDTH_B => 32,         -- DECIMAL
        READ_LATENCY_B => 2,             -- DECIMAL
        READ_RESET_VALUE_B => "0",       -- String
        RST_MODE_A => "SYNC",            -- String
        RST_MODE_B => "SYNC",            -- String
        SIM_ASSERT_CHK => 0,             -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_EMBEDDED_CONSTRAINT => 0,    -- DECIMAL
        USE_MEM_INIT => 1,               -- DECIMAL
        USE_MEM_INIT_MMI => 0,           -- DECIMAL
        WAKEUP_TIME => "disable_sleep",  -- String
        WRITE_DATA_WIDTH_A => 32,        -- DECIMAL
        WRITE_MODE_B => "no_change",     -- String
        WRITE_PROTECT => 1               -- DECIMAL
    ) port map (
        dbiterrb => open,      -- 1-bit output: Status signal to indicate double bit error occurrence on the data output of port B
        doutb => SB_rd_data,   -- READ_DATA_WIDTH_B-bit output: Data output for port B read operations
        sbiterrb => open,      -- 1-bit output: Status signal to indicate single bit error occurrence on the data output of port B
        addra => cfg_wr_addr(11 downto 2), -- ADDR_WIDTH_A-bit input: Address for port A write operations
        addrb => SB_rd_addr,   -- ADDR_WIDTH_B-bit input: Address for port B read operations
        clka => i_axi_clk,     -- 1-bit input: Clock signal for port A. Also clocks port B when parameter CLOCKING_MODE is "common_clock"
        clkb => i_axi_clk,     -- 1-bit input: Clock signal for port B when parameter CLOCKING_MODE is "independent_clock"
        dina => cfg_word,      -- WRITE_DATA_WIDTH_A-bit input: Data input for port A write operations
        ena => '1',            -- 1-bit input: Memory enable signal for port A. Must be high on clock cycles when write operations are initiated
        enb => '1',            -- 1-bit input: Memory enable signal for port B. Must be high on clock cycles when read operations are initiated
        injectdbiterra => '0', -- 1-bit input: Controls double bit error injection on input data when ECC enabled
        injectsbiterra => '0', -- 1-bit input: Controls single bit error injection on input data when ECC enabled
        regceb => '1',         -- 1-bit input: Clock Enable for the last register stage on the output data path
        rstb => '0',           -- 1-bit input: Reset signal for the final port B output register stage
        sleep => '0',          -- 1-bit input: sleep signal to enable the dynamic power saving feature
        wea => cfg_word_wr_en  -- WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-bit input: Write enable vector for port A input data port dina
    );
    
    -------------------------------------------------------------
    -- Readout of subarray beam table 
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            if (readout_start = '1') then
                if (unsigned(total_subarray_beams) = 0) then
                    dout_SB_done <= '1';
                else
                    dout_SB_done <= '0';
                end if;
                cur_readout_SB <= (others => '0');
            else
                if (SB_rd_fsm_del3 = get_dout_rd4) then
                    -- use fsm_del3 so that dout_SB_done will only be set after dout_SB_valid.
                    cur_readout_SB <= std_logic_vector(unsigned(cur_readout_SB) + 1);
                end if;
                if (unsigned(cur_readout_SB) = unsigned(total_subarray_beams)) then
                    dout_SB_done <= '1';
                else
                    dout_SB_done <= '0';
                end if;
            end if;
            
            -- capture the config request, and hold it until it is processed
            if dout_SB_req = '1' then
                dout_SB_req_d0 <= '1';
            elsif (SB_rd_fsm = get_dout_rd1) then
                dout_SB_req_d0 <= '0';
            end if;

            -- This fsm handles reading from the subarray-beam table
            -- The output modules ask for the next subarray beam, and after the data has been read here it is placed in registers for the output module to use.
            case SB_rd_fsm is
                when idle =>
                    SB_rd_fsm_dbg <= "0000";
                    if dout_SB_req_d0 = '1' then
                        SB_rd_fsm <= get_dout_rd1;
                    end if;
                
                when get_dout_rd1 =>
                    SB_rd_fsm_dbg <= "0110";
                    SB_rd_addr(9) <= readout_tableSelect;
                    SB_rd_addr(8 downto 2) <= cur_readout_SB;
                    SB_rd_addr(1 downto 0) <= "00";
                    SB_rd_fsm <= get_dout_rd2;
            
                when get_dout_rd2 =>
                    SB_rd_fsm_dbg <= "0111";
                    SB_rd_addr(1 downto 0) <= "01";
                    SB_rd_fsm <= get_dout_rd3;
                
                when get_dout_rd3 =>
                    SB_rd_fsm_dbg <= "1000";
                    SB_rd_addr(1 downto 0) <= "10";
                    SB_rd_fsm <= get_dout_rd4;
                
                when get_dout_rd4 =>
                    SB_rd_fsm_dbg <= "1001";
                    SB_rd_addr(1 downto 0) <= "11";
                    SB_rd_fsm <= idle;
                
                when others =>
                    SB_rd_fsm_dbg <= "1111";
                    SB_rd_fsm <= idle;
            
            end case;
            
            -- del1 : SB_rd_addr is valid
            SB_rd_fsm_del1 <= SB_rd_fsm;
            
            SB_rd_fsm_del2 <= SB_rd_fsm_del1;
            
            -- del3  : SB_rd_data is valid
            SB_rd_fsm_del3 <= SB_rd_fsm_del2;
            
            -- Assign din and dout data read from the subarray-beam table
            if (SB_rd_fsm_del3 = get_dout_rd1) then
                dout_SB_stations      <= SB_rd_data(15 downto 0);
                dout_SB_coarseStart   <= '0' & SB_rd_data(30 downto 16);
                dout_SB_outputDisable <= SB_rd_data(31);
            end if;
            if (SB_rd_fsm_del3 = get_dout_rd2) then
                dout_SB_fineStart <= SB_rd_data(15 downto 0);
            end if;
            if (SB_rd_fsm_del3 = get_dout_rd3) then
                dout_SB_n_fine           <= SB_rd_data(23 downto 0);
                dout_SB_fineIntegrations <= SB_rd_data(30 downto 24);
                dout_SB_timeIntegrations <= SB_rd_data(31);
            end if;
            
            if (SB_rd_fsm_del3 = get_dout_rd4) then
                dout_SB_HBM_base_addr <= SB_rd_data(31 downto 1) & '0';
                dout_SB_bad_poly      <= SB_rd_data(0);
                dout_SB_valid         <= '1';
            else
                dout_SB_valid <= '0';
            end if;
            
            axi_rst_del1 <= i_axi_rst;
            axi_rst_del2 <= axi_rst_del1;
            
        end if;
    end process;
    
    -------------------------------------------------------------
    -- Readout corner turn 2 data from the HBM
    cori : entity ct_lib.corr_ct2_dout_v80
    port map (
        -- Only uses the 300 MHz clock.
        i_axi_clk    => i_axi_clk,           -- in std_logic;
        i_start      => readout_start,       -- in std_logic; Start reading out data to the correlators
        i_buffer     => readout_buffer,      -- in std_logic; -- which of the double buffers to read out ?
        i_frameCount => readout_frameCount, -- in (31:0); -- 849ms frame since epoch.
        -- Data path reset
        i_rst       => axi_rst_del2,        --  in std_logic;
        -- Data from the subarray beam table. After o_SB_req goes high, i_SB_valid will be driven high with requested data from the table on the other busses.
        o_SB_req    => dout_SB_req,     -- Rising edge gets the parameters for the next subarray-beam to read out.
        o_SB_buffer => open,            -- out std_logic; Which of the two HBM buffers are we reading from (was used for selecting bad poly memory read address in previous versions, now unused)
        i_SB        => cur_readout_SB,  -- in (6:0); which subarray-beam are we currently processing from the subarray-beam table.
        i_SB_valid  => dout_SB_valid,   -- subarray-beam data below is valid; goes low when o_get_subarray_beam goes high, then goes high again once the parameters are valid.
        i_SB_done   => dout_SB_done,    -- Indicates that all the subarray beams for this correlator core has been processed.
        i_stations  => dout_SB_stations,                -- in (15:0); The number of (sub)stations in this subarray-beam
        i_coarseStart => dout_SB_coarseStart,           -- in (15:0); The first coarse channel in this subarray-beam
        i_outputDisable => dout_SB_outputDisable,       -- in std_logic;
        i_fineStart => dout_SB_fineStart,               -- in (15:0); The first fine channel in this subarray-beam
        i_n_fine => dout_SB_n_fine,                     -- in (23:0); The number of fine channels in this subarray-beam
        i_fineIntegrations => dout_SB_fineIntegrations, -- in (6:0);  Number of fine channels to integrate
        i_timeIntegrations => dout_SB_timeIntegrations, -- in std_logic;  Number of time samples per integration.
        i_HBM_base_addr    => dout_SB_HBM_base_addr,    -- in (31:0)  Base address in HBM for this subarray-beam.
        i_bad_poly => dout_SB_bad_poly,                 -- in std_logic;
        ---------------------------------------------------------------
        -- Data out to the correlator array
        --
        -- correlator 0 is ready to receive a new block of data. This will go low once data starts to be received.
        -- A block of data consists of data for 64 times, and up to 512 virtual channels.
        i_cor_ready   => cor_ready, -- in std_logic;  
        -- Each 256 bit word : two time samples, 4 consecutive virtual channels
        -- (31:0) = time 0, virtual channel 0; (63:32) = time 0, virtual channel 1; (95:64) = time 0, virtual channel 2; (127:96) = time 0, virtual channel 3;
        -- (159:128) = time 1, virtual channel 0; (191:160) = time 1, virtual channel 1; (223:192) = time 1, virtual channel 2; (255:224) = time 1, virtual channel 3;
        o_cor_data    => cor_data, --  out (255:0); 
        -- meta data
        o_cor_time    => cor_time,       -- out (7:0); Time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
        o_cor_station => cor_station, -- out (11:0); First of the 4 virtual channels in o_cor0_data
        o_cor_valid   => cor_valid,     -- out std_logic;
        o_cor_frameCount => cor_frameCount, -- out (31:0)
        o_cor_last       => cor_last,      -- out std_logic; Last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
        o_cor_final      => cor_final,     -- out std_logic; Indicates that at the completion of processing the last block of correlator data, the integration is complete.
        o_cor_tileType   => cor_tileType, -- out std_logic;
        o_cor_first      => cor_first,    -- out std_logic;  -- This is the first block of data for an integration - i.e. first fine channel, first block of 64 time samples, for this tile
        o_cor_tile_location     => cor_tileLocation, -- out (9:0);
        o_cor_tileChannel       => cor_tileChannel,    -- out (23:0);
        o_cor_tileTotalTimes    => cor_tileTotalTimes, -- out (7:0);  Number of time samples to integrate for this tile.
        o_cor_tiletotalChannels => cor_tileTotalChannels, -- out (6:0); Number of frequency channels to integrate for this tile.
        o_cor_rowstations       => cor_rowStations, -- out (8:0); Number of stations in the row memories to process; up to 256.
        o_cor_colstations       => cor_colStations, -- out (8:0); Number of stations in the col memories to process; up to 256.
        o_cor_subarray_beam     => cor_subarrayBeam, -- out (7:0); Which entry is this in the subarray-beam table ? 
        o_cor_totalStations     => cor_totalStations, -- out (15:0); Total number of stations being processing for this subarray-beam.
        o_cor_badPoly           => cor_badPoly,       -- out std_logic; No valid polynomial for some of the data in the subarray-beam
        ----------------------------------------------------------------
        -- read interfaces for the HBM
        o_HBM_axi_ar      => o_HBM_axi_ar,        -- out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_arready => i_HBM_axi_arready, -- in  std_logic;
        i_HBM_axi_r       => i_HBM_axi_r,       -- in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_rready  => o_HBM_axi_rready,    -- out std_logic
        ----------------------------------------------------------------
        -- debug info, could be connected to an ILA
        o_ar_fsm_dbg      => dout_ar_fsm_dbg,        -- out (3:0);
        o_readout_fsm_dbg => dout_readout_fsm_dbg,   -- out (3:0);
        o_arFIFO_wr_count => dout_arFIFO_wr_count,   -- out (6:0);
        o_dataFIFO_wrCount => dout_dataFIFO_wrCount, -- out (9:0);
        o_readout_error       => dout_readout_error,    -- out std_logic;
        o_recent_start_gap    => dout_recent_start_gap,    -- out (31:0);
        o_recent_readout_time => dout_recent_readout_time, -- out (31:0);
        o_min_start_gap       => dout_min_start_gap        -- out (31:0)
    );
    
    -- Correlator instance
    icor1 : entity correlator_lib.single_correlator_v80
    generic map (
        g_PIPELINE_STAGES => 2, -- integer
        g_CORRELATOR_INSTANCE  => g_CORRELATOR_INSTANCE  -- integer; unique ID for this correlator instance
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
        o_cor_ready => cor_ready, -- out std_logic;  
        -- Each 256 bit word : two time samples, 4 consecutive virtual channels
        -- (31:0) = time 0, virtual channel 0; (63:32) = time 0, virtual channel 1; (95:64) = time 0, virtual channel 2; (127:96) = time 0, virtual channel 3;
        -- (159:128) = time 1, virtual channel 0; (191:160) = time 1, virtual channel 1; (223:192) = time 1, virtual channel 2; (255:224) = time 1, virtual channel 3;
        i_cor_data  => cor_data, --  in (255:0); 
        -- Counts the virtual channels in i_cor_data, always in steps of 4, where the value is the first of the 4 virtual channels in i_cor_data
        -- If i_cor_tileType = '0', then up to 256 channels are delivered, with the same channels going to both row and column memories.
        --                          In this case, i_cor_VC_count will run from 0 to 256 in steps of 4.
        -- If i_cor_tileType = '1', then up to 512 channels are delivered, with different channels going to the row and column memories.
        --                          counts 0 to 255 go to the column memories, while counts 256-511 go to the row memories. 
        i_cor_station => cor_station,  -- in (8:0); first of the 4 virtual channels in i_cor0_data
        i_cor_time    => cor_time,     -- in (7:0); time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
        -- Options for tileType : 
        --   '0' = Triangle. In this case, all the input data goes to both the row and column memories, and a triangle from the correlation matrix is computed.
        --            For correlation cells on the diagonal, only non-duplicate entries are sent out.
        --   '1' = Rectangle. In this case, the first 256 virtual channels on i_cor0_data go to the column memories, while the next 128 virtual channels go to the row memories.
        --            All correlation products for the rectangle are then computed.
        i_cor_tileType => cor_tileType, --  in std_logic;
        i_cor_valid    => cor_valid,    --  in std_logic; i_cor0_data, i_cor0_time, i_cor0_VC, i_cor0_FC and i_cor0_tileType are valid when i_cor0_valid = '1'
        -- i_cor0_last and i_cor0_final go high after a block of data has been sent.
        i_cor_first    => cor_first,    -- in std_logic; This is the first block of data for an integration - i.e. first fine channel, first block of 64 time samples, for this tile
        i_cor_last     => cor_last,     -- in std_logic; Last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
        i_cor_final    => cor_final,    -- in std_logic; Indicates that at the completion of processing the most recent block of correlator data, the integration is complete. i_cor0_tileCount and i_cor0_tileChannel are valid when this is high.   
        -- TileLocation bits 3:0 = tile column, bits 7:4 = tile row. Each tile is 256x256 stations.
        -- Tiles can be triangles or squares from the full correlation.
        -- e.g. for 512x512 stations, there will be 4 tiles, consisting of 2 triangles and 1 square.
        --      for 4096x4096 stations, there will be 16 triangles, and 120 squares.
        i_cor_tileLocation => cor_tileLocation, -- in (9:0); bits 3:0 = tile column, bits 7:4 = tile row, bits 9:8 = "00";
        i_cor_frameCount   => cor_frameCount,   -- in (31:0);
        -- Which block of frequency channels is this tile for ?
        -- This sets the offset within the HBM that the result is written to, relative to the base address which is extracted from registers based on i_cor0_tileCount.
        i_cor_tileChannel       => cor_tileChannel, --  in (23:0);
        i_cor_tileTotalTimes    => cor_tileTotalTimes,    -- in (7:0) Number of time samples to integrate for this tile.
        i_cor_tiletotalChannels => cor_tileTotalChannels, -- in (6:0) Number of frequency channels to integrate for this tile.
        i_cor_rowstations       => cor_rowStations,       -- in (8:0) Number of stations in the row memories to process; up to 256.
        i_cor_colstations       => cor_colStations,       -- in (8:0) Number of stations in the col memories to process; up to 256.
        i_cor_totalStations     => cor_totalStations,     -- in (15:0); Total number of stations being processing for this subarray-beam.
        i_cor_subarrayBeam      => cor_subarrayBeam,      -- in (7:0);  Which entry is this in the subarray-beam table ?
        i_cor_badPoly           => cor_badPoly,           -- in std_logic;
        i_cor_tableSelect       => cor_tableSelect,       -- in std_logic;
        ---------------------------------------------------------------
        -- Data out to the HBM
        o_HBM_axi_aw      => o_HBM_axi_aw,      -- out t_axi4_full_addr; write address bus (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_awready => i_HBM_axi_awready, -- in  std_logic;
        o_HBM_axi_w       => o_HBM_axi_w,       -- out t_axi4_full_data; w data bus (.valid, .data(511:0), .last, .resp(1:0))
        i_HBM_axi_wready  => i_HBM_axi_wready,  -- in  std_logic;
        i_HBM_axi_b       => i_HBM_axi_b,       -- in  t_axi4_full_b; write response bus (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        ---------------------------------------------------------------
        -- Readout bus tells the packetiser what to do
        o_ro_data  => o_ro_data,  -- out (127:0);
        o_ro_valid => o_ro_valid, -- out std_logic;
        i_ro_stall => i_ro_stall, -- in std_logic;
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
        o_tb_channel   => o_tb_channel,  -- out (23:0) -- first fine channel index for this correlation.
        --
        o_freq_index0_repeat => o_freq_index0_repeat -- out std_logic
    );
    
--    ----------------------------------------------------------------
--    -- Registers
--    --


--    -- ARGS Gaskets for V80
--    i_cor_noc : entity noc_lib.args_noc
--    generic map (
--        G_DEBUG => FALSE
--    ) port map ( 
--        i_clk       => i_axi_clk,
--        i_rst       => i_axi_rst,
    
--        noc_wren    => noc_wren,
--        noc_rden    => noc_rden,
--        noc_wr_adr  => noc_wr_adr,
--        noc_wr_dat  => noc_wr_dat,
--        noc_rd_adr  => noc_rd_adr,
--        noc_rd_dat  => noc_rd_dat_mux
--    );

--    i_cor_args : entity correlator_lib.cor_config_versal
--    port map (
--        MM_CLK          => i_axi_clk,  -- in std_logic;
--        MM_RST          => i_axi_rst,  -- in std_logic;
        
--        noc_wren        => noc_wren,
--        noc_rden        => noc_rden,
--        noc_wr_adr      => noc_wr_adr,
--        noc_wr_dat      => noc_wr_dat,
--        noc_rd_adr      => noc_rd_adr,
--        noc_rd_dat      => noc_rd_dat_mux,
        
--        SETUP_FIELDS_RW => config_rw,  -- out t_setup_rw;
--        SETUP_FIELDS_RO => config_ro   -- in  t_setup_ro
--    );
    
--END GENERATE;
    
--    config_ro.cor0_HBM_start <= cor0_HBM_curr_rd_base; --(others => '0'); -- TODO - should come from the SPEAD packet readout module
--    config_ro.cor0_HBM_end <= cor0_HBM_end;
--    config_ro.cor0_HBM_size <= (others => '0'); -- TODO - calculate from cor0_HBM_end and cor0_HBM_start
    
--    config_ro.cor1_HBM_start <= cor1_HBM_curr_rd_base; --(others => '0'); -- TODO - should come from the SPEAD packet readout module
--    config_ro.cor1_HBM_end <= cor1_HBM_end;
--    config_ro.cor1_HBM_size <= (others => '0'); -- TODO - calculate from cor0_HBM_end and cor0_HBM_start
    
--    dummy <= config_rw.full_reset;
    
end Behavioral;
