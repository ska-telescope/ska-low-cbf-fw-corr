----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au) & Norbert Abel
-- 
-- Create Date: 13.03.2020 09:47:34
-- Module Name: ct_atomic_pst_in - Behavioral
-- Description: 
--  First stage corner turn (between LFAA ingest and the filterbanks) 
--  The corner turn takes data for all channels for some number of stations, buffers the data, 
--  and outputs data in bursts for each channel. Burst length is programmable via MACE.
-- 
-- INPUT DATA [x1]:
-- for time = ... (forever)
--    for coarse_group = 1:384/8-1  (order of the coarse groups may vary)
--       for coarse = 1:8
--          for time = 1:2:2048
--             [[ts0, pol0], [ts0, pol1], [ts1, pol0], [ts1, pol1]]
--
-- OUTPUT DATA:
-- Output <BURST LENGTH> and <PRELOAD LENGTH> is configurable via MACE.
-- for coarse = <order defined by a table, programmed via MACE>
--    for time = 1:(<BURST LENGTH> + <PRELOAD LENGTH>)x4096
--       if station_group == 1: [station0, pol0], [station0, pol1]
--
----------------------------------------------------------------------------------
-- Structure
-- ---------
-- This is the top level of the corner turn; it contains :
--  + Timing controls; i.e. when to start reading data out of the buffer.
--  + Registers
--  + Logic to write data to the HBM.
--  + corner turn readout.
--
--  The corner turn supports up to 1024 virtual channels. It is agnostic about what the virtual channels represent, e.g.
--    - 512 stations * 2 coarse channels
--    - 8 stations * 128 coarse channels
--
--  The corner turn uses 3 buffers of 1 Gbyte each.
--  
--  Within a 1 Gbyte buffer: 
--   * 1 GByte/1024 channels = 1 Mbyte per channel
--     - Each LFAA packet is 8192 bytes, so 1 Mbyte = 128 LFAA packets
--     - Each LFAA packet is 2.21184ms, so 128 LFAA packets = 283.115 ms
--   * Address of a packet within the buffer = (virtual_channel) * 1 Mbyte + packet_count
--     - i.e. byte address within a buffer has 
--          - bits 12:0 = byte within an LFAA packet (LFAA packets are 8192 bytes)
--          - bits 19:13 = packet count within the buffer (up to 128 LFAA packets per buffer)
--          - bits 29:20 = virtual channel
--   * The total number of LFAA packets per buffer is configurable via a generic, up to a maximum of 128.
--   
--  A shadow memory keeps track of which LFAA packets have been written to the memory.
--  (1 Gbyte)/(8192 bytes) = 2^30/2^13 = 2^17 = 131072 blocks.
--  1 ultraRAM = 32 kbytes = 262144 bits. So 2 ultraRAMs are used as the shadow memory.
--  
----------------------------------------------------------------------------------
-- Sequencing
--  On reset, the fsm uses the packet count for the first packet received (on "i_packetCount")
--  to determine which packets to expect. Thereafter, it follows the fastest advancing
--  packet count, providing it doesn't skip ahead multiple frames.
--  
--
----------------------------------------------------------------------------------
-- Default Numbers:
--  LFAA time samples = 1080 ns
--  LFAA bandwidth/coarse channel = 1/1080ns = 925.925 KHz
--  LFAA input blocks = 2048 time samples = 2.21184 ms
--  
-- Correlator filterbank output:
--   Output is in 4096 sample blocks. 
--
--   For g_LFAA_BLOCKS_PER_FRAME = 32 LFAA blocks:    <-- This case requires a higher clock rate due to the higher filterbank preload overhead.
--     32 LFAA blocks = 32 * 2.2ms = 70.4 ms
--     32 LFAA blocks = 16 output blocks
--     Preload samples = 4096 * 11 = 11 output blocks
--     4096 sample output blocks per second = (1024 channels) * (16+11) / 70.77888 ms  = 390625 (4096 sample blocks/second)
--     Used clock cycles on the output bus (4 dual-pol channels per cycle) = (390625/4) * 4096 = 400,000,000 (used clock cycles per second)
--
--   For g_LFAA_BLOCKS_PER_FRAME = 128 LFAA blocks:
--     128 LFAA blocks = 128 * 2.2ms = 283.115520 ms
--     128 LFAA blocks = 64 output blocks
--     Preload samples = 4096 * 11 = 11 output blocks
--     4096 sample output blocks per second = (1024 channels) * (64+11) / 283.11552 ms  = 271270 (4096 sample blocks/second)
--     Used clock cycles on the output bus (4 dual-pol channels per cycle) = (271270/4) * 4096 = 277,777,777 (used clock cycles per second)   
--
--
--   So for correlator filterbanks running at 300 MHz
--     - Packets/second = 271270  (note 4096 time samples/packet)
--     - Clocks/second = 300,000,000
--     - Clocks/packet = 4423  (maximum allowed)
--
----------------------------------------------------------------------------------
-- Delays
--   Delays are specified by polynomial coefficients:
--
--  163840 Bytes (=160kBytes) total, first 80 kBytes are the first buffer, second 80 kBytes are the second buffer
--  Within that memory :
--    words 0 to 9 : Config for virtual channel 0, buffer 0 (see below for specification of contents)
--    words 10 to 19 : Config for virtual channel 1, buffer 0
--    ...
--    words 10230 to 10239 : Config for virtual channel 1023, first buffer
--    words 10240 to 20479 : Config for all 1024 virtual channels, second buffer
--  See comments in the "poly_eval.vhd" module for the definition of the 80 bytes for each virtual channel and buffer.
--
--
----------------------------------------------------------------------------------

library IEEE, ct_lib, common_lib, xpm;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
library DSP_top_lib;
use DSP_top_lib.DSP_top_pkg.all;
USE ct_lib.corr_ct1_reg_pkg.ALL;
USE common_lib.common_pkg.ALL;
use xpm.vcomponents.all;

Library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;

entity corr_ct1_top is
    generic (
        g_GENERATE_ILA      : BOOLEAN := FALSE
    );
    port (
        -- shared memory interface clock (300 MHz)
        i_shared_clk     : in std_logic;
        i_shared_rst     : in std_logic;
        -- Registers (uses the shared memory clock)
        i_saxi_mosi       : in  t_axi4_lite_mosi; -- MACE IN
        o_saxi_miso       : out t_axi4_lite_miso; -- MACE OUT
        i_poly_full_axi_mosi : in  t_axi4_full_mosi; -- => mc_full_mosi(c_corr_ct1_full_index),
        o_poly_full_axi_miso : out t_axi4_full_miso; -- => mc_full_miso(c_corr_ct1_full_index),
        -- other config (comes from LFAA ingest module).
        -- This should be valid before coming out of reset.
        i_totalChannelsTable0 : in std_logic_vector(11 downto 0); -- total virtual channels in table 0
        i_totalChannelsTable1 : in std_logic_vector(11 downto 0); -- total virtual channels in table 1
        i_rst               : in std_logic;   -- While in reset, process nothing.
        o_rst               : out std_logic;  -- Reset is now driven from the LFAA ingest module.
        --o_validMemRstActive : out std_logic;  -- reset is in progress, don't send data; Only used in the testbench. Reset takes about 20us.
        -- Headers for each valid packet received by the LFAA ingest.
        -- LFAA packets are about 8300 bytes long, so at 100Gbps each LFAA packet is about 660 ns long. This is about 200 of the interface clocks (@300MHz)
        -- These signals use i_shared_clk
        i_virtualChannel : in std_logic_vector(15 downto 0); -- Single number which incorporates both the channel and station; this module supports values in the range 0 to 1023.
        i_packetCount    : in std_logic_vector(47 downto 0);
        i_valid          : in std_logic;
        -- select the table to use in LFAA Ingest. Changes to the configuration tables to be used (in ingest, ct1, and ct2) are sequenced from within corner turn 1
        o_vct_table_select : out std_logic;
        -- Notify the packetiser that a table swap is in progress
        -- This will go high for a while, but will go low prior to the first notification to the packetiser of 
        -- data to be sent using the new tables. 
        -- o_packetiser_table_select is the new table that will soon be selected. 
        -- The packetiser should hold its switch active bit high from when it sees a rising edge on 
        -- o_table_swap_in_progress through to when it gets notification of a packet to be sent using o_packetiser_table_select 
        o_table_swap_in_progress : out std_logic;
        o_packetiser_table_select : out std_logic;
        o_table_add_remove          : out std_logic;
        -- 
        ------------------------------------------------------------------------------------
        -- Data output, to go to the filterbanks.
        -- Data bus output to the Filterbanks
        -- 8 Outputs, each complex data, 8 bit real, 8 bit imaginary.
        --FB_clk  : in std_logic;  -- interface runs off i_shared_clk
        o_sof   : out std_logic;   -- Start of frame, occurs for every new set of channels.
        o_sofFull : out std_logic; -- Start of a full frame, i.e. 128 LFAA packets worth for all virtual channels.
        o_data0  : out t_slv_16_arr(1 downto 0);
        o_data1  : out t_slv_16_arr(1 downto 0);
        o_meta01 : out t_CT1_META_out; --   - .HDeltaP(15:0), .VDeltaP(15:0), .frameCount(31:0), virtualChannel(15:0), .valid
        o_data2  : out t_slv_16_arr(1 downto 0);
        o_data3  : out t_slv_16_arr(1 downto 0);
        o_meta23 : out t_CT1_META_out;
        o_data4  : out t_slv_16_arr(1 downto 0);
        o_data5  : out t_slv_16_arr(1 downto 0);
        o_meta45 : out t_CT1_META_out;
        o_data6  : out t_slv_16_arr(1 downto 0);
        o_data7  : out t_slv_16_arr(1 downto 0);
        o_meta67 : out t_CT1_META_out;
        o_lastChannel : out std_logic; -- aligns with meta data, indicates this is the last group of channels to be processed in this frame.
        -- o_demap_table_select will change just prior to the start of reading out of a new integration frame.
        -- So it should be registered on the first output of a new integration frame in corner turn 2.
        o_demap_table_select : out std_logic;
        o_valid : out std_logic;
        -------------------------------------------------------------
        i_axi_dbg  : in std_logic_vector(127 downto 0); -- 128 bits
        i_axi_dbg_valid : in std_logic;
        -------------------------------------------------------------
        -- AXI bus to the shared memory. 
        -- This has the aw, b, ar and r buses (the w bus is on the output of the LFAA decode module)
        -- w bus - write data
        o_m01_axi_aw : out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m01_axi_awready : in std_logic;
        -- b bus - write response
        i_m01_axi_b  : in t_axi4_full_b;   -- (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        -- ar bus - read address
        o_m01_axi_ar      : out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m01_axi_arready : in std_logic;
        -- r bus - read data
        i_m01_axi_r       : in  t_axi4_full_data;
        o_m01_axi_rready  : out std_logic;
        i_m01_axi_rst_dbg : in std_logic_vector(31 downto 0); -- in (31:0)
        -------------------------------------------------------------
        -- debug data dump to HBM
        o_m06_axi_aw      : out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m06_axi_awready : in std_logic;
        -- b bus - write response
        o_m06_axi_w       : out t_axi4_full_data; -- (.valid, .data , .last, .resp(1:0))
        i_m06_axi_wready  : in std_logic;
        i_m06_axi_b       : in t_axi4_full_b;  -- (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        -- ar bus - read address
        o_m06_axi_ar      : out t_axi4_full_addr; -- (.valid, .addr(39:0), .len(7:0))
        i_m06_axi_arready : in std_logic;
        -- r bus - read data
        i_m06_axi_r       : in t_axi4_full_data; -- (.valid, .data(511:0), .last, .resp(1:0));
        o_m06_axi_rready  : out std_logic;
        --
        i_m06_axi_rst_dbg : in std_logic_vector(31 downto 0) -- in (31:0)
    );
    
    -- prevent optimisation across module boundaries.
    attribute keep_hierarchy : string;
    attribute keep_hierarchy of corr_ct1_top : entity is "yes";    
    
end corr_ct1_top;

architecture Behavioral of corr_ct1_top is
    
    -- register interface
    signal config_rw : t_config_rw;
    signal config_ro : t_config_ro;
    
    signal validMemWriteAddr : std_logic_vector(18 downto 0);
    signal validMemWrEn : std_logic;
    signal validMemReadAddr : std_logic_vector(18 downto 0);
    signal validMemReadData : std_logic;
    
    signal output_count_in  : t_config_correlator_output_count_ram_in;
    signal output_count_out : t_config_correlator_output_count_ram_out;
    
    type input_fsm_type is (idle, start_divider, wait_divider, check_range_calc,
        check_range, dump_pre_latch_on, packet_early_or_late, check_awfifo_space, 
        generate_aw, check_advance_buffer, start_readout_calc0, start_readout_calc1, 
        start_readout_calc2, start_readout);
    signal input_fsm : input_fsm_type;
    
    signal AWFIFO_dout : std_logic_vector(31 downto 0);
    signal AWFIFO_empty : std_logic;
    signal AWFIFO_full : std_logic;
    signal AWFIFO_RdDataCount : std_logic_vector(9 downto 0);
    signal AWFIFO_WrDataCount : std_logic_vector(9 downto 0);
    signal AWFIFO_din : std_logic_vector(31 downto 0);
    signal AWFIFO_rst : std_logic;
    signal AWFIFO_wrEn : std_logic;
    signal awStop : std_logic := '0';
    signal awCount : std_logic_vector(3 downto 0) := "0000";
    signal sps_addr : std_logic_vector(31 downto 0) := (others => '0');
    
    signal validMemSetWrAddr : std_logic_vector(18 downto 0);
    signal validMemSetWrEn : std_logic;
    signal duplicate : std_logic;
    signal dataMissing : std_logic;
    signal missing_count, duplicate_count, early_or_late_count : std_logic_vector(31 downto 0) := (others => '0');
    signal NChannels : std_logic_vector(11 downto 0) := x"400";
    signal clocksPerPacket : std_logic_vector(15 downto 0);
    signal running : std_logic := '0';
    signal chan0, chan1, chan2, chan3 : std_logic_vector(9 downto 0);
    signal ok0, ok1, ok2, ok3 : std_logic := '0';
    signal validOut : std_logic;
    signal validOutDel : std_logic;
    signal outputCountAddr : std_logic_vector(9 downto 0);
    signal outputCountWrData : std_logic_vector(31 downto 0);
    signal outputCountRdDat : std_logic_vector(31 downto 0);
    signal outputCountWrEn : std_logic;
    type validBlocks_fsm_type is (idle, clear_all_start, clear_all_run, readChan0, readChan0Wait0, readChan0Wait1, 
        readChan0Wait2, writeChan0, readChan1, readChan1Wait0, readChan1Wait1, readChan1Wait2, writeChan1, 
        readChan2, readChan2Wait0, readChan2Wait1, readChan2Wait2, writeChan2,
        readChan3, readChan3Wait0, readChan3Wait1, readChan3Wait2, writeChan3);
    signal validBlocks_fsm : validBlocks_fsm_type := idle;
    signal meta01, meta23, meta45, meta67 : t_CT1_META_out;
    signal data0, data1, data2, data3, data4, data5, data6, data7 : t_slv_16_arr(1 downto 0);
    signal FBClk_rst : std_logic;
    signal validMemRstActive : std_logic;
    signal AWFIFO_rst_del2, AWFIFO_rst_del1 : std_logic;
    
    component ila_beamData
    port (
        clk : in std_logic;
        probe0 : in std_logic_vector(119 downto 0)); 
    end component;
    
    signal valid_del1 : std_logic;
    signal input_packets : std_logic_vector(31 downto 0) := x"00000000";
    
    signal div_remainder : std_logic_vector(1 downto 0);    
    signal div_quotient, ct_integration : std_logic_vector(41 downto 0);
    signal div_valid, do_division : std_logic;
    signal ct_frame_count : std_logic_vector(40 downto 0);
    signal data_rst : std_logic;
    signal status : std_logic_vector(31 downto 0);
    signal pre_latch_on_count : std_logic_vector(31 downto 0);
    signal wr_integration, rd_integration, next_buffer_integration, previous_buffer_integration : std_logic_vector(31 downto 0);
    signal input_fsm_dbg : std_logic_vector(4 downto 0);
    signal current_wr_buffer, current_rd_buffer : std_logic_vector(1 downto 0);
    signal waiting_to_latch_on, first_readout : std_logic;
    signal packet_count_in_buffer : std_logic_vector(6 downto 0);
    signal ct_buffer, next_wr_buffer, previous_wr_buffer : std_logic_vector(1 downto 0);
    signal ct_eq_current, ct_eq_next, ct_eq_previous : std_logic;
    signal framecount_start : std_logic_vector(6 downto 0);
    signal aw_overflow : std_logic;
    signal awfifo_hwm : std_logic_vector(9 downto 0);
    signal trigger_readout : std_logic;
    signal drop_packet : std_logic := '0';
    signal readoverflow, readOverflow_set : std_logic := '0';
    signal buffers_sent_count : std_logic_vector(31 downto 0);
    signal poly_addr : std_logic_vector(14 downto 0); 
    signal poly_rddata : std_logic_vector(63 downto 0);
    
    signal poly_dbg_wrEn, poly_wr_occurred : std_logic;
    signal poly_dbg_wrAddr, poly_wr_addr : std_logic_vector(14 downto 0);
    signal dbg_vec_final : std_logic_vector(255 downto 0);
    signal dbg_vec_valid : std_logic;
    signal dbg_vec : std_logic_vector(255 downto 0);
    signal hbm_ila_addr : std_logic_vector(31 downto 0);
    signal m06_axi_aw : t_axi4_full_addr;
    signal m06_axi_w : t_axi4_full_data;
    signal sof_int,  sofFull_int : std_logic;
    signal m01_axi_rready : std_logic;
    
    component ila_120_16k
    port (
        clk : in std_logic;
        probe0 : in std_logic_vector(119 downto 0)); 
    end component;
    
    signal m01_axi_ar :  t_axi4_full_addr;
    
    signal dbg_input_fsm_dbg : std_logic_vector(4 downto 0);
    signal dbg_running : std_logic;
    signal dbg_wr_buffer : std_logic_vector(1 downto 0);
    signal dbg_first_readout : std_logic;
    signal dbg_waiting_to_latch_on : std_logic;
    signal dbg_readOverflow_set : std_logic;
    signal dbg_readoverflow : std_logic;
    signal dbg_chan0 : std_logic_vector(9 downto 0);
    signal dbg_integration : std_logic_vector(31 downto 0);
    signal dbg_ctFrame : std_logic_vector(1 downto 0);
    signal dbg_o_valid : std_logic;
    signal dbg_sof_int : std_logic;
    signal dbg_sofFull_int : std_logic;
    signal time_since_sofFull : std_logic_vector(31 downto 0);
    signal dbg_hbm_aw_valid : std_logic;
    signal dbg_hbm_aw_ready : std_logic;
    signal dbg_hbm_r_ready : std_logic;
    signal dbg_hbm_ar_addr : std_logic_vector(31 downto 0);
    signal dbg_hbm_ar_valid : std_logic;
    signal dbg_hbm_ar_ready : std_logic;
    signal dbg_hbm_r_valid : std_logic;
    
    signal dbg_rd_tracker_bad : std_logic; --  <= i_hbm_rst_dbg(1)(0);
    signal dbg_wr_tracker_bad : std_logic; -- <= i_hbm_rst_dbg(1)(1);
    signal dbg_wr_tracker : std_logic_vector(11 downto 0);
    signal dbg_hbm_reset_fsm : std_logic_vector(3 downto 0);
    signal dbg_hbm_reset : std_logic;

    signal uptime : std_logic_vector(39 downto 0);
    signal time_since_sof, time_since_data_rst, time_since_ivalid, time_since_hbm_rst : std_logic_vector(31 downto 0);
    signal dbg_vec2 : std_logic_vector(255 downto 0);
    signal dbg_vec2_valid : std_logic;
    signal vct_table_in_use, ct2_tables_in_use : std_logic;
    signal readoutData : t_slv_32_arr(3 downto 0);
    signal validOut_final : std_logic;
    signal m01_axi_rst_dbg : std_logic_vector(31 downto 0);
    signal clks_between_readouts, recent_clks_between_readouts, min_clks_between_readouts : std_logic_vector(31 downto 0) := (others => '1');
    
begin
    
    ------------------------------------------------------------------------------------
    -- CONFIG (TO/FROM MACE)
    ------------------------------------------------------------------------------------

    E_TOP_CONFIG : entity ct_lib.corr_ct1_reg
    port map (
        MM_CLK  => i_shared_clk, -- in std_logic;
        MM_RST  => i_shared_rst, -- in std_logic;
        SLA_IN  => i_saxi_mosi,  -- IN    t_axi4_lite_mosi;
        SLA_OUT => o_saxi_miso,  -- OUT   t_axi4_lite_miso;

        CONFIG_FIELDS_RW   => config_rw, -- OUT t_config_rw;
        CONFIG_FIELDS_RO   => config_ro, -- IN  t_config_ro;
        
        --CONFIG_TABLE_0_IN  => config_table0_in, -- IN  t_config_table_0_ram_in;
		--CONFIG_TABLE_0_OUT => config_table0_out, -- OUT t_config_table_0_ram_out;
		--CONFIG_TABLE_1_IN  => config_table1_in, -- IN  t_config_table_1_ram_in;
		--CONFIG_TABLE_1_OUT => config_table1_out, -- OUT t_config_table_1_ram_out;
        
        CONFIG_CORRELATOR_OUTPUT_COUNT_IN => output_count_in,   -- IN  t_config_psspst_output_count_ram_in;
		CONFIG_CORRELATOR_OUTPUT_COUNT_OUT => output_count_out  -- OUT t_config_psspst_output_count_ram_out
    );
    
    
    -----------------------------------------------------------------------
    -- Full AXI interface - write to the ultraRAM 
    -- Full axi to bram
    poly_axi_bram_inst : entity ct_lib.poly_axi_bram_wrapper
    port map ( 
        i_clk  => i_shared_clk,
        i_rst  => i_shared_rst,
        -------------------------------------------------------
        -------------------------------------------------------
        -- Block ram interface for access by the rest of the module
        -- Memory is 18432 x 8 byte words
        -- read latency 3 clocks
        i_bram_addr    => poly_addr, -- in std_logic_vector(14 downto 0); 
        o_bram_rddata  => poly_rddata, --  out std_logic_vector(63 downto 0);
        -------------------------------------------------------
        -- ARGs axi interface
        i_vd_full_axi_mosi => i_poly_full_axi_mosi, -- in  t_axi4_full_mosi
        o_vd_full_axi_miso => o_poly_full_axi_miso, -- out t_axi4_full_miso
        --
        o_dbg_wrEn   => poly_dbg_wrEn, --  out std_logic;
        o_dbg_wrAddr => poly_dbg_wrAddr --  out std_logic_vector(14 downto 0)
    );
	
    -- Three buffers in the HBM. 
    --           integration_count : 
    -- 
    -- Buffer 0 stores framecounts : 0, 3, 6, 9,  12, 15 ...
    -- Buffer 1 stores framecounts : 1, 4, 7, 10, 13, 16 ...
    -- Buffer 2 stores framecounts : 2, 5, 8, 11, 14, 17 ...
    -- which integration are we up to. i.e. framecount in buffer 0 is 3x this value.
    -- This is for writing to the buffer. Equivalent count for reading would be behind by one.
    config_ro.integration_count <= wr_integration(31 downto 0);
    -- 32 bit status counters
    config_ro.early_or_late_count <= early_or_late_count;
    config_ro.pre_latch_on_count <= pre_latch_on_count;
    config_ro.duplicates_count <= duplicate_count;
    config_ro.missing_count <= "0000" & missing_count(31 downto 4); -- Drop low 4 bits since each missing block is reported 16 times.
    config_ro.input_packets <= input_packets;
    config_ro.status <= status;
    config_ro.buffers_sent_count <= buffers_sent_count;
    -- registers to note if something terrible happened.
    config_ro.error_input_overflow <= aw_overflow; -- std_logic;
    config_ro.error_read_overflow <= readOverflow_set; -- std_logic;
    
    -- This is the virtual channel table that is currently in use
    config_ro.table_in_use(0) <= vct_table_in_use;
    config_ro.table_in_use(1) <= ct2_tables_in_use;

    o_vct_table_select <= vct_table_in_use;
    o_demap_table_select <= ct2_tables_in_use;
    --o_totalChannels <= NChannels;
    
    o_rst   <= config_rw.full_reset;
    
    process(i_shared_clk)
    begin
        if rising_edge(i_shared_clk) then
            if data_rst = '1' then
                early_or_late_count <= (others => '0');
                pre_latch_on_count <= (others => '0');
                duplicate_count <= (others => '0');
                missing_count <= (others => '0');
                input_packets <= (others => '0');
                buffers_sent_count <= (others => '0');
            else
                if valid_del1 = '1' then
                    input_packets <= std_logic_vector(unsigned(input_packets) + 1);
                end if;
                if input_fsm = packet_early_or_late then
                    early_or_late_count <= std_logic_vector(unsigned(early_or_late_count) + 1);
                end if;
                if input_fsm = dump_pre_latch_on then
                    pre_latch_on_count <= std_logic_vector(unsigned(pre_latch_on_count) + 1);
                end if;
                if duplicate = '1' then
                    duplicate_count <= std_logic_vector(unsigned(duplicate_count) + 1);
                end if;
                if dataMissing = '1' then
                    missing_count <= std_logic_vector(unsigned(missing_count) + 1);
                end if;
                if (trigger_readout = '1') then
                    buffers_sent_count <= std_logic_vector(unsigned(buffers_sent_count) + 1);
                end if;
            end if;
            
            status(4 downto 0) <= input_fsm_dbg;
            status(5) <= running;
            status(7 downto 6) <= current_wr_buffer;
            status(8) <= first_readout;
            status(9) <= waiting_to_latch_on;
            status(10) <= aw_overflow;
            status(20 downto 11) <= awfifo_hwm;
            status(21) <= '0';
            status(22) <= readOverflow_set;
            status(31 downto 23) <= "000000000";
            
            if data_rst = '1' then
                aw_overflow <= '0';
                awfifo_hwm <= (others => '0'); -- high water mark for the aw fifo
                readOverflow_set <= '0';
            else
                if (i_valid = '1' and input_fsm /= idle) then
                    aw_overflow <= '1';
                end if;
                if (unsigned(awfifo_wrDataCount) > unsigned(awfifo_hwm)) then
                    awfifo_hwm <= awfifo_wrDataCount;
                end if;
                if readoverflow = '1' then
                    readOverflow_set <= '1';
                end if;
            end if;
            if waiting_to_latch_on = '0' and data_rst = '0' then
                running <= '1';
            else
                running <= '0';
            end if;
            
            framecount_start <= config_rw.framecount_start(6 downto 0);
            
        end if;
    end process;
    
    -----------------------------------------------------------------------------------------------------
    -- Processing of input headers (i_virtualChannel, i_packetCount, i_valid) to generate write addresses
    -----------------------------------------------------------------------------------------------------
    
    -- i_packet_count determines the location to write to in the HBM
    -- This repeats every 384 packets : 0-127 -> HBM buffer 0, 128-255 -> HBM buffer 1, 256-383 -> HBM buffer 2
    -- To find which buffer the packet should go to, divide by 384
    -- Division by 128 is done by shifting, this divides by 3.
    div3i : entity ct_lib.corr_div3
    port map (
        i_clk  => i_shared_clk,
        -- Input
        i_din   => ct_frame_count, -- in (40:0); 
        i_valid => do_division, -- in std_logic;
        -- Output - XX clock latency
        o_quotient  => div_quotient,  -- out (41:0); Integration this packet is part of
        o_remainder => div_remainder, -- out (1:0); Selects which HBM buffer this packet should go to.
        o_valid     => div_valid      -- out std_logic, about 12 clocks after i_valid
    );
    
    do_division <= '1' when input_fsm = start_divider else '0';
    
    process(i_shared_clk)
    begin
        if rising_edge(i_shared_clk) then
            
            valid_del1 <= i_valid;
            
            -- The data path reset puts everything back to the default state,
            -- and causes the state machine to latch on to the incoming data stream
            -- when it is released.
            -- data_rst also clears all the status registers.
            data_rst <= i_rst;
            
            if data_rst = '1' then
                o_table_swap_in_progress <= '0'; 
            elsif vct_table_in_use /= config_rw.table_select(1) or ct2_tables_in_use /= config_rw.table_select(1) then
                o_table_swap_in_progress <= '1';
            else 
                o_table_swap_in_progress <= '0';
            end if;
            o_packetiser_table_select <= config_rw.table_select(1);
            
            o_table_add_remove        <= config_rw.table_select(0); 
            
            --------------------------------------------------------------
            if trigger_readout = '1' then
                clks_between_readouts <= (others => '0');
            elsif clks_between_readouts(31) = '0' then
                clks_between_readouts <= std_logic_vector(unsigned(clks_between_readouts) + 1);
            end if;
            
            if data_rst = '1' then
                recent_clks_between_readouts <= (others => '1');
                min_clks_between_readouts <= (others => '1');
            elsif trigger_readout = '1' then
                recent_clks_between_readouts <= clks_between_readouts;
                if unsigned(clks_between_readouts) < unsigned(min_clks_between_readouts) then
                    min_clks_between_readouts <= clks_between_readouts;
                end if;
            end if;
            
            m01_axi_rst_dbg <= i_m01_axi_rst_dbg;
            
            config_ro.recent_readout_gap <= recent_clks_between_readouts;
            config_ro.minimum_readout_gap <= min_clks_between_readouts;
            config_ro.hbm_status <= m01_axi_rst_dbg;
            
            --------------------------------------------------------------
            
            if data_rst = '1' then
                input_fsm <= idle;
                -- After coming out of reset, always start writing in buffer 2,
                -- so we have preload data for buffer 0.
                --
                --                 first writes 
                --                 after reset
                --                   |
                -- ... buf0   buf1   buf2   buf0  buf1 ...
                --                          |
                --                      Start of frame
                --                      will be read  
                --                      from here.
                --
                current_wr_buffer <= "10";
                current_rd_buffer <= "00";
                -- When "waiting_to_latch_on" packets are discarded until they
                -- fall into the correct window.
                waiting_to_latch_on <= '1';
                -- Hold off reading out anything until we are reading out 
                -- buffer 0 (i.e. the first buffer in the integration frame).
                first_readout <= '1';
                wr_integration <= (others => '0');
                rd_integration <= (others => '0');
                drop_packet <= '0';
                -- 
                input_fsm_dbg <= "00000";
                if config_rw.table_select(1) = '0' then
                    NChannels <= i_totalChannelsTable0;
                else
                    NChannels <= i_totalChannelsTable1;
                end if;
                clocksPerPacket <= config_rw.output_cycles;
                -- Four options for table_select : 
                --  0 = Use Table 0, switchover for removing subarrays
                --  1 = Use Table 0, switchover for adding subarrays
                --  2 = Use Table 1, switchover for removing subarrays
                --  3 = Use Table 1, switchover for adding subarrays
                vct_table_in_use <= config_rw.table_select(1);
                ct2_tables_in_use <= config_rw.table_select(1);
                
            else
                case input_fsm is
                    when idle =>
                        input_fsm_dbg <= "00001";
                        trigger_readout <= '0';
                        if i_valid = '1' then
                            sps_addr(29 downto 20) <= i_virtualChannel(9 downto 0);
                            -- which packet out of 128 SPS packets per corner turn frame.
                            sps_addr(19 downto 13) <= i_packetCount(6 downto 0);
                            -- low 13 bits are zero, sps packets are 8192 byte aligned in HBM. 
                            sps_addr(12 downto 0) <= (others => '0');
                            -- top 2 bits select the HBM buffer (put in later).
                            sps_addr(31 downto 30) <= "00";
                            -- 128 packets per buffer (per virtual channel).
                            -- So low 7 bits is where in the buffer this packet will be.
                            packet_count_in_buffer <= i_packetCount(6 downto 0);
                            
                            -- There are 128 SPS packets per corner turn frame.
                            -- High bits are divided by 3 to select which integration it is part of,
                            -- and which of the 3 buffers the packet will go to.
                            ct_frame_count <= i_packetCount(47 downto 7);
                            -- divider finds ct_frame_count/3.
                            -- floor(ct_frame_count/3) is the integration frame, 
                            -- mod(ct_frame_count,3) is the HBM buffer the packet is written to.
                            input_fsm <= start_divider;
                        end if;
                        awCount <= "0000";
                        AWFIFO_wrEn <= '0';
                    
                    when start_divider =>
                        input_fsm_dbg <= "00010";
                        trigger_readout <= '0';
                        AWFIFO_wrEn <= '0';
                        -- Divide ct_frame_count by 3, to get which of the 3 corner turn buffers
                        -- the packet should go into, and which integration it is part of.
                        input_fsm <= wait_divider;
                        
                    when wait_divider =>
                        input_fsm_dbg <= "00011";
                        trigger_readout <= '0';
                        AWFIFO_wrEn <= '0';
                        if div_valid = '1' then
                            -- which HBM buffer does the packet go to (2 bits)
                            ct_buffer <= div_remainder;
                            -- which integration is this packet a part of (42 bits)
                            ct_integration <= div_quotient;
                            input_fsm <= check_range_calc;
                        end if;
                    
                    when check_range_calc =>
                        input_fsm_dbg <= "00100";
                        trigger_readout <= '0';
                        AWFIFO_wrEn <= '0';
                        input_fsm <= check_range;
                    
                    when check_range =>
                        input_fsm_dbg <= "00101";
                        AWFIFO_wrEn <= '0';
                        trigger_readout <= '0';
                        sps_addr(31 downto 30) <= ct_buffer;
                        
                        if waiting_to_latch_on = '1' or validMemRstActive = '1' then
                            -- if we are waiting to latch onto the data stream,
                            -- then check that the packet is close to the preload packets used in buffer 2
                            -- when reading buffer 0.
                            -- 13 preload packets used, will have to clear a few extra in the readout to cope with
                            -- both +ve and -ve delays.
                            if (validMemRstActive = '0' and ct_buffer = "10" and unsigned(packet_count_in_buffer) > (128-14)) then
                                waiting_to_latch_on <= '0';
                                -- current integration is the index of the integration that
                                -- we are currently writing data into the HBM for.
                                -- The index is relative to the SPS epoch (either monthly
                                -- updates, or J2000, depending on the ICD version)
                                wr_integration <= ct_integration(31 downto 0);
                                input_fsm <= generate_aw;
                                drop_packet <= '0';
                            else
                                -- dump the packet
                                input_fsm <= dump_pre_latch_on;
                                drop_packet <= '1';
                            end if;
                        else
                            -- check the packet count is not too early or too late
                            if ((ct_buffer = current_wr_buffer and ct_eq_current = '1') or
                                (ct_buffer = next_wr_buffer and ct_eq_next = '1' and (unsigned(packet_count_in_buffer) < 64)) or
                                (ct_buffer = previous_wr_buffer and ct_eq_previous = '1' and (unsigned(packet_count_in_buffer) > 112))) then
                                -- just write the packet into the buffer
                                input_fsm <= generate_aw;
                                drop_packet <= '0';
                            else
                                -- packet is too far into the future or the past, drop it.
                                input_fsm <= packet_early_or_late;
                                drop_packet <= '1';
                            end if;
                        end if;
                    
                    when dump_pre_latch_on =>
                        input_fsm_dbg <= "00110";
                        AWFIFO_wrEn <= '0';
                        trigger_readout <= '0';
                        input_fsm <= generate_aw; 
                        -- Still need to generate write addresses even if we are discarding the packet.
                        -- Otherwise it will mess up the axi bus, since wdata bus is in the LFAA ingest module.
                        -- Write to a point just past the end of the write window, where it will get overwritten
                        -- later when the real packet turns up.
                        sps_addr(31 downto 30) <= next_wr_buffer;
                        sps_addr(29 downto 20) <= (others => '0');
                        sps_addr(19 downto 13) <= "1000001"; -- position 65, just beyond the point where packets can be written to. 
                        sps_addr(12 downto 0) <= (others => '0');
                    
                    when packet_early_or_late =>
                        input_fsm_dbg <= "00111";
                        -- signal an error - packet was too early or too late.
                        AWFIFO_wrEn <= '0';
                        trigger_readout <= '0';
                        input_fsm <= generate_aw; 
                        -- Still need to generate write addresses even if we are discarding the packet.
                        -- Otherwise it will mess up the axi bus, since wdata bus is in the LFAA ingest module.
                        -- Write to a point just past the end of the write window, where it will get overwritten
                        -- later when the real packet turns up.
                        sps_addr(31 downto 30) <= next_wr_buffer;
                        sps_addr(29 downto 20) <= (others => '0');
                        sps_addr(19 downto 13) <= "1000001"; -- position 65, just beyond the point where packets can be written to. 
                        sps_Addr(12 downto 0) <= (others => '0');
                    
                    when check_awfifo_space =>
                        -- check there is space in the FIFO for 16 aw transactions.
                        input_fsm_dbg <= "01000";
                        trigger_readout <= '0';
                        if awStop = '0' then
                            input_fsm <= generate_aw;
                        end if;
                    
                    when generate_aw =>
                        input_fsm_dbg <= "01001";
                        trigger_readout <= '0';
                        -- Put the write addresses into the FIFO
                        -- Generates 16 write addresses, each 8 beats.
                        -- 16 writes * 8 beats * 64 bytes/beat = 8192 bytes
                        awFIFO_din(31 downto 13)    <= sps_addr(31 downto 13);
                        awFIFO_din(12)              <= awCount(0);
                        awFIFO_din(11 downto 1)     <= (others => '0');  -- each burst is 64 beats * 64 bytes = 4096 bytes.
                        awFIFO_din(0) <= drop_packet; -- not used for the axi transaction, just used to avoid writing to the valid memory
                        awCount <= std_logic_vector(unsigned(awCount) + 1);
                        AWFIFO_wrEn <= '1';
                        if awCount = "0001" then
                            input_fsm <= check_advance_buffer;
                        end if;
                    
                    when check_advance_buffer =>
                        -- Do we need to move to the next buffer
                        input_fsm_dbg <= "01010";
                        AWFIFO_wrEn <= '0';
                        trigger_readout <= '0';
                        if (ct_buffer = next_wr_buffer and ct_eq_next = '1' and 
                            (unsigned(packet_count_in_buffer) < 64) and 
                            (unsigned(packet_count_in_buffer) > unsigned(framecount_start))) then
                            -- update current buffer to the next buffer, trigger readout 
                            current_wr_buffer <= next_wr_buffer;
                            -- next integration only increments if we were up to buffer 2. 
                            -- Otherwise, this is still the same integration.
                            wr_integration <= next_buffer_integration;
                            if ((first_readout = '0') or
                                (first_readout = '1' and current_wr_buffer = "00")) then
                                -- The first readout after a reset always starts in buffer 0
                                current_rd_buffer <= current_wr_buffer;
                                -- When we switch to a new read buffer, check if we need to switch to a new set of tables.
                                -- Note vct switchover has the constraint :
                                --  - For removal of a subarray(s), ct2 switchover has to occur first
                                --  - For addition of a subarray(s), vct switchover has to occur first
                                if (current_wr_buffer = "01") then
                                    -- If "current_wr_buffer" is "01", but we are switching, then we are actually currently writing to buffer "10".
                                    -- This is where we can switch over the virtual channel table to the new value.
                                    if config_rw.table_select(0) = '0' then
                                        -- table_select(0) = '0' => Switch to remove a subarray, so ct2_tables_in_use has to switch first
                                        if (ct2_tables_in_use = config_rw.table_select(1)) then
                                            -- ct2_tables_in_use already matches, so go ahead and switch vct_table_in_use
                                            vct_table_in_use <= config_rw.table_select(1);
                                        end if;
                                    else
                                        -- Switch to add a subarray, so vct_table_in_use has to switch first
                                        vct_table_in_use <= config_rw.table_select(1);
                                    end if;
                                end if;
                                
                                if current_wr_buffer = "00" then
                                    -- We are about to start reading the first buffer (i.e. buffer "00")
                                    -- This is where we switch over the ct2 tables, so that the new tables are used for 
                                    -- an entire integration interval (849 ms).
                                    if config_rw.table_select(0) = '0' then
                                        -- table_select(0) = '0' => switch to add a subarray, so ct2_tables_in_use has to switch first
                                        ct2_tables_in_use <= config_rw.table_select(1);
                                    else
                                        -- table_select(0) = '1' => switch to remove a subarray, so vct_table_in_use has to switch first
                                        if vct_table_in_use = config_rw.table_select(1) then
                                            ct2_tables_in_use <= config_rw.table_select(1);
                                        end if;
                                    end if;
                                end if;
                                --
                                rd_integration <= wr_integration;
                                first_readout <= '0';
                                input_fsm <= start_readout_calc0;
                            else
                                input_fsm <= idle;
                            end if;
                        else
                            input_fsm <= idle;
                        end if;
                    
                    when start_readout_calc0 =>
                        input_fsm_dbg <= "01011";
                        AWFIFO_wrEn <= '0';
                        trigger_readout <= '0';
                        if current_rd_buffer = "00" then
                            -- clocksPerPacket and NChannels are used in the readout, 
                            -- only update them at the start of an integration.
                            -- Use the number of channels for the table that is being used
                            if (ct2_tables_in_use = '0') then
                                NChannels <= i_totalChannelsTable0;
                            else
                                NChannels <= i_totalChannelsTable1;
                            end if;
                            clocksPerPacket <= config_rw.output_cycles;
                        end if;
                        
                        -- select which delay buffer to use for the readout
                        input_fsm <= start_readout_calc1;
                        
                    when start_readout_calc1 =>
                        input_fsm_dbg <= "01100";
                        AWFIFO_wrEn <= '0';
                        trigger_readout <= '0';
                        input_fsm <= start_readout_calc2;
                        
                    when start_readout_calc2 =>
                        input_fsm_dbg <= "01101";
                        AWFIFO_wrEn <= '0';
                        trigger_readout <= '0';
                        input_fsm <= start_readout;
                        
                    when start_readout =>
                        input_fsm_dbg <= "01110";
                        AWFIFO_wrEn <= '0';
                        trigger_readout <= '1';
                        input_fsm <= idle;
                        
                    when others =>
                        input_fsm_dbg <= "11111";
                        trigger_readout <= '0';
                        AWFIFO_wrEn <= '0';
                        input_fsm <= idle;
                end case;
            end if;
            
            case current_wr_buffer is
                when "00" =>
                    next_wr_buffer <= "01";
                    previous_wr_buffer <= "10";
                    next_buffer_integration <= wr_integration;
                    previous_buffer_integration <= std_logic_vector(unsigned(wr_integration) - 1);
                when "01" =>
                    next_wr_buffer <= "10";
                    previous_wr_buffer <= "00";
                    next_buffer_integration <= wr_integration;
                    previous_buffer_integration <= wr_integration;
                when others => -- "10"
                    next_wr_buffer <= "00";
                    previous_wr_buffer <= "01";
                    next_buffer_integration <= std_logic_vector(unsigned(wr_integration) + 1);
                    previous_buffer_integration <= wr_integration;
            end case;
            
            -- pipeline calculations to improve timing
            -- input_fsm state "check_range_calc" exists to allow a cycle for these calculations to finish.
            if ct_integration(31 downto 0) = next_buffer_integration(31 downto 0) then
                ct_eq_next <= '1';
            else
                ct_eq_next <= '0';
            end if;
            if ct_integration(31 downto 0) = wr_integration(31 downto 0) then
                ct_eq_current <= '1';
            else
                ct_eq_current <= '0';
            end if;
            if ct_integration(31 downto 0) = previous_buffer_integration(31 downto 0) then
                ct_eq_previous <= '1';
            else
                ct_eq_previous <= '0';
            end if;

            if (unsigned(AWFIFO_WrDataCount) > 255) then
                awStop <= '1';
            else
                awStop <= '0';
            end if;
            
            ---------------------------------------------------
            AWFIFO_rst <= data_rst;
            
        end if;
    end process;
    
    -- FIFO for write addresses 
    -- Input to the fifo comes from "input_fsm". It is read as fast as addresses are accepted by the shared memory bus.
    fifo_aw_inst : xpm_fifo_sync
    generic map (
        DOUT_RESET_VALUE => "0",    -- String
        ECC_MODE => "no_ecc",       -- String
        FIFO_MEMORY_TYPE => "auto", -- String
        FIFO_READ_LATENCY => 1,     -- DECIMAL
        FIFO_WRITE_DEPTH => 512,     -- DECIMAL; Allow up to 32 outstanding write requests.
        FULL_RESET_VALUE => 0,      -- DECIMAL
        PROG_EMPTY_THRESH => 10,    -- DECIMAL
        PROG_FULL_THRESH => 10,     -- DECIMAL
        RD_DATA_COUNT_WIDTH => 10,  -- DECIMAL
        READ_DATA_WIDTH => 32,      -- DECIMAL
        READ_MODE => "fwft",        -- String
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "0404", -- String  -- bit 2 and bit 10 enables write data count and read data count
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 32,     -- DECIMAL
        WR_DATA_COUNT_WIDTH => 10   -- DECIMAL
    )
    port map (
        almost_empty => open,     -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
        almost_full => open,      -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
        data_valid => open,       -- Need to set bit 12 of "USE_ADV_FEATURES" to enable this output. 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
        dbiterr => open,          -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
        dout => AWFIFO_dout,      -- READ_DATA_WIDTH-bit output: Read Data: The output data bus is driven when reading the FIFO.
        empty => AWFIFO_empty,    -- 1-bit output: Empty Flag: When asserted, this signal indicates that- the FIFO is empty.
        full => AWFIFO_full,      -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full.
        overflow => open,         -- 1-bit output: Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected, because the FIFO is full
        prog_empty => open,       -- 1-bit output: Programmable Empty: This signal is asserted when the number of words in the FIFO is less than or equal to the programmable empty threshold value.
        prog_full => open,        -- 1-bit output: Programmable Full: This signal is asserted when the number of words in the FIFO is greater than or equal to the programmable full threshold value.
        rd_data_count => AWFIFO_RdDataCount, -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
        rd_rst_busy => open,      -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
        sbiterr => open,          -- 1-bit output: Single Bit Error: Indicates that the ECC decoder detected and fixed a single-bit error.
        underflow => open,        -- 1-bit output: Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected because the FIFO is empty.
        wr_ack => open,           -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.
        wr_data_count => AWFIFO_WrDataCount, -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        wr_rst_busy => open,      -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
        din => AWFIFO_din,        -- WRITE_DATA_WIDTH-bit input: Write Data: The input data bus used when writing the FIFO.
        injectdbiterr => '0',     -- 1-bit input: Double Bit Error Injection
        injectsbiterr => '0',     -- 1-bit input: Single Bit Error Injection: 
        rd_en => i_m01_axi_awready, -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO. 
        rst => AWFIFO_rst,        -- 1-bit input: Reset: Must be synchronous to wr_clk.
        sleep => '0',             -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
        wr_clk => i_shared_clk,   -- 1-bit input: Write clock: Used for write operation. wr_clk must be a free running clock.
        wr_en => AWFIFO_wrEn      -- 1-bit input: Write Enable: 
    );
    
    o_m01_axi_aw.valid <= not AWFIFO_empty; --  out std_logic;
    o_m01_axi_aw.addr  <= x"00" & AWFIFO_dout(31 downto 1) & '0';
    -- Number of beats in a burst -1; 
    -- 8 beats * 64 byte wide bus = 512 bytes per burst, so 16 bursts for a full LFAA packet of 8192 bytes.
    -- Warning : The "wlast" signal generated in the LFAA ingest module (in "LFAAProcess100G.vhd") assumes that this value is 7 (=8 beats per burst).
    o_m01_axi_aw.len   <= x"3F"; -- Update to 4096 bytes per transfer from 512. "00000111"; -- out std_logic_vector(7 downto 0); 
    
    -----------------------------------------------------------------------------------------------
    -- Valid memory keeps track of whether data has been written to each 8192 byte block in the shared memory.
    -- One valid bit for every 8192 bytes.
    -- 1Gbyte/8192 bytes = 2^30/2^13 = 2^17 bits
    -- 
    
    -- When the last write address goes for an LFAA packet, then we assume we are done writing and can set the bit in the valid memory.
    process(i_shared_clk)
    begin
        if rising_edge(i_shared_clk) then
            if (AWFIFO_empty = '0') and (i_m01_axi_awready = '1') and (AWFIFO_dout(12) = '1') and (AWFIFO_dout(0) = '0') then
                -- bit 0 of AWFIFO_dout indicates that the packet is being dropped.
                validMemSetWrEn <= '1';
                validMemSetWrAddr <= AWFIFO_dout(31 downto 13);
            else
                validMemSetWrEn <= '0';
            end if;
        end if;
    end process;
    
    validmemInst : entity ct_lib.corr_ct1_valid
    port map (
        i_clk => i_shared_clk,
        i_rst => AWFIFO_rst,
        o_rstActive => validMemRstActive,
        -- Set valid
        i_setAddr   => validMemSetWrAddr,  -- in(18:0)
        i_setValid  => validMemSetWrEn,    -- in std_logic;
        o_duplicate => duplicate,          -- out std_logic;
        -- clear valid
        i_clearAddr => validMemWriteAddr,  -- in(18:0)
        i_clearValid => validMemWrEn,      -- in std_logic;
        -- Read contents
        i_readAddr => validMemReadAddr,    -- in(18:0)
        o_readData => validMemReadData     -- out std_logic;
    );
    
    -----------------------------------------------------------------------------------------------
    -- readout of a frame
    
    readout : entity ct_lib.corr_ct1_readout
    generic map (
        g_SPS_PACKETS_PER_FRAME => 128,
        -- 24 preload + 24 postload for the 49 tap ripple filter
        g_RIPPLE_PRELOAD  => 24, -- integer := 15;
        g_RIPPLE_POSTLOAD => 24  -- integer := 15
    )
    port map (
        shared_clk => i_shared_clk, -- in std_logic; Shared memory clock
        i_rst      => AWFIFO_rst,
        -- input signals to trigger reading of a buffer
        i_currentBuffer => current_rd_buffer, -- in(1:0);
        i_readStart => trigger_readout,       -- in std_logic; Pulse to start readout from i_currentBuffer
        i_integration => rd_integration,      -- in(31:0)
        i_Nchannels => NChannels,             -- in(11:0); -- Total number of virtual channels to read out,
        i_clocksPerPacket => clocksPerPacket, -- in(15:0)
        -- Reading Coarse and fine delay info from the registers
        -- In the registers, word 0, bits 15:0  = Coarse delay, word 0 bits 31:16 = Hpol DeltaP, word 1 bits 15:0 = Vpol deltaP, word 1 bits 31:16 = deltaDeltaP
        o_delayTableAddr => poly_addr,   -- out (14:0); -- 2 addresses per virtual channel, up to 1024 virtual channels
        i_delayTableData => poly_rdData, -- in (63:0); -- Data from the delay table with 3 cycle latency. 
        
        -- Read and write to the valid memory, to check the place we are reading from in the HBM has valid data
        o_validMemReadAddr => validMemReadAddr, -- out (18 downto 0); -- 8192 bytes per LFAA packet, 1 GByte of memory, so 1Gbyte/8192 bytes = 2^30/2^13 = 2^17
        i_validMemReadData => validMemReadData, -- in std_logic;  -- read data returned 3 clocks later.
        o_validMemWriteAddr => validMemWriteAddr, -- out (18:0); -- write always clear the memory (mark the block as invalid).
        o_validMemWrEn      => validMemWrEn,      -- out std_logic;
        
        -- Data output to the filterbanks
        -- FB_clk  => FB_clk,  -- in std_logic; Interface runs off shared_clk
        o_sof   => sof_int,   -- out std_logic; start of frame.
        o_sofFull => sofFull_int, -- out std_logic; -- start of a full frame, i.e. 283 ms of data.
        o_readoutData => readoutData, -- t_slv_32_arr(3 downto 0);
        o_meta0 => meta01, -- out t_CT1_META_out;
        o_meta1 => meta23, -- out t_CT1_META_out;
        o_meta2 => meta45, -- out t_CT1_META_out;
        o_meta3 => meta67, --
        o_lastChannel => o_lastChannel, -- out std_logic; Aligns with o_metaX
        o_valid => validOut, -- out std_logic;
        
        -- AXI read address and data input buses
        -- ar bus - read address
        o_axi_ar      => m01_axi_ar,      -- out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_axi_arready => i_m01_axi_arready, -- in std_logic;
        -- r bus - read data
        i_axi_r       => i_m01_axi_r,      -- in  t_axi4_full_data;
        o_axi_rready  => m01_axi_rready, -- out std_logic;
        -- errors and debug
        -- Flag an error; we were asked to start reading but we haven't finished reading the previous frame.
        o_readOverflow => readOverflow,       -- out std_logic -- pulses high in the shared_clk domain.
        o_Unexpected_rdata => open,   -- out std_logic -- data was returned from the HBM that we didn't expect (i.e. no read request was put in for it)
        o_dataMissing => dataMissing, -- out std_logic -- Read from a HBM address that we haven't written data to. Most reads are 8 beats = 8*64 = 512 bytes, so this will go high 16 times per missing LFAA packet.
        o_dbg_vec   => dbg_vec,       -- out std_logic_vector(255 downto 0);
        o_dbg_valid => dbg_vec_valid,  -- out std_logic
        o_dFIFO_underflow => config_ro.dFIFO_underflow, --  out std_logic_vector(3 downto 0); -- Read of output fifos but they were empty
        -- mismatch between output and expected when sending debug data inserted in lfaaIngest
        o_dbgCheckData0 => config_ro.dbgCheckData0, -- out std_logic_vector(31 downto 0);
        o_dbgCheckData1 => config_ro.dbgCheckData1, -- out std_logic_vector(31 downto 0);
        o_dbgCheckData2 => config_ro.dbgCheckData2, -- out std_logic_vector(31 downto 0);
        o_dbgCheckData3 => config_ro.dbgCheckData3, -- out std_logic_vector(31 downto 0);
        o_dbgBadData0 => config_ro.dbgBadData0, --  out std_logic_vector(31 downto 0);
        o_dbgBadData1 => config_ro.dbgBadData1, -- out std_logic_vector(31 downto 0);
        o_dbgBadData2 => config_ro.dbgBadData2, -- out std_logic_vector(31 downto 0);
        o_dbgBadData3 => config_ro.dbgBadData3, -- out std_logic_vector(31 downto 0);
        o_mismatch_set => config_ro.mismatch_set, -- out std_logic_vector(3 downto 0);
        i_reset_mismatch => config_rw.reset_mismatch -- in std_logic        
    );
    
    
    ----------------------------------------------------------------------------
    
    flati : entity ct_lib.flattening_wrapper
    port map (
        clk => i_shared_clk,
        -----------------------------------------------------------
        -- Data in
        i_sof     => sof_int,     -- in std_logic;
        i_sofFull => sofFull_int, -- in std_logic;
        i_data    => readoutData, -- in t_slv_32_arr(3 downto 0);
        i_valid   => validOut,    -- in std_logic;
        i_flatten_select => config_rw.ripple_select, -- in (1:0); -- 0 = identity, "01" = TPM 16d, "10" = TPM 18a
        -----------------------------------------------------------
        -- Data out
        o_HPol0   => data0, -- out t_slv_16_arr(1 downto 0);
        o_VPol0   => data1, -- out t_slv_16_arr(1 downto 0);
        o_HPol1   => data2, -- out t_slv_16_arr(1 downto 0);
        o_VPol1   => data3, -- out t_slv_16_arr(1 downto 0);
        o_HPol2   => data4, -- out t_slv_16_arr(1 downto 0);
        o_VPol2   => data5, -- out t_slv_16_arr(1 downto 0);
        o_HPol3   => data6, -- out t_slv_16_arr(1 downto 0);
        o_Vpol3   => data7, -- out t_slv_16_arr(1 downto 0);
        o_valid   => validOut_final, --  out std_logic
        -- sof and sofFull need to be delayed by the latency of the flattening filter (27 clocks), so they don't overlap with 
        -- the end of the data from the previous frame
        -- The 27 clock latency is dependent on the xilinx FIR IP block, and is just the latency from valid in going high to
        -- valid out going high from that block. Latency for the first frame is higher because it includes loading the preload data.
        o_sof     => o_sof,
        o_sofFUll => o_sofFull
    );
    
    o_data0 <= data0;
    o_data1 <= data1;
    o_data2 <= data2;
    o_data3 <= data3;
    o_data4 <= data4;
    o_data5 <= data5;
    o_data6 <= data6;
    o_data7 <= data7;
    o_valid <= validOut_final;
    
    -- No need to delay the meta data to align with o_data0, o_valid
    -- The delay through the flattening filter means that o_metaXX will change before o_valid by up to about 30 clocks.
    -- But o_metaXX is only sampled by the filterbank at the start of a packet (i.e. once every 4096 clocks)
    -- So it is ok for it to change ~30 clocks earlier.
    o_meta01 <= meta01;
    o_meta23 <= meta23;
    o_meta45 <= meta45;
    o_meta67 <= meta67;
    
    
    o_m01_axi_rready <= m01_axi_rready;
    o_m01_axi_ar <= m01_axi_ar;
    
    -- Everything on the same clock domain;
    process(i_shared_clk)
    begin
        if rising_edge(i_shared_clk) then
            AWFIFO_rst_del1 <= AWFIFO_rst;
            AWFIFO_rst_del2 <= AWFIFO_rst_del1;
            FBClk_rst <= AWFIFO_rst_del1 and (not AWFIFO_rst_del2);
        end if;
    end process;
    
    -- Count valid blocks output to the filterbanks for each channel
    process(i_shared_clk)
    begin
        if rising_edge(i_shared_clk) then
            validOutdel <= validOut;
            
            outputCountRdDat <= output_count_out.rd_dat;
            
            -- fsm to go through and do read-modify-write for each of the output channels to count valid packets.
            if FBClk_rst = '1' then
                validBlocks_fsm <= clear_all_start;
            else
                case validBlocks_fsm is
                    when idle =>
                        if validOut = '1' and validOutdel = '0' then
                            chan0 <= meta01.virtualChannel(9 downto 0);
                            chan1 <= meta23.virtualChannel(9 downto 0);
                            chan2 <= meta45.virtualChannel(9 downto 0);
                            chan3 <= meta67.virtualChannel(9 downto 0);
                            if readoutData(0)(7 downto 0) = "10000000" then
                                -- first sample in the packet is flagged,
                                -- either data was missing or it is RFI
                                ok0 <= '0';
                            else
                                ok0 <= '1';
                            end if;
                            if readoutData(1)(7 downto 0) = "10000000" then
                                ok1 <= '0';
                            else
                                ok1 <= '1';
                            end if;
                            if readoutData(2)(7 downto 0) = "10000000" then
                                ok2 <= '0';
                            else
                                ok2 <= '1';
                            end if;
                            if readoutData(3)(7 downto 0) = "10000000" then
                                ok3 <= '0';
                            else
                                ok3 <= '1';
                            end if;
                            validBlocks_fsm <= readChan0;
                        end if;
                        outputCountWrEn <= '0';
                        
                    when clear_all_start =>
                        outputCountAddr <= (others => '0');
                        outputCountWrData <= (others => '0');
                        outputCountWrEn <= '1';
                        validBlocks_fsm <= clear_all_run;
                        
                    when clear_all_run => 
                        outputCountAddr <= std_logic_vector(unsigned(outputCountAddr) + 1);
                        if outputCountAddr = "1111111111" then
                            validBlocks_fsm <= idle;
                            outputCountWrEn <= '0';
                        end if;
                        
                    when readChan0 =>
                        validBlocks_fsm <= readChan0Wait0;
                        outputCountAddr <= chan0;
                        outputCountWrEn <= '0';
                    
                    when readChan0Wait0 =>  -- address to the memory is correct for chan0 in this state
                        validBlocks_fsm <= readChan0Wait1;
                        outputCountWrEn <= '0';
                    
                    when readChan0Wait1 =>
                        validBlocks_fsm <= readChan0Wait2;
                        outputCountWrEn <= '0';
                    
                    when readChan0Wait2 =>
                        validBlocks_fsm <= writeChan0;
                        outputCountWrEn <= '0';
                    
                    when writeChan0 =>   -- read data for chan0 is valid in this state.
                        validBlocks_fsm <= readChan1;
                        outputCountWrData <= std_logic_vector(unsigned(outputCountRdDat) + 1);
                        outputCountWrEn <= ok0;
                        
                    when readChan1 =>
                        validBlocks_fsm <= readChan1Wait0;
                        outputCountWrEn <= '0';
                        outputCountAddr <= chan1;
                    
                    when readChan1Wait0 =>
                        validBlocks_fsm <= readChan1Wait1;
                        outputCountWrEn <= '0';
                    
                    when readChan1Wait1 =>
                        validBlocks_fsm <= readChan1Wait2;
                        outputCountWrEn <= '0';
                    
                    when readChan1Wait2 =>
                        validBlocks_fsm <= writeChan1;
                        outputCountWrEn <= '0';
                        
                    when writeChan1 =>
                        validBlocks_fsm <= readChan2;
                        outputCountWrData <= std_logic_vector(unsigned(outputCountRdDat) + 1);
                        outputCountWrEn <= ok1;
                    
                    when readChan2 =>
                        validBlocks_fsm <= readChan2Wait0;
                        outputCountWrEn <= '0';
                        outputCountAddr <= chan2;
                    
                    when readChan2Wait0 =>
                        validBlocks_fsm <= readChan2Wait1;
                        outputCountWrEn <= '0';
                    
                    when readChan2Wait1 =>
                        validBlocks_fsm <= readChan2Wait2;
                        outputCountWrEn <= '0';
                    
                    when readChan2Wait2 =>
                        validBlocks_fsm <= writeChan2;
                        outputCountWrEn <= '0';
                    
                    when writeChan2 =>
                        validBlocks_fsm <= readChan3;
                        outputCountWrData <= std_logic_vector(unsigned(outputCountRdDat) + 1);
                        outputCountWrEn <= ok2;
                    
                    when readChan3 =>
                        validBlocks_fsm <= readChan3Wait0;
                        outputCountWrEn <= '0';
                        outputCountAddr <= chan3;
                    
                    when readChan3Wait0 =>
                        validBlocks_fsm <= readChan3Wait1;
                        outputCountWrEn <= '0';
                    
                    when readChan3Wait1 =>
                        validBlocks_fsm <= readChan3Wait2;
                        outputCountWrEn <= '0';
                    
                    when readChan3Wait2 =>
                        validBlocks_fsm <= writeChan3;
                        outputCountWrEn <= '0';
                    
                    when writeChan3 =>
                        validBlocks_fsm <= idle;
                        outputCountWrData <= std_logic_vector(unsigned(outputCountRdDat) + 1);
                        outputCountWrEn <= ok3;
                        
                    when others =>
                        validBlocks_fsm <= idle;
                end case;
            end if;
        end if;
    end process;
    
    output_count_in.adr <= outputCountAddr;
    output_count_in.wr_dat <= outputCountWrData;
    output_count_in.wr_en <= outputCountWrEn;
    output_count_in.rd_en <= '1';
    output_count_in.clk <= i_shared_clk;
    output_count_in.rst <= '0';

    -------------------------------------------------------------------------
    -- debug data dump to the HBM
    process(i_shared_clk)
    begin
        if rising_edge(i_shared_clk) then
            if poly_dbg_wrEn = '1' then
                poly_wr_occurred <= '1';
                poly_wr_addr <= poly_dbg_wraddr;
            elsif dbg_vec_valid = '1' then
                poly_wr_occurred <= '0';
            end if;
            
        end if;
    end process;
    
    dbg_vec_final(175 downto 0)   <= dbg_vec(175 downto 0);
    dbg_vec_final(191 downto 176) <= poly_wr_occurred & poly_wr_addr;
    dbg_vec_final(255 downto 192) <= dbg_vec(255 downto 192);
    
    
    -- Alternate set of signals for the HBM ILA
    process(i_shared_clk)
    begin
        if rising_edge(i_shared_clk) then
            uptime <= std_logic_vector(unsigned(uptime) + 1);
            
            if sof_int = '1' then
                time_since_sof <= (others => '0');
            else
                time_since_sof <= std_logic_vector(unsigned(time_since_sof) + 1);
            end if;
            
            if soffull_int = '1' then
                time_since_sofFull <= (others => '0');
            else
                time_since_sofFull <= std_logic_vector(unsigned(time_since_sofFull) + 1);
            end if;
            
            if data_Rst = '1' then
                time_since_data_rst <= (others => '0');
            elsif time_since_data_rst /= x"ffffffff" then
                time_since_data_rst <= std_logic_vector(unsigned(time_since_data_rst) + 1);
            end if;
            
            if dbg_hbm_reset = '1' then
                time_since_hbm_rst <= (others => '0');
            elsif time_since_hbm_rst /= x"ffffffff" then
                time_since_hbm_rst <= std_logic_vector(unsigned(time_since_hbm_rst) + 1);
            end if;
            
            if i_valid = '1' then
                time_since_ivalid <= (others => '0');
            elsif time_since_ivalid /= x"ffffffff" then
                time_since_ivalid <= std_logic_vector(unsigned(time_since_ivalid) + 1);
            end if;
            
--            if validOut = '1' and validOutdel = '0' then
--                dbg_vec2(15 downto 0) <= meta01.virtualChannel(15 downto 0);
--                dbg_vec2(31 downto 16) <= meta01.integration(15 downto 0);
--                dbg_vec2(33 downto 32) <= meta01.ctframe;
--                dbg_vec2(34) <= dbg_rd_tracker_bad;
--                dbg_vec2(35) <= dbg_wr_tracker_bad;
--                dbg_vec2(36) <= waiting_to_latch_on;
--                dbg_vec2(37) <= running;
--                dbg_vec2(38) <= readOverflow_set;
--                dbg_vec2(39) <= readoverflow;
--                dbg_vec2(51 downto 40) <= dbg_wr_tracker;
--                dbg_vec2(55 downto 52) <= "0000";
--                dbg_vec2(103 downto 64) <= uptime;
--                dbg_vec2(127 downto 104) <= time_since_sof(23 downto 0);
--                dbg_vec2(159 downto 128) <= time_since_sofFull(31 downto 0);
--                dbg_vec2(191 downto 160) <= time_since_data_rst(31 downto 0);
--                dbg_vec2(223 downto 192) <= time_since_hbm_rst(31 downto 0);
--                dbg_vec2(227 downto 224) <= dbg_hbm_reset_fsm;
--                dbg_vec2(228) <= '1';
--                dbg_vec2(231 downto 229) <= "000";
--                dbg_vec2(255 downto 232) <= time_since_ivalid(31 downto 8);
--                dbg_vec2_valid <= '1';
--            elsif validOut = '0' and validOutDel = '1' then
--                -- Falling edge of validOut
--                dbg_vec2(34) <= dbg_rd_tracker_bad;
--                dbg_vec2(35) <= dbg_wr_tracker_bad;
--                dbg_vec2(36) <= waiting_to_latch_on;
--                dbg_vec2(37) <= running;
--                dbg_vec2(38) <= readOverflow_set;
--                dbg_vec2(39) <= readoverflow;
--                dbg_vec2(51 downto 40) <= dbg_wr_tracker;
--                dbg_vec2(55 downto 52) <= "0000";
--                dbg_vec2(103 downto 64) <= uptime;
--                dbg_vec2(127 downto 104) <= time_since_sof(23 downto 0);
--                dbg_vec2(159 downto 128) <= time_since_sofFull(31 downto 0);
--                dbg_vec2(191 downto 160) <= time_since_data_rst(31 downto 0);
--                dbg_vec2(223 downto 192) <= time_since_hbm_rst(31 downto 0);
--                dbg_vec2(227 downto 224) <= dbg_hbm_reset_fsm;
--                dbg_vec2(228) <= '0';
--                dbg_vec2(231 downto 229) <= "000";
--                dbg_vec2(255 downto 232) <= time_since_ivalid(31 downto 8);
--                dbg_vec2_valid <= '1';
--            else
--                dbg_vec2_valid <= '0';
--            end if;
            
            if ((validOut = '1' and validOutdel = '0') or i_axi_dbg_valid = '1') then
                dbg_vec2(15 downto 0) <= meta01.virtualChannel(15 downto 0);
                dbg_vec2(31 downto 16) <= meta01.integration(15 downto 0);
                dbg_vec2(33 downto 32) <= meta01.ctframe;
                dbg_vec2(34) <= dbg_rd_tracker_bad;
                dbg_vec2(35) <= dbg_wr_tracker_bad;
                dbg_vec2(36) <= waiting_to_latch_on;
                dbg_vec2(37) <= running;
                dbg_vec2(38) <= readOverflow_set;
                dbg_vec2(39) <= readoverflow;
                dbg_vec2(51 downto 40) <= dbg_wr_tracker;
                dbg_vec2(52) <= validOut;
                dbg_vec2(53) <= validOutDel;
                dbg_vec2(54) <= i_axi_dbg_valid;
                dbg_vec2(55) <= '0';
                dbg_vec2(103 downto 64) <= uptime;
                dbg_vec2(127 downto 104) <= time_since_sof(23 downto 0);
                dbg_vec2(255 downto 128) <= i_axi_dbg;
                dbg_vec2_valid <= '1';
            elsif ((validOut = '0' and validOutDel = '1') or i_axi_dbg_valid = '1') then
                -- Falling edge of validOut
                dbg_vec2(31 downto 0) <= time_since_data_rst(31 downto 0);
                dbg_vec2(34) <= dbg_rd_tracker_bad;
                dbg_vec2(35) <= dbg_wr_tracker_bad;
                dbg_vec2(36) <= waiting_to_latch_on;
                dbg_vec2(37) <= running;
                dbg_vec2(38) <= readOverflow_set;
                dbg_vec2(39) <= readoverflow;
                dbg_vec2(51 downto 40) <= dbg_wr_tracker;
                dbg_vec2(52) <= validOut;
                dbg_vec2(53) <= validOutDel;
                dbg_vec2(54) <= i_axi_dbg_valid;
                dbg_vec2(55) <= '0';
                dbg_vec2(103 downto 64) <= uptime;
                dbg_vec2(127 downto 104) <= time_since_sofFull(23 downto 0);
                dbg_vec2(255 downto 128) <= i_axi_dbg;
                dbg_vec2_valid <= '1';
            else
                dbg_vec2_valid <= '0';
            end if;            
            
            
        end if;
    end process;
    
    
    hbm_ilai : entity ct_lib.hbm_ila
    port map (
        dsp_clk    => i_shared_clk, -- : in std_logic;
        -- 16 bytes of debug data, and valid.
        i_ila_data       => dbg_vec2, -- dbg_vec_final, -- in std_logic_vector(255 downto 0);
        i_ila_data_valid => dbg_vec2_valid, -- dbg_vec_valid, -- in std_logic;
        o_hbm_addr       => hbm_ila_addr, -- out std_logic_vector(31 downto 0); -- Address we are up to in the HBM.
        -- Write out to the HBM
        -- write address buses : out t_axi4_full_addr(.valid, .addr(39:0), .len(7:0))
        axi_clk  => i_shared_clk, -- in std_logic;
        axi_rst  => i_shared_rst, -- in std_logic;
        o_HBM_axi_aw      => m06_axi_aw,      -- out t_axi4_full_addr;
        i_HBM_axi_awready => i_m06_axi_awready, -- in std_logic;
        -- w data buses : out t_axi4_full_data(.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_w       => m06_axi_w, -- out t_axi4_full_data;
        i_HBM_axi_wready  => i_m06_axi_wready  -- in std_logic  -- in std_logic;
    );
    
    o_m06_axi_aw <= m06_axi_aw;
    o_m06_axi_w <= m06_axi_w;
    
    -- never read the debug memory
    o_m06_axi_ar.valid <= '0';
    o_m06_axi_ar.addr <= (others => '0');
    o_m06_axi_ar.len <= (others => '0');
    o_m06_axi_rready <= '1';
    
--    HBM_ila_ila : ila_beamData
--    port map (
--        clk => i_shared_clk,   -- IN STD_LOGIC;
--        probe0(31 downto 0) => dbg_vec_final(31 downto 0), --  IN STD_LOGIC_VECTOR(119 DOWNTO 0)
--        probe0(63 downto 32) => m06_axi_w.data(31 downto 0),
--        probe0(95 downto 64) => hbm_ila_addr(31 downto 0),
--        probe0(96) => dbg_vec_valid,
--        probe0(97) => i_m06_axi_awready,
--        probe0(98) => i_m06_axi_wready,
--        probe0(99) => m06_axi_aw.valid,
--        probe0(100) => m06_axi_w.valid,
--        probe0(119 downto 101) => m06_axi_aw.addr(18 downto 0)
--    );
    
    ---------------------------------------------------------------------------
    -- debug ILA
    process(i_shared_clk)
    begin
        if rising_edge(i_shared_clk) then
            
            dbg_input_fsm_dbg <= input_fsm_dbg;
            dbg_running <= running;
            dbg_wr_buffer <= current_wr_buffer;
            dbg_first_readout <= first_readout;
            dbg_waiting_to_latch_on <= waiting_to_latch_on;
            dbg_readOverflow_set <= readOverflow_set;
            dbg_readoverflow <= readoverflow;
            dbg_chan0 <= meta01.virtualChannel(9 downto 0);
            dbg_integration <= wr_integration; -- (31:0); integration in units of 849ms relative to the epoch.
            --dbg_ctFrame <= FBctFrame; -- 2 bits
            dbg_o_valid <= validOut;
            dbg_sof_int <= sof_int;
            dbg_sofFull_int <= sofFull_int;
            
            dbg_hbm_aw_valid <= not AWFIFO_empty;
            dbg_hbm_aw_ready <= i_m01_axi_awready;
            
            dbg_hbm_r_valid <= i_m01_axi_r.valid;
            dbg_hbm_r_ready <= m01_axi_rready; -- out std_logic;
            
            dbg_hbm_ar_addr <= m01_axi_ar.addr(31 downto 0);
            dbg_hbm_ar_valid <= m01_axi_ar.valid;
            dbg_hbm_ar_ready <= i_m01_axi_arready;
            
            dbg_rd_tracker_bad <= i_m01_axi_rst_dbg(0);
            dbg_wr_tracker_bad <= i_m01_axi_rst_dbg(1);
            dbg_wr_tracker <= i_m01_axi_rst_dbg(27 downto 16);
            
            dbg_hbm_reset <= i_m01_axi_rst_dbg(2);
            dbg_hbm_reset_fsm <= i_m01_axi_rst_dbg(31 downto 28);
            
        end if;
    end process;
    
debug_ila_gen : if g_GENERATE_ILA GENERATE    
    ct2_ila : ila_120_16k
    port map (
       clk => i_shared_clk,
       probe0(0) => data_rst,
       probe0(5 downto 1) => dbg_input_fsm_dbg,
       probe0(6) => dbg_running,
       probe0(8 downto 7) => dbg_wr_buffer,
       probe0(9) => dbg_first_readout,
       probe0(10) => dbg_waiting_to_latch_on,
       probe0(11) => dbg_readOverflow_set,
       probe0(12) => dbg_readoverflow,
       probe0(22 downto 13) => dbg_chan0,
       probe0(35 downto 23) => dbg_integration(12 downto 0),
       
       probe0(39 downto 36) => dbg_hbm_reset_fsm,
       probe0(40) => dbg_hbm_reset,
       probe0(41) => dbg_rd_tracker_bad,
       probe0(42) => dbg_wr_tracker_bad,
       probe0(54 downto 43) => dbg_wr_tracker,
       
       probe0(56 downto 55) => "00",
       probe0(57) => dbg_o_valid,
       probe0(58) => dbg_sof_int,
       probe0(59) => dbg_sofFull_int,
       probe0(91 downto 60) => time_since_sofFull,
       probe0(92) => dbg_hbm_aw_valid,
       probe0(93) => dbg_hbm_aw_ready,
       probe0(94) => dbg_hbm_r_valid,
       probe0(95) => dbg_hbm_r_ready,
       probe0(96) => dbg_hbm_ar_valid,
       probe0(97) => dbg_hbm_ar_ready,
       probe0(119 downto 98) => dbg_hbm_ar_addr(31 downto 10)
    );
END GENERATE;    
    
end Behavioral;
