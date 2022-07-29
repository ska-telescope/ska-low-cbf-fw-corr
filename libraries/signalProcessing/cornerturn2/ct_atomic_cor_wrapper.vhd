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
--      |                            |                           |                            |                            |                                     (28672 words)            
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
--      - 1024 virtual channels
--        - 3456 fine channels per virtual channel
--      - 192 time samples ( = 384 LFAA packets at the input to the filterbank = 849.3466 ms)
--      - 2 pol,
--   Data is written to the memory in 512 byte blocks, where each block has :
--      - 1 fine channel, 4 virtual channels, 2 pol, 32 times.
--   So:
--     - 32 bit address needed to address 4Gbytes:
--      - bits 8:0 = address within a  512 byte data block written in a single burst to the HBM
--      - bits 16:9 = 256 different groups of virtual channels (4 virtual channels in each HBM write)
--          *!! Using these address bits is critical, since it allows the readout to read multiple 512-byte blocks at a time.
--           !! Readout can thus read at the full HBM rate, close to 100Gb/sec.
--           !! Write data rate is 25.6Gb/sec, so this means the readout can read the data 3 or 4 times.
--           !! Multiple reads of the same data reduces the buffer memory required in the correlator.
--      - bits 28:17 = 3456 different fine channels
--      - bits 31:29 = 6 blocks of 32 times (192 times per buffer) / (32 times per 512 byte HBM write) 
----------------------------------------------------------------------------------
library IEEE, ct_lib, DSP_top_lib, common_lib, axi4_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use DSP_top_lib.DSP_top_pkg.all;
USE common_lib.common_pkg.ALL;
use axi4_lib.axi4_lite_pkg.ALL;
USE axi4_lib.axi4_full_pkg.ALL;
use ct_lib.ct_atomic_cor_out_reg_pkg.all;
Library xpm;
use xpm.vcomponents.all;

entity ct_atomic_cor_wrapper is
    generic (
        g_USE_META : boolean := FALSE  -- Put meta data into the memory in place of the actual data, to make it easier to find bugs in the corner turn. 
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
        i_rst : in std_logic;
        -- Data in from the correlator filterbanks; bursts of 3456 clocks for each channel.
        -- (on i_axi_clk)
        i_sof          : in std_logic; -- pulse high at the start of every frame. (1 frame is typically 60ms of data).
        i_frameCount     : in std_logic_vector(36 downto 0); -- frame count is the same for all simultaneous output streams.
        i_virtualChannel : in t_slv_16_arr(3 downto 0); -- 4 virtual channels, one for each of the PST data streams.
        i_HeaderValid : in std_logic_vector(3 downto 0);
        i_data        : in t_ctc_output_payload_arr(3 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), i_data(2), i_data(3)
        i_dataValid   : in std_logic;
        
        -- Data out to the correlator - to be determined.
        
        
        -- AXI interface to the HBM
        -- Corner turn between filterbanks and correlator
        -- aw bus = write address
        o_m02_axi_aw      : out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m02_axi_awready : in  std_logic;
        o_m02_axi_w       : out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_m02_axi_wready  : in  std_logic;
        i_m02_axi_b       : in  t_axi4_full_b;    -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        o_m02_axi_ar      : out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m02_axi_arready : in  std_logic;
        i_m02_axi_r       : in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_m02_axi_rready  : out std_logic
    );
end ct_atomic_cor_wrapper;

architecture Behavioral of ct_atomic_cor_wrapper is
    
    signal statctrl_ro : t_statctrl_ro;
    
begin
    

    din_inst : entity ct_lib.ct_atomic_cor_out_din
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
        i_sof            => i_sof,            -- in std_logic; -- pulse high at the start of every frame. (1 frame is typically 60ms of data).
        i_frameCount     => i_frameCount,     -- in std_logic_vector(36 downto 0); -- frame count is the same for all simultaneous output streams.
        i_virtualChannel => i_virtualChannel, -- in t_slv_16_arr(3 downto 0); -- 4 virtual channels, one for each of the PST data streams.
        i_HeaderValid    => i_headerValid,    -- in std_logic_vector(3 downto 0);
        i_data           => i_data,           -- in t_ctc_output_payload_arr(3 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), i_data(2)
        i_dataValid      => i_dataValid,      -- in std_logic;
        
        -- AXI interface to the HBM
        -- Corner turn between filterbanks and correlator
        -- aw bus = write address
        i_axi_clk     => i_axi_clk,         -- in std_logic;
        o_axi_aw      => o_m02_axi_aw,      -- out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_axi_awready => i_m02_axi_awready, -- in  std_logic;
        o_axi_w       => o_m02_axi_w,       -- out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_axi_wready  => i_m02_axi_wready,  -- in  std_logic;
        i_axi_b       => i_m02_axi_b        -- in  t_axi4_full_b     -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
    );
    
    -- Tie off the read side of the HBM bus 
    
    o_m02_axi_ar.valid <= '0';
    o_m02_axi_ar.addr <= (others => '0');
    o_m02_axi_ar.len <= "00000000";
    
    o_m02_axi_rready <= '1';
    
    ------------------------------------------------------------------------------
    -- Registers
    reginst : entity ct_lib.ct_atomic_cor_out_reg
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
