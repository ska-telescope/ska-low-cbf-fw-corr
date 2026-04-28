----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: Jan 2025 (based on u55c version)
-- Module Name: corr_ct2_top_v80.vhd
-- Description: 
--    Corner turn between the filterbanks and the correlator for SKA correlator processing. 
-- 
-- Data coming in from the filterbanks :
--   12 dual-pol channels, with burst of 3456 fine channels at a time.
--   Total number of bytes per clock coming in is (12 channels)*(2 pol)*(2 complex) = 48 bytes.
--   with roughly 3456 out of every 4096 clocks active.
--   Total data rate in is thus roughly (48 bytes * 8 bits)*3456/4096 * 300 MHz = 97.2 Gb/sec (This is the average data rate while data is flowing)
--   The long term average data rate in is (3456/4096 fine channels used) * (1/1080ns sampling period) * (32 bits/sample) * (3072 channels) = 76.8 Gb/sec 
--
-- Storing to HBM and incoming ultraRAM buffering
--   Data is written to the HBM in blocks of (16 times) * (1 fine [226 Hz] channels) * (4 stations) * (2 pol) * (2 bytes/sample) = 256 bytes.
--
--   This requires double buffering in ultraRAM in this module of 16 time samples from the filterbanks.
--   So we have a buffer which is (2 (double buffer)) * (16 times) * (12 virtual channels) * (2 pol) * (3456 fine channels) * (2 complex) * (1 byte/sample) = 5184 kBytes = 162 ultraRAMs.
--
--   The ultraRAM buffer is constructed from 12 pieces, each of which is (128 bits wide) * (7x4096 deep)
--     - Each piece is thus 14 ultraRAMs.
--     - Total ultraRAMs used = 12*14 = 168
--     - Even and odd indexed fine channels are dealt with separately, with their own HBM interface
--     - Data layout in the ultraRAM buffer for even-indexed fine channels :
--     
--      | WrEn="000000000001" | WrEn="000000000010" | WrEn="000000000100" | WrEn="000000001000" | WrEn="000000010000"  | WrEn="000000100000"  |   <-- Write enable vector for the memory blocks (for even indexed channels)
--      |128 bits = 4 channels|
--      |  * 2 pol * 2 complex|
-- Addr |---------------------|---------------------|---------------------|---------------------|----------------------|----------------------|
--      |    InputBuf0        |    InputBuf1        |    InputBuf2        |    InputBuf3        |   buf 4              |  buf 5               |
--      |<-------128 bits---->|<-----128 bits------>|<-----128 bits------>|<-----128 bits------>|<-------128 bits----->|<--------128 bits---->|  ---                                -----------
-- 28159|  fine 3454, t=12    |  fine 3454, t=13    |  fine 3454, t=14    |  fine 3454, t=15    |                      |                      |   |                                 second half 
--      |                     |                     |                     |                     |                      |                      |  13824 words                        of double buffer
--      |                     |                     |                     |                     |                      |                      |   |
--      |                     |                     |                     |                     |                      |                      |   |                                 Starts at address 14336
-- 14336|                     |                     |                     |                     |                      |                      |   |                              
-- skip |---------------------|---------------------|---------------------|---------------------|----------------------|----------------------|-------------------------------------------------------------
-- 13823|fine 3454,t=14,ch0-3 |fine 3454,t=15,ch0-3 |fine 3454,t=14,ch4-7 |fine 3454,t=15,ch4-7 |fine 3454,t=14,ch8-11 |fine 3454,t=15,ch8-11 |                      
--      |                     |                     |                     |                     |                      |                      |                                     First half
--      |                     |                     |                     |                     |                      |                      |                                     of double buffer
--      |                     |                     |                     |                     |                      |                      |                                     (13824 words)            
--      |        ...          |        ...          |        ...          |           ...       |                      |                      |
--      |---------------------|---------------------|---------------------|---------------------|----------------------|----------------------|  ----
--  15  | fine=2,t=14,chan0-3 | fine=2,t=15,chan0-3 | fine=2,t=14,chan4-7 | fine=2,t=15,chan4-7 | fine=2,t=14,chan8-11 | fine=2,t=15,chan8-11 | 
-- ...  |        ...          |        ...          |          ...        |        ...          |           ...        |                      | HBM packets for fine channel 2          
--  8   | fine=2,t=0,chan0-3  | fine=2,t=1,chan0-3  | fine=2,t=0,chan4-7  | fine=2,t=1,chan4-7  | fine=2,t=0,chan8-11  | fine=2,t=1,chan8-11  |                                     Total 1728 packets of 8 words each = 13824 words
--      |---------------------|---------------------|---------------------|---------------------|----------------------|----------------------|  ----
--  7   | fine=0,t=14,chan0-3 | fine=0,t=15,chan0-3 | fine=0,t=14,chan4-7 | fine=0,t=15,chan4-7 | fine=0,t=14,chan8-11 | fine=0,t=15,chan8-11 |
--  6   | fine=0,t=12,chan0-3 | fine=0,t=13,chan0-3 | fine=0,t=12,chan4-7 | fine=0,t=13,chan4-7 | fine=0,t=12,chan8-11 | fine=0,t=13,chan8-11 |
--  5   | fine=0,t=10,chan0-3 | fine=0,t=11,chan0-3 | fine=0,t=10,chan4-7 | fine=0,t=11,chan4-7 | fine=0,t=10,chan8-11 | fine=0,t=11,chan8-11 |
--  4   | fine=0,t=8,chan0-3  | fine=0,t=9,chan0-3  | fine=0,t=8,chan4-7  | fine=0,t=9,chan4-7  | fine=0,t=8,chan8-11  | fine=0,t=9,chan8-11  | HBM packets for fine channel 0 
--  3   | fine=0,t=6,chan0-3  | fine=0,t=7,chan0-3  | fine=0,t=6,chan4-7  | fine=0,t=7,chan4-7  | fine=0,t=6,chan8-11  | fine=0,t=7,chan8-11  |
--  2   | fine=0,t=4,chan0-3  | fine=0,t=5,chan0-3  | fine=0,t=4,chan4-7  | fine=0,t=5,chan4-7  | fine=0,t=4,chan8-11  | fine=0,t=5,chan8-11  |
--  1   | fine=0,t=2,chan0-3  | fine=0,t=3,chan0-3  | fine=0,t=2,chan4-7  | fine=0,t=3,chan4-7  | fine=0,t=2,chan8-11  | fine=0,t=3,chan8-11  |
--  0   | fine=0,t=0,chan0-3  | fine=0,t=1,chan0-3  | fine=0,t=0,chan4-7  | fine=0,t=1,chan4-7  | fine=0,t=0,chan8-11  | fine=0,t=1,chan8-11  |
--      |---------------------|---------------------|---------------------|---------------------|----------------------|----------------------|  ---                                ---------- 
--      |<------------ 1 burst to HBM ------------->|<------------1 HBM burst------------------>|<---------------1 HBM burst----------------->|             
--               (256 bit wide HBM interface)
--
--   As data comes into this module, it is written to the ultraRAM buffer in 128 bit words.
--   i.e. data for one fine channel and 4 channels is written to one of the four ultraRAM blocks (inputBut0, inputBuf1, inputBuf2, inputBuf3)
--   Blocks of 8 words in the buffer make up a block written to the HBM.
--   One 512-bit word = 64 bytes = (1 fine channel) * (4 times) * (4 virtual channels) * (2 pol) * (2 bytes/sample)
--
-- HBM addressing :
--   Data is written on 512 byte boundaries.
--   This corner turn uses 2 x 3Gbyte HBM buffers.
--   Each  3Gbyte HBM buffer has space for :
--      - 512 virtual channels
--        - 3456 fine channels per virtual channel
--      - 384 time samples = double buffered 192 time samples (192 time samples = 384 LFAA packets at the input to the filterbank = 849.3466 ms)
--        (so 192 time samples (=849ms) is being read out while the next 192 time samples are being written)
--      - 2 pol,
--   Data is written to the memory in 512 byte blocks, where each block has :
--      - 1 fine channel, 4 virtual channels, 2 pol, 32 times.
--   So:
--     - 32 bit address needed to address 3 Gbytes:
--      - bits 8:0 = address within a  512 byte data block written in a single burst to the HBM
--      - Higher order address bits are determined depending on the subarray-beam table entries.
--        Data is packed into HBM first by station, then by fine channel, then by time block (1 time block = 32 time samples)
----------------------------------------------------------------------------------
library IEEE, ct_lib, DSP_top_lib, common_lib, axi4_lib;
Library xpm, correlator_lib, noc_lib, signal_processing_common;

use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use DSP_top_lib.DSP_top_pkg.all;
use common_lib.common_pkg.ALL;
use axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.ALL;
use ct_lib.corr_ct2_reg_pkg.all;
use xpm.vcomponents.all;
use signal_processing_common.target_fpga_pkg.ALL;

entity corr_ct2_top_v80 is
    generic (
        g_USE_META          : boolean := FALSE; -- Put meta data into the memory in place of the actual data, to make it easier to find bugs in the corner turn. 
        g_MAX_CORRELATORS   : integer := 6;     -- Maximum number of correlator cells that can be instantiated.
        g_GENERATE_ILA      : BOOLEAN := FALSE
    );
    port(
        -- Registers AXI Lite Interface (uses i_axi_clk)
        i_axi_clk  : in std_logic;
        i_axi_rst  : in std_logic;
        -- Pipelined reset from first stage corner turn
        i_rst : in std_logic;   -- First data received after this reset is placed in the first 283ms block in a 849 ms integration.
        -- Registers NOC interface
        i_noc_wren    : in STD_LOGIC;
        i_noc_rden    : in STD_LOGIC;
        i_noc_wr_adr  : in STD_LOGIC_VECTOR(17 DOWNTO 0);
        i_noc_wr_dat  : in STD_LOGIC_VECTOR(31 DOWNTO 0);
        i_noc_rd_adr  : in STD_LOGIC_VECTOR(17 DOWNTO 0);
        o_noc_rd_dat  : out STD_LOGIC_VECTOR(31 DOWNTO 0);
        -------------------------------------------------------------------------------------
        -- hbm reset
        o_hbm_reset_c1      : out std_logic;
        i_hbm_status_c1     : in std_logic_vector(7 downto 0);
        o_hbm_reset_c2      : out std_logic;
        i_hbm_status_c2     : in std_logic_vector(7 downto 0);
        ------------------------------------------------------------------------------------
        -- Data in from the correlator filterbanks; bursts of 3456 clocks for each channel.
        -- (on i_axi_clk)
        i_sof          : in std_logic; -- pulse high at the start of every frame. (1 frame is 283 ms of data).
        i_integration  : in std_logic_vector(31 downto 0); -- frame count is the same for all simultaneous output streams.
        i_ctFrame      : in std_logic_vector(1 downto 0);  -- 283 ms frame within each integration interval
        i_virtualChannel : in t_slv_16_arr(11 downto 0);   -- 12 virtual channels, one for each of the data streams.
        i_bad_poly     : in std_logic_vector(11 downto 0);  -- one signal for each group of 4 virtual channels
        i_lastChannel  : in std_logic;   -- last of the group of 4 channels
        i_demap_table_select : in std_logic;
        i_HeaderValid  : in std_logic_vector(11 downto 0);
        i_data         : in t_ctc_output_payload_arr(11 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), ..., i_data(11)
        i_dataValid    : in std_logic;
        ---------------------------------------------------------------
        -- Data out to the correlator arrays
        -- packets of data to each correlator instance
        -- Sends a single packet full of instructions to each correlator, at the start of each 849ms corner turn frame readout.
        --  - 1st byte (o_axis_cor_first = '1') = Readout buffer selection
        --  - Next 4 bytes                      = framecount
        --  - 1 byte                            = Number of subarray beams
        -- The remaining (128 subarray-beams) * (4 words/subarray-beam) * (4 bytes/word) = 2048 bytes contains the subarray-beam table for the correlator
        -- The LSB of the 4th word contains the bad_poly bit for the subarray beam.
        -- The correlator should use (o_cor_cfg_last and o_cor_cfg_valid) to trigger processing 849ms of data.
        o_cor_cfg_data  : out t_slv_8_arr(5 downto 0); -- 8 bit wide buses, to 6 correlators.
        o_cor_cfg_first : out std_logic_vector(5 downto 0);
        o_cor_cfg_last  : out std_logic_vector(5 downto 0);
        o_cor_cfg_valid : out std_logic_vector(5 downto 0);
        -----------------------------------------------------------------
        -- AXI interface to the HBM
        -- Corner turn between filterbanks and correlator
        -- Expected to be up to 18 Gbyte of unified memory used by the correlators
        -- One HBM port is used for even indexed fine channels, while the other HBM port is used for odd indexed fine channels.
        o_HBM_axi_aw      : out t_axi4_full_addr_arr(1 downto 0); -- write address bus : out t_axi4_full_addr_arr(4 downto 0)(.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_awready : in std_logic_vector(1 downto 0);
        o_HBM_axi_w       : out t_axi4_full_data_arr(1 downto 0); -- w data bus : out t_axi4_full_data_arr(4 downto 0)(.valid, .data(511:0), .last, .resp(1:0))
        i_HBM_axi_wready  : in std_logic_vector(1 downto 0);
        i_HBM_axi_b       : in t_axi4_full_b_arr(1 downto 0);     -- write response bus : in t_axi4_full_b_arr(4 downto 0)(.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        
        -- signals used in testing to initiate readout of the buffer when HBM is preloaded with data,
        -- so we don't have to wait for the previous processing stages to complete.
        i_readout_start : in std_logic;
        i_readout_buffer : in std_logic;
        i_readout_frameCount : in std_logic_vector(31 downto 0);
        i_freq_index0_repeat : in std_logic;
        -- debug
        i_hbm_status   : in t_slv_8_arr(5 downto 0);
        i_hbm_reset_final : in std_logic;
        i_eth_disable_fsm_dbg : in std_logic_vector(4 downto 0);
        --
        i_hbm0_rst_dbg : in std_logic_vector(31 downto 0);
        i_hbm1_rst_dbg : in std_logic_vector(31 downto 0)
    );
end corr_ct2_top_v80;

architecture Behavioral of corr_ct2_top_v80 is
    
    signal statctrl_ro : t_statctrl_ro;
    signal statctrl_rw : t_statctrl_rw;
    signal frameCount_mod3 : std_logic_vector(1 downto 0) := "00";
    signal frameCount_849ms : std_logic_vector(31 downto 0) := (others => '0');
    --signal frameCount_startup : std_logic := '1';
    signal buf0_fineIntegrations, buf1_fineIntegrations : std_logic_vector(4 downto 0);
    signal vc_demap_in : t_statctrl_vc_demap_ram_in;
    signal subarray_beam_in : t_statctrl_subarray_beam_ram_in;
    signal vc_demap_out : t_statctrl_vc_demap_ram_out;
    signal subarray_beam_out : t_statctrl_subarray_beam_ram_out;
    signal vc_demap_rd_data, SB_rd_data : std_logic_vector(31 downto 0);
    signal vc_demap_rd_addr : std_logic_vector(9 downto 0);
    signal din_SB_addr : std_logic_vector(9 downto 0);
    --signal din_subarray_beam_read : std_logic;
    signal din_SB_valid : std_logic; -- SB data is valid.
    signal din_SB_stations : std_logic_vector(15 downto 0);    -- The number of (sub)stations in this subarray-beam
    signal din_SB_coarseStart : std_logic_vector(15 downto 0); -- The first coarse channel in this subarray-beam
    signal din_SB_fineStart : std_logic_vector(15 downto 0);   -- The first fine channel in this subarray-beam
    signal din_SB_n_fine : std_logic_Vector(23 downto 0);      -- The number of fine channels in this subarray-beam
    signal din_SB_HBM_base_addr : std_logic_vector(31 downto 0); --  Base address in HBM for this subarray-beam.
    signal dout_SB_req      : std_logic_vector(g_MAX_CORRELATORS-1 downto 0);
    --signal dout_SB_req_d0   : std_logic := '0'; -- std_logic_vector(5 downto 0) := (others => '0');
    --signal dout_SB_req_d1   : std_logic := '0'; -- std_logic_vector(5 downto 0) := (others => '0');
    signal dout_SB_valid    : std_logic_vector(g_MAX_CORRELATORS-1 downto 0);
    signal dout_SB_stations : t_slv_16_arr(g_MAX_CORRELATORS-1 downto 0);    -- The number of (sub)stations in this subarray-beam
    signal dout_SB_coarseStart : t_slv_16_arr(g_MAX_CORRELATORS-1 downto 0); -- The first coarse channel in this subarray-beam
    signal dout_SB_outputDisable : std_logic_vector(g_MAX_CORRELATORS-1 downto 0); -- Don't generate any output to the correlator for this entry in the subarray beam table
    signal dout_SB_fineStart : t_slv_16_arr(g_MAX_CORRELATORS-1 downto 0);   -- The first fine channel in this subarray-beam
    signal dout_SB_n_fine : t_slv_24_arr(g_MAX_CORRELATORS-1 downto 0);      -- The number of fine channels in this subarray-beam
    signal dout_SB_fineIntegrations : t_slv_7_arr(g_MAX_CORRELATORS-1 downto 0);  -- Number of fine channels to integrate
    signal dout_SB_timeIntegrations : std_logic_vector(g_MAX_CORRELATORS-1 downto 0);  -- in (1:0);  Number of time samples per integration.
    signal dout_SB_HBM_base_addr : t_slv_32_arr(g_MAX_CORRELATORS-1 downto 0);    -- in (31:0)  Base address in HBM for this subarray-beam.
    signal cur_readout_SB : t_slv_7_arr(g_MAX_CORRELATORS-1 downto 0);
    signal dout_SB_bad_poly : std_logic_vector(g_MAX_CORRELATORS-1 downto 0);
    signal total_subarray_beams : t_slv_16_arr(g_MAX_CORRELATORS-1 downto 0);
    --signal dout_SB_done : std_logic_vector(15 downto 0);
    type SB_rd_fsm_type is (idle, get_din_rd1, get_din_rd2, get_din_rd3, get_din_rd4, get_din_wait_done, send_meta, get_dout, dout_done);
    signal SB_rd_fsm, SB_rd_fsm_del1, SB_rd_fsm_del2, SB_rd_fsm_del3, SB_rd_fsm_del4 : SB_rd_fsm_type;
    signal dout_SB_sel, dout_SB_sel_del1, dout_SB_sel_del2, dout_SB_sel_del3 : std_logic_vector(2 downto 0);
    signal SB_addr : std_logic_vector(12 downto 0);
    signal din_SB_req : std_logic;
    signal readout_tableSelect : std_logic := '0';
    signal din_tableSelect : std_logic := '0';
    signal recent_virtualChannel : std_logic_vector(15 downto 0);
    --signal lastTime : std_logic;
    
    signal vc_demap_req : std_logic_vector(2 downto 0);  -- request a read from address o_vc_demap_rd_addr
    signal vc_demap_data_valid   : std_logic_vector(2 downto 0);  -- Read data below (i_demap* signals) is valid.
    signal vc_demap_SB_index     : std_logic_vector(9 downto 0);  -- index into the subarray-beam table.
    signal vc_demap_station      : std_logic_vector(11 downto 0); -- station index within the subarray-beam.
    signal vc_demap_skyFrequency : std_logic_vector(8 downto 0);  -- sky frequency.
    signal vc_demap_valid        : std_logic;                     -- This entry in the demap table is valid.
    signal vc_demap_req_del1     : std_logic_vector(2 downto 0);
    
    signal readout_start, readout_buffer_int, readout_buffer : std_logic := '0';
    signal readout_start_pulse, readout_start_del1, readout_buffer_del1 : std_logic := '0';
    
    signal readout_frame_count, readout_clock_count, readout_interval : std_logic_vector(31 downto 0) := (others => '0');
    signal readout_clock_count_counting : std_logic := '0';
    signal trigger_readout, trigger_buffer : std_logic := '0';
    signal sof_hold : std_logic := '0';
    signal readInClocks_count, readInClocks : std_logic_vector(31 downto 0) := x"00000000";
    signal readin_clock_count_counting, sof_full : std_logic := '0';
    signal cor_valid_int : std_logic_vector(g_MAX_CORRELATORS-1 downto 0);
    signal readoutBursts : std_logic_vector(31 downto 0);
    signal cor0_valid_del1, cor0_valid_del2 : std_logic;
    signal din_status1_del1, din_status2_del1, din_status1, din_status2, cur_status0 : std_logic_vector(31 downto 0);
    
    signal rst_del1, rst_del2 : std_logic;
    signal module_enable : std_logic := '0';
    signal dataValid : std_logic;
    signal update_table : std_logic := '0';
    signal readout_frameCount, readout_frameCount_del1, trigger_frameCount : std_logic_vector(31 downto 0);
    
    signal dout_ar_fsm_dbg : std_logic_vector(3 downto 0);
    signal dout_readout_fsm_dbg : std_logic_vector(3 downto 0);
    signal dout_arFIFO_wr_count : std_logic_vector(6 downto 0);
    signal dout_dataFIFO_wrCount : std_logic_vector(9 downto 0);
    
    -- debug ILA 
    signal dbg_i_sof : std_logic; 
    signal dbg_i_integration : std_logic_vector(3 downto 0);
    signal dbg_i_ctFrame : std_logic_vector(1 downto 0);
    signal dbg_i_virtualChannel : std_logic_vector(3 downto 0);
    signal dbg_i_headerValid, dbg_i_dataValid : std_logic;
    
    -- 20 bits
    signal dbg_SB_rd_fsm_dbg, SB_rd_fsm_dbg : std_logic_vector(3 downto 0);  -- 4 bits
    signal dbg_din_SB_req : std_logic;     -- 1 bit
    signal dbg_dout_SB_req : std_logic;  -- 1 bit
    signal dbg_readout_start : std_logic;
    signal dbg_dout_SB_done : std_logic_vector(1 downto 0); -- 2 bits
    signal dbg_SB_addr : std_logic_vector(3 downto 0);
    signal dbg_update_table, dbg_vc_demap_req, dbg_din_tableSelect : std_logic;
    signal dbg_vc_demap_rd_addr : std_logic_vector(3 downto 0);
    signal dbg_vc_demap_data_valid, dbg_din_SB_valid : std_logic;
    
    -- 32 bits
    signal dbg_din_copyToHBM_count : std_logic_vector(15 downto 0);
    signal dbg_din_copy_fsm_dbg : std_logic_vector(3 downto 0);
    signal dbg_din_copyData_fsm_dbg : std_logic_vector(3 downto 0);
    signal dbg_din_dataFIFO_dataCount : std_logic_vector(5 downto 0);
    signal dbg_din_first_aw, dbg_din_copy_fsm_stuck : std_logic;
    
    -- 8 bits
    signal dbg_din_copydata_count : std_logic_vector(3 downto 0);  -- really 15:0
    signal dbg_din_copy_fineChannel : std_logic_vector(3 downto 0);
     
    signal dbg_dout_ar_fsm_dbg : std_logic_vector(3 downto 0);
    signal dbg_dout_readout_fsm_dbg : std_logic_vector(3 downto 0);
    signal dbg_dout_arFIFO_wr_count : std_logic_vector(6 downto 0);
    signal dbg_dout_dataFIFO_wrCount : std_logic_vector(9 downto 0);
    signal dbg_cor_valid : std_logic;
    signal dbg_cor_tileChannel : std_logic_vector(7 downto 0);
    signal dbg_freq_index0_repeat : std_logic;
    signal dbg_axi_aw_valid, dbg_axi_aw_ready, dbg_axi_w_valid, dbg_axi_w_last, dbg_axi_w_ready : std_logic;
    
    signal o_cor_tileChannel_int    : t_slv_24_arr(g_MAX_CORRELATORS-1 downto 0);
    
    component ila_120_16k
    port (
        clk : in std_logic;
        probe0 : in std_logic_vector(119 downto 0)); 
    end component;
    
    signal HBM_axi_aw : t_axi4_full_addr_arr(1 downto 0);
    signal HBM_axi_w  : t_axi4_full_data_arr(1 downto 0);
    
    signal dbg_hbm_status0, dbg_hbm_status1 : std_logic_vector(7 downto 0);
    signal dbg_hbm_reset_final : std_logic;
    signal dbg_eth_disable_fsm_dbg : std_logic_vector(4 downto 0);
    
    signal dbg_rd_tracker_bad : std_logic; --  <= i_hbm_rst_dbg(1)(0);
    signal dbg_wr_tracker_bad : std_logic; -- <= i_hbm_rst_dbg(1)(1);
    signal dbg_wr_tracker : std_logic_vector(11 downto 0);
    
    signal cor_bp_wr_addr : std_logic_vector(7 downto 0);
    signal cor_bp_wr_en   : std_logic_vector(5 downto 0);
    signal cor_bp_wr_data : std_logic;
    
    signal cor_bp_rd_addr : std_logic_vector(7 downto 0);
    signal cor_bp_rd_data : std_logic_vector(5 downto 0);
    signal dout_HBM_buffer : std_logic_vector(g_MAX_CORRELATORS-1 downto 0);
    signal dout_readout_error : std_logic_vector(1 downto 0);
    signal dout_recent_start_gap :  std_logic_vector(31 downto 0);
    signal dout_recent_readout_time : std_logic_vector(31 downto 0);
    
    signal noc_rd_dat_mux           : STD_LOGIC_VECTOR(31 DOWNTO 0);
    signal bram_addr_d1             : STD_LOGIC_VECTOR(17 DOWNTO 0);
    signal bram_addr_d2             : STD_LOGIC_VECTOR(17 DOWNTO 0);
    signal max_copyAW_time : std_logic_vector(31 downto 0); -- time required to put out all the addresses
    signal max_copyData_time : std_logic_vector(31 downto 0); -- time required to put out all the data
    signal min_trigger_interval : std_logic_Vector(31 downto 0); -- minimum time available
    signal wr_overflow : std_logic_vector(31 downto 0); --
    signal dout_min_start_gap : std_logic_vector(31 downto 0);
    
    signal cfg_to_send : t_slv_40_arr(5 downto 0);
    signal cfg_to_send_valid, cfg_to_send_first, cfg_to_send_last : t_slv_5_arr(5 downto 0);
    signal readout_pending : std_logic := '0';
    signal dout_SB_entry_del2, dout_SB_entry_del3, dout_SB_entry_del1, dout_SB_entry : std_logic_vector(8 downto 0);
    
    signal aw_count, w_count : std_logic_vector(31 downto 0);
    signal aw_last_addr : std_logic_vector(31 downto 0);
    signal status1, status2, status3, status4 : std_logic_vector(31 downto 0);
    
begin
    
    dataValid <= i_dataValid and module_enable;
    
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            if i_sof = '1' then
                sof_hold <= '1';
            elsif dataValid = '1' then
                sof_hold <= '0';
            end if;
            
            rst_del1 <= i_rst;
            rst_del2 <= rst_del1;
            if rst_del1 = '0' and rst_del2 = '1' then
                -- falling edge of rst enables this module.
                module_enable <= '1';
            end if;
            
            if i_rst = '1' then
                frameCount_mod3 <= "00";
                update_table <= '1';
                frameCount_849ms <= (others => '0');
            elsif (sof_hold = '1' and dataValid = '1') then
                -- This picks up the framecount for the first packet in the frame = 283ms of data.
                -- If i_virtualChannel(0) = 0 then this is the start of a new block of 283 ms.
                -- Note : i_virtualChannel is only valid when i_dataValid = '1'.
                frameCount_mod3 <= i_ctFrame;
                frameCount_849ms <= i_integration;
                
                if (unsigned(i_virtualChannel(0)) = 0) and i_ctFrame = "00" then
                    update_table <= '1';
                else
                    update_table <= '0';
                end if;
            else
                update_table <= '0';
            end if;
            
            if (sof_hold = '1' and dataValid = '1' and (unsigned(i_virtualChannel(0)) = 0)) then
                sof_full <= '1';
            else
                sof_full <= '0';
            end if;
            
            if i_headerValid(0) = '1' then
                recent_virtualChannel <= i_virtualChannel(3);
            end if;
            
            if i_readout_start = '1' then
                -- This is used in the testbench to readout preloaded data from the HBM
                readout_start <= '1';
                readout_buffer <= i_readout_buffer;
                readout_frameCount <= i_readout_frameCount;
            else
                -- Normal functionality in the hardware
                readout_start <= trigger_readout;
                readout_buffer <= trigger_buffer;
                readout_frameCount <= trigger_frameCount;
            end if;
            
            readout_start_del1 <= readout_start;
            
            if readout_start = '1' and readout_start_del1 = '0' then
                readout_start_pulse <= '1';
            else
                readout_start_pulse <= '0';
            end if;
            
            
            ---------------------------------------------------------------------
            -- Monitoring
            ---------------------------------------------------------------------
            
            -- Count the number of frames that have been triggered to read out
            if i_rst = '1' then
                readout_frame_count <= (others => '0');
            elsif readout_start_pulse = '1' then
                readout_frame_count <= std_logic_vector(unsigned(readout_frame_count) + 1);
            end if;
            
            -- Count the clock cycles between read out triggers
            if i_rst = '1' then
                readout_clock_count <= (others => '0');
                readout_interval <= (others => '0');
                readout_clock_count_counting <= '0';
            elsif readout_start_pulse = '1' then
                readout_clock_count <= (others => '0');
                readout_interval <= readout_clock_count;
                readout_clock_count_counting <= '1';
            elsif readout_clock_count_counting = '1' then
                readout_clock_count <= std_logic_vector(unsigned(readout_clock_count) + 1);
                if readout_clock_count = x"fffffffe" then
                    readout_clock_count_counting <= '0';
                end if;
            end if;
            
            -- count the number of clock cycles between 283 ms frames from the filterbank
            if sof_full = '1' then
                readInClocks_count <= (others => '0');
                readInClocks <= readInClocks_count;
                readin_clock_count_counting <= '1';
            elsif readin_clock_count_counting = '1' then
                readInClocks_count <= std_logic_vector(unsigned(readInClocks_count) + 1);
                if readInClocks_count = x"fffffffe" then
                    readin_clock_count_counting <= '0';
                end if;
            end if;
            
            -- Count the number of bursts of data output to the correlators
            cor0_valid_del1 <= cor_valid_int(0);
            cor0_valid_del2 <= cor0_valid_del1;
            if i_rst = '1' then
                readoutBursts <= (others => '0');
            elsif cor0_valid_del1 = '1' and cor0_valid_del2 = '0' then
                readoutBursts <= std_logic_vector(unsigned(readoutBursts) + 1);
            end if;
            
            -- HBM transactions
           -- HBM_axi_aw      : out t_axi4_full_addr_arr(1 downto 0); -- write address bus : out t_axi4_full_addr_arr(4 downto 0)(.valid, .addr(39:0), .len(7:0))
           -- i_HBM_axi_awready
            if HBM_axi_aw(0).valid = '1' and i_HBM_axi_awready(0) = '1' then
                aw_count <= std_logic_vector(unsigned(aw_count) + 1);
                aw_last_addr <= HBM_axi_aw(0).addr(31 downto 0);
            end if;
            if HBM_axi_w(0).valid = '1' and i_HBM_axi_wready(0) = '1' then
                w_count <= std_logic_vector(unsigned(w_count) + 1);
            end if;
            
            status1 <= aw_count;
            status2 <= w_count;
            status3 <= aw_last_addr;
            status4(0) <= HBM_axi_aw(0).valid;
            status4(1) <= i_HBM_axi_awready(0);
            status4(2) <= HBM_axi_w(0).valid;
            status4(3) <= i_HBM_axi_wready(0);
            status4(31 downto 4) <= HBM_axi_aw(0).addr(31 downto 4);
            
            -- General status
            cur_status0(0) <= i_rst;
            cur_status0(1) <= i_dataValid;
            cur_Status0(2) <= sof_hold;
            cur_Status0(4 downto 3) <= frameCount_mod3;
            cur_status0(15 downto 5) <= "00000000000";
            cur_status0(31 downto 16) <= recent_virtualChannel;
            
            din_status1_del1 <= din_status1;
            din_status2_del1 <= din_status2;
            
        end if;
    end process;
    
    -- HBM reset vector
    statctrl_ro.hbm_reset_status_corr_1 <= i_hbm_status_c1; 
    o_hbm_reset_c1                      <= statctrl_rw.hbm_reset_corr_1;
    
    statctrl_ro.hbm_reset_status_corr_2 <= i_hbm_status_c2; 
    o_hbm_reset_c2                      <= statctrl_rw.hbm_reset_corr_2;
    
    statctrl_ro.readinclocks <= readInClocks;
    statctrl_ro.readInAllClocks <= readout_interval;
    statctrl_ro.readoutBursts <= readoutBursts;
    statctrl_ro.readoutFrames <= readout_frame_count;
    statctrl_ro.frameCountIn <= frameCount_849ms;
    statctrl_ro.status0  <= cur_status0;
    statctrl_ro.din_status1 <= din_status1_del1;
    statctrl_ro.din_status2 <= din_status2_del1;
    
    statctrl_ro.status1 <= status1;
    statctrl_ro.status2 <= status2;
    statctrl_ro.status3 <= status3;
    statctrl_ro.status4 <= status4;
    
    -- corr_ct2_din has buffers and logic for 1024 virtual channels = two correlator cells.
    din_inst : entity ct_lib.corr_ct2_din_v80
    generic map (
        g_USE_META => g_USE_META  -- Put meta data into the memory in place of the actual data, to make it easier to find bugs in the corner turn.
    ) port map (
        -- Data in from the correlator filterbanks; bursts of 3456 clocks for each channel.
        -- 
        i_rst              => rst_del1,         -- in std_logic;
        i_sof              => i_sof,            -- in std_logic; -- pulse high at the start of every new set of virtual channels
        -- i_frameCount_mod3 and i_frameCount_849ms are captured on the SECOND cycle of i_datavalid after i_sof
        i_frameCount_mod3  => frameCount_mod3,  -- in(1:0)
        i_frameCount_849ms => frameCount_849ms, -- in (31:0)
        i_virtualChannel0  => i_virtualChannel(0), -- in (15:0); first virtual channel of the 12 being processed
        i_bad_poly         => i_bad_poly,       -- in (11:0);
        i_lastChannel      => i_lastchannel,    -- in std_logic;
        i_HeaderValid      => i_headerValid,    -- in (11:0);
        i_data             => i_data,           -- in t_ctc_output_payload_arr(11 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), ... ,  i_data(11)
        i_dataValid        => dataValid,        -- in std_logic;
        o_trigger_readout  => trigger_readout,  -- out std_logic; All data has been written to the HBM, can start reading out to the correlator.
        o_trigger_buffer   => trigger_buffer,   -- out std_logic;
        o_trigger_frameCount => trigger_frameCount, -- out (31:0)
        -- interface to the bad poly memory
        -- interface to the bad poly memories - one for each of the 6 possible correlator cores
        o_bp_addr     => cor_bp_wr_addr, -- out (7:0); same address for all 6 memories
        o_bp_wr_en    => cor_bp_wr_en,   -- out (5:0); write enable for the bad poly memory for each of the 6 correlator cores
        o_bp_wr_data  => cor_bp_wr_data, -- out std_logic; same write data for all 6 memories
        
        --------------------------------------------------------------------
        -- interface to the demap table 
        o_vc_demap_rd_addr   => vc_demap_rd_addr,    -- out (9:0);  Address into the demap table, 0-1023 = floor(virtual_channel / 4)
        o_vc_demap_req       => vc_demap_req,        -- out (2:0);  Request a read from address o_vc_demap_rd_addr
        i_demap_data_valid   => vc_demap_data_valid, -- in (2:0);   Read data below (i_demap* signals) is valid.
        i_demap_SB_index     => vc_demap_SB_index,   -- in (9:0);   index into the subarray-beam table.
        i_demap_station      => vc_demap_station,    -- in (11:0);  station index within the subarray-beam.
        i_demap_skyFrequency => vc_demap_skyFrequency, -- in (8:0); sky frequency.
        i_demap_valid        => vc_demap_valid,        -- in std_logic; This entry in the demap table is valid.
        -- Interface to the subarray_beam table
        o_SB_addr          => din_SB_addr,          -- out (9:0);
        o_SB_req           => din_SB_req,           -- out std_logic;
        i_SB_valid         => din_SB_valid,         -- in std_logic; SB data is valid.
        i_SB_stations      => din_SB_stations,      -- in (15:0); The number of (sub)stations in this subarray-beam
        i_SB_coarseStart   => din_SB_coarseStart,   -- in (15:0); The first coarse channel in this subarray-beam
        i_SB_fineStart     => din_SB_fineStart,     -- in (15:0); The first fine channel in this subarray-beam
        i_SB_n_fine        => din_SB_n_fine,        -- in (23:0); The number of fine channels in this subarray-beam
        i_SB_HBM_base_addr => din_SB_HBM_base_addr, -- in (31:0); Base address in HBM for this subarray-beam.
        
        -- Status
        o_status1 => din_status1,
        o_status2 => din_status2,
        o_max_copyAW_time => max_copyAW_time, -- out std_logic_vector(31 downto 0); -- time required to put out all the addresses
        o_max_copyData_time => max_copyData_time, -- out std_logic_vector(31 downto 0); -- time required to put out all the data
        o_min_trigger_interval => min_trigger_interval, -- : out std_logic_Vector(31 downto 0); -- minimum time available
        o_wr_overflow => wr_overflow, -- : out std_logic_vector(31 downto 0); --overflow + debug info when the overflow occurred.
        i_insert_dbg => statctrl_rw.insert_dbg(0), -- in std_logic;
        -- AXI interface to the HBM
        -- Corner turn between filterbanks and correlator
        -- two HBM interfaces
        i_axi_clk      => i_axi_clk,         -- in std_logic;
        -- 2 blocks of memory, 3 Gbytes for virtual channels 0-511, 3 Gbytes for virtual channels 512-1023
        o_HBM_axi_aw      => HBM_axi_aw(1 downto 0),      -- out t_axi4_full_addr_arr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_awready => i_HBM_axi_awready(1 downto 0), -- in  std_logic_vector;
        o_HBM_axi_w       => HBM_axi_w(1 downto 0),       -- out t_axi4_full_data_arr; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_HBM_axi_wready  => i_HBM_axi_wready(1 downto 0),  -- in  std_logic_vector;
        i_HBM_axi_b       => i_HBM_axi_b(1 downto 0)        -- in  t_axi4_full_b_arr     -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.       
    );
    o_HBM_axi_aw <= HBM_axi_aw;
    o_HBM_axi_w <= HBM_axi_w;
    
    ----------------------------------------
    -- Bad poly memory
    -- One bit for each entry in the subarray-beam table
    -- double buffered, so data is written to one half by corr_ct2_din, 
    --   while the other half is being read from by corr_ct2_dout
    -- Write side must be cleared to zeros at the start of a frame. 
    -- 2 correlators, so 2 memories,
    -- Each correlator can have up to 128 entries in the subarray-beam table, 
    -- 2 buffers so 256 total entries for each correlator cell.
    -- Address bits (6:0) = subarray-beam
    --                (7) = selects 849 ms frame, alternates with lsb of frameCount_849ms
    bad_poly01i : entity ct_lib.corr_ct2_bad_poly_mem
    port map (
        clk  => i_axi_clk, -- in std_logic;
        -- First memory
        wr_addr0 => cor_bp_wr_addr, -- in std_logic_vector(7 downto 0);
        wr_en0   => cor_bp_wr_en(0),   -- in std_logic;
        wr_data0 => cor_bp_wr_data, -- in std_logic;
        rd_addr0 => cor_bp_rd_addr, -- in std_logic_vector(7 downto 0);
        rd_data0 => cor_bp_rd_data(0), -- out std_logic; -- 2 clock read latency
        -- Second memory
        wr_addr1 => cor_bp_wr_addr, -- in std_logic_vector(7 downto 0);
        wr_en1   => cor_bp_wr_en(1),   -- in std_logic;
        wr_data1 => cor_bp_wr_data, -- in std_logic;
        rd_addr1 => cor_bp_rd_addr, -- in std_logic_vector(7 downto 0);
        rd_data1 => cor_bp_rd_data(1)  -- out std_logic  -- 2 clock read latency
    );
    
    bad_poly23i : entity ct_lib.corr_ct2_bad_poly_mem
    port map (
        clk  => i_axi_clk, -- in std_logic;
        -- First memory
        wr_addr0 => cor_bp_wr_addr, -- in std_logic_vector(7 downto 0);
        wr_en0   => cor_bp_wr_en(2),   -- in std_logic;
        wr_data0 => cor_bp_wr_data, -- in std_logic;
        rd_addr0 => cor_bp_rd_addr, -- in std_logic_vector(7 downto 0);
        rd_data0 => cor_bp_rd_data(2), -- out std_logic; -- 2 clock read latency
        -- Second memory
        wr_addr1 => cor_bp_wr_addr, -- in std_logic_vector(7 downto 0);
        wr_en1   => cor_bp_wr_en(3),   -- in std_logic;
        wr_data1 => cor_bp_wr_data, -- in std_logic;
        rd_addr1 => cor_bp_rd_addr, -- in std_logic_vector(7 downto 0);
        rd_data1 => cor_bp_rd_data(3)  -- out std_logic  -- 2 clock read latency
    );
    
    bad_poly45i : entity ct_lib.corr_ct2_bad_poly_mem
    port map (
        clk  => i_axi_clk, -- in std_logic;
        -- First memory
        wr_addr0 => cor_bp_wr_addr, -- in std_logic_vector(7 downto 0);
        wr_en0   => cor_bp_wr_en(4),   -- in std_logic;
        wr_data0 => cor_bp_wr_data, -- in std_logic;
        rd_addr0 => cor_bp_rd_addr, -- in std_logic_vector(7 downto 0);
        rd_data0 => cor_bp_rd_data(4), -- out std_logic; -- 2 clock read latency
        -- Second memory
        wr_addr1 => cor_bp_wr_addr, -- in std_logic_vector(7 downto 0);
        wr_en1   => cor_bp_wr_en(5),   -- in std_logic;
        wr_data1 => cor_bp_wr_data, -- in std_logic;
        rd_addr1 => cor_bp_rd_addr, -- in std_logic_vector(7 downto 0);
        rd_data1 => cor_bp_rd_data(5)  -- out std_logic  -- 2 clock read latency
    );
        
    ------------------------------------------------------------------------------
    -- Registers
    reginst : entity ct_lib.corr_ct2_versal
    PORT map (
        MM_CLK     => i_axi_clk,   -- in  std_logic;
        MM_RST     => i_axi_rst,   -- in  std_logic;
        -- Interface to the NOC module (The NOC module in the level above includes XPM NOC component and axi to ram interface conversion)
        noc_wren   => i_noc_wren,
        noc_rden   => i_noc_rden,
        noc_wr_adr => i_noc_wr_adr,
        noc_wr_dat => i_noc_wr_dat,
        noc_rd_adr => i_noc_rd_adr,
        noc_rd_dat => o_noc_rd_dat,
        --
        STATCTRL_FIELDS_RW	=> statctrl_rw, -- out t_statctrl_rw; single field .buf0_subarray_beams_table0, .buf0_subarray_beams_table1, .buf1_subarray_beams_table0, .buf1_subarray_beams_table1
        STATCTRL_FIELDS_RO	=> statctrl_ro, -- in  t_statctrl_ro
        STATCTRL_VC_DEMAP_IN       => vc_demap_in,      -- in  t_statctrl_vc_demap_ram_in;
        STATCTRL_VC_DEMAP_OUT      => vc_demap_out,     -- out t_statctrl_vc_demap_ram_out;
        STATCTRL_SUBARRAY_BEAM_IN  => subarray_beam_in, -- in  t_statctrl_subarray_beam_ram_in;
        STATCTRL_SUBARRAY_BEAM_OUT => subarray_beam_out -- out t_statctrl_subarray_beam_ram_out
    );

    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            statctrl_ro.bufferoverflowerror <= wr_overflow;  -- 32 bits of debug info
            statctrl_ro.max_copyAW_time <= max_copyAW_time; -- out std_logic_vector(31 downto 0); -- time required to put out all the addresses
            statctrl_ro.max_copyData_time <= max_copyData_time; --  : out std_logic_vector(31 downto 0); -- time required to put out all the data
            statctrl_ro.min_trigger_interval <= min_trigger_interval; --  out std_logic_Vector(31 downto 0); -- minimum time available
            statctrl_ro.hbm_status0 <= i_hbm0_rst_dbg;
            statctrl_ro.hbm_status1 <= i_hbm1_rst_dbg;
            
            statctrl_ro.readouterror <= dout_readout_error;
            statctrl_ro.readoutGap <= dout_recent_start_gap;
            statctrl_ro.minReadoutGap <= dout_min_start_gap;
            statctrl_ro.readoutTime <= dout_recent_readout_time;
            statctrl_ro.hbmbuf0packetcount <= (others => '0');
            statctrl_ro.hbmbuf1packetcount <= (others => '0');
            
        end if;
    end process;
    vc_demap_in.adr(11 downto 1) <= din_tableSelect & vc_demap_rd_addr; -- full address is 12 bits
    -- Two words for each entry in the vc_demap table, but we only use the first word. 
    -- The second word is for forwarding of data on the ethernet port, which is not currently implemented. 
    vc_demap_in.adr(0) <= '0'; 
	vc_demap_in.wr_dat <= (others => '0');  -- 32 bit write data; unused.
    vc_demap_in.wr_en <= '0'; -- don't write to the vc_demap table.
    vc_demap_in.rd_en <= '1';
    vc_demap_in.clk <= i_axi_clk; --
    vc_demap_in.rst <= '0';
    vc_demap_rd_data <= vc_demap_out.rd_dat;
    
    subarray_beam_in.wr_dat <= (others => '0');
    subarray_beam_in.wr_en <= '0';
    subarray_beam_in.rd_en <= '1';
    subarray_beam_in.clk <= i_axi_clk;
    subarray_beam_in.rst <= '0';
    subarray_beam_in.adr <= SB_addr;
    
    process(i_axi_clk)
        variable dout_SB_sel_v : integer := 0;
    begin
        if rising_edge(i_axi_clk) then
            
            ----------------------------------------------------------------------------------------
            -- Logic for reading the demap table.
            -- vc_demap_req should pulse high for 1 clock.
            -- Read data comes back in the next clock.
            vc_demap_req_del1 <= vc_demap_req;
            vc_demap_data_valid <= vc_demap_req_del1;
            
            if vc_demap_req_del1(0) = '1' or vc_demap_req_del1(1) = '1' or vc_demap_req_del1(2) = '1' then
                vc_demap_SB_index <= vc_demap_out.rd_dat(30 downto 29) & vc_demap_out.rd_dat(7 downto 0);       -- Index into the subarray-beam table.
                vc_demap_station  <= vc_demap_out.rd_dat(19 downto 8);      -- station index within the subarray-beam.
                vc_demap_skyFrequency <= vc_demap_out.rd_dat(28 downto 20); -- sky frequency.
                vc_demap_valid        <= vc_demap_out.rd_dat(31);           -- This entry in the demap table is valid.      
            end if;
            
            ----------------------------------------------------------------------------------------
            -- Logic for reading the subarray-beam table
            --
            if update_table = '1' then
                -- Update table occurs at the start of each new 849 ms readout
                -- Set the subarray-beam table that is used for writing data into the HBM.
                -- Set at the start of data input for the frame, so it is fixed through the frame.
                din_tableSelect <= i_demap_table_select;
            end if;
            
            if (readout_start = '1') then
                -- Get the number of subarray-beams in each table at the start of the readout.
                -- Because the number of correlator cells is embedded in the registers via the names, this piece of code
                -- will have to be edited to match the registers yaml file if there are more that 2 correlator cells.
                if (din_tableSelect = '0') then
                    -- readout is using first of the two copies of the subarray-beam table
                    readout_tableSelect <= '0';
                    total_subarray_beams(0) <= statctrl_rw.buf0_subarray_beams_table0;
                    total_subarray_beams(1) <= statctrl_rw.buf1_subarray_beams_table0;
                    total_subarray_beams(2) <= statctrl_rw.buf2_subarray_beams_table0;
                    total_subarray_beams(3) <= statctrl_rw.buf3_subarray_beams_table0;
                    total_subarray_beams(4) <= statctrl_rw.buf4_subarray_beams_table0;
                    total_subarray_beams(5) <= statctrl_rw.buf5_subarray_beams_table0;
                else
                    readout_tableSelect <= '1';
                    total_subarray_beams(0) <= statctrl_rw.buf0_subarray_beams_table1;
                    total_subarray_beams(1) <= statctrl_rw.buf1_subarray_beams_table1;
                    total_subarray_beams(2) <= statctrl_rw.buf2_subarray_beams_table1;
                    total_subarray_beams(3) <= statctrl_rw.buf3_subarray_beams_table1;
                    total_subarray_beams(4) <= statctrl_rw.buf4_subarray_beams_table1;
                    total_subarray_beams(5) <= statctrl_rw.buf5_subarray_beams_table1;
                end if;
                readout_buffer_del1 <= readout_buffer;
                readout_frameCount_del1 <= readout_frameCount;
                -- Where we are currently up to in the subarray-beam table for each correlator cell readout.
                for i in 0 to (g_MAX_CORRELATORS-1) loop
                    cur_readout_SB(i) <= (others => '0');
                end loop;
                readout_pending <= '1';
            elsif SB_rd_fsm = dout_done or SB_rd_fsm = idle then
                readout_pending <= '0';
            end if;
            
            -- This fsm handles reading from the subarray-beam table in the registers.
            -- There are multiple modules contending for access to the table; : 
            --  - The data input side, "corr_ct2_din", for working out where in HBM to put data from the filterbanks
            --  - The one, two or maybe more data output modules ("corr_ct2_dout")
            -- The output modules ask for the next subarray beam, and after the data has been read here it is placed in registers for the output module to use.
            case SB_rd_fsm is
                when idle =>
                    SB_rd_fsm_dbg <= "0000";
                    if readout_pending = '1' then
                        SB_rd_fsm <= send_meta;
                        dout_SB_sel <= "000";  -- which correlator to read out for
                        dout_SB_entry <= "000000000"; -- which of the 512 maximum possible words in each table we are up to
                    elsif din_SB_req = '1' then
                        SB_rd_fsm <= get_din_rd1;
                    end if;
                
                when get_din_rd1 =>
                    SB_rd_fsm_dbg <= "0001";
                    SB_addr(12) <= din_tableSelect;
                    SB_addr(11 downto 2) <= din_SB_addr; -- 10 bits
                    SB_addr(1 downto 0) <= "00";
                    SB_rd_fsm <= get_din_rd2;
                    
                when get_din_rd2 => 
                    SB_rd_fsm_dbg <= "0010";
                    SB_addr(1 downto 0) <= "01";
                    SB_rd_fsm <= get_din_rd3;
                
                when get_din_rd3 =>
                    SB_rd_fsm_dbg <= "0011";
                    SB_addr(1 downto 0) <= "10";
                    SB_rd_fsm <= get_din_rd4;
                
                when get_din_rd4 => 
                    SB_rd_fsm_dbg <= "0100";
                    SB_addr(1 downto 0) <= "11";
                    SB_rd_fsm <= get_din_wait_done;
                
                when get_din_wait_done =>
                    -- Wait until valid is sent so the fsm doesn't do the same read again. 
                    SB_rd_fsm_dbg <= "0101";
                    if (SB_rd_fsm_del4 = get_din_rd4) then
                        SB_rd_fsm <= idle;
                    end if;
                
                -----------------------------------------------------------------------
                -- Send packets of meta and subarray-beam table data to each of the correlator cores
                when send_meta =>
                    -- First 5 bytes = readout_buffer, readout_frameCount 
                    if dout_SB_sel = "101" then 
                        -- hold in this state for 6 clocks so that it behaves the same as in the get_dout state,
                        -- and allows time for the 1-byte wide bus to the correlators to clear the data loaded.
                        SB_rd_fsm <= get_dout;
                        dout_SB_sel <= "000";
                    else
                        dout_SB_sel <= std_logic_vector(unsigned(dout_SB_sel) + 1);
                    end if;
                    
                when get_dout =>
                    -- Readout the full subarray beam table for all 6 correlators, to copy it onto the o_axis_cor_* bus
                    -- which is sent to each correlator core.
                    -- Read address 0 for all correlator cores, then address 1 etc. 
                    SB_addr(12) <= readout_tableSelect;
                    SB_addr(11 downto 9) <= dout_SB_sel;  -- steps through each correlator core
                    SB_addr(8 downto 0) <= dout_SB_entry; -- steps through each word in the subarray-beam memory for a particular correlator core
                    cor_bp_rd_addr(7) <= readout_tableSelect;  -- Which of the two HBM buffers are we reading from, will always be the same for the two correlators
                    cor_bp_rd_addr(6 downto 0) <= dout_SB_entry(8 downto 2); -- 4 words in each subarray-beam table entry
                    if dout_SB_sel = "101" then
                        dout_SB_sel <= "000";
                        dout_SB_entry <= std_logic_vector(unsigned(dout_SB_entry) + 1);
                        if (unsigned(dout_SB_entry) = 511) then
                            SB_rd_fsm <= dout_done;
                        end if;
                    else
                        dout_SB_sel <= std_logic_vector(unsigned(dout_SB_sel) + 1);
                    end if;
                    
                when dout_done =>
                    SB_rd_fsm <= idle;
                    
                when others =>
                    SB_rd_fsm_dbg <= "1111";
                    SB_rd_fsm <= idle;
            
            end case;
            
            -- del1 : SB_addr is valid, cor_bp_rd_addr is valid
            SB_rd_fsm_del1 <= SB_rd_fsm;
            dout_SB_sel_del1 <= dout_SB_sel;
            dout_SB_entry_del1 <= dout_SB_entry;
            
            -- del2 : subarray_beam_out.rd_dat is valid.
            SB_rd_fsm_del2 <= SB_rd_fsm_del1;
            dout_SB_sel_del2 <= dout_SB_sel_del1;
            dout_SB_entry_del2 <= dout_SB_entry_del1;
            
            -- del3  : SB_rd_data is valid
            SB_rd_fsm_del3 <= SB_rd_fsm_del2;
            dout_SB_sel_del3 <= dout_SB_sel_del2;
            dout_SB_entry_del3 <= dout_SB_entry_del2;
            SB_rd_data <= subarray_beam_out.rd_dat;
            
            SB_rd_fsm_del4 <= SB_rd_fsm_del3;
            
            -- Assign din and dout data read from the subarray-beam table
            if (SB_rd_fsm_del3 = get_din_rd1) then
                din_SB_stations <= SB_rd_data(15 downto 0);
                -- bit 31 of the first word is "output_disable".
                -- It is not used by the data input side, so it is masked off here.
                din_SB_coarseStart <= '0' & SB_rd_data(30 downto 16);
            end if;
            if (SB_rd_fsm_del3 = get_din_rd2) then
                din_SB_fineStart <= SB_rd_data(15 downto 0);
            end if;
            if (SB_rd_fsm_del3 = get_din_rd3) then
                din_SB_n_fine <= SB_rd_data(23 downto 0);
            end if;
            if (SB_rd_fsm_del3 = get_din_rd4) then
                din_SB_HBM_base_addr <= SB_rd_data(31 downto 0);
                din_SB_valid <= '1';
            else
                din_SB_valid <= '0';
            end if;

        end if;
    end process;            
    
    
    cor_out_geni : for i in 0 to 5 generate

        -----------------------------------------------------------------------    
        -- For each 849ms corner turn, send packets of data to each correlator with instructions for the 
        -- correlations to complete
        --  output signals are: 
        --     o_axis_cor_data  : out t_slv_8_arr(5 downto 0); -- 8 bit wide buses, to 6 correlators.
        --     o_axis_cor_valid : out std_logic_vector(5 downto 0);
        --     o_axis_cor_first : out std_logic;
        --     o_axis_cor_last  : out std_logic;
        -- 
        -- Packets are sent on "readout_start_pulse"
        --  - 1st byte (o_axis_cor_first = '1') = Readout buffer selection
        --  - Next 4 bytes                      = framecount
        --  - 1 byte                            = Number of subarray beams 
        --  - Then 128 groups of 4 bytes each, where each 4 bytes are the data from a 32-bit word in the subarray beam table.
        --  The lsb of the last 32 bit word is replaced with the bad poly value for that subarray beam (LSB must be zero in the table because addresses are 256 byte aligned)
        -- 
        -- The fsm reads the first word from the SB table for each of the 6 correlators, then the next word etc, 
        -- so that 4 bytes are read for every correlator once every 6 clocks.    
    
        process(i_axi_clk)
            variable dout_SB_sel_v : integer := 0;
        begin
            if rising_edge(i_axi_clk) then
                if (unsigned(dout_SB_sel_del3) = i) then
                    if (SB_rd_fsm_del3 = send_meta) then
                        cfg_to_send(i) <= readout_frameCount_Del1 & "0000000" & readout_buffer_del1;
                        cfg_to_send_valid(i) <= "11111";
                        cfg_to_send_first(i) <= "00001";
                        cfg_to_send_last(i) <= "00000";
                    elsif (SB_rd_fsm_del3 = get_dout) then
                        if (unsigned(dout_SB_entry_del3) = 0) then
                            -- first word read for this correlator, put in the number of subarray beams as well as the data read from the config memory
                            cfg_to_send(i) <= SB_rd_data & total_subarray_beams(i)(7 downto 0);
                            cfg_to_send_valid(i) <= "11111";
                            cfg_to_send_first(i) <= "00000";
                            cfg_to_send_last(i) <= "00000";
                        else
                            if (dout_SB_entry_del3(1 downto 0) = "11") then
                                -- last of 4 words, put bad poly in the LSB
                                cfg_to_send(i) <= x"00" & SB_rd_data(31 downto 1) & cor_bp_rd_data(i);
                            else
                                cfg_to_send(i) <= x"00" & SB_rd_data;
                            end if;
                            cfg_to_send_valid(i) <= "01111";
                            cfg_to_send_first(i) <= "00000";
                            if (unsigned(dout_SB_entry_del3) = 511) then
                                cfg_to_send_last(i) <= "01000";
                            else
                                cfg_to_send_last(i) <= "00000";
                            end if;
                        end if;
                    end if;
                else
                    -- Right shift to send up to 5 bytes
                    -- This assumes that there will be at least 5 clocks between a new set of 4 or 5 bytes being written to these registers.
                    cfg_to_send(i) <= x"00" & cfg_to_send(i)(39 downto 8);
                    cfg_to_send_valid(i) <= '0' & cfg_to_send_valid(i)(4 downto 1);
                    cfg_to_send_first(i) <= '0' & cfg_to_send_first(i)(4 downto 1);
                    cfg_to_send_last(i) <= '0' & cfg_to_send_last(i)(4 downto 1);
                end if;
                
            end if;
        end process;
    
        o_cor_cfg_data(i) <= cfg_to_send(i)(7 downto 0);
        o_cor_cfg_first(i) <= cfg_to_send_first(i)(0);
        o_cor_cfg_last(i) <= cfg_to_send_last(i)(0);
        o_cor_cfg_valid(i) <= cfg_to_send_valid(i)(0);
        
    end generate;
    
    -- Note : 4 words of data in the subarray-beam table per entry, with : 
    --     Word 0 : bits(15:0) = number of (sub)stations in this subarray-beam
    --              bits(31:16) = starting coarse frequency channel
    --     Word 1 : bits (15:0) = starting fine frequency channel 
    --     word 2 : bits (23:0) = Number of fine channels stored 
    --              bits (29:24) = Fine channels per integration 
    --              bits (31:30) = integration time; 0 = 283 ms, 1 = 849 ms, others invalid 
    --     Word 3 : bits (31:0) = Base Address in HBM to store this subarray beam, units of 4 bytes (so 32 bits addresses up to 16 GBytes)
    --
    -- So data to the readout modules is :
    -- Control signals : 
    --   o_get_subarray_beam => buf0_get_subarray_beam, -- Rising edge gets the parameters for the next subarray-beam to read out.
    --   i_subarray_beam_valid => buf0_subarray_beam_valid; -- subarray-beam data below is valid; goes low when o_get_subarray_beam goes high, then goes high again once the parameters are valid.
    -- Data : 
    --   word 0, bits 15:0  = i_stations => readout_buf0_stations, -- The number of (sub)stations in this subarray-beam
    --   word 0, bits 31:16 = i_coarseStart => readout_buf0_coarseStart, -- the first coarse channel in this subarray-beam
    --   word 1, bits 15:0  = i_fineStart => readout_buf0_fineStart, -- the first fine channel in this subarray-beam
    --   word 2, bits 23:0  = i_n_fine => readout_buf0_n_fine, -- The number of fine channels in this subarray-beam
    --   word 2, bits 29:24 = i_fineIntegrations => readout_buf0_fineIntegrations, -- Number of fine channels to integrate
    --   word 2, bits 31:30 = i_timeIntegrations => readout_buf0_timeIntegrations, -- Number of time samples per integration.
    --   word 3, bits 31:0  = i_HBM_base_addr => readout_buf0_HBM_base_addr,       -- base address in HBM for this subarray-beam.
    
    
    ----------------------------------------------------------------------------------------
    
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            -- 13 bits
            dbg_i_sof <= i_sof; 
            dbg_i_integration <= i_integration(3 downto 0);
            dbg_i_ctFrame <= i_ctFrame(1 downto 0);
            dbg_i_virtualChannel <= i_virtualChannel(0)(3 downto 0);
            dbg_i_headerValid <= i_HeaderValid(0);
            dbg_i_dataValid <= i_dataValid;
            
            -- 20 bits
            dbg_SB_rd_fsm_dbg <= SB_rd_fsm_dbg;  -- 4 bits
            dbg_din_SB_req <= din_SB_req;     -- 1 bit
            dbg_dout_SB_req <= dout_SB_req(0);  -- 1 bit
            dbg_readout_start <= readout_start;
            dbg_dout_SB_done <= "00"; -- dout_SB_done(1 downto 0); -- 2 bits
            dbg_SB_addr <= SB_addr(3 downto 0);
            dbg_update_table <= update_table;
            dbg_vc_demap_req <= vc_demap_req(0);
            dbg_din_tableSelect <= din_tableSelect;
            dbg_vc_demap_rd_addr <= vc_demap_rd_addr(3 downto 0);
            
            -- 2 bits
            dbg_vc_demap_data_valid <= vc_demap_data_valid(0);
            dbg_din_SB_valid <= din_SB_valid;
            
            -- 32 bits
            dbg_din_copyToHBM_count <= din_status1(15 downto 0);
            dbg_din_copy_fsm_dbg <= din_status1(19 downto 16);
            dbg_din_copyData_fsm_dbg <= din_status1(23 downto 20);
            dbg_din_dataFIFO_dataCount <= din_status1(29 downto 24);
            dbg_din_first_aw <= din_status1(30);
            dbg_din_copy_fsm_stuck <= din_status1(31);
            
            -- 8 bits
            dbg_din_copydata_count <= din_status2(15 downto 12);  -- really 15:0
            dbg_din_copy_fineChannel <= din_status2(31 downto 28); -- really 31:20
            
            -- 25 bits  
            dbg_dout_ar_fsm_dbg <= dout_ar_fsm_dbg; -- : std_logic_vector(3 downto 0);
            dbg_dout_readout_fsm_dbg <= dout_readout_fsm_dbg; -- : std_logic_vector(3 downto 0);
            dbg_dout_arFIFO_wr_count <= dout_arFIFO_wr_count; --  : std_logic_vector(6 downto 0);
            dbg_dout_dataFIFO_wrCount <= dout_dataFIFO_wrCount; -- : std_logic_vector(9 downto 0);
            
            -- 9 bits
            dbg_cor_valid <= cor_valid_int(0);
            dbg_cor_tileChannel <= o_cor_tileChannel_int(0)(7 downto 0);
            
            -- 1 bit
            dbg_freq_index0_repeat <= i_freq_index0_repeat; -- (export from single_correlator.vhd)
            
            -- 5 bits
            dbg_axi_aw_valid <= HBM_axi_aw(0).valid;
            dbg_axi_aw_ready <= i_HBM_axi_awready(0);
            dbg_axi_w_valid <= HBM_axi_w(0).valid;
            dbg_axi_w_last <= HBM_axi_w(0).last;
            dbg_axi_w_ready <= i_HBM_axi_wready(0);
            
            --
            dbg_hbm_status0 <= i_hbm_status(0); -- 8 bits
            dbg_hbm_status1 <= i_hbm_status(1); -- 8 bits
            dbg_hbm_reset_final <= i_hbm_reset_final; -- 1 bit
            dbg_eth_disable_fsm_dbg <= i_eth_disable_fsm_dbg; -- 5 bits
            
            --
            dbg_rd_tracker_bad <= i_hbm0_rst_dbg(0);
            dbg_wr_tracker_bad <= i_hbm0_rst_dbg(1);
            dbg_wr_tracker <= i_hbm0_rst_dbg(27 downto 16);
            
            --o_dbg(0) <= rd_tracker_bad;
            --o_dbg(1) <= wr_tracker_bad;
            --o_dbg(3 downto 2) <= "00";
            --o_dbg(15 downto 4) <= std_logic_vector(hbm_rd_tracker);
            --o_dbg(27 downto 16) <= std_logic_vector(hbm_wr_tracker);
            --o_dbg(31 downto 28) <= "0000";
            
            
        end if;
    end process;
    
debug_ila_gen : if g_GENERATE_ILA GENERATE    
    ct2_ila : ila_120_16k
    port map (
        clk => i_axi_clk,   -- IN STD_LOGIC;
        
        -- 13 bits
        probe0(0) => dbg_i_sof,
        probe0(4 downto 1) => dbg_i_integration, -- <= i_integration(3 downto 0);
        probe0(6 downto 5) => dbg_i_ctFrame, -- <= i_ctFrame(1 downto 0);
        probe0(10 downto 7) => dbg_i_virtualChannel, -- <= i_virtualChannel(0)(3 downto 0);
        probe0(11) => dbg_i_headerValid, -- <= i_HeaderValid(0);
        probe0(12) => dbg_i_dataValid, -- <= i_dataValid;
        
        -- 20 bits
        probe0(16 downto 13) => dbg_SB_rd_fsm_dbg, -- <= SB_rd_fsm_dbg;  -- 4 bits
        probe0(17) => dbg_din_SB_req, -- <= din_SB_req;     -- 1 bit
        probe0(18) => dbg_dout_SB_req, -- <= dout_SB_req(0);  -- 1 bit
        probe0(19) => dbg_readout_start, -- <= readout_start;
        probe0(21 downto 20) => dbg_dout_SB_done, -- <= dout_SB_done(1 downto 0); -- 2 bits
        probe0(25 downto 22) => dbg_SB_addr, -- <= SB_addr(3 downto 0);
        probe0(26) => dbg_update_table, -- <= update_table;
        probe0(27) => dbg_vc_demap_req, -- <= vc_demap_req;
        probe0(28) => dbg_din_tableSelect, -- <= din_tableSelect;
        probe0(32 downto 29) => dbg_vc_demap_rd_addr, -- <= vc_demap_rd_addr(3 downto 0);
        
        -- 2 bits
        probe0(33) => dbg_vc_demap_data_valid, -- <= vc_demap_data_valid;
        probe0(34) => dbg_din_SB_valid, -- <= din_SB_valid;
        
        -- 32 bits
        --probe0(50 downto 35) => dbg_din_copyToHBM_count, -- <= din_status1(15 downto 0);
        probe0(35) => dbg_hbm_reset_final,
        probe0(40 downto 36) => dbg_eth_disable_fsm_dbg,
        probe0(48 downto 41) => dbg_hbm_status1,
        probe0(50 downto 49) => dbg_hbm_status0(1 downto 0),
        
        probe0(54 downto 51) => dbg_din_copy_fsm_dbg, -- <= din_status1(19 downto 16);
        probe0(58 downto 55) => dbg_din_copyData_fsm_dbg, -- <= din_status1(23 downto 20);
        probe0(64 downto 59) => dbg_din_dataFIFO_dataCount, -- <= din_status1(29 downto 24);
        probe0(65) => dbg_din_first_aw, -- <= din_status1(30);
        probe0(66) => dbg_din_copy_fsm_stuck, -- <= din_status1(31);
        
        -- 8 bits
        probe0(70 downto 67) => dbg_din_copydata_count, -- <= din_status2(15 downto 12);  -- really 15:0
        probe0(74 downto 71) => dbg_din_copy_fineChannel, -- <= din_status2(31 downto 28); -- really 31:20
        
        -- 25 bits  
        probe0(78 downto 75) => dbg_dout_ar_fsm_dbg, -- <= dout_ar_fsm_dbg; -- : std_logic_vector(3 downto 0);
        probe0(82 downto 79) => dbg_dout_readout_fsm_dbg, -- <= dout_readout_fsm_dbg; -- : std_logic_vector(3 downto 0);
        probe0(89 downto 83) => dbg_dout_arFIFO_wr_count, -- <= dout_arFIFO_wr_count; --  : std_logic_vector(6 downto 0);
        probe0(99 downto 90) => dbg_dout_dataFIFO_wrCount, -- <= dout_dataFIFO_wrCount; -- : std_logic_vector(9 downto 0);
        
        -- 9 bits
        probe0(100) => dbg_rd_tracker_bad,
        probe0(101) => dbg_wr_tracker_bad,
        probe0(109 downto 102) => dbg_wr_tracker(7 downto 0),
        
        --probe0(100) => dbg_cor_valid, -- <= cor_valid_int(0);
        --probe0(108 downto 101) => dbg_cor_tileChannel, -- <= o_cor_tileChannel(0)(7 downto 0);
        
        -- 1 bit
        --probe0(109) => dbg_freq_index0_repeat, -- <= i_freq_index0_repeat; -- (export from single_correlator.vhd)
        
        -- 9 bits
        probe0(110) => dbg_axi_aw_valid, -- <= o_HBM_axi_aw(0).valid;
        probe0(111) => dbg_axi_aw_ready, -- <= i_HBM_axi_awready(0);
        probe0(112) => dbg_axi_w_valid, -- <= o_HBM_axi_w(0).valid;
        probe0(113) => dbg_axi_w_last, -- <= o_HBM_axi_w(0).last;
        probe0(114) => dbg_axi_w_ready, -- <= i_HBM_axi_wready(0);
        probe0(115) => '0',  -- <= o_HBM_axi_ar(0).valid;
        probe0(116) => '0',  -- <= i_HBM_axi_arready(0);
        probe0(117) => '0',  -- <= i_HBM_axi_r(0).valid;
        probe0(118) => '0',  -- <= o_HBM_axi_rready(0);
        probe0(119) => rst_del2
    );
END GENERATE;
    
    
end Behavioral;
