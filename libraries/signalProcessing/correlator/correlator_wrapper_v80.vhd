----------------------------------------------------------------------------------
-- Company: CSIRO 
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: Jan 2026 (based on earlier u55c version)
-- Module Name: correlator_top_v80 - Behavioral
-- Description: 
--  Wrapper for a single correlator core for the v80.
--  Includes the NOC modules required to connect to HBM and to connect to streaming AXI control packets 
--  
----------------------------------------------------------------------------------
library IEEE, correlator_lib, common_lib, xpm, spead_lib;
library axi4_lib, DSP_top_lib, noc_lib, signal_processing_common;

use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
--use correlator_lib.cor_config_reg_pkg.ALL;
use common_lib.common_pkg.ALL;
use xpm.vcomponents.all;
use axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;
use spead_lib.spead_packet_pkg.ALL;
use signal_processing_common.target_fpga_pkg.ALL;


entity correlator_wrapper_v80 is
    generic (
        g_USE_VNOC : boolean := False;   -- if true, instantiate HBM NOC component instead of VNOC component for the HBM interface
        g_CORRELATOR_INSTANCE : integer   -- unique ID for this correlator instance
    );
    port (
        -- clock used for all data input and output from this module (300 MHz)
        i_axi_clk : in std_logic;
        i_axi_rst : in std_logic;
        -- Processing clock used for the correlation (>412.5 MHz)
        i_cor_clk : in std_logic;
        i_cor_rst : in std_logic;
        ---------------------------------------------------------------
        -- bus in from CT2 with instructions to the correlator core
        -- packets of data to each correlator instance
        -- Receive a single packet full of instructions to each correlator, at the start of each 849ms corner turn frame readout.
        -- The first byte received is the number of subarray-beams configured
        -- The remaining (128 subarray-beams) * (4 words/subarray-beam) * (4 bytes/word) = 2048 bytes contains the subarray-beam table for the correlator
        -- The LSB of the 4th word for each subarray-beam contains the bad_poly bit for the subarray beam.
        -- The correlator should use (o_cor_cfg_last and o_cor_cfg_valid) to trigger processing 849ms of data.
        i_cor_cfg_data  : in std_logic_vector(7 downto 0); -- 8 bit wide bus
        i_cor_cfg_first : in std_logic;
        i_cor_cfg_last  : in std_logic;
        i_cor_cfg_valid : in std_logic
    );
end correlator_wrapper_v80;

architecture Behavioral of correlator_wrapper_v80 is
    
    signal HBM_axi_ar, HBM_axi_aw, HBM_axi_addr_dummy : t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
    signal HBM_axi_arready : std_logic;
    signal HBM_axi_r : t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
    signal HBM_axi_rready : std_logic;
    signal HBM_axi_ready_dummy : std_logic := '1';
    signal HBM_axi_awready : std_logic;
    signal HBM_axi_w :  t_axi4_full_data; -- w data bus (.valid, .data(511:0), .last, .resp(1:0))
    signal HBM_axi_wready : std_logic;
    signal HBM_axi_b : t_axi4_full_b;
    signal HBM_axi_w_dummy : t_axi4_full_data;
    signal HBM_axi_bready : std_logic;
    
    signal ro_FIFO_din : std_logic_vector(127 downto 0);
    signal ro_FIFO_wrEn : std_logic;
    signal ro_FIFO_valid, ro_FIFO_full : std_logic;
    signal ro_FIFO_dout : std_logic_vector(127 downto 0);
    signal ro_FIFO_wr_count : std_logic_vector(4 downto 0);
    signal ro_FIFO_RdEn, ro_tready : std_logic;
    signal ro_reg_used : std_logic := '0';
    signal ro_tdata : std_logic_vector(127 downto 0);
    
    signal ro_tdest : std_logic_vector(3 downto 0);
    signal ro_tkeep : std_logic_vector(15 downto 0);
    signal ro_tid : std_logic_vector(5 downto 0);
    signal ro_tlast : std_logic;
    signal ro_stall : std_logic;
    
begin
    
    cori : entity correlator_lib.correlator_top_v80
    generic map (
        g_CORRELATOR_INSTANCE => g_CORRELATOR_INSTANCE -- integer; unique ID for this correlator instance
    ) port map (
        -- clock used for all data input and output from this module (300 MHz)
        i_axi_clk => i_axi_clk, -- in std_logic;
        i_axi_rst => i_axi_rst, -- in std_logic;
        -- Processing clock used for the correlation (>412.5 MHz)
        i_cor_clk => i_cor_clk, -- in std_logic;
        i_cor_rst => i_cor_rst, -- in std_logic;
        ---------------------------------------------------------------------------
        -- AXI stream input with packets of control data from corner turn 2
        i_cor_cfg_data  => i_cor_cfg_data,  -- in (7:0);  8 bit wide bus
        i_cor_cfg_first => i_cor_cfg_first, -- in std_logic;
        i_cor_cfg_last  => i_cor_cfg_last,  -- in std_logic;
        i_cor_cfg_valid => i_cor_cfg_valid, -- in std_logic;
        ---------------------------------------------------------------------------
        -- 256 bit wide memory interface
        -- Read from HBM to go to the correlator
        o_HBM_axi_ar      => HBM_axi_ar, -- out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_arready => HBM_axi_arready, -- in  std_logic;
        i_HBM_axi_r       => HBM_axi_r,       -- in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_rready  => HBM_axi_rready,  -- out std_logic;
        -- write to HBM at the output of the correlator
        o_HBM_axi_aw      => HBM_axi_aw,      -- out t_axi4_full_addr; -- write address bus (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_awready => HBM_axi_awready, -- in  std_logic;
        o_HBM_axi_w       => HBM_axi_w,       -- out t_axi4_full_data; -- w data bus (.valid, .data(511:0), .last, .resp(1:0))
        i_HBM_axi_wready  => HBM_axi_wready,  -- in  std_logic;
        i_HBM_axi_b       => HBM_axi_b,       -- in  t_axi4_full_b; -- write response bus (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        ---------------------------------------------------------------
        -- Readout bus tells the packetiser what to do
        o_ro_data  => ro_FIFO_din,  -- out std_logic_vector(127 downto 0);
        o_ro_valid => ro_FIFO_wrEn, -- out std_logic;
        i_ro_stall => ro_stall,     -- in std_logic;
        ---------------------------------------------------------------
        -- Copy of the bus taking data to be written to the HBM,
        -- for the first correlator instance.
        -- Used for simulation only, to check against the model data.
        o_tb_data      => open, -- out std_logic_vector(255 downto 0);
        o_tb_visValid  => open, -- out std_logic; -- o_tb_data is valid visibility data
        o_tb_TCIvalid  => open, -- out std_logic; -- i_data is valid TCI & DV data
        o_tb_dcount    => open, -- out std_logic_vector(7 downto 0);  -- counts the 256 transfers for one cell of visibilites, or 16 transfers for the centroid data. 
        o_tb_cell      => open, -- out std_logic_vector(7 downto 0);  -- in (7:0);  -- a "cell" is a 16x16 station block of correlations
        o_tb_tile      => open, -- out std_logic_vector(9 downto 0);  -- a "tile" is a 16x16 block of cells, i.e. a 256x256 station correlation.
        o_tb_channel   => open, -- out std_logic_vector(23 downto 0); -- first fine channel index for this correlation.
        -- an old debug trigger I think
        o_freq_index0_repeat => open --: out std_logic
    );
    
    ------------------------------------------------------------------
    -- Instantiate HBM interfaces
    -- Read and write use separate NOC interfaces
    -- Read from HBM reads from the full CT2 memory (18 Gbytes)
    
    HBM_readi : entity signal_processing_common.hbm_noc_if
    generic map (
        g_HBM_base_addr => c_V80_HBM_BASE_CT2_ADDR, -- : std_logic_vector(63 downto 0) := x"0000004600000000";  -- default is the HBM base address
        g_USE_VNOC => c_CORRELATOR_VNOC(g_CORRELATOR_INSTANCE)  -- "pl_hbm" for the native HBM interfaces at the top of the chip or "VNOC" for other NOC interfaces
    ) port map (
        clk  => i_axi_clk, --  in std_logic;
        -- write
        i_HBM_axi_aw      => HBM_axi_addr_dummy, -- in t_axi4_full_addr; -- write address bus : out t_axi4_full_addr(.valid, .addr(39:0), .len(7:0))
        o_HBM_axi_awready => open,             -- out std_logic;
        i_HBM_axi_w       => HBM_axi_w_dummy,  -- in t_axi4_full_data; -- w data bus : out t_axi4_full_data(.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_wready  => open,             -- out std_logic;
        o_HBM_axi_b       => open,             -- out t_axi4_full_b;     -- write response bus : in t_axi4_full_b(.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        i_HBM_axi_bready  => HBM_axi_ready_dummy, -- in std_logic;
        -- read
        i_HBM_axi_ar => HBM_axi_ar, -- in t_axi4_full_addr;
        o_HBM_axi_arready => HBM_axi_arready, -- out std_logic;
        o_HBM_axi_r  => HBM_axi_r, -- out t_axi4_full_data;
        i_HBM_axi_rready => HBM_axi_rready -- in std_logic
    );
    
    HBM_axi_w_dummy.valid <= '0';
    HBM_axi_w_dummy.data <= (others => '0');
    HBM_axi_w_dummy.last <= '0';
    HBM_axi_w_dummy.resp <= (others => '0');
    
    -- Write to HBM is just for the visibility output buffer, which is smaller and specific to this correlator core 
    HBM_writei : entity signal_processing_common.hbm_noc_if
    generic map (
        g_HBM_base_addr => c_V80_HBM_BASE_VIS_ADDR(g_CORRELATOR_INSTANCE), -- std_logic_vector(63 downto 0) := x"0000004600000000";  -- default is the HBM base address
        g_USE_VNOC =>  c_CORRELATOR_VNOC(g_CORRELATOR_INSTANCE)  -- "pl_hbm" for the native HBM interfaces at the top of the chip or "VNOC" for other NOC interfaces
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
        i_HBM_axi_ar => HBM_axi_addr_dummy, -- in t_axi4_full_addr;
        o_HBM_axi_arready => open, -- out std_logic;
        o_HBM_axi_r  => open, -- out t_axi4_full_data;
        i_HBM_axi_rready => HBM_axi_ready_dummy -- in std_logic
    );
    
    HBM_axi_bready <= '0';
    HBM_axi_ready_dummy <= '1';
    HBM_axi_addr_dummy.valid <= '0';
    HBM_axi_addr_dummy.addr <= (others => '0');
    HBM_axi_addr_dummy.len <= (others => '0');
    
    ------------------------------------------------------------------
    -- Point to point streaming AXI to tell the packetiser to read out data from the HBM
    -- The FIFO allows for tready from the NOC to go low
    ro_fifoi : xpm_fifo_sync
    generic map (
        CASCADE_HEIGHT => 0,        -- DECIMAL
        DOUT_RESET_VALUE => "0",    -- String
        ECC_MODE => "no_ecc",       -- String
        FIFO_MEMORY_TYPE => "distributed", -- String
        FIFO_READ_LATENCY => 0,     -- DECIMAL
        FIFO_WRITE_DEPTH => 16,     -- DECIMAL
        FULL_RESET_VALUE => 0,      -- DECIMAL
        PROG_EMPTY_THRESH => 10,    -- DECIMAL
        PROG_FULL_THRESH => 10,     -- DECIMAL
        RD_DATA_COUNT_WIDTH => 5,   -- DECIMAL
        READ_DATA_WIDTH => 128,     -- DECIMAL
        READ_MODE => "fwft",        -- String
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "1404", -- String; bit 12 = enable data valid flag, bits 2 and 10 enable read and write data counts
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 128,    -- DECIMAL
        WR_DATA_COUNT_WIDTH => 5    -- DECIMAL
    ) port map (
        almost_empty => open,        -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
        almost_full => open,         -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
        data_valid => ro_FIFO_valid, -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
        dbiterr => open,             -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
        dout => ro_FIFO_dout,        -- READ_DATA_WIDTH-bit output: Read Data: The output data bus is driven when reading the FIFO.
        empty => open,               -- 1-bit output: Empty Flag: When asserted, this signal indicates that- the FIFO is empty.
        full => ro_FIFO_full,        -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full.
        overflow => open,            -- 1-bit output: Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected, because the FIFO is full
        prog_empty => open,          -- 1-bit output: Programmable Empty: This signal is asserted when the number of words in the FIFO is less than or equal to the programmable empty threshold value.
        prog_full => open,           -- 1-bit output: Programmable Full: This signal is asserted when the number of words in the FIFO is greater than or equal to the programmable full threshold value.
        rd_data_count => open,       -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
        rd_rst_busy => open,         -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
        sbiterr => open,             -- 1-bit output: Single Bit Error: Indicates that the ECC decoder detected and fixed a single-bit error.
        underflow => open,           -- 1-bit output: Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected because the FIFO is empty.
        wr_ack => open,              -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.
        wr_data_count => ro_FIFO_wr_count, -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        wr_rst_busy => open,         -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
        din => ro_FIFO_din,          -- WRITE_DATA_WIDTH-bit input: Write Data: The input data bus used when writing the FIFO.
        injectdbiterr => '0',        -- 1-bit input: Double Bit Error Injection
        injectsbiterr => '0',        -- 1-bit input: Single Bit Error Injection: 
        rd_en => ro_FIFO_RdEn,       -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO. 
        rst => '0',                  -- 1-bit input: Reset: Must be synchronous to wr_clk.
        sleep => '0',                -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
        wr_clk => i_axi_clk,         -- 1-bit input: Write clock: Used for write operation. wr_clk must be a free running clock.
        wr_en => ro_FIFO_wrEn        -- 1-bit input: Write Enable: 
    );
    
    ro_FIFO_rdEn <= '1' when ro_FIFO_valid = '1' and ro_reg_used = '0' else '0';
    
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            if ro_FIFO_rdEn = '1' then
                ro_tdata <= ro_FIFO_dout;
                ro_reg_used <= '1';
            elsif ro_tready = '1' then
                ro_reg_used <= '0';
            end if;
            
            if unsigned(ro_FIFO_wr_count) > 8 then
                ro_stall <= '1';
            else
                ro_stall <= '0';
            end if;
            
        end if;
    end process;
    
    -- xpm_nmu_strm: AXI Streaming (AXI Full) NOC Master Unit
    -- Xilinx Parameterized Macro, version 2025.1
    xpm_nmu_strm_inst : xpm_nmu_strm
    generic map (
        DATA_WIDTH => 128,    -- DECIMAL
        DST_ID_WIDTH => 4,    -- DECIMAL
        ID_WIDTH => 6,        -- DECIMAL
        NOC_FABRIC => "VNOC"  -- STRING
    ) port map (
        dst_id_err    => open,       -- 1-bit output: Indicates DST ID error
        s_axis_tready => ro_tready,  -- 1-bit output: TREADY: Indicates that the receiver can accept a transfer in the current cycle.
        s_axis_aclk   => i_axi_clk,  -- 1-bit input: Slave Interface Clock: All signals on slave interface are sampled on the rising edge of this clock.
        s_axis_tdata  => ro_tdata,   -- DATA_WIDTH-bit input: TDATA: The data payload. An integer number of bytes.
        s_axis_tdest  => ro_tdest,   -- DST_ID_WIDTH-bit input: TDEST: Provides routing information for the data stream.
        s_axis_tid    => ro_tid,     -- ID_WIDTH-bit input: TID: Identification tag for the data transfer
        s_axis_tkeep  => ro_tkeep,   -- DATA_WIDTH/8-bit input: TKEEP byte qualifier
        s_axis_tlast  => ro_tlast,   -- 1-bit input: TLAST: Indicates the boundary of a packet.
        s_axis_tvalid => ro_reg_used -- 1-bit input: TVALID: indicates the Transmitter is driving a valid transfer
    );
    ro_tkeep <= "1111111111111111";
    ro_tlast <= '1';
    ro_tid <= std_logic_vector(to_unsigned(g_CORRELATOR_INSTANCE,6));
    ro_tdest <= "0000";
    
--    ----------------------------------------------------------------
--    -- Registers
--    --


--    -- ARGS Gaskets for V80
--    i_cor_noc : entity noc_lib.args_noc
--    generic map (
--        G_DEBUG => FALSE
--    ) port map ( 
--        i_clk       => i_axi_clk,
--        i_rst       => i_axi_rst,
    
--        noc_wren    => noc_wren,
--        noc_rden    => noc_rden,
--        noc_wr_adr  => noc_wr_adr,
--        noc_wr_dat  => noc_wr_dat,
--        noc_rd_adr  => noc_rd_adr,
--        noc_rd_dat  => noc_rd_dat_mux
--    );

--    i_cor_args : entity correlator_lib.cor_config_versal
--    port map (
--        MM_CLK          => i_axi_clk,  -- in std_logic;
--        MM_RST          => i_axi_rst,  -- in std_logic;
        
--        noc_wren        => noc_wren,
--        noc_rden        => noc_rden,
--        noc_wr_adr      => noc_wr_adr,
--        noc_wr_dat      => noc_wr_dat,
--        noc_rd_adr      => noc_rd_adr,
--        noc_rd_dat      => noc_rd_dat_mux,
        
--        SETUP_FIELDS_RW => config_rw,  -- out t_setup_rw;
--        SETUP_FIELDS_RO => config_ro   -- in  t_setup_ro
--    );
    
--END GENERATE;
    
--    config_ro.cor0_HBM_start <= cor0_HBM_curr_rd_base; --(others => '0'); -- TODO - should come from the SPEAD packet readout module
--    config_ro.cor0_HBM_end <= cor0_HBM_end;
--    config_ro.cor0_HBM_size <= (others => '0'); -- TODO - calculate from cor0_HBM_end and cor0_HBM_start
    
--    config_ro.cor1_HBM_start <= cor1_HBM_curr_rd_base; --(others => '0'); -- TODO - should come from the SPEAD packet readout module
--    config_ro.cor1_HBM_end <= cor1_HBM_end;
--    config_ro.cor1_HBM_size <= (others => '0'); -- TODO - calculate from cor0_HBM_end and cor0_HBM_start
    
--    dummy <= config_rw.full_reset;
    
end Behavioral;
