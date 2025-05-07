-------------------------------------------------------------------------------
--
-- File Name: v80_top.vhd
-- Contributing Authors: Giles Babich
-- Template Rev: 1.0
--
-------------------------------------------------------------------------------

LIBRARY IEEE, UNISIM, common_lib, axi4_lib, technology_lib, util_lib, dsp_top_lib, correlator_lib;
library LFAADecode_lib, timingcontrol_lib, capture128bit_lib, versal_dcmac_lib, noc_lib, axi4_lib;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
--USE common_lib.common_pkg.ALL;
--USE common_lib.common_mem_pkg.ALL;
USE axi4_lib.axi4_lite_pkg.ALL;
--USE axi4_lib.axi4_stream_pkg.ALL;
USE axi4_lib.axi4_full_pkg.ALL;
--USE technology_lib.tech_mac_100g_pkg.ALL;
--USE technology_lib.technology_pkg.ALL;
--USE technology_lib.technology_select_pkg.all;
use correlator_lib.version_pkg.all;
USE versal_dcmac_lib.versal_dcmac_pkg.ALL;

USE UNISIM.vcomponents.all;
Library xpm;
use xpm.vcomponents.all;

-------------------------------------------------------------------------------
ENTITY v80_top IS
    generic (
        -- GLOBAL GENERICS for PERENTIE LOGIC
        g_DEBUG_ILA     : BOOLEAN := FALSE
    );
    PORT (
        CH0_DDR4_0_0_act_n : out STD_LOGIC_VECTOR ( 0 to 0 );
        CH0_DDR4_0_0_adr : out STD_LOGIC_VECTOR ( 16 downto 0 );
        CH0_DDR4_0_0_ba : out STD_LOGIC_VECTOR ( 1 downto 0 );
        CH0_DDR4_0_0_bg : out STD_LOGIC_VECTOR ( 0 to 0 );
        CH0_DDR4_0_0_ck_c : out STD_LOGIC_VECTOR ( 0 to 0 );
        CH0_DDR4_0_0_ck_t : out STD_LOGIC_VECTOR ( 0 to 0 );
        CH0_DDR4_0_0_cke : out STD_LOGIC_VECTOR ( 0 to 0 );
        CH0_DDR4_0_0_cs_n : out STD_LOGIC_VECTOR ( 0 to 0 );
        CH0_DDR4_0_0_dm_n : inout STD_LOGIC_VECTOR ( 8 downto 0 );
        CH0_DDR4_0_0_dq : inout STD_LOGIC_VECTOR ( 71 downto 0 );
        CH0_DDR4_0_0_dqs_c : inout STD_LOGIC_VECTOR ( 8 downto 0 );
        CH0_DDR4_0_0_dqs_t : inout STD_LOGIC_VECTOR ( 8 downto 0 );
        CH0_DDR4_0_0_odt : out STD_LOGIC_VECTOR ( 0 to 0 );
        CH0_DDR4_0_0_reset_n : out STD_LOGIC_VECTOR ( 0 to 0 );
        CH0_DDR4_0_1_act_n : out STD_LOGIC_VECTOR ( 0 to 0 );
        CH0_DDR4_0_1_adr : out STD_LOGIC_VECTOR ( 17 downto 0 );
        CH0_DDR4_0_1_alert_n : in STD_LOGIC_VECTOR ( 0 to 0 );
        CH0_DDR4_0_1_ba : out STD_LOGIC_VECTOR ( 1 downto 0 );
        CH0_DDR4_0_1_bg : out STD_LOGIC_VECTOR ( 1 downto 0 );
        CH0_DDR4_0_1_ck_c : out STD_LOGIC_VECTOR ( 0 to 0 );
        CH0_DDR4_0_1_ck_t : out STD_LOGIC_VECTOR ( 0 to 0 );
        CH0_DDR4_0_1_cke : out STD_LOGIC_VECTOR ( 0 to 0 );
        CH0_DDR4_0_1_cs_n : out STD_LOGIC_VECTOR ( 0 to 0 );
        CH0_DDR4_0_1_dq : inout STD_LOGIC_VECTOR ( 71 downto 0 );
        CH0_DDR4_0_1_dqs_c : inout STD_LOGIC_VECTOR ( 17 downto 0 );
        CH0_DDR4_0_1_dqs_t : inout STD_LOGIC_VECTOR ( 17 downto 0 );
        CH0_DDR4_0_1_odt : out STD_LOGIC_VECTOR ( 0 to 0 );
        CH0_DDR4_0_1_par : out STD_LOGIC_VECTOR ( 0 to 0 );
        CH0_DDR4_0_1_reset_n : out STD_LOGIC_VECTOR ( 0 to 0 );

        gt_pcie_refclk_clk_n : in STD_LOGIC;
        gt_pcie_refclk_clk_p : in STD_LOGIC;
        gt_pciea1_grx_n : in STD_LOGIC_VECTOR ( 7 downto 0 );
        gt_pciea1_grx_p : in STD_LOGIC_VECTOR ( 7 downto 0 );
        gt_pciea1_gtx_n : out STD_LOGIC_VECTOR ( 7 downto 0 );
        gt_pciea1_gtx_p : out STD_LOGIC_VECTOR ( 7 downto 0 );
        
        hbm_ref_clk_0_clk_n : in STD_LOGIC_VECTOR ( 0 to 0 );
        hbm_ref_clk_0_clk_p : in STD_LOGIC_VECTOR ( 0 to 0 );
        hbm_ref_clk_1_clk_n : in STD_LOGIC_VECTOR ( 0 to 0 );
        hbm_ref_clk_1_clk_p : in STD_LOGIC_VECTOR ( 0 to 0 );
        
        smbus_0_scl_io          : inout STD_LOGIC;
        smbus_0_sda_io          : inout STD_LOGIC;
        
        sys_clk0_0_clk_n        : in STD_LOGIC_VECTOR ( 0 to 0 );
        sys_clk0_0_clk_p        : in STD_LOGIC_VECTOR ( 0 to 0 );
        sys_clk0_1_clk_n        : in STD_LOGIC_VECTOR ( 0 to 0 );
        sys_clk0_1_clk_p        : in STD_LOGIC_VECTOR ( 0 to 0 );
        
        -- 100 MHz connected to GTY GTREF pin.
        mcio0_100mhz_clk_p      : in STD_LOGIC;
        mcio0_100mhz_clk_n      : in STD_LOGIC;
        
        mcio1_100mhz_clk_p      : in STD_LOGIC;
        mcio1_100mhz_clk_n      : in STD_LOGIC;
        
        mcio2_100mhz_clk_p      : in STD_LOGIC;
        mcio2_100mhz_clk_n      : in STD_LOGIC;
        
        ---------------------------------------------------------
        qsfp0_322mhz_clk_p      : in STD_LOGIC;
        qsfp0_322mhz_clk_n      : in STD_LOGIC;
        
        qsfp0_4x_grx_p          : in STD_LOGIC_VECTOR(3 downto 0);
        qsfp0_4x_grx_n          : in STD_LOGIC_VECTOR(3 downto 0);
        
        qsfp0_4x_gtx_p          : out STD_LOGIC_VECTOR(3 downto 0);
        qsfp0_4x_gtx_n          : out STD_LOGIC_VECTOR(3 downto 0);

        qsfp1_4x_grx_p          : in STD_LOGIC_VECTOR(3 downto 0);
        qsfp1_4x_grx_n          : in STD_LOGIC_VECTOR(3 downto 0);
        
        qsfp1_4x_gtx_p          : out STD_LOGIC_VECTOR(3 downto 0);
        qsfp1_4x_gtx_n          : out STD_LOGIC_VECTOR(3 downto 0)        
    );
END v80_top;

ARCHITECTURE structure OF v80_top IS

COMPONENT clk_system_base
    Port ( 
        clk_in_100      : in STD_LOGIC;
        clk_out_300     : out STD_LOGIC
    );
END COMPONENT;

component ila_0 is
Port ( 
    clk : in STD_LOGIC;
    probe0 : in STD_LOGIC_VECTOR ( 191 downto 0 )
);
end component;

---------------------------------------------------------------------------------------

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

signal eth100_reset_final : std_logic;
signal fec_enable_322m : std_logic;
signal eth100g_clk     : std_logic;
signal eth100g_locked  : std_logic;

signal eth100G_rx_total_packets : std_logic_vector(31 downto 0);
signal eth100G_rx_bad_fcs       : std_logic_vector(31 downto 0);
signal eth100G_rx_bad_code      : std_logic_vector(31 downto 0);
signal eth100G_tx_total_packets : std_logic_vector(31 downto 0);

signal Clock_100            : std_logic;
signal Clock_100_resetn     : std_logic;

signal Clock_100_GTY        : std_logic;
signal Clock_100_GTY_buf    : std_logic;

signal clock_300_rst        : std_logic := '1';
signal clock_300_rst_cnt    : unsigned(31 downto 0) := x"00001000";
signal clock_300            : std_logic;

signal dcmac_clk            : std_logic;
signal dcmac_locked         : std_logic_vector(1 downto 0);
signal dcmac_locked_300m    : std_logic;

signal dcmac_rx_data_0      : seg_streaming_axi;
signal dcmac_rx_data_1      : seg_streaming_axi;

signal dcmac_tx_data_0      : seg_streaming_axi;
signal dcmac_tx_data_1      : seg_streaming_axi;

signal dcmac_tx_ready_0     : std_logic;

begin

----------------------------------------------------------------
-- Clock from GTY GTREF

    MCIO_0_IBUFDS_GTE5_inst : IBUFDS_GTE5
    generic map (
        REFCLK_EN_TX_PATH     => '0',
        REFCLK_HROW_CK_SEL    => 0,      
        REFCLK_ICNTL_RX       => 0                                      
    )
    port map (
        O         => open,
        ODIV2     => Clock_100_GTY,
        CEB       => '0',             -- Zero = on
                      
        I         => mcio1_100mhz_clk_p,
        IB        => mcio1_100mhz_clk_n
    );
  
    BUFG_GT_inst : BUFG_GT
    generic map (
        SIM_DEVICE  => "VERSAL_HBM"
    )
    port map (
        CLR     => '0',
        CLRMASK => '0',
        CE      => '1',
        CEMASK  => '0',
        DIV     => "000",

        I       => Clock_100_GTY,
        O       => Clock_100_GTY_buf
    );

----------------------------------------------------------------
-- MMCM 
    i_system_clock : clk_system_base
    Port map( 
        clk_in_100      => Clock_100_GTY_buf,
        clk_out_300     => clock_300
    );
    
    reset_300_proc : process(clock_300)
    begin
        if rising_edge(clock_300) then
            if clock_300_rst_cnt = 1 then
                clock_300_rst       <= '0';
            else
                clock_300_rst_cnt   <= clock_300_rst_cnt - 1;
                clock_300_rst       <= '1';
            end if;
        end if;
    end process;
    
----------------------------------------------------------------
    i_dcmac_wrapper : entity versal_dcmac_lib.dcmac_wrapper
    Port map ( 
        i_clk                   => Clock_100_GTY_buf,
        i_reset                 => Clock_100_resetn,
        
        i_host_clk              => Clock_100,
   
        qsfp0_322mhz_clk_p      => qsfp0_322mhz_clk_p,
        qsfp0_322mhz_clk_n      => qsfp0_322mhz_clk_n,
        
        qsfp0_4x_grx_p          => qsfp0_4x_grx_p,
        qsfp0_4x_grx_n          => qsfp0_4x_grx_n,
        
        qsfp0_4x_gtx_p          => qsfp0_4x_gtx_p,
        qsfp0_4x_gtx_n          => qsfp0_4x_gtx_n,

        qsfp1_4x_grx_p          => qsfp1_4x_grx_p,
        qsfp1_4x_grx_n          => qsfp1_4x_grx_n,
        
        qsfp1_4x_gtx_p          => qsfp1_4x_gtx_p,
        qsfp1_4x_gtx_n          => qsfp1_4x_gtx_n,
        
        ------------------------
        o_dcmac_clk             => dcmac_clk,
        
        o_port_0_rx_bus         => dcmac_rx_data_0,
        o_port_1_rx_bus         => dcmac_rx_data_1,

        o_port_0_tx_bus         => dcmac_tx_data_0,
        o_port_0_tx_ready       => dcmac_tx_ready_0,
        o_port_1_tx_bus         => dcmac_tx_data_1,

        o_port_0_locked         => dcmac_locked(0),
        o_port_1_locked         => dcmac_locked(1)
    );
----------------------------------------------------------------
    i_v80_board : entity work.top_wrapper
    port map (

        gt_pcie_refclk_clk_n    => gt_pcie_refclk_clk_n,
        gt_pcie_refclk_clk_p    => gt_pcie_refclk_clk_p,
        gt_pciea1_grx_n         => gt_pciea1_grx_n,
        gt_pciea1_grx_p         => gt_pciea1_grx_p,
        gt_pciea1_gtx_n         => gt_pciea1_gtx_n,
        gt_pciea1_gtx_p         => gt_pciea1_gtx_p,
        
        CIPS_clk_100            => Clock_100,
               
        hbm_ref_clk_0_clk_n     => hbm_ref_clk_0_clk_n,
        hbm_ref_clk_0_clk_p     => hbm_ref_clk_0_clk_p,
        hbm_ref_clk_1_clk_n     => hbm_ref_clk_1_clk_n,
        hbm_ref_clk_1_clk_p     => hbm_ref_clk_1_clk_p,
        
        smbus_0_scl_io          => smbus_0_scl_io,
        smbus_0_sda_io          => smbus_0_sda_io,

        sys_clk0_0_clk_p        => sys_clk0_0_clk_p,
        sys_clk0_0_clk_n        => sys_clk0_0_clk_n,
        sys_clk0_1_clk_p        => sys_clk0_1_clk_p,
        sys_clk0_1_clk_n        => sys_clk0_1_clk_n,
        
        CH0_DDR4_0_0_dq         => CH0_DDR4_0_0_dq,
        CH0_DDR4_0_0_dqs_t      => CH0_DDR4_0_0_dqs_t,
        CH0_DDR4_0_0_dqs_c      => CH0_DDR4_0_0_dqs_c,
        CH0_DDR4_0_0_adr        => CH0_DDR4_0_0_adr,
        CH0_DDR4_0_0_ba         => CH0_DDR4_0_0_ba,
        CH0_DDR4_0_0_bg         => CH0_DDR4_0_0_bg,
        CH0_DDR4_0_0_act_n      => CH0_DDR4_0_0_act_n,
        CH0_DDR4_0_0_reset_n    => CH0_DDR4_0_0_reset_n,
        CH0_DDR4_0_0_ck_t       => CH0_DDR4_0_0_ck_t,
        CH0_DDR4_0_0_ck_c       => CH0_DDR4_0_0_ck_c,
        CH0_DDR4_0_0_cke        => CH0_DDR4_0_0_cke,
        CH0_DDR4_0_0_cs_n       => CH0_DDR4_0_0_cs_n,
        CH0_DDR4_0_0_dm_n       => CH0_DDR4_0_0_dm_n,
        CH0_DDR4_0_0_odt        => CH0_DDR4_0_0_odt,
        CH0_DDR4_0_1_dq         => CH0_DDR4_0_1_dq,
        CH0_DDR4_0_1_dqs_t      => CH0_DDR4_0_1_dqs_t,
        CH0_DDR4_0_1_dqs_c      => CH0_DDR4_0_1_dqs_c,
        CH0_DDR4_0_1_adr        => CH0_DDR4_0_1_adr,
        CH0_DDR4_0_1_ba         => CH0_DDR4_0_1_ba,
        CH0_DDR4_0_1_bg         => CH0_DDR4_0_1_bg,
        CH0_DDR4_0_1_act_n      => CH0_DDR4_0_1_act_n,
        CH0_DDR4_0_1_reset_n    => CH0_DDR4_0_1_reset_n,
        CH0_DDR4_0_1_ck_t       => CH0_DDR4_0_1_ck_t,
        CH0_DDR4_0_1_ck_c       => CH0_DDR4_0_1_ck_c,
        CH0_DDR4_0_1_cke        => CH0_DDR4_0_1_cke,
        CH0_DDR4_0_1_cs_n       => CH0_DDR4_0_1_cs_n,
        CH0_DDR4_0_1_odt        => CH0_DDR4_0_1_odt,
        CH0_DDR4_0_1_par        => CH0_DDR4_0_1_par,
        CH0_DDR4_0_1_alert_n    => CH0_DDR4_0_1_alert_n
    
      );
----------------------------------------------------------------    

i_dcmac_to_cmac : entity versal_dcmac_lib.segment_to_saxi 
    Port Map ( 
        -- Data in from the 100GE MAC
        i_MAC_clk               => dcmac_clk,
        i_MAC_rst               => NOT dcmac_locked(0),
        
        i_clk_300               => clock_300,
        i_clk_300_rst           => clock_300_rst,

        -- Streaming AXI interface - compatible with CMAC S_AXI
        -- RX
        o_rx_axis_tdata         => rx_axis_tdata,
        o_rx_axis_tkeep         => rx_axis_tkeep,
        o_rx_axis_tlast         => rx_axis_tlast,
        i_rx_axis_tready        => rx_axis_tready,
        o_rx_axis_tuser         => rx_axis_tuser,
        o_rx_axis_tvalid        => rx_axis_tvalid,
        
        o_dcmac_locked          => dcmac_locked_300m,

        -- Segmented Streaming AXI, 512
        i_data_to_receive       => dcmac_rx_data_0

    );

debug_gen : if g_DEBUG_ILA GENERATE
    debug_v80_top : ila_0 
    Port map ( 
        clk                     => clock_300,
        probe0(31 downto 0)     => std_logic_vector(clock_300_rst_cnt),
        probe0(32)              => clock_300_rst,
        probe0(191 downto 33)   => (others => '0')
    );
end generate;

i_correlator_core : entity correlator_lib.correlator_core
    generic map (
        -- GENERICS for use in the testbench 
        g_SIMULATION                => FALSE,  -- when true, the 100GE core is disabled and instead the lbus comes from the top level pins
        g_USE_META                  => FALSE,    -- Put meta data into the memory in place of the actual data, to make it easier to find bugs in the corner turn.
        -- GLOBAL GENERICS for PERENTIE LOGIC
        g_DEBUG_ILA                 => FALSE,

        g_FIRMWARE_MAJOR_VERSION    => C_FIRMWARE_MAJOR_VERSION,
        g_FIRMWARE_MINOR_VERSION    => C_FIRMWARE_MINOR_VERSION,
        g_FIRMWARE_PATCH_VERSION    => C_FIRMWARE_PATCH_VERSION
    )
    port map (
        clk_100         => Clock_100_GTY_buf,
        clk_100_rst     => '0',
        
        clk_300         => clock_300,
        clk_300_rst     => clock_300_rst,
        
        -- Received data from 100GE
        i_axis_tdata        => rx_axis_tdata,
        i_axis_tkeep        => rx_axis_tkeep,
        i_axis_tlast        => rx_axis_tlast,
        i_axis_tuser        => rx_axis_tuser,
        i_axis_tvalid       => rx_axis_tvalid,
        
        -- Data to be transmitted on 100GE
        o_dcmac_tx_data_0   => dcmac_tx_data_0,
        i_dcmac_tx_ready_0  => dcmac_tx_ready_0,
        
        i_eth100g_clk       => clock_300,
        i_eth100g_locked    => dcmac_locked_300m,
        -- reset of the valid memory is in progress.
        o_validMemRstActive => open,
        
        -- Other signals to/from the timeslave 
        i_PTP_time_ARGs_clk     => (others => '0'),
        o_eth100_reset_final    => open,
        o_fec_enable_322m       => open,
        
        i_eth100G_rx_total_packets  => (others => '0'),
        i_eth100G_rx_bad_fcs        => (others => '0'),
        i_eth100G_rx_bad_code       => (others => '0'),
        i_eth100G_tx_total_packets  => (others => '0'),
        
        
        -- trigger readout of the second corner turn data without waiting for the rest of the signal chain.
        -- used in testing with pre-load of the second corner turn HBM data
        i_ct2_readout_start         => '0',
        i_ct2_readout_buffer        => '0',
        i_ct2_readout_frameCount    => (others => '0'),
        
        i_input_HBM_reset           => '0'
    );

    
END structure;
