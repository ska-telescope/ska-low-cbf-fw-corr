----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: May 2025
-- Design Name: v80_top 
-- 
-- Description: 
--  Testbench for the correlator on the v80
-- 
----------------------------------------------------------------------------------
library IEEE, ethernet_lib;
library common_lib, correlator_lib, versal_dcmac_lib;
library axi4_lib;
library xpm;
USE xpm.vcomponents.all;
USE IEEE.STD_LOGIC_1164.ALL;
USE axi4_lib.axi4_stream_pkg.ALL;
USE axi4_lib.axi4_lite_pkg.ALL;
USE axi4_lib.axi4_full_pkg.all;

USE versal_dcmac_lib.versal_dcmac_pkg.ALL;
USE ethernet_lib.ethernet_pkg.ALL;
USE std.textio.all;
USE IEEE.std_logic_textio.all;
USE IEEE.NUMERIC_STD.ALL;
USE common_lib.common_pkg.all;
USE std.env.finish;

library technology_lib;

entity tb_correlatorCore is
    generic (
        g_SPS_PACKETS_PER_FRAME : integer := 128;
        g_CORRELATORS : integer := 2; -- Number of correlator instances to instantiate (0, 1, 2)
        g_USE_DUMMY_FB : boolean := TRUE;  -- use a dummy version of the filterbank to speed up simulation.
        -- Location of the test case; All the other filenames in generics here are in this directory
        --g_TEST_CASE : string := "/home/bab031/Documents/_ska_low/ska-low-cbf-fw-corr/low-cbf-model/src_atomic/run_cor_1sa_17stations/";
        g_TEST_CASE        : string := "../../../../../../../low-cbf-model/src_atomic/run_cor_1sa_6stations/";
        --/home/bab031/Documents/_ska_low/ska-low-cbf-fw-corr/low-cbf-model/src_atomic/run_cor_1sa_17stations
        --g_TEST_CASE : string := "../../../../../../";
        -- text file with SPS packets
        g_SPS_DATA_FILENAME : string := "sps_axi_tb_input.txt";
        -- Register initialisation
        g_REGISTER_INIT_FILENAME : string := "tb_registers.txt";
        -- File to log the output data to (the 100GE axi interface)
        g_SDP_FILENAME : string := "tb_SDP_data_out.txt";
        -- initialisation of corner turn 1 HBM
        g_LOAD_CT1_HBM : boolean := False;
        g_CT1_INIT_FILENAME : string := "";
        -- initialisation of corner turn 2 HBM
        g_LOAD_CT2_HBM_CORR1 : boolean := True;
        g_CT2_HBM_CORR1_FILENAME : string := "ct2_init.txt";
        g_LOAD_CT2_HBM_CORR2 : boolean := False;
        g_CT2_HBM_CORR2_FILENAME : string := "";
        --
        --
        g_LOAD_VIS_CHECK_FILE   : boolean := TRUE;
        -- Text file to use to check against the visibility data going to the HBM from the correlator.
        g_VIS_CHECK_FILE : string := "LTA_vis_check.txt";
        -- Text file to use to check the meta data going to the HBM from the correlator
        g_META_CHECK_FILE : string := "LTA_TCI_FD_check.txt";
        -- Number of bytes to dump from the filterbank output
        -- Default 8 Mbytes; 
        -- Needs to be at least = 
        --  ceil(virtual_channels/4) * (512 bytes) * (3456 fine channels) * (2 timegroups (of 32 times each))
        g_CT2_HBM_DUMP_SIZE : integer := 8388608;  
        g_CT2_HBM_DUMP_ADDR : integer := 0; -- Address to start the memory dump at.
        g_CT2_HBM_DUMP_FNAME : string := "ct2_hbm_dump.txt";
        
        g_RDOUT_HBM_DUMP_SIZE : integer := 32768;  
        g_RDOUT_HBM_DUMP_ADDR : integer := 0; -- Address to start the memory dump at.
        g_RDOUT_HBM_DUMP_FNAME : string := "RDOUT_hbm_dump.txt"
        
    );
end tb_correlatorCore;

architecture Behavioral of tb_correlatorCore is

    
    signal clk_100      : std_logic := '0';
    signal clk_300      : std_logic := '0';
    signal dcmac_clk    : std_logic := '0';
    
    signal clk_100_rst  : std_logic := '0';
    signal clk_300_rst  : std_logic := '0';
    
    signal ap_rst_n     : std_logic := '0';

    signal dcmac_run            : std_logic := '0';

    signal dcmac_locked         : std_logic := '0';
    signal dcmac_locked_300m    : std_logic := '0';
    
    signal dcmac_rx_data_0      : seg_streaming_axi;
    signal dcmac_rx_data_1      : seg_streaming_axi;
    
    signal dcmac_tx_data_0      : seg_streaming_axi;
    signal dcmac_tx_data_1      : seg_streaming_axi;
    
    signal dcmac_tx_ready_0     : std_logic;
    
    signal dcmac_reset          : std_logic := '0';

    signal LFAADone : std_logic := '0';
    -- The shared memory in the shell is 128Kbytes;
    -- i.e. 32k x 4 byte words. 
--    type memType is array(32767 downto 0) of integer;
--    shared variable sharedMem : memType;
    
    function strcmp(a, b : string) return boolean is
        alias a_val : string(1 to a'length) is a;
        alias b_val : string(1 to b'length) is b;
        variable a_char, b_char : character;
    begin
        if a'length /= b'length then
            return false;
        elsif a = b then
            return true;
        else
            return false;
        end if;
    end;

    
    constant g_HBM_INTERFACES : integer := 6;
    signal HBM_axi_awvalid  : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_awready  : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_awaddr   : t_slv_64_arr(g_HBM_INTERFACES-1 downto 0); -- out std_logic_vector(M01_AXI_ADDR_WIDTH-1 downto 0);
    signal HBM_axi_awid     : t_slv_1_arr(g_HBM_INTERFACES-1 downto 0);  -- std_logic_vector(M01_AXI_ID_WIDTH - 1 downto 0);
    signal HBM_axi_awlen    : t_slv_8_arr(g_HBM_INTERFACES-1 downto 0);  -- std_logic_vector(7 downto 0);
    signal HBM_axi_awsize   : t_slv_3_arr(g_HBM_INTERFACES-1 downto 0);  -- std_logic_vector(2 downto 0);
    signal HBM_axi_awburst  : t_slv_2_arr(g_HBM_INTERFACES-1 downto 0);  -- std_logic_vector(1 downto 0);
    signal HBM_axi_awlock   : t_slv_2_arr(g_HBM_INTERFACES-1 downto 0);  -- std_logic_vector(1 downto 0);
    signal HBM_axi_awcache  : t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);  -- std_logic_vector(3 downto 0);
    signal HBM_axi_awprot   : t_slv_3_arr(g_HBM_INTERFACES-1 downto 0);  -- std_logic_vector(2 downto 0);
    signal HBM_axi_awqos    : t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);  -- out std_logic_vector(3 downto 0);
    signal HBM_axi_awregion : t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);  -- std_logic_vector(3 downto 0);
    signal HBM_axi_wvalid   : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_wready   : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_wdata    : t_slv_512_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_vector(M01_AXI_DATA_WIDTH-1 downto 0);
    signal HBM_axi_wstrb    : t_slv_64_arr(g_HBM_INTERFACES-1 downto 0);  -- std_logic_vector(M01_AXI_DATA_WIDTH/8-1 downto 0);
    signal HBM_axi_wlast    : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_bvalid   : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_bready   : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_bresp    : t_slv_2_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_vector(1 downto 0);
    signal HBM_axi_bid      : t_slv_1_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_vector(M01_AXI_ID_WIDTH - 1 downto 0);
    signal HBM_axi_arvalid  : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_arready  : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_araddr   : t_slv_64_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_vector(M01_AXI_ADDR_WIDTH-1 downto 0);
    signal HBM_axi_arid     : t_slv_1_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_vector(M01_AXI_ID_WIDTH-1 downto 0);
    signal HBM_axi_arlen    : t_slv_8_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_vector(7 downto 0);
    signal HBM_axi_arsize   : t_slv_3_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_vector(2 downto 0);
    signal HBM_axi_arburst  : t_slv_2_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_vector(1 downto 0);
    signal HBM_axi_arlock   : t_slv_2_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_vector(1 downto 0);
    signal HBM_axi_arcache  : t_slv_4_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_vector(3 downto 0);
    signal HBM_axi_arprot   : t_slv_3_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_Vector(2 downto 0);
    signal HBM_axi_arqos    : t_slv_4_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_vector(3 downto 0);
    signal HBM_axi_arregion : t_slv_4_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_vector(3 downto 0);
    signal HBM_axi_rvalid   : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_rready   : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_rdata    : t_slv_512_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_vector(M01_AXI_DATA_WIDTH-1 downto 0);
    signal HBM_axi_rlast    : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_rid      : t_slv_1_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_vector(M01_AXI_ID_WIDTH - 1 downto 0);
    signal HBM_axi_rresp    : t_slv_2_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_vector(1 downto 0);

    signal setupDone : std_logic;
    signal eth100G_clk : std_logic := '0';
    signal eth100G_locked : std_logic := '0';

    signal power_up_rst_eth100G_clk : std_logic_vector(31 downto 0);

    signal m00_bram_we : STD_LOGIC_VECTOR(3 DOWNTO 0);
    signal m00_bram_en : STD_LOGIC;
    signal m00_bram_addr : STD_LOGIC_VECTOR(16 DOWNTO 0);
    signal m00_bram_addr_word : std_logic_vector(14 downto 0);
    signal m00_bram_wrData : STD_LOGIC_VECTOR(31 DOWNTO 0);
    signal m00_bram_rdData : STD_LOGIC_VECTOR(31 DOWNTO 0);
    signal m00_bram_clk : std_logic;
    signal validMemRstActive : std_logic; 

    signal m02_arFIFO_dout, m02_arFIFO_din : std_logic_vector(63 downto 0);
    signal m02_arFIFO_empty, m02_arFIFO_rdEn, m02_arFIFO_wrEn : std_logic;
    signal m02_arFIFO_wrDataCount : std_logic_vector(5 downto 0);
    signal M02_READ_QUEUE_SIZE, MIN_LAG : integer;
    signal m02_arlen_delayed : std_logic_vector(7 downto 0);
    signal m02_arsize_delayed : std_logic_vector(2 downto 0);
    signal m02_arburst_delayed : std_logic_vector(1 downto 0);
    signal m02_arcache_delayed : std_logic_vector(3 downto 0);
    signal m02_arprot_delayed : std_logic_vector(2 downto 0);
    signal m02_arqos_delayed : std_logic_vector(3 downto 0);
    signal m02_arregion_delayed : std_logic_vector(3 downto 0);
    
    signal m02_araddr_delayed : std_logic_vector(19 downto 0);
    signal m02_reqTime : std_logic_vector(31 downto 0);
    signal m02_arvalid_delayed, m02_arready_delayed : std_logic;
        
    signal wr_addr_x410E0, rd_addr_x410E0 : std_logic := '0'; 
    signal wrdata_x410E0, rddata_x410E0 : std_logic := '0';
    
    signal rx_axi_tdata     : std_logic_vector(511 downto 0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
    signal rx_axi_tkeep     : std_logic_vector(63 downto 0);  -- one bit per byte in i_axi_tdata
    signal rx_axi_tlast     : std_logic;
    signal rx_axi_tuser     : std_logic_vector(79 downto 0);  -- Timestamp for the packet.
    signal rx_axi_tvalid    : std_logic;
    
    signal player_rx_axi_tdata  : std_logic_vector(511 downto 0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
    signal player_rx_axi_tkeep  : std_logic_vector(63 downto 0);  -- one bit per byte in i_axi_tdata
    signal player_rx_axi_tlast  : std_logic;
    signal player_rx_axi_tuser  : std_logic_vector(79 downto 0);  -- Timestamp for the packet.
    signal player_rx_axi_tvalid : std_logic;
    
    signal bytes_to_transmit_spead_v3   : std_logic_vector(13 downto 0) := "10000001100010"; --14D"8290";
    signal bytes_to_transmit_spead_v2   : std_logic_vector(13 downto 0) := "10000001110010"; --14D"8306";
    
    -- Data to be transmitted on 100GE
    signal eth100_tx_axi_tdata : std_logic_vector(511 downto 0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
    signal eth100_tx_axi_tkeep : std_logic_vector(63 downto 0);  -- one bit per byte in i_axi_tdata
    signal eth100_tx_axi_tlast : std_logic;                      
    signal eth100_tx_axi_tuser : std_logic;  
    signal eth100_tx_axi_tvalid : std_logic;
    
    constant one0 : std_logic_vector(3 downto 0) := "0000";
    constant FOUR0 : std_logic_vector(15 downto 0) := x"0000";
    constant FOUR1 : std_logic_vector(3 downto 0) := "0001";
    constant T0 : std_logic_vector(511 downto 0) := (others => '0');
    
    signal tvalid_ext : std_logic_vector(3 downto 0);
    signal tlast_ext : std_logic_vector(3 downto 0);
    signal tuser_ext : std_logic_vector(3 downto 0);
    signal sim_register_input_file_counter : integer := 0;
    
    signal load_ct1_HBM, load_ct2_HBM_corr1, load_ct2_HBM_corr2 : std_logic := '0';
    signal axi4_lite_miso_dummy : t_axi4_lite_miso;
    signal axi4_full_miso_dummy : t_axi4_full_miso;
    
    signal ct2_readout_start  : std_logic := '0';
    signal ct2_readout_buffer : std_logic := '0';
    signal ct2_readout_frameCount : std_logic_vector(31 downto 0) := x"00000000";
    
    signal cor0_tb_data : std_logic_vector(255 downto 0);
    signal cor0_tb_data_check : t_slv_32_arr(7 downto 0);
    signal cor0_tb_visValid : std_logic; -- o_tb_data is valid visibility data
    signal cor0_tb_TCIvalid : std_logic; -- i_data is valid TCI & DV data
    signal cor0_tb_dcount   : std_logic_vector(7 downto 0);  -- counts the 256 transfers for one cell of visibilites, or 16 transfers for the centroid data. 
    signal cor0_tb_cell : std_logic_vector(7 downto 0);  -- a "cell" is a 16x16 station block of correlations
    signal cor0_tb_tile : std_logic_Vector(9 downto 0);  -- a "tile" is a 16x16 block of cells, i.e. a 256x256 station correlation.
    signal cor0_tb_channel : std_logic_vector(23 downto 0);
    signal visCheckDone, visMetaCheckDone : std_logic;
    --signal visCheckData : std_logic_vector(255 downto 0);
    signal visCheckData, visMetaCheckData : t_slv_32_arr(7 downto 0);
    
    signal ct2_HBM_dump_trigger : std_logic := '0';
    signal dump_trigger_count : integer := 0;
    signal sof_count : integer := 0;
    signal FB_out_sof : std_logic := '0';
    
    signal Dump_packet_hbm : std_logic;
    
    signal load_packet_buffer : std_logic;
    
    signal input_HBM_reset      : std_logic;
    
    signal clk_data_input       : std_logic := '0';
    signal clk_data_input_rst   : std_logic;
    
    signal clk_425_rst_cnt      : unsigned(31 downto 0) := x"00001000";
    signal clk_300_rst_cnt      : unsigned(31 downto 0) := x"00001000";
    
    signal clock_300_rst        : std_logic;
    
    ------------------------------------------------------------------------------------
    -- Segmented-AXI test packet stimulus (dcmac_rx_data_0)
    --
    -- Segmented-AXI framing (which 64-byte beat carries EOP, which of its four 16-byte
    -- segments EOP falls in, and how many trailing bytes in that segment are invalid)
    -- is derived directly from each packet's total on-wire byte count (Ethernet header
    -- through end of UDP payload, excluding FCS), so the asserted tlast/empty position
    -- always matches the length encoded in the packet's own IP/UDP headers.
    ------------------------------------------------------------------------------------
    type t_seg_frame_info is record
        last_word_idx : integer;                     -- index of the beat containing EOP
        eop_seg_idx   : integer;                      -- 0..3, which segment carries EOP
        eop_seg       : std_logic_vector(3 downto 0); -- one-hot form of eop_seg_idx
        eop_empty     : std_logic_vector(3 downto 0); -- invalid byte count in that segment
    end record;

    function calc_seg_frame_info(total_bytes : integer) return t_seg_frame_info is
        variable info            : t_seg_frame_info;
        variable last_word_idx   : integer;
        variable valid_last_word : integer;
        variable eop_seg_idx     : integer;
        variable valid_eop_seg   : integer;
    begin
        last_word_idx    := (total_bytes - 1) / 64;
        valid_last_word  := total_bytes - last_word_idx * 64;
        eop_seg_idx       := (valid_last_word - 1) / 16;
        valid_eop_seg     := valid_last_word - eop_seg_idx * 16;
        info.last_word_idx := last_word_idx;
        info.eop_seg_idx   := eop_seg_idx;
        case eop_seg_idx is
            when 0 => info.eop_seg := x"1";
            when 1 => info.eop_seg := x"2";
            when 2 => info.eop_seg := x"4";
            when others => info.eop_seg := x"8";
        end case;
        info.eop_empty := std_logic_vector(to_unsigned(16 - valid_eop_seg, 4));
        return info;
    end function;

    -- Total on-wire byte count for each test packet (Ethernet header through end of UDP payload).
    constant c_V2_TOTAL_BYTES       : integer := 8306; -- SPEAD v2, no VLAN
    constant c_V3_TOTAL_BYTES       : integer := 8290; -- SPEAD v3, no VLAN
    constant c_V2_VLAN2_TOTAL_BYTES : integer := 8314; -- SPEAD v2, two stacked 802.1Q VLAN tags
    constant c_V3_VLAN2_TOTAL_BYTES : integer := 8298; -- SPEAD v3, two stacked 802.1Q VLAN tags

    -- Test packet indices, used by c_PACKET_TYPES and get_test_packet_word below.
    constant c_PKT_V2       : integer := 0;
    constant c_PKT_V3       : integer := 1;
    constant c_PKT_V2_VLAN2 : integer := 2;
    constant c_PKT_V3_VLAN2 : integer := 3;

    type t_seg_frame_info_arr is array (0 to 3) of t_seg_frame_info;
    constant c_TEST_PACKET_FRAME_INFO : t_seg_frame_info_arr := (
        c_PKT_V2       => calc_seg_frame_info(c_V2_TOTAL_BYTES),
        c_PKT_V3       => calc_seg_frame_info(c_V3_TOTAL_BYTES),
        c_PKT_V2_VLAN2 => calc_seg_frame_info(c_V2_VLAN2_TOTAL_BYTES),
        c_PKT_V3_VLAN2 => calc_seg_frame_info(c_V3_VLAN2_TOTAL_BYTES)
    );

    -- Packet data taken from PCAP, copy hex stream from wireshark; ChangeEndian converts
    -- it to match the streaming AXI byte ordering. Only word(0)/word(1)/word(2) carry
    -- meaningful header content - beats beyond word_idx=2 up to last_word_idx just repeat
    -- word(2) (filler); the true valid length is entirely controlled by
    -- c_TEST_PACKET_FRAME_INFO above, not by how much of the array is populated.
    constant c_test_packet_v2 : t_slv_512_arr(0 to 2) := (
        0 => ChangeEndian(x"248a07463b5e62000a050a020800450020647687000080117b970a050a020a000a64f0d0123420504c1253040206000000088001001500050a08800400000000"),
        1 => ChangeEndian(x"2000902700005e72eab7960000154251c0009011001501122e6eb000000000000417b00100000000001033000000000000008080808080808080808080808080"),
        2 => ChangeEndian(x"80808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080")
    );

    constant c_test_packet_v3 : t_slv_512_arr(0 to 2) := (
        0 => ChangeEndian(x"001122334455001122334455080045002054acdc4000401159ba0a0000010a000002123412342040000053040206000000068001000100000006800400000000"),
        1 => ChangeEndian(x"2000b010ffff000004d2b000000000010064b0010101015e00003300000000000000000000000000000000000000000000000000000000000000000000000000"),
        2 => ChangeEndian(x"00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
    );

    -- v2 with two stacked 802.1Q VLAN tags (TPID 0x8100, VID 100 outer / VID 200 inner)
    -- inserted between the source MAC and the Ethertype. IP/UDP header fields unchanged.
    constant c_test_packet_v2_vlan2 : t_slv_512_arr(0 to 2) := (
        0 => ChangeEndian(x"248a07463b5e62000a050a0281000064810000c80800450020647687000080117b970a050a020a000a64f0d0123420504c125304020600000008800100150005"),
        1 => ChangeEndian(x"0a088004000000002000902700005e72eab7960000154251c0009011001501122e6eb000000000000417b0010000000000103300000000000000808080808080"),
        2 => ChangeEndian(x"80808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080")
    );

    -- v3 with two stacked 802.1Q VLAN tags (TPID 0x8100, VID 100 outer / VID 200 inner)
    -- inserted between the source MAC and the Ethertype. IP/UDP header fields unchanged.
    constant c_test_packet_v3_vlan2 : t_slv_512_arr(0 to 2) := (
        0 => ChangeEndian(x"00112233445500112233445581000064810000c8080045002054acdc4000401159ba0a0000010a00000212341234204000005304020600000006800100010000"),
        1 => ChangeEndian(x"00068004000000002000b010ffff000004d2b000000000010064b0010101015e0000330000000000000000000000000000000000000000000000000000000000"),
        2 => ChangeEndian(x"00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
    );

    function get_test_packet_word(pkt_type : integer; word_idx : integer) return std_logic_vector is
        variable idx : integer;
    begin
        if word_idx < 2 then
            idx := word_idx;
        else
            idx := 2;
        end if;
        case pkt_type is
            when c_PKT_V2       => return c_test_packet_v2(idx);
            when c_PKT_V3       => return c_test_packet_v3(idx);
            when c_PKT_V2_VLAN2 => return c_test_packet_v2_vlan2(idx);
            when others         => return c_test_packet_v3_vlan2(idx);
        end case;
    end function;

    ------------------------------------------------------------------------------------
    -- Reference model for dut_1_dcmac_to_cmac's output (rx_axi_tdata/tkeep/tlast/tvalid).
    --
    -- segment_to_saxi.vhd's double-VLAN strip path (p_vlan_detected="11", see
    -- vlan_proc/segment_to_saxi.vhd around line 634) replaces the outer+inner 802.1Q tags
    -- (original bytes 12..21, 10 bytes: 2x(TPID+TCI) plus the real Ethertype that followed
    -- them) with a single hardcoded 2-byte 0x0800 Ethertype at the same starting offset -
    -- a net -8 bytes. Everything else (MAC addresses, and the IP header onward, including
    -- its now-stale length fields, which the DUT does not currently recompute) is passed
    -- through unchanged. Non-VLAN packets pass through byte-for-byte with no change at all.
    ------------------------------------------------------------------------------------
    function get_expected_byte(pkt_type : integer; byte_idx : integer) return std_logic_vector is
        variable src_idx : integer;
        variable word    : std_logic_vector(511 downto 0);
        variable bit_lo  : integer;
        variable is_vlan : boolean;
    begin
        is_vlan := (pkt_type = c_PKT_V2_VLAN2) or (pkt_type = c_PKT_V3_VLAN2);
        if is_vlan and byte_idx = 12 then
            return x"08";
        elsif is_vlan and byte_idx = 13 then
            return x"00";
        elsif is_vlan and byte_idx >= 14 then
            src_idx := byte_idx + 8;
        else
            src_idx := byte_idx;
        end if;
        word   := get_test_packet_word(pkt_type, src_idx / 64);
        bit_lo := (src_idx mod 64) * 8;
        return word(bit_lo + 7 downto bit_lo);
    end function;

    function get_expected_total_bytes(pkt_type : integer) return integer is
    begin
        case pkt_type is
            when c_PKT_V2       => return c_V2_TOTAL_BYTES;
            when c_PKT_V3       => return c_V3_TOTAL_BYTES;
            when c_PKT_V2_VLAN2 => return c_V2_VLAN2_TOTAL_BYTES - 8;
            when others         => return c_V3_VLAN2_TOTAL_BYTES - 8;
        end case;
    end function;

    function count_valid_bytes(tkeep : std_logic_vector(63 downto 0)) return integer is
        variable cnt : integer := 0;
    begin
        for b in 0 to 63 loop
            if tkeep(b) = '1' then
                cnt := cnt + 1;
            end if;
        end loop;
        return cnt;
    end function;

    -- test_packet_running_proc steps through each of these types in turn: for each type
    -- it sends c_PACKETS_PER_GROUP copies back-to-back at full line rate, then
    -- c_PACKETS_PER_GROUP copies individually gapped, then waits c_INTER_TYPE_WAIT before
    -- moving on to the next type.
    type t_int_arr is array (natural range <>) of integer;
    constant c_PACKET_TYPES      : t_int_arr(0 to 3) := (c_PKT_V2, c_PKT_V3, c_PKT_V2_VLAN2, c_PKT_V3_VLAN2);
    constant c_PACKETS_PER_GROUP : integer := 10;
    constant c_INTER_PACKET_GAP  : integer := 100; -- idle dcmac_clk cycles between packets in the gapped group
    constant c_INTER_TYPE_WAIT   : time    := 1 us; -- wait after each type's two groups before moving to the next type
    constant c_END_OF_TEST_WAIT : time    := 2 us; -- wait after the last packet is sent before the simulation finishes
    
    signal vlan_stats           : t_slv_32_arr(2 downto 0);
    
    -- awready, wready bresp, bvalid, arready, rdata, rresp, rvalid, rdata
    -- +bid buser
    -- Do an axi-lite read of a single 32-bit register.
    PROCEDURE axi_lite_rd(SIGNAL mm_clk   : IN STD_LOGIC;
                          SIGNAL axi_miso : IN t_axi4_lite_miso;
                          SIGNAL axi_mosi : OUT t_axi4_lite_mosi;
                          register_addr   : NATURAL;  -- 4-byte word address
                          variable rd_data  : out std_logic_vector(31 downto 0)) is

        VARIABLE stdio             : line;
        VARIABLE result            : STD_LOGIC_VECTOR(31 DOWNTO 0);
        variable wvalidInt         : std_logic;
        variable awvalidInt        : std_logic;
    BEGIN
        -- Start transaction
        WAIT UNTIL rising_edge(mm_clk);
            -- Setup read address
            axi_mosi.arvalid <= '1';
            axi_mosi.araddr <= std_logic_vector(to_unsigned(register_addr*4, 32));
            axi_mosi.rready <= '1';

        read_address_wait: LOOP
            WAIT UNTIL rising_edge(mm_clk);
            IF axi_miso.arready = '1' THEN
               axi_mosi.arvalid <= '0';
               axi_mosi.araddr <= (OTHERS => '0');
            END IF;

            IF axi_miso.rvalid = '1' THEN
               EXIT;
            END IF;
        END LOOP;

        rd_data := axi_miso.rdata(31 downto 0);
        -- Read response
        IF axi_miso.rresp = "01" THEN
            write(stdio, string'("exclusive access error "));
            writeline(output, stdio);
        ELSIF axi_miso.rresp = "10" THEN
            write(stdio, string'("slave error "));
            writeline(output, stdio);
        ELSIF axi_miso.rresp = "11" THEN
           write(stdio, string'("address decode error "));
           writeline(output, stdio);
        END IF;

        WAIT UNTIL rising_edge(mm_clk);
        axi_mosi.rready <= '0';
    end procedure;
    
begin

    clk_300     <= not clk_300 after 1.666 ns; -- 300 MHz clock.
    clk_100     <= not clk_100 after 5 ns; -- 100 MHz clock
    
    eth100G_clk <= not eth100G_clk after 1.553 ns; -- 322 MHz
    
    dcmac_clk   <= not dcmac_clk after 1.2594 ns;    -- 397 MHz (i_MAC_clk)

    -- 425 MHz (i_dcmac_data_clk)
    clk_data_input      <= not clk_data_input after 1.1765 ns;
    
    reset_425_proc : process(clk_data_input)
    begin
        if rising_edge(clk_data_input) then
            if clk_425_rst_cnt = 1 then
                clk_data_input_rst     <= '0';
            else
                clk_425_rst_cnt <= clk_425_rst_cnt - 1;
                clk_data_input_rst     <= '1';
            end if;
        end if;
    end process;

    reset_300_proc : process(clk_300)
    begin
        if rising_edge(clk_300) then
            if clk_300_rst_cnt = 1 then
                clock_300_rst     <= '0';
            else
                clk_300_rst_cnt <= clk_300_rst_cnt - 1;
                clock_300_rst     <= '1';
            end if;
        end if;
    end process;
        
    

    eth100G_locking_proc: process(eth100G_clk)
    begin
        if rising_edge(eth100G_clk) then
            -- power up reset logic
            if power_up_rst_eth100G_clk(31) = '1' then
                power_up_rst_eth100G_clk(31 downto 0) <= power_up_rst_eth100G_clk(30 downto 0) & '0';
                eth100G_locked  <= '0';
            else
                eth100G_locked  <= '1';
            end if;
        end if;
    end process;

clk_300_rst <= NOT ap_rst_n;

    clkc_300_running_proc : process
        file RegCmdfile: TEXT;
        variable RegLine_in : Line;
        variable RegGood : boolean;
        variable cmd_str : string(1 to 2);
        variable regAddr : std_logic_vector(31 downto 0);
        variable regSize : std_logic_vector(31 downto 0);
        variable regData : std_logic_vector(31 downto 0);
        variable readResult : std_logic_vector(31 downto 0);
    begin
        input_HBM_reset <= '0';
        Dump_packet_hbm <= '0';        
        SetupDone <= '0';
        ap_rst_n <= '1';
        load_ct1_HBM <= '0';
        load_ct2_HBM_corr1 <= '0';
        load_ct2_HBM_corr2 <= '0';
        load_packet_buffer <= '0';
        FILE_OPEN(RegCmdfile, g_TEST_CASE & g_REGISTER_INIT_FILENAME, READ_MODE);
        
        for i in 1 to 10 loop
            WAIT UNTIL RISING_EDGE(clk_300);
        end loop;
        ap_rst_n <= '0';
        for i in 1 to 10 loop
             WAIT UNTIL RISING_EDGE(clk_300);
        end loop;
        ap_rst_n <= '1';
        
        if g_LOAD_CT1_HBM then
            load_ct1_HBM <= '1';
        end if;
        if g_LOAD_CT2_HBM_CORR1 then
            load_ct2_HBM_corr1 <= '1';
        end if;
        if g_LOAD_CT2_HBM_CORR2 then
            load_ct2_HBM_corr2 <= '1';
        end if;  
        
        if g_LOAD_VIS_CHECK_FILE then
            load_packet_buffer  <= '1';
        end if;
        
        wait until rising_edge(clk_300);
        
        load_ct1_HBM        <= '0';
        load_ct2_HBM_corr1  <= '0';
        load_ct2_HBM_corr2  <= '0';
        load_packet_buffer  <= '0';
        
        
        for i in 1 to 100 loop
             WAIT UNTIL RISING_EDGE(clk_300);
        end loop;
        


        wait UNTIL RISING_EDGE(clk_300);
        wait UNTIL RISING_EDGE(clk_300);
        wait UNTIL RISING_EDGE(clk_300);
        wait UNTIL RISING_EDGE(clk_300);
        if (g_LOAD_CT2_HBM_CORR1 or g_LOAD_CT2_HBM_CORR2) then
            ct2_readout_start <= '1';
        else
            ct2_readout_start <= '0';
        end if;
        wait UNTIL RISING_EDGE(clk_300);
        ct2_readout_start <= '0';

        if validMemRstActive = '1' then
            wait until validMemRstActive = '0';
        end if;
        
        SetupDone <= '1';
        
        -- trigger HBM reset
        WAIT for 2.3 us;
        input_HBM_reset <= '0';
        -- Trigger to dump HBM output
        WAIT for 60 us;
        Dump_packet_hbm <= '1';
        
        wait;
    end process;
    ct2_readout_buffer <= '0';
    ct2_readout_frameCount <= (others => '0');
    
    
    -------------------------------------------------------------------------------------------
    -- DCMAC test packet
    -------------------------------------------------------------------------------------------------------------------------------
    -- Test packet data/framing constants are declared above (c_test_packet_*,
    -- c_TEST_PACKET_FRAME_INFO, c_PACKET_TYPES). See test_packet_running_proc below.

    dcmac_running_proc : process

    begin
        -- simulate interface coming online.        
        dcmac_locked    <= '0';
        dcmac_run       <= '0';

        
        for i in 1 to 100 loop
            WAIT UNTIL RISING_EDGE(dcmac_clk);
        end loop;

        dcmac_locked    <= '1';

        for i in 1 to 100 loop
            WAIT UNTIL RISING_EDGE(dcmac_clk);
        end loop;

        dcmac_run       <= '1';

        wait;
    end process;    


    -- Drives dcmac_rx_data_0, stepping through c_PACKET_TYPES in turn. For each type:
    --   c_PACKETS_PER_GROUP copies back-to-back at full line rate (no idle beats),
    --   then c_PACKETS_PER_GROUP copies individually gapped by c_INTER_PACKET_GAP,
    --   then a c_INTER_TYPE_WAIT idle period before moving on to the next type.
    test_packet_running_proc : process
        procedure send_packet(pkt_type : in integer) is
            variable v_last_word : integer;
            variable v_data512   : std_logic_vector(511 downto 0);
        begin
            v_last_word := c_TEST_PACKET_FRAME_INFO(pkt_type).last_word_idx;
            for word_idx in 0 to v_last_word loop
                v_data512 := get_test_packet_word(pkt_type, word_idx);
                dcmac_rx_data_0.tdata0 <= v_data512(127 downto 0);
                dcmac_rx_data_0.tdata1 <= v_data512(255 downto 128);
                dcmac_rx_data_0.tdata2 <= v_data512(383 downto 256);
                dcmac_rx_data_0.tdata3 <= v_data512(511 downto 384);
                dcmac_rx_data_0.tvalid <= '1';

                if word_idx = 0 then
                    dcmac_rx_data_0.sop <= x"1";
                else
                    dcmac_rx_data_0.sop <= x"0";
                end if;

                if word_idx = v_last_word then
                    dcmac_rx_data_0.eop <= c_TEST_PACKET_FRAME_INFO(pkt_type).eop_seg;
                    -- segments before the EOP segment are fully valid, the EOP segment
                    -- carries the computed invalid-byte count, anything after is unused.
                    for seg in 0 to 3 loop
                        if seg < c_TEST_PACKET_FRAME_INFO(pkt_type).eop_seg_idx then
                            dcmac_rx_data_0.empty(seg) <= x"0";
                        elsif seg = c_TEST_PACKET_FRAME_INFO(pkt_type).eop_seg_idx then
                            dcmac_rx_data_0.empty(seg) <= c_TEST_PACKET_FRAME_INFO(pkt_type).eop_empty;
                        else
                            dcmac_rx_data_0.empty(seg) <= x"F";
                        end if;
                    end loop;
                else
                    dcmac_rx_data_0.eop      <= x"0";
                    dcmac_rx_data_0.empty(0) <= x"0";
                    dcmac_rx_data_0.empty(1) <= x"0";
                    dcmac_rx_data_0.empty(2) <= x"0";
                    dcmac_rx_data_0.empty(3) <= x"0";
                end if;

                wait until rising_edge(dcmac_clk);
            end loop;
        end procedure;

        procedure idle_gap(n_cycles : in integer) is
        begin
            dcmac_rx_data_0.tvalid   <= '0';
            dcmac_rx_data_0.sop      <= x"0";
            dcmac_rx_data_0.eop      <= x"0";
            dcmac_rx_data_0.empty(0) <= x"0";
            dcmac_rx_data_0.empty(1) <= x"0";
            dcmac_rx_data_0.empty(2) <= x"0";
            dcmac_rx_data_0.empty(3) <= x"0";
            for i in 1 to n_cycles loop
                wait until rising_edge(dcmac_clk);
            end loop;
        end procedure;
    begin
        dcmac_rx_data_0.tvalid    <= '0';
        dcmac_rx_data_0.sop       <= x"0";
        dcmac_rx_data_0.eop       <= x"0";
        dcmac_rx_data_0.empty(0)  <= x"0";
        dcmac_rx_data_0.empty(1)  <= x"0";
        dcmac_rx_data_0.empty(2)  <= x"0";
        dcmac_rx_data_0.empty(3)  <= x"0";
        dcmac_rx_data_0.enable    <= x"F";
        dcmac_rx_data_0.tuser_err <= x"0";
        dcmac_rx_data_0.ready     <= '0';

        wait until dcmac_run = '1';
        wait until rising_edge(dcmac_clk);

        for type_idx in c_PACKET_TYPES'range loop
            -- c_PACKETS_PER_GROUP copies back-to-back at full line rate
            for i in 1 to c_PACKETS_PER_GROUP loop
                send_packet(c_PACKET_TYPES(type_idx));
            end loop;

            -- c_PACKETS_PER_GROUP copies, each individually gapped
            idle_gap(c_INTER_PACKET_GAP);
            for i in 1 to c_PACKETS_PER_GROUP loop
                send_packet(c_PACKET_TYPES(type_idx));
                idle_gap(c_INTER_PACKET_GAP);
            end loop;

            if type_idx /= c_PACKET_TYPES'high then
                wait for c_INTER_TYPE_WAIT;
            end if;
        end loop;

        report "segmented AXI stimulus: all packet types complete";
        wait for c_END_OF_TEST_WAIT;
        report "simulation successfully finished";
        finish;
    end process;

    -- Verifies dut_1_dcmac_to_cmac's output (rx_axi_tdata/tkeep/tlast/tvalid, clocked on
    -- clk_data_input) against the same c_PACKET_TYPES / c_PACKETS_PER_GROUP sequence driven
    -- into dcmac_rx_data_0 above, confirming only the VLAN tags (per get_expected_byte) were
    -- stripped and nothing else changed. Limitation: this walks the expected packet list in
    -- lock-step with the DUT's output stream - if the DUT ever drops, duplicates, or splits
    -- a packet's tlast, this checker will misalign and report a cascade of mismatches from
    -- that point on rather than cleanly identifying the one bad packet.
    output_check_proc : process
        variable v_pkt_type        : integer;
        variable v_expected_bytes  : integer;
        variable v_byte_pos        : integer;
        variable v_valid_this_beat : integer;
        variable v_mismatches      : integer := 0;
        variable v_packets_checked : integer := 0;
        variable v_exp_byte        : std_logic_vector(7 downto 0);
        variable v_act_byte        : std_logic_vector(7 downto 0);
    begin
        wait until dcmac_run = '1';

        for type_idx in c_PACKET_TYPES'range loop
            for grp in 1 to 2 loop -- 1 : back-to-back group, 2 : gapped group
                for pkt_num in 1 to c_PACKETS_PER_GROUP loop
                    v_pkt_type       := c_PACKET_TYPES(type_idx);
                    v_expected_bytes := get_expected_total_bytes(v_pkt_type);
                    v_byte_pos       := 0;

                    loop
                        wait until rising_edge(clk_data_input);
                        exit when rx_axi_tvalid = '1';
                    end loop;

                    loop
                        v_valid_this_beat := count_valid_bytes(rx_axi_tkeep);

                        for b in 0 to 63 loop
                            if b < v_valid_this_beat then
                                v_exp_byte := get_expected_byte(v_pkt_type, v_byte_pos);
                                v_act_byte := rx_axi_tdata(8*b+7 downto 8*b);
                                if v_act_byte /= v_exp_byte then
                                    report "output_check_proc: byte mismatch, packet type "
                                        & integer'image(v_pkt_type) & " (group " & integer'image(grp)
                                        & " #" & integer'image(pkt_num) & ") byte "
                                        & integer'image(v_byte_pos) & " expected "
                                        & integer'image(to_integer(unsigned(v_exp_byte))) & " got "
                                        & integer'image(to_integer(unsigned(v_act_byte)))
                                        severity error;
                                    v_mismatches := v_mismatches + 1;
                                end if;
                                v_byte_pos := v_byte_pos + 1;
                            end if;
                        end loop;

                        if rx_axi_tlast = '1' then
                            if v_byte_pos /= v_expected_bytes then
                                report "output_check_proc: packet type " & integer'image(v_pkt_type)
                                    & " (group " & integer'image(grp) & " #" & integer'image(pkt_num)
                                    & ") length mismatch, expected " & integer'image(v_expected_bytes)
                                    & " got " & integer'image(v_byte_pos)
                                    severity error;
                                v_mismatches := v_mismatches + 1;
                            end if;
                            exit;
                        end if;

                        loop
                            wait until rising_edge(clk_data_input);
                            exit when rx_axi_tvalid = '1';
                        end loop;
                    end loop;

                    v_packets_checked := v_packets_checked + 1;
                end loop;
            end loop;
        end loop;

        if v_mismatches = 0 then
            report "output_check_proc: PASSED, " & integer'image(v_packets_checked) & " packets verified";
        else
            report "output_check_proc: FAILED, " & integer'image(v_mismatches) & " mismatches across "
                & integer'image(v_packets_checked) & " packets"
                severity error;
        end if;

        wait;
    end process;


    process
        file cmdfile: TEXT;
        variable line_in : Line;
        variable good : boolean;
        variable sps_axi_repeats : std_logic_vector(15 downto 0);
        variable sps_axi_tvalid : std_logic_vector(3 downto 0);
        variable sps_axi_tlast : std_logic_vector(3 downto 0);
        variable sps_axi_tkeep : std_logic_vector(63 downto 0);
        variable sps_axi_tdata  : std_logic_vector(511 downto 0);
        variable sps_axi_tuser : std_logic_vector(79 downto 0);
        
    begin
        
      
        
        FILE_OPEN(cmdfile,g_TEST_CASE & g_SPS_DATA_FILENAME,READ_MODE);
        wait until SetupDone = '1';
        
        wait until rising_edge(eth100G_clk);
        
--        while (not endfile(cmdfile)) loop 
--            readline(cmdfile, line_in);
--            hread(line_in, sps_axi_repeats, good);
--            hread(line_in, sps_axi_tvalid, good);
--            hread(line_in, sps_axi_tlast, good);
--            hread(line_in, sps_axi_tkeep, good);
--            hread(line_in, sps_axi_tdata, good);
--            hread(line_in, sps_axi_tuser, good);
            
--            for i in 0 to 63 loop
--                rx_axi_tdata(i*8+7 downto i*8) <= sps_axi_tdata(503 - i*8 + 8 downto (504 - i*8)) ;  -- 512 bits
--                rx_axi_tkeep(i) <= sps_axi_tkeep(63 - i);
--            end loop;
--            rx_axi_tlast <= sps_axi_tlast(0);
--            rx_axi_tuser <= sps_axi_tuser;
--            rx_axi_tvalid <= sps_axi_tvalid(0);
            
--            wait until rising_edge(eth100G_clk);
--            while sps_axi_repeats /= "0000000000000000" loop
--                sps_axi_repeats := std_logic_vector(unsigned(sps_axi_repeats) - 1);
--                wait until rising_edge(eth100G_clk);
--            end loop;
--        end loop;
        
        LFAADone <= '1';
        wait;
        report "number of tx packets all received";
        wait for 5 us;
        report "simulation successfully finished";
        finish;
    end process;
    
    
    -- write the output 100GE axi bus to a file.
--    tvalid_ext <= "000" & eth100_tx_axi_tvalid;
--    tlast_ext <= "000" & eth100_tx_axi_tlast;
--    tuser_ext <= "000" & eth100_tx_axi_tuser;
    
--    process
--		file logfile: TEXT;
--		--variable data_in : std_logic_vector((BIT_WIDTH-1) downto 0);
--		variable line_out : Line;
--    begin
--	    FILE_OPEN(logfile, g_TEST_CASE &  g_SDP_FILENAME, WRITE_MODE);
		
--		loop
--            -- wait until we need to read another command
--            -- need to when : rising clock edge, and last_cmd_cycle high
--            -- read the next entry from the file and put it out into the command queue.
--            wait until rising_edge(eth100G_clk);
--            if eth100_tx_axi_tvalid = '1' then
                
--                -- write data to the file
--                hwrite(line_out,FOUR0,RIGHT,4);  -- repeats of this line, tied to 0
                
--                hwrite(line_out,tvalid_ext,RIGHT,2); -- tvalid
--                hwrite(line_out,tlast_ext,RIGHT,2);  -- tlast
--                hwrite(line_out,eth100_tx_axi_tkeep,RIGHT,18);    -- tkeep
--                hwrite(line_out,eth100_tx_axi_tdata,RIGHT,130); -- tdata
--                hwrite(line_out,tlast_ext,RIGHT,2); -- tuser
                
--                writeline(logfile,line_out);
--            end if;
         
--        end loop;
--        file_close(logfile);	
--        wait;
--    end process;
    

    
dcmac_reset <= NOT dcmac_locked;
---------------------------------------------------------------------------------------------------------------
-- DUTs

    dut_1_dcmac_to_cmac : entity versal_dcmac_lib.segment_to_saxi 
    Port Map ( 
        -- Data in from the 100GE MAC
        i_MAC_clk               => dcmac_clk,
        i_MAC_rst               => dcmac_reset,
        
        i_dcmac_data_clk        => clk_data_input,
        i_dcmac_data_rst        => clk_data_input_rst,
        
        i_clk_args_domain       => clk_300,
        i_clk_args_domain_rst   => '0',

        -- Streaming AXI interface - compatible with CMAC S_AXI
        -- RX
        o_rx_axis_tdata         => rx_axi_tdata,
        o_rx_axis_tkeep         => rx_axi_tkeep,
        o_rx_axis_tlast         => rx_axi_tlast,
        i_rx_axis_tready        => '1',
        o_rx_axis_tuser         => rx_axi_tuser,
        o_rx_axis_tvalid        => rx_axi_tvalid,
        
        o_dcmac_locked          => open,
        
        o_vlan_stats            => vlan_stats,

        -- Segmented Streaming AXI, 512
        i_data_to_receive       => dcmac_rx_data_0

    );    
    
--    dut_2 : entity correlator_lib.correlator_core
--    generic map (
--        g_SIMULATION => TRUE, -- BOOLEAN;  -- when true, the 100GE core is disabled and instead the lbus comes from the top level pins
--        g_USE_META => FALSE,   -- BOOLEAN;  -- puts meta data in place of the filterbank data in the corner turn, to help debug the corner turn.
--        -- GLOBAL GENERICS for PERENTIE LOGIC
--        g_DEBUG_ILA                => FALSE, --  BOOLEAN
--        g_SPS_PACKETS_PER_FRAME    => g_SPS_PACKETS_PER_FRAME,   --  allowed values are 32, 64 or 128. 32 and 64 are for simulation. For real system, use 128.

--        -- All the HBM interfaces are the same width;
--        -- Actual interfaces used are : 
--        --  M01, 3 Gbytes HBM; first stage corner turn, between LFAA ingest and the filterbanks
--        --  M02, 3 Gbytes HBM; Correlator HBM for fine channels going to the first correlator instance; buffer between the filterbanks and the correlator
--        --  M03, 3 Gbytes HBM; Correlator HBM for fine channels going to the Second correlator instance; buffer between the filterbanks and the correlator
--        --  M04, 512 Mbytes HBM; visibilities from first correlator instance
--        --  M05, 512 Mbytes HBM; visibilities from second correlator instance
--        g_HBM_INTERFACES     => g_HBM_INTERFACES,   -- integer := 5;
--        g_HBM_AXI_ADDR_WIDTH => 64,  -- integer := 64;
--        g_HBM_AXI_DATA_WIDTH => 512, -- integer := 512;
--        g_HBM_AXI_ID_WIDTH   => 1,   -- integer := 1
--        -- Number of correlator blocks to instantiate.
--        g_CORRELATORS        => g_CORRELATORS,  -- integer := 2
--        g_USE_DUMMY_FB       => g_USE_DUMMY_FB
--    ) port map (
--        clk_100         => clk_100,
--        clk_100_rst     => clk_100_rst,
        
--        clk_300         => clk_300,
--        clk_300_rst     => clock_300_rst,
               
--        o_clk_data_input        => clk_data_input,
--        o_clk_data_input_rst    => clk_data_input_rst,
--        -----------------------------------------------------------------------
--        -- Ports used for simulation only.
--        --
--        -- Received data from 100GE
--        i_axis_tdata    => rx_axi_tdata,   -- in (511:0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
--        i_axis_tkeep    => rx_axi_tkeep,   -- in (63:0);  -- one bit per byte in i_axi_tdata
--        i_axis_tlast    => rx_axi_tlast,   -- in std_logic;
--        i_axis_tuser    => rx_axi_tuser,   -- in (79:0);  -- Timestamp for the packet.
--        i_axis_tvalid   => rx_axi_tvalid, -- in std_logic;
        
--        -- Data to be transmitted on 100GE
--        o_dcmac_tx_data_0   => dcmac_tx_data_0,
--        i_dcmac_tx_ready_0  => dcmac_tx_ready_0,
        
--        i_dcmac_clk         => dcmac_clk,
--        i_dcmac_locked      => '1',
        
--        -- reset of the valid memory is in progress.
--        i_vlan_stats        => vlan_stats,
--        -- reset of the valid memory is in progress.
--        o_validMemRstActive => open,
        
--        -- Other signals to/from the timeslave 
--        i_PTP_time_ARGs_clk     => (others => '0'),
--        o_dcmac_reset           => open,
        
--        i_eth100G_rx_total_packets  => open,
--        i_eth100G_rx_bad_fcs        => open,
--        i_eth100G_rx_bad_code       => open,
--        i_eth100G_tx_total_packets  => open,
        
       
--        -- trigger readout of the second corner turn data without waiting for the rest of the signal chain.
--        -- used in testing with pre-load of the second corner turn HBM data
--        i_ct2_readout_start  => ct2_readout_start, -- in std_logic;
--        i_ct2_readout_buffer => ct2_readout_buffer, -- in std_logic;
--        i_ct2_readout_frameCount => ct2_readout_frameCount, -- in (31:0);
        
--        i_input_HBM_reset   => input_HBM_reset,
--        ---------------------------------------------------------------
--        -- copy of the bus taking data to be written to the HBM.
--        -- Used for simulation only, to check against the model data.
--        o_tb_data      => cor0_tb_data,     -- out (255:0);
--        o_tb_visValid  => cor0_tb_visValid, -- out std_logic; -- o_tb_data is valid visibility data
--        o_tb_TCIvalid  => cor0_tb_TCIvalid, -- out std_logic; -- i_data is valid TCI & DV data
--        o_tb_dcount    => cor0_tb_dcount,   -- out (7:0);  -- counts the 256 transfers for one cell of visibilites, or 16 transfers for the centroid data. 
--        o_tb_cell      => cor0_tb_cell,     -- out (7:0);  -- in (7:0);  -- a "cell" is a 16x16 station block of correlations
--        o_tb_tile      => cor0_tb_tile,     -- out (9:0);  -- a "tile" is a 16x16 block of cells, i.e. a 256x256 station correlation.
--        o_tb_channel   => cor0_tb_channel,  -- out (23:0) -- first fine channel index for this correlation.
--       -- Start of a burst of data through the filterbank, 
--        -- Used in the testbench to trigger download of the data written into the CT2 memory.
--        o_FB_out_sof   => FB_out_sof        -- out std_logic
--    );
    
    
    dut_dcmac_to_cmac_same_freq : entity versal_dcmac_lib.segment_to_saxi 
    Port Map ( 
        -- Data in from the 100GE MAC
        i_MAC_clk               => dcmac_clk,
        i_MAC_rst               => dcmac_reset,
        
        i_dcmac_data_clk        => dcmac_clk,
        i_dcmac_data_rst        => dcmac_reset,

        i_clk_args_domain       => clk_300,
        i_clk_args_domain_rst   => '0',

        -- Streaming AXI interface - compatible with CMAC S_AXI
        -- RX
        o_rx_axis_tdata         => player_rx_axi_tdata,
        o_rx_axis_tkeep         => player_rx_axi_tkeep,
        o_rx_axis_tlast         => player_rx_axi_tlast,
        i_rx_axis_tready        => '1',
        o_rx_axis_tuser         => player_rx_axi_tuser,
        o_rx_axis_tvalid        => player_rx_axi_tvalid,
        
        o_dcmac_locked          => dcmac_locked_300m,

        -- Segmented Streaming AXI, 512
        i_data_to_receive       => dcmac_rx_data_0

    );
    
    dut_3_packet_player : entity versal_dcmac_lib.dcmac_packet_player
--    Generic (
--        g_DEBUG_ILA             : BOOLEAN := FALSE;
--        PLAYER_CDC_FIFO_DEPTH   : INTEGER := 1024        -- FIFO is 512 Wide, 9KB packets = 73728 bits, 512 * 256 = 131072, 256 depth allows ~1.88 9K packets, we are target packets sizes smaller than this.
--    );
    Port Map ( 
        i_clk                   => dcmac_clk,
        i_clk_reset             => dcmac_reset,
        
        i_bytes_to_transmit     => bytes_to_transmit_spead_v2,
        i_data_to_player        => player_rx_axi_tdata,
        i_data_to_player_wr     => player_rx_axi_tvalid,
        o_data_to_player_rdy    => open,
        
        o_dcmac_ready           => open,
        
        -- to DCMAC
        i_dcmac_clk             => dcmac_clk,
        i_dcmac_clk_rst         => dcmac_reset,

        -- segmented streaming AXI 
        o_data_to_transmit      => dcmac_tx_data_0,
        i_dcmac_ready           => dcmac_locked
    );
--    ----------------------------------------------------------------------------------
--    -- Emulate HBM
--    -- 3 Gbyte of memory for the first corner turn.
--    HBM3G_1 : entity correlator_lib.HBM_axi_tbModel
--    generic map (
--        AXI_ADDR_WIDTH => 32, -- : integer := 32;   -- Byte address width. This also defines the amount of data. Use the correct width for the HBM memory block, e.g. 28 bits for 256 MBytes.
--        AXI_ID_WIDTH => 1, -- integer := 1;
--        AXI_DATA_WIDTH => 512, -- integer := 256;  -- Must be a multiple of 32 bits.
--        READ_QUEUE_SIZE => 16, --  integer := 16;
--        MIN_LAG => 60,  -- integer := 80   
--        INCLUDE_PROTOCOL_CHECKER => TRUE,
--        RANDSEED => 43526, -- : natural := 12345;
--        LATENCY_LOW_PROBABILITY => 95, --  natural := 95;   -- probability, as a percentage, that non-zero gaps between read beats will be small (i.e. < 3 clocks)
--        LATENCY_ZERO_PROBABILITY => 80 -- natural := 80   -- probability, as a percentage, that the gap between read beats will be zero.
--    ) Port map (
--        i_clk => clk_300,
--        i_rst_n => ap_rst_n,
--        axi_awaddr   => HBM_axi_awaddr(0)(31 downto 0),
--        axi_awid     => HBM_axi_awid(0), -- in std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
--        axi_awlen    => HBM_axi_awlen(0),
--        axi_awsize   => HBM_axi_awsize(0),
--        axi_awburst  => HBM_axi_awburst(0),
--        axi_awlock   => HBM_axi_awlock(0),
--        axi_awcache  => HBM_axi_awcache(0),
--        axi_awprot   => HBM_axi_awprot(0),
--        axi_awqos    => HBM_axi_awqos(0), -- in(3:0)
--        axi_awregion => HBM_axi_awregion(0), -- in(3:0)
--        axi_awvalid  => HBM_axi_awvalid(0),
--        axi_awready  => HBM_axi_awready(0),
--        axi_wdata    => HBM_axi_wdata(0),
--        axi_wstrb    => HBM_axi_wstrb(0),
--        axi_wlast    => HBM_axi_wlast(0),
--        axi_wvalid   => HBM_axi_wvalid(0),
--        axi_wready   => HBM_axi_wready(0),
--        axi_bresp    => HBM_axi_bresp(0),
--        axi_bvalid   => HBM_axi_bvalid(0),
--        axi_bready   => HBM_axi_bready(0),
--        axi_bid      => HBM_axi_bid(0), -- out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
--        axi_araddr   => HBM_axi_araddr(0)(31 downto 0),
--        axi_arlen    => HBM_axi_arlen(0),
--        axi_arsize   => HBM_axi_arsize(0),
--        axi_arburst  => HBM_axi_arburst(0),
--        axi_arlock   => HBM_axi_arlock(0),
--        axi_arcache  => HBM_axi_arcache(0),
--        axi_arprot   => HBM_axi_arprot(0),
--        axi_arvalid  => HBM_axi_arvalid(0),
--        axi_arready  => HBM_axi_arready(0),
--        axi_arqos    => HBM_axi_arqos(0),
--        axi_arid     => HBM_axi_arid(0),
--        axi_arregion => HBM_axi_arregion(0),
--        axi_rdata    => HBM_axi_rdata(0),
--        axi_rresp    => HBM_axi_rresp(0),
--        axi_rlast    => HBM_axi_rlast(0),
--        axi_rvalid   => HBM_axi_rvalid(0),
--        axi_rready   => HBM_axi_rready(0),
--        i_write_to_disk => '0', -- : in std_logic;
--        i_fname => "", -- : in string
--        i_write_to_disk_addr => 0, -- in integer; -- address to start the memory dump at.
--        i_write_to_disk_size => 0, -- in integer; -- size in bytes
--        -- Initialisation of the memory
--        i_init_mem   => load_ct1_HBM,   -- in std_logic;
--        i_init_fname => g_TEST_CASE & g_CT1_INIT_FILENAME  -- in string
--    );
    
--    -- 3 GBytes second stage corner turn, first correlator cell
--    HBM3G_2 : entity correlator_lib.HBM_axi_tbModel
--    generic map (
--        AXI_ADDR_WIDTH => 32, -- : integer := 32;   -- Byte address width. This also defines the amount of data. Use the correct width for the HBM memory block, e.g. 28 bits for 256 MBytes.
--        AXI_ID_WIDTH => 1, -- integer := 1;
--        AXI_DATA_WIDTH => 512, -- integer := 256;  -- Must be a multiple of 32 bits.
--        READ_QUEUE_SIZE => 16, --  integer := 16;
--        MIN_LAG => 60,  -- integer := 80   
--        INCLUDE_PROTOCOL_CHECKER => TRUE,
--        RANDSEED => 43526, -- : natural := 12345;
--        LATENCY_LOW_PROBABILITY => 95, --  natural := 95;   -- probability, as a percentage, that non-zero gaps between read beats will be small (i.e. < 3 clocks)
--        LATENCY_ZERO_PROBABILITY => 80 -- natural := 80   -- probability, as a percentage, that the gap between read beats will be zero.
--    ) Port map (
--        i_clk => clk_300,
--        i_rst_n => ap_rst_n,
--        axi_awaddr   => HBM_axi_awaddr(1)(31 downto 0),
--        axi_awid     => HBM_axi_awid(1), -- in std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
--        axi_awlen    => HBM_axi_awlen(1),
--        axi_awsize   => HBM_axi_awsize(1),
--        axi_awburst  => HBM_axi_awburst(1),
--        axi_awlock   => HBM_axi_awlock(1),
--        axi_awcache  => HBM_axi_awcache(1),
--        axi_awprot   => HBM_axi_awprot(1),
--        axi_awqos    => HBM_axi_awqos(1), -- in(3:0)
--        axi_awregion => HBM_axi_awregion(1), -- in(3:0)
--        axi_awvalid  => HBM_axi_awvalid(1),
--        axi_awready  => HBM_axi_awready(1),
--        axi_wdata    => HBM_axi_wdata(1),
--        axi_wstrb    => HBM_axi_wstrb(1),
--        axi_wlast    => HBM_axi_wlast(1),
--        axi_wvalid   => HBM_axi_wvalid(1),
--        axi_wready   => HBM_axi_wready(1),
--        axi_bresp    => HBM_axi_bresp(1),
--        axi_bvalid   => HBM_axi_bvalid(1),
--        axi_bready   => HBM_axi_bready(1),
--        axi_bid      => HBM_axi_bid(1), -- out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
--        axi_araddr   => HBM_axi_araddr(1)(31 downto 0),
--        axi_arlen    => HBM_axi_arlen(1),
--        axi_arsize   => HBM_axi_arsize(1),
--        axi_arburst  => HBM_axi_arburst(1),
--        axi_arlock   => HBM_axi_arlock(1),
--        axi_arcache  => HBM_axi_arcache(1),
--        axi_arprot   => HBM_axi_arprot(1),
--        axi_arvalid  => HBM_axi_arvalid(1),
--        axi_arready  => HBM_axi_arready(1),
--        axi_arqos    => HBM_axi_arqos(1),
--        axi_arid     => HBM_axi_arid(1),
--        axi_arregion => HBM_axi_arregion(1),
--        axi_rdata    => HBM_axi_rdata(1),
--        axi_rresp    => HBM_axi_rresp(1),
--        axi_rlast    => HBM_axi_rlast(1),
--        axi_rvalid   => HBM_axi_rvalid(1),
--        axi_rready   => HBM_axi_rready(1),
--        i_write_to_disk => ct2_HBM_dump_trigger, -- in std_logic;
--        i_fname         => g_TEST_CASE & g_CT2_HBM_DUMP_FNAME,  -- in string
--        i_write_to_disk_addr => g_CT2_HBM_DUMP_ADDR,     -- in integer; Address to start the memory dump at.
--        i_write_to_disk_size => g_CT2_HBM_DUMP_SIZE, -- in integer; Size in bytes
--        -- Initialisation of the memory
--        -- The memory is loaded with the contents of the file i_init_fname in 
--        -- any clock cycle where i_init_mem is high.
--        i_init_mem   => load_ct2_HBM_corr1, -- in std_logic;
--        i_init_fname => g_TEST_CASE & g_CT2_HBM_CORR1_FILENAME  -- in string
--    );
    
--    -- 3 GBytes second stage corner turn, second correlator cell
--    HBM3G_3 : entity correlator_lib.HBM_axi_tbModel
--    generic map (
--        AXI_ADDR_WIDTH => 32, -- : integer := 32;   -- Byte address width. This also defines the amount of data. Use the correct width for the HBM memory block, e.g. 28 bits for 256 MBytes.
--        AXI_ID_WIDTH => 1, -- integer := 1;
--        AXI_DATA_WIDTH => 512, -- integer := 256;  -- Must be a multiple of 32 bits.
--        READ_QUEUE_SIZE => 16, --  integer := 16;
--        MIN_LAG => 60,  -- integer := 80   
--        INCLUDE_PROTOCOL_CHECKER => TRUE,
--        RANDSEED => 43526, -- : natural := 12345;
--        LATENCY_LOW_PROBABILITY => 95, --  natural := 95;   -- probability, as a percentage, that non-zero gaps between read beats will be small (i.e. < 3 clocks)
--        LATENCY_ZERO_PROBABILITY => 80 -- natural := 80   -- probability, as a percentage, that the gap between read beats will be zero.
--    ) Port map (
--        i_clk => clk_300,
--        i_rst_n => ap_rst_n,
--        axi_awaddr   => HBM_axi_awaddr(2)(31 downto 0),
--        axi_awid     => HBM_axi_awid(2), -- in std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
--        axi_awlen    => HBM_axi_awlen(2),
--        axi_awsize   => HBM_axi_awsize(2),
--        axi_awburst  => HBM_axi_awburst(2),
--        axi_awlock   => HBM_axi_awlock(2),
--        axi_awcache  => HBM_axi_awcache(2),
--        axi_awprot   => HBM_axi_awprot(2),
--        axi_awqos    => HBM_axi_awqos(2), -- in(3:0)
--        axi_awregion => HBM_axi_awregion(2), -- in(3:0)
--        axi_awvalid  => HBM_axi_awvalid(2),
--        axi_awready  => HBM_axi_awready(2),
--        axi_wdata    => HBM_axi_wdata(2),
--        axi_wstrb    => HBM_axi_wstrb(2),
--        axi_wlast    => HBM_axi_wlast(2),
--        axi_wvalid   => HBM_axi_wvalid(2),
--        axi_wready   => HBM_axi_wready(2),
--        axi_bresp    => HBM_axi_bresp(2),
--        axi_bvalid   => HBM_axi_bvalid(2),
--        axi_bready   => HBM_axi_bready(2),
--        axi_bid      => HBM_axi_bid(2), -- out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
--        axi_araddr   => HBM_axi_araddr(2)(31 downto 0),
--        axi_arlen    => HBM_axi_arlen(2),
--        axi_arsize   => HBM_axi_arsize(2),
--        axi_arburst  => HBM_axi_arburst(2),
--        axi_arlock   => HBM_axi_arlock(2),
--        axi_arcache  => HBM_axi_arcache(2),
--        axi_arprot   => HBM_axi_arprot(2),
--        axi_arvalid  => HBM_axi_arvalid(2),
--        axi_arready  => HBM_axi_arready(2),
--        axi_arqos    => HBM_axi_arqos(2),
--        axi_arid     => HBM_axi_arid(2),
--        axi_arregion => HBM_axi_arregion(2),
--        axi_rdata    => HBM_axi_rdata(2),
--        axi_rresp    => HBM_axi_rresp(2),
--        axi_rlast    => HBM_axi_rlast(2),
--        axi_rvalid   => HBM_axi_rvalid(2),
--        axi_rready   => HBM_axi_rready(2),
--        i_write_to_disk => '0', -- : in std_logic;
--        i_fname => "", -- : in string
--        i_write_to_disk_addr => 0, --  in integer; -- address to start the memory dump at.
--        i_write_to_disk_size => 0, --  in integer; -- size in bytes
--        -- Initialisation of the memory
--        i_init_mem   => load_ct2_HBM_corr2,   -- in std_logic;
--        i_init_fname => g_TEST_CASE & g_CT2_HBM_CORR2_FILENAME  -- in string
--    );
    
    
--    -- 512 MBytes visibilities output buffer for first correlator cell.
--    HBM512M_1 : entity correlator_lib.HBM_axi_tbModel
--    generic map (
--        AXI_ADDR_WIDTH => 32, -- : integer := 32;   -- Byte address width. This also defines the amount of data. Use the correct width for the HBM memory block, e.g. 28 bits for 256 MBytes.
--        AXI_ID_WIDTH => 1, -- integer := 1;
--        AXI_DATA_WIDTH => 512, -- integer := 256;  -- Must be a multiple of 32 bits.
--        READ_QUEUE_SIZE => 16, --  integer := 16;
--        MIN_LAG => 60,  -- integer := 80   
--        INCLUDE_PROTOCOL_CHECKER => TRUE,
--        RANDSEED => 43526, -- : natural := 12345;
--        LATENCY_LOW_PROBABILITY => 95, --  natural := 95;   -- probability, as a percentage, that non-zero gaps between read beats will be small (i.e. < 3 clocks)
--        LATENCY_ZERO_PROBABILITY => 80 -- natural := 80   -- probability, as a percentage, that the gap between read beats will be zero.
--    ) Port map (
--        i_clk => clk_300,
--        i_rst_n => ap_rst_n,
--        axi_awaddr   => HBM_axi_awaddr(3)(31 downto 0),
--        axi_awid     => HBM_axi_awid(3), -- in std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
--        axi_awlen    => HBM_axi_awlen(3),
--        axi_awsize   => HBM_axi_awsize(3),
--        axi_awburst  => HBM_axi_awburst(3),
--        axi_awlock   => HBM_axi_awlock(3),
--        axi_awcache  => HBM_axi_awcache(3),
--        axi_awprot   => HBM_axi_awprot(3),
--        axi_awqos    => HBM_axi_awqos(3), -- in(3:0)
--        axi_awregion => HBM_axi_awregion(3), -- in(3:0)
--        axi_awvalid  => HBM_axi_awvalid(3),
--        axi_awready  => HBM_axi_awready(3),
--        axi_wdata    => HBM_axi_wdata(3),
--        axi_wstrb    => HBM_axi_wstrb(3),
--        axi_wlast    => HBM_axi_wlast(3),
--        axi_wvalid   => HBM_axi_wvalid(3),
--        axi_wready   => HBM_axi_wready(3),
--        axi_bresp    => HBM_axi_bresp(3),
--        axi_bvalid   => HBM_axi_bvalid(3),
--        axi_bready   => HBM_axi_bready(3),
--        axi_bid      => HBM_axi_bid(3), -- out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
--        axi_araddr   => HBM_axi_araddr(3)(31 downto 0),
--        axi_arlen    => HBM_axi_arlen(3),
--        axi_arsize   => HBM_axi_arsize(3),
--        axi_arburst  => HBM_axi_arburst(3),
--        axi_arlock   => HBM_axi_arlock(3),
--        axi_arcache  => HBM_axi_arcache(3),
--        axi_arprot   => HBM_axi_arprot(3),
--        axi_arvalid  => HBM_axi_arvalid(3),
--        axi_arready  => HBM_axi_arready(3),
--        axi_arqos    => HBM_axi_arqos(3),
--        axi_arid     => HBM_axi_arid(3),
--        axi_arregion => HBM_axi_arregion(3),
--        axi_rdata    => HBM_axi_rdata(3),
--        axi_rresp    => HBM_axi_rresp(3),
--        axi_rlast    => HBM_axi_rlast(3),
--        axi_rvalid   => HBM_axi_rvalid(3),
--        axi_rready   => HBM_axi_rready(3),
--        i_write_to_disk => Dump_packet_hbm, -- : in std_logic;

--        i_fname                 => g_TEST_CASE & g_RDOUT_HBM_DUMP_FNAME,  -- in string
--        i_write_to_disk_addr    => g_RDOUT_HBM_DUMP_ADDR,     -- in integer; Address to start the memory dump at.
--        i_write_to_disk_size    => g_RDOUT_HBM_DUMP_SIZE, -- in integer; Size in bytes

--        -- Initialisation of the memory
--        i_init_mem   => load_packet_buffer,   -- in std_logic;
--        i_init_fname => g_TEST_CASE & g_VIS_CHECK_FILE  -- in string
--    );

--    -- 512 MBytes visibilities output buffer for the second correlator cell.
--    HBM512M_2 : entity correlator_lib.HBM_axi_tbModel
--    generic map (
--        AXI_ADDR_WIDTH => 32, -- : integer := 32;   -- Byte address width. This also defines the amount of data. Use the correct width for the HBM memory block, e.g. 28 bits for 256 MBytes.
--        AXI_ID_WIDTH => 1, -- integer := 1;
--        AXI_DATA_WIDTH => 512, -- integer := 256;  -- Must be a multiple of 32 bits.
--        READ_QUEUE_SIZE => 16, --  integer := 16;
--        MIN_LAG => 60,  -- integer := 80   
--        INCLUDE_PROTOCOL_CHECKER => TRUE,
--        RANDSEED => 43526, -- : natural := 12345;
--        LATENCY_LOW_PROBABILITY => 95, --  natural := 95;   -- probability, as a percentage, that non-zero gaps between read beats will be small (i.e. < 3 clocks)
--        LATENCY_ZERO_PROBABILITY => 80 -- natural := 80   -- probability, as a percentage, that the gap between read beats will be zero.
--    ) Port map (
--        i_clk => clk_300,
--        i_rst_n => ap_rst_n,
--        axi_awaddr   => HBM_axi_awaddr(4)(31 downto 0),
--        axi_awid     => HBM_axi_awid(4), -- in std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
--        axi_awlen    => HBM_axi_awlen(4),
--        axi_awsize   => HBM_axi_awsize(4),
--        axi_awburst  => HBM_axi_awburst(4),
--        axi_awlock   => HBM_axi_awlock(4),
--        axi_awcache  => HBM_axi_awcache(4),
--        axi_awprot   => HBM_axi_awprot(4),
--        axi_awqos    => HBM_axi_awqos(4), -- in(3:0)
--        axi_awregion => HBM_axi_awregion(4), -- in(3:0)
--        axi_awvalid  => HBM_axi_awvalid(4),
--        axi_awready  => HBM_axi_awready(4),
--        axi_wdata    => HBM_axi_wdata(4),
--        axi_wstrb    => HBM_axi_wstrb(4),
--        axi_wlast    => HBM_axi_wlast(4),
--        axi_wvalid   => HBM_axi_wvalid(4),
--        axi_wready   => HBM_axi_wready(4),
--        axi_bresp    => HBM_axi_bresp(4),
--        axi_bvalid   => HBM_axi_bvalid(4),
--        axi_bready   => HBM_axi_bready(4),
--        axi_bid      => HBM_axi_bid(4), -- out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
--        axi_araddr   => HBM_axi_araddr(4)(31 downto 0),
--        axi_arlen    => HBM_axi_arlen(4),
--        axi_arsize   => HBM_axi_arsize(4),
--        axi_arburst  => HBM_axi_arburst(4),
--        axi_arlock   => HBM_axi_arlock(4),
--        axi_arcache  => HBM_axi_arcache(4),
--        axi_arprot   => HBM_axi_arprot(4),
--        axi_arvalid  => HBM_axi_arvalid(4),
--        axi_arready  => HBM_axi_arready(4),
--        axi_arqos    => HBM_axi_arqos(4),
--        axi_arid     => HBM_axi_arid(4),
--        axi_arregion => HBM_axi_arregion(4),
--        axi_rdata    => HBM_axi_rdata(4),
--        axi_rresp    => HBM_axi_rresp(4),
--        axi_rlast    => HBM_axi_rlast(4),
--        axi_rvalid   => HBM_axi_rvalid(4),
--        axi_rready   => HBM_axi_rready(4),
--        i_write_to_disk => '0', -- : in std_logic;
--        i_fname => "", -- : in string
--        i_write_to_disk_addr => 0, -- : in integer; -- address to start the memory dump at.
--        i_write_to_disk_size => 0, -- : in integer; -- size in bytes
--        -- Initialisation of the memory
--        i_init_mem   => '0',   -- in std_logic;
--        i_init_fname => ""  -- in string
--    );
    
    
end Behavioral;
