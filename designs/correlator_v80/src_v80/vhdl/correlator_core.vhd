-------------------------------------------------------------------------------
--
-- File Name: correlator.vhd
-- Contributing Authors: Giles Babich, David Humphrey
-- Template Rev: 1.0
--
-- Title: Top Level for vitis compatible acceleration core
--
-------------------------------------------------------------------------------

LIBRARY IEEE, UNISIM, common_lib, axi4_lib, technology_lib, dsp_top_lib, correlator_lib, stats_lib;
LIBRARY noc_lib, versal_dcmac_lib, system_lib, signal_processing_common;

USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE common_lib.common_pkg.ALL;
USE common_lib.common_mem_pkg.ALL;
USE axi4_lib.axi4_lite_pkg.ALL;
USE axi4_lib.axi4_stream_pkg.ALL;
USE axi4_lib.axi4_full_pkg.ALL;

USE technology_lib.technology_pkg.ALL;
USE technology_lib.technology_select_pkg.all;
use correlator_lib.build_details_pkg.all;
USE correlator_lib.correlator_v80_system_reg_pkg.ALL;

USE versal_dcmac_lib.versal_dcmac_pkg.ALL;

USE UNISIM.vcomponents.all;
Library xpm;
use xpm.vcomponents.all;

-------------------------------------------------------------------------------
ENTITY correlator_core IS
    generic (
        -- GENERICS for use in the testbench 
        g_SIMULATION : boolean := FALSE;  -- when true, the 100GE core is disabled and instead the lbus comes from the top level pins
        g_USE_META   : boolean := FALSE;    -- Put meta data into the memory in place of the actual data, to make it easier to find bugs in the corner turn.
        -- GLOBAL GENERICS for PERENTIE LOGIC
        g_DEBUG_ILA                : boolean := FALSE;
        g_SPS_PACKETS_PER_FRAME    : integer := 128;  -- Number of SPS packets per frame.
        g_FIRMWARE_MAJOR_VERSION   : std_logic_vector(15 downto 0) := x"0000";
        g_FIRMWARE_MINOR_VERSION   : std_logic_vector(15 downto 0) := x"0001";
        g_FIRMWARE_PATCH_VERSION   : std_logic_vector(15 downto 0) := x"0000";
        g_FIRMWARE_LABEL           : std_logic_vector(31 downto 0) := x"00000000";
        g_FIRMWARE_PERSONALITY     : std_logic_vector(31 downto 0) := x"434F5252"; -- ascii "CORR"
        g_FIRMWARE_BUILD_DATE      : std_logic_vector(31 downto 0) := x"00000000";

        -- All the HBM interfaces are the same width;
        -- Actual interfaces used are : 
        --  M01, 3 Gbytes HBM; first stage corner turn, between LFAA ingest and the filterbanks
        --  M02, 3 Gbytes HBM; Correlator HBM for fine channels going to the first correlator instance; buffer between the filterbanks and the correlator
        --  M03, 3 Gbytes HBM; Correlator HBM for fine channels going to the Second correlator instance; buffer between the filterbanks and the correlator
        --  M04, 512 Mbytes HBM; visibilities from first correlator instance
        --  M05, 512 Mbytes HBM; visibilities from second correlator instance
        g_HBM_INTERFACES : integer := 6;
        g_HBM_AXI_ADDR_WIDTH : integer := 64;
        g_HBM_AXI_DATA_WIDTH : integer := 512;
        g_HBM_AXI_ID_WIDTH   : integer := 1;
        -- Number of correlator blocks to instantiate.
        -- Set g_CORRELATORS to 0 and g_USE_DUMMY_FB to True for fast build times.
        g_CORRELATORS        : integer := 2;  -- 1 or 2
        g_INCLUDE_SPS_MONITOR : boolean := TRUE;
        g_USE_DUMMY_FB       : boolean := FALSE -- Should be FALSE for normal operation.
    );
    port (
        clk_100         : in std_logic;
        clk_100_rst     : in std_logic;
        
        clk_300         : in std_logic;
        clk_300_rst     : in std_logic;
        
        i_dcmac_locked_300m : in std_logic;
        
        -- Received data from 100GE
        i_axis_tdata    : in std_logic_vector(511 downto 0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
        i_axis_tkeep    : in std_logic_vector(63 downto 0);  -- one bit per byte in i_axi_tdata
        i_axis_tlast    : in std_logic;
        i_axis_tuser    : in std_logic_vector(79 downto 0);  -- Timestamp for the packet.
        i_axis_tvalid   : in std_logic;
        
        -- Data to be transmitted on 100GE
        o_dcmac_tx_data_0   : out seg_streaming_axi;
        i_dcmac_tx_ready_0  : in std_logic;
        
        i_eth100g_clk    : in std_logic;
        i_eth100g_locked : in std_logic;
        -- reset of the valid memory is in progress.
        o_validMemRstActive : out std_logic;
        -- Other signals to/from the timeslave 
        i_PTP_time_ARGs_clk     : std_logic_vector(79 downto 0);
        o_dcmac_reset           : out std_logic;
        
        i_eth100G_rx_total_packets : in std_logic_vector(31 downto 0);
        i_eth100G_rx_bad_fcs       : in std_logic_vector(31 downto 0);
        i_eth100G_rx_bad_code      : in std_logic_vector(31 downto 0);
        i_eth100G_tx_total_packets : in std_logic_vector(31 downto 0);
        
        
        -- trigger readout of the second corner turn data without waiting for the rest of the signal chain.
        -- used in testing with pre-load of the second corner turn HBM data
        i_ct2_readout_start         : in std_logic;
        i_ct2_readout_buffer        : in std_logic;
        i_ct2_readout_frameCount    : in std_logic_vector(31 downto 0);
        
        i_input_HBM_reset           : in std_logic;
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
        o_FB_out_sof   : out std_logic
    );
END correlator_core;

-------------------------------------------------------------------------------
ARCHITECTURE structure OF correlator_core IS

    component ila_0 is
    Port ( 
        clk : in STD_LOGIC;
        probe0 : in STD_LOGIC_VECTOR ( 191 downto 0 )
    );
    end component;

    component clk_mmcm_400 is
    Port ( 
        clk_in1 : in STD_LOGIC;
        clk_out1 : out STD_LOGIC
    );
    end component;
    
    component clk_mmcm_425 is
    Port ( 
        clk_in1 : in STD_LOGIC;
        clk_out1 : out STD_LOGIC
    );
    end component;

    component clk_mmcm_450 is
    Port ( 
        clk_in1 : in STD_LOGIC;
        clk_out1 : out STD_LOGIC
    );
    end component;
        
    COMPONENT ila_twoby256_4k
    PORT (
        clk : IN STD_LOGIC;
        probe0 : IN STD_LOGIC_VECTOR(255 DOWNTO 0);
        probe1 : IN STD_LOGIC_VECTOR(255 DOWNTO 0) 
    );
    END COMPONENT;
    
    constant NOC_DATA_WIDTH     : integer   := 256;                 -- 32/64/128/256/512
    constant NOC_ADDR_WIDTH     : integer   := 64;                  -- 12 to 64
    constant NOC_ID_WIDTH       : integer   := 1;                   -- 1 to 16
    constant NOC_AUSER_WIDTH    : integer   := 16;                  -- 16 for VNOC with parity disabled, 18 for VNOC with parity enabled 
    constant NOC_DUSER_WIDTH    : integer   := 1;                   -- 2*DATA_WIDTH/8 for parity enablement with VNOC, 1 for VNOC with parity disabled cases.

    signal ap_rst : std_logic;

    signal system_fields_rw : t_system_rw;
    signal system_fields_ro : t_system_ro;
        
    signal noc_wren         : STD_LOGIC;
    signal noc_rden         : STD_LOGIC;
    signal noc_wr_adr       : STD_LOGIC_VECTOR(17 DOWNTO 0);
    signal noc_wr_dat       : STD_LOGIC_VECTOR(31 DOWNTO 0);
    signal noc_rd_adr       : STD_LOGIC_VECTOR(17 DOWNTO 0);
    signal noc_rd_dat       : STD_LOGIC_VECTOR(31 DOWNTO 0);
    
    signal uptime : std_logic_vector(31 downto 0) := x"00000000";

    signal eth100_reset : std_logic := '0';
    signal dest_req : std_logic;
    signal eth100G_status_ap_clk : std_logic_vector(128 downto 0);
    signal eth100G_status_eth_clk : std_logic_vector(128 downto 0);
    signal eth100G_send, eth100G_rcv : std_logic;
    
    signal ap_clk_count : std_logic_vector(31 downto 0) := (others => '0');
    
    signal freerunCount : std_logic_vector(31 downto 0) := x"00000000";
    signal freerunSecCount : std_logic_vector(31 downto 0) := x"00000000";

    signal GTY_startup_rst : std_logic := '0';

    signal clk400 : std_logic;
    signal clk425 : std_logic;
    
    signal clk_450          : std_logic;
    signal clk_450_rst      : std_logic := '1';
    signal clk_450_rst_cnt  : unsigned(31 downto 0) := x"00001000";
    
    signal clk_gt_freerun_use : std_logic;
    
    signal eth100G_uptime : std_logic_vector(31 downto 0) := (others => '0');
    signal eth100G_seconds : std_logic_vector(31 downto 0) := (others => '0');
    
    signal araddr64bit, awaddr64bit : std_logic_vector(63 downto 0);
    signal m01_shared : std_logic_vector(63 downto 0);
    signal m02_shared : std_logic_vector(63 downto 0);
    signal m03_shared : std_logic_vector(63 downto 0);
    
    signal fec_enable_100m          : std_logic;
    signal fec_enable_cache         : std_logic;
    
    signal fec_enable_reset_count   : integer := 0;
    signal fec_enable_reset         : std_logic := '0';
    
    -- Logic side signals of HBM reset mechanism
    signal HBM_axi_aw, HBM_axi_aw_sigproc : t_axi4_full_addr_arr(g_HBM_INTERFACES-1 downto 0);

    signal HBM_axi_w, HBM_axi_w_sigproc : t_axi4_full_data_arr(g_HBM_INTERFACES-1 downto 0);

    signal HBM_axi_b                : t_axi4_full_b_arr(g_HBM_INTERFACES-1 downto 0);

    signal HBM_axi_ar               : t_axi4_full_addr_arr(g_HBM_INTERFACES-1 downto 0);   

    signal HBM_axi_r                : t_axi4_full_data_arr(g_HBM_INTERFACES-1 downto 0);

    -- HBM reset
    signal hbm_reset                : std_logic_vector(5 downto 0);
    signal hbm_status               : t_slv_8_arr(5 downto 0);
    signal hbm_rst_dbg              : t_slv_32_arr(5 downto 0);
    signal hbm_reset_combined       : std_logic_vector(5 downto 0);
    
    ---------------------------------------------------------------------------------------
    -- HBM GASKET
    signal slave_wr_data_bus        : t_axi4_full_data_arr(g_HBM_INTERFACES-1 downto 0);
    signal slave_wr_addr_bus        : t_axi4_full_addr_arr(g_HBM_INTERFACES-1 downto 0);
    
    signal slave_rd_data_bus        : t_axi4_full_data_arr(g_HBM_INTERFACES-1 downto 0);
    signal slave_rd_addr_bus        : t_axi4_full_addr_arr(g_HBM_INTERFACES-1 downto 0);
    
    signal master_wr_data_bus       : t_axi4_full_data_arr(g_HBM_INTERFACES-1 downto 0);
    signal master_wr_addr_bus       : t_axi4_full_addr_arr(g_HBM_INTERFACES-1 downto 0);
    
    signal master_rd_data_bus       : t_axi4_full_data_arr(g_HBM_INTERFACES-1 downto 0);
    signal master_rd_addr_bus       : t_axi4_full_addr_arr(g_HBM_INTERFACES-1 downto 0);
    
    signal slave_wr_data_bus_rdy    : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal slave_wr_addr_bus_rdy    : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    
    signal slave_rd_data_bus_rdy    : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal slave_rd_addr_bus_rdy    : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    
    signal master_wr_data_bus_rdy   : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal master_wr_addr_bus_rdy   : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    
    signal master_rd_data_bus_rdy   : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal master_rd_addr_bus_rdy   : std_logic_vector(g_HBM_INTERFACES-1 downto 0);

    ---------------------------------------------------------------------------------------
    -- AXI4 interfaces for accessing HBM
    -- 0 = 3 Gbytes for LFAA ingest corner turn 
    -- 1 = 3 Gbytes, buffer between the filterbanks and the correlator
    --     First half, for fine channels that go to the first correlator instance.
    -- 2 = 3 Gbytes, buffer between the filterbanks and the correlator
    --     second half, for fine channels that go to the second correlator instance.
    -- 3 = 0.5 Gbytes, Visibilities from First correlator instance;
    -- 4 = 0.5 Gbytes, Visibilities from Second correlator instance;
    --signal HBM_axi_awvalid  : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_awready, HBM_axi_awready_sigproc : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_awaddr   : t_slv_64_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_awid     : t_slv_1_arr(g_HBM_INTERFACES-1 downto 0);
    --signal HBM_axi_awlen    : t_slv_8_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_awsize   : t_slv_3_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_awburst  : t_slv_2_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_awlock   : t_slv_1_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_awcache  : t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_awprot   : t_slv_3_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_awqos    : t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_awregion : t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);

    --signal HBM_axi_wvalid   : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_wready, HBM_axi_wready_sigproc : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    --signal HBM_axi_wdata    : t_slv_512_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_wstrb    : t_slv_64_arr(g_HBM_INTERFACES-1 downto 0);
    --signal HBM_axi_wlast    : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_bvalid   : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_bready   : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_bresp    : t_slv_2_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_bid      : t_slv_1_arr(g_HBM_INTERFACES-1 downto 0);
    --signal HBM_axi_arvalid  : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_arready  : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_araddr   : t_slv_64_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_arid     : t_slv_1_arr(g_HBM_INTERFACES-1 downto 0);
    --signal HBM_axi_arlen    : t_slv_8_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_arsize   : t_slv_3_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_arburst  : t_slv_2_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_arlock   : t_slv_1_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_arcache  : t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_arprot   : t_slv_3_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_arqos    : t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_arregion : t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);
    --signal HBM_axi_rvalid   : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_rready   : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    --signal HBM_axi_rdata    : t_slv_512_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_vector(M01_AXI_DATA_WIDTH-1 downto 0);
    --signal HBM_axi_rlast    : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_rid      : t_slv_1_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_vector(M01_AXI_ID_WIDTH - 1 downto 0);
    --signal HBM_axi_rresp    : t_slv_2_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_vector(1 downto 0);
    signal HBM_axi_awuser   : t_slv_16_arr(g_HBM_INTERFACES-1 downto 0);

    signal HBM_axi_wid      : t_slv_1_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_wuser    : t_slv_1_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_buser    : t_slv_16_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_aruser   : t_slv_16_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_ruser    : t_slv_1_arr(g_HBM_INTERFACES-1 downto 0);

    signal HBM_axi_araddr256Mbyte, HBM_axi_awaddr256Mbyte : t_slv_8_arr(g_HBM_INTERFACES-1 downto 0);
    
    constant HBM_GASKET_NO_OF_STATUS    : INTEGER := 5;
    signal HBM_gasket_stat  : t_slv_32_matrix((g_HBM_INTERFACES-1) downto 0, (HBM_GASKET_NO_OF_STATUS-1) downto 0);
    
    -- V80 contains 32GB of HBM
    -- Base address for this is 0x40_0000_0000
    -- Biggest HBM block in Correlator is 4GB
    constant HBM_base_addr  : t_slv_64_arr(g_HBM_interfaces-1 downto 0) := ( x"0000004600000000",   -- Base         
                                                                             x"0000004500000000",   -- +4GB addr
                                                                             x"0000004400000000",   -- +4GB addr
                                                                             x"0000004200000000",   -- +4GB addr
                                                                             x"0000004100000000",   -- +4GB addr
                                                                             x"0000004700000000"    -- +4GB addr    -- LFAA
                                                                            );
-- From Xilinx Doc PG313
-- Base address 0 - LFAA    - HBM14_PORT0_hbmc  - 0x47_0000_0000
-- Base address 1 - CT2_1   - HBM2_PORT0_hbmc   - 0x41_0000_0000
-- Base address 2 - CT2_2   - HBM4_PORT0_hbmc   - 0x42_0000_0000
-- Base address 3 - Corr_1  - HBM8_PORT0_hbmc   - 0x44_0000_0000
-- Base address 4 - Corr_2  - HBM10_PORT0_hbmc  - 0x45_0000_0000
-- Base address 5 - ILA     - HBM12_PORT0_hbmc  - 0x46_0000_0000

    signal axi_dbg : std_logic_vector(127 downto 0);
    signal axi_dbg_valid : std_logic;
    
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
    
    signal hbm_reset_final      : std_logic;
    signal i_axis_tdata_gated   : std_logic_vector(511 downto 0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
    signal i_axis_tkeep_gated   : std_logic_vector(63 downto 0);  -- one bit per byte in i_axi_tdata
    signal i_axis_tlast_gated   : std_logic;
    signal i_axis_tuser_gated   : std_logic_vector(79 downto 0); -- Timestamp for the packet.
    signal i_axis_tvalid_gated  : std_logic;
    signal eth_disable_fsm_dbg  : std_logic_vector(4 downto 0);
    signal hbm_reset_actual     : std_logic_vector(5 downto 0);
    
    signal bytes_to_transmit    : STD_LOGIC_VECTOR(13 downto 0);
    signal data_to_player       : STD_LOGIC_VECTOR(511 downto 0);
    signal data_to_player_wr    : STD_LOGIC;
    signal data_to_player_rdy   : STD_LOGIC;
    
    signal eth100G_rst          : std_logic;
    signal o_null               : t_axi4_lite_miso;
    
    signal HBM_ila_counter      : unsigned(31 downto 0);
    
    signal eth_disable, eth_disable_done : std_logic;
    signal lfaaDecode_reset : std_logic;
    
    signal sps_mon_aw : t_axi4_full_addr;
    signal sps_mon_w  : t_axi4_full_data;
    signal sps_monitor_period_eth_clk, sps_monitor_time_since_write_eth_clk : std_logic_vector(15 downto 0);
    
begin
    
    ---------------------------------------------------------------------------
    -- CLOCKING & RESETS  --
    ---------------------------------------------------------------------------
   
    i_mmcm_400 : clk_mmcm_400 
    Port map ( 
        clk_in1     => clk_100,
        clk_out1    => clk400
    );

    i_mmcm_425 : clk_mmcm_425
    Port map ( 
        clk_in1     => clk_100,
        clk_out1    => clk425
    );

    i_mmcm_450 : clk_mmcm_450
    Port map ( 
        clk_in1     => clk_100,
        clk_out1    => clk_450
    );
    
    reset_450_proc : process(clk_450)
    begin
        if rising_edge(clk_450) then
            if clk_450_rst_cnt = 1 then
                clk_450_rst     <= '0';
            else
                clk_450_rst_cnt <= clk_450_rst_cnt - 1;
                clk_450_rst     <= '1';
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- System Peripheral Registers  --
    ---------------------------------------------------------------------------
    i_system_noc : entity noc_lib.args_noc
    generic map (
        G_DEBUG         => FALSE,
        G_TEST_HARNESS  => FALSE
    )
    port map ( 
        i_clk       => clk_300,
        i_rst       => clk_300_rst,
    
        noc_wren    => noc_wren,
        noc_rden    => noc_rden,
        noc_wr_adr  => noc_wr_adr,
        noc_wr_dat  => noc_wr_dat,
        noc_rd_adr  => noc_rd_adr,
        noc_rd_dat  => noc_rd_dat
    );
 
    i_system_regs: entity correlator_lib.correlator_v80_system_versal
    GENERIC MAP (
        g_technology      => c_tech_alveo
    )
    PORT MAP (
        mm_clk            => clk_300,
        mm_rst            => clk_300_rst,
        
        noc_wren          => noc_wren,
        noc_rden          => noc_rden,
        noc_wr_adr        => noc_wr_adr,
        noc_wr_dat        => noc_wr_dat,
        noc_rd_adr        => noc_rd_adr,
        noc_rd_dat        => noc_rd_dat,
        
        system_fields_rw  => system_fields_rw,
        system_fields_ro  => system_fields_ro
    );
    
    -- Build version.
    -- On the gemini cards, this was the build date accessed via the USR_ACCESSE2 primitive.
    -- However this is not supported in a vitis kernel since it cannot be placed in the dynamic region.
    
    system_fields_ro.firmware_major_version <= g_FIRMWARE_MAJOR_VERSION;
    system_fields_ro.firmware_minor_version <= g_FIRMWARE_MINOR_VERSION;
    system_fields_ro.firmware_patch_version <= g_FIRMWARE_PATCH_VERSION;
    system_fields_ro.firmware_label         <= g_FIRMWARE_LABEL;
    system_fields_ro.firmware_personality   <= g_FIRMWARE_PERSONALITY;
    system_fields_ro.build_date             <= x"66666666";             -- Now under CI/CD, rely on the ARGs generation
    system_fields_ro.commit_short_hash      <= C_SHA_SHORT;
    system_fields_ro.build_type             <= C_BUILD_TYPE;
    system_fields_ro.no_of_correlator_instances <= std_logic_vector(to_unsigned(g_CORRELATORS , 4));
    
 -- Select either HBM ILA or the SPS monitor
    hbm_ila_geni : if (not g_INCLUDE_SPS_MONITOR) generate
        
        system_fields_ro.sps_monitor_time_since_write <= (others => '0');
        system_fields_ro.sps_monitor_wr_addr <= (others => '0');
        system_fields_ro.sps_monitor_exists <= '0';
        
        HBM_axi_aw <= HBM_axi_aw_sigproc;
        HBM_axi_w <= HBM_axi_w_sigproc;
        
        HBM_axi_awready_sigproc <= HBM_axi_awready;
        HBM_axi_wready_sigproc <= HBM_axi_wready;
        
    end generate;
    
    hbm_sps_mon_gen : if g_INCLUDE_SPS_MONITOR generate
        
        system_fields_ro.sps_monitor_exists <= '1';
        
        HBM_axi_aw(4 downto 0) <= HBM_axi_aw_sigproc(4 downto 0);
        HBM_axi_aw(5) <= sps_mon_aw;
        HBM_axi_w(4 downto 0) <= HBM_axi_w_sigproc(4 downto 0);
        HBM_axi_w(5) <= sps_mon_w;
        
        HBM_axi_awready_sigproc(4 downto 0) <= HBM_axi_awready(4 downto 0);
        HBM_axi_wready_sigproc(4 downto 0) <= HBM_axi_wready(4 downto 0);
        HBM_axi_awready_sigproc(5) <= '1';
        HBM_axi_wready_sigproc(5) <= '1';
        
        sps_statsi : entity stats_lib.sps_statistics_top
        generic map (
            g_BUFFER_ADDR_BITS => 29,  -- integer := 30; -- number of bits in the HBM address; 30 = 2^30 bytes = 1 GByte
            g_USE_512BIT       => '0', -- std_logic := '0';    -- use 512 bit wide axi interface (otherwise use 256 bit)
            g_CLKS_PER_MILLISECOND => 322000 --  integer    -- Number of dsp_clk clks per 1 ms
        ) port map (
            -- Data in from the 100GE MAC
            i_axis_tdata => i_axis_tdata,   -- in std_logic_vector(511 downto 0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
            i_axis_tkeep => i_axis_tkeep,   -- in std_logic_vector(63 downto 0);  -- one bit per byte in i_axi_tdata
            i_axis_tlast => i_axis_tlast,   -- in std_logic;                      
            i_axis_tuser => i_axis_tuser,   -- in std_logic_vector(79 downto 0);  -- Timestamp for the packet.
            i_axis_tvalid => i_axis_tvalid, -- in std_logic;
            i_data_clk    => i_eth100G_clk, -- in std_logic;     -- 322 MHz for 100GE MAC
            i_data_rst    => '0', -- in std_logic;
            -- milliseconds between writing summaries to the HBM
            i_period_ms        => sps_monitor_period_eth_clk, -- , -- : in std_logic_vector(15 downto 0);
            o_time_since_wr_ms => sps_monitor_time_since_write_eth_clk, --  out std_logic_vector(15 downto 0); 
            ----------------------------------------------------------------------------------
            -- Data out to the memory interface; This is the wdata portion of the AXI full bus.
            i_ap_clk        => ap_clk, -- in  std_logic;  -- Shared memory clock used to access the HBM.
            i_ap_rst        => '0',    --  in  std_logic;
            o_axi_aw        => sps_mon_aw,         -- out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
            i_axi_awready   => HBM_axi_awready(5), -- in std_logic;
            o_axi_w         => sps_mon_w,          -- out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0)) => o_m01_axi_w,    -- w data bus (.wvalid, .wdata, .wlast)
            i_axi_wready    => HBM_axi_wready(5),  -- in std_logic;
            -----------------------------------------------------------------------------------
            -- Configuration and status
            o_status => open, -- out std_logic_vector(31 downto 0); -- ??? put something in here
            o_wrAddr => system_fields_ro.sps_monitor_wr_addr -- out (31:0); Most recent address written to in the HBM, on i_ap_clk
        );
        
        xpm_cdc_array_single_ap2ethi : xpm_cdc_array_single
        generic map (
            DEST_SYNC_FF => 2,   -- DECIMAL; range: 2-10
            INIT_SYNC_FF => 0,   -- DECIMAL; 0=disable simulation init values, 1=enable simulation init values
            SIM_ASSERT_CHK => 0, -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
            SRC_INPUT_REG => 1,  -- DECIMAL; 0=do not register input, 1=register input
            WIDTH => 16           -- DECIMAL; range: 1-1024
        ) port map (
            dest_out => sps_monitor_period_eth_clk,      -- WIDTH-bit output: src_in synchronized to the destination clock domain. This output is registered.
            dest_clk => i_eth100G_clk, -- 1-bit input: Clock signal for the destination clock domain.
            src_clk  => clk_300,        -- 1-bit input: optional; required when SRC_INPUT_REG = 1
            src_in   => system_fields_rw.sps_monitor_period         -- WIDTH-bit input: Input single-bit array to be synchronized to destination clock domain. 
        );
        
        xpm_cdc_array_single_eth2api : xpm_cdc_array_single
        generic map (
            DEST_SYNC_FF => 2,   -- DECIMAL; range: 2-10
            INIT_SYNC_FF => 0,   -- DECIMAL; 0=disable simulation init values, 1=enable simulation init values
            SIM_ASSERT_CHK => 0, -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
            SRC_INPUT_REG => 1,  -- DECIMAL; 0=do not register input, 1=register input
            WIDTH => 16           -- DECIMAL; range: 1-1024
        ) port map (
            dest_out => system_fields_ro.sps_monitor_time_since_write, -- WIDTH-bit output: src_in synchronized to the destination clock domain. This output is registered.
            dest_clk => clk_300,               -- 1-bit input: Clock signal for the destination clock domain.
            src_clk  => i_eth100G_clk,        -- 1-bit input: optional; required when SRC_INPUT_REG = 1
            src_in   => sps_monitor_time_since_write_eth_clk -- WIDTH-bit input: Input single-bit array to be synchronized to destination clock domain. 
        );
    
    end generate;
    
    o_dcmac_reset <= system_fields_rw.qsfpgty_resets;
    
    -- Uptime counter
    process(clk_300)
    begin
        if rising_edge(clk_300) then
            -- Assume 300 MHz for ap_clk, 
            if (unsigned(ap_clk_count) < 299999999) then
                ap_clk_count <= std_logic_vector(unsigned(ap_clk_count) + 1);
            else
                ap_clk_count <= (others => '0');
                uptime <= std_logic_vector(unsigned(uptime) + 1);
            end if;
            

            system_fields_ro.time_uptime                    <= uptime;
            system_fields_ro.status_clocks_locked           <= '1';
            system_fields_ro.eth100G_locked                 <= i_dcmac_locked_300m;
            system_fields_ro.eth100G_rx_total_packets       <= i_eth100G_rx_total_packets;
            system_fields_ro.eth100G_rx_bad_fcs             <= i_eth100G_rx_bad_fcs;
            system_fields_ro.eth100G_rx_bad_code            <= i_eth100G_rx_bad_code;
            system_fields_ro.eth100G_tx_total_packets       <= i_eth100G_tx_total_packets;
            system_fields_ro.eth100g_ptp_nano_seconds       <= x"BADBAD00";
            system_fields_ro.eth100g_ptp_lower_seconds      <= x"BADBAD00";
            system_fields_ro.eth100g_ptp_upper_seconds      <= x"BADBAD00";

            system_fields_ro.hbm_1_status_0                 <= HBM_gasket_stat(0,0);
            system_fields_ro.hbm_1_status_1                 <= HBM_gasket_stat(0,1);
            system_fields_ro.hbm_1_status_2                 <= HBM_gasket_stat(0,2);
            system_fields_ro.hbm_1_status_3                 <= HBM_gasket_stat(0,3);
            system_fields_ro.hbm_1_status_4                 <= HBM_gasket_stat(0,4);

            system_fields_ro.hbm_2_status_0                 <= HBM_gasket_stat(1,0);
            system_fields_ro.hbm_2_status_1                 <= HBM_gasket_stat(1,1);
            system_fields_ro.hbm_2_status_2                 <= HBM_gasket_stat(1,2);
            system_fields_ro.hbm_2_status_3                 <= HBM_gasket_stat(1,3);
            system_fields_ro.hbm_2_status_4                 <= HBM_gasket_stat(1,4);

            system_fields_ro.hbm_3_status_0                 <= HBM_gasket_stat(2,0);
            system_fields_ro.hbm_3_status_1                 <= HBM_gasket_stat(2,1);
            system_fields_ro.hbm_3_status_2                 <= HBM_gasket_stat(2,2);
            system_fields_ro.hbm_3_status_3                 <= HBM_gasket_stat(2,3);
            system_fields_ro.hbm_3_status_4                 <= HBM_gasket_stat(2,4);

            system_fields_ro.hbm_4_status_0                 <= HBM_gasket_stat(3,0);
            system_fields_ro.hbm_4_status_1                 <= HBM_gasket_stat(3,1);
            system_fields_ro.hbm_4_status_2                 <= HBM_gasket_stat(3,2);
            system_fields_ro.hbm_4_status_3                 <= HBM_gasket_stat(3,3);
            system_fields_ro.hbm_4_status_4                 <= HBM_gasket_stat(3,4);

            system_fields_ro.hbm_5_status_0                 <= HBM_gasket_stat(4,0);
            system_fields_ro.hbm_5_status_1                 <= HBM_gasket_stat(4,1);
            system_fields_ro.hbm_5_status_2                 <= HBM_gasket_stat(4,2);
            system_fields_ro.hbm_5_status_3                 <= HBM_gasket_stat(4,3);
            system_fields_ro.hbm_5_status_4                 <= HBM_gasket_stat(4,4);
            
        end if;
    end process;


    --------------------------------------------------------------------------
    --  Correlator Signal Processing
    
   dsp_topi : entity dsp_top_lib.DSP_top_correlator
   generic map (
       g_DEBUG_ILA             => g_DEBUG_ILA,
       g_SPS_PACKETS_PER_FRAME => g_SPS_PACKETS_PER_FRAME, -- for a single virtual channel, nominal value is 128 = 283 ms frames.
       g_USE_META              => g_USE_META,
       g_CORRELATORS           => g_CORRELATORS,  -- number of correlator blocks to instantiate.
       g_USE_DUMMY_FB          => g_USE_DUMMY_FB,
       g_INCLUDE_SPS_MONITOR   => g_INCLUDE_SPS_MONITOR
   ) port map (
       -- Received data from 100GE
       i_axis_tdata   => i_axis_tdata_gated,  -- in (511:0); 64 bytes of data, 1st byte in the packet is in bits 7:0.
       i_axis_tkeep   => i_axis_tkeep_gated,  -- in (63:0);  one bit per byte in i_axi_tdata
       i_axis_tlast   => i_axis_tlast_gated,  -- in std_logic;                      
       i_axis_tuser   => i_axis_tuser_gated,  -- in (79:0);  Timestamp for the packet.
       i_axis_tvalid  => i_axis_tvalid_gated, -- in std_logic;
       -- Data to be transmitted on 100GE
       o_bytes_to_transmit     => bytes_to_transmit,
       o_data_to_player        => data_to_player,
       o_data_to_player_wr     => data_to_player_wr,
       i_data_to_player_rdy    => data_to_player_rdy,
        
       i_clk_100GE         => clk_300,          -- CDC from 195 to 300 one level up.
       i_eth100G_locked    => i_dcmac_locked_300m,
       -- Filterbank processing clock, 450 MHz
       i_clk425            => clk425,  -- in std_logic;
       i_clk400            => clk400,  -- in std_logic;
       -----------------------------------------------------------------------
       -- reset of the valid memory is in progress.
       o_validMemRstActive => o_validMemRstActive,
       -----------------------------------------------------------------------
       -- AXI slave interfaces for modules
       i_MACE_clk  => clk_300, -- in std_logic;
       i_MACE_rst  => clk_300_rst, -- in std_logic;
       -- LFAADecode, lite + full slave
       i_LFAALite_axi_mosi             => c_axi4_lite_mosi_rst, 
       o_LFAALite_axi_miso => open,
       i_LFAAFull_axi_mosi             => c_axi4_full_mosi_null,
       o_LFAAFull_axi_miso => open,
       -- Corner Turn between LFAA Ingest and the filterbanks.
       i_LFAA_CT_axi_mosi              => c_axi4_lite_mosi_rst,
       o_LFAA_CT_axi_miso => open,
       i_poly_full_axi_mosi            => c_axi4_full_mosi_null,
       o_poly_full_axi_miso => open,
       -- Filterbanks
       i_FB_axi_mosi                   => c_axi4_lite_mosi_rst,
       o_FB_axi_miso => open,
       -- Corner turn between filterbanks and the correlator
       i_cor_CT_axi_mosi               => c_axi4_lite_mosi_rst,
       o_cor_CT_axi_miso => open,
       -- correlator
       i_cor_axi_mosi                  => c_axi4_lite_mosi_rst,
       o_cor_axi_miso => open,
       -- Output HBM
       i_spead_hbm_rd_lite_axi_mosi(0) => c_axi4_lite_mosi_rst,
       i_spead_hbm_rd_lite_axi_mosi(1) => c_axi4_lite_mosi_rst,
        
       o_spead_hbm_rd_lite_axi_miso(0) => o_null,
       o_spead_hbm_rd_lite_axi_miso(1) => o_null,
       
       i_spead_hbm_rd_full_axi_mosi(0) => c_axi4_full_mosi_null,
       i_spead_hbm_rd_full_axi_mosi(1) => c_axi4_full_mosi_null,

       o_spead_hbm_rd_full_axi_miso    => open,

       -- SDP SPEAD
       i_spead_lite_axi_mosi(0)        => c_axi4_lite_mosi_rst,
       i_spead_lite_axi_mosi(1)        => c_axi4_lite_mosi_rst,

       o_spead_lite_axi_miso           => open,

       i_spead_full_axi_mosi(0)        => c_axi4_full_mosi_null, 
       i_spead_full_axi_mosi(1)        => c_axi4_full_mosi_null, 

       o_spead_full_axi_miso           => open,

       -----------------------------------------------------------------------
       -- AXI interfaces to HBM memory (5 interfaces used)
       -- write address buses : out t_axi4_full_addr_arr(4:0)(.valid, .addr(39:0), .len(7:0))
       o_HBM_axi_aw      => HBM_axi_aw_sigproc,
       i_HBM_axi_awready => HBM_axi_awready_sigproc, -- in std_logic_vector(5:0);
       -- w data buses : out t_axi4_full_data_arr(5:0)(.valid, .data(511:0), .last, .resp(1:0))
       o_HBM_axi_w       => HBM_axi_w_sigproc,
       i_HBM_axi_wready  => HBM_axi_wready_sigproc,  -- in std_logic_vector(5:0);
       -- write response bus : in t_axi4_full_b_arr(5:0)(.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
       i_HBM_axi_b       => HBM_axi_b,
       -- read address bus : out t_axi4_full_addr_arr(5:0)(.valid, .addr(39:0), .len(7:0))
       o_HBM_axi_ar      => HBM_axi_ar,
       i_HBM_axi_arready => HBM_axi_arready, -- in std_logic_vector(5:0);
       -- r data bus : in t_axi4_full_data_arr(5:0)(.valid, .data(511:0), .last, .resp(1:0))
       i_HBM_axi_r       => HBM_axi_r,
       o_HBM_axi_rready  => HBM_axi_rready,  -- out std_logic_vector(5:0);
        
       -- trigger readout of the second corner turn data without waiting for the rest of the signal chain.
       -- used in testing with pre-load of the second corner turn HBM data
       i_ct2_readout_start => i_ct2_readout_start,
       i_ct2_readout_buffer => i_ct2_readout_buffer,
       i_ct2_readout_frameCount => i_ct2_readout_frameCount,
       ---------------------------------------------------------------
       -- copy of the bus taking data to be written to the HBM.
       -- Used for simulation only, to check against the model data.
       o_tb_data      => o_tb_data,     -- out (255:0);
       o_tb_visValid  => o_tb_visValid, -- out std_logic; -- o_tb_data is valid visibility data
       o_tb_TCIvalid  => o_tb_TCIvalid, -- out std_logic; -- i_data is valid TCI & DV data
       o_tb_dcount    => o_tb_dcount,   -- out (7:0);  -- counts the 256 transfers for one cell of visibilites, or 16 transfers for the centroid data. 
       o_tb_cell      => o_tb_cell,     -- out (7:0);  -- in (7:0);  -- a "cell" is a 16x16 station block of correlations
       o_tb_tile      => o_tb_tile,     -- out (9:0);  -- a "tile" is a 16x16 block of cells, i.e. a 256x256 station correlation.
       o_tb_channel   => o_tb_channel,  -- out (23:0) -- first fine channel index for this correlation.
       -- Start of a burst of data through the filterbank, 
       -- Used in the testbench to trigger download of the data written into the CT2 memory.
       o_FB_out_sof   => o_FB_out_sof,   -- out std_logic

       -- HBM reset
       o_hbm_reset          => hbm_reset,
       i_hbm_status         => hbm_status,
       i_hbm_rst_dbg        => hbm_rst_dbg,
       i_hbm_reset_final    => eth_disable_done,   -- 1 bit
       i_eth_disable_fsm_dbg => eth_disable_fsm_dbg, -- 5 bits
       i_axi_dbg            => axi_dbg, -- 128 bits
       i_axi_dbg_valid      => axi_dbg_valid,
       -- 100GE input disable
       o_lfaaDecode_reset   => lfaaDecode_reset,
       i_ethDisable_done    => eth_disable_done
   );
    
    hbm_reset_combined(0)               <= hbm_reset(0) OR i_input_HBM_reset;
    hbm_reset_combined(5 downto 1)      <= hbm_reset(5 downto 1);
    
    
    -----------------------------------------------------------------------------------------------------------
    CMAC_100G_reset_proc : process(i_eth100G_clk)
    begin
        if rising_edge(i_eth100G_clk) then
            eth100G_rst     <= NOT i_eth100G_locked;
        end if;
    end process;
    
    i_packet_player : entity versal_dcmac_lib.dcmac_packet_player
    Generic Map (
        g_DEBUG_ILA             => g_DEBUG_ILA,
        PLAYER_CDC_FIFO_DEPTH   => 1024        -- FIFO is 512 Wide, 9KB packets = 73728 bits, 512 * 256 = 131072, 256 depth allows ~1.88 9K packets, we are target packets sizes smaller than this.
    )
    Port Map ( 
        i_clk                   => clk_300,
        i_clk_reset             => clk_300_rst,
        
        i_bytes_to_transmit     => bytes_to_transmit,
        i_data_to_player        => data_to_player,
        i_data_to_player_wr     => data_to_player_wr,
        o_data_to_player_rdy    => data_to_player_rdy,
        
        o_dcmac_ready           => open,
        
        -- to DCMAC
        i_dcmac_clk             => i_eth100G_clk,
        i_dcmac_clk_rst         => eth100G_rst,

        -- segmented streaming AXI 
        o_data_to_transmit      => o_dcmac_tx_data_0,
        i_dcmac_ready           => i_dcmac_tx_ready_0
    );

    -----------------------------------------------------------------------------------------------------------
--    i_axis_tdata_gated  <= i_axis_tdata;
--    i_axis_tkeep_gated  <= i_axis_tkeep;
--    i_axis_tlast_gated  <= i_axis_tlast;
--    i_axis_tuser_gated  <= i_axis_tuser;
--    i_axis_tvalid_gated <= i_axis_tvalid;
    
    -- i_input_HBM_reset is only used in the testbench, it is tied to '0' for 
    eth_disable <= lfaaDecode_reset OR i_input_HBM_reset;
    
    
    eth_block : entity correlator_lib.eth_disable
    generic map (
        -- Number of i_ap_clk clocks to wait after blocking ethernet traffic before driving o_reset
        -- This allows us to wait a while for e.g. SPS input writes to HBM to complete properly
        g_HOLDOFF => 2048, -- : integer := 1024;
        -- Number of i_eth_clk clocks to wait before unblocking ethernet traffic after de-asserting o_reset
        g_RESTART_HOLDOFF => 2048 -- : integer := 4096
    ) port map (
        -- Reset signal is on i_ap_clk
        i_ap_clk  => clk_300,      --  in std_logic;
        i_reset   => eth_disable, --  in std_logic;  
        o_reset   => eth_disable_done,     --  out std_logic; -- Goes high following i_reset after the 100G ethernet has been blocked
        o_fsm_dbg => eth_disable_fsm_dbg, --  out std_logic_vector(4 downto 0); -- fsm state 
        -----------------------------------------------------
        -- DCMAC has been changed to 300 MHz in the V80 via CDC one level up.
        i_eth_clk    => clk_300, --  in std_logic;
        -----------------------------------------------------
        -- Received data from 100GE
        i_axis_tdata => i_axis_tdata, --  in std_logic_vector(511 downto 0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
        i_axis_tkeep => i_axis_tkeep, -- in std_logic_vector(63 downto 0);  -- one bit per byte in i_axi_tdata
        i_axis_tlast => i_axis_tlast, -- in std_logic;                      
        i_axis_tuser => i_axis_tuser, -- in std_logic_vector(79 downto 0);  -- Timestamp for the packet.
        i_axis_tvalid => i_axis_tvalid, -- in std_logic;
        -- Data output - 1 clock latency from input
        o_axis_tdata => i_axis_tdata_gated, -- out std_logic_vector(511 downto 0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
        o_axis_tkeep => i_axis_tkeep_gated, -- out std_logic_vector(63 downto 0);  -- one bit per byte in i_axi_tdata
        o_axis_tlast => i_axis_tlast_gated, -- out std_logic;                      
        o_axis_tuser => i_axis_tuser_gated, -- out std_logic_vector(79 downto 0);  -- Timestamp for the packet.
        o_axis_tvalid => i_axis_tvalid_gated -- out std_logic
        -----------------------------------------------------
    );     
    

    
    --------------------------------------------------------------------------------------------------
    -- debug
    debug_gen : IF g_DEBUG_ILA GENERATE
        debug_correlator_core : ila_0 
        Port map ( 
            clk                     => clk_300,
            probe0(31 downto 0)     => ap_clk_count,
            probe0(63 downto 32)    => i_eth100G_rx_total_packets,
            probe0(95 downto 64)    => i_eth100G_rx_bad_fcs,
            probe0(127 downto 96)   => i_eth100G_rx_bad_code,
            probe0(159 downto 128)  => i_eth100G_tx_total_packets,
            probe0(160)             => i_dcmac_locked_300m,
            
            probe0(191 downto 161)  => uptime(30 downto 0)
        );

        hbm_LFAAin_ila: ila_0
        PORT MAP (
            clk                     => clk_450,
        
            probe0(63 downto 0)     => HBM_axi_awaddr(0),
            probe0(127 downto 64)   => HBM_axi_araddr(0),
            probe0(135 downto 128)  => master_rd_addr_bus(0).len,
            probe0(143 downto 136)  => master_wr_addr_bus(0).len,
            probe0(144)             => master_wr_addr_bus_rdy(0),
            probe0(145)             => master_wr_addr_bus(0).valid,
        
            probe0(146)             => master_rd_data_bus(0).valid,
            probe0(147)             => master_rd_data_bus_rdy(0),
            probe0(148)             => master_rd_data_bus(0).last,
        
            probe0(149)             => master_wr_data_bus(0).valid,
            probe0(150)             => master_wr_data_bus_rdy(0),
            probe0(151)             => master_wr_data_bus(0).last,
            
            probe0(152)             => master_rd_addr_bus(0).valid,
            probe0(153)             => master_rd_addr_bus_rdy(0),
            
            probe0(169 downto 154)  => HBM_axi_buser(0),
            probe0(185 downto 170)  => HBM_axi_aruser(0),       
        
            probe0(191 downto 186)  => ( others => '0' )
        );

    END GENERATE;
    
    -----------------------------------------------------------------------------------------------------------
    hbm_ila_debug_chk : process(clk_450)
    begin
        if rising_edge(clk_450) then
            HBM_ila_counter <= HBM_ila_counter + 1;
        end if;
    end process;
    
    
axi_HBM_gen : for i in 0 to 4 generate

    hbm_gasket : entity common_lib.axi512_to_256
        Generic Map (
            NO_OF_STATUS    => HBM_GASKET_NO_OF_STATUS
        )
        Port Map (
            -- 256 wide connects to NOC MASTER UNIT.
            ---------------------------------------------------------
            -- 512 bit wide slave interface
            -- w bus
            i_clks          => clk_300,
            i_clks_reset    => clk_300_rst,

            i_axi_w         => slave_wr_data_bus(i),  -- write data (.valid, .data(511:0), .last, .resp(1:0))   
            o_axi_wready    => slave_wr_data_bus_rdy(i),
            -- aw bus - write address
            i_axi_aw        => slave_wr_addr_bus(i),
            o_axi_awready   => slave_wr_addr_bus_rdy(i),
            -- b bus - write response; not used; o_axi_b.valid is tied to '0'
            o_axi_b         => open, -- we don't use this.
            -- ar bus - read address
            i_axi_ar        => slave_rd_addr_bus(i),
            o_axi_arready   => slave_rd_addr_bus_rdy(i),
            -- r bus - read data
            o_axi_r         => slave_rd_data_bus(i),
            i_axi_rready    => slave_rd_data_bus_rdy(i),
            ---------------------------------------------------------
            -- 256 bit wide master interface
            -- w bus
            i_clkm          => clk_450,
            i_clkm_reset    => clk_450_rst,

            o_axi_w         => master_wr_data_bus(i),
            i_axi_wready    => master_wr_data_bus_rdy(i),
            -- aw bus - write address
            o_axi_aw        => master_wr_addr_bus(i),
            i_axi_awready   => master_wr_addr_bus_rdy(i),
            -- b bus - write response
            i_axi_b.valid   => '0',
            i_axi_b.resp    => "00",
            -- ar bus - read address
            o_axi_ar        => master_rd_addr_bus(i),
            i_axi_arready   => master_rd_addr_bus_rdy(i),
            -- r bus - read data
            i_axi_r         => master_rd_data_bus(i),
            o_axi_rready    => master_rd_data_bus_rdy(i),      -- we are always ready
            ----------------------------------------------------------
            -- Status
            o_status(0)     => HBM_gasket_stat(i,0),
            o_status(1)     => HBM_gasket_stat(i,1),
            o_status(2)     => HBM_gasket_stat(i,2),
            o_status(3)     => HBM_gasket_stat(i,3),
            o_status(4)     => HBM_gasket_stat(i,4)
        );

    slave_wr_data_bus(i)        <= HBM_axi_w(i);
    HBM_axi_wready(i)           <= slave_wr_data_bus_rdy(i);

    slave_wr_addr_bus(i)        <= HBM_axi_aw(i);
    HBM_axi_awready(i)          <= slave_wr_addr_bus_rdy(i);
    

    HBM_axi_r(i)                <= slave_rd_data_bus(i);
    slave_rd_data_bus_rdy(i)    <= HBM_axi_rready(i);
    
    slave_rd_addr_bus(i)        <= HBM_axi_ar(i);
    HBM_axi_arready(i)          <= slave_rd_addr_bus_rdy(i);


    ------------------------------------------------------------------------------------
    -- ar and aw addresses need to be set to the correct offset within the HBM
    HBM_axi_araddr256Mbyte(i)          <= master_rd_addr_bus(i).addr(35 downto 28); -- 8 bit address of 256MByte pieces, within 64 Gbytes ((35:0) addresses 64 Gbytes)
    HBM_axi_araddr(i)(63 downto 36)    <= HBM_base_addr(i)(63 downto 36);
    HBM_axi_araddr(i)(35 downto 28)    <= std_logic_vector(unsigned(HBM_base_addr(i)(35 downto 28)) + unsigned(HBM_axi_araddr256Mbyte(i)));
    HBM_axi_araddr(i)(27 downto 0)     <= master_rd_addr_bus(i).addr(27 downto 0);
    
    HBM_axi_awaddr256Mbyte(i)          <= master_wr_addr_bus(i).addr(35 downto 28); -- 8 bit address of 256MByte pieces, within 64 Gbytes ((35:0) addresses 64 Gbytes)
    HBM_axi_awaddr(i)(63 downto 36)    <= HBM_base_addr(i)(63 downto 36);
    HBM_axi_awaddr(i)(35 downto 28)    <= std_logic_vector(unsigned(HBM_base_addr(i)(35 downto 28)) + unsigned(HBM_axi_awaddr256Mbyte(i)));
    HBM_axi_awaddr(i)(27 downto 0)     <= master_wr_addr_bus(i).addr(27 downto 0);
    
    -- register slice ports that have a fixed value.
    HBM_axi_awsize(i)       <= get_axi_size(NOC_DATA_WIDTH);
    HBM_axi_awburst(i)      <= "01";   -- "01" indicates incrementing addresses for each beat in the burst.  -- out std_logic_vector(1 downto 0);
    HBM_axi_bready(i)       <= '1';  -- Always accept acknowledgement of write transactions. -- out std_logic;
    HBM_axi_wstrb(i)        <= (others => '1');  -- We always write all bytes in the bus. --  out std_logic_vector(63 downto 0);
    HBM_axi_arsize(i)       <= get_axi_size(NOC_DATA_WIDTH);   -- 6 = 64 bytes per beat = 512 bit wide bus. -- out std_logic_vector(2 downto 0);
    HBM_axi_arburst(i)      <= "01";    -- "01" = incrementing address for each beat in the burst. -- out std_logic_vector(1 downto 0);
    
    -- these have no ports on the axi register slice
    HBM_axi_arlock(i)(0)    <= '0';
    HBM_axi_awlock(i)(0)    <= '0';
    HBM_axi_awcache(i)      <= "0011";  -- out std_logic_vector(3 downto 0); bufferable transaction. Default in Vitis environment.
    HBM_axi_awprot(i)       <= "000";   -- Has no effect in Vitis environment. -- out std_logic_vector(2 downto 0);
    HBM_axi_awqos(i)        <= "0000";  -- Has no effect in vitis environment, -- out std_logic_vector(3 downto 0);
    HBM_axi_awregion(i)     <= "0000"; -- Has no effect in Vitis environment. -- out std_logic_vector(3 downto 0);
    HBM_axi_arcache(i)      <= "0011";  -- out std_logic_vector(3 downto 0); bufferable transaction. Default in Vitis environment.
    HBM_axi_arprot(i)       <= "000";   -- Has no effect in vitis environment; out std_logic_Vector(2 downto 0);
    HBM_axi_arqos(i)        <= "0000"; -- Has no effect in vitis environment; out std_logic_vector(3 downto 0);
    HBM_axi_arregion(i)     <= "0000"; -- Has no effect in vitis environment; out std_logic_vector(3 downto 0);
    HBM_axi_awid(i)(0)      <= '0';   -- We only use a single ID -- out std_logic_vector(0 downto 0);
    HBM_axi_arid(i)(0)      <= '0';     -- ID are not used. -- out std_logic_vector(0 downto 0);

    HBM_axi_awuser(i)       <= x"0000";     -- New NOC fields to keeep an eye on.
    HBM_axi_wid(i)(0)       <= '0';         -- New NOC fields to keeep an eye on.
    HBM_axi_wuser(i)(0)     <= '0';         -- New NOC fields to keeep an eye on.

    -- HBM Master NoC
    i_hbm_noc : xpm_nmu_mm
        generic map (
            NOC_FABRIC    => "VNOC",			-- pl/pl_hbm
            DATA_WIDTH    => NOC_DATA_WIDTH,			-- 32/64/128/256/512
            ADDR_WIDTH    => NOC_ADDR_WIDTH,			-- 12 to 64
            ID_WIDTH      => NOC_ID_WIDTH,				-- 1 to 16
            AUSER_WIDTH   => NOC_AUSER_WIDTH,			-- 16 for VNOC with parity disabled, 18 for VNOC with parity enabled 
            DUSER_WIDTH   => NOC_DUSER_WIDTH,			-- 2*DATA_WIDTH/8 for parity enablement with VNOC, 1 for VNOC with parity disabled cases
            ENABLE_USR_INTERRUPT => "false",	-- false/true
            SIDEBAND_PINS => "false"		-- false/true/addr/data
        )
        port map ( 
            s_axi_aclk              => clk_450,
            
            -----------------------------------------------------
            -- To Logic
            -- ADDR
            s_axi_awid              => HBM_axi_awid(i),
            s_axi_awaddr            => HBM_axi_awaddr(i), --HBM_axi_aw(i).addr,
            s_axi_awlen             => master_wr_addr_bus(i).len,
            s_axi_awsize            => HBM_axi_awsize(i),
            s_axi_awburst           => HBM_axi_awburst(i),
            s_axi_awlock            => HBM_axi_awlock(i),
            s_axi_awcache           => HBM_axi_awcache(i),
            s_axi_awprot            => HBM_axi_awprot(i),
            s_axi_awregion          => HBM_axi_awregion(i),
            s_axi_awqos             => HBM_axi_awqos(i),
            s_axi_awuser            => HBM_axi_awuser(i),                -- Where does this go?
            s_axi_awvalid           => master_wr_addr_bus(i).valid,
            s_axi_awready           => master_wr_addr_bus_rdy(i),

            -- DATA
            s_axi_wid               => HBM_axi_wid(i),
            s_axi_wdata             => master_wr_data_bus(i).data(255 downto 0),
            s_axi_wstrb             => HBM_axi_wstrb(i)(31 downto 0),
            s_axi_wlast             => master_wr_data_bus(i).last,
            s_axi_wuser             => HBM_axi_wuser(i),
            s_axi_wvalid            => master_wr_data_bus(i).valid,
            s_axi_wready            => master_wr_data_bus_rdy(i),

            s_axi_bid               => HBM_axi_bid(i),
            s_axi_bresp             => HBM_axi_b(i).resp,
            s_axi_buser             => HBM_axi_buser(i),
            s_axi_bvalid            => HBM_axi_b(i).valid,
            s_axi_bready            => HBM_axi_bready(i),
            
            -- reading from logic
            -- ADDR

            s_axi_arid              => HBM_axi_arid(i),
            s_axi_araddr            => HBM_axi_araddr(i), --HBM_axi_ar(i).addr,
            s_axi_arlen             => master_rd_addr_bus(i).len,
            s_axi_arsize            => HBM_axi_arsize(i),
            s_axi_arburst           => HBM_axi_arburst(i),
            s_axi_arlock            => HBM_axi_arlock(i),
            s_axi_arcache           => HBM_axi_arcache(i),
            s_axi_arprot            => HBM_axi_arprot(i),
            s_axi_arregion          => HBM_axi_arregion(i),
            s_axi_arqos             => HBM_axi_arqos(i),
            s_axi_aruser            => HBM_axi_aruser(i),
            s_axi_arvalid           => master_rd_addr_bus(i).valid,
            s_axi_arready           => master_rd_addr_bus_rdy(i),

            -- DATA
            s_axi_rid               => HBM_axi_rid(i),
            s_axi_rdata             => master_rd_data_bus(i).data(255 downto 0),
            s_axi_rresp             => master_rd_data_bus(i).resp,
            s_axi_rlast             => master_rd_data_bus(i).last,
            s_axi_ruser             => HBM_axi_ruser(i),
            s_axi_rvalid            => master_rd_data_bus(i).valid,
            s_axi_rready            => master_rd_data_bus_rdy(i),
            
            nmu_usr_interrupt_in    => x"0"
        
        );

END GENERATE;


-- Interfaces that use 256 bits natively
--  sps stats module is 256 bits already, don't include the axi512_to_256 gasket
sps_stats_gen : if g_INCLUDE_SPS_MONITOR generate
    axi_sps_stats_gen : for i in 5 to 5 generate

--    hbm_gasket : entity common_lib.axi512_to_256
--        Generic Map (
--            NO_OF_STATUS    => HBM_GASKET_NO_OF_STATUS
--        )
--        Port Map (
--            -- 256 wide connects to NOC MASTER UNIT.
--            ---------------------------------------------------------
--            -- 512 bit wide slave interface
--            -- w bus
--            i_clks          => clk_300,
--            i_clks_reset    => clk_300_rst,

--            i_axi_w         => slave_wr_data_bus(i),  -- write data (.valid, .data(511:0), .last, .resp(1:0))   
--            o_axi_wready    => slave_wr_data_bus_rdy(i),
--            -- aw bus - write address
--            i_axi_aw        => slave_wr_addr_bus(i),
--            o_axi_awready   => slave_wr_addr_bus_rdy(i),
--            -- b bus - write response; not used; o_axi_b.valid is tied to '0'
--            o_axi_b         => open, -- we don't use this.
--            -- ar bus - read address
--            i_axi_ar        => slave_rd_addr_bus(i),
--            o_axi_arready   => slave_rd_addr_bus_rdy(i),
--            -- r bus - read data
--            o_axi_r         => slave_rd_data_bus(i),
--            i_axi_rready    => slave_rd_data_bus_rdy(i),
--            ---------------------------------------------------------
--            -- 256 bit wide master interface
--            -- w bus
--            i_clkm          => clk_450,
--            i_clkm_reset    => clk_450_rst,

--            o_axi_w         => master_wr_data_bus(i),
--            i_axi_wready    => master_wr_data_bus_rdy(i),
--            -- aw bus - write address
--            o_axi_aw        => master_wr_addr_bus(i),
--            i_axi_awready   => master_wr_addr_bus_rdy(i),
--            -- b bus - write response
--            i_axi_b.valid   => '0',
--            i_axi_b.resp    => "00",
--            -- ar bus - read address
--            o_axi_ar        => master_rd_addr_bus(i),
--            i_axi_arready   => master_rd_addr_bus_rdy(i),
--            -- r bus - read data
--            i_axi_r         => master_rd_data_bus(i),
--            o_axi_rready    => master_rd_data_bus_rdy(i),      -- we are always ready
--            ----------------------------------------------------------
--            -- Status
--            o_status(0)     => HBM_gasket_stat(i,0),
--            o_status(1)     => HBM_gasket_stat(i,1),
--            o_status(2)     => HBM_gasket_stat(i,2),
--            o_status(3)     => HBM_gasket_stat(i,3),
--            o_status(4)     => HBM_gasket_stat(i,4)
--        );

    ------------------------------------------------------------------------------------
    -- ar and aw addresses need to be set to the correct offset within the HBM
    HBM_axi_araddr256Mbyte(i)          <= HBM_axi_ar(i).addr(35 downto 28); -- 8 bit address of 256MByte pieces, within 64 Gbytes ((35:0) addresses 64 Gbytes)
    HBM_axi_araddr(i)(63 downto 36)    <= HBM_base_addr(i)(63 downto 36);
    HBM_axi_araddr(i)(35 downto 28)    <= std_logic_vector(unsigned(HBM_base_addr(i)(35 downto 28)) + unsigned(HBM_axi_araddr256Mbyte(i)));
    HBM_axi_araddr(i)(27 downto 0)     <= HBM_axi_ar(i).addr(27 downto 0);
    
    HBM_axi_awaddr256Mbyte(i)          <= HBM_axi_aw(i).addr(35 downto 28); -- 8 bit address of 256MByte pieces, within 64 Gbytes ((35:0) addresses 64 Gbytes)
    HBM_axi_awaddr(i)(63 downto 36)    <= HBM_base_addr(i)(63 downto 36);
    HBM_axi_awaddr(i)(35 downto 28)    <= std_logic_vector(unsigned(HBM_base_addr(i)(35 downto 28)) + unsigned(HBM_axi_awaddr256Mbyte(i)));
    HBM_axi_awaddr(i)(27 downto 0)     <= HBM_axi_aw(i).addr(27 downto 0);
    
    -- register slice ports that have a fixed value.
    HBM_axi_awsize(i)       <= get_axi_size(NOC_DATA_WIDTH);
    HBM_axi_awburst(i)      <= "01";   -- "01" indicates incrementing addresses for each beat in the burst.  -- out std_logic_vector(1 downto 0);
    HBM_axi_bready(i)       <= '1';  -- Always accept acknowledgement of write transactions. -- out std_logic;
    HBM_axi_wstrb(i)        <= (others => '1');  -- We always write all bytes in the bus. --  out std_logic_vector(63 downto 0);
    HBM_axi_arsize(i)       <= get_axi_size(NOC_DATA_WIDTH);   -- 6 = 64 bytes per beat = 512 bit wide bus. -- out std_logic_vector(2 downto 0);
    HBM_axi_arburst(i)      <= "01";    -- "01" = incrementing address for each beat in the burst. -- out std_logic_vector(1 downto 0);
    
    -- these have no ports on the axi register slice
    HBM_axi_arlock(i)(0)    <= '0';
    HBM_axi_awlock(i)(0)    <= '0';
    HBM_axi_awcache(i)      <= "0011";  -- out std_logic_vector(3 downto 0); bufferable transaction. Default in Vitis environment.
    HBM_axi_awprot(i)       <= "000";   -- Has no effect in Vitis environment. -- out std_logic_vector(2 downto 0);
    HBM_axi_awqos(i)        <= "0000";  -- Has no effect in vitis environment, -- out std_logic_vector(3 downto 0);
    HBM_axi_awregion(i)     <= "0000"; -- Has no effect in Vitis environment. -- out std_logic_vector(3 downto 0);
    HBM_axi_arcache(i)      <= "0011";  -- out std_logic_vector(3 downto 0); bufferable transaction. Default in Vitis environment.
    HBM_axi_arprot(i)       <= "000";   -- Has no effect in vitis environment; out std_logic_Vector(2 downto 0);
    HBM_axi_arqos(i)        <= "0000"; -- Has no effect in vitis environment; out std_logic_vector(3 downto 0);
    HBM_axi_arregion(i)     <= "0000"; -- Has no effect in vitis environment; out std_logic_vector(3 downto 0);
    HBM_axi_awid(i)(0)      <= '0';   -- We only use a single ID -- out std_logic_vector(0 downto 0);
    HBM_axi_arid(i)(0)      <= '0';     -- ID are not used. -- out std_logic_vector(0 downto 0);

    HBM_axi_awuser(i)       <= x"0000";     -- New NOC fields to keeep an eye on.
    HBM_axi_wid(i)(0)       <= '0';         -- New NOC fields to keeep an eye on.
    HBM_axi_wuser(i)(0)     <= '0';         -- New NOC fields to keeep an eye on.

    -- HBM Master NoC
    i_hbm_noc : xpm_nmu_mm
        generic map (
            NOC_FABRIC    => "VNOC",			-- pl/pl_hbm
            DATA_WIDTH    => NOC_DATA_WIDTH,			-- 32/64/128/256/512
            ADDR_WIDTH    => NOC_ADDR_WIDTH,			-- 12 to 64
            ID_WIDTH      => NOC_ID_WIDTH,				-- 1 to 16
            AUSER_WIDTH   => NOC_AUSER_WIDTH,			-- 16 for VNOC with parity disabled, 18 for VNOC with parity enabled 
            DUSER_WIDTH   => NOC_DUSER_WIDTH,			-- 2*DATA_WIDTH/8 for parity enablement with VNOC, 1 for VNOC with parity disabled cases
            ENABLE_USR_INTERRUPT => "false",	-- false/true
            SIDEBAND_PINS => "false"		-- false/true/addr/data
        )
        port map ( 
            s_axi_aclk              => clk_300,  -- 300MHz clock is fine for the SPS stats, bandwidth requirement is low.
            
            -----------------------------------------------------
            -- To Logic
            -- ADDR
            s_axi_awid              => HBM_axi_awid(i),
            s_axi_awaddr            => HBM_axi_awaddr(i), --HBM_axi_aw(i).addr,
            s_axi_awlen             => HBM_axi_aw(i).len,
            s_axi_awsize            => HBM_axi_awsize(i),
            s_axi_awburst           => HBM_axi_awburst(i),
            s_axi_awlock            => HBM_axi_awlock(i),
            s_axi_awcache           => HBM_axi_awcache(i),
            s_axi_awprot            => HBM_axi_awprot(i),
            s_axi_awregion          => HBM_axi_awregion(i),
            s_axi_awqos             => HBM_axi_awqos(i),
            s_axi_awuser            => HBM_axi_awuser(i),                -- Where does this go?
            s_axi_awvalid           => HBM_axi_aw(i).valid,
            s_axi_awready           => HBM_axi_awready(i),

            -- DATA
            s_axi_wid               => HBM_axi_wid(i),
            s_axi_wdata             => HBM_axi_w(i).data(255 downto 0),
            s_axi_wstrb             => HBM_axi_wstrb(i)(31 downto 0),
            s_axi_wlast             => HBM_axi_w(i).last,
            s_axi_wuser             => HBM_axi_wuser(i),
            s_axi_wvalid            => HBM_axi_w(i).valid,
            s_axi_wready            => HBM_axi_wready(i),

            s_axi_bid               => HBM_axi_bid(i),
            s_axi_bresp             => HBM_axi_b(i).resp,
            s_axi_buser             => HBM_axi_buser(i),
            s_axi_bvalid            => HBM_axi_b(i).valid,
            s_axi_bready            => HBM_axi_bready(i),
            
            -- reading from logic
            -- ADDR

            s_axi_arid              => HBM_axi_arid(i),
            s_axi_araddr            => HBM_axi_araddr(i), --HBM_axi_ar(i).addr,
            s_axi_arlen             => HBM_axi_ar(i).len,
            s_axi_arsize            => HBM_axi_arsize(i),
            s_axi_arburst           => HBM_axi_arburst(i),
            s_axi_arlock            => HBM_axi_arlock(i),
            s_axi_arcache           => HBM_axi_arcache(i),
            s_axi_arprot            => HBM_axi_arprot(i),
            s_axi_arregion          => HBM_axi_arregion(i),
            s_axi_arqos             => HBM_axi_arqos(i),
            s_axi_aruser            => HBM_axi_aruser(i),
            s_axi_arvalid           => HBM_axi_ar(i).valid,
            s_axi_arready           => HBM_axi_arready(i),

            -- DATA
            s_axi_rid               => HBM_axi_rid(i),
            s_axi_rdata             => HBM_axi_r(i).data(255 downto 0),
            s_axi_rresp             => HBM_axi_r(i).resp,
            s_axi_rlast             => HBM_axi_r(i).last,
            s_axi_ruser             => HBM_axi_ruser(i),
            s_axi_rvalid            => HBM_axi_r(i).valid,
            s_axi_rready            => HBM_axi_rready(i),
            
            nmu_usr_interrupt_in    => x"0"
        );

    END GENERATE;
end generate;

    
END structure;
