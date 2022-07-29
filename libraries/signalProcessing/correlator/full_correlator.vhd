----------------------------------------------------------------------------------
-- Company: CSIRO 
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 06/18/2021 11:40:30 AM
-- Module Name: correlator - Behavioral
-- Description: 
--  Full correlator. Processes every 12th sample.
--
-- Input data order for each corner turn frame:
--
--   For fine_channel = 0:(i_totalCoarse * 108 - 1)
--      For time_group = 0:63                    (for standard length corner turn; each time_Group is 6 time samples
--         For port = 0:(i_totalJimbles*8 - 1)
--            -6 time samples per clock.
--            
-- For this correlator, data is cut down to every 12th sample, so we get:
--
--   For fine_channel = 0:(i_totalCoarse * 108 - 1)
--      For time_group = 0:2:63                  (Data delivered every second timeGroup)
--         For port = 0:(i_totalJimbles*8 - 1)
--            -1 time sample
--
-- Structure:
--  mult-accumulate is done using an 8x8 matrix correlator.
--
--  Flow :
--    - Get data for all ports for 32 time samples.
--      - i.e. all the data for 1 fine channel.
--        This takes (64 time groups) * (224 ports + 1 unused clock) = 14400 clocks.
--        Data is stored in 8 BRAMs 
--          - Each BRAM has data for 224/8 = 28 ports, and 32 times (one sample every second time group),
--            double buffered, so 28*32 * 2 => 2048 deep, 32 bits wide.
--    - Process this data (32 time samples, all ports, 1 fine channel) :
--      - The 8x8 matrix correlator processes 8x8 squares of the ACM at a time.
--      - 224 ports = 28*8 ports, so there are 28*29/2 = 406 8x8 ACM squares to process.
--      - Each 8x8 ACM square takes 32 clocks, since there are 32 time samples to process. 
--         - So we need 406*32 = 12992 clocks to process the full frame.
--           Can use a 400 MHz clock for the ACM :
--             Time to process = 12992 * 2.5ns = 32.48 us,
--             Time for data to come in = 14400 * (1/435) = 33.1 us
--      - Use 40 bit accumulator (40 bit real + 40 bit imaginary):
--          16 bit x 16 bit = 32 bit, accumulate 32 times -> 37 bits.
--    - 32 clocks to get the data out of the correlator array.
--      - 64 elements in the array, so read two samples per clock.
--      - If not accumulating across fine channels:
--        - Then add to data from HBM and write back to HBM 
--          2 samples * (2 complex) * (4 bytes) in 2.5 ns (400 MHz clock) = 16 bytes/2.5ns = 51.2 Gbit/sec
--      - OR, accumulate multiple fine channels using block ram:
--        - 8 bytes per ACM element (4 byte real + 4 byte imaginary)
--        - Total ACM elements = 224*225/2 = 25200
--        - Read 2 elements per clock, so need a memory which is : (16 bytes wide) x (12600 deep)
--            = 8 ultraRAMs (=16 bytes wide x 16384 deep).
--
-- STRUCTURE:
--   * 8x8 correlator array
--   * input data propagates down and to the right
--   * 32 time samples accumulated within the array
--   * Once every 32 clocks, accumulated values from within the array are read out.
--   * Accumulated values within the array propagate up and, in the top row, to the left.
--   * Two accumulated values are read out every clock. These are 40-bit re + 40 bit imaginary samples.
--   * 40-bit integers are converted to single-precision floats
---  * Floats are accumulated with data from the HBM (if this is the first in a group of fine channels to be accumulated),
--     or with data from the internal accumulation memory
--   * Result is written to either the HBM or the internal accumulation memory.
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
----------------------------------------------------------------------------------
library IEEE, correlator_lib, common_lib, xpm;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
library DSP_top_lib;
USE correlator_lib.correlator_reg_pkg.ALL;
USE common_lib.common_pkg.ALL;
use xpm.vcomponents.all;

Library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;

entity full_correlator is
    generic (
        --
        g_CT1_N27BLOCKS_PER_FRAME : integer := 24 -- Number nominal value is 24, corresponding to 24 * 27 = 648 CODIF packets = 21 ms corner turn 
    );
    port (
        -- Parameters, must be in the i_clk400 domain.
        i_totalJimbles : in std_logic_vector(4 downto 0); -- total jimbles in use
       
        -- Number of fine channels to integrate. Valid options are submultiples of 108, the number of fine channels per coarse channel.
        --  108 = 27*4, so valid options are 1, 2, 3, 4, 6, 9, 12, 18, 27, 36, 54, 108
        i_fineChannelsToIntegrate : in std_logic_vector(6 downto 0);
        ----------------------------------------------
        -- Start integration. Signal in the i_BF_clk domain.
        -- This should be asserted for 1 clock, during the first burst from the first fine channel in a corner turn.
        i_start : in std_logic;
        i_totalCoarse : in std_logic_vector(3 downto 0);  -- Number of coarse channels in use, in the i_BF_clk domain.
        i_integrationPeriod : in std_logic_vector(31 downto 0);  -- Number of time samples to integrate.
        o_running : out std_logic;  -- indicates the correlator is running.
        ------------------------------------------------------------------
        -- 14.8 kHz input data
        -- ! i_dataRe, i_dataIm is aligned with the meta data, i_fine, i_port etc.
        -- ! This is different to the input to the beamformers, which get the meta data 12 clocks early.
        i_BF_clk      : in std_logic;
        i_dataRe      : in std_logic_vector(15 downto 0);  -- 1 time sample delivered every second clock.
        i_dataIm      : in std_logic_vector(15 downto 0);
        i_valid       : in std_logic;  -- Only send every second packet from the corner turn.
        i_coarse      : in std_logic_vector(3 downto 0);
        i_fine        : in std_logic_vector(6 downto  0); -- fine runs from 0:107
        i_port        : in std_logic_vector(7 downto 0);  -- up to 224 ports
        i_firstPort   : in std_logic; -- First port (used to trigger a new accumulator cycle in the beamformers).
        i_timeGroup   : in std_logic_vector(5 downto 0); -- Sampled when i_firstPort is asserted. Counts through 64 timegroups. Each timegroup is 6 time samples.
        i_lastPort    : in std_logic;
        -- 400 MHz Processing clock 
        i_clk400 : in std_logic;
        -- Interface to the HBM
        -- State machine in the level above this gets the data from the HBM and returns it to the HBM
        -- The interface at this level is FIFO-like; just read and write.
        -- This module assumes that HBM data will be available to read when it is needed,
        -- since the data input from the corner turn cannot be stalled.
        --
        -- Read from HBM : Data is read in the same cycle as o_rdHBM = '1' (i.e. fwft FIFO required)
        o_rdHBM : out std_logic;
        i_HBMdata : in std_logic_vector(127 downto 0);
        o_flushHBM : out std_logic; -- HBM reads are 512 bit words, but it is possible that a full set of integration data is not a multiple of 512 bits. This signal indicates that the last part of the last 512 bits should be dropped.
        -- Write to HBM : o_HBMdata is valid when o_wrHBM = '1'.
        o_wrHBM : out std_logic;
        o_lastHBMWrite : out std_logic;  -- last word of HBM data for the corner turn, valid when o_wrHBM = '1'
        o_HBMdata : out std_logic_vector(511 downto 0)
    );
end full_correlator;

architecture Behavioral of full_correlator is
    
    -- 16 x 16 bit complex multiplier
    -- create_ip -name cmpy -vendor xilinx.com -library ip -version 6.0 -module_name cmult16x16
    -- set_property -dict [list CONFIG.Component_Name {cmult16x16} CONFIG.OptimizeGoal {Performance} CONFIG.MinimumLatency {4}] [get_ips cmult16x16]
    component cmult16x16
    port (
        aclk : IN STD_LOGIC;
        s_axis_a_tvalid : IN STD_LOGIC;
        s_axis_a_tdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);  -- re and im in (15:0) and (31:16) respectively.
        s_axis_b_tvalid : IN STD_LOGIC;
        s_axis_b_tdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);  -- re and im in (15:0) and (31:16) respectively.
        m_axis_dout_tvalid : OUT STD_LOGIC;
        m_axis_dout_tdata : OUT STD_LOGIC_VECTOR(79 DOWNTO 0)); -- 4 cycle latency, result is real in (32:0), imaginary in (72:40).
    end component;
    
    component int40_to_float
    port (
        aclk : IN STD_LOGIC;
        s_axis_a_tvalid : IN STD_LOGIC;
        s_axis_a_tdata : IN STD_LOGIC_VECTOR(39 DOWNTO 0);
        m_axis_result_tvalid : OUT STD_LOGIC;
        m_axis_result_tdata : OUT STD_LOGIC_VECTOR(31 DOWNTO 0));
    end component;
    
    component fp_add
    port (
        aclk : IN STD_LOGIC;
        s_axis_a_tvalid : IN STD_LOGIC;
        s_axis_a_tdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
        s_axis_b_tvalid : IN STD_LOGIC;
        s_axis_b_tdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
        m_axis_result_tvalid : OUT STD_LOGIC;
        m_axis_result_tdata : OUT STD_LOGIC_VECTOR(31 DOWNTO 0));
    end component;
    
    type correlator_fsm_type is ( wait_start, run, done);
    signal correlator_fsm : correlator_fsm_type := done;
    
    signal lastPortDel1, lastPortDel2 : std_logic;
    type multReIm_out_type is array(3 downto 0) of t_slv_36_arr(5 downto 0);
    -- Number of groups of 6 times from the beamformer. Nominal value is 63 (for g_CT1_N27BLOCKS_PER_FRAME = 24)
    -- +5 is to calculate the ceiling in the division function.
    constant c_MAXTIMEGROUP : integer := (g_CT1_N27BLOCKS_PER_FRAME * 16 + 5)/6 - 1;
    constant c_MAXTIMEGROUP_DIV2 : integer :=  ((g_CT1_N27BLOCKS_PER_FRAME * 16 + 5)/6 - 1) / 2;
    constant c_WAIT32_TIME : integer := 32 - c_MAXTIMEGROUP_DIV2;
    constant c_TIMES_PER_CORNERTURN : integer := g_CT1_N27BLOCKS_PER_FRAME * 16;
    signal portDel1, portDel2 : std_logic_vector(7 downto 0);
    signal integrationPeriod : std_logic_vector(31 downto 0);
    signal totalCoarseMinus1 : std_logic_vector(3 downto 0);
    
    signal colwrDataDel : t_slv_32_arr(7 downto 0);
    signal colWrAddrDel : t_slv_11_arr(7 downto 0);
    signal colRdAddrDel : t_slv_11_arr(7 downto 0);
    signal colRdAddr : std_logic_vector(10 downto 0);
    signal colWrEn : t_slv_1_arr(7 downto 0);
    signal colPortDel : t_slv_3_arr(7 downto 0);
    signal colValidDel : std_logic_vector(7 downto 0);
    attribute dont_touch : string;
    attribute dont_touch of colWrDataDel : signal is "true";
    attribute dont_touch of colWrAddrDel : signal is "true";
    attribute dont_touch of colWrEn : signal is "true";
    attribute dont_touch of colPortDel : signal is "true";
    attribute dont_touch of colValidDel : signal is "true";
    attribute dont_touch of colRdAddrDel : signal is "true";
    
    signal rowWrDataDel : t_slv_32_arr(7 downto 0);
    signal rowWrAddrDel : t_slv_11_arr(7 downto 0);
    signal rowRdAddrDel : t_slv_11_arr(7 downto 0);
    signal rowRdAddr : std_logic_vector(10 downto 0);
    signal rowWrEn : t_slv_1_arr(7 downto 0);
    signal rowPortDel : t_slv_3_arr(7 downto 0);
    signal rowValidDel : std_logic_vector(7 downto 0);
    attribute dont_touch of rowWrDataDel : signal is "true";
    attribute dont_touch of rowWrAddrDel : signal is "true";
    attribute dont_touch of rowWrEn : signal is "true";
    attribute dont_touch of rowPortDel : signal is "true";
    attribute dont_touch of rowValidDel : signal is "true";
    attribute dont_touch of rowRdAddrDel : signal is "true";
    
    type t_slv_8x8_arr32 is array(7 downto 0) of t_slv_32_arr(7 downto 0);
    signal colDoutDel : t_slv_8x8_arr32;
    signal rowDoutDel : t_slv_8x8_arr32;
    signal wrBuffer : std_logic := '0';
    signal rdBuffer : std_logic := '1';
    signal wrDone : std_logic;
    signal wrDone_clk400 : std_logic;
    signal dataIm_neg : std_logic_Vector(15 downto 0);
    
    type t_slv_8x8_arr80 is array(7 downto 0) of t_slv_80_arr(7 downto 0);
    signal multOut : t_slv_8x8_arr80;
    
    type t_slv_8x8_arr40 is array(7 downto 0) of t_slv_40_arr(7 downto 0);
    signal multOutRe, multOutIm : t_slv_8x8_arr40;
    --signal 
    signal BF_to_clk400_din : std_logic_vector(13 downto 0);
    signal firstFrameBFclk : std_logic := '0';
    signal BF_to_clk400_src_send : std_logic := '0';
    signal BF_to_clk400_src_rcv : std_logic;
    signal BF_to_clk400_dest_req : std_logic;
    signal BF_to_clk400_dest_out : std_logic_vector(13 downto 0);
    
    signal colRdBuffer, rowRdBuffer : std_logic;
    signal colRdTime, colRdJimble, rowRdTime, rowRdJimble : std_logic_vector(4 downto 0);
    signal rdBuffer_clk400 : std_logic := '0';
    signal totalJimblesMinus1 : std_logic_vector(4 downto 0);
    
    type read_fsm_type is (running, wait32, done);
    signal read_fsm : read_fsm_type := done;
    signal colRdJimble_eq_rowRdJimble : std_logic;
    signal colRdJimble_eq_totalJimblesMinus1 : std_logic;
    signal readRunningDel : std_logic_vector(31 downto 0);
    signal firstTimeDel : std_logic_vector(31 downto 0);
    signal lastTimeDel : std_logic_vector(15 downto 0);
    signal readRunningDel2D, firstTimeDel2D, lastTimeDel2D : t_slv_8_arr(7 downto 0);
    signal accumulatorRe, accumulatorReHold, accumulatorIm, accumulatorImHold, accumulatorReShift, accumulatorImShift : t_slv_8x8_arr40;
    
    attribute dont_touch of readRunningDel2D : signal is "true";
    attribute dont_touch of firstTimeDel2D : signal is "true";
    attribute dont_touch of lastTimeDel2D : signal is "true";
    
    signal wait32Count : std_logic_vector(4 downto 0) := "00000";
    
    signal loadShift : std_logic;
    signal loadShiftDel : std_logic_vector(7 downto 0);
    signal loadShiftCount : std_logic_vector(4 downto 0) := "00000";
    signal shiftRow : std_logic;
    signal shiftOutTwoSamples : std_logic;
    signal shiftRowDel : std_logic_vector(7 downto 0);
    signal shiftOutTwoSamplesDel : std_logic_vector(7 downto 0);
  
    --attribute dont_touch of loadShiftDel : signal is "true";
    attribute dont_touch of shiftRowDel : signal is "true";
    attribute dont_touch of shiftOutTwoSamplesDel : signal is "true";
    
    signal sampleReFloat : t_slv_32_arr(1 downto 0);
    signal sampleImFloat : t_slv_32_arr(1 downto 0);
    
    signal longTermAccumRe : t_slv_32_arr(1 downto 0);
    signal longTermAccumIm : t_slv_32_arr(1 downto 0);
    signal sampleReAccumulated, sampleImAccumulated : t_slv_32_arr(1 downto 0);
    
    signal freqAccumDout : std_logic_vector(127 downto 0);
    signal freqAccumWrAddr, freqAccumRdAddr : std_logic_vector(13 downto 0);
    signal freqAccumDin : std_logic_vector(127 downto 0);
    signal freqAccumWrEn : std_logic_vector(0 downto 0);
    
    signal wrHBM : std_logic := '0';
    signal HBMoutputReg : std_logic_vector(511 downto 0);
    signal HBMoutputRegUsed : std_logic_vector(1 downto 0);
    
    signal overflowOutUsed, freqAccumDinValid : std_logic := '0';
    signal overflowOut : std_logic_vector(63 downto 0);
    signal validSamples, validSamplesOutput : std_logic_vector(1 downto 0);
    signal validSamplesDelAdder : t_slv_2_arr(9 downto 0);
    
    signal first_8x8blockDel : std_logic_vector(23 downto 0);
    signal diagonalDel : std_logic_vector(23 downto 0);
    
    signal validDel : std_logic;
    signal coarseBFclk : std_logic_vector(3 downto 0);
    signal fineBFclk : std_logic_vector(6 downto 0);
    signal firstFrame, firstFrame_clk400 : std_logic;
    signal firstFrameDel : std_logic_vector(23 downto 0);
    --signal coarseChannelDel : t_slv_4_arr(23 downto 0);
    signal coarseChannel : std_logic_vector(3 downto 0);
    signal coarse_clk400 : std_logic_vector(3 downto 0);
    --signal fineChannelDel : t_slv_7_arr(23 downto 0);
    signal fineChannel : std_logic_vector(6 downto 0);
    signal fine_clk400 : std_logic_vector(6 downto 0);
    signal fineChannelsToIntegrate_minus1, fineChannelsToIntegrate_minus2, fineCount : std_logic_vector(6 downto 0);
    signal fineStart, fineEnd : std_logic;
    signal fineStartDel : std_logic_vector(23 downto 0);
    signal fineEndDel : std_logic_vector(23 downto 0);
    signal CT_frame_done : std_logic := '0';
    signal integrationStillRunning : std_logic := '0';
    signal samplesIntegrated, samplesIntegratedThisChannel : std_logic_vector(31 downto 0);
    signal dataImDel1, dataImDel2 : std_logic_vector(15 downto 0);
    signal dataReDel1, dataReDel2 : std_logic_vector(15 downto 0);
    signal integrationIncludesThisSample : std_logic;
    signal validDel1, validDel2 : std_logic;
    
    signal HBMrdEn, freqAccumRdEn, HBMrdEnDel1, freqAccumRdEnDel1, HBMrdEnDel2, freqAccumRdEnDel2, HBMrdEnDel3, freqAccumRdEnDel3, HBMrdEnDel4, freqAccumRdEnDel4 : std_logic;
    signal longTermDataIn : std_logic_vector(127 downto 0);
    signal longTermReadMappingDel6, longTermReadMappingDel5, longTermReadMappingDel4, longTermReadMappingDel3, longTermReadMappingDel2, longTermReadMappingDel1, longTermReadMapping : std_logic_vector(1 downto 0);
    signal overflowIn : std_logic_vector(63 downto 0);
    signal longTermRdEn : std_logic;
    signal currentReadCount : std_logic_vector(4 downto 0);
    signal readoutRunning, readoutRunningDel1 : std_logic := '0';
    signal currentRow : std_logic_vector(2 downto 0);
    signal currentRead : std_logic_vector(1 downto 0);
    signal arrayReadoutDiagonalDel1 : std_logic := '0';
    signal firstLongTermRd, firstLongTermRdDel1 : std_logic;
    signal arrayReadoutFineStartDel1, arrayReadoutFineStartDel2 : std_logic;
    signal arrayReadoutDiagonalDel2, arrayReadoutFirstCTDel1, arrayReadoutFirstCTDel2 : std_logic;
    signal validSamplesDel1, validSamplesDel2, validSamplesDel3, validSamplesDel4, validSamplesDel5, validSamplesDel6 : std_logic_vector(1 downto 0);
    signal arrayReadoutStart, arrayReadoutDiagonal, arrayReadoutFirst, arrayReadoutFirstCT, arrayReadoutFineStart, arrayReadoutFineEnd : std_logic;
    signal arrayReadoutFirstDel1, arrayReadoutFirstDel2 : std_logic := '0';
    signal arrayReadoutFineEndAdder : std_logic_vector(10 downto 0);
    signal arrayReadoutFineEndDel1, arrayReadoutFineEndDel2, arrayReadoutFineEndDel3, arrayReadoutFineEndDel4, arrayReadoutFineEndDel5, arrayReadoutFineEndDel6, arrayReadoutFineEndDel7, arrayReadoutFineEndDel8, arrayReadoutFineEndDel9 : std_logic;
    signal startOfACM : std_logic;
    signal arrayReadoutFirstDel9, arrayReadoutFirstDel8, arrayReadoutFirstDel7, arrayReadoutFirstDel6, arrayReadoutFirstDel5, arrayReadoutFirstDel4, arrayReadoutFirstDel3 : std_logic;
    signal arrayReadoutFirstDel : std_logic_vector(10 downto 0);
    signal startOfCTDel : std_logic_vector(23 downto 0);
    signal arrayReadoutStartOfCTDel : std_logic_vector(9 downto 0);
    signal arrayReadoutStartOfCTDel9, arrayReadoutStartOfCTDel8, arrayReadoutStartOfCTDel7, arrayReadoutStartOfCTDel6, arrayReadoutStartOfCTDel5, arrayReadoutStartOfCTDel4, arrayReadoutStartOfCTDel3, arrayReadoutStartOfCTDel2, arrayReadoutStartOfCTDel1 : std_logic;
    signal arrayReadoutStartOfCT : std_logic;
    
    signal lastLongTermRdDel5, lastLongTermRdDel4, lastLongTermRdDel3, lastLongTermRdDel2, lastLongTermRdDel1, lastLongTermRd : std_logic := '0';
    signal arrayReadoutLastDel1 : std_logic := '0';
    signal CTFrameDone_clk400 : std_logic;
    signal arrayReadoutLast : std_logic;
    signal CTFrameDoneDel, last_8x8blockDel : std_logic_vector(23 downto 0);
    signal lastHBMWrite : std_logic;
    signal lastLongTermRdDel : std_logic_vector(10 downto 0);
    signal lastLongTermRdDel7, lastLongTermRdDel6 : std_logic;
    signal read_fsm_eq_done_BF_clk, read_fsm_eq_done : std_logic;
    signal running_int : std_logic := '0';
    signal timeGroupDel1, timeGroupDel2 : std_logic_vector(5 downto 0);
    signal startDel1 : std_logic := '0';
    signal coarseDel1 : std_logic_vector(3 downto 0);
    signal coarseDel2_eq_totalCoarseMinus1 : std_logic;
    signal fineDel1 : std_logic_vector(6 downto 0);
    signal fineDel2_eq_107 : std_logic;
    signal CTFrameDone : std_logic := '0';
    
begin
    
    dataIm_neg <= std_logic_vector(-signed(dataImDel2));
    o_running <= running_int;
    process(i_BF_clk)
    begin
        if rising_edge(i_BF_clk) then
            
            -- Input address, data and write enable for the memories.
            colWrDataDel(0) <= dataIm_neg & dataReDel2;  -- complex conjugate of the input for the column data
            colWrDataDel(7 downto 1) <= colWrDataDel(6 downto 0);
            -- Address : low 5 bits for the time sample, high 5 bits for the port, top bit for the buffer.
            colWrAddrDel(0)(4 downto 0) <= timeGroupDel2(5 downto 1);  -- i_valid will only be high for every second timeGroup.
            colWrAddrDel(0)(9 downto 5) <= portDel2(7 downto 3);
            colWrAddrDel(0)(10) <= wrBuffer;
            colWrAddrDel(7 downto 1) <= colWrAddrDel(6 downto 0);
            
            colPortDel(7 downto 1) <= colPortDel(6 downto 0);  -- low 3 bits of the port, used to determine which memories to write to.
            colValidDel(7 downto 1) <= colValidDel(6 downto 0);
            for i in 0 to 7 loop
                if (colValidDel(i) = '1' and unsigned(colPortDel(i)) = i) then
                    colWrEn(i)(0) <= '1';
                else
                    colWrEn(i)(0) <= '0';
                end if;
            end loop;
            dataReDel1 <= i_dataRe;
            dataReDel2 <= dataReDel1;
            dataImDel1 <= i_dataIm;
            dataImDel2 <= dataImDel1;
            portDel1 <= i_port;
            portDel2 <= portDel1;
            validDel1 <= i_valid;
            validDel2 <= validDel1;
            timeGroupDel1 <= i_timeGroup;
            timeGroupDel2 <= timeGroupDel1;
            lastPortDel1 <= i_lastPort;
            lastPortDel2 <= lastPortDel1;
            if integrationIncludesThisSample = '1' then
                rowWrDataDel(0) <= dataImDel2 & dataReDel2;  -- 2 cycle latency on the data since there is a two cycle latency to calculate "integrationIncludesThisSample"
            else
                rowWrDataDel(0) <= (others => '0');
            end if;
            rowWrDataDel(7 downto 1) <= rowWrDataDel(6 downto 0);
            
            rowWrAddrDel(0)(4 downto 0) <= timeGroupDel2(5 downto 1);
            rowWrAddrDel(0)(9 downto 5) <= portDel2(7 downto 3);
            rowWrAddrDel(0)(10) <= wrBuffer;
            rowWrAddrDel(7 downto 1) <= rowWrAddrDel(6 downto 0);
            
            rowPortDel(7 downto 1) <= rowPortDel(6 downto 0);
            rowValidDel(7 downto 1) <= rowValidDel(6 downto 0);
            for i in 0 to 7 loop
                if (rowValidDel(i) = '1' and unsigned(rowPortDel(i)) = i) then
                    rowWrEn(i)(0) <= '1';
                else
                    rowWrEn(i)(0) <= '0';
                end if;
            end loop;
            
            -- On the last write to the input memories, swap wrBuffer, and notify the readout side (which is in the i_clk400 domain).
            if i_start = '1' then
                firstFrameBFclk <= '1';
            elsif (CT_frame_done = '1') then
                firstFrameBFclk <= '0';
            end if;
            
            if i_start = '1' then
                samplesIntegrated <= (others => '0');  -- number of samples that have been integrated at the start of the corner turn.
            elsif (CT_frame_done = '1') then
                if integrationStillRunning = '1' then
                    samplesIntegrated <= std_logic_vector(unsigned(samplesIntegrated) + c_MAXTIMEGROUP_DIV2 + 1);
                end if;
            end if;
            startDel1 <= i_start;
            if i_start = '1' or startDel1 = '1' then
                running_int <= '1';
            elsif integrationStillRunning = '0' and read_fsm_eq_done_BF_clk = '1' then
                running_int <= '0';
            end if;
            
            samplesIntegratedThisChannel <= std_logic_vector(unsigned(samplesIntegrated) + unsigned(i_timeGroup(5 downto 1)));
            
            if (unsigned(samplesIntegratedThisChannel) < unsigned(i_integrationPeriod)) then
                integrationIncludesThisSample <= '1';
            else
                integrationIncludesThisSample <= '0';
            end if;
            
            if (unsigned(samplesIntegrated) < unsigned(i_integrationPeriod)) then
                integrationStillRunning <= '1';
            else
                integrationStillRunning <= '0';
            end if;
            
            validDel <= i_valid;
            if i_valid = '1' and validDel = '0' then
                coarseBFclk <= i_coarse;
                fineBFclk <= i_fine;
            end if;
            
            if validDel2 = '1' and unsigned(timeGroupDel2(5 downto 1)) = c_MAXTIMEGROUP_DIV2 and lastPortDel2 = '1' and integrationStillRunning = '1' then
                wrDone <= '1';
                rdBuffer <= wrBuffer;
                wrBuffer <= not wrBuffer;
            else
                wrDone <= '0';
            end if;
            
            totalCoarseMinus1 <= std_logic_vector(unsigned(i_totalCoarse) - 1);
            coarseDel1 <= i_coarse;
            if (coarseDel1 = totalCoarseMinus1) then
                coarseDel2_eq_totalCoarseMinus1 <= '1';
            else
                coarseDel2_eq_totalCoarseMinus1 <= '0';
            end if;
            fineDel1 <= i_fine;
            if (unsigned(fineDel1) = 107) then
                fineDel2_eq_107 <= '1';
            else
                fineDel2_eq_107 <= '0';
            end if;
            if (validDel2 = '1' and unsigned(timeGroupDel2(5 downto 1)) = c_MAXTIMEGROUP_DIV2 and lastPortDel2 = '1' and (coarseDel2_eq_totalCoarseMinus1 = '1') and (fineDel2_eq_107 = '1')) then
                CT_frame_done <= '1';
            else
                CT_frame_done <= '0';
            end if;
            
        end if;
    end process;

    colPortDel(0) <= portDel2(2 downto 0);
    colValidDel(0) <= validDel2;
    rowPortDel(0) <= portDel2(2 downto 0);
    rowValidDel(0) <= validDel2;
    
    col_ram_gen : for row_col_ram in 0 to 7 generate
        
        -- Each memory catches data for every 8th port, and 32 time samples, double buffered.
        col_bram_inst : xpm_memory_sdpram
        generic map (
            ADDR_WIDTH_A => 11,              -- DECIMAL
            ADDR_WIDTH_B => 11,              -- DECIMAL
            AUTO_SLEEP_TIME => 0,            -- DECIMAL
            BYTE_WRITE_WIDTH_A => 32,        -- DECIMAL
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
            WRITE_DATA_WIDTH_A => 32,       -- DECIMAL
            WRITE_MODE_B => "read_first"     -- String
        ) port map (
            dbiterrb => open,                   -- 1-bit output: Status signal to indicate double bit error occurrence on the data output of port A.
            doutb => colDoutDel(0)(row_col_ram),      -- READ_DATA_WIDTH_B-bit output: Data output for port B read operations.
            sbiterrb => open,                   -- 1-bit output: Status signal to indicate single bit error occurrence on the data output of port B.
            addra => colWrAddrDel(row_col_ram), -- ADDR_WIDTH_A-bit input: Address for port A write and read operations.
            addrb => colRdAddrDel(row_col_ram), -- ADDR_WIDTH_B-bit input: Address for port B write and read operations.
            clka => i_BF_clk,                   -- 1-bit input: Clock signal for port A. Also clocks port B when parameter CLOCKING_MODE is "common_clock".
            clkb => i_clk400,                   -- Unused when parameter CLOCKING_MODE is "common_clock".
            dina => colWrDatadel(row_col_ram),  -- WRITE_DATA_WIDTH_A-bit input: Data input for port A write operations.
            ena => '1',                 -- 1-bit input: Memory enable signal for port A.
            enb => '1',                 -- 1-bit input: Memory enable signal for port B.
            injectdbiterra => '0',      -- 1-bit input: Controls double bit error injection on input data
            injectsbiterra => '0',      -- 1-bit input: Controls single bit error injection on input data
            regceb => '1',              -- 1-bit input: Clock Enable for the last register stage on the output data path.
            rstb => '0',                -- 1-bit input: Reset signal for the final port B output register
            sleep => '0',               -- 1-bit input: sleep signal to enable the dynamic power saving feature.
            wea => colWrEn(row_col_ram) -- WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-bit input: Write enable vector for port A input data port dina. 
        );

        -- Each memory catches data for every 8th port, and 32 time samples, double buffered.
        row_bram_inst : xpm_memory_sdpram
        generic map (
            ADDR_WIDTH_A => 11,              -- DECIMAL
            ADDR_WIDTH_B => 11,              -- DECIMAL
            AUTO_SLEEP_TIME => 0,            -- DECIMAL
            BYTE_WRITE_WIDTH_A => 32,        -- DECIMAL
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
            WRITE_DATA_WIDTH_A => 32,       -- DECIMAL
            WRITE_MODE_B => "read_first"     -- String
        ) port map (
            dbiterrb => open,                   -- 1-bit output: Status signal to indicate double bit error occurrence on the data output of port A.
            doutb => rowDoutDel(0)(row_col_ram),      -- READ_DATA_WIDTH_B-bit output: Data output for port B read operations.
            sbiterrb => open,                   -- 1-bit output: Status signal to indicate single bit error occurrence on the data output of port B.
            addra => rowWrAddrDel(row_col_ram), -- ADDR_WIDTH_A-bit input: Address for port A write and read operations.
            addrb => rowRdAddrDel(row_col_ram), -- ADDR_WIDTH_B-bit input: Address for port B write and read operations.
            clka => i_BF_clk,                   -- 1-bit input: Clock signal for port A. Also clocks port B when parameter CLOCKING_MODE is "common_clock".
            clkb => i_clk400,                   -- Unused when parameter CLOCKING_MODE is "common_clock".
            dina => rowWrDatadel(row_col_ram),  -- WRITE_DATA_WIDTH_A-bit input: Data input for port A write operations.
            ena => '1',                 -- 1-bit input: Memory enable signal for port A.
            enb => '1',                 -- 1-bit input: Memory enable signal for port B.
            injectdbiterra => '0',      -- 1-bit input: Controls double bit error injection on input data
            injectsbiterra => '0',      -- 1-bit input: Controls single bit error injection on input data
            regceb => '1',              -- 1-bit input: Clock Enable for the last register stage on the output data path.
            rstb => '0',                -- 1-bit input: Reset signal for the final port B output register
            sleep => '0',               -- 1-bit input: sleep signal to enable the dynamic power saving feature.
            wea => rowWrEn(row_col_ram) -- WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-bit input: Write enable vector for port A input data port dina. 
        );
    
    end generate;
    
    -- get read fsm state back to the i_BF_clk domain
    xpm_cdc_single_inst : xpm_cdc_single
    generic map (
        DEST_SYNC_FF => 10,   -- DECIMAL; range: 2-10; Use a long delay to avoid setting o_running to '0' at the start of the last frame.
        INIT_SYNC_FF => 1,   -- DECIMAL; 0=disable simulation init values, 1=enable simulation init values
        SIM_ASSERT_CHK => 0, -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        SRC_INPUT_REG => 1   -- DECIMAL; 0=do not register input, 1=register input
    ) port map (
        dest_out => read_fsm_eq_done_BF_clk, -- 1-bit output: src_in synchronized to the destination clock domain. This output is registered.
        dest_clk => i_BF_clk, -- 1-bit input: Clock signal for the destination clock domain.
        src_clk => i_clk400,  -- 1-bit input: optional; required when SRC_INPUT_REG = 1
        src_in => read_fsm_eq_done -- 1-bit input: Input signal to be synchronized to dest_clk domain.
    );
    
    -- Get wrDone and the buffer into the i_clk400 domain.
    process(i_BF_clk)
    begin
        if rising_edge(i_BF_clk) then
            if wrDone = '1' then
                BF_to_clk400_din(0) <= rdBuffer;
                BF_to_clk400_din(1) <= firstFrameBFclk;
                BF_to_clk400_din(5 downto 2) <= coarseBFclk;
                BF_to_clk400_din(12 downto 6) <= fineBFclk;
                BF_to_clk400_din(13) <= CT_Frame_Done;
                BF_to_clk400_src_send <= '1';
            elsif BF_to_clk400_src_rcv = '1' then
                BF_to_clk400_src_send <= '0';
            end if;
        end if;
    end process;
    
    
    xpm_cdc_handshake_inst : xpm_cdc_handshake
    generic map (
        DEST_EXT_HSK => 0,   -- DECIMAL; 0=internal handshake, 1=external handshake
        DEST_SYNC_FF => 3,   -- DECIMAL; range: 2-10
        INIT_SYNC_FF => 1,   -- DECIMAL; 0=disable simulation init values, 1=enable simulation init values
        SIM_ASSERT_CHK => 0, -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        SRC_SYNC_FF => 4,    -- DECIMAL; range: 2-10
        WIDTH => 14           -- DECIMAL; range: 1-1024
    )
    port map (
        dest_out => BF_to_clk400_dest_out, -- WIDTH-bit output: Input bus (src_in) synchronized to destination clock domain.
        dest_req => BF_to_clk400_dest_req, -- 1-bit output: Assertion of this signal indicates that new dest_out data has been received and is ready to be used or captured by the destination logic. 
        src_rcv => BF_to_clk400_src_rcv,   -- 1-bit output: Acknowledgement from destination logic that src_in has been received. 
        dest_ack => '1', -- 1-bit input: optional; required when DEST_EXT_HSK = 1
        dest_clk => i_clk400, -- 1-bit input: Destination clock.
        src_clk => i_BF_clk,  -- 1-bit input: Source clock.
        src_in => BF_to_clk400_din,     -- WIDTH-bit input: Input bus that will be synchronized to the destination clock domain.
        src_send => BF_to_clk400_src_send  -- 1-bit input: Send to destination clock domain. Only assert when src_rcv = '0', only deassert when src_rcv = '1'
    );
    
    
    process(i_clk400)
    begin
        if rising_Edge(i_clk400) then
        
            if BF_to_clk400_dest_req = '1' then
                -- Process the frame...
                -- BF_to_clk400_dest_req pulses once per fine channel,
                -- to indicate that row_bram and col_bram contain all data for the corner turn frame for one fine channel. 
                rdBuffer_clk400 <= BF_to_clk400_dest_out(0);
                firstFrame_clk400 <= BF_to_clk400_dest_out(1);  -- Indicates that this is the first corner turn frame in the integration period.
                coarse_clk400 <= BF_to_clk400_dest_out(5 downto 2);
                fine_clk400 <= BF_to_clk400_dest_out(12 downto 6);
                CTFrameDone_clk400 <= BF_to_clk400_dest_out(13);
                wrDone_clk400 <= '1';
            else
                wrDone_clk400 <= '0';
            end if;
            
            fineChannelsToIntegrate_minus1 <= std_logic_vector(unsigned(i_fineChannelsToIntegrate) - 1);
            fineChannelsToIntegrate_minus2 <= std_logic_vector(unsigned(i_fineChannelsToIntegrate) - 2);
            -- fsm to manage readout of row_bram and col_bram, to process the full ACM
            --    - Note : row_bram & col_bram contain all the data required for the full ACM for 1 fine channel. 
            -- Read pattern 0 each line below is 32 clocks to read 32 time samples. 
            --  row 0, col 0  --- First row of the ACM, single 8x8 block calculated.
            --  row 1, col 0  \
            --  row 1, col 1  /-- Second row of the ACM, 2 8x8 blocks calculated.  
            --  row 2, col 0  \
            --  row 2, col 1   +- Third row of the ACM, 3 8x8 blocks calculated. 
            --  row 2, col 2  /
            --   etc..
            --   up to row and column (i_totalJimbles - 1)  (since each jimble contributes 8 ports).
            if wrDone_clk400 = '1' then
                colRdBuffer <= rdBuffer_clk400;
                colRdTime <= "00000";
                colRdJimble <= "00000";
                rowRdBuffer <= rdBuffer_clk400;
                rowRdTime <= "00000";
                rowRdJimble <= "00000";
                read_fsm <= running;
                firstFrame <= firstFrame_clk400;
                coarseChannel <= coarse_clk400;
                fineChannel <= fine_clk400;
                if (unsigned(fine_clk400) = 0) then
                    fineCount <= (others => '0');
                    fineStart <= '1';  -- first fine channel in a block of fine channels to integrate
                    if (unsigned(fineChannelsToIntegrate_minus1) = 0) then
                        fineEnd <= '1'; -- last fine channel in a block of fine channels to integrate
                    else
                        fineEnd <= '0';
                    end if;
                else
                    if (fineCount = fineChannelsToIntegrate_minus1) then
                        fineCount <= (others => '0');
                        fineStart <= '1';
                        if (unsigned(fineChannelsToIntegrate_minus1) = 0) then
                            fineEnd <= '1';
                        else
                            fineEnd <= '0';
                        end if;
                    else
                        fineCount <= std_logic_vector(unsigned(fineCount) + 1);
                        fineStart <= '0';
                        if (fineCount = fineChannelsToIntegrate_minus2) then
                            fineEnd <= '1';
                        else
                            fineEnd <= '0';
                        end if; 
                    end if; 
                end if;
                if CTFrameDone_clk400 = '1' then
                    CTFrameDone <= '1';
                else
                    CTFrameDone <= '0';
                end if;
            else
                case read_fsm is
                    when running =>
                        if (unsigned(rowRdTime) = c_MAXTIMEGROUP_DIV2) then
                            rowRdTime <= "00000";
                            colRdTime <= "00000";
                            if (c_MAXTIMEGROUP_DIV2 < 31) then
                                read_fsm <= wait32;
                                wait32Count <= std_logic_vector(to_unsigned(c_WAIT32_TIME,5));
                            elsif (colRdJimble_eq_rowRdJimble = '1') then -- end of this row of 8x8 blocks, go to the next row
                                colRdJimble <= "00000";
                                rowRdJimble <= std_logic_vector(unsigned(rowRdJimble) + 1);
                                if (colRdJimble_eq_totalJimblesMinus1 = '1') then -- end of the ACM
                                    read_fsm <= done;
                                end if;
                            else
                                colRdJimble <= std_logic_vector(unsigned(colRdJimble) + 1);
                            end if;
                        else
                            rowRdTime <= std_logic_vector(unsigned(rowRdTime) + 1);
                            colRdTime <= std_logic_vector(unsigned(colRdTime) + 1);
                        end if;
                    
                    when wait32 => 
                        -- We can only initiate a new 8x8 block of correlations once every 32 clocks,
                        -- since we need 32 clocks to read the data out.
                        -- So if the number of times being integrated is less than 32, wait until 32 clocks elapse.
                        wait32Count <= std_logic_vector(unsigned(wait32Count) - 1);
                        if (unsigned(wait32Count) = 1) then
                            if (colRdJimble_eq_rowRdJimble = '1') then -- end of this row of 8x8 blocks, go to the next row
                                colRdJimble <= "00000";
                                rowRdJimble <= std_logic_vector(unsigned(rowRdJimble) + 1);
                                if (colRdJimble_eq_totalJimblesMinus1 = '1') then -- end of the ACM
                                    read_fsm <= done;
                                end if;
                            else
                                colRdJimble <= std_logic_vector(unsigned(colRdJimble) + 1);
                                read_fsm <= running;
                            end if;
                        end if; 
                    
                    when done =>
                        read_fsm <= done;
                end case;
            end if;
            
            if read_fsm = done then
                read_fsm_eq_done <= '1';
            else
                read_fsm_eq_done <= '0';
            end if;
            
            colRdAddrDel(0) <= colRdBuffer & colRdJimble & colRdTime;
            rowRdAddrDel(0) <= rowRdBuffer & rowRdJimble & rowRdTime;
            
            colRdAddrDel(7 downto 1) <= colRdAddrDel(6 downto 0);
            rowRdAddrDel(7 downto 1) <= rowRdAddrDel(6 downto 0);
            
            rowDoutDel(7 downto 1) <= rowDoutDel(6 downto 0);
            colDoutDel(7 downto 1) <= colDoutDel(6 downto 0);
            
            if read_fsm = running then
                readRunningDel(0) <= '1';
            else
                readRunningDel(0) <= '0';
            end if;
            
            if ((rowRdTime = "00000") and (read_fsm = running)) then
                firstTimeDel(0) <= '1';   -- First time sample to integrate in a corner turn (i.e. group of 32 time samples for the nominal 21 ms corner turn)
            else
                firstTimeDel(0) <= '0';
            end if;
            
            if ((unsigned(rowRdTime) = c_MAXTIMEGROUP_DIV2) and (read_fsm = running)) then
                lastTimeDel(0) <= '1';
            else
                lastTimeDel(0) <= '0';
            end if;
            
            -- colRdAddrDel(0), rowRdAddrDel(0) align with readRunningDel(0)
            -- Valid data from first col_bram aligns with readRunningDel(3)  (three cycle read latency on the memory)
            -- Valid data at the output of the multipliers in the array align with :
            --   readRunningDel(3 + col_mult + row_mult + 4)  - 4 cycle latency through the multiplier, plus pipeline latencies within the 8x8 array.
            readRunningDel(31 downto 1) <= readRunningDel(30 downto 0);
            firstTimeDel(31 downto 1) <= firstTimeDel(30 downto 0);
            lastTimeDel(15 downto 1) <= lastTimeDel(14 downto 0);
            diagonalDel(23 downto 1) <= diagonalDel(22 downto 0);
            first_8x8blockDel(23 downto 1) <= first_8x8blockDel(22 downto 0);
            firstFrameDel(0) <= firstFrame;
            firstFrameDel(23 downto 1) <= firstFrameDel(22 downto 0);
            
            CTFrameDoneDel(0) <= CTFrameDone; -- _clk400 and wrDone_clk400;
            CTFrameDoneDel(23 downto 1) <= CTFrameDoneDel(22 downto 0);
            last_8x8blockDel(23 downto 1) <= last_8x8blockDel(22 downto 0);
            
            if wrDone_clk400 = '1' and (unsigned(coarse_clk400) = 0) and (unsigned(fine_clk400) = 0) then
                startOfCTDel(0) <= '1';
            else
                startOfCTDel(0) <= '0';
            end if;
            startOfCTDel(23 downto 1) <= startOfCTDel(22 downto 0);
            fineStartDel(0) <= fineStart;
            fineStartDel(23 downto 1) <= fineStartDel(22 downto 0);
            
            fineEndDel(0) <= fineEnd;
            fineEndDel(23 downto 1) <= fineEndDel(22 downto 0);
            
            -- Pipelined operations for the fsm
            totalJimblesMinus1 <= std_logic_vector(unsigned(i_totalJimbles) - 1);
            if (colRdJimble = rowRdJimble) then
                colRdJimble_eq_rowRdJimble <= '1';
                diagonalDel(0) <= '1';
            else
                colRdJimble_eq_rowRdJimble <= '0';
                diagonalDel(0) <= '0';
            end if;
            
            if colRdJimble = "00000" and rowRdJimble = "00000" then
                first_8x8blockDel(0) <= '1';
            else
                first_8x8blockDel(0) <= '0';
            end if;
            
            if (colRdJimble = totalJimblesMinus1) then
                colRdJimble_eq_totalJimblesMinus1 <= '1';
            else
                colRdJimble_eq_totalJimblesMinus1 <= '0';
            end if;

            -- create 2-D arrays of control signals readRunning and firstTime, to prevent place and route trying to use one register to 
            -- drive every element on the diagonal of the 8x8 array.
            readRunningDel2D(0) <= readRunningDel(13 downto 6);  -- start at 6, so readRunningDel2D(0)(0) indicates valid output of the (0,0) multiplier
            readRunningDel2D(7 downto 1) <= readRunningDel2D(6 downto 0);

            firstTimeDel2D(0) <= firstTimeDel(13 downto 6);
            firstTimeDel2D(7 downto 1) <= firstTimeDel2D(6 downto 0);
            
            lastTimeDel2D(0) <= lastTimeDel(14 downto 7); -- 1 clock later than readRunningDel2D, since this signal move data from the accumulator to the hold register in the array. 
            lastTimeDel2D(7 downto 1) <= lastTimeDel2D(6 downto 0);
            
            -- 
            loadShift <= lastTimeDel2D(7)(6);
            loadShiftDel <= loadShift & loadShift & loadShift & loadShift & loadShift & loadShift & loadShift & loadShift;
            if lastTimeDel2D(7)(6) = '1' then
                -- This counts down over 32 clocks. Used to define when and how data is shifted into the output registers; 
                -- either up from the row below, or across 2 columns within the first row.  
                loadShiftCount <= "11111";  
            elsif unsigned(loadShiftCount) /= 0 then
                loadshiftCount <= std_logic_vector(unsigned(loadShiftCount) - 1);
            end if;
            if (loadShiftCount(1 downto 0) = "00" and loadShiftCount(4 downto 2) /= "000") then
                shiftRow <= '1';
            else
                shiftRow <= '0';
            end if;
            if (loadShiftCount(1 downto 0) /= "00") then
                shiftOutTwoSamples <= '1';
            else
                shiftOutTwoSamples <= '0';
            end if;
            shiftRowDel <= shiftRow & shiftRow & shiftRow & shiftRow & shiftRow & shiftRow & shiftRow & shiftRow;
            shiftOutTwoSamplesDel <= shiftOutTwoSamples & shiftOutTwoSamples & shiftOutTwoSamples & shiftOutTwoSamples & shiftOutTwoSamples & shiftOutTwoSamples & shiftOutTwoSamples & shiftOutTwoSamples;
    
            -- Signals that control what happens to the data read out of the 8x8 correlator array
            --   arrayReadoutStart     - high in the first clock of every 8x8 readout
            --   arrayReadoutDiagonal  - high in the first clock of the 8x8 readout if this 8x8 block is on the diagonal of the ACM
            --   arrayReadoutFirst     - indicates this is the first 8x8 block in the ACM (Occurs for each fine channel).
            --   arrayReadoutLast      - indicates this is the last 8x8 block in the ACM, for the last fine channel.
            --   arrayReadoutFirstCT   - This is the first fine channel in the first corner turn frame in the integration, so the start value for the integration is zero.
            --   arrayReadoutFineStart - indicates this is the first fine channel in a block of fine channels that we are integrating
            --                           i.e. the integration data comes from HBM, unless it is zero (i.e. arrayReadoutFirstCT = '1')
            --   arrayReadoutFineEnd   - indicates this is the last fine channel in a block of fine channels that we are integrating.
            --                           i.e. the output of the integration should be written to HBM, not to the ultraRAM buffer.
            --   arrayReadoutStartOfCT - Pulses high at the start of the corner turn, i.e. just prior to the processing of the first fine channel.
            --
            if lastTimeDel2D(7)(6) = '1' then
                -- Valid 2 clocks prior to accumulatorReShift (i.e. the data read out of the correlator array) is valid
                arrayReadoutStart <= '1';
            else
                arrayReadoutStart <= '0';
            end if;
            
            if diagonalDel(21) = '1' then  
                -- del(21) : 
                --   3 clocks to get output of the brams;
                --   4 clocks to get output of the array complex multipliers;
                --   14 clocks to propagate to the bottom right of the 8x8 array
                --   1 clock to move to "accumulatorReHold" register
                --   1 clock to move to "accumulatorReShift" register
                --  -2 clocks to align with arrayReadoutStart
                arrayReadoutDiagonal <= '1';
            else
                arrayReadoutDiagonal <= '0';
            end if;
            
            if (first_8x8blockDel(21) = '1') then
                arrayReadoutFirst <= '1';  -- first 8x8 block in a fine channel
            else
                arrayReadoutFirst <= '0';
            end if;
            
            if (firstFrameDel(21) = '1') then
                arrayReadoutFirstCT <= '1'; -- first corner turn frame of the integration
            else
                arrayReadoutFirstCT <= '0';
            end if;
            
            arrayReadoutFineStart <= fineStartDel(21);
            arrayReadoutFineEnd <= fineEndDel(21);
            arrayReadoutStartOfCT <= startOfCTDel(21);
            arrayReadoutLast <= CTFrameDoneDel(21) and last_8x8blockDel(21);
            --------------------------------------------------------------------
            -- Accumulator and shift logic within the 8x8 correlator array
            for col_mult in 0 to 7 loop
                for row_mult in 0 to 7 loop
                    
                    if firstTimeDel2D(row_mult)(col_mult) = '1' then
                        accumulatorRe(row_mult)(col_mult) <= multOutRe(row_mult)(col_mult);
                        accumulatorIm(row_mult)(col_mult) <= multOutIm(row_mult)(col_mult);
                    elsif readRunningDel2D(col_mult)(row_mult) = '1' then
                        accumulatorRe(row_mult)(col_mult) <= std_logic_vector(unsigned(accumulatorRe(row_mult)(col_mult)) + unsigned(multOutRe(row_mult)(col_mult)));
                        accumulatorIm(row_mult)(col_mult) <= std_logic_vector(unsigned(accumulatorIm(row_mult)(col_mult)) + unsigned(multOutIm(row_mult)(col_mult)));
                    end if;
                    
                    if lastTimeDel2D(row_mult)(col_mult) = '1' then
                        accumulatorReHold(row_mult)(col_mult) <= accumulatorRe(row_mult)(col_mult);
                        accumulatorImHold(row_mult)(col_mult) <= accumulatorIm(row_mult)(col_mult);
                    end if;
                    
                    if loadShiftDel(row_mult) = '1' then
                        accumulatorReShift(row_mult)(col_mult) <= accumulatorReHold(row_mult)(col_mult);
                        accumulatorImShift(row_mult)(col_mult) <= accumulatorImHold(row_mult)(col_mult);
                    elsif shiftRowDel(row_mult) = '1' then
                        if row_mult /= 7 then
                            accumulatorReShift(row_mult)(col_mult) <= accumulatorReShift(row_mult+1)(col_mult);
                            accumulatorImShift(row_mult)(col_mult) <= accumulatorImShift(row_mult+1)(col_mult);
                        end if;
                    elsif shiftOutTwoSamplesDel(col_mult) = '1' then
                        if row_mult = 0 and (col_mult < 6) then
                            accumulatorReShift(row_mult)(col_mult) <= accumulatorReShift(row_mult)(col_mult + 2);
                            accumulatorImShift(row_mult)(col_mult) <= accumulatorImShift(row_mult)(col_mult + 2);
                        end if;
                    end if;
                end loop;
            end loop;
            
        end if;
    end process;
    
    last_8x8blockDel(0) <= colRdJimble_eq_totalJimblesMinus1 and colRdJimble_eq_rowRdJimble;
    
    -- The multiplier array:
    col_mult_gen : for col_mult in 0 to 7 generate
        row_mult_gen : for row_mult in 0 to 7 generate
            
            cmultsi : cmult16x16
            port map (
                aclk => i_clk400,                     -- IN STD_LOGIC;
                s_axis_a_tvalid => '1',               -- IN STD_LOGIC;
                s_axis_a_tdata  => rowDoutDel(col_mult)(row_mult),    -- in(31:0); real (15:0), imaginary (31:16)
                s_axis_b_tvalid => '1',              -- IN STD_LOGIC;
                s_axis_b_tdata  => colDoutDel(row_mult)(col_mult),     -- in(31:0); real (15:0), imaginary (31:16)
                m_axis_dout_tvalid => open,          -- OUT STD_LOGIC;
                m_axis_dout_tdata  => multOut(row_mult)(col_mult) -- out(79:0); -- real (32:0), imaginary (72:40); 4 cycle latency.
            );            
            
            multOutRe(row_mult)(col_mult) <= multOut(row_mult)(col_mult)(39 downto 0);
            multOutIm(row_mult)(col_mult) <= multOut(row_mult)(col_mult)(79 downto 40);
            
        end generate;
    end generate;
    
    
    -- Conversion to floating point for the upper left two samples in the 8x8 correlator array
    int2floatGen : for cSample in 0 to 1 generate
        i40_to_float0 : int40_to_float
        port map (
            aclk                 => i_clk400, --  IN STD_LOGIC;
            s_axis_a_tvalid      => '1', --  IN STD_LOGIC;
            s_axis_a_tdata       => accumulatorReShift(0)(cSample), --  IN STD_LOGIC_VECTOR(39 DOWNTO 0);
            m_axis_result_tvalid => open, --  OUT STD_LOGIC;
            m_axis_result_tdata  => sampleReFloat(cSample) --  OUT STD_LOGIC_VECTOR(31 DOWNTO 0));
        );
        
        i40_to_float1 : int40_to_float
        port map (
            aclk                 => i_clk400, --  IN STD_LOGIC;
            s_axis_a_tvalid      => '1', --  IN STD_LOGIC;
            s_axis_a_tdata       => accumulatorImShift(0)(cSample), --  IN STD_LOGIC_VECTOR(39 DOWNTO 0);
            m_axis_result_tvalid => open, --  OUT STD_LOGIC;
            m_axis_result_tdata  => sampleImFloat(cSample) --  OUT STD_LOGIC_VECTOR(31 DOWNTO 0));
        );
        
        -- Accumulate with either HBM or ultraRAM data:
        fp_add0 : fp_add
        port map (
            aclk => i_clk400, -- : IN STD_LOGIC;
            s_axis_a_tvalid => '1', --  IN STD_LOGIC;
            s_axis_a_tdata => sampleReFloat(cSample), --  IN STD_LOGIC_VECTOR(31 DOWNTO 0);
            s_axis_b_tvalid => '1', --  IN STD_LOGIC;
            s_axis_b_tdata => longTermAccumRe(cSample), --  IN STD_LOGIC_VECTOR(31 DOWNTO 0);
            m_axis_result_tvalid => open, --  OUT STD_LOGIC;
            m_axis_result_tdata => sampleReAccumulated(cSample) --  OUT STD_LOGIC_VECTOR(31 DOWNTO 0));
        );
    
        fp_add1 : fp_add
        port map (
            aclk => i_clk400, -- : IN STD_LOGIC;
            s_axis_a_tvalid => '1', --  IN STD_LOGIC;
            s_axis_a_tdata => sampleImFloat(cSample), --  IN STD_LOGIC_VECTOR(31 DOWNTO 0);
            s_axis_b_tvalid => '1', --  IN STD_LOGIC;
            s_axis_b_tdata => longTermAccumIm(cSample), --  IN STD_LOGIC_VECTOR(31 DOWNTO 0);
            m_axis_result_tvalid => open, --  OUT STD_LOGIC;
            m_axis_result_tdata => sampleImAccumulated(cSample) --  OUT STD_LOGIC_VECTOR(31 DOWNTO 0));
        );
        
    end generate;
    

    -- Control the frequency and long-term accumulation
    -- Accumulation across frequency channels uses an ultraRAM buffer.
    -- Accumulation across multiple corner turn frames uses HBM
    process(i_clk400)
    begin
        if rising_edge(i_clk400) then
            
            -- Select accumulator adder input
            --  For HBM data:
            --   - reads are 512 bits = 64 bytes = 8 ACM elements.
            --   - So for 8x8 ACM blocks that are not on the diagonal, 8 HBM words are needed, one every 4 clocks.
            --   - For 8x8 ACM blocks on the diagonal, there are 36 elements used = 4.5 HBM words
            --   - This module takes data from the HBM in 128 bit words, so that it matches the word size of the ultraRAM buffer.
            --
            --  For data from the ultraram accumulator:
            --   - reads are 128 bits = 16 bytes = 2 ACM elements.
            --   - For 8x8 ACM blocks that are not on the diagonal, 32 reads are needed, one every clock 
            --   - For 8x8 ACM blocks on the diagonal, 36 elements used = 18 ultraRAM reads.
            --    clock | ultraRAM word used is    |  ultraRAM or HBM reads             | read data (di(0), di(1)) into longTermAccumRe/Im(0)/(1) (=0,1) and overflow (of)
            --      0     1  -  -  -  -  -  -  -       <- RdEn at cycle 0,                di(0)->0,di(1)->of,      | --                       |  --                      |  --
            --      4     1  2  -  -  -  -  -  -       <- RdEn at cycle 4                 of->0,di(0)->1,di(1)->of | --                       |  --                      |  --
            --      8     2  3  3  -  -  -  -  -       <- RdEn at cycle 8                 of->0,di(0)->1,di(1)->of | of->0                    |  --                      |  --
            --      12    4  4  5  5  -  -  -  -       <- RdEn at cycle 12, 13            di(0)->0,di(1)->1,       | di(0)->0,di(1)->1        |  --                      |  --
            --      16    6  6  7  7  8  -  -  -       <- RdEn at cycle 16, 17, 18        di(0)->0,di(1)->1        | di(0)->0,di(1)->1        | di(0)->0,di(1)->of       |  --
            --      20    8  9  9  10 10 11 -  -       <- RdEn at cycle 20, 21, 22        of->0,di(0)->1,di(1)->of | of->0,di(0)->1,di(1)->of | of->0,di(0)->1,di(1)->of |  --
            --      24    11 12 12 13 13 14 14 -       <- RdEn at cycle 24, 25, 26        of->0,di(0)->1,di(1)->of | of->0,di(0)->1,di(1)->of | of->0,di(0)->1,di(1)->of | of->0
            --      28    15 15 16 16 17 17 18 18      <- RdEn at cycle 28, 29, 30, 31.   di(0)->0,di(1)->1        | di(0)->0,di(1)->1        | di(0)->0,di(1)->1        | di(0)->0,di(1)->1 
            --
            --   - From the table above, the options for loading the long term accumulator input are:
            --      LongTermReadMapping                  cycles
            --      "00" : di(0)->0,di(1)->of            :  0, 18
            --      "01" : of->0,di(0)->1,di(1)->of      :  4, 8, 20, 21, 22, 24,25,26
            --      "10" : di(0)->0,di(1)->1             :  12, 13, 16, 17, 28, 29, 30, 31, +all cases where this 8x8 ACM block is not on the diagonal.
            --      "11" : No Change
            --
            -- Processing pipeline
            -- cycle    signals
            --   -2     arrayReadoutStart                      
            --   -1     currentReadCount, readoutRunning
            --   0      currentRow, longTermRdEn, longTermReadMapping            = first clock where accumulatorReShift(0) is high.
            --   1      validSamples, freqAccumRdEn, longTermReadMappingDel1, freqAccumRdAddr
            --   2                       longTermReadMappingDel2
            --   3                       longTermReadMappingDel3
            --   4                       longTermReadMappingDel4
            --   5      freqAccumDout,   longTermReadMappingDel5
            --   6      longTermDataIn,  longTermReadMappingDel6
            --   7      longTermAccumRe, SampleReFloat         output of the int -> float is valid for the first element in the 8x8 correlator array (int40_to_Float has 7 clock latency)
            --   8
            --   9
            --   10
            --   11
            --   12
            --   13
            --   14
            --   15
            --   16
            --   17
            --   18    SampleReAccumulated    output of floating point adder fp_add. (11 clock latency) 
            --   19
            --   20

            -- signals that control what happens to the data read out of the 8x8 correlator array
            --   arrayReadoutStart     - high in the first clock of every 8x8 readout
            --   arrayReadoutDiagonal  - high in the first clock of the 8x8 readout if this 8x8 block is on the diagonal of the ACM
            --   arrayReadoutFirst     - indicates this is the first 8x8 block in the ACM.
            --   arrayReadoutLast      - indicates this is the last 8x8 block in the ACM, for the last fine channel.
            --   arrayReadoutFirstCT   - This is the first corner turn frame in the integration, so the start value for the integration is zero.
            --   arrayReadoutFineStart - indicates this is the first fine channel in a block of fine channels that we are integrating
            --                           i.e. the integration data comes from HBM, unless it is zero (i.e. arrayReadoutFirstCT = '1')
            --   arrayReadoutFineEnd   - indicates this is the last fine channel in a block of fine channels that we are integrating.
            --                           i.e. the output of the integration should be written to HBM, not to the ultraRAM buffer.
            --   arrayReadoutStartOfCT - Pulses high at the start of the corner turn, i.e. just prior to the processing of the first fine channel.
            --

            ------------------------
            -- "-2" pipeline stage
            if arrayReadoutStart = '1' then
                currentReadCount <= "00000"; -- counts 0 to 31, for 32 clock cycles to read data out of the 8x8 correlator array (2 samples at a time)
                readoutRunning <= '1';
                arrayReadoutDiagonalDel1 <= arrayReadoutDiagonal;
                arrayReadoutFirstDel1 <= arrayReadoutFirst;
                arrayReadoutLastDel1 <= arrayReadoutLast;
            elsif readoutRunning = '1' then
                currentReadCount <= std_logic_vector(unsigned(currentReadCount) + 1);
                if currentReadCount = "11111" then
                    readoutRunning <= '0';
                end if;
            end if;
            
            arrayReadoutFineStartDel1 <= arrayReadoutFineStart;
            arrayReadoutFirstCTDel1 <= arrayReadoutFirstCT;
            
            arrayReadoutFineEndDel1 <= arrayReadoutFineEnd;
            arrayReadoutStartOfCTDel1 <= arrayReadoutStartOfCT;
            --------------------------
            -- "-1" pipeline stage
            currentRow <= currentReadCount(4 downto 2);
            currentRead <= currentReadCount(1 downto 0);
            arrayReadoutDiagonalDel2 <= arrayReadoutDiagonalDel1;
            arrayReadoutFineStartDel2 <= arrayReadoutFineStartDel1;
            arrayReadoutFirstCTDel2 <= arrayReadoutFirstCTDel1;
            arrayReadoutFirstDel2 <= arrayReadoutFirstDel1;
            arrayReadoutFineEndDel2 <= arrayReadoutFineEndDel1;
            arrayReadoutStartOfCTDel2 <= arrayReadoutStartOfCTDel1;
            readoutRunningDel1 <= readoutRunning;
            if readoutRunning = '1' then
                if arrayReadoutDiagonalDel1 = '1' then
                    if (currentReadCount = "00000" or currentReadCount = "00100" or currentReadCount = "01000" or 
                        currentReadCount = "01100" or currentReadCount = "01101" or currentReadCount = "10000" or
                        currentReadCount = "10001" or currentReadCount = "10010" or currentReadCount = "10100" or
                        currentReadCount = "10101" or currentReadCount = "10110" or currentReadCount = "11000" or
                        currentReadCount = "11001" or currentReadCount = "11010" or currentReadCount = "11100" or
                        currentReadCount = "11101" or currentReadCount = "11110" or currentReadCount = "11111") then
                        -- See comments above for which cycles we need to read new data in for the diagonal case.
                        longTermRdEn <= '1';
                    else
                        longTermRdEn <= '0';
                    end if;
                    -- Work out how data from the long term accumulator gets mapped to the inputs to the floating point adder.
                    -- This is only complicated becuase of the diagonal elements in the ACM, and because the read gets 2 samples at a time.  
                    if (currentReadCount = "00000" or currentReadCount = "10010") then
                        longTermReadMapping <= "00"; -- Tells later pipeline stage to use : di(0)->0,di(1)->of
                    elsif (currentReadCount = "00100" or currentReadCount = "01000" or currentReadCount = "01001" or currentReadCount = "10100" or 
                           currentReadCount = "10101" or currentReadCount = "10110" or currentReadCount = "11000" or
                           currentReadCount = "11001" or currentReadCount = "11010" or currentReadCount = "11011") then
                        longTermReadMapping <= "01"; -- Tells later pipeline stage to use : of->0,di(0)->1,di(1)->of   
                    elsif (currentReadCount = "01100" or currentReadCount = "01101" or currentReadCount = "10000" or
                           currentReadCount = "10001" or currentReadCount = "11100" or currentReadCount = "11101" or
                           currentReadCount = "11110" or currentReadCount = "11111") then --, +all cases where this 8x8 ACM block is not on the diagonal.
                        longTermReadMapping <= "10"; -- Tells later pipeline stage to use : di(0)->0,di(1)->1 
                    else
                        longTermReadMapping <= "11";  -- Don't load anything.
                    end if;
                else
                    -- read every clock cycle
                    longTermRdEn <= '1';
                    longTermReadMapping <= "10"; -- Tells later pipeline stage to use : di(0)->0,di(1)->1 
                end if;
            else
                longTermRdEn <= '0';
            end if;
            if currentReadCount = "00000" and arrayReadoutFirstDel1 = '1' then
                firstLongTermRd <= '1';
            else
                firstLongTermRd <= '0';
            end if;
            
            if currentReadCount = "11111" and arrayReadoutLastDel1 = '1' then
                lastLongTermRd <= '1';
            else
                lastLongTermRd <= '0';
            end if;
            -------------------------
            -- "0" pipeline stage.
            -- Inputs to frequency accumulator (also output to the HBM)
            -- 8x8 array on the diagonal only keep the lower left part of the array:
            arrayReadoutFirstDel3 <= arrayReadoutFirstDel2;
            firstLongTermRdDel1 <= firstLongTermRd;
            lastLongTermRdDel1 <= lastLongTermRd;
            longTermReadMappingDel1 <= longTermReadMapping;
            arrayReadoutFineEndDel3 <= arrayReadoutFineEndDel2;
            arrayReadoutStartOfCTDel3 <= arrayReadoutStartOfCTDel2;
            if arrayReadoutDiagonalDel2 = '0' and readoutRunningDel1 = '1' then
                -- validSamples - 2 bit vector identifying which samples generated by the floating point adders are valid.
                validSamples <= "11"; -- both sample are valid
            elsif arrayReadoutDiagonalDel2 = '1' and readoutRunningDel1 = '1'then 
                if ((currentRow = "000" and currentRead = "00") or
                    (currentRow = "010" and currentRead = "01") or 
                    (currentRow = "100" and currentRead = "10") or 
                    (currentRow = "110" and currentRead = "11")) then
                    validSamples <= "01";
                elsif ((currentRow = "001" and currentRead = "00") or
                       (currentRow = "010" and currentRead = "00") or
                       (currentRow = "011" and (currentRead = "00" or currentRead = "01")) or
                       (currentRow = "100" and (currentRead = "00" or currentRead = "01")) or
                       (currentRow = "101" and (currentRead = "00" or currentRead = "01" or currentRead = "10")) or
                       (currentRow = "110" and (currentRead = "00" or currentRead = "01" or currentRead = "10")) or
                       (currentRow = "111")) then
                    validSamples <= "11";
                else
                    validSamples <= "00";
                end if;
            else
                validSamples <= "00";
            end if;            
            if longTermRdEn = '1' then
                if arrayReadoutFineStartDel2 = '1' then
                    -- First fine channel, current integration data comes from HBM or is zeros.
                    if arrayReadoutFirstCTDel2 = '1' then
                        -- first CT, so integration starts at zeros
                        HBMRdEn <= '0';
                        freqAccumRdEn <= '0';
                    else
                        -- Use HBM data
                        HBMRdEn <= '1';
                        freqAccumRdEn <= '0';
                    end if;
                else
                    -- current integration data comes from ultraRAM
                    freqAccumRdEn <= '1';
                    if firstLongTermRd = '1' then
                        freqAccumRdAddr <= (others => '0');
                    else
                        freqAccumRdAddr <= std_logic_vector(unsigned(freqAccumRdAddr) + 1);
                    end if;
                    HBMRdEn <= '0';
                end if;
            else
                freqAccumRdEn <= '0';
                HBMRdEn <= '0';
            end if;
            
            ------------------------
            -- "1" pipeline stage
            -- 
            HBMrdEnDel1 <= HBMrdEn;
            freqAccumRdEnDel1 <= freqAccumRdEn;
            longTermReadMappingDel2 <= longTermReadMappingDel1;
            validSamplesDel1 <= validSamples;
            arrayReadoutFineEndDel4 <= arrayReadoutFineEndDel3;
            arrayReadoutFirstDel4 <= arrayReadoutFirstDel3;
            lastLongTermRdDel2 <= lastLongTermRdDel1;
            arrayReadoutStartOfCTDel4 <= arrayReadoutStartOfCTDel3;
--            if freqAccumRdEn = '1' then
--                if firstLongTermRdDel1 = '1' then
--                    freqAccumRdAddr <= (others => '0');
--                else
--                    freqAccumRdAddr <= std_logic_vector(unsigned(freqAccumRdAddr) + 1);
--                end if;
--            end if;
            
            ----------------------
            -- "2" pipeline stage
            HBMrdEnDel2 <= HBMrdEnDel1;
            freqAccumRdEnDel2 <= freqAccumRdEnDel1;
            longTermReadMappingDel3 <= longTermReadMappingDel2;
            validSamplesDel2 <= validSamplesDel1;
            arrayReadoutFineEndDel5 <= arrayReadoutFineEndDel4;
            arrayReadoutFirstDel5 <= arrayReadoutFirstDel4;
            arrayReadoutStartOfCTDel5 <= arrayReadoutStartOfCTDel4;
            lastLongTermRdDel3 <= lastLongTermRdDel2;
            
            ----------------------
            -- "3" pipeline stage
            HBMRdEnDel3 <= HBMRdEnDel2;
            freqAccumRdEnDel3 <= freqAccumRdEnDel2;
            longTermReadMappingDel4 <= longTermReadMappingDel3;
            validSamplesDel3 <= validSamplesDel2;
            arrayReadoutFineEndDel6 <= arrayReadoutFineEndDel5;
            arrayReadoutFirstDel6 <= arrayReadoutFirstDel5;
            arrayReadoutStartOfCTDel6 <= arrayReadoutStartOfCTDel5;
            lastLongTermRdDel4 <= lastLongTermRdDel3;
            
            ----------------------
            -- "4" pipeline stage
            HBMRdEnDel4 <= HBMRdEnDel3;
            o_rdHBM <= HBMRdEnDel3;
            freqAccumRdEnDel4 <= freqAccumRdEnDel3;
            longTermReadMappingDel5 <= longTermReadMappingDel4;
            validSamplesDel4 <= validSamplesDel3;
            arrayReadoutFineEndDel7 <= arrayReadoutFineEndDel6;
            arrayReadoutFirstDel7 <= arrayReadoutFirstDel6;
            arrayReadoutStartOfCTDel7 <= arrayReadoutStartOfCTDel6;
            lastLongTermRdDel5 <= lastLongTermRdDel4;
            
            ----------------------
            -- "5" pipeline stage
            --   - "freqAccumDout" is valid at this point (4 cycle latency from freqAccumRdAddr
            --   - i_HBMdata also valid.
            longTermReadMappingDel6 <= longTermReadMappingDel5;
            validSamplesDel5 <= validSamplesDel4;
            arrayReadoutFineEndDel8 <= arrayReadoutFineEndDel7;
            arrayReadoutFirstDel8 <= arrayReadoutFirstDel7;
            arrayReadoutStartOfCTDel8 <= arrayReadoutStartOfCTDel7;
            lastLongTermRdDel6 <= lastLongTermRdDel5;
            o_flushHBM <= lastLongTermRdDel5;
            if HBMRdEnDel4 = '1' then
                longTermDataIn <= i_HBMdata;
            elsif freqAccumRdEnDel4 = '1' then
                longTermDataIn <= freqAccumDout;
            else
                longTermDataIn <= (others => '0');
            end if;
            
            ------------------------
            -- "6" pipeline stage
            validSamplesDel6 <= validSamplesDel5;
            arrayReadoutFineEndDel9 <= arrayReadoutFineEndDel8;
            arrayReadoutFirstDel9 <= arrayReadoutFirstDel8;
            arrayReadoutStartOfCTDel9 <= arrayReadoutStartOfCTDel8;
            lastLongTermRdDel7 <= lastLongTermRdDel6;
            
            if LongTermReadMappingDel6 = "00" then
                -- di(0)->0,di(1)->of      (of = overflow, di = longTermDataIn)
                longTermAccumRe(0) <= longTermDataIn(31 downto 0);
                longTermAccumIm(0) <= longTermDataIn(63 downto 32);
                longTermAccumRe(1) <= (others => '0');
                longTermAccumIm(1) <= (others => '0');
                overflowIn <= longTermDataIn(127 downto 64);
            elsif LongTermReadMappingDel6 = "01" then
                -- of->0,di(0)->1,di(1)->of
                longTermAccumRe(0) <= overflowIn(31 downto 0);
                longTermAccumIm(0) <= overflowIn(63 downto 32);
                longTermAccumRe(1) <= longTermDataIn(31 downto 0);
                longTermAccumIm(1) <= longTermDataIn(63 downto 32);
                overflowIn <= longTermDataIn(127 downto 64);
            elsif LongTermReadMappingDel6 = "10" then
                --  di(0)->0,di(1)->1 
                longTermAccumRe(0) <= longTermDataIn(31 downto 0);
                longTermAccumIm(0) <= longTermDataIn(63 downto 32);
                longTermAccumRe(1) <= longTermDataIn(95 downto 64);
                longTermAccumIm(1) <= longTermDataIn(127 downto 96);
            end if;
            
            -----------------------------------------------
            -----------------------------------------------
            -- 11 clock latency until the output of the floating point adders is valid.

            validSamplesDelAdder(0) <= validSamplesDel6;
            validSamplesDelAdder(9 downto 1) <= validSamplesDelAdder(8 downto 0);
            validSamplesOutput <= validSamplesDelAdder(9);
            
            arrayReadoutFineEndAdder(0) <= arrayReadoutFineEndDel9;  -- "adder" suffix since arrayReadoutFineEndAdder(10) aligns with the output of the floating point adder.
            arrayReadoutFineEndAdder(10 downto 1) <= arrayReadoutFineEndAdder(9 downto 0);
            
            arrayReadoutFirstDel(0) <= arrayReadoutFirstDel9;
            arrayReadoutFirstDel(10 downto 1) <= arrayReadoutFirstDel(9 downto 0);
            
            arrayReadoutStartOfCTDel(0) <= arrayReadoutStartOfCTDel9;
            arrayReadoutStartOfCTDel(9 downto 1) <= arrayReadoutStartOfCTDel(8 downto 0);
            
            lastLongTermRdDel(0) <= lastLongTermRdDel7;
            lastLongTermRdDel(10 downto 1) <= lastLongTermRdDel(9 downto 0);
            ----------------------------------------------
            -- Write to the long-term accumulator, either the HBM or the ultraRAM buffer.

            -- rising edge of arrayReadoutFirstDel(8) is used to reset the readout of the ACM.
            -- This will occur once at the start of the readout of a full ACM
            if (arrayReadoutFirstDel(8) = '1' and arrayReadoutFirstDel(9) = '0') then
                startOfACM <= '1';
            else
                startOfACM <= '0';
            end if;
            
            if startOfACM = '1' then  -- start of a new ACM (i.e. a new group of frequency channels that are being integrated together)
                overflowOutUsed <= '0';
                freqAccumDinValid <= '0';
            elsif validSamplesOutput = "01" then  -- one of the floating point adders has valid output data. This only occurs on the 8x8 ACM cells on the diagonal.
                if overflowOutUsed = '1' then
                    freqAccumDin(63 downto 0) <= overflowOut;
                    freqAccumDin(127 downto 64) <= sampleImAccumulated(0) & SampleReAccumulated(0);
                    freqAccumDinValid <= '1';
                    overflowOutUsed <= '0';
                else
                    overflowOut <= sampleImAccumulated(0) & SampleReAccumulated(0);
                    overflowOutUsed <= '1';
                    freqAccumDinValid <= '0';
                end if;
            elsif validSamplesOutput = "11" then
                if overflowOutUsed = '1' then
                    freqAccumDin(63 downto 0) <= overflowOut;
                    freqAccumDin(127 downto 64) <= sampleImAccumulated(0) & sampleReAccumulated(0);
                    overflowOut <= sampleImAccumulated(1) & sampleReAccumulated(1);
                    freqAccumDinValid <= '1';
                    overflowOutUsed <= '1';
                else
                    freqAccumDin(63 downto 0) <= sampleImAccumulated(0) & sampleReAccumulated(0);
                    freqAccumDin(127 downto 64) <= sampleImAccumulated(1) & sampleReAccumulated(1);
                    overflowOutUsed <= '0';
                    freqAccumDinValid <= '1';
                end if;
            else
                freqAccumDinValid <= '0';
            end if;
            
            if startOfACM = '1' then
                freqAccumWrAddr <= (others => '0');
            elsif freqAccumDinValid = '1' then
                freqAccumWrAddr <= std_logic_vector(unsigned(freqAccumWrAddr) + 1);
            end if;
            
            -- Outputs to the HBM
            -- Accumulate 4 x 128-bit words into the output register
            if arrayReadoutStartOfCTDel(8) = '1' then
                HBMoutputRegUsed <= "00";
                wrHBM <= '0';
                lastHBMWrite <= '0';
            elsif freqAccumDinValid = '1' and arrayReadoutFineEndAdder(10) = '1' then
                -- This is the last fine channel that we are accumulating, so the output goes to the HBM.
                if lastLongTermRdDel(10) = '1' then
                    lastHBMWrite <= '1';
                end if;
                if HBMoutputRegUsed = "00" then
                    HBMoutputReg(127 downto 0) <= freqAccumDin;
                    HBMoutputRegUsed <= "01";
                    wrHBM <= '0';
                elsif HBMoutputRegUsed = "01" then
                    HBMoutputReg(255 downto 128) <= freqAccumDin;
                    HBMoutputRegUsed <= "10";
                    wrHBM <= '0';
                elsif HBMoutputRegUsed = "10" then
                    HBMoutputReg(383 downto 256) <= freqAccumDin;
                    HBMoutputRegUsed <= "11";
                    wrHBM <= '0';
                else
                    HBMoutputReg(511 downto 384) <= freqAccumDin;
                    HBMoutputRegUsed <= "00";
                    wrHBM <= '1';
                end if;
            else
                wrHBM <= '0';
                lastHBMWrite <= '0';
            end if;
            
        end if;
    end process;

    o_lastHBMWrite <= lastHBMWrite;
    o_wrHBM <= wrHBM;
    o_HBMData <= HBMoutputReg;

    -- ultraRAM buffer for accumulation across frequency channels.
    --  - 8 bytes per ACM element (4 byte real + 4 byte imaginary)
    --  - Total ACM elements = 224*225/2 = 25200
    --  - Read 2 elements per clock, so we need a memory which is : (16 bytes wide) x (12600 deep)
    --     = 8 ultraRAMs (= 16 bytes wide x 16384 deep).
    xpm_memory_tdpram_inst : xpm_memory_sdpram
    generic map (
        ADDR_WIDTH_A => 14,              -- DECIMAL
        ADDR_WIDTH_B => 14,              -- DECIMAL
        AUTO_SLEEP_TIME => 0,            -- DECIMAL
        BYTE_WRITE_WIDTH_A => 128,       -- DECIMAL
        CASCADE_HEIGHT => 0,             -- DECIMAL
        CLOCKING_MODE => "common_clock", -- String
        ECC_MODE => "no_ecc",            -- String
        MEMORY_INIT_FILE => "none",      -- String
        MEMORY_INIT_PARAM => "0",        -- String
        MEMORY_OPTIMIZATION => "true",   -- String
        MEMORY_PRIMITIVE => "ultra",     -- String
        MEMORY_SIZE => 2097152,          -- DECIMAL  -- Total bits in the memory; 16384 * 128 = 2097152
        MESSAGE_CONTROL => 0,            -- DECIMAL
        READ_DATA_WIDTH_B => 128,        -- DECIMAL
        READ_LATENCY_B => 4,             -- DECIMAL  (NOTE : cascaded urams need latency > 3 to use registers in the cascade path).
        READ_RESET_VALUE_B => "0",       -- String
        RST_MODE_A => "SYNC",            -- String
        RST_MODE_B => "SYNC",            -- String
        SIM_ASSERT_CHK => 0,             -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_EMBEDDED_CONSTRAINT => 0,    -- DECIMAL
        USE_MEM_INIT => 0,               -- DECIMAL
        WAKEUP_TIME => "disable_sleep",  -- String
        WRITE_DATA_WIDTH_A => 128,       -- DECIMAL
        WRITE_MODE_B => "read_first"     -- String
    )
    port map (
        dbiterrb => open,       -- 1-bit output: Status signal to indicate double bit error occurrence on the data output of port A.
        doutb => freqAccumDout, -- READ_DATA_WIDTH_B-bit output: Data output for port B read operations.
        sbiterrb => open,       -- 1-bit output: Status signal to indicate single bit error occurrence on the data output of port B.
        addra => freqAccumWrAddr, -- ADDR_WIDTH_A-bit input: Address for port A write and read operations.
        addrb => freqAccumRdAddr, -- ADDR_WIDTH_B-bit input: Address for port B write and read operations.
        clka => i_clk400,       -- 1-bit input: Clock signal for port A. Also clocks port B when parameter CLOCKING_MODE is "common_clock".
        clkb => i_clk400,       -- Unused when parameter CLOCKING_MODE is "common_clock".
        dina => freqAccumDin,   -- WRITE_DATA_WIDTH_A-bit input: Data input for port A write operations.
        ena => '1',             -- 1-bit input: Memory enable signal for port A.
        enb => '1',             -- 1-bit input: Memory enable signal for port B.
        injectdbiterra => '0',  -- 1-bit input: Controls double bit error injection on input data
        injectsbiterra => '0',  -- 1-bit input: Controls single bit error injection on input data
        regceb => '1',          -- 1-bit input: Clock Enable for the last register stage on the output data path.
        rstb => '0',            -- 1-bit input: Reset signal for the final port B output register
        sleep => '0',           -- 1-bit input: sleep signal to enable the dynamic power saving feature.
        wea => freqAccumWrEn    -- WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-bit input: Write enable vector for port A input data port dina. 
    );    
    
    freqAccumWrEn(0) <= freqAccumDinValid;
    
    -----------------------------------------------------------------------------------
    
    
end Behavioral;
