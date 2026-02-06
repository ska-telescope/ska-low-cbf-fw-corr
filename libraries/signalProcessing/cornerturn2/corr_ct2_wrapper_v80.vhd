----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: Jan 2025
-- Module Name: corr_ct2_wrapper_v80.vhd
-- Description: 
--    Corner turn between the filterbanks and the correlator for SKA correlator processing. 
--    Includes corner turn module and NOC components
-- 
----------------------------------------------------------------------------------
library IEEE, ct_lib, DSP_top_lib, common_lib, axi4_lib;
Library xpm, correlator_lib, noc_lib, signal_processing_common;

use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use DSP_top_lib.DSP_top_pkg.all;
use common_lib.common_pkg.ALL;
use axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.ALL;
use ct_lib.corr_ct2_reg_pkg.all;
use xpm.vcomponents.all;
use signal_processing_common.target_fpga_pkg.ALL;

entity corr_ct2_wrapper_v80 is
    generic (
        g_USE_META          : boolean := FALSE; -- Put meta data into the memory in place of the actual data, to make it easier to find bugs in the corner turn. 
        g_MAX_CORRELATORS   : integer := 6;     -- Maximum number of correlator cells that can be instantiated.
        g_GENERATE_ILA      : BOOLEAN := FALSE
    );
    port(
        -- Registers AXI Lite Interface (uses i_axi_clk)
        i_axi_clk  : in std_logic;
        i_axi_rst  : in std_logic;
        -- pipelined reset from first stage corner turn ?
        i_rst : in std_logic;   -- First data received after this reset is placed in the first 283ms block in a 849 ms integration.
        -- Data in from the correlator filterbanks; bursts of 3456 clocks for each channel.
        -- (on i_axi_clk)
        i_sof          : in std_logic; -- pulse high at the start of every frame. (1 frame is 283 ms of data).
        i_integration  : in std_logic_vector(31 downto 0); -- frame count is the same for all simultaneous output streams.
        i_ctFrame      : in std_logic_vector(1 downto 0);  -- 283 ms frame within each integration interval
        i_virtualChannel : in t_slv_16_arr(3 downto 0);    -- 4 virtual channels, one for each of the data streams.
        i_bad_poly     : in std_logic_vector(2 downto 0);  -- one signal for each group of 4 virtual channels
        i_lastChannel  : in std_logic;   -- last of the group of 4 channels
        i_demap_table_select : in std_logic;
        i_HeaderValid : in std_logic_vector(11 downto 0);
        i_data        : in t_ctc_output_payload_arr(11 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), ..., i_data(11)
        i_dataValid   : in std_logic;
        -- control data out to the correlator arrays
        -- packets of data to each correlator instance
        o_cor_cfg_data  : out t_slv_8_arr(5 downto 0); -- 8 bit wide buses, to 6 correlators.
        o_cor_cfg_first : out std_logic_vector(5 downto 0);
        o_cor_cfg_last  : out std_logic_vector(5 downto 0);
        o_cor_cfg_valid : out std_logic_vector(5 downto 0);
   
    );
end corr_ct2_wrapper_v80;

architecture Behavioral of corr_ct2_wrapper_v80 is
    
    signal statctrl_ro : t_statctrl_ro;
    signal statctrl_rw : t_statctrl_rw;
    signal frameCount_mod3 : std_logic_vector(1 downto 0) := "00";
    signal frameCount_849ms : std_logic_vector(31 downto 0) := (others => '0');
    --signal frameCount_startup : std_logic := '1';
    signal buf0_fineIntegrations, buf1_fineIntegrations : std_logic_vector(4 downto 0);
    signal vc_demap_in : t_statctrl_vc_demap_ram_in;
    signal subarray_beam_in : t_statctrl_subarray_beam_ram_in;
    signal vc_demap_out : t_statctrl_vc_demap_ram_out;
    signal subarray_beam_out : t_statctrl_subarray_beam_ram_out;
    signal vc_demap_rd_data, SB_rd_data : std_logic_vector(31 downto 0);
    signal vc_demap_rd_addr : std_logic_vector(9 downto 0);
    signal din_SB_addr : std_logic_vector(7 downto 0);
    
    signal noc_wren                 : STD_LOGIC;
    signal noc_rden                 : STD_LOGIC;
    signal noc_wr_adr               : STD_LOGIC_VECTOR(17 DOWNTO 0);
    signal noc_wr_dat               : STD_LOGIC_VECTOR(31 DOWNTO 0);
    signal noc_rd_adr               : STD_LOGIC_VECTOR(17 DOWNTO 0);
    signal noc_rd_dat               : STD_LOGIC_VECTOR(31 DOWNTO 0);
    signal noc_rd_dat_mux           : STD_LOGIC_VECTOR(31 DOWNTO 0);
    signal bram_addr_d1             : STD_LOGIC_VECTOR(17 DOWNTO 0);
    signal bram_addr_d2             : STD_LOGIC_VECTOR(17 DOWNTO 0);
    signal max_copyAW_time : std_logic_vector(31 downto 0); -- time required to put out all the addresses
    signal max_copyData_time : std_logic_vector(31 downto 0); -- time required to put out all the data
    signal min_trigger_interval : std_logic_Vector(31 downto 0); -- minimum time available
    signal wr_overflow : std_logic_vector(31 downto 0); --
    signal dout_min_start_gap : std_logic_vector(31 downto 0);
    
    signal HBM_axi_aw : t_axi4_full_addr_arr(1 downto 0); -- write address bus : out t_axi4_full_addr_arr(4 downto 0)(.valid, .addr(39:0), .len(7:0))
    signal HBM_axi_awready : std_logic_vector(1 downto 0);
    signal HBM_axi_w : t_axi4_full_data_arr(1 downto 0); -- w data bus : out t_axi4_full_data_arr(4 downto 0)(.valid, .data(511:0), .last, .resp(1:0))
    signal HBM_axi_wready : std_logic_vector(1 downto 0);
    signal HBM_axi_b : t_axi4_full_b_arr(1 downto 0);     -- write response bus : in t_axi4_full_b_arr(4 downto 0)(.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
    signal HBM_axi_ar_dummy : t_axi4_full_addr;
    
begin


    ct2topi : entity ct_lib.corr_ct2_top_v80
    generic map (
        g_USE_META   => g_USE_META,              -- boolean := FALSE; -- Put meta data into the memory in place of the actual data, to make it easier to find bugs in the corner turn.
        g_MAX_CORRELATORS => g_MAX_CORRELATORS,  -- integer := 6;     -- Maximum number of correlator cells that can be instantiated.
        g_GENERATE_ILA => g_GENERATE_ILA         -- BOOLEAN := FALSE
    ) port map(
        -- Registers AXI Lite Interface (uses i_axi_clk)
        i_axi_clk  => i_axi_clk, -- in std_logic;
        i_axi_rst  => i_axi_rst, -- in std_logic;
        -- Pipelined reset from first stage corner turn
        i_rst  => i_rst, --  in std_logic;   -- First data received after this reset is placed in the first 283ms block in a 849 ms integration.
        -- Registers NOC interface
        i_noc_wren    => noc_wren, -- in STD_LOGIC;
        i_noc_rden    => noc_rden, -- in STD_LOGIC;
        i_noc_wr_adr  => noc_wr_adr, -- in STD_LOGIC_VECTOR(17 DOWNTO 0);
        i_noc_wr_dat  => noc_wr_dat, -- in STD_LOGIC_VECTOR(31 DOWNTO 0);
        i_noc_rd_adr  => noc_rd_adr, -- in STD_LOGIC_VECTOR(17 DOWNTO 0);
        o_noc_rd_dat  => noc_rd_dat, -- out STD_LOGIC_VECTOR(31 DOWNTO 0);
        -------------------------------------------------------------------------------------
        -- hbm reset   
        o_hbm_reset_c1      : out std_logic;
        i_hbm_status_c1     : in std_logic_vector(7 downto 0);
        o_hbm_reset_c2      : out std_logic;
        i_hbm_status_c2     : in std_logic_vector(7 downto 0);
        o_hbm_reset_c3      : out std_logic;
        i_hbm_status_c3     : in std_logic_vector(7 downto 0);
        o_hbm_reset_c4      : out std_logic;
        i_hbm_status_c4     : in std_logic_vector(7 downto 0);
        o_hbm_reset_c5      : out std_logic;
        i_hbm_status_c5     : in std_logic_vector(7 downto 0);
        o_hbm_reset_c6      : out std_logic;
        i_hbm_status_c6     : in std_logic_vector(7 downto 0);
        ------------------------------------------------------------------------------------
        -- Data in from the correlator filterbanks; bursts of 3456 clocks for each channel.
        -- (on i_axi_clk)
        i_sof          => i_sof, --  in std_logic; -- pulse high at the start of every frame. (1 frame is 283 ms of data).
        i_integration  => i_integration, -- in std_logic_vector(31 downto 0); -- frame count is the same for all simultaneous output streams.
        i_ctFrame      => i_ctFrame, --  in std_logic_vector(1 downto 0);  -- 283 ms frame within each integration interval
        i_virtualChannel => i_virtualChannel, --  in t_slv_16_arr(3 downto 0);    -- 4 virtual channels, one for each of the data streams.
        i_bad_poly     => i_bad_poly, -- in std_logic_vector(2 downto 0);  -- one signal for each group of 4 virtual channels
        i_lastChannel  => i_lastChannel, -- in std_logic;   -- last of the group of 4 channels
        i_demap_table_select => i_demap_table_select, --  in std_logic;
        i_HeaderValid => i_headerValid, --  in std_logic_vector(3 downto 0);
        i_data        => i_data, --  in t_ctc_output_payload_arr(11 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), ..., i_data(11)
        i_dataValid   => i_dataValid, --  in std_logic;
        ---------------------------------------------------------------
        -- Data out to the correlator arrays
        -- packets of data to each correlator instance
        -- Sends a single packet full of instructions to each correlator, at the start of each 849ms corner turn frame readout.
        -- The first byte sent is the number of subarray-beams configured
        -- The remaining (128 subarray-beams) * (4 words/subarray-beam) * (4 bytes/word) = 2048 bytes contains the subarray-beam table for the correlator
        -- The LSB of the 4th word contains the bad_poly bit for the subarray beam.
        -- The correlator should use (o_cor_cfg_last and o_cor_cfg_valid) to trigger processing 849ms of data.
        o_cor_cfg_data  => o_cor_cfg_data,  -- out t_slv_8_arr(5 downto 0); -- 8 bit wide buses, to 6 correlators.
        o_cor_cfg_first => o_cor_cfg_first, -- out std_logic_vector(5 downto 0);
        o_cor_cfg_last  => o_cor_cfg_last,  -- out std_logic_vector(5 downto 0);
        o_cor_cfg_valid => o_cor_cfg_valid, -- out std_logic_vector(5 downto 0);
        -----------------------------------------------------------------
        -- AXI interface to the HBM
        -- Corner turn between filterbanks and correlator
        -- Expected to be up to 18 Gbyte of unified memory used by the correlators
        o_HBM_axi_aw      => HBM_axi_aw,      -- out t_axi4_full_addr_arr(1 downto 0); -- write address bus : out t_axi4_full_addr_arr(4 downto 0)(.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_awready => HBM_axi_awready, -- in std_logic_vector(1 downto 0);
        o_HBM_axi_w       => HBM_axi_w,       -- out t_axi4_full_data_arr(1 downto 0); -- w data bus : out t_axi4_full_data_arr(4 downto 0)(.valid, .data(511:0), .last, .resp(1:0))
        i_HBM_axi_wready  => HBM_axi_wready,  -- in std_logic_vector(1 downto 0);
        i_HBM_axi_b       => HBM_axi_b,       -- in t_axi4_full_b_arr(1 downto 0);     -- write response bus : in t_axi4_full_b_arr(4 downto 0)(.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        
        -- signals used in testing to initiate readout of the buffer when HBM is preloaded with data,
        -- so we don't have to wait for the previous processing stages to complete.
        i_readout_start  => '0', --  in std_logic;
        i_readout_buffer => '0', -- in std_logic;
        i_readout_frameCount => (others => '0'), -- in std_logic_vector(31 downto 0);
        i_freq_index0_repeat => '0', --  in std_logic;
        -- debug
        i_hbm_status  : in t_slv_8_arr(5 downto 0);
        i_hbm_reset_final : in std_logic;
        i_eth_disable_fsm_dbg : in std_logic_vector(4 downto 0);
        --
        i_hbm0_rst_dbg : in std_logic_vector(31 downto 0);
        i_hbm1_rst_dbg : in std_logic_vector(31 downto 0);
        i_hbm2_rst_dbg : in std_logic_vector(31 downto 0);
        i_hbm3_rst_dbg : in std_logic_vector(31 downto 0);
        i_hbm4_rst_dbg : in std_logic_vector(31 downto 0);
        i_hbm5_rst_dbg : in std_logic_vector(31 downto 0)
    );
    
    -- Registers NOC interface
    i_ct2_noc : entity noc_lib.args_noc
    generic map (
        G_DEBUG => FALSE
    ) port map ( 
        i_clk       => i_axi_clk,
        i_rst       => i_axi_rst,
        noc_wren    => noc_wren,
        noc_rden    => noc_rden,
        noc_wr_adr  => noc_wr_adr,
        noc_wr_dat  => noc_wr_dat,
        noc_rd_adr  => noc_rd_adr,
        noc_rd_dat  => noc_rd_dat
    );
    
    
    ------------------------------------------------------------------
    -- Instantiate HBM 
    -- two interface for writing to HBM only. 
    -- CT2 reads occur in the correlators.
    
    HBM0i : entity work.hbm_noc_if
    generic map (
        g_HBM_base_addr : std_logic_vector(63 downto 0) := x"0000004600000000";  -- default is the HBM base address
        g_NOC_FABRIC : string := "pl_hbm"  -- "pl_hbm" for the native HBM interfaces at the top of the chip or "VNOC" for other NOC interfaces
    ) port map (
        clk  => i_axi_clk, --  in std_logic;
        -- write
        i_HBM_axi_aw      => HBM_axi_aw, --  in t_axi4_full_addr; -- write address bus : out t_axi4_full_addr(.valid, .addr(39:0), .len(7:0))
        o_HBM_axi_awready => hbm_axi_awready, -- out std_logic;
        i_HBM_axi_w       => HBM_axi_w, -- in t_axi4_full_data; -- w data bus : out t_axi4_full_data(.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_wready  => HBM_axi_wready, -- out std_logic;
        o_HBM_axi_b       => HBM_axi_b, --out t_axi4_full_b;     -- write response bus : in t_axi4_full_b(.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        i_HBM_axi_bready  => HBM_axi_bready, -- in std_logic;
        -- read
        i_HBM_axi_ar => HBM_axi_ar_dummy, -- in t_axi4_full_addr;
        o_HBM_axi_arready => HBM_axi_arready, -- out std_logic;
        o_HBM_axi_r  => HBM_axi_r, -- out t_axi4_full_data;
        i_HBM_axi_rready => HBM_axi_rready_dummy -- in std_logic
    );
    
    HBM1i : entity work.hbm_noc_if
    generic map (
        g_HBM_base_addr : std_logic_vector(63 downto 0) := x"0000004600000000";  -- default is the HBM base address
        g_NOC_FABRIC : string := "pl_hbm"  -- "pl_hbm" for the native HBM interfaces at the top of the chip or "VNOC" for other NOC interfaces
    ) port map (
        clk  => i_axi_clk, --  in std_logic;
        -- write
        i_HBM_axi_aw      => HBM_axi_aw, --  in t_axi4_full_addr; -- write address bus : out t_axi4_full_addr(.valid, .addr(39:0), .len(7:0))
        o_HBM_axi_awready => hbm_axi_awready, -- out std_logic;
        i_HBM_axi_w       => HBM_axi_w, -- in t_axi4_full_data; -- w data bus : out t_axi4_full_data(.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_wready  => HBM_axi_wready, -- out std_logic;
        o_HBM_axi_b       => HBM_axi_b, --out t_axi4_full_b;     -- write response bus : in t_axi4_full_b(.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        i_HBM_axi_bready  => HBM_axi_bready, -- in std_logic;
        -- read
        i_HBM_axi_ar => HBM_axi_ar_dummy, -- in t_axi4_full_addr;
        o_HBM_axi_arready => HBM_axi_arready, -- out std_logic;
        o_HBM_axi_r  => HBM_axi_r, -- out t_axi4_full_data;
        i_HBM_axi_rready => HBM_axi_rready_dummy -- in std_logic
    );
    
    HBM_axi_ar_dummy.valid <= '0';
    HBM_axi_ar_dummy.addr <= (others => '0');
    HBM_axi_ar_dummy.len <= (others => '0');
    HBM_axi_rready_dummy <= '1';
    
end Behavioral;
