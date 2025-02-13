----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 13.09.2020 23:55:03
-- Module Name: corr_ct1_readout - Behavioral
-- Description: 
--  Readout data for correlator processing from the first stage corner turn.
-- 
--  -----------------------------------------------------------------------------
--  Flow chart:
--
--    commands in (i_currentBuffer, i_readStart, i_Nchannels)
--        |
--    Wait until all previous memory read requests have returned, and the buffer is empty.
--        |
--    Generate Read addresses on the AXI bus to shared memory ------------>>>----------------
--     (Read from 4 different virtual channels at a time)                                   |
--        |                                                                         Generate start of frame signal for the read side. 
--    Data from shared memory goes into buffer                                      Also send the packet count to the read side for the first packet in the frame.
--     (write side of buffer is 512 deep x 512 bits wide)                                   |
--        |                                                                                 |
--    Read data from BRAM buffer into 128 bit registers ------------------<<<----------------
--     (Read side of the buffer is 2048 deep x 128 bits wide)
--        |
--    Send data from 128 bit registers to the filterbanks, 32 bits at a time.
--
--  -----------------------------------------------------------------------------
--  Structure:
-- 
--   commands in -> read address fsm (ar_fsm) -> AXI AR bus (axi_arvalid, axi_arready, axi_araddr, axi_arlen)
--                                            -> 
--
--   Read data bus (axi_rvalid, axi_rdata etc) -> BRAM buffer (4096 deep x 512 bits) -> 4 x 512 bit registers (one for each filterbank output) -> 4 x 32 bit FIFOs -> output busses
--           ar_fsm    -->  ar FIFO            -> buffer_FIFOs                                   -> read fsm 
--
--  There are several buffers :
--    - ar_FIFO : Holds information about the read request until the read data comes back from the external memory.
--    - Buffer  : Main buffer, write side 512 deep x 512 bits wide, split into 4 buffers, one for each channel being read out
--                Read side of the buffer is 2048 deep x 128 bits wide. It needs to be 128 bits wide in order to have sufficient read bandwidth.
--    - buffer_fifos : 3 fifos, one for each buffer in the main buffer, holds information about each word in the buffer
--    - reg128  : 3 x 128 bit registers, to convert from 128 bit data out of the buffer to 32 bit data that is sent to the filterbanks
--    - fifo32 : 3 x 32 bit wide FIFOs, to stream data to the filterbanks.
--     
--  ------------------------------------------------------------------------------
--  BRAM buffer structure
--  Requirements :
--    - Single clock, since input clock is the 300 MHz clock from the AXI bus, output clock is 300 MHz clock to the filterbanks.
--    - 512 wide input (=width of the AXI bus)
--    - Buffer data for 4 different virtual channels (since this module drives 4 dual-pol filterbanks)
--  Structure :
--    - 4096 deep x 512 bits wide. (8 UltraRAMs). 
--    - The buffer is split into 4 regions of 1024 words, addresses 0-1023, 1024-3047, 2048-3071, 3072-4095, one for each virtual channel being simultaneously read out.
--    - Within a 1024-word block, there is 64kBytes of space, sufficient for 8 LFAA packets = 4 output packets (output packets to the filterbank are 2 LFAA packets long).
--
--  In addition to the main 4096x512 buffer, a FIFO is kept for each of the three regions in the buffer
--  Every time a 512 bit word is written to the buffer, an entry is written to the FIFO
--  FIFO contents :
--      - bits 15:0  = HDeltaP (HDeltaP and VDeltaP are the fine delay information placed in the meta info for this output data)
--      - bits 31:16 = VDeltaP
--      - bit 35:32  = S = Number of samples in the 512 bit word - 1. Note 512 bits = 64 bytes = 16 samples, so this ranges from 0 to 15
--                     For the first word in a channel, the data will be left aligned, i.e. in bits(511 downto (512 - (S+1)*32))
--                     while for the last word it will be right aligned, i.e. in bits((S+1)*32 downto 0).
--
--  Each of these 4 FIFOs uses 1x18K BRAM.
--  After a start of frame signal is received, the read side fsm waits until all the FIFOs contain at least 256 entries before it starts reading.
--   (Note 256 entries = 256 x 64 bytes = 16 kbytes = 4096 samples = 1 output burst to the filterbanks.)
--  Then the read fsm reads at the rate programmed in the registers (i.e. a fixed number of output clock cycles per output frame).
--  
--  Coarse Delay implementation:
--   To implement the coarse delay for each channel :
--    - Reads from shared memory are 512 bit aligned
--    - Reads from the the ultraRAM buffer are 512 bit aligned
--    - Reads from the 128 bit register are 32 bit aligned, i.e. aligned to the first sample. 
--
--  Output frames & coarse Delay
--   The coarse delay is up to 2047 LFAA samples.
--   The last sample output to the correlator filterbanks for a frame is <last sample in frame> - 2048 + coarse_delay
--   This means that the first sample output to the correlator filterbanks will be 
--       <last sample in the previous frame> - 2048 + coarse_delay - <preload> 
--     =  <last sample in the previous frame> - 2048 + coarse_delay - 11 * 4096
--     =  <last sample in the previous frame> - 47104 + coarse_delay
--   The output is in units of blocks of 4096 samples, since each of these generates a new output from the filterbanks.
--  
--   Preload data for the correlator filterbank consists of 11*4096 = 45056 samples.
-- 
--  Note : For diagrams showing how the coarse delay relates to buffers see 
--    https://confluence.skatelescope.org/display/SE/PSS+and+PST+Coarse+Corner+Turner (page is for pst but similar concepts apply to correlator)
--  ------------------------------------------------------------------------------
--  Memory latency
--  The HBM controller quotes a memory latency of 128 memory clocks (i.e. 900MHz clocks)
--  (or possibly more, depending on transaction patterns.)
--  There are two separate command queues in the HBM controller of 128 and 12 entries. Likely both are enabled 
--  in the Vitis design.
--  128 x 900 MHz clocks = 142 ns = 43 x 300 MHz clocks.
--  So we can roughly expect that read data will be returned around 43 clocks after the read 
--  request has been issued. Since we are requesting bursts of 16 x 256 bit words, there will likely be 
--  3 or 4 transactions in flight if we are reading at the full rate.
----------------------------------------------------------------------------------

library IEEE, xpm, common_lib, ct_lib, DSP_top_lib, axi4_lib;
use IEEE.STD_LOGIC_1164.ALL;
use xpm.vcomponents.all;
use IEEE.NUMERIC_STD.ALL;
USE common_lib.common_pkg.ALL;
use DSP_top_lib.DSP_top_pkg.ALL;
use axi4_lib.axi4_full_pkg.ALL;

entity corr_ct1_readout is
    generic (
        -- Number of SPS PACKETS per frame. 128 = 283 ms corner turn frame.
        -- 32 is also supported by this module, for use in simulation only.
        g_SPS_PACKETS_PER_FRAME : integer := 128;
        -- center tap of the filterbank FIR filter.
        g_FILTER_CENTER : integer := 23598
    );
    Port(
        shared_clk : in std_logic; -- Shared memory clock
        i_rst      : in std_logic; -- module reset, on shared_clk.
        -- input signals to trigger reading of a buffer, on shared_clk
        i_currentBuffer   : in std_logic_vector(1 downto 0);
        i_readStart       : in std_logic;                      -- Pulse to start readout from readBuffer
        i_integration     : in std_logic_vector(31 downto 0);  -- Integration Count for the first packet in i_currentBuffer
        i_Nchannels       : in std_logic_vector(11 downto 0);  -- Total number of virtual channels to read out,
        i_clocksPerPacket : in std_logic_vector(15 downto 0);  -- Number of clocks per output, connect to register "output_cycles"
        -- Reading Coarse and fine delay info from the registers
        -- In the registers, word 0, bits 15:0  = Coarse delay, word 0 bits 31:16 = Hpol DeltaP, word 1 bits 15:0 = Vpol deltaP, word 1 bits 31:16 = deltaDeltaP
        o_delayTableAddr : out std_logic_vector(14 downto 0);  -- 2 buffers, 10 words per buffer, 1024 virtual channels = 20480 words
        i_delayTableData : in std_logic_vector(63 downto 0);   -- Data from the delay table with 3 cycle latency. 
        -- Read and write to the valid memory, to check the place we are reading from in the HBM has valid data
        o_validMemReadAddr : out std_logic_vector(18 downto 0); -- 8192 bytes per LFAA packet, 1 GByte of memory, so 1Gbyte/8192 bytes = 2^30/2^13 = 2^17
        i_validMemReadData : in std_logic;  -- read data returned 3 clocks later.
        o_validMemWriteAddr : out std_logic_vector(18 downto 0); -- write always clears the memory (mark the block as invalid).
        o_validMemWrEn      : out std_logic;
        -- Data output to the filterbanks
        -- meta fields are 
        --   - .HDeltaP(15:0), .VDeltaP(15:0) : phase across the band, used by the fine delay.
        --   - .frameCount(36:0), = high 32 bits is the LFAA frame count, low 5 bits is the 64 sample block within the frame. 
        --   - .virtualChannel(15:0) = Virtual channels are processed in order, so this just counts.
        --   - .valid                = Number of virtual channels being processed may not be a multiple of 3, so there is also a valid qualifier.
        --FB_clk  : in std_logic;  -- interface runs off shared_clk
        o_sof   : out std_logic; -- start of frame for a particular set of 4 virtual channels.
        o_sofFull : out std_logic; -- start of a full frame, i.e. 283 ms of data.
        o_HPol0 : out t_slv_8_arr(1 downto 0);
        o_VPol0 : out t_slv_8_arr(1 downto 0);
        o_meta0 : out t_CT1_META_out;  -- defined in DSP_top_pkg.vhd; 
        
        o_HPol1 : out t_slv_8_arr(1 downto 0);
        o_VPol1 : out t_slv_8_arr(1 downto 0);
        o_meta1 : out t_CT1_META_out;
        
        o_HPol2 : out t_slv_8_arr(1 downto 0);
        o_VPol2 : out t_slv_8_arr(1 downto 0);
        o_meta2 : out t_CT1_META_out;
        
        o_HPol3 : out t_slv_8_arr(1 downto 0);
        o_VPol3 : out t_slv_8_arr(1 downto 0);
        o_meta3 : out t_CT1_META_out;
        o_lastChannel : out std_logic; -- Aligns with o_metaX
        o_valid : out std_logic;
        -- AXI read address and data input buses
        -- ar bus - read address
        o_axi_ar      : out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_axi_arready : in std_logic; 
        
        -- r bus - read data
        i_axi_r       : in  t_axi4_full_data;
        o_axi_rready  : out std_logic;
        
        -- errors and debug
        -- Flag an error; we were asked to start reading but we haven't finished reading the previous frame.
        o_readOverflow : out std_logic;     -- Pulses high in the shared_clk domain.
        o_Unexpected_rdata : out std_logic; -- data was returned from the HBM that we didn't expect (i.e. no read request was put in for it)
        o_dataMissing : out std_logic;      -- Read from a HBM address that we haven't written data to. Most reads are 8 beats = 8*64 = 512 bytes, so this will go high 16 times per missing LFAA packet.
        o_bad_readstart : out std_logic;    -- read start occured prior to delay calculation finishing for the previous read.
        -- Debug data
        o_dbg_vec : out std_logic_vector(255 downto 0);
        o_dbg_valid : out std_logic
    );
end corr_ct1_readout;

architecture Behavioral of corr_ct1_readout is
    
    signal bufRdAddr : std_logic_vector(11 downto 0);
    signal bufDout : std_logic_vector(511 downto 0);
    
    signal FBintegration : std_logic_vector(31 downto 0);
    signal FBctFrame : std_logic_vector(1 downto 0);
    signal cdc_dataOut : std_logic_vector(65 downto 0);
    signal cdc_dataIn : std_logic_vector(65 downto 0);
    signal shared_to_FB_valid, shared_to_FB_valid_del1 : std_logic;
    signal shared_to_FB_send, shared_to_FB_rcv : std_logic := '0';
    --signal FBbufferStartAddr : std_logic_vector(7 downto 0);
    signal FBClocksPerPacket, FBClocksPerPacketMinusTwo : std_logic_vector(15 downto 0);
    signal FBNChannels : std_logic_vector(15 downto 0);
    signal bufReadAddr0, bufReadAddr1, bufReadAddr2, bufReadAddr3 : std_logic_vector(9 downto 0);
    
    signal ARFIFO_dout : std_logic_vector(15 downto 0);
    signal ARFIFO_validOut : std_logic;
    signal ARFIFO_empty : std_logic;
    signal ARFIFO_full : std_logic;
    signal ARFIFO_RdDataCount : std_logic_vector(5 downto 0);
    signal ARFIFO_WrDataCount : std_logic_vector(5 downto 0);
    signal ARFIFO_din : std_logic_vector(12 downto 0);
    signal ARFIFO_rdEn : std_logic;
    signal ARFIFO_rst : std_logic;
    signal ARFIFO_wrEn : std_logic;
    
    signal ar_virtualChannel : std_logic_vector(9 downto 0);
    signal ar_currentBuffer : std_logic_vector(1 downto 0);
    signal ar_previousBuffer, ar_nextBuffer : std_logic_vector(1 downto 0);
    signal ar_integration : std_logic_vector(31 downto 0);
    signal ar_NChannels : std_logic_vector(11 downto 0);
    signal ar_clocksPerPacket : std_logic_vector(15 downto 0);
    
    type ar_fsm_type is (waitDelaysValid, getCoarseDelays0, getCoarseDelays1, getDataIdle, getBufData,
                         waitARReady, checkAllVirtualChannelsDone, waitAllDone, checkDone, done);
    signal ar_fsm, ar_fsmDel1, ar_fsmDel2, ar_fsmDel3, ar_fsmDel4 : ar_fsm_type;
    signal pendingReads, bufMaxUsed : t_slv_11_arr(3 downto 0);
    signal ARFIFO_wrBeats : std_logic_vector(10 downto 0);
    
    signal bufBuffer : t_slv_2_arr(3 downto 0);
    signal bufSample : t_slv_20_arr(3 downto 0);  -- 128 LFAA packets per buffer, 2048 samples per LFAA packet = 2^18 samples per buffer.
    signal bufLen : t_slv_3_arr(3 downto 0);
    signal bufSamplesRemaining : t_slv_20_arr(3 downto 0);
    signal bufSamplesToRead : t_slv_8_arr(3 downto 0);
    signal bufLen_ext : t_slv_20_arr(3 downto 0);
    
    signal bufVirtualChannel : t_slv_10_arr(3 downto 0);
    signal bufCoarseDelay : t_slv_20_arr(3 downto 0);
    signal bufHasMoreSamples : std_logic_vector(3 downto 0); -- one bit for each buffer.
    signal bufFirstRead, bufLastRead : std_logic_Vector(3 downto 0);
    
    signal rdata_beats : std_logic_vector(2 downto 0);
    signal rdata_beatCount : std_logic_vector(2 downto 0);
    signal rdata_rdStartOffset, rdata_rdStartOffsetDel2, rdata_rdStartOffsetDel3, rdata_rdStartOffsetDel4, rdata_rdStartOffsetDel5, rdata_rdStartOffsetDel6, rdata_rdStartOffsetDel7 : std_logic_vector(3 downto 0);
    signal axi_rvalid_del1, axi_rvalid_del2, axi_rvalid_del3, axi_rvalid_del4, axi_rvalid_del5, axi_rvalid_del6, axi_rvalid_del7 : std_logic;
    signal rdata_stream, rdata_streamDel2, rdata_streamDel3, rdata_streamDel4, rdata_streamDel5, rdata_streamDel6, rdata_streamDel7 : std_logic_vector(1 downto 0);
    signal ar_regUsed : std_logic := '0';
    
    signal bufFIFO_din : std_logic_vector(3 downto 0);
    signal bufFIFO_dout : t_slv_4_arr(3 downto 0);
    signal delayFIFO_dout : t_slv_129_arr(3 downto 0);
    signal bufFIFO_empty : std_logic_vector(3 downto 0);
    signal bufFIFO_rdDataCount : t_slv_11_arr(3 downto 0);
    signal bufFIFO_wrDataCount : t_slv_11_arr(3 downto 0);
    signal bufFIFO_rdEn, bufFIFO_wrEn, bufFIFO_wrEnDel1 : std_logic_vector(3 downto 0);
    
    signal bufWrAddr : std_logic_vector(11 downto 0);
    signal bufWrAddr0, bufWrAddr1, bufWrAddr2, bufWrAddr3 : std_logic_vector(9 downto 0);
    signal bufWE : std_logic_vector(0 downto 0);
    
    signal axi_arvalid : std_logic;
    signal axi_araddr  : std_logic_vector(31 downto 0);
    signal axi_arlen   : std_logic_vector(2 downto 0);

    signal ARFIFO_dinDel1, ARFIFO_dinDel2, ARFIFO_dinDel3 : std_logic_vector(15 downto 0);
    signal ARFIFO_dinDel4, ARFIFO_dinDel5, ARFIFO_dinDel6 : std_logic_vector(15 downto 0);
    signal ARFIFO_wrEnDel1, ARFIFO_wrEnDel2, ARFIFO_wrEnDel3, ARFIFO_wrEnDel4, ARFIFO_wrEnDel5, ARFIFO_wrEnDel6 : std_logic;
    signal rdata_dvalid : std_logic;
    signal bufWrData : std_logic_vector(511 downto 0);
    
    signal validMemWriteAddr, validMemWriteAddrDel1, validMemWriteAddrDel2 : std_logic_vector(18 downto 0);
    signal validMemWrEn, validMemWrEnDel1, validMemWrEnDel2 : std_logic;
    signal axi_arvalidDel1 : std_logic;
    signal readStartDel1, readStartDel2 : std_logic;

    type rd_fsm_type is (reset_output_fifos_start, reset_output_fifos_wait, reset_output_fifos, reset_output_fifos_wait1, reset_output_fifos_wait2, rd_wait, rd_buf0, rd_buf1, rd_buf2, rd_buf3, rd_start, idle);
    signal rd_fsm : rd_fsm_type := idle;
    signal readOutRst : std_logic := '0';
    signal buf0WordsRemaining, buf1WordsRemaining, buf2WordsRemaining, buf3WordsRemaining : std_logic_vector(15 downto 0) := x"0000";
    signal buf0RdEnableDel2, buf0RdEnableDel1, buf0RdEnable : std_logic := '0';
    signal buf1RdEnableDel2, buf1RdEnableDel1, buf1RdEnable : std_logic := '0';
    signal buf2RdEnableDel2, buf2RdEnableDel1, buf2RdEnable : std_logic := '0';
    signal buf3RdEnableDel2, buf3RdEnableDel1, buf3RdEnable : std_logic := '0';
    signal bufRdValid : std_logic_vector(3 downto 0);
    signal rdStop : std_logic_vector(3 downto 0);
    signal rstBusy : std_logic_vector(3 downto 0);
    signal buf0ReadDone, buf1ReadDone, buf2ReadDone, buf3ReadDone : std_logic := '0';
    signal channelCount : std_logic_vector(15 downto 0);
    
    signal rdOffset : t_slv_4_arr(3 downto 0);
    signal readoutData : t_slv_32_arr(3 downto 0);
    signal readoutHDeltaP : t_slv_16_arr(3 downto 0);
    signal readoutVDeltaP : t_slv_16_arr(3 downto 0);
    signal readoutHOffsetP : t_slv_16_arr(3 downto 0);
    signal readoutVOffsetP : t_slv_16_arr(3 downto 0);
    signal bufFIFOHalfFull : std_logic_vector(3 downto 0);
    signal allPacketsSent : std_logic;
    
    signal readoutStartDel : std_logic_vector(27 downto 0) := x"0000000";
    signal readoutStart : std_logic := '0';
    signal readPacket : std_logic := '0';
    signal clockCount : std_logic_vector(15 downto 0);
    signal packetsRemaining, packetsRemaining_minus1 : std_logic_vector(15 downto 0);
    signal some_packets_remaining : std_logic := '0';
    signal validOut : std_logic_vector(3 downto 0);
    --signal packetCount : std_logic_vector(31 downto 0);
    signal meta0VirtualChannel, meta1VirtualChannel, meta2VirtualChannel, meta3VirtualChannel : std_logic_vector(15 downto 0);
    signal sofFull, sof : std_logic := '0';
    signal axi_rdataDel1 : std_logic_vector(511 downto 0);
    signal selRFI : std_logic;
    signal clockCountIncrement : std_logic := '0';
    signal clockCountZero : std_logic := '0';
    
    signal rstDel1, rstDel2, rstInternal, rstFIFOs, rstFIFOsDel1 : std_logic := '0';
    signal rd_wait_count : std_logic_vector(3 downto 0) := "0000";
    signal ar_fsm_buffer, ar_fsm_bufferDel1, ar_fsm_bufferDel2, ar_fsm_bufferDel3, ar_fsm_bufferDel4 : std_logic_vector(1 downto 0) := "00";
    signal shared_to_FB_send_del1 : std_logic := '0';
    component ila_beamData
    port (
        clk : in std_logic;
        probe0 : in std_logic_vector(119 downto 0)); 
    end component;
    
    component ila_2
    port (
        clk : in std_logic;
        probe0 : in std_logic_vector(63 downto 0)); 
    end component;
    
    signal delay_vc, delay_packet : std_logic_vector(15 downto 0);
    signal delay_Hpol_deltaP, delay_Hpol_phase, delay_Vpol_deltaP, delay_Vpol_phase : std_logic_vector(31 downto 0);
    signal delay_valid : std_logic;
    signal delay_offset, delay_offset_inv, delay_offset_neg : std_logic_vector(11 downto 0); -- Number of whole 1080ns samples to delay by.
    
    signal delayFIFO_din : std_logic_vector(128 downto 0);
    signal delayFIFO_wrEn : std_logic_Vector(3 downto 0);
    
    type poly_fsm_t is (start, wait_done0, wait_done1, wait_done2, check_fifos, update_vc, check_vc, done);
    signal poly_fsm : poly_fsm_t := done;
    signal poly_vc_base : std_logic_vector(15 downto 0);
    signal poly_integration : std_logic_vector(31 downto 0);
    signal poly_ct_frame : std_logic_vector(1 downto 0);
    signal Nchannels : std_logic_vector(11 downto 0);
    signal poly_start : std_logic := '0';
    signal poly_idle : std_logic;
    signal poly_vc : t_slv_16_arr(3 downto 0);
    signal delayFIFO_wrDataCount : t_slv_11_arr(3 downto 0);
    signal delayFIFO_rdDataCount : t_slv_11_arr(3 downto 0);
    signal coarseFIFO_din : std_logic_vector(31 downto 0);
    signal coarseFIFO_wrEn : std_logic_vector(3 downto 0);
    signal coarseFIFO_wrDataCount : t_slv_6_arr(3 downto 0);
    signal coarseFIFO_empty : std_logic_vector(3 downto 0);
    signal coarseFIFO_dout : t_slv_32_arr(3 downto 0);
    signal coarseFIFO_rdEn : std_logic_vector(3 downto 0);
    signal delayFIFO_empty : std_logic_vector(3 downto 0);
    signal delayFIFO_rden : std_logic_vector(3 downto 0);
    signal readout_delay_vc : t_slv_16_arr(3 downto 0);
    signal readout_delay_packet : t_slv_8_arr(3 downto 0);

    -- HBM ILA related things
    component fp64_to_fp32
    port (
        aclk : IN STD_LOGIC;
        s_axis_a_tvalid : IN STD_LOGIC;
        s_axis_a_tdata : IN STD_LOGIC_VECTOR(63 DOWNTO 0);
        m_axis_result_tvalid : OUT STD_LOGIC;
        m_axis_result_tdata : OUT STD_LOGIC_VECTOR(31 DOWNTO 0));
    end component;
    
    signal poly_result : std_logic_vector(63 downto 0);
    signal poly_time : std_logic_vector(63 downto 0);
    signal poly_buffer_select : std_logic;
    signal dbg_poly_integration : std_logic_vector(31 downto 0);
    signal dbg_poly_ct_frame : std_logic_vector(1 downto 0);
    signal poly_uptime : std_logic_vector(47 downto 0);
    signal dbg_valid, dbg_valid_del1, dbg_valid_del2 : std_logic;
    signal dbg_vec : std_logic_vector(255 downto 0);
    signal dbg_vec_del1, dbg_vec_del2 : std_logic_vector(255 downto 0);
    signal fp32_delay_valid, fp32_delay_valid2 : std_logic;
    signal poly_result_fp32, poly_time_fp32 : std_logic_vector(31 downto 0);
    signal bad_poly : std_logic; 

begin
    
    o_axi_ar.len(7 downto 3) <= "00000";  -- Never ask for more than 8 x 64 byte words.
    o_axi_ar.len(2 downto 0) <= axi_arlen(2 downto 0);
    o_axi_rready <= '1';
    o_axi_ar.valid <= axi_arvalid;
    o_axi_ar.addr <= x"00" & axi_araddr;
    
    o_validMemReadAddr <= axi_araddr(31 downto 13);
    
    process(shared_clk)
        variable bufSampleTemp : t_slv_20_arr(3 downto 0);
        --variable bufSampleRelative_v : t_slv_20_arr(3 downto 0);
        variable bufSamplesToRead20bit : t_slv_20_arr(3 downto 0);
        variable bufLenx16 : t_slv_24_arr(3 downto 0);
        variable bufSampleTemp8bit : t_slv_8_arr(3 downto 0);
        --variable fineDelaySampleOffset, 
        --variable sampleRelative : std_logic_vector(31 downto 0);
        variable LFAABlock_v : std_logic_vector(6 downto 0);
        variable samplesToRead_v, readStartAddr_v : std_logic_vector(4 downto 0);
        
    begin
        if rising_edge(shared_clk) then
        
            ----------------------------------------------------------------------------
            -- write to clear the valid memory (mark the block as invalid).
             
            LFAABlock_v := axi_araddr(19 downto 13);
            axi_arvalidDel1 <= axi_arvalid;
            if ((((axi_araddr(31 downto 30) = ar_currentBuffer) and (axi_araddr(12 downto 9) = "0000") and (unsigned(LFAABlock_v) = 0))) and 
                (axi_arvalid = '1' and axi_arvalidDel1 = '0')) then
                -- Note axi_araddr(31:30) = 1 GByte buffer in the HBM  = valid memory address bits (18:17)
                --      axi_araddr(29:20) = virtual channel            = valid memory address bits (16:7)
                --      axi_araddr(19:13) = LFAA block                 = valid memory address bits (6:0)
                --      axi_araddr(12:0)  = byte within the 8192 byte LFAA block.
                --                          Reads are 512 bytes, so if bits(12:9) = "1111" then this is the last read from this LFAA block.
                -- This clause clears the valid bit :
                --   - For the 13th from the end LFAA block in the previous buffer, on the first memory request to the first LFAA block in the current buffer
                --     (This happens on the reads of current buffer to ensure that all the preload blocks in the previous buffer are cleared,
                --      since large values of the coarse delay may mean the first possible preload LFAA block in previous buffer is not read to preload the filterbanks)
                validMemWrEn <= '1';
                validMemWriteAddr(18 downto 17) <= ar_previousBuffer;
                validMemWriteAddr(16 downto 7) <= axi_araddr(29 downto 20);
                validMemWriteAddr(6 downto 0) <= std_logic_vector(to_unsigned(g_SPS_PACKETS_PER_FRAME - 13,7));
            elsif (((axi_araddr(31 downto 30) = ar_currentBuffer) and (axi_araddr(12 downto 9) = "1111") and (unsigned(LFAABlock_v) < (g_SPS_PACKETS_PER_FRAME-13))) or 
                   ((axi_araddr(31 downto 30) = ar_previousBuffer) and (axi_araddr(12 downto 9) = "1111") and (unsigned(LFAABlock_v) >= (g_SPS_PACKETS_PER_FRAME-13)))) and
                  (axi_arvalid = '1' and axi_arvalidDel1 = '0') then
                -- clear the valid bit
                --   - on the last read from any but the final 23 blocks in this buffer.
                --   - Or the last read from the final 23 blocks of the previous buffer.
                --     (since 23 blocks at the end of the buffer are used to preload the filterbank for the next frame)
                validMemWriteAddr <= axi_araddr(31 downto 13);
                validMemWrEn <= '1';
            else
                validMemWrEn <= '0';
            end if;
            -- Need to delay writing to the valid memory by a few clocks, since we are also reading from the valid memory at the same time.
            -- The write must come after the read.
            validMemWriteAddrDel1 <= validMemWriteAddr;
            validMemWrEnDel1      <= validMemWrEn;
            
            validMemWriteAddrDel2 <= validMemWriteAddrDel1;
            validMemWrEnDel2      <= validMemWrEnDel1;
            
            o_validMemWriteAddr <= validMemWriteAddrDel2;
            o_validMemWrEn <= validMemWrEnDel2;
            
            -----------------------------------------------------------------------------
            -- State machine to evaluate polynomials and store the result in the FIFOs.
            
            if rstInternal = '1' then
                poly_fsm <= done;
            elsif i_readStart = '1' then
                poly_fsm <= start;
                poly_vc_base <= x"0000"; -- first of 4 consecutive virtual channels that are calculated in parallel
                poly_integration <= i_integration; -- in std_logic_vector(31 downto 0); Which integration is this for ?
                poly_ct_frame <= i_currentBuffer;
                Nchannels <= i_Nchannels;
            else
                case poly_fsm is
                    when start =>
                        poly_start <= '1'; -- Start on a batch of 4 polynomials
                        poly_fsm <= wait_done0;
                        
                    -- three wait states so that poly_idle can go low in response to poly_start. 
                    when wait_done0 =>
                        poly_start <= '0';
                        poly_fsm <= wait_done1;
                        
                    when wait_done1 =>
                        poly_start <= '0';
                        poly_fsm <= wait_done2;
                    
                    when wait_done2 =>
                        poly_start <= '0';
                        if poly_idle = '1' then
                            poly_fsm <= check_fifos;
                        end if;
                    
                    when check_fifos =>
                        -- fine delay FIFOs are 1024 deep.
                        -- Coarse delay FIFOs are 32 deep.
                        -- There are 64 fine delays per virtual channel per frame.
                        -- ensure we have space for at least two new sets of virtual channels before getting the next set of delays
                        if ((unsigned(delayFIFO_wrDataCount(0)) < 896) and 
                            (unsigned(coarseFIFO_wrDataCount(0)) < 24)) then
                            poly_fsm <= update_vc;
                        end if;
                        poly_start <= '0';
                        
                    when update_vc =>
                        poly_vc_base <= std_logic_vector(unsigned(poly_vc_base) + 4);
                        poly_fsm <= check_vc;
                        poly_start <= '0';
                        
                    when check_vc =>
                        if (unsigned(poly_vc_base) < unsigned(Nchannels)) then
                            poly_fsm <= start;
                        else
                            poly_fsm <= done;
                        end if;
                        poly_start <= '0';
                    
                    when done =>
                        poly_fsm <= done;
                        poly_start <= '0';
                        
                end case;
            end if;
            
            if i_readStart = '1' and poly_idle = '0' then
                o_bad_readstart <= '1';
            else
                o_bad_readstart <= '0';
            end if;
            
            -----------------------------------------------------------------------------
            -- State machine to read from the shared memory
            readStartDel1 <= i_readStart;
            readStartDel2 <= readStartDel1;
            
            rstDel1 <= i_rst;
            rstDel2 <= rstDel1;
            rstInternal <= rstDel2;
            rstFIFOs <= rstDel1;
            rstFIFOsDel1 <= rstFIFOs;
            
            if rstInternal = '1' then
                ar_fsm <= done;
            elsif i_readStart = '1' then
                -- start generating read addresses.
                ar_fsm <= waitDelaysValid;
                ar_fsm_buffer <= "00";
                ar_virtualChannel <= (others => '0');
                ar_currentBuffer <= i_currentBuffer;
                if i_currentBuffer = "00" then
                    ar_previousBuffer <= "10";
                elsif i_currentBuffer = "01" then
                    ar_previousBuffer <= "00";
                else -- i_currentBuffer = "10" 
                    ar_previousBuffer <= "01";
                end if;
                if i_currentBuffer = "00" then
                    ar_nextBuffer <= "01";
                elsif i_currentBuffer = "01" then
                    ar_nextBuffer <= "10";
                else -- i_currentBuffer = "10" 
                    ar_nextBuffer <= "00";
                end if;
                
                ar_integration <= i_integration;
                ar_NChannels <= i_NChannels;
                ar_clocksPerPacket <= i_clocksPerPacket;
                axi_arvalid <= '0';
            else
                case ar_fsm is
                    ---------------------------------------------------------------------------
                    -- Before reading a group of 4 virtual channels, we have to get the coarse and fine delay information.
                    -- 
                    when waitDelaysValid =>
                        -- wait until the coarse and fine delay signals are valid
                        -- This will take a few hundred clocks for the first set of virtual channels at the start of the readout of a corner turn frame,
                        -- but for the remaining virtual channels the data should already be in the FIFO at this point.
                        if coarseFIFO_empty = "0000" then
                            ar_fsm <= getCoarseDelays0;
                        end if;
                    
                    when getCoarseDelays0 =>
                        ar_fsm <= getCoarseDelays1;
                        
                    when getCoarseDelays1 =>
                        ar_fsm <= getDataIdle;
                        ar_virtualChannel <= std_logic_vector(unsigned(ar_virtualChannel) + 4);
                    
                    ----------------------------------------------------------------------------------
                    -- Read data from HBM
                    --  byte address within a buffer has 
                    --     - bits 12:0 = byte within an LFAA packet (LFAA packets are 8192 bytes)
                    --     - bits 19:13 = packet count within the buffer (up to 32 LFAA packets per buffer)
                    --     - bits 29:20 = virtual channel
                    --     - bits 31:30 = buffer selection
                    
                    when getDataIdle =>
                        -- Check there is space available in the buffers (buffers are 1024 words), and if so then get more data for the buffer with the least amount of data
                        if (unsigned(bufMaxUsed(0)) < 1000) or (unsigned(bufMaxUsed(1)) < 1000) or (unsigned(bufMaxUsed(2)) < 1000) or (unsigned(bufMaxUsed(3)) < 1000) then
                            ar_fsm <= getBufData;
                        end if;
                        
                        if (((unsigned(bufMaxUsed(0)) <= unsigned(bufMaxUsed(1))) or (bufHasMoreSamples(1) = '0')) and 
                            ((unsigned(bufMaxUsed(0)) <= unsigned(bufMaxUsed(2))) or (bufHasMoreSamples(2) = '0')) and
                            ((unsigned(bufMaxUsed(0)) <= unsigned(bufMaxUsed(3))) or (bufHasMoreSamples(3) = '0')) and
                            bufHasMoreSamples(0) = '1') then
                            ar_fsm_buffer <= "00"; -- which buffer to get data for
                        elsif (((unsigned(bufMaxUsed(1)) <= unsigned(bufMaxUsed(2))) or (bufHasMoreSamples(2) = '0')) and 
                               ((unsigned(bufMaxUsed(1)) <= unsigned(bufMaxUsed(3))) or (bufHasMoreSamples(3) = '0')) and
                               bufHasMoreSamples(1) = '1') then
                            ar_fsm_buffer <= "01";
                        elsif (((unsigned(bufMaxUsed(2)) <= unsigned(bufMaxUsed(3))) or bufHasMoreSamples(3) = '0') and 
                               (bufHasMoreSamples(2) = '1')) then
                            ar_fsm_buffer <= "10";
                        else
                            -- At least one buffer must have more samples because otherwise we couldn't have gotten into this state.
                            ar_fsm_buffer <= "11";
                        end if;
                        axi_arvalid <= '0';
                    
                    when getBufData =>  -- "buf0" in the name "getBuf0Data" refers to the particular virtual channel
                        axi_arvalid <= '1';
                        axi_araddr(31 downto 30) <= bufBuffer(to_integer(unsigned(ar_fsm_buffer))); -- which HBM buffer
                        axi_araddr(29 downto 20) <= bufVirtualChannel(to_integer(unsigned(ar_fsm_buffer)));
                        axi_araddr(19 downto 0) <= bufSample(to_integer(unsigned(ar_fsm_buffer)))(17 downto 0) & "00"; -- LFAA packet within the buffer (bits 17:13), sample (bits 12:2), 4 byte aligned (bits 1:0 = "00")
                        axi_arlen(2 downto 0) <= bufLen(to_integer(unsigned(ar_fsm_buffer)));
                        ar_fsm <= waitARReady;
                    
                    when waitARReady =>
                        if i_axi_arready = '1' then
                            axi_arvalid <= '0';
                            ar_fsm <= checkDone;
                        end if;
                        
                    when checkDone => -- check if we have more data to get for each virtual channel
                        if bufHasMoreSamples /= "0000" then
                            ar_fsm <= getDataIdle;
                            ar_fsm_buffer <= "00";
                        else
                            ar_fsm <= checkAllVirtualChannelsDone;
                        end if; 
                    
                    when checkAllVirtualChannelsDone =>
                        if (unsigned(ar_NChannels) > unsigned(ar_virtualChannel)) then
                            -- Note at this point ar_virtualChannel has already been incremented by 4,
                            -- so it points to the next set of virtual channels we are about to start reading.
                            ar_fsm <= waitDelaysValid; -- Get the next group of 4 virtual channels.
                            ar_fsm_buffer <= "00";
                        else
                            ar_fsm <= waitAllDone;
                        end if;
                    
                    when waitAllDone =>
                        -- Wait until the ar_fifo is empty, since we should flag an error is we start up again without draining the fifo.
                        if ARFIFO_WrDataCount = "000000" then 
                            ar_fsm <= done;
                        end if;
                        
                    when done =>
                        ar_fsm <= done;
                        axi_arvalid <= '0';
                        
                    when others =>
                        ar_fsm <= done;
                end case;
            end if;
            
            ar_fsmDel1 <= ar_fsm;
            ar_fsmDel2 <= ar_fsmDel1;
            ar_fsmDel3 <= ar_fsmDel2;
            ar_fsmDel4 <= ar_fsmDel3;
            
            ar_fsm_bufferDel1 <= ar_fsm_buffer;
            ar_fsm_bufferDel2 <= ar_fsm_bufferDel1;
            ar_fsm_bufferDel3 <= ar_fsm_bufferDel2;
            ar_fsm_bufferDel4 <= ar_fsm_bufferDel3;
            
            -- Total space which could be used in the buffers after all pending reads return
            for i in 0 to 3 loop
                bufMaxUsed(i) <= std_logic_vector(unsigned(bufFIFO_wrDataCount(i)) + unsigned(pendingReads(i)));
            end loop;
            
            -- Capture and update the delay information
            for i in 0 to 3 loop
                if ar_fsm = getCoarseDelays0 then
                    bufVirtualChannel(i) <= std_logic_vector(unsigned(ar_virtualChannel) + i);
                    bufCoarseDelay(i) <= coarseFIFO_dout(i)(11) & coarseFIFO_dout(i)(11) & coarseFIFO_dout(i)(11) & coarseFIFO_dout(i)(11) & 
                                         coarseFIFO_dout(i)(11) & coarseFIFO_dout(i)(11) & coarseFIFO_dout(i)(11) & coarseFIFO_dout(i)(11) & coarseFIFO_dout(i)(11 downto 0);
                    bufFirstRead(i) <= '1';
                    bufLastRead(i) <= '0';
                elsif ar_fsm = getCoarseDelays1 then
                    --
                    --  First Frame read from the buffer:
                    --
                    --                                      start of the corner 
                    --                                        turn buffer
                    --                                             |
                    --                                             |
                    --         |<------------------------------12x4096 samples----------------------------->|
                    --         |<--------(6x4096-n) samples------->|<----------(6x4096+n) samples---------->|
                    --         |
                    --    First Sample sent
                    --    = (end of buffer - (6*4096-n))
                    --    = (64*4096 - (6*4096 - n))
                    --    = 237568 + n
                    --  where n = bufCoarseDelay
                    --
                    bufBuffer(i) <= ar_previousBuffer; -- initial reads are the pre-load data from the previous buffer
                    bufSampleTemp(i) := std_logic_vector((g_SPS_PACKETS_PER_FRAME * 2048) - 24576 + unsigned(bufCoarseDelay(i)));
                    bufSampleTemp8bit(i) := '0' & bufSampleTemp(i)(6 downto 0);
                    -- Round it down so we have 64 byte aligned accesses to the HBM. Note buf0Sample is the sample within the buffer for this particular virtual channel
                    bufSample(i) <= bufSampleTemp(i)(19 downto 4) & "0000"; -- This gets multiplied by 4 to get the byte address, so the byte address will be 64 byte aligned.
                    
                    --bufSampleRelative_v(i) := std_logic_vector(unsigned(bufCoarseDelay(i)) - 47104 - (11*4096 - g_FILTER_CENTER)); -- Index of the sample to be read relative to the first sample in the buffer.
                    --bufSampleRelative(i) <= bufSampleRelative_v(i)(19) & bufSampleRelative_v(i)(19) & bufSampleRelative_v(i)(19) & 
                    --                        bufSampleRelative_v(i)(19) & bufSampleRelative_v(i);
                    -- Number of 64 byte words to read.
                    -- First read is chosen such that the remaining reads are aligned to a 512 byte boundary (i.e. 8*64 bytes).
                    -- The 64 byte word we are reading within the current 512 byte block is buf0SampleTemp(6 downto 4)
                    -- so if buf0SampleTemp(6:4) = "000" then length = 8, "001" => 7, "010" => 6, "011" => 5, "100" => 4, "101" => 3, "110" => 2, "111" => 1
                    -- But axi length of "0000" means a length of 1. So buf0SampleTemp(6:4) = "000" -> length = "111", "001" => "110" etc.
                    bufLen(i) <= not bufSampleTemp(i)(6 downto 4);  -- buf0Len = number of beats in the AXI memory transaction - 1.
                    -- Up to 512 bytes per read = up to 128 samples per read (each sample is 4 bytes),
                    -- so the number of samples read is the number to the next 512 byte boundary, i.e. 128 - buf0SampleTemp(6:0)
                    bufSamplesToRead(i) <= std_logic_vector(128 - unsigned(bufSampleTemp8bit(i)));
                    -- total number of samples per frame is g_LFAA_BLOCKS_PER_FRAME * 2048, plus the preload of 11*4096 = 45056 samples
                    bufSamplesRemaining(i) <= std_logic_vector(to_unsigned(g_SPS_PACKETS_PER_FRAME * 2048 + 45056,20)); 
                elsif ((ar_fsm = getBufData) and (unsigned(ar_fsm_buffer) = i)) then
                    -- the "getBufData" state occurs multiple times, once for each buffer.
                    bufSample(i) <= std_logic_vector(unsigned(bufSample(i)) + unsigned(bufLen_ext(i)) + 16);
                    bufSamplesToRead20bit(i) := "000000000000" & bufSamplesToRead(i);
                    bufLenx16(i) := "00000000000000000" & bufLen(i) & "0000";
                    -- bufSampleRelative is the index of the sample corresponding to a 16 sample boundary in the readout in the first data word returned from the HBM
                    -- It is used to determine the fine delay to use. Note +16 here because bufLen is 1 less than the number of beats, and each beat is 16 samples.
                    --bufSampleRelative(i) <= std_logic_vector(signed(bufSampleRelative(i)) + signed(bufLenx16(i)) + 16);  
                    bufSamplesRemaining(i) <= std_logic_vector(unsigned(bufSamplesRemaining(i)) - unsigned(bufSamplesToRead20bit(i)));
                    bufFirstRead(i) <= '0';
                elsif ((ar_fsmDel1 = getBufData) and (unsigned(ar_fsm_bufferDel1) = i)) then  -- Second of two steps to update buf0Sample when we issue a read request
                    if (unsigned(bufSample(i)) = (g_SPS_PACKETS_PER_FRAME * 2048)) then -- i.e. if we have hit the end of the preload buffer, then go to the start of the next buffer.
                        bufSample(i) <= (others => '0');
                        if (bufBuffer(i) = ar_previousBuffer) then
                            bufBuffer(i) <= ar_currentBuffer;
                        else
                            bufBuffer(i) <= ar_nextBuffer;
                        end if;
                    end if;
                    if (unsigned(bufSamplesRemaining(i)) <= 128) then
                        bufLastRead(i) <= '1';
                    end if;
                    if (unsigned(bufSamplesRemaining(i)) < 128) then -- last read can be shorter
                        if bufSamplesRemaining(i)(3 downto 0) = "0000" then
                            bufLen(i) <= std_logic_vector(unsigned(bufSamplesRemaining(i)(6 downto 4)) - 1); -- -1 since axi len is 1 less than number of words requested.
                        else
                            bufLen(i) <= bufSamplesRemaining(i)(6 downto 4); -- Low bits are non zero, so need to do a read to get those as well, hence no -1.
                        end if;
                        bufSamplesToRead(i) <= bufSamplesRemaining(i)(7 downto 0);
                    else
                        bufLen(i) <= "111"; -- 8 beats. 
                        bufSamplesToRead(i) <= "10000000"; -- 128 samples in a full length (8 x 512 bit words) read.
                    end if;                   
                    
                end if;
                
                if (unsigned(bufSamplesRemaining(i)) > 0) then
                    bufHasMoreSamples(i) <= '1';
                else
                    bufHasMoreSamples(i) <= '0';
                end if;                
                
                if ((ar_fsm = getBufData) and (unsigned(ar_fsm_buffer) = i)) then
                    ARFIFO_din(1 downto 0) <= bufBuffer(i); -- Destination buffer
                    ARFIFO_din(2) <= bufFirstRead(i); -- first read for a particular virtual channel
                    ARFIFO_din(3) <= bufLastRead(i);  -- Last read for a particular virtual channel
                    -- Low 4 bits of the Number of valid samples in this read.
                    -- This is only needed for the first and last reads for a given channel.
                    ARFIFO_din(7 downto 4) <= bufSamplesToRead(i)(3 downto 0); 
                    ARFIFO_din(10 downto 8) <= bufLen(i); -- Number of Beats in this read - 1. Range will be 0 to 7. (Note 8 beats = 8 x 512 bits = maximum size of a burst to the HBM)
                    ARFIFO_din(12 downto 11) <= std_logic_vector(to_unsigned(i,2));  -- indicates which stream this is (i.e. the virtual channel loaded in the "getBufData" state)
                end if;
                
            end loop;
            
            if ar_fsm = getBufData then
                ARFIFO_wrEn <= '1';
            else
                ARFIFO_wrEn <= '0';
            end if;
            
            if i_readStart = '1' and ar_fsm /= done then
                -- Flag an error; we were asked to start reading but we haven't finished reading the previous frame.
                o_readOverflow <= '1';
            else
                o_readOverflow <= '0';
            end if;
            
            -- Sample offset from the startpoint sample for the fine delay information 
            -- (i.e. relative to i_startpacket), for the first valid sample in this burst.
            -- 32 bit sample offset means a maximum delay of (2^32 samples) * 1080ns/sample = 4638 seconds
            -- Note this sample offset can be negative.
            --  ar_startPacket is the packet count that the fine delay information is referenced to. 
            --  ar_packetCount is the packet count for the first packet in the current buffer.
            -- So the number we want is 
            --  bufXSampleRelative + ar_packetCount * 2048 - ar_startPacket* 2048;

            -- Keep track of the number of pending read words in the ARFIFO for each buffer
            for i in 0 to 3 loop
                if (i_readStart = '1') then
                    pendingReads(i) <= (others => '0');
                elsif ARFIFO_wrEn = '1' and unsigned(ARFIFO_din(12 downto 11)) = i and (bufFIFO_wrEnDel1(i) = '0') then
                    -- When bufFIFO_wrEnDel1 is high, then the data stops being accounted for in "pendingReads" and is accounted for by bufFIFO_wrDataCount instead. 
                    pendingReads(i) <= std_logic_vector(unsigned(pendingReads(i)) + unsigned(ARFIFO_wrBeats) + 1);  -- ARFIFO_wrBeats is one less than the actual number of beats (as per AXI standard), so add one here.
                elsif (ARFIFO_wrEn = '0' or unsigned(ARFIFO_din(12 downto 11)) /= i) and (bufFIFO_wrEnDel1(i) = '1') then
                    pendingReads(i) <= std_logic_vector(unsigned(pendingReads(i)) - 1);
                elsif (ARFIFO_wrEn = '1' and unsigned(ARFIFO_din(12 downto 11)) = i and bufFIFO_wrEnDel1(i) = '1') then
                    pendingReads(i) <= std_logic_vector(unsigned(pendingReads(i)) + unsigned(ARFIFO_wrBeats) + 1 - 1); -- +1 to make ARFIFO_wrBeats the true number of beats, but -1 because a word got written into the buffer.
                end if;
            end loop;
            
            -- Delay writing to the FIFO until the valid data comes back.
            -- Convert the number of samples to read into an offset to start reading from.
            ARFIFO_dinDel1(3 downto 0) <= ARFIFO_din(3 downto 0);
            samplesToRead_v := '0' & ARFIFO_din(7 downto 4);
            readStartAddr_v := std_logic_vector(16 - unsigned(samplesToRead_v)); -- so, e.g. 1 sample to read = start reading from sample 15.
            ARFIFO_dinDel1(7 downto 4) <= readStartAddr_v(3 downto 0);
            ARFIFO_dinDel1(12 downto 8) <= ARFIFO_din(12 downto 8);
            ARFIFO_dinDel1(15 downto 13) <= "000";
            
            ARFIFO_wrEnDel1 <= ARFIFO_wrEn;  -- ARFIFO_wrEn is valid in the same cycle as o_validMemReadAddr
            
            ARFIFO_dinDel2 <= ARFIFO_dinDel1;
            ARFIFO_wrEnDel2 <= ARFIFO_wrEnDel1;
            
            ARFIFO_dinDel3 <= ARFIFO_dinDel2;
            ARFIFO_wrEnDel3 <= ARFIFO_wrEnDel2;
            
            ARFIFO_dinDel4 <= ARFIFO_dinDel3;
            ARFIFO_wrEnDel4 <= ARFIFO_wrEnDel3;
            
            ARFIFO_dinDel5 <= ARFIFO_dinDel4;
            ARFIFO_wrEnDel5 <= ARFIFO_wrEnDel4;
            
            ARFIFO_dinDel6(12 downto 0) <= ARFIFO_dinDel5(12 downto 0);
            ARFIFO_dinDel6(13) <= i_validMemReadData;
            ARFIFO_dinDel6(15 downto 14) <= "00";
            ARFIFO_wrEnDel6 <= ARFIFO_wrEnDel5;
            if i_validMemReadData = '0' and ARFIFO_wrEnDel5 = '1' then
                -- 5 cycle latency to read the valid memory;
                -- Read address is taken from HBM read address, valid when ARFIFO_wrEn = '1'
                o_dataMissing <= '1'; -- we are reading from somewhere in memory that we haven't written data to.
            else
                o_dataMissing <= '0';
            end if;
            
        end if;
    end process;
    
    bufLen_ext(0) <= "0000000000000" & bufLen(0) & "0000";
    bufLen_ext(1) <= "0000000000000" & bufLen(1) & "0000";
    bufLen_ext(2) <= "0000000000000" & bufLen(2) & "0000";
    bufLen_ext(3) <= "0000000000000" & bufLen(3) & "0000";
    
    -- changed, I think 10:8 is right...
    ARFIFO_wrBeats <= "00000000" & ARFIFO_din(10 downto 8);
    
    -- FIFO for the read requests, so we know which buffer to put the data into when it is returned. (several read requests can be in flight at a time)
    --  Data that goes into this FIFO:  
    --  - bits 1:0   : Selects destination buffer
    --  - bit  2     : First read of a particular virtual channel for this frame (a "frame" is configurable but nominally 283 ms) 
    --  - bit  3     : Last read of a particular virtual channel for this frame
    --  - bits 7:4   : number of valid samples (only applies to first or last reads for a channel)
    --  - bits 10:8  : Number of beats in this read (i.e. number of 512 bit data words to expect)
    --  - bits 15:11 : unused.
    --  - bits 31:16 : HPolDeltaP - fine delay phase shift across the band.
    --  - bits 47:32 : VPolDeltaP - fine delay phase shift across the band.
    --  - bits 63:48 : DeltaDeltaP
    --  - bits 95:64 : Sample offset from the starting sample for the fine delay information. 
    --  - bit  96    : invalid - no data was written to the shared memory, so data returned should be flagged invalid.
    --  - bit  98:97 : Which of the three streams that are simultaneously being read is this one ? "00", "01", "10"
    fifo_ar_inst : xpm_fifo_sync
    generic map (
        DOUT_RESET_VALUE => "0",    -- String
        ECC_MODE => "no_ecc",       -- String
        FIFO_MEMORY_TYPE => "distributed", -- String
        FIFO_READ_LATENCY => 1,     -- DECIMAL
        FIFO_WRITE_DEPTH => 32,     -- DECIMAL; Allow up to 32 outstanding read requests.
        FULL_RESET_VALUE => 0,      -- DECIMAL
        PROG_EMPTY_THRESH => 10,    -- DECIMAL
        PROG_FULL_THRESH => 10,     -- DECIMAL
        RD_DATA_COUNT_WIDTH => 6,   -- DECIMAL
        READ_DATA_WIDTH => 16,     -- DECIMAL
        READ_MODE => "fwft",        -- String
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "1404", -- String  -- bit 2 and bit 10 enables write data count and read data count
                                               -- bit 12 enables the data_valid output.
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 16,    -- DECIMAL
        WR_DATA_COUNT_WIDTH => 6    -- DECIMAL
    )
    port map (
        almost_empty => open,     -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
        almost_full => open,      -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
        data_valid => ARFIFO_validOut, -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
        dbiterr => open,          -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
        dout => ARFIFO_dout,      -- READ_DATA_WIDTH-bit output: Read Data: The output data bus is driven when reading the FIFO.
        empty => ARFIFO_empty,    -- 1-bit output: Empty Flag: When asserted, this signal indicates that- the FIFO is empty.
        full => ARFIFO_full,      -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full.
        overflow => open,         -- 1-bit output: Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected, because the FIFO is full
        prog_empty => open,       -- 1-bit output: Programmable Empty: This signal is asserted when the number of words in the FIFO is less than or equal to the programmable empty threshold value.
        prog_full => open,        -- 1-bit output: Programmable Full: This signal is asserted when the number of words in the FIFO is greater than or equal to the programmable full threshold value.
        rd_data_count => ARFIFO_RdDataCount, -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
        rd_rst_busy => open,      -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
        sbiterr => open,          -- 1-bit output: Single Bit Error: Indicates that the ECC decoder detected and fixed a single-bit error.
        underflow => open,        -- 1-bit output: Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected because the FIFO is empty.
        wr_ack => open,           -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.
        wr_data_count => ARFIFO_WrDataCount, -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        wr_rst_busy => open,      -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
        din => ARFIFO_dinDel6,    -- WRITE_DATA_WIDTH-bit input: Write Data: The input data bus used when writing the FIFO.
        injectdbiterr => '0',     -- 1-bit input: Double Bit Error Injection
        injectsbiterr => '0',     -- 1-bit input: Single Bit Error Injection: 
        rd_en => ARFIFO_rdEn,     -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO. 
        rst => ARFIFO_rst,        -- 1-bit input: Reset: Must be synchronous to wr_clk.
        sleep => '0',             -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
        wr_clk => shared_clk,     -- 1-bit input: Write clock: Used for write operation. wr_clk must be a free running clock.
        wr_en => ARFIFO_wrEnDel6  -- 1-bit input: Write Enable: 
    );
    
    ARFIFO_rst <= rstFIFOs;
    ARFIFO_rdEn <= '1' when ar_regUsed = '0' and i_axi_r.valid = '1' else '0';
    
    process(shared_clk)
    begin
        if rising_edge(shared_clk) then
            -- Process data from the ar fifo ("ar_fifo_inst") as the corresponding data comes back from the shared memory
            -- Write to the buffer and the FIFOs associated with the buffer.
            --  Tasks :
            --   - Read from ar fifo
            --   - compute fine delays for each 512 bit word
            --   - Write to the buffer fifos
            --
            --------------------------------------------------------------------------------------------------
            if i_axi_r.valid = '1' and ar_regUsed = '0' and ARFIFO_validout = '0' then
                -- Error; data returned from memory that we didn't expect
                o_Unexpected_rdata <= '1';
            else
                o_Unexpected_rdata <= '0';
            end if;
            
            if (rstFIFOs = '1' or i_readStart = '1') then
                bufWrAddr0 <= (others => '0');
                bufWrAddr1 <= (others => '0');
                bufWrAddr2 <= (others => '0');
                bufWrAddr3 <= (others => '0');
            elsif i_axi_r.valid = '1' then
                if ((ar_regUsed = '0' and ARFIFO_dout(12 downto 11) = "00") or (ar_regUsed = '1' and rdata_stream = "00")) then
                    bufWrAddr0 <= std_logic_vector(unsigned(bufWrAddr0) + 1);
                end if;
                if ((ar_regUsed = '0' and ARFIFO_dout(12 downto 11) = "01") or (ar_regUsed = '1' and rdata_stream = "01")) then
                    bufWrAddr1 <= std_logic_vector(unsigned(bufWrAddr1) + 1);
                end if;
                if ((ar_regUsed = '0' and ARFIFO_dout(12 downto 11) = "10") or (ar_regUsed = '1' and rdata_stream = "10")) then
                    bufWrAddr2 <= std_logic_vector(unsigned(bufWrAddr2) + 1);
                end if;
                if ((ar_regUsed = '0' and ARFIFO_dout(12 downto 11) = "11") or (ar_regUsed = '1' and rdata_stream = "11")) then
                    bufWrAddr3 <= std_logic_vector(unsigned(bufWrAddr3) + 1);
                end if;
            end if;
            
            -- As data comes back from the memory, generate the fine delays and write to the buffer fifos.
            -- if this is the first beat in the transaction, then fine delay data comes from ar_fifo, 
            -- otherwise the data is the captured version of the fifo output from the first beat.
            if rstFIFOs = '1' or i_readStart = '1' then  
                ar_regUsed <= '0';
            elsif ar_regUsed = '0' and i_axi_r.valid = '1' then
                --rdata_first <= ARFIFO_dout(2);   -- First read of a particular virtual channel for this frame (a "frame" is configurable but nominally 50ms) 
                --rdata_last <= ARFIFO_dout(3);    -- Last read of a particular virtual channel for this frame
                rdata_rdStartOffset <= ARFIFO_dout(7 downto 4);  -- Number of valid samples (only applies to first or last reads for a channel)
                rdata_beats <= ARFIFO_dout(10 downto 8);         -- Number of beats in this read (i.e. number of 512 bit data words to expect); "000" = 1 beat, up to "111" = 8 beats.
                rdata_beatCount <= "001";  -- this value isn't used until the next beat arrives, at which point it matches with the definition of rdata_beats (= total beats - 1).
                if ARFIFO_dout(10 downto 8) = "000" then   -- 10:8 is the number of beats in the read; if it is "000" then there is one beat, so no need to hold over the data in the register.
                    ar_regUsed <= '0';
                else
                    ar_regUsed <= '1';
                end if;
                rdata_dvalid <= ARFIFO_dout(13);
                rdata_stream <= ARFIFO_dout(12 downto 11);
            elsif ar_regUsed = '1' and i_axi_r.valid = '1' then
                rdata_beatCount <= std_logic_vector(unsigned(rdata_beatCount) + 1);
                if rdata_beatCount = rdata_beats then
                    ar_regUsed <= '0';
                end if;
            end if;
            axi_rvalid_del1 <= i_axi_r.valid;
            
            rdata_rdStartOffsetDel2 <= rdata_rdStartOffset;
            rdata_streamDel2 <= rdata_stream;
            axi_rvalid_del2 <= axi_rvalid_del1;
            
            rdata_rdStartOffsetDel3 <= rdata_rdStartOffsetDel2;
            rdata_streamDel3 <= rdata_streamDel2;
            axi_rvalid_del3 <= axi_rvalid_del2;
            
            --
            rdata_rdStartOffsetDel4 <= rdata_rdStartOffsetDel3;
            rdata_streamDel4 <= rdata_streamDel3;
            axi_rvalid_del4 <= axi_rvalid_del3;
            
            -- Scale by 2^-21 and round 
            rdata_rdStartOffsetDel5 <= rdata_rdStartOffsetDel4;
            rdata_streamDel5 <= rdata_streamDel4;
            axi_rvalid_del5 <= axi_rvalid_del4;
            
            rdata_rdStartOffsetDel6 <= rdata_rdStartOffsetDel5;
            rdata_streamDel6 <= rdata_streamDel5;
            axi_rvalid_del6 <= axi_rvalid_del5;
            
            -- 
            rdata_rdStartOffsetDel7 <= rdata_rdStartOffsetDel6;
            rdata_streamDel7 <= rdata_streamDel6;
            axi_rvalid_del7 <= axi_rvalid_del6;
            
            --
            bufFIFO_din(3 downto 0) <= rdata_rdStartOffsetDel7;
            
            if axi_rvalid_del7 = '1' and rdata_streamDel7 = "00" then
                bufFIFO_wrEn(0) <= '1';
            else
                bufFIFO_wrEn(0) <= '0';
            end if;
            if axi_rvalid_del7 = '1' and rdata_streamDel7 = "01" then
                bufFIFO_wrEn(1) <= '1';
            else
                bufFIFO_wrEn(1) <= '0';
            end if;
            if axi_rvalid_del7 = '1' and rdata_streamDel7 = "10" then
                bufFIFO_wrEn(2) <= '1';
            else
                bufFIFO_wrEn(2) <= '0';
            end if;
            if axi_rvalid_del7 = '1' and rdata_streamDel7 = "11" then
                bufFIFO_wrEn(3) <= '1';
            else
                bufFIFO_wrEn(3) <= '0';
            end if;
            
            bufFIFO_wrEnDel1 <= bufFIFO_wrEn;
        end if;
    end process;

    -- FIFOs for the data in the buffer.
    -- A word is written to one of these fifos every time a word is written to the buffer
    -- The read and write size of the FIFO keeps track of the number of valid words in the main buffer.
    bufFifoGen : for i in 0 to 3 generate
        buffer_fifo_inst : xpm_fifo_async
        generic map (
            CDC_SYNC_STAGES => 2,        -- DECIMAL
            DOUT_RESET_VALUE => "0",     -- String
            ECC_MODE => "no_ecc",        -- String
            FIFO_MEMORY_TYPE => "auto", -- String
            FIFO_READ_LATENCY => 0,      -- DECIMAL; has to be zero for first word fall through (READ_MODE => "fwft")
            FIFO_WRITE_DEPTH => 1024,    -- DECIMAL
            FULL_RESET_VALUE => 0,       -- DECIMAL
            PROG_EMPTY_THRESH => 10,     -- DECIMAL
            PROG_FULL_THRESH => 10,      -- DECIMAL
            RD_DATA_COUNT_WIDTH => 11,   -- DECIMAL
            READ_DATA_WIDTH => 4,       -- DECIMAL
            READ_MODE => "fwft",         -- String
            RELATED_CLOCKS => 0,         -- DECIMAL
            SIM_ASSERT_CHK => 0,         -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
            USE_ADV_FEATURES => "0404",  -- String "404" includes read and write data counts.
            WAKEUP_TIME => 0,            -- DECIMAL
            WRITE_DATA_WIDTH => 4,      -- DECIMAL
            WR_DATA_COUNT_WIDTH => 11    -- DECIMAL
        )
        port map (
            almost_empty => open,     -- 1-bit output: Almost Empty
            almost_full => open,      -- 1-bit output: Almost Full
            data_valid => open,       -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
            dbiterr => open,          -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
            dout => bufFIFO_dout(i),   -- READ_DATA_WIDTH-bit output: Read Data.
            empty => bufFIFO_empty(i), -- 1-bit output: Empty Flag: When asserted, this signal indicates that the FIFO is empty
            full => open,             -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full. 
            overflow => open,         -- 1-bit output: Overflow
            prog_empty => open,       -- 1-bit output: Programmable Empty: This signal is asserted when the number of words in the FIFO is less than or equal to the programmable empty threshold value. 
            prog_full => open,        -- 1-bit output: Programmable Full: This signal is asserted when the number of words in the FIFO is greater than or equal to the programmable full threshold value. 
            rd_data_count => bufFIFO_rdDataCount(i), -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count
            rd_rst_busy => open,      -- 1-bit output: Read Reset Busy
            sbiterr => open,          -- 1-bit output: Single Bit Error
            underflow => open,        -- 1-bit output: Underflow
            wr_ack => open,           -- 1-bit output: Write Acknowledge: Iindicates that a write request (wr_en) during the prior clock cycle is succeeded.
            wr_data_count => bufFIFO_wrDataCount(i), -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count
            wr_rst_busy => open,      -- 1-bit output: Write Reset Busy
            din => bufFIFO_din,       -- Same for all FIFOs, since we only write to one fifo at a time. WRITE_DATA_WIDTH-bit input: Write Data; 
            injectdbiterr => '0',     -- 1-bit input: Double Bit Error Injection
            injectsbiterr => '0',     -- 1-bit input: Single Bit Error Injection
            rd_clk => shared_clk,     -- 1-bit input: Read clock: Used for read operation. 
            rd_en => bufFIFO_rdEn(i), -- 1-bit input: Read Enable.
            rst => rstFIFOsDel1,      -- 1-bit input: Reset: Must be synchronous to wr_clk
            sleep => '0',             -- 1-bit input: Dynamic power saving:
            wr_clk => shared_clk,     -- 1-bit input: Write clock:
            wr_en => bufFIFO_wrEn(i)  -- 1-bit input: Write Enable:
        );
        
        -------------------------------------------------------------------------------------
        -------------------------------------------------------------------------------------
        -- fine Delay FIFO - One entry for each block of 4096 output samples
        
        delay_fifo_inst : xpm_fifo_async
        generic map (
            CDC_SYNC_STAGES => 2,        -- DECIMAL
            DOUT_RESET_VALUE => "0",     -- String
            ECC_MODE => "no_ecc",        -- String
            FIFO_MEMORY_TYPE => "block", -- String
            FIFO_READ_LATENCY => 0,      -- DECIMAL; has to be zero for first word fall through (READ_MODE => "fwft")
            FIFO_WRITE_DEPTH => 1024,    -- DECIMAL
            FULL_RESET_VALUE => 0,       -- DECIMAL
            PROG_EMPTY_THRESH => 10,     -- DECIMAL
            PROG_FULL_THRESH => 10,      -- DECIMAL
            RD_DATA_COUNT_WIDTH => 11,   -- DECIMAL
            READ_DATA_WIDTH => 129,       -- DECIMAL
            READ_MODE => "fwft",         -- String
            RELATED_CLOCKS => 0,         -- DECIMAL
            SIM_ASSERT_CHK => 0,         -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
            USE_ADV_FEATURES => "0404",  -- String "404" includes read and write data counts.
            WAKEUP_TIME => 0,            -- DECIMAL
            WRITE_DATA_WIDTH => 129,      -- DECIMAL
            WR_DATA_COUNT_WIDTH => 11    -- DECIMAL
        )
        port map (
            almost_empty => open,     -- 1-bit output: Almost Empty
            almost_full => open,      -- 1-bit output: Almost Full
            data_valid => open,       -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
            dbiterr => open,          -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
            dout => delayFIFO_dout(i),   -- READ_DATA_WIDTH-bit output: Read Data.
            empty => delayFIFO_empty(i), -- 1-bit output: Empty Flag: When asserted, this signal indicates that the FIFO is empty
            full => open,             -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full. 
            overflow => open,         -- 1-bit output: Overflow
            prog_empty => open,       -- 1-bit output: Programmable Empty: This signal is asserted when the number of words in the FIFO is less than or equal to the programmable empty threshold value. 
            prog_full => open,        -- 1-bit output: Programmable Full: This signal is asserted when the number of words in the FIFO is greater than or equal to the programmable full threshold value. 
            rd_data_count => delayFIFO_rdDataCount(i), -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count
            rd_rst_busy => open,      -- 1-bit output: Read Reset Busy
            sbiterr => open,          -- 1-bit output: Single Bit Error
            underflow => open,        -- 1-bit output: Underflow
            wr_ack => open,           -- 1-bit output: Write Acknowledge: Iindicates that a write request (wr_en) during the prior clock cycle is succeeded.
            wr_data_count => delayFIFO_wrDataCount(i), -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count
            wr_rst_busy => open,      -- 1-bit output: Write Reset Busy
            din => delayFIFO_din,     -- Same for all FIFOs, since we only write to one fifo at a time. WRITE_DATA_WIDTH-bit input: Write Data; 
            injectdbiterr => '0',     -- 1-bit input: Double Bit Error Injection
            injectsbiterr => '0',     -- 1-bit input: Single Bit Error Injection
            rd_clk => shared_clk,     -- 1-bit input: Read clock: Used for read operation. 
            rd_en => delayFIFO_rdEn(i), -- 1-bit input: Read Enable.
            rst => rstFIFOsDel1,      -- 1-bit input: Reset: Must be synchronous to wr_clk
            sleep => '0',             -- 1-bit input: Dynamic power saving:
            wr_clk => shared_clk,     -- 1-bit input: Write clock:
            wr_en => delayFIFO_wrEn(i)  -- 1-bit input: Write Enable:
        );        
        
        -- Coarse Delay FIFO - One entry for each virtual channel per corner turn frame
        coarse_delay_fifo_inst : xpm_fifo_async
        generic map (
            CDC_SYNC_STAGES => 2,        -- DECIMAL
            DOUT_RESET_VALUE => "0",     -- String
            ECC_MODE => "no_ecc",        -- String
            FIFO_MEMORY_TYPE => "distributed", -- String
            FIFO_READ_LATENCY => 0,      -- DECIMAL; has to be zero for first word fall through (READ_MODE => "fwft")
            FIFO_WRITE_DEPTH => 32,    -- DECIMAL
            FULL_RESET_VALUE => 0,       -- DECIMAL
            PROG_EMPTY_THRESH => 10,     -- DECIMAL
            PROG_FULL_THRESH => 10,      -- DECIMAL
            RD_DATA_COUNT_WIDTH => 6,   -- DECIMAL
            READ_DATA_WIDTH => 32,       -- DECIMAL
            READ_MODE => "fwft",         -- String
            RELATED_CLOCKS => 0,         -- DECIMAL
            SIM_ASSERT_CHK => 0,         -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
            USE_ADV_FEATURES => "0404",  -- String "404" includes read and write data counts.
            WAKEUP_TIME => 0,            -- DECIMAL
            WRITE_DATA_WIDTH => 32,      -- DECIMAL
            WR_DATA_COUNT_WIDTH => 6     -- DECIMAL
        )
        port map (
            almost_empty => open,     -- 1-bit output: Almost Empty
            almost_full => open,      -- 1-bit output: Almost Full
            data_valid => open,       -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
            dbiterr => open,          -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
            dout => coarseFIFO_dout(i),   -- READ_DATA_WIDTH-bit output: Read Data.
            empty => coarseFIFO_empty(i), -- 1-bit output: Empty Flag: When asserted, this signal indicates that the FIFO is empty
            full => open,             -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full. 
            overflow => open,         -- 1-bit output: Overflow
            prog_empty => open,       -- 1-bit output: Programmable Empty: This signal is asserted when the number of words in the FIFO is less than or equal to the programmable empty threshold value. 
            prog_full => open,        -- 1-bit output: Programmable Full: This signal is asserted when the number of words in the FIFO is greater than or equal to the programmable full threshold value. 
            rd_data_count => open, -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count
            rd_rst_busy => open,      -- 1-bit output: Read Reset Busy
            sbiterr => open,          -- 1-bit output: Single Bit Error
            underflow => open,        -- 1-bit output: Underflow
            wr_ack => open,           -- 1-bit output: Write Acknowledge: Iindicates that a write request (wr_en) during the prior clock cycle is succeeded.
            wr_data_count => coarseFIFO_wrDataCount(i), -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count
            wr_rst_busy => open,      -- 1-bit output: Write Reset Busy
            din => coarseFIFO_din,       -- Same for all FIFOs, since we only write to one fifo at a time. WRITE_DATA_WIDTH-bit input: Write Data; 
            injectdbiterr => '0',     -- 1-bit input: Double Bit Error Injection
            injectsbiterr => '0',     -- 1-bit input: Single Bit Error Injection
            rd_clk => shared_clk,     -- 1-bit input: Read clock: Used for read operation. 
            rd_en => coarseFIFO_rdEn(i), -- 1-bit input: Read Enable.
            rst => rstFIFOsDel1,      -- 1-bit input: Reset: Must be synchronous to wr_clk
            sleep => '0',             -- 1-bit input: Dynamic power saving:
            wr_clk => shared_clk,     -- 1-bit input: Write clock:
            wr_en => coarseFIFO_wrEn(i)  -- 1-bit input: Write Enable:
        );
        
    end generate;
    
    -- sample shift is negative of sample delay. Or something like that.
    delay_offset_inv <= (not delay_offset);
    delay_offset_neg <= std_logic_vector(signed(delay_offset_inv) + 1);
    
    process(shared_clk)
    begin
        if rising_edge(shared_clk) then
            delayFIFO_din(31 downto 0) <= delay_Hpol_deltaP;
            delayFIFO_din(63 downto 32) <= delay_Vpol_deltaP;
            delayFIFO_din(95 downto 64) <= delay_Hpol_phase;
            delayFIFO_din(127 downto 96) <= delay_Vpol_phase;
            delayFIFO_din(128) <= bad_poly;
            --delayFIFO_din(143 downto 128) <= delay_vc;  -- Just a sanity check, fifo read and write order should be ensure that the correct virtual channel goes to the correct output
            --delayFIFO_din(151 downto 144) <= delay_packet(7 downto 0); -- packet within the corner turn frame
            if delay_valid = '1' then
                if delay_vc(1 downto 0) = "00" then
                    delayFIFO_wrEn <= "0001";
                elsif delay_vc(1 downto 0) = "01" then
                    delayFIFO_wrEn <= "0010";
                elsif delay_vc(1 downto 0) = "10" then
                    delayFIFO_wrEn <= "0100";
                else
                    delayFIFO_wrEn <= "1000";
                end if;
            else
                delayFIFO_wrEn <= "0000";
            end if;
            
            coarseFIFO_din(11 downto 0) <= delay_offset_neg;
            coarseFIFO_din(27 downto 12) <= delay_vc;
            coarseFIFO_din(31 downto 28) <= "0000";
            if (delay_valid = '1' and (unsigned(delay_packet) = 0)) then
                if delay_vc(1 downto 0) = "00" then
                    coarseFIFO_wrEn <= "0001";
                elsif delay_vc(1 downto 0) = "01" then
                    coarseFIFO_wrEn <= "0010";
                elsif delay_vc(1 downto 0) = "10" then
                    coarseFIFO_wrEn <= "0100";
                else
                    coarseFIFO_wrEn <= "1000";
                end if;
            else
                coarseFIFO_wrEn <= "0000";
            end if;
            
            if ar_fsm = getCoarseDelays0 then
                coarseFIFO_rdEn <= "1111";
            else
                coarseFIFO_rdEn <= "0000";
            end if;
            
        end if;
    end process;
    
    
    --bufWrAddr <= 
    --    "00" & bufWrAddr0 when ((ar_regUsed = '0' and ARFIFO_dout(12 downto 11) = "00") or (ar_regUsed = '1' and rdata_stream = "00")) else
    --    "01" & bufWrAddr1 when ((ar_regUsed = '0' and ARFIFO_dout(12 downto 11) = "01") or (ar_regUsed = '1' and rdata_stream = "01")) else
    --    "10" & bufWrAddr2; --  when ((ar_regUsed = '0' and ARFIFO_dout(12 downto 11) = "10") or (ar_regUsed = '1' and rdata_stream = "10"))
    --bufWE(0) <= i_axi_rvalid;
    --bufWrData <= 
    --    i_axi_rdata   when ((ar_regUsed = '0' and ARFIFO_dout(13) = '1') or (ar_regUsed = '1' and rdata_dvalid = '1')) else 
    --    x"80808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080";
        
    -- improve timing : Register the input to the main buffer memory.
    -- This makes placement easier, since the memory can end up being placed in a different SLR to the HBM
    process(shared_clk)
    begin
        if rising_edge(shared_clk) then
            if ((ar_regUsed = '0' and ARFIFO_dout(12 downto 11) = "00") or (ar_regUsed = '1' and rdata_stream = "00")) then
                bufWrAddr <= "00" & bufWrAddr0;
            elsif ((ar_regUsed = '0' and ARFIFO_dout(12 downto 11) = "01") or (ar_regUsed = '1' and rdata_stream = "01")) then
                bufWrAddr <= "01" & bufWrAddr1;
            elsif ((ar_regUsed = '0' and ARFIFO_dout(12 downto 11) = "10") or (ar_regUsed = '1' and rdata_stream = "10")) then
                bufWrAddr <= "10" & bufWrAddr2;
            else
                bufWrAddr <= "11" & bufWrAddr3;
            end if;
            bufWE(0) <= i_axi_r.valid;
            axi_rdataDel1 <= i_axi_r.data;
            if ((ar_regUsed = '0' and ARFIFO_dout(13) = '1') or (ar_regUsed = '1' and rdata_dvalid = '1')) then
                selRFI <= '0';
            else
                selRFI <= '1';
            end if;
        end if;
    end process;
    
    bufWrData <= axi_rdataDel1 when selRFI = '0' else x"80808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080";
    
    -- Memory to buffer data coming back from the shared memory.
    -- both sides are 4096 deep by 512 wide
    main_buffer_inst : xpm_memory_sdpram
    generic map (    
        -- Common module generics
        MEMORY_SIZE             => 2097152,        -- Total memory size in bits; 4096 x 512 = 2097152
        MEMORY_PRIMITIVE        => "ultra",        --string; "auto", "distributed", "block" or "ultra" ;
        CLOCKING_MODE           => "common_clock", --string; "common_clock", "independent_clock" 
        MEMORY_INIT_FILE        => "none",         --string; "none" or "<filename>.mem" 
        MEMORY_INIT_PARAM       => "",             --string;
        USE_MEM_INIT            => 0,              --integer; 0,1
        WAKEUP_TIME             => "disable_sleep",--string; "disable_sleep" or "use_sleep_pin" 
        MESSAGE_CONTROL         => 0,              --integer; 0,1
        ECC_MODE                => "no_ecc",       --string; "no_ecc", "encode_only", "decode_only" or "both_encode_and_decode" 
        AUTO_SLEEP_TIME         => 0,              --Do not Change
        USE_EMBEDDED_CONSTRAINT => 0,              --integer: 0,1
        MEMORY_OPTIMIZATION     => "true",         --string; "true", "false" 
    
        -- Port A module generics
        WRITE_DATA_WIDTH_A      => 512,            --positive integer
        BYTE_WRITE_WIDTH_A      => 512,            --integer; 8, 9, or WRITE_DATA_WIDTH_A value
        ADDR_WIDTH_A            => 12,             --positive integer
    
        -- Port B module generics
        READ_DATA_WIDTH_B       => 512,            --positive integer
        ADDR_WIDTH_B            => 12,             --positive integer
        READ_RESET_VALUE_B      => "0",            --string
        READ_LATENCY_B          => 3,              --non-negative integer
        WRITE_MODE_B            => "read_first")    --string; "write_first", "read_first", "no_change" 
    port map (
        -- Common module ports
        sleep                   => '0',
        -- Port A (Write side)
        clka                    => shared_clk,  -- clock for the shared memory, 300 MHz
        ena                     => '1',
        wea                     => bufWE,
        addra                   => bufWrAddr,
        dina                    => bufWrData,
        injectsbiterra          => '0',
        injectdbiterra          => '0',
        -- Port B (read side)
        clkb                    => shared_clk,  -- Filterbank clock, also 300 MHz.
        rstb                    => '0',
        enb                     => '1',
        regceb                  => '1',
        addrb                   => bufRdAddr,
        doutb                   => bufDout,
        sbiterrb                => open,
        dbiterrb                => open
    );

    --------------------------------------------------------------------------------------------
    --------------------------------------------------------------------------------------------
    -- Evaluation of the polynomials to get the delays 
    poly_vc(0) <= poly_vc_base; -- in t_slv_16_arr((g_VIRTUAL_CHANNELS-1) downto 0); List of virtual channels to evaluate; this maps to the address in the lookup table.
    poly_vc(1) <= poly_vc_base(15 downto 2) & "01";
    poly_vc(2) <= poly_vc_base(15 downto 2) & "10";
    poly_vc(3) <= poly_vc_base(15 downto 2) & "11";
    
    
    poly_delays : entity ct_lib.poly_eval
    generic map (
        -- Number of virtual channels to generate in at a time, code supports up to 16
        -- Code assumes at least 4, otherwise it would need extra delays to wait for data to return from the memory. 
        g_VIRTUAL_CHANNELS => 4 -- : integer range 4 to 16 := 4 
    ) port map (
        clk  => shared_clk, -- in std_logic;
        -- First output after a reset will reset the data generation
        i_rst => rstInternal, --  in std_logic;
        -- Control
        i_start            => poly_start, -- in std_logic; Start on a batch of 4 polynomials
        i_virtual_channels => poly_vc, -- in t_slv_16_arr((g_VIRTUAL_CHANNELS-1) downto 0); List of virtual channels to evaluate; this maps to the address in the lookup table.
        i_integration      => poly_integration, -- in std_logic_vector(31 downto 0); Which integration is this for ?
        i_ct_frame         => poly_ct_frame, -- in std_logic_vector(1 downto 0);  3 corner turn frames per integration
        o_idle             => poly_idle, -- out std_logic;
        
        -- read the config memory (to get polynomial coefficients)
        -- Block ram interface for access by the rest of the module
        -- Memory is 20480 x 8 byte words = (2 buffers) x (10240 words) = (1024 virtual channels) x (10 words)
        -- read latency 3 clocks
        o_rd_addr  => o_delayTableAddr, -- out (14:0);
        i_rd_data  => i_delayTableData, -- in (63:0);  -- 3 clock latency.
        
        -----------------------------------------------------------------------
        -- Output delay parameters 
        -- For each pulse on i_start, this module generates 64*4 = 256 outputs
        -- in bursts of 4 outputs. (4 virtual channels, 64 time samples)
        --
        -- For each virtual channel :
        --  - Virtual channel. 15 bits. Copy of one of the i_poly entries
        --  - packet count. 8 bits. Counts from 0 to 63 for the 64 output packets generated by the correlator 
        --                          per 283ms corner turn frame. 
        --  - Coarse delay : 11 bits. Number of 1080ns samples to delay by
        --  - bufHpolDeltaP : 16 bits. Delay as a phase step across the coarse channel
        --  - bufHpolPhase  : 16 bits. Phase offset for H pol
        --  - bufVpolDeltaP : 16 bits. Delay as a phase step across the coarse channel
        --  - bufVpolPhase  : 16 bits. Phase offset for V pol
        o_vc     => delay_vc, -- out std_logic_vector(15 downto 0);
        o_packet => delay_packet, -- out std_logic_vector(15 downto 0);
        --
        o_sample_offset => delay_offset, -- out std_logic_vector(11 downto 0); -- Number of whole 1080ns samples to delay by.
        -- Units for deltaP are rotations; 1 sign bit, 15 fractional bits. + 16 extra fractional bits
        -- So pi radians at the band edge = 16384 * 65536
        -- As a fraction of a coarse sample, 1 coarse sample = pi radian at the band edge = 16384 * 65536
        --                                   0.5 coarse samples = pi/2 radians at the band edge = 8192 * 65536
        o_Hpol_deltaP => delay_Hpol_deltaP, -- out std_logic_vector(31 downto 0);
        -- Phase uses 32768 * 65536 to represent pi radians. Note this differs by a factor of 2 compared with Hpol_deltaP.
        o_Hpol_phase => delay_Hpol_phase, -- out std_logic_vector(31 downto 0);
        o_Vpol_deltaP => delay_Vpol_deltaP, -- out std_logic_vector(31 downto 0);
        o_Vpol_phase  => delay_Vpol_phase, -- out std_logic_vector(31 downto 0);
        o_bad_poly    => bad_poly,         -- out std_logic; No valid polynomial was found.
        o_valid       => delay_valid,      -- out std_logic
        
        ----------------------------------------------------------------------
        -- Debug Data, valid on o_valid
        o_poly_result => poly_result, --  out std_logic_vector(63 downto 0);
        o_poly_time   => poly_time,   --  out std_logic_vector(63 downto 0);
        o_buffer_select => poly_buffer_select, --  out std_logic;
        o_integration => dbg_poly_integration,  -- out std_logic_vector(31 downto 0); -- 32 bits
        o_ct_frame    => dbg_poly_ct_frame,     -- out std_logic_vector(1 downto 0);  -- 2 bits
        o_uptime      => poly_uptime        -- out std_logic_vector(47 downto 0)  -- 48 bits, count of 300 MHz clocks.        
    );

     -- Generate a 256 bit word to write to the debug ILA
    process(shared_clk)
    begin
        if rising_edge(shared_clk) then
            
            dbg_valid <= delay_valid;
            dbg_vec(31 downto 0) <= poly_uptime(39 downto 8);
            dbg_vec(41 downto 32) <= delay_vc(9 downto 0);
            dbg_vec(47 downto 42) <= delay_packet(5 downto 0);
            dbg_vec(63 downto 48) <= "0000" & delay_offset;
            dbg_vec(95 downto 64) <= delay_Hpol_phase;
            dbg_vec(127 downto 96) <= delay_Hpol_deltaP;
            dbg_vec(159 downto 128) <= dbg_poly_integration(29 downto 0) & dbg_poly_ct_frame;
            dbg_vec(175 downto 160) <= poly_buffer_select & "0000" & delayFIFO_wrDataCount(0);
            dbg_vec(191 downto 176) <= x"0000"; -- to be used for other signals at the higher level.
            dbg_vec(223 downto 192) <= x"00000000";
            dbg_vec(255 downto 224) <= x"00000000";
            
            dbg_vec_del1 <= dbg_vec;
            dbg_valid_del1 <= dbg_valid;
            
            dbg_vec_del2 <= dbg_vec_del1;
            dbg_valid_del2 <= dbg_valid_del1;
            
            o_dbg_vec(191 downto 0) <= dbg_vec_del2(191 downto 0);
            o_dbg_vec(223 downto 192) <= poly_result_fp32;
            o_dbg_vec(255 downto 224) <= poly_time_fp32;
            o_dbg_valid <= dbg_valid_del2;
            
        end if;
    end process;
    
    fp64_to_fp32_1i : fp64_to_fp32
    port map (
        aclk => shared_clk,
        s_axis_a_tvalid => delay_valid,
        s_axis_a_tdata => poly_result,
        m_axis_result_tvalid => fp32_delay_valid,
        m_axis_result_tdata => poly_result_fp32
    );

    fp64_to_fp32_2i : fp64_to_fp32
    port map (
        aclk => shared_clk,
        s_axis_a_tvalid => delay_valid,
        s_axis_a_tdata  => poly_time,
        m_axis_result_tvalid => fp32_delay_valid2,
        m_axis_result_tdata => poly_time_fp32
    );

    --------------------------------------------------------------------------------------------
    -- Signals that control readout to the filterbank:
    --   - Via buffer (dual port memory) 
    --               - sample data
    --   - Via FIFOs (one word for every word in the buffer)
    --               - fine delays (VDeltaP, HDeltaP)
    --               - Number of valid samples in each word in the memory
    --   - Via cdc macro, at the start of every frame (i.e. when reading out a new buffer)
    --               - 32 bit timestamp for the first packet output
    --               - Number of clocks per 64 sample output packet
    --               - Number of virtual channels
    --   (- Generic : g_LFAA_BLOCKS_PER_FRAME - There are 2048 samples per LFAA block, 
    --    so the total number of 64 sample output packets in a buffer is (2048/64) * g_LFAA_BLOCKS_PER_FRAME = 32 * g_LFAA_BLOCKS_PER_FRAME.)
    -- 
    -- Readout of the data is triggered by data being passed across the cdc macro.
    -- Notes:
    --   - Notation:
    --        - "Frame", all the data in a single 1024 Mbyte buffer, about 283 ms worth for all virtual channels
    --        - "burst", all frame data for a set of 4 virtual channels, since 4 virtual channels are output at a time.
    --            * There are ceil(virtual_channels/4) bursts per frame.
    --        - "packet", a block of 4096 samples, for 4 virtual channels (or less in the final burst of the frame, if the number of virtual channels is not a multiple of 4).
    --            * Total number of packets per burst is 
    --               packets_per_burst = g_LFAA_BLOCKS_PER_FRAME/2 + 11 
    --               (note 11*4096 = 45056 = the number of preload samples)
    --   - There are 16 samples in a single buffer entry, so the number of entries in the buffer per burst per virtual channel is either:
    --         packets_per_burst * 4096/16 = g_LFAA_BLOCKS_PER_FRAME*128 + 11*256       (for the case where the first sample is aligned to a 64 byte boundary)
    --     or                                g_LFAA_BLOCKS_PER_FRAME*128 + 11*256 + 1   (for the case where the first sample is not aligned to a 64 byte boundary)
    --
    
    cdc_dataIn(15 downto 0) <= "0000" & ar_NChannels; -- 12 bit
    cdc_dataIn(31 downto 16) <= x"0056" when (unsigned(ar_clocksPerPacket) < 86) else ar_clocksPerPacket;   -- 16 bit; minimum possible value is 86.
    cdc_dataIn(63 downto 32) <= ar_integration;       -- 32 bit
    cdc_dataIn(65 downto 64) <= ar_currentBuffer;     -- 2 bit

    
    process(shared_clk)
    begin
        if rising_edge(shared_clk) then
            if readStartDel1 = '1' and readStartDel2 = '0' then
                shared_to_FB_send <= '1';
            elsif shared_to_FB_rcv = '1' then
                shared_to_FB_send <= '0';
            end if;
        end if;
    end process;
    
    --------------------------------------------------------------------------
    -- This was originally a clock domain crossing, but for the correlator we 
    -- are using the HBM clock for the filterbank.
    -- The signals are kept the same as for the xpm_cdc_handshake component so that the output clock could be changed easily if needed.
    process(shared_clk)
    begin
        if rising_edge(shared_clk) then
            if shared_to_FB_send = '1' then
                cdc_dataOut <= cdc_dataIn;
                shared_to_FB_valid <= '1';
            else
                shared_to_FB_valid <= '0';
            end if;
            shared_to_FB_send_del1 <= shared_to_FB_send;
        end if;
    end process;
    shared_to_FB_rcv <= '1';
    
    --------------------------------------------------------------------------
    
    -- Memory readout 
    process(shared_clk)
    begin
        if rising_edge(shared_clk) then
            if shared_to_FB_send_del1 = '1' then
                -- This happens once per corner turn frame (i.e. once per 283 ms)
                FBintegration <= cdc_dataOut(63 downto 32);  -- Packet count at the start of the frame, output as meta data.
                FBctFrame <= cdc_dataOut(65 downto 64);
                FBClocksPerPacket <= cdc_dataOut(31 downto 16);         -- Number of FB clock cycles per output packet
                FBNChannels <= cdc_dataOut(15 downto 0);                -- Number of virtual channels to read for the frame
            end if;
            
            shared_to_FB_valid_del1 <= shared_to_FB_valid;
            
            
            if rstInternal = '1' then
                bufReadAddr0 <= (others => '0');
                bufReadAddr1 <= (others => '0');
                bufReadAddr2 <= (others => '0');
                bufReadAddr3 <= (others => '0');
                channelCount <= (others => '0');
                rd_fsm <= idle;
                buf0RdEnable <= '0';
                buf1RdEnable <= '0';
                buf2RdEnable <= '0';
                buf3RdEnable <= '0';
                bufFIFO_rdEn(0) <= '0';
                bufFIFO_rdEn(1) <= '0';
                bufFIFO_rdEn(2) <= '0';
                bufFIFO_rdEn(3) <= '0';
                sof <= '0';
                sofFull <= '0';
            elsif shared_to_FB_valid_del1 = '1' then
                -- Start reading out the data from the buffer.
                -- This occurs once per frame (typically 282 ms).
                -- Buffers are always emptied at the end of a frame, so we always start from 0.
                bufReadAddr0 <= (others => '0');
                bufReadAddr1 <= (others => '0');
                bufReadAddr2 <= (others => '0');
                bufReadAddr3 <= (others => '0');
                channelCount <= (others => '0');
                --rd_fsm <= rd_start;
                rd_fsm <= reset_output_fifos_start;
                buf0RdEnable <= '0';
                buf1RdEnable <= '0';
                buf2RdEnable <= '0';
                buf3RdEnable <= '0';
                bufFIFO_rdEn(0) <= '0';
                bufFIFO_rdEn(1) <= '0';
                bufFIFO_rdEn(2) <= '0';
                bufFIFO_rdEn(3) <= '0';
                sofFull <= '1';
            else
                case rd_fsm is
                    when idle =>
                        rd_fsm <= idle;
                        buf0RdEnable <= '0';
                        buf1RdEnable <= '0';
                        buf2RdEnable <= '0';
                        sof <= '0';
                        sofFull <= '0';
                    
                    when rd_start => -- start of reading for a particular group of 4 channels.
                        -- wait until data is available in the buffer, and get the start address from the FIFOs
                        if bufFIFOHalfFull = "1111" and delayFIFO_empty = "0000" then -- all four fifos have plenty of data; so readout won't result in underflow.
                            sof <= '1';
                            -- The buffer is 64 bytes wide, so to align the data 
                            -- we have to choose which of the 16 samples in a 64-byte word to start at
                            rdOffset(0) <= bufFIFO_dout(0)(3 downto 0);
                            rdOffset(1) <= bufFIFO_dout(1)(3 downto 0);
                            rdOffset(2) <= bufFIFO_dout(2)(3 downto 0);
                            rdOffset(3) <= bufFIFO_dout(3)(3 downto 0);
                            -- The number of 64-byte (=512 bit) words that we have to read from the buffer for each channel is 
                            --      g_LFAA_BLOCKS_PER_FRAME*128 + 11*256       (for the case where the first sample is aligned to a 64 byte boundary)
                            --   or g_LFAA_BLOCKS_PER_FRAME*128 + 11*256 + 1   (for the case where the first sample is not aligned to a 64 byte boundary)                            
                            --
                            if bufFIFO_dout(0)(3 downto 0) = "0000" then
                                buf0WordsRemaining <= std_logic_vector(to_unsigned(g_SPS_PACKETS_PER_FRAME*128 + 2816,16));
                            else
                                buf0WordsRemaining <= std_logic_vector(to_unsigned(g_SPS_PACKETS_PER_FRAME*128 + 2817,16));
                            end if;
                            if bufFIFO_dout(1)(3 downto 0) = "0000" then
                                buf1WordsRemaining <= std_logic_vector(to_unsigned(g_SPS_PACKETS_PER_FRAME*128 + 2816,16));
                            else
                                buf1WordsRemaining <= std_logic_vector(to_unsigned(g_SPS_PACKETS_PER_FRAME*128 + 2817,16));
                            end if;
                            if bufFIFO_dout(2)(3 downto 0) = "0000" then
                                buf2WordsRemaining <= std_logic_vector(to_unsigned(g_SPS_PACKETS_PER_FRAME*128 + 2816,16));
                            else
                                buf2WordsRemaining <= std_logic_vector(to_unsigned(g_SPS_PACKETS_PER_FRAME*128 + 2817,16));
                            end if;
                            
                            if bufFIFO_dout(3)(3 downto 0) = "0000" then
                                buf3WordsRemaining <= std_logic_vector(to_unsigned(g_SPS_PACKETS_PER_FRAME*128 + 2816,16));
                            else
                                buf3WordsRemaining <= std_logic_vector(to_unsigned(g_SPS_PACKETS_PER_FRAME*128 + 2817,16));
                            end if;
                            
                            rd_fsm <= rd_buf0;
                        else
                            sof <= '0';
                        end if;
                        buf0RdEnable <= '0';
                        buf1RdEnable <= '0';
                        buf2RdEnable <= '0';
                        buf3RdEnable <= '0';
                    
                    when rd_buf0 =>
                        rd_fsm <= rd_buf1;
                        sof <= '0';
                        sofFull <= '0';
                        bufRdAddr <= "00" & bufReadAddr0;  -- buffer 0 is the first 1/4 of the buffer, 1024 x 64 byte words.
                        if (rdStop(0) = '0' and buf0ReadDone = '0') then
                            bufReadAddr0 <= std_logic_vector(unsigned(bufReadAddr0) + 1);
                            buf0WordsRemaining <= std_logic_vector(unsigned(buf0WordsRemaining) - 1);
                            buf0RdEnable <= '1';
                        else
                            buf0RdEnable <= '0';
                        end if;
                        buf1RdEnable <= '0';
                        buf2RdEnable <= '0';
                        buf3RdEnable <= '0';
                        
                    when rd_buf1 =>
                        rd_fsm <= rd_buf2;
                        sof <= '0';
                        sofFull <= '0';
                        bufRdAddr <= "01" & bufReadAddr1;
                        if (rdStop(1) = '0' and buf1ReadDone = '0') then
                            bufReadAddr1 <= std_logic_vector(unsigned(bufReadAddr1) + 1);
                            buf1WordsRemaining <= std_logic_vector(unsigned(buf1WordsRemaining) - 1);
                            buf1RdEnable <= '1';
                        else
                            buf1RdEnable <= '0';
                        end if;
                        buf0RdEnable <= '0';
                        buf2RdEnable <= '0';
                        buf3RdEnable <= '0';
                        
                    when rd_buf2 =>
                        rd_fsm <= rd_buf3;
                        sof <= '0';
                        sofFull <= '0';
                        bufRdAddr <= "10" & bufReadAddr2;
                        if (rdStop(2) = '0' and buf2ReadDone = '0') then
                            bufReadAddr2 <= std_logic_vector(unsigned(bufReadAddr2) + 1);
                            buf2WordsRemaining <= std_logic_vector(unsigned(buf2WordsRemaining) - 1);
                            buf2RdEnable <= '1';
                        else
                            buf2RdEnable <= '0';
                        end if;
                        buf0RdEnable <= '0';
                        buf1RdEnable <= '0';
                        buf3RdEnable <= '0';

                    when rd_buf3 =>
                        rd_fsm <= rd_wait;
                        rd_wait_count <= "1011";
                        sof <= '0';
                        sofFull <= '0';
                        bufRdAddr <= "11" & bufReadAddr3;
                        if (rdStop(3) = '0' and buf3ReadDone = '0') then
                            bufReadAddr3 <= std_logic_vector(unsigned(bufReadAddr3) + 1);
                            buf3WordsRemaining <= std_logic_vector(unsigned(buf3WordsRemaining) - 1);
                            buf3RdEnable <= '1';
                        else
                            buf3RdEnable <= '0';
                        end if;
                        buf0RdEnable <= '0';
                        buf1RdEnable <= '0';                    
                        buf2RdEnable <= '0';
                    
                    when rd_wait => 
                        -- Tightest loop involves rd_buf0 -> rd_buf1 -> rd_buf2 -> rd_buf3 -> rd_wait -> rd_buf0 ... .
                        -- The rd_wait state is needed to ensure we don't send data to the output fifos more than 1 in every 16 clocks.
                        sof <= '0';
                        sofFull <= '0';
                        if rd_wait_count /= "0000" then
                            rd_wait_count <= std_logic_vector(unsigned(rd_wait_count) - 1);
                        else
                            if (buf0ReadDone = '1' and buf1ReadDone = '1' and buf2ReadDone = '1' and buf3ReadDone = '1' and allPacketsSent = '1') then 
                                -- Finished a full coarse channel (actually 4 coarse channels, since 4 channels are sent at a time).
                                -- Wait here until all the output packets have been sent so we can reset the output FIFOs before starting the next coarse channel.
                                rd_fsm <= reset_output_fifos;
                            elsif ((rdStop(0) = '0' and buf0ReadDone = '0') or 
                                   (rdStop(1) = '0' and buf1ReadDone = '0') or
                                   (rdStop(2) = '0' and buf2ReadDone = '0') or 
                                   (rdStop(3) = '0' and buf3ReadDone = '0')) then  -- space is available in at least one of the output FIFOs
                                rd_fsm <= rd_buf0;
                            end if;
                        end if;
                        buf0RdEnable <= '0';
                        buf1RdEnable <= '0';
                        buf2RdEnable <= '0';
                        buf3RdEnable <= '0';
                    
                    when reset_output_fifos =>
                        sof <= '0';
                        sofFull <= '0';
                        rd_fsm <= reset_output_fifos_wait1;
                        channelCount <= std_logic_vector(unsigned(channelCount) + 4);
                        buf0RdEnable <= '0';
                        buf1RdEnable <= '0';
                        buf2RdEnable <= '0';
                        buf3RdEnable <= '0';
                    
                    when reset_output_fifos_start => -- this is just for the first group of 4 channels that are read out from the buffer. 
                        rd_fsm <= reset_output_fifos_wait1;
                    
                    when reset_output_fifos_wait1 =>
                        rd_fsm <= reset_output_fifos_wait2;
                        buf0RdEnable <= '0';
                        buf1RdEnable <= '0';
                        buf2RdEnable <= '0';
                        buf3RdEnable <= '0';
                        sof <= '0';
                        
                    when reset_output_fifos_wait2 =>
                        rd_fsm <= reset_output_fifos_wait;
                        buf0RdEnable <= '0';
                        buf1RdEnable <= '0';
                        buf2RdEnable <= '0';
                        buf3RdEnable <= '0';
                        sof <= '0';
                                            
                    when reset_output_fifos_wait =>
                        -- wait until the output fifos have finished reset.
                        if rstBusy = "0000" then
                            if (unsigned(channelCount) >= unsigned(FBNChannels)) then
                                rd_fsm <= idle;
                            else
                                rd_fsm <= rd_start;
                            end if;
                        end if;
                        buf0RdEnable <= '0';
                        buf1RdEnable <= '0';
                        buf2RdEnable <= '0';
                        buf3RdEnable <= '0';
                        sof <= '0';
                        
                    when others =>
                        rd_fsm <= idle;
                end case;
                
                -- Read the fifos whenever we read from the associated buffer.
                bufFIFO_rdEn(0) <= buf0RdEnable;
                bufFIFO_rdEn(1) <= buf1RdEnable;
                bufFIFO_rdEn(2) <= buf2RdEnable;
                bufFIFO_rdEn(3) <= buf3RdEnable;
                
            end if;
            
            for i in 0 to 3 loop
                if (unsigned(bufFIFO_rdDataCount(i)) > 256) then
                    -- 256 words in the buffer, 64 bytes per word = 16 kbytes = 4096 samples = 1 packet to the correlator filterbank.
                    bufFIFOHalfFull(i) <= '1';
                else
                    bufFIFOHalfFull(i) <= '0';
                end if;
            end loop;
            
            if (unsigned(buf0WordsRemaining) = 0) and (rd_fsm /= rd_start) then
                buf0ReadDone <= '1';
            else
                buf0ReadDone <= '0';
            end if;
            
            if (unsigned(buf1WordsRemaining) = 0) and (rd_fsm /= rd_start) then
                buf1ReadDone <= '1';
            else
                buf1ReadDone <= '0';
            end if;
            
            if (unsigned(buf2WordsRemaining) = 0) and (rd_fsm /= rd_start) then
                buf2ReadDone <= '1';
            else
                buf2ReadDone <= '0';
            end if;
            
            if (unsigned(buf3WordsRemaining) = 0) and (rd_fsm /= rd_start) then
                buf3ReadDone <= '1';
            else
                buf3ReadDone <= '0';
            end if;
            
            buf0RdEnableDel1 <= buf0RdEnable;
            buf1RdEnableDel1 <= buf1RdEnable;
            buf2RdEnableDel1 <= buf2RdEnable;
            buf3RdEnableDel1 <= buf3RdEnable;
            
            buf0RdEnableDel2 <= buf0RdEnableDel1;
            buf1RdEnableDel2 <= buf1RdEnableDel1;
            buf2RdEnableDel2 <= buf2RdEnableDel1;
            buf3RdEnableDel2 <= buf3RdEnableDel1;
            
            bufRdValid(0) <= buf0RdEnableDel2;
            bufRdValid(1) <= buf1RdEnableDel2;
            bufRdValid(2) <= buf2RdEnableDel2;
            bufRdValid(3) <= buf3RdEnableDel2;
            
            if rstInternal = '1' or rd_fsm = reset_output_fifos or rd_fsm = reset_output_fifos_start then
                readOutRst <= '1';
            else
                readOutRst <= '0';
            end if;
            
            -- Wait until data has got into the final fifo and then start the readout to the filterbanks
            -- There are 
            -- = (g_LFAA_BLOCKS_PER_FRAME / 2 + 11) 4096-sample packets per frame (per channel)
            if (rd_fsm = rd_start and bufFIFOHalfFull = "1111") then
                readoutStart <= '1';
            else
                readoutStart <= '0';
            end if;
            
            readoutStartDel(0) <= readoutStart;
            readoutStartDel(27 downto 1) <= readoutStartDel(26 downto 0);
            
            FBClocksPerPacketMinusTwo <= std_logic_vector(unsigned(FBClocksPerPacket) - 2);
            if (unsigned(clockCount) < (unsigned(FBClocksPerPacketMinusTwo))) then
                clockCountIncrement <= '1';
            else
                clockCountIncrement <= '0';
            end if;
            
            -- 16 clocks to copy data into the FIFO in corr_ct1_readout_32bit
            -- plus some extra delay for read latency of the buffer in this module 
            -- and read latency of the FIFO.
            if (rstInternal = '1') then
                packetsRemaining <= (others => '0');
                clockCount <= (others => '0');
                clockCountZero <= '1';
                delayFIFO_rden <= "0000";
            elsif readoutStartDel(27) = '1' then
                -- Packets are 4096 samples; Number of packets in a burst is 11 preload packets plus half the number of LFAA blocks per frame, since LFAA blocks are 2048 samples.
                packetsRemaining <= std_logic_vector(to_unsigned(g_SPS_PACKETS_PER_FRAME /2 + 11,16));
                clockCount <= (others => '0');
                clockCountZero <= '1';
                delayFIFO_rden <= "0000";

                o_meta0.HDeltaP <= delayFIFO_dout(0)(31 downto 0);
                o_meta0.VDeltaP <= delayFIFO_dout(0)(63 downto 32);
                o_meta0.HoffsetP <= delayFIFO_dout(0)(95 downto 64);
                o_meta0.VoffsetP <= delayFIFO_dout(0)(127 downto 96);
                o_meta0.bad_poly <= delayFIFO_dout(0)(128);
                    
                o_meta1.HDeltaP <= delayFIFO_dout(1)(31 downto 0);
                o_meta1.VDeltaP <= delayFIFO_dout(1)(63 downto 32);
                o_meta1.HoffsetP <= delayFIFO_dout(1)(95 downto 64);
                o_meta1.VoffsetP <= delayFIFO_dout(1)(127 downto 96);
                o_meta1.bad_poly <= delayFIFO_dout(1)(128);
                    
                o_meta2.HDeltaP <= delayFIFO_dout(2)(31 downto 0);
                o_meta2.VDeltaP <= delayFIFO_dout(2)(63 downto 32);
                o_meta2.HoffsetP <= delayFIFO_dout(2)(95 downto 64);
                o_meta2.VoffsetP <= delayFIFO_dout(2)(127 downto 96);
                o_meta2.bad_poly <= delayFIFO_dout(2)(128);
                  
                o_meta3.HDeltaP <= delayFIFO_dout(3)(31 downto 0);
                o_meta3.VDeltaP <= delayFIFO_dout(3)(63 downto 32);
                o_meta3.HoffsetP <= delayFIFO_dout(3)(95 downto 64);
                o_meta3.VoffsetP <= delayFIFO_dout(3)(127 downto 96);  
                o_meta3.bad_poly <= delayFIFO_dout(3)(128);
                
            elsif (unsigned(packetsRemaining) > 0) then
                -- Changed to improve timing, was : if (unsigned(clockCount) < (unsigned(FBClocksPerPacketMinusOne))) then
                if clockCountIncrement = '1' or clockCountZero = '1' then
                    clockCount <= std_logic_vector(unsigned(clockCount) + 1);
                    clockCountZero <= '0';  -- This signal is needed because of the extra cycle latency before clockCountIncrement becomes valid when clockCount is set to zero. 
                    delayFIFO_rden <= "0000";
                else
                    clockCount <= (others => '0');
                    clockCountZero <= '1';
                       
                    o_meta0.HDeltaP <= delayFIFO_dout(0)(31 downto 0);
                    o_meta0.VDeltaP <= delayFIFO_dout(0)(63 downto 32);
                    o_meta0.HoffsetP <= delayFIFO_dout(0)(95 downto 64);
                    o_meta0.VoffsetP <= delayFIFO_dout(0)(127 downto 96);
                    o_meta0.bad_poly <= delayFIFO_dout(0)(128);
                    
                    o_meta1.HDeltaP <= delayFIFO_dout(1)(31 downto 0);
                    o_meta1.VDeltaP <= delayFIFO_dout(1)(63 downto 32);
                    o_meta1.HoffsetP <= delayFIFO_dout(1)(95 downto 64);
                    o_meta1.VoffsetP <= delayFIFO_dout(1)(127 downto 96);
                    o_meta1.bad_poly <= delayFIFO_dout(1)(128);
                    
                    o_meta2.HDeltaP <= delayFIFO_dout(2)(31 downto 0);
                    o_meta2.VDeltaP <= delayFIFO_dout(2)(63 downto 32);
                    o_meta2.HoffsetP <= delayFIFO_dout(2)(95 downto 64);
                    o_meta2.VoffsetP <= delayFIFO_dout(2)(127 downto 96);
                    o_meta2.bad_poly <= delayFIFO_dout(2)(128);
                    
                    o_meta3.HDeltaP <= delayFIFO_dout(3)(31 downto 0);
                    o_meta3.VDeltaP <= delayFIFO_dout(3)(63 downto 32);
                    o_meta3.HoffsetP <= delayFIFO_dout(3)(95 downto 64);
                    o_meta3.VoffsetP <= delayFIFO_dout(3)(127 downto 96);
                    o_meta3.bad_poly <= delayFIFO_dout(3)(128);                    
                    
                    packetsRemaining <= packetsRemaining_minus1;
                    if ((unsigned(packetsRemaining_minus1) <= (g_SPS_PACKETS_PER_FRAME/2)) and
                        (some_packets_remaining = '1')) then
                        -- At the point where this happens, actual packetsRemaining is one less than "packetsRemaining"
                        delayFIFO_rden <= "1111";
                    else
                        delayFIFO_rden <= "0000";
                    end if;
                end if;
            else
                delayFIFO_rden <= "0000";
            end if;
            
            packetsRemaining_minus1 <= std_logic_vector(unsigned(packetsRemaining) - 1);
            if (unsigned(packetsRemaining_minus1) > 0) then 
                some_packets_remaining <= '1';
            else
                some_packets_remaining <= '0';
            end if;
            
            if ((unsigned(packetsRemaining) > 0) and (unsigned(clockCount) < 4096)) then
                readPacket <= '1';
            else
                readPacket <= '0';
            end if;
            
            if (unsigned(packetsRemaining) = 0) then
                allPacketsSent <= '1';
            else
                allPacketsSent <= '0';
            end if;
            
            meta0VirtualChannel <= channelCount;
            meta1VirtualChannel <= std_logic_vector(unsigned(channelCount) + 1);
            meta2VirtualChannel <= std_logic_vector(unsigned(channelCount) + 2);
            meta3VirtualChannel <= std_logic_vector(unsigned(channelCount) + 3);
            
            if (unsigned(meta0VirtualChannel) < unsigned(FBNChannels)) then
                o_meta0.valid <= '1';
            else
                o_meta0.valid <= '0';
            end if;
            if (unsigned(meta1VirtualChannel) < unsigned(FBNChannels)) then
                o_meta1.valid <= '1';
            else
                o_meta1.valid <= '0';
            end if;
            if (unsigned(meta2VirtualChannel) < unsigned(FBNChannels)) then
                o_meta2.valid <= '1';
            else
                o_meta2.valid <= '0';
            end if;
            if (unsigned(meta3VirtualChannel) < unsigned(FBNChannels)) then
                o_meta3.valid <= '1';
            else
                o_meta3.valid <= '0';
            end if;
            if ((unsigned(meta3VirtualChannel)+1) >= unsigned(FBNChannels)) then
                o_lastChannel <= '1';
            else
                o_lastChannel <= '0';
            end if;
            o_sofFull <= sof and sofFull;
            
        end if;
    end process;
    
    o_sof <= sof;
    
    outputFifoGen : for i in 0 to 3 generate
        outfifoInst: entity ct_lib.corr_ct1_readout_32bit
        Port map(
            i_clk => shared_clk,
            i_rst => readOutRst, -- in std_logic;  -- Drive this high for one clock between each virtual channel.
            o_rstBusy => rstBusy(i), --  out std_logic;
            -- Data in from the buffer
            i_data => bufDout, -- in std_logic_vector(511 downto 0); --
            -- data in from the FIFO that shadows the buffer
            i_rdOffset => rdOffset(i), -- in std_logic_vector(1 downto 0);  -- Sample offset in the 128 bit word; 0 = use all 4 samples, "01" = Skip first sample, "10" = skip 2 samples, "11" = skip 3 samples; Only used on the first 128 bit word after i_rst.
            i_valid    => bufRdValid(i), -- in std_logic; -- should go high no more than once every 4 clocks
            o_stop     => rdStop(i), -- out std_logic;
            -- data out
            o_data    => readoutData(i),    -- out std_logic_vector(31 downto 0); 
            i_run     => readPacket,        -- in std_logic -- should go high for a burst of 64 clocks to output a packet.
            o_valid   => validOut(i)        -- out std_logic;
        );
    end generate;
    
    o_valid <= validOut(0);
    
    o_HPol0(0) <= readoutData(0)(7 downto 0);  -- 8 bit real part
    o_HPol0(1) <= readoutData(0)(15 downto 8); -- 8 bit imaginary part
    o_VPol0(0) <= readoutData(0)(23 downto 16); -- 8 bit real part
    o_VPol0(1) <= readoutData(0)(31 downto 24); -- 8 bit imaginary part
    
    o_meta0.integration <= FBintegration; -- (31:0); integration in units of 849ms relative to the epoch.
    o_meta0.ctFrame <= FBctFrame;
    o_meta0.virtualChannel <= meta0VirtualChannel;     -- virtualChannel(15:0) = Virtual channels are processed in order, so this just counts.
    
    o_HPol1(0) <= readoutData(1)(7 downto 0);  -- 8 bit real part
    o_HPol1(1) <= readoutData(1)(15 downto 8); -- 8 bit imaginary part
    o_VPol1(0) <= readoutData(1)(23 downto 16); -- 8 bit real part
    o_VPol1(1) <= readoutData(1)(31 downto 24); -- 8 bit imaginary part
    o_meta1.integration <= FBintegration;
    o_meta1.ctFrame <= FBctFrame;
    o_meta1.virtualChannel <= meta1VirtualChannel;
    
    o_HPol2(0) <= readoutData(2)(7 downto 0);  -- 8 bit real part
    o_HPol2(1) <= readoutData(2)(15 downto 8); -- 8 bit imaginary part
    o_VPol2(0) <= readoutData(2)(23 downto 16); -- 8 bit real part
    o_VPol2(1) <= readoutData(2)(31 downto 24); -- 8 bit imaginary part
    o_meta2.integration <= FBintegration;
    o_meta2.ctFrame <= FBctFrame;
    o_meta2.virtualChannel <= meta2VirtualChannel;
    
    o_HPol3(0) <= readoutData(3)(7 downto 0);  -- 8 bit real part
    o_HPol3(1) <= readoutData(3)(15 downto 8); -- 8 bit imaginary part
    o_VPol3(0) <= readoutData(3)(23 downto 16); -- 8 bit real part
    o_VPol3(1) <= readoutData(3)(31 downto 24); -- 8 bit imaginary part
    o_meta3.integration <= FBintegration;
    o_meta3.ctFrame <= FBctFrame;
    o_meta3.virtualChannel <= meta3VirtualChannel;
    
end Behavioral;
