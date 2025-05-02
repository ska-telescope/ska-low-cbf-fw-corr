-------------------------------------------------------------------------------
--
-- File Name: correlator.vhd
-- Contributing Authors: Giles Babich, David Humphrey
-- Template Rev: 1.0
--
-- Title: Top Level for vitis compatible acceleration core
--
-------------------------------------------------------------------------------

LIBRARY IEEE, UNISIM, common_lib, axi4_lib, technology_lib, dsp_top_lib, correlator_lib;
LIBRARY noc_lib;

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
USE correlator_lib.correlator_system_reg_pkg.ALL;

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
        g_USE_DUMMY_FB       : boolean := FALSE -- Should be FALSE for normal operation.
    );
    port (
        clk_100         : in std_logic;
        clk_100_rst     : in std_logic;
        
        clk_300         : in std_logic;
        clk_300_rst     : in std_logic;
        
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
    
    component correlator_system_versal_reg is 
    GENERIC (g_technology : t_technology := c_tech_select_default);
    PORT (
        MM_CLK              : IN    STD_LOGIC;
        MM_RST              : IN    STD_LOGIC;
        noc_wren            : IN STD_LOGIC;
        noc_rden            : IN STD_LOGIC;
        noc_wr_adr          : IN STD_LOGIC_VECTOR(17 DOWNTO 0);
        noc_wr_dat          : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
        noc_rd_adr          : IN STD_LOGIC_VECTOR(17 DOWNTO 0);
        noc_rd_dat          : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
        SYSTEM_FIELDS_RW: OUT t_system_rw;
        SYSTEM_FIELDS_RO: IN  t_system_ro
        );
    end component;
      
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
    signal hbm_reset_combined       : std_logic_vector(5 downto 0);
    
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
    

    
    signal hbm_reset_final : std_logic;
    signal i_axis_tdata_gated : std_logic_vector(511 downto 0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
    signal i_axis_tkeep_gated : std_logic_vector(63 downto 0);  -- one bit per byte in i_axi_tdata
    signal i_axis_tlast_gated : std_logic;
    signal i_axis_tuser_gated : std_logic_vector(79 downto 0); -- Timestamp for the packet.
    signal i_axis_tvalid_gated : std_logic;
    signal eth_disable_fsm_dbg : std_logic_vector(4 downto 0);
    signal hbm_reset_actual : std_logic_vector(5 downto 0);
    
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
   
    ---------------------------------------------------------------------------
    -- System Peripheral Registers  --
    ---------------------------------------------------------------------------
    i_system_noc : entity noc_lib.args_noc
    generic map (
        G_DEBUG => TRUE
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


    i_system_regs: correlator_system_versal_reg
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
        end if;
    end process;
    system_fields_ro.time_uptime <= uptime;
    system_fields_ro.status_clocks_locked <= '1';
    
    --------------------------------------------------------------------------------------------------
    -- debug
    
    debug_correlator_core : ila_0 
    Port map ( 
        clk                     => clk_300,
        probe0(31 downto 0)     => ap_clk_count,
        probe0(63 downto 32)    => uptime,
        probe0(191 downto 64)   => (others => '0')
    );
    

--    --------------------------------------------------------------------------------------------------
--    -- 100G PORT A or Upper for U55C
--    locked_100G_port_a : xpm_cdc_single
--    generic map (
--        DEST_SYNC_FF    => 2,   
--        INIT_SYNC_FF    => 0,   
--        SIM_ASSERT_CHK  => 0, 
--        SRC_INPUT_REG   => 1   
--    )
--    port map (
--        dest_out    => system_fields_ro.eth100G_locked,
--        dest_clk    => ap_clk,
--        src_clk     => i_eth100G_clk,   
--        src_in      => i_eth100G_locked 
--    );

--    system_fields_ro.eth100G_rx_total_packets       <= i_eth100G_rx_total_packets;
--    system_fields_ro.eth100G_rx_bad_fcs             <= i_eth100G_rx_bad_fcs;
--    system_fields_ro.eth100G_rx_bad_code            <= i_eth100G_rx_bad_code;
--    system_fields_ro.eth100G_tx_total_packets       <= i_eth100G_tx_total_packets;
--    system_fields_ro.eth100g_ptp_nano_seconds       <= i_PTP_time_ARGs_clk(31 downto 0);
--    system_fields_ro.eth100g_ptp_lower_seconds      <= i_PTP_time_ARGs_clk(63 downto 32);
--    system_fields_ro.eth100g_ptp_upper_seconds      <= x"0000" & i_PTP_time_ARGs_clk(79 downto 64);
    
    
    
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
        o_axis_tdata   => o_axis_tdata,  -- out (511:0); 64 bytes of data, 1st byte in the packet is in bits 7:0.
        o_axis_tkeep   => o_axis_tkeep,  -- out (63:0);  one bit per byte in o_axis_tdata
        o_axis_tlast   => o_axis_tlast,  -- out std_logic;                      
        o_axis_tuser   => o_axis_tuser,  -- out std_logic;
        o_axis_tvalid  => o_axis_tvalid, -- out std_logic;
        i_axis_tready  => i_axis_tready, -- in std_logic;
        
        i_clk_100GE         => i_eth100G_clk,      -- in std_logic;
        i_eth100G_locked    => i_eth100G_locked,
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
        
        o_spead_hbm_rd_lite_axi_miso    => open,

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
        o_HBM_axi_aw      => logic_HBM_axi_aw,       
        i_HBM_axi_awready => logic_HBM_axi_awreadyi, -- in std_logic_vector(5:0);
        -- w data buses : out t_axi4_full_data_arr(5:0)(.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_w       => logic_HBM_axi_w,        
        i_HBM_axi_wready  => logic_HBM_axi_wreadyi,  -- in std_logic_vector(5:0);
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
        i_hbm_reset_final => hbm_reset_final,   -- 1 bit
        i_eth_disable_fsm_dbg => eth_disable_fsm_dbg, -- 5 bits
        i_axi_dbg => axi_dbg, -- 128 bits
        i_axi_dbg_valid => axi_dbg_valid
    );
    
    hbm_reset_combined(0)               <= hbm_reset(0) OR i_input_HBM_reset;
    hbm_reset_combined(5 downto 1)      <= hbm_reset(5 downto 1);
    
    
--    eth_block : entity correlator_lib.eth_disable
--    generic map (
--        -- Number of i_ap_clk clocks to wait after blocking ethernet traffic before driving o_reset
--        -- This allows us to wait a while for e.g. SPS input writes to HBM to complete properly
--        g_HOLDOFF => 1024, -- : integer := 1024;
--        -- Number of i_eth_clk clocks to wait before unblocking ethernet traffic after de-asserting o_reset
--        g_RESTART_HOLDOFF => 2048 -- : integer := 4096
--    ) port map (
--        -- Reset signal is on i_ap_clk
--        i_ap_clk  => ap_clk,  --  in std_logic;
--        i_reset   => hbm_reset_combined(0), --  in std_logic;  
--        o_reset   => hbm_reset_final,       --  out std_logic; -- Goes high following i_reset after the 100G ethernet has been blocked
--        o_fsm_dbg => eth_disable_fsm_dbg, --  out std_logic_vector(4 downto 0); -- fsm state 
--        -----------------------------------------------------
--        -- Everything else is on i_eth_clk
--        i_eth_clk    => i_eth100G_clk, --  in std_logic;
--        -----------------------------------------------------
--        -- Received data from 100GE
--        i_axis_tdata => i_axis_tdata, --  in std_logic_vector(511 downto 0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
--        i_axis_tkeep => i_axis_tkeep, -- in std_logic_vector(63 downto 0);  -- one bit per byte in i_axi_tdata
--        i_axis_tlast => i_axis_tlast, -- in std_logic;                      
--        i_axis_tuser => i_axis_tuser, -- in std_logic_vector(79 downto 0);  -- Timestamp for the packet.
--        i_axis_tvalid => i_axis_tvalid, -- in std_logic;
--        -- Data output - 1 clock latency from input
--        o_axis_tdata => i_axis_tdata_gated, -- out std_logic_vector(511 downto 0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
--        o_axis_tkeep => i_axis_tkeep_gated, -- out std_logic_vector(63 downto 0);  -- one bit per byte in i_axi_tdata
--        o_axis_tlast => i_axis_tlast_gated, -- out std_logic;                      
--        o_axis_tuser => i_axis_tuser_gated, -- out std_logic_vector(79 downto 0);  -- Timestamp for the packet.
--        o_axis_tvalid => i_axis_tvalid_gated -- out std_logic
--        -----------------------------------------------------
--    );    
    
   
    

        
--    -- ar and aw addresses need to be set to the correct offset within the HBM
--    HBM_axi_araddr256Mbytei(i) <= HBM_axi_ar(i).addr(35 downto 28); -- 8 bit address of 256MByte pieces, within 64 Gbytes ((35:0) addresses 64 Gbytes)
--    HBM_axi_araddri(i)(63 downto 36) <= HBM_shared(i)(63 downto 36);
--    HBM_axi_araddri(i)(35 downto 28) <= std_logic_vector(unsigned(HBM_shared(i)(35 downto 28)) + unsigned(HBM_axi_araddr256Mbytei(i)));
--    HBM_axi_araddri(i)(27 downto 0) <= HBM_axi_ar(i).addr(27 downto 0);

--    HBM_axi_awaddr256Mbytei(i) <= HBM_axi_aw(i).addr(35 downto 28); -- 8 bit address of 256MByte pieces, within 64 Gbytes ((35:0) addresses 64 Gbytes)
--    HBM_axi_awaddri(i)(63 downto 36) <= HBM_shared(i)(63 downto 36);
--    HBM_axi_awaddri(i)(35 downto 28) <= std_logic_vector(unsigned(HBM_shared(i)(35 downto 28)) + unsigned(HBM_axi_awaddr256Mbytei(i)));
--    HBM_axi_awaddri(i)(27 downto 0) <= HBM_axi_aw(i).addr(27 downto 0);
        

    
END structure;
