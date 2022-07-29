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
--   - Get data for all 1024 ports for 64 time samples.
--      - i.e. all the data for 1 fine channel for about 1/3 of a second (= minimum integration time).
--      - Each sample is 16 bits, so the memory required for this is
--        (1024 ports) * (64 times) * (2 bytes) = 128 kBytes
--      - The actual memory required is 4x this : 
--         - x2 for double buffering, so data can be loaded as it is being used.
--         - x2 since data is stored in row and column memories to feed to the matrix correlator.
--      - So there is 256 kBytes in the row memories (and column memories)
--         - 256 kBytes = 64 BRAMs  (So total memory in row + col rams is 128 BRAMs)
--         - Split into 16 pieces = 4 BRAMs per piece
--            - Each row or column memory is (32 bits wide) x (4096 deep)
--                - 32 bits wide = sufficient for dual pol complex 8+8 bit samples.
--                - 4096 deep = (2 double buffered) * (32 stations) * (64 times)
--      - Loading data :
--         - For the full correlation, Number of clocks to use the data in the memory is :
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
--      - Convert to floating point, so 8 bytes per sample, so data rate out is 16*8 = 128 bytes per clock @ 412.5 MHz = 422 Gbit/sec.
--      - Accumulate more time or fine channels in an ultraRAM buffer
--      
--    - ultraRAM accumulation buffer :
--      - Holds 1/3 of a full correlation
--      - (1/3) * (1024*1025/2) = 174934 correlation products, each of which is 8 bytes (4+4 complex, single precision floating point)
--      - 174934 * (8 bytes) = 1399472 bytes = 43 ultraRAMs.
--      - Accumulation buffer is double buffered, so it can be dumped to HBM while new data is coming in,
--      - So it need 86 ultraRAMs.
--      - Needs to be split into 16 pieces, so we can process 16 samples at a time from the CMAC array
--      - So it is made up of 16 memories, each 6 ultraRAMs in size
--      - i.e. 16 memories, each 6*4096 = 24576 deep x 8 bytes wide.
--        16x6 = 96 ultraRAMs used.
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
--   * 32x32 correlator array
--   * input data propagates down and to the right
--   * 64 time samples accumulated within the array
--   * Once every 64 clocks, accumulated values from within the array are read out.
--   * Accumulated values within the array propagate up and, in the top row, to the left.
--   * 16 accumulated values are read out every clock. These are 24-bit re + 24 bit imaginary samples.
--   * 24-bit integers are converted to single-precision floats
---  * Floats are accumulated with data from the internal accumulation memory
--      - Allows integration across multiple blocks of 64 time samples, and multiple fine channels.
--   * Completed integration is written to the HBM, while ultraRAM buffer is switched to other buffer so accumulation can continue for the next group of fine channels.
--
--
--  HBM      or internal accumulator --+---------------------------+----------------> To HBM (if last fine channel) or internal accumulator
-- (i_HBMData)    (8 ultraRAMs)   accumulate                   accumulate              (o_HBMData)                     (8 ultraRAMs)
--                                    /\                          /\
--                                    |                           |  
--                              int40->float                 int40->float 
--                                    /\                          /\
--                 col_bram0          |          col_bram1        |        col_bram2                        col_bram7
--   data in --->  ports 0,8,16...    |      --> ports 1,9,17,... |    --> ports 2,10,18...     --> ... --> ports 7,15,23...
--             |          |           |                |          |             |
--            \/         \/           |               \/          |            \/
--        row_bram0 --> mult(0,0),accumulate --> mult(0,1)-accumulate --> mult(0,2)-accumulate --> ... --> mult(0,7)-accumulate    [Accumulation result shifts
--   ports 0,8,16...      |       32 times          |       32 times         |                              |                       left in steps of 2 in this (the top)  
--             |          |          /\             |           /\           |                              |                       row, so all products come out
--            \/         \/          |             \/           |           \/                             \/                       in pairs of sample to the int40->float
--        row_bram1 --> mult(1,0),accumulate --> mult(1,1)-accumulate --> mult(1,2)            --> ... --> mult(1,7)-accumulate     conversion]
--    ports 1,9,17...     |        32 times                 32 times  
--             |          |          /\                        /\
--            \/         \/          |                         |
--        row_bram2 --> mult(1,1)-accumulate --> ...
--    ports 2,10,18                 32 times
--            |                      /\
--           ...                     |
--
--
--   
--
----------------------------------------------------------------------------------
library IEEE, correlator_lib, common_lib, xpm;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
library DSP_top_lib;
USE correlator_lib.cor_config_reg_pkg.ALL;
USE common_lib.common_pkg.ALL;
use xpm.vcomponents.all;

Library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;

entity correlator_top is
    generic (
        g_SOME_GENERIC : integer := 1
    );
    port (
        -- Output from the registers that are defined elsewhere (on i_axi_clk)
        i_totalStations : in std_logic_vector(11 downto 0);
        i_totalCoarse   : in std_logic_vector(11 downto 0);
        i_totalChannels : in std_logic_vector(11 downto 0);
        -- Registers AXI Lite Interface (uses i_axi_clk)
        i_axi_mosi : in t_axi4_lite_mosi;
        o_axi_miso : out t_axi4_lite_miso;
        i_axi_clk  : in std_logic;
        i_axi_rst  : in std_logic;
        ------------------------------------------------------------------
        -- Input data
        i_din       : in std_logic_vector(511 downto 0); -- full width bus from the corner turn HBM readout.
        i_din_valid : in std_logic;
        -- clock used for the correlator
        i_din_clk   : in std_logic;
        ------------------------------------------------------------------
        -- Data output to the packetiser
        o_100GE_data : out std_logic_vector(127 downto 0);
        o_100GE_valid : out std_logic;
        ------------------------------------------------------------------
        -- AXI interface to the HBM for storage of visibilities
        -- aw bus = write address
        o_m03_axi_aw      : out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m03_axi_awready : in  std_logic;
        o_m03_axi_w       : out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_m03_axi_wready  : in  std_logic;
        i_m03_axi_b       : in  t_axi4_full_b;    -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        o_m03_axi_ar      : out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m03_axi_arready : in  std_logic;
        i_m03_axi_r       : in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_m03_axi_rready  : out std_logic
    );
end correlator_top;

architecture Behavioral of correlator_top is
    
    signal config_rw : t_setup_rw;
    signal config_ro : t_setup_ro;
    
--    signal totalJimbles_BFclk : std_logic_Vector(5 downto 0);
--    signal totalCoarse_BFclk : std_logic_vector(3 downto 0);
--    signal jimblesCoarse_axiClk : std_logic_vector(9 downto 0);
--    signal jimblesCoarse_BFclk : std_logic_vector(9 downto 0);
    
--    signal axi2BFclk_dest_out : std_logic_vector(193 downto 0);
--    signal config_axiClk : std_logic_vector(113 downto 0);
--    signal calPorts : t_slv_8_arr(3 downto 0);
--    signal calFineChannelsToIntegrate : std_logic_vector(7 downto 0);
--    signal calIntegrationPeriod : std_logic_vector(31 downto 0);
--    signal calFrameStart : std_logic_vector(39 downto 0);
--    signal calCorrelatorEnabled, runCalCorrelatorDel, runCalCorrelator, startCalCorrelator : std_logic;
--    signal firstCoarse, firstFine, firstPort, firstTimeGroup, calStartPacketCount : std_logic;
--    signal calDinFIFO_dout : std_logic_vector(511 downto 0);
    
--    signal calDinFIFO_empty, calDinFIFO_full, calDinFIFO_rst : std_logic;
--    signal calDinFIFO_RdEn, calDinFIFO_WrEn : std_logic;
    
--    signal calDoutFIFO_WrEn : std_logic;
--    signal calDoutFIFO_wdata, calDoutFIFO_dout : std_logic_vector(511 downto 0);
--    signal calDoutFIFO_empty, calDoutFIFO_full : std_logic;
    
--    signal calConfig_axiclk : std_logic_vector(193 downto 0);
--    signal fullConfig_axiclk : std_logic_vector(17 downto 0);
--    signal sendCount : std_logic_vector(5 downto 0) := "000000";
--    signal axi2clk400_dest_out : std_logic_vector(17 downto 0);
--    signal axi2clk400_dest_req : std_logic;
--    signal totalJimbles_clk400 : std_logic_vector(5 downto 0);
--    signal totalCoarse_clk400 : std_logic_vector(3 downto 0);
--    signal fullFineChannelsToIntegrate : std_logic_vector(7 downto 0);
--    signal fullIntegrationPeriod_BFclk : std_logic_vector(31 downto 0);
--    signal fullIntegrationPeriod_clk400 : std_logic_vector(31 downto 0);
--    signal fullFrameStart : std_logic_vector(39 downto 0);
--    signal startFullCorrelator, runFullCorrelator, runFullCorrelatorDel, fullCorrelatorEnabled, fullStartPacketCount : std_logic;
    
--    signal full_dataRe, full_dataIm : std_logic_vector(15 downto 0);
--    signal full_coarse : std_logic_vector(3 downto 0);
--    signal full_fine : std_logic_vector(6 downto 0);
--    signal full_port : std_logic_vector(7 downto 0);
--    signal full_lastPort, full_firstPort : std_logic;
--    signal full_timeGroup : std_logic_vector(5 downto 0);
--    signal full_valid : std_logic;

--    signal full_dataReDel1, full_dataImDel1 : std_logic_vector(15 downto 0);
--    signal full_coarseDel1 : std_logic_vector(3 downto 0);
--    signal full_fineDel1 : std_logic_vector(6 downto 0);
--    signal full_portDel1 : std_logic_vector(7 downto 0);
--    signal full_lastPortDel1, full_firstPortDel1 : std_logic;
--    signal full_timeGroupDel1 : std_logic_vector(5 downto 0);
--    signal full_validDel1 : std_logic;
    
--    signal fullDoutFIFO_WrEn : std_logic;
--    signal fullDoutFIFO_wdata : std_logic_vector(511 downto 0);
    
--    signal awFIFO_rst : std_logic;
--    signal awFIFO_wrEn : stD_logic;
--    signal awFIFO_wdata : std_logic_vector(7 downto 0);
--    signal aw_writefUll : std_logic := '0';
--    signal awFIFO_wrDataCount : std_logic_vector(5 downto 0);
--    signal awFIFO_full : std_logic;
--    signal awFIFO_RdEn : std_logic;
--    signal awFIFO_dout : std_logic_Vector(7 downto 0);
--    signal awFIFO_rdDataCount : std_logic_vector(5 downto 0);
--    signal awFIFO_empty : std_logic;
    
--    signal fullDoutFIFO_RdEn, calDoutFIFO_RdEn, wdata_sel : std_logic := '0';
--    signal wCount : std_logic_vector(5 downto 0);
--    type wdata_fsm_type is (idle, readdata);
--    signal wdata_fsm : wdata_fsm_type := idle;
--    signal fullDoutFIFO_dout : std_logic_Vector(511 downto 0);
--    signal fullDoutFIFO_rdDataCount, calDoutFIFO_rdDataCount : std_logic_vector(9 downto 0);
--    signal fullDoutFIFO_empty : std_logic;
--    type aw_fsm_type is (idle, idle_running, wait_aw_ready, wait_awFIFO_ready, wait_all_writes_done, trigger_ar_fsm);
--    signal aw_fsm : aw_fsm_type := idle;
--    signal m0_axi_awvalid_int, m0_axi_awvalidDel : std_logic := '0';
--    signal fullStartupBuffer : std_logic_vector(1 downto 0);
--    signal fullTimeSamplesMinus1 : std_logic_vector(31 downto 0);
--    signal fullSingleCTonly, calSingleCTonly : std_logic := '0';
--    signal calFinished, fullFinished : std_logic := '0';
--    signal fullWrBuffer : std_logic_vector(1 downto 0);
--    signal calWrBuffer : std_logic_vector(4 downto 0);
--    signal fullWrAddr : std_logic_vector(14 downto 0);
--    signal calWrAddr : std_logic_vector(11 downto 0);
--    signal calBufferSize : std_logic_vector(17 downto 0);
--    signal fullBufferSize : std_logic_vector(20 downto 0);
--    signal axi2clk400_src_send, axi2BFclk_src_send, axi2clk400_src_rcv, axi2BFclk_src_rcv, axi2BFclk_dest_req : std_logic := '0';
--    signal full_lastHBMWrite, cal_lastHBMWrite : std_logic;
--    signal fullDinFIFO_RdEn : std_logic;
--    signal fullDinFIFO_dout : std_logic_vector(127 downto 0);
--    signal fullLastHBMWriteOccurred : std_logic;
--    signal calLastHBMWriteOccurred : std_logic := '0';
--    signal cal_lastHBMWrite_axi_clk, full_lastHBMWrite_axi_clk : std_logic;
--    signal calDoutFIFO_rst, fullDoutFIFO_rst : std_logic := '0';
--    signal fullDinFIFO_rst : std_logic;
--    signal fullDoutFIFO_full_axi_clk_hold, fullDoutFIFO_full_axi_clk, fullDoutFIFO_full : std_logic := '0';
--    signal calDoutFIFO_full_axi_clk, calDoutFIFO_full_axi_clk_hold : std_logic := '0';
--    signal fullDinUnderflow_axi_clk, fullDinUnderflow_axi_clk_hold, calDinUnderflow_axi_clk, calDinUnderflow_axi_clk_hold : std_logic := '0';
--    signal calDinUnderflow, fullDinUnderflow, fullDinFIFO_empty : std_logic := '0';
--    signal fatal_write_done_before_read_done : std_logic := '0';
    
--    signal calWordsToRead, calWordsToRead_minus1, calWordsToRead_minus64 : std_logic_vector(17 downto 0);
--    signal fullWordsToRead, fullWordsToRead_minus1, fullWordsToRead_minus64 : std_logic_vector(20 downto 0);
--    signal calRdAddr : std_logic_vector(28 downto 0);
--    signal fullRdAddr : std_logic_vector(28 downto 0);
--    type ar_fsm_type is (idle, start_wait, check_cal, wait_cal, check_full, wait_full, check_done, wait_readsPending);
--    signal ar_fsm, ar_fsmDel : ar_fsm_type := idle;
--    signal arFIFO_WrEn : std_logic := '0';
--    signal arFIFO_wdata : std_logic_vector(7 downto 0) := x"00";
--    signal calDinFIFO_wrDataCount, fullDinFIFO_wrDataCount, calDinReadsPending, fullDinReadsPending, calDinUsedOrPending, fullDinUsedOrPending : std_logic_vector(9 downto 0) := "0000000000";
--    signal arFIFO_rst, arFIFO_full : std_logic := '0';
--    signal arFIFO_dout : std_logic_vector(7 downto 0);
--    signal fullDinFIFO_WrEn : std_logic := '0';
--    signal arFIFO_RdEn, arFIFO_underflow_hold : std_logic := '0';
--    signal fullDinFIFO_full : std_logic;
--    signal arFIFO_empty : std_logic;
--    signal calDinFIFO_wrEnDel : std_logic;
--    signal arlen_ext : std_logic_vector(9 downto 0);
--    signal fullDinFIFO_wrEnDel : std_logic;
--    signal startFullCorrelator_axi_clk : std_logic;
--    signal startCalCorrelator_axi_clk : std_logic;
    
--    function get_full_samples_per_CT return integer is
--    begin
--        if g_CT1_N27BLOCKS_PER_FRAME = 24 then
--            return 32;
--        elsif g_CT1_N27BLOCKS_PER_FRAME = 2 then
--            return 2;
--        else
--            assert FALSE report "Bad corner turn length" severity failure;
--            return 32;
--        end if;
--    end get_full_samples_per_CT;
    
--    function get_cal_samples_per_CT return integer is
--    begin
--        if g_CT1_N27BLOCKS_PER_FRAME = 24 then
--            return 384;  -- 64 time groups, 6 time samples per group = 384 per corner turn.
--        elsif g_CT1_N27BLOCKS_PER_FRAME = 2 then
--            return 32;  -- 32 time samples per corner turn
--        else
--            assert FALSE report "Bad corner turn length" severity failure;
--            return 384;
--        end if;
--    end get_cal_samples_per_CT;
    
--    constant g_FULL_TIMESAMPLES_PER_CT : integer := get_full_samples_per_CT;
--    constant g_CAL_TIMESAMPLES_PER_CT : integer := get_cal_samples_per_CT;
--    signal fullTimeSamplesRemaining, calTimeSamplesRemaining : std_logic_vector(31 downto 0) := (others => '0');
--    signal full_flushHBM_axi_clk, full_flushHBM : std_logic := '0';
--    signal cal_running, full_running : std_logic := '0';
--    signal running_BF_clk : std_logic_vector(1 downto 0);
--    signal running_axi_clk : std_logic_vector(1 downto 0);
--    signal wdataTotalReads, awFIFO_dout_len_ext, pendingCalHBMwrites, pendingFullHBMwrites, awlen_plus1  : std_logic_vector(9 downto 0) := "0000000000";
--    signal wdataCalReadDone, wdataFullReadDone : std_logic;
--    signal wrFullWordsRemaining, wrCalWordsRemaining : std_logic_vector(11 downto 0);
--    signal fullDoutFIFO_RdEnDel1, calDoutFIFO_RdEnDel1 : std_logic;
    
begin
    o_m03_axi_aw.addr <= (others => '0');
    o_m03_axi_aw.valid <= '0';
    o_m03_axi_aw.len <= (others => '0');
    o_m03_axi_w.data <= (others => '0');
    o_m03_axi_w.valid <= '0';
    o_m03_axi_w.last <= '0';
    o_m03_axi_w.resp <= "00";
    o_m03_axi_ar.addr <= (others => '0');
    o_m03_axi_ar.valid <= '0';
    o_m03_axi_ar.len <= (others => '0');
    o_m03_axi_rready <= '1';
    
--    fci : entity correlator_lib.full_correlator
--    generic map (
--        g_CT1_N27BLOCKS_PER_FRAME => g_CT1_N27BLOCKS_PER_FRAME -- Number nominal value is 24, corresponding to 24 * 27 = 648 CODIF packets = 21 ms corner turn 
--    ) port map (
--        -- Parameters, must be in the i_clk400 domain.
--        i_totalJimbles => totalJimbles_clk400(4 downto 0), -- in(4:0); -- total jimbles in use
--        -- Number of fine channels to integrate. Valid options are submultiples of 108, the number of fine channels per coarse channel.
--        --  108 = 27*4, so valid options are 1, 2, 3, 4, 6, 9, 12, 18, 27, 36, 54, 108
--        i_fineChannelsToIntegrate => fullFineChannelsToIntegrate(6 downto 0), -- in std_logic_vector(6 downto 0);
--        ----------------------------------------------
--        -- Start integration. Signal in the i_BF_clk domain.
--        -- This should be asserted for 1 clock, prior to the first burst from the first fine channel in a corner turn.
--        i_start => startFullCorrelator, -- in std_logic;
--        i_totalCoarse => totalCoarse_BFclk, -- in std_logic_vector(3 downto 0);  -- Number of coarse channels in use, in the i_BF_clk domain.
--        i_integrationPeriod => fullIntegrationPeriod_BFclk, -- in std_logic_vector(31 downto 0);  -- Number of time samples to integrate.
--        o_running => full_running, -- : out std_logic;  -- indicates the correlator is running.
--        ------------------------------------------------------------------
--        -- 14.8 kHz input data
--        -- ! i_dataRe, i_dataIm is aligned with the meta data, i_fine, i_port etc.
--        -- ! This is different to the input to the beamformers, which get the meta data 12 clocks early.
--        i_BF_clk      => i_BF_clk,    -- in std_logic;
--        i_dataRe      => full_dataReDel1, -- in(15:0)  -- 1 time sample per clock.
--        i_dataIm      => full_dataImDel1, -- in(15:0)
--        i_valid       => full_validDel1,  -- in std_logic;
--        i_coarse      => full_coarseDel1, -- in std_logic_vector(3 downto 0);
--        i_fine        => full_fineDel1,   -- in std_logic_vector(6 downto  0); -- fine runs from 0:107
--        i_port        => full_portDel1,   -- in std_logic_vector(7 downto 0);  -- up to 224 ports
--        i_firstPort   => full_firstPortDel1, -- in std_logic; -- First port (used to trigger a new accumulator cycle in the beamformers).
--        i_timeGroup   => full_timeGroupDel1, -- in std_logic_vector(5 downto 0); -- Sampled when i_firstPort is asserted. Counts through 64 timegroups. Each timegroup is 6 time samples.
--        i_lastPort    => full_lastPortDel1, --  in std_logic;
        
--        -- 400 MHz Processing clock 
--        i_clk400  => i_clk400, --  in std_logic;
--        -- Interface to the HBM
--        -- State machine in the level above this gets the data from the HBM and returns it to the HBM
--        -- The interface at this level is FIFO-like; just read and write.
--        -- This module assumes that HBM data will be available to read when it is needed,
--        -- since the data input from the corner turn cannot be stalled.
--        --
--        -- Read from HBM : Data is read in the same cycle as o_rdHBM = '1' (i.e. fwft FIFO required)
--        o_rdHBM => fullDinFIFO_RdEn,   -- out std_logic;
--        i_HBMdata => fullDinFIFO_dout, -- in std_logic_vector(127 downto 0);
--        o_flushHBM => full_flushHBM,   -- out std_logic; -- HBM reads are 512 bit words, but it is possible that a full set of integration data is not a multiple of 512 bits. This signal indicates that the last part of the last 512 bits should be dropped.
--        -- Write to HBM : o_HBMdata is valid when o_wrHBM = '1'.
--        o_wrHBM => fullDoutFIFO_WrEn,        -- out std_logic;
--        o_lastHBMWrite => full_lastHBMWrite, -- out std_logic;  -- last word of HBM data for the corner turn.
--        o_HBMdata => fullDoutFIFO_wdata      -- out std_logic_vector(511 downto 0)
--    );

    ----------------------------------------------------------------
    -- Registers
    --
    
    i_correlator_reg : entity correlator_lib.cor_config_reg
    port map (
        MM_CLK          => i_axi_clk,  -- in std_logic;
        MM_RST          => i_axi_rst,  -- in std_logic;
        SLA_IN          => i_axi_mosi, -- in t_axi4_lite_mosi;
        SLA_OUT         => o_axi_miso, -- out t_axi4_lite_miso;
        SETUP_FIELDS_RW => config_rw,  -- out t_setup_rw;
        SETUP_FIELDS_RO => config_ro   -- in  t_setup_ro
    );
    
    config_ro.dummy <= x"FABBFEAD";
   
    
end Behavioral;
