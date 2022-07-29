-------------------------------------------------------------------------------
--
-- File Name: correlator.vhd
-- Contributing Authors: Giles Babich, David Humphrey
-- Template Rev: 1.0
--
-- Title: Top Level for vitis compatible acceleration core
--
-------------------------------------------------------------------------------

LIBRARY IEEE, UNISIM, common_lib, axi4_lib, technology_lib, util_lib, dsp_top_lib, correlator_lib;
library LFAADecode_lib, timingcontrol_lib, capture128bit_lib;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE common_lib.common_pkg.ALL;
USE common_lib.common_mem_pkg.ALL;
USE axi4_lib.axi4_lite_pkg.ALL;
USE axi4_lib.axi4_stream_pkg.ALL;
USE axi4_lib.axi4_full_pkg.ALL;
USE technology_lib.tech_mac_100g_pkg.ALL;
USE technology_lib.technology_pkg.ALL;
USE technology_lib.technology_select_pkg.all;
--USE vcu128_board_lib.ip_pkg.ALL;
--USE vcu128_board_lib.board_pkg.ALL;
--USE tech_mac_100g_lib.tech_mac_100g_pkg.ALL;

USE work.correlator_bus_pkg.ALL;
USE work.correlator_system_reg_pkg.ALL;
USE UNISIM.vcomponents.all;
Library xpm;
use xpm.vcomponents.all;

-------------------------------------------------------------------------------
ENTITY correlator_core IS
    generic (
        -- GENERICS for use in the testbench 
        g_SIMULATION : BOOLEAN := FALSE;  -- when true, the 100GE core is disabled and instead the lbus comes from the top level pins
        g_USE_META : boolean := FALSE;    -- Put meta data into the memory in place of the actual data, to make it easier to find bugs in the corner turn.
        -- GLOBAL GENERICS for PERENTIE LOGIC
        g_DEBUG_ILA                     : BOOLEAN := FALSE;
        -- Number of LFAA blocks per first stage corner turn frame; Nominal (and maximum allowed) value is 128;
        -- Allowed values are 32, 64, 128.
        -- Minimum possible value is 32, since we need enough preload data in a buffer to initialise the filterbanks
        -- Filterbanks need 11 x 4096 samples for initialisation; That's 22 LFAA frames (since they are 2048 samples).
        g_LFAA_BLOCKS_PER_FRAME   : integer := 128;  -- Number of LFAA blocks per frame divided by 3; minimum value is 1, i.e. 3 LFAA blocks per frame.
        g_FIRMWARE_MAJOR_VERSION        : std_logic_vector(15 downto 0) := x"0000";
        g_FIRMWARE_MINOR_VERSION        : std_logic_vector(15 downto 0) := x"0000";
        g_FIRMWARE_PATCH_VERSION        : std_logic_vector(15 downto 0) := x"0000";
        g_FIRMWARE_LABEL                : std_logic_vector(31 downto 0) := x"00000000";
        g_FIRMWARE_PERSONALITY          : std_logic_vector(31 downto 0) := x"20434F52"; -- ascii " COR"
        g_FIRMWARE_BUILD_DATE           : std_logic_vector(31 downto 0) := x"00000000";
        -- GENERICS for SHELL INTERACTION
        C_S_AXI_CONTROL_ADDR_WIDTH : integer := 7;
        C_S_AXI_CONTROL_DATA_WIDTH : integer := 32;
        C_M_AXI_ADDR_WIDTH : integer := 64;
        C_M_AXI_DATA_WIDTH : integer := 32;
        C_M_AXI_ID_WIDTH   : integer := 1;
        -- M01 = first stage corner turn, between LFAA ingest and the filterbanks
        M01_AXI_ADDR_WIDTH : integer := 64; 
        M01_AXI_DATA_WIDTH : integer := 512;
        M01_AXI_ID_WIDTH   : integer := 1;
        -- M02 = Correlator HBM; buffer between the filterbanks and the correlator
        M02_AXI_ADDR_WIDTH : integer := 64; 
        M02_AXI_DATA_WIDTH : integer := 512; 
        M02_AXI_ID_WIDTH   : integer := 1;
        -- M03 = Visibilities
        M03_AXI_ADDR_WIDTH : integer := 64;  
        M03_AXI_DATA_WIDTH : integer := 512; 
        M03_AXI_ID_WIDTH   : integer := 1
    );
    PORT (
        ap_clk : in std_logic;
        ap_rst_n : in std_logic;
        
        -----------------------------------------------------------------------
        -- Ports used for simulation only.
        --
        -- Received data from 100GE
        i_eth100_rx_sosi : in t_lbus_sosi;
        -- Data to be transmitted on 100GE
        o_eth100_tx_sosi : out t_lbus_sosi;
        i_eth100_tx_siso : in t_lbus_siso;
        i_clk_100GE    : in std_logic;
        -- reset of the valid memory is in progress.
        o_validMemRstActive : out std_logic;
        --------------------------------------------------------------------------------------
        --  Note: A minimum subset of AXI4 memory mapped signals are declared.  AXI
        --  signals omitted from these interfaces are automatically inferred with the
        -- optimal values for Xilinx SDx systems.  This allows Xilinx AXI4 Interconnects
        -- within the system to be optimized by removing logic for AXI4 protocol
        -- features that are not necessary. When adapting AXI4 masters within the RTL
        -- kernel that have signals not declared below, it is suitable to add the
        -- signals to the declarations below to connect them to the AXI4 Master.
        --
        -- List of ommited signals - effect
        -- -------------------------------
        -- ID     - Transaction ID are used for multithreading and out of order transactions.  This increases complexity. This saves logic and increases Fmax in the system when ommited.
        -- SIZE   - Default value is log2(data width in bytes). Needed for subsize bursts. This saves logic and increases Fmax in the system when ommited.
        -- BURST  - Default value (0b01) is incremental.  Wrap and fixed bursts are not recommended. This saves logic and increases Fmax in the system when ommited.
        -- LOCK   - Not supported in AXI4
        -- CACHE  - Default value (0b0011) allows modifiable transactions. No benefit to changing this.
        -- PROT   - Has no effect in SDx systems.
        -- QOS    - Has no effect in SDx systems.
        -- REGION - Has no effect in SDx systems.
        -- USER   - Has no effect in SDx systems.
        -- RESP   - Not useful in most SDx systems.
        --------------------------------------------------------------------------------------
        --  AXI4-Lite slave interface
        s_axi_control_awvalid : in std_logic;
        s_axi_control_awready : out std_logic;
        s_axi_control_awaddr : in std_logic_vector(C_S_AXI_CONTROL_ADDR_WIDTH-1 downto 0);
        s_axi_control_wvalid : in std_logic;
        s_axi_control_wready : out std_logic;
        s_axi_control_wdata  : in std_logic_vector(C_S_AXI_CONTROL_DATA_WIDTH-1 downto 0);
        s_axi_control_wstrb  : in std_logic_vector(C_S_AXI_CONTROL_DATA_WIDTH/8-1 downto 0);
        s_axi_control_arvalid : in std_logic;
        s_axi_control_arready : out std_logic;
        s_axi_control_araddr : in std_logic_vector(C_S_AXI_CONTROL_ADDR_WIDTH-1 downto 0);
        s_axi_control_rvalid : out std_logic;
        s_axi_control_rready : in std_logic;
        s_axi_control_rdata  : out std_logic_vector(C_S_AXI_CONTROL_DATA_WIDTH-1 downto 0);
        s_axi_control_rresp  : out std_logic_vector(1 downto 0);
        s_axi_control_bvalid : out std_logic;
        s_axi_control_bready : in std_logic;
        s_axi_control_bresp  : out std_logic_vector(1 downto 0);
  
        -- AXI4 master interface for accessing registers : m00_axi
        m00_axi_awvalid : out std_logic;
        m00_axi_awready : in std_logic;
        m00_axi_awaddr : out std_logic_vector(C_M_AXI_ADDR_WIDTH-1 downto 0);
        m00_axi_awid   : out std_logic_vector(C_M_AXI_ID_WIDTH - 1 downto 0);
        m00_axi_awlen   : out std_logic_vector(7 downto 0);
        m00_axi_awsize   : out std_logic_vector(2 downto 0);
        m00_axi_awburst  : out std_logic_vector(1 downto 0);
        m00_axi_awlock   : out std_logic_vector(1 downto 0);
        m00_axi_awcache  : out std_logic_vector(3 downto 0);
        m00_axi_awprot   : out std_logic_vector(2 downto 0);
        m00_axi_awqos    : out std_logic_vector(3 downto 0);
        m00_axi_awregion : out std_logic_vector(3 downto 0);
    
        m00_axi_wvalid    : out std_logic;
        m00_axi_wready    : in std_logic;
        m00_axi_wdata     : out std_logic_vector(C_M_AXI_DATA_WIDTH-1 downto 0);
        m00_axi_wstrb     : out std_logic_vector(C_M_AXI_DATA_WIDTH/8-1 downto 0);
        m00_axi_wlast     : out std_logic;
        m00_axi_bvalid    : in std_logic;
        m00_axi_bready    : out std_logic;
        m00_axi_bresp     : in std_logic_vector(1 downto 0);
        m00_axi_bid       : in std_logic_vector(C_M_AXI_ID_WIDTH - 1 downto 0);
        m00_axi_arvalid   : out std_logic;
        m00_axi_arready   : in std_logic;
        m00_axi_araddr    : out std_logic_vector(C_M_AXI_ADDR_WIDTH-1 downto 0);
        m00_axi_arid      : out std_logic_vector(C_M_AXI_ID_WIDTH-1 downto 0);
        m00_axi_arlen     : out std_logic_vector(7 downto 0);
        m00_axi_arsize    : out std_logic_vector(2 downto 0);
        m00_axi_arburst   : out std_logic_vector(1 downto 0);
        m00_axi_arlock    : out std_logic_vector(1 downto 0);
        m00_axi_arcache   : out std_logic_vector(3 downto 0);
        m00_axi_arprot    : out std_logic_Vector(2 downto 0);
        m00_axi_arqos     : out std_logic_vector(3 downto 0);
        m00_axi_arregion  : out std_logic_vector(3 downto 0);
        m00_axi_rvalid    : in std_logic;
        m00_axi_rready    : out std_logic;
        m00_axi_rdata     : in std_logic_vector(C_M_AXI_DATA_WIDTH-1 downto 0);
        m00_axi_rlast     : in std_logic;
        m00_axi_rid       : in std_logic_vector(C_M_AXI_ID_WIDTH - 1 downto 0);
        m00_axi_rresp     : in std_logic_vector(1 downto 0);
        ---------------------------------------------------------------------------------------
        -- AXI4 master interface for accessing HBM for the LFAA ingest corner turn : m01_axi
        m01_axi_awvalid : out std_logic;
        m01_axi_awready : in std_logic;
        m01_axi_awaddr : out std_logic_vector(M01_AXI_ADDR_WIDTH-1 downto 0);
        m01_axi_awid   : out std_logic_vector(M01_AXI_ID_WIDTH - 1 downto 0);
        m01_axi_awlen   : out std_logic_vector(7 downto 0);
        m01_axi_awsize   : out std_logic_vector(2 downto 0);
        m01_axi_awburst  : out std_logic_vector(1 downto 0);
        m01_axi_awlock   : out std_logic_vector(1 downto 0);
        m01_axi_awcache  : out std_logic_vector(3 downto 0);
        m01_axi_awprot   : out std_logic_vector(2 downto 0);
        m01_axi_awqos    : out std_logic_vector(3 downto 0);
        m01_axi_awregion : out std_logic_vector(3 downto 0);
    
        m01_axi_wvalid    : out std_logic;
        m01_axi_wready    : in std_logic;
        m01_axi_wdata     : out std_logic_vector(M01_AXI_DATA_WIDTH-1 downto 0);
        m01_axi_wstrb     : out std_logic_vector(M01_AXI_DATA_WIDTH/8-1 downto 0);
        m01_axi_wlast     : out std_logic;
        m01_axi_bvalid    : in std_logic;
        m01_axi_bready    : out std_logic;
        m01_axi_bresp     : in std_logic_vector(1 downto 0);
        m01_axi_bid       : in std_logic_vector(M01_AXI_ID_WIDTH - 1 downto 0);
        m01_axi_arvalid   : out std_logic;
        m01_axi_arready   : in std_logic;
        m01_axi_araddr    : out std_logic_vector(M01_AXI_ADDR_WIDTH-1 downto 0);
        m01_axi_arid      : out std_logic_vector(M01_AXI_ID_WIDTH-1 downto 0);
        m01_axi_arlen     : out std_logic_vector(7 downto 0);
        m01_axi_arsize    : out std_logic_vector(2 downto 0);
        m01_axi_arburst   : out std_logic_vector(1 downto 0);
        m01_axi_arlock    : out std_logic_vector(1 downto 0);
        m01_axi_arcache   : out std_logic_vector(3 downto 0);
        m01_axi_arprot    : out std_logic_Vector(2 downto 0);
        m01_axi_arqos     : out std_logic_vector(3 downto 0);
        m01_axi_arregion  : out std_logic_vector(3 downto 0);
        m01_axi_rvalid    : in std_logic;
        m01_axi_rready    : out std_logic;
        m01_axi_rdata     : in std_logic_vector(M01_AXI_DATA_WIDTH-1 downto 0);
        m01_axi_rlast     : in std_logic;
        m01_axi_rid       : in std_logic_vector(M01_AXI_ID_WIDTH - 1 downto 0);
        m01_axi_rresp     : in std_logic_vector(1 downto 0);

        ---------------------------------------------------------------------------------------
        -- m02 : axi full HBM interface for filterbank output.
        m02_axi_awvalid : out std_logic;
        m02_axi_awready : in std_logic;
        m02_axi_awaddr : out std_logic_vector(M02_AXI_ADDR_WIDTH-1 downto 0);
        m02_axi_awid   : out std_logic_vector(M02_AXI_ID_WIDTH - 1 downto 0);
        m02_axi_awlen   : out std_logic_vector(7 downto 0);
        m02_axi_awsize   : out std_logic_vector(2 downto 0);
        m02_axi_awburst  : out std_logic_vector(1 downto 0);
        m02_axi_awlock   : out std_logic_vector(1 downto 0);
        m02_axi_awcache  : out std_logic_vector(3 downto 0);
        m02_axi_awprot   : out std_logic_vector(2 downto 0);
        m02_axi_awqos    : out std_logic_vector(3 downto 0);
        m02_axi_awregion : out std_logic_vector(3 downto 0);
    
        m02_axi_wvalid    : out std_logic;
        m02_axi_wready    : in std_logic;
        m02_axi_wdata     : out std_logic_vector(M02_AXI_DATA_WIDTH-1 downto 0);
        m02_axi_wstrb     : out std_logic_vector(M02_AXI_DATA_WIDTH/8-1 downto 0);
        m02_axi_wlast     : out std_logic;
        m02_axi_bvalid    : in std_logic;
        m02_axi_bready    : out std_logic;
        m02_axi_bresp     : in std_logic_vector(1 downto 0);
        m02_axi_bid       : in std_logic_vector(M02_AXI_ID_WIDTH - 1 downto 0);
        m02_axi_arvalid   : out std_logic;
        m02_axi_arready   : in std_logic;
        m02_axi_araddr    : out std_logic_vector(M02_AXI_ADDR_WIDTH-1 downto 0);
        m02_axi_arid      : out std_logic_vector(M02_AXI_ID_WIDTH-1 downto 0);
        m02_axi_arlen     : out std_logic_vector(7 downto 0);
        m02_axi_arsize    : out std_logic_vector(2 downto 0);
        m02_axi_arburst   : out std_logic_vector(1 downto 0);
        m02_axi_arlock    : out std_logic_vector(1 downto 0);
        m02_axi_arcache   : out std_logic_vector(3 downto 0);
        m02_axi_arprot    : out std_logic_Vector(2 downto 0);
        m02_axi_arqos     : out std_logic_vector(3 downto 0);
        m02_axi_arregion  : out std_logic_vector(3 downto 0);
        m02_axi_rvalid    : in std_logic;
        m02_axi_rready    : out std_logic;
        m02_axi_rdata     : in std_logic_vector(M02_AXI_DATA_WIDTH-1 downto 0);
        m02_axi_rlast     : in std_logic;
        m02_axi_rid       : in std_logic_vector(M02_AXI_ID_WIDTH - 1 downto 0);
        m02_axi_rresp     : in std_logic_vector(1 downto 0);        
        -------------------------------------------------------------------------------------
        -- m03 : Visibilities
        m03_axi_awvalid : out std_logic;
        m03_axi_awready : in std_logic;
        m03_axi_awaddr : out std_logic_vector(M03_AXI_ADDR_WIDTH-1 downto 0);
        m03_axi_awid   : out std_logic_vector(M03_AXI_ID_WIDTH - 1 downto 0);
        m03_axi_awlen   : out std_logic_vector(7 downto 0);
        m03_axi_awsize   : out std_logic_vector(2 downto 0);
        m03_axi_awburst  : out std_logic_vector(1 downto 0);
        m03_axi_awlock   : out std_logic_vector(1 downto 0);
        m03_axi_awcache  : out std_logic_vector(3 downto 0);
        m03_axi_awprot   : out std_logic_vector(2 downto 0);
        m03_axi_awqos    : out std_logic_vector(3 downto 0);
        m03_axi_awregion : out std_logic_vector(3 downto 0);
    
        m03_axi_wvalid    : out std_logic;
        m03_axi_wready    : in std_logic;
        m03_axi_wdata     : out std_logic_vector(M03_AXI_DATA_WIDTH-1 downto 0);
        m03_axi_wstrb     : out std_logic_vector(M03_AXI_DATA_WIDTH/8-1 downto 0);
        m03_axi_wlast     : out std_logic;
        m03_axi_bvalid    : in std_logic;
        m03_axi_bready    : out std_logic;
        m03_axi_bresp     : in std_logic_vector(1 downto 0);
        m03_axi_bid       : in std_logic_vector(M03_AXI_ID_WIDTH - 1 downto 0);
        m03_axi_arvalid   : out std_logic;
        m03_axi_arready   : in std_logic;
        m03_axi_araddr    : out std_logic_vector(M03_AXI_ADDR_WIDTH-1 downto 0);
        m03_axi_arid      : out std_logic_vector(M03_AXI_ID_WIDTH-1 downto 0);
        m03_axi_arlen     : out std_logic_vector(7 downto 0);
        m03_axi_arsize    : out std_logic_vector(2 downto 0);
        m03_axi_arburst   : out std_logic_vector(1 downto 0);
        m03_axi_arlock    : out std_logic_vector(1 downto 0);
        m03_axi_arcache   : out std_logic_vector(3 downto 0);
        m03_axi_arprot    : out std_logic_Vector(2 downto 0);
        m03_axi_arqos     : out std_logic_vector(3 downto 0);
        m03_axi_arregion  : out std_logic_vector(3 downto 0);
        m03_axi_rvalid    : in std_logic;
        m03_axi_rready    : out std_logic;
        m03_axi_rdata     : in std_logic_vector(M03_AXI_DATA_WIDTH-1 downto 0);
        m03_axi_rlast     : in std_logic;
        m03_axi_rid       : in std_logic_vector(M03_AXI_ID_WIDTH - 1 downto 0);
        m03_axi_rresp     : in std_logic_vector(1 downto 0);       

        -- GT pins
        --- clk_freerun is a 100MHz free running clock.        
        clk_freerun    : in std_logic; 
        gt_rxp_in      : in std_logic_vector(3 downto 0);
        gt_rxn_in      : in std_logic_vector(3 downto 0);
        gt_txp_out     : out std_logic_vector(3 downto 0);
        gt_txn_out     : out std_logic_vector(3 downto 0);
        gt_refclk_p    : in std_logic;
        gt_refclk_n    : in std_logic
    );
END correlator_core;

-------------------------------------------------------------------------------
ARCHITECTURE structure OF correlator_core IS

    -- 300MHz in, 100 MHz and 450 MHz out.
    component clk_gen100MHz
    port (
        clk100_out : out std_logic;
        clk450_out : out std_logic;       
        clk_in1    : in  std_logic);
    end component;

    component clk_gen400MHz
    port (
        clk400_out : out std_logic;
        clk_in1    : in  std_logic);
    end component;
    
    COMPONENT ila_0
    PORT (
   	    clk : IN STD_LOGIC;
   	    probe0 : IN STD_LOGIC_VECTOR(191 DOWNTO 0));
    END COMPONENT;

    COMPONENT ila_1
    PORT (
        clk : IN STD_LOGIC;
        probe0 : IN STD_LOGIC_VECTOR(575 DOWNTO 0)
        );
    END COMPONENT;

    
    
    signal ap_rst : std_logic;
    signal ap_idle, idle_int : std_logic;
    signal mc_master_mosi : t_axi4_full_mosi;
    signal mc_master_miso : t_axi4_full_miso;
    
    signal LFAA_FB_CT_mosi : t_axi4_full_mosi;  -- AXI bus to shared memory, used for corner turn between the LFAA ingest and filterbanks.
    signal LFAA_FB_CT_miso : t_axi4_full_miso;
    
    signal FB_BF_CT_mosi : t_axi4_full_mosi; -- AXI bus to shared memory, used for the corner turn between the filterbanks and the beamformer.
    signal FB_BF_CT_miso : t_axi4_full_miso;    
    
    signal mc_lite_miso   : t_axi4_lite_miso_arr(0 TO c_nof_lite_slaves-1);
    signal mc_lite_mosi   : t_axi4_lite_mosi_arr(0 TO c_nof_lite_slaves-1);
    signal mc_full_miso   : t_axi4_full_miso_arr(0 TO c_nof_full_slaves-1);
    signal mc_full_mosi   : t_axi4_full_mosi_arr(0 TO c_nof_full_slaves-1);
    
    signal cdma_status : std_logic_vector(14 downto 0);
    
    signal ap_start, ap_done : std_logic;
    signal DMA_src_addr, DMA_dest_addr : std_logic_vector(31 downto 0);
    signal DMA_size : std_logic_vector(31 downto 0);
    signal DMASharedMemAddr : std_logic_vector(63 downto 0);
    
    signal system_fields_rw : t_system_rw;
    signal system_fields_ro : t_system_ro;
    signal uptime : std_logic_vector(31 downto 0) := x"00000000";

    signal eth100_rx_sosi : t_lbus_sosi;
    signal eth100_tx_sosi : t_lbus_sosi;
    signal eth100_tx_siso : t_lbus_siso;
    signal eth100_reset : std_logic := '0';
    signal dest_req : std_logic;
    signal eth100G_status_ap_clk : std_logic_vector(128 downto 0);
    signal eth100G_status_eth_clk : std_logic_vector(128 downto 0);
    signal eth100G_send, eth100G_rcv, eth100G_clk, eth100G_locked : std_logic;
    
    signal eth100G_rx_total_packets : std_logic_vector(31 downto 0);
    signal eth100G_rx_bad_fcs : std_logic_vector(31 downto 0);
    signal eth100G_rx_bad_code : std_logic_vector(31 downto 0);
    signal eth100G_tx_total_packets : std_logic_vector(31 downto 0);
    signal eth100G_rx_reset : std_logic;
    signal eth100G_tx_reset : std_logic;
    signal ap_clk_count : std_logic_vector(31 downto 0) := (others => '0');
    
    signal freerunCount : std_logic_vector(31 downto 0) := x"00000000";
    signal freerunSecCount : std_logic_vector(31 downto 0) := x"00000000";

    signal GTY_startup_rst, eth100_reset_final : std_logic := '0';
    signal clk100 : std_logic;
    signal clk400 : std_logic;
    signal clk450 : std_logic;
    signal clk_gt_freerun_use : std_logic;
    
    signal eth100G_uptime : std_logic_vector(31 downto 0) := (others => '0');
    signal eth100G_seconds : std_logic_vector(31 downto 0) := (others => '0');
    
    signal araddr64bit, awaddr64bit : std_logic_vector(63 downto 0);
    signal m01_shared : std_logic_vector(63 downto 0);
    signal m02_shared : std_logic_vector(63 downto 0);
    signal m03_shared : std_logic_vector(63 downto 0);
    
    signal fec_enable_322m          : std_logic;
    signal fec_enable_100m          : std_logic;
    signal fec_enable_cache         : std_logic;
    
    signal fec_enable_reset_count   : integer := 0;
    signal fec_enable_reset         : std_logic := '0';
    
    
    signal m01_axi_awreadyi  : std_logic;
    signal m01_axi_awidi     : std_logic_vector(M01_AXI_ID_WIDTH - 1 downto 0);
    signal m01_axi_awsizei   : std_logic_vector(2 downto 0);
    signal m01_axi_awbursti  : std_logic_vector(1 downto 0);
    signal m01_axi_wreadyi   : std_logic;
    signal m01_axi_wstrbi    : std_logic_vector(M01_AXI_DATA_WIDTH/8-1 downto 0);
    signal m01_axi_breadyi   : std_logic;
    signal m01_axi_arreadyi  : std_logic;
    signal m01_axi_aridi     : std_logic_vector(M01_AXI_ID_WIDTH-1 downto 0);
    signal m01_axi_arsizei   : std_logic_vector(2 downto 0);
    signal m01_axi_arbursti  : std_logic_vector(1 downto 0);
    signal m01_axi_rreadyi   : std_logic;

    signal m02_axi_awreadyi  : std_logic;
    signal m02_axi_awidi     : std_logic_vector(M02_AXI_ID_WIDTH - 1 downto 0);
    signal m02_axi_awsizei   : std_logic_vector(2 downto 0);
    signal m02_axi_awbursti  : std_logic_vector(1 downto 0);
    signal m02_axi_wreadyi   : std_logic;
    signal m02_axi_wstrbi    : std_logic_vector(M02_AXI_DATA_WIDTH/8-1 downto 0);
    signal m02_axi_breadyi   : std_logic;
    signal m02_axi_arreadyi  : std_logic;
    signal m02_axi_aridi     : std_logic_vector(M02_AXI_ID_WIDTH-1 downto 0);
    signal m02_axi_arsizei   : std_logic_vector(2 downto 0);
    signal m02_axi_arbursti  : std_logic_vector(1 downto 0);
    signal m02_axi_rreadyi   : std_logic;
    
    signal m03_axi_awreadyi  : std_logic;
    signal m03_axi_awidi     : std_logic_vector(M03_AXI_ID_WIDTH - 1 downto 0);
    signal m03_axi_awsizei   : std_logic_vector(2 downto 0);
    signal m03_axi_awbursti  : std_logic_vector(1 downto 0);
    signal m03_axi_wreadyi   : std_logic;
    signal m03_axi_wstrbi    : std_logic_vector(M03_AXI_DATA_WIDTH/8-1 downto 0);
    signal m03_axi_breadyi   : std_logic;
    signal m03_axi_arreadyi  : std_logic;
    signal m03_axi_aridi     : std_logic_vector(M03_AXI_ID_WIDTH-1 downto 0);
    signal m03_axi_arsizei   : std_logic_vector(2 downto 0);
    signal m03_axi_arbursti  : std_logic_vector(1 downto 0);
    signal m03_axi_rreadyi   : std_logic;
    
    signal m01_axi_r, m01_axi_w   : t_axi4_full_data;
    signal m01_axi_ar, m01_axi_aw : t_axi4_full_addr;
    signal m01_axi_b              : t_axi4_full_b;
    
    signal m02_axi_r, m02_axi_w   : t_axi4_full_data;
    signal m02_axi_ar, m02_axi_aw : t_axi4_full_addr;
    signal m02_axi_b              : t_axi4_full_b;    

    signal m03_axi_r, m03_axi_w   : t_axi4_full_data;
    signal m03_axi_ar, m03_axi_aw : t_axi4_full_addr;
    signal m03_axi_b              : t_axi4_full_b;    
    
    signal m01_axi_araddr256Mbytei, m01_axi_awaddr256Mbytei : std_logic_vector(7 downto 0);
    signal m02_axi_araddr256Mbytei, m02_axi_awaddr256Mbytei : std_logic_vector(7 downto 0);
    signal m03_axi_araddr256Mbytei, m03_axi_awaddr256Mbytei : std_logic_vector(7 downto 0);
    signal m01_axi_araddri, m01_axi_awaddri, m02_axi_araddri, m02_axi_awaddri, m03_axi_araddri, m03_axi_awaddri : std_logic_vector(63 downto 0);

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
    
    -- create_ip -name axi_register_slice -vendor xilinx.com -library ip -version 2.1 -module_name axi_reg_slice512_LLFFL
    -- set_property -dict [list CONFIG.ADDR_WIDTH {64} CONFIG.DATA_WIDTH {512} CONFIG.REG_W {1} CONFIG.Component_Name {axi_reg_slice512_LLFFL}] [get_ips axi_reg_slice512_LLFFL]
    COMPONENT axi_reg_slice512_LLFFL
    PORT (
        aclk : IN STD_LOGIC;
        aresetn : IN STD_LOGIC;
        s_axi_awaddr : IN STD_LOGIC_VECTOR(63 DOWNTO 0);
        s_axi_awlen : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        s_axi_awsize : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        s_axi_awburst : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_awvalid : IN STD_LOGIC;
        s_axi_awready : OUT STD_LOGIC;
        s_axi_wdata : IN STD_LOGIC_VECTOR(511 DOWNTO 0);
        s_axi_wstrb : IN STD_LOGIC_VECTOR(63 DOWNTO 0);
        s_axi_wlast : IN STD_LOGIC;
        s_axi_wvalid : IN STD_LOGIC;
        s_axi_wready : OUT STD_LOGIC;
        s_axi_bresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_bvalid : OUT STD_LOGIC;
        s_axi_bready : IN STD_LOGIC;
        s_axi_araddr : IN STD_LOGIC_VECTOR(63 DOWNTO 0);
        s_axi_arlen : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        s_axi_arsize : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        s_axi_arburst : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_arvalid : IN STD_LOGIC;
        s_axi_arready : OUT STD_LOGIC;
        s_axi_rdata : OUT STD_LOGIC_VECTOR(511 DOWNTO 0);
        s_axi_rresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_rlast : OUT STD_LOGIC;
        s_axi_rvalid : OUT STD_LOGIC;
        s_axi_rready : IN STD_LOGIC;
        m_axi_awaddr : OUT STD_LOGIC_VECTOR(63 DOWNTO 0);
        m_axi_awlen : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
        m_axi_awsize : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        m_axi_awburst : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_awvalid : OUT STD_LOGIC;
        m_axi_awready : IN STD_LOGIC;
        m_axi_wdata : OUT STD_LOGIC_VECTOR(511 DOWNTO 0);
        m_axi_wstrb : OUT STD_LOGIC_VECTOR(63 DOWNTO 0);
        m_axi_wlast : OUT STD_LOGIC;
        m_axi_wvalid : OUT STD_LOGIC;
        m_axi_wready : IN STD_LOGIC;
        m_axi_bresp : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_bvalid : IN STD_LOGIC;
        m_axi_bready : OUT STD_LOGIC;
        m_axi_araddr : OUT STD_LOGIC_VECTOR(63 DOWNTO 0);
        m_axi_arlen : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
        m_axi_arsize : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        m_axi_arburst : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_arvalid : OUT STD_LOGIC;
        m_axi_arready : IN STD_LOGIC;
        m_axi_rdata : IN STD_LOGIC_VECTOR(511 DOWNTO 0);
        m_axi_rresp : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_rlast : IN STD_LOGIC;
        m_axi_rvalid : IN STD_LOGIC;
        m_axi_rready : OUT STD_LOGIC);
    END COMPONENT;
    
begin
    
    ---------------------------------------------------------------------------
    -- CLOCKING & RESETS  --
    ---------------------------------------------------------------------------

    u_get100 : clk_gen100MHz
    port map ( 
        clk100_out => clk100,  -- 100 MHz 
        clk450_out => clk450,  -- 450 MHz clock, used for some signal processing.
        clk_in1 => clk_freerun  -- 300 MHz in
    );
    
    clk_gt_freerun_use <= clk_freerun; -- or use clk_gt_freerun, if we can convince vitis to connect clk_gt_freerun to anything... 
    
    u_get400 : clk_gen400MHz
    port map (
        clk400_out => clk400, -- 
        clk_in1    => clk_freerun  -- 300MHz clock in
    );
    
    ---------------------------------------------------------------------------
    -- AXI-lite control interface
    -- Complies with requirements for a vitis accelerator
    
    u_krnl_ctrl: entity correlator_lib.krnl_control_axi
    generic map(
        C_S_AXI_ADDR_WIDTH => C_S_AXI_CONTROL_ADDR_WIDTH,
        C_S_AXI_DATA_WIDTH => C_S_AXI_CONTROL_DATA_WIDTH
    ) PORT MAP (
        -- axi4 lite slave signals
        ACLK => ap_clk,   -- input
        ARESET => ap_rst, -- input  wire
        --ACLK_EN => '1',   -- input  wire
        AWADDR => s_axi_control_awaddr,   -- input  wire [C_S_AXI_ADDR_WIDTH-1:0] 
        AWVALID => s_axi_control_awvalid, -- input  wire                          
        AWREADY => s_axi_control_awready, -- output wire                          
        WDATA   => s_axi_control_wdata,   -- input  wire [C_S_AXI_DATA_WIDTH-1:0] 
        WSTRB   => s_axi_control_wstrb,   -- input  wire [C_S_AXI_DATA_WIDTH/8-1:0] 
        WVALID  => s_axi_control_wvalid,  -- input  wire
        WREADY  => s_axi_control_wready,  -- output wire
        BRESP   => s_axi_control_bresp,   -- output wire [1:0]
        BVALID  => s_axi_control_bvalid,  -- output wire 
        BREADY  => s_axi_control_bready,  -- input  wire 
        ARADDR  => s_axi_control_araddr,  -- input  wire [C_S_AXI_ADDR_WIDTH-1:0]
        ARVALID => s_axi_control_arvalid, -- input  wire
        ARREADY => s_axi_control_arready, -- output wire 
        RDATA   => s_axi_control_rdata,   -- output wire [C_S_AXI_DATA_WIDTH-1:0]
        RRESP   => s_axi_control_rresp,   -- output wire [1:0]
        RVALID  => s_axi_control_rvalid,  -- output wire 
        RREADY  => s_axi_control_rready,  -- input  wire 
        interrupt => open,                -- output wire 
        -- // user signals
        ap_start => ap_start, -- output wire; bit 0 of register 0, indicates kernel should start processing
        ap_done  => ap_done,  -- input  wire; bit 1 of register 0, indicates processing is complete. This is registered internally. It should be pulsed high when processing is done. 
        ap_ready => ap_done,  -- input  wire; bit 3 of register 0. Undocumented in UG1393; multiple use cases described in vitis documentation, e.g. www.xilinx.com/html_docs/xilinx2020_1/vitis_doc/programmingvitishls.html
        ap_idle  => ap_idle,  -- input  wire; Idle should go low on ap_start, and stay low until the cycle after ap_done.
        dma_src  => DMA_src_addr,  -- output wire [31:0]
        dma_dest => DMA_dest_addr, -- output wire [31:0]
        dma_shared => DMASharedMemAddr, -- output wire [63:0]  -- Base Address of the shared memory block.
        dma_size => DMA_size,      -- output wire [31:0]
        m01_shared => m01_shared,  -- out(63:0)
        m02_shared => m02_shared,  -- out(63:0)
        m03_shared => m03_shared   -- out(63:0)
    );
    
    ap_idle <= '0' when (idle_int = '0' or (idle_int = '1' and ap_start = '1')) else '1';
    
    -- state machine and cdma block to copy registers on command from krnl_control
    -- This uses 32 bit addresses; the high 32 bits are 0 for ARGs slaves, and fixed to the high order bits from DMA_src_addr or DMA_dest_addr for connection to the output AXI bus to shared memory.
    u_cdma : entity correlator_lib.cdma_wrapper
    port map(
        i_clk      => ap_clk,
        i_rst      => ap_rst,
        i_srcAddr  => DMA_src_addr(31 downto 0),  -- in(31:0);
        i_destAddr => DMA_dest_addr(31 downto 0), -- in(31:0);
        i_size     => DMA_size,                   -- in(31:0);
        i_start    => ap_start,                   -- in std_logic;
        o_idle     => idle_int,                   -- out std_logic; -- High whenever not busy.
        o_done     => ap_done,                    -- out std_logic; -- Pulses high to indicate transaction is complete.
        o_status   => cdma_status,                -- out(14:0) -- cdma status register, read after a transaction is complete (register address 0x4)
        -- AXI master 
        o_AXI_mosi => mc_master_mosi, -- t_axi4_full_mosi;
        i_AXI_miso => mc_master_miso  -- t_axi4_full_miso
    );

	
    ---------------------------------------------------------------------------
    -- Bus Interconnect  --
    ---------------------------------------------------------------------------
    
    process(ap_clk)
    begin
        if rising_edge(ap_clk) then
            ap_rst <= not ap_rst_n;
        end if;
    end process;

    u_interconnect: ENTITY work.correlator_bus_top
    PORT MAP (
        CLK            => ap_clk,
        RST            => ap_rst, -- axi_rst,
        SLA_IN         => mc_master_mosi,
        SLA_OUT        => mc_master_miso,
        MSTR_IN_LITE   => mc_lite_miso,
        MSTR_OUT_LITE  => mc_lite_mosi,
        MSTR_IN_FULL   => mc_full_miso,
        MSTR_OUT_FULL  => mc_full_mosi
    );
    
    -- Map the connection to shared memory for register reads and writes.
    m00_axi_awvalid <= mc_full_mosi(c_vitis_shared_full_index).awvalid; -- out std_logic;
    
    awaddr64bit(16 downto 0) <= mc_full_mosi(c_vitis_shared_full_index).awaddr(16 downto 0);
    awaddr64bit(63 downto 17) <= (others => '0');
    m00_axi_awaddr  <= std_logic_vector(unsigned(DMASharedMemAddr) + unsigned(awaddr64bit)); 
    
    m00_axi_awid    <= mc_full_mosi(c_vitis_shared_full_index).awid(C_M_AXI_ID_WIDTH - 1 downto 0); -- out std_logic_vector(C_M_AXI_ID_WIDTH - 1 downto 0);
    m00_axi_awlen   <= mc_full_mosi(c_vitis_shared_full_index).awlen(7 downto 0); -- out std_logic_vector(7 downto 0);
    m00_axi_awsize  <= mc_full_mosi(c_vitis_shared_full_index).awsize(2 downto 0); -- out std_logic_vector(2 downto 0);
    m00_axi_awburst <= mc_full_mosi(c_vitis_shared_full_index).awburst(1 downto 0); -- out std_logic_vector(1 downto 0);
    m00_axi_awlock  <= "00"; -- mc_full_mosi(c_vitis_shared_full_index).awlock(1 downto 0);  -- out std_logic_vector(1 downto 0);
    m00_axi_awcache <= mc_full_mosi(c_vitis_shared_full_index).awcache(3 downto 0); -- out std_logic_vector(3 downto 0);
    m00_axi_awprot  <= mc_full_mosi(c_vitis_shared_full_index).awprot(2 downto 0);  -- out std_logic_vector(2 downto 0);
    m00_axi_awqos   <= mc_full_mosi(c_vitis_shared_full_index).awqos(3 downto 0);   -- out std_logic_vector(3 downto 0);
    m00_axi_awregion <= mc_full_mosi(c_vitis_shared_full_index).awregion(3 downto 0); -- out std_logic_vector(3 downto 0);
    mc_full_miso(c_vitis_shared_full_index).awready <= m00_axi_awready; --in std_logic;
    
    m00_axi_wvalid <= mc_full_mosi(c_vitis_shared_full_index).wvalid; -- out std_logic;
    mc_full_miso(c_vitis_shared_full_index).wready <= m00_axi_wready; -- in std_logic;
    m00_axi_wdata <= mc_full_mosi(c_vitis_shared_full_index).wdata(C_M_AXI_DATA_WIDTH-1 downto 0);   -- out std_logic_vector(C_M_AXI_DATA_WIDTH-1 downto 0);
    m00_axi_wstrb <= mc_full_mosi(c_vitis_shared_full_index).wstrb(C_M_AXI_DATA_WIDTH/8-1 downto 0); -- out std_logic_vector(C_M_AXI_DATA_WIDTH/8-1 downto 0);
    m00_axi_wlast <= mc_full_mosi(c_vitis_shared_full_index).wlast; -- out std_logic;
    
    mc_full_miso(c_vitis_shared_full_index).bvalid <= m00_axi_bvalid; -- in std_logic;
    m00_axi_bready <= mc_full_mosi(c_vitis_shared_full_index).bready; -- out std_logic;
    mc_full_miso(c_vitis_shared_full_index).bresp(1 downto 0) <= m00_axi_bresp; -- in std_logic_vector(1 downto 0);
    mc_full_miso(c_vitis_shared_full_index).bid(C_M_AXI_ID_WIDTH - 1 downto 0) <= m00_axi_bid; -- in std_logic_vector(C_M_AXI_ID_WIDTH - 1 downto 0);
    
    m00_axi_arvalid <= mc_full_mosi(c_vitis_shared_full_index).arvalid; -- out std_logic;
    mc_full_miso(c_vitis_shared_full_index).arready <= m00_axi_arready; -- in std_logic;
    
    
    araddr64bit(16 downto 0) <= mc_full_mosi(c_vitis_shared_full_index).araddr(16 downto 0);
    araddr64bit(63 downto 17) <= (others => '0');
    m00_axi_araddr <= std_logic_vector(unsigned(DMASharedMemAddr) + unsigned(araddr64bit));
    m00_axi_arid <= mc_full_mosi(c_vitis_shared_full_index).arid(C_M_AXI_ID_WIDTH-1 downto 0); -- out std_logic_vector(C_M_AXI_ID_WIDTH-1 downto 0);
    m00_axi_arlen <= mc_full_mosi(c_vitis_shared_full_index).arlen(7 downto 0); -- out std_logic_vector(7 downto 0);
    m00_axi_arsize <= mc_full_mosi(c_vitis_shared_full_index).arsize(2 downto 0); -- out std_logic_vector(2 downto 0);
    m00_axi_arburst <= mc_full_mosi(c_vitis_shared_full_index).arburst(1 downto 0); -- out std_logic_vector(1 downto 0);
    m00_axi_arlock <= "00"; -- out std_logic_vector(1 downto 0);
    m00_axi_arcache <= mc_full_mosi(c_vitis_shared_full_index).arcache(3 downto 0); -- out std_logic_vector(3 downto 0);
    m00_axi_arprot <= mc_full_mosi(c_vitis_shared_full_index).arprot(2 downto 0); -- out std_logic_Vector(2 downto 0);
    m00_axi_arqos <= mc_full_mosi(c_vitis_shared_full_index).arqos(3 downto 0);   -- out std_logic_vector(3 downto 0);
    m00_axi_arregion <= mc_full_mosi(c_vitis_shared_full_index).arregion(3 downto 0); -- out std_logic_vector(3 downto 0);
    
    mc_full_miso(c_vitis_shared_full_index).rvalid <= m00_axi_rvalid; -- in std_logic;
    m00_axi_rready <= mc_full_mosi(c_vitis_shared_full_index).rready; -- out std_logic;
    mc_full_miso(c_vitis_shared_full_index).rdata(C_M_AXI_DATA_WIDTH-1 downto 0) <= m00_axi_rdata; -- in std_logic_vector(C_M_AXI_DATA_WIDTH-1 downto 0);
    mc_full_miso(c_vitis_shared_full_index).rlast <= m00_axi_rlast; -- in std_logic;
    mc_full_miso(c_vitis_shared_full_index).rid(C_M_AXI_ID_WIDTH - 1 downto 0) <= m00_axi_rid; -- in std_logic_vector(C_M_AXI_ID_WIDTH - 1 downto 0);
    mc_full_miso(c_vitis_shared_full_index).rresp(1 downto 0) <= m00_axi_rresp; -- in std_logic_vector(1 downto 0)    
    
    
    ---------------------------------------------------------------------------
    -- TOP Level Registers  --
    ---------------------------------------------------------------------------

    fpga_regs: ENTITY correlator_lib.correlator_system_reg
    GENERIC MAP (
        g_technology      => c_tech_alveo)
    PORT MAP (
        mm_clk            => ap_clk,
        mm_rst            => ap_rst,
        sla_in            => mc_lite_mosi(c_system_lite_index),
        sla_out           => mc_lite_miso(c_system_lite_index),
        system_fields_rw  => system_fields_rw,
        system_fields_ro  => system_fields_ro);
    
    -- Build version.
    -- On the gemini cards, this was the build date accessed via the USR_ACCESSE2 primitive.
    -- However this is not supported in a vitis kernel since it cannot be placed in the dynamic region.
    
    system_fields_ro.firmware_major_version	<= g_FIRMWARE_MAJOR_VERSION;
    system_fields_ro.firmware_minor_version	<= g_FIRMWARE_MINOR_VERSION;
    system_fields_ro.firmware_patch_version	<= g_FIRMWARE_PATCH_VERSION;
    system_fields_ro.firmware_label			<= g_FIRMWARE_LABEL;
    system_fields_ro.firmware_personality	<= g_FIRMWARE_PERSONALITY;
    system_fields_ro.build_date             <= g_FIRMWARE_BUILD_DATE;
    
   
    -- Uptime counter
    process(ap_clk)
    begin
        if rising_edge(ap_clk) then
            -- Assume 300 MHz for ap_clk, 
            if (unsigned(ap_clk_count) < 299999999) then
                ap_clk_count <= std_logic_vector(unsigned(ap_clk_count) + 1);
            else
                ap_clk_count <= (others => '0');
                uptime <= std_logic_vector(unsigned(uptime) + 1);
            end if;
        end if;
    end process;
    system_fields_ro.time_uptime <= uptime;
    system_fields_ro.status_clocks_locked <= '1';
    
    -- clock domain conversions :
    --  From ap_clk to clk_gt_freerun_use
    --    t_system_rw.qsfpgty_resets -> eth100_reset
    -- xpm_cdc_single: Single-bit Synchronizer, Xilinx Parameterized Macro, version 2019.1
    xpm_cdc_single_inst : xpm_cdc_single
    generic map (
        DEST_SYNC_FF => 2,   -- DECIMAL; range: 2-10
        INIT_SYNC_FF => 0,   -- DECIMAL; 0=disable simulation init values, 1=enable simulation init values
        SIM_ASSERT_CHK => 0, -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        SRC_INPUT_REG => 1   -- DECIMAL; 0=do not register input, 1=register input
    )
    port map (
        dest_out => eth100_reset, -- 1-bit output: src_in synchronized to the destination clock domain. This output is registered.
        dest_clk => clk_gt_freerun_use, -- 1-bit input: Clock signal for the destination clock domain.
        src_clk => ap_clk,   -- 1-bit input: optional; required when SRC_INPUT_REG = 1
        src_in => system_fields_rw.qsfpgty_resets     -- 1-bit input: Input signal to be synchronized to dest_clk domain.
    );

    fec_enable_cdc_ethernet_322m_domain : xpm_cdc_single
    generic map (
        DEST_SYNC_FF => 2,   -- DECIMAL; range: 2-10
        INIT_SYNC_FF => 0,   -- DECIMAL; 0=disable simulation init values, 1=enable simulation init values
        SIM_ASSERT_CHK => 0, -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        SRC_INPUT_REG => 1   -- DECIMAL; 0=do not register input, 1=register input
    )
    port map (
        dest_out => fec_enable_322m, -- 1-bit output: src_in synchronized to the destination clock domain. This output is registered.
        dest_clk => eth100G_clk, -- 1-bit input: Clock signal for the destination clock domain.
        src_clk => ap_clk,   -- 1-bit input: optional; required when SRC_INPUT_REG = 1
        src_in => system_fields_rw.eth100g_fec_enable     -- 1-bit input: Input signal to be synchronized to dest_clk domain.
    );
    
    fec_enable_cdc_gt_input_100m_domain : xpm_cdc_single
    generic map (
        DEST_SYNC_FF => 2,   -- DECIMAL; range: 2-10
        INIT_SYNC_FF => 0,   -- DECIMAL; 0=disable simulation init values, 1=enable simulation init values
        SIM_ASSERT_CHK => 0, -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        SRC_INPUT_REG => 1   -- DECIMAL; 0=do not register input, 1=register input
    )
    port map (
        dest_out => fec_enable_100m, -- 1-bit output: src_in synchronized to the destination clock domain. This output is registered.
        dest_clk => clk_gt_freerun_use, -- 1-bit input: Clock signal for the destination clock domain.
        src_clk => ap_clk,   -- 1-bit input: optional; required when SRC_INPUT_REG = 1
        src_in => system_fields_rw.eth100g_fec_enable     -- 1-bit input: Input signal to be synchronized to dest_clk domain.
    );
    
    --  From eth100G_clk -> ap_clk
    --    eth100G_locked, eth100G_rx_total_packets, eth100G_rx_bad_fcs, eth100G_rx_bad_code, eth100G_tx_total_packets
    xpm_cdc_handshake_inst : xpm_cdc_handshake
    generic map (
        DEST_EXT_HSK => 0,   -- DECIMAL; 0=internal handshake, 1=external handshake
        DEST_SYNC_FF => 2,   -- DECIMAL; range: 2-10
        INIT_SYNC_FF => 0,   -- DECIMAL; 0=disable simulation init values, 1=enable simulation init values
        SIM_ASSERT_CHK => 0, -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        SRC_SYNC_FF => 2,    -- DECIMAL; range: 2-10
        WIDTH => 129         -- DECIMAL; range: 1-1024
    )
    port map (
        dest_out => eth100G_status_ap_clk, -- WIDTH-bit output: Input bus (src_in) synchronized to destination clock domain. This output is registered.
        dest_req => dest_req, -- 1-bit output: '1' indicates that new dest_out data is valid, will pulse high if DEST_EXT_HSK = 0 
        src_rcv => eth100G_rcv,   -- 1-bit output: Acknowledgement from destination logic that src_in has been received. This signal will be deasserted once destination handshake has fully completed
        dest_ack => '1', -- 1-bit input: optional; required when DEST_EXT_HSK = 1
        dest_clk => ap_clk,     -- 1-bit input: Destination clock.
        src_clk  => eth100G_clk, -- 1-bit input: Source clock.
        src_in => eth100G_status_eth_clk,     -- WIDTH-bit input: Input bus that will be synchronized to the destination clock domain.
        src_send => eth100G_send  -- 1-bit input: Assertion of this signal allows the src_in bus to be synchronized to the destination clock domain. 
    );

    process(ap_clk)
    begin
        if rising_edge(ap_clk) then
            if dest_req = '1' then
                system_fields_ro.eth100G_locked <= eth100G_status_ap_clk(128);
                system_fields_ro.eth100G_rx_total_packets <= eth100G_status_ap_clk(127 downto 96);
                system_fields_ro.eth100G_rx_bad_fcs <= eth100G_status_ap_clk(95 downto 64);  
                system_fields_ro.eth100G_rx_bad_code <= eth100G_status_ap_clk(63 downto 32);
                system_fields_ro.eth100G_tx_total_packets <= eth100G_status_ap_clk(31 downto 0);
            end if;
        end if;
    end process;
    
    process(eth100G_clk)
    begin
        if rising_edge(eth100G_clk) then
            eth100G_status_eth_clk(128) <= eth100G_locked;
            eth100G_status_eth_clk(127 downto 96) <= eth100G_rx_total_packets;
            eth100G_status_eth_clk(95 downto 64) <= eth100G_rx_bad_fcs;
            eth100G_status_eth_clk(63 downto 32) <= eth100G_rx_bad_code;
            eth100G_status_eth_clk(31 downto 0) <= eth100G_tx_total_packets;
            if eth100G_rcv = '0' then
                eth100G_send <= '1'; -- just send across the clock domain whenever the clock crossing module is ready.
            else
                eth100G_send <= '0';
            end if;
        end if;
    end process;
    
    -------------------------------------------------------------------------------------------
    -- 100G ethernet
    -------------------------------------------------------------------------------------------
    
    u100SimulationGen : if g_SIMULATION generate
        gt_txp_out <= "0000";
        gt_txn_out <= "0000";
        eth100G_clk <= i_clk_100GE;
        eth100G_locked <= '1';
        eth100G_rx_reset <= '0';
        eth100G_tx_reset <= '0';
        eth100G_rx_total_packets <= x"cafe0000";
        eth100G_rx_bad_fcs <= x"cafe0001";
        eth100G_rx_bad_code <= x"cafe0002";
        eth100G_tx_total_packets <= x"cafe0003";
        
        -- Received data from 100GE
        eth100_rx_sosi <= i_eth100_rx_sosi;
        -- Data to be transmitted on 100GE
        eth100_tx_siso <= i_eth100_tx_siso;
        o_eth100_tx_sosi <= eth100_tx_sosi;
        
    end generate;
    
    u100Gen : if (not g_SIMULATION) generate
        u_100G : entity correlator_lib.mac_100g_wrapper
        Port map(
            gt_rxp_in   => gt_rxp_in, -- in(3:0);
            gt_rxn_in   => gt_rxn_in, -- in(3:0);
            gt_txp_out  => gt_txp_out, -- out(3:0);
            gt_txn_out  => gt_txn_out, -- out(3:0);
            gt_refclk_p => gt_refclk_p, -- IN STD_LOGIC;
            gt_refclk_n => gt_refclk_n, -- IN STD_LOGIC;
            sys_reset   => eth100_reset_final,   -- IN STD_LOGIC;   -- sys_reset, clocked by dclk.
            i_dclk_100  => clk_gt_freerun_use, --  IN STD_LOGIC;   -- stable clock for the core; The frequency is specified in the wizard. See comments above about the actual frequency supplied by the Alveo platform.        
            -- loopback for the GTYs
            -- "000" = normal operation, "001" = near-end PCS loopback, "010" = near-end PMA loopback
            -- "100" = far-end PMA loopback, "110" = far-end PCS loopback.
            -- See GTY user guid (Xilinx doc UG578) for details.
            loopback  => "000", -- in(2:0);  
            tx_enable => '1',   -- in std_logic;
            rx_enable => '1',   -- in std_logic;
            i_fec_enable    => fec_enable_322m,
            -- All remaining signals are clocked on tx_clk_out
            tx_clk_out => eth100G_clk, -- out std_logic; This is the clock used by the data in and out of the core. 322 MHz.
            
            -- User Interface Signals
            rx_locked  => eth100G_locked, -- out std_logic; 
    
            user_rx_reset => eth100G_rx_reset, -- out std_logic;
            user_tx_reset => eth100G_tx_reset, -- out std_logic;
    
            -- Statistics Interface, on eth100_clk
            rx_total_packets => eth100G_rx_total_packets, -- out(31:0);
            rx_bad_fcs       => eth100G_rx_bad_fcs,       -- out(31:0);
            rx_bad_code      => eth100G_rx_bad_code,      -- out(31:0);
            tx_total_packets => eth100G_tx_total_packets, -- out(31:0);
            
            -- Received data from optics
            data_rx_sosi => eth100_rx_sosi, -- out t_lbus_sosi;
    
            -- Data to be transmitted to optics
            data_tx_sosi => eth100_tx_sosi, -- IN t_lbus_sosi;
            data_tx_siso => eth100_tx_siso,  -- OUT t_lbus_siso
            
            -- ARGs Interface
            i_MACE_clk  => ap_clk, -- in std_logic;
            i_MACE_rst  => ap_rst, -- in std_logic;
            i_DRP_Lite_axi_mosi => mc_lite_mosi(c_drp_lite_index),
            o_DRP_Lite_axi_miso => mc_lite_miso(c_drp_lite_index)
        );
    end generate;

    process(clk_gt_freerun_use)
    begin
        if rising_edge(clk_gt_freerun_use) then
            if (unsigned(freerunCount) < 100000000) then
                freerunCount <= std_logic_vector(unsigned(freerunCount) + 1);
            else
                freerunCount <= (others => '0');
                freerunSecCount <= std_logic_vector(unsigned(freerunSecCount) + 1);
            end if;
            
            if (unsigned(freerunSecCount) < 2) then   -- document for the 100G core just says that reset needs to be asserted until the clocks are stable.
                GTY_startup_rst <= '1';
            else
                GTY_startup_rst <= '0';
            end if;
            
            eth100_reset_final <= eth100_reset or GTY_startup_rst or fec_enable_reset;
            
        end if;
    end process;
    
    load_new_fec_state_proc : process(clk_gt_freerun_use)
    begin
        if rising_edge(clk_gt_freerun_use) then
        
            fec_enable_cache <= fec_enable_100m;
            
            if fec_enable_cache /= fec_enable_100m then
                fec_enable_reset_count <= 0;
                fec_enable_reset <= '1';
            elsif fec_enable_reset_count < 100 then
                fec_enable_reset_count <= fec_enable_reset_count + 1;
            else
                fec_enable_reset <= '0';
            end if;
            
        end if;
    end process;
    
    
    process(eth100G_clk)
    begin
        if rising_edge(eth100G_clk) then
            if (unsigned(eth100G_uptime) < 322000000) then
                eth100G_uptime <= std_logic_vector(unsigned(eth100G_uptime) + 1);
            else
                eth100G_uptime <= (others => '0');
                eth100G_seconds <= std_logic_vector(unsigned(eth100G_seconds) + 1);
            end if;
            
        end if;
    end process;

    --------------------------------------------------------------------------
    --  Correlator Signal Processing
    
    dsp_topi : entity dsp_top_lib.DSP_top_correlator
    generic map (
        g_DEBUG_ILA             => g_DEBUG_ILA,
        g_LFAA_BLOCKS_PER_FRAME => g_LFAA_BLOCKS_PER_FRAME, -- nominal value is 128
        g_USE_META              => g_USE_META
    ) port map (
        -- Received data from 100GE
        i_data_rx_sosi      => eth100_rx_sosi, -- in t_lbus_sosi;
        -- Data to be transmitted on 100GE
        o_data_tx_sosi      => eth100_tx_sosi, -- out t_lbus_sosi;
        i_data_tx_siso      => eth100_tx_siso, -- in t_lbus_siso;
        i_clk_100GE         => eth100G_clk,      -- in std_logic;
        i_eth100G_locked    => eth100G_locked,
        -- Filterbank processing clock, 450 MHz
        i_clk450 => clk450,  -- in std_logic;
        i_clk400 => clk400,  -- in std_logic;
        -----------------------------------------------------------------------
        -- reset of the valid memory is in progress.
        o_validMemRstActive => o_validMemRstActive,
        -----------------------------------------------------------------------
        -- AXI slave interfaces for modules
        i_MACE_clk  => ap_clk, -- in std_logic;
        i_MACE_rst  => ap_rst, -- in std_logic;
        -- DSP top lite slave
        --i_dsptopLite_axi_mosi => mc_lite_mosi(c_dsp_top_lite_index), -- in t_axi4_lite_mosi;
        --o_dsptopLite_axi_miso => mc_lite_miso(c_dsp_top_lite_index), -- out t_axi4_lite_miso;
        -- LFAADecode, lite + full slave
        i_LFAALite_axi_mosi => mc_lite_mosi(c_LFAADecode100g_lite_index), -- in t_axi4_lite_mosi; 
        o_LFAALite_axi_miso => mc_lite_miso(c_LFAADecode100g_lite_index), -- out t_axi4_lite_miso;
        i_LFAAFull_axi_mosi => mc_full_mosi(c_lfaadecode100g_full_index), -- in  t_axi4_full_mosi;
        o_LFAAFull_axi_miso => mc_full_miso(c_lfaadecode100g_full_index), -- out t_axi4_full_miso;
        -- Timing control
        i_timing_axi_mosi => mc_lite_mosi(c_timingcontrola_lite_index), -- in t_axi4_lite_mosi;
        o_timing_axi_miso => mc_lite_miso(c_timingcontrola_lite_index), -- out t_axi4_lite_miso;
        -- Corner Turn between LFAA Ingest and the filterbanks.
        i_LFAA_CT_axi_mosi => mc_lite_mosi(c_CT_atomic_cor_in_lite_index), -- in  t_axi4_lite_mosi;
        o_LFAA_CT_axi_miso => mc_lite_miso(c_CT_atomic_cor_in_lite_index), -- out t_axi4_lite_miso;
        -- Filterbanks
        i_FB_axi_mosi => mc_lite_mosi(c_filterbanks_lite_index), -- in  t_axi4_lite_mosi;
        o_FB_axi_miso => mc_lite_miso(c_filterbanks_lite_index), -- out t_axi4_lite_miso;
        -- Corner turn between filterbanks and the correlator
        i_cor_CT_axi_mosi => mc_lite_mosi(c_ct_atomic_cor_out_lite_index), -- in  t_axi4_lite_mosi;
        o_cor_CT_axi_miso => mc_lite_miso(c_ct_atomic_cor_out_lite_index), -- out t_axi4_lite_miso;
        -- correlator
        i_cor_axi_mosi => mc_lite_mosi(c_config_lite_index), -- in  t_axi4_lite_mosi;
        o_cor_axi_miso => mc_lite_miso(c_config_lite_index), -- out t_axi4_lite_miso;
        
        -- PSR Packetiser interface
        i_PSR_packetiser_lite_axi_mosi  => mc_lite_mosi(c_packetiser_lite_index),
        o_PSR_packetiser_lite_axi_miso  => mc_lite_miso(c_packetiser_lite_index),
        i_PSR_packetiser_full_axi_mosi  => mc_full_mosi(c_packetiser_full_index), 
        o_PSR_packetiser_full_axi_miso  => mc_full_miso(c_packetiser_full_index), 
        -----------------------------------------------------------------------
        -- AXI interfaces to shared memory
        --  Shared memory block for the first corner turn (at the output of the LFAA ingest block)
        -- Corner Turn between LFAA ingest and the filterbanks
        -- AXI4 master interface for accessing HBM for the LFAA ingest corner turn : m01_axi
        -- aw bus - write addresses.
        o_m01_axi_aw      => m01_axi_aw,       -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m01_axi_awready => m01_axi_awreadyi, --                     in std_logic;
        o_m01_axi_w       => m01_axi_w,        -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_m01_axi_wready  => m01_axi_wreadyi,  --              in std_logic;
        i_m01_axi_b       => m01_axi_b,        -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        o_m01_axi_ar      => m01_axi_ar,       -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m01_axi_arready => m01_axi_arreadyi, --                    in std_logic;
        i_m01_axi_r       => m01_axi_r,        -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_m01_axi_rready  => m01_axi_rreadyi,  --              out std_logic;
        
        -- Buffer between filterbanks and correlator - could be up to 6 Gbytes.
        o_m02_axi_aw      => m02_axi_aw,       -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m02_axi_awready => m02_axi_awreadyi, --                     in std_logic;
        o_m02_axi_w       => m02_axi_w,        -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_m02_axi_wready  => m02_axi_wreadyi,  --              in std_logic;
        i_m02_axi_b       => m02_axi_b,        -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        o_m02_axi_ar      => m02_axi_ar,       -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m02_axi_arready => m02_axi_arreadyi, --                    in std_logic;
        i_m02_axi_r       => m02_axi_r,        -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_m02_axi_rready  => m02_axi_rreadyi,  --              out std_logic;
        
        -- Visibilities buffer
        -- aw, w, b, ar, and r buses.
        o_m03_axi_aw      => m03_axi_aw,       -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m03_axi_awready => m03_axi_awreadyi, --                     in std_logic;
        o_m03_axi_w       => m03_axi_w,        -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_m03_axi_wready  => m03_axi_wreadyi,  --              in std_logic;
        i_m03_axi_b       => m03_axi_b,        -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        o_m03_axi_ar      => m03_axi_ar,       -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m03_axi_arready => m03_axi_arreadyi, --                    in std_logic;
        i_m03_axi_r       => m03_axi_r,        -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_m03_axi_rready  => m03_axi_rreadyi   --              out std_logic;
    );
    
    
    -- Default outgoing signals for m01 bus
    m01_axi_araddr256Mbytei <= m01_axi_ar.addr(35 downto 28); -- 8 bit address of 256MByte pieces, within 64 Gbytes ((35:0) addresses 64 Gbytes)
    m01_axi_araddri(63 downto 36) <= m01_shared(63 downto 36);
    m01_axi_araddri(35 downto 28) <= std_logic_vector(unsigned(m01_shared(35 downto 28)) + unsigned(m01_axi_araddr256Mbytei));
    m01_axi_araddri(27 downto 0) <= m01_axi_ar.addr(27 downto 0);
    
    m01_axi_awaddr256Mbytei <= m01_axi_aw.addr(35 downto 28); -- 8 bit address of 256MByte pieces, within 64 Gbytes ((35:0) addresses 64 Gbytes)
    m01_axi_awaddri(63 downto 36) <= m01_shared(63 downto 36);
    m01_axi_awaddri(35 downto 28) <= std_logic_vector(unsigned(m01_shared(35 downto 28)) + unsigned(m01_axi_awaddr256Mbytei));
    m01_axi_awaddri(27 downto 0) <= m01_axi_aw.addr(27 downto 0);
    
    m01_axi_awidi(0) <= '0';   -- We only use a single ID -- out std_logic_vector(0 downto 0);
    m01_axi_awsizei  <= get_axi_size(M01_AXI_DATA_WIDTH);
    m01_axi_awbursti <= "01";   -- "01" indicates incrementing addresses for each beat in the burst.  -- out std_logic_vector(1 downto 0);
    m01_axi_breadyi  <= '1';  -- Always accept acknowledgement of write transactions. -- out std_logic;
    m01_axi_wstrbi  <= (others => '1');  -- We always write all bytes in the bus. --  out std_logic_vector(63 downto 0);
    m01_axi_aridi(0) <= '0';     -- ID are not used. -- out std_logic_vector(0 downto 0);
    m01_axi_arsizei  <= get_axi_size(M01_AXI_DATA_WIDTH);   -- 6 = 64 bytes per beat = 512 bit wide bus. -- out std_logic_vector(2 downto 0);
    m01_axi_arbursti <= "01";    -- "01" = incrementing address for each beat in the burst. -- out std_logic_vector(1 downto 0);
   
    -- these have no ports on the axi register slice
    m01_axi_arlock <= "00";
    m01_axi_awlock <= "00";
    m01_axi_awcache <= "0011";  -- out std_logic_vector(3 downto 0); bufferable transaction. Default in Vitis environment.
    m01_axi_awprot  <= "000";   -- Has no effect in Vitis environment. -- out std_logic_vector(2 downto 0);
    m01_axi_awqos   <= "0000";  -- Has no effect in vitis environment, -- out std_logic_vector(3 downto 0);
    m01_axi_awregion <= "0000"; -- Has no effect in Vitis environment. -- out std_logic_vector(3 downto 0);
    m01_axi_arcache <= "0011";  -- out std_logic_vector(3 downto 0); bufferable transaction. Default in Vitis environment.
    m01_axi_arprot  <= "000";   -- Has no effect in vitis environment; out std_logic_Vector(2 downto 0);
    m01_axi_arqos    <= "0000"; -- Has no effect in vitis environment; out std_logic_vector(3 downto 0);
    m01_axi_arregion <= "0000"; -- Has no effect in vitis environment; out std_logic_vector(3 downto 0);
    -- Ignored incoming signals for m01 bus:
    -- m01_axi_bid; Since we only use 1 ID, we can ignore this. -- in std_logic_vector(0 downto 0);
    -- m01_axi_rid  -- in std_logic_vector(0 downto 0);
    
    -- Default outgoing signals for the m02 bus
    m02_axi_araddr256Mbytei <= m02_axi_ar.addr(35 downto 28); -- 8 bit address of 256MByte pieces, within 64 Gbytes ((35:0) addresses 64 Gbytes)
    m02_axi_araddri(63 downto 36) <= m02_shared(63 downto 36);
    m02_axi_araddri(35 downto 28) <= std_logic_vector(unsigned(m02_shared(35 downto 28)) + unsigned(m02_axi_araddr256Mbytei));
    m02_axi_araddri(27 downto 0) <= m02_axi_ar.addr(27 downto 0);
    
    m02_axi_awaddr256Mbytei <= m02_axi_aw.addr(35 downto 28); -- 8 bit address of 256MByte pieces, within 64 Gbytes ((35:0) addresses 64 Gbytes)
    m02_axi_awaddri(63 downto 36) <= m02_shared(63 downto 36);
    m02_axi_awaddri(35 downto 28) <= std_logic_vector(unsigned(m02_shared(35 downto 28)) + unsigned(m02_axi_awaddr256Mbytei));
    m02_axi_awaddri(27 downto 0) <= m02_axi_aw.addr(27 downto 0);    
    
    m02_axi_awidi(0) <= '0';   -- We only use a single ID -- out std_logic_vector(0 downto 0);
    m02_axi_awsizei  <= get_axi_size(M02_AXI_DATA_WIDTH);  -- size of 5 indicates 32 bytes in each beat (i.e. 256 bit wide bus) -- out std_logic_vector(2 downto 0);
    m02_axi_awbursti <= "01";   -- "01" indicates incrementing addresses for each beat in the burst.  -- out std_logic_vector(1 downto 0);
    m02_axi_wstrbi  <= (others => '1');  -- We always write all bytes in the bus. --  out std_logic_vector(63 downto 0);
    m02_axi_aridi(0) <= '0';     -- ID are not used. -- out std_logic_vector(0 downto 0);
    m02_axi_arsizei  <= get_axi_size(M02_AXI_DATA_WIDTH);   -- 5 = 32 bytes per beat = 256 bit wide bus. -- out std_logic_vector(2 downto 0);
    m02_axi_arbursti <= "01";    -- "01" = incrementing address for each beat in the burst. -- out std_logic_vector(1 downto 0);
    
    m02_axi_awcache <= "0011";  -- out std_logic_vector(3 downto 0); bufferable transaction. Default in Vitis environment.
    m02_axi_awprot  <= "000";   -- Has no effect in Vitis environment. -- out std_logic_vector(2 downto 0);
    m02_axi_awqos   <= "0000";  -- Has no effect in vitis environment, -- out std_logic_vector(3 downto 0);
    m02_axi_awregion <= "0000"; -- Has no effect in Vitis environment. -- out std_logic_vector(3 downto 0);
    m02_axi_arlock <= "00";
    m02_axi_awlock <= "00";
    m02_axi_arcache <= "0011";  -- out std_logic_vector(3 downto 0); bufferable transaction. Default in Vitis environment.
    m02_axi_arprot  <= "000";   -- Has no effect in vitis environment; out std_logic_Vector(2 downto 0);
    m02_axi_arqos    <= "0000"; -- Has no effect in vitis environment; out std_logic_vector(3 downto 0);
    m02_axi_arregion <= "0000"; -- Has no effect in vitis environment; out std_logic_vector(3 downto 0);
    
    -- m03 HBM interface:
    m03_axi_araddr256Mbytei <= m03_axi_ar.addr(35 downto 28); -- 8 bit address of 256MByte pieces, within 64 Gbytes ((35:0) addresses 64 Gbytes)
    m03_axi_araddri(63 downto 36) <= m03_shared(63 downto 36);
    m03_axi_araddri(35 downto 28) <= std_logic_vector(unsigned(m03_shared(35 downto 28)) + unsigned(m03_axi_araddr256Mbytei));
    m03_axi_araddri(27 downto 0) <= m03_axi_ar.addr(27 downto 0);
    
    m03_axi_awaddr256Mbytei <= m03_axi_aw.addr(35 downto 28); -- 8 bit address of 256MByte pieces, within 64 Gbytes ((35:0) addresses 64 Gbytes)
    m03_axi_awaddri(63 downto 36) <= m03_shared(63 downto 36);
    m03_axi_awaddri(35 downto 28) <= std_logic_vector(unsigned(m03_shared(35 downto 28)) + unsigned(m03_axi_awaddr256Mbytei));
    m03_axi_awaddri(27 downto 0) <= m03_axi_aw.addr(27 downto 0);
    m03_axi_awidi(0) <= '0';   -- We only use a single ID -- out std_logic_vector(0 downto 0);
    m03_axi_awsizei  <= get_axi_size(M03_AXI_DATA_WIDTH);   -- size of 5 indicates 32 bytes in each beat (i.e. 256 bit wide bus) -- out std_logic_vector(2 downto 0);
    m03_axi_awbursti <= "01";   -- "01" indicates incrementing addresses for each beat in the burst.  -- out std_logic_vector(1 downto 0);
    m03_axi_wstrbi  <= (others => '1');  -- We always write all bytes in the bus. --  out std_logic_vector(63 downto 0);
    m03_axi_aridi(0) <= '0';     -- ID are not used. -- out std_logic_vector(0 downto 0);
    m03_axi_arsizei  <= get_axi_size(M03_AXI_DATA_WIDTH);    -- 5 = 32 bytes per beat = 256 bit wide bus. -- out std_logic_vector(2 downto 0);
    m03_axi_arbursti <= "01";    -- "01" = incrementing address for each beat in the burst. -- out std_logic_vector(1 downto 0);
    
    m03_axi_awcache <= "0011";  -- out std_logic_vector(3 downto 0); bufferable transaction. Default in Vitis environment.
    m03_axi_awprot  <= "000";   -- Has no effect in Vitis environment. -- out std_logic_vector(2 downto 0);
    m03_axi_awqos   <= "0000";  -- Has no effect in vitis environment, -- out std_logic_vector(3 downto 0);
    m03_axi_awregion <= "0000"; -- Has no effect in Vitis environment. -- out std_logic_vector(3 downto 0);
    m03_axi_arlock <= "00";
    m03_axi_awlock <= "00";
    m03_axi_arcache <= "0011";  -- out std_logic_vector(3 downto 0); bufferable transaction. Default in Vitis environment.
    m03_axi_arprot  <= "000";   -- Has no effect in vitis environment; out std_logic_Vector(2 downto 0);
    m03_axi_arqos    <= "0000"; -- Has no effect in vitis environment; out std_logic_vector(3 downto 0);
    m03_axi_arregion <= "0000"; -- Has no effect in vitis environment; out std_logic_vector(3 downto 0);
    
    
    -- Register slice for the m01 AXI interface
    m01_reg_slice : axi_reg_slice512_LLFFL
    port map (
        aclk    => ap_clk, --  IN STD_LOGIC;
        aresetn => ap_rst_n, --  IN STD_LOGIC;
        -- 
        s_axi_awaddr   => m01_axi_awaddri, -- IN STD_LOGIC_VECTOR(63 DOWNTO 0);
        s_axi_awlen    => m01_axi_aw.len,  -- IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        s_axi_awsize   => m01_axi_awsizei, -- IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        s_axi_awburst  => m01_axi_awbursti, -- IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_awvalid  => m01_axi_aw.valid,  -- IN STD_LOGIC;
        s_axi_awready  => m01_axi_awreadyi,  -- OUT STD_LOGIC;
        s_axi_wdata    => m01_axi_w.data,    -- IN STD_LOGIC_VECTOR(511 DOWNTO 0);
        s_axi_wstrb    => m01_axi_wstrbi,    -- IN STD_LOGIC_VECTOR(63 DOWNTO 0);
        s_axi_wlast    => m01_axi_w.last,    -- IN STD_LOGIC;
        s_axi_wvalid   => m01_axi_w.valid,   -- IN STD_LOGIC;
        s_axi_wready   => m01_axi_wreadyi,   -- OUT STD_LOGIC;
        s_axi_bresp    => m01_axi_b.resp,    --  OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_bvalid   => m01_axi_b.valid,   -- OUT STD_LOGIC;
        s_axi_bready   => m01_axi_breadyi,   -- IN STD_LOGIC;
        s_axi_araddr   => m01_axi_araddri,   -- IN STD_LOGIC_VECTOR(63 DOWNTO 0);
        s_axi_arlen    => m01_axi_ar.len,    -- IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        s_axi_arsize   => m01_axi_arsizei,   -- IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        s_axi_arburst  => m01_axi_arbursti,  -- IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_arvalid  => m01_axi_ar.valid,  -- IN STD_LOGIC;
        s_axi_arready  => m01_axi_arreadyi,  -- OUT STD_LOGIC;
        s_axi_rdata    => m01_axi_r.data,    -- OUT STD_LOGIC_VECTOR(511 DOWNTO 0);
        s_axi_rresp    => m01_axi_r.resp,    -- OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_rlast    => m01_axi_r.last,    -- OUT STD_LOGIC;
        s_axi_rvalid   => m01_axi_r.valid,   -- OUT STD_LOGIC;
        s_axi_rready   => m01_axi_rreadyi,   -- IN STD_LOGIC;
        --
        m_axi_awaddr   => m01_axi_awaddr, -- OUT STD_LOGIC_VECTOR(63 DOWNTO 0);
        m_axi_awlen    => m01_axi_awlen,  -- OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
        m_axi_awsize   => m01_axi_awsize, -- OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        m_axi_awburst  => m01_axi_awburst, -- OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_awvalid  => m01_axi_awvalid,  -- OUT STD_LOGIC;
        m_axi_awready  => m01_axi_awready,  -- IN STD_LOGIC;
        m_axi_wdata    => m01_axi_wdata,    -- OUT STD_LOGIC_VECTOR(511 DOWNTO 0);
        m_axi_wstrb    => m01_axi_wstrb,    -- OUT STD_LOGIC_VECTOR(63 DOWNTO 0);
        m_axi_wlast    => m01_axi_wlast,    -- OUT STD_LOGIC;
        m_axi_wvalid   => m01_axi_wvalid,   -- OUT STD_LOGIC;
        m_axi_wready   => m01_axi_wready,   -- IN STD_LOGIC;
        m_axi_bresp    => m01_axi_bresp,    -- IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_bvalid   => m01_axi_bvalid,   -- IN STD_LOGIC;
        m_axi_bready   => m01_axi_bready,   -- OUT STD_LOGIC;
        m_axi_araddr   => m01_axi_araddr,   -- OUT STD_LOGIC_VECTOR(63 DOWNTO 0);
        m_axi_arlen    => m01_axi_arlen,    -- OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
        m_axi_arsize   => m01_axi_arsize,   -- OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        m_axi_arburst  => m01_axi_arburst,  -- OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
       
        m_axi_arvalid  => m01_axi_arvalid,  -- OUT STD_LOGIC;
        m_axi_arready  => m01_axi_arready,  -- IN STD_LOGIC;
        m_axi_rdata    => m01_axi_rdata,    -- IN STD_LOGIC_VECTOR(511 DOWNTO 0);
        m_axi_rresp    => m01_axi_rresp,    -- IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_rlast    => m01_axi_rlast,    -- IN STD_LOGIC;
        m_axi_rvalid   => m01_axi_rvalid,   -- IN STD_LOGIC;
        m_axi_rready   => m01_axi_rready    --: OUT STD_LOGIC
    );

    -- Register slice for the m02 AXI interface
    m02_reg_slice : axi_reg_slice512_LLFFL
    port map (
        aclk    => ap_clk, --  IN STD_LOGIC;
        aresetn => ap_rst_n, --  IN STD_LOGIC;
        -- 
        s_axi_awaddr   => m02_axi_awaddri, -- IN STD_LOGIC_VECTOR(63 DOWNTO 0);
        s_axi_awlen    => m02_axi_aw.len,  -- IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        s_axi_awsize   => m02_axi_awsizei, -- IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        s_axi_awburst  => m02_axi_awbursti, -- IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_awvalid  => m02_axi_aw.valid,  -- IN STD_LOGIC;
        s_axi_awready  => m02_axi_awreadyi,  -- OUT STD_LOGIC;
        s_axi_wdata    => m02_axi_w.data,    -- IN STD_LOGIC_VECTOR(255 DOWNTO 0);
        s_axi_wstrb    => m02_axi_wstrbi,    -- IN STD_LOGIC_VECTOR(63 DOWNTO 0);
        s_axi_wlast    => m02_axi_w.last,    -- IN STD_LOGIC;
        s_axi_wvalid   => m02_axi_w.valid,   -- IN STD_LOGIC;
        s_axi_wready   => m02_axi_wreadyi,   -- OUT STD_LOGIC;
        s_axi_bresp    => m02_axi_b.resp,    --  OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_bvalid   => m02_axi_b.valid,   -- OUT STD_LOGIC;
        s_axi_bready   => m02_axi_breadyi,   -- IN STD_LOGIC;
        s_axi_araddr   => m02_axi_araddri,   -- IN STD_LOGIC_VECTOR(63 DOWNTO 0);
        s_axi_arlen    => m02_axi_ar.len,    -- IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        s_axi_arsize   => m02_axi_arsizei,   -- IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        s_axi_arburst  => m02_axi_arbursti,  -- IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_arvalid  => m02_axi_ar.valid,  -- IN STD_LOGIC;
        s_axi_arready  => m02_axi_arreadyi,  -- OUT STD_LOGIC;
        s_axi_rdata    => m02_axi_r.data,    -- OUT STD_LOGIC_VECTOR(255 DOWNTO 0);
        s_axi_rresp    => m02_axi_r.resp,    -- OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_rlast    => m02_axi_r.last,    -- OUT STD_LOGIC;
        s_axi_rvalid   => m02_axi_r.valid,   -- OUT STD_LOGIC;
        s_axi_rready   => m02_axi_rreadyi,   -- IN STD_LOGIC;
        --
        m_axi_awaddr   => m02_axi_awaddr, -- OUT STD_LOGIC_VECTOR(63 DOWNTO 0);
        m_axi_awlen    => m02_axi_awlen,  -- OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
        m_axi_awsize   => m02_axi_awsize, -- OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        m_axi_awburst  => m02_axi_awburst, -- OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_awvalid  => m02_axi_awvalid,  -- OUT STD_LOGIC;
        m_axi_awready  => m02_axi_awready,  -- IN STD_LOGIC;
        m_axi_wdata    => m02_axi_wdata,    -- OUT STD_LOGIC_VECTOR(255 DOWNTO 0);
        m_axi_wstrb    => m02_axi_wstrb,    -- OUT STD_LOGIC_VECTOR(63 DOWNTO 0);
        m_axi_wlast    => m02_axi_wlast,    -- OUT STD_LOGIC;
        m_axi_wvalid   => m02_axi_wvalid,   -- OUT STD_LOGIC;
        m_axi_wready   => m02_axi_wready,   -- IN STD_LOGIC;
        m_axi_bresp    => m02_axi_bresp,    -- IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_bvalid   => m02_axi_bvalid,   -- IN STD_LOGIC;
        m_axi_bready   => m02_axi_bready,   -- OUT STD_LOGIC;
        m_axi_araddr   => m02_axi_araddr,   -- OUT STD_LOGIC_VECTOR(63 DOWNTO 0);
        m_axi_arlen    => m02_axi_arlen,    -- OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
        m_axi_arsize   => m02_axi_arsize,   -- OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        m_axi_arburst  => m02_axi_arburst,  -- OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_arvalid  => m02_axi_arvalid,  -- OUT STD_LOGIC;
        m_axi_arready  => m02_axi_arready,  -- IN STD_LOGIC;
        m_axi_rdata    => m02_axi_rdata,    -- IN STD_LOGIC_VECTOR(255 DOWNTO 0);
        m_axi_rresp    => m02_axi_rresp,    -- IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_rlast    => m02_axi_rlast,    -- IN STD_LOGIC;
        m_axi_rvalid   => m02_axi_rvalid,   -- IN STD_LOGIC;
        m_axi_rready   => m02_axi_rready    --: OUT STD_LOGIC
    );

    -- Register slice for the m03 AXI interface
    m03_reg_slice : axi_reg_slice512_LLFFL
    port map (
        aclk    => ap_clk, --  IN STD_LOGIC;
        aresetn => ap_rst_n, --  IN STD_LOGIC;
        -- 
        s_axi_awaddr   => m03_axi_awaddri, -- IN STD_LOGIC_VECTOR(63 DOWNTO 0);
        s_axi_awlen    => m03_axi_aw.len,  -- IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        s_axi_awsize   => m03_axi_awsizei, -- IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        s_axi_awburst  => m03_axi_awbursti, -- IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_awvalid  => m03_axi_aw.valid,  -- IN STD_LOGIC;
        s_axi_awready  => m03_axi_awreadyi,  -- OUT STD_LOGIC;
        s_axi_wdata    => m03_axi_w.data,    -- IN STD_LOGIC_VECTOR(255 DOWNTO 0);
        s_axi_wstrb    => m03_axi_wstrbi,    -- IN STD_LOGIC_VECTOR(63 DOWNTO 0);
        s_axi_wlast    => m03_axi_w.last,    -- IN STD_LOGIC;
        s_axi_wvalid   => m03_axi_w.valid,   -- IN STD_LOGIC;
        s_axi_wready   => m03_axi_wreadyi,   -- OUT STD_LOGIC;
        s_axi_bresp    => m03_axi_b.resp,    --  OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_bvalid   => m03_axi_b.valid,   -- OUT STD_LOGIC;
        s_axi_bready   => m03_axi_breadyi,   -- IN STD_LOGIC;
        s_axi_araddr   => m03_axi_araddri,   -- IN STD_LOGIC_VECTOR(63 DOWNTO 0);
        s_axi_arlen    => m03_axi_ar.len,    -- IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        s_axi_arsize   => m03_axi_arsizei,   -- IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        s_axi_arburst  => m03_axi_arbursti,  -- IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_arvalid  => m03_axi_ar.valid,  -- IN STD_LOGIC;
        s_axi_arready  => m03_axi_arreadyi,  -- OUT STD_LOGIC;
        s_axi_rdata    => m03_axi_r.data,    -- OUT STD_LOGIC_VECTOR(255 DOWNTO 0);
        s_axi_rresp    => m03_axi_r.resp,    -- OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_rlast    => m03_axi_r.last,    -- OUT STD_LOGIC;
        s_axi_rvalid   => m03_axi_r.valid,   -- OUT STD_LOGIC;
        s_axi_rready   => m03_axi_rreadyi,   -- IN STD_LOGIC;
        --
        m_axi_awaddr   => m03_axi_awaddr, -- OUT STD_LOGIC_VECTOR(63 DOWNTO 0);
        m_axi_awlen    => m03_axi_awlen,  -- OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
        m_axi_awsize   => m03_axi_awsize, -- OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        m_axi_awburst  => m03_axi_awburst, -- OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_awvalid  => m03_axi_awvalid,  -- OUT STD_LOGIC;
        m_axi_awready  => m03_axi_awready,  -- IN STD_LOGIC;
        m_axi_wdata    => m03_axi_wdata,    -- OUT STD_LOGIC_VECTOR(255 DOWNTO 0);
        m_axi_wstrb    => m03_axi_wstrb,    -- OUT STD_LOGIC_VECTOR(63 DOWNTO 0);
        m_axi_wlast    => m03_axi_wlast,    -- OUT STD_LOGIC;
        m_axi_wvalid   => m03_axi_wvalid,   -- OUT STD_LOGIC;
        m_axi_wready   => m03_axi_wready,   -- IN STD_LOGIC;
        m_axi_bresp    => m03_axi_bresp,    -- IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_bvalid   => m03_axi_bvalid,   -- IN STD_LOGIC;
        m_axi_bready   => m03_axi_bready,   -- OUT STD_LOGIC;
        m_axi_araddr   => m03_axi_araddr,   -- OUT STD_LOGIC_VECTOR(63 DOWNTO 0);
        m_axi_arlen    => m03_axi_arlen,    -- OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
        m_axi_arsize   => m03_axi_arsize,   -- OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        m_axi_arburst  => m03_axi_arburst,  -- OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_arvalid  => m03_axi_arvalid,  -- OUT STD_LOGIC;
        m_axi_arready  => m03_axi_arready,  -- IN STD_LOGIC;
        m_axi_rdata    => m03_axi_rdata,    -- IN STD_LOGIC_VECTOR(255 DOWNTO 0);
        m_axi_rresp    => m03_axi_rresp,    -- IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_rlast    => m03_axi_rlast,    -- IN STD_LOGIC;
        m_axi_rvalid   => m03_axi_rvalid,   -- IN STD_LOGIC;
        m_axi_rready   => m03_axi_rready    --: OUT STD_LOGIC
    );
    

    ILA_GEN : if g_DEBUG_ILA GENERATE    
        u_ap_clk_ila : ila_0
        port map (
            clk => ap_clk, -- : IN STD_LOGIC;
            probe0(0) => ap_start, --  : IN STD_LOGIC_VECTOR(127 DOWNTO 0)
            probe0(1) => idle_int,
            probe0(2) => ap_done,
            probe0(17 downto 3) => cdma_status,
            probe0(49 downto 18) => DMA_src_addr,
            probe0(81 downto 50) => DMA_dest_addr,
            probe0(95 downto 82) => DMA_size(13 downto 0),
            probe0(111 downto 96) => uptime(15 downto 0),
            probe0(127 downto 112) => g_FIRMWARE_BUILD_DATE,
            probe0(191 downto 128) => DMASharedMemAddr
        );
        
        u_othermem_ila : ila_0
        port map (
            clk => ap_clk,
            probe0(63 downto 0) => m01_shared,
            probe0(127 downto 64) => m02_shared,
            probe0(191 downto 128) => (others => '0')
        );
        
    END GENERATE;
    
END structure;
