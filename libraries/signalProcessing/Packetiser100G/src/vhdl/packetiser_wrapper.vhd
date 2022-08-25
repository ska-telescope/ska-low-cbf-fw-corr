-------------------------------------------------------------------------------
--
-- File Name: packetiser_wrapper.vhd
-- Contributing Authors: Giles Babich
-- Type: RTL
-- Created: May 2022
--
--
-- Description: 
--  Wrapper for packetiser and ARGs handling.
--
-------------------------------------------------------------------------------

LIBRARY IEEE, common_lib, axi4_lib, ct_lib, DSP_top_lib;
library LFAADecode100G_lib, timingcontrol_lib, capture128bit_lib, captureFine_lib, DSP_top_lib, filterbanks_lib, interconnect_lib, bf_lib, PSR_Packetiser_lib;

USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE common_lib.common_pkg.ALL;
USE common_lib.common_mem_pkg.ALL;
USE axi4_lib.axi4_lite_pkg.ALL;
USE axi4_lib.axi4_stream_pkg.ALL;
USE axi4_lib.axi4_full_pkg.ALL;

use PSR_Packetiser_lib.ethernet_pkg.ALL;
use PSR_Packetiser_lib.CbfPsrHeader_pkg.ALL;

library technology_lib;
USE technology_lib.tech_mac_100g_pkg.ALL;

library xpm;
use xpm.vcomponents.all;

-------------------------------------------------------------------------------
entity packetiser_wrapper is
    generic (
        g_DEBUG_ILA                     : boolean := false
    );
    port (
        -----------------------------------------------------------------------
        -- Data to be transmitted on 100GE
        o_data_tx_sosi              : out t_lbus_sosi;
        i_data_tx_siso              : in t_lbus_siso;
        
        i_clk_100GE                 : in std_logic;
        i_eth100G_locked            : in std_logic;
        
        -- AXI to CMAC interface to be implemented
        o_tx_axis_tdata             : OUT STD_LOGIC_VECTOR(511 downto 0);
        o_tx_axis_tkeep             : OUT STD_LOGIC_VECTOR(63 downto 0);
        o_tx_axis_tvalid            : OUT STD_LOGIC;
        o_tx_axis_tlast             : OUT STD_LOGIC;
        o_tx_axis_tuser             : OUT STD_LOGIC;
        i_tx_axis_tready            : in STD_LOGIC;
        -----------------------------------------------------------------------
        -- Other processing clocks.
        i_clk450 : in std_logic; -- 450 MHz
        i_clk400 : in std_logic; -- 400 MHz

        i_beamData_pipe_1           : std_logic_vector(63 downto 0);
        i_beamPacketCount_pipe_1    : std_logic_vector(36 downto 0);
        i_beamBeam_pipe_1           : std_logic_vector(7 downto 0);
        i_beamFreqIndex_pipe_1      : std_logic_vector(10 downto 0);
        i_beamValid_pipe_1          : std_logic;

        i_beamData_pipe_2           : std_logic_vector(63 downto 0);
        i_beamPacketCount_pipe_2    : std_logic_vector(36 downto 0);
        i_beamBeam_pipe_2           : std_logic_vector(7 downto 0);
        i_beamFreqIndex_pipe_2      : std_logic_vector(10 downto 0);
        i_beamValid_pipe_2          : std_logic;

        i_beamData_pipe_3           : std_logic_vector(63 downto 0);
        i_beamPacketCount_pipe_3    : std_logic_vector(36 downto 0);
        i_beamBeam_pipe_3           : std_logic_vector(7 downto 0);
        i_beamFreqIndex_pipe_3      : std_logic_vector(10 downto 0);
        i_beamValid_pipe_3          : std_logic;

        -----------------------------------------------------------------------

        -- MACE AXI slave interfaces for modules
        -- The 300MHz MACE_clk is also used for some of the signal processing
        i_MACE_clk  : in std_logic;
        i_MACE_rst  : in std_logic;
       
        -- Stream 1
        i_PSR_packetiser_Lite_axi_mosi : in t_axi4_lite_mosi; 
        o_PSR_packetiser_Lite_axi_miso : out t_axi4_lite_miso;
        
        i_PSR_packetiser_Full_axi_mosi : in  t_axi4_full_mosi;
        o_PSR_packetiser_Full_axi_miso : out t_axi4_full_miso;

        -- Stream 2
        i_PSR_packetiser_2_Lite_axi_mosi : in t_axi4_lite_mosi; 
        o_PSR_packetiser_2_Lite_axi_miso : out t_axi4_lite_miso;
        
        i_PSR_packetiser_2_Full_axi_mosi : in  t_axi4_full_mosi;
        o_PSR_packetiser_2_Full_axi_miso : out t_axi4_full_miso;

        -- Stream 3
        i_PSR_packetiser_3_Lite_axi_mosi : in t_axi4_lite_mosi; 
        o_PSR_packetiser_3_Lite_axi_miso : out t_axi4_lite_miso;
        
        i_PSR_packetiser_3_Full_axi_mosi : in  t_axi4_full_mosi;
        o_PSR_packetiser_3_Full_axi_miso : out t_axi4_full_miso
    );
END packetiser_wrapper;

-------------------------------------------------------------------------------
ARCHITECTURE structure OF packetiser_wrapper IS
   
COMPONENT ila_0
PORT (
    clk : IN STD_LOGIC;
    probe0 : IN STD_LOGIC_VECTOR(191 DOWNTO 0));
END COMPONENT;

---------------------------------------------------------------------------
-- SIGNAL DECLARATIONS  --
--------------------------------------------------------------------------- 

signal cmac_reset                       : std_logic;

signal beamformer_to_packetiser_data    :  packetiser_stream_in; 
signal beamformer_to_packetiser_data_2  :  packetiser_stream_in;
signal beamformer_to_packetiser_data_3  :  packetiser_stream_in;
 
signal packet_stream_stats              :  t_packetiser_stats(2 downto 0);

signal packetiser_stream_1_host_bus_in  : packetiser_config_in;
signal packetiser_stream_2_host_bus_in  : packetiser_config_in;
signal packetiser_stream_3_host_bus_in  : packetiser_config_in;
  
signal packetiser_host_bus_out          : packetiser_config_out;  
signal packetiser_host_bus_out_2        : packetiser_config_out;
signal packetiser_host_bus_out_3        : packetiser_config_out;  

signal packetiser_host_bus_ctrl         :  packetiser_stream_ctrl;
signal packetiser_host_bus_ctrl_2       :  packetiser_stream_ctrl;
signal packetiser_host_bus_ctrl_3       :  packetiser_stream_ctrl;


begin
    


-----------------------------------------------------------------------------------------------
cmac_reset <= NOT i_eth100G_locked;
    
-- 100GE output 
packet_generator : entity PSR_Packetiser_lib.psr_packetiser100G_Top 
Generic Map (
    g_DEBUG_ILA                 => g_DEBUG_ILA,
    Number_of_stream            => 3,
    packet_type                 => 3
)
Port Map ( 
    -- ~322 MHz
    i_cmac_clk                  => i_clk_100GE,
    i_cmac_rst                  => cmac_reset,
    
    i_packetiser_clk            => i_clk400,
    i_packetiser_rst            => '0',
    
    -- Lbus to MAC
    o_data_to_transmit          => o_data_tx_sosi,
    i_data_to_transmit_ctl      => i_data_tx_siso,
    
    -- AXI to CMAC interface to be implemented
    o_tx_axis_tdata             => o_tx_axis_tdata,
    o_tx_axis_tkeep             => o_tx_axis_tkeep,
    o_tx_axis_tvalid            => o_tx_axis_tvalid,
    o_tx_axis_tlast             => o_tx_axis_tlast,
    o_tx_axis_tuser             => o_tx_axis_tuser,
    i_tx_axis_tready            => '0',
    
    -- signals from signal processing/HBM/the moon/etc
    packet_stream_ctrl          => packetiser_host_bus_ctrl,
    
    packet_stream_stats         => packet_stream_stats,
            
    packet_stream(0)            => beamformer_to_packetiser_data,
    packet_stream(1)            => beamformer_to_packetiser_data_2,
    packet_stream(2)            => beamformer_to_packetiser_data_3,
    packet_stream_out           => open,
    
    -- AXI BRAM to packetiser
    packet_config_in_stream_1   => packetiser_stream_1_host_bus_in,
    packet_config_in_stream_2   => packetiser_stream_2_host_bus_in,
    packet_config_in_stream_3   => packetiser_stream_3_host_bus_in,
    
    -- AXI BRAM return path from packetiser 
    packet_config_stream_1      => packetiser_host_bus_out.config_data_out,
    packet_config_stream_2      => packetiser_host_bus_out_2.config_data_out,
    packet_config_stream_3      => packetiser_host_bus_out_3.config_data_out
    
);
------------------------------
-- PIPE 1
beamformer_to_packetiser_data.data_clk                  <= i_clk400;
beamformer_to_packetiser_data.data_in_wr                <= i_beamValid_pipe_1;
beamformer_to_packetiser_data.data(511 downto 64)       <= (others =>'0');
beamformer_to_packetiser_data.data(63 downto 0)         <= i_beamData_pipe_1;
beamformer_to_packetiser_data.bytes_to_transmit         <= (others =>'0');
    
-- PST signals are passed with data to make headers on the fly. Zero out for other packet types.
beamformer_to_packetiser_data.PST_virtual_channel       <= i_beamFreqIndex_pipe_1(9 downto 0);
beamformer_to_packetiser_data.PST_beam                  <= i_beamBeam_pipe_1;
beamformer_to_packetiser_data.PST_time_ref              <= i_beamPacketCount_pipe_1;

------------------------------
-- PIPE 2
beamformer_to_packetiser_data_2.data_clk                <= i_clk400;
beamformer_to_packetiser_data_2.data_in_wr              <= i_beamValid_pipe_2;
beamformer_to_packetiser_data_2.data(511 downto 64)     <= (others =>'0');
beamformer_to_packetiser_data_2.data(63 downto 0)       <= i_beamData_pipe_2;
beamformer_to_packetiser_data_2.bytes_to_transmit       <= (others =>'0');
    
-- PST signals are passed with data to make headers on the fly. Zero out for other packet types.
beamformer_to_packetiser_data_2.PST_virtual_channel     <= i_beamFreqIndex_pipe_2(9 downto 0);
beamformer_to_packetiser_data_2.PST_beam                <= i_beamBeam_pipe_2;
beamformer_to_packetiser_data_2.PST_time_ref            <= i_beamPacketCount_pipe_2;

------------------------------
-- PIPE 3
beamformer_to_packetiser_data_3.data_clk                <= i_clk400;
beamformer_to_packetiser_data_3.data_in_wr              <= i_beamValid_pipe_3;
beamformer_to_packetiser_data_3.data(511 downto 64)     <= (others =>'0');
beamformer_to_packetiser_data_3.data(63 downto 0)       <= i_beamData_pipe_3;
beamformer_to_packetiser_data_3.bytes_to_transmit       <= (others =>'0');
    
-- PST signals are passed with data to make headers on the fly. Zero out for other packet types.
beamformer_to_packetiser_data_3.PST_virtual_channel     <= i_beamFreqIndex_pipe_3(9 downto 0);
beamformer_to_packetiser_data_3.PST_beam                <= i_beamBeam_pipe_3;
beamformer_to_packetiser_data_3.PST_time_ref            <= i_beamPacketCount_pipe_3;

-------------------------------------------------------------------------------------------------------------

packetiser_host : entity PSR_Packetiser_lib.cmac_args 
    Port Map ( 
    
        -- ARGS interface
        -- MACE clock is 300 MHz
        i_MACE_clk                          => i_MACE_clk,
        i_MACE_rst                          => i_MACE_rst,
        
        i_packetiser_clk                    => i_clk400,
        
        i_PSR_packetiser_Lite_axi_mosi      => i_PSR_packetiser_Lite_axi_mosi,
        o_PSR_packetiser_Lite_axi_miso      => o_PSR_packetiser_Lite_axi_miso,
        
        i_PSR_packetiser_Full_axi_mosi      => i_PSR_packetiser_Full_axi_mosi,
        o_PSR_packetiser_Full_axi_miso      => o_PSR_packetiser_Full_axi_miso,
        
        o_packet_stream_ctrl                => packetiser_host_bus_ctrl,
                
        i_packet_stream_stats               => packet_stream_stats,
                
        o_packet_config                     => packetiser_stream_1_host_bus_in,
        i_packet_config_out                 => packetiser_host_bus_out

    );


packetiser_host_pipe2 : entity PSR_Packetiser_lib.cmac_args 
    Port Map ( 
    
        -- ARGS interface
        -- MACE clock is 300 MHz
        i_MACE_clk                          => i_MACE_clk,
        i_MACE_rst                          => i_MACE_rst,
        
        i_packetiser_clk                    => i_clk400,
        
        i_PSR_packetiser_Lite_axi_mosi      => i_PSR_packetiser_2_Lite_axi_mosi,
        o_PSR_packetiser_Lite_axi_miso      => o_PSR_packetiser_2_Lite_axi_miso,
        
        i_PSR_packetiser_Full_axi_mosi      => i_PSR_packetiser_2_Full_axi_mosi,
        o_PSR_packetiser_Full_axi_miso      => o_PSR_packetiser_2_Full_axi_miso,
        
        o_packet_stream_ctrl                => packetiser_host_bus_ctrl_2,
                
        i_packet_stream_stats               => packet_stream_stats,
                
        o_packet_config                     => packetiser_stream_2_host_bus_in,
        i_packet_config_out                 => packetiser_host_bus_out_2

    );
    
packetiser_host_pipe3 : entity PSR_Packetiser_lib.cmac_args 
    Port Map ( 
    
        -- ARGS interface
        -- MACE clock is 300 MHz
        i_MACE_clk                          => i_MACE_clk,
        i_MACE_rst                          => i_MACE_rst,
        
        i_packetiser_clk                    => i_clk400,
        
        i_PSR_packetiser_Lite_axi_mosi      => i_PSR_packetiser_3_Lite_axi_mosi,
        o_PSR_packetiser_Lite_axi_miso      => o_PSR_packetiser_3_Lite_axi_miso,
        
        i_PSR_packetiser_Full_axi_mosi      => i_PSR_packetiser_3_Full_axi_mosi,
        o_PSR_packetiser_Full_axi_miso      => o_PSR_packetiser_3_Full_axi_miso,
        
        o_packet_stream_ctrl                => packetiser_host_bus_ctrl_3,
                
        i_packet_stream_stats               => packet_stream_stats,
                
        o_packet_config                     => packetiser_stream_3_host_bus_in,
        i_packet_config_out                 => packetiser_host_bus_out_3

    );    
-----------------------------------------------------------------------------------------------


    
END structure;
