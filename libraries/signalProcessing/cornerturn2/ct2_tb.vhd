----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey
-- 
-- Create Date: 08/14/2023 10:14:24 PM
-- Module Name: ct1_tb - Behavioral
-- Description: 
--  Standalone testbench for correlator corner turn 1
-- 
----------------------------------------------------------------------------------

library IEEE, correlator_lib, ct_lib, common_lib, filterbanks_lib;
use IEEE.STD_LOGIC_1164.ALL;
Library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;
use IEEE.NUMERIC_STD.ALL;
use std.textio.all;
use IEEE.std_logic_textio.all;
USE ct_lib.corr_ct2_reg_pkg.ALL;
USE common_lib.common_pkg.ALL;
library DSP_top_lib;
use DSP_top_lib.DSP_top_pkg.all;

entity ct2_tb is
    generic(
        g_PACKET_GAP : integer := 4100; -- number of clocks from the start of one filterbank packet to the start of the next 
        g_VC_GAP : integer := 20000;   -- number of clocks idle between groups of 4 virtual channels from the filterbank
        g_MAX_CORRELATORS : integer := 2;
        g_TEST_CASE : integer := 4 -- selects a set of register transactions and other configuration to use in the test.
        -- 
    );
end ct2_tb;

architecture Behavioral of ct2_tb is

    function get_axi_size(AXI_DATA_WIDTH : integer) return std_logic_vector is
    begin
        if AXI_DATA_WIDTH = 8 then
            return "000";
        elsif AXI_DATA_WIDTH = 16 then
            return "001";
        elsif AXI_DATA_WIDTH = 32 then
            return "010";
        elsif AXI_DATA_WIDTH = 64 then
            return "011";
        elsif AXI_DATA_WIDTH = 128 then
            return "100";
        elsif AXI_DATA_WIDTH = 256 then
            return "101";
        elsif AXI_DATA_WIDTH = 512 then
            return "110";    -- size of 6 indicates 64 bytes in each beat (i.e. 512 bit wide bus) -- out std_logic_vector(2 downto 0);
        elsif AXI_DATA_WIDTH = 1024 then
            return "111";
        else
            assert FALSE report "Bad AXI data width" severity failure;
            return "000";
        end if;
    end get_axi_size;
    constant HBM_DATA_WIDTH : integer := 512;

    signal logic_HBM_axi_aw, HBM_axi_aw : t_axi4_full_addr_arr(g_MAX_CORRELATORS-1 downto 0); -- write address bus : out t_axi4_full_addr_arr(4 downto 0)(.valid, .addr(39:0), .len(7:0))
    signal logic_HBM_axi_awready, HBM_axi_awready : std_logic_vector(g_MAX_CORRELATORS-1 downto 0);
    signal logic_HBM_axi_w, HBM_axi_w : t_axi4_full_data_arr(g_MAX_CORRELATORS-1 downto 0); -- w data bus : out t_axi4_full_data_arr(4 downto 0)(.valid, .data(511:0), .last, .resp(1:0))
    signal logic_HBM_axi_wready, HBM_axi_wready : std_logic_vector(g_MAX_CORRELATORS-1 downto 0);
    signal logic_HBM_axi_b, HBM_axi_b :  t_axi4_full_b_arr(g_MAX_CORRELATORS-1 downto 0);     -- write response bus : in t_axi4_full_b_arr(4 downto 0)(.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
    signal logic_HBM_axi_ar, HBM_axi_ar :  t_axi4_full_addr_arr(g_MAX_CORRELATORS-1 downto 0); -- read address bus : out t_axi4_full_addr_arr(4 downto 0)(.valid, .addr(39:0), .len(7:0))
    signal logic_HBM_axi_arready, HBM_axi_arready : std_logic_vector(g_MAX_CORRELATORS-1 downto 0);
    signal logic_HBM_axi_r, HBM_axi_r :  t_axi4_full_data_arr(g_MAX_CORRELATORS-1 downto 0);  -- r data bus : in t_axi4_full_data_arr(4 downto 0)(.valid, .data(511:0), .last, .resp(1:0))
    signal logic_HBM_axi_rready, HBM_axi_rready : std_logic_vector(g_MAX_CORRELATORS-1 downto 0);
    
    signal cor_data   : t_slv_256_arr(g_MAX_CORRELATORS-1 downto 0);
    signal cor_time    : t_slv_8_arr(g_MAX_CORRELATORS-1 downto 0);  -- time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
    signal cor_station : t_slv_12_arr(g_MAX_CORRELATORS-1 downto 0); -- first of the 4 stations in o_cor0_data
    signal cor_valid   : std_logic_vector(g_MAX_CORRELATORS-1 downto 0);
    signal cor_frameCount : t_slv_32_arr(g_MAX_CORRELATORS-1 downto 0);
    signal cor_last    :  std_logic_vector(g_MAX_CORRELATORS-1 downto 0);  -- last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.        
    signal cor_final   :  std_logic_vector(g_MAX_CORRELATORS-1 downto 0);  -- Indicates that at the completion of processing the last block of correlator data, the integration is complete.
    signal cor_tileType    :  std_logic_vector(g_MAX_CORRELATORS-1 downto 0);  -- '0' for triangle, '1' for square. Triangles use the same data for the row and column.
    signal cor_first, cor_badPoly :  std_logic_vector(g_MAX_CORRELATORS-1 downto 0);  -- This is the first block of data for an integration - i.e. first fine channel, first block of 64 time samples, for this tile
    signal cor_tileLocation :  t_slv_10_arr(g_MAX_CORRELATORS-1 downto 0); -- bits 3:0 = tile column, bits 7:4 = tile row, bits 9:8 = "00";
    signal cor_tileChannel :  t_slv_24_arr(g_MAX_CORRELATORS-1 downto 0);
    signal cor_tileTotalTimes    :  t_slv_8_arr(g_MAX_CORRELATORS-1 downto 0); -- Number of time samples to integrate for this tile.
    signal cor_tiletotalChannels :  t_slv_5_arr(g_MAX_CORRELATORS-1 downto 0); -- Number of frequency channels to integrate for this tile.
    signal cor_rowstations       :  t_slv_9_arr(g_MAX_CORRELATORS-1 downto 0); -- number of stations in the row memories to process; up to 256.
    signal cor_colstations       :  t_slv_9_arr(g_MAX_CORRELATORS-1 downto 0); -- number of stations in the col memories to process; up to 256.
    signal cor_totalStations     :  t_slv_16_arr(g_MAX_CORRELATORS-1 downto 0); -- Total number of stations being processing for this subarray-beam.
    signal cor_subarrayBeam      :  t_slv_8_arr(g_MAX_CORRELATORS-1 downto 0);  -- Which entry is this in the subarray-beam table ?     
    
    signal mc_lite_mosi : t_axi4_lite_mosi;
    signal mc_lite_miso : t_axi4_lite_miso;
    signal send_fb_data : std_logic := '0';
    
    type t_fb_fsm is (wait_sof, send_sof, send_sof_wait, send_data0, send_Data, packet_gap, new_vc_gap, frame_gap);
    signal fb_fsm : t_fb_fsm := wait_sof;
    
    signal fb_sof, fb_dataValid : std_logic;
    signal fb_headerValid : std_logic_vector(3 downto 0);
    signal fb_virtualChannel : t_slv_16_arr(3 downto 0);
    signal fb_count_slv : std_logic_vector(15 downto 0);
    signal packets_sent_slv : std_logic_vector(15 downto 0);
    signal fb_data : t_ctc_output_payload_arr(3 downto 0);
    signal cor_ready : std_logic_vector(1 downto 0);
    signal hbm_reset_final : std_logic := '0';
    
    signal hbm_status : t_slv_8_arr(1 downto 0);
    signal hbm_rst_dbg : t_slv_32_arr(1 downto 0);
    
    signal HBM_axi_awsize, HBM_axi_arprot,  HBM_axi_awprot : t_slv_3_arr(1 downto 0);
    signal HBM_axi_awburst : t_slv_2_arr(1 downto 0);
    signal HBM_axi_bready : std_logic_vector(1 downto 0);
    signal HBM_axi_wstrb : t_slv_64_arr(1 downto 0);
    signal HBM_axi_arsize : t_slv_3_arr(1 downto 0);
    signal HBM_axi_arburst, HBM_axi_arlock, HBM_axi_awlock : t_slv_2_arr(1 downto 0);
    signal HBM_axi_awcache, HBM_axi_awqos, HBM_axi_arqos, HBM_axi_arregion, HBM_axi_awregion, HBM_axi_arcache : t_slv_4_arr(1 downto 0);
    signal HBM_axi_awid, HBM_axi_arid, HBM_axi_bid : t_slv_1_arr(1 downto 0);
    
    signal clk300, clk300_rst, data_rst : std_logic := '0';
    signal virtual_channels : std_logic_vector(10 downto 0);
    
    signal write_HBM_to_disk2, init_mem2 : std_logic := '0';
    signal fb_count : integer := 0;
    signal fb_integration : std_logic_vector(31 downto 0) := (others => '0');
    signal fb_ctFrame : std_logic_vector(1 downto 0) := "00";
    signal fb_vc0 : std_logic_vector(15 downto 0) := (others => '0');
    signal packets_sent : integer := 0;
    signal rst_n : std_logic;
    signal fb_bad_poly : std_logic;
    
    signal bad_poly_packets_sent : integer;
    signal bad_poly_integration : std_logic_vector(31 downto 0);
    signal bad_poly_ctFrame : std_logic_vector(1 downto 0);
    signal bad_poly_vc : std_logic_vector(15 downto 0);
    signal c_VIRTUAL_CHANNELS : integer := 0;
    signal fb_lastChannel : std_logic;
    signal fb_demap_table_select : std_logic;
    
begin
    
    clk300 <= not clk300 after 1.666 ns;
    rst_n <= not clk300_rst;
    
    process
        file RegCmdfile: TEXT;
        variable RegLine_in : Line;
        variable RegGood : boolean;
        variable cmd_str : string(1 to 2);
        variable regAddr : std_logic_vector(31 downto 0);
        variable regSize : std_logic_vector(31 downto 0);
        variable regData : std_logic_vector(31 downto 0);
        variable readResult : std_logic_vector(31 downto 0);
    begin
        
        -- startup default values
        virtual_channels <= (others => '0');
        mc_lite_mosi.awaddr <= (others => '0');
        mc_lite_mosi.awprot <= "000";
        mc_lite_mosi.awvalid <= '0';
        mc_lite_mosi.wdata <= (others => '0');
        mc_lite_mosi.wstrb <= "1111";
        mc_lite_mosi.wvalid <= '0';
        mc_lite_mosi.bready <= '0';
        mc_lite_mosi.araddr <= (others => '0');
        mc_lite_mosi.arprot <= "000";
        mc_lite_mosi.arvalid <= '0';
        mc_lite_mosi.rready <= '0';
        send_fb_data <= '0';
        clk300_rst <= '0';
        hbm_reset_final <= '0';
        fb_demap_table_select <= '0';
        
        for i in 1 to 10 loop
            WAIT UNTIL RISING_EDGE(clk300);
        end loop;
        clk300_rst <= '1';
        for i in 1 to 10 loop
             WAIT UNTIL RISING_EDGE(clk300);
        end loop;
        clk300_rst <= '0';
        
        for i in 1 to 100 loop
             WAIT UNTIL RISING_EDGE(clk300);
        end loop;
        
        -- For some reason the first transaction doesn't work; this is just a dummy transaction
        -- Arguments are       clk,    miso      ,    mosi     , 4-byte word Addr, write ?, data)
        --axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, 0,    true, x"00000000");
        
        if g_TEST_CASE = 0 then
            -- 8 virtual channels, 1 subarray-beam
            c_VIRTUAL_CHANNELS <= 8;
            WAIT UNTIL RISING_EDGE(clk300);
            virtual_channels <= std_logic_vector(to_unsigned(c_VIRTUAL_CHANNELS,11));
            -- Set where bad poly will occur in the data stream.
            bad_poly_packets_sent <= 0;
            bad_poly_integration <= (others => '0');
            bad_poly_ctFrame <= "00";
            bad_poly_vc <= x"0000";
            
            -- select table 0
            fb_demap_table_select <= '0';
            -- 1 subarray-beam in table 0
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_buf0_subarray_beams_table0_address.base_address + c_statctrl_buf0_subarray_beams_table0_address.address, true, x"00000001");
            -- 0 subarray-beams in table 1
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_buf0_subarray_beams_table1_address.base_address + c_statctrl_buf0_subarray_beams_table1_address.address, true, x"00000000");
            -- 0 subarray-beams for second correlator, table 0
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_buf1_subarray_beams_table0_address.base_address + c_statctrl_buf1_subarray_beams_table0_address.address, true, x"00000000");
            -- 0 subarray-beams for second correlator, table 1
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_buf1_subarray_beams_table1_address.base_address + c_statctrl_buf1_subarray_beams_table1_address.address, true, x"00000000");
            -- demap table
            -- 2 words per group of 4 virtual channels :
            --   Word 0 : bits(7:0) = subarray-beam id, index into the subarray_beam table. 
            --            bits(19:8) = (sub)station within this subarray.
            --            bits(28:20) = channel frequency index 
            --            bit(31) = 1 to indicate valid
            --   word 1 : bits(11:0) = start fine channel for forwarding on the 100GE port. (0)
            --            bits(23:12) = End fine channel for forwarding on the 100GE port. (3455 = xD7F)
            --            bits(31:24) = Forwarding address  (unused)
            -- 8 virtual channels in this test case, so 2 x 2 words in the demap table
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 0, true, x"99000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 1, true, x"00000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 2, true, x"99000400");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 3, true, x"00000000");
            -- subarray beam table
            -- Word 0 : bits(15:0) = number of (sub)stations in this subarray-beam, \
            --          bits(31:16) = starting coarse frequency channel, \
            -- Word 1 : bits (15:0) = starting fine frequency channel \
            -- Word 2 : bits (23:0) = Number of fine channels stored \
            --          bits (29:24) = Fine channels per integration \
            --          bits (31:30) = integration time; 0 = 283 ms, 1 = 849 ms, others invalid \
            -- Word 3 : bits (31:0) = Base Address in HBM within a 1.5 Gbyte block to store channelised source data for this subarray-beam \
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 0, true, x"01900008");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 1, true, x"00000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 2, true, x"58000D80");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 3, true, x"00000000");
            
            WAIT UNTIL RISING_EDGE(clk300);
            send_fb_data <= '1';
            WAIT UNTIL RISING_EDGE(clk300);
            send_fb_data <= '0';
            WAIT UNTIL RISING_EDGE(clk300);
        elsif g_TEST_CASE = 1 then
            -- 8 virtual channels, 2 subarray-beams, one in each correlator
            c_VIRTUAL_CHANNELS <= 8;
            WAIT UNTIL RISING_EDGE(clk300);
            virtual_channels <= std_logic_vector(to_unsigned(c_VIRTUAL_CHANNELS,11));
            -- Set where bad poly will occur in the data stream.
            bad_poly_packets_sent <= 0;
            bad_poly_integration <= (others => '0');
            bad_poly_ctFrame <= "00";
            -- note bad poly vc only works on blocks of 4 channels, so bad_poly_vc needs to be a multiple of 4.
            bad_poly_vc <= x"0004";  -- bad poly is somewhere in the second subarray-beam
            
            -- select table 0
            fb_demap_table_select <= '0';
            
            -- 1 subarray-beam in table 0
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_buf0_subarray_beams_table0_address.base_address + c_statctrl_buf0_subarray_beams_table0_address.address, true, x"00000001");
            -- 0 subarray-beams in table 1
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_buf0_subarray_beams_table1_address.base_address + c_statctrl_buf0_subarray_beams_table1_address.address, true, x"00000000");
            -- 1 subarray-beams for second correlator, table 0
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_buf1_subarray_beams_table0_address.base_address + c_statctrl_buf1_subarray_beams_table0_address.address, true, x"00000001");
            -- 0 subarray-beams for second correlator, table 1
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_buf1_subarray_beams_table1_address.base_address + c_statctrl_buf1_subarray_beams_table1_address.address, true, x"00000000");
            -- demap table
            -- 2 words per group of 4 virtual channels :
            --   Word 0 : bits(7:0) = subarray-beam id, index into the subarray_beam table. Values of 0 to 127 are for the first correlator, 128 to 255 for the second correlator. 
            --            bits(19:8) = (sub)station within this subarray.
            --            bits(28:20) = channel frequency index 
            --            bit(31) = 1 to indicate valid
            --   word 1 : !!! This is for exporting the fine channel data on the 100GE port, bypassing the correlator. The functionality is not implemented in the firmware, and may never be.
            --            bits(11:0) = start fine channel for forwarding on the 100GE port. (0)
            --            bits(23:12) = End fine channel for forwarding on the 100GE port. (3455 = xD7F)
            --            bits(31:24) = Forwarding address  (unused)
            -- 8 virtual channels in this test case, so 2 x 2 words in the demap table
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 0, true, x"99000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 1, true, x"00000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 2, true, x"99100080");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 3, true, x"00000000");
            -- subarray beam table
            -- Word 0 : bits(15:0) = number of (sub)stations in this subarray-beam, \
            --          bits(31:16) = starting coarse frequency channel, \
            -- Word 1 : bits (15:0) = starting fine frequency channel \
            -- Word 2 : bits (23:0) = Number of fine channels stored \
            --          bits (29:24) = Fine channels per integration \
            --          bits (31:30) = integration time; 0 = 283 ms, 1 = 849 ms, others invalid \
            -- Word 3 : bits (31:0) = Base Address in HBM within a 1.5 Gbyte block to store channelised source data for this subarray-beam \
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 0, true, x"01900004");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 1, true, x"00000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 2, true, x"58000D80");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 3, true, x"00000000");
            
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 512 + 0, true, x"01910004");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 512 + 1, true, x"00000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 512 + 2, true, x"58000D80");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 512 + 3, true, x"00000000");
            
            WAIT UNTIL RISING_EDGE(clk300);
            send_fb_data <= '1';
            WAIT UNTIL RISING_EDGE(clk300);
            send_fb_data <= '0';
            WAIT UNTIL RISING_EDGE(clk300);
        
        elsif g_TEST_CASE = 2 then
            -- 8 virtual channels, 2 subarray-beams, both in the first correlator
            c_VIRTUAL_CHANNELS <= 8;
            WAIT UNTIL RISING_EDGE(clk300);
            virtual_channels <= std_logic_vector(to_unsigned(c_VIRTUAL_CHANNELS,11));
            -- Set where bad poly will occur in the data stream.
            bad_poly_packets_sent <= 0;
            bad_poly_integration <= (others => '0');
            bad_poly_ctFrame <= "00";
            -- note bad poly vc only works on blocks of 4 channels, so bad_poly_vc needs to be a multiple of 4.
            bad_poly_vc <= x"0004";  -- bad poly is somewhere in the second subarray-beam
            
            -- select table 0
            fb_demap_table_select <= '0';
            -- 2 subarray-beam in table 0
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_buf0_subarray_beams_table0_address.base_address + c_statctrl_buf0_subarray_beams_table0_address.address, true, x"00000002");
            -- 0 subarray-beams in table 1
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_buf0_subarray_beams_table1_address.base_address + c_statctrl_buf0_subarray_beams_table1_address.address, true, x"00000000");
            -- 1 subarray-beams for second correlator, table 0
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_buf1_subarray_beams_table0_address.base_address + c_statctrl_buf1_subarray_beams_table0_address.address, true, x"00000000");
            -- 0 subarray-beams for second correlator, table 1
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_buf1_subarray_beams_table1_address.base_address + c_statctrl_buf1_subarray_beams_table1_address.address, true, x"00000000");
            -- demap table
            -- 2 words per group of 4 virtual channels :
            --   Word 0 : bits(7:0) = subarray-beam id, index into the subarray_beam table. Values of 0 to 127 are for the first correlator, 128 to 255 for the second correlator. 
            --            bits(19:8) = (sub)station within this subarray.
            --            bits(28:20) = channel frequency index 
            --            bit(31) = 1 to indicate valid
            --   word 1 : !!! This is for exporting the fine channel data on the 100GE port, bypassing the correlator. The functionality is not implemented in the firmware, and may never be.
            --            bits(11:0) = start fine channel for forwarding on the 100GE port. (0)
            --            bits(23:12) = End fine channel for forwarding on the 100GE port. (3455 = xD7F)
            --            bits(31:24) = Forwarding address  (unused)
            -- 8 virtual channels in this test case, so 2 x 2 words in the demap table
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 0, true, x"99000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 1, true, x"00000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 2, true, x"99100001");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 3, true, x"00000000");
            -- subarray beam table
            -- Word 0 : bits(15:0) = number of (sub)stations in this subarray-beam, \
            --          bits(31:16) = starting coarse frequency channel, \
            -- Word 1 : bits (15:0) = starting fine frequency channel \
            -- Word 2 : bits (23:0) = Number of fine channels stored \
            --          bits (29:24) = Fine channels per integration \
            --          bits (31:30) = integration time; 0 = 283 ms, 1 = 849 ms, others invalid \
            -- Word 3 : bits (31:0) = Base Address in HBM within a 1.5 Gbyte block to store channelised source data for this subarray-beam \
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 0, true, x"01900004");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 1, true, x"00000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 2, true, x"58000D80");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 3, true, x"00000000");
            
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 0, true, x"01910004");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 1, true, x"00000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 2, true, x"58000D80");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 3, true, x"00000000");
            
            WAIT UNTIL RISING_EDGE(clk300);
            send_fb_data <= '1';
            WAIT UNTIL RISING_EDGE(clk300);
            send_fb_data <= '0';
            WAIT UNTIL RISING_EDGE(clk300);

        elsif g_TEST_CASE = 3 then
            -- 8 virtual channels, 2 subarray-beams, both in the first correlator
            c_VIRTUAL_CHANNELS <= 8;
            WAIT UNTIL RISING_EDGE(clk300);
            virtual_channels <= std_logic_vector(to_unsigned(c_VIRTUAL_CHANNELS,11));
            -- Set where bad poly will occur in the data stream.
            bad_poly_packets_sent <= 0;
            bad_poly_integration <= (others => '0');
            bad_poly_ctFrame <= "00";
            -- note bad poly vc only works on blocks of 4 channels, so bad_poly_vc needs to be a multiple of 4.
            bad_poly_vc <= x"0004";  -- bad poly is somewhere in the second subarray-beam
            
            -- select table 0
            fb_demap_table_select <= '0';
            -- 2 subarray-beam in table 0
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_buf0_subarray_beams_table0_address.base_address + c_statctrl_buf0_subarray_beams_table0_address.address, true, x"00000002");
            -- 0 subarray-beams in table 1
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_buf0_subarray_beams_table1_address.base_address + c_statctrl_buf0_subarray_beams_table1_address.address, true, x"00000000");
            -- 1 subarray-beams for second correlator, table 0
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_buf1_subarray_beams_table0_address.base_address + c_statctrl_buf1_subarray_beams_table0_address.address, true, x"00000000");
            -- 0 subarray-beams for second correlator, table 1
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_buf1_subarray_beams_table1_address.base_address + c_statctrl_buf1_subarray_beams_table1_address.address, true, x"00000000");
            -- demap table
            -- 2 words per group of 4 virtual channels :
            --   Word 0 : bits(7:0) = subarray-beam id, index into the subarray_beam table. Values of 0 to 127 are for the first correlator, 128 to 255 for the second correlator. 
            --            bits(19:8) = (sub)station within this subarray.
            --            bits(28:20) = channel frequency index 
            --            bit(31) = 1 to indicate valid
            --   word 1 : !!! This is for exporting the fine channel data on the 100GE port, bypassing the correlator. The functionality is not implemented in the firmware, and may never be.
            --            bits(11:0) = start fine channel for forwarding on the 100GE port. (0)
            --            bits(23:12) = End fine channel for forwarding on the 100GE port. (3455 = xD7F)
            --            bits(31:24) = Forwarding address  (unused)
            -- 8 virtual channels in this test case, so 2 x 2 words in the demap table
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 0, true, x"99000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 1, true, x"00000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 2, true, x"99100001");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 3, true, x"00000000");
            -- subarray beam table
            -- Word 0 : bits(15:0) = number of (sub)stations in this subarray-beam, \
            --          bits(31:16) = starting coarse frequency channel, \
            -- Word 1 : bits (15:0) = starting fine frequency channel \
            -- Word 2 : bits (23:0) = Number of fine channels stored \
            --          bits (29:24) = Fine channels per integration \
            --          bits (31:30) = integration time; 0 = 283 ms, 1 = 849 ms, others invalid \
            -- Word 3 : bits (31:0) = Base Address in HBM within a 1.5 Gbyte block to store channelised source data for this subarray-beam \
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 0, true, x"01900004");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 1, true, x"00000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 2, true, x"58000D80");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 3, true, x"00000000");
            
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 0, true, x"01910004");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 1, true, x"00000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 2, true, x"58000D80");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 3, true, x"00000000");
            
            WAIT UNTIL RISING_EDGE(clk300);
            send_fb_data <= '1';
            WAIT UNTIL RISING_EDGE(clk300);
            send_fb_data <= '0';
            WAIT UNTIL RISING_EDGE(clk300);
            wait for 10 ms;
            -- !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            -- Setup a page flip
            -- !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            WAIT UNTIL RISING_EDGE(clk300);
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 512 + 0, true, x"99000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 512 + 1, true, x"00000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 512 + 2, true, x"99100001");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 512 + 3, true, x"00000000");
            
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 1024 + 0, true, x"01900004");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 1024 + 1, true, x"00000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 1024 + 2, true, x"58000D80");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 1024 + 3, true, x"00000000");
            
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 1024 + 4 + 0, true, x"01910004");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 1024 + 4 + 1, true, x"00000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 1024 + 4 + 2, true, x"58000D80");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 1024 + 4 + 3, true, x"00000000");
            
            fb_demap_table_select <= '1';
            WAIT UNTIL RISING_EDGE(clk300);
            
        elsif g_TEST_CASE = 4 then
            -- 1 virtual channel, 1 subarray-beam, integrate 2 channels, 
            c_VIRTUAL_CHANNELS <= 1;
            WAIT UNTIL RISING_EDGE(clk300);
            virtual_channels <= std_logic_vector(to_unsigned(c_VIRTUAL_CHANNELS,11));
            -- Set where bad poly will occur in the data stream.
            bad_poly_packets_sent <= 0;
            bad_poly_integration <= (others => '0');
            bad_poly_ctFrame <= "00";
            -- note bad poly vc only works on blocks of 4 channels, so bad_poly_vc needs to be a multiple of 4.
            bad_poly_vc <= x"0004";  -- bad poly is somewhere in the second subarray-beam
            
            -- select table 0
            fb_demap_table_select <= '0';
            -- 1 subarray-beam in table 0
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_buf0_subarray_beams_table0_address.base_address + c_statctrl_buf0_subarray_beams_table0_address.address, true, x"00000001");
            -- 0 subarray-beams in table 1
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_buf0_subarray_beams_table1_address.base_address + c_statctrl_buf0_subarray_beams_table1_address.address, true, x"00000000");
            -- 1 subarray-beams for second correlator, table 0
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_buf1_subarray_beams_table0_address.base_address + c_statctrl_buf1_subarray_beams_table0_address.address, true, x"00000000");
            -- 0 subarray-beams for second correlator, table 1
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_buf1_subarray_beams_table1_address.base_address + c_statctrl_buf1_subarray_beams_table1_address.address, true, x"00000000");
            -- demap table
            -- 2 words per group of 4 virtual channels :
            --   Word 0 : bits(7:0) = subarray-beam id, index into the subarray_beam table. Values of 0 to 127 are for the first correlator, 128 to 255 for the second correlator. 
            --            bits(19:8) = (sub)station within this subarray.
            --            bits(28:20) = channel frequency index 
            --            bit(31) = 1 to indicate valid
            --   word 1 : !!! This is for exporting the fine channel data on the 100GE port, bypassing the correlator. The functionality is not implemented in the firmware, and may never be.
            --            bits(11:0) = start fine channel for forwarding on the 100GE port. (0)
            --            bits(23:12) = End fine channel for forwarding on the 100GE port. (3455 = xD7F)
            --            bits(31:24) = Forwarding address  (unused)
            -- 1 virtual channels in this test case, so only 1 x 2 words needed in the demap table
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 0, true, x"86400000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 1, true, x"00000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 2, true, x"00000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 3, true, x"00000000");
            -- subarray beam table
            -- Word 0 : bits(15:0) = number of (sub)stations in this subarray-beam, \
            --          bits(31:16) = starting coarse frequency channel, \
            -- Word 1 : bits (15:0) = starting fine frequency channel \
            -- Word 2 : bits (23:0) = Number of fine channels stored \
            --          bits (29:24) = Fine channels per integration \
            --          bits (31:30) = integration time; 0 = 283 ms, 1 = 849 ms, others invalid \
            -- Word 3 : bits (31:0) = Base Address in HBM within a 1.5 Gbyte block to store channelised source data for this subarray-beam \
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 0, true, x"00640001");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 1, true, x"000006BA");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 2, true, x"4200000C");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 3, true, x"00000000");
            
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 0, true, x"00000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 1, true, x"00000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 2, true, x"00000000");
            axi_lite_transaction(clk300, mc_lite_miso, mc_lite_mosi, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 3, true, x"00000000");
            
            WAIT UNTIL RISING_EDGE(clk300);
            send_fb_data <= '1';
            WAIT UNTIL RISING_EDGE(clk300);
            send_fb_data <= '0';
            WAIT UNTIL RISING_EDGE(clk300);
        end if;
        
        
        wait;
    end process;    
    


    --------------------------------------------------------------------------------
    -- Emulate the filterbanks
    -- 
    process(clk300)
    begin
        if rising_Edge(clk300) then
            -- 
            -- 283 ms ct1 frame = 64 time samples from the filterbank
            
            if clk300_rst = '1' then
                fb_fsm <= wait_sof;
                fb_count <= 0;
                fb_integration <= (others => '0');
                fb_ctFrame <= "00";
                fb_vc0 <= (others => '0');
                packets_sent <= 0;
            else
                case fb_fsm is
                    when wait_sof =>
                        if send_fb_data = '1' then
                           fb_fsm <= send_sof;
                        end if;
                        fb_count <= 0;
                        
                    when send_sof =>
                        fb_fsm <= send_sof_wait;
                        fb_count <= 0;
                        
                    when send_sof_wait =>
                        if fb_count = 1000 then
                            fb_fsm <= send_data0;
                            fb_count <= 0;
                        else
                            fb_count <= fb_count + 1;
                        end if;
                        
                    when send_data0 => -- send first word in the frame
                        fb_fsm <= send_data;
                        fb_count <= fb_count + 1;
                        
                    when send_data =>
                        if fb_count = 3455 then
                            fb_fsm <= packet_gap;
                        end if;
                        fb_count <= fb_count + 1;
                        
                    when packet_gap =>
                        if fb_count = 4100 then
                            fb_count <= 0;
                            if packets_sent = 63 then
                                packets_sent <= 0;
                                -- 63, plus the one just sent = 64 packets sent
                                -- move to the next virtual channel
                                if (unsigned(fb_vc0) + 4) > (c_VIRTUAL_CHANNELS-1) then
                                    -- Sent data for all the virtual channels, move on to the next 283 ms frame
                                    fb_vc0 <= (others => '0');
                                    fb_fsm <= frame_gap;
                                    if fb_ctFrame = "10" then
                                        fb_ctFrame <= "00";
                                        fb_integration <= std_logic_vector(unsigned(fb_integration) + 1);
                                    else
                                        fb_ctFrame <= std_logic_vector(unsigned(fb_ctFrame) + 1);
                                    end if;
                                else
                                    -- Go to the next set of 4 virtual channels
                                    fb_vc0 <= std_logic_vector(unsigned(fb_vc0) + 4);
                                    fb_fsm <= new_vc_gap;
                                end if;
                            else
                                packets_sent <= packets_sent + 1;
                                fb_fsm <= send_data0;
                            end if;
                        else
                            fb_count <= fb_count + 1;
                        end if;
                    
                    when new_vc_gap =>
                        -- Wait about 11*4100 = 45100 clocks between bursts of output packets
                        -- Could do less for faster simulation
                        if fb_count = 44000 then
                            fb_count <= 0;
                            fb_fsm <= send_sof;
                        else
                            fb_count <= fb_count + 1;
                        end if;    
                    
                    when frame_gap =>
                        -- wait before starting the next 283ms frame
                        if fb_count = 100000 then
                            fb_count <= 0;
                            fb_fsm <= send_sof;
                        else
                            fb_count <= fb_count + 1;
                        end if;
                    
                    when others => 
                        fb_fsm <= wait_sof;
                        
                end case;
            end if;
            
        end if;
    end process;
    

    
    fb_sof <= '1' when fb_fsm = send_sof else '0';  -- in std_logic; -- pulse high at the start of every frame. (1 frame is 283 ms of data).
    -- fb_integration, -- in std_logic_vector(31 downto 0); -- frame count is the same for all simultaneous output streams.
    -- fb_ctFrame,     -- in std_logic_vector(1 downto 0); -- 283 ms frame within each integration interval
    -- fb_virtualChannel, -- in t_slv_16_arr(3 downto 0);    -- 4 virtual channels, one for each of the data streams.
    fb_virtualChannel(0) <= fb_vc0;
    fb_virtualChannel(1) <= std_logic_vector(unsigned(fb_vc0) + 1);
    fb_virtualChannel(2) <= std_logic_vector(unsigned(fb_vc0) + 2);
    fb_virtualChannel(3) <= std_logic_vector(unsigned(fb_vc0) + 3);
    fb_bad_poly <= '1' when fb_dataValid = '1' and fb_vc0 = bad_poly_vc and fb_ctFrame = bad_poly_ctFrame and fb_integration = bad_poly_integration and packets_sent = bad_poly_packets_sent else '0';
    fb_headerValid <= "1111" when fb_fsm = send_data0 else "0000"; --  -- in std_logic_vector(3 downto 0);
    -- in the data - fb_count = fine channel, 0 to 3455
    -- packet in frame, 0 to 63,
    -- ct_frame, 0 to 2
    -- fb_integration 32 bit value
    -- virtual channel, 0 to 1023
    --
    fb_count_slv <= std_logic_vector(to_unsigned(fb_count,16));
    packets_sent_slv <= std_logic_vector(to_unsigned(packets_sent,16));
    
    fb_data(0).Hpol.re <= fb_count_slv(7 downto 0); -- in t_ctc_output_payload_arr(3 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), i_data(2), i_data(3)
    fb_data(0).Hpol.im(3 downto 0) <= fb_count_slv(11 downto 8);
    fb_data(0).Hpol.im(7 downto 4) <= fb_integration(3 downto 0);
    fb_data(0).Vpol.re(5 downto 0) <= packets_sent_slv(5 downto 0);
    fb_data(0).Vpol.re(7 downto 6) <= fb_ctFrame(1 downto 0);
    fb_data(0).Vpol.im <= fb_virtualChannel(0)(7 downto 0);
    
    fb_data(1).Hpol.re <= fb_count_slv(7 downto 0); -- in t_ctc_output_payload_arr(3 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), i_data(2), i_data(3)
    fb_data(1).Hpol.im(3 downto 0) <= fb_count_slv(11 downto 8);
    fb_data(1).Hpol.im(7 downto 4) <= fb_integration(3 downto 0);
    fb_data(1).Vpol.re(5 downto 0) <= packets_sent_slv(5 downto 0);
    fb_data(1).Vpol.re(7 downto 6) <= fb_ctFrame(1 downto 0);
    fb_data(1).Vpol.im <= fb_virtualChannel(1)(7 downto 0);

    fb_data(2).Hpol.re <= fb_count_slv(7 downto 0); -- in t_ctc_output_payload_arr(3 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), i_data(2), i_data(3)
    fb_data(2).Hpol.im(3 downto 0) <= fb_count_slv(11 downto 8);
    fb_data(2).Hpol.im(7 downto 4) <= fb_integration(3 downto 0);
    fb_data(2).Vpol.re(5 downto 0) <= packets_sent_slv(5 downto 0);
    fb_data(2).Vpol.re(7 downto 6) <= fb_ctFrame(1 downto 0);
    fb_data(2).Vpol.im <= fb_virtualChannel(2)(7 downto 0);
    
    fb_data(3).Hpol.re <= fb_count_slv(7 downto 0); -- in t_ctc_output_payload_arr(3 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), i_data(2), i_data(3)
    fb_data(3).Hpol.im(3 downto 0) <= fb_count_slv(11 downto 8);
    fb_data(3).Hpol.im(7 downto 4) <= fb_integration(3 downto 0);
    fb_data(3).Vpol.re(5 downto 0) <= packets_sent_slv(5 downto 0);
    fb_data(3).Vpol.re(7 downto 6) <= fb_ctFrame(1 downto 0);
    fb_data(3).Vpol.im <= fb_virtualChannel(3)(7 downto 0);   
    
    fb_dataValid <= '1' when fb_fsm = send_data0 or fb_fsm = send_data else '0'; -- in std_logic;
    
    fb_lastChannel <= '1' when (unsigned(fb_vc0) + 4) > (c_VIRTUAL_CHANNELS-1) else '0';
    
    ct2i : entity ct_lib.corr_ct2_top
    generic map (
        g_USE_META => FALSE, -- : boolean := FALSE;   -- Put meta data into the memory in place of the actual data, to make it easier to find bugs in the corner turn. 
        g_CORRELATORS => 2, -- : integer := 2;    -- Number of correlator cells to instantiate.
        g_MAX_CORRELATORS => 2 -- : integer := 2 -- Maximum number of correlator cells that can be instantiated.
    ) port map (
        -- Registers AXI Lite Interface (uses i_axi_clk)
        i_axi_clk  => clk300,       -- in std_logic;
        i_axi_rst  => clk300_rst,   -- in std_logic;
        i_axi_mosi => mc_lite_mosi, -- in t_axi4_lite_mosi;
        o_axi_miso => mc_lite_miso, -- out t_axi4_lite_miso;
        -- pipelined reset from first stage corner turn ?
        i_rst  => clk300_rst, --  in std_logic;   -- First data received after this reset is placed in the first 283ms block in a 849 ms integration.
        
        -- hbm reset   
        o_hbm_reset_c1   => open, --  out std_logic;
        i_hbm_status_c1  => (others => '0'), -- in std_logic_vector(7 downto 0);
        o_hbm_reset_c2   => open, --  out std_logic;
        i_hbm_status_c2  => (others => '0'), --  in std_logic_vector(7 downto 0);

        -- Data in from the correlator filterbanks; bursts of 3456 clocks for each channel.
        -- (on i_axi_clk)
        i_sof          => fb_sof,         -- in std_logic; -- pulse high at the start of every frame. (1 frame is 283 ms of data).
        i_integration  => fb_integration, -- in std_logic_vector(31 downto 0); -- frame count is the same for all simultaneous output streams.
        i_ctFrame      => fb_ctFrame,     -- in std_logic_vector(1 downto 0); -- 283 ms frame within each integration interval
        i_virtualChannel => fb_virtualChannel, -- in t_slv_16_arr(3 downto 0);    -- 4 virtual channels, one for each of the data streams.
        i_bad_poly       => fb_bad_poly,     -- in std_logic;
        i_lastChannel    => fb_lastChannel,  -- in std_logic;
        i_demap_table_select => fb_demap_table_select, -- in std_logic;
        i_HeaderValid => fb_headerValid,  -- in std_logic_vector(3 downto 0);
        i_data        => fb_data,         -- in t_ctc_output_payload_arr(3 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), i_data(2), i_data(3)
        i_dataValid   => fb_dataValid,    -- in std_logic;
        
        ---------------------------------------------------------------
        -- Data out to the correlator arrays
        --
        -- The correlator is ready to receive a new block of data. This will go low once data starts to be received.
        -- A block of data consists of data for 64 times, and up to 512 virtual channels.
        i_cor_ready  => cor_ready, --  in std_logic_vector(g_MAX_CORRELATORS-1 downto 0);  
        -- Each 256 bit word : two time samples, 4 consecutive virtual channels
        -- (31:0) = time 0, virtual channel 0; (63:32) = time 0, virtual channel 1; (95:64) = time 0, virtual channel 2; (127:96) = time 0, virtual channel 3;
        -- (159:128) = time 1, virtual channel 0; (191:160) = time 1, virtual channel 1; (223:192) = time 1, virtual channel 2; (255:224) = time 1, virtual channel 3;
        o_cor_data   => cor_data, --  out t_slv_256_arr(g_MAX_CORRELATORS-1 downto 0); 
        -- meta data
        o_cor_time    => cor_time, --  out t_slv_8_arr(g_MAX_CORRELATORS-1 downto 0);  -- time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
        o_cor_station => cor_station, --  out t_slv_12_arr(g_MAX_CORRELATORS-1 downto 0); -- first of the 4 stations in o_cor0_data
        o_cor_valid   => cor_valid, --  out std_logic_vector(g_MAX_CORRELATORS-1 downto 0);
        o_cor_frameCount => cor_framecount, --  out t_slv_32_arr(g_MAX_CORRELATORS-1 downto 0);
        o_cor_last    => cor_last, -- out std_logic_vector(g_MAX_CORRELATORS-1 downto 0);  -- last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.        
        o_cor_final   => cor_final, -- out std_logic_vector(g_MAX_CORRELATORS-1 downto 0);  -- Indicates that at the completion of processing the last block of correlator data, the integration is complete.
        o_cor_tileType => cor_tileType, -- out std_logic_vector(g_MAX_CORRELATORS-1 downto 0);  -- '0' for triangle, '1' for square. Triangles use the same data for the row and column.
        o_cor_first    => cor_first,    -- out std_logic_vector(g_MAX_CORRELATORS-1 downto 0);  -- This is the first block of data for an integration - i.e. first fine channel, first block of 64 time samples, for this tile
        o_cor_tileLocation => cor_tileLocation, --  out t_slv_10_arr(g_MAX_CORRELATORS-1 downto 0); -- bits 3:0 = tile column, bits 7:4 = tile row, bits 9:8 = "00";
        o_cor_tileChannel  => cor_tileChannel, -- out t_slv_24_arr(g_MAX_CORRELATORS-1 downto 0);
        o_cor_tileTotalTimes    => cor_tileTotalTimes, -- out t_slv_8_arr(g_MAX_CORRELATORS-1 downto 0); -- Number of time samples to integrate for this tile.
        o_cor_tiletotalChannels => cor_tiletotalChannels, --  out t_slv_5_arr(g_MAX_CORRELATORS-1 downto 0); -- Number of frequency channels to integrate for this tile.
        o_cor_rowstations       => cor_rowstations, -- out t_slv_9_arr(g_MAX_CORRELATORS-1 downto 0); -- number of stations in the row memories to process; up to 256.
        o_cor_colstations       => cor_colstations, -- out t_slv_9_arr(g_MAX_CORRELATORS-1 downto 0); -- number of stations in the col memories to process; up to 256.
        o_cor_totalStations     => cor_totalStations, -- out t_slv_16_arr(g_MAX_CORRELATORS-1 downto 0); -- Total number of stations being processing for this subarray-beam.
        o_cor_subarrayBeam      => cor_subarrayBeam,  -- out t_slv_8_arr(g_MAX_CORRELATORS-1 downto 0);  -- Which entry is this in the subarray-beam table ? 
        o_cor_badPoly           => cor_badPoly,       -- out std_logic_vector(g_MAX_CORRELATORS-1 downto 0); -- out std_logic; No valid polynomial for some of the data in the subarray-beam
        -----------------------------------------------------------------
        -- AXI interface to the HBM
        -- Corner turn between filterbanks and correlator
        -- 3 Gbytes for each correlator cell.
        o_HBM_axi_aw      => logic_HBM_axi_aw,      -- out t_axi4_full_addr_arr(g_MAX_CORRELATORS-1 downto 0); -- write address bus : out t_axi4_full_addr_arr(4 downto 0)(.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_awready => logic_HBM_axi_awready, -- in std_logic_vector(g_MAX_CORRELATORS-1 downto 0);
        o_HBM_axi_w       => logic_HBM_axi_w,       -- out t_axi4_full_data_arr(g_MAX_CORRELATORS-1 downto 0); -- w data bus : out t_axi4_full_data_arr(4 downto 0)(.valid, .data(511:0), .last, .resp(1:0))
        i_HBM_axi_wready  => logic_HBM_axi_wready,  -- in std_logic_vector(g_MAX_CORRELATORS-1 downto 0);
        i_HBM_axi_b       => logic_HBM_axi_b,       -- in t_axi4_full_b_arr(g_MAX_CORRELATORS-1 downto 0);     -- write response bus : in t_axi4_full_b_arr(4 downto 0)(.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        o_HBM_axi_ar      => logic_HBM_axi_ar,      -- out t_axi4_full_addr_arr(g_MAX_CORRELATORS-1 downto 0); -- read address bus : out t_axi4_full_addr_arr(4 downto 0)(.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_arready => logic_HBM_axi_arready, -- in std_logic_vector(g_MAX_CORRELATORS-1 downto 0);
        i_HBM_axi_r       => logic_HBM_axi_r,       -- in t_axi4_full_data_arr(g_MAX_CORRELATORS-1 downto 0);  -- r data bus : in t_axi4_full_data_arr(4 downto 0)(.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_rready  => logic_HBM_axi_rready,  -- out std_logic_vector(g_MAX_CORRELATORS-1 downto 0);
        -- signals used in testing to initiate readout of the buffer when HBM is preloaded with data,
        -- so we don't have to wait for the previous processing stages to complete.
        i_readout_start   => '0', -- in std_logic;
        i_readout_buffer  => '0', -- in std_logic;
        i_readout_frameCount => (others => '0'), --  in std_logic_vector(31 downto 0);
        i_freq_index0_repeat => '0', -- in std_logic;
        -- debug
        i_hbm_status => (others => (others => '0')),  -- in t_slv_8_arr(5 downto 0);
        i_hbm_reset_final => '0',                     -- in std_logic;
        i_eth_disable_fsm_dbg => (others => '0'),     -- in std_logic_vector(4 downto 0);
        i_hbm_rst_dbg  => (others => (others => '0')) -- in t_slv_32_arr(5 downto 0)
    );
    
    -- drive low once data is sent ?
    cor_ready <= "11";
    

    
    axi_HBM_gen : for i in 0 to 1 generate

        -- reset blocks for HBM interfaces.
        hbm_resetter : entity correlator_lib.hbm_axi_reset_handler 
        generic map (
            DEBUG_ILA               => FALSE )
        port map ( 
            i_clk                   => clk300,
            i_reset                 => clk300_rst,
    
            i_logic_reset           => hbm_reset_final, -- hbm_reset_combined(i),
            o_in_reset              => open,
            o_reset_complete        => hbm_status(i),
            o_dbg                   => hbm_rst_dbg(i),
            -----------------------------------------------------
            -- To HBM
            -- Data out to the HBM
            -- ADDR
            o_hbm_axi_aw_addr       => HBM_axi_aw(i).addr,
            o_hbm_axi_aw_len        => HBM_axi_aw(i).len,
            o_hbm_axi_aw_valid      => HBM_axi_aw(i).valid,
    
            i_hbm_axi_awready       => HBM_axi_awready(i),
    
            -- DATA
            o_hbm_axi_w_data        => HBM_axi_w(i).data,
            o_hbm_axi_w_resp        => HBM_axi_w(i).resp,
            o_hbm_axi_w_last        => HBM_axi_w(i).last,
            o_hbm_axi_w_valid       => HBM_axi_w(i).valid,
            i_hbm_axi_wready        => HBM_axi_wready(i),
    
            i_hbm_axi_b_valid       => HBM_axi_b(i).valid,
            i_hbm_axi_b_resp        => HBM_axi_b(i).resp,
            
            -- reading from HBM
            -- ADDR
            o_hbm_axi_ar_addr       => HBM_axi_ar(i).addr,
            o_hbm_axi_ar_len        => HBM_axi_ar(i).len,
            o_hbm_axi_ar_valid      => HBM_axi_ar(i).valid,
            i_hbm_axi_arready       => HBM_axi_arready(i),
    
            -- DATA
            i_hbm_axi_r_data        => HBM_axi_r(i).data,
            i_hbm_axi_r_resp        => HBM_axi_r(i).resp,
            i_hbm_axi_r_last        => HBM_axi_r(i).last,
            i_hbm_axi_r_valid       => HBM_axi_r(i).valid,
            o_hbm_axi_rready        => HBM_axi_rready(i),
    
            -----------------------------------------------------
            -- To Logic
            -- ADDR
            i_logic_axi_aw_addr     => logic_HBM_axi_aw(i).addr,
            i_logic_axi_aw_len      => logic_HBM_axi_aw(i).len,
            i_logic_axi_aw_valid    => logic_HBM_axi_aw(i).valid,
    
            o_logic_axi_awready     => logic_HBM_axi_awready(i),
    
            -- DATA
            i_logic_axi_w_data      => logic_HBM_axi_w(i).data,
            i_logic_axi_w_resp      => logic_HBM_axi_w(i).resp,
            i_logic_axi_w_last      => logic_HBM_axi_w(i).last,
            i_logic_axi_w_valid     => logic_HBM_axi_w(i).valid,
            o_logic_axi_wready      => logic_HBM_axi_wready(i),
    
            o_logic_axi_b_valid     => logic_HBM_axi_b(i).valid,
            o_logic_axi_b_resp      => logic_HBM_axi_b(i).resp,
            
            -- reading from logic
            -- ADDR
            i_logic_axi_ar_addr     => logic_HBM_axi_ar(i).addr,
            i_logic_axi_ar_len      => logic_HBM_axi_ar(i).len,
            i_logic_axi_ar_valid    => logic_HBM_axi_ar(i).valid,
            o_logic_axi_arready     => logic_HBM_axi_arready(i),
    
            -- DATA
            o_logic_axi_r_data      => logic_HBM_axi_r(i).data,
            o_logic_axi_r_resp      => logic_HBM_axi_r(i).resp,
            o_logic_axi_r_last      => logic_HBM_axi_r(i).last,
            o_logic_axi_r_valid     => logic_HBM_axi_r(i).valid,
            i_logic_axi_rready      => logic_HBM_axi_rready(i)
        
        );
        
        -- register slice ports that have a fixed value.
        HBM_axi_awsize(i)  <= get_axi_size(HBM_DATA_WIDTH);
        HBM_axi_awburst(i) <= "01";   -- "01" indicates incrementing addresses for each beat in the burst.  -- out std_logic_vector(1 downto 0);
        HBM_axi_bready(i)  <= '1';  -- Always accept acknowledgement of write transactions. -- out std_logic;
        HBM_axi_wstrb(i)  <= (others => '1');  -- We always write all bytes in the bus. --  out std_logic_vector(63 downto 0);
        HBM_axi_arsize(i)  <= get_axi_size(HBM_DATA_WIDTH);   -- 6 = 64 bytes per beat = 512 bit wide bus. -- out std_logic_vector(2 downto 0);
        HBM_axi_arburst(i) <= "01";    -- "01" = incrementing address for each beat in the burst. -- out std_logic_vector(1 downto 0);
        
        -- these have no ports on the axi register slice
        HBM_axi_arlock(i)   <= "00";
        HBM_axi_awlock(i)   <= "00";
        HBM_axi_awcache(i)  <= "0011";  -- out std_logic_vector(3 downto 0); bufferable transaction. Default in Vitis environment.
        HBM_axi_awprot(i)   <= "000";   -- Has no effect in Vitis environment. -- out std_logic_vector(2 downto 0);
        HBM_axi_awqos(i)    <= "0000";  -- Has no effect in vitis environment, -- out std_logic_vector(3 downto 0);
        HBM_axi_awregion(i) <= "0000"; -- Has no effect in Vitis environment. -- out std_logic_vector(3 downto 0);
        HBM_axi_arcache(i)  <= "0011";  -- out std_logic_vector(3 downto 0); bufferable transaction. Default in Vitis environment.
        HBM_axi_arprot(i)   <= "000";   -- Has no effect in vitis environment; out std_logic_Vector(2 downto 0);
        HBM_axi_arqos(i)    <= "0000"; -- Has no effect in vitis environment; out std_logic_vector(3 downto 0);
        HBM_axi_arregion(i) <= "0000"; -- Has no effect in vitis environment; out std_logic_vector(3 downto 0);
        HBM_axi_awid(i)(0) <= '0';   -- We only use a single ID -- out std_logic_vector(0 downto 0);
        HBM_axi_arid(i)(0) <= '0';     -- ID are not used. -- out std_logic_vector(0 downto 0);
        HBM_axi_bid(i)(0) <= '0';
        
        -- 3 GBytes second stage corner turn, one for each correlator cell
        HBM3G_2 : entity correlator_lib.HBM_axi_tbModel
        generic map (
            AXI_ADDR_WIDTH => 32, -- : integer := 32;   -- Byte address width. This also defines the amount of data. Use the correct width for the HBM memory block, e.g. 28 bits for 256 MBytes.
            AXI_ID_WIDTH => 1, -- integer := 1;
            AXI_DATA_WIDTH => 512, -- integer := 256;  -- Must be a multiple of 32 bits.
            READ_QUEUE_SIZE => 16, --  integer := 16;
            MIN_LAG => 60,  -- integer := 80   
            INCLUDE_PROTOCOL_CHECKER => TRUE,
            RANDSEED => 43526, -- : natural := 12345;
            LATENCY_LOW_PROBABILITY => 95, --  natural := 95;   -- probability, as a percentage, that non-zero gaps between read beats will be small (i.e. < 3 clocks)
            LATENCY_ZERO_PROBABILITY => 80 -- natural := 80   -- probability, as a percentage, that the gap between read beats will be zero.
        ) Port map (
            i_clk => clk300,
            i_rst_n => rst_n,
            axi_awaddr   => HBM_axi_aw(i).addr(31 downto 0),
            axi_awid     => HBM_axi_awid(i), -- in std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
            axi_awlen    => HBM_axi_aw(i).len,
            axi_awsize   => HBM_axi_awsize(i),
            axi_awburst  => HBM_axi_awburst(i),
            axi_awlock   => HBM_axi_awlock(i),
            axi_awcache  => HBM_axi_awcache(i),
            axi_awprot   => HBM_axi_awprot(i),
            axi_awqos    => HBM_axi_awqos(i), -- in(3:0)
            axi_awregion => HBM_axi_awregion(i), -- in(3:0)
            axi_awvalid  => HBM_axi_aw(i).valid,
            axi_awready  => HBM_axi_awready(i),
            axi_wdata    => HBM_axi_w(i).data,
            axi_wstrb    => HBM_axi_wstrb(i),
            axi_wlast    => HBM_axi_w(i).last,
            axi_wvalid   => HBM_axi_w(i).valid,
            axi_wready   => HBM_axi_wready(i),
            axi_bresp    => HBM_axi_b(i).resp,
            axi_bvalid   => HBM_axi_b(i).valid,
            axi_bready   => HBM_axi_bready(i),
            axi_bid      => HBM_axi_bid(i), -- out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
            axi_araddr   => HBM_axi_ar(i).addr(31 downto 0),
            axi_arlen    => HBM_axi_ar(i).len,
            axi_arsize   => HBM_axi_arsize(i),
            axi_arburst  => HBM_axi_arburst(i),
            axi_arlock   => HBM_axi_arlock(i),
            axi_arcache  => HBM_axi_arcache(i),
            axi_arprot   => HBM_axi_arprot(i),
            axi_arvalid  => HBM_axi_ar(i).valid,
            axi_arready  => HBM_axi_arready(i),
            axi_arqos    => HBM_axi_arqos(i),
            axi_arid     => HBM_axi_arid(i),
            axi_arregion => HBM_axi_arregion(i),
            axi_rdata    => HBM_axi_r(i).data,
            axi_rresp    => HBM_axi_r(i).resp,
            axi_rlast    => HBM_axi_r(i).last,
            axi_rvalid   => HBM_axi_r(i).valid,
            axi_rready   => HBM_axi_rready(i),
            i_write_to_disk => '0', -- in std_logic;
            i_fname         => "",  -- in string
            i_write_to_disk_addr => 0, -- g_CT2_HBM_DUMP_ADDR,     -- in integer; Address to start the memory dump at.
            i_write_to_disk_size => 0, -- g_CT2_HBM_DUMP_SIZE, -- in integer; Size in bytes
            -- Initialisation of the memory
            -- The memory is loaded with the contents of the file i_init_fname in 
            -- any clock cycle where i_init_mem is high.
            i_init_mem   => '0', -- load_ct2_HBM_corr(i), -- in std_logic;
            i_init_fname => "" -- g_TEST_CASE & g_CT2_HBM_CORR1_FILENAME  -- in string
        );
    
    end generate;
    
-- write CT1 output to a file
--    process
--		file logfile: TEXT;
--		--variable data_in : std_logic_vector((BIT_WIDTH-1) downto 0);
--		variable line_out : Line;
--    begin
--	    FILE_OPEN(logfile, g_CT1_OUT_FILENAME, WRITE_MODE);
--		loop
--            wait until rising_edge(clk300);
--            if fb_valid = '1' then
                
--                if fb_valid_del = '0' and fb_valid = '1' then
--                    -- Rising edge of fb_valid, write out the meta data
--                    line_out := "";
--                    hwrite(line_out,hex_one,RIGHT,1);
--                    hwrite(line_out,fb_meta01.HDeltaP,RIGHT,9);
--                    hwrite(line_out,fb_meta01.HOffsetP,RIGHT,9);
--                    hwrite(line_out,fb_meta01.VDeltaP,RIGHT,9);
--                    hwrite(line_out,fb_meta01.VOffsetP,RIGHT,9);
--                    hwrite(line_out,fb_meta01.integration,RIGHT,9);
--                    hwrite(line_out,"00" & fb_meta01.ctFrame,RIGHT,2);
--                    hwrite(line_out,fb_meta01.virtualChannel,RIGHT,5);
--                    writeline(logfile,line_out);
                    
--                    line_out := "";
--                    hwrite(line_out,hex_two,RIGHT,1);
--                    hwrite(line_out,fb_meta23.HDeltaP,RIGHT,9);
--                    hwrite(line_out,fb_meta23.HOffsetP,RIGHT,9);
--                    hwrite(line_out,fb_meta23.VDeltaP,RIGHT,9);
--                    hwrite(line_out,fb_meta23.VOffsetP,RIGHT,9);
--                    hwrite(line_out,fb_meta23.integration,RIGHT,9);
--                    hwrite(line_out,"00" & fb_meta23.ctFrame,RIGHT,2);
--                    hwrite(line_out,fb_meta23.virtualChannel,RIGHT,5);
--                    writeline(logfile,line_out);
                    
--                    line_out := "";
--                    hwrite(line_out,hex_three,RIGHT,1);
--                    hwrite(line_out,fb_meta45.HDeltaP,RIGHT,9);
--                    hwrite(line_out,fb_meta45.HOffsetP,RIGHT,9);
--                    hwrite(line_out,fb_meta45.VDeltaP,RIGHT,9);
--                    hwrite(line_out,fb_meta45.VOffsetP,RIGHT,9);
--                    hwrite(line_out,fb_meta45.integration,RIGHT,9);
--                    hwrite(line_out,"00" & fb_meta45.ctFrame,RIGHT,2);
--                    hwrite(line_out,fb_meta45.virtualChannel,RIGHT,5);
--                    writeline(logfile,line_out);
                    
--                    line_out := "";
--                    hwrite(line_out,hex_four,RIGHT,1);
--                    hwrite(line_out,fb_meta67.HDeltaP,RIGHT,9);
--                    hwrite(line_out,fb_meta67.HOffsetP,RIGHT,9);
--                    hwrite(line_out,fb_meta67.VDeltaP,RIGHT,9);
--                    hwrite(line_out,fb_meta67.VOffsetP,RIGHT,9);
--                    hwrite(line_out,fb_meta67.integration,RIGHT,9);
--                    hwrite(line_out,"00" & fb_meta67.ctFrame,RIGHT,2);
--                    hwrite(line_out,fb_meta67.virtualChannel,RIGHT,5);
--                    writeline(logfile,line_out);
                    
--                end if;
                
--                -- write out the samples to the file
--                line_out := "";
--                hwrite(line_out,hex_five,RIGHT,1);
--                hwrite(line_out,fb_data0(0),RIGHT,3);
--                hwrite(line_out,fb_data0(1),RIGHT,3);
--                hwrite(line_out,fb_data1(0),RIGHT,3);
--                hwrite(line_out,fb_data1(1),RIGHT,3);
--                hwrite(line_out,fb_data2(0),RIGHT,3);
--                hwrite(line_out,fb_data2(1),RIGHT,3);
--                hwrite(line_out,fb_data3(0),RIGHT,3);
--                hwrite(line_out,fb_data3(1),RIGHT,3);
                
--                hwrite(line_out,fb_data4(0),RIGHT,3);
--                hwrite(line_out,fb_data4(1),RIGHT,3);
--                hwrite(line_out,fb_data5(0),RIGHT,3);
--                hwrite(line_out,fb_data5(1),RIGHT,3);
--                hwrite(line_out,fb_data6(0),RIGHT,3);
--                hwrite(line_out,fb_data6(1),RIGHT,3);
--                hwrite(line_out,fb_data7(0),RIGHT,3);
--                hwrite(line_out,fb_data7(1),RIGHT,3);
--                writeline(logfile,line_out);
--            end if;
         
--        end loop;
--        file_close(logfile);	
--        wait;
--    end process;

end Behavioral;
