----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 30.10.2020 22:21:03
-- Module Name: ct_atomic_cor_out - Behavioral
-- Description: 
--    Corner turn between the filterbanks and the correlator for SKA correlator processing. 
-- 
-- Data coming in from the filterbanks :
--   4 dual-pol channels, with burst of 3456 fine channels at a time.
--   Total number of bytes per clock coming in is  (4 channels)*(2 pol)*(2 complex) = 16 bytes.
--   with roughly 3456 out of every 4096 clocks active.
--   Total data rate in is thus roughly (16 bytes * 8 bits)*3456/4096 * 300 MHz = 32.4 Gb/sec (this is the average data rate while data is flowing)
--   Actual total data rate in is (3456/4096 fine channels used) * (1/1080ns sampling period) * (32 bits/sample) * (1024 channels) = 25.6 Gb/sec 
--
-- Storing to HBM and incoming ultraRAM buffering
--   Data is written to the HBM in blocks of (32 times) * (1 fine [226 Hz] channels) * (4 stations) * (2 pol) * (2 bytes/sample) = 512 bytes.
--
--   This requires double buffering in ultraRAM in this module of 32 time samples from the filterbanks.
--   So we have a buffer which is (2 (double buffer)) * (32 times) * (4 virtual channels) * (2 pol) * (3456 fine channels) * (2 bytes/sample) = 3456 kBytes = 108 ultraRAMs.
--
--   The ultraRAM buffer is constructed from 4 pieces, each of which is (128 bits wide) * (14x4096 deep)
--     - Each piece is thus 28 ultraRAMs.
--     - Total ultraRAMs used = 4x28 = 112
--     - Data Layout in the ultraRAM buffer :
--
--      |----------------------------|---------------------------|----------------------------|----------------------------|  ---                                ---------- 
--      |    InputBuf0               |    InputBuf1              |    InputBuf2               |    InputBuf3               |   |
--      |<-------128 bits----------->|<-----128 bits------------>|<-----128 bits------------->|<-----128 bits------------->|   |
--      |                            |                           |                            |                            |  28672 words                        second half 
--      |                            |                           |                            |                            |  (= 7*4096)                         of double buffer
--      |                            |                           |                            |                            |   |
--      |                            |                           |                            |                            |   |                                 Starts at address 28672
--      |                            |                           |                            |                            |  ---                                ----------
--      |                            |                           |                            |                            |                     
--      |                            |                           |                            |                            |                                     First half
--      |                            |                           |                            |                            |                                     of double buffer
--      |                            |                           |                            |                            |                                     (27648 words)            
--      |        ...                 |          ...              |        ...                 |           ...              |
--      | fine=1, t=28, 4 chan,2 pol | fine=1,t=29, 4 chan,2 pol | fine=1,t=30, 4 chan, 2 pol | fine=1,t=31, 4 chan, 2 pol |  ---- 
--      |        ...                 |          ...              |        ...                 |           ...              |  HBM packet for fine channel = 1           
--      | fine=1, t=0, 4 chan,2 pol  | fine=1,t=1, 4 chan,2 pol  | fine=1,t=2, 4 chan, 2 pol  | fine=1,t=3, 4 chan, 2 pol  |                                     Total 3456 packets of 8 words each = 27648 words
--      | fine=0, t=28, 4 chan,2 pol | fine=0,t=29, 4 chan,2 pol | fine=0,t=30, 4 chan, 2 pol | fine=0,t=31, 4 chan, 2 pol |  ----                                |
--      |        ...                 |          ...              |        ...                 |           ...              |  HBM packet for fine channel = 0     |    
--      | fine=0, t=4, 4 chan,2 pol  | fine=0,t=5, 4 chan,2 pol  | fine=0,t=6, 4 chan, 2 pol  | fine=0,t=7, 4 chan, 2 pol  |  8 x 512 bit words                   |
--      | fine=0, t=0, 4 chan,2 pol  | fine=0,t=1, 4 chan,2 pol  | fine=0,t=2, 4 chan, 2 pol  | fine=0,t=3, 4 chan, 2 pol  |                                      |
--      |----------------------------|---------------------------|----------------------------|----------------------------|  ---                                ---------- 
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
--      - bits 15:9 = 128 different groups of virtual channels (4 virtual channels in each HBM write)
--          *!! Using these address bits is critical, since it allows the readout to read multiple 512-byte blocks at a time.
--           !! Readout can thus read at the full HBM rate, close to 100Gb/sec.
--           !! Write data rate is 25.6Gb/sec, so this means the readout can read the data 3 or 4 times.
--           !! Multiple reads of the same data reduces the buffer memory required in the correlator long term accumulator.
--      - bits 27:16 = 3456 different fine channels
--      - bits 31:28 = 12 blocks of 32 times (2 buffers) * (192 times per buffer) / (32 times per 512 byte HBM write) 
--          - So bits 31:28 run from 0 to 11, for 3 Gbytes of memory, with 0 to 5 being the first 192 time samples, and 6-11 being the second 192 time samples.
----------------------------------------------------------------------------------
library IEEE, ct_lib, DSP_top_lib, common_lib, axi4_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use DSP_top_lib.DSP_top_pkg.all;
USE common_lib.common_pkg.ALL;
use axi4_lib.axi4_lite_pkg.ALL;
USE axi4_lib.axi4_full_pkg.ALL;
use ct_lib.corr_ct2_reg_pkg.all;
Library xpm;
use xpm.vcomponents.all;

entity corr_ct2_top is
    generic (
        g_USE_META : boolean := FALSE;   -- Put meta data into the memory in place of the actual data, to make it easier to find bugs in the corner turn. 
        g_CORRELATORS : integer := 2;    -- Number of correlator cells to instantiate.
        g_MAX_CORRELATORS : integer := 2 -- Maximum number of correlator cells that can be instantiated.
    );
    port(
        -- Registers AXI Lite Interface (uses i_axi_clk)
        i_axi_clk  : in std_logic;
        i_axi_rst  : in std_logic;
        i_axi_mosi : in t_axi4_lite_mosi;
        o_axi_miso : out t_axi4_lite_miso;
        -- pipelined reset from first stage corner turn ?
        i_rst : in std_logic;   -- First data received after this reset is placed in the first 283ms block in a 849 ms integration.
        -- configuration data from registers in other modules
        i_virtualChannels   : in std_logic_vector(10 downto 0); -- total virtual channels 
        -- Data in from the correlator filterbanks; bursts of 3456 clocks for each channel.
        -- (on i_axi_clk)
        i_sof          : in std_logic; -- pulse high at the start of every frame. (1 frame is 283 ms of data).
        i_frameCount   : in std_logic_vector(31 downto 0); -- intra-frame count; Each count here is a block of 4096 LFAA samples = 1 time sample at the filterbank output.
        i_virtualChannel : in t_slv_16_arr(3 downto 0);    -- 4 virtual channels, one for each of the data streams.
        i_HeaderValid : in std_logic_vector(3 downto 0);
        i_data        : in t_ctc_output_payload_arr(3 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), i_data(2), i_data(3)
        i_dataValid   : in std_logic;
        ---------------------------------------------------------------
        -- Data out to the correlator arrays
        --
        -- The correlator is ready to receive a new block of data. This will go low once data starts to be received.
        -- A block of data consists of data for 64 times, and up to 512 virtual channels.
        i_cor_ready  : in std_logic_vector(g_MAX_CORRELATORS-1 downto 0);  
        -- Each 256 bit word : two time samples, 4 consecutive virtual channels
        -- (31:0) = time 0, virtual channel 0; (63:32) = time 0, virtual channel 1; (95:64) = time 0, virtual channel 2; (127:96) = time 0, virtual channel 3;
        -- (159:128) = time 1, virtual channel 0; (191:160) = time 1, virtual channel 1; (223:192) = time 1, virtual channel 2; (255:224) = time 1, virtual channel 3;
        o_cor_data   : out t_slv_256_arr(g_MAX_CORRELATORS-1 downto 0); 
        -- meta data
        o_cor_time    : out t_slv_8_arr(g_MAX_CORRELATORS-1 downto 0);  -- time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
        o_cor_station : out t_slv_12_arr(g_MAX_CORRELATORS-1 downto 0); -- first of the 4 stations in o_cor0_data
        o_cor_valid   : out std_logic_vector(g_MAX_CORRELATORS-1 downto 0);
        o_cor_last    : out std_logic_vector(g_MAX_CORRELATORS-1 downto 0);  -- last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.        
        o_cor_final   : out std_logic_vector(g_MAX_CORRELATORS-1 downto 0);  -- Indicates that at the completion of processing the last block of correlator data, the integration is complete.
        o_cor_tileType    : out std_logic_vector(g_MAX_CORRELATORS-1 downto 0);  -- '0' for triangle, '1' for square. Triangles use the same data for the row and column.
        o_cor_first       : out std_logic_vector(g_MAX_CORRELATORS-1 downto 0);  -- This is the first block of data for an integration - i.e. first fine channel, first block of 64 time samples, for this tile
        o_cor_tileLocation : out t_slv_10_arr(g_MAX_CORRELATORS-1 downto 0); -- bits 3:0 = tile column, bits 7:4 = tile row, bits 9:8 = "00";
        o_cor_tileChannel : out t_slv_24_arr(g_MAX_CORRELATORS-1 downto 0);
        o_cor_tileTotalTimes    : out t_slv_8_arr(g_MAX_CORRELATORS-1 downto 0); -- Number of time samples to integrate for this tile.
        o_cor_tiletotalChannels : out t_slv_5_arr(g_MAX_CORRELATORS-1 downto 0); -- Number of frequency channels to integrate for this tile.
        o_cor_rowstations       : out t_slv_9_arr(g_MAX_CORRELATORS-1 downto 0); -- number of stations in the row memories to process; up to 256.
        o_cor_colstations       : out t_slv_9_arr(g_MAX_CORRELATORS-1 downto 0); -- number of stations in the col memories to process; up to 256.
        o_cor_totalStations     : out t_slv_16_arr(g_MAX_CORRELATORS-1 downto 0); -- Total number of stations being processing for this subarray-beam.
        o_cor_subarrayBeam      : out t_slv_8_arr(g_MAX_CORRELATORS-1 downto 0);  -- Which entry is this in the subarray-beam table ? 
        -----------------------------------------------------------------
        -- AXI interface to the HBM
        -- Corner turn between filterbanks and correlator
        -- 3 Gbytes for each correlator cell.
        o_HBM_axi_aw      : out t_axi4_full_addr_arr(g_MAX_CORRELATORS-1 downto 0); -- write address bus : out t_axi4_full_addr_arr(4 downto 0)(.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_awready : in std_logic_vector(g_MAX_CORRELATORS-1 downto 0);
        o_HBM_axi_w       : out t_axi4_full_data_arr(g_MAX_CORRELATORS-1 downto 0); -- w data bus : out t_axi4_full_data_arr(4 downto 0)(.valid, .data(511:0), .last, .resp(1:0))
        i_HBM_axi_wready  : in std_logic_vector(g_MAX_CORRELATORS-1 downto 0);
        i_HBM_axi_b       : in t_axi4_full_b_arr(g_MAX_CORRELATORS-1 downto 0);     -- write response bus : in t_axi4_full_b_arr(4 downto 0)(.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        o_HBM_axi_ar      : out t_axi4_full_addr_arr(g_MAX_CORRELATORS-1 downto 0); -- read address bus : out t_axi4_full_addr_arr(4 downto 0)(.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_arready : in std_logic_vector(g_MAX_CORRELATORS-1 downto 0);
        i_HBM_axi_r       : in t_axi4_full_data_arr(g_MAX_CORRELATORS-1 downto 0);  -- r data bus : in t_axi4_full_data_arr(4 downto 0)(.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_rready  : out std_logic_vector(g_MAX_CORRELATORS-1 downto 0);
        -- signals used in testing to initiate readout of the buffer when HBM is preloaded with data,
        -- so we don't have to wait for the previous processing stages to complete.
        i_readout_start : in std_logic;
        i_readout_buffer : in std_logic
    );
end corr_ct2_top;

architecture Behavioral of corr_ct2_top is
    
    signal statctrl_ro : t_statctrl_ro;
    signal statctrl_rw : t_statctrl_rw;
    signal frameCount_mod3 : std_logic_vector(1 downto 0) := "00";
    signal frameCount_849ms : std_logic_vector(31 downto 0);
    signal frameCount_startup : std_logic := '1';
    signal previous_framecount : std_logic_vector(11 downto 0) := "000000000000";
    signal buf0_fineIntegrations, buf1_fineIntegrations : std_logic_vector(4 downto 0);
    signal vc_demap_in : t_statctrl_vc_demap_ram_in;
    signal subarray_beam_in : t_statctrl_subarray_beam_ram_in;
    signal vc_demap_out : t_statctrl_vc_demap_ram_out;
    signal subarray_beam_out : t_statctrl_subarray_beam_ram_out;
    signal vc_demap_rd_data, SB_rd_data : std_logic_vector(31 downto 0);
    signal vc_demap_rd_addr : std_logic_vector(7 downto 0);
    signal din_SB_addr : std_logic_vector(7 downto 0);
    --signal din_subarray_beam_read : std_logic;
    signal din_SB_valid : std_logic; -- SB data is valid.
    signal din_SB_stations : std_logic_vector(15 downto 0);    -- The number of (sub)stations in this subarray-beam
    signal din_SB_coarseStart : std_logic_vector(15 downto 0); -- The first coarse channel in this subarray-beam
    signal din_SB_fineStart : std_logic_vector(15 downto 0);   -- The first fine channel in this subarray-beam
    signal din_SB_n_fine : std_logic_Vector(23 downto 0);      -- The number of fine channels in this subarray-beam
    signal din_SB_HBM_base_addr : std_logic_vector(31 downto 0); --  Base address in HBM for this subarray-beam.
    signal dout_SB_req, dout_SB_req_del1, dout_SB_valid : std_logic_vector(g_MAX_CORRELATORS-1 downto 0);  -- subarray-beam data below is valid; goes low when o_get_subarray_beam goes high, then goes high again once the parameters are valid.
    signal dout_SB_stations : t_slv_16_arr(g_MAX_CORRELATORS-1 downto 0);    -- The number of (sub)stations in this subarray-beam
    signal dout_SB_coarseStart : t_slv_16_arr(g_MAX_CORRELATORS-1 downto 0); -- The first coarse channel in this subarray-beam
    signal dout_SB_fineStart : t_slv_16_arr(g_MAX_CORRELATORS-1 downto 0);   -- The first fine channel in this subarray-beam
    signal dout_SB_n_fine : t_slv_24_arr(g_MAX_CORRELATORS-1 downto 0);      -- The number of fine channels in this subarray-beam
    signal dout_SB_fineIntegrations : t_slv_6_arr(g_MAX_CORRELATORS-1 downto 0);  -- Number of fine channels to integrate
    signal dout_SB_timeIntegrations : t_slv_2_arr(g_MAX_CORRELATORS-1 downto 0);  -- in (1:0);  Number of time samples per integration.
    signal dout_SB_HBM_base_addr : t_slv_32_arr(g_MAX_CORRELATORS-1 downto 0);    -- in (31:0)  Base address in HBM for this subarray-beam.
    signal cur_readout_SB : t_slv_7_arr(g_MAX_CORRELATORS-1 downto 0);
    signal total_subarray_beams : t_slv_16_arr(g_MAX_CORRELATORS-1 downto 0);
    signal dout_SB_done : std_logic_vector(15 downto 0);
    type SB_rd_fsm_type is (idle, get_din_rd1, get_din_rd2, get_din_rd3, get_din_rd4, get_dout_rd1, get_dout_rd2, get_dout_rd3, get_dout_rd4);
    signal SB_rd_fsm, SB_rd_fsm_del1, SB_rd_fsm_del2, SB_rd_fsm_del3 : SB_rd_fsm_type;
    signal dout_SB_sel, dout_SB_sel_del1, dout_SB_sel_del2, dout_SB_sel_del3 : std_logic_vector(0 downto 0);
    signal SB_addr : std_logic_vector(10 downto 0);
    signal din_SB_req : std_logic;
    signal readout_tableSelect : std_logic := '0';
    signal din_tableSelect : std_logic := '0';
    signal last_channel : std_logic_vector(10 downto 0);
    signal recent_virtualChannel : std_logic_vector(15 downto 0);
    signal lastTime : std_logic;
    
    signal vc_demap_req : std_logic;  -- request a read from address o_vc_demap_rd_addr
    signal vc_demap_data_valid   : std_logic;  -- Read data below (i_demap* signals) is valid.
    signal vc_demap_SB_index     : std_logic_vector(7 downto 0);  -- index into the subarray-beam table.
    signal vc_demap_station      : std_logic_vector(11 downto 0); -- station index within the subarray-beam.
    signal vc_demap_skyFrequency : std_logic_vector(8 downto 0);  -- sky frequency.
    signal vc_demap_valid        : std_logic;                     -- This entry in the demap table is valid.
    signal vc_demap_fw_start     : std_logic_vector(11 downto 0);  -- first fine channel to forward as a packet to the 100GE
    signal vc_demap_fw_end       : std_logic_vector(11 downto 0); -- Last fine channel to forward as a packet to the 100GE
    signal vc_demap_fw_dest      : std_logic_vector(7 downto 0);  -- Tag for the packet.
    signal vc_demap_req_del1, vc_demap_req_del2 : std_logic;
    
    signal readout_start_int, readout_start, readout_buffer_int, readout_buffer : std_logic := '0';
    
begin
    
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            if i_rst = '1' then
                frameCount_mod3 <= "00";
                frameCount_849ms <= (others => '0');
                frameCount_startup <= '1';
            elsif (i_sof = '1') then
                -- This picks up the framecount for the first packet in the frame = 283ms of data.
                -- If the framecount is the same as the framecount for the first frame from the previous i_sof,
                -- then we are just going to the next virtual channel; if different, then we have moved on to the next 283ms block.
                -- Maybe we could also just check that i_virtualChannel(0) = 0 ?
                previous_framecount <= i_frameCount(11 downto 0);  -- just 12 bits, since we don't need to check every bit of framecount to see if it has changed.
                frameCount_startup <= '0';
                if (previous_frameCount /= i_frameCount(11 downto 0)) and frameCount_Startup = '0' then
                    case frameCount_mod3 is
                        when "00" => frameCount_mod3 <= "01";
                        when "01" => frameCount_mod3 <= "10";
                        when others => 
                            frameCount_mod3 <= "00";
                            frameCount_849ms <= std_logic_vector(unsigned(frameCount_849ms) + 1);
                    end case;
                end if;
            end if;
            
            last_channel <= std_logic_vector(unsigned(i_virtualChannels) - 1);
            
            if i_headerValid(0) = '1' then
                recent_virtualChannel <= i_virtualChannel(3);
            end if;
            
            if (frameCount_mod3 = "10" and (unsigned(recent_virtualChannel) = unsigned(last_channel)) and (lastTime = '1')) then
                readout_start_int <= '1';
                readout_buffer_int <= frameCount_849ms(0);
            else
                readout_start_int <= '0';
            end if;
            
            if i_readout_start = '1' then
                readout_start <= '1';
                readout_buffer <= i_readout_buffer;
            else
                readout_start <= readout_start_int;
                readout_buffer <= readout_buffer_int;
            end if;
            
        end if;
    end process;
    
    -- corr_ct2_din has buffers and logic for 1024 virtual channels = two correlator cells.
    din_inst : entity ct_lib.corr_ct2_din
    generic map (
        g_USE_META => g_USE_META  -- Put meta data into the memory in place of the actual data, to make it easier to find bugs in the corner turn.
    ) port map (
        -- Data in from the correlator filterbanks; bursts of 3456 clocks for each channel.
        -- 
        i_sof              => i_sof,            -- in std_logic; -- pulse high at the start of every frame. (1 frame is typically 60ms of data).
        i_tableSelect      => statctrl_rw.table_select, -- in std_logic;
        i_frameCount_mod3  => frameCount_mod3,  -- in(1:0)
        i_frameCount_849ms => frameCount_849ms, -- in (31:0)
        i_virtualChannel   => i_virtualChannel, -- in t_slv_16_arr(3 downto 0); -- 4 virtual channels, one for each of the data streams.
        i_HeaderValid      => i_headerValid,    -- in std_logic_vector(3 downto 0);
        i_data             => i_data,           -- in t_ctc_output_payload_arr(3 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), i_data(2)
        i_dataValid        => i_dataValid,      -- in std_logic;
        o_lastTime         => lastTime,         -- out std_logic; last time sample for a particular virtual channel received.
        
        -- interface to the demap table
        o_vc_demap_rd_addr   => vc_demap_rd_Addr,    -- out (7:0);  address into the demap table, 0-255 = floor(virtual_channel / 4)
        o_vc_demap_req       => vc_demap_req,        -- out std_logic;  -- request a read from address o_vc_demap_rd_addr
        i_demap_data_valid   => vc_demap_data_valid, -- in std_logic;  -- Read data below (i_demap* signals) is valid.
        i_demap_SB_index     => vc_demap_SB_index,   -- in (7:0);  -- index into the subarray-beam table.
        i_demap_station      => vc_demap_station,    -- in (11:0); -- station index within the subarray-beam.
        i_demap_skyFrequency => vc_demap_skyFrequency, -- in (8:0);  -- sky frequency.
        i_demap_valid        => vc_demap_valid,        -- in std_logic;                     -- This entry in the demap table is valid.
        i_demap_fw_start     => vc_demap_fw_start,     -- in (11:0);  -- first fine channel to forward as a packet to the 100GE
        i_demap_fw_end       => vc_demap_fw_end,       -- in (11:0); -- Last fine channel to forward as a packet to the 100GE
        i_demap_fw_dest      => vc_demap_fw_dest,      -- out (7:0);  -- Tag for the packet.         
        
        -- Interface to the subarray_beam table
        o_SB_addr          => din_SB_addr,          -- out (7:0);
        o_SB_req           => din_SB_req,           -- out std_logic;
        i_SB_valid         => din_SB_valid,         -- in std_logic; SB data is valid.
        i_SB_stations      => din_SB_stations,      -- in (15:0); The number of (sub)stations in this subarray-beam
        i_SB_coarseStart   => din_SB_coarseStart,   -- in (15:0); The first coarse channel in this subarray-beam
        i_SB_fineStart     => din_SB_fineStart,     -- in (15:0); The first fine channel in this subarray-beam
        i_SB_n_fine        => din_SB_n_fine,        -- in (23:0); The number of fine channels in this subarray-beam
        i_SB_HBM_base_addr => din_SB_HBM_base_addr, -- in (31:0); Base address in HBM for this subarray-beam.
        
        -- AXI interface to the HBM
        -- Corner turn between filterbanks and correlator
        -- two HBM interfaces
        i_axi_clk      => i_axi_clk,         -- in std_logic;
        -- 2 blocks of memory, 3 Gbytes for virtual channels 0-511, 3 Gbytes for virtual channels 512-1023
        o_HBM_axi_aw      => o_HBM_axi_aw(1 downto 0),      -- out t_axi4_full_addr_arr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_awready => i_HBM_axi_awready(1 downto 0), -- in  std_logic_vector;
        o_HBM_axi_w       => o_HBM_axi_w(1 downto 0),       -- out t_axi4_full_data_arr; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_HBM_axi_wready  => i_HBM_axi_wready(1 downto 0),  -- in  std_logic_vector;
        i_HBM_axi_b       => i_HBM_axi_b(1 downto 0)        -- in  t_axi4_full_b_arr     -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.       
    );
    
    
    corrgen : for i in 0 to (g_CORRELATORS-1) generate
    
        cori : entity ct_lib.corr_ct2_dout
        port map (
            -- Only uses the 300 MHz clock.
            i_axi_clk   => i_axi_clk, --  in std_logic;
            i_start     => readout_start, --  in std_logic; -- start reading out data to the correlators
            i_buffer    => readout_buffer, --  in std_logic; -- which of the double buffers to read out ?
            
            -- Data from the subarray beam table. After o_SB_req goes high, i_SB_valid will be driven high with requested data from the table on the other busses.
            o_SB_req   => dout_SB_req(i),    -- Rising edge gets the parameters for the next subarray-beam to read out.
            i_SB       => cur_readout_SB(i), -- in (6:0); which subarray-beam are we currently processing from the subarray-beam table.
            i_SB_valid => dout_SB_valid(i),  -- subarray-beam data below is valid; goes low when o_get_subarray_beam goes high, then goes high again once the parameters are valid.
            i_SB_done  => dout_SB_done(i),   -- Indicates that all the subarray beams for this correlator core has been processed.
            i_stations => dout_SB_stations(i),                 -- in (15:0); The number of (sub)stations in this subarray-beam
            i_coarseStart => dout_SB_coarseStart(i),           -- in (15:0); The first coarse channel in this subarray-beam
            i_fineStart => dout_SB_fineStart(i),               -- in (15:0); The first fine channel in this subarray-beam
            i_n_fine => dout_SB_n_fine(i),                     -- in (23:0); The number of fine channels in this subarray-beam
            i_fineIntegrations => dout_SB_fineIntegrations(i), -- in (5:0);  Number of fine channels to integrate
            i_timeIntegrations => dout_SB_timeIntegrations(i), -- in (1:0);  Number of time samples per integration.
            i_HBM_base_addr    => dout_SB_HBM_base_addr(i),    -- in (31:0)  Base address in HBM for this subarray-beam.
            ---------------------------------------------------------------
            -- Data out to the correlator arrays
            --
            -- correlator 0 is ready to receive a new block of data. This will go low once data starts to be received.
            -- A block of data consists of data for 64 times, and up to 512 virtual channels.
            i_cor_ready => i_cor_ready(i), -- in std_logic;  
            -- Each 256 bit word : two time samples, 4 consecutive virtual channels
            -- (31:0) = time 0, virtual channel 0; (63:32) = time 0, virtual channel 1; (95:64) = time 0, virtual channel 2; (127:96) = time 0, virtual channel 3;
            -- (159:128) = time 1, virtual channel 0; (191:160) = time 1, virtual channel 1; (223:192) = time 1, virtual channel 2; (255:224) = time 1, virtual channel 3;
            o_cor_data  => o_cor_data(i), --  out (255:0); 
            -- meta data
            o_cor_time => o_cor_time(i),       -- out (7:0); Time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
            o_cor_station => o_cor_station(i), -- out (11:0); First of the 4 virtual channels in o_cor0_data
            o_cor_valid => o_cor_valid(i),     -- out std_logic;
            o_cor_last  => o_cor_last(i),      -- out std_logic; Last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
            o_cor_final => o_cor_final(i),     -- out std_logic; Indicates that at the completion of processing the last block of correlator data, the integration is complete.
            o_cor_tileType => o_cor_tileType(i), -- out std_logic;
            o_cor_first    => o_cor_first(i),    -- out std_logic;  -- This is the first block of data for an integration - i.e. first fine channel, first block of 64 time samples, for this tile
            o_cor_tile_location => o_cor_tileLocation(i), -- out (9:0);
            o_cor_tileChannel => o_cor_tileChannel(i),    -- out (23:0);
            o_cor_tileTotalTimes => o_cor_tileTotalTimes(i), -- out (7:0);  Number of time samples to integrate for this tile.
            o_cor_tiletotalChannels => o_cor_tileTotalChannels(i), -- out (4:0); Number of frequency channels to integrate for this tile.
            o_cor_rowstations       => o_cor_rowStations(i), -- out (8:0); Number of stations in the row memories to process; up to 256.
            o_cor_colstations       => o_cor_colStations(i), -- out (8:0); Number of stations in the col memories to process; up to 256.
            o_cor_subarray_beam     => o_cor_subarrayBeam(i), -- out (7:0); Which entry is this in the subarray-beam table ? 
            o_cor_totalStations     => o_cor_totalStations(i), -- out (15:0); Total number of stations being processing for this subarray-beam.
            ----------------------------------------------------------------
            -- read interfaces for the HBM
            o_HBM_axi_ar      => o_HBM_axi_ar(i),      -- out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
            i_HBM_axi_arready => i_HBM_axi_arready(i), -- in  std_logic;
            i_HBM_axi_r       => i_HBM_axi_r(i),       -- in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
            o_HBM_axi_rready  => o_HBM_axi_rready(i)   -- out std_logic
        );
    
    end generate;
    
    corrNoGen : for i in g_CORRELATORS to (g_MAX_CORRELATORS-1) generate
        
        o_cor_data(i) <= (others => '0');
        o_cor_time(i) <= (others => '0');
        o_cor_station(i) <= (others => '0');
        o_cor_valid(i) <= '0';
        o_cor_last(i) <= '0';
        o_cor_final(i) <= '0';
        o_cor_tileType(i) <= '0';
        o_cor_first(i) <= '0';
        o_cor_tileLocation(i) <= (others => '0');
        o_cor_tileChannel(i) <= (others => '0');
        o_cor_tileTotalTimes(i) <= (others => '0');
        o_cor_tileTotalChannels(i) <= (others => '0');
        o_cor_rowStations(i) <= (others => '0');
        o_cor_colStations(i) <= (others => '0');
        
        o_HBM_axi_ar(i).valid <= '0';
        o_HBM_axi_ar(i).addr <= (others => '0');
        o_HBM_axi_ar(i).len <= (others => '0');
        o_HBM_axi_rready(i) <= '1';
        dout_SB_req(i) <= '0';
        
    end generate;     
    
    ------------------------------------------------------------------------------
    -- Registers
    reginst : entity ct_lib.corr_ct2_reg
    PORT map (
        MM_CLK              => i_axi_clk,   -- in  std_logic;
        MM_RST              => i_axi_rst,   -- in  std_logic;
        SLA_IN              => i_axi_mosi,  -- in  t_axi4_lite_mosi;
        SLA_OUT             => o_axi_miso,  -- out t_axi4_lite_miso;
        STATCTRL_FIELDS_RW	=> statctrl_rw, -- out t_statctrl_rw; single field .table_select, .buf0_subarray_beams_table0, .buf0_subarray_beams_table1, .buf1_subarray_beams_table0, .buf1_subarray_beams_table1
        STATCTRL_FIELDS_RO	=> statctrl_ro, -- in  t_statctrl_ro
        STATCTRL_VC_DEMAP_IN       => vc_demap_in,      -- in  t_statctrl_vc_demap_ram_in;
        STATCTRL_VC_DEMAP_OUT      => vc_demap_out,     -- out t_statctrl_vc_demap_ram_out;
        STATCTRL_SUBARRAY_BEAM_IN  => subarray_beam_in, -- in  t_statctrl_subarray_beam_ram_in;
        STATCTRL_SUBARRAY_BEAM_OUT => subarray_beam_out -- out t_statctrl_subarray_beam_ram_out
    );
    
    statctrl_ro.bufferoverflowerror <= '0';
    statctrl_ro.readouterror <= '0';
    statctrl_ro.hbmbuf0packetcount <= (others => '0');
    statctrl_ro.hbmbuf1packetcount <= (others => '0');
    statctrl_ro.readinclocks <= (others => '0');
    statctrl_ro.readoutclocks <= (others => '0');
    
    vc_demap_in.adr(9 downto 1) <= din_tableSelect & vc_demap_rd_addr; -- full address is 10 bits
    vc_demap_in.adr(0) <= '0' when vc_demap_req = '1' else '1';
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
            vc_demap_req_del2 <= vc_demap_req_del1;
            vc_demap_data_valid <= vc_demap_req_del2;
            
            if vc_demap_req_del1 = '1' then
                vc_demap_SB_index <= vc_demap_out.rd_dat(7 downto 0);       -- Index into the subarray-beam table.
                vc_demap_station  <= vc_demap_out.rd_dat(19 downto 8);      -- station index within the subarray-beam.
                vc_demap_skyFrequency <= vc_demap_out.rd_dat(28 downto 20); -- sky frequency.
                vc_demap_valid        <= vc_demap_out.rd_dat(31);           -- This entry in the demap table is valid.      
            end if;
            if vc_demap_Req_del2 = '1' then
                vc_demap_fw_start <= vc_demap_out.rd_dat(11 downto 0);  -- first fine channel to forward as a packet to the 100GE
                vc_demap_fw_end   <= vc_demap_out.rd_dat(23 downto 12); -- Last fine channel to forward as a packet to the 100GE
                vc_demap_fw_dest  <= vc_demap_out.rd_dat(31 downto 24); -- Tag for the packet.    
            end if;
            
            ----------------------------------------------------------------------------------------
            -- Logic for reading the subarray-beam table
            --
            if i_sof = '1' and frameCount_mod3 = "00" then
                -- Set the subarray-beam table that is used for writing data into the HBM.
                -- Set at the start of data input for the frame, so it is fixed through the frame.
                din_tableSelect <= statctrl_rw.table_select; 
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
                    if (unsigned(statctrl_rw.buf0_subarray_beams_table0) = 0) then
                        dout_SB_done(0) <= '1';
                    else
                        dout_SB_done(0) <= '0';
                    end if;
                    if (unsigned(statctrl_rw.buf1_subarray_beams_table0) = 0) then
                        dout_SB_done(1) <= '1';
                    else
                        dout_SB_done(1) <= '0';
                    end if;
                else
                    readout_tableSelect <= '1';
                    total_subarray_beams(0) <= statctrl_rw.buf0_subarray_beams_table1;
                    total_subarray_beams(1) <= statctrl_rw.buf1_subarray_beams_table1;
                    if (unsigned(statctrl_rw.buf0_subarray_beams_table1) = 0) then
                        dout_SB_done(0) <= '1';
                    else
                        dout_SB_done(0) <= '0';
                    end if;
                    if (unsigned(statctrl_rw.buf1_subarray_beams_table1) = 0) then
                        dout_SB_done(1) <= '1';
                    else
                        dout_SB_done(1) <= '0';
                    end if;
                end if;
                -- Where we are currently up to in the subarray-beam table for each correlator cell readout.
                for i in 0 to (g_MAX_CORRELATORS-1) loop
                    cur_readout_SB(i) <= (others => '0');
                end loop;
            else
                for i in 0 to (g_MAX_CORRELATORS - 1) loop
                    if (SB_rd_fsm_del3 = get_dout_rd4) and (unsigned(dout_SB_sel) = i) then
                        -- use fsm_del3 so that dout_SB_done will only be set after dout_SB_valid.
                        cur_readout_SB(i) <= std_logic_vector(unsigned(cur_readout_SB(i)) + 1);
                    end if;
                    if (unsigned(cur_readout_SB(i)) = unsigned(total_subarray_beams(i))) then
                        dout_SB_done(i) <= '1';
                    else
                        dout_SB_done(i) <= '0';
                    end if;
                end loop;
            end if;
            
            dout_sb_req_del1 <= dout_sb_req;
            
            -- This fsm handles reading from the subarray-beam table in the registers.
            -- There are multiple modules contending for access to the table; : 
            --  - The data input side, "corr_ct2_din", for working out where in HBM to put data from the filterbanks
            --  - The one, two or maybe more data output modules ("corr_ct2_dout")
            -- The output modules ask for the next subarray beam, and after the data has been read here it is placed in registers for the output module to use.
            case SB_rd_fsm is
                when idle =>
                    if din_SB_req = '1' then
                        SB_rd_fsm <= get_din_rd1;
                    elsif unsigned(dout_SB_req) /= 0 then
                        SB_rd_fsm <= get_dout_rd1;
                        for i in 0 to (g_MAX_CORRELATORS-1) loop
                            if dout_SB_req(i) = '1' then
                                dout_SB_sel_v := i;
                            end if;
                        end loop;
                        if dout_SB_sel_v = 0 then
                            dout_SB_sel(0) <= '0';
                        elsif dout_SB_sel_v = 1 then
                            dout_SB_sel(0) <= '1';
                        end if;
                    end if;
                
                when get_din_rd1 =>
                    SB_addr(10) <= din_tableSelect;
                    SB_addr(9 downto 2) <= din_SB_addr; -- 8 bits
                    SB_addr(1 downto 0) <= "00";
                    SB_rd_fsm <= get_din_rd2;
                    
                when get_din_rd2 => 
                    SB_addr(1 downto 0) <= "01";
                    SB_rd_fsm <= get_din_rd3;
                
                when get_din_rd3 =>
                    SB_addr(1 downto 0) <= "10";
                    SB_rd_fsm <= get_din_rd4;
                
                when get_din_rd4 => 
                    SB_addr(1 downto 0) <= "11";
                    SB_rd_fsm <= idle;
                
                when get_dout_rd1 =>
                    SB_addr(10) <= readout_tableSelect;
                    SB_addr(9) <= dout_SB_sel(0); -- just 0 or 1; need to expand this to more bits if there are more than 2 correlator cells.
                    SB_addr(8 downto 2) <= cur_readout_SB(to_integer(unsigned(dout_SB_sel)));
                    SB_addr(1 downto 0) <= "00";
                    SB_rd_fsm <= get_dout_rd2;
            
                when get_dout_rd2 =>
                    SB_addr(1 downto 0) <= "01";
                    SB_rd_fsm <= get_dout_rd3;
                
                when get_dout_rd3 =>
                    SB_addr(1 downto 0) <= "10";
                    SB_rd_fsm <= get_dout_rd4;
                
                when get_dout_rd4 =>
                    SB_addr(1 downto 0) <= "11";
                    SB_rd_fsm <= idle;
                
                when others =>
                    SB_rd_fsm <= idle;
            
            end case;
            
            -- del1 : SB_addr is valid
            SB_rd_fsm_del1 <= SB_rd_fsm;
            dout_SB_sel_del1 <= dout_SB_sel;
            
            -- del2 : subarray_beam_out.rd_dat is valid.
            SB_rd_fsm_del2 <= SB_rd_fsm_del1;
            dout_SB_sel_del2 <= dout_SB_sel_del1;
            
            -- del3  : SB_rd_data is valid
            SB_rd_fsm_del3 <= SB_rd_fsm_del2;
            dout_SB_sel_del3 <= dout_SB_sel_del2;
            SB_rd_data <= subarray_beam_out.rd_dat;
            
            -- Assign din and dout data read from the subarray-beam table
            if (SB_rd_fsm_del3 = get_din_rd1) then
                din_SB_stations <= SB_rd_data(15 downto 0);
                din_SB_coarseStart <= SB_rd_data(31 downto 16);
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
            
            if (SB_rd_fsm_del3 = get_dout_rd1) then
                dout_SB_stations(to_integer(unsigned(dout_SB_sel_del3))) <= SB_rd_data(15 downto 0);
                dout_SB_coarseStart(to_integer(unsigned(dout_SB_sel_del3))) <= SB_rd_data(31 downto 16);
            end if;
            if (SB_rd_fsm_del3 = get_dout_rd2) then
                dout_SB_fineStart(to_integer(unsigned(dout_SB_sel_del3))) <= SB_rd_data(15 downto 0);
            end if;
            if (SB_rd_fsm_del3 = get_dout_rd3) then
                dout_SB_n_fine(to_integer(unsigned(dout_SB_sel_del3))) <= SB_rd_data(23 downto 0);
                dout_SB_fineIntegrations(to_integer(unsigned(dout_SB_sel_del3))) <= SB_rd_data(29 downto 24);
                dout_SB_timeIntegrations(to_integer(unsigned(dout_SB_sel_del3))) <= SB_rd_data(31 downto 30);
            end if;
            dout_SB_valid <= (others => '0');
            if (SB_rd_fsm_del3 = get_dout_rd4) then
                dout_SB_HBM_base_addr(to_integer(unsigned(dout_SB_sel_del3))) <= SB_rd_data(31 downto 0);
                dout_SB_valid(to_integer(unsigned(dout_SB_sel_del3))) <= '1';
            end if;
            
        end if;
    end process;

    
    -- Note : 4 words of data in the subarray-beam table per entry, with : 
    --     Word 0 : bits(15:0) = number of (sub)stations in this subarray-beam, \
    --              bits(31:16) = starting coarse frequency channel, \
    --     Word 1 : bits (15:0) = starting fine frequency channel \
    --     word 2 : bits (23:0) = Number of fine channels stored \
    --              bits (29:24) = Fine channels per integration \
    --              bits (31:30) = integration time; 0 = 283 ms, 1 = 849 ms, others invalid \
    --     Word 3 : bits (31:0) = Base Address in HBM within a 1.5 Gbyte block to store this subarray beam \
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
    
    
    
end Behavioral;
