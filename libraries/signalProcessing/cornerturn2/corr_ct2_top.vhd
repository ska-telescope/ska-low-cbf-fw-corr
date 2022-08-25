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
        g_USE_META : boolean := FALSE; -- Put meta data into the memory in place of the actual data, to make it easier to find bugs in the corner turn. 
        g_USE_TWO_CORRELATORS : boolean := TRUE
    );
    port(
    
        -- Parameters, in the i_axi_clk domain.
        i_stations : in std_logic_vector(10 downto 0); -- up to 1024 stations
        i_coarse   : in std_logic_vector(9 downto 0);  -- Number of coarse channels.
        i_virtualChannels : in std_logic_vector(10 downto 0); -- total virtual channels (= i_stations * i_coarse)
        -- Registers AXI Lite Interface (uses i_axi_clk)
        i_axi_clk  : in std_logic;
        i_axi_rst  : in std_logic;
        i_axi_mosi : in t_axi4_lite_mosi;
        o_axi_miso : out t_axi4_lite_miso;
        -- pipelined reset from first stage corner turn ?
        i_rst : in std_logic;   -- First data received after this reset is placed in the first 283ms block in a 849 ms integration.
        -- Data in from the correlator filterbanks; bursts of 3456 clocks for each channel.
        -- (on i_axi_clk)
        i_sof          : in std_logic; -- pulse high at the start of every frame. (1 frame is 283 ms of data).
        i_frameCount   : in std_logic_vector(36 downto 0); -- LFAA frame count
        i_virtualChannel : in t_slv_16_arr(3 downto 0); -- 4 virtual channels, one for each of the PST data streams.
        i_HeaderValid : in std_logic_vector(3 downto 0);
        i_data        : in t_ctc_output_payload_arr(3 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), i_data(2), i_data(3)
        i_dataValid   : in std_logic;
        ---------------------------------------------------------------
        -- Data out to the correlator arrays
        --
        -- correlator 0 is ready to receive a new block of data. This will go low once data starts to be received.
        -- A block of data consists of data for 64 times, and up to 512 virtual channels.
        i_cor0_ready    : in std_logic;  
        -- Each 256 bit word : two time samples, 4 consecutive virtual channels
        -- (31:0) = time 0, virtual channel 0; (63:32) = time 0, virtual channel 1; (95:64) = time 0, virtual channel 2; (127:96) = time 0, virtual channel 3;
        -- (159:128) = time 1, virtual channel 0; (191:160) = time 1, virtual channel 1; (223:192) = time 1, virtual channel 2; (255:224) = time 1, virtual channel 3;
        o_cor0_data     : out std_logic_vector(255 downto 0); 
        -- meta data
        o_cor0_time     : out std_logic_vector(7 downto 0); -- time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
        o_cor0_VC       : out std_logic_vector(11 downto 0); -- first of the 4 virtual channels in o_cor0_data
        o_cor0_FC       : out std_logic_vector(11 downto 0); -- which 226 Hz fine channel is this ? 0 to 3455.
        o_cor0_triangle : out std_logic_vector(3 downto 0); -- which correlator triangle is this data for ? 0 to 3 for modes that don't use substations.
        o_cor0_valid    : out std_logic;
        o_cor0_last     : out std_logic;  -- last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.        
        o_cor0_final : out std_logic;  -- Indicates that at the completion of processing the last block of correlator data, the integration is complete.
        --
        i_cor1_ready    : in std_logic;  
        -- Each 256 bit word : two time samples, 4 consecutive virtual channels
        -- (31:0) = time 0, virtual channel 0; (63:32) = time 0, virtual channel 1; (95:64) = time 0, virtual channel 2; (127:96) = time 0, virtual channel 3;
        -- (159:128) = time 1, virtual channel 0; (191:160) = time 1, virtual channel 1; (223:192) = time 1, virtual channel 2; (255:224) = time 1, virtual channel 3;
        o_cor1_data     : out std_logic_vector(255 downto 0); 
        -- meta data
        o_cor1_time     : out std_logic_vector(7 downto 0); -- time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
        o_cor1_VC       : out std_logic_vector(11 downto 0); -- first of the 4 virtual channels in o_cor0_data
        o_cor1_FC       : out std_logic_vector(11 downto 0); -- which 226 Hz fine channel is this ? 0 to 3455.
        o_cor1_triangle : out std_logic_vector(3 downto 0); -- which correlator triangle is this data for ? 0 to 3 for modes that don't use substations.
        o_cor1_valid    : out std_logic;
        o_cor1_last     : out std_logic;  -- last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
        o_cor1_final : out std_logic;  -- Indicates that at the completion of processing the last block of correlator data, the integration is complete.
        -- AXI interface to the HBM
        -- Corner turn between filterbanks and correlator
        -- 3 Gbytes for virtual channels 0-511
        o_HBM0_axi_aw      : out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM0_axi_awready : in  std_logic;
        o_HBM0_axi_w       : out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_HBM0_axi_wready  : in  std_logic;
        i_HBM0_axi_b       : in  t_axi4_full_b;    -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        o_HBM0_axi_ar      : out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM0_axi_arready : in  std_logic;
        i_HBM0_axi_r       : in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_HBM0_axi_rready  : out std_logic;
        -- 3 Gbytes for virtual channels 512-1023
        o_HBM1_axi_aw      : out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM1_axi_awready : in  std_logic;
        o_HBM1_axi_w       : out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_HBM1_axi_wready  : in  std_logic;
        i_HBM1_axi_b       : in  t_axi4_full_b;    -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        o_HBM1_axi_ar      : out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM1_axi_arready : in  std_logic;
        i_HBM1_axi_r       : in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_HBM1_axi_rready  : out std_logic
    );
end corr_ct2_top;

architecture Behavioral of corr_ct2_top is
    
    signal statctrl_ro : t_statctrl_ro;
    signal frameCount_mod3 : std_logic_vector(1 downto 0) := "00";
    signal frameCount_startup : std_logic := '1';
    signal previous_framecount : std_logic_vector(11 downto 0) := "000000000000";
    signal buf0_virtualChannels, buf1_virtualChannels : std_logic_vector(11 downto 0);
    signal buf0_fineIntegrations, buf1_fineIntegrations : std_logic_vector(4 downto 0);
    
begin
    
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            if i_rst = '1' then
                frameCount_mod3 <= "00";
                frameCount_startup <= '1';
            elsif (i_sof = '1') then
                previous_framecount <= i_frameCount(11 downto 0);  -- just 12 bits, since we don't need to check every bit of framecount to see if it has changed.
                frameCount_startup <= '0';
                if (previous_frameCount /= i_frameCount(11 downto 0)) and frameCount_Startup = '0' then
                    case frameCount_mod3 is
                        when "00" => frameCount_mod3 <= "01";
                        when "01" => frameCount_mod3 <= "10";
                        when others => frameCount_mod3 <= "00";
                    end case;
                end if;
            end if;
        end if;
    end process;

    din_inst : entity ct_lib.corr_ct2_din
    generic map (
        g_USE_META => g_USE_META --  boolean := FALSE  -- Put meta data into the memory in place of the actual data, to make it easier to find bugs in the corner turn. 
    ) port map (
        -- Parameters, in the i_axi_clk domain.
        i_stations => i_stations, -- in std_logic_vector(10 downto 0); -- up to 1024 stations
        i_coarse   => i_coarse,   -- in std_logic_vector(9 downto 0);  -- Number of coarse channels.
        i_virtualChannels => i_virtualChannels, --  in std_logic_vector(10 downto 0); -- total virtual channels (= i_stations * i_coarse)
        -- Registers AXI Lite Interface (uses i_axi_clk)
        
        -- Data in from the correlator filterbanks; bursts of 3456 clocks for each channel.
        -- 
        i_sof             => i_sof,            -- in std_logic; -- pulse high at the start of every frame. (1 frame is typically 60ms of data).
        i_frameCount_mod3 => frameCount_mod3, -- in(1:0)
        i_frameCount      => i_frameCount,      -- in (31:0)
        i_virtualChannel  => i_virtualChannel, -- in t_slv_16_arr(3 downto 0); -- 4 virtual channels, one for each of the PST data streams.
        i_HeaderValid     => i_headerValid,    -- in std_logic_vector(3 downto 0);
        i_data            => i_data,           -- in t_ctc_output_payload_arr(3 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), i_data(2)
        i_dataValid       => i_dataValid,      -- in std_logic;
        
        -- AXI interface to the HBM
        -- Corner turn between filterbanks and correlator
        -- two HBM interfaces
        i_axi_clk      => i_axi_clk,         -- in std_logic;
        -- 3 Gbytes for virtual channels 0-511
        o_HBM0_axi_aw      => o_HBM0_axi_aw,      -- out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM0_axi_awready => i_HBM0_axi_awready, -- in  std_logic;
        o_HBM0_axi_w       => o_HBM0_axi_w,       -- out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_HBM0_axi_wready  => i_HBM0_axi_wready,  -- in  std_logic;
        i_HBM0_axi_b       => i_HBM0_axi_b,        -- in  t_axi4_full_b     -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        -- 3 Gbytes for virtual channels 512-1023
        o_HBM1_axi_aw      => o_HBM1_axi_aw,      -- out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM1_axi_awready => i_HBM1_axi_awready, -- in  std_logic;
        o_HBM1_axi_w       => o_HBM1_axi_w,       -- out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_HBM1_axi_wready  => i_HBM1_axi_wready,  -- in  std_logic;
        i_HBM1_axi_b       => i_HBM1_axi_b        -- in  t_axi4_full_b     -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
    );
    
    
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            if unsigned(i_virtualChannels) > 511 then
                buf0_virtualChannels <= std_logic_vector(to_unsigned(512,12));
                buf1_virtualChannels <= std_logic_vector(resize(unsigned(i_virtualChannels),12) - 512);
            else
                buf0_virtualChannels <= std_logic_vector(resize(unsigned(i_virtualChannels),12));
            end if;
            buf0_fineIntegrations <= "11000"; -- default is to integrate 24 fine channels
            buf1_fineIntegrations <= "11000";
        end if;
    end process;
    
    
    cor0i : entity ct_lib.corr_ct2_dout
    port map (
        -- Only uses the 300 MHz clock.
        i_axi_clk   => i_axi_clk, --  in std_logic;
        i_start     => readout_start, --  in std_logic; -- start reading out data to the correlators
        i_buffer    => readout_buffer, --  in std_logic; -- which of the double buffers to read out ?
        i_virtualChannels => buf0_virtualChannels, --  in std_logic_vector(11 downto 0); -- How many virtual channels are there in this buffer ?
        i_fineIntegrations => buf0_fineIntegrations, --  in std_logic_vector(4 downto 0); -- Number of fine channels to integrate, max 24.
        ---------------------------------------------------------------
        -- Data out to the correlator arrays
        --
        -- correlator 0 is ready to receive a new block of data. This will go low once data starts to be received.
        -- A block of data consists of data for 64 times, and up to 512 virtual channels.
        i_cor_ready => i_cor0_ready, -- in std_logic;  
        -- Each 256 bit word : two time samples, 4 consecutive virtual channels
        -- (31:0) = time 0, virtual channel 0; (63:32) = time 0, virtual channel 1; (95:64) = time 0, virtual channel 2; (127:96) = time 0, virtual channel 3;
        -- (159:128) = time 1, virtual channel 0; (191:160) = time 1, virtual channel 1; (223:192) = time 1, virtual channel 2; (255:224) = time 1, virtual channel 3;
        o_cor_data  => o_cor0_data, --  out std_logic_vector(255 downto 0); 
        -- meta data
        o_cor_time => o_cor0_time, -- out std_logic_vector(7 downto 0); -- time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
        o_cor_VC   => o_cor0_VC,   -- out std_logic_vector(11 downto 0); -- first of the 4 virtual channels in o_cor0_data
        o_cor_FC   => o_cor0_FC,   -- out std_logic_vector(11 downto 0); -- which 226 Hz fine channel is this ? 0 to 3455.
        o_cor_triangle => o_cor0_triangle, -- out std_logic_vector(3 downto 0); -- which correlator triangle is this data for ? 0 to 3 for modes that don't use substations.
        o_cor_valid => o_cor0_valid, -- out std_logic;
        o_cor_last  => o_cor0_last,  -- out std_logic;  -- last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
        o_cor_final => o_cor0_final, -- out std_logic;  -- Indicates that at the completion of processing the last block of correlator data, the integration is complete.
        ----------------------------------------------------------------
        -- read interfaces for the HBM
        o_HBM_axi_ar      => o_HBM0_axi_ar,      -- out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_arready => i_HBM0_axi_arready, -- in  std_logic;
        i_HBM_axi_r       => i_HBM0_axi_r,       -- in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_rready  => o_HBM0_axi_rready   -- out std_logic
    );
    
    c2gen : if g_USE_TWO_CORRELATORS generate

        cor1i : entity ct_lib.corr_ct2_dout
        port map (
            -- Only uses the 300 MHz clock.
            i_axi_clk   => i_axi_clk, --  in std_logic;
            i_start     => readout_start, --  in std_logic; -- start reading out data to the correlators
            i_buffer    => readout_buffer, --  in std_logic; -- which of the double buffers to read out ?
            i_virtualChannels => buf1_virtualChannels, --  in std_logic_vector(11 downto 0); -- How many virtual channels are there in this buffer ?
            i_fineIntegrations => buf1_fineIntegrations, --  in std_logic_vector(4 downto 0); -- Number of fine channels to integrate, max 24.
            ---------------------------------------------------------------
            -- Data out to the correlator arrays
            --
            -- correlator 0 is ready to receive a new block of data. This will go low once data starts to be received.
            -- A block of data consists of data for 64 times, and up to 512 virtual channels.
            i_cor_ready => i_cor1_ready, -- in std_logic;  
            -- Each 256 bit word : two time samples, 4 consecutive virtual channels
            -- (31:0) = time 0, virtual channel 0; (63:32) = time 0, virtual channel 1; (95:64) = time 0, virtual channel 2; (127:96) = time 0, virtual channel 3;
            -- (159:128) = time 1, virtual channel 0; (191:160) = time 1, virtual channel 1; (223:192) = time 1, virtual channel 2; (255:224) = time 1, virtual channel 3;
            o_cor_data  => o_cor1_data, --  out std_logic_vector(255 downto 0); 
            -- meta data
            o_cor_time => o_cor1_time, -- out std_logic_vector(7 downto 0); -- time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
            o_cor_VC   => o_cor1_VC,   -- out std_logic_vector(11 downto 0); -- first of the 4 virtual channels in o_cor0_data
            o_cor_FC   => o_cor1_FC,   -- out std_logic_vector(11 downto 0); -- which 226 Hz fine channel is this ? 0 to 3455.
            o_cor_triangle => o_cor1_triangle, -- out std_logic_vector(3 downto 0); -- which correlator triangle is this data for ? 0 to 3 for modes that don't use substations.
            o_cor_valid => o_cor1_valid, -- out std_logic;
            o_cor_last  => o_cor1_last,  -- out std_logic;  -- last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
            o_cor_final => o_cor1_final, -- out std_logic;  -- Indicates that at the completion of processing the last block of correlator data, the integration is complete.
            ----------------------------------------------------------------
            -- read interfaces for the HBM
            o_HBM_axi_ar      => o_HBM1_axi_ar,      -- out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
            i_HBM_axi_arready => i_HBM1_axi_arready, -- in  std_logic;
            i_HBM_axi_r       => i_HBM1_axi_r,       -- in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
            o_HBM_axi_rready  => o_HBM1_axi_rready   -- out std_logic
        );
    
    end generate;
    
    c2gen2 : if (not g_USE_TWO_CORRELATORS) generate
        
        o_cor1_data <= (others => '0');
        o_cor1_time <= (others => '0');
        o_cor1_FC <= (others => '0');
        o_cor1_triangle <= (others => '0');
        o_cor1_valid <= '0';
        o_cor1_last <= '0';
        o_cor1_final <= '0';
        o_HBM1_axi_ar.valid <= '0';
        o_HBM1_axi_ar.addr <= (others => '0');
        o_HBM1_axi_ar.len <= (others => '0');
        o_HBM1_axi_rready <= '1';
        
    end generate;     
    
    ------------------------------------------------------------------------------
    -- Registers
    reginst : entity ct_lib.corr_ct2_reg
    PORT map (
        MM_CLK              => i_axi_clk,  -- IN    STD_LOGIC;
        MM_RST              => i_axi_rst,  -- IN    STD_LOGIC;
        SLA_IN              => i_axi_mosi, -- IN    t_axi4_lite_mosi;
        SLA_OUT             => o_axi_miso, -- OUT   t_axi4_lite_miso;
        STATCTRL_FIELDS_RO	=> statctrl_ro  --: IN  t_statctrl_ro
    );
    
    statctrl_ro.bufferoverflowerror <= '0';
    statctrl_ro.readouterror <= '0';
    statctrl_ro.hbmbuf0packetcount <= (others => '0');
    statctrl_ro.hbmbuf1packetcount <= (others => '0');
    statctrl_ro.readinclocks <= (others => '0');
    statctrl_ro.readoutclocks <= (others => '0');
    
    
end Behavioral;
