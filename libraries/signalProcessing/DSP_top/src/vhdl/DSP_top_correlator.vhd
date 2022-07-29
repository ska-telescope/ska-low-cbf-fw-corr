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
library LFAADecode100G_lib, timingcontrol_lib, capture128bit_lib, captureFine_lib, DSP_top_lib, filterbanks_lib, interconnect_lib, bf_lib, PSR_Packetiser_lib, correlator_lib;
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

use PSR_Packetiser_lib.ethernet_pkg.ALL;
use PSR_Packetiser_lib.CbfPsrHeader_pkg.ALL;

library technology_lib;
USE technology_lib.tech_mac_100g_pkg.ALL;

library xpm;
use xpm.vcomponents.all;

-------------------------------------------------------------------------------
entity DSP_top_correlator is
    generic (
        -- Number of LFAA blocks per frame for the PSS/PST output.
        -- Each LFAA block is 2048 time samples. e.g. 27 for a 60 ms corner turn.
        -- This value needs to be a multiple of 3 so that there are a whole number of PST outputs per frame.
        -- Maximum value is 30, (limited by the 256MByte buffer size, which has to fit 1024 virtual channels)
        g_DEBUG_ILA              : boolean := false;
        g_BEAM_ILA               : boolean := false;
        g_LFAA_BLOCKS_PER_FRAME  : integer := 9;  -- Number of LFAA blocks per frame divided by 3; minimum value is 1, i.e. 3 LFAA blocks per frame.
        g_USE_META               : boolean := FALSE  -- Put meta data into the memory in place of the actual data, to make it easier to find bugs in the corner turn. 
    );
    port (
        -----------------------------------------------------------------------
        -- Received data from 100GE
        i_data_rx_sosi      : in t_lbus_sosi;
        -- Data to be transmitted on 100GE
        o_data_tx_sosi      : out t_lbus_sosi;
        i_data_tx_siso      : in t_lbus_siso;
        i_clk_100GE         : in std_logic;
        i_eth100G_locked    : in std_logic;
        -----------------------------------------------------------------------
        -- Other processing clocks.
        i_clk450 : in std_logic; -- 450 MHz
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
        -- Timing control
        i_timing_axi_mosi : in t_axi4_lite_mosi;
        o_timing_axi_miso : out t_axi4_lite_miso;
        -- Corner Turn between LFAA Ingest and the filterbanks.
        i_LFAA_CT_axi_mosi : in t_axi4_lite_mosi;  --
        o_LFAA_CT_axi_miso : out t_axi4_lite_miso; --
        -- registers for the filterbanks
        i_FB_axi_mosi : in t_axi4_lite_mosi;
        o_FB_axi_miso : out t_axi4_lite_miso;
        -- Registers for the correlator corner turn 
        i_cor_CT_axi_mosi : in t_axi4_lite_mosi;  --
        o_cor_CT_axi_miso : out t_axi4_lite_miso; --
        -- correlator
        i_cor_axi_mosi : in  t_axi4_lite_mosi;
        o_cor_axi_miso : out t_axi4_lite_miso;
        -- Output packetiser
        i_PSR_packetiser_Lite_axi_mosi : in t_axi4_lite_mosi; 
        o_PSR_packetiser_Lite_axi_miso : out t_axi4_lite_miso;
        
        i_PSR_packetiser_Full_axi_mosi : in  t_axi4_full_mosi;
        o_PSR_packetiser_Full_axi_miso : out t_axi4_full_miso;
        -----------------------------------------------------------------------
        -- AXI interfaces to shared memory
        -- Uses the same clock as MACE (300MHz)
        --  Shared memory block for the first corner turn (at the output of the LFAA ingest block)
        -- Corner Turn between LFAA ingest and the filterbanks
        -- aw bus - write addresses.
        o_m01_axi_aw      : out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m01_axi_awready : in  std_logic;
        o_m01_axi_w       : out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_m01_axi_wready  : in  std_logic;
        i_m01_axi_b       : in  t_axi4_full_b;    -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        o_m01_axi_ar      : out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m01_axi_arready : in  std_logic;
        i_m01_axi_r       : in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_m01_axi_rready  : out std_logic;
        
        -- Buffer between filterbanks and correlator - could be up to 6 Gbytes.
        o_m02_axi_aw      : out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m02_axi_awready : in  std_logic;
        o_m02_axi_w       : out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_m02_axi_wready  : in  std_logic;
        i_m02_axi_b       : in  t_axi4_full_b;    -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        o_m02_axi_ar      : out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m02_axi_arready : in  std_logic;
        i_m02_axi_r       : in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_m02_axi_rready  : out std_logic;
        
        -- Visibilities buffer
        -- aw, w, b, ar, and r buses.
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
END DSP_top_correlator;

-------------------------------------------------------------------------------
ARCHITECTURE structure OF DSP_top_correlator IS

    ---------------------------------------------------------------------------
    -- SIGNAL DECLARATIONS  --
    --------------------------------------------------------------------------- 
    
    signal dbg_timer_expire : std_logic;
    signal dbg_timer  :  std_logic_vector(15 downto 0);    
    signal LFAADecode_dbg : std_logic_vector(13 downto 0);
    signal LFAA_tx_fsm, LFAA_stats_fsm, LFAA_rx_fsm : std_logic_vector(3 downto 0);
    signal LFAA_goodpacket, LFAA_nonSPEAD : std_logic;
    
    signal gnd : std_logic_vector(199 downto 0);
    
    signal timingPacketData : std_logic_vector(63 downto 0);
    signal timingPacketValid : std_logic;
    
    signal clk_LFAA40GE_wallTime : t_wall_time;
    signal clk_HBM_wallTime : t_wall_time;
    --signal clk_wall_wallTime : t_wall_time;
    
    signal CTCDataIn : std_logic_vector(63 downto 0);
    signal CTCValidIn : std_logic;
    signal CTCSOPIn   : std_logic;
    
  
    signal CTFCorDataIn : std_logic_vector(63 downto 0);
    signal CTFCorSOPIn  : std_logic;
    signal CTFCorValid  : std_logic;
    
    signal MACE_clk_vec : std_logic_vector(0 downto 0);
    signal MACE_clk_rst : std_logic_vector(0 downto 0);
    
    --signal dsp_top_rw  : t_statctrl_rw;
    
    signal CTC_CorSof : std_logic; -- single cycle pulse: this cycle is the first of 204*4096
    --signal CTC_CorHeader : t_ctc_output_header_a(pc_CTC_OUTPUT_NUMBER-1 downto 0);    -- meta data belonging to the data coming out
    signal CTC_CorHeaderValid : std_logic;                                            -- new meta data (every output packet, aka 4096 cycles) 
    --signal CTC_CorData : t_ctc_output_data_a(pc_CTC_OUTPUT_NUMBER-1 downto 0);      -- the actual output data
    signal CTC_CorDataValid : std_logic;

    signal CTC_CorSof_del1 : std_logic; -- single cycle pulse: this cycle is the first of 204*4096
    --signal CTC_CorHeader_del1 : t_ctc_output_header_a(pc_CTC_OUTPUT_NUMBER-1 downto 0);    -- meta data belonging to the data coming out
    signal CTC_CorHeaderValid_del1 : std_logic;                                            -- new meta data (every output packet, aka 4096 cycles) 
    --signal CTC_CorData_del1 : t_ctc_output_data_a(pc_CTC_OUTPUT_NUMBER-1 downto 0);      -- the actual output data
    signal CTC_CorDataValid_del1 : std_logic;

    signal CTC_CorSof_del2 : std_logic; -- single cycle pulse: this cycle is the first of 204*4096
    --signal CTC_CorHeader_del2  : t_ctc_output_header_a(pc_CTC_OUTPUT_NUMBER-1 downto 0);    -- meta data belonging to the data coming out
    signal CTC_CorHeaderValid_del2  : std_logic;                                            -- new meta data (every output packet, aka 4096 cycles) 
    --signal CTC_CorData_del2  : t_ctc_output_data_a(pc_CTC_OUTPUT_NUMBER-1 downto 0);      -- the actual output data
    signal CTC_CorDataValid_del2  : std_logic;

    signal CTC_CorSof_del3  : std_logic; -- single cycle pulse: this cycle is the first of 204*4096
    --signal CTC_CorHeader_del3 : t_ctc_output_header_a(pc_CTC_OUTPUT_NUMBER-1 downto 0);    -- meta data belonging to the data coming out
    signal CTC_CorHeaderValid_del3 : std_logic;                                            -- new meta data (every output packet, aka 4096 cycles) 
    --signal CTC_CorData_del3 : t_ctc_output_data_a(pc_CTC_OUTPUT_NUMBER-1 downto 0);      -- the actual output data
    signal CTC_CorDataValid_del3 : std_logic;

    signal CTC_PSSPSTSof : std_logic; 
    --signal CTC_PSSPSTData : t_ctc_output_data_a(2 downto 0);  -- 3 different streams, each 32 bits (8 bits each for VpolRe, VpolIm, HpolRe, HpolIm)
    signal CTC_PSSPSTDataValid : std_logic;
    --signal CTC_PSSPSTHeader : t_ctc_output_header_a(2 downto 0); -- one header per stream
    signal CTC_PSSPSTHeaderValid : std_logic;

    signal CTC_PSSPSTSof_del1 : std_logic; 
    --signal CTC_PSSPSTData_del1 : t_ctc_output_data_a(2 downto 0);  -- 3 different streams, each 32 bits (8 bits each for VpolRe, VpolIm, HpolRe, HpolIm)
    signal CTC_PSSPSTDataValid_del1 : std_logic;
    --signal CTC_PSSPSTHeader_del1 : t_ctc_output_header_a(2 downto 0); -- one header per stream
    signal CTC_PSSPSTHeaderValid_del1 : std_logic;
    
    signal CTC_PSSPSTSof_del2 : std_logic; 
    --signal CTC_PSSPSTData_del2 : t_ctc_output_data_a(2 downto 0);  -- 3 different streams, each 32 bits (8 bits each for VpolRe, VpolIm, HpolRe, HpolIm)
    signal CTC_PSSPSTDataValid_del2 : std_logic;
    --signal CTC_PSSPSTHeader_del2 : t_ctc_output_header_a(2 downto 0); -- one header per stream
    signal CTC_PSSPSTHeaderValid_del2 : std_logic;
    
    signal CTC_PSSPSTSof_del3 : std_logic; 
    --signal CTC_PSSPSTData_del3 : t_ctc_output_data_a(2 downto 0);  -- 3 different streams, each 32 bits (8 bits each for VpolRe, VpolIm, HpolRe, HpolIm)
    signal CTC_PSSPSTDataValid_del3 : std_logic;
    --signal CTC_PSSPSTHeader_del3 : t_ctc_output_header_a(2 downto 0); -- one header per stream
    signal CTC_PSSPSTHeaderValid_del3 : std_logic;    
        
    
    signal CTC_HBM_clk_rst : std_logic;          -- reset going to the HBM core
    signal CTC_HBM_mosi : t_axi4_full_mosi;   -- data going to the HBM core
    signal CTC_HBM_miso : t_axi4_full_miso;   -- data coming from the HBM core
    signal CTC_HBM_ready : std_logic;
    
    --signal FB_PSSHeader      : t_ctc_output_header_a(2 downto 0);
    signal FB_PSSHeaderValid : std_logic;
    --signal FB_PSSData        : t_ctc_output_data_a(2 downto 0);
    signal FB_PSSDataValid   : std_logic;
    -- PST filterbank data output
    --signal FB_PSTHeader      : t_ctc_output_header_a(2 downto 0);
    signal FB_PSTHeaderValid : std_logic;
    --signal FB_PSTData        : t_ctc_output_data_a(2 downto 0);
    signal FB_PSTDataValid   : std_logic;
    signal HBMPage : std_logic_vector(9 downto 0);
    signal hbm_width_rst : std_logic := '0';
    
    signal MACE_HBM_mosi : t_axi4_full_mosi;
    signal MACE_HBM_miso : t_axi4_full_miso;
    
    signal hbm_axi_rst, hbm_axi_rst_del1, hbm_axi_rst_del2, hbm_axi_rst_del3 : std_logic := '0';
    signal IC_rst, IC_rst_del1, IC_rst_del2, IC_rst_del3 : std_logic_vector(31 downto 0);
    
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
    signal LFAAingest_packetCount    : std_logic_vector(31 downto 0);  -- Packet count from the SPEAD header.
    signal LFAAingest_valid          : std_logic;                      -- out std_logic
    
    signal LFAAingest_wvalid : std_logic;
    signal LFAAingest_wready : std_logic;
    signal LFAAingest_wdata  : std_logic_vector(511 downto 0);
    signal LFAAingest_wstrb  : std_logic_vector(63 downto 0);
    signal LFAAingest_wlast  : std_logic;
    
    signal FB_sof : std_logic;
    
    signal FB_data0 : t_slv_8_arr(1 downto 0);
    signal FB_data1 : t_slv_8_arr(1 downto 0);
    signal FB_meta01 : t_atomic_CT_pst_META_out; 
    signal FB_data2 : t_slv_8_arr(1 downto 0);
    signal FB_data3 : t_slv_8_arr(1 downto 0);
    signal FB_meta23 : t_atomic_CT_pst_META_out;
    signal FB_data4 : t_slv_8_arr(1 downto 0);
    signal FB_data5 : t_slv_8_arr(1 downto 0);
    signal FB_meta45 : t_atomic_CT_pst_META_out;
    signal FB_data6 : t_slv_8_arr(1 downto 0);
    signal FB_data7 : t_slv_8_arr(1 downto 0);
    signal FB_meta67 : t_atomic_CT_pst_META_out;    
    
    signal FB_valid : std_logic;
    
    signal clk300_walltime : std_logic_vector(63 downto 0); -- wall time in clk300 domain, in nanoseconds
    signal clk400_walltime : std_logic_vector(63 downto 0); -- out(63:0); -- wall time in clk400 domain, in nanoseconds
    signal clk450_walltime : std_logic_vector(63 downto 0); -- out(63:0); -- wall time in the clk450 domain, in nanoseconds
    signal clk322_walltime : std_logic_vector(63 downto 0); -- 
    
    signal FD_frameCount :  std_logic_vector(36 downto 0); -- frame count is the same for all simultaneous output streams.
    signal FD_virtualChannel : t_slv_16_arr(3 downto 0); -- 3 virtual channels, one for each of the PST data streams.
    signal FD_headerValid : std_logic_vector(3 downto 0);
    signal FD_data : t_ctc_output_payload_arr(3 downto 0);
    signal FD_dataValid : std_logic;
    
    signal totalStations : std_logic_vector(11 downto 0);
    signal totalCoarse   : std_logic_vector(11 downto 0);
    signal totalChannels : std_logic_vector(11 downto 0); 
    
    signal BFdataIn : std_logic_vector(95 downto 0); -- 3 consecutive fine channels delivered every clock.
    signal BFflagged : std_logic_vector(2 downto 0);
    signal BFFine : std_logic_vector(7 downto 0);  -- fine channel / 3, so the actual fine channel for the first of the 3 fine channels in o_data is (o_fine*3)
    signal BFCoarse : std_logic_vector(9 downto 0); -- coarse channel.
    signal BFPacketCount : std_logic_vector(36 downto 0); -- The packet count for this packet, based on the original packet count from LFAA.
    signal BFValidIn : std_logic;
    signal BFBeamsEnabled : std_logic_vector(7 downto 0);
    signal ct_rst : std_logic;
    signal ct_sof : std_logic;
    signal CT_sofCount : std_logic_vector(11 downto 0) := (others => '0');
    signal CT_sofFinal : std_logic := '0';
    
    signal BFFirstStation : std_logic;
    signal BFLastStation : std_logic;
    signal BFtimeStep : std_logic_vector(4 downto 0);
    signal BFVirtualChannel : std_logic_vector(9 downto 0);
    
    signal BFJonesBuffer : std_logic;
    signal BFPhaseBuffer : std_logic;
    
    signal beamData : std_logic_vector(63 downto 0);
    signal beamPacketCount : std_logic_vector(36 downto 0);
    signal beamBeam : std_logic_vector(7 downto 0);
    signal beamFreqIndex : std_logic_vector(10 downto 0);
    signal beamValid : std_logic;
    
    -- copy of the beam bus with breakout of some signals so names are easier to see in the ILA core.
    signal bDataReal0, bDataImag0, bDataReal1, bDataImag1 : std_logic_vector(15 downto 0);
    signal bVirtualChannel : std_logic_vector(9 downto 0);  -- 10 bits
    signal bBeam : std_logic_vector(7 downto 0);  -- 8 bits
    signal bPacketCount : std_logic_vector(36 downto 0); -- 37 bits
    signal bValid : std_logic;
    
    signal m02_axi_awvalid_dbg : std_logic;
    signal m02_axi_awready_dbg : std_logic;
    signal m02_axi_awaddr_dbg  : std_logic_vector(27 downto 0);
    signal m02_axi_awlen_dbg   : std_logic_vector(3 downto 0);
    -- w bus - write data
    signal m02_axi_wvalid_dbg  : std_logic;
    signal m02_axi_wready_dbg  : std_logic;
    signal m02_axi_wdata_dbg   : std_logic_vector(255 downto 0);
    signal m02_axi_wlast_dbg   : std_logic;
    -- b bus - write response
    signal m02_axi_bvalid_dbg  : std_logic;
    signal m02_axi_bresp_dbg   : std_logic_vector(1 downto 0);
    -- ar bus - read address
    signal m02_axi_arvalid_dbg  : std_logic;
    signal m02_axi_arready_dbg  : std_logic;
    signal m02_axi_araddr_dbg   : std_logic_vector(27 downto 0);
    signal m02_axi_arlen_dbg    : std_logic_vector(3 downto 0);
    -- r bus - read data
    signal m02_axi_rvalid_dbg   : std_logic;
    signal m02_axi_rready_dbg   : std_logic;
    signal m02_axi_rdata_dbg    : std_logic_vector(255 downto 0);
    signal m02_axi_rlast_dbg    : std_logic;
    signal m02_axi_rresp_dbg    : std_logic_vector(1 downto 0);


    signal m03_axi_awvalid_dbg : std_logic;
    signal m03_axi_awready_dbg : std_logic;
    signal m03_axi_awaddr_dbg  : std_logic_vector(27 downto 0);
    signal m03_axi_awlen_dbg   : std_logic_vector(3 downto 0);
    -- w bus - write data
    signal m03_axi_wvalid_dbg  : std_logic;
    signal m03_axi_wready_dbg  : std_logic;
    signal m03_axi_wdata_dbg   : std_logic_vector(255 downto 0);
    signal m03_axi_wlast_dbg   : std_logic;
    -- ar bus - read address
    signal m03_axi_arvalid_dbg  : std_logic;
    signal m03_axi_arready_dbg  : std_logic;
    signal m03_axi_araddr_dbg   : std_logic_vector(27 downto 0);
    signal m03_axi_arlen_dbg    : std_logic_vector(3 downto 0);
    -- r bus - read data
    signal m03_axi_rvalid_dbg   : std_logic;
    signal m03_axi_rready_dbg   : std_logic;
    signal m03_axi_rdata_dbg    : std_logic_vector(255 downto 0);
    signal m03_axi_rlast_dbg    : std_logic;
    signal m03_axi_rresp_dbg    : std_logic_vector(1 downto 0);
    
    signal dbg_ILA_trigger, bdbg_ILA_triggerDel1, bdbg_ILA_trigger, bdbg_ILA_triggerDel2 : std_logic;
    signal dataMismatch_dbg, dataMismatch, datamismatchBFclk : std_logic;
    
    signal cmac_reset           : std_logic;
    
    signal beamformer_to_packetiser_data :  packetiser_stream_in;  
    signal packet_stream_stats           :  t_packetiser_stats(2 downto 0);

    signal packetiser_host_bus_in : packetiser_config_in;  
    signal packetiser_host_bus_out :  packetiser_config_out;  
    signal packetiser_host_bus_out_2        : packetiser_config_out;
    signal packetiser_host_bus_out_3        : packetiser_config_out;  

    signal packetiser_host_bus_ctrl :  packetiser_stream_ctrl;
    
    signal FB_to_100G_data : std_logic_vector(127 downto 0);
    signal FB_to_100G_valid : std_logic;
    signal FB_to_100G_ready : std_logic;
    signal packet_stream_out : t_packetiser_stream_out(2 downto 0);
    
begin
    
    gnd <= (others => '0');
    
    --------------------------------------------------------------------------
    -- Signal Processing signal Chains
    --------------------------------------------------------------------------
    mac100G <= x"aabbccddeeff";
    clk100GE_wallTime.sec <= (others => '0');
    clk100GE_wallTime.ns <= (others => '0');
    
    
    -- Takes in data from the 100GE port, checks it is a valid SPEAD packet, then
    --  - Notifies the corner turn, which generates the write address part of the AXI memory interface.
    --  - Outputs the data part of the packet on the wdata part of the AXI memory interface.
    LFAAin : entity LFAADecode100G_lib.LFAADecodeTop100G
    port map(
        -- Data in from the 100GE MAC
        -- Input is a 512 bit wide data in from the 100GE core. It consists of 4 segments of 128 bits each.
        -- Includes .data(511:0), .valid(3:0), .eop(3:0), .sop(3:0), .error(3:0), .empty(3:0)(3:0)
        i_eth100_rx_sosi => i_data_rx_sosi, -- in t_axi4_sosi; lds that are used are .tdata, .tvalid, .tuser
        i_data_clk       => i_clk_100GE,    -- in std_logic;  322 MHz for 100GE MAC
        i_data_rst       => '0',            -- in std_logic;
        -- Data to the corner turn. This is just some header information about each LFAA packet, needed to generate the address the data is to be written to.
        o_virtualChannel => LFAAingest_virtualChannel,  -- out(15:0), single number to uniquely identify the channel+station for this packet.
        o_packetCount    => LFAAingest_packetCount,     -- out(31:0). Packet count from the SPEAD header.
        o_valid          => LFAAingest_valid,           -- out std_logic; o_virtualChannel and o_packetCount are valid.
        -- Timing information from timing packets, on the 322 MHz clock (i_clk_100GE)
        o_100GE_timing_valid => timingPacketValid, -- out std_logic;
        o_100GE_timing       => timingPacketData,  -- out std_logic_vector(63 downto 0)
        -- wdata portion of the AXI-full external interface (should go directly to the external memory)
        o_axi_w      => o_m01_axi_w,    -- w data bus (.wvalid, .wdata, .wlast)
        i_axi_wready => i_m01_axi_wready, -- 
          -- o_axi_wvalid => m01_axi_wvalid, -- out std_logic;
          -- i_axi_wready => m01_axi_wready, -- in std_logic;
          -- o_axi_wdata  => m01_axi_wdata,  -- out std_logic_vector(511 downto 0);
          -- o_axi_wlast  => m01_axi_wlast,  -- out std_logic;
        -- miscellaneous
        i_my_mac           => mac100G,      -- in std_logic_vector(47 downto 0); -- MAC address for this board; incoming packets from the 40GE interface are filtered using this.
        i_wallTime         => clk322_wallTime,  -- in(63:0); time in nanoseconds.
        --AXI lite Interface
        i_s_axi_mosi       => i_LFAALite_axi_mosi, -- in t_axi4_lite_mosi; at the top level use mc_lite_mosi(c_LFAADecode_lite_index)
        o_s_axi_miso       => o_LFAALite_axi_miso, -- out t_axi4_lite_miso;
        i_s_axi_clk        => i_MACE_clk,         
        i_s_axi_rst        => i_MACE_rst,
        -- registers AXI Full interface
        i_vcstats_MM_IN    => i_LFAAFull_axi_mosi, -- in  t_axi4_full_mosi; At the top level use mc_full_mosi(c_LFAAdecode_full_index),
        o_vcstats_MM_OUT   => o_LFAAFull_axi_miso, -- out t_axi4_full_miso;
        -- Output from the registers that are used elsewhere (on i_s_axi_clk)
        o_totalStations => totalStations, -- out std_logic_vector(11 downto 0);
        o_totalCoarse   => totalCoarse,   -- out std_logic_vector(11 downto 0);
        o_totalChannels => totalChannels, -- out std_logic_vector(11 downto 0);
        -- debug
        o_dbg              => LFAADecode_dbg
    );

    timing : entity timingControl_lib.timing_control_atomic
    port map (
        -- Registers - Uses 300 MHz clock
        mm_rst    => i_MACE_rst,        -- in std_logic;
        i_sla_in  => i_timing_axi_mosi, -- in t_axi4_lite_mosi;
        o_sla_out => o_timing_axi_miso, -- out t_axi4_lite_miso;
        -------------------------------------------------------
        -- clocks :
        -- THe 300MHz clock must be 300MHz, since it is used to track the time in ns. However this module will still work if the other clocks are not the frequency implied by their name.
        i_clk300        => i_MACE_clk,   -- 300 MHz processing clock, used for interfaces in the vitis core. This clock is used for tracking the time (3 clocks = 10 ns)
        i_clk400        => i_clk400,     -- in std_logic;  -- 400 MHz processing clock.
        i_clk450        => i_clk450,     -- in std_logic;  -- 450 MHz processing clock.
        i_LFAA100GE_clk => i_clk_100GE,  -- in std_logic;  -- 322 MHz clock from the 100GE core. 
        -- Wall time outputs in each clock domain
        o_clk300_wallTime => clk300_walltime, -- out(63:0); -- wall time in clk300 domain, in nanoseconds
        o_clk400_wallTime => clk400_walltime, -- out(63:0); -- wall time in clk400 domain, in nanoseconds
        o_clk450_wallTime => clk450_walltime, -- out(63:0); -- wall time in the clk450 domain, in nanoseconds
        o_clk100GE_wallTime => clk322_walltime, -- out(63:0); -- wall time in clk322 domain, in nanoseconds
        --------------------------------------------------------
        -- Timing notifications from LFAA ingest module.
        -- This is the wall time according to timing packets coming in on the 100G network. This is in the i_LFAA100GE_clk domain.
        i_100GE_timing_valid => timingPacketValid, -- in std_logic;
        i_100GE_timing       => timingPacketData   -- in(63:0)  -- current time in nanoseconds according to UDP timing packets from the switch
    );
    
    
    LFAA_FB_CT : entity CT_lib.ct_atomic_cor_in
    generic map (
        g_LFAA_BLOCKS_PER_FRAME => g_LFAA_BLOCKS_PER_FRAME
    ) port map (
        -- shared memory interface clock (300 MHz)
        i_shared_clk => i_MACE_clk, -- in std_logic;
        i_shared_rst => i_MACE_rst, -- in std_logic;
        --AXI Lite Interface for registers
        i_saxi_mosi => i_LFAA_CT_axi_mosi, -- in t_axi4_lite_mosi;
        o_saxi_miso => o_LFAA_CT_axi_miso, -- out t_axi4_lite_miso;
        --wall time:
        i_shared_clk_wall_time => clk300_walltime, -- in(63:0); --wall time in input_clk domain           
        i_FB_clk_wall_time => clk450_walltime, -- in(63:0); --wall time in output_clk domain
        -- other config (from LFAA ingest config, must be the same for the corner turn)
        i_virtualChannels => totalChannels(10 downto 0), -- in std_logic_vector(10 downto 0); -- total virtual channels (= i_stations * i_coarse)
        o_rst => ct_rst, -- reset output from a register in the corner turn; used to reset downstream modules.
        o_validMemRstActive => o_validMemRstActive, -- out std_logic;  -- reset is in progress, don't send data; Only used in the testbench. Reset takes about 20us.
        --
        -- Headers for each valid packet received by the LFAA ingest.
        -- LFAA packets are about 8300 bytes long, so at 100Gbps each LFAA packet is about 660 ns long. This is about 200 of the interface clocks (@300MHz)
        -- These signals use i_shared_clk
        i_virtualChannel => LFAAingest_virtualChannel, -- in std_logic_vector(15 downto 0); -- Single number which incorporates both the channel and station; this module supports values in the range 0 to 1023.
        i_packetCount    => LFAAingest_packetCount,    -- in std_logic_vector(31 downto 0);
        i_valid          => LFAAingest_valid, --  in std_logic;    
        -- Data bus output to the Filterbanks
        -- 6 Outputs, each complex data, 8 bit real, 8 bit imaginary.
        --FB_clk  => i_clk450,     -- in std_logic; Interface runs off shared_clk
        o_sof   => FB_sof,     -- out std_logic; start of data for a set of 4 virtual channels.
        o_sofFull => CT_sof,   -- out std_logic; start of the full frame, i.e. a burst of (typically) 60ms of data.
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
        o_m01_axi_aw      => o_m01_axi_aw,      -- out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m01_axi_awready => i_m01_axi_awready, -- in std_logic;
        -- b bus - write response
        i_m01_axi_b  => i_m01_axi_b,            -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        -- ar bus - read address
        o_m01_axi_ar => o_m01_axi_ar,           -- out t_axi4_full_addr; (.valid, .addr(39:0), .len(7:0))
        i_m01_axi_arready => i_m01_axi_arready, -- in std_logic;
        -- r bus - read data
        i_m01_axi_r      => i_m01_axi_r,        -- in t_axi4_full_data  (.valid, .data(511:0), .last, .resp(1:0))
        o_m01_axi_rready => o_m01_axi_rready    -- out std_logic;
    );
    
    -- Correlator filterbank and fine delay.
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
        i_RFIScale         => "10011", -- in(4:0);
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
        -- Data out; bursts of 216 clocks for each channel.
        -- PST filterbank data output
        o_frameCount     => FD_frameCount,     -- out std_logic_vector(36 downto 0); -- frame count is the same for all simultaneous output streams.
        o_virtualChannel => FD_virtualChannel, -- out t_slv_16_arr(3 downto 0); -- 3 virtual channels, one for each of the PST data streams.
        o_HeaderValid    => FD_headerValid,    -- out std_logic_vector(3 downto 0);
        o_Data           => FD_data,           -- out t_ctc_output_payload_arr(3 downto 0);
        o_DataValid      => FD_dataValid,      -- out std_logic
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
    
    -- Corner turn between filterbanks and correlator
    ct_cor_out_inst : entity CT_lib.ct_atomic_cor_wrapper
    generic map (
        g_USE_META => g_USE_META   -- Put meta data into the memory in place of the actual data, to make it easier to find bugs in the corner turn. 
    ) port map (
        -- Parameters, in the i_axi_clk domain.
        i_stations => totalStations(10 downto 0), -- in std_logic_vector(10 downto 0); -- up to 1024 stations
        i_coarse   => totalCoarse(9 downto 0),   -- in std_logic_vector(9 downto 0);  -- Number of coarse channels.
        i_virtualChannels => totalChannels(10 downto 0), --  in std_logic_vector(10 downto 0); -- total virtual channels (= i_stations * i_coarse)
        -- Registers AXI Lite Interface (uses i_axi_clk)
        i_axi_mosi  => i_cor_CT_axi_mosi, -- in t_axi4_lite_mosi;
        o_axi_miso  => o_cor_CT_axi_miso, -- out t_axi4_lite_miso;
        i_axi_rst   => i_MACE_rst, -- in std_logic;
        -- pipelined reset from first stage corner turn ?
        i_rst  => '0',  --  in std_logic;
        -- Data in from the correlator filterbanks; bursts of 3456 clocks for each channel.
        -- 
        i_sof            => FB_sof,            -- in std_logic; -- pulse high at the start of every frame. (1 frame is typically 283 ms of data).
        i_frameCount     => FD_frameCount,     -- in std_logic_vector(36 downto 0); -- frame count is the same for all simultaneous output streams.
        i_virtualChannel => FD_virtualChannel, -- in t_slv_16_arr(3 downto 0); -- 4 virtual channels, one for each of the PST data streams.
        i_HeaderValid    => FD_headerValid,    -- in std_logic_vector(3 downto 0);
        i_data           => FD_data,           -- in t_ctc_output_payload_arr(3 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), i_data(2)
        i_dataValid      => FD_dataValid,      -- in std_logic;
        -- Data out to the correlator - to be determined.
        
        
        -- AXI interface to the HBM
        -- Corner turn between filterbanks and correlator
        -- aw bus = write address
        i_axi_clk         => i_MACE_clk,        -- in std_logic;
        o_m02_axi_aw      => o_m02_axi_aw,      -- out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m02_axi_awready => i_m02_axi_awready, -- in  std_logic;
        o_m02_axi_w       => o_m02_axi_w,       -- out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_m02_axi_wready  => i_m02_axi_wready,  -- in  std_logic;
        i_m02_axi_b       => i_m02_axi_b,       -- in  t_axi4_full_b;    -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        o_m02_axi_ar      => o_m02_axi_ar,      -- out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m02_axi_arready => i_m02_axi_arready, -- in  std_logic;
        i_m02_axi_r       => i_m02_axi_r,       -- in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_m02_axi_rready  => o_m02_axi_rready   -- out std_logic
    );
    
    -- Correlator
    
    correlator_inst : entity correlator_lib.correlator_top
    generic map (
        g_SOME_GENERIC => 0
    ) port map (
        -- Output from the registers that are defined elsewhere (on i_axi_clk)
        i_totalStations => totalStations, -- in std_logic_vector(11 downto 0);
        i_totalCoarse   => totalCoarse,   -- in std_logic_vector(11 downto 0);
        i_totalChannels => totalChannels, -- in std_logic_vector(11 downto 0);
        -- Registers AXI Lite Interface (uses i_axi_clk)
        i_axi_mosi => i_cor_axi_mosi, -- in t_axi4_lite_mosi;
        o_axi_miso => o_cor_axi_miso, -- out t_axi4_lite_miso;
        i_axi_clk  => i_MACE_clk,     -- in std_logic;
        i_axi_rst  => i_MACE_rst,     -- in std_logic;        
        -- Data input from the corner turn
        i_din       => (others => '0'), --  in std_logic_vector(511 downto 0); -- full width bus from the corner turn HBM readout.
        i_din_valid => '0', --  in std_logic;
        -- clock used for the correlator
        i_din_clk     => i_clk400, --  in std_logic;
        -- Data output to the packetiser
        o_100GE_data  => open, -- out std_logic_vector(127 downto 0);
        o_100GE_valid => open, -- out std_logic;
        
        -- AXI interface to the HBM for storage of visibilities
        -- aw bus = write address
        o_m03_axi_aw      => o_m03_axi_aw,      -- out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m03_axi_awready => i_m03_axi_awready, -- in  std_logic;
        o_m03_axi_w       => o_m03_axi_w,       -- out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_m03_axi_wready  => i_m03_axi_wready,  -- in  std_logic;
        i_m03_axi_b       => i_m03_axi_b,       -- in  t_axi4_full_b;    -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        o_m03_axi_ar      => o_m03_axi_ar,      -- out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m03_axi_arready => i_m03_axi_arready, -- in  std_logic;
        i_m03_axi_r       => i_m03_axi_r,       -- in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_m03_axi_rready  => o_m03_axi_rready   -- out std_logic
    );
       
    -----------------------------------------------------------------------------------------------
    -- 100GE output 
    
    FB_to_100G_ready <= packet_stream_out(0).data_in_rdy;
    
    beamformer_to_packetiser_data.data_clk            <= i_MACE_clk;
    beamformer_to_packetiser_data.data_in_wr          <= FB_to_100G_valid;
    beamformer_to_packetiser_data.data(511 downto 128) <= (others =>'0');
    beamformer_to_packetiser_data.data(127 downto 0)   <= FB_to_100G_data;
    beamformer_to_packetiser_data.bytes_to_transmit   <= (others =>'0');
    
    -- PST signals are passed with data to make headers on the fly. Zero out for other packet types.
    beamformer_to_packetiser_data.PST_virtual_channel <= (others => '0');
    beamformer_to_packetiser_data.PST_beam            <= (others => '0');
    beamformer_to_packetiser_data.PST_time_ref        <= (others => '0');
    
    cmac_reset <= NOT i_eth100G_locked;
    
    packet_generator : entity PSR_Packetiser_lib.psr_packetiser100G_Top 
    Generic Map (
        g_DEBUG_ILA       => g_DEBUG_ILA,
        Number_of_stream  => 1,
        packet_type       => 5   -- 5 = correlator packets
    )
    Port Map ( 
        -- ~322 MHz
        i_cmac_clk => i_clk_100GE,
        i_cmac_rst => cmac_reset,
        
        i_packetiser_clk => i_MACE_clk,
        i_packetiser_rst => '0',
        
        -- Lbus to MAC
        o_data_to_transmit        => o_data_tx_sosi,
        i_data_to_transmit_ctl    => i_data_tx_siso,
        
        -- AXI to CMAC interface to be implemented
        o_tx_axis_tdata           => open,
        o_tx_axis_tkeep           => open,
        o_tx_axis_tvalid          => open,
        o_tx_axis_tlast           => open,
        o_tx_axis_tuser           => open,
        i_tx_axis_tready          => '0',
        
        -- signals from signal processing/HBM/the moon/etc
        packet_stream_ctrl        => packetiser_host_bus_ctrl,
        
        packet_stream_stats       => packet_stream_stats,
                
        packet_stream(0)          => beamformer_to_packetiser_data,
        packet_stream(1)          => null_packetiser_stream_in,
        packet_stream(2)          => null_packetiser_stream_in,
        packet_stream_out         => packet_stream_out,
        
        packet_config_in_stream_1 => packetiser_host_bus_in, -- packetiser_host_bus_out.config_data_out,    -- in packetiser_config_in;
        packet_config_in_stream_2 => null_packetiser_config_in, --  packetiser_config_in_null, --  packetiser_host_bus_out_2.config_data_out,  -- in packetiser_config_in;
        packet_config_in_stream_3 => null_packetiser_config_in , -- packetiser_config_in_null, -- packetiser_host_bus_out_3.config_data_out,  -- in packetiser_config_in;
        
        -- read data from the configuration memory
        packet_config_stream_1   => packetiser_host_bus_out.config_data_out, -- out std_logic_vector(31 downto 0);
        packet_config_stream_2   => open, -- out std_logic_vector(31 downto 0);
        packet_config_stream_3   => open   -- out std_logic_vector(31 downto 0)
        
    );
    
    packetiser_host_bus_out.config_data_valid <= '0'; -- unused.
    
    packetiser_host : entity PSR_Packetiser_lib.cmac_args 
    generic map (
        g_NUMBER_OF_STREAMS => 3   -- really we only need 1, but this generic only works when it is 3.
    ) Port Map ( 
    
        -- ARGS interface
        -- MACE clock is 300 MHz
        i_MACE_clk                          => i_MACE_clk,
        i_MACE_rst                          => i_MACE_rst,
        
        i_packetiser_clk                    => i_MACE_clk,
        
        i_PSR_packetiser_Lite_axi_mosi      => i_PSR_packetiser_Lite_axi_mosi,
        o_PSR_packetiser_Lite_axi_miso      => o_PSR_packetiser_Lite_axi_miso,
        
        i_PSR_packetiser_Full_axi_mosi      => i_PSR_packetiser_Full_axi_mosi,
        o_PSR_packetiser_Full_axi_miso      => o_PSR_packetiser_Full_axi_miso,
        
        o_packet_stream_ctrl                => packetiser_host_bus_ctrl,  --   out packetiser_stream_ctrl;
                
        i_packet_stream_stats               => packet_stream_stats,  --  in t_packetiser_stats((g_NUMBER_OF_STREAMS-1) downto 0);
                
        o_packet_config                     => packetiser_host_bus_in,  --  out packetiser_config_in;  
        i_packet_config_out                 => packetiser_host_bus_out  --  in packetiser_config_out 

    );
    
END structure;
