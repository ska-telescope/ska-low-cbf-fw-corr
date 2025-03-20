----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey
-- 
-- Create Date: 19/03/2025 10:14:24 PM
-- Module Name: ct1_test3_top_tb - Behavioral
-- Description: 
--  Instantiate ct1_tb with generics set for "test3" 
--  The configuration for "test3" is defined in ./test/test3.yaml
--  In the test directory:
--   * Generate the input files files by running:
--     > python3 ct1_test.py -d test3.txt -t test3_ct1_out.txt test3.yaml
--   * Run the simulation for 7.5 ms
--     - This is sufficent for a 283 ms, 8 virtual channel frame to come out of ct1
--   * Run the python again, to check the results: 
--     > python3 ct1_test.py -d test3.txt -t test3_ct1_out.txt test3.yaml
----------------------------------------------------------------------------------

library IEEE, correlator_lib, ct_lib, common_lib, filterbanks_lib;
use IEEE.STD_LOGIC_1164.ALL;
Library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;
use IEEE.NUMERIC_STD.ALL;
use std.textio.all;
use IEEE.std_logic_textio.all;
USE ct_lib.corr_ct1_reg_pkg.ALL;
USE common_lib.common_pkg.ALL;
library DSP_top_lib;
use DSP_top_lib.DSP_top_pkg.all;

entity ct1_test3_top_tb is
end ct1_test3_top_tb;

architecture Behavioral of ct1_test3_top_tb is

begin

    dut : entity work.ct1_tb
    generic map(
        -- Number of virtual channels to generate input data for
        g_VIRTUAL_CHANNELS => 8,
        -- Number of virtual channels configured in the ingest module for each set of tables.
        g_CT1_VIRTUAL_CHANNELS0 => 8,
        g_CT1_VIRTUAL_CHANNELS1 => 8,
        g_PACKET_GAP => 1000,
        -- 
        g_PACKET_COUNT_START => x"00000000104E",
        g_REGISTER_INIT_FILENAME => "/home/hum089/projects/perentie/corr_latest/ska-low-cbf-fw-corr/libraries/signalProcessing/cornerturn1/test/test3.txt",
        g_CT1_OUT_FILENAME       => "/home/hum089/projects/perentie/corr_latest/ska-low-cbf-fw-corr/libraries/signalProcessing/cornerturn1/test/test3_ct1_out.txt",
        g_FB_OUT_FILENAME  => "/home/hum089/projects/perentie/corr_latest/ska-low-cbf-fw-corr/libraries/signalProcessing/cornerturn1/test/test3_fb_out.txt",
        g_RIPPLE_SELECT => x"00000001", -- 0 for identity, 1 for TPM 16d correction, 2 for TPM 18a correction 
        g_USE_FILTERBANK => '0'
    );
   

end Behavioral;
