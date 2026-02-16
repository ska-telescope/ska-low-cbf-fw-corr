-------------------------------------------------------------------------------
--
-- File Name: dsp_top_correlator.vhd
-- Contributing Authors: David Humphrey
-- Type: RTL
-- Created: May 2022
--
-- Title: Top Level for the Perentie correlator
--
-- Description: 
--  Includes all the signal processing and data manipulation modules.
--  This is the v80 version
--  Modifications compared to the U55C version :
--   - Support for 3072 virtual channels (up from 1024)
--   - 12 parallel filterbanks (up from 4)
--   - two HBM interfaces for CT1, each 256 bits wide (vs 1 x 512 bit interface for the U55c version)
--       - This enables support for 200 GE interfaces. SPS packets are split across multiple 1GByte HBM blocks to enable higher bandwidth to the HBM.
--   - 6 correlator instances (up from 2)
--
-------------------------------------------------------------------------------

LIBRARY IEEE, common_lib, axi4_lib, ct_lib, DSP_top_lib, signal_processing_common;
library LFAADecode100G_lib, DSP_top_lib, filterbanks_lib, spead_lib, correlator_lib;
use ct_lib.all;
use DSP_top_lib.DSP_top_pkg.all;
--use DSP_top_lib.DSP_top_reg_pkg.all;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE common_lib.common_pkg.ALL;
USE common_lib.common_mem_pkg.ALL;
USE axi4_lib.axi4_lite_pkg.ALL;
USE axi4_lib.axi4_stream_pkg.ALL;
USE axi4_lib.axi4_full_pkg.ALL;
use spead_lib.spead_packet_pkg.ALL;
use signal_processing_common.target_fpga_pkg.ALL;

library xpm;
use xpm.vcomponents.all;

-------------------------------------------------------------------------------
entity DSP_top_correlator_v80 is
    generic (
        g_DEBUG_ILA              : boolean := false;
        -- Each SPS packet is 2048 time samples @ 1080ns/sample. The second stage corner turn only supports
        -- a value for g_LFAA_BLOCKS_PER_FRAME of 128.
        -- 128 packets per frame = (1080 ns) * (2048 samples/packet) * 128 packets = 
        -- This value needs to be a multiple of 3 so that there are a whole number of PST outputs per frame.
        -- Maximum value is 30, (limited by the 256MByte buffer size, which has to fit 1024 virtual channels)
        g_SPS_PACKETS_PER_FRAME  : integer := 128;  -- Number of LFAA blocks per frame 
        g_USE_META               : boolean := FALSE;  -- Put meta data into the memory in place of the actual data, to make it easier to find bugs in the corner turn. 
        -- There are 34 bytes per sample : 4 x 8 byte visibilites, + 1 byte TCI + 1 byte DV
        g_PACKET_SAMPLES_DIV16   : integer := 64;  -- Actual number of samples in a correlator SPEAD packet is this value x 16; each sample is 34 bytes; default value => 64*34 = 2176 bytes of data per packet.
        g_CORRELATORS            : integer := 6;
        g_MAX_CORRELATORS        : integer := 6;
        g_USE_DUMMY_FB           : boolean := FALSE;
        g_INCLUDE_SPS_MONITOR    : boolean  --  If sps monitor is included, HBM ILA is removed
    );
    port (
        -----------------------------------------------------------------------
        -- Received data from 100GE
        i_axis_tdata   : in std_logic_vector(511 downto 0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
        i_axis_tkeep   : in std_logic_vector(63 downto 0);  -- one bit per byte in i_axi_tdata
        i_axis_tlast   : in std_logic;                      
        i_axis_tuser   : in std_logic_vector(79 downto 0);  -- Timestamp for the packet.
        i_axis_tvalid  : in std_logic;
        -- Data to be transmitted on 100GE
        o_bytes_to_transmit     : OUT STD_LOGIC_VECTOR(13 downto 0);
        o_data_to_player        : OUT STD_LOGIC_VECTOR(511 downto 0);
        o_data_to_player_wr     : OUT STD_LOGIC;
        i_data_to_player_rdy    : IN STD_LOGIC;
        --
        i_clk_100GE         : in std_logic;
        i_eth100G_locked    : in std_logic;
        -----------------------------------------------------------------------
        -- Other processing clocks.
        i_clk425 : in std_logic; -- 425 MHz
        i_clk400 : in std_logic; -- 400 MHz
        -----------------------------------------------------------------------
        -- Debug signal used in the testbench.
        o_validMemRstActive : out std_logic;  -- reset of the valid memory is in progress.
        -----------------------------------------------------------------------
        -- MACE AXI slave interfaces for modules
        -- The 300MHz MACE_clk is also used for some of the signal processing
        i_MACE_clk  : in std_logic;
        i_MACE_clkx2 : in std_logic;  -- used in v80 for double rate DSPs in ct1 and filterbanks
        i_MACE_rst  : in std_logic;
        -- trigger readout of the second corner turn data without waiting for the rest of the signal chain.
        -- used in testing with pre-load of the second corner turn HBM data
        i_ct2_readout_start  : in std_logic;
        i_ct2_readout_buffer : in std_logic;
        i_ct2_readout_frameCount : in std_logic_vector(31 downto 0);
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
        -- Start of a burst of data through the filterbank, 
        -- Used in the testbench to trigger download of the data written into the CT2 memory.
        o_FB_out_sof   : out std_logic;
        --------------------------------------------------------------
        -- HBM reset
        o_hbm_reset    : out std_logic_vector(14 downto 0);
        i_hbm_status   : in t_slv_8_arr(5 downto 0);
        i_hbm_rst_dbg  : in t_slv_32_arr(5 downto 0);
        i_hbm_reset_final : in std_logic;
        i_eth_disable_fsm_dbg : in std_logic_vector(4 downto 0); -- 5 bits
        i_axi_dbg  : in std_logic_vector(127 downto 0); -- 128 bits
        i_axi_dbg_valid : in std_logic;
        -- 100GE input disable
        o_lfaaDecode_reset : out std_logic;
        i_ethDisable_done : in std_logic   --
    );
end DSP_top_correlator_v80;

-------------------------------------------------------------------------------
ARCHITECTURE structure OF DSP_top_correlator_v80 IS

    ---------------------------------------------------------------------------
    -- SIGNAL DECLARATIONS  --
    ---------------------------------------------------------------------------   
    signal LFAADecode_dbg : std_logic_vector(13 downto 0);
    signal gnd : std_logic_vector(199 downto 0);
    
    signal clk_LFAA40GE_wallTime : t_wall_time;
    signal clk_HBM_wallTime : t_wall_time;
    
    signal MACE_clk_vec : std_logic_vector(0 downto 0);
    signal MACE_clk_rst : std_logic_vector(0 downto 0);
    
    signal fineDelayDisable : std_logic;
    signal RFIScale : std_logic_vector(4 downto 0);
   
    COMPONENT ila_0
    PORT (
   	    clk : IN STD_LOGIC;
   	    probe0 : IN STD_LOGIC_VECTOR(191 DOWNTO 0));
    END COMPONENT;
    
    component ila_beamData
    port (
        clk : in std_logic;
        probe0 : in std_logic_vector(119 downto 0)); 
    end component;
    
    signal mac100G : std_logic_vector(47 downto 0);
    signal clk100GE_wallTime : t_wall_time;
    
    signal LFAAingest_virtualChannel : std_logic_vector(15 downto 0);  -- single number to uniquely identify the channel+station for this packet.
    signal LFAAingest_packetCount    : std_logic_vector(47 downto 0);  -- Packet count from the SPEAD header.
    signal LFAAingest_valid          : std_logic;                      -- out std_logic
    
    signal LFAAingest_wvalid : std_logic;
    signal LFAAingest_wready : std_logic;
    signal LFAAingest_wdata  : std_logic_vector(511 downto 0);
    signal LFAAingest_wstrb  : std_logic_vector(63 downto 0);
    signal LFAAingest_wlast  : std_logic;
    
    signal FB_sof : std_logic;
    
    signal FB_data  : t_slv_32_arr(23 downto 0);
    -- signal FB_meta01, FB_meta23, FB_meta45, FB_meta67 : t_CT1_META_out;
    
    signal FB_valid : std_logic;
    
    signal FD_integration :  std_logic_vector(31 downto 0); -- frame count is the same for all simultaneous output streams.
    signal FD_ctFrame : std_logic_vector(1 downto 0);
    signal FD_virtualChannel : t_slv_16_arr(11 downto 0); -- 3 virtual channels, one for each of the PST data streams.
    signal FD_headerValid : std_logic_vector(11 downto 0);
    signal FD_data : t_ctc_output_payload_arr(11 downto 0);
    signal FD_dataValid : std_logic;
    
    signal ct_rst : std_logic;
    signal ct_sof : std_logic;
    signal CT_sofCount : std_logic_vector(11 downto 0) := (others => '0');
    signal CT_sofFinal : std_logic := '0';
    
    signal dbg_ILA_trigger, bdbg_ILA_triggerDel1, bdbg_ILA_trigger, bdbg_ILA_triggerDel2 : std_logic;
    signal dataMismatch_dbg, dataMismatch, datamismatchBFclk : std_logic;
    
    signal cmac_reset           : std_logic;
    
    -- SPEAD Signals
    signal from_spead_pack       : t_spead_to_hbm_bus_array(1 downto 0);
    signal to_spead_pack         : t_hbm_to_spead_bus_array(1 downto 0);
    signal packetiser_enable     : std_logic_vector(1 downto 0); 

    -- 100G reset
    signal eth100G_rst           : std_logic := '0';

    signal FB_to_100G_data : std_logic_vector(127 downto 0);
    signal FB_to_100G_valid : std_logic;
    signal FB_to_100G_ready : std_logic;
    signal cor_ready, cor_valid, cor_last, cor_final, cor_badPoly : std_logic_vector((g_MAX_CORRELATORS-1) downto 0);
    signal cor_tileType, cor_first : std_logic_vector((g_MAX_CORRELATORS-1) downto 0);
    signal cor_data : t_slv_256_arr((g_MAX_CORRELATORS-1) downto 0);
    signal cor_time : t_slv_8_arr((g_MAX_CORRELATORS-1) downto 0);
    signal cor_station : t_slv_12_arr((g_MAX_CORRELATORS-1) downto 0);
    
    signal cor_tileLocation : t_slv_10_arr((g_MAX_CORRELATORS-1) downto 0);
    signal cor_frameCount : t_slv_32_arr((g_MAX_CORRELATORS-1) downto 0);
    signal cor_tileChannel : t_slv_24_arr((g_MAX_CORRELATORS-1) downto 0);
    signal cor_tileTotalTimes : t_slv_8_arr((g_MAX_CORRELATORS-1) downto 0); -- Number of time samples to integrate for this tile.
    signal cor_timeTotalChannels : t_slv_7_arr((g_MAX_CORRELATORS-1) downto 0);  -- Number of frequency channels to integrate for this tile.
    signal cor_rowStations, cor_colStations : t_slv_9_arr((g_MAX_CORRELATORS-1) downto 0); -- number of stations in the row memories to process; up to 256.
    signal cor_totalStations : t_slv_16_arr(g_MAX_CORRELATORS-1 downto 0); -- Total number of stations being processing for this subarray-beam.
    signal cor_subarrayBeam : t_slv_8_arr(g_MAX_CORRELATORS-1 downto 0);
    
    signal cor_packet_data : t_slv_256_arr((g_MAX_CORRELATORS-1) downto 0);
    signal cor_packet_valid : std_logic_vector((g_MAX_CORRELATORS-1) downto 0);
    signal LFAAingest_totalChannels : std_logic_vector(11 downto 0);

    signal FB_out_sof : std_logic;

    signal FB_meta_delays         : t_CT1_META_delays_arr(11 downto 0); -- defined in DSP_top_pkg.vhd; fields are : HDeltaP(31:0), VDeltaP(31:0), HOffsetP(31:0), VOffsetP(31:0), bad_poly (std_logic)
    signal FB_meta_RFIThresholds  : t_slv_32_arr(11 downto 0);
    signal FB_meta_integration    : std_logic_vector(31 downto 0);
    signal FB_meta_CTFrame        : std_logic_vector(1 downto 0);
    signal FB_meta_virtualChannel : std_logic_vector(11 downto 0); -- first virtual channel output, remaining 3 (U55c) or 11 (V80) are o_meta_VC+1, +2, etc.
    signal FB_meta_valid          : std_logic_vector(11 downto 0);
    
    signal ct_rst_del1, ct_rst_del2 : std_logic := '0';
    signal reset_to_ct_1 : std_logic;
    signal freq_index0_repeat : std_logic;
    signal FD_bad_poly : std_logic_vector(2 downto 0);
    signal LFAAingest_table_select : std_logic;
    signal totalChannelsTable0, totalChannelsTable1 : std_logic_vector(11 downto 0);
    signal FB_demap_table_select : std_logic;
    signal FB_lastChannel : std_logic;
    signal FD_lastChannel, FD_demap_table_select : std_logic;
    signal cor_tableSelect : std_logic_vector(g_MAX_CORRELATORS-1 downto 0);
    signal table_swap_in_progress : std_logic;
    signal packetiser_table_select : std_logic;
    signal table_add_remove : std_logic;
    signal HBM_reset_ct1 : std_logic;
    
    signal cor_cfg_data, cor_cfg_data_del1, cor_cfg_data_del2, cor_cfg_data_del3, cor_cfg_data_del4 : t_slv_8_arr(5 downto 0); -- 8 bit wide buses, to 6 correlators.
    signal cor_cfg_first, cor_cfg_first_del1, cor_cfg_first_del2, cor_cfg_first_del3, cor_cfg_first_del4 : std_logic_vector(5 downto 0);
    signal cor_cfg_last, cor_cfg_last_del1, cor_cfg_last_del2, cor_cfg_last_del3, cor_cfg_last_del4 : std_logic_vector(5 downto 0);
    signal cor_cfg_valid, cor_cfg_valid_del1, cor_cfg_valid_del2,  cor_cfg_valid_del3,  cor_cfg_valid_del4 : std_logic_vector(5 downto 0);
    
    signal HBM_axi_a_dummy : t_axi4_full_addr;
    signal HBM_axi_w_dummy : t_axi4_full_data; 
    signal HBM_axi_ready_dummy : std_logic;
    
    signal SPS_HBM_axi_aw, CT1_HBM_axi_ar : t_axi4_full_addr_arr(1 downto 0);
    signal SPS_HBM_axi_w, CT1_HBM_axi_r : t_axi4_full_data_arr(1 downto 0);
    signal SPS_HBM_axi_wready, SPS_HBM_axi_awready, SPS_HBM_axi_bready, CT1_HBM_axi_arready, CT1_HBM_axi_rready : std_logic_vector(1 downto 0);
    signal SPS_HBM_axi_b : t_axi4_full_b_arr(1 downto 0);   
    signal dummy_slv32 : std_logic_vector(31 downto 0) := x"00000000";
    
    signal HBM_ILA_axi_aw : t_axi4_full_addr; -- write address bus : out t_axi4_full_addr(.valid, .addr(39:0), .len(7:0))
    signal HBM_ILA_axi_awready : std_logic;
    signal HBM_ILA_axi_w : t_axi4_full_data; -- w data bus : out t_axi4_full_data(.valid, .data(511:0), .last, .resp(1:0))
    signal HBM_ILA_axi_wready : std_logic;
    signal HBM_ILA_axi_b : t_axi4_full_b;     -- write response bus : in t_axi4_full_b(.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
    signal HBM_ILA_axi_bready : std_logic;
    -- read
    signal HBM_ILA_axi_ar : t_axi4_full_addr;
    signal HBM_ILA_axi_arready : std_logic;
    signal HBM_ILA_axi_r : t_axi4_full_data;
    signal HBM_ILA_axi_rready : std_logic;
    
begin
    
    HBM_axi_a_dummy.valid <= '0';
    HBM_axi_a_dummy.addr <= (others => '0');
    HBM_axi_a_dummy.len <= (others => '0');
    HBM_axi_ready_dummy <= '1';
    HBM_axi_w_dummy.valid <= '0';
    HBM_axi_w_dummy.data <= (others => '0');
    HBM_axi_w_dummy.last <= '0';
    HBM_axi_w_dummy.resp <= (others => '0');
    dummy_slv32 <= (others => '0');
    
    gnd <= (others => '0');
    
    o_hbm_reset(0) <= HBM_reset_ct1;
    o_hbm_reset(1) <= HBM_reset_ct1;
    -- never reset the HBM interface for interfaces 8 to 13 (=correlator outputs), or 14 (HBM ILA) 
    o_hbm_reset(14 downto 8) <= "0000000";
    --------------------------------------------------------------------------
    -- Signal Processing signal Chains
    --------------------------------------------------------------------------
    mac100G <= x"aabbccddeeff";
    clk100GE_wallTime.sec <= (others => '0');
    clk100GE_wallTime.ns <= (others => '0');
    
    
    -- Takes in data from the 100GE port, checks it is a valid SPEAD packet, then
    --  - Notifies the corner turn, which generates the write address part of the AXI memory interface.
    --  - Outputs the data part of the packet on the wdata part of the AXI memory interface.
    LFAAingest_packetCount(47 downto 40)    <= x"00";


    LFAAin : entity LFAADecode100G_lib.LFAADecodeTop100G
    port map(
        -- Data in from the 100GE MAC
        i_axis_tdata     => i_axis_tdata, --  in (511:0); 64 bytes of data, 1st byte in the packet is in bits 7:0.
        i_axis_tkeep     => i_axis_tkeep, --  in (63:0);  one bit per byte in i_axi_tdata
        i_axis_tlast     => i_axis_tlast, --  in std_logic;                      
        i_axis_tuser     => i_axis_tuser, --  in (79:0);  -- Timestamp for the packet, from the PTP core
        i_axis_tvalid    => i_axis_tvalid, -- in std_logic;
        i_100GE_clk      => i_clk_100GE,   -- 322 MHz from the 100GE MAC; note 512 bits x 322 MHz = 165 Mbit/sec, so even full rate traffic will have .valid low 1/3rd of the time.
        i_100GE_rst      => eth100G_rst,
        --i_data_rst       => '0',            -- in std_logic;
        -- Data to the corner turn. This is just some header information about each LFAA packet, needed to generate the address the data is to be written to.
        o_virtualChannel => LFAAingest_virtualChannel,  -- out(15:0), single number to uniquely identify the channel+station for this packet.
        o_packetCount    => LFAAingest_packetCount(39 downto 0), -- out(31:0). Packet count from the SPEAD header.
        o_totalChannels  => LFAAingest_totalChannels,   -- out (11:0);
        o_totalChannelsTable0 => totalChannelsTable0, -- out (11:0)
        o_totalChannelsTable1 => totalChannelsTable1, -- out (11:0)
        o_totalStations  => open, -- LFAAingest_totalStations,   -- out (11:0);
        o_totalCoarse    => open, -- LFAAingest_totalCoarse,     -- out (11:0);
        o_tableSelect    => open, -- LFAAingest_tableSelect,     -- out std_logic;
        o_valid          => LFAAingest_valid,           -- out std_logic; o_virtualChannel and o_packetCount are valid.
        -- wdata portion of the AXI-full external interface (should go directly to the external memory)
        o_axi_w      => SPS_HBM_axi_w(0),      -- w data bus (.wvalid, .wdata, .wlast)
        i_axi_wready => SPS_HBM_axi_wready(0), -- 
        -- Second wdata bus for the second half (i.e. 4kBytes) of each packet, used when g_CORRELATOR_V80 = True
        o_axi_w2      => SPS_HBM_axi_w(1),      -- out t_axi4_full_data; w data bus (.wvalid, .wdata, .wlast)
        i_axi_wready2 => SPS_HBM_axi_wready(1), -- in std_logic;
        -- AXI lite Interface, not used for V80, registers are connected to the NOC at a lower level
        i_s_axi_mosi  => c_axi4_lite_mosi_rst, -- in t_axi4_lite_mosi;
        o_s_axi_miso  => open, -- out t_axi4_lite_miso;
        i_s_axi_clk   => i_MACE_clk,         
        i_s_axi_rst   => i_MACE_rst,
        -- registers AXI Full interface
        i_vcstats_MM_IN  => c_axi4_full_mosi_null, -- in  t_axi4_full_mosi;
        o_vcstats_MM_OUT => open,                  -- out t_axi4_full_miso;
        -- control signal in to select which virtual channel table to use
        i_vct_table_select => LFAAingest_table_select, -- in std_logic;
        -- hbm reset   
        o_hbm_reset        => HBM_reset_ct1, -- o_hbm_reset(0),
        i_hbm_status       => i_hbm_status(0),
        -- LFAADecode reset
        -- Out to disable ethernet input, then when that is done, comes back in to reset the ingest pipeline
        -- both here and in CT1
        o_LFAADecode_reset => o_LFAADecode_reset, -- out std_logic;
        i_ethDisable_done  => i_ethDisable_done,  -- in std_logic;
        o_reset_to_ct      => reset_to_ct_1,
        -- debug
        o_dbg              => LFAADecode_dbg
    );
    
    -------------------------------------------------------------------------------------------------
    -- 2 NOC interfaces to write data from the 100/200GE into the HBM 
    SPS_HBM_write0 : entity signal_processing_common.hbm_noc_if
    generic map (
        g_HBM_base_addr => c_V80_HBM_BASE_CT1_ADDR, -- std_logic_vector(63 downto 0) := x"0000004600000000";  -- default is the HBM base address
        g_USE_VNOC => c_V80_HBM_SPS_DECODE_VNOC0    -- True to use VNOC, otherwise false for HBM specific NOC interfaces at the top of SLR0
    ) port map (
        clk  => i_MACE_clk, --  in std_logic;
        -- write
        i_HBM_axi_aw      => SPS_HBM_axi_aw(0),      -- in t_axi4_full_addr; -- write address bus : out t_axi4_full_addr(.valid, .addr(39:0), .len(7:0))
        o_HBM_axi_awready => SPS_HBM_axi_awready(0), -- out std_logic;
        i_HBM_axi_w       => SPS_HBM_axi_w(0),       -- in t_axi4_full_data; -- w data bus : out t_axi4_full_data(.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_wready  => SPS_HBM_axi_wready(0),  -- out std_logic;
        o_HBM_axi_b       => SPS_HBM_axi_b(0),       -- out t_axi4_full_b;     -- write response bus : in t_axi4_full_b(.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        i_HBM_axi_bready  => SPS_HBM_axi_bready(0),  -- in std_logic;
        -- read
        i_HBM_axi_ar => HBM_axi_a_dummy, -- in t_axi4_full_addr;
        o_HBM_axi_arready => open, -- out std_logic;
        o_HBM_axi_r  => open, -- out t_axi4_full_data;
        i_HBM_axi_rready => HBM_axi_ready_dummy -- in std_logic
    );

    SPS_HBM_write1 : entity signal_processing_common.hbm_noc_if
    generic map (
        g_HBM_base_addr => c_V80_HBM_BASE_CT1_ADDR, -- std_logic_vector(63 downto 0) := x"0000004600000000";  -- default is the HBM base address
        g_USE_VNOC => c_V80_HBM_SPS_DECODE_VNOC1   -- True to use VNOC, otherwise false for HBM specific NOC interfaces at the top of SLR0
    ) port map (
        clk  => i_MACE_clk, --  in std_logic;
        -- write
        i_HBM_axi_aw      => SPS_HBM_axi_aw(1),      -- in t_axi4_full_addr; -- write address bus : out t_axi4_full_addr(.valid, .addr(39:0), .len(7:0))
        o_HBM_axi_awready => SPS_HBM_axi_awready(1), -- out std_logic;
        i_HBM_axi_w       => SPS_HBM_axi_w(1),       -- in t_axi4_full_data; -- w data bus : out t_axi4_full_data(.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_wready  => SPS_HBM_axi_wready(1),  -- out std_logic;
        o_HBM_axi_b       => SPS_HBM_axi_b(1),       -- out t_axi4_full_b;     -- write response bus : in t_axi4_full_b(.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        i_HBM_axi_bready  => SPS_HBM_axi_bready(1),  -- in std_logic;
        -- read
        i_HBM_axi_ar => HBM_axi_a_dummy, -- in t_axi4_full_addr;
        o_HBM_axi_arready => open, -- out std_logic;
        o_HBM_axi_r  => open, -- out t_axi4_full_data;
        i_HBM_axi_rready => HBM_axi_ready_dummy -- in std_logic
    );
    SPS_HBM_axi_bready(1 downto 0) <= "11";
    
    ---------------------------------------------------------------------------------------------------
    
    LFAA_FB_CT : entity CT_lib.corr_ct1_top
    generic map (
         g_INCLUDE_SPS_MONITOR   => g_INCLUDE_SPS_MONITOR  -- If sps monitor is included, HBM ILA is removed
    ) port map (
        -- shared memory interface clock (300 MHz)
        i_shared_clk   => i_MACE_clk, -- in std_logic;
        i_shared_clkx2 => i_MACE_clkx2, -- in std_logic;
        i_shared_rst   => i_MACE_rst, -- in std_logic;
        --AXI Lite Interface for registers
        i_saxi_mosi    => c_axi4_lite_mosi_rst, -- in t_axi4_lite_mosi;
        o_saxi_miso    => open, -- out t_axi4_lite_miso;
        -- axi full interface for the polynomials
        i_poly_full_axi_mosi => c_axi4_full_mosi_null, --  in  t_axi4_full_mosi; -- => mc_full_mosi(c_corr_ct1_full_index),
        o_poly_full_axi_miso => open, --  out t_axi4_full_miso; -- => mc_full_miso(c_corr_ct1_full_index),
        -- other config (from LFAA ingest config, must be the same for the corner turn)
        i_totalChannelsTable0 => totalChannelsTable0, -- out (11:0); Total virtual channels in vct table 0
        i_totalChannelsTable1 => totalChannelsTable1, -- out (11:0); Total virtual channels in vct table 1
        i_rst => reset_to_ct_1,
        o_rst => ct_rst, -- reset output from a register in the corner turn; used to reset downstream modules.
        -- Headers for each valid packet received by the LFAA ingest.
        -- LFAA packets are about 8300 bytes long, so at 100Gbps each LFAA packet is about 660 ns long. This is about 200 of the interface clocks (@300MHz)
        -- These signals use i_shared_clk
        i_virtualChannel => LFAAingest_virtualChannel, -- in std_logic_vector(15 downto 0); -- Single number which incorporates both the channel and station; this module supports values in the range 0 to 1023.
        i_packetCount    => LFAAingest_packetCount,    -- in std_logic_vector(31 downto 0);
        i_valid          => LFAAingest_valid, --  in std_logic;
        -- select the table to use in LFAA Ingest. Changes to the configuration tables to be used (in ingest, ct1, and ct2) are sequenced from within corner turn 1
        o_vct_table_select => LFAAingest_table_select,  -- out std_logic;
        --
        o_table_swap_in_progress  => table_swap_in_progress,  -- out std_logic;
        o_packetiser_table_select => packetiser_table_select, -- out std_logic; 
        o_table_add_remove        => table_add_remove,        -- out std_logic;
        
        ------------------------------------------------------------------------------------
        -- Data output, to go to the filterbanks.
        -- Data bus output to the Filterbanks
        -- 24 Outputs, each complex data, 16 bit real, 16 bit imaginary.
        o_sof     => FB_sof,    -- out std_logic;   -- Start of frame, occurs for every new set of channels.
        o_sofFull => CT_sof,    -- out std_logic; -- Start of a full frame, i.e. 128 LFAA packets worth for all virtual channels.
        o_data    => FB_data,  -- out t_slv_32_arr(23 downto 0);  -- each 32-bit value has real in bits 15:0, imaginary in bits 31:16 
        o_meta_delays         => FB_meta_delays,         -- out t_CT1_META_delays_arr(11 downto 0); -- defined in DSP_top_pkg.vhd; fields are : HDeltaP(31:0), VDeltaP(31:0), HOffsetP(31:0), VOffsetP(31:0), bad_poly (std_logic)
        o_meta_RFIThresholds  => FB_meta_RFIThresholds,  -- out t_slv_32_arr(11 downto 0);
        o_meta_integration    => FB_meta_integration,    -- out std_logic_vector(31 downto 0);
        o_meta_ctFrame        => FB_meta_CTFrame,        -- out std_logic_vector(1 downto 0);
        o_meta_virtualChannel => FB_meta_virtualChannel, -- out std_logic_vector(11 downto 0); -- first virtual channel output, remaining 3 (U55c) or 11 (V80) are o_meta_VC+1, +2, etc.
        o_meta_valid          => FB_meta_valid,          -- out std_logic_vector(11 downto 0); -- Total number of virtual channels need not be a multiple of 12, so individual valid signals here.
        o_lastChannel         => FB_lastChannel,         -- out std_logic; -- aligns with meta data, indicates this is the last group of channels to be processed in this frame.
        -- o_demap_table_select will change just prior to the start of reading out of a new integration frame.
        -- So it should be registered on the first output of a new integration frame in corner turn 2.
        o_demap_table_select => FB_demap_table_select,   -- out std_logic;
        o_valid   => FB_valid, -- out std_logic;
        
        -------------------------------------------------------------
        i_axi_dbg  => i_axi_dbg,            -- in (127:0)
        i_axi_dbg_valid => i_axi_dbg_valid, -- in std_logic
        -------------------------------------------------------------
        -- AXI bus to the shared memory. 
        -- This has the aw, b, ar and r buses (the w bus is on the output of the LFAA decode module)
        -- aw bus - write address
        o_m01_axi_aw      => SPS_HBM_axi_aw(0),      -- out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m01_axi_awready => SPS_HBM_axi_awready(0), -- in std_logic;
        -- b bus - write response
        i_m01_axi_b       => SPS_HBM_axi_b(0),       -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        -- ar bus - read address
        o_m01_axi_ar      => CT1_HBM_axi_ar(0),      -- out t_axi4_full_addr; (.valid, .addr(39:0), .len(7:0))
        i_m01_axi_arready => CT1_HBM_axi_arready(0), -- in std_logic;
        -- r bus - read data
        i_m01_axi_r       => CT1_HBM_axi_r(0),       -- in t_axi4_full_data  (.valid, .data(511:0), .last, .resp(1:0))
        o_m01_axi_rready  => CT1_HBM_axi_rready(0),  -- out std_logic;
        i_m01_axi_rst_dbg => dummy_slv32,     -- in (31:0)
        -------------------------------------------------------------
        -- Second HBM bus, used for the second half of each 64-byte word in the v80 version.
        -- Unused for the u55c version 
        o_m02_axi_aw      => SPS_HBM_axi_aw(1),      -- out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m02_axi_awready => SPS_HBM_axi_awready(1), -- in std_logic;
        -- b bus - write response
        i_m02_axi_b       => SPS_HBM_axi_b(1),       -- in t_axi4_full_b;   -- (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        -- ar bus - read address
        o_m02_axi_ar      => CT1_HBM_axi_ar(1),      -- out t_axi4_full_addr; read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m02_axi_arready => CT1_HBM_axi_arready(1), -- in std_logic;
        -- r bus - read data
        i_m02_axi_r       => CT1_HBM_axi_r(1),       -- in t_axi4_full_data  (.valid, .data(511:0), .last, .resp(1:0))
        o_m02_axi_rready  => CT1_HBM_axi_rready(1),  -- out std_logic;
        i_m02_axi_rst_dbg => dummy_slv32,     -- in (31:0)
        -------------------------------------------------------------
        -- HBM ILA
        o_m06_axi_aw      => HBM_ILA_axi_aw,      -- out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m06_axi_awready => HBM_ILA_axi_awready, -- in std_logic;
        -- b bus - write response
        o_m06_axi_w       => HBM_ILA_axi_w,       -- t_axi4_full_data; -- (.valid, .data , .last, .resp(1:0))
        i_m06_axi_wready  => HBM_ILA_axi_wready,  -- in std_logic;
        i_m06_axi_b       => HBM_ILA_axi_b,            -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        -- ar bus - read address
        o_m06_axi_ar      => HBM_ILA_axi_ar,      -- out t_axi4_full_addr; (.valid, .addr(39:0), .len(7:0))
        i_m06_axi_arready => HBM_ILA_axi_arready, -- in std_logic;
        -- r bus - read data
        i_m06_axi_r       => HBM_ILA_axi_r,       -- in t_axi4_full_data  (.valid, .data(511:0), .last, .resp(1:0))
        o_m06_axi_rready  => HBM_ILA_axi_rready,  -- out std_logic;
        --
        i_m06_axi_rst_dbg => dummy_slv32,          -- in (31:0)
        -- addr/data ARGS interface used for simulation to avoid the NOC component
        i_noc_wren_tb => '0', -- in std_logic;
        i_noc_rden_tb => '0', -- in std_logic;
        i_noc_wr_adr_tb => (others => '0'), -- in (17:0);
        i_noc_wr_dat_tb => (others => '0'), -- in (31:0);
        i_noc_rd_adr_tb => (others => '0'), -- in (17:0);
        o_noc_rd_dat_tb => open             -- out (31:0)
    );
    
    -------------------------------------------------------------------------------------------------
    -- 2 NOC interfaces for CT1 to read data from the HBM to send to the filterbanks 
    CT1_HBM_read0 : entity signal_processing_common.hbm_noc_if
    generic map (
        g_HBM_base_addr => c_V80_HBM_BASE_CT1_ADDR, -- std_logic_vector(63 downto 0) := x"0000004600000000";  -- default is the HBM base address
        g_USE_VNOC => c_V80_HBM_CT1_READ_VNOC0    -- True to use VNOC, otherwise false for HBM specific NOC interfaces at the top of SLR0
    ) port map (
        clk  => i_MACE_clk, --  in std_logic;
        -- write
        i_HBM_axi_aw      => HBM_axi_a_dummy,      -- in t_axi4_full_addr; -- write address bus : out t_axi4_full_addr(.valid, .addr(39:0), .len(7:0))
        o_HBM_axi_awready => open, -- out std_logic;
        i_HBM_axi_w       => HBM_axi_w_dummy,       -- in t_axi4_full_data; -- w data bus : out t_axi4_full_data(.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_wready  => open,  -- out std_logic;
        o_HBM_axi_b       => open,       -- out t_axi4_full_b;     -- write response bus : in t_axi4_full_b(.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        i_HBM_axi_bready  => HBM_axi_ready_dummy,  -- in std_logic;
        -- read
        i_HBM_axi_ar      => CT1_HBM_axi_ar(0), -- in t_axi4_full_addr;
        o_HBM_axi_arready => CT1_HBM_axi_arready(0), -- out std_logic;
        o_HBM_axi_r       => CT1_HBM_axi_r(0), -- out t_axi4_full_data;
        i_HBM_axi_rready  => CT1_HBM_axi_rready(0) -- in std_logic
    );
    
    CT1_HBM_read1 : entity signal_processing_common.hbm_noc_if
    generic map (
        g_HBM_base_addr => c_V80_HBM_BASE_CT1_ADDR, -- std_logic_vector(63 downto 0) := x"0000004600000000";  -- default is the HBM base address
        g_USE_VNOC => c_V80_HBM_CT1_READ_VNOC1    -- True to use VNOC, otherwise false for HBM specific NOC interfaces at the top of SLR0
    ) port map (
        clk  => i_MACE_clk, --  in std_logic;
        -- write
        i_HBM_axi_aw      => HBM_axi_a_dummy,      -- in t_axi4_full_addr; -- write address bus : out t_axi4_full_addr(.valid, .addr(39:0), .len(7:0))
        o_HBM_axi_awready => open, -- out std_logic;
        i_HBM_axi_w       => HBM_axi_w_dummy,       -- in t_axi4_full_data; -- w data bus : out t_axi4_full_data(.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_wready  => open,  -- out std_logic;
        o_HBM_axi_b       => open,       -- out t_axi4_full_b;     -- write response bus : in t_axi4_full_b(.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        i_HBM_axi_bready  => HBM_axi_ready_dummy,  -- in std_logic;
        -- read
        i_HBM_axi_ar      => CT1_HBM_axi_ar(1),      -- in t_axi4_full_addr;
        o_HBM_axi_arready => CT1_HBM_axi_arready(1), -- out std_logic;
        o_HBM_axi_r       => CT1_HBM_axi_r(1),       -- out t_axi4_full_data;
        i_HBM_axi_rready  => CT1_HBM_axi_rready(1)   -- in std_logic
    );
    
    -- NOC interface for the HBM ILA 
    SPS_HBM_ILA : entity signal_processing_common.hbm_noc_if
    generic map (
        g_HBM_base_addr => c_V80_HBM_ILA_ADDR, -- std_logic_vector(63 downto 0) := x"0000004600000000";  -- default is the HBM base address
        g_USE_VNOC => c_V80_HBM_ILA_VNOC       -- True to use VNOC, otherwise false for HBM specific NOC interfaces at the top of SLR0
    ) port map (
        clk  => i_MACE_clk, --  in std_logic;
        -- write
        i_HBM_axi_aw      => HBM_ILA_axi_aw,      -- in t_axi4_full_addr; -- write address bus : out t_axi4_full_addr(.valid, .addr(39:0), .len(7:0))
        o_HBM_axi_awready => HBM_ILA_axi_awready, -- out std_logic;
        i_HBM_axi_w       => HBM_ILA_axi_w,       -- in t_axi4_full_data; -- w data bus : out t_axi4_full_data(.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_wready  => HBM_ILA_axi_wready,  -- out std_logic;
        o_HBM_axi_b       => HBM_ILA_axi_b,       -- out t_axi4_full_b;     -- write response bus : in t_axi4_full_b(.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        i_HBM_axi_bready  => HBM_ILA_axi_bready,  -- in std_logic;
        -- read
        i_HBM_axi_ar => HBM_ILA_axi_ar,           -- in t_axi4_full_addr;
        o_HBM_axi_arready => HBM_ILA_axi_arready, -- out std_logic;
        o_HBM_axi_r  => HBM_ILA_axi_r,            -- out t_axi4_full_data;
        i_HBM_axi_rready => HBM_ILA_axi_rready    -- in std_logic
    );
    
    -- Correlator filterbank and fine delay.
    FBreali : if (not g_USE_DUMMY_FB) generate

        corFB_i : entity filterbanks_lib.FB_top_correlator
        generic map (
            g_FILTERBANKS_DIV2 => 6  -- 12 parallel filterbanks 
        ) port map (
            i_data_rst => FB_sof, -- in std_logic;
            -- Register interface
            i_axi_clk    => i_MACE_clk,   -- in std_logic;
            i_axi_clk_2x => i_MACE_clkx2, -- in std_logic;
            i_axi_rst    => i_MACE_rst,      -- in std_logic;
            i_axi_mosi => c_axi4_lite_mosi_rst,  -- in t_axi4_lite_mosi;
            o_axi_miso => open,  -- out t_axi4_lite_miso;
            -- Configuration (on i_data_clk)
            i_fineDelayDisable => '0',     -- in std_logic;
            -----------------------------------------
            -- data input, common valid signal, expects packets of 4096 samples. 
            -- Requires at least 2 clocks idle time between packets
            i_sof     => FB_sof,  --  in std_logic;   -- Start of frame, occurs for every new set of channels.
            i_data    => FB_data, --  in t_slv_32_arr(23 downto 0);  -- each 32-bit value has real in bits 15:0, imaginary in bits 31:16 
            i_meta_delays => FB_meta_delays, -- in t_CT1_META_delays_arr(11 downto 0); -- defined in DSP_top_pkg.vhd; fields are : HDeltaP(31:0), VDeltaP(31:0), HOffsetP(31:0), VOffsetP(31:0), bad_poly (std_logic)
            i_meta_RFIThresholds  => FB_meta_RFIThresholds,  -- in t_slv_32_arr(11 downto 0);
            i_meta_integration    => FB_meta_integration,    -- in std_logic_vector(31 downto 0);
            i_meta_ctFrame        => FB_meta_CTFrame,        -- in std_logic_vector(1 downto 0);
            i_meta_virtualChannel => FB_meta_virtualChannel, -- in std_logic_vector(11 downto 0); -- first virtual channel output, remaining 3 (U55c) or 11 (V80) are o_meta_VC+1, +2, etc.
            i_meta_valid          => FB_meta_valid,  -- in std_logic_vector(11 downto 0); -- Total number of virtual channels need not be a multiple of 12, so individual valid signals here.
            i_lastChannel         => FB_lastChannel, -- in std_logic; -- aligns with meta data, indicates this is the last group of channels to be processed in this frame.
            -- o_demap_table_select will change just prior to the start of reading out of a new integration frame.
            -- So it should be registered on the first output of a new integration frame in corner turn 2.
            i_demap_table_select  => FB_demap_table_select, -- in std_logic;
            i_dataValid           => FB_valid,              -- in std_logic;
            
            -- Data out; bursts of 3456 clocks for each channel.
            -- Correlator filterbank data output
            o_integration    => FD_integration,    -- out (31:0); Frame count is the same for all simultaneous output streams.
            o_ctFrame        => FD_ctFrame,        -- out (1:0);
            o_virtualChannel => FD_virtualChannel, -- out t_slv_16_arr(11 downto 0); 3 virtual channels, one for each of the PST data streams.
            o_bad_poly       => FD_bad_poly,       -- out (2:0);
            o_lastChannel    => FD_lastChannel,    -- out std_logic; Last of the group of 4 channels
            o_demap_table_select => FD_demap_table_select, -- out std_logic;
            o_HeaderValid    => FD_headerValid,    -- out (11:0);
            o_Data           => FD_data,           -- out t_ctc_output_payload_arr(11 downto 0);
            o_DataValid      => FD_dataValid,      -- out std_logic
            -- i_SOF delayed by 16384 clocks;
            -- i_sof occurs at the start of each new block of 4 virtual channels.
            -- Delay of 16384 is enough to ensure that o_sof falls in the gap
            -- between data packets at the filterbank output that occurs due to the filterbank preload.
            o_sof => FB_out_sof -- out std_logic;
        );
    
    end generate;
    
    FBdummyi : if g_USE_DUMMY_FB generate
        corFB_i : entity filterbanks_lib.FB_top_correlator_dummy_v80
        port map (
            i_data_rst => FB_sof, -- in std_logic;
            -- Register interface
            i_axi_clk => i_MACE_clk,    -- in std_logic;
            i_axi_rst => i_MACE_rst,    -- in std_logic;
            i_axi_mosi => c_axi4_lite_mosi_rst, -- in t_axi4_lite_mosi;
            o_axi_miso => open, -- out t_axi4_lite_miso;
            -- Configuration (on i_data_clk)
            i_fineDelayDisable => '0',     -- in std_logic;
            -- Data input, common valid signal, expects packets of 4096 samples
            i_sof     => FB_sof,  --  in std_logic; Start of frame, occurs for every new set of channels.
            i_data    => FB_data, --  in t_slv_32_arr(23 downto 0); Each 32-bit value has real in bits 15:0, imaginary in bits 31:16 
            i_meta_delays => FB_meta_delays, -- in t_CT1_META_delays_arr(11 downto 0); -- defined in DSP_top_pkg.vhd; fields are : HDeltaP(31:0), VDeltaP(31:0), HOffsetP(31:0), VOffsetP(31:0), bad_poly (std_logic)
            i_meta_RFIThresholds  => FB_meta_RFIThresholds,  -- in t_slv_32_arr(11 downto 0);
            i_meta_integration    => FB_meta_integration,    -- in std_logic_vector(31 downto 0);
            i_meta_ctFrame        => FB_meta_CTFrame,        -- in std_logic_vector(1 downto 0);
            i_meta_virtualChannel => FB_meta_virtualChannel, -- in std_logic_vector(11 downto 0); -- first virtual channel output, remaining 3 (U55c) or 11 (V80) are o_meta_VC+1, +2, etc.
            i_meta_valid          => FB_meta_valid,  -- in std_logic_vector(11 downto 0); -- Total number of virtual channels need not be a multiple of 12, so individual valid signals here.
            i_lastChannel         => FB_lastChannel, -- in std_logic; -- aligns with meta data, indicates this is the last group of channels to be processed in this frame.
            -- o_demap_table_select will change just prior to the start of reading out of a new integration frame.
            -- So it should be registered on the first output of a new integration frame in corner turn 2.
            i_demap_table_select  => FB_demap_table_select, -- in std_logic;
            i_dataValid           => FB_valid,              -- in std_logic;
            -- Data out; bursts of 3456 clocks for each channel.
            -- Correlator filterbank data output
            o_integration    => FD_integration,    -- out (31:0); frame count is the same for all simultaneous output streams.
            o_ctFrame        => FD_ctFrame,        -- out (1:0);
            o_virtualChannel => FD_virtualChannel, -- out t_slv_16_arr(3 downto 0); -- 3 virtual channels, one for each of the PST data streams.
            o_bad_poly       => FD_bad_poly,       -- out std_logic;
            o_lastChannel    => FD_lastChannel,    -- out std_logic; Last of the group of 4 channels
            o_demap_table_select => FD_demap_table_select, -- out std_logic;
            o_HeaderValid    => FD_headerValid,    -- out (11:0);
            o_Data           => FD_data,           -- out t_ctc_output_payload_arr(11 downto 0);
            o_DataValid      => FD_dataValid,      -- out std_logic
            -- i_SOF delayed by 16384 clocks;
            -- i_sof occurs at the start of each new block of 4 virtual channels.
            -- Delay of 16384 is enough to ensure that o_sof falls in the gap
            -- between data packets at the filterbank output that occurs due to the filterbank preload.
            o_sof => FB_out_sof -- out std_logic;
        );
    end generate;
    
    o_FB_out_sof <= FB_out_sof;
    
    process(i_MACE_clk)
    begin
        if rising_edge(i_MACE_clk) then
            ct_rst_del1 <= ct_rst;
            ct_rst_del2 <= ct_rst_del1;
        end if;
    end process;
        
    -- Corner turn between filterbanks and correlator
    ct_cor_out_inst : entity CT_lib.corr_ct2_wrapper_v80
    generic map (
        g_USE_META => g_USE_META,   -- Put meta data into the memory in place of the actual data, to make it easier to find bugs in the corner turn. 
        g_MAX_CORRELATORS => g_MAX_CORRELATORS,
        g_GENERATE_ILA => False
    ) port map (
        -- Registers AXI Lite Interface (uses i_axi_clk)
        i_axi_clk => i_MACE_clk,
        i_axi_rst => i_MACE_rst, -- in std_logic;
        -- pipelined reset from first stage corner turn ?
        i_rst  => ct_rst_del2,  --  in std_logic;
        -- Data in from the correlator filterbanks; bursts of 3456 clocks for each channel.
        -- 
        i_sof             => FB_out_sof,        -- in std_logic; Pulse high at the start of every new group of virtual channels. (1 frame is typically 283 ms of data).
        i_integration     => FD_integration,    -- in std_logic_vector(31 downto 0); -- frame count is the same for all simultaneous output streams.
        i_ctFrame         => FD_ctFrame,        -- in (1:0);
        i_virtualChannel  => FD_virtualChannel, -- in t_slv_16_arr(11 downto 0); 12 virtual channels processed in parallel
        i_bad_poly        => FD_bad_poly,       -- in (2:0); One value for each group of 4 virtual channels.
        i_lastChannel     => FD_lastChannel,    -- in std_logic; Last of the group of 4 channels
        i_demap_table_select => FD_demap_table_select, -- in std_logic;
        i_HeaderValid     => FD_headerValid,    -- in (11:0);
        i_data            => FD_data,           -- in t_ctc_output_payload_arr(11 downto 0); 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), ..., i_data(11)
        i_dataValid       => FD_dataValid,      -- in std_logic;
        --------------------------------------------------------------------------
        -- Data out to the correlators
        -- control data out to the correlator arrays
        -- packets of data to each correlator instance
        o_cor_cfg_data  => cor_cfg_data,  -- out t_slv_8_arr(5 downto 0); -- 8 bit wide buses, to 6 correlators.
        o_cor_cfg_first => cor_cfg_first, -- out std_logic_vector(5 downto 0);
        o_cor_cfg_last  => cor_cfg_last,  -- out std_logic_vector(5 downto 0);
        o_cor_cfg_valid => cor_cfg_valid  -- out std_logic_vector(5 downto 0)
    );
   
    -- Pipeline stages between ct2 and the correlator instances.
    -- This bus may have multiple SLR crossings
    process(i_MACE_clk)
    begin
        if rising_edge(i_MACE_clk) then
            cor_cfg_data_del1  <= cor_cfg_data;  -- out t_slv_8_arr(5 downto 0); -- 8 bit wide buses, to 6 correlators.
            cor_cfg_first_del1 <= cor_cfg_first; -- out (5:0);
            cor_cfg_last_del1  <= cor_cfg_last;  -- out (5:0);
            cor_cfg_valid_del1 <= cor_cfg_valid; -- out (5:0);
            
            cor_cfg_data_del2  <= cor_cfg_data_del1;
            cor_cfg_first_del2 <= cor_cfg_first_del1;
            cor_cfg_last_del2  <= cor_cfg_last_del1;
            cor_cfg_valid_del2 <= cor_cfg_valid_del1;
            
            cor_cfg_data_del3  <= cor_cfg_data_del2;
            cor_cfg_first_del3 <= cor_cfg_first_del2;
            cor_cfg_last_del3  <= cor_cfg_last_del2;
            cor_cfg_valid_del3 <= cor_cfg_valid_del2;
            
            cor_cfg_data_del4  <= cor_cfg_data_del3;
            cor_cfg_first_del4 <= cor_cfg_first_del3;
            cor_cfg_last_del4  <= cor_cfg_last_del3;
            cor_cfg_valid_del4 <= cor_cfg_valid_del3;
        end if;
    end process;
   
    -- Correlator instances
    
    correlator_geni : for i in 0 to (g_CORRELATORS-1) generate
        correlator_wrapperi : entity correlator_lib.correlator_wrapper_v80
        generic map(
            g_CORRELATOR_INSTANCE => i --  integer; unique ID for this correlator instance
        ) port map (
            -- clock used for all data input and output from this module (300 MHz)
            i_axi_clk => i_MACE_clk, -- in std_logic;
            i_axi_rst => i_MACE_rst, -- in std_logic;
            -- Processing clock used for the correlation (>412.5 MHz)
            i_cor_clk => i_clk425, -- in std_logic;
            i_cor_rst => '0',      -- in std_logic;
            ---------------------------------------------------------------
            -- bus in from CT2 with instructions to the correlator core
            -- packets of data to each correlator instance
            -- Receive a single packet full of instructions to each correlator, at the start of each 849ms corner turn frame readout.
            -- The first byte received is the number of subarray-beams configured
            -- The remaining (128 subarray-beams) * (4 words/subarray-beam) * (4 bytes/word) = 2048 bytes contains the subarray-beam table for the correlator
            -- The LSB of the 4th word for each subarray-beam contains the bad_poly bit for the subarray beam.
            -- The correlator should use (o_cor_cfg_last and o_cor_cfg_valid) to trigger processing 849ms of data.
            i_cor_cfg_data  => cor_cfg_data_del4(i),  -- in (7:0); 8 bit wide bus
            i_cor_cfg_first => cor_cfg_first_del4(i), -- in std_logic;
            i_cor_cfg_last  => cor_cfg_last_del4(i),  -- in std_logic;
            i_cor_cfg_valid => cor_cfg_valid_del4(i)  -- in std_logic
        );
    end generate;
    
    -----------------------------------------------------------------------------------------------
    -- 100GE output 
    
    spead_packetiser_top : entity spead_lib.spead_top_cor_v80 
    generic map ( 
        g_CORRELATORS       => g_CORRELATORS,
        g_DEBUG_ILA         => FALSE
    ) port map ( 
        -- clock used for all data input and output from this module (300 MHz)
        i_axi_clk           => i_MACE_clk,
        i_axi_rst           => i_MACE_rst,
        i_local_reset       => '0',
        --
        i_table_swap_in_progress  => table_swap_in_progress,  -- in std_logic;
        i_packetiser_table_select => packetiser_table_select, -- in std_logic;
        i_table_add_remove        => table_add_remove,        -- in std_logic;
        -- streaming AXI to CMAC
        i_cmac_clk          => i_clk_100GE,
        i_cmac_clk_rst      => eth100G_rst,
        o_bytes_to_transmit  => o_bytes_to_transmit,
        o_data_to_player     => o_data_to_player,
        o_data_to_player_wr  => o_data_to_player_wr,
        i_data_to_player_rdy => i_data_to_player_rdy,
        --
        i_debug             => (others => '0')
    );
    
    CMAC_100G_reset_proc : process(i_clk_100GE)
    begin
        if rising_edge(i_clk_100GE) then
            eth100G_rst     <= NOT i_eth100G_locked;
        end if;
    end process;
    
   
END structure;
