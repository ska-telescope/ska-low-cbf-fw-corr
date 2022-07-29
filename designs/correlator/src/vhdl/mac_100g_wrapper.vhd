----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 18.08.2020 09:14:27
-- Design Name: 
-- Module Name: mac_100g_wrapper - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------
library IEEE, axi4_lib, technology_lib, common_lib, signal_processing_common, DRP_lib;
use IEEE.STD_LOGIC_1164.ALL;
USE axi4_lib.axi4_stream_pkg.ALL;
USE technology_lib.tech_mac_100g_pkg.ALL;
USE common_lib.common_pkg.ALL;
use IEEE.NUMERIC_STD.ALL;

use axi4_lib.axi4_lite_pkg.ALL;
USE DRP_lib.DRP_drp_reg_pkg.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity mac_100g_wrapper is
    generic (
        DEBUG_ILA               : BOOLEAN := FALSE
    
    );
    Port(
        gt_rxp_in               : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        gt_rxn_in               : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        gt_txp_out              : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        gt_txn_out              : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        gt_refclk_p             : IN STD_LOGIC;
        gt_refclk_n             : IN STD_LOGIC;
        sys_reset               : IN STD_LOGIC;   -- sys_reset, clocked by dclk.
        i_dclk_100              : IN STD_LOGIC;                     -- stable clock for the core; 300Mhz from kernel -> PLL -> 100 Mhz

        -- loopback for the GTYs
        -- "000" = normal operation, "001" = near-end PCS loopback, "010" = near-end PMA loopback
        -- "100" = far-end PMA loopback, "110" = far-end PCS loopback.
        -- See GTY user guid (Xilinx doc UG578) for details.
        loopback                : IN STD_LOGIC_VECTOR(2 DOWNTO 0);  
        tx_enable               : IN STD_LOGIC;
        rx_enable               : IN STD_LOGIC;
        
        i_fec_enable            : IN STD_LOGIC;

        tx_clk_out              : OUT STD_LOGIC;                   -- Should be driven by one of the tx_clk_outs

        -- User Interface Signals
        rx_locked               : OUT STD_LOGIC;

        user_rx_reset           : OUT STD_LOGIC;
        user_tx_reset           : OUT STD_LOGIC;

        -- Statistics Interface
        rx_total_packets        : out std_logic_vector(31 downto 0);
        rx_bad_fcs              : out std_logic_vector(31 downto 0);
        rx_bad_code             : out std_logic_vector(31 downto 0);
        tx_total_packets        : out std_logic_vector(31 downto 0);

        -- Received data from optics
        data_rx_sosi            : OUT t_lbus_sosi;

        -- Data to be transmitted to optics
        data_tx_sosi            : IN t_lbus_sosi;
        data_tx_siso            : OUT t_lbus_siso;
        
        -- ARGS DRP interface
        i_MACE_clk              : in std_logic;
        i_MACE_rst              : in std_logic;
        i_DRP_Lite_axi_mosi     : in t_axi4_lite_mosi; 
        o_DRP_Lite_axi_miso     : out t_axi4_lite_miso 
        
    );
end mac_100g_wrapper;

architecture Behavioral of mac_100g_wrapper is

    COMPONENT cmac_usplus_0
      PORT (
        gt_txp_out : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        gt_txn_out : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        gt_rxp_in : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        gt_rxn_in : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        gt_txusrclk2 : OUT STD_LOGIC;
        gt_loopback_in : IN STD_LOGIC_VECTOR(11 DOWNTO 0);
        gt_ref_clk_out : OUT STD_LOGIC;
        gt_rxrecclkout : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        gt_powergoodout : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        gtwiz_reset_tx_datapath : IN STD_LOGIC;
        gtwiz_reset_rx_datapath : IN STD_LOGIC;
        sys_reset : IN STD_LOGIC;
        gt_ref_clk_p : IN STD_LOGIC;
        gt_ref_clk_n : IN STD_LOGIC;
        init_clk : IN STD_LOGIC;
        rx_dataout0 : OUT STD_LOGIC_VECTOR(127 DOWNTO 0);
        rx_dataout1 : OUT STD_LOGIC_VECTOR(127 DOWNTO 0);
        rx_dataout2 : OUT STD_LOGIC_VECTOR(127 DOWNTO 0);
        rx_dataout3 : OUT STD_LOGIC_VECTOR(127 DOWNTO 0);
        rx_enaout0 : OUT STD_LOGIC;
        rx_enaout1 : OUT STD_LOGIC;
        rx_enaout2 : OUT STD_LOGIC;
        rx_enaout3 : OUT STD_LOGIC;
        rx_eopout0 : OUT STD_LOGIC;
        rx_eopout1 : OUT STD_LOGIC;
        rx_eopout2 : OUT STD_LOGIC;
        rx_eopout3 : OUT STD_LOGIC;
        rx_errout0 : OUT STD_LOGIC;
        rx_errout1 : OUT STD_LOGIC;
        rx_errout2 : OUT STD_LOGIC;
        rx_errout3 : OUT STD_LOGIC;
        rx_mtyout0 : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        rx_mtyout1 : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        rx_mtyout2 : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        rx_mtyout3 : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        rx_sopout0 : OUT STD_LOGIC;
        rx_sopout1 : OUT STD_LOGIC;
        rx_sopout2 : OUT STD_LOGIC;
        rx_sopout3 : OUT STD_LOGIC;
        rx_otn_bip8_0 : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
        rx_otn_bip8_1 : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
        rx_otn_bip8_2 : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
        rx_otn_bip8_3 : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
        rx_otn_bip8_4 : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
        rx_otn_data_0 : OUT STD_LOGIC_VECTOR(65 DOWNTO 0);
        rx_otn_data_1 : OUT STD_LOGIC_VECTOR(65 DOWNTO 0);
        rx_otn_data_2 : OUT STD_LOGIC_VECTOR(65 DOWNTO 0);
        rx_otn_data_3 : OUT STD_LOGIC_VECTOR(65 DOWNTO 0);
        rx_otn_data_4 : OUT STD_LOGIC_VECTOR(65 DOWNTO 0);
        rx_otn_ena : OUT STD_LOGIC;
        rx_otn_lane0 : OUT STD_LOGIC;
        rx_otn_vlmarker : OUT STD_LOGIC;
        rx_preambleout : OUT STD_LOGIC_VECTOR(55 DOWNTO 0);
        usr_rx_reset : OUT STD_LOGIC;
        gt_rxusrclk2 : OUT STD_LOGIC;
        stat_rx_aligned : OUT STD_LOGIC;
        stat_rx_aligned_err : OUT STD_LOGIC;
        stat_rx_bad_code : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        stat_rx_bad_fcs : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        stat_rx_bad_preamble : OUT STD_LOGIC;
        stat_rx_bad_sfd : OUT STD_LOGIC;
        stat_rx_bip_err_0 : OUT STD_LOGIC;
        stat_rx_bip_err_1 : OUT STD_LOGIC;
        stat_rx_bip_err_10 : OUT STD_LOGIC;
        stat_rx_bip_err_11 : OUT STD_LOGIC;
        stat_rx_bip_err_12 : OUT STD_LOGIC;
        stat_rx_bip_err_13 : OUT STD_LOGIC;
        stat_rx_bip_err_14 : OUT STD_LOGIC;
        stat_rx_bip_err_15 : OUT STD_LOGIC;
        stat_rx_bip_err_16 : OUT STD_LOGIC;
        stat_rx_bip_err_17 : OUT STD_LOGIC;
        stat_rx_bip_err_18 : OUT STD_LOGIC;
        stat_rx_bip_err_19 : OUT STD_LOGIC;
        stat_rx_bip_err_2 : OUT STD_LOGIC;
        stat_rx_bip_err_3 : OUT STD_LOGIC;
        stat_rx_bip_err_4 : OUT STD_LOGIC;
        stat_rx_bip_err_5 : OUT STD_LOGIC;
        stat_rx_bip_err_6 : OUT STD_LOGIC;
        stat_rx_bip_err_7 : OUT STD_LOGIC;
        stat_rx_bip_err_8 : OUT STD_LOGIC;
        stat_rx_bip_err_9 : OUT STD_LOGIC;
        stat_rx_block_lock : OUT STD_LOGIC_VECTOR(19 DOWNTO 0);
        stat_rx_broadcast : OUT STD_LOGIC;
        stat_rx_fragment : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        stat_rx_framing_err_0 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        stat_rx_framing_err_1 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        stat_rx_framing_err_10 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        stat_rx_framing_err_11 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        stat_rx_framing_err_12 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        stat_rx_framing_err_13 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        stat_rx_framing_err_14 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        stat_rx_framing_err_15 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        stat_rx_framing_err_16 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        stat_rx_framing_err_17 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        stat_rx_framing_err_18 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        stat_rx_framing_err_19 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        stat_rx_framing_err_2 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        stat_rx_framing_err_3 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        stat_rx_framing_err_4 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        stat_rx_framing_err_5 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        stat_rx_framing_err_6 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        stat_rx_framing_err_7 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        stat_rx_framing_err_8 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        stat_rx_framing_err_9 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        stat_rx_framing_err_valid_0 : OUT STD_LOGIC;
        stat_rx_framing_err_valid_1 : OUT STD_LOGIC;
        stat_rx_framing_err_valid_10 : OUT STD_LOGIC;
        stat_rx_framing_err_valid_11 : OUT STD_LOGIC;
        stat_rx_framing_err_valid_12 : OUT STD_LOGIC;
        stat_rx_framing_err_valid_13 : OUT STD_LOGIC;
        stat_rx_framing_err_valid_14 : OUT STD_LOGIC;
        stat_rx_framing_err_valid_15 : OUT STD_LOGIC;
        stat_rx_framing_err_valid_16 : OUT STD_LOGIC;
        stat_rx_framing_err_valid_17 : OUT STD_LOGIC;
        stat_rx_framing_err_valid_18 : OUT STD_LOGIC;
        stat_rx_framing_err_valid_19 : OUT STD_LOGIC;
        stat_rx_framing_err_valid_2 : OUT STD_LOGIC;
        stat_rx_framing_err_valid_3 : OUT STD_LOGIC;
        stat_rx_framing_err_valid_4 : OUT STD_LOGIC;
        stat_rx_framing_err_valid_5 : OUT STD_LOGIC;
        stat_rx_framing_err_valid_6 : OUT STD_LOGIC;
        stat_rx_framing_err_valid_7 : OUT STD_LOGIC;
        stat_rx_framing_err_valid_8 : OUT STD_LOGIC;
        stat_rx_framing_err_valid_9 : OUT STD_LOGIC;
        stat_rx_got_signal_os : OUT STD_LOGIC;
        stat_rx_hi_ber : OUT STD_LOGIC;
        stat_rx_inrangeerr : OUT STD_LOGIC;
        stat_rx_internal_local_fault : OUT STD_LOGIC;
        stat_rx_jabber : OUT STD_LOGIC;
        stat_rx_local_fault : OUT STD_LOGIC;
        stat_rx_mf_err : OUT STD_LOGIC_VECTOR(19 DOWNTO 0);
        stat_rx_mf_len_err : OUT STD_LOGIC_VECTOR(19 DOWNTO 0);
        stat_rx_mf_repeat_err : OUT STD_LOGIC_VECTOR(19 DOWNTO 0);
        stat_rx_misaligned : OUT STD_LOGIC;
        stat_rx_multicast : OUT STD_LOGIC;
        stat_rx_oversize : OUT STD_LOGIC;
        stat_rx_packet_1024_1518_bytes : OUT STD_LOGIC;
        stat_rx_packet_128_255_bytes : OUT STD_LOGIC;
        stat_rx_packet_1519_1522_bytes : OUT STD_LOGIC;
        stat_rx_packet_1523_1548_bytes : OUT STD_LOGIC;
        stat_rx_packet_1549_2047_bytes : OUT STD_LOGIC;
        stat_rx_packet_2048_4095_bytes : OUT STD_LOGIC;
        stat_rx_packet_256_511_bytes : OUT STD_LOGIC;
        stat_rx_packet_4096_8191_bytes : OUT STD_LOGIC;
        stat_rx_packet_512_1023_bytes : OUT STD_LOGIC;
        stat_rx_packet_64_bytes : OUT STD_LOGIC;
        stat_rx_packet_65_127_bytes : OUT STD_LOGIC;
        stat_rx_packet_8192_9215_bytes : OUT STD_LOGIC;
        stat_rx_packet_bad_fcs : OUT STD_LOGIC;
        stat_rx_packet_large : OUT STD_LOGIC;
        stat_rx_packet_small : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        ctl_rx_enable : IN STD_LOGIC;
        ctl_rx_force_resync : IN STD_LOGIC;
        ctl_rx_test_pattern : IN STD_LOGIC;
        core_rx_reset : IN STD_LOGIC;
        rx_clk : IN STD_LOGIC;
        stat_rx_received_local_fault : OUT STD_LOGIC;
        stat_rx_remote_fault : OUT STD_LOGIC;
        stat_rx_status : OUT STD_LOGIC;
        stat_rx_stomped_fcs : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        stat_rx_synced : OUT STD_LOGIC_VECTOR(19 DOWNTO 0);
        stat_rx_synced_err : OUT STD_LOGIC_VECTOR(19 DOWNTO 0);
        stat_rx_test_pattern_mismatch : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        stat_rx_toolong : OUT STD_LOGIC;
        stat_rx_total_bytes : OUT STD_LOGIC_VECTOR(6 DOWNTO 0);
        stat_rx_total_good_bytes : OUT STD_LOGIC_VECTOR(13 DOWNTO 0);
        stat_rx_total_good_packets : OUT STD_LOGIC;
        stat_rx_total_packets : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        stat_rx_truncated : OUT STD_LOGIC;
        stat_rx_undersize : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        stat_rx_unicast : OUT STD_LOGIC;
        stat_rx_vlan : OUT STD_LOGIC;
        stat_rx_pcsl_demuxed : OUT STD_LOGIC_VECTOR(19 DOWNTO 0);
        stat_rx_pcsl_number_0 : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
        stat_rx_pcsl_number_1 : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
        stat_rx_pcsl_number_10 : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
        stat_rx_pcsl_number_11 : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
        stat_rx_pcsl_number_12 : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
        stat_rx_pcsl_number_13 : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
        stat_rx_pcsl_number_14 : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
        stat_rx_pcsl_number_15 : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
        stat_rx_pcsl_number_16 : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
        stat_rx_pcsl_number_17 : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
        stat_rx_pcsl_number_18 : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
        stat_rx_pcsl_number_19 : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
        stat_rx_pcsl_number_2 : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
        stat_rx_pcsl_number_3 : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
        stat_rx_pcsl_number_4 : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
        stat_rx_pcsl_number_5 : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
        stat_rx_pcsl_number_6 : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
        stat_rx_pcsl_number_7 : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
        stat_rx_pcsl_number_8 : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
        stat_rx_pcsl_number_9 : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
        stat_tx_bad_fcs : OUT STD_LOGIC;
        stat_tx_broadcast : OUT STD_LOGIC;
        stat_tx_frame_error : OUT STD_LOGIC;
        stat_tx_local_fault : OUT STD_LOGIC;
        stat_tx_multicast : OUT STD_LOGIC;
        stat_tx_packet_1024_1518_bytes : OUT STD_LOGIC;
        stat_tx_packet_128_255_bytes : OUT STD_LOGIC;
        stat_tx_packet_1519_1522_bytes : OUT STD_LOGIC;
        stat_tx_packet_1523_1548_bytes : OUT STD_LOGIC;
        stat_tx_packet_1549_2047_bytes : OUT STD_LOGIC;
        stat_tx_packet_2048_4095_bytes : OUT STD_LOGIC;
        stat_tx_packet_256_511_bytes : OUT STD_LOGIC;
        stat_tx_packet_4096_8191_bytes : OUT STD_LOGIC;
        stat_tx_packet_512_1023_bytes : OUT STD_LOGIC;
        stat_tx_packet_64_bytes : OUT STD_LOGIC;
        stat_tx_packet_65_127_bytes : OUT STD_LOGIC;
        stat_tx_packet_8192_9215_bytes : OUT STD_LOGIC;
        stat_tx_packet_large : OUT STD_LOGIC;
        stat_tx_packet_small : OUT STD_LOGIC;
        stat_tx_total_bytes : OUT STD_LOGIC_VECTOR(5 DOWNTO 0);
        stat_tx_total_good_bytes : OUT STD_LOGIC_VECTOR(13 DOWNTO 0);
        stat_tx_total_good_packets : OUT STD_LOGIC;
        stat_tx_total_packets : OUT STD_LOGIC;
        stat_tx_unicast : OUT STD_LOGIC;
        stat_tx_vlan : OUT STD_LOGIC;
        ctl_tx_enable : IN STD_LOGIC;
        ctl_tx_send_idle : IN STD_LOGIC;
        ctl_tx_send_rfi : IN STD_LOGIC;
        ctl_tx_send_lfi : IN STD_LOGIC;
        ctl_tx_test_pattern : IN STD_LOGIC;
        core_tx_reset : IN STD_LOGIC;
        tx_ovfout : OUT STD_LOGIC;
        tx_rdyout : OUT STD_LOGIC;
        tx_unfout : OUT STD_LOGIC;
        tx_datain0 : IN STD_LOGIC_VECTOR(127 DOWNTO 0);
        tx_datain1 : IN STD_LOGIC_VECTOR(127 DOWNTO 0);
        tx_datain2 : IN STD_LOGIC_VECTOR(127 DOWNTO 0);
        tx_datain3 : IN STD_LOGIC_VECTOR(127 DOWNTO 0);
        tx_enain0 : IN STD_LOGIC;
        tx_enain1 : IN STD_LOGIC;
        tx_enain2 : IN STD_LOGIC;
        tx_enain3 : IN STD_LOGIC;
        tx_eopin0 : IN STD_LOGIC;
        tx_eopin1 : IN STD_LOGIC;
        tx_eopin2 : IN STD_LOGIC;
        tx_eopin3 : IN STD_LOGIC;
        tx_errin0 : IN STD_LOGIC;
        tx_errin1 : IN STD_LOGIC;
        tx_errin2 : IN STD_LOGIC;
        tx_errin3 : IN STD_LOGIC;
        tx_mtyin0 : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        tx_mtyin1 : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        tx_mtyin2 : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        tx_mtyin3 : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        tx_sopin0 : IN STD_LOGIC;
        tx_sopin1 : IN STD_LOGIC;
        tx_sopin2 : IN STD_LOGIC;
        tx_sopin3 : IN STD_LOGIC;
        tx_preamblein : IN STD_LOGIC_VECTOR(55 DOWNTO 0);
        usr_tx_reset : OUT STD_LOGIC;
        core_drp_reset : IN STD_LOGIC;
        -- FEC
        ctl_tx_rsfec_enable                     : IN STD_LOGIC;
        ctl_rx_rsfec_enable                     : IN STD_LOGIC; 
        ctl_rsfec_ieee_error_indication_mode    : IN STD_LOGIC;
        ctl_rx_rsfec_enable_correction          : IN STD_LOGIC; 
        ctl_rx_rsfec_enable_indication          : IN STD_LOGIC;

        -- GT DRP
        gt_drpclk : in STD_LOGIC;
        gt0_drpdo : out STD_LOGIC_VECTOR ( 15 downto 0 );
        gt0_drprdy : out STD_LOGIC;
        gt0_drpen : in STD_LOGIC;
        gt0_drpwe : in STD_LOGIC;
        gt0_drpaddr : in STD_LOGIC_VECTOR ( 9 downto 0 );
        gt0_drpdi : in STD_LOGIC_VECTOR ( 15 downto 0 );
        gt1_drpdo : out STD_LOGIC_VECTOR ( 15 downto 0 );
        gt1_drprdy : out STD_LOGIC;
        gt1_drpen : in STD_LOGIC;
        gt1_drpwe : in STD_LOGIC;
        gt1_drpaddr : in STD_LOGIC_VECTOR ( 9 downto 0 );
        gt1_drpdi : in STD_LOGIC_VECTOR ( 15 downto 0 );
        gt2_drpdo : out STD_LOGIC_VECTOR ( 15 downto 0 );
        gt2_drprdy : out STD_LOGIC;
        gt2_drpen : in STD_LOGIC;
        gt2_drpwe : in STD_LOGIC;
        gt2_drpaddr : in STD_LOGIC_VECTOR ( 9 downto 0 );
        gt2_drpdi : in STD_LOGIC_VECTOR ( 15 downto 0 );
        gt3_drpdo : out STD_LOGIC_VECTOR ( 15 downto 0 );
        gt3_drprdy : out STD_LOGIC;
        gt3_drpen : in STD_LOGIC;
        gt3_drpwe : in STD_LOGIC;
        gt3_drpaddr : in STD_LOGIC_VECTOR ( 9 downto 0 );
        gt3_drpdi : in STD_LOGIC_VECTOR ( 15 downto 0 );
        
        common0_drpaddr : in STD_LOGIC_VECTOR ( 15 downto 0 );
        common0_drpdi : in STD_LOGIC_VECTOR ( 15 downto 0 );
        common0_drpwe : in STD_LOGIC;
        common0_drpen : in STD_LOGIC;
        common0_drprdy : out STD_LOGIC;
        common0_drpdo : out STD_LOGIC_VECTOR ( 15 downto 0 );

        -- CMAC DRP
        drp_clk : IN STD_LOGIC;
        drp_addr : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
        drp_di : IN STD_LOGIC_VECTOR(15 DOWNTO 0);
        drp_en : IN STD_LOGIC;
        drp_do : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
        drp_rdy : OUT STD_LOGIC;
        drp_we : IN STD_LOGIC
      );
    END COMPONENT;

    COMPONENT ila_0
    PORT (
        clk : IN STD_LOGIC;
        probe0 : IN STD_LOGIC_VECTOR(191 DOWNTO 0));
    END COMPONENT;

    signal stat_rx_total_bytes              : std_logic_vector(6 downto 0);  -- unused at present.
    signal stat_rx_total_packets            : std_logic_vector(2 downto 0);    -- Total RX packets
    signal stat_rx_total_good_packets		: std_logic;    
    signal stat_rx_packet_bad_fcs           : std_logic;                       -- Bad checksums
    signal stat_rx_packet_64_bytes		    : std_logic;
    signal stat_rx_packet_65_127_bytes	    : std_logic;
    signal stat_rx_packet_128_255_bytes	    : std_logic;
    signal stat_rx_packet_256_511_bytes	    : std_logic;
    signal stat_rx_packet_512_1023_bytes	: std_logic;
    signal stat_rx_packet_1024_1518_bytes	: std_logic;
    signal stat_rx_packet_1519_1522_bytes	: std_logic;
    signal stat_rx_packet_1523_1548_bytes	: std_logic;
    signal stat_rx_packet_1549_2047_bytes	: std_logic;
    signal stat_rx_packet_2048_4095_bytes	: std_logic;
    signal stat_rx_packet_4096_8191_bytes	: std_logic;
    signal stat_rx_packet_8192_9215_bytes	: std_logic;
    signal stat_rx_packet_small             : std_logic_vector(2 downto 0);
    signal stat_rx_packet_large             : std_logic;
    signal stat_rx_unicast                  : std_logic;
    signal stat_rx_multicast				: std_logic;
    signal stat_rx_broadcast				: std_logic;
    signal stat_rx_oversize				    : std_logic;
    signal stat_rx_toolong                  : std_logic;    
    signal stat_rx_undersize				: std_logic_vector(2 downto 0);
    signal stat_rx_fragment				    : std_logic_vector(2 downto 0);
    signal stat_rx_bad_code                 : std_logic_vector(2 downto 0);    -- Bit errors on the line
    signal stat_rx_bad_sfd                  : std_logic;
    signal stat_rx_bad_preamble             : std_logic;    
    
    constant STAT_REGISTERS  : integer := 28;
    
    signal stats_count                : t_slv_32_arr(0 to (STAT_REGISTERS-1));
    signal stats_increment            : t_slv_3_arr(0 to (STAT_REGISTERS-1));
    
    signal stats_to_host_data_out       : t_slv_32_arr(0 to (STAT_REGISTERS-1));
    
    signal stat_tx_total_packets : std_logic;
    signal stat_tx_total_bytes   : std_logic_vector(5 downto 0);
    signal stat_tx_increment     : t_slv_1_arr(0 to 0);
    signal stat_tx_count         : t_slv_32_arr(0 to 0);
    
    signal i_tx_clk_out : std_logic;
    signal rx_clk_in    : std_logic;
    signal i_loopback   : std_logic_vector(11 downto 0);
    signal i_user_tx_reset : std_logic;
    signal i_user_rx_reset : std_logic;
    
    signal tx_send_rfi : std_logic;
    signal tx_send_lfi : std_logic;
    signal rsfec_tx_enable : std_logic;
    signal i_tx_enable : std_logic;
    signal i_rx_locked : std_logic;
    signal rx_local_fault : std_logic;
    signal rsfec_rx_enable : std_logic;
    signal rx_remote_fault : std_logic;
    signal rx_receive_local_fault : std_logic;
    signal tx_send_idle : std_logic := '0';
    
    signal system_reset_int : std_logic;
    
    signal tx_rx_reset_holdoff_count    : std_logic_vector(27 downto 0) := x"0000000";
    signal tx_rx_counter_reset          : std_logic := '0';
    
    signal cmac_stats_reset             : std_logic_vector(7 downto 0);
    signal stat_reset                   : std_logic;
    ---------
    -- DRP and stat additions
    constant DRP_TO_HOST_REGISTERS      : integer := 5;
    
    signal drp_to_host_data_in          : t_slv_16_arr(0 to (DRP_TO_HOST_REGISTERS-1));
    signal drp_to_host_data_out         : t_slv_16_arr(0 to (DRP_TO_HOST_REGISTERS-1));
    
    
    signal core_drp_reset_comb  : STD_LOGIC;
    
    
    -- CMAC DRP signals
    signal cmac_drp_reset   : STD_LOGIC;
    signal cmac_drp_addr    : STD_LOGIC_VECTOR ( 9 downto 0 );
    signal cmac_drp_di      : STD_LOGIC_VECTOR ( 15 downto 0 );
    signal cmac_drp_en      : STD_LOGIC;
    signal cmac_drp_do      : STD_LOGIC_VECTOR ( 15 downto 0 );
    signal cmac_drp_rdy     : STD_LOGIC;
    signal cmac_drp_we      : STD_LOGIC;
       
    type drp_statemachine is (IDLE, CMD, READ_DATA, FINISH);
    signal cmac_drp_sm : drp_statemachine;
    
    
    signal cmac_DRP_SM_Control   : std_logic_vector(15 downto 0);
    signal cmac_DRP_SM_Ctl_cache : std_logic_vector(15 downto 0);
    signal cmac_DRP_addr_Control : std_logic_vector(9 downto 0);
    signal cmac_DRP_SM_rd_data   : std_logic_vector(15 downto 0);
    signal cmac_DRP_SM_wr_data   : std_logic_vector(15 downto 0);
    signal cmac_DRP_SM_wr_verify : std_logic;
    
    signal cmac_drp_rw_registers     : t_cmac_drp_interface_rw;
    signal cmac_drp_ro_registers     : t_cmac_drp_interface_ro;
    
    -- GT DRP Signals
    
    signal gt_drp_sm            : drp_statemachine;
    
    signal gt_drp_reset   : STD_LOGIC;
    signal gt_drp_addr    : STD_LOGIC_VECTOR ( 9 downto 0 );
    signal gt_drp_di      : t_slv_16_arr(0 to 3);
    signal gt_drp_en      : STD_LOGIC;
    signal gt_drp_do      : t_slv_16_arr(0 to 3);
    signal gt_drp_rdy     : STD_LOGIC_VECTOR ( 3 downto 0 );
    signal gt_drp_we      : STD_LOGIC_VECTOR ( 3 downto 0 );
    
    signal GT_DRP_SM_rd_data      : t_slv_16_arr(0 to 3);
    signal GT_DRP_SM_wr_data      : t_slv_16_arr(0 to 3);    
        
    signal GT_DRP_SM_Control   : std_logic_vector(15 downto 0);
    signal GT_DRP_SM_Ctl_cache : std_logic_vector(15 downto 0);
    signal GT_DRP_addr_Control : std_logic_vector(9 downto 0);
    
    signal GT_DRP_SM_wr_verify : std_logic_vector(3 downto 0);
    
    
    
--    signal gt_drp_rw_registers  : t_gt_drp_interface_rw;
--    signal gt_drp_ro_registers  : t_gt_drp_interface_ro;
    
    
begin
    
    ---------------------------------------------------------------------------
    -- Statistics
    
    -- some duplicates here
    rx_total_packets    <= stats_count(0);
    rx_bad_fcs          <= stats_count(2);
    rx_bad_code         <= stats_count(24);
    
    tx_total_packets    <= stats_count(27); 
    
    
    ------------
    stats_increment(0) <= stat_rx_total_packets;
    stats_increment(1) <= "00" & stat_rx_total_good_packets;
    stats_increment(2) <= "00" & stat_rx_packet_bad_fcs;
    stats_increment(3) <= "00" & stat_rx_packet_64_bytes;
    stats_increment(4) <= "00" & stat_rx_packet_65_127_bytes;
    stats_increment(5) <= "00" & stat_rx_packet_128_255_bytes;
    stats_increment(6) <= "00" & stat_rx_packet_256_511_bytes;
    stats_increment(7) <= "00" & stat_rx_packet_512_1023_bytes;
    stats_increment(8) <= "00" & stat_rx_packet_1024_1518_bytes;
    stats_increment(9) <= "00" & stat_rx_packet_1519_1522_bytes;
    stats_increment(10) <= "00" & stat_rx_packet_1523_1548_bytes;
    stats_increment(11) <= "00" & stat_rx_packet_1549_2047_bytes;
    stats_increment(12) <= "00" & stat_rx_packet_2048_4095_bytes;
    stats_increment(13) <= "00" & stat_rx_packet_4096_8191_bytes;
    stats_increment(14) <= "00" & stat_rx_packet_8192_9215_bytes;
    stats_increment(15) <= stat_rx_packet_small;
    stats_increment(16) <= "00" & stat_rx_packet_large;
    stats_increment(17) <= "00" & stat_rx_unicast;
    stats_increment(18) <= "00" & stat_rx_multicast;
    stats_increment(19) <= "00" & stat_rx_broadcast;
    stats_increment(20) <= "00" & stat_rx_oversize;
    stats_increment(21) <= "00" & stat_rx_toolong;  
    stats_increment(22) <= stat_rx_undersize;
    stats_increment(23) <= stat_rx_fragment;
    stats_increment(24) <= stat_rx_bad_code;
    
    stats_increment(25) <= "00" & stat_rx_bad_sfd;
    stats_increment(26) <= "00" & stat_rx_bad_preamble;  
    stats_increment(27) <= "00" & stat_tx_total_packets;
    
    -- delay RX stats until 0.5 sec after lock
    delay_rx_stat_proc : process(i_tx_clk_out)
    begin
        if rising_edge(i_tx_clk_out) then
            -- reset from host = 1, reset from locked negative logic
            stat_reset <= cmac_stats_reset(0) OR (NOT i_rx_locked); 
            
            tx_rx_counter_reset <= stat_reset;
            
--            if stat_reset= '1' then
--                tx_rx_counter_reset            <= '1';
--                tx_rx_reset_holdoff_count     <= x"0000000";
--            elsif tx_rx_reset_holdoff_count(27) = '1' then  -- 322 MHZ, so 134,217,000 ~ 0.41sec
--                tx_rx_counter_reset            <= '0';
--            elsif stat_reset = '0' then
--                tx_rx_reset_holdoff_count     <= std_logic_vector(unsigned(tx_rx_reset_holdoff_count) + 1);
--                tx_rx_counter_reset            <= '1';
--            end if;
    
        end if;
    end process;

    stats_accumulators_rx: FOR i IN 0 TO (STAT_REGISTERS-1) GENERATE
        u_cnt_acc: ENTITY common_lib.common_accumulate
        GENERIC MAP (
            g_representation  => "UNSIGNED")
        PORT MAP (
            rst      => tx_rx_counter_reset,
            clk      => i_tx_clk_out,
            clken    => '1',
            sload    => '0',
            in_val   => '1',
            in_dat   => stats_increment(i),
            out_dat  => stats_count(i)
        );
    END GENERATE;


    -- Other connections
    rx_clk_in <= i_tx_clk_out;
    tx_clk_out <= i_tx_clk_out;

    user_tx_reset <= i_user_tx_reset;
    user_rx_reset <= i_user_rx_reset;

    i_loopback(2 DOWNTO 0) <= loopback;
    i_loopback(5 DOWNTO 3) <= loopback;
    i_loopback(8 DOWNTO 6) <= loopback;
    i_loopback(11 DOWNTO 9) <= loopback;

    --rx_locked <= i_rx_locked AND NOT rx_remote_fault;
    rx_locked <= i_rx_locked;

    -- startup 
    tx_startup_fsm: process(i_tx_clk_out)
    begin
        if rising_edge(i_tx_clk_out) then
            if i_user_tx_reset = '1' then
                tx_send_rfi <= '0';  -- rfi = remote fault indication
                tx_send_lfi <= '0';  -- lfi = local fault indication
                --rsfec_tx_enable <= '0';
                i_tx_enable <= '0';
            else
                if i_rx_locked = '1' then
                    tx_send_rfi <= '0';
                    tx_send_lfi <= rx_local_fault;
                    --rsfec_tx_enable <= '1';
                    i_tx_enable <= tx_enable;
                else
                    tx_send_rfi <= '1';
                    tx_send_lfi <= '1';
                    --rsfec_tx_enable <= '1';
                    i_tx_enable <= '0';
                end if;
            end if;
        end if;
    end process;

    FEC_ENABLE: process(i_tx_clk_out)
    begin
        if rising_edge(i_tx_clk_out) then
             rsfec_rx_enable <= i_fec_enable;
             rsfec_tx_enable <= i_fec_enable;
        end if;
    end process;


core_drp_reset_comb <= cmac_drp_reset OR sys_reset;-- OR gt_drp_reset;

    mac_1: cmac_usplus_0
    PORT MAP (
        gt_rxp_in => gt_rxp_in,
        gt_rxn_in => gt_rxn_in,
        gt_txp_out => gt_txp_out,
        gt_txn_out => gt_txn_out,
        gt_ref_clk_p => gt_refclk_p, 
        gt_ref_clk_n => gt_refclk_n, 
        gt_ref_clk_out => OPEN,

        sys_reset => sys_reset, 
        core_rx_reset => sys_reset, 
        core_tx_reset => sys_reset,
        
        core_drp_reset => core_drp_reset_comb, 
 
        init_clk        => i_dclk_100,
        gt_rxrecclkout  => open, 
        rx_clk          => rx_clk_in, 
        
        gt_txusrclk2    => i_tx_clk_out,
        
        gt_loopback_in => i_loopback,
        --gt_rxrate => X"000", 
        --gt_rxprbscntreset => X"0", 
        --gt_rxprbserr => OPEN, 
        --gt_rxprbssel => X"0000",
        --gt_txbufstatus => OPEN,
        --gt_txdiffctrl => c_txdiffctrl,
        --gt_txinhibit => X"0", 
        --gt_txpostcursor => c_txpostcursor,
        --gt_txprbsforceerr => X"0", 
        --gt_txprbssel => X"0000", 
        --gt_txprecursor => c_txprecursor,
        gtwiz_reset_tx_datapath => sys_reset, 
        
        gtwiz_reset_rx_datapath => sys_reset,

        common0_drpaddr => X"0000", 
        common0_drpdi => X"0000", 
        common0_drpwe => '0',
        common0_drpen => '0', 
        common0_drprdy => OPEN, 
        common0_drpdo => OPEN,

        gt_drpclk => i_dclk_100,
        
        gt0_drpdo => gt_drp_do(0),
        gt1_drpdo => gt_drp_do(1),
        gt2_drpdo => gt_drp_do(2),
        gt3_drpdo => gt_drp_do(3),
        
        gt0_drprdy => gt_drp_rdy(0), 
        gt1_drprdy => gt_drp_rdy(1),
        gt2_drprdy => gt_drp_rdy(2),
        gt3_drprdy => gt_drp_rdy(3),
        
        gt0_drpen => gt_drp_en,
        gt1_drpen => gt_drp_en,
        gt2_drpen => gt_drp_en,
        gt3_drpen => gt_drp_en,
        
        gt0_drpwe => gt_drp_we(0), 
        gt1_drpwe => gt_drp_we(1),
        gt2_drpwe => gt_drp_we(2),
        gt3_drpwe => gt_drp_we(3),
        
        gt0_drpaddr => gt_drp_addr, 
        gt1_drpaddr => gt_drp_addr, 
        gt2_drpaddr => gt_drp_addr, 
        gt3_drpaddr => gt_drp_addr,
        
        gt0_drpdi => gt_drp_di(0), 
        gt1_drpdi => gt_drp_di(1), 
        gt2_drpdi => gt_drp_di(2),
        gt3_drpdi => gt_drp_di(3),
        
        -- PG203 Integrated 100G Ethernet v3.1
        -- DRP clock anything upto 250 MHz.

        
        drp_clk     => i_dclk_100   ,
        drp_addr    => cmac_drp_addr, -- gnd(9 DOWNTO 0), 
        drp_di      => cmac_drp_di, 
        drp_en      => cmac_drp_en,
        drp_we      => cmac_drp_we, 
        drp_do      => cmac_drp_do, 
        drp_rdy     => cmac_drp_rdy,

        gt_powergoodout => OPEN,
        ctl_tx_rsfec_enable => rsfec_tx_enable,
        ctl_rx_rsfec_enable => rsfec_rx_enable, 
        ctl_rsfec_ieee_error_indication_mode => '1',
        ctl_rx_rsfec_enable_correction => '1', 
        ctl_rx_rsfec_enable_indication => '1',

        usr_rx_reset => i_user_rx_reset,
        rx_dataout0 => data_rx_sosi.data(127 DOWNTO 0), rx_dataout1 => data_rx_sosi.data(255 DOWNTO 128),
        rx_dataout2 => data_rx_sosi.data(383 DOWNTO 256), rx_dataout3 => data_rx_sosi.data(511 DOWNTO 384),
        rx_enaout0 => data_rx_sosi.valid(0), rx_enaout1 => data_rx_sosi.valid(1), rx_enaout2 => data_rx_sosi.valid(2), rx_enaout3 => data_rx_sosi.valid(3),
        rx_eopout0 => data_rx_sosi.eop(0), rx_eopout1 => data_rx_sosi.eop(1), rx_eopout2 => data_rx_sosi.eop(2), rx_eopout3 => data_rx_sosi.eop(3),
        rx_errout0 => data_rx_sosi.error(0), 
        rx_errout1 => data_rx_sosi.error(1), 
        rx_errout2 => data_rx_sosi.error(2), 
        rx_errout3 => data_rx_sosi.error(3),
        rx_mtyout0 => data_rx_sosi.empty(0), rx_mtyout1 => data_rx_sosi.empty(1), rx_mtyout2 => data_rx_sosi.empty(2), rx_mtyout3 => data_rx_sosi.empty(3),
        rx_sopout0 => data_rx_sosi.sop(0), rx_sopout1 => data_rx_sosi.sop(1), rx_sopout2 => data_rx_sosi.sop(2), rx_sopout3 => data_rx_sosi.sop(3),
        
        ctl_rx_enable => rx_enable, ctl_rx_force_resync => '0', ctl_rx_test_pattern => '0',
        stat_rx_local_fault => OPEN, stat_rx_block_lock => OPEN,
        rx_otn_bip8_0 => OPEN, rx_otn_bip8_1 => OPEN, rx_otn_bip8_2 => OPEN, rx_otn_bip8_3 => OPEN, rx_otn_bip8_4 => OPEN,
        rx_otn_data_0 => OPEN, rx_otn_data_1 => OPEN, rx_otn_data_2 => OPEN, rx_otn_data_3 => OPEN, rx_otn_data_4 => OPEN,
        rx_otn_ena => OPEN, rx_otn_lane0 => OPEN, rx_otn_vlmarker => OPEN,

        stat_rx_vlan => OPEN, stat_rx_pcsl_demuxed => OPEN,
        --stat_rx_rsfec_am_lock0 => OPEN, 
        --stat_rx_rsfec_am_lock1 => OPEN, 
        --stat_rx_rsfec_am_lock2 => OPEN, 
        --stat_rx_rsfec_am_lock3 => OPEN,
        --stat_rx_rsfec_corrected_cw_inc => OPEN, 
        --stat_rx_rsfec_cw_inc => OPEN,
        --stat_rx_rsfec_err_count0_inc => OPEN, 
        --stat_rx_rsfec_err_count1_inc => OPEN, 
        --stat_rx_rsfec_err_count2_inc => OPEN,
        --stat_rx_rsfec_err_count3_inc => OPEN, stat_rx_rsfec_hi_ser => OPEN, stat_rx_rsfec_lane_alignment_status => OPEN,
        --stat_rx_rsfec_lane_fill_0 => OPEN, stat_rx_rsfec_lane_fill_1 => OPEN, stat_rx_rsfec_lane_fill_2 => OPEN,
        --stat_rx_rsfec_lane_fill_3 => OPEN, stat_rx_rsfec_lane_mapping => OPEN, stat_rx_rsfec_uncorrected_cw_inc => OPEN,
        stat_rx_status => OPEN, stat_rx_test_pattern_mismatch => OPEN,
        stat_rx_remote_fault => rx_remote_fault, 
        stat_rx_bad_fcs => OPEN, 
        stat_rx_stomped_fcs => OPEN, 
        stat_rx_truncated => OPEN,
        stat_rx_internal_local_fault => rx_local_fault, 
        stat_rx_received_local_fault => rx_receive_local_fault, 
        stat_rx_hi_ber => OPEN, 
        stat_rx_got_signal_os => OPEN,
        
        stat_rx_total_bytes             => stat_rx_total_bytes, 
        stat_rx_total_packets           => stat_rx_total_packets, 
        stat_rx_total_good_bytes => OPEN, 
        stat_rx_total_good_packets      => stat_rx_total_good_packets,
        stat_rx_packet_bad_fcs          => stat_rx_packet_bad_fcs, 
        stat_rx_packet_64_bytes         => stat_rx_packet_64_bytes, 
        stat_rx_packet_65_127_bytes     => stat_rx_packet_65_127_bytes, 
        stat_rx_packet_128_255_bytes    => stat_rx_packet_128_255_bytes,
        stat_rx_packet_256_511_bytes    => stat_rx_packet_256_511_bytes, 
        stat_rx_packet_512_1023_bytes   => stat_rx_packet_512_1023_bytes, 
        stat_rx_packet_1024_1518_bytes  => stat_rx_packet_1024_1518_bytes,
        stat_rx_packet_1519_1522_bytes  => stat_rx_packet_1519_1522_bytes, 
        stat_rx_packet_1523_1548_bytes  => stat_rx_packet_1523_1548_bytes, 
        stat_rx_packet_1549_2047_bytes  => stat_rx_packet_1549_2047_bytes,
        stat_rx_packet_2048_4095_bytes  => stat_rx_packet_2048_4095_bytes, 
        stat_rx_packet_4096_8191_bytes  => stat_rx_packet_4096_8191_bytes,
        stat_rx_packet_8192_9215_bytes  => stat_rx_packet_8192_9215_bytes,
        stat_rx_packet_small            => stat_rx_packet_small, 
        stat_rx_packet_large            => stat_rx_packet_large, 
        
        stat_rx_unicast                 => stat_rx_unicast, 
        stat_rx_multicast               => stat_rx_multicast, 
        stat_rx_broadcast               => stat_rx_broadcast, 
        
        stat_rx_oversize                => stat_rx_oversize, 
        stat_rx_toolong                 => stat_rx_toolong, 
        stat_rx_undersize               => stat_rx_undersize,
        stat_rx_fragment                => stat_rx_fragment, 
        stat_rx_jabber => OPEN, 
        stat_rx_bad_code                => stat_rx_bad_code, 
        stat_rx_bad_sfd                 => stat_rx_bad_sfd, 
        stat_rx_bad_preamble            => stat_rx_bad_preamble,
        
        stat_rx_pcsl_number_0 => OPEN, stat_rx_pcsl_number_1 => OPEN, stat_rx_pcsl_number_2 => OPEN, stat_rx_pcsl_number_3 => OPEN,
        stat_rx_pcsl_number_4 => OPEN, stat_rx_pcsl_number_5 => OPEN, stat_rx_pcsl_number_6 => OPEN, stat_rx_pcsl_number_7 => OPEN,
        stat_rx_pcsl_number_8 => OPEN, stat_rx_pcsl_number_9 => OPEN, stat_rx_pcsl_number_10 => OPEN, stat_rx_pcsl_number_11 => OPEN,
        stat_rx_pcsl_number_12 => OPEN, stat_rx_pcsl_number_13 => OPEN, stat_rx_pcsl_number_14 => OPEN, stat_rx_pcsl_number_15 => OPEN,
        stat_rx_pcsl_number_16 => OPEN, stat_rx_pcsl_number_17 => OPEN, stat_rx_pcsl_number_18 => OPEN, stat_rx_pcsl_number_19 => OPEN,
        stat_tx_broadcast => OPEN, stat_tx_multicast => OPEN, stat_tx_unicast => OPEN, stat_tx_vlan => OPEN,
        stat_rx_bip_err_0 => OPEN, stat_rx_bip_err_1 => OPEN, stat_rx_bip_err_2 => OPEN, stat_rx_bip_err_3 => OPEN,
        stat_rx_bip_err_4 => OPEN, stat_rx_bip_err_5 => OPEN, stat_rx_bip_err_6 => OPEN, stat_rx_bip_err_7 => OPEN,
        stat_rx_bip_err_8 => OPEN, stat_rx_bip_err_9 => OPEN, stat_rx_bip_err_10 => OPEN, stat_rx_bip_err_11 => OPEN,
        stat_rx_bip_err_12 => OPEN, stat_rx_bip_err_13 => OPEN, stat_rx_bip_err_14 => OPEN, stat_rx_bip_err_15 => OPEN,
        stat_rx_bip_err_16 => OPEN, stat_rx_bip_err_17 => OPEN, stat_rx_bip_err_18 => OPEN, stat_rx_bip_err_19 => OPEN,
        stat_rx_framing_err_0 => OPEN, stat_rx_framing_err_1 => OPEN, stat_rx_framing_err_2 => OPEN, stat_rx_framing_err_3 => OPEN,
        stat_rx_framing_err_4 => OPEN, stat_rx_framing_err_5 => OPEN, stat_rx_framing_err_6 => OPEN, stat_rx_framing_err_7 => OPEN,
        stat_rx_framing_err_8 => OPEN, stat_rx_framing_err_9 => OPEN, stat_rx_framing_err_10 => OPEN, stat_rx_framing_err_11 => OPEN,
        stat_rx_framing_err_12 => OPEN, stat_rx_framing_err_13 => OPEN, stat_rx_framing_err_14 => OPEN, stat_rx_framing_err_15 => OPEN,
        stat_rx_framing_err_16 => OPEN, stat_rx_framing_err_17 => OPEN, stat_rx_framing_err_18 => OPEN, stat_rx_framing_err_19 => OPEN,
        stat_rx_framing_err_valid_0 => OPEN, stat_rx_framing_err_valid_1 => OPEN, stat_rx_framing_err_valid_2 => OPEN,
        stat_rx_framing_err_valid_3 => OPEN, stat_rx_framing_err_valid_4 => OPEN, stat_rx_framing_err_valid_5 => OPEN,
        stat_rx_framing_err_valid_6 => OPEN, stat_rx_framing_err_valid_7 => OPEN, stat_rx_framing_err_valid_8 => OPEN,
        stat_rx_framing_err_valid_9 => OPEN, stat_rx_framing_err_valid_10 => OPEN, stat_rx_framing_err_valid_11 => OPEN,
        stat_rx_framing_err_valid_12 => OPEN, stat_rx_framing_err_valid_13 => OPEN, stat_rx_framing_err_valid_14 => OPEN,
        stat_rx_framing_err_valid_15 => OPEN, stat_rx_framing_err_valid_16 => OPEN, stat_rx_framing_err_valid_17 => OPEN,
        stat_rx_framing_err_valid_18 => OPEN, stat_rx_framing_err_valid_19 => OPEN, stat_rx_inrangeerr => OPEN, stat_rx_mf_err => OPEN,
        stat_rx_mf_len_err => OPEN, 
        stat_rx_mf_repeat_err => OPEN, stat_rx_misaligned => OPEN,
        stat_rx_aligned => i_rx_locked, stat_rx_aligned_err => OPEN,
        stat_rx_synced => OPEN, stat_rx_synced_err => OPEN,

        usr_tx_reset => i_user_tx_reset,
        tx_unfout => data_tx_siso.underflow, tx_ovfout => data_tx_siso.overflow, tx_rdyout => data_tx_siso.ready,
        tx_datain0 => data_tx_sosi.data(127 DOWNTO 0), tx_datain1 => data_tx_sosi.data(255 DOWNTO 128),
        tx_datain2 => data_tx_sosi.data(383 DOWNTO 256), tx_datain3 => data_tx_sosi.data(511 DOWNTO 384),
        tx_enain0 => data_tx_sosi.valid(0), tx_enain1 => data_tx_sosi.valid(1), tx_enain2 => data_tx_sosi.valid(2), tx_enain3 => data_tx_sosi.valid(3),
        tx_eopin0 => data_tx_sosi.eop(0), tx_eopin1 => data_tx_sosi.eop(1), tx_eopin2 => data_tx_sosi.eop(2), tx_eopin3 => data_tx_sosi.eop(3),
        tx_errin0 => data_tx_sosi.error(0), tx_errin1 => data_tx_sosi.error(1), tx_errin2 => data_tx_sosi.error(2), tx_errin3 => data_tx_sosi.error(3),
        tx_mtyin0 => data_tx_sosi.empty(0), tx_mtyin1 => data_tx_sosi.empty(1), tx_mtyin2 => data_tx_sosi.empty(2), tx_mtyin3 => data_tx_sosi.empty(3),
        tx_sopin0 => data_tx_sosi.sop(0), tx_sopin1 => data_tx_sosi.sop(1), tx_sopin2 => data_tx_sosi.sop(2), tx_sopin3 => data_tx_sosi.sop(3),

        tx_preamblein => (others => '0'), -- gnd(55 DOWNTO 0), 
        rx_preambleout => OPEN, 
        stat_tx_local_fault => OPEN,
        stat_tx_total_bytes => stat_tx_total_bytes, stat_tx_total_packets => stat_tx_total_packets, stat_tx_total_good_bytes => OPEN, stat_tx_total_good_packets => OPEN,
        stat_tx_bad_fcs => OPEN, stat_tx_packet_64_bytes => OPEN, stat_tx_packet_65_127_bytes => OPEN, stat_tx_packet_128_255_bytes => OPEN,
        stat_tx_packet_256_511_bytes => OPEN, stat_tx_packet_512_1023_bytes => OPEN, stat_tx_packet_1024_1518_bytes => OPEN,
        stat_tx_packet_1519_1522_bytes => OPEN, stat_tx_packet_1523_1548_bytes => OPEN, stat_tx_packet_1549_2047_bytes => OPEN,
        stat_tx_packet_2048_4095_bytes => OPEN, stat_tx_packet_4096_8191_bytes => OPEN,stat_tx_packet_8192_9215_bytes => OPEN,
        stat_tx_packet_small => OPEN, stat_tx_packet_large => OPEN, stat_tx_frame_error => OPEN,

        ctl_tx_enable => i_tx_enable, 
        ctl_tx_send_rfi => tx_send_rfi,  
        ctl_tx_send_lfi => tx_send_lfi,  
        ctl_tx_send_idle => tx_send_idle,
        ctl_tx_test_pattern => '0'
    );



--------------------------------------------------------------------------------------------------
-- CMAC DRP Operations
-- As Per PG203 v3.1

cmac_drp_proc : process(i_dclk_100)
begin

    if sys_reset = '1' then
        cmac_drp_sm         <= IDLE;
        cmac_drp_reset      <= '0';
        cmac_drp_di         <= x"0000";
    elsif rising_edge(i_dclk_100) then
--        cmac_drp_di         <= x"0000";
        
        cmac_DRP_SM_Ctl_cache    <= cmac_DRP_SM_Control;
        -- core_drp_reset connects in the IP core to TX_RESET, RX_RESET and RX_SERDES_RESET
        
        -- DRP_EN when 1 perform either read or write
        -- DRP_WE when 0 = read, when 1 = write
        -- DRP_RDY asserted when operation complete, for read this indicates data is ready/valid.

        case cmac_drp_sm is
            when IDLE =>
                if cmac_DRP_SM_Control(0) = '1' AND cmac_DRP_SM_Ctl_cache(0) = '0' then    -- act -> Bit 0 = 0 for read, 1 for write
                    cmac_drp_sm         <= CMD;
                    cmac_drp_addr       <= cmac_DRP_addr_Control;
                    cmac_drp_we         <= cmac_DRP_SM_Control(1);
                    cmac_drp_di         <= cmac_DRP_SM_wr_data;
                    cmac_drp_reset      <= '1';     -- put DRP into reset.
                end if;
            
            when CMD => 
                cmac_drp_en     <= '1';
                cmac_drp_sm     <= READ_DATA;
            
            when READ_DATA => 
                cmac_drp_en     <= '0';
                
                if cmac_drp_rdy = '1' and cmac_drp_we = '0'then     -- IF READING THEN EXIT
                    cmac_drp_sm         <= FINISH;
                    cmac_DRP_SM_rd_data      <= cmac_drp_do;
                elsif cmac_drp_rdy = '1' then                       -- IF NOT MUST BE WRITING, TRIGGER A RD TO VERIFY UPDATE.
                    cmac_drp_sm         <= CMD;
                    cmac_drp_we         <= '0';
                end if;
                            
            when FINISH => 
                cmac_drp_sm         <= IDLE;
                
                cmac_drp_reset      <= '0';     -- Release DRP reset.
            
            
            when others =>
                cmac_drp_sm <= IDLE;
                
        end case;            

    end if;
end process;

-------------------------------------------------------------------------------------
-- Components
gt_drp_proc : process(i_dclk_100)
begin

    if sys_reset = '1' then
        gt_drp_sm         <= IDLE;
--        gt_drp_reset      <= '0';
        gt_drp_di(0)      <= x"0000";
        gt_drp_di(1)      <= x"0000";
        gt_drp_di(2)      <= x"0000";
        gt_drp_di(3)      <= x"0000";
    elsif rising_edge(i_dclk_100) then
--        cmac_drp_di         <= x"0000";
        
        gt_DRP_SM_Ctl_cache    <= gt_DRP_SM_Control;
        -- core_drp_reset connects in the IP core to TX_RESET, RX_RESET and RX_SERDES_RESET
        
        -- DRP_EN when 1 perform either read or write
        -- DRP_WE when 0 = read, when 1 = write
        -- DRP_RDY asserted when operation complete, for read this indicates data is ready/valid.

        case gt_drp_sm is
            when IDLE =>
                if gt_DRP_SM_Control(0) = '1' AND gt_DRP_SM_Ctl_cache(0) = '0' then    -- act -> Bit 0 = 0 for read, 1 for write
                    gt_drp_sm               <= CMD;
                    gt_drp_addr             <= gt_DRP_addr_Control;
                    gt_drp_we(3 downto 0)   <= gt_DRP_SM_Control(4 downto 1);
                    gt_drp_di(0)            <= gt_DRP_SM_wr_data(0);
                    gt_drp_di(1)            <= gt_DRP_SM_wr_data(0);
                    gt_drp_di(2)            <= gt_DRP_SM_wr_data(0);
                    gt_drp_di(3)            <= gt_DRP_SM_wr_data(0);
--                    gt_drp_reset            <= '1';     -- put DRP into reset.
                end if;
            
            when CMD => 
                gt_drp_en     <= '1';
                gt_drp_sm     <= READ_DATA;
            
            when READ_DATA => 
                gt_drp_en     <= '0';
                
                if gt_drp_rdy(0) = '1' and gt_drp_we(0) = '0'then     -- IF READING THEN EXIT
                    gt_drp_sm               <= FINISH;
                    gt_DRP_SM_rd_data(0)    <= gt_drp_do(0);
                    gt_DRP_SM_rd_data(1)    <= gt_drp_do(1);
                    gt_DRP_SM_rd_data(2)    <= gt_drp_do(2);
                    gt_DRP_SM_rd_data(3)    <= gt_drp_do(3);
                elsif gt_drp_rdy(0) = '1' then                       -- IF NOT MUST BE WRITING, TRIGGER A RD TO VERIFY UPDATE.
                    gt_drp_sm               <= CMD;
                    gt_drp_we(3 downto 0)   <= X"0";
                end if;
                            
            when FINISH => 
                gt_drp_sm         <= IDLE;
                
--                gt_drp_reset      <= '0';     -- Release DRP reset.
            
            
            when others =>
                gt_drp_sm <= IDLE;
                
        end case;            

    end if;
end process;


-------------------------------------------------------------------------------------
-- Components

ARGS_DRP_lite : entity DRP_lib.DRP_drp_reg 
    
    PORT MAP (
        -- AXI Lite signals, 300 MHz Clock domain
        MM_CLK                          => i_MACE_clk,
        MM_RST                          => i_MACE_rst,
        
        SLA_IN                          => i_DRP_Lite_axi_mosi,
        SLA_OUT                         => o_DRP_Lite_axi_miso,

        CMAC_DRP_INTERFACE_FIELDS_RW    => cmac_drp_rw_registers,
        
        CMAC_DRP_INTERFACE_FIELDS_RO    => cmac_drp_ro_registers
        
        );

---------------------------------
-- CDC ARGS to logic

-- reset stats
sync_cmac_stat_reset : entity signal_processing_common.sync_vector
    generic map (
        WIDTH => 8
    )
    Port Map ( 
        clock_a_rst => i_MACE_rst,
        Clock_a     => i_MACE_clk,
        data_in     => cmac_drp_rw_registers.cmac_stat_reset,
        
        Clock_b     => i_tx_clk_out,
        data_out    => cmac_stats_reset
    ); 




-- CMAC PORTS       
sync_cmac_DRP_SM_Control : entity signal_processing_common.sync_vector
    generic map (
        WIDTH => 16
    )
    Port Map ( 
        clock_a_rst => i_MACE_rst,
        Clock_a     => i_MACE_clk,
        data_in     => cmac_drp_rw_registers.cmac_drp_sm_control_vector,
        
        Clock_b     => i_dclk_100,
        data_out    => cmac_DRP_SM_Control
    );        
sync_cmac_drp_addr_base : entity signal_processing_common.sync_vector
    generic map (
        WIDTH => 10
    )
    Port Map ( 
        clock_a_rst => i_MACE_rst,
        Clock_a     => i_MACE_clk,
        data_in     => cmac_drp_rw_registers.cmac_drp_addr_base,
        Clock_b     => i_dclk_100,
        data_out    => cmac_DRP_addr_Control
    );
sync_cmac_DRP_SM_wr_data : entity signal_processing_common.sync_vector
    generic map (
        WIDTH => 16
    )
    Port Map ( 
        clock_a_rst => i_MACE_rst,
        Clock_a     => i_MACE_clk,
        data_in     => cmac_drp_rw_registers.cmac_drp_value_to_write,
        
        Clock_b     => i_dclk_100,
        data_out    => cmac_DRP_SM_wr_data
    );

-- GT PORTS

sync_GT_DRP_SM_Control : entity signal_processing_common.sync_vector
    generic map (
        WIDTH => 16
    )
    Port Map ( 
        clock_a_rst => i_MACE_rst,
        Clock_a     => i_MACE_clk,
        data_in     => cmac_drp_rw_registers.gt_drp_sm_control_vector,
        
        Clock_b     => i_dclk_100,
        data_out    => gt_DRP_SM_Control
    );        
sync_GT_drp_addr_base : entity signal_processing_common.sync_vector
    generic map (
        WIDTH => 10
    )
    Port Map ( 
        clock_a_rst => i_MACE_rst,
        Clock_a     => i_MACE_clk,
        data_in     => cmac_drp_rw_registers.gt_drp_addr_base,
        
        Clock_b     => i_dclk_100,
        data_out    => gt_DRP_addr_Control
    );

-- ASSUMING ALL GTs will take the same WR data as they are bonded.
sync_GT0_DRP_SM_wr_data : entity signal_processing_common.sync_vector
    generic map (
        WIDTH => 16
    )
    Port Map ( 
        clock_a_rst => i_MACE_rst,
        Clock_a     => i_MACE_clk,
        data_in     => cmac_drp_rw_registers.gt_0_drp_value_to_write,
        
        Clock_b     => i_dclk_100,
        data_out    => gt_DRP_SM_wr_data(0)
    );


drp_to_host_data_in(0) <= cmac_DRP_SM_rd_data;
drp_to_host_data_in(1) <= GT_DRP_SM_rd_data(0);
drp_to_host_data_in(2) <= GT_DRP_SM_rd_data(1);
drp_to_host_data_in(3) <= GT_DRP_SM_rd_data(2);
drp_to_host_data_in(4) <= GT_DRP_SM_rd_data(3);

sync_DRP_to_Host: FOR i IN 0 TO (DRP_TO_HOST_REGISTERS-1) GENERATE

    DRP_RD_DATA : entity signal_processing_common.sync_vector
        generic map (
            WIDTH => 16
        )
        Port Map ( 
            clock_a_rst => sys_reset,
            Clock_a     => i_dclk_100,
            data_in     => drp_to_host_data_in(i),
            
            Clock_b     => i_MACE_clk,
            data_out    => drp_to_host_data_out(i)
        );  

END GENERATE;

cmac_drp_ro_registers.cmac_drp_return_value     <= drp_to_host_data_out(0);
cmac_drp_ro_registers.gt_0_drp_return_value     <= drp_to_host_data_out(1);
cmac_drp_ro_registers.gt_1_drp_return_value     <= drp_to_host_data_out(2);
cmac_drp_ro_registers.gt_2_drp_return_value     <= drp_to_host_data_out(3);
cmac_drp_ro_registers.gt_3_drp_return_value     <= drp_to_host_data_out(4);
    
DRP_ila : if DEBUG_ILA GENERATE    
    cmac_drp_ila : ila_0
        port map (
            clk                     => i_dclk_100, 
            probe0(15 downto 0)     => cmac_DRP_SM_Control, 
            probe0(31 downto 16)    => cmac_DRP_SM_wr_data,
            probe0(47 downto 32)    => cmac_DRP_SM_rd_data,
            probe0(57 downto 48)    => cmac_DRP_addr_Control,
            probe0(58)              => cmac_drp_reset,
            probe0(59)              => cmac_drp_en,
            probe0(60)              => cmac_drp_rdy,
            probe0(61)              => cmac_drp_we,
            probe0(77 downto 62)    => cmac_drp_di, 
            probe0(93 downto 78)    => cmac_drp_do,
            probe0(103 downto 94)   => cmac_drp_addr,
            probe0(191 downto 104)  => (others => '0')
        );    
    
    gt_drp_ila : ila_0
        port map (
            clk                     => i_dclk_100, 
            probe0(15 downto 0)     => gt_DRP_SM_Control, 
            probe0(31 downto 16)    => gt_DRP_SM_wr_data(0),
            probe0(47 downto 32)    => gt_DRP_SM_rd_data(0),
            probe0(57 downto 48)    => gt_DRP_addr_Control,
            probe0(58)              => gt_drp_reset,
            probe0(59)              => gt_drp_en,
            probe0(63 downto 60)    => gt_drp_rdy,
            probe0(67 downto 64)    => gt_drp_we,
            probe0(83 downto 68)    => gt_drp_di(0), 
            probe0(99 downto 84)    => gt_drp_do(0),
            probe0(109 downto 100)  => gt_drp_addr,
            probe0(191 downto 110)  => (others => '0')
        ); 
END GENERATE;
    
--------------------------------------------------------------------------------
-- STATS TO DRP ARGS
sync_stats_to_Host: FOR i IN 0 TO (STAT_REGISTERS-1) GENERATE

    DRP_RD_DATA : entity signal_processing_common.sync_vector
        generic map (
            WIDTH => 32
        )
        Port Map ( 
            clock_a_rst => tx_rx_counter_reset,
            Clock_a     => i_tx_clk_out,
            data_in     => stats_count(i),
            
            Clock_b     => i_MACE_clk,
            data_out    => stats_to_host_data_out(i)
        );  

END GENERATE;

cmac_drp_ro_registers.cmac_stat_tx_total_packets			<= stats_to_host_data_out(27); 
cmac_drp_ro_registers.cmac_stat_rx_total_packets			<= stats_to_host_data_out(0); 
cmac_drp_ro_registers.cmac_stat_rx_total_good_packets		<= stats_to_host_data_out(1);
cmac_drp_ro_registers.cmac_stat_rx_packet_bad_fcs			<= stats_to_host_data_out(2);
cmac_drp_ro_registers.cmac_stat_rx_packet_64_bytes		    <= stats_to_host_data_out(3);
cmac_drp_ro_registers.cmac_stat_rx_packet_65_127_bytes	    <= stats_to_host_data_out(4);
cmac_drp_ro_registers.cmac_stat_rx_packet_128_255_bytes     <= stats_to_host_data_out(5);
cmac_drp_ro_registers.cmac_stat_rx_packet_256_511_bytes     <= stats_to_host_data_out(6);
cmac_drp_ro_registers.cmac_stat_rx_packet_512_1023_bytes    <= stats_to_host_data_out(7);
cmac_drp_ro_registers.cmac_stat_rx_packet_1024_1518_bytes   <= stats_to_host_data_out(8);
cmac_drp_ro_registers.cmac_stat_rx_packet_1519_1522_bytes   <= stats_to_host_data_out(9);
cmac_drp_ro_registers.cmac_stat_rx_packet_1523_1548_bytes   <= stats_to_host_data_out(10);
cmac_drp_ro_registers.cmac_stat_rx_packet_1549_2047_bytes   <= stats_to_host_data_out(11);
cmac_drp_ro_registers.cmac_stat_rx_packet_2048_4095_bytes   <= stats_to_host_data_out(12);
cmac_drp_ro_registers.cmac_stat_rx_packet_4096_8191_bytes   <= stats_to_host_data_out(13);
cmac_drp_ro_registers.cmac_stat_rx_packet_8192_9215_bytes   <= stats_to_host_data_out(14);
cmac_drp_ro_registers.cmac_stat_rx_packet_small             <= stats_to_host_data_out(15);
cmac_drp_ro_registers.cmac_stat_rx_packet_large             <= stats_to_host_data_out(16);
cmac_drp_ro_registers.cmac_stat_rx_unicast                  <= stats_to_host_data_out(17);
cmac_drp_ro_registers.cmac_stat_rx_multicast                <= stats_to_host_data_out(18);
cmac_drp_ro_registers.cmac_stat_rx_broadcast                <= stats_to_host_data_out(19);
cmac_drp_ro_registers.cmac_stat_rx_oversize                 <= stats_to_host_data_out(20);
cmac_drp_ro_registers.cmac_stat_rx_toolong                  <= stats_to_host_data_out(21);
cmac_drp_ro_registers.cmac_stat_rx_undersize                <= stats_to_host_data_out(22);
cmac_drp_ro_registers.cmac_stat_rx_fragment                 <= stats_to_host_data_out(23);

cmac_drp_ro_registers.cmac_stat_rx_bad_code                 <= stats_to_host_data_out(24);
cmac_drp_ro_registers.cmac_stat_rx_bad_sfd                  <= stats_to_host_data_out(25);
cmac_drp_ro_registers.cmac_stat_rx_bad_preamble             <= stats_to_host_data_out(26);


stats_ila : if DEBUG_ILA GENERATE

    cmac_stats_ila : ila_0
        port map (
            clk                     => i_tx_clk_out, 
            probe0(6 downto 0)      => stat_rx_total_bytes, 
            probe0(9 downto 7)      => stat_rx_total_packets,
            probe0(10)              => stat_rx_total_good_packets,
            probe0(11)              => stat_rx_packet_bad_fcs,
            probe0(12)              => stat_rx_packet_64_bytes,
            probe0(13)              => stat_rx_packet_65_127_bytes,
            probe0(14)              => stat_rx_packet_128_255_bytes,
            probe0(15)              => stat_rx_packet_256_511_bytes,
            probe0(16)              => stat_rx_packet_512_1023_bytes,
            probe0(17)              => stat_rx_packet_1024_1518_bytes,
            probe0(18)              => stat_rx_packet_1519_1522_bytes,
            probe0(19)              => stat_rx_packet_1523_1548_bytes,
            probe0(20)              => stat_rx_packet_1549_2047_bytes,
            probe0(21)              => stat_rx_packet_2048_4095_bytes,
            probe0(22)              => stat_rx_packet_4096_8191_bytes,
            probe0(23)              => stat_rx_packet_8192_9215_bytes,
            probe0(26 downto 24)    => stat_rx_packet_small,
            probe0(27)              => stat_rx_packet_large,
            probe0(28)              => stat_rx_unicast,
            probe0(29)              => stat_rx_multicast,
            probe0(30)              => stat_rx_broadcast,
            probe0(31)              => stat_rx_oversize,
            probe0(32)              => stat_rx_toolong,
            probe0(35 downto 33)    => stat_rx_undersize, 
            probe0(38 downto 36)    => stat_rx_fragment,
            probe0(41 downto 39)    => stat_rx_bad_code,
            probe0(191 downto 42)   => (others => '0')
        );  
END GENERATE;
       
end Behavioral;
