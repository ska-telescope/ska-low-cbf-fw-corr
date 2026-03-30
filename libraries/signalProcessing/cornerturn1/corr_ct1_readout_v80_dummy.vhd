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

library IEEE, xpm, common_lib, ct_lib, DSP_top_lib, axi4_lib, signal_processing_common;
use IEEE.STD_LOGIC_1164.ALL;
use xpm.vcomponents.all;
use IEEE.NUMERIC_STD.ALL;
USE common_lib.common_pkg.ALL;
use DSP_top_lib.DSP_top_pkg.ALL;
use axi4_lib.axi4_full_pkg.ALL;
use signal_processing_common.target_fpga_pkg.ALL;

entity corr_ct1_readout_v80 is
    generic (
        -- Number of SPS PACKETS per frame. 128 = 283 ms corner turn frame.
        -- 32 is also supported by this module, for use in simulation only.
        g_SPS_PACKETS_PER_FRAME : integer := 128;
        -- center tap of the filterbank FIR filter.
        g_FILTER_CENTER : integer := 23598;
        --
        g_RIPPLE_PRELOAD : integer := 15;
        g_RIPPLE_POSTLOAD : integer := 15;
        g_GENERATE_ILA    : BOOLEAN := False
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
        -- Polynomial configuration :
        -- 2 buffers, 10 words per buffer
        --  - U55c version 1024 virtual channels = 20480 words; 
        --  - V80 version 3072 virtual channels, 61440 words;
        o_delayTableAddr : out std_logic_vector(15 downto 0);
        i_delayTableData : in std_logic_vector(63 downto 0);   -- Data from the delay table with 3 cycle latency. 
        -- RFI threshold for this channel.
        o_RFI_rd_addr : out std_logic_vector(11 downto 0);
        i_RFI_rd_data : in std_logic_vector(31 downto 0);
        -- Read and write to the valid memory, to check the place we are reading from in the HBM has valid data
        o_validMemReadAddr : out std_logic_vector(20 downto 0); -- 8192 bytes per LFAA packet, 9 GBytes of memory, so 9 Gbytes/8192 bytes = 1,179,648 
        i_validMemReadData : in std_logic;  -- read data returned 5 clocks later.
        o_validMemWriteAddr : out std_logic_vector(20 downto 0); -- write always clears the memory (mark the block as invalid).
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
        o_readoutData : out t_slv_32_arr(11 downto 0);  -- 32 bits per virtual channel, consisting of 8+8 bit complex values with 2 polarisations
        o_meta_delays         : out t_CT1_META_delays_arr(11 downto 0); -- defined in DSP_top_pkg.vhd; fields are : HDeltaP(31:0), VDeltaP(31:0), HOffsetP(31:0), VOffsetP(31:0), bad_poly (std_logic)
        o_meta_RFIThresholds  : out t_slv_32_arr(11 downto 0);
        o_meta_integration    : out std_logic_vector(31 downto 0);
        o_meta_ctFrame        : out std_logic_vector(1 downto 0); 
        o_meta_virtualChannel : out std_logic_vector(11 downto 0); -- first virtual channel output, remaining 3 (U55c) or 11 (V80) are o_meta_VC+1, +2, etc.
        o_meta_valid          : out std_logic_vector(11 downto 0); -- Total number of virtual channels need not be a multiple of 12, so individual valid signals here.
        o_lastChannel : out std_logic; -- Aligns with o_metaX
        o_valid : out std_logic;
        -------------------------------------------------------------------------
        -- AXI read address and data input buses
        -- ar bus - read address
        o_axi_ar      : out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_axi_arready : in std_logic; 
        -- r bus - read data
        i_axi_r       : in  t_axi4_full_data;
        o_axi_rready  : out std_logic;
        -- Second interface, only used for the v80 version
        o_axi2_ar      : out t_axi4_full_addr; -- (.valid, .addr(39:0), .len(7:0))
        i_axi2_arready : in std_logic;
        -- r bus - read data
        i_axi2_r       : in  t_axi4_full_data;
        o_axi2_rready  : out std_logic;
        -------------------------------------------------------------------------
        -- errors and debug
        -- Flag an error; we were asked to start reading but we haven't finished reading the previous frame.
        o_readOverflow : out std_logic;     -- Pulses high in the shared_clk domain.
        o_Unexpected_rdata : out std_logic; -- data was returned from the HBM that we didn't expect (i.e. no read request was put in for it)
        o_dataMissing : out std_logic;      -- Read from a HBM address that we haven't written data to. Most reads are 8 beats = 8*64 = 512 bytes, so this will go high 16 times per missing LFAA packet.
        o_bad_readstart : out std_logic;    -- read start occured prior to delay calculation finishing for the previous read.
        o_dFIFO_underflow : out std_logic_vector(11 downto 0); -- Read of output fifos but they were empty
        -- Debug data
        o_dbg_vec : out std_logic_vector(255 downto 0);
        o_dbg_valid : out std_logic;
        -- mismatch between output and expected when sending debug data inserted in lfaaIngest
        o_dbgCheckData : out t_slv_32_arr(11 downto 0);  -- expected
        o_dbgBadData   : out t_slv_32_arr(11 downto 0);  -- actual first time it doesnt match expected
        o_mismatch_set : out std_logic_vector(11 downto 0);
        i_reset_mismatch : in std_logic        
    );
end corr_ct1_readout_v80;

architecture Behavioral of corr_ct1_readout_v80 is
    
begin
    
    o_axi_ar.len(7 downto 4) <= "0000";  -- Never ask for more than 16 x 32 byte words.
    o_axi_ar.len(3 downto 0) <= "0000"; -- axi_arlen(3 downto 0);
    o_axi_rready <= '1';
    o_axi_ar.valid <= '0'; -- axi_arvalid0;
    o_axi_ar.addr <= (others => '0');

    o_axi2_ar.len(7 downto 4) <= "0000";  -- Never ask for more than 16 x 32 byte words.
    o_axi2_ar.len(3 downto 0) <= "0000"; --axi_arlen(3 downto 0);
    o_axi2_rready <= '1';
    o_axi2_ar.valid <= '0';
    o_axi2_ar.addr <= (others => '0');
    
    o_validMemReadAddr <= (others => '0');
    
end Behavioral;
