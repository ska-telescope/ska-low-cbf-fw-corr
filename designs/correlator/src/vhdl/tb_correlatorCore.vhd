----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 20.08.2020 21:59:42
-- Design Name: 
-- Module Name: tb_vitisAccelCore - Behavioral
-- Description: 
--  Testbench for the correlator
-- 
----------------------------------------------------------------------------------
library IEEE;
library common_lib, correlator_lib;
library axi4_lib;
library xpm;
use xpm.vcomponents.all;
use IEEE.STD_LOGIC_1164.ALL;
use axi4_lib.axi4_stream_pkg.ALL;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;
--use dsp_top_lib.run2_tb_pkg.ALL;
use std.textio.all;
use IEEE.std_logic_textio.all;
use IEEE.NUMERIC_STD.ALL;
use common_lib.common_pkg.all;
use std.env.finish;

library technology_lib;
USE technology_lib.tech_mac_100g_pkg.ALL;

entity tb_correlatorCore is
    generic (
        g_SPS_PACKETS_PER_FRAME : integer := 128;
        g_CORRELATORS : integer := 2; -- Number of correlator instances to instantiate (0, 1, 2)
        g_USE_DUMMY_FB : boolean := TRUE;  -- use a dummy version of the filterbank to speed up simulation.
        -- Location of the test case; All the other filenames in generics here are in this directory
        g_TEST_CASE : string := "../../../../../../../../low-cbf-model/src_atomic/run_cor_1sa_6stations_cof/";
        --g_TEST_CASE : string := "../../../../../../../";
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
        g_CT2_HBM_DUMP_FNAME : string := "ct2_hbm_dump.txt"
    );
end tb_correlatorCore;

architecture Behavioral of tb_correlatorCore is

    signal ap_clk : std_logic := '0';
    signal clk100 : std_logic := '0';
    signal ap_rst_n : std_logic := '0';
    signal mc_lite_mosi : t_axi4_lite_mosi;
    signal mc_lite_miso : t_axi4_lite_miso;

    signal LFAADone : std_logic := '0';
    -- The shared memory in the shell is 128Kbytes;
    -- i.e. 32k x 4 byte words. 
    type memType is array(32767 downto 0) of integer;
    shared variable sharedMem : memType;
    
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
    
    COMPONENT axi_bram_RegisterSharedMem
    PORT (
        s_axi_aclk : IN STD_LOGIC;
        s_axi_aresetn : IN STD_LOGIC;
        s_axi_awaddr : IN STD_LOGIC_VECTOR(16 DOWNTO 0);
        s_axi_awlen : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        s_axi_awsize : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        s_axi_awburst : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_awlock : IN STD_LOGIC;
        s_axi_awcache : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        s_axi_awprot : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        s_axi_awvalid : IN STD_LOGIC;
        s_axi_awready : OUT STD_LOGIC;
        s_axi_wdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
        s_axi_wstrb : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        s_axi_wlast : IN STD_LOGIC;
        s_axi_wvalid : IN STD_LOGIC;
        s_axi_wready : OUT STD_LOGIC;
        s_axi_bresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_bvalid : OUT STD_LOGIC;
        s_axi_bready : IN STD_LOGIC;
        s_axi_araddr : IN STD_LOGIC_VECTOR(16 DOWNTO 0);
        s_axi_arlen : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        s_axi_arsize : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        s_axi_arburst : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_arlock : IN STD_LOGIC;
        s_axi_arcache : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        s_axi_arprot : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        s_axi_arvalid : IN STD_LOGIC;
        s_axi_arready : OUT STD_LOGIC;
        s_axi_rdata : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
        s_axi_rresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_rlast : OUT STD_LOGIC;
        s_axi_rvalid : OUT STD_LOGIC;
        s_axi_rready : IN STD_LOGIC;
        bram_rst_a : OUT STD_LOGIC;
        bram_clk_a : OUT STD_LOGIC;
        bram_en_a : OUT STD_LOGIC;
        bram_we_a : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        bram_addr_a : OUT STD_LOGIC_VECTOR(16 DOWNTO 0);
        bram_wrdata_a : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
        bram_rddata_a : IN STD_LOGIC_VECTOR(31 DOWNTO 0));
    END COMPONENT;
    
    --signal s_axi_aclk :  STD_LOGIC;
    --signal s_axi_aresetn :  STD_LOGIC;
    signal m00_awaddr :  STD_LOGIC_VECTOR(63 DOWNTO 0);
    signal m00_awlen :  STD_LOGIC_VECTOR(7 DOWNTO 0);
    signal m00_awsize :  STD_LOGIC_VECTOR(2 DOWNTO 0);
    signal m00_awburst :  STD_LOGIC_VECTOR(1 DOWNTO 0);
    signal m00_awlock :  STD_LOGIC;
    signal m00_awcache :  STD_LOGIC_VECTOR(3 DOWNTO 0);
    signal m00_awprot :  STD_LOGIC_VECTOR(2 DOWNTO 0);
    signal m00_awvalid :  STD_LOGIC;
    signal m00_awready :  STD_LOGIC;
    signal m00_wdata :  STD_LOGIC_VECTOR(31 DOWNTO 0);
    signal m00_wstrb :  STD_LOGIC_VECTOR(3 DOWNTO 0);
    signal m00_wlast :  STD_LOGIC;
    signal m00_wvalid :  STD_LOGIC;
    signal m00_wready :  STD_LOGIC;
    signal m00_bresp :  STD_LOGIC_VECTOR(1 DOWNTO 0);
    signal m00_bvalid :  STD_LOGIC;
    signal m00_bready :  STD_LOGIC;
    signal m00_araddr :  STD_LOGIC_VECTOR(63 DOWNTO 0);
    signal m00_arlen :  STD_LOGIC_VECTOR(7 DOWNTO 0);
    signal m00_arsize : STD_LOGIC_VECTOR(2 DOWNTO 0);
    signal m00_arburst : STD_LOGIC_VECTOR(1 DOWNTO 0);
    signal m00_arlock :  STD_LOGIC;
    signal m00_arcache :  STD_LOGIC_VECTOR(3 DOWNTO 0);
    signal m00_arprot :  STD_LOGIC_VECTOR(2 DOWNTO 0);
    signal m00_arvalid :  STD_LOGIC;
    signal m00_arready :  STD_LOGIC;
    signal m00_rdata :  STD_LOGIC_VECTOR(31 DOWNTO 0);
    signal m00_rresp :  STD_LOGIC_VECTOR(1 DOWNTO 0);
    signal m00_rlast :  STD_LOGIC;
    signal m00_rvalid :  STD_LOGIC;
    signal m00_rready :  STD_LOGIC;
    
    constant g_HBM_INTERFACES : integer := 5;
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
    
    signal eth100_rx_axi_tdata : std_logic_vector(511 downto 0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
    signal eth100_rx_axi_tkeep : std_logic_vector(63 downto 0);  -- one bit per byte in i_axi_tdata
    signal eth100_rx_axi_tlast : std_logic;
    signal eth100_rx_axi_tuser : std_logic_vector(79 downto 0);  -- Timestamp for the packet.
    signal eth100_rx_axi_tvalid : std_logic;
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

    ap_clk <= not ap_clk after 1.666 ns; -- 300 MHz clock.
    clk100 <= not clk100 after 5 ns; -- 100 MHz clock
    eth100G_clk <= not eth100G_clk after 1.553 ns; -- 322 MHz

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
        SetupDone <= '0';
        ap_rst_n <= '1';
        load_ct1_HBM <= '0';
        load_ct2_HBM_corr1 <= '0';
        load_ct2_HBM_corr2 <= '0';
        FILE_OPEN(RegCmdfile, g_TEST_CASE & g_REGISTER_INIT_FILENAME, READ_MODE);
        
        for i in 1 to 10 loop
            WAIT UNTIL RISING_EDGE(ap_clk);
        end loop;
        ap_rst_n <= '0';
        for i in 1 to 10 loop
             WAIT UNTIL RISING_EDGE(ap_clk);
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
        
        wait until rising_edge(ap_clk);
        
        load_ct1_HBM <= '0';
        load_ct2_HBM_corr1 <= '0';
        load_ct2_HBM_corr2 <= '0';
        
        
        for i in 1 to 100 loop
             WAIT UNTIL RISING_EDGE(ap_clk);
        end loop;
        
        -- For some reason the first transaction doesn't work; this is just a dummy transaction
        -- Arguments are       clk,    miso      ,    mosi     , 4-byte word Addr, write ?, data)
        axi_lite_transaction(ap_clk, mc_lite_miso, mc_lite_mosi, 0,    true, x"00000000");
       
        -- Addresses in the axi lite control module
        -- ADDR_AP_CTRL         = 6'h00,
        -- ADDR_DMA_SRC_0       = 6'h10,
        -- ADDR_DMA_DEST_0      = 6'h14,
        -- ADDR_DMA_SHARED_0    = 6'h18,
        -- ADDR_DMA_SHARED_1    = 6'h1C,
        -- ADDR_DMA_SIZE        = 6'h20,
        --
        axi_lite_transaction(ap_clk, mc_lite_miso, mc_lite_mosi, 6, true, x"DEF20000");  -- Full address of the shared memory; arbitrary so long as it is 128K aligned.
        axi_lite_transaction(ap_clk, mc_lite_miso, mc_lite_mosi, 7, true, x"56789ABC");  -- High 32 bits of the  address of the shared memory; arbitrary.
        
        -- Pseudo code :
        --
        --  Repeat while there are commands in the command file:
        --    - Read command from the file (either read or write, together with the ARGs register address)
        --        - Possible commands : [read address length]   <-- Does a register read.
        --                              [write address length]  <-- Does a register write
        --    - If this is a write, then read the write data from the file, and copy into a shared variable used by the memory.
        --    - trigger the kernel to do the register read/write.
        --  Trigger sending of the 100G test data.
        --

        while (not endfile(RegCmdfile)) loop 
            sim_register_input_file_counter <= sim_register_input_file_counter +1;
            readline(RegCmdfile, RegLine_in);
            
            assert False report "Processing register command " & RegLine_in.all severity note;
            
            -- line_in should have a command; process it.
            read(RegLine_in,cmd_str,RegGood);   -- cmd should be either "rd" or "wr"
            hread(RegLine_in,regAddr,regGood);  -- then the register address
            hread(RegLine_in,regSize,regGood);  -- then the number of words
            
            if strcmp(cmd_str,"wr") then
            
                -- The command is a write, so get the write data into the shared memory variable "sharedMem"
                -- Divide by 4 to get the number of words, since the size is in bytes.
                for i in 0 to (to_integer(unsigned(regSize(31 downto 2)))-1) loop
                    readline(regCmdFile, regLine_in);
                    hread(regLine_in,regData,regGood);
                    sharedMem(i) := to_integer(signed(regData));
                end loop;
                
                -- put in the source address. For writes, the source address is the shared memory, which is mapped to word address 0x8000 (=byte address 0x20000) in the ARGS address space.
                axi_lite_transaction(ap_clk, mc_lite_miso, mc_lite_mosi, 4, true, x"00020000"); 
                -- Put in the destination address in the ARGS memory space.
                axi_lite_transaction(ap_clk, mc_lite_miso, mc_lite_mosi, 5, true, regAddr);
                -- Size = number of bytes to transfer. 
                axi_lite_transaction(ap_clk, mc_lite_miso, mc_lite_mosi, 8, true, regSize);

            elsif strcmp(cmd_str,"rd") then
                -- Put in the source address
                axi_lite_transaction(ap_clk, mc_lite_miso, mc_lite_mosi, 4, true, regAddr);      -- source Address
                -- Destination Address - the shared memory. 
                axi_lite_transaction(ap_clk, mc_lite_miso, mc_lite_mosi, 5, true, x"00040000");  
                axi_lite_transaction(ap_clk, mc_lite_miso, mc_lite_mosi, 8, true, regSize);      -- size of the transaction in bytes
                
            else
                assert False report "Bad data in register command file" severity error;
            end if;
   
            -- trigger the command
            axi_lite_transaction(ap_clk, mc_lite_miso, mc_lite_mosi, 0, true, x"00000001");
        
            -- Poll until the command is done
            readResult := (others => '0');
            while (readResult(1) = '0') loop
                axi_lite_rd(ap_clk, mc_lite_miso, mc_lite_mosi, 0, readResult);
                for i in 1 to 10 loop
                    WAIT UNTIL RISING_EDGE(ap_clk);
                end loop;
            end loop;
            
        end loop;

        wait UNTIL RISING_EDGE(ap_clk);
        wait UNTIL RISING_EDGE(ap_clk);
        wait UNTIL RISING_EDGE(ap_clk);
        wait UNTIL RISING_EDGE(ap_clk);
        if (g_LOAD_CT2_HBM_CORR1 or g_LOAD_CT2_HBM_CORR2) then
            ct2_readout_start <= '1';
        else
            ct2_readout_start <= '0';
        end if;
        wait UNTIL RISING_EDGE(ap_clk);
        ct2_readout_start <= '0';

        if validMemRstActive = '1' then
            wait until validMemRstActive = '0';
        end if;
        
        SetupDone <= '1';
        
        wait;
    end process;
    ct2_readout_buffer <= '0';
    ct2_readout_frameCount <= (others => '0');
    
    m00_bram_addr_word <= m00_bram_addr(16 downto 2);
    
    process(m00_bram_clk)
    begin
        if rising_edge(m00_bram_clk) then
            m00_bram_rdData <= std_logic_vector(to_signed(sharedMem(to_integer(unsigned(m00_bram_addr_word))),32)); 
           
            if m00_bram_we(0) = '1' and m00_bram_en = '1' then
                sharedMem(to_integer(unsigned(m00_bram_addr_word))) := to_integer(signed(m00_bram_wrData));
            end if;
           
            assert (m00_bram_we(3 downto 0) /= "0000" or m00_bram_we(3 downto 0) /= "1111") report "Byte wide write enables should never occur to shared memory" severity error;
           
        end if;
    end process;
    
    -----------------------------------------------------------------------------------
    -----------------------------------------------------------------------------------
    -- axi BRAM controller to interface to the shared memory for register reads and writes.
    
    registerSharedMem : axi_bram_RegisterSharedMem
    PORT MAP (
        s_axi_aclk => ap_clk,
        s_axi_aresetn => ap_rst_n,
        s_axi_awaddr => m00_awaddr(16 downto 0),
        s_axi_awlen => m00_awlen,
        s_axi_awsize => m00_awsize,
        s_axi_awburst => m00_awburst,
        s_axi_awlock => '0',
        s_axi_awcache => m00_awcache,
        s_axi_awprot => m00_awprot,
        s_axi_awvalid => m00_awvalid,
        s_axi_awready => m00_awready,
        s_axi_wdata => m00_wdata,
        s_axi_wstrb => m00_wstrb,
        s_axi_wlast => m00_wlast,
        s_axi_wvalid => m00_wvalid,
        s_axi_wready => m00_wready,
        s_axi_bresp => m00_bresp,
        s_axi_bvalid => m00_bvalid,
        s_axi_bready => m00_bready,
        s_axi_araddr => m00_araddr(16 downto 0),
        s_axi_arlen => m00_arlen,
        s_axi_arsize => m00_arsize,
        s_axi_arburst => m00_arburst,
        s_axi_arlock => '0',
        s_axi_arcache => m00_arcache,
        s_axi_arprot => m00_arprot,
        s_axi_arvalid => m00_arvalid,
        s_axi_arready => m00_arready,
        s_axi_rdata => m00_rdata,
        s_axi_rresp => m00_rresp,
        s_axi_rlast => m00_rlast,
        s_axi_rvalid => m00_rvalid,
        s_axi_rready => m00_rready,
        bram_rst_a => open,   -- OUT STD_LOGIC;
        bram_clk_a => m00_bram_clk, -- OUT STD_LOGIC;
        bram_en_a  => m00_bram_en, -- OUT STD_LOGIC;
        bram_we_a  => m00_bram_we, -- OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        bram_addr_a => m00_bram_addr, -- OUT STD_LOGIC_VECTOR(16 DOWNTO 0);
        bram_wrdata_a => m00_bram_wrData, -- OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
        bram_rddata_a => m00_bram_rdData  -- IN STD_LOGIC_VECTOR(31 DOWNTO 0)
    );
    
    -------------------------------------------------------------------------------------------
    -- 100 GE data input
    --  
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
        
        eth100_rx_axi_tdata <= (others => '0'); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
        eth100_rx_axi_tkeep <= (others => '0'); -- 64 bits,  one bit per byte in i_axi_tdata
        eth100_rx_axi_tlast <= '0';    -- in std_logic;
        eth100_rx_axi_tuser <= (others => '0'); -- 80 bit timestamp for the packet.
        eth100_rx_axi_tvalid <= '0';   -- in std_logic;        
        
        FILE_OPEN(cmdfile,g_TEST_CASE & g_SPS_DATA_FILENAME,READ_MODE);
        wait until SetupDone = '1';
        
        wait until rising_edge(eth100G_clk);
        
        while (not endfile(cmdfile)) loop 
            readline(cmdfile, line_in);
            hread(line_in, sps_axi_repeats, good);
            hread(line_in, sps_axi_tvalid, good);
            hread(line_in, sps_axi_tlast, good);
            hread(line_in, sps_axi_tkeep, good);
            hread(line_in, sps_axi_tdata, good);
            hread(line_in, sps_axi_tuser, good);
            
            for i in 0 to 63 loop
                eth100_rx_axi_tdata(i*8+7 downto i*8) <= sps_axi_tdata(503 - i*8 + 8 downto (504 - i*8)) ;  -- 512 bits
                eth100_rx_axi_tkeep(i) <= sps_axi_tkeep(63 - i);
            end loop;
            eth100_rx_axi_tlast <= sps_axi_tlast(0);
            eth100_rx_axi_tuser <= sps_axi_tuser;
            eth100_rx_axi_tvalid <= sps_axi_tvalid(0);
            
            wait until rising_edge(eth100G_clk);
            while sps_axi_repeats /= "0000000000000000" loop
                sps_axi_repeats := std_logic_vector(unsigned(sps_axi_repeats) - 1);
                wait until rising_edge(eth100G_clk);
            end loop;
        end loop;
        
        LFAADone <= '1';
        wait;
        report "number of tx packets all received";
        wait for 5 us;
        report "simulation successfully finished";
        finish;
    end process;
    
    
    -- write the output 100GE axi bus to a file.
    tvalid_ext <= "000" & eth100_tx_axi_tvalid;
    tlast_ext <= "000" & eth100_tx_axi_tlast;
    tuser_ext <= "000" & eth100_tx_axi_tuser;
    
    process
		file logfile: TEXT;
		--variable data_in : std_logic_vector((BIT_WIDTH-1) downto 0);
		variable line_out : Line;
    begin
	    FILE_OPEN(logfile, g_TEST_CASE &  g_SDP_FILENAME, WRITE_MODE);
		
		loop
            -- wait until we need to read another command
            -- need to when : rising clock edge, and last_cmd_cycle high
            -- read the next entry from the file and put it out into the command queue.
            wait until rising_edge(eth100G_clk);
            if eth100_tx_axi_tvalid = '1' then
                
                -- write data to the file
                hwrite(line_out,FOUR0,RIGHT,4);  -- repeats of this line, tied to 0
                
                hwrite(line_out,tvalid_ext,RIGHT,2); -- tvalid
                hwrite(line_out,tlast_ext,RIGHT,2);  -- tlast
                hwrite(line_out,eth100_tx_axi_tkeep,RIGHT,18);    -- tkeep
                hwrite(line_out,eth100_tx_axi_tdata,RIGHT,130); -- tdata
                hwrite(line_out,tlast_ext,RIGHT,2); -- tuser
                
                writeline(logfile,line_out);
            end if;
         
        end loop;
        file_close(logfile);	
        wait;
    end process;
    
    -- timeslave and 100GE core is outside correlator_core, and contains a register slave.
    -- drive the signals here.
    axi4_lite_miso_dummy.awready <= '1'; --  t_axi4_lite_miso;
    axi4_lite_miso_dummy.wready <= '1';
    axi4_lite_miso_dummy.bresp <= (others => '0');
    axi4_lite_miso_dummy.bvalid <= '0';
    axi4_lite_miso_dummy.arready <= '1';
    axi4_lite_miso_dummy.rdata <= (others => '0');
    axi4_lite_miso_dummy.rresp <= (others => '0');
    axi4_lite_miso_dummy.rvalid <= '0';
    
    axi4_full_miso_dummy.awready <= '1'; --  t_axi4_lite_miso;
    axi4_full_miso_dummy.wready <= '1';
    axi4_full_miso_dummy.bresp <= (others => '0');
    axi4_full_miso_dummy.bvalid <= '0';
    axi4_full_miso_dummy.arready <= '1';
    axi4_full_miso_dummy.rdata <= (others => '0');
    axi4_full_miso_dummy.rresp <= (others => '0');
    axi4_full_miso_dummy.rvalid <= '0';
    axi4_full_miso_dummy.bid <= (others => '0');
    axi4_full_miso_dummy.buser <= (others => '0');
    
    
    ------------------------------------------------------------
    -- Checking of the data written to the HBM by the correlator
    
    -- split visibility and visibility meta data into 32 bit words
    -- for easier comparison with the model data.
    cor0_tb_data_check(0) <= cor0_tb_data(31 downto 0);
    cor0_tb_data_check(1) <= cor0_tb_data(63 downto 32);
    cor0_tb_data_check(2) <= cor0_tb_data(95 downto 64);
    cor0_tb_data_check(3) <= cor0_tb_data(127 downto 96);
    cor0_tb_data_check(4) <= cor0_tb_data(159 downto 128);
    cor0_tb_data_check(5) <= cor0_tb_data(191 downto 160);
    cor0_tb_data_check(6) <= cor0_tb_data(223 downto 192);
    cor0_tb_data_check(7) <= cor0_tb_data(255 downto 224);    
    
    process
        file vis_check_file: TEXT;
        variable line_in : Line;
        variable good : boolean;
        variable vis256bits : t_slv_32_arr(7 downto 0);
        variable data_addr : std_logic_vector(31 downto 0);
    begin
        
        FILE_OPEN(vis_check_file,g_TEST_CASE & g_VIS_CHECK_FILE,READ_MODE);
        visCheckDone <= '0';
        while (not endfile(vis_check_file)) loop
            --
            -- Format is the same as the memory initialisation for HBM model.
            -- Each line in the file has the address, then 512 bytes, 
            --  consisting of 128 x 32 bits, where each 32 bits is an 8 digit hex value.
            -- e.g. 
            --  00000000 00000000 00000001 00000002 ... 0000007F
            --   addr     word 0   word 1   word 2  ... word 127
            --
            readline(vis_check_file, line_in);
            -- read the address word, and discard. We assume the data is in order.
            hread(line_in, data_addr, good);
            for j256 in 0 to 15 loop -- 16 x 256 bit words on a line in the text file.
                -- Visibility data to be checked consists of 256 bit words, i.e. 8 x (32bit words)
                for i in 0 to 7 loop
                    hread(line_in, vis256bits(i), good);
                end loop;
                visCheckData <= vis256bits;
                -- wait for a word of visibility data from the correlator
                wait until (falling_edge(ap_clk) and (cor0_tb_visValid = '1'));
                assert (vis256bits = cor0_tb_data_check) report "Visibility data does not match" severity error;
            end loop;
        end loop;
        
        visCheckDone <= '1';
        report "Finished checking visibility data for correlator";
        wait;
    end process;

    
    -- Check visibility meta data
    process
        file vis_meta_check_file: TEXT;
        variable line_in : Line;
        variable good : boolean;
        variable visMeta256bits : t_slv_32_arr(7 downto 0);
        variable data_addr : std_logic_vector(31 downto 0);
    begin
        
        FILE_OPEN(vis_meta_check_file,g_TEST_CASE & g_META_CHECK_FILE,READ_MODE);
        visMetaCheckDone <= '0';
        while (not endfile(vis_meta_check_file)) loop 
            -- file format as for the visibility data, see visibility check process above.
            readline(vis_meta_check_file, line_in);
            -- read the address word, and discard. We assume the data is in order.
            hread(line_in, data_addr, good);
            for j256 in 0 to 15 loop -- 16 x 256 bit words on a line in the text file.
                -- Visibility data to be checked consists of 256 bit words, i.e. 8 x (32bit words)
                for i in 0 to 7 loop
                    hread(line_in, visMeta256bits(i), good);
                end loop;
                visMetaCheckData <= visMeta256bits;
                -- wait for a word of visibility data from the correlator
                wait until (falling_edge(ap_clk) and (cor0_tb_TCIValid = '1'));
                assert (visMeta256bits = cor0_tb_data_check) report "Visibility Meta data (TCI, FD) does not match" severity error;
            end loop;
        end loop;
        
        visMetaCheckDone <= '1';
        report "Finished checking visibility meta data for correlator";
        wait;
    end process;
    
    -- Trigger dump of the CT2 data after it has been written from the filterbank
    process(ap_clk)
    begin
        if rising_edge(ap_clk) then
            if FB_out_sof = '1' then
                sof_count <= sof_count + 1;
            end if;
            
            if sof_count = 2 and FB_out_sof = '1' then
                -- Wait about 50 us for the copy to HBM to be complete, then trigger dump of the HBM contents to a file.
                dump_trigger_count <= 65535;
            elsif (dump_trigger_count /= 0) then
                dump_trigger_count <= dump_trigger_count - 1;
            end if;
            
            if dump_trigger_count = 1 then
                ct2_HBM_dump_trigger <= '1';
            else
                ct2_HBM_dump_trigger <= '0';
            end if;
            
        end if;
    end process;
    
    
    dut : entity correlator_lib.correlator_core
    generic map (
        g_SIMULATION => TRUE, -- BOOLEAN;  -- when true, the 100GE core is disabled and instead the lbus comes from the top level pins
        g_USE_META => FALSE,   -- BOOLEAN;  -- puts meta data in place of the filterbank data in the corner turn, to help debug the corner turn.
        -- GLOBAL GENERICS for PERENTIE LOGIC
        g_DEBUG_ILA                => FALSE, --  BOOLEAN
        g_SPS_PACKETS_PER_FRAME    => g_SPS_PACKETS_PER_FRAME,   --  allowed values are 32, 64 or 128. 32 and 64 are for simulation. For real system, use 128.
        C_S_AXI_CONTROL_ADDR_WIDTH => 7,   -- integer := 7;
        C_S_AXI_CONTROL_DATA_WIDTH => 32,  -- integer := 32;
        C_M_AXI_ADDR_WIDTH => 64,          -- integer := 64;
        C_M_AXI_DATA_WIDTH => 32,          -- integer := 32;
        C_M_AXI_ID_WIDTH => 1,             -- integer := 1
        -- All the HBM interfaces are the same width;
        -- Actual interfaces used are : 
        --  M01, 3 Gbytes HBM; first stage corner turn, between LFAA ingest and the filterbanks
        --  M02, 3 Gbytes HBM; Correlator HBM for fine channels going to the first correlator instance; buffer between the filterbanks and the correlator
        --  M03, 3 Gbytes HBM; Correlator HBM for fine channels going to the Second correlator instance; buffer between the filterbanks and the correlator
        --  M04, 512 Mbytes HBM; visibilities from first correlator instance
        --  M05, 512 Mbytes HBM; visibilities from second correlator instance
        g_HBM_INTERFACES     => g_HBM_INTERFACES,   -- integer := 5;
        g_HBM_AXI_ADDR_WIDTH => 64,  -- integer := 64;
        g_HBM_AXI_DATA_WIDTH => 512, -- integer := 512;
        g_HBM_AXI_ID_WIDTH   => 1,   -- integer := 1
        -- Number of correlator blocks to instantiate.
        g_CORRELATORS        => g_CORRELATORS,  -- integer := 2
        g_USE_DUMMY_FB       => g_USE_DUMMY_FB
    ) port map (
        ap_clk   => ap_clk, --  in std_logic;
        ap_rst_n => ap_rst_n, -- in std_logic;
        
        -----------------------------------------------------------------------
        -- Ports used for simulation only.
        --
        -- Received data from 100GE
        i_axis_tdata => eth100_rx_axi_tdata,   -- in (511:0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
        i_axis_tkeep => eth100_rx_axi_tkeep,   -- in (63:0);  -- one bit per byte in i_axi_tdata
        i_axis_tlast => eth100_rx_axi_tlast,   -- in std_logic;
        i_axis_tuser => eth100_rx_axi_tuser,   -- in (79:0);  -- Timestamp for the packet.
        i_axis_tvalid => eth100_rx_axi_tvalid, -- in std_logic;
        -- Data to be transmitted on 100GE
        o_axis_tdata => eth100_tx_axi_tdata, -- out std_logic_vector(511 downto 0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
        o_axis_tkeep => eth100_tx_axi_tkeep, -- out std_logic_vector(63 downto 0);  -- one bit per byte in i_axi_tdata
        o_axis_tlast => eth100_tx_axi_tlast, -- out std_logic;                      
        o_axis_tuser => eth100_tx_axi_tuser, -- out std_logic;  
        o_axis_tvalid => eth100_tx_axi_tvalid, -- out std_logic;
        i_axis_tready    => '1',
        
        i_eth100g_clk       => eth100G_clk, --  in std_logic;
        i_eth100g_locked    => eth100G_locked,       -- in std_logic;
        -- reset of the valid memory is in progress.
        o_validMemRstActive => validMemRstActive, -- out std_logic;

        i_PTP_time_ARGs_clk  => (others => '0'), -- in (79:0);
        o_eth100_reset_final => open, -- out std_logic;
        o_fec_enable_322m    => open, -- out std_logic;
        
        i_eth100G_rx_total_packets => (others => '0'), -- in (31:0);
        i_eth100G_rx_bad_fcs       => (others => '0'), -- in (31:0);
        i_eth100G_rx_bad_code      => (others => '0'), -- in (31:0);
        i_eth100G_tx_total_packets => (others => '0'), -- in (31:0);
        
        -- registers in the timeslave core
        o_cmac_mc_lite_mosi => open, --  out t_axi4_lite_mosi; 
        i_cmac_mc_lite_miso => axi4_lite_miso_dummy, --  in t_axi4_lite_miso;
        o_timeslave_mc_full_mosi => open, --  out t_axi4_full_mosi;
        i_timeslave_mc_full_miso => axi4_full_miso_dummy, -- in t_axi4_full_miso;

        --  Note: A minimum subset of AXI4 memory mapped signals are declared.  AXI
        --  signals omitted from these interfaces are automatically inferred with the
        -- optimal values for Xilinx SDx systems.  This allows Xilinx AXI4 Interconnects
        -- within the system to be optimized by removing logic for AXI4 protocol
        -- features that are not necessary. When adapting AXI4 masters within the RTL
        -- kernel that have signals not declared below, it is suitable to add the
        -- signals to the declarations below to connect them to the AXI4 Master.
        --
        -- List of omitted signals - effect
        -- -------------------------------
        --  ID - Transaction ID are used for multithreading and out of order transactions.  This increases complexity. This saves logic and increases Fmax in the system when ommited.
        -- SIZE - Default value is log2(data width in bytes). Needed for subsize bursts. This saves logic and increases Fmax in the system when ommited.
        -- BURST - Default value (0b01) is incremental.  Wrap and fixed bursts are not recommended. This saves logic and increases Fmax in the system when ommited.
        -- LOCK - Not supported in AXI4
        -- CACHE - Default value (0b0011) allows modifiable transactions. No benefit to changing this.
        -- PROT - Has no effect in SDx systems.
        -- QOS - Has no effect in SDx systems.
        -- REGION - Has no effect in SDx systems.
        -- USER - Has no effect in SDx systems.
        --  RESP - Not useful in most SDx systems.
        --------------------------------------------------------------------------------------
        --  AXI4-Lite slave interface
        s_axi_control_awvalid => mc_lite_mosi.awvalid, --  in std_logic;
        s_axi_control_awready => mc_lite_miso.awready, --  out std_logic;
        s_axi_control_awaddr  => mc_lite_mosi.awaddr(6 downto 0), -- in std_logic_vector(C_S_AXI_CONTROL_ADDR_WIDTH-1 downto 0);
        s_axi_control_wvalid  => mc_lite_mosi.wvalid, -- in std_logic;
        s_axi_control_wready  => mc_lite_miso.wready, -- out std_logic;
        s_axi_control_wdata   => mc_lite_mosi.wdata(31 downto 0), -- in std_logic_vector(C_S_AXI_CONTROL_DATA_WIDTH-1 downto 0);
        s_axi_control_wstrb   => mc_lite_mosi.wstrb(3 downto 0), -- in std_logic_vector(C_S_AXI_CONTROL_DATA_WIDTH/8-1 downto 0);
        s_axi_control_arvalid => mc_lite_mosi.arvalid, -- in std_logic;
        s_axi_control_arready => mc_lite_miso.arready, -- out std_logic;
        s_axi_control_araddr  => mc_lite_mosi.araddr(6 downto 0), -- in std_logic_vector(C_S_AXI_CONTROL_ADDR_WIDTH-1 downto 0);
        s_axi_control_rvalid  => mc_lite_miso.rvalid,  -- out std_logic;
        s_axi_control_rready  => mc_lite_mosi.rready, -- in std_logic;
        s_axi_control_rdata   => mc_lite_miso.rdata(31 downto 0), -- out std_logic_vector(C_S_AXI_CONTROL_DATA_WIDTH-1 downto 0);
        s_axi_control_rresp   => mc_lite_miso.rresp(1 downto 0), -- out std_logic_vector(1 downto 0);
        s_axi_control_bvalid  => mc_lite_miso.bvalid, -- out std_logic;
        s_axi_control_bready  => mc_lite_mosi.bready, -- in std_logic;
        s_axi_control_bresp   => mc_lite_miso.bresp(1 downto 0), -- out std_logic_vector(1 downto 0);
  
        -- AXI4 master interface for accessing registers : m00_axi
        m00_axi_awvalid => m00_awvalid, -- out std_logic;
        m00_axi_awready => m00_awready, -- in std_logic;
        m00_axi_awaddr  => m00_awaddr,  -- out std_logic_vector(C_M_AXI_ADDR_WIDTH-1 downto 0);
        m00_axi_awid    => open, --s_axi_awid,    -- out std_logic_vector(C_M_AXI_ID_WIDTH - 1 downto 0);
        m00_axi_awlen   => m00_awlen,   -- out std_logic_vector(7 downto 0);
        m00_axi_awsize  => m00_awsize,  -- out std_logic_vector(2 downto 0);
        m00_axi_awburst => m00_awburst, -- out std_logic_vector(1 downto 0);
        m00_axi_awlock  => open, -- s_axi_awlock,  -- out std_logic_vector(1 downto 0);
        m00_axi_awcache => m00_awcache, -- out std_logic_vector(3 downto 0);
        m00_axi_awprot  => m00_awprot,  -- out std_logic_vector(2 downto 0);
        m00_axi_awqos   => open, -- s_axi_awqos,   -- out std_logic_vector(3 downto 0);
        m00_axi_awregion => open, -- s_axi_awregion, -- out std_logic_vector(3 downto 0);
        m00_axi_wvalid   => m00_wvalid,   -- out std_logic;
        m00_axi_wready   => m00_wready,   -- in std_logic;
        m00_axi_wdata    => m00_wdata,    -- out std_logic_vector(C_M_AXI_DATA_WIDTH-1 downto 0);
        m00_axi_wstrb    => m00_wstrb,    -- out std_logic_vector(C_M_AXI_DATA_WIDTH/8-1 downto 0);
        m00_axi_wlast    => m00_wlast,    -- out std_logic;
        m00_axi_bvalid   => m00_bvalid,   -- in std_logic;
        m00_axi_bready   => m00_bready,   -- out std_logic;
        m00_axi_bresp    => m00_bresp,    -- in std_logic_vector(1 downto 0);
        m00_axi_bid      => "0", -- s_axi_bid,      -- in std_logic_vector(C_M_AXI_ID_WIDTH - 1 downto 0);
        m00_axi_arvalid  => m00_arvalid,  -- out std_logic;
        m00_axi_arready  => m00_arready,  -- in std_logic;
        m00_axi_araddr   => m00_araddr,   -- out std_logic_vector(C_M_AXI_ADDR_WIDTH-1 downto 0);
        m00_axi_arid     => open, -- s_axi_arid,     -- out std_logic_vector(C_M_AXI_ID_WIDTH-1 downto 0);
        m00_axi_arlen    => m00_arlen,    -- out std_logic_vector(7 downto 0);
        m00_axi_arsize   => m00_arsize,   -- out std_logic_vector(2 downto 0);
        m00_axi_arburst  => m00_arburst,  -- out std_logic_vector(1 downto 0);
        m00_axi_arlock   => open, -- s_axi_arlock,   -- out std_logic_vector(1 downto 0);
        m00_axi_arcache  => m00_arcache,  -- out std_logic_vector(3 downto 0);
        m00_axi_arprot   => m00_arprot,   -- out std_logic_Vector(2 downto 0);
        m00_axi_arqos    => open, -- s_axi_arqos,    -- out std_logic_vector(3 downto 0);
        m00_axi_arregion => open, -- s_axi_arregion, -- out std_logic_vector(3 downto 0);
        m00_axi_rvalid   => m00_rvalid,   -- in std_logic;
        m00_axi_rready   => m00_rready,   -- out std_logic;
        m00_axi_rdata    => m00_rdata,    -- in std_logic_vector(C_M_AXI_DATA_WIDTH-1 downto 0);
        m00_axi_rlast    => m00_rlast,    -- in std_logic;
        m00_axi_rid      => "0", -- s_axi_rid,      -- in std_logic_vector(C_M_AXI_ID_WIDTH - 1 downto 0);
        m00_axi_rresp    => m00_rresp,    -- in std_logic_vector(1 downto 0);

        ---------------------------------------------------------------------------------------
        -- AXI4 interfaces for accessing HBM
        -- 0 = 3 Gbytes for LFAA ingest corner turn 
        -- 1 = 3 Gbytes, buffer between the filterbanks and the correlator
        --     First half, for fine channels that go to the first correlator instance.
        -- 2 = 3 Gbytes, buffer between the filterbanks and the correlator
        --     second half, for fine channels that go to the second correlator instance.
        -- 3 = 0.5 Gbytes, Visibilities from First correlator instance;
        -- 4 = 0.5 Gbytes, Visibilities from Second correlator instance;
        HBM_axi_awvalid  => HBM_axi_awvalid, -- out std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awready  => HBM_axi_awready, -- in std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awaddr   => HBM_axi_awaddr,  -- out t_slv_64_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awid     => HBM_axi_awid,    -- out t_slv_1_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awlen    => HBM_axi_awlen,   -- out t_slv_8_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awsize   => HBM_axi_awsize,  -- out t_slv_3_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awburst  => HBM_axi_awburst, -- out t_slv_2_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awlock   => HBM_axi_awlock,  -- out t_slv_2_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awcache  => HBM_axi_awcache, -- out t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awprot   => HBM_axi_awprot,  -- out t_slv_3_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awqos    => HBM_axi_awqos,   -- out t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awregion => HBM_axi_awregion, -- out t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_wvalid   => HBM_axi_wvalid,   -- out std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_wready   => HBM_axi_wready,   -- in std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_wdata    => HBM_axi_wdata,    -- out t_slv_512_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_wstrb    => HBM_axi_wstrb,    -- out t_slv_64_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_wlast    => HBM_axi_wlast,    -- out std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_bvalid   => HBM_axi_bvalid,   -- in std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_bready   => HBM_axi_bready,   -- out std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_bresp    => HBM_axi_bresp,    -- in t_slv_2_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_bid      => HBM_axi_bid,      -- in t_slv_1_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arvalid  => HBM_axi_arvalid,  -- out std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arready  => HBM_axi_arready,  -- in std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_araddr   => HBM_axi_araddr,   -- out t_slv_64_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arid     => HBM_axi_arid,     -- out t_slv_1_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arlen    => HBM_axi_arlen,    -- out t_slv_8_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arsize   => HBM_axi_arsize,   -- out t_slv_3_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arburst  => HBM_axi_arburst,  -- out t_slv_2_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arlock   => HBM_axi_arlock,   -- out t_slv_2_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arcache  => HBM_axi_arcache,  -- out t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arprot   => HBM_axi_arprot,   -- out t_slv_3_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arqos    => HBM_axi_arqos,    -- out t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arregion => HBM_axi_arregion, -- out t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_rvalid   => HBM_axi_rvalid,   -- in std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_rready   => HBM_axi_rready,   -- out std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_rdata    => HBM_axi_rdata,    -- in t_slv_512_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_rlast    => HBM_axi_rlast,    -- in std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_rid      => HBM_axi_rid,      -- in t_slv_1_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_rresp    => HBM_axi_rresp,    -- in t_slv_2_arr(g_HBM_INTERFACES-1 downto 0);
        -- GT pins
        -- clk_gt_freerun is a 50MHz free running clock, according to the GT kernel Example Design user guide.
        -- But it looks like it is configured to be 100MHz in the example designs for all parts except the U280. 
        clk_freerun => clk100,   -- in std_logic; 
        -- trigger readout of the second corner turn data without waiting for the rest of the signal chain.
        -- used in testing with pre-load of the second corner turn HBM data
        i_ct2_readout_start  => ct2_readout_start, -- in std_logic;
        i_ct2_readout_buffer => ct2_readout_buffer, -- in std_logic;
        i_ct2_readout_frameCount => ct2_readout_frameCount, -- in (31:0);
        ---------------------------------------------------------------
        -- copy of the bus taking data to be written to the HBM.
        -- Used for simulation only, to check against the model data.
        o_tb_data      => cor0_tb_data,     -- out (255:0);
        o_tb_visValid  => cor0_tb_visValid, -- out std_logic; -- o_tb_data is valid visibility data
        o_tb_TCIvalid  => cor0_tb_TCIvalid, -- out std_logic; -- i_data is valid TCI & DV data
        o_tb_dcount    => cor0_tb_dcount,   -- out (7:0);  -- counts the 256 transfers for one cell of visibilites, or 16 transfers for the centroid data. 
        o_tb_cell      => cor0_tb_cell,     -- out (7:0);  -- in (7:0);  -- a "cell" is a 16x16 station block of correlations
        o_tb_tile      => cor0_tb_tile,     -- out (9:0);  -- a "tile" is a 16x16 block of cells, i.e. a 256x256 station correlation.
        o_tb_channel   => cor0_tb_channel,  -- out (23:0) -- first fine channel index for this correlation.
       -- Start of a burst of data through the filterbank, 
        -- Used in the testbench to trigger download of the data written into the CT2 memory.
        o_FB_out_sof   => FB_out_sof        -- out std_logic
    );
    
    ----------------------------------------------------------------------------------
    -- Emulate HBM
    -- 3 Gbyte of memory for the first corner turn.
    HBM3G_1 : entity correlator_lib.HBM_axi_tbModel
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
        i_clk => ap_clk,
        i_rst_n => ap_rst_n,
        axi_awaddr   => HBM_axi_awaddr(0)(31 downto 0),
        axi_awid     => HBM_axi_awid(0), -- in std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        axi_awlen    => HBM_axi_awlen(0),
        axi_awsize   => HBM_axi_awsize(0),
        axi_awburst  => HBM_axi_awburst(0),
        axi_awlock   => HBM_axi_awlock(0),
        axi_awcache  => HBM_axi_awcache(0),
        axi_awprot   => HBM_axi_awprot(0),
        axi_awqos    => HBM_axi_awqos(0), -- in(3:0)
        axi_awregion => HBM_axi_awregion(0), -- in(3:0)
        axi_awvalid  => HBM_axi_awvalid(0),
        axi_awready  => HBM_axi_awready(0),
        axi_wdata    => HBM_axi_wdata(0),
        axi_wstrb    => HBM_axi_wstrb(0),
        axi_wlast    => HBM_axi_wlast(0),
        axi_wvalid   => HBM_axi_wvalid(0),
        axi_wready   => HBM_axi_wready(0),
        axi_bresp    => HBM_axi_bresp(0),
        axi_bvalid   => HBM_axi_bvalid(0),
        axi_bready   => HBM_axi_bready(0),
        axi_bid      => HBM_axi_bid(0), -- out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        axi_araddr   => HBM_axi_araddr(0)(31 downto 0),
        axi_arlen    => HBM_axi_arlen(0),
        axi_arsize   => HBM_axi_arsize(0),
        axi_arburst  => HBM_axi_arburst(0),
        axi_arlock   => HBM_axi_arlock(0),
        axi_arcache  => HBM_axi_arcache(0),
        axi_arprot   => HBM_axi_arprot(0),
        axi_arvalid  => HBM_axi_arvalid(0),
        axi_arready  => HBM_axi_arready(0),
        axi_arqos    => HBM_axi_arqos(0),
        axi_arid     => HBM_axi_arid(0),
        axi_arregion => HBM_axi_arregion(0),
        axi_rdata    => HBM_axi_rdata(0),
        axi_rresp    => HBM_axi_rresp(0),
        axi_rlast    => HBM_axi_rlast(0),
        axi_rvalid   => HBM_axi_rvalid(0),
        axi_rready   => HBM_axi_rready(0),
        i_write_to_disk => '0', -- : in std_logic;
        i_fname => "", -- : in string
        i_write_to_disk_addr => 0, -- in integer; -- address to start the memory dump at.
        i_write_to_disk_size => 0, -- in integer; -- size in bytes
        -- Initialisation of the memory
        i_init_mem   => load_ct1_HBM,   -- in std_logic;
        i_init_fname => g_TEST_CASE & g_CT1_INIT_FILENAME  -- in string
    );
    
    -- 3 GBytes second stage corner turn, first correlator cell
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
        i_clk => ap_clk,
        i_rst_n => ap_rst_n,
        axi_awaddr   => HBM_axi_awaddr(1)(31 downto 0),
        axi_awid     => HBM_axi_awid(1), -- in std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        axi_awlen    => HBM_axi_awlen(1),
        axi_awsize   => HBM_axi_awsize(1),
        axi_awburst  => HBM_axi_awburst(1),
        axi_awlock   => HBM_axi_awlock(1),
        axi_awcache  => HBM_axi_awcache(1),
        axi_awprot   => HBM_axi_awprot(1),
        axi_awqos    => HBM_axi_awqos(1), -- in(3:0)
        axi_awregion => HBM_axi_awregion(1), -- in(3:0)
        axi_awvalid  => HBM_axi_awvalid(1),
        axi_awready  => HBM_axi_awready(1),
        axi_wdata    => HBM_axi_wdata(1),
        axi_wstrb    => HBM_axi_wstrb(1),
        axi_wlast    => HBM_axi_wlast(1),
        axi_wvalid   => HBM_axi_wvalid(1),
        axi_wready   => HBM_axi_wready(1),
        axi_bresp    => HBM_axi_bresp(1),
        axi_bvalid   => HBM_axi_bvalid(1),
        axi_bready   => HBM_axi_bready(1),
        axi_bid      => HBM_axi_bid(1), -- out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        axi_araddr   => HBM_axi_araddr(1)(31 downto 0),
        axi_arlen    => HBM_axi_arlen(1),
        axi_arsize   => HBM_axi_arsize(1),
        axi_arburst  => HBM_axi_arburst(1),
        axi_arlock   => HBM_axi_arlock(1),
        axi_arcache  => HBM_axi_arcache(1),
        axi_arprot   => HBM_axi_arprot(1),
        axi_arvalid  => HBM_axi_arvalid(1),
        axi_arready  => HBM_axi_arready(1),
        axi_arqos    => HBM_axi_arqos(1),
        axi_arid     => HBM_axi_arid(1),
        axi_arregion => HBM_axi_arregion(1),
        axi_rdata    => HBM_axi_rdata(1),
        axi_rresp    => HBM_axi_rresp(1),
        axi_rlast    => HBM_axi_rlast(1),
        axi_rvalid   => HBM_axi_rvalid(1),
        axi_rready   => HBM_axi_rready(1),
        i_write_to_disk => ct2_HBM_dump_trigger, -- in std_logic;
        i_fname         => g_TEST_CASE & g_CT2_HBM_DUMP_FNAME,  -- in string
        i_write_to_disk_addr => g_CT2_HBM_DUMP_ADDR,     -- in integer; Address to start the memory dump at.
        i_write_to_disk_size => g_CT2_HBM_DUMP_SIZE, -- in integer; Size in bytes
        -- Initialisation of the memory
        -- The memory is loaded with the contents of the file i_init_fname in 
        -- any clock cycle where i_init_mem is high.
        i_init_mem   => load_ct2_HBM_corr1, -- in std_logic;
        i_init_fname => g_TEST_CASE & g_CT2_HBM_CORR1_FILENAME  -- in string
    );
    
    -- 3 GBytes second stage corner turn, second correlator cell
    HBM3G_3 : entity correlator_lib.HBM_axi_tbModel
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
        i_clk => ap_clk,
        i_rst_n => ap_rst_n,
        axi_awaddr   => HBM_axi_awaddr(2)(31 downto 0),
        axi_awid     => HBM_axi_awid(2), -- in std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        axi_awlen    => HBM_axi_awlen(2),
        axi_awsize   => HBM_axi_awsize(2),
        axi_awburst  => HBM_axi_awburst(2),
        axi_awlock   => HBM_axi_awlock(2),
        axi_awcache  => HBM_axi_awcache(2),
        axi_awprot   => HBM_axi_awprot(2),
        axi_awqos    => HBM_axi_awqos(2), -- in(3:0)
        axi_awregion => HBM_axi_awregion(2), -- in(3:0)
        axi_awvalid  => HBM_axi_awvalid(2),
        axi_awready  => HBM_axi_awready(2),
        axi_wdata    => HBM_axi_wdata(2),
        axi_wstrb    => HBM_axi_wstrb(2),
        axi_wlast    => HBM_axi_wlast(2),
        axi_wvalid   => HBM_axi_wvalid(2),
        axi_wready   => HBM_axi_wready(2),
        axi_bresp    => HBM_axi_bresp(2),
        axi_bvalid   => HBM_axi_bvalid(2),
        axi_bready   => HBM_axi_bready(2),
        axi_bid      => HBM_axi_bid(2), -- out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        axi_araddr   => HBM_axi_araddr(2)(31 downto 0),
        axi_arlen    => HBM_axi_arlen(2),
        axi_arsize   => HBM_axi_arsize(2),
        axi_arburst  => HBM_axi_arburst(2),
        axi_arlock   => HBM_axi_arlock(2),
        axi_arcache  => HBM_axi_arcache(2),
        axi_arprot   => HBM_axi_arprot(2),
        axi_arvalid  => HBM_axi_arvalid(2),
        axi_arready  => HBM_axi_arready(2),
        axi_arqos    => HBM_axi_arqos(2),
        axi_arid     => HBM_axi_arid(2),
        axi_arregion => HBM_axi_arregion(2),
        axi_rdata    => HBM_axi_rdata(2),
        axi_rresp    => HBM_axi_rresp(2),
        axi_rlast    => HBM_axi_rlast(2),
        axi_rvalid   => HBM_axi_rvalid(2),
        axi_rready   => HBM_axi_rready(2),
        i_write_to_disk => '0', -- : in std_logic;
        i_fname => "", -- : in string
        i_write_to_disk_addr => 0, --  in integer; -- address to start the memory dump at.
        i_write_to_disk_size => 0, --  in integer; -- size in bytes
        -- Initialisation of the memory
        i_init_mem   => load_ct2_HBM_corr2,   -- in std_logic;
        i_init_fname => g_TEST_CASE & g_CT2_HBM_CORR2_FILENAME  -- in string
    );
    
    
    -- 512 MBytes visibilities output buffer for first correlator cell.
    HBM512M_1 : entity correlator_lib.HBM_axi_tbModel
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
        i_clk => ap_clk,
        i_rst_n => ap_rst_n,
        axi_awaddr   => HBM_axi_awaddr(3)(31 downto 0),
        axi_awid     => HBM_axi_awid(3), -- in std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        axi_awlen    => HBM_axi_awlen(3),
        axi_awsize   => HBM_axi_awsize(3),
        axi_awburst  => HBM_axi_awburst(3),
        axi_awlock   => HBM_axi_awlock(3),
        axi_awcache  => HBM_axi_awcache(3),
        axi_awprot   => HBM_axi_awprot(3),
        axi_awqos    => HBM_axi_awqos(3), -- in(3:0)
        axi_awregion => HBM_axi_awregion(3), -- in(3:0)
        axi_awvalid  => HBM_axi_awvalid(3),
        axi_awready  => HBM_axi_awready(3),
        axi_wdata    => HBM_axi_wdata(3),
        axi_wstrb    => HBM_axi_wstrb(3),
        axi_wlast    => HBM_axi_wlast(3),
        axi_wvalid   => HBM_axi_wvalid(3),
        axi_wready   => HBM_axi_wready(3),
        axi_bresp    => HBM_axi_bresp(3),
        axi_bvalid   => HBM_axi_bvalid(3),
        axi_bready   => HBM_axi_bready(3),
        axi_bid      => HBM_axi_bid(3), -- out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        axi_araddr   => HBM_axi_araddr(3)(31 downto 0),
        axi_arlen    => HBM_axi_arlen(3),
        axi_arsize   => HBM_axi_arsize(3),
        axi_arburst  => HBM_axi_arburst(3),
        axi_arlock   => HBM_axi_arlock(3),
        axi_arcache  => HBM_axi_arcache(3),
        axi_arprot   => HBM_axi_arprot(3),
        axi_arvalid  => HBM_axi_arvalid(3),
        axi_arready  => HBM_axi_arready(3),
        axi_arqos    => HBM_axi_arqos(3),
        axi_arid     => HBM_axi_arid(3),
        axi_arregion => HBM_axi_arregion(3),
        axi_rdata    => HBM_axi_rdata(3),
        axi_rresp    => HBM_axi_rresp(3),
        axi_rlast    => HBM_axi_rlast(3),
        axi_rvalid   => HBM_axi_rvalid(3),
        axi_rready   => HBM_axi_rready(3),
        i_write_to_disk => '0', -- : in std_logic;
        i_fname => "", -- : in string
        i_write_to_disk_addr => 0, -- : in integer; -- address to start the memory dump at.
        i_write_to_disk_size => 0, -- : in integer; -- size in bytes
        -- Initialisation of the memory
        i_init_mem   => '0',   -- in std_logic;
        i_init_fname => ""  -- in string
    );
    
    -- 512 MBytes visibilities output buffer for the second correlator cell.
    HBM512M_2 : entity correlator_lib.HBM_axi_tbModel
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
        i_clk => ap_clk,
        i_rst_n => ap_rst_n,
        axi_awaddr   => HBM_axi_awaddr(4)(31 downto 0),
        axi_awid     => HBM_axi_awid(4), -- in std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        axi_awlen    => HBM_axi_awlen(4),
        axi_awsize   => HBM_axi_awsize(4),
        axi_awburst  => HBM_axi_awburst(4),
        axi_awlock   => HBM_axi_awlock(4),
        axi_awcache  => HBM_axi_awcache(4),
        axi_awprot   => HBM_axi_awprot(4),
        axi_awqos    => HBM_axi_awqos(4), -- in(3:0)
        axi_awregion => HBM_axi_awregion(4), -- in(3:0)
        axi_awvalid  => HBM_axi_awvalid(4),
        axi_awready  => HBM_axi_awready(4),
        axi_wdata    => HBM_axi_wdata(4),
        axi_wstrb    => HBM_axi_wstrb(4),
        axi_wlast    => HBM_axi_wlast(4),
        axi_wvalid   => HBM_axi_wvalid(4),
        axi_wready   => HBM_axi_wready(4),
        axi_bresp    => HBM_axi_bresp(4),
        axi_bvalid   => HBM_axi_bvalid(4),
        axi_bready   => HBM_axi_bready(4),
        axi_bid      => HBM_axi_bid(4), -- out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        axi_araddr   => HBM_axi_araddr(4)(31 downto 0),
        axi_arlen    => HBM_axi_arlen(4),
        axi_arsize   => HBM_axi_arsize(4),
        axi_arburst  => HBM_axi_arburst(4),
        axi_arlock   => HBM_axi_arlock(4),
        axi_arcache  => HBM_axi_arcache(4),
        axi_arprot   => HBM_axi_arprot(4),
        axi_arvalid  => HBM_axi_arvalid(4),
        axi_arready  => HBM_axi_arready(4),
        axi_arqos    => HBM_axi_arqos(4),
        axi_arid     => HBM_axi_arid(4),
        axi_arregion => HBM_axi_arregion(4),
        axi_rdata    => HBM_axi_rdata(4),
        axi_rresp    => HBM_axi_rresp(4),
        axi_rlast    => HBM_axi_rlast(4),
        axi_rvalid   => HBM_axi_rvalid(4),
        axi_rready   => HBM_axi_rready(4),
        i_write_to_disk => '0', -- : in std_logic;
        i_fname => "", -- : in string
        i_write_to_disk_addr => 0, -- : in integer; -- address to start the memory dump at.
        i_write_to_disk_size => 0, -- : in integer; -- size in bytes
        -- Initialisation of the memory
        i_init_mem   => '0',   -- in std_logic;
        i_init_fname => ""  -- in string
    );
    
    
end Behavioral;
