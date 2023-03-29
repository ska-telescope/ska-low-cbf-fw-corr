----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 03/20/2023 02:34:53 PM
-- Module Name: tb_top_1sa_2stations - Behavioral
-- Description: 
--  Instantiate the correlator test bench for a particular test case.
-- 
----------------------------------------------------------------------------------
library IEEE, correlator_lib;
use IEEE.STD_LOGIC_1164.ALL;
use correlator_lib.all;

entity tb_top_1sa_2stations is
--  Port ( );
end tb_top_1sa_2stations;

architecture Behavioral of tb_top_1sa_2stations is

begin

    tbinst : entity correlator_lib.tb_correlatorCore
    generic map (
        g_SPS_PACKETS_PER_FRAME => 128, -- : integer := 128;
        g_CORRELATORS => 0, -- : integer := 0; -- Number of correlator instances to instantiate (0, 1, 2)
        g_USE_DUMMY_FB => FALSE, -- boolean := FALSE
        -- Location of the test case; All the other filenames in generics here are in this directory
        g_TEST_CASE => "../../../../../../../../low-cbf-model/src_atomic/run_cor_1sa_2stations_cof/", --  string := "../../../../../../../../low-cbf-model/src_atomic/run_cor_1sa_6stations_cof/";
        -- text file with SPS packets
        g_SPS_DATA_FILENAME => "sps_axi_tb_input.txt", -- string := "sps_axi_tb_input.txt";
        -- Register initialisation
        g_REGISTER_INIT_FILENAME => "tb_registers.txt", -- string := "tb_registers.txt";
        -- File to log the output data to (the 100GE axi interface)
        g_SDP_FILENAME => "tb_SDP_data_out.txt", -- string := "tb_SDP_data_out.txt";
        -- initialisation of corner turn 1 HBM
        g_LOAD_CT1_HBM => False, -- : boolean := False;
        g_CT1_INIT_FILENAME => "", -- : string := "";
        -- initialisation of corner turn 2 HBM
        g_LOAD_CT2_HBM_CORR1 => False, -- : boolean := True;
        g_CT2_HBM_CORR1_FILENAME => "", -- : string := "ct2_init.txt";
        g_LOAD_CT2_HBM_CORR2 => False, -- : boolean := False;
        g_CT2_HBM_CORR2_FILENAME => "", -- : string := "";
        --
        --
        -- Text file to use to check against the visibility data going to the HBM from the correlator.
        g_VIS_CHECK_FILE => "LTA_vis_check.txt", --  : string := "LTA_vis_check.txt";
        -- Text file to use to check the meta data going to the HBM from the correlator
        g_META_CHECK_FILE => "LTA_TCI_FD_check.txt", -- : string := "LTA_TCI_FD_check.txt"
        -- Number of bytes to dump from the filterbank output
        g_CT2_HBM_DUMP_SIZE => 2097152, -- 2 Mbytes, enough to get a whole coarse channel for 4 stations
        g_CT2_HBM_DUMP_ADDR => 0, -- : integer := 0; -- Address to start the memory dump at.
        g_CT2_HBM_DUMP_FNAME => "ct2_hbm_dump.txt"
    );
    -- port map ();

end Behavioral;
