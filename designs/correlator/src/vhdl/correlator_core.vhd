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
LIBRARY xpm, spead_lib;

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
use correlator_lib.build_details_pkg.all;
USE work.correlator_bus_pkg.ALL;
USE work.correlator_system_reg_pkg.ALL;
USE UNISIM.vcomponents.all;

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
        -- GENERICS for SHELL INTERACTION
        C_S_AXI_CONTROL_ADDR_WIDTH : integer := 7;
        C_S_AXI_CONTROL_DATA_WIDTH : integer := 32;
        C_M_AXI_ADDR_WIDTH : integer := 64;
        C_M_AXI_DATA_WIDTH : integer := 32;
        C_M_AXI_ID_WIDTH   : integer := 1;
        -- All the HBM interfaces are the same width;
        -- Actual interfaces used are : 
        --  M01, 3 Gbytes HBM; first stage corner turn, between LFAA ingest and the filterbanks
        --  M02, 3 Gbytes HBM; Correlator HBM for fine channels going to the first correlator instance; buffer between the filterbanks and the correlator
        --  M03, 3 Gbytes HBM; Correlator HBM for fine channels going to the Second correlator instance; buffer between the filterbanks and the correlator
        --  M04, 512 Mbytes HBM; visibilities from first correlator instance
        --  M05, 512 Mbytes HBM; visibilities from second correlator instance
        g_HBM_INTERFACES : integer := 5;
        g_HBM_AXI_ADDR_WIDTH : integer := 64;
        g_HBM_AXI_DATA_WIDTH : integer := 512;
        g_HBM_AXI_ID_WIDTH   : integer := 1;
        -- Number of correlator blocks to instantiate.
        -- Set g_CORRELATORS to 0 and g_USE_DUMMY_FB to True for fast build times.
        g_CORRELATORS        : integer := 2;  -- 1 or 2
        g_USE_DUMMY_FB       : boolean := FALSE -- Should be FALSE for normal operation.
    );
    port (
        ap_clk : in std_logic;
        ap_rst_n : in std_logic;
        
        -- Received data from 100GE
        i_axis_tdata : in std_logic_vector(511 downto 0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
        i_axis_tkeep : in std_logic_vector(63 downto 0);  -- one bit per byte in i_axi_tdata
        i_axis_tlast : in std_logic;
        i_axis_tuser : in std_logic_vector(79 downto 0);  -- Timestamp for the packet.
        i_axis_tvalid : in std_logic;
        
        -- Data to be transmitted on 100GE
        o_axis_tdata : out std_logic_vector(511 downto 0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
        o_axis_tkeep : out std_logic_vector(63 downto 0);  -- one bit per byte in i_axi_tdata
        o_axis_tlast : out std_logic;                      
        o_axis_tuser : out std_logic;  
        o_axis_tvalid : out std_logic;
        i_axis_tready : in std_logic;
        
        i_eth100g_clk    : in std_logic;
        i_eth100g_locked : in std_logic;
        -- reset of the valid memory is in progress.
        o_validMemRstActive : out std_logic;
        -- Other signals to/from the timeslave 
        i_PTP_time_ARGs_clk  : std_logic_vector(79 downto 0);
        o_eth100_reset_final : out std_logic;
        o_fec_enable_322m    : out std_logic;
        
        i_eth100G_rx_total_packets : in std_logic_vector(31 downto 0);
        i_eth100G_rx_bad_fcs       : in std_logic_vector(31 downto 0);
        i_eth100G_rx_bad_code      : in std_logic_vector(31 downto 0);
        i_eth100G_tx_total_packets : in std_logic_vector(31 downto 0);
        
        -- registers for the CMAC in Timeslave BD 
        o_cmac_mc_lite_mosi : out t_axi4_lite_mosi; 
        i_cmac_mc_lite_miso : in t_axi4_lite_miso;
        -- registers in the timeslave core
        o_timeslave_mc_full_mosi : out t_axi4_full_mosi;
        i_timeslave_mc_full_miso : in t_axi4_full_miso;
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
  
        -- AXI4 interface for accessing registers : m00_axi
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
        -- AXI4 interfaces for accessing HBM
        -- 0 = 3 Gbytes for LFAA ingest corner turn 
        -- 1 = 3 Gbytes, buffer between the filterbanks and the correlator
        --     First half, for fine channels that go to the first correlator instance.
        -- 2 = 3 Gbytes, buffer between the filterbanks and the correlator
        --     second half, for fine channels that go to the second correlator instance.
        -- 3 = 0.5 Gbytes, Visibilities from First correlator instance;
        -- 4 = 0.5 Gbytes, Visibilities from Second correlator instance;
        HBM_axi_awvalid  : out std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awready  : in std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awaddr   : out t_slv_64_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awid     : out t_slv_1_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awlen    : out t_slv_8_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awsize   : out t_slv_3_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awburst  : out t_slv_2_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awlock   : out t_slv_2_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awcache  : out t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awprot   : out t_slv_3_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awqos    : out t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_awregion : out t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);
    
        HBM_axi_wvalid    : out std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_wready    : in std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_wdata     : out t_slv_512_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_wstrb     : out t_slv_64_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_wlast     : out std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_bvalid    : in std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_bready    : out std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_bresp     : in t_slv_2_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_bid       : in t_slv_1_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arvalid   : out std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arready   : in std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_araddr    : out t_slv_64_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arid      : out t_slv_1_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arlen     : out t_slv_8_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arsize    : out t_slv_3_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arburst   : out t_slv_2_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arlock    : out t_slv_2_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arcache   : out t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arprot    : out t_slv_3_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arqos     : out t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_arregion  : out t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_rvalid    : in std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_rready    : out std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_rdata     : in t_slv_512_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_vector(M01_AXI_DATA_WIDTH-1 downto 0);
        HBM_axi_rlast     : in std_logic_vector(g_HBM_INTERFACES-1 downto 0);
        HBM_axi_rid       : in t_slv_1_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_vector(M01_AXI_ID_WIDTH - 1 downto 0);
        HBM_axi_rresp     : in t_slv_2_arr(g_HBM_INTERFACES-1 downto 0); -- std_logic_vector(1 downto 0);
        
        -- GT pins
        --- clk_freerun is a 100MHz free running clock.        
        clk_freerun    : in std_logic;
        
        -- trigger readout of the second corner turn data without waiting for the rest of the signal chain.
        -- used in testing with pre-load of the second corner turn HBM data
        i_ct2_readout_start  : in std_logic;
        i_ct2_readout_buffer : in std_logic;
        i_ct2_readout_frameCount : in std_logic_vector(31 downto 0);
        
        i_input_HBM_reset       : in std_logic;
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

    -- 300MHz in, 100 MHz and 425 MHz out.
    component clk_gen100MHz
    port (
        clk100_out : out std_logic;
        clk425_out : out std_logic;       
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
    
    component ila_beamData
    port (
        clk : in std_logic;
        probe0 : in std_logic_vector(119 downto 0)); 
    end component;

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

    --signal eth100_tx_sosi : t_lbus_sosi;
    --signal eth100_tx_siso : t_lbus_siso;
    signal eth100_reset : std_logic := '0';
    signal dest_req : std_logic;
    signal eth100G_status_ap_clk : std_logic_vector(128 downto 0);
    signal eth100G_status_eth_clk : std_logic_vector(128 downto 0);
    signal eth100G_send, eth100G_rcv : std_logic;
    
    signal ap_clk_count : std_logic_vector(31 downto 0) := (others => '0');
    
    signal freerunCount : std_logic_vector(31 downto 0) := x"00000000";
    signal freerunSecCount : std_logic_vector(31 downto 0) := x"00000000";

    signal GTY_startup_rst : std_logic := '0';
    signal clk100 : std_logic;
    signal clk400 : std_logic;
    signal clk425 : std_logic;
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
    signal logic_HBM_axi_aw         : t_axi4_full_addr_arr(g_HBM_INTERFACES-1 downto 0);
    signal logic_HBM_axi_awreadyi   : std_logic_vector(g_HBM_INTERFACES-1 downto 0);

    signal logic_HBM_axi_w          : t_axi4_full_data_arr(g_HBM_INTERFACES-1 downto 0);
    signal logic_HBM_axi_wreadyi    : std_logic_vector(g_HBM_INTERFACES-1 downto 0);

    signal logic_HBM_axi_b          : t_axi4_full_b_arr(g_HBM_INTERFACES-1 downto 0);

    signal logic_HBM_axi_ar         : t_axi4_full_addr_arr(g_HBM_INTERFACES-1 downto 0);
    signal logic_HBM_axi_arreadyi   : std_logic_vector(g_HBM_INTERFACES-1 downto 0);    

    signal logic_HBM_axi_r          : t_axi4_full_data_arr(g_HBM_INTERFACES-1 downto 0);
    signal logic_HBM_axi_rreadyi    : std_logic_vector(g_HBM_INTERFACES-1 downto 0);

    -- HBM reset
    signal hbm_reset                : std_logic_vector(5 downto 0);
    signal hbm_status               : t_slv_8_arr(5 downto 0);
    signal hbm_rst_dbg              : t_slv_32_arr(5 downto 0);
    
    signal m01_axi_r, m01_axi_w   : t_axi4_full_data;

    signal HBM_axi_araddr256Mbytei, HBM_axi_awaddr256Mbytei : t_slv_8_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_aw : t_axi4_full_addr_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_awreadyi : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_w : t_axi4_full_data_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_wreadyi : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_b : t_axi4_full_b_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_ar : t_axi4_full_addr_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_arreadyi : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_r : t_axi4_full_data_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_rreadyi : std_logic_vector(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_araddri, HBM_axi_awaddri : t_slv_64_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_awsizei : t_slv_3_arr(g_HBM_INTERFACES-1 downto 0);
    
    signal HBM_axi_awbursti : t_slv_2_arr(g_HBM_INTERFACES - 1 downto 0);
    signal HBM_axi_breadyi : std_logic_vector(g_HBM_INTERFACES - 1 downto 0);
    signal HBM_axi_wstrbi : t_slv_64_arr(g_HBM_INTERFACES - 1 downto 0);
    signal HBM_axi_arsizei : t_slv_3_arr(g_HBM_INTERFACES - 1 downto 0);
    signal HBM_axi_arbursti : t_slv_2_arr(g_HBM_INTERFACES - 1 downto 0);
    signal HBM_shared : t_slv_64_arr(g_HBM_interfaces-1 downto 0);
    
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
    
    signal eth_disable, eth_disable_done : std_logic;
    signal i_axis_tdata_gated : std_logic_vector(511 downto 0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
    signal i_axis_tkeep_gated : std_logic_vector(63 downto 0);  -- one bit per byte in i_axi_tdata
    signal i_axis_tlast_gated : std_logic;
    signal i_axis_tuser_gated : std_logic_vector(79 downto 0); -- Timestamp for the packet.
    signal i_axis_tvalid_gated : std_logic;
    signal eth_disable_fsm_dbg : std_logic_vector(4 downto 0);
    signal hbm_reset_actual : std_logic_vector(5 downto 0);
    signal lfaaDecode_reset : std_logic;

    signal bytes_to_transmit    : STD_LOGIC_VECTOR(13 downto 0);
    signal data_to_player       : STD_LOGIC_VECTOR(511 downto 0);
    signal data_to_player_wr    : STD_LOGIC;
    signal data_to_player_rdy   : STD_LOGIC;
    
    signal eth100G_rst          : STD_LOGIC;

    
begin
    
    ---------------------------------------------------------------------------
    -- CLOCKING & RESETS  --
    ---------------------------------------------------------------------------

    u_get100 : clk_gen100MHz
    port map ( 
        clk100_out => clk100,  -- 100 MHz 
        clk425_out => clk425,  -- 425 MHz clock, used for the correlator.
        clk_in1 => clk_freerun  -- 100 MHz in
    );
    
    clk_gt_freerun_use <= clk_freerun; -- or use clk_gt_freerun, if we can convince vitis to connect clk_gt_freerun to anything... 
    
    u_get400 : clk_gen400MHz
    port map (
        clk400_out => clk400, -- 
        clk_in1    => clk_freerun  -- 100MHz clock in
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
        m01_shared => HBM_shared(0),  -- out(63:0)
        m02_shared => HBM_shared(1),  -- out(63:0)
        m03_shared => HBM_shared(2),  -- out(63:0)
        m04_shared => HBM_shared(3),  -- out(63:0)
        m05_shared => HBM_shared(4),  -- out(63:0)
        m06_shared => HBM_shared(5)   -- out(63:0)
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
    
    process(ap_clk)
    begin
        if rising_edge(ap_clk) then
            axi_dbg(0) <= mc_master_mosi.awvalid;
            axi_dbg(1) <= mc_master_mosi.wvalid;
            axi_dbg(2) <= mc_master_mosi.arvalid;
            axi_dbg(3) <= mc_master_miso.awready;
            axi_dbg(4) <= mc_master_miso.wready;
            axi_dbg(5) <= mc_master_miso.arready;
            axi_dbg(31 downto 6) <= (others => '0');
            axi_dbg(63 downto 32) <= mc_master_mosi.awaddr(31 downto 0);
            axi_dbg(95 downto 64) <= mc_master_mosi.wdata(31 downto 0);
            axi_dbg(127 downto 96) <= mc_master_mosi.araddr(31 downto 0);
            if ((mc_master_mosi.awvalid = '1' and  mc_master_miso.awready = '1') or
                (mc_master_mosi.wvalid = '1' and mc_master_miso.wready = '1') or
                (mc_master_mosi.arvalid = '1' and mc_master_miso.arready = '1')) then
                axi_dbg_valid <= '1';
            else
                axi_dbg_valid <= '0';
            end if;
        end if;
    end process;
    
    
    o_cmac_mc_lite_mosi <= mc_lite_mosi(c_cmac_lite_index);
    mc_lite_miso(c_cmac_lite_index) <= i_cmac_mc_lite_miso;

    o_timeslave_mc_full_mosi <= mc_full_mosi(c_timeslave_full_index);
    mc_full_miso(c_timeslave_full_index) <= i_timeslave_mc_full_miso;

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
    
    system_fields_ro.firmware_major_version <= g_FIRMWARE_MAJOR_VERSION;
    system_fields_ro.firmware_minor_version <= g_FIRMWARE_MINOR_VERSION;
    system_fields_ro.firmware_patch_version <= g_FIRMWARE_PATCH_VERSION;
    system_fields_ro.firmware_label         <= g_FIRMWARE_LABEL;
    system_fields_ro.firmware_personality   <= g_FIRMWARE_PERSONALITY;
    system_fields_ro.build_date             <= x"66666666";             -- Now under CI/CD, rely on the ARGs generation
    system_fields_ro.commit_short_hash      <= C_SHA_SHORT;
    system_fields_ro.build_type             <= C_BUILD_TYPE;

    system_fields_ro.sps_monitor_exists     <= '1';
    system_fields_ro.sps_monitor_time_since_write <= sps_monitor_time_since_write_clk_ap;  -- 16 bits
    system_fields_ro.sps_monitor_wr_addr <= sps_monitor_wr_addr_clk_ap; -- 32 bits
    
    

    sps_statsi : entity stats_lib.sps_statistics_top
    generic map (
        g_BUFFER_ADDR_BITS => 30,  -- integer := 30; -- number of bits in the HBM address; 30 = 2^30 bytes = 1 GByte
        g_USE_512BIT       => '1', -- std_logic := '0';    -- use 512 bit wide axi interface (otherwise use 256 bit)
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
        -- PTP time, on i_data_clk, bits 31:0 = ns (counts 0 to (10^9 -1))
        -- bits 79:32 = seconds
        i_ptp_time     => (others => '0'), --  in std_logic_vector(79 downto 0);
        -- milliseconds between writing summaries to the HBM
        i_period_ms        => sps_monitor_period_eth_clk, -- system_fields_rw.sps_monitor_period, -- : in std_logic_vector(15 downto 0);
        o_time_since_wr_ms => sps_monitor_time_since_write_eth_clk, --  out std_logic_vector(15 downto 0); 
        ----------------------------------------------------------------------------------
        -- Data out to the memory interface; This is the wdata portion of the AXI full bus.
        i_ap_clk        => ap_clk, -- in  std_logic;  -- Shared memory clock used to access the HBM.
        i_ap_rst        => '0', --  in  std_logic;
        o_axi_aw        => sps_mon_aw,      -- out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_axi_awready   => sps_mon_awready, -- in std_logic;
        o_axi_w         => sps_mon_w        -- out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0)) => o_m01_axi_w,    -- w data bus (.wvalid, .wdata, .wlast)
        i_axi_wready    => sps_mon_wready,  -- in std_logic;
        -----------------------------------------------------------------------------------
        -- Configuration and status
        o_status => open, -- out std_logic_vector(31 downto 0); -- ??? put something in here
        o_wrAddr => sps_monitor_wr_addr -- out std_logic_vector(31 downto 0)  -- Most recent address written to in the HBM
    );
    
    
    
    
    

    system_fields_ro.no_of_correlator_instances <= std_logic_vector(to_unsigned(g_CORRELATORS , 4));
    
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
        dest_out => o_fec_enable_322m, -- 1-bit output: src_in synchronized to the destination clock domain. This output is registered.
        dest_clk => i_eth100G_clk, -- 1-bit input: Clock signal for the destination clock domain.
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
    
    --------------------------------------------------------------------------------------------------
    -- 100G PORT A or Upper for U55C
    locked_100G_port_a : xpm_cdc_single
    generic map (
        DEST_SYNC_FF    => 2,   
        INIT_SYNC_FF    => 0,   
        SIM_ASSERT_CHK  => 0, 
        SRC_INPUT_REG   => 1   
    )
    port map (
        dest_out    => system_fields_ro.eth100G_locked,
        dest_clk    => ap_clk,
        src_clk     => i_eth100G_clk,   
        src_in      => i_eth100G_locked 
    );

    system_fields_ro.eth100G_rx_total_packets       <= i_eth100G_rx_total_packets;
    system_fields_ro.eth100G_rx_bad_fcs             <= i_eth100G_rx_bad_fcs;
    system_fields_ro.eth100G_rx_bad_code            <= i_eth100G_rx_bad_code;
    system_fields_ro.eth100G_tx_total_packets       <= i_eth100G_tx_total_packets;
    system_fields_ro.eth100g_ptp_nano_seconds       <= i_PTP_time_ARGs_clk(31 downto 0);
    system_fields_ro.eth100g_ptp_lower_seconds      <= i_PTP_time_ARGs_clk(63 downto 32);
    system_fields_ro.eth100g_ptp_upper_seconds      <= x"0000" & i_PTP_time_ARGs_clk(79 downto 64);
    
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
            
            o_eth100_reset_final <= eth100_reset or GTY_startup_rst or fec_enable_reset;
            
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
    
    
    process(i_eth100G_clk)
    begin
        if rising_edge(i_eth100G_clk) then
            if (unsigned(eth100G_uptime) < 322000000) then
                eth100G_uptime <= std_logic_vector(unsigned(eth100G_uptime) + 1);
            else
                eth100G_uptime <= (others => '0');
                eth100G_seconds <= std_logic_vector(unsigned(eth100G_seconds) + 1);
            end if;
            
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Packet Player (moved outside DSP to accomodate US and VERSAL MACs)
    -- S_AXI packet player config    
    cmac_saxi_and_cdc : entity spead_lib.packet_player generic map (
            g_DEBUG_ILA             => g_DEBUG_ILA,
            LBUS_TO_CMAC_INUSE      => FALSE,
            PLAYER_CDC_FIFO_DEPTH   => 512   
        )
        port map ( 
            i_clk                   => ap_clk,
            i_clk_reset             => ap_rst,
        
            i_cmac_clk              => i_eth100G_clk,
            i_cmac_clk_rst          => eth100G_rst,
            
            i_bytes_to_transmit     => bytes_to_transmit,
            i_data_to_player        => data_to_player,
            i_data_to_player_wr     => data_to_player_wr,
            o_data_to_player_rdy    => data_to_player_rdy,
            
            -- streaming AXI to CMAC
            o_tx_axis_tdata         => o_axis_tdata,
            o_tx_axis_tkeep         => o_axis_tkeep,
            o_tx_axis_tvalid        => o_axis_tvalid,
            o_tx_axis_tlast         => o_axis_tlast,
            o_tx_axis_tuser         => o_axis_tuser,
            i_tx_axis_tready        => i_axis_tready,
            
            -- LBUS to CMAC
            -- o_data_to_transmit      : out t_lbus_sosi;
            i_data_to_transmit_ctl  => c_lbus_siso_rst
        );

    CMAC_100G_reset_proc : process(i_eth100G_clk)
    begin
        if rising_edge(i_eth100G_clk) then
            eth100G_rst     <= NOT i_eth100G_locked;
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
        g_USE_DUMMY_FB          => g_USE_DUMMY_FB
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
        
        i_clk_100GE      => i_eth100G_clk,      -- in std_logic;
        i_eth100G_locked => i_eth100G_locked,
        -- Filterbank processing clock, 450 MHz
        i_clk425 => clk425,  -- in std_logic;
        i_clk400 => clk400,  -- in std_logic;
        -----------------------------------------------------------------------
        -- reset of the valid memory is in progress.
        o_validMemRstActive => o_validMemRstActive,
        -----------------------------------------------------------------------
        -- AXI slave interfaces for modules
        i_MACE_clk  => ap_clk, -- in std_logic;
        i_MACE_rst  => ap_rst, -- in std_logic;
        -- LFAADecode, lite + full slave
        i_LFAALite_axi_mosi => mc_lite_mosi(c_LFAADecode100g_lite_index), -- in t_axi4_lite_mosi; 
        o_LFAALite_axi_miso => mc_lite_miso(c_LFAADecode100g_lite_index), -- out t_axi4_lite_miso;
        i_LFAAFull_axi_mosi => mc_full_mosi(c_lfaadecode100g_full_index), -- in  t_axi4_full_mosi;
        o_LFAAFull_axi_miso => mc_full_miso(c_lfaadecode100g_full_index), -- out t_axi4_full_miso;
        -- Corner Turn between LFAA Ingest and the filterbanks.
        i_LFAA_CT_axi_mosi => mc_lite_mosi(c_corr_ct1_lite_index), -- in  t_axi4_lite_mosi;
        o_LFAA_CT_axi_miso => mc_lite_miso(c_corr_ct1_lite_index), -- out t_axi4_lite_miso;
        i_poly_full_axi_mosi => mc_full_mosi(c_corr_ct1_full_index),
        o_poly_full_axi_miso => mc_full_miso(c_corr_ct1_full_index),
        -- Filterbanks
        i_FB_axi_mosi => mc_lite_mosi(c_filterbanks_lite_index), -- in  t_axi4_lite_mosi;
        o_FB_axi_miso => mc_lite_miso(c_filterbanks_lite_index), -- out t_axi4_lite_miso;
        -- Corner turn between filterbanks and the correlator
        i_cor_CT_axi_mosi => mc_lite_mosi(c_corr_ct2_lite_index), -- in  t_axi4_lite_mosi;
        o_cor_CT_axi_miso => mc_lite_miso(c_corr_ct2_lite_index), -- out t_axi4_lite_miso;
        -- correlator
        i_cor_axi_mosi => mc_lite_mosi(c_config_lite_index), -- in  t_axi4_lite_mosi;
        o_cor_axi_miso => mc_lite_miso(c_config_lite_index), -- out t_axi4_lite_miso;
        -- Output HBM
        i_spead_hbm_rd_lite_axi_mosi(0) => mc_lite_mosi(c_hbm_rd_debug_lite_index),
        i_spead_hbm_rd_lite_axi_mosi(1) => mc_lite_mosi(c_hbm_rd_debug_2_lite_index),
        
        o_spead_hbm_rd_lite_axi_miso(0) => mc_lite_miso(c_hbm_rd_debug_lite_index),
        o_spead_hbm_rd_lite_axi_miso(1) => mc_lite_miso(c_hbm_rd_debug_2_lite_index),
        
        i_spead_hbm_rd_full_axi_mosi(0) => mc_full_mosi(c_hbm_rd_debug_full_index),
        i_spead_hbm_rd_full_axi_mosi(1) => mc_full_mosi(c_hbm_rd_debug_2_full_index),
        
        o_spead_hbm_rd_full_axi_miso(0) => mc_full_miso(c_hbm_rd_debug_full_index),
        o_spead_hbm_rd_full_axi_miso(1) => mc_full_miso(c_hbm_rd_debug_2_full_index),

        -- SDP SPEAD
        i_spead_lite_axi_mosi(0)    => mc_lite_mosi(c_spead_sdp_lite_index),
        i_spead_lite_axi_mosi(1)    => mc_lite_mosi(c_spead_sdp_2_lite_index),

        o_spead_lite_axi_miso(0)    => mc_lite_miso(c_spead_sdp_lite_index),
        o_spead_lite_axi_miso(1)    => mc_lite_miso(c_spead_sdp_2_lite_index),

        i_spead_full_axi_mosi(0)    => mc_full_mosi(c_spead_sdp_full_index), 
        i_spead_full_axi_mosi(1)    => mc_full_mosi(c_spead_sdp_2_full_index), 

        o_spead_full_axi_miso(0)    => mc_full_miso(c_spead_sdp_full_index),
        o_spead_full_axi_miso(1)    => mc_full_miso(c_spead_sdp_2_full_index),

        -----------------------------------------------------------------------
        -- AXI interfaces to HBM memory (5 interfaces used)
        -- write address buses : out t_axi4_full_addr_arr(4:0)(.valid, .addr(39:0), .len(7:0))
        o_HBM_axi_aw      => logic_HBM_axi_aw_sigproc,
        i_HBM_axi_awready => logic_HBM_axi_awreadyi_sigproc, -- in std_logic_vector(5:0);
        -- w data buses : out t_axi4_full_data_arr(5:0)(.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_w       => logic_HBM_axi_w_sigproc,        
        i_HBM_axi_wready  => logic_HBM_axi_wreadyi_sigproc,  -- in std_logic_vector(5:0);
        -- write response bus : in t_axi4_full_b_arr(5:0)(.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        i_HBM_axi_b       => logic_HBM_axi_b,
        -- read address bus : out t_axi4_full_addr_arr(5:0)(.valid, .addr(39:0), .len(7:0))
        o_HBM_axi_ar      => logic_HBM_axi_ar,
        i_HBM_axi_arready => logic_HBM_axi_arreadyi, -- in std_logic_vector(5:0);
        -- r data bus : in t_axi4_full_data_arr(5:0)(.valid, .data(511:0), .last, .resp(1:0))
        i_HBM_axi_r       => logic_HBM_axi_r,
        o_HBM_axi_rready  => logic_HBM_axi_rreadyi,  -- out std_logic_vector(5:0);
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
        o_hbm_reset    => hbm_reset,
        i_hbm_status   => hbm_status,
        i_hbm_rst_dbg  => hbm_rst_dbg,
        i_hbm_reset_final => eth_disable_done,   -- 1 bit
        i_eth_disable_fsm_dbg => eth_disable_fsm_dbg, -- 5 bits
        i_axi_dbg => axi_dbg, -- 128 bits
        i_axi_dbg_valid => axi_dbg_valid,
        -- 100GE input disable
        o_lfaaDecode_reset => lfaaDecode_reset,
        i_ethDisable_done => eth_disable_done
    );
    
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
        i_ap_clk  => ap_clk,      --  in std_logic;
        i_reset   => eth_disable, --  in std_logic;  
        o_reset   => eth_disable_done,     --  out std_logic; -- Goes high following i_reset after the 100G ethernet has been blocked
        o_fsm_dbg => eth_disable_fsm_dbg, --  out std_logic_vector(4 downto 0); -- fsm state 
        -----------------------------------------------------
        -- Everything else is on i_eth_clk
        i_eth_clk    => i_eth100G_clk, --  in std_logic;
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
    
    -- register for SLR crossing
    process(ap_clk)
    begin
        if rising_edge(ap_clk) then
            hbm_reset_actual(0) <= hbm_reset(0);
            hbm_reset_actual(1) <= hbm_reset(1);
            hbm_reset_actual(2) <= hbm_reset(2);
            hbm_reset_actual(3) <= hbm_reset(3);
            hbm_reset_actual(4) <= hbm_reset(4);
            hbm_reset_actual(5) <= '0'; -- don't reset the HBM for the ILA, want to be able to see what is happening.
        end if;
    end process;
    
    ---------------------------------------------------------------------
    -- Fill out the missing (superfluous) bits of the axi HBM busses, and add an AXI pipeline stage.    
    
    -- Select either HBM ILA or the SPS monitor
    hbm_ila_geni : if (not g_INCLUDE_SPS_MONITOR) generate
        
        logic_HBM_axi_aw <= logic_HBM_axi_aw_sigproc;
        logic_HBM_axi_w <= logic_HBM_axi_w_sigproc;
        
    end generate;
    
    hbm_sps_mon_gen : if g_INCLUDE_SPS_MONITOR generate
        logic_HBM_axi_aw(4 downto 0) <= logic_HBM_axi_aw_sigproc(4 downto 0);
        logic_HBM_axi_aw(5) <= sps_mon_aw;
        logic_HBM_axi_w(4 downto 0) <= logic_HBM_axi_w_sigproc(4 downto 0);
        logic_HBM_axi_w(5) <= sps_mon_w;
    end generate;
    
    
    
    axi_HBM_gen : for i in 0 to 5 generate

        -- reset blocks for HBM interfaces.
        hbm_resetter : entity correlator_lib.hbm_axi_reset_handler 
            generic map (
                DEBUG_ILA               => FALSE )
            port map ( 
                i_clk                   => ap_clk,
                i_reset                 => ap_rst,
        
                i_logic_reset           => hbm_reset_actual(i), -- hbm_reset_combined(i),
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
        
                i_hbm_axi_awready       => HBM_axi_awreadyi(i),
        
                -- DATA
                o_hbm_axi_w_data        => HBM_axi_w(i).data,
                o_hbm_axi_w_resp        => HBM_axi_w(i).resp,
                o_hbm_axi_w_last        => HBM_axi_w(i).last,
                o_hbm_axi_w_valid       => HBM_axi_w(i).valid,
                i_hbm_axi_wready        => HBM_axi_wreadyi(i),
        
                i_hbm_axi_b_valid       => HBM_axi_b(i).valid,
                i_hbm_axi_b_resp        => HBM_axi_b(i).resp,
                
                -- reading from HBM
                -- ADDR
                o_hbm_axi_ar_addr       => HBM_axi_ar(i).addr,
                o_hbm_axi_ar_len        => HBM_axi_ar(i).len,
                o_hbm_axi_ar_valid      => HBM_axi_ar(i).valid,
                i_hbm_axi_arready       => HBM_axi_arreadyi(i),
        
                -- DATA
                i_hbm_axi_r_data        => HBM_axi_r(i).data,
                i_hbm_axi_r_resp        => HBM_axi_r(i).resp,
                i_hbm_axi_r_last        => HBM_axi_r(i).last,
                i_hbm_axi_r_valid       => HBM_axi_r(i).valid,
                o_hbm_axi_rready        => HBM_axi_rreadyi(i),
        
                -----------------------------------------------------
                -- To Logic
                -- ADDR
                i_logic_axi_aw_addr     => logic_HBM_axi_aw(i).addr,
                i_logic_axi_aw_len      => logic_HBM_axi_aw(i).len,
                i_logic_axi_aw_valid    => logic_HBM_axi_aw(i).valid,
        
                o_logic_axi_awready     => logic_HBM_axi_awreadyi(i),
        
                -- DATA
                i_logic_axi_w_data      => logic_HBM_axi_w(i).data,
                i_logic_axi_w_resp      => logic_HBM_axi_w(i).resp,
                i_logic_axi_w_last      => logic_HBM_axi_w(i).last,
                i_logic_axi_w_valid     => logic_HBM_axi_w(i).valid,
                o_logic_axi_wready      => logic_HBM_axi_wreadyi(i),
        
                o_logic_axi_b_valid     => logic_HBM_axi_b(i).valid,
                o_logic_axi_b_resp      => logic_HBM_axi_b(i).resp,
                
                -- reading from logic
                -- ADDR
                i_logic_axi_ar_addr     => logic_HBM_axi_ar(i).addr,
                i_logic_axi_ar_len      => logic_HBM_axi_ar(i).len,
                i_logic_axi_ar_valid    => logic_HBM_axi_ar(i).valid,
                o_logic_axi_arready     => logic_HBM_axi_arreadyi(i),
        
                -- DATA
                o_logic_axi_r_data      => logic_HBM_axi_r(i).data,
                o_logic_axi_r_resp      => logic_HBM_axi_r(i).resp,
                o_logic_axi_r_last      => logic_HBM_axi_r(i).last,
                o_logic_axi_r_valid     => logic_HBM_axi_r(i).valid,
                i_logic_axi_rready      => logic_HBM_axi_rreadyi(i)
            
            );
        
        -- ar and aw addresses need to be set to the correct offset within the HBM
        HBM_axi_araddr256Mbytei(i) <= HBM_axi_ar(i).addr(35 downto 28); -- 8 bit address of 256MByte pieces, within 64 Gbytes ((35:0) addresses 64 Gbytes)
        HBM_axi_araddri(i)(63 downto 36) <= HBM_shared(i)(63 downto 36);
        HBM_axi_araddri(i)(35 downto 28) <= std_logic_vector(unsigned(HBM_shared(i)(35 downto 28)) + unsigned(HBM_axi_araddr256Mbytei(i)));
        HBM_axi_araddri(i)(27 downto 0) <= HBM_axi_ar(i).addr(27 downto 0);
        
        HBM_axi_awaddr256Mbytei(i) <= HBM_axi_aw(i).addr(35 downto 28); -- 8 bit address of 256MByte pieces, within 64 Gbytes ((35:0) addresses 64 Gbytes)
        HBM_axi_awaddri(i)(63 downto 36) <= HBM_shared(i)(63 downto 36);
        HBM_axi_awaddri(i)(35 downto 28) <= std_logic_vector(unsigned(HBM_shared(i)(35 downto 28)) + unsigned(HBM_axi_awaddr256Mbytei(i)));
        HBM_axi_awaddri(i)(27 downto 0) <= HBM_axi_aw(i).addr(27 downto 0);
        
        -- register slice ports that have a fixed value.
        HBM_axi_awsizei(i)  <= get_axi_size(g_HBM_AXI_DATA_WIDTH);
        HBM_axi_awbursti(i) <= "01";   -- "01" indicates incrementing addresses for each beat in the burst.  -- out std_logic_vector(1 downto 0);
        HBM_axi_breadyi(i)  <= '1';  -- Always accept acknowledgement of write transactions. -- out std_logic;
        HBM_axi_wstrbi(i)  <= (others => '1');  -- We always write all bytes in the bus. --  out std_logic_vector(63 downto 0);
        HBM_axi_arsizei(i)  <= get_axi_size(g_HBM_AXI_DATA_WIDTH);   -- 6 = 64 bytes per beat = 512 bit wide bus. -- out std_logic_vector(2 downto 0);
        HBM_axi_arbursti(i) <= "01";    -- "01" = incrementing address for each beat in the burst. -- out std_logic_vector(1 downto 0);
        
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
        
        -- Register slice for the HBM AXI interfaces
        HBM_reg_slice : axi_reg_slice512_LLFFL
        port map (
            aclk    => ap_clk, --  IN STD_LOGIC;
            aresetn => ap_rst_n, --  IN STD_LOGIC;
            -- 
            s_axi_awaddr   => HBM_axi_awaddri(i), -- IN STD_LOGIC_VECTOR(63 DOWNTO 0);
            s_axi_awlen    => HBM_axi_aw(i).len,  -- IN STD_LOGIC_VECTOR(7 DOWNTO 0);
            s_axi_awsize   => HBM_axi_awsizei(i), -- IN STD_LOGIC_VECTOR(2 DOWNTO 0);
            s_axi_awburst  => HBM_axi_awbursti(i), -- IN STD_LOGIC_VECTOR(1 DOWNTO 0);
            s_axi_awvalid  => HBM_axi_aw(i).valid,  -- IN STD_LOGIC;
            s_axi_awready  => HBM_axi_awreadyi(i),  -- OUT STD_LOGIC;
            s_axi_wdata    => HBM_axi_w(i).data,    -- IN STD_LOGIC_VECTOR(511 DOWNTO 0);
            s_axi_wstrb    => HBM_axi_wstrbi(i),    -- IN STD_LOGIC_VECTOR(63 DOWNTO 0);
            s_axi_wlast    => HBM_axi_w(i).last,    -- IN STD_LOGIC;
            s_axi_wvalid   => HBM_axi_w(i).valid,   -- IN STD_LOGIC;
            s_axi_wready   => HBM_axi_wreadyi(i),   -- OUT STD_LOGIC;
            s_axi_bresp    => HBM_axi_b(i).resp,    --  OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
            s_axi_bvalid   => HBM_axi_b(i).valid,   -- OUT STD_LOGIC;
            s_axi_bready   => HBM_axi_breadyi(i),   -- IN STD_LOGIC;
            s_axi_araddr   => HBM_axi_araddri(i),   -- IN STD_LOGIC_VECTOR(63 DOWNTO 0);
            s_axi_arlen    => HBM_axi_ar(i).len,    -- IN STD_LOGIC_VECTOR(7 DOWNTO 0);
            s_axi_arsize   => HBM_axi_arsizei(i),   -- IN STD_LOGIC_VECTOR(2 DOWNTO 0);
            s_axi_arburst  => HBM_axi_arbursti(i),  -- IN STD_LOGIC_VECTOR(1 DOWNTO 0);
            s_axi_arvalid  => HBM_axi_ar(i).valid,  -- IN STD_LOGIC;
            s_axi_arready  => HBM_axi_arreadyi(i),  -- OUT STD_LOGIC;
            s_axi_rdata    => HBM_axi_r(i).data,    -- OUT STD_LOGIC_VECTOR(511 DOWNTO 0);
            s_axi_rresp    => HBM_axi_r(i).resp,    -- OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
            s_axi_rlast    => HBM_axi_r(i).last,    -- OUT STD_LOGIC;
            s_axi_rvalid   => HBM_axi_r(i).valid,   -- OUT STD_LOGIC;
            s_axi_rready   => HBM_axi_rreadyi(i),   -- IN STD_LOGIC;
            --
            m_axi_awaddr   => HBM_axi_awaddr(i), -- OUT STD_LOGIC_VECTOR(63 DOWNTO 0);
            m_axi_awlen    => HBM_axi_awlen(i),  -- OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
            m_axi_awsize   => HBM_axi_awsize(i), -- OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
            m_axi_awburst  => HBM_axi_awburst(i), -- OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
            m_axi_awvalid  => HBM_axi_awvalid(i),  -- OUT STD_LOGIC;
            m_axi_awready  => HBM_axi_awready(i),  -- IN STD_LOGIC;
            m_axi_wdata    => HBM_axi_wdata(i),    -- OUT STD_LOGIC_VECTOR(511 DOWNTO 0);
            m_axi_wstrb    => HBM_axi_wstrb(i),    -- OUT STD_LOGIC_VECTOR(63 DOWNTO 0);
            m_axi_wlast    => HBM_axi_wlast(i),    -- OUT STD_LOGIC;
            m_axi_wvalid   => HBM_axi_wvalid(i),   -- OUT STD_LOGIC;
            m_axi_wready   => HBM_axi_wready(i),   -- IN STD_LOGIC;
            m_axi_bresp    => HBM_axi_bresp(i),    -- IN STD_LOGIC_VECTOR(1 DOWNTO 0);
            m_axi_bvalid   => HBM_axi_bvalid(i),   -- IN STD_LOGIC;
            m_axi_bready   => HBM_axi_bready(i),   -- OUT STD_LOGIC;
            m_axi_araddr   => HBM_axi_araddr(i),   -- OUT STD_LOGIC_VECTOR(63 DOWNTO 0);
            m_axi_arlen    => HBM_axi_arlen(i),    -- OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
            m_axi_arsize   => HBM_axi_arsize(i),   -- OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
            m_axi_arburst  => HBM_axi_arburst(i),  -- OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
           
            m_axi_arvalid  => HBM_axi_arvalid(i),  -- OUT STD_LOGIC;
            m_axi_arready  => HBM_axi_arready(i),  -- IN STD_LOGIC;
            m_axi_rdata    => HBM_axi_rdata(i),    -- IN STD_LOGIC_VECTOR(511 DOWNTO 0);
            m_axi_rresp    => HBM_axi_rresp(i),    -- IN STD_LOGIC_VECTOR(1 DOWNTO 0);
            m_axi_rlast    => HBM_axi_rlast(i),    -- IN STD_LOGIC;
            m_axi_rvalid   => HBM_axi_rvalid(i),   -- IN STD_LOGIC;
            m_axi_rready   => HBM_axi_rready(i)    --: OUT STD_LOGIC
        );
        
        
    end generate;
    
    
--    u_othermem_ila : ila_0
--    port map (
--        clk => ap_clk,
--        probe0(39 downto 0) => HBM_shared(5)(39 downto 0),
--        probe0(79 downto 40) => HBM_axi_awaddr(5)(39 downto 0),
--        probe0(80) => HBM_axi_awvalid(5),
--        probe0(81) => HBM_axi_awready(5),
--        probe0(89 downto 82) => HBM_axi_awlen(5)(7 downto 0),
--        probe0(90) => HBM_axi_wvalid(5),
--        probe0(91) => HBM_axi_wready(5),
--        probe0(92) => HBM_axi_wlast(5),
--        probe0(94 downto 93) => HBM_axi_bresp(5)(1 downto 0),
--        probe0(95) => HBM_axi_bvalid(5),
--        probe0(96) => HBM_axi_bready(5),
--        probe0(99 downto 97) => "000",
--        probe0(163 downto 100) => HBM_axi_wdata(5)(63 downto 0),
--        probe0(171 downto 164) => hbm_status(5),
--        probe0(191 downto 172) => (others => '0')
--    );
    

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
