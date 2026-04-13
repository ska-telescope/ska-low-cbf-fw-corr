----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey
-- 
-- Create Date: 08/14/2023 10:14:24 PM
-- Module Name: ct1_tb - Behavioral
-- Description: 
--  Standalone testbench for correlator corner turn 2
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

entity ct2_v80_tb is
    generic(
        g_PACKET_GAP : integer := 4100; -- number of clocks from the start of one filterbank packet to the start of the next 
        g_VC_GAP : integer := 20000;   -- number of clocks idle between groups of 12 virtual channels from the filterbank
        g_CORRELATOR_CORES : integer := 1;
        g_TEST_CASE : integer := 4 -- selects a set of register transactions and other configuration to use in the test.
        -- 
    );
end ct2_v80_tb;

architecture Behavioral of ct2_v80_tb is

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
    constant HBM_DATA_WIDTH : integer := 256;


    procedure noc_write(signal clk : in std_logic;
                        signal noc_wren : out std_logic;
                        signal noc_wrAddr : out std_logic_vector(17 downto 0);  -- address in units of 4-byte words
                        signal noc_wrData : out std_logic_vector(31 downto 0);
                        register_addr : natural;  -- Also address in units of 4-byte words
                        wr_data : std_logic_vector(31 downto 0)) is

    begin
        wait until rising_edge(clk);
        noc_wren <= '1';
        noc_wrAddr <= std_logic_vector(to_unsigned(register_addr, 18));
        noc_wrData <= wr_data;
        wait until rising_edge(clk);
        noc_wren <= '0';
        wait until rising_edge(clk);
        
    end procedure;
    
    
-- for i in 0 to 19 loop
--                readline(regCmdFile, regLine_in);
--                hread(regLine_in,regData,regGood);
--                noc_wren <= '1';
--                regAddr := std_logic_vector(unsigned(regAddr_4byte_base) + i);
--                noc_wr_adr <= regAddr; -- The address from the file is a byte address, noc address is 4-byte words
--                noc_wr_dat <= regData;
--                noc_wren <= '1';
--                wait until rising_edge(clk300);
--                wait for 1 ps;
--            end loop;
--            noc_wren <= '0';




    signal HBM_axi_aw, HBM_axi_vis_aw : t_axi4_full_addr_arr(1 downto 0); -- write address bus : out t_axi4_full_addr_arr(4 downto 0)(.valid, .addr(39:0), .len(7:0))
    signal HBM_axi_awready, HBM_axi_vis_awready : std_logic_vector(1 downto 0);
    signal HBM_axi_w, HBM_axi_vis_w : t_axi4_full_data_arr(1 downto 0); -- w data bus : out t_axi4_full_data_arr(4 downto 0)(.valid, .data(511:0), .last, .resp(1:0))
    signal HBM_axi_wready, HBM_axi_vis_wready : std_logic_vector(1 downto 0);
    signal HBM_axi_b, HBM_axi_vis_b :  t_axi4_full_b_arr(1 downto 0);     -- write response bus : in t_axi4_full_b_arr(4 downto 0)(.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
    signal HBM_axi_ar, HBM_axi_vis_ar :  t_axi4_full_addr_arr(1 downto 0); -- read address bus : out t_axi4_full_addr_arr(4 downto 0)(.valid, .addr(39:0), .len(7:0))
    signal HBM_axi_arready, HBM_axi_vis_arready : std_logic_vector(1 downto 0);
    signal HBM_axi_r, HBM_axi_vis_r :  t_axi4_full_data_arr(1 downto 0);  -- r data bus : in t_axi4_full_data_arr(4 downto 0)(.valid, .data(511:0), .last, .resp(1:0))
    signal HBM_axi_rready, HBM_axi_vis_rready : std_logic_vector(1 downto 0);
    
    signal send_fb_data : std_logic := '0';
    
    type t_fb_fsm is (wait_sof, send_sof, send_sof_wait, send_data0, send_Data, packet_gap, new_vc_gap, frame_gap);
    signal fb_fsm : t_fb_fsm := wait_sof;
    
    signal fb_sof, fb_dataValid : std_logic;
    signal fb_headerValid : std_logic_vector(11 downto 0);
    signal fb_virtualChannel : t_slv_16_arr(11 downto 0);
    signal fb_count_slv : std_logic_vector(15 downto 0);
    signal packets_sent_slv : std_logic_vector(15 downto 0);
    signal fb_data : t_ctc_output_payload_arr(11 downto 0);
    signal cor_ready : std_logic_vector(1 downto 0);
    signal hbm_reset_final : std_logic := '0';
    
    signal hbm_status : t_slv_8_arr(1 downto 0);
    signal hbm_rst_dbg : t_slv_32_arr(1 downto 0);
    
    signal HBM_axi_awsize, HBM_axi_vis_awsize, HBM_axi_arprot, HBM_axi_vis_arprot, HBM_axi_awprot, HBM_axi_vis_awprot : t_slv_3_arr(1 downto 0);
    signal HBM_axi_awburst, HBM_axi_vis_awburst : t_slv_2_arr(1 downto 0);
    signal HBM_axi_bready, HBM_axi_vis_bready : std_logic_vector(1 downto 0);
    signal HBM_axi_wstrb, HBM_axi_vis_wstrb : t_slv_64_arr(1 downto 0);
    signal HBM_axi_arsize, HBM_axi_vis_arsize : t_slv_3_arr(1 downto 0);
    signal HBM_axi_arburst, HBM_axi_vis_arburst, HBM_axi_arlock, HBM_axi_vis_arlock, HBM_axi_awlock, HBM_axi_vis_awlock : t_slv_2_arr(1 downto 0);
    signal HBM_axi_awcache, HBM_axi_vis_awcache, HBM_axi_awqos, HBM_axi_vis_awqos, HBM_axi_arqos, HBM_axi_vis_arqos, HBM_axi_arregion, HBM_axi_vis_arregion, HBM_axi_awregion, HBM_axi_vis_awregion, HBM_axi_arcache, HBM_axi_vis_arcache : t_slv_4_arr(1 downto 0);
    signal HBM_axi_awid, HBM_axi_vis_awid, HBM_axi_arid, HBM_axi_vis_arid, HBM_axi_bid, HBM_axi_vis_bid : t_slv_1_arr(1 downto 0);
    
    signal clk300, clk300_rst, data_rst : std_logic := '0';
    signal clk400 : std_logic := '0';
    signal virtual_channels : std_logic_vector(10 downto 0);
    
    signal write_HBM_to_disk2, init_mem2 : std_logic := '0';
    signal fb_count : integer := 0;
    signal fb_integration : std_logic_vector(31 downto 0) := (others => '0');
    signal fb_ctFrame : std_logic_vector(1 downto 0) := "00";
    signal fb_vc0 : std_logic_vector(15 downto 0) := (others => '0');
    signal packets_sent : integer := 0;
    signal rst_n : std_logic;
    signal fb_bad_poly : std_logic_vector(11 downto 0);
    
    signal bad_poly_packets_sent : integer;
    signal bad_poly_integration : std_logic_vector(31 downto 0);
    signal bad_poly_ctFrame : std_logic_vector(1 downto 0);
    signal bad_poly_vc : std_logic_vector(15 downto 0);
    signal c_VIRTUAL_CHANNELS : integer := 0;
    signal fb_lastChannel : std_logic;
    signal fb_demap_table_select : std_logic;
    
    signal dummy_slv32 : std_logic_vector(31 downto 0);
    signal dummy_slv8_zeros : t_slv_8_arr(5 downto 0);
    
    signal noc_wr_adr, noc_rd_adr : std_logic_vector(17 downto 0);
    signal noc_wr_dat, noc_rd_dat : std_logic_vector(31 downto 0);
    signal noc_wren : std_logic;
    signal noc_rden : std_logic;
    signal dummy_slv8 : std_logic_vector(7 downto 0);
    
    signal cor_cfg_data : t_slv_8_arr(5 downto 0); -- 8 bit wide buses, to 6 correlators.
    signal cor_cfg_first : std_logic_vector(5 downto 0);
    signal cor_cfg_last : std_logic_vector(5 downto 0);
    signal cor_cfg_valid : std_logic_vector(5 downto 0);
    signal clk400_rst : std_logic := '0';
    
    signal ro_FIFO_din : t_slv_128_arr(5 downto 0);
    signal ro_FIFO_wrEn : std_logic_vector(5 downto 0);
    signal ro_stall : std_logic_vector(5 downto 0);
    
begin
    
    clk300 <= not clk300 after 1.666 ns;
    clk400 <= not clk400 after 1.25 ns;
    rst_n <= not clk300_rst;
    
    process
    begin
        clk400_rst <= '0';
        for i in 1 to 10 loop
            wait until rising_edge(clk400);
        end loop;
        clk400_rst <= '1';
        wait until rising_edge(clk400);
        wait until rising_edge(clk400);
        clk400_rst <= '0';
        wait until rising_edge(clk400);
        wait;
    end process;
    
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
        send_fb_data <= '0';
        clk300_rst <= '0';
        hbm_reset_final <= '0';
        fb_demap_table_select <= '0';
        noc_wr_adr <= (others => '0');
        noc_rd_adr <= (others => '0');
        noc_wr_dat <= (others => '0');
        noc_wren <= '0';
        noc_rden <= '0';
        
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
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_buf0_subarray_beams_table0_address.base_address + c_statctrl_buf0_subarray_beams_table0_address.address, x"00000001");
            -- 0 subarray-beams in table 1
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_buf0_subarray_beams_table1_address.base_address + c_statctrl_buf0_subarray_beams_table1_address.address, x"00000000");
            -- 0 subarray-beams for second correlator, table 0
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_buf1_subarray_beams_table0_address.base_address + c_statctrl_buf1_subarray_beams_table0_address.address, x"00000000");
            -- 0 subarray-beams for second correlator, table 1
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_buf1_subarray_beams_table1_address.base_address + c_statctrl_buf1_subarray_beams_table1_address.address, x"00000000"); 
            
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
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 0, x"99000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 1, x"00000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 2, x"99000400");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 3, x"00000000");
            -- subarray beam table
            -- Word 0 : bits(15:0) = number of (sub)stations in this subarray-beam, \
            --          bits(31:16) = starting coarse frequency channel, \
            -- Word 1 : bits (15:0) = starting fine frequency channel \
            -- Word 2 : bits (23:0) = Number of fine channels stored \
            --          bits (30:24) = Fine channels per integration \
            --          bit  (31) = integration time; 0 = 283 ms, 1 = 849 ms \
            -- Word 3 : bits (31:0) = Base Address in HBM within a 1.5 Gbyte block to store channelised source data for this subarray-beam \
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 0, x"01900008");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 1, x"00000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 2, x"98000D80");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 3, x"00000000");
            
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
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_buf0_subarray_beams_table0_address.base_address + c_statctrl_buf0_subarray_beams_table0_address.address, x"00000001");
            -- 0 subarray-beams in table 1
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_buf0_subarray_beams_table1_address.base_address + c_statctrl_buf0_subarray_beams_table1_address.address, x"00000000");
            -- 1 subarray-beams for second correlator, table 0
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_buf1_subarray_beams_table0_address.base_address + c_statctrl_buf1_subarray_beams_table0_address.address, x"00000001");
            -- 0 subarray-beams for second correlator, table 1
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_buf1_subarray_beams_table1_address.base_address + c_statctrl_buf1_subarray_beams_table1_address.address, x"00000000");
            
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
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 0, x"99000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 1, x"00000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 2, x"99100080");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 3, x"00000000");
            -- subarray beam table
            -- Word 0 : bits(15:0) = number of (sub)stations in this subarray-beam, \
            --          bits(31:16) = starting coarse frequency channel, \
            -- Word 1 : bits (15:0) = starting fine frequency channel \
            -- Word 2 : bits (23:0) = Number of fine channels stored \
            --          bits (30:24) = Fine channels per integration \
            --          bit  (31) = integration time; 0 = 283 ms, 1 = 849 ms \
            -- Word 3 : bits (31:0) = Base Address in HBM within a 1.5 Gbyte block to store channelised source data for this subarray-beam \
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 0, x"01900004");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 1, x"00000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 2, x"98000D80");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 3, x"00000000");
            -- configure second correlator
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 512 + 0, x"01910004");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 512 + 1, x"00000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 512 + 2, x"98000D80");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 512 + 3, x"00000000");
            
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
            -- 2 subarray-beams in table 0
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_buf0_subarray_beams_table0_address.base_address + c_statctrl_buf0_subarray_beams_table0_address.address, x"00000002");
            -- 0 subarray-beams in table 1
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_buf0_subarray_beams_table1_address.base_address + c_statctrl_buf0_subarray_beams_table1_address.address, x"00000000");
            -- 0 subarray-beams for second correlator, table 0
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_buf1_subarray_beams_table0_address.base_address + c_statctrl_buf1_subarray_beams_table0_address.address, x"00000000");
            -- 0 subarray-beams for second correlator, table 1
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_buf1_subarray_beams_table1_address.base_address + c_statctrl_buf1_subarray_beams_table1_address.address, x"00000000");
            
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
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 0, x"99000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 1, x"00000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 2, x"99100001");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 3, x"00000000");
            
            -- subarray beam table
            -- Word 0 : bits(15:0) = number of (sub)stations in this subarray-beam, \
            --          bits(31:16) = starting coarse frequency channel, \
            -- Word 1 : bits (15:0) = starting fine frequency channel \
            -- Word 2 : bits (23:0) = Number of fine channels stored \
            --          bits (30:24) = Fine channels per integration \
            --          bit  (31) = integration time; 0 = 283 ms, 1 = 849 ms \
            -- Word 3 : bits (31:0) = Base Address in HBM within a 1.5 Gbyte block to store channelised source data for this subarray-beam \
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 0, x"01900004");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 1, x"00000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 2, x"98000D80");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 3, x"00000000");
            -- configure second subarray beam (still for first correlator)
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 0, x"01910004");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 1, x"00000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 2, x"98000D80");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 3, x"00000000");
            
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
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_buf0_subarray_beams_table0_address.base_address + c_statctrl_buf0_subarray_beams_table0_address.address, x"00000002");
            -- 0 subarray-beams in table 1
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_buf0_subarray_beams_table1_address.base_address + c_statctrl_buf0_subarray_beams_table1_address.address, x"00000000");
            -- 1 subarray-beams for second correlator, table 0
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_buf1_subarray_beams_table0_address.base_address + c_statctrl_buf1_subarray_beams_table0_address.address, x"00000001");
            -- 0 subarray-beams for second correlator, table 1
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_buf1_subarray_beams_table1_address.base_address + c_statctrl_buf1_subarray_beams_table1_address.address, x"00000000");
            
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
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 0, x"99000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 1, x"00000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 2, x"99100001");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 3, x"00000000");
            -- subarray beam table
            -- Word 0 : bits(15:0) = number of (sub)stations in this subarray-beam, \
            --          bits(31:16) = starting coarse frequency channel, \
            -- Word 1 : bits (15:0) = starting fine frequency channel \
            -- Word 2 : bits (23:0) = Number of fine channels stored \
            --          bits (30:24) = Fine channels per integration \
            --          bit  (31) = integration time; 0 = 283 ms, 1 = 849 ms \
            -- Word 3 : bits (31:0) = Base Address in HBM within a 1.5 Gbyte block to store channelised source data for this subarray-beam
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 0, x"01900004");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 1, x"00000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 2, x"98000D80");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 3, x"00000000");
            -- configure second subarray beam (still for first correlator)
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 0, x"01910004");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 1, x"00000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 2, x"98000D80");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 3, x"00000000");
            
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
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 512 + 0, x"99000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 512 + 1, x"00000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 512 + 2, x"99100001");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 512 + 3, x"00000000");
            
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4096 + 0, x"01900004");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4096 + 1, x"00000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4096 + 2, x"98000D80");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4096 + 3, x"00000000");
            -- configure second subarray beam (still for first correlator)
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4096 + 4 + 0, x"01910004");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4096 + 4 + 1, x"00000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4096 + 4 + 2, x"98000D80");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4096 + 4 + 3, x"00000000");
            
            -- 2 subarray-beams in table 1
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat,      c_statctrl_buf0_subarray_beams_table1_address.base_address + c_statctrl_buf0_subarray_beams_table1_address.address, x"00000002");
            -- 1 subarray-beams for second correlator, table 1
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat,      c_statctrl_buf1_subarray_beams_table1_address.base_address + c_statctrl_buf1_subarray_beams_table1_address.address, x"00000001");
            
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
            bad_poly_vc <= x"0001";  -- bad poly is somewhere in the second subarray-beam
            
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_buf0_subarray_beams_table0_address.base_address + c_statctrl_buf0_subarray_beams_table0_address.address, x"00000001");
            -- 0 subarray-beams in table 1
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_buf0_subarray_beams_table1_address.base_address + c_statctrl_buf0_subarray_beams_table1_address.address, x"00000000");
            -- 1 subarray-beams for second correlator, table 0
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_buf1_subarray_beams_table0_address.base_address + c_statctrl_buf1_subarray_beams_table0_address.address, x"00000000");
            -- 0 subarray-beams for second correlator, table 1
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_buf1_subarray_beams_table1_address.base_address + c_statctrl_buf1_subarray_beams_table1_address.address, x"00000000");
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
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 0, x"86400000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 1, x"00000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 2, x"00000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_vc_demap_address.base_address + c_statctrl_vc_demap_address.address + 3, x"00000000");
            
            -- subarray beam table
            -- Word 0 : bits(15:0) = number of (sub)stations in this subarray-beam, \
            --          bits(31:16) = starting coarse frequency channel, \
            -- Word 1 : bits (15:0) = starting fine frequency channel \
            -- Word 2 : bits (23:0) = Number of fine channels stored \
            --          bits (30:24) = Fine channels per integration \
            --          bit  (31) = integration time; 0 = 283 ms, 1 = 849 ms \
            -- Word 3 : bits (31:0) = Base Address in HBM within a 1.5 Gbyte block to store channelised source data for this subarray-beam
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 0, x"00640001");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 1, x"000006BA");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 2, x"8200000C");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 3, x"00000000");
            -- configure second subarray beam (still for first correlator)
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 0, x"00000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 1, x"00000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 2, x"00000000");
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat, c_statctrl_subarray_beam_address.base_address + c_statctrl_subarray_beam_address.address + 4 + 3, x"00000000");
            
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
                                if (unsigned(fb_vc0) + 12) > (c_VIRTUAL_CHANNELS-1) then
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
                                    -- Go to the next set of 12 virtual channels
                                    fb_vc0 <= std_logic_vector(unsigned(fb_vc0) + 12);
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
    fb_virtualChannel(4) <= std_logic_vector(unsigned(fb_vc0) + 4);
    fb_virtualChannel(5) <= std_logic_vector(unsigned(fb_vc0) + 5);
    fb_virtualChannel(6) <= std_logic_vector(unsigned(fb_vc0) + 6);
    fb_virtualChannel(7) <= std_logic_vector(unsigned(fb_vc0) + 7);
    fb_virtualChannel(8) <= std_logic_vector(unsigned(fb_vc0) + 8);
    fb_virtualChannel(9) <= std_logic_vector(unsigned(fb_vc0) + 9);
    fb_virtualChannel(10) <= std_logic_vector(unsigned(fb_vc0) + 10);
    fb_virtualChannel(11) <= std_logic_vector(unsigned(fb_vc0) + 11);
    fb_bad_poly(0) <= '1' when fb_dataValid = '1' and fb_vc0 = bad_poly_vc and fb_ctFrame = bad_poly_ctFrame and fb_integration = bad_poly_integration and packets_sent = bad_poly_packets_sent else '0';
    fb_bad_poly(1) <= '1' when fb_dataValid = '1' and fb_virtualChannel(1) = bad_poly_vc and fb_ctFrame = bad_poly_ctFrame and fb_integration = bad_poly_integration and packets_sent = bad_poly_packets_sent else '0';
    fb_bad_poly(2) <= '1' when fb_dataValid = '1' and fb_virtualChannel(2) = bad_poly_vc and fb_ctFrame = bad_poly_ctFrame and fb_integration = bad_poly_integration and packets_sent = bad_poly_packets_sent else '0';
    fb_bad_poly(3) <= '1' when fb_dataValid = '1' and fb_virtualChannel(3) = bad_poly_vc and fb_ctFrame = bad_poly_ctFrame and fb_integration = bad_poly_integration and packets_sent = bad_poly_packets_sent else '0';
    fb_bad_poly(4) <= '1' when fb_dataValid = '1' and fb_virtualChannel(4) = bad_poly_vc and fb_ctFrame = bad_poly_ctFrame and fb_integration = bad_poly_integration and packets_sent = bad_poly_packets_sent else '0';
    fb_bad_poly(5) <= '1' when fb_dataValid = '1' and fb_virtualChannel(5) = bad_poly_vc and fb_ctFrame = bad_poly_ctFrame and fb_integration = bad_poly_integration and packets_sent = bad_poly_packets_sent else '0';
    fb_bad_poly(6) <= '1' when fb_dataValid = '1' and fb_virtualChannel(6) = bad_poly_vc and fb_ctFrame = bad_poly_ctFrame and fb_integration = bad_poly_integration and packets_sent = bad_poly_packets_sent else '0';
    fb_bad_poly(7) <= '1' when fb_dataValid = '1' and fb_virtualChannel(7) = bad_poly_vc and fb_ctFrame = bad_poly_ctFrame and fb_integration = bad_poly_integration and packets_sent = bad_poly_packets_sent else '0';
    fb_bad_poly(8) <= '1' when fb_dataValid = '1' and fb_virtualChannel(8) = bad_poly_vc and fb_ctFrame = bad_poly_ctFrame and fb_integration = bad_poly_integration and packets_sent = bad_poly_packets_sent else '0';
    fb_bad_poly(9) <= '1' when fb_dataValid = '1' and fb_virtualChannel(9) = bad_poly_vc and fb_ctFrame = bad_poly_ctFrame and fb_integration = bad_poly_integration and packets_sent = bad_poly_packets_sent else '0';
    fb_bad_poly(10) <= '1' when fb_dataValid = '1' and fb_virtualChannel(10) = bad_poly_vc and fb_ctFrame = bad_poly_ctFrame and fb_integration = bad_poly_integration and packets_sent = bad_poly_packets_sent else '0';
    fb_bad_poly(11) <= '1' when fb_dataValid = '1' and fb_virtualChannel(11) = bad_poly_vc and fb_ctFrame = bad_poly_ctFrame and fb_integration = bad_poly_integration and packets_sent = bad_poly_packets_sent else '0';
    
    fb_headerValid <= "111111111111" when fb_fsm = send_data0 else "000000000000"; --  -- in std_logic_vector(3 downto 0);
    -- in the data - fb_count = fine channel, 0 to 3455
    -- packet in frame, 0 to 63,
    -- ct_frame, 0 to 2
    -- fb_integration 32 bit value
    -- virtual channel, 0 to 1023
    --
    fb_count_slv <= std_logic_vector(to_unsigned(fb_count,16));
    packets_sent_slv <= std_logic_vector(to_unsigned(packets_sent,16));
    
    fb_datageni : for i in 0 to 11 generate
        fb_data(i).Hpol.re <= fb_count_slv(7 downto 0); -- in t_ctc_output_payload_arr(3 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), i_data(2), i_data(3)
        fb_data(i).Hpol.im(3 downto 0) <= fb_count_slv(11 downto 8);
        fb_data(i).Hpol.im(7 downto 4) <= fb_integration(3 downto 0);
        fb_data(i).Vpol.re(5 downto 0) <= packets_sent_slv(5 downto 0);
        fb_data(i).Vpol.re(7 downto 6) <= fb_ctFrame(1 downto 0);
        fb_data(i).Vpol.im <= fb_virtualChannel(i)(7 downto 0);
    end generate;
    
    fb_dataValid <= '1' when fb_fsm = send_data0 or fb_fsm = send_data else '0'; -- in std_logic;
    
    fb_lastChannel <= '1' when (unsigned(fb_vc0) + 12) > (c_VIRTUAL_CHANNELS-1) else '0';
    
    

    ct2topi : entity ct_lib.corr_ct2_top_v80
    generic map (
        g_USE_META   => false,    -- boolean := FALSE; Put meta data into the memory in place of the actual data, to make it easier to find bugs in the corner turn.
        g_MAX_CORRELATORS => 6,   -- integer := 6; Maximum number of correlator cells that can be instantiated.
        g_GENERATE_ILA => false   -- BOOLEAN := FALSE
    ) port map(
        -- Registers AXI Lite Interface (uses i_axi_clk)
        i_axi_clk  => clk300,     -- in std_logic;
        i_axi_rst  => clk300_rst, -- in std_logic;
        -- Pipelined reset from first stage corner turn
        i_rst  => clk300_rst, --  in std_logic;   -- First data received after this reset is placed in the first 283ms block in a 849 ms integration.
        -- Registers NOC interface
        i_noc_wren    => noc_wren, -- in STD_LOGIC;
        i_noc_rden    => noc_rden, -- in STD_LOGIC;
        i_noc_wr_adr  => noc_wr_adr, -- in STD_LOGIC_VECTOR(17 DOWNTO 0);
        i_noc_wr_dat  => noc_wr_dat, -- in STD_LOGIC_VECTOR(31 DOWNTO 0);
        i_noc_rd_adr  => noc_rd_adr, -- in STD_LOGIC_VECTOR(17 DOWNTO 0);
        o_noc_rd_dat  => noc_rd_dat, -- out STD_LOGIC_VECTOR(31 DOWNTO 0);
        -------------------------------------------------------------------------------------
        -- hbm reset   
        o_hbm_reset_c1  => open, --  out std_logic;
        i_hbm_status_c1 => dummy_slv8, -- in (7:0);
        o_hbm_reset_c2  => open, -- out std_logic;
        i_hbm_status_c2 => dummy_slv8, -- in (7:0);
        ------------------------------------------------------------------------------------
        -- Data in from the correlator filterbanks; bursts of 3456 clocks for each channel.
        -- (on i_axi_clk)
        i_sof          => fb_sof,              -- in std_logic; pulse high at the start of every frame. (1 frame is 283 ms of data).
        i_integration  => fb_integration,      -- in (31:0); frame count is the same for all simultaneous output streams.
        i_ctFrame      => fb_ctFrame,          -- in (1:0);  283 ms frame within each integration interval
        i_virtualChannel => fb_virtualChannel, -- in t_slv_16_arr(11 downto 0); 12 virtual channels, one for each of the data streams.
        i_bad_poly     => fb_bad_poly,         -- in (11:0); one bit for each virtual channel
        i_lastChannel  => fb_lastChannel,      -- in std_logic; last of the group of 4 channels
        i_demap_table_select => fb_demap_table_select, -- in std_logic;
        i_HeaderValid => fb_headerValid,       -- in (11:0);
        i_data        => fb_data,              -- in t_ctc_output_payload_arr(11 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), ..., i_data(11)
        i_dataValid   => fb_dataValid,         -- in std_logic;
        ---------------------------------------------------------------
        -- Data out to the correlator arrays
        -- packets of data to each correlator instance
        -- Sends a single packet full of instructions to each correlator, at the start of each 849ms corner turn frame readout.
        -- The first byte sent is the number of subarray-beams configured
        -- The remaining (128 subarray-beams) * (4 words/subarray-beam) * (4 bytes/word) = 2048 bytes contains the subarray-beam table for the correlator
        -- The LSB of the 4th word contains the bad_poly bit for the subarray beam.
        -- The correlator should use (o_cor_cfg_last and o_cor_cfg_valid) to trigger processing 849ms of data.
        o_cor_cfg_data  => cor_cfg_data,  -- out t_slv_8_arr(5 downto 0); -- 8 bit wide buses, to 6 correlators.
        o_cor_cfg_first => cor_cfg_first, -- out std_logic_vector(5 downto 0);
        o_cor_cfg_last  => cor_cfg_last,  -- out std_logic_vector(5 downto 0);
        o_cor_cfg_valid => cor_cfg_valid, -- out std_logic_vector(5 downto 0);
        -----------------------------------------------------------------
        -- AXI interface to the HBM
        -- Corner turn between filterbanks and correlator
        -- Expected to be up to 18 Gbyte of unified memory used by the correlators
        o_HBM_axi_aw      => HBM_axi_aw,      -- out t_axi4_full_addr_arr(1 downto 0); -- write address bus : out t_axi4_full_addr_arr(4 downto 0)(.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_awready => HBM_axi_awready, -- in std_logic_vector(1 downto 0);
        o_HBM_axi_w       => HBM_axi_w,       -- out t_axi4_full_data_arr(1 downto 0); -- w data bus : out t_axi4_full_data_arr(4 downto 0)(.valid, .data(511:0), .last, .resp(1:0))
        i_HBM_axi_wready  => HBM_axi_wready,  -- in std_logic_vector(1 downto 0);
        i_HBM_axi_b       => HBM_axi_b,       -- in t_axi4_full_b_arr(1 downto 0);     -- write response bus : in t_axi4_full_b_arr(4 downto 0)(.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        
        -- signals used in testing to initiate readout of the buffer when HBM is preloaded with data,
        -- so we don't have to wait for the previous processing stages to complete.
        i_readout_start  => '0', --  in std_logic;
        i_readout_buffer => '0', -- in std_logic;
        i_readout_frameCount => (others => '0'), -- in std_logic_vector(31 downto 0);
        i_freq_index0_repeat => '0', --  in std_logic;
        -- debug
        i_hbm_status  => dummy_slv8_zeros, -- in t_slv_8_arr(5 downto 0);
        i_hbm_reset_final => '0', --  in std_logic;
        i_eth_disable_fsm_dbg => "00000", --  in std_logic_vector(4 downto 0);
        --
        i_hbm0_rst_dbg => dummy_slv32, -- in std_logic_vector(31 downto 0);
        i_hbm1_rst_dbg => dummy_slv32  -- in std_logic_vector(31 downto 0);
    );    
    dummy_slv8 <= (others => '0');
    dummy_slv32 <= (others => '0');
    dummy_slv8_zeros <= (others => (others => '0'));
    
    --------------------------------------------------------------------------------------------------------
    -- Testbench allows for up to 2 correlator cores
    -- beyond that it would need an extra interface into the "HBM_axi_TwoInterface_tbModel"
    corr_geni : for i in 0 to (g_CORRELATOR_CORES-1) generate
        cori : entity correlator_lib.correlator_top_v80
        generic map (
            g_CORRELATOR_INSTANCE => i -- integer; unique ID for this correlator instance
        ) port map (
            -- clock used for all data input and output from this module (300 MHz)
            i_axi_clk => clk300, -- in std_logic;
            i_axi_rst => clk300_rst, -- in std_logic;
            -- Processing clock used for the correlation (>412.5 MHz)
            i_cor_clk => clk400, -- in std_logic;
            i_cor_rst => clk400_rst, -- in std_logic;
            ---------------------------------------------------------------------------
            -- AXI stream input with packets of control data from corner turn 2
            i_cor_cfg_data  => cor_cfg_data(i),  -- in (7:0);  8 bit wide bus
            i_cor_cfg_first => cor_cfg_first(i), -- in std_logic;
            i_cor_cfg_last  => cor_cfg_last(i),  -- in std_logic;
            i_cor_cfg_valid => cor_cfg_valid(i), -- in std_logic;
            ---------------------------------------------------------------------------
            -- 256 bit wide memory interface
            -- Read from HBM to go to the correlator
            o_HBM_axi_ar      => HBM_axi_ar(i), -- out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
            i_HBM_axi_arready => HBM_axi_arready(i), -- in  std_logic;
            i_HBM_axi_r       => HBM_axi_r(i),       -- in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
            o_HBM_axi_rready  => HBM_axi_rready(i),  -- out std_logic;
            -- write to HBM at the output of the correlator
            o_HBM_axi_aw      => HBM_axi_vis_aw(i),      -- out t_axi4_full_addr; -- write address bus (.valid, .addr(39:0), .len(7:0))
            i_HBM_axi_awready => HBM_axi_vis_awready(i), -- in  std_logic;
            o_HBM_axi_w       => HBM_axi_vis_w(i),       -- out t_axi4_full_data; -- w data bus (.valid, .data(511:0), .last, .resp(1:0))
            i_HBM_axi_wready  => HBM_axi_vis_wready(i),  -- in  std_logic;
            i_HBM_axi_b       => HBM_axi_vis_b(i),       -- in  t_axi4_full_b; -- write response bus (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
            ---------------------------------------------------------------
            -- Readout bus tells the packetiser what to do
            o_ro_data  => ro_FIFO_din(i),  -- out std_logic_vector(127 downto 0);
            o_ro_valid => ro_FIFO_wrEn(i), -- out std_logic;
            i_ro_stall => ro_stall(i),     -- in std_logic;
            ---------------------------------------------------------------
            -- Copy of the bus taking data to be written to the HBM,
            -- for the first correlator instance.
            -- Used for simulation only, to check against the model data.
            o_tb_data      => open, -- out std_logic_vector(255 downto 0);
            o_tb_visValid  => open, -- out std_logic; -- o_tb_data is valid visibility data
            o_tb_TCIvalid  => open, -- out std_logic; -- i_data is valid TCI & DV data
            o_tb_dcount    => open, -- out std_logic_vector(7 downto 0);  -- counts the 256 transfers for one cell of visibilites, or 16 transfers for the centroid data. 
            o_tb_cell      => open, -- out std_logic_vector(7 downto 0);  -- in (7:0);  -- a "cell" is a 16x16 station block of correlations
            o_tb_tile      => open, -- out std_logic_vector(9 downto 0);  -- a "tile" is a 16x16 block of cells, i.e. a 256x256 station correlation.
            o_tb_channel   => open, -- out std_logic_vector(23 downto 0); -- first fine channel index for this correlation.
            -- an old debug trigger I think
            o_freq_index0_repeat => open --: out std_logic
        );
        
        -- ro_stall comes from fifo half full in the full design
        ro_stall(i) <= '0';
        
        HBM1G_VIS : entity correlator_lib.HBM_axi_tbModel
        generic map (
            AXI_ADDR_WIDTH => 32, -- : integer := 32;   -- Byte address width. This also defines the amount of data. Use the correct width for the HBM memory block, e.g. 28 bits for 256 MBytes.
            AXI_ID_WIDTH => 1, -- integer := 1;
            AXI_DATA_WIDTH => 256, -- integer := 256;  -- Must be a multiple of 32 bits.
            READ_QUEUE_SIZE => 16, --  integer := 16;
            MIN_LAG => 60,  -- integer := 80   
            INCLUDE_PROTOCOL_CHECKER => TRUE,
            RANDSEED => 43526, -- : natural := 12345;
            LATENCY_LOW_PROBABILITY => 95,  -- natural := 95;   -- probability, as a percentage, that non-zero gaps between read beats will be small (i.e. < 3 clocks)
            LATENCY_ZERO_PROBABILITY => 80  -- natural := 80   -- probability, as a percentage, that the gap between read beats will be zero.
        ) Port map (
            i_clk => clk300,
            i_rst_n => rst_n,
            axi_awaddr   => HBM_axi_vis_aw(i).addr(31 downto 0),
            axi_awid     => HBM_axi_vis_awid(i), -- in std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
            axi_awlen    => HBM_axi_vis_aw(i).len,
            axi_awsize   => HBM_axi_vis_awsize(i),
            axi_awburst  => HBM_axi_vis_awburst(i),
            axi_awlock   => HBM_axi_vis_awlock(i),
            axi_awcache  => HBM_axi_vis_awcache(i),
            axi_awprot   => HBM_axi_vis_awprot(i),
            axi_awqos    => HBM_axi_vis_awqos(i), -- in(3:0)
            axi_awregion => HBM_axi_vis_awregion(i), -- in(3:0)
            axi_awvalid  => HBM_axi_vis_aw(i).valid,
            axi_awready  => HBM_axi_vis_awready(i),
            axi_wdata    => HBM_axi_vis_w(i).data(255 downto 0),
            axi_wstrb    => HBM_axi_vis_wstrb(i)(31 downto 0),
            axi_wlast    => HBM_axi_vis_w(i).last,
            axi_wvalid   => HBM_axi_vis_w(i).valid,
            axi_wready   => HBM_axi_vis_wready(i),
            axi_bresp    => HBM_axi_vis_b(i).resp,
            axi_bvalid   => HBM_axi_vis_b(i).valid,
            axi_bready   => HBM_axi_vis_bready(i),
            axi_bid      => HBM_axi_vis_bid(i), -- out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
            axi_araddr   => HBM_axi_vis_ar(i).addr(31 downto 0),
            axi_arlen    => HBM_axi_vis_ar(i).len,
            axi_arsize   => HBM_axi_vis_arsize(i),
            axi_arburst  => HBM_axi_vis_arburst(i),
            axi_arlock   => HBM_axi_vis_arlock(i),
            axi_arcache  => HBM_axi_vis_arcache(i),
            axi_arprot   => HBM_axi_vis_arprot(i),
            axi_arvalid  => HBM_axi_vis_ar(i).valid,
            axi_arready  => HBM_axi_vis_arready(i),
            axi_arqos    => HBM_axi_vis_arqos(i),
            axi_arid     => HBM_axi_vis_arid(i),
            axi_arregion => HBM_axi_vis_arregion(i),
            axi_rdata    => HBM_axi_vis_r(i).data(255 downto 0),
            axi_rresp    => HBM_axi_vis_r(i).resp,
            axi_rlast    => HBM_axi_vis_r(i).last,
            axi_rvalid   => HBM_axi_vis_r(i).valid,
            axi_rready   => HBM_axi_vis_rready(i),         
            --
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
    ----------------------------------------------------------------------------------------------------------------

    axi_HBM_gen : for i in 0 to 1 generate
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
        
        --
        HBM_axi_vis_awsize(i)  <= get_axi_size(HBM_DATA_WIDTH);
        HBM_axi_vis_awburst(i) <= "01";   -- "01" indicates incrementing addresses for each beat in the burst.  -- out std_logic_vector(1 downto 0);
        HBM_axi_vis_bready(i)  <= '1';  -- Always accept acknowledgement of write transactions. -- out std_logic;
        HBM_axi_vis_wstrb(i)  <= (others => '1');  -- We always write all bytes in the bus. --  out std_logic_vector(63 downto 0);
        HBM_axi_vis_arsize(i)  <= get_axi_size(HBM_DATA_WIDTH);   -- 6 = 64 bytes per beat = 512 bit wide bus. -- out std_logic_vector(2 downto 0);
        HBM_axi_vis_arburst(i) <= "01";    -- "01" = incrementing address for each beat in the burst. -- out std_logic_vector(1 downto 0);
        
        -- These have no ports on the axi register slice
        HBM_axi_vis_arlock(i)   <= "00";
        HBM_axi_vis_awlock(i)   <= "00";
        HBM_axi_vis_awcache(i)  <= "0011";  -- out std_logic_vector(3 downto 0); bufferable transaction. Default in Vitis environment.
        HBM_axi_vis_awprot(i)   <= "000";   -- Has no effect in Vitis environment. -- out std_logic_vector(2 downto 0);
        HBM_axi_vis_awqos(i)    <= "0000";  -- Has no effect in vitis environment, -- out std_logic_vector(3 downto 0);
        HBM_axi_vis_awregion(i) <= "0000"; -- Has no effect in Vitis environment. -- out std_logic_vector(3 downto 0);
        HBM_axi_vis_arcache(i)  <= "0011";  -- out std_logic_vector(3 downto 0); bufferable transaction. Default in Vitis environment.
        HBM_axi_vis_arprot(i)   <= "000";   -- Has no effect in vitis environment; out std_logic_Vector(2 downto 0);
        HBM_axi_vis_arqos(i)    <= "0000"; -- Has no effect in vitis environment; out std_logic_vector(3 downto 0);
        HBM_axi_vis_arregion(i) <= "0000"; -- Has no effect in vitis environment; out std_logic_vector(3 downto 0);
        HBM_axi_vis_awid(i)(0) <= '0';   -- We only use a single ID -- out std_logic_vector(0 downto 0);
        HBM_axi_vis_arid(i)(0) <= '0';     -- ID are not used. -- out std_logic_vector(0 downto 0);
        HBM_axi_vis_bid(i)(0) <= '0';
        
    end generate;

    -- 16 GBytes second stage corner turn, unified memory space across all correlator cells
    HBM16G_2 : entity correlator_lib.HBM_axi_TwoInterface_tbModel
    generic map (
        AXI_ADDR_WIDTH => 34, -- : integer := 32;   -- Byte address width. This also defines the amount of data. Use the correct width for the HBM memory block, e.g. 28 bits for 256 MBytes.
        AXI_ID_WIDTH => 1, -- integer := 1;
        AXI_DATA_WIDTH => 256, -- integer := 256;  -- Must be a multiple of 32 bits.
        READ_QUEUE_SIZE => 16, --  integer := 16;
        MIN_LAG => 60,  -- integer := 80   
        INCLUDE_PROTOCOL_CHECKER => TRUE,
        RANDSEED => 43526, -- : natural := 12345;
        LATENCY_LOW_PROBABILITY => 95,  --  natural := 95;   -- probability, as a percentage, that non-zero gaps between read beats will be small (i.e. < 3 clocks)
        LATENCY_ZERO_PROBABILITY => 80, -- natural := 80   -- probability, as a percentage, that the gap between read beats will be zero.
        LATENCY_LOW_PROBABILITY2 => 97, --  natural := 95;   -- probability, as a percentage, that non-zero gaps between read beats will be small (i.e. < 3 clocks)
        LATENCY_ZERO_PROBABILITY2 => 82 -- natural := 80   -- probability, as a percentage, that the gap between read beats will be zero.
    ) Port map (
        i_clk => clk300,
        i_rst_n => rst_n,
        axi_awaddr   => HBM_axi_aw(0).addr(33 downto 0),
        axi_awid     => HBM_axi_awid(0), -- in std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        axi_awlen    => HBM_axi_aw(0).len,
        axi_awsize   => HBM_axi_awsize(0),
        axi_awburst  => HBM_axi_awburst(0),
        axi_awlock   => HBM_axi_awlock(0),
        axi_awcache  => HBM_axi_awcache(0),
        axi_awprot   => HBM_axi_awprot(0),
        axi_awqos    => HBM_axi_awqos(0), -- in(3:0)
        axi_awregion => HBM_axi_awregion(0), -- in(3:0)
        axi_awvalid  => HBM_axi_aw(0).valid,
        axi_awready  => HBM_axi_awready(0),
        axi_wdata    => HBM_axi_w(0).data(255 downto 0),
        axi_wstrb    => HBM_axi_wstrb(0)(31 downto 0),
        axi_wlast    => HBM_axi_w(0).last,
        axi_wvalid   => HBM_axi_w(0).valid,
        axi_wready   => HBM_axi_wready(0),
        axi_bresp    => HBM_axi_b(0).resp,
        axi_bvalid   => HBM_axi_b(0).valid,
        axi_bready   => HBM_axi_bready(0),
        axi_bid      => HBM_axi_bid(0), -- out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        axi_araddr   => HBM_axi_ar(0).addr(33 downto 0),
        axi_arlen    => HBM_axi_ar(0).len,
        axi_arsize   => HBM_axi_arsize(0),
        axi_arburst  => HBM_axi_arburst(0),
        axi_arlock   => HBM_axi_arlock(0),
        axi_arcache  => HBM_axi_arcache(0),
        axi_arprot   => HBM_axi_arprot(0),
        axi_arvalid  => HBM_axi_ar(0).valid,
        axi_arready  => HBM_axi_arready(0),
        axi_arqos    => HBM_axi_arqos(0),
        axi_arid     => HBM_axi_arid(0),
        axi_arregion => HBM_axi_arregion(0),
        axi_rdata    => HBM_axi_r(0).data(255 downto 0),
        axi_rresp    => HBM_axi_r(0).resp,
        axi_rlast    => HBM_axi_r(0).last,
        axi_rvalid   => HBM_axi_r(0).valid,
        axi_rready   => HBM_axi_rready(0),
        --
        axi2_awaddr   => HBM_axi_aw(1).addr(33 downto 0),
        axi2_awid     => HBM_axi_awid(1), -- in std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        axi2_awlen    => HBM_axi_aw(1).len,
        axi2_awsize   => HBM_axi_awsize(1),
        axi2_awburst  => HBM_axi_awburst(1),
        axi2_awlock   => HBM_axi_awlock(1),
        axi2_awcache  => HBM_axi_awcache(1),
        axi2_awprot   => HBM_axi_awprot(1),
        axi2_awqos    => HBM_axi_awqos(1), -- in(3:0)
        axi2_awregion => HBM_axi_awregion(1), -- in(3:0)
        axi2_awvalid  => HBM_axi_aw(1).valid,
        axi2_awready  => HBM_axi_awready(1),
        axi2_wdata    => HBM_axi_w(1).data(255 downto 0),
        axi2_wstrb    => HBM_axi_wstrb(1)(31 downto 0),
        axi2_wlast    => HBM_axi_w(1).last,
        axi2_wvalid   => HBM_axi_w(1).valid,
        axi2_wready   => HBM_axi_wready(1),
        axi2_bresp    => HBM_axi_b(1).resp,
        axi2_bvalid   => HBM_axi_b(1).valid,
        axi2_bready   => HBM_axi_bready(1),
        axi2_bid      => HBM_axi_bid(1), -- out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        axi2_araddr   => HBM_axi_ar(1).addr(33 downto 0),
        axi2_arlen    => HBM_axi_ar(1).len,
        axi2_arsize   => HBM_axi_arsize(1),
        axi2_arburst  => HBM_axi_arburst(1),
        axi2_arlock   => HBM_axi_arlock(1),
        axi2_arcache  => HBM_axi_arcache(1),
        axi2_arprot   => HBM_axi_arprot(1),
        axi2_arvalid  => HBM_axi_ar(1).valid,
        axi2_arready  => HBM_axi_arready(1),
        axi2_arqos    => HBM_axi_arqos(1),
        axi2_arid     => HBM_axi_arid(1),
        axi2_arregion => HBM_axi_arregion(1),
        axi2_rdata    => HBM_axi_r(1).data(255 downto 0),
        axi2_rresp    => HBM_axi_r(1).resp,
        axi2_rlast    => HBM_axi_r(1).last,
        axi2_rvalid   => HBM_axi_r(1).valid,
        axi2_rready   => HBM_axi_rready(1),            
        --
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
