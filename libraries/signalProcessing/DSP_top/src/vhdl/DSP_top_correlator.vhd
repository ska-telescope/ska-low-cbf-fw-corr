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
--
-------------------------------------------------------------------------------

LIBRARY IEEE, common_lib, axi4_lib, ct_lib, DSP_top_lib;
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

library technology_lib;
USE technology_lib.tech_mac_100g_pkg.ALL;

library xpm;
use xpm.vcomponents.all;

-------------------------------------------------------------------------------
entity DSP_top_correlator is
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
        g_CORRELATORS            : integer := 2;
        g_MAX_CORRELATORS        : integer := 2;
        g_USE_DUMMY_FB           : boolean := FALSE
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
        o_axis_tdata   : out std_logic_vector(511 downto 0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
        o_axis_tkeep   : out std_logic_vector(63 downto 0);  -- one bit per byte in i_axi_tdata
        o_axis_tlast   : out std_logic;                      
        o_axis_tuser   : out std_logic;
        o_axis_tvalid  : out std_logic;
        i_axis_tready  : in std_logic;
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
        i_MACE_rst  : in std_logic;
        -- LFAADecode, lite + full slave
        i_LFAALite_axi_mosi : in t_axi4_lite_mosi;  -- => mc_lite_mosi(c_LFAADecode_lite_index),
        o_LFAALite_axi_miso : out t_axi4_lite_miso; -- => mc_lite_miso(c_LFAADecode_lite_index),
        i_LFAAFull_axi_mosi : in  t_axi4_full_mosi; -- => mc_full_mosi(c_LFAAdecode_full_index),
        o_LFAAFull_axi_miso : out t_axi4_full_miso; -- => mc_full_miso(c_LFAAdecode_full_index),
        -- Corner Turn between LFAA Ingest and the filterbanks.
        i_LFAA_CT_axi_mosi : in t_axi4_lite_mosi;  --
        o_LFAA_CT_axi_miso : out t_axi4_lite_miso; --
        i_poly_full_axi_mosi : in  t_axi4_full_mosi; -- => mc_full_mosi(c_corr_ct1_full_index),
        o_poly_full_axi_miso : out t_axi4_full_miso; -- => mc_full_miso(c_corr_ct1_full_index),
        -- registers for the filterbanks
        i_FB_axi_mosi : in t_axi4_lite_mosi;
        o_FB_axi_miso : out t_axi4_lite_miso;
        -- Registers for the correlator corner turn 
        i_cor_CT_axi_mosi : in t_axi4_lite_mosi;  --
        o_cor_CT_axi_miso : out t_axi4_lite_miso; --
        -- correlator
        i_cor_axi_mosi : in  t_axi4_lite_mosi;
        o_cor_axi_miso : out t_axi4_lite_miso;
        -- Output HBM
        i_spead_hbm_rd_lite_axi_mosi : in t_axi4_lite_mosi_arr(1 downto 0);
        o_spead_hbm_rd_lite_axi_miso : out t_axi4_lite_miso_arr(1 downto 0);
        -- Output packetiser
        i_spead_lite_axi_mosi   : in t_axi4_lite_mosi_arr(1 downto 0); 
        o_spead_lite_axi_miso   : out t_axi4_lite_miso_arr(1 downto 0);
        i_spead_full_axi_mosi   : in  t_axi4_full_mosi_arr(1 downto 0);
        o_spead_full_axi_miso   : out t_axi4_full_miso_arr(1 downto 0);
        -----------------------------------------------------------------------
        -- AXI interfaces to shared memory
        -- Uses the same clock as MACE (300MHz)
        o_HBM_axi_aw      : out t_axi4_full_addr_arr(5 downto 0); -- write address bus (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_awready : in std_logic_vector(5 downto 0);
        o_HBM_axi_w       : out t_axi4_full_data_arr(5 downto 0); -- w data bus : (.valid, .data(511:0), .last, .resp(1:0))
        i_HBM_axi_wready  : in std_logic_vector(5 downto 0);
        i_HBM_axi_b       : in t_axi4_full_b_arr(5 downto 0);     -- write response bus : (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        o_HBM_axi_ar      : out t_axi4_full_addr_arr(5 downto 0); -- read address bus : (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_arready : in std_logic_vector(5 downto 0);
        i_HBM_axi_r       : in t_axi4_full_data_arr(5 downto 0); -- r data bus (.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_rready  : out std_logic_vector(5 downto 0);
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
        o_hbm_reset    : out std_logic_vector(5 downto 0);
        i_hbm_status   : in t_slv_8_arr(5 downto 0);
        i_hbm_rst_dbg  : in t_slv_32_arr(5 downto 0);
        i_hbm_reset_final : in std_logic;
        i_eth_disable_fsm_dbg : in std_logic_vector(4 downto 0) -- 5 bits
    );
end DSP_top_correlator;

-------------------------------------------------------------------------------
ARCHITECTURE structure OF DSP_top_correlator IS

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
    
    signal FB_data0 : t_slv_8_arr(1 downto 0);
    signal FB_data1 : t_slv_8_arr(1 downto 0);
    signal FB_meta01 : t_CT1_META_out; 
    signal FB_data2 : t_slv_8_arr(1 downto 0);
    signal FB_data3 : t_slv_8_arr(1 downto 0);
    signal FB_meta23 : t_CT1_META_out;
    signal FB_data4 : t_slv_8_arr(1 downto 0);
    signal FB_data5 : t_slv_8_arr(1 downto 0);
    signal FB_meta45 : t_CT1_META_out;
    signal FB_data6 : t_slv_8_arr(1 downto 0);
    signal FB_data7 : t_slv_8_arr(1 downto 0);
    signal FB_meta67 : t_CT1_META_out;    
    
    signal FB_valid : std_logic;
    
    signal FD_integration :  std_logic_vector(31 downto 0); -- frame count is the same for all simultaneous output streams.
    signal FD_ctFrame : std_logic_vector(1 downto 0);
    signal FD_virtualChannel : t_slv_16_arr(3 downto 0); -- 3 virtual channels, one for each of the PST data streams.
    signal FD_headerValid : std_logic_vector(3 downto 0);
    signal FD_data : t_ctc_output_payload_arr(3 downto 0);
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
    signal cor_ready, cor_valid, cor_last, cor_final : std_logic_vector((g_MAX_CORRELATORS-1) downto 0);
    signal cor_tileType, cor_first : std_logic_vector((g_MAX_CORRELATORS-1) downto 0);
    signal cor_data : t_slv_256_arr((g_MAX_CORRELATORS-1) downto 0);
    signal cor_time : t_slv_8_arr((g_MAX_CORRELATORS-1) downto 0);
    signal cor_station : t_slv_12_arr((g_MAX_CORRELATORS-1) downto 0);
    
    signal cor_tileLocation : t_slv_10_arr((g_MAX_CORRELATORS-1) downto 0);
    signal cor_frameCount : t_slv_32_arr((g_MAX_CORRELATORS-1) downto 0);
    signal cor_tileChannel : t_slv_24_arr((g_MAX_CORRELATORS-1) downto 0);
    signal cor_tileTotalTimes : t_slv_8_arr((g_MAX_CORRELATORS-1) downto 0); -- Number of time samples to integrate for this tile.
    signal cor_timeTotalChannels : t_slv_5_arr((g_MAX_CORRELATORS-1) downto 0);  -- Number of frequency channels to integrate for this tile.
    signal cor_rowStations, cor_colStations : t_slv_9_arr((g_MAX_CORRELATORS-1) downto 0); -- number of stations in the row memories to process; up to 256.
    signal cor_totalStations : t_slv_16_arr(g_MAX_CORRELATORS-1 downto 0); -- Total number of stations being processing for this subarray-beam.
    signal cor_subarrayBeam : t_slv_8_arr(g_MAX_CORRELATORS-1 downto 0);
    
    signal cor_packet_data : t_slv_256_arr((g_MAX_CORRELATORS-1) downto 0);
    signal cor_packet_valid : std_logic_vector((g_MAX_CORRELATORS-1) downto 0);
    signal totalChannels : std_logic_vector(11 downto 0);
    signal data_tx_siso : t_lbus_siso;
    signal FB_out_sof : std_logic;
    signal ct_rst_del1, ct_rst_del2 : std_logic := '0';
    signal reset_to_ct_1 : std_logic;
    signal freq_index0_repeat : std_logic;
    
begin
    
    gnd <= (others => '0');
    o_hbm_reset(5 downto 3) <= "000";
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
        o_packetCount    => LFAAingest_packetCount(39 downto 0),     -- out(31:0). Packet count from the SPEAD header.
        o_valid          => LFAAingest_valid,           -- out std_logic; o_virtualChannel and o_packetCount are valid.
        -- wdata portion of the AXI-full external interface (should go directly to the external memory)
        o_axi_w      => o_HBM_axi_w(0),      -- w data bus (.wvalid, .wdata, .wlast)
        i_axi_wready => i_HBM_axi_wready(0), -- 
        --AXI lite Interface
        i_s_axi_mosi       => i_LFAALite_axi_mosi, -- in t_axi4_lite_mosi; at the top level use mc_lite_mosi(c_LFAADecode_lite_index)
        o_s_axi_miso       => o_LFAALite_axi_miso, -- out t_axi4_lite_miso;
        i_s_axi_clk        => i_MACE_clk,         
        i_s_axi_rst        => i_MACE_rst,
        -- registers AXI Full interface
        i_vcstats_MM_IN    => i_LFAAFull_axi_mosi, -- in  t_axi4_full_mosi; At the top level use mc_full_mosi(c_LFAAdecode_full_index),
        o_vcstats_MM_OUT   => o_LFAAFull_axi_miso, -- out t_axi4_full_miso;
        -- Output from the registers that are used elsewhere (on i_s_axi_clk)
        o_totalChannels    => totalChannels,       -- out (11:0); Total number of virtual channels defined.
        
        -- hbm reset   
        o_hbm_reset        => o_hbm_reset(0),
        i_hbm_status       => i_hbm_status(0),

        o_reset_to_ct      => reset_to_ct_1,
        -- debug
        o_dbg              => LFAADecode_dbg
    );
    
    LFAA_FB_CT : entity CT_lib.corr_ct1_top
    -- generic map (
    --     g_SPS_PACKETS_PER_FRAME => g_SPS_PACKETS_PER_FRAME
    -- ) 
    port map (
        -- shared memory interface clock (300 MHz)
        i_shared_clk        => i_MACE_clk, -- in std_logic;
        i_shared_rst        => i_MACE_rst, -- in std_logic;
        --AXI Lite Interface for registers
        i_saxi_mosi         => i_LFAA_CT_axi_mosi, -- in t_axi4_lite_mosi;
        o_saxi_miso         => o_LFAA_CT_axi_miso, -- out t_axi4_lite_miso;
        -- axi full interface for the polynomials
        i_poly_full_axi_mosi => i_poly_full_axi_mosi, --  in  t_axi4_full_mosi; -- => mc_full_mosi(c_corr_ct1_full_index),
        o_poly_full_axi_miso => o_poly_full_axi_miso, --  out t_axi4_full_miso; -- => mc_full_miso(c_corr_ct1_full_index),
        -- other config (from LFAA ingest config, must be the same for the corner turn)
        i_virtualChannels   => totalChannels(10 downto 0), -- in std_logic_vector(10 downto 0); -- total virtual channels (= i_stations * i_coarse)
        i_rst               => reset_to_ct_1,
        o_rst => ct_rst, -- reset output from a register in the corner turn; used to reset downstream modules.
        --o_validMemRstActive => o_validMemRstActive, -- out std_logic;  -- reset is in progress, don't send data; Only used in the testbench. Reset takes about 20us.
        --
        -- Headers for each valid packet received by the LFAA ingest.
        -- LFAA packets are about 8300 bytes long, so at 100Gbps each LFAA packet is about 660 ns long. This is about 200 of the interface clocks (@300MHz)
        -- These signals use i_shared_clk
        i_virtualChannel => LFAAingest_virtualChannel, -- in std_logic_vector(15 downto 0); -- Single number which incorporates both the channel and station; this module supports values in the range 0 to 1023.
        i_packetCount    => LFAAingest_packetCount,    -- in std_logic_vector(31 downto 0);
        i_valid          => LFAAingest_valid, --  in std_logic;    
        -- Data bus output to the Filterbanks
        -- 8 Outputs, each complex data, 8 bit real, 8 bit imaginary.
        o_sof   => FB_sof,     -- out std_logic; start of data for a set of 4 virtual channels.
        o_sofFull => CT_sof,   -- out std_logic; start of the full frame, i.e. a burst of (typically) 283 ms of data.
        o_data0 => FB_data0,   -- out t_slv_8_arr(1 downto 0);
        o_data1 => FB_data1,   -- out t_slv_8_arr(1 downto 0);
        o_meta01 => FB_meta01, -- out 
        o_data2 => FB_data2,   -- out t_slv_8_arr(1 downto 0);
        o_data3 => FB_data3,   -- out t_slv_8_arr(1 downto 0);
        o_meta23 => FB_meta23, -- out 
        o_data4 => FB_data4,   -- out t_slv_8_arr(1 downto 0);
        o_data5 => FB_data5,   -- out t_slv_8_arr(1 downto 0);
        o_meta45 => FB_meta45, -- out 
        o_data6 => FB_data6,   -- out t_slv_8_arr(1 downto 0);
        o_data7 => FB_data7,   -- out t_slv_8_arr(1 downto 0);
        o_meta67 => FB_meta67, -- out 
        o_valid => FB_valid,   -- out std_logic;
        -------------------------------------------------------------
        -- AXI bus to the shared memory. 
        -- This has the aw, b, ar and r buses (the w bus is on the output of the LFAA decode module)
        -- aw bus - write address
        o_m01_axi_aw      => o_HBM_axi_aw(0),      -- out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m01_axi_awready => i_HBM_axi_awready(0), -- in std_logic;
        -- b bus - write response
        i_m01_axi_b  => i_HBM_axi_b(0),            -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        -- ar bus - read address
        o_m01_axi_ar => o_HBM_axi_ar(0),           -- out t_axi4_full_addr; (.valid, .addr(39:0), .len(7:0))
        i_m01_axi_arready => i_HBM_axi_arready(0), -- in std_logic;
        -- r bus - read data
        i_m01_axi_r      => i_HBM_axi_r(0),        -- in t_axi4_full_data  (.valid, .data(511:0), .last, .resp(1:0))
        o_m01_axi_rready => o_HBM_axi_rready(0),   -- out std_logic;
        -------------------------------------------------------------
        -- HBM ILA
        o_m06_axi_aw      => o_HBM_axi_aw(5),      -- out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m06_axi_awready => i_HBM_axi_awready(5), -- in std_logic;
        -- b bus - write response
        o_m06_axi_w       => o_HBM_axi_w(5),       -- t_axi4_full_data; -- (.valid, .data , .last, .resp(1:0))
        i_m06_axi_wready  => i_HBM_axi_wready(5),  -- in std_logic;
        i_m06_axi_b  => i_HBM_axi_b(5),            -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        -- ar bus - read address
        o_m06_axi_ar => o_HBM_axi_ar(5),           -- out t_axi4_full_addr; (.valid, .addr(39:0), .len(7:0))
        i_m06_axi_arready => i_HBM_axi_arready(5), -- in std_logic;
        -- r bus - read data
        i_m06_axi_r      => i_HBM_axi_r(5),        -- in t_axi4_full_data  (.valid, .data(511:0), .last, .resp(1:0))
        o_m06_axi_rready => o_HBM_axi_rready(5),   -- out std_logic;
        --
        i_hbm_rst_dbg  => i_hbm_rst_dbg
    );
    
    -- Correlator filterbank and fine delay.
    FBreali : if (not g_USE_DUMMY_FB) generate

        corFB_i : entity filterbanks_lib.FB_top_correlator
        port map (
            i_data_rst => FB_sof, -- in std_logic;
            -- Register interface
            i_axi_clk => i_MACE_clk,    -- in std_logic;
            i_axi_rst => i_MACE_rst,    -- in std_logic;
            i_axi_mosi => i_FB_axi_mosi, -- in t_axi4_lite_mosi;
            o_axi_miso => o_FB_axi_miso, -- out t_axi4_lite_miso;
            -- Configuration (on i_data_clk)
            i_fineDelayDisable => '0',     -- in std_logic;
            -- Data input, common valid signal, expects packets of 4096 samples
            i_SOF    => FB_sof,
            i_data0  => FB_data0, -- in t_slv_8_arr(1 downto 0);  -- 6 Inputs, each complex data, 8 bit real, 8 bit imaginary.
            i_data1  => FB_data1, -- in t_slv_8_arr(1 downto 0);
            i_meta01 => FB_meta01,
            i_data2  => FB_data2, -- in t_slv_8_arr(1 downto 0);
            i_data3  => FB_data3, -- in t_slv_8_arr(1 downto 0);
            i_meta23 => FB_meta23,
            i_data4  => FB_data4, -- in t_slv_8_arr(1 downto 0);
            i_data5  => FB_data5, -- in t_slv_8_arr(1 downto 0);
            i_meta45 => FB_meta45,
            i_data6  => FB_data6, -- in t_slv_8_arr(1 downto 0);
            i_data7  => FB_data7, -- in t_slv_8_arr(1 downto 0);
            i_meta67 => FB_meta67,
            i_dataValid => FB_valid, -- in std_logic;
            -- Data out; bursts of 3456 clocks for each channel.
            -- Correlator filterbank data output
            o_integration    => FD_integration,    -- out std_logic_vector(31 downto 0); -- frame count is the same for all simultaneous output streams.
            o_ctFrame        => FD_ctFrame,        -- out (1:0);
            o_virtualChannel => FD_virtualChannel, -- out t_slv_16_arr(3 downto 0); -- 3 virtual channels, one for each of the PST data streams.
            o_HeaderValid    => FD_headerValid,    -- out std_logic_vector(3 downto 0);
            o_Data           => FD_data,           -- out t_ctc_output_payload_arr(3 downto 0);
            o_DataValid      => FD_dataValid,      -- out std_logic
            -- i_SOF delayed by 16384 clocks;
            -- i_sof occurs at the start of each new block of 4 virtual channels.
            -- Delay of 16384 is enough to ensure that o_sof falls in the gap
            -- between data packets at the filterbank output that occurs due to the filterbank preload.
            o_sof => FB_out_sof, -- out std_logic;
            -- Correlator filterbank output as packets
            -- Each output packet contains all the data for:
            --  - Single time step
            --  - Single polarisation
            --  - single coarse channel
            -- This is 3456 * 2 (re+im) bytes, plus 16 bytes of header.
            -- The data is transferred in bursts of 433 clocks.
            o_packetData  => FB_to_100G_data, -- out std_logic_vector(127 downto 0);
            o_packetValid => FB_to_100G_valid, -- out std_logic;
            i_packetReady => FB_to_100G_ready  -- in std_logic
        );
    
    end generate;
    
    FBdummyi : if g_USE_DUMMY_FB generate

        corFB_i : entity filterbanks_lib.FB_top_correlator_dummy
        port map (
            i_data_rst => FB_sof, -- in std_logic;
            -- Register interface
            i_axi_clk => i_MACE_clk,    -- in std_logic;
            i_axi_rst => i_MACE_rst,    -- in std_logic;
            i_axi_mosi => i_FB_axi_mosi, -- in t_axi4_lite_mosi;
            o_axi_miso => o_FB_axi_miso, -- out t_axi4_lite_miso;
            -- Configuration (on i_data_clk)
            i_fineDelayDisable => '0',     -- in std_logic;
            i_RFIScale         => "10000", -- in(4:0);
            -- Data input, common valid signal, expects packets of 4096 samples
            i_SOF    => FB_sof,
            i_data0  => FB_data0, -- in t_slv_8_arr(1 downto 0);  -- 6 Inputs, each complex data, 8 bit real, 8 bit imaginary.
            i_data1  => FB_data1, -- in t_slv_8_arr(1 downto 0);
            i_meta01 => FB_meta01,
            i_data2  => FB_data2, -- in t_slv_8_arr(1 downto 0);
            i_data3  => FB_data3, -- in t_slv_8_arr(1 downto 0);
            i_meta23 => FB_meta23,
            i_data4  => FB_data4, -- in t_slv_8_arr(1 downto 0);
            i_data5  => FB_data5, -- in t_slv_8_arr(1 downto 0);
            i_meta45 => FB_meta45,
            i_data6  => FB_data6, -- in t_slv_8_arr(1 downto 0);
            i_data7  => FB_data7, -- in t_slv_8_arr(1 downto 0);
            i_meta67 => FB_meta67,
            i_dataValid => FB_valid, -- in std_logic;
            -- Data out; bursts of 3456 clocks for each channel.
            -- Correlator filterbank data output
            o_integration    => FD_integration,    -- out (31:0); frame count is the same for all simultaneous output streams.
            o_ctFrame        => FD_ctFrame,        -- out (1:0);
            o_virtualChannel => FD_virtualChannel, -- out t_slv_16_arr(3 downto 0); -- 3 virtual channels, one for each of the PST data streams.
            o_HeaderValid    => FD_headerValid,    -- out std_logic_vector(3 downto 0);
            o_Data           => FD_data,           -- out t_ctc_output_payload_arr(3 downto 0);
            o_DataValid      => FD_dataValid,      -- out std_logic
            -- i_SOF delayed by 16384 clocks;
            -- i_sof occurs at the start of each new block of 4 virtual channels.
            -- Delay of 16384 is enough to ensure that o_sof falls in the gap
            -- between data packets at the filterbank output that occurs due to the filterbank preload.
            o_sof => FB_out_sof, -- out std_logic;
            -- Correlator filterbank output as packets
            -- Each output packet contains all the data for:
            --  - Single time step
            --  - Single polarisation
            --  - single coarse channel
            -- This is 3456 * 2 (re+im) bytes, plus 16 bytes of header.
            -- The data is transferred in bursts of 433 clocks.
            o_packetData  => FB_to_100G_data, -- out std_logic_vector(127 downto 0);
            o_packetValid => FB_to_100G_valid, -- out std_logic;
            i_packetReady => FB_to_100G_ready  -- in std_logic
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
    ct_cor_out_inst : entity CT_lib.corr_ct2_top
    generic map (
        g_USE_META => g_USE_META,   -- Put meta data into the memory in place of the actual data, to make it easier to find bugs in the corner turn. 
        g_CORRELATORS => g_CORRELATORS, --  boolean := TRUE
        g_MAX_CORRELATORS => g_MAX_CORRELATORS
    ) port map (
        -- Registers AXI Lite Interface (uses i_axi_clk)
        i_axi_mosi  => i_cor_CT_axi_mosi, -- in t_axi4_lite_mosi;
        o_axi_miso  => o_cor_CT_axi_miso, -- out t_axi4_lite_miso;
        i_axi_rst   => i_MACE_rst, -- in std_logic;
        -- pipelined reset from first stage corner turn ?
        i_rst  => ct_rst_del2,  --  in std_logic;
        -- hbm reset   
        o_hbm_reset_c1      => o_hbm_reset(1),
        i_hbm_status_c1     => i_hbm_status(1),
        
        o_hbm_reset_c2      => o_hbm_reset(2),
        i_hbm_status_c2     => i_hbm_status(2),
        --        
        i_virtualChannels => totalChannels(10 downto 0),  
        -- Data in from the correlator filterbanks; bursts of 3456 clocks for each channel.
        -- 
        i_sof             => FB_out_sof,        -- in std_logic; Pulse high at the start of every new group of virtual channels. (1 frame is typically 283 ms of data).
        i_integration     => FD_integration,    -- in std_logic_vector(31 downto 0); -- frame count is the same for all simultaneous output streams.
        i_ctFrame         => FD_ctFrame,        -- in (1:0);
        i_virtualChannel  => FD_virtualChannel, -- in t_slv_16_arr(3 downto 0); 4 virtual channels, one for each of the PST data streams.
        i_HeaderValid     => FD_headerValid,    -- in (3:0);
        i_data            => FD_data,           -- in t_ctc_output_payload_arr(3 downto 0); 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), i_data(2)
        i_dataValid       => FD_dataValid,      -- in std_logic;
        --------------------------------------------------------------------------
        -- Data out to the correlators
        i_cor_ready             => cor_ready,     -- in std_logic; 
        o_cor_data              => cor_data,      -- out (255:0); 
        o_cor_time              => cor_time,      -- out (7:0); time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
        o_cor_station           => cor_station,   -- out (8:0); first of the 4 stations in i_cor0_data
        o_cor_tileType          => cor_tileType,  -- out slv(); 
        o_cor_valid             => cor_valid,     -- out slv();  -- i_cor0_data, i_cor0_time, i_cor0_VC, i_cor0_FC and i_cor0_tileType are valid when i_cor0_valid = '1'
        o_cor_frameCount        => cor_frameCount, -- out t_slv_32_arr
        o_cor_first             => cor_first,     -- out slv();  -- This is the first block of data for an integration - i.e. first fine channel, first block of 64 time samples, for this tile
        o_cor_last              => cor_last,      -- out slv();  -- last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
        o_cor_final             => cor_final,     -- out slv();  -- Indicates that at the completion of processing the most recent block of correlator data, the integration is complete. i_cor0_tileCount and i_cor0_tileChannel are valid when this is high.
        o_cor_tileLocation      => cor_tileLocation, -- out t_slv_10_arr;   -- bits 3:0 = tile column, bits 7:4 = tile row, bits 9:8 = "00";
        o_cor_tileChannel       => cor_tileChannel,       -- out t_slv_24_arr; Indicates the fine channel relative to the start of the subarray-beam buffer.
        o_cor_tileTotalTimes    => cor_tileTotalTimes,    -- out t_slv_8_arr; Number of time samples to integrate for this tile.
        o_cor_tiletotalChannels => cor_timeTotalChannels, -- out t_slv_5_arr; Number of frequency channels to integrate for this tile.
        o_cor_rowstations       => cor_rowStations,       -- out t_slv_9_arr; Number of stations in the row memories to process; up to 256.
        o_cor_colstations       => cor_colStations,       -- out t_slv_9_arr; Number of stations in the col memories to process; up to 256.   
        o_cor_totalStations     => cor_totalStations,     -- out t_slv_16_arr(g_MAX_CORRELATORS-1 downto 0); Total number of stations being processing for this subarray-beam.
        o_cor_subarrayBeam      => cor_subarrayBeam,      -- out t_slv_8_arr(g_MAX_CORRELATORS-1 downto 0);  Which entry is this in the subarray-beam table ? 
        -- AXI interface to the HBM
        -- Corner turn between filterbanks and correlator
        i_axi_clk         => i_MACE_clk,        -- in std_logic;
        o_HBM_axi_aw      => o_HBM_axi_aw(2 downto 1),      -- out t_axi4_full_addr_arr(g_MAX_CORRELATORS-1 : 0); -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_awready => i_HBM_axi_awready(2 downto 1), -- in  std_logic_vector;
        o_HBM_axi_w       => o_HBM_axi_w(2 downto 1),       -- out t_axi4_full_data_arr; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_HBM_axi_wready  => i_HBM_axi_wready(2 downto 1),  -- in  std_logic_vector;
        i_HBM_axi_b       => i_HBM_axi_b(2 downto 1),       -- in  t_axi4_full_b_arr;    -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        o_HBM_axi_ar      => o_HBM_axi_ar(2 downto 1),      -- out t_axi4_full_addr_arr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_arready => i_HBM_axi_arready(2 downto 1), -- in  std_logic_vector;
        i_HBM_axi_r       => i_HBM_axi_r(2 downto 1),       -- in  t_axi4_full_data_arr; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_rready  => o_HBM_axi_rready(2 downto 1),   -- out std_logic_vector
        -- signals used in testing to initiate readout of the buffer when HBM is preloaded with data,
        -- so we don't have to wait for the previous processing stages to complete.
        i_readout_start  => i_ct2_readout_start,  -- in std_logic;
        i_readout_buffer => i_ct2_readout_buffer,  -- in std_logic
        i_readout_frameCount => i_ct2_readout_frameCount,  -- in (31:0)
        i_freq_index0_repeat => freq_index0_repeat,
        -- debug
        i_hbm_status   => i_hbm_status, -- : in t_slv_8_arr(5 downto 0);
        i_hbm_reset_final => i_hbm_reset_final, -- : in std_logic;
        i_eth_disable_fsm_dbg => i_eth_disable_fsm_dbg, -- : in std_logic_vector(4 downto 0)
        i_hbm_rst_dbg  => i_hbm_rst_dbg   -- in t_slv_32_arr(5 downto 0);
    );
    
    -- Correlator
    
    correlator_inst : entity correlator_lib.correlator_top
    generic map (
        g_CORRELATORS  => g_CORRELATORS, -- integer := 2;
        -- Actual number of samples in a correlator SPEAD packet is this value x 16.
        -- There are 34 bytes per sample : 4 x 8 byte visibilites, + 1 byte TCI + 1 byte DV
        g_PACKET_SAMPLES_DIV16 => g_PACKET_SAMPLES_DIV16 -- integer;
    ) port map (
        -- clock used for all data input and output from this module (300 MHz)
        i_axi_clk => i_MACE_clk, -- in std_logic;
        i_axi_rst => i_MACE_rst, -- in std_logic;
        -- Processing clock used for the correlation (>412.5 MHz)
        i_cor_clk => i_clk425,   -- in std_logic;
        i_cor_rst => '0',        -- in std_logic;    
        
        ------------------------------------------------------------------------------------
        -- data input for the first correlator instance
        o_cor0_ready => cor_ready(0), --  out std_logic;  
        -- Each 256 bit word : two time samples, 4 consecutive virtual channels
        -- (31:0) = time 0, virtual channel 0; (63:32) = time 0, virtual channel 1; (95:64) = time 0, virtual channel 2; (127:96) = time 0, virtual channel 3;
        -- (159:128) = time 1, virtual channel 0; (191:160) = time 1, virtual channel 1; (223:192) = time 1, virtual channel 2; (255:224) = time 1, virtual channel 3;
        i_cor0_data  => cor_data(0),  --  in std_logic_vector(255 downto 0); 
        -- meta data
        i_cor0_time    => cor_time(0), --  in std_logic_vector(7 downto 0); -- time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
        i_cor0_station => cor_station(0),   --  in std_logic_vector(8 downto 0); -- first of the 4 virtual channels in i_cor0_data
        -- Options for tileType : 
        --   '0' = Triangle. In this case, all the input data goes to both the row and column memories, and a triangle from the correlation matrix is computed.
        --            For correlation cells on the diagonal, only non-duplicate entries are sent out.
        --   '1' = Rectangle. In this case, the first 256 virtual channels on i_cor0_data go to the column memories, while the next 128 virtual channels go to the row memories.
        --            All correlation products for the rectangle are then computed.
        i_cor0_tileType => cor_tileType(0), --  in std_logic;
        i_cor0_valid    => cor_valid(0),    --  in std_logic;  -- i_cor0_data, i_cor0_time, i_cor0_VC, i_cor0_FC and i_cor0_tileType are valid when i_cor0_valid = '1'
        -- i_cor0_last and i_cor0_final go high after a block of data has been sent.
        i_cor0_first    => cor_first(0),    --  in std_logic;  -- This is the first block of data for an integration - i.e. first fine channel, first block of 64 time samples, for this tile
        i_cor0_last     => cor_last(0),     --  in std_logic;  -- last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
        i_cor0_final    => cor_final(0),    -- in std_logic;  -- Indicates that at the completion of processing the most recent block of correlator data, the integration is complete. i_cor0_tileCount and i_cor0_tileChannel are valid when this is high.   
        -- up to 1024 different tiles; each tile is a subset of the correlation for particular subarray and beam.
        -- Tiles can be triangles or rectangles from the full correlation.
        -- e.g. for 512x512 stations, there will be 4 tiles, consisting of 2 triangles and 2 rectangles.
        --      for 4096x4096 stations, there will be 16 triangles, and 240 rectangles.
        i_cor0_tileLocation => cor_tileLocation(0), --  in std_logic_vector(9 downto 0);
        i_cor0_frameCount   => cor_frameCount(0),   -- in (31:0);
        -- Which block of frequency channels is this tile for ?
        -- This sets the offset within the HBM that the result is written to, relative to the base address which is extracted from registers based on i_cor0_tileCount.
        i_cor0_tileChannel       => cor_tileChannel(0),       -- in (23:0);
        i_cor0_tileTotalTimes    => cor_tileTotalTimes(0),    -- in (7:0);  Number of time samples to integrate for this tile.
        i_cor0_tiletotalChannels => cor_timeTotalChannels(0), -- in (4:0);  Number of frequency channels to integrate for this tile.
        i_cor0_rowstations       => cor_rowStations(0),       -- in (8:0);  Number of stations in the row memories to process; up to 256.
        i_cor0_colstations       => cor_colStations(0),       -- in (8:0);  Number of stations in the col memories to process; up to 256.
        i_cor0_totalStations     => cor_totalStations(0),     -- in (15:0); Total number of stations being processing for this subarray-beam.
        i_cor0_subarrayBeam      => cor_subarrayBeam(0),      -- in (7:0);  Which entry is this in the subarray-beam table ?
        ------------------------------------------------------------------------------------
        -- Data input for the second correlator instance
        o_cor1_ready    => cor_ready(1), --  out std_logic; 
        i_cor1_data     => cor_data(1),  --  in (255:0); 
        i_cor1_time     => cor_time(1),  --  in (7:0); Time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
        i_cor1_station  => cor_station(1),  --  in (8:0); First of the 4 virtual channels in i_cor0_data
        i_cor1_tileType => cor_tileType(1), --  in std_logic;
        i_cor1_valid    => cor_valid(1),    --  in std_logic; i_cor0_data, i_cor0_time, i_cor0_VC, i_cor0_FC and i_cor0_tileType are valid when i_cor0_valid = '1'
        i_cor1_first    => cor_first(1),    -- in std_logic;  This is the first block of data for an integration - i.e. first fine channel, first block of 64 time samples, for this tile
        i_cor1_last     => cor_last(1),     -- in std_logic;  Last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
        i_cor1_final    => cor_final(1),    -- in std_logic;  Indicates that at the completion of processing the most recent block of correlator data, the integration is complete. i_cor0_tileCount and i_cor0_tileChannel are valid when this is high.
        i_cor1_tileLocation => cor_tileLocation(1), --  in (9:0);
        i_cor1_frameCount   => cor_frameCount(1),   -- in (31:0);
        i_cor1_tileChannel       => cor_tileChannel(1),       --  in (23:0);
        i_cor1_tileTotalTimes    => cor_tileTotalTimes(1),    --  in (7:0); Number of time samples to integrate for this tile.
        i_cor1_tiletotalChannels => cor_timeTotalChannels(1), --  in (4:0); Number of frequency channels to integrate for this tile.
        i_cor1_rowstations       => cor_rowStations(1),       --  in (8:0); Number of stations in the row memories to process; up to 256.
        i_cor1_colstations       => cor_colStations(1),       --  in (8:0); Number of stations in the col memories to process; up to 256.           
        i_cor1_totalStations     => cor_totalStations(1),     -- in (15:0); Total number of stations being processing for this subarray-beam.
        i_cor1_subarrayBeam      => cor_subarrayBeam(1),      -- in (7:0);  Which entry is this in the subarray-beam table ?
        
        -- AXI interface to the HBM for storage of visibilities
        o_cor0_axi_aw      => o_HBM_axi_aw(3),      -- out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_cor0_axi_awready => i_HBM_axi_awready(3), -- in  std_logic;
        o_cor0_axi_w       => o_HBM_axi_w(3),       -- out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_cor0_axi_wready  => i_HBM_axi_wready(3),  -- in  std_logic;
        i_cor0_axi_b       => i_HBM_axi_b(3),       -- in  t_axi4_full_b;    -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        o_cor0_axi_ar      => o_HBM_axi_ar(3),      -- out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_cor0_axi_arready => i_HBM_axi_arready(3), -- in  std_logic;
        i_cor0_axi_r       => i_HBM_axi_r(3),       -- in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_cor0_axi_rready  => o_HBM_axi_rready(3),  -- out std_logic
        
        
        -- axi interface to the HBM for the second correlator instance.
        o_cor1_axi_aw      => o_HBM_axi_aw(4),      -- out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_cor1_axi_awready => i_HBM_axi_awready(4), -- in  std_logic;
        o_cor1_axi_w       => o_HBM_axi_w(4),       -- out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_cor1_axi_wready  => i_HBM_axi_wready(4),  -- in  std_logic;
        i_cor1_axi_b       => i_HBM_axi_b(4),       -- in  t_axi4_full_b;    -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        o_cor1_axi_ar      => o_HBM_axi_ar(4),      -- out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_cor1_axi_arready => i_HBM_axi_arready(4), -- in  std_logic;
        i_cor1_axi_r       => i_HBM_axi_r(4),       -- in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_cor1_axi_rready  => o_HBM_axi_rready(4),   -- out std_logic
        
        ------------------------------------------------------------------        
        -- spead packet interface
        i_from_spead_pack   => from_spead_pack,
        o_to_spead_pack     => to_spead_pack,

        i_packetiser_enable     => packetiser_enable,
        
        -- ARGs Debug
        i_spead_hbm_rd_lite_axi_mosi => i_spead_hbm_rd_lite_axi_mosi,
        o_spead_hbm_rd_lite_axi_miso => o_spead_hbm_rd_lite_axi_miso,
        ------------------------------------------------------------------
        -- Registers AXI Lite Interface (uses i_axi_clk)
        i_axi_mosi => i_cor_axi_mosi, -- in t_axi4_lite_mosi;
        o_axi_miso => o_cor_axi_miso, -- out t_axi4_lite_miso;
        
        ------------------------------------------------------------------
        -- Data output to the packetiser
        o_packet0_dout  => cor_packet_data(0),  --  out (255:0);
        o_packet0_valid => cor_packet_valid(0), --  out std_logic;
        i_packet0_ready => '1',               --  in std_logic
        
        o_packet1_dout  => cor_packet_data(1),  --  out (255:0);
        o_packet1_valid => cor_packet_valid(1), --  out std_logic;
        i_packet1_ready => '1',                --  in std_logic

        ---------------------------------------------------------------
        -- copy of the bus taking data to be written to the HBM.
        -- Used for simulation only, to check against the model data.
        o_tb_data      => o_tb_data,     -- out (255:0);
        o_tb_visValid  => o_tb_visValid, -- out std_logic; -- o_tb_data is valid visibility data
        o_tb_TCIvalid  => o_tb_TCIvalid, -- out std_logic; -- i_data is valid TCI & DV data
        o_tb_dcount    => o_tb_dcount,   -- out (7:0);  -- counts the 256 transfers for one cell of visibilites, or 16 transfers for the centroid data. 
        o_tb_cell      => o_tb_cell,     -- out (7:0);  -- in (7:0);  -- a "cell" is a 16x16 station block of correlations
        o_tb_tile      => o_tb_tile,     -- out (9:0);  -- a "tile" is a 16x16 block of cells, i.e. a 256x256 station correlation.
        o_tb_channel   => o_tb_channel,   -- out (23:0) -- first fine channel index for this correlation.
        
        --
        o_freq_index0_repeat => freq_index0_repeat
    );
    
    
    -----------------------------------------------------------------------------------------------
    -- 100GE output 
    
    spead_packetiser_top : entity spead_lib.spead_top 
    generic map ( 
        g_CORRELATORS       => g_CORRELATORS,
        g_DEBUG_ILA         => FALSE
    )
    port map ( 
        -- clock used for all data input and output from this module (300 MHz)
        i_axi_clk           => i_MACE_clk,
        i_axi_rst           => i_MACE_rst,

        i_local_reset       => '0',

        -- streaming AXI to CMAC
        i_cmac_clk          => i_clk_100GE,
        i_cmac_clk_rst      => eth100G_rst,

        o_tx_axis_tdata     => o_axis_tdata,
        o_tx_axis_tkeep     => o_axis_tkeep,
        o_tx_axis_tvalid    => o_axis_tvalid,
        o_tx_axis_tlast     => o_axis_tlast,
        o_tx_axis_tuser     => o_axis_tuser,
        i_tx_axis_tready    => i_axis_tready,

        -- Packed up Correlator Data.
        o_from_spead_pack   => from_spead_pack,
        i_to_spead_pack     => to_spead_pack,

        o_packetiser_enable => packetiser_enable,
        
        i_debug             => (others => '0'),

        -- ARGs interface.
        i_spead_lite_axi_mosi   => i_spead_lite_axi_mosi,
        o_spead_lite_axi_miso   => o_spead_lite_axi_miso,
        i_spead_full_axi_mosi   => i_spead_full_axi_mosi,
        o_spead_full_axi_miso   => o_spead_full_axi_miso
    );  

    CMAC_100G_reset_proc : process(i_clk_100GE)
    begin
        if rising_edge(i_clk_100GE) then
            eth100G_rst     <= NOT i_eth100G_locked;
        end if;
    end process;
    
   
END structure;
