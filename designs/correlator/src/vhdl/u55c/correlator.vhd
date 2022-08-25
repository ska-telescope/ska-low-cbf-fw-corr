-------------------------------------------------------------------------------
--
-- File Name: vitisAccelCore.vhd
-- Contributing Authors: David Humphrey
-- Template Rev: 1.0
--
-- Title: Top Level for vitis compatible acceleration core
--
--  This is just a wrapper for the core which drops signals that are used for simulation only.
--  IP packager doesn't like some of these signals and they could potentially confuse vitis.
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


USE work.correlator_bus_pkg.ALL;
USE work.correlator_system_reg_pkg.ALL;
USE UNISIM.vcomponents.all;
Library xpm;
use xpm.vcomponents.all;

-------------------------------------------------------------------------------
ENTITY correlator IS
    generic (
        -- GLOBAL GENERICS for PERENTIE LOGIC
        g_DEBUG_ILA                : BOOLEAN := FALSE;
        -- Number of LFAA blocks per first stage corner turn frame; Nominal (and maximum allowed) value is 128;
        -- Allowed values are 32, 64, 128.
        -- Minimum possible value is 32, since we need enough preload data in a buffer to initialise the filterbanks
        -- Filterbanks need 11 x 4096 samples for initialisation; That's 22 LFAA frames (since they are 2048 samples).
        g_LFAA_BLOCKS_PER_FRAME    : integer := 128;  
        g_FIRMWARE_MAJOR_VERSION   : std_logic_vector(15 downto 0) := x"0000";
        g_FIRMWARE_MINOR_VERSION   : std_logic_vector(15 downto 0) := x"0000";
        g_FIRMWARE_PATCH_VERSION   : std_logic_vector(15 downto 0) := x"0000";
        g_FIRMWARE_LABEL           : std_logic_vector(31 downto 0) := x"00000000";
        g_FIRMWARE_PERSONALITY     : std_logic_vector(31 downto 0) := x"20434F52"; -- ASCII " COR"
        g_FIRMWARE_BUILD_DATE      : std_logic_vector(31 downto 0) := x"23072021";
        g_USE_META                 : BOOLEAN := FALSE;
        -- GENERICS for SHELL INTERACTION
        C_S_AXI_CONTROL_ADDR_WIDTH : integer := 7;
        C_S_AXI_CONTROL_DATA_WIDTH : integer := 32;
        C_M_AXI_ADDR_WIDTH : integer := 64;
        C_M_AXI_DATA_WIDTH : integer := 32;
        C_M_AXI_ID_WIDTH   : integer := 1;
        -- M01, 3 Gbytes HBM; first stage corner turn, between LFAA ingest and the filterbanks
        M01_AXI_ADDR_WIDTH : integer := 64;
        M01_AXI_DATA_WIDTH : integer := 512;
        M01_AXI_ID_WIDTH   : integer := 1;
        -- M02, 3 Gbytes HBM; Correlator HBM for fine channels going to the first correlator instance; buffer between the filterbanks and the correlator
        M02_AXI_ADDR_WIDTH : integer := 64;
        M02_AXI_DATA_WIDTH : integer := 512; 
        M02_AXI_ID_WIDTH   : integer := 1;
        -- M03, 3 Gbytes HBM; Correlator HBM for fine channels going to the Second correlator instance; buffer between the filterbanks and the correlator
        M03_AXI_ADDR_WIDTH : integer := 64;  
        M03_AXI_DATA_WIDTH : integer := 512;
        M03_AXI_ID_WIDTH   : integer := 1;
        -- M04, 2 Gbytes HBM; Visibilities from first correlator instance
        M04_AXI_ADDR_WIDTH : integer := 64;  
        M04_AXI_DATA_WIDTH : integer := 512;
        M04_AXI_ID_WIDTH   : integer := 1;
        -- M05, 2 Gbytes HBM; Visibilities from second correlator instance
        M05_AXI_ADDR_WIDTH : integer := 64;  
        M05_AXI_DATA_WIDTH : integer := 512;
        M05_AXI_ID_WIDTH   : integer := 1
    );
    PORT (
        ap_clk : in std_logic;
        ap_rst_n : in std_logic;
        
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
        -- 3 Gbytes
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
        -- AXI4 master interface; Correlator HBM; buffer between the filterbanks and the correlator
        -- First half, for fine channels that go to the first correlator instance.
        -- 3 Gbytes
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

        -- AXI4 master interface; Correlator HBM; buffer between the filterbanks and the correlator
        -- Second half, for fine channels that go to the second correlator instance.
        -- 3 Gbytes
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
        
        -- M04 = Visibilities from first correlator instance; 2 Gbytes
        m04_axi_awvalid : out std_logic;
        m04_axi_awready : in std_logic;
        m04_axi_awaddr : out std_logic_vector(M04_AXI_ADDR_WIDTH-1 downto 0);
        m04_axi_awid   : out std_logic_vector(M04_AXI_ID_WIDTH - 1 downto 0);
        m04_axi_awlen   : out std_logic_vector(7 downto 0);
        m04_axi_awsize   : out std_logic_vector(2 downto 0);
        m04_axi_awburst  : out std_logic_vector(1 downto 0);
        m04_axi_awlock   : out std_logic_vector(1 downto 0);
        m04_axi_awcache  : out std_logic_vector(3 downto 0);
        m04_axi_awprot   : out std_logic_vector(2 downto 0);
        m04_axi_awqos    : out std_logic_vector(3 downto 0);
        m04_axi_awregion : out std_logic_vector(3 downto 0);
        m04_axi_wvalid    : out std_logic;
        m04_axi_wready    : in std_logic;
        m04_axi_wdata     : out std_logic_vector(M04_AXI_DATA_WIDTH-1 downto 0);
        m04_axi_wstrb     : out std_logic_vector(M04_AXI_DATA_WIDTH/8-1 downto 0);
        m04_axi_wlast     : out std_logic;
        m04_axi_bvalid    : in std_logic;
        m04_axi_bready    : out std_logic;
        m04_axi_bresp     : in std_logic_vector(1 downto 0);
        m04_axi_bid       : in std_logic_vector(M04_AXI_ID_WIDTH - 1 downto 0);
        m04_axi_arvalid   : out std_logic;
        m04_axi_arready   : in std_logic;
        m04_axi_araddr    : out std_logic_vector(M04_AXI_ADDR_WIDTH-1 downto 0);
        m04_axi_arid      : out std_logic_vector(M04_AXI_ID_WIDTH-1 downto 0);
        m04_axi_arlen     : out std_logic_vector(7 downto 0);
        m04_axi_arsize    : out std_logic_vector(2 downto 0);
        m04_axi_arburst   : out std_logic_vector(1 downto 0);
        m04_axi_arlock    : out std_logic_vector(1 downto 0);
        m04_axi_arcache   : out std_logic_vector(3 downto 0);
        m04_axi_arprot    : out std_logic_Vector(2 downto 0);
        m04_axi_arqos     : out std_logic_vector(3 downto 0);
        m04_axi_arregion  : out std_logic_vector(3 downto 0);
        m04_axi_rvalid    : in std_logic;
        m04_axi_rready    : out std_logic;
        m04_axi_rdata     : in std_logic_vector(M04_AXI_DATA_WIDTH-1 downto 0);
        m04_axi_rlast     : in std_logic;
        m04_axi_rid       : in std_logic_vector(M04_AXI_ID_WIDTH - 1 downto 0);
        m04_axi_rresp     : in std_logic_vector(1 downto 0);           
        
        -- M05 = Visibilities from second correlator instance; 2 Gbytes
        m05_axi_awvalid : out std_logic;
        m05_axi_awready : in std_logic;
        m05_axi_awaddr : out std_logic_vector(M05_AXI_ADDR_WIDTH-1 downto 0);
        m05_axi_awid   : out std_logic_vector(M05_AXI_ID_WIDTH - 1 downto 0);
        m05_axi_awlen   : out std_logic_vector(7 downto 0);
        m05_axi_awsize   : out std_logic_vector(2 downto 0);
        m05_axi_awburst  : out std_logic_vector(1 downto 0);
        m05_axi_awlock   : out std_logic_vector(1 downto 0);
        m05_axi_awcache  : out std_logic_vector(3 downto 0);
        m05_axi_awprot   : out std_logic_vector(2 downto 0);
        m05_axi_awqos    : out std_logic_vector(3 downto 0);
        m05_axi_awregion : out std_logic_vector(3 downto 0);
        m05_axi_wvalid    : out std_logic;
        m05_axi_wready    : in std_logic;
        m05_axi_wdata     : out std_logic_vector(M05_AXI_DATA_WIDTH-1 downto 0);
        m05_axi_wstrb     : out std_logic_vector(M05_AXI_DATA_WIDTH/8-1 downto 0);
        m05_axi_wlast     : out std_logic;
        m05_axi_bvalid    : in std_logic;
        m05_axi_bready    : out std_logic;
        m05_axi_bresp     : in std_logic_vector(1 downto 0);
        m05_axi_bid       : in std_logic_vector(M05_AXI_ID_WIDTH - 1 downto 0);
        m05_axi_arvalid   : out std_logic;
        m05_axi_arready   : in std_logic;
        m05_axi_araddr    : out std_logic_vector(M05_AXI_ADDR_WIDTH-1 downto 0);
        m05_axi_arid      : out std_logic_vector(M05_AXI_ID_WIDTH-1 downto 0);
        m05_axi_arlen     : out std_logic_vector(7 downto 0);
        m05_axi_arsize    : out std_logic_vector(2 downto 0);
        m05_axi_arburst   : out std_logic_vector(1 downto 0);
        m05_axi_arlock    : out std_logic_vector(1 downto 0);
        m05_axi_arcache   : out std_logic_vector(3 downto 0);
        m05_axi_arprot    : out std_logic_Vector(2 downto 0);
        m05_axi_arqos     : out std_logic_vector(3 downto 0);
        m05_axi_arregion  : out std_logic_vector(3 downto 0);
        m05_axi_rvalid    : in std_logic;
        m05_axi_rready    : out std_logic;
        m05_axi_rdata     : in std_logic_vector(M05_AXI_DATA_WIDTH-1 downto 0);
        m05_axi_rlast     : in std_logic;
        m05_axi_rid       : in std_logic_vector(M05_AXI_ID_WIDTH - 1 downto 0);
        m05_axi_rresp     : in std_logic_vector(1 downto 0);             
        
        -- GT pins
        -- clk_gt_freerun is a 50MHz free running clock, according to the GT kernel Example Design user guide.
        -- But it looks like it is configured to be 100MHz in the example designs for all parts except the U280. 
        -- Warning : vitis doesn't hook this up.
        clk_freerun    : in std_logic;
        gt_rxp_in      : in std_logic_vector(3 downto 0);
        gt_rxn_in      : in std_logic_vector(3 downto 0);
        gt_txp_out     : out std_logic_vector(3 downto 0);
        gt_txn_out     : out std_logic_vector(3 downto 0);
        gt_refclk_p    : in std_logic;
        gt_refclk_n    : in std_logic
    );
END correlator;

ARCHITECTURE structure OF correlator IS

    signal dummy0 : t_lbus_sosi;
    signal dummy1 : t_lbus_siso;

begin
    
    
    
    vcore : entity correlator_lib.correlator_core
    generic map (
        -- GENERICS for use in the testbench 
        g_SIMULATION => FALSE, -- when true, the 100GE core is disabled and instead the lbus comes from the top level pins
        g_USE_META => g_USE_META, -- when true, meta data is written to the second stage corner turn instead of the filterbank output. For debug only.
        -- GLOBAL GENERICS for PERENTIE LOGIC
        g_DEBUG_ILA               => g_DEBUG_ILA, --  BOOLEAN := FALSE;
        g_LFAA_BLOCKS_PER_FRAME   => g_LFAA_BLOCKS_PER_FRAME,  -- Number of LFAA blocks per frame.
        g_FIRMWARE_MAJOR_VERSION  => g_FIRMWARE_MAJOR_VERSION,
        g_FIRMWARE_MINOR_VERSION  => g_FIRMWARE_MINOR_VERSION,
        g_FIRMWARE_PATCH_VERSION  => g_FIRMWARE_PATCH_VERSION,
        g_FIRMWARE_LABEL          => g_FIRMWARE_LABEL,
        g_FIRMWARE_PERSONALITY    => g_FIRMWARE_PERSONALITY,
        g_FIRMWARE_BUILD_DATE     => g_FIRMWARE_BUILD_DATE,
        -- GENERICS for SHELL INTERACTION
        C_S_AXI_CONTROL_ADDR_WIDTH => C_S_AXI_CONTROL_ADDR_WIDTH, -- integer := 6;
        C_S_AXI_CONTROL_DATA_WIDTH => C_S_AXI_CONTROL_DATA_WIDTH, -- integer := 32;
        C_M_AXI_ADDR_WIDTH => C_M_AXI_ADDR_WIDTH, -- integer := 64;
        C_M_AXI_DATA_WIDTH => C_M_AXI_DATA_WIDTH, -- integer := 32;
        C_M_AXI_ID_WIDTH   => C_M_AXI_ID_WIDTH,   -- integer := 1;
        -- Filterbank HBM
        M01_AXI_ADDR_WIDTH => M01_AXI_ADDR_WIDTH, -- integer := 64;
        M01_AXI_DATA_WIDTH => M01_AXI_DATA_WIDTH, -- integer := 512;
        M01_AXI_ID_WIDTH   => M01_AXI_ID_WIDTH,   -- integer := 1;
        -- Correlator HBM
        M02_AXI_ADDR_WIDTH => M02_AXI_ADDR_WIDTH, -- integer := 64;  
        M02_AXI_DATA_WIDTH => M02_AXI_DATA_WIDTH, -- integer := 512; 
        M02_AXI_ID_WIDTH   => M02_AXI_ID_WIDTH,   -- integer := 1
        -- Visibilities HBM
        M03_AXI_ADDR_WIDTH => M03_AXI_ADDR_WIDTH, -- integer := 64;  
        M03_AXI_DATA_WIDTH => M03_AXI_DATA_WIDTH, -- integer := 512;
        M03_AXI_ID_WIDTH   => M03_AXI_ID_WIDTH    -- integer := 1
    ) PORT map (
        ap_clk => ap_clk, -- in std_logic;
        ap_rst_n => ap_rst_n, -- in std_logic;
        
        -----------------------------------------------------------------------
        -- Ports used for simulation only.
        --
        -- Received data from 100GE
        i_eth100_rx_sosi => dummy0, -- in t_lbus_sosi;
        -- Data to be transmitted on 100GE
        o_eth100_tx_sosi => open, -- out t_lbus_sosi;
        i_eth100_tx_siso => dummy1, --  in t_lbus_siso;
        i_clk_100GE      => '0', -- in std_logic;
        
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
        s_axi_control_awvalid =>  s_axi_control_awvalid, 
        s_axi_control_awready =>  s_axi_control_awready, 
        s_axi_control_awaddr  =>  s_axi_control_awaddr,  
        s_axi_control_wvalid  =>  s_axi_control_wvalid,  
        s_axi_control_wready  =>  s_axi_control_wready,  
        s_axi_control_wdata   =>  s_axi_control_wdata,   
        s_axi_control_wstrb   =>  s_axi_control_wstrb,   
        s_axi_control_arvalid =>  s_axi_control_arvalid, 
        s_axi_control_arready =>  s_axi_control_arready, 
        s_axi_control_araddr  =>  s_axi_control_araddr,  
        s_axi_control_rvalid  =>  s_axi_control_rvalid,  
        s_axi_control_rready  =>  s_axi_control_rready,  
        s_axi_control_rdata   =>  s_axi_control_rdata,   
        s_axi_control_rresp   =>  s_axi_control_rresp,   
        s_axi_control_bvalid  =>  s_axi_control_bvalid,  
        s_axi_control_bready  =>  s_axi_control_bready,  
        s_axi_control_bresp   =>  s_axi_control_bresp,   
  
        -- AXI4 master interface for accessing registers : m00_axi
        m00_axi_awvalid =>  m00_axi_awvalid,   
        m00_axi_awready =>  m00_axi_awready,   
        m00_axi_awaddr  =>  m00_axi_awaddr,    
        m00_axi_awid    =>  m00_axi_awid,      
        m00_axi_awlen   =>  m00_axi_awlen,     
        m00_axi_awsize  =>  m00_axi_awsize,    
        m00_axi_awburst =>  m00_axi_awburst,   
        m00_axi_awlock  =>  m00_axi_awlock,    
        m00_axi_awcache =>  m00_axi_awcache,   
        m00_axi_awprot  =>  m00_axi_awprot,    
        m00_axi_awqos   =>  m00_axi_awqos,     
        m00_axi_awregion => m00_axi_awregion,  
        m00_axi_wvalid   => m00_axi_wvalid,    
        m00_axi_wready   => m00_axi_wready,    
        m00_axi_wdata    => m00_axi_wdata,     
        m00_axi_wstrb    => m00_axi_wstrb,     
        m00_axi_wlast    => m00_axi_wlast,     
        m00_axi_bvalid   => m00_axi_bvalid,    
        m00_axi_bready   => m00_axi_bready,    
        m00_axi_bresp    => m00_axi_bresp,     
        m00_axi_bid      => m00_axi_bid,       
        m00_axi_arvalid  => m00_axi_arvalid,   
        m00_axi_arready  => m00_axi_arready,   
        m00_axi_araddr   => m00_axi_araddr,    
        m00_axi_arid     => m00_axi_arid,      
        m00_axi_arlen    => m00_axi_arlen,     
        m00_axi_arsize   => m00_axi_arsize,    
        m00_axi_arburst  => m00_axi_arburst,   
        m00_axi_arlock   => m00_axi_arlock,    
        m00_axi_arcache  => m00_axi_arcache,   
        m00_axi_arprot   => m00_axi_arprot,    
        m00_axi_arqos    => m00_axi_arqos,     
        m00_axi_arregion => m00_axi_arregion,  
        m00_axi_rvalid   => m00_axi_rvalid,    
        m00_axi_rready   => m00_axi_rready,    
        m00_axi_rdata    => m00_axi_rdata,     
        m00_axi_rlast    => m00_axi_rlast,     
        m00_axi_rid      => m00_axi_rid,       
        m00_axi_rresp    => m00_axi_rresp,     
        ---------------------------------------------------------------------------------------
        -- AXI4 master interface for accessing HBM for the LFAA ingest corner turn : m01_axi
        m01_axi_awvalid  =>  m01_axi_awvalid,   
        m01_axi_awready  =>  m01_axi_awready,   
        m01_axi_awaddr   =>  m01_axi_awaddr,    
        m01_axi_awid     =>  m01_axi_awid,      
        m01_axi_awlen    =>  m01_axi_awlen,     
        m01_axi_awsize   =>  m01_axi_awsize,    
        m01_axi_awburst  =>  m01_axi_awburst,   
        m01_axi_awlock   =>  m01_axi_awlock,    
        m01_axi_awcache  =>  m01_axi_awcache,   
        m01_axi_awprot   =>  m01_axi_awprot,    
        m01_axi_awqos    =>  m01_axi_awqos,     
        m01_axi_awregion =>  m01_axi_awregion,  
   
        m01_axi_wvalid   =>  m01_axi_wvalid,    
        m01_axi_wready   =>  m01_axi_wready,    
        m01_axi_wdata    =>  m01_axi_wdata,     
        m01_axi_wstrb    =>  m01_axi_wstrb,     
        m01_axi_wlast    =>  m01_axi_wlast,     
        m01_axi_bvalid   =>  m01_axi_bvalid,    
        m01_axi_bready   =>  m01_axi_bready,    
        m01_axi_bresp    =>  m01_axi_bresp,     
        m01_axi_bid      =>  m01_axi_bid,       
        m01_axi_arvalid  =>  m01_axi_arvalid,   
        m01_axi_arready  =>  m01_axi_arready,   
        m01_axi_araddr   =>  m01_axi_araddr,    
        m01_axi_arid     =>  m01_axi_arid,      
        m01_axi_arlen    =>  m01_axi_arlen,     
        m01_axi_arsize   =>  m01_axi_arsize,    
        m01_axi_arburst  =>  m01_axi_arburst,   
        m01_axi_arlock   =>  m01_axi_arlock,    
        m01_axi_arcache  =>  m01_axi_arcache,   
        m01_axi_arprot   =>  m01_axi_arprot,    
        m01_axi_arqos    =>  m01_axi_arqos,     
        m01_axi_arregion =>  m01_axi_arregion,  
        m01_axi_rvalid   =>  m01_axi_rvalid,    
        m01_axi_rready   =>  m01_axi_rready,    
        m01_axi_rdata    =>  m01_axi_rdata,     
        m01_axi_rlast    =>  m01_axi_rlast,     
        m01_axi_rid      =>  m01_axi_rid,       
        m01_axi_rresp    =>  m01_axi_rresp,     

        ---------------------------------------------------------------------------------------
        -- 3 Gbyte HBM for fine channel data for input to the first correlator instance
        m02_axi_awvalid  => m02_axi_awvalid,  
        m02_axi_awready  => m02_axi_awready,   
        m02_axi_awaddr   => m02_axi_awaddr,    
        m02_axi_awid     => m02_axi_awid,      
        m02_axi_awlen    => m02_axi_awlen,     
        m02_axi_awsize   => m02_axi_awsize,    
        m02_axi_awburst  => m02_axi_awburst,   
        m02_axi_awlock   => m02_axi_awlock,    
        m02_axi_awcache  => m02_axi_awcache,   
        m02_axi_awprot   => m02_axi_awprot,    
        m02_axi_awqos    => m02_axi_awqos,     
        m02_axi_awregion => m02_axi_awregion,  
   
        m02_axi_wvalid   => m02_axi_wvalid,    
        m02_axi_wready   => m02_axi_wready,    
        m02_axi_wdata    => m02_axi_wdata,     
        m02_axi_wstrb    => m02_axi_wstrb,     
        m02_axi_wlast    => m02_axi_wlast,     
        m02_axi_bvalid   => m02_axi_bvalid,    
        m02_axi_bready   => m02_axi_bready,    
        m02_axi_bresp    => m02_axi_bresp,     
        m02_axi_bid      => m02_axi_bid,       
        m02_axi_arvalid  => m02_axi_arvalid,   
        m02_axi_arready  => m02_axi_arready,   
        m02_axi_araddr   => m02_axi_araddr,    
        m02_axi_arid     => m02_axi_arid,      
        m02_axi_arlen    => m02_axi_arlen,     
        m02_axi_arsize   => m02_axi_arsize,    
        m02_axi_arburst  => m02_axi_arburst,   
        m02_axi_arlock   => m02_axi_arlock,    
        m02_axi_arcache  => m02_axi_arcache,   
        m02_axi_arprot   => m02_axi_arprot,    
        m02_axi_arqos    => m02_axi_arqos,     
        m02_axi_arregion => m02_axi_arregion,  
        m02_axi_rvalid   => m02_axi_rvalid,    
        m02_axi_rready   => m02_axi_rready,    
        m02_axi_rdata    => m02_axi_rdata,     
        m02_axi_rlast    => m02_axi_rlast,     
        m02_axi_rid      => m02_axi_rid,       
        m02_axi_rresp    => m02_axi_rresp,     
        ------------------------------------------------------------------------------------------
        -- 3 Gbyte HBM for fine channel data for input to the second correlator instance.
        m03_axi_awvalid  => m03_axi_awvalid,  
        m03_axi_awready  => m03_axi_awready,   
        m03_axi_awaddr   => m03_axi_awaddr,    
        m03_axi_awid     => m03_axi_awid,      
        m03_axi_awlen    => m03_axi_awlen,     
        m03_axi_awsize   => m03_axi_awsize,    
        m03_axi_awburst  => m03_axi_awburst,   
        m03_axi_awlock   => m03_axi_awlock,    
        m03_axi_awcache  => m03_axi_awcache,   
        m03_axi_awprot   => m03_axi_awprot,    
        m03_axi_awqos    => m03_axi_awqos,     
        m03_axi_awregion => m03_axi_awregion,  
        m03_axi_wvalid   => m03_axi_wvalid,    
        m03_axi_wready   => m03_axi_wready,    
        m03_axi_wdata    => m03_axi_wdata,     
        m03_axi_wstrb    => m03_axi_wstrb,     
        m03_axi_wlast    => m03_axi_wlast,     
        m03_axi_bvalid   => m03_axi_bvalid,    
        m03_axi_bready   => m03_axi_bready,    
        m03_axi_bresp    => m03_axi_bresp,     
        m03_axi_bid      => m03_axi_bid,       
        m03_axi_arvalid  => m03_axi_arvalid,   
        m03_axi_arready  => m03_axi_arready,   
        m03_axi_araddr   => m03_axi_araddr,    
        m03_axi_arid     => m03_axi_arid,      
        m03_axi_arlen    => m03_axi_arlen,     
        m03_axi_arsize   => m03_axi_arsize,    
        m03_axi_arburst  => m03_axi_arburst,   
        m03_axi_arlock   => m03_axi_arlock,    
        m03_axi_arcache  => m03_axi_arcache,   
        m03_axi_arprot   => m03_axi_arprot,    
        m03_axi_arqos    => m03_axi_arqos,     
        m03_axi_arregion => m03_axi_arregion,  
        m03_axi_rvalid   => m03_axi_rvalid,    
        m03_axi_rready   => m03_axi_rready,    
        m03_axi_rdata    => m03_axi_rdata,     
        m03_axi_rlast    => m03_axi_rlast,     
        m03_axi_rid      => m03_axi_rid,       
        m03_axi_rresp    => m03_axi_rresp,   

        ------------------------------------------------------------------------------------------
        -- Visibilities HBM for first correlator instance
        m04_axi_awvalid  => m04_axi_awvalid,  
        m04_axi_awready  => m04_axi_awready,   
        m04_axi_awaddr   => m04_axi_awaddr,    
        m04_axi_awid     => m04_axi_awid,      
        m04_axi_awlen    => m04_axi_awlen,     
        m04_axi_awsize   => m04_axi_awsize,    
        m04_axi_awburst  => m04_axi_awburst,   
        m04_axi_awlock   => m04_axi_awlock,    
        m04_axi_awcache  => m04_axi_awcache,   
        m04_axi_awprot   => m04_axi_awprot,    
        m04_axi_awqos    => m04_axi_awqos,     
        m04_axi_awregion => m04_axi_awregion,  
        m04_axi_wvalid   => m04_axi_wvalid,    
        m04_axi_wready   => m04_axi_wready,    
        m04_axi_wdata    => m04_axi_wdata,     
        m04_axi_wstrb    => m04_axi_wstrb,     
        m04_axi_wlast    => m04_axi_wlast,     
        m04_axi_bvalid   => m04_axi_bvalid,    
        m04_axi_bready   => m04_axi_bready,    
        m04_axi_bresp    => m04_axi_bresp,     
        m04_axi_bid      => m04_axi_bid,       
        m04_axi_arvalid  => m04_axi_arvalid,   
        m04_axi_arready  => m04_axi_arready,   
        m04_axi_araddr   => m04_axi_araddr,    
        m04_axi_arid     => m04_axi_arid,      
        m04_axi_arlen    => m04_axi_arlen,     
        m04_axi_arsize   => m04_axi_arsize,    
        m04_axi_arburst  => m04_axi_arburst,   
        m04_axi_arlock   => m04_axi_arlock,    
        m04_axi_arcache  => m04_axi_arcache,   
        m04_axi_arprot   => m04_axi_arprot,    
        m04_axi_arqos    => m04_axi_arqos,     
        m04_axi_arregion => m04_axi_arregion,  
        m04_axi_rvalid   => m04_axi_rvalid,    
        m04_axi_rready   => m04_axi_rready,    
        m04_axi_rdata    => m04_axi_rdata,     
        m04_axi_rlast    => m04_axi_rlast,     
        m04_axi_rid      => m04_axi_rid,       
        m04_axi_rresp    => m04_axi_rresp,

        ------------------------------------------------------------------------------------------
        -- Visibilities HBM for second correlator instance
        m05_axi_awvalid  => m05_axi_awvalid,  
        m05_axi_awready  => m05_axi_awready,   
        m05_axi_awaddr   => m05_axi_awaddr,    
        m05_axi_awid     => m05_axi_awid,      
        m05_axi_awlen    => m05_axi_awlen,     
        m05_axi_awsize   => m05_axi_awsize,    
        m05_axi_awburst  => m05_axi_awburst,   
        m05_axi_awlock   => m05_axi_awlock,    
        m05_axi_awcache  => m05_axi_awcache,   
        m05_axi_awprot   => m05_axi_awprot,    
        m05_axi_awqos    => m05_axi_awqos,     
        m05_axi_awregion => m05_axi_awregion,  
        m05_axi_wvalid   => m05_axi_wvalid,    
        m05_axi_wready   => m05_axi_wready,    
        m05_axi_wdata    => m05_axi_wdata,     
        m05_axi_wstrb    => m05_axi_wstrb,     
        m05_axi_wlast    => m05_axi_wlast,     
        m05_axi_bvalid   => m05_axi_bvalid,    
        m05_axi_bready   => m05_axi_bready,    
        m05_axi_bresp    => m05_axi_bresp,     
        m05_axi_bid      => m05_axi_bid,       
        m05_axi_arvalid  => m05_axi_arvalid,   
        m05_axi_arready  => m05_axi_arready,   
        m05_axi_araddr   => m05_axi_araddr,    
        m05_axi_arid     => m05_axi_arid,      
        m05_axi_arlen    => m05_axi_arlen,     
        m05_axi_arsize   => m05_axi_arsize,    
        m05_axi_arburst  => m05_axi_arburst,   
        m05_axi_arlock   => m05_axi_arlock,    
        m05_axi_arcache  => m05_axi_arcache,   
        m05_axi_arprot   => m05_axi_arprot,    
        m05_axi_arqos    => m05_axi_arqos,     
        m05_axi_arregion => m05_axi_arregion,  
        m05_axi_rvalid   => m05_axi_rvalid,    
        m05_axi_rready   => m05_axi_rready,    
        m05_axi_rdata    => m05_axi_rdata,     
        m05_axi_rlast    => m05_axi_rlast,     
        m05_axi_rid      => m05_axi_rid,       
        m05_axi_rresp    => m05_axi_rresp,

        -- GT pins
        -- clk_freerun is a 100MHz free running clock.

        clk_freerun    => clk_freerun, 
        gt_rxp_in      => gt_rxp_in,      
        gt_rxn_in      => gt_rxn_in,      
        gt_txp_out     => gt_txp_out,     
        gt_txn_out     => gt_txn_out,     
        gt_refclk_p    => gt_refclk_p,    
        gt_refclk_n    => gt_refclk_n    
    );
    
END structure;
