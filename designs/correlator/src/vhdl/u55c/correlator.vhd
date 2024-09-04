-------------------------------------------------------------------------------
--
-- File Name: correlator.vhd
-- Contributing Authors: David Humphrey
-- Template Rev: 1.0
--
-- Title: Top Level for vitis compatible correlator acceleration core
--
--  This is just a wrapper for the core which drops signals that are used for simulation only.
--  IP packager doesn't like some of these signals and they could potentially confuse vitis.
-------------------------------------------------------------------------------

LIBRARY IEEE, UNISIM, common_lib, axi4_lib, technology_lib, util_lib, dsp_top_lib, correlator_lib, Timeslave_CMAC_lib;
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
use work.version_pkg.all;
USE UNISIM.vcomponents.all;
Library xpm;
use xpm.vcomponents.all;

-------------------------------------------------------------------------------
ENTITY correlator IS
    generic (
        -- GLOBAL GENERICS for PERENTIE LOGIC
        g_DEBUG_ILA                : BOOLEAN := FALSE;
--        g_FIRMWARE_MAJOR_VERSION   : std_logic_vector(15 downto 0) := x"0000";
--        g_FIRMWARE_MINOR_VERSION   : std_logic_vector(15 downto 0) := x"0000";
--        g_FIRMWARE_PATCH_VERSION   : std_logic_vector(15 downto 0) := x"0000";
        g_FIRMWARE_LABEL           : std_logic_vector(31 downto 0) := x"00000000";
        g_FIRMWARE_PERSONALITY     : std_logic_vector(31 downto 0) := x"434F5252"; -- ASCII "CORR"
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
    
    constant g_HBM_INTERFACES       : integer := 5;
    constant g_HBM_AXI_ADDR_WIDTH   : integer := 64;
    constant g_HBM_AXI_DATA_WIDTH   : integer := 512;
    constant g_HBM_AXI_ID_WIDTH     : integer := 1;
    
    ---------------------------------------------------------------------------------------
    -- AXI4 interfaces for accessing HBM
    -- 0 = 3 Gbytes for LFAA ingest corner turn 
    -- 1 = 3 Gbytes, buffer between the filterbanks and the correlator
    --     First half, for fine channels that go to the first correlator instance.
    -- 2 = 3 Gbytes, buffer between the filterbanks and the correlator
    --     second half, for fine channels that go to the second correlator instance.
    -- 3 = 2 Gbytes, Visibilities from First correlator instance;
    -- 4 = 2 Gbytes, Visibilities from Second correlator instance;
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

    constant zero_vec : std_logic_Vector(511 downto 0) := (others => '0');
    signal ap_rst : std_logic;
    
    signal rx_axis_tdata : std_logic_vector(511 downto 0);
    signal rx_axis_tkeep : std_logic_vector(63 downto 0);
    signal rx_axis_tlast : std_logic;
    signal rx_axis_tready : std_logic;
    signal rx_axis_tuser : std_logic_vector(79 downto 0);
    signal rx_axis_tvalid : std_logic;
    signal PTP_time_ARGs_clk : std_logic_vector(79 downto 0);
    
    signal tx_axis_tdata : std_logic_vector(511 downto 0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
    signal tx_axis_tkeep : std_logic_vector(63 downto 0);  -- one bit per byte in i_axi_tdata
    signal tx_axis_tlast : std_logic;
    signal tx_axis_tuser : std_logic;
    signal tx_axis_tvalid : std_logic;
    signal tx_axis_tready : std_logic;
    
    signal cmac_mc_lite_mosi : t_axi4_lite_mosi; 
    signal cmac_mc_lite_miso : t_axi4_lite_miso;

    signal timeslave_mc_full_mosi : t_axi4_full_mosi;
    signal timeslave_mc_full_miso : t_axi4_full_miso;
    signal eth100_reset_final : std_logic;
    signal fec_enable_322m : std_logic;
    signal eth100g_clk     : std_logic;
    signal eth100g_locked  : std_logic;
    
    signal eth100G_rx_total_packets : std_logic_vector(31 downto 0);
    signal eth100G_rx_bad_fcs       : std_logic_vector(31 downto 0);
    signal eth100G_rx_bad_code      : std_logic_vector(31 downto 0);
    signal eth100G_tx_total_packets : std_logic_vector(31 downto 0);
    
begin

    -------------------------------------------------------------------------------
    -- The 100GE core and timeslave are not used in the simulation.
     
    -- temp driving
    rx_axis_tready  <= '1';
    
    process(ap_clk)
    begin
        if rising_edge(ap_clk) then
            ap_rst <= not ap_rst_n;
        end if;
    end process;
    
    u_100G_port_a : entity Timeslave_CMAC_lib.CMAC_100G_wrap_w_timeslave
    Generic map (
        U55_TOP_QSFP        => TRUE,
        U55_BOTTOM_QSFP     => FALSE         -- THIS CONFIG IS VALID FOR U50 as well.
    )
    Port map(
        gt_rxp_in   => gt_rxp_in, -- in(3:0);
        gt_rxn_in   => gt_rxn_in, -- in(3:0);
        gt_txp_out  => gt_txp_out, -- out(3:0);
        gt_txn_out  => gt_txn_out, -- out(3:0);
        gt_refclk_p => gt_refclk_p, -- IN STD_LOGIC;
        gt_refclk_n => gt_refclk_n, -- IN STD_LOGIC;
        sys_reset   => eth100_reset_final,   -- IN STD_LOGIC;   -- sys_reset, clocked by dclk.
        i_dclk_100  => clk_freerun,     --  100MHz supplied by the Alveo platform.       
        
        i_fec_enable => fec_enable_322m,
        -- All remaining signals are clocked on tx_clk_out
        tx_clk_out   => eth100G_clk, -- out std_logic; This is the clock used by the data in and out of the core. 322 MHz.
        
        -- User Interface Signals
        rx_locked     => eth100G_locked, -- out std_logic; 
        user_rx_reset => open,
        user_tx_reset => open,

        -- Statistics Interface, on eth100_clk
        rx_total_packets    => eth100G_rx_total_packets, -- out(31:0);
        rx_bad_fcs          => eth100G_rx_bad_fcs,       -- out(31:0);
        rx_bad_code         => eth100G_rx_bad_code,      -- out(31:0);
        tx_total_packets    => eth100G_tx_total_packets, -- out(31:0);
        
        -----------------------------------------------------------------------
        -- streaming AXI to CMAC
        i_tx_axis_tdata     => tx_axis_tdata,
        i_tx_axis_tkeep     => tx_axis_tkeep,
        i_tx_axis_tvalid    => tx_axis_tvalid,
        i_tx_axis_tlast     => tx_axis_tlast,
        i_tx_axis_tuser     => tx_axis_tuser,
        o_tx_axis_tready    => tx_axis_tready,
        
        -- RX
        o_rx_axis_tdata     => rx_axis_tdata,
        o_rx_axis_tkeep     => rx_axis_tkeep,
        o_rx_axis_tlast     => rx_axis_tlast,
        i_rx_axis_tready    => rx_axis_tready,
        o_rx_axis_tuser     => rx_axis_tuser,
        o_rx_axis_tvalid    => rx_axis_tvalid,
        
        -- streaming AXI to CMAC, Pre_timeslave
        CMAC_rx_axis_tdata  => open,
        CMAC_rx_axis_tkeep  => open,
        CMAC_rx_axis_tlast  => open,
        CMAC_rx_axis_tuser  => open,
        CMAC_rx_axis_tvalid => open, 
        -----------------------------------------------------------------------
        
        -- PTP Data
        PTP_time_CMAC_clk => open,
        PTP_pps_CMAC_clk  => open,        
        PTP_time_ARGs_clk => PTP_time_ARGs_clk,
        PTP_pps_ARGs_clk  => open,
        
        -- ARGs Interface
        i_ARGs_clk => ap_clk, -- in std_logic;
        i_ARGs_rst => ap_rst, -- in std_logic;
        
        i_CMAC_Lite_axi_mosi      => cmac_mc_lite_mosi,
        o_CMAC_Lite_axi_miso      => cmac_mc_lite_miso,
        
        i_Timeslave_Full_axi_mosi => timeslave_mc_full_mosi,
        o_Timeslave_Full_axi_miso => timeslave_mc_full_miso
    );
    
    vcore : entity correlator_lib.correlator_core
    generic map (
        -- GENERICS for use in the testbench 
        g_SIMULATION                => FALSE, -- when true, the 100GE core is disabled and instead the lbus comes from the top level pins
        g_USE_META                  => g_USE_META, -- when true, meta data is written to the second stage corner turn instead of the filterbank output. For debug only.
        -- GLOBAL GENERICS for PERENTIE LOGIC
        g_DEBUG_ILA                 => g_DEBUG_ILA, --  BOOLEAN := FALSE;
        -- Number of SPS packets per first stage corner turn frame; Nominal (and maximum allowed) value is 128;
        -- Allowed values are 32, 64, 128. Always use 128 when running in hardware.
        -- Minimum possible value is 32, since we need enough preload data in a buffer to initialise the filterbanks
        -- Filterbanks need 11 x 4096 samples for initialisation; That's 22 LFAA frames (since they are 2048 samples).
        g_SPS_PACKETS_PER_FRAME     => 128,
        g_FIRMWARE_MAJOR_VERSION    => C_FIRMWARE_MAJOR_VERSION,
        g_FIRMWARE_MINOR_VERSION    => C_FIRMWARE_MINOR_VERSION,
        g_FIRMWARE_PATCH_VERSION    => C_FIRMWARE_PATCH_VERSION,
        g_FIRMWARE_LABEL            => g_FIRMWARE_LABEL,
        g_FIRMWARE_PERSONALITY      => g_FIRMWARE_PERSONALITY,
        g_FIRMWARE_BUILD_DATE       => g_FIRMWARE_BUILD_DATE,
        -- GENERICS for SHELL INTERACTION
        C_S_AXI_CONTROL_ADDR_WIDTH  => C_S_AXI_CONTROL_ADDR_WIDTH, -- integer := 7;
        C_S_AXI_CONTROL_DATA_WIDTH  => C_S_AXI_CONTROL_DATA_WIDTH, -- integer := 32;
    
        C_M_AXI_ADDR_WIDTH          => C_M_AXI_ADDR_WIDTH, -- integer := 64;
        C_M_AXI_DATA_WIDTH          => C_M_AXI_DATA_WIDTH, -- integer := 32;
        C_M_AXI_ID_WIDTH            => C_M_AXI_ID_WIDTH,   -- integer := 1;
    
        g_HBM_INTERFACES            => g_HBM_INTERFACES,
        g_HBM_AXI_ADDR_WIDTH        => g_HBM_AXI_ADDR_WIDTH,
        g_HBM_AXI_DATA_WIDTH        => g_HBM_AXI_DATA_WIDTH,
        g_HBM_AXI_ID_WIDTH          => g_HBM_AXI_ID_WIDTH) 
    PORT map (
        ap_clk => ap_clk, -- in std_logic;
        ap_rst_n => ap_rst_n, -- in std_logic;
        -----------------------------------------------------------------------
        -- Ports used for simulation only.
        --
        -- Received data from 100GE
        i_axis_tdata => rx_axis_tdata, -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
        i_axis_tkeep => rx_axis_tkeep,  -- one bit per byte in i_axi_tdata
        i_axis_tlast => rx_axis_tlast,
        i_axis_tuser => rx_axis_tuser, -- Timestamp for the packet.
        i_axis_tvalid => rx_axis_tvalid,
        -- Data to be transmitted on 100GE
        o_axis_tdata => tx_axis_tdata,  -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
        o_axis_tkeep => tx_axis_tkeep,  -- one bit per byte in i_axi_tdata
        o_axis_tlast => tx_axis_tlast,  -- out std_logic;                      
        o_axis_tuser => tx_axis_tuser,  -- out std_logic;  
        o_axis_tvalid => tx_axis_tvalid, -- out std_logic;
        i_axis_tready   => tx_axis_tready,  -- in std_logic;
        i_eth100g_clk   => eth100g_clk,     -- in std_logic;
        i_eth100g_locked => eth100g_locked, -- in std_logic;
        -- reset of the valid memory is in progress.
        o_validMemRstActive => open, -- out std_logic;
        -- Other signals to/from the timeslave 
        i_PTP_time_ARGs_clk   => PTP_time_ARGs_clk, -- in (79:0);
        o_eth100_reset_final  => eth100_reset_final, -- out std_logic;
        o_fec_enable_322m     => fec_enable_322m,    -- out std_logic;
        
        i_eth100G_rx_total_packets => eth100G_rx_total_packets, -- in (31:0);
        i_eth100G_rx_bad_fcs       => eth100G_rx_bad_fcs,       -- in (31:0);
        i_eth100G_rx_bad_code      => eth100G_rx_bad_code,      -- in (31:0);
        i_eth100G_tx_total_packets => eth100G_tx_total_packets, -- in (31:0);
        
        -- registers for the CMAC in Timeslave BD 
        o_cmac_mc_lite_mosi         => cmac_mc_lite_mosi,
        i_cmac_mc_lite_miso         => cmac_mc_lite_miso,
        -- registers in the timeslave core
        o_timeslave_mc_full_mosi    => timeslave_mc_full_mosi,
        i_timeslave_mc_full_miso    => timeslave_mc_full_miso,
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
        -- AXI4 master interface for accessing HBM
        HBM_axi_awvalid  =>  HBM_axi_awvalid,   
        HBM_axi_awready  =>  HBM_axi_awready,   
        HBM_axi_awaddr   =>  HBM_axi_awaddr,    
        HBM_axi_awid     =>  HBM_axi_awid,      
        HBM_axi_awlen    =>  HBM_axi_awlen,     
        HBM_axi_awsize   =>  HBM_axi_awsize,    
        HBM_axi_awburst  =>  HBM_axi_awburst,   
        HBM_axi_awlock   =>  HBM_axi_awlock,    
        HBM_axi_awcache  =>  HBM_axi_awcache,   
        HBM_axi_awprot   =>  HBM_axi_awprot,    
        HBM_axi_awqos    =>  HBM_axi_awqos,     
        HBM_axi_awregion =>  HBM_axi_awregion,  
    
        HBM_axi_wvalid   =>  HBM_axi_wvalid,    
        HBM_axi_wready   =>  HBM_axi_wready,    
        HBM_axi_wdata    =>  HBM_axi_wdata,     
        HBM_axi_wstrb    =>  HBM_axi_wstrb,     
        HBM_axi_wlast    =>  HBM_axi_wlast,     
        HBM_axi_bvalid   =>  HBM_axi_bvalid,    
        HBM_axi_bready   =>  HBM_axi_bready,    
        HBM_axi_bresp    =>  HBM_axi_bresp,     
        HBM_axi_bid      =>  HBM_axi_bid,       
        HBM_axi_arvalid  =>  HBM_axi_arvalid,   
        HBM_axi_arready  =>  HBM_axi_arready,   
        HBM_axi_araddr   =>  HBM_axi_araddr,    
        HBM_axi_arid     =>  HBM_axi_arid,      
        HBM_axi_arlen    =>  HBM_axi_arlen,     
        HBM_axi_arsize   =>  HBM_axi_arsize,    
        HBM_axi_arburst  =>  HBM_axi_arburst,   
        HBM_axi_arlock   =>  HBM_axi_arlock,    
        HBM_axi_arcache  =>  HBM_axi_arcache,   
        HBM_axi_arprot   =>  HBM_axi_arprot,    
        HBM_axi_arqos    =>  HBM_axi_arqos,     
        HBM_axi_arregion =>  HBM_axi_arregion,  
        HBM_axi_rvalid   =>  HBM_axi_rvalid,    
        HBM_axi_rready   =>  HBM_axi_rready,    
        HBM_axi_rdata    =>  HBM_axi_rdata,     
        HBM_axi_rlast    =>  HBM_axi_rlast,     
        HBM_axi_rid      =>  HBM_axi_rid,       
        HBM_axi_rresp    =>  HBM_axi_rresp,     
        
        -- GT pins
        -- clk_freerun is a 100MHz free running clock.
        clk_freerun    => clk_freerun,
        
        i_ct2_readout_start     => '0',
        i_ct2_readout_buffer    => '0',
        i_ct2_readout_frameCount => (others => '0'),
        i_input_HBM_reset       => '0'
    );
    
        
    ---------------------------------------------------------------------------------------
    -- vector mapping for HBM axi interfaces
    -- since vitis needs to have individual port names.
    ---------------------------------------------------------------------------------------
    
    HBM_axi_awvalid(0)  <=  m01_axi_awvalid;   
    HBM_axi_awready(0)  <=  m01_axi_awready;   
    HBM_axi_awaddr(0)   <=  m01_axi_awaddr;    
    HBM_axi_awid(0)     <=  m01_axi_awid;      
    HBM_axi_awlen(0)    <=  m01_axi_awlen;     
    HBM_axi_awsize(0)   <=  m01_axi_awsize;    
    HBM_axi_awburst(0)  <=  m01_axi_awburst;   
    HBM_axi_awlock(0)   <=  m01_axi_awlock;    
    HBM_axi_awcache(0)  <=  m01_axi_awcache;   
    HBM_axi_awprot(0)   <=  m01_axi_awprot;    
    HBM_axi_awqos(0)    <=  m01_axi_awqos;     
    HBM_axi_awregion(0) <=  m01_axi_awregion;  
    
    HBM_axi_wvalid(0)   <=  m01_axi_wvalid;    
    HBM_axi_wready(0)   <=  m01_axi_wready;    
    HBM_axi_wdata(0)    <=  m01_axi_wdata;     
    HBM_axi_wstrb(0)    <=  m01_axi_wstrb;     
    HBM_axi_wlast(0)    <=  m01_axi_wlast;     
    HBM_axi_bvalid(0)   <=  m01_axi_bvalid;    
    HBM_axi_bready(0)   <=  m01_axi_bready;    
    HBM_axi_bresp(0)    <=  m01_axi_bresp;     
    HBM_axi_bid(0)      <=  m01_axi_bid;       
    HBM_axi_arvalid(0)  <=  m01_axi_arvalid;   
    HBM_axi_arready(0)  <=  m01_axi_arready;   
    HBM_axi_araddr(0)   <=  m01_axi_araddr;    
    HBM_axi_arid(0)     <=  m01_axi_arid;      
    HBM_axi_arlen(0)    <=  m01_axi_arlen;     
    HBM_axi_arsize(0)   <=  m01_axi_arsize;    
    HBM_axi_arburst(0)  <=  m01_axi_arburst;   
    HBM_axi_arlock(0)   <=  m01_axi_arlock;    
    HBM_axi_arcache(0)  <=  m01_axi_arcache;   
    HBM_axi_arprot(0)   <=  m01_axi_arprot;    
    HBM_axi_arqos(0)    <=  m01_axi_arqos;     
    HBM_axi_arregion(0) <=  m01_axi_arregion;  
    HBM_axi_rvalid(0)   <=  m01_axi_rvalid;    
    HBM_axi_rready(0)   <=  m01_axi_rready;    
    HBM_axi_rdata(0)    <=  m01_axi_rdata;     
    HBM_axi_rlast(0)    <=  m01_axi_rlast;     
    HBM_axi_rid(0)      <=  m01_axi_rid;       
    HBM_axi_rresp(0)    <=  m01_axi_rresp;     
    
    ---------------------------------------------------------------------------------------
    -- 3 Gbyte HBM for fine channel data for input to the first correlator instance
    HBM_axi_awvalid(1)  <= m02_axi_awvalid;  
    HBM_axi_awready(1)  <= m02_axi_awready;   
    HBM_axi_awaddr(1)   <= m02_axi_awaddr;    
    HBM_axi_awid(1)     <= m02_axi_awid;      
    HBM_axi_awlen(1)    <= m02_axi_awlen;     
    HBM_axi_awsize(1)   <= m02_axi_awsize;    
    HBM_axi_awburst(1)  <= m02_axi_awburst;   
    HBM_axi_awlock(1)   <= m02_axi_awlock;    
    HBM_axi_awcache(1)  <= m02_axi_awcache;   
    HBM_axi_awprot(1)   <= m02_axi_awprot;    
    HBM_axi_awqos(1)    <= m02_axi_awqos;     
    HBM_axi_awregion(1) <= m02_axi_awregion;  
    
    HBM_axi_wvalid(1)   <= m02_axi_wvalid;    
    HBM_axi_wready(1)   <= m02_axi_wready;    
    HBM_axi_wdata(1)    <= m02_axi_wdata;     
    HBM_axi_wstrb(1)    <= m02_axi_wstrb;     
    HBM_axi_wlast(1)    <= m02_axi_wlast;     
    HBM_axi_bvalid(1)   <= m02_axi_bvalid;    
    HBM_axi_bready(1)   <= m02_axi_bready;    
    HBM_axi_bresp(1)    <= m02_axi_bresp;     
    HBM_axi_bid(1)      <= m02_axi_bid;       
    HBM_axi_arvalid(1)  <= m02_axi_arvalid;   
    HBM_axi_arready(1)  <= m02_axi_arready;   
    HBM_axi_araddr(1)   <= m02_axi_araddr;    
    HBM_axi_arid(1)     <= m02_axi_arid;      
    HBM_axi_arlen(1)    <= m02_axi_arlen;     
    HBM_axi_arsize(1)   <= m02_axi_arsize;    
    HBM_axi_arburst(1)  <= m02_axi_arburst;   
    HBM_axi_arlock(1)   <= m02_axi_arlock;    
    HBM_axi_arcache(1)  <= m02_axi_arcache;   
    HBM_axi_arprot(1)   <= m02_axi_arprot;    
    HBM_axi_arqos(1)    <= m02_axi_arqos;     
    HBM_axi_arregion(1) <= m02_axi_arregion;  
    HBM_axi_rvalid(1)   <= m02_axi_rvalid;    
    HBM_axi_rready(1)   <= m02_axi_rready;    
    HBM_axi_rdata(1)    <= m02_axi_rdata;     
    HBM_axi_rlast(1)    <= m02_axi_rlast;     
    HBM_axi_rid(1)      <= m02_axi_rid;       
    HBM_axi_rresp(1)    <= m02_axi_rresp;     
    ------------------------------------------------------------------------------------------
    -- 3 Gbyte HBM for fine channel data for input to the second correlator instance.
    HBM_axi_awvalid(2)  <= m03_axi_awvalid;  
    HBM_axi_awready(2)  <= m03_axi_awready;   
    HBM_axi_awaddr(2)   <= m03_axi_awaddr;    
    HBM_axi_awid(2)     <= m03_axi_awid;      
    HBM_axi_awlen(2)    <= m03_axi_awlen;     
    HBM_axi_awsize(2)   <= m03_axi_awsize;    
    HBM_axi_awburst(2)  <= m03_axi_awburst;   
    HBM_axi_awlock(2)   <= m03_axi_awlock;    
    HBM_axi_awcache(2)  <= m03_axi_awcache;   
    HBM_axi_awprot(2)   <= m03_axi_awprot;    
    HBM_axi_awqos(2)    <= m03_axi_awqos;     
    HBM_axi_awregion(2) <= m03_axi_awregion;  
    
    HBM_axi_wvalid(2)   <= m03_axi_wvalid;    
    HBM_axi_wready(2)   <= m03_axi_wready;    
    HBM_axi_wdata(2)    <= m03_axi_wdata;     
    HBM_axi_wstrb(2)    <= m03_axi_wstrb;     
    HBM_axi_wlast(2)    <= m03_axi_wlast;     
    HBM_axi_bvalid(2)   <= m03_axi_bvalid;    
    HBM_axi_bready(2)   <= m03_axi_bready;    
    HBM_axi_bresp(2)    <= m03_axi_bresp;     
    HBM_axi_bid(2)      <= m03_axi_bid;       
    HBM_axi_arvalid(2)  <= m03_axi_arvalid;   
    HBM_axi_arready(2)  <= m03_axi_arready;   
    HBM_axi_araddr(2)   <= m03_axi_araddr;    
    HBM_axi_arid(2)     <= m03_axi_arid;      
    HBM_axi_arlen(2)    <= m03_axi_arlen;     
    HBM_axi_arsize(2)   <= m03_axi_arsize;    
    HBM_axi_arburst(2)  <= m03_axi_arburst;   
    HBM_axi_arlock(2)   <= m03_axi_arlock;    
    HBM_axi_arcache(2)  <= m03_axi_arcache;   
    HBM_axi_arprot(2)   <= m03_axi_arprot;    
    HBM_axi_arqos(2)    <= m03_axi_arqos;     
    HBM_axi_arregion(2) <= m03_axi_arregion;  
    HBM_axi_rvalid(2)   <= m03_axi_rvalid;    
    HBM_axi_rready(2)   <= m03_axi_rready;    
    HBM_axi_rdata(2)    <= m03_axi_rdata;     
    HBM_axi_rlast(2)    <= m03_axi_rlast;     
    HBM_axi_rid(2)      <= m03_axi_rid;       
    HBM_axi_rresp(2)    <= m03_axi_rresp;   
    
    ------------------------------------------------------------------------------------------
    -- Visibilities HBM for first correlator instance
    HBM_axi_awvalid(3)  <= m04_axi_awvalid;  
    HBM_axi_awready(3)  <= m04_axi_awready;   
    HBM_axi_awaddr(3)   <= m04_axi_awaddr;    
    HBM_axi_awid(3)     <= m04_axi_awid;      
    HBM_axi_awlen(3)    <= m04_axi_awlen;     
    HBM_axi_awsize(3)   <= m04_axi_awsize;    
    HBM_axi_awburst(3)  <= m04_axi_awburst;   
    HBM_axi_awlock(3)   <= m04_axi_awlock;    
    HBM_axi_awcache(3)  <= m04_axi_awcache;   
    HBM_axi_awprot(3)   <= m04_axi_awprot;    
    HBM_axi_awqos(3)    <= m04_axi_awqos;     
    HBM_axi_awregion(3) <= m04_axi_awregion;  
    
    HBM_axi_wvalid(3)   <= m04_axi_wvalid;    
    HBM_axi_wready(3)   <= m04_axi_wready;    
    HBM_axi_wdata(3)    <= m04_axi_wdata;     
    HBM_axi_wstrb(3)    <= m04_axi_wstrb;     
    HBM_axi_wlast(3)    <= m04_axi_wlast;     
    HBM_axi_bvalid(3)   <= m04_axi_bvalid;    
    HBM_axi_bready(3)   <= m04_axi_bready;    
    HBM_axi_bresp(3)    <= m04_axi_bresp;     
    HBM_axi_bid(3)      <= m04_axi_bid;       
    HBM_axi_arvalid(3)  <= m04_axi_arvalid;   
    HBM_axi_arready(3)  <= m04_axi_arready;   
    HBM_axi_araddr(3)   <= m04_axi_araddr;    
    HBM_axi_arid(3)     <= m04_axi_arid;      
    HBM_axi_arlen(3)    <= m04_axi_arlen;     
    HBM_axi_arsize(3)   <= m04_axi_arsize;    
    HBM_axi_arburst(3)  <= m04_axi_arburst;   
    HBM_axi_arlock(3)   <= m04_axi_arlock;    
    HBM_axi_arcache(3)  <= m04_axi_arcache;   
    HBM_axi_arprot(3)   <= m04_axi_arprot;    
    HBM_axi_arqos(3)    <= m04_axi_arqos;     
    HBM_axi_arregion(3) <= m04_axi_arregion;  
    HBM_axi_rvalid(3)   <= m04_axi_rvalid;    
    HBM_axi_rready(3)   <= m04_axi_rready;    
    HBM_axi_rdata(3)    <= m04_axi_rdata;     
    HBM_axi_rlast(3)    <= m04_axi_rlast;     
    HBM_axi_rid(3)      <= m04_axi_rid;       
    HBM_axi_rresp(3)    <= m04_axi_rresp;
    
    ------------------------------------------------------------------------------------------
    -- Visibilities HBM for second correlator instance
    HBM_axi_awvalid(4)  <= m05_axi_awvalid;  
    HBM_axi_awready(4)  <= m05_axi_awready;   
    HBM_axi_awaddr(4)   <= m05_axi_awaddr;    
    HBM_axi_awid(4)     <= m05_axi_awid;      
    HBM_axi_awlen(4)    <= m05_axi_awlen;     
    HBM_axi_awsize(4)   <= m05_axi_awsize;    
    HBM_axi_awburst(4)  <= m05_axi_awburst;   
    HBM_axi_awlock(4)   <= m05_axi_awlock;    
    HBM_axi_awcache(4)  <= m05_axi_awcache;   
    HBM_axi_awprot(4)   <= m05_axi_awprot;    
    HBM_axi_awqos(4)    <= m05_axi_awqos;     
    HBM_axi_awregion(4) <= m05_axi_awregion;  
    HBM_axi_wvalid(4)   <= m05_axi_wvalid;    
    HBM_axi_wready(4)   <= m05_axi_wready;    
    HBM_axi_wdata(4)    <= m05_axi_wdata;     
    HBM_axi_wstrb(4)    <= m05_axi_wstrb;     
    HBM_axi_wlast(4)    <= m05_axi_wlast;     
    HBM_axi_bvalid(4)   <= m05_axi_bvalid;    
    HBM_axi_bready(4)   <= m05_axi_bready;    
    HBM_axi_bresp(4)    <= m05_axi_bresp;     
    HBM_axi_bid(4)      <= m05_axi_bid;       
    HBM_axi_arvalid(4)  <= m05_axi_arvalid;   
    HBM_axi_arready(4)  <= m05_axi_arready;   
    HBM_axi_araddr(4)   <= m05_axi_araddr;    
    HBM_axi_arid(4)     <= m05_axi_arid;      
    HBM_axi_arlen(4)    <= m05_axi_arlen;     
    HBM_axi_arsize(4)   <= m05_axi_arsize;    
    HBM_axi_arburst(4)  <= m05_axi_arburst;   
    HBM_axi_arlock(4)   <= m05_axi_arlock;    
    HBM_axi_arcache(4)  <= m05_axi_arcache;   
    HBM_axi_arprot(4)   <= m05_axi_arprot;    
    HBM_axi_arqos(4)    <= m05_axi_arqos;     
    HBM_axi_arregion(4) <= m05_axi_arregion;  
    HBM_axi_rvalid(4)   <= m05_axi_rvalid;    
    HBM_axi_rready(4)   <= m05_axi_rready;    
    HBM_axi_rdata(4)    <= m05_axi_rdata;     
    HBM_axi_rlast(4)    <= m05_axi_rlast;     
    HBM_axi_rid(4)      <= m05_axi_rid;       
    HBM_axi_rresp(4)    <= m05_axi_rresp;
    
END structure;
