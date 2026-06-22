----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey
--
-- Module Name: ct2_v80_tb - Behavioral
-- Description:
--  Standalone testbench for correlator corner turn 2 (V80 version).
--
--  Test configuration is supplied entirely through generics.  Create a
--  top-level wrapper entity that instantiates this module with the appropriate
--  generic map for each test case.  The Python checker (ct2_check.py) reads
--  that same wrapper file to reconstruct the expected HBM contents.
--
--  HBM dump:
--   At simulation time g_SIM_DURATION_US the contents of the CT2 HBM are
--   written to g_HBM_DUMP_FILE (one 32-bit hex word per line, lowest address
--   first).  The simulation then stops.
--
----------------------------------------------------------------------------------

library IEEE, correlator_lib, ct_lib, common_lib, filterbanks_lib;
use IEEE.STD_LOGIC_1164.ALL;
Library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;
use IEEE.NUMERIC_STD.ALL;
use std.textio.all;
use IEEE.std_logic_textio.all;
USE ct_lib.corr_ct2_reg_pkg.ALL;
USE common_lib.common_pkg.ALL;
library DSP_top_lib;
use DSP_top_lib.DSP_top_pkg.all;

entity ct2_v80_tb is
    generic(
        -- Filterbank timing
        g_PACKET_GAP        : integer := 4100;  -- clocks from start of one filterbank packet to start of next
        g_VC_GAP            : integer := 20000; -- clocks idle between groups of 12 virtual channels
        -- Design configuration
        g_VIRTUAL_CHANNELS  : integer := 12;
        g_CORRELATOR_CORES  : integer := 1;
        -- Bad-poly injection: set g_BAD_POLY_VC to x"FFFF" to disable completely
        g_BAD_POLY_VC       : std_logic_vector(15 downto 0) := x"FFFF";
        g_BAD_POLY_PACKETS  : integer := 0;
        -- Subarray-beam count registers, one per [correlator][table]:
        --   index 0 = corr0/table0, 1 = corr0/table1, 2 = corr1/table0, 3 = corr1/table1
        -- Use ascending (0 to 3) so positional aggregates map left-to-right.
        g_SB_COUNTS         : t_slv_32_arr(0 to 3) := (x"00000001", x"00000000",
                                                        x"00000000", x"00000000");
        -- Demap table: 2 words per group of 4 VCs (table 0).
        --   word 0: bit31=valid, bits28:20=sky_freq_idx(9b), bits19:8=station(12b), bits7:0=SB_id(8b)
        --   word 1: forwarding info (unused)
        g_DEMAP_TABLE       : t_slv_32_arr := (0 => x"00000000");
        -- Subarray-beam table for correlator 0 (4 words per SB entry, sequential):
        --   word 0: bits15:0=stations(16b),  bits31:16=coarse_start(16b)
        --   word 1: bits15:0=fine_start(16b)
        --   word 2: bits23:0=num_fine(24b), bits30:24=fine_per_int(7b), bit31=int_mode(0=283ms,1=849ms)
        --   word 3: HBM base byte address (32b)
        g_SB_C0_TABLE       : t_slv_32_arr := (0 => x"00000000");
        -- Subarray-beam table for correlator 1 (written at register offset +512)
        g_SB_C1_TABLE       : t_slv_32_arr := (0 => x"00000000");
        -- Simulation control
        g_SIM_DURATION_US   : integer := 5000;
        g_HBM_DUMP_FILE     : string  := "ct2_hbm_dump.txt";
        g_HBM_DUMP_BYTES    : integer := 33554432  -- 32 MB default
    );
end ct2_v80_tb;

architecture Behavioral of ct2_v80_tb is

    function get_axi_size(AXI_DATA_WIDTH : integer) return std_logic_vector is
    begin
        if    AXI_DATA_WIDTH = 8    then return "000";
        elsif AXI_DATA_WIDTH = 16   then return "001";
        elsif AXI_DATA_WIDTH = 32   then return "010";
        elsif AXI_DATA_WIDTH = 64   then return "011";
        elsif AXI_DATA_WIDTH = 128  then return "100";
        elsif AXI_DATA_WIDTH = 256  then return "101";
        elsif AXI_DATA_WIDTH = 512  then return "110";
        elsif AXI_DATA_WIDTH = 1024 then return "111";
        else
            assert FALSE report "Bad AXI data width" severity failure;
            return "000";
        end if;
    end get_axi_size;

    constant HBM_DATA_WIDTH : integer := 256;

    procedure noc_write(signal clk       : in std_logic;
                        signal noc_wren  : out std_logic;
                        signal noc_wrAddr: out std_logic_vector(17 downto 0);
                        signal noc_wrData: out std_logic_vector(31 downto 0);
                        register_addr    : natural;
                        wr_data          : std_logic_vector(31 downto 0)) is
    begin
        wait until rising_edge(clk);
        noc_wren  <= '1';
        noc_wrAddr <= std_logic_vector(to_unsigned(register_addr, 18));
        noc_wrData <= wr_data;
        wait until rising_edge(clk);
        noc_wren <= '0';
        wait until rising_edge(clk);
    end procedure;

    -- AXI buses (CT2 HBM for filterbank->correlator data)
    signal HBM_axi_aw, HBM_axi_vis_aw : t_axi4_full_addr_arr(1 downto 0);
    signal HBM_axi_awready, HBM_axi_vis_awready : std_logic_vector(1 downto 0);
    signal HBM_axi_w, HBM_axi_vis_w : t_axi4_full_data_arr(1 downto 0);
    signal HBM_axi_wready, HBM_axi_vis_wready : std_logic_vector(1 downto 0);
    signal HBM_axi_b, HBM_axi_vis_b : t_axi4_full_b_arr(1 downto 0);
    signal HBM_axi_ar, HBM_axi_vis_ar : t_axi4_full_addr_arr(1 downto 0);
    signal HBM_axi_arready, HBM_axi_vis_arready : std_logic_vector(1 downto 0);
    signal HBM_axi_r, HBM_axi_vis_r : t_axi4_full_data_arr(1 downto 0);
    signal HBM_axi_rready, HBM_axi_vis_rready : std_logic_vector(1 downto 0);

    signal send_fb_data : std_logic := '0';

    type t_fb_fsm is (wait_sof, send_sof, send_sof_wait, send_data0, send_Data, packet_gap, new_vc_gap, frame_gap);
    signal fb_fsm : t_fb_fsm := wait_sof;
    signal fb_sof, fb_dataValid : std_logic;
    signal fb_headerValid : std_logic_vector(11 downto 0);
    signal fb_virtualChannel : t_slv_16_arr(11 downto 0);
    signal fb_count_slv : std_logic_vector(15 downto 0);
    signal packets_sent_slv : std_logic_vector(15 downto 0);
    signal fb_data : t_ctc_output_payload_arr(11 downto 0);
    signal cor_ready : std_logic_vector(1 downto 0);
    signal hbm_reset_final : std_logic := '0';

    signal hbm_status : t_slv_8_arr(1 downto 0);
    signal hbm_rst_dbg : t_slv_32_arr(1 downto 0);

    signal HBM_axi_awsize, HBM_axi_vis_awsize, HBM_axi_arprot, HBM_axi_vis_arprot, HBM_axi_awprot, HBM_axi_vis_awprot : t_slv_3_arr(1 downto 0);
    signal HBM_axi_awburst, HBM_axi_vis_awburst : t_slv_2_arr(1 downto 0);
    signal HBM_axi_bready, HBM_axi_vis_bready : std_logic_vector(1 downto 0);
    signal HBM_axi_wstrb, HBM_axi_vis_wstrb : t_slv_64_arr(1 downto 0);
    signal HBM_axi_arsize, HBM_axi_vis_arsize : t_slv_3_arr(1 downto 0);
    signal HBM_axi_arburst, HBM_axi_vis_arburst, HBM_axi_arlock, HBM_axi_vis_arlock, HBM_axi_awlock, HBM_axi_vis_awlock : t_slv_2_arr(1 downto 0);
    signal HBM_axi_awcache, HBM_axi_vis_awcache, HBM_axi_awqos, HBM_axi_vis_awqos, HBM_axi_arqos, HBM_axi_vis_arqos, HBM_axi_arregion, HBM_axi_vis_arregion, HBM_axi_awregion, HBM_axi_vis_awregion, HBM_axi_arcache, HBM_axi_vis_arcache : t_slv_4_arr(1 downto 0);
    signal HBM_axi_awid, HBM_axi_vis_awid, HBM_axi_arid, HBM_axi_vis_arid, HBM_axi_bid, HBM_axi_vis_bid : t_slv_1_arr(1 downto 0);

    signal clk300, clk300_rst, data_rst : std_logic := '0';
    signal clk400 : std_logic := '0';
    signal virtual_channels : std_logic_vector(10 downto 0);

    -- write_HBM_to_disk2 is pulsed for one clock at g_SIM_DURATION_US to dump CT2 HBM
    signal write_HBM_to_disk2, init_mem2 : std_logic := '0';
    signal fb_count : integer := 0;
    signal fb_integration : std_logic_vector(31 downto 0) := (others => '0');
    signal fb_ctFrame : std_logic_vector(1 downto 0) := "00";
    signal fb_vc0 : std_logic_vector(15 downto 0) := (others => '0');
    signal packets_sent : integer := 0;
    signal rst_n : std_logic;
    signal fb_bad_poly : std_logic_vector(11 downto 0);

    signal bad_poly_packets_sent : integer;
    signal bad_poly_integration  : std_logic_vector(31 downto 0);
    signal bad_poly_ctFrame      : std_logic_vector(1 downto 0);
    signal bad_poly_vc           : std_logic_vector(15 downto 0);
    signal c_VIRTUAL_CHANNELS    : integer := 0;
    signal fb_lastChannel        : std_logic;
    signal fb_demap_table_select : std_logic;

    signal dummy_slv32    : std_logic_vector(31 downto 0);
    signal dummy_slv8_zeros : t_slv_8_arr(5 downto 0);

    signal noc_wr_adr, noc_rd_adr : std_logic_vector(17 downto 0);
    signal noc_wr_dat, noc_rd_dat : std_logic_vector(31 downto 0);
    signal noc_wren  : std_logic;
    signal noc_rden  : std_logic;
    signal dummy_slv8 : std_logic_vector(7 downto 0);

    signal cor_cfg_data  : t_slv_8_arr(5 downto 0);
    signal cor_cfg_first : std_logic_vector(5 downto 0);
    signal cor_cfg_last  : std_logic_vector(5 downto 0);
    signal cor_cfg_valid : std_logic_vector(5 downto 0);
    signal clk400_rst : std_logic := '0';

    signal ro_FIFO_din : t_slv_128_arr(5 downto 0);
    signal ro_FIFO_wrEn : std_logic_vector(5 downto 0);
    signal ro_stall     : std_logic_vector(5 downto 0);

begin

    clk300 <= not clk300 after 1.666 ns;
    clk400 <= not clk400 after 1.25 ns;
    rst_n  <= not clk300_rst;

    process
    begin
        clk400_rst <= '0';
        for i in 1 to 10 loop
            wait until rising_edge(clk400);
        end loop;
        clk400_rst <= '1';
        wait until rising_edge(clk400);
        wait until rising_edge(clk400);
        clk400_rst <= '0';
        wait until rising_edge(clk400);
        wait;
    end process;

    ---------------------------------------------------------------------------
    -- Configuration process: writes register tables using the generic values.
    ---------------------------------------------------------------------------
    process
    begin
        virtual_channels      <= (others => '0');
        send_fb_data          <= '0';
        clk300_rst            <= '0';
        hbm_reset_final       <= '0';
        fb_demap_table_select <= '0';
        noc_wr_adr <= (others => '0');
        noc_rd_adr <= (others => '0');
        noc_wr_dat <= (others => '0');
        noc_wren   <= '0';
        noc_rden   <= '0';

        for i in 1 to 10 loop wait until rising_edge(clk300); end loop;
        clk300_rst <= '1';
        for i in 1 to 10 loop wait until rising_edge(clk300); end loop;
        clk300_rst <= '0';
        for i in 1 to 100 loop wait until rising_edge(clk300); end loop;

        -- Set virtual channel count and bad-poly parameters
        c_VIRTUAL_CHANNELS   <= g_VIRTUAL_CHANNELS;
        bad_poly_packets_sent <= g_BAD_POLY_PACKETS;
        bad_poly_integration  <= (others => '0');
        bad_poly_ctFrame      <= "00";
        bad_poly_vc           <= g_BAD_POLY_VC;
        wait until rising_edge(clk300);
        virtual_channels <= std_logic_vector(to_unsigned(g_VIRTUAL_CHANNELS, 11));

        -- Subarray-beam counts: 4 registers [corr0/t0, corr0/t1, corr1/t0, corr1/t1]
        noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat,
            c_statctrl_buf0_subarray_beams_table0_address.base_address + 0,
            g_SB_COUNTS(0));
        noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat,
            c_statctrl_buf0_subarray_beams_table1_address.base_address + 1,
            g_SB_COUNTS(1));
        noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat,
            c_statctrl_buf1_subarray_beams_table0_address.base_address + 2,
            g_SB_COUNTS(2));
        noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat,
            c_statctrl_buf1_subarray_beams_table1_address.base_address + 3,
            g_SB_COUNTS(3));

        -- Demap table (2 words per group of 4 VCs, sequential from base)
        for i in 0 to g_DEMAP_TABLE'length - 1 loop
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat,
                c_statctrl_vc_demap_address.base_address +
                c_statctrl_vc_demap_address.address + i,
                g_DEMAP_TABLE(g_DEMAP_TABLE'low + i));
        end loop;

        -- Subarray-beam table for correlator 0 (sequential from base)
        for i in 0 to g_SB_C0_TABLE'length - 1 loop
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat,
                c_statctrl_subarray_beam_address.base_address +
                c_statctrl_subarray_beam_address.address + i,
                g_SB_C0_TABLE(g_SB_C0_TABLE'low + i));
        end loop;

        -- Subarray-beam table for correlator 1 (offset +512 words from base)
        for i in 0 to g_SB_C1_TABLE'length - 1 loop
            noc_write(clk300, noc_wren, noc_wr_adr, noc_wr_dat,
                c_statctrl_subarray_beam_address.base_address +
                c_statctrl_subarray_beam_address.address + 512 + i,
                g_SB_C1_TABLE(g_SB_C1_TABLE'low + i));
        end loop;

        -- Start filterbank data
        wait until rising_edge(clk300);
        send_fb_data <= '1';
        wait until rising_edge(clk300);
        send_fb_data <= '0';
        wait until rising_edge(clk300);

        wait;
    end process;

    ---------------------------------------------------------------------------
    -- Simulation termination: dump HBM at g_SIM_DURATION_US then stop.
    ---------------------------------------------------------------------------
    sim_end : process
    begin
        write_HBM_to_disk2 <= '0';
        wait for g_SIM_DURATION_US * 1 us;
        -- Pulse write_HBM_to_disk2 for exactly one clock to trigger the dump
        wait until rising_edge(clk300);
        write_HBM_to_disk2 <= '1';
        wait until rising_edge(clk300);
        write_HBM_to_disk2 <= '0';
        wait until rising_edge(clk300);
        report "Simulation complete - HBM dumped to " & g_HBM_DUMP_FILE severity failure;
    end process;

    ---------------------------------------------------------------------------
    -- Filterbank emulator
    ---------------------------------------------------------------------------
    process(clk300)
    begin
        if rising_edge(clk300) then
            if clk300_rst = '1' then
                fb_fsm       <= wait_sof;
                fb_count     <= 0;
                fb_integration <= (others => '0');
                fb_ctFrame   <= "00";
                fb_vc0       <= (others => '0');
                packets_sent <= 0;
            else
                case fb_fsm is
                    when wait_sof =>
                        if send_fb_data = '1' then fb_fsm <= send_sof; end if;
                        fb_count <= 0;

                    when send_sof =>
                        fb_fsm   <= send_sof_wait;
                        fb_count <= 0;

                    when send_sof_wait =>
                        if fb_count = 1000 then
                            fb_fsm   <= send_data0;
                            fb_count <= 0;
                        else
                            fb_count <= fb_count + 1;
                        end if;

                    when send_data0 =>
                        fb_fsm   <= send_data;
                        fb_count <= fb_count + 1;

                    when send_data =>
                        if fb_count = 3455 then fb_fsm <= packet_gap; end if;
                        fb_count <= fb_count + 1;

                    when packet_gap =>
                        if fb_count = 4100 then
                            fb_count <= 0;
                            if packets_sent = 63 then
                                packets_sent <= 0;
                                if (unsigned(fb_vc0) + 12) > (c_VIRTUAL_CHANNELS - 1) then
                                    fb_vc0   <= (others => '0');
                                    fb_fsm   <= frame_gap;
                                    if fb_ctFrame = "10" then
                                        fb_ctFrame    <= "00";
                                        fb_integration <= std_logic_vector(unsigned(fb_integration) + 1);
                                    else
                                        fb_ctFrame <= std_logic_vector(unsigned(fb_ctFrame) + 1);
                                    end if;
                                else
                                    fb_vc0 <= std_logic_vector(unsigned(fb_vc0) + 12);
                                    fb_fsm <= new_vc_gap;
                                end if;
                            else
                                packets_sent <= packets_sent + 1;
                                fb_fsm       <= send_data0;
                            end if;
                        else
                            fb_count <= fb_count + 1;
                        end if;

                    when new_vc_gap =>
                        if fb_count = 44000 then
                            fb_count <= 0;
                            fb_fsm   <= send_sof;
                        else
                            fb_count <= fb_count + 1;
                        end if;

                    when frame_gap =>
                        if fb_count = 100000 then
                            fb_count <= 0;
                            fb_fsm   <= send_sof;
                        else
                            fb_count <= fb_count + 1;
                        end if;

                    when others =>
                        fb_fsm <= wait_sof;
                end case;
            end if;
        end if;
    end process;

    fb_sof <= '1' when fb_fsm = send_sof else '0';

    fb_virtualChannel(0)  <= fb_vc0;
    fb_virtualChannel(1)  <= std_logic_vector(unsigned(fb_vc0) + 1);
    fb_virtualChannel(2)  <= std_logic_vector(unsigned(fb_vc0) + 2);
    fb_virtualChannel(3)  <= std_logic_vector(unsigned(fb_vc0) + 3);
    fb_virtualChannel(4)  <= std_logic_vector(unsigned(fb_vc0) + 4);
    fb_virtualChannel(5)  <= std_logic_vector(unsigned(fb_vc0) + 5);
    fb_virtualChannel(6)  <= std_logic_vector(unsigned(fb_vc0) + 6);
    fb_virtualChannel(7)  <= std_logic_vector(unsigned(fb_vc0) + 7);
    fb_virtualChannel(8)  <= std_logic_vector(unsigned(fb_vc0) + 8);
    fb_virtualChannel(9)  <= std_logic_vector(unsigned(fb_vc0) + 9);
    fb_virtualChannel(10) <= std_logic_vector(unsigned(fb_vc0) + 10);
    fb_virtualChannel(11) <= std_logic_vector(unsigned(fb_vc0) + 11);

    fb_bad_poly_gen : for i in 0 to 11 generate
        fb_bad_poly(i) <= '1' when fb_dataValid = '1'
            and fb_virtualChannel(i) = bad_poly_vc
            and fb_ctFrame    = bad_poly_ctFrame
            and fb_integration = bad_poly_integration
            and packets_sent  = bad_poly_packets_sent
            else '0';
    end generate;

    fb_headerValid <= "111111111111" when fb_fsm = send_data0 else "000000000000";

    fb_count_slv    <= std_logic_vector(to_unsigned(fb_count, 16));
    packets_sent_slv <= std_logic_vector(to_unsigned(packets_sent, 16));

    -- Data encoding (same for all 12 channels):
    --   Hpol.re = fb_count[7:0]         (fine channel, bits 7:0)
    --   Hpol.im = integration[3:0] & fb_count[11:8]  (integration + fine channel upper bits)
    --   Vpol.re = ct_frame[1:0] & packets_sent[5:0]   (time sample within 849ms frame)
    --   Vpol.im = virtual_channel[7:0]
    fb_datageni : for i in 0 to 11 generate
        fb_data(i).Hpol.re                <= fb_count_slv(7 downto 0);
        fb_data(i).Hpol.im(3 downto 0)   <= fb_count_slv(11 downto 8);
        fb_data(i).Hpol.im(7 downto 4)   <= fb_integration(3 downto 0);
        fb_data(i).Vpol.re(5 downto 0)   <= packets_sent_slv(5 downto 0);
        fb_data(i).Vpol.re(7 downto 6)   <= fb_ctFrame(1 downto 0);
        fb_data(i).Vpol.im                <= fb_virtualChannel(i)(7 downto 0);
    end generate;

    fb_dataValid  <= '1' when fb_fsm = send_data0 or fb_fsm = send_data else '0';
    fb_lastChannel <= '1' when (unsigned(fb_vc0) + 12) > (c_VIRTUAL_CHANNELS - 1) else '0';

    ---------------------------------------------------------------------------
    -- CT2 DUT
    ---------------------------------------------------------------------------
    ct2topi : entity ct_lib.corr_ct2_top_v80
    generic map (
        g_USE_META        => false,
        g_MAX_CORRELATORS => 6,
        g_GENERATE_ILA    => false
    ) port map (
        i_axi_clk             => clk300,
        i_axi_rst             => clk300_rst,
        i_rst                 => clk300_rst,
        i_noc_wren            => noc_wren,
        i_noc_rden            => noc_rden,
        i_noc_wr_adr          => noc_wr_adr,
        i_noc_wr_dat          => noc_wr_dat,
        i_noc_rd_adr          => noc_rd_adr,
        o_noc_rd_dat          => noc_rd_dat,
        o_hbm_reset_c1        => open,
        i_hbm_status_c1       => dummy_slv8,
        o_hbm_reset_c2        => open,
        i_hbm_status_c2       => dummy_slv8,
        i_sof                 => fb_sof,
        i_integration         => fb_integration,
        i_ctFrame             => fb_ctFrame,
        i_virtualChannel      => fb_virtualChannel,
        i_bad_poly            => fb_bad_poly,
        i_lastChannel         => fb_lastChannel,
        i_demap_table_select  => fb_demap_table_select,
        i_HeaderValid         => fb_headerValid,
        i_data                => fb_data,
        i_dataValid           => fb_dataValid,
        o_cor_cfg_data        => cor_cfg_data,
        o_cor_cfg_first       => cor_cfg_first,
        o_cor_cfg_last        => cor_cfg_last,
        o_cor_cfg_valid       => cor_cfg_valid,
        o_HBM_axi_aw          => HBM_axi_aw,
        i_HBM_axi_awready     => HBM_axi_awready,
        o_HBM_axi_w           => HBM_axi_w,
        i_HBM_axi_wready      => HBM_axi_wready,
        i_HBM_axi_b           => HBM_axi_b,
        i_readout_start       => '0',
        i_readout_buffer      => '0',
        i_readout_frameCount  => (others => '0'),
        i_freq_index0_repeat  => '0',
        i_hbm_status          => dummy_slv8_zeros,
        i_hbm_reset_final     => '0',
        i_eth_disable_fsm_dbg => "00000",
        i_hbm0_rst_dbg        => dummy_slv32,
        i_hbm1_rst_dbg        => dummy_slv32
    );

    dummy_slv8        <= (others => '0');
    dummy_slv32       <= (others => '0');
    dummy_slv8_zeros  <= (others => (others => '0'));

    ---------------------------------------------------------------------------
    -- Correlator cores
    ---------------------------------------------------------------------------
    corr_geni : for i in 0 to (g_CORRELATOR_CORES - 1) generate
        cori : entity correlator_lib.correlator_top_v80
        generic map (g_CORRELATOR_INSTANCE => i)
        port map (
            i_axi_clk        => clk300,
            i_axi_rst        => clk300_rst,
            i_cor_clk        => clk400,
            i_cor_rst        => clk400_rst,
            i_cor_cfg_data   => cor_cfg_data(i),
            i_cor_cfg_first  => cor_cfg_first(i),
            i_cor_cfg_last   => cor_cfg_last(i),
            i_cor_cfg_valid  => cor_cfg_valid(i),
            o_HBM_axi_ar      => HBM_axi_ar(i),
            i_HBM_axi_arready => HBM_axi_arready(i),
            i_HBM_axi_r       => HBM_axi_r(i),
            o_HBM_axi_rready  => HBM_axi_rready(i),
            o_HBM_axi_aw      => HBM_axi_vis_aw(i),
            i_HBM_axi_awready => HBM_axi_vis_awready(i),
            o_HBM_axi_w       => HBM_axi_vis_w(i),
            i_HBM_axi_wready  => HBM_axi_vis_wready(i),
            i_HBM_axi_b       => HBM_axi_vis_b(i),
            o_ro_data         => ro_FIFO_din(i),
            o_ro_valid        => ro_FIFO_wrEn(i),
            i_ro_stall        => ro_stall(i),
            o_tb_data         => open,
            o_tb_visValid     => open,
            o_tb_TCIvalid     => open,
            o_tb_dcount       => open,
            o_tb_cell         => open,
            o_tb_tile         => open,
            o_tb_channel      => open,
            o_freq_index0_repeat => open
        );
        ro_stall(i) <= '0';

        HBM1G_VIS : entity correlator_lib.HBM_axi_tbModel
        generic map (
            AXI_ADDR_WIDTH           => 32,
            AXI_ID_WIDTH             => 1,
            AXI_DATA_WIDTH           => 256,
            READ_QUEUE_SIZE          => 16,
            MIN_LAG                  => 60,
            INCLUDE_PROTOCOL_CHECKER => TRUE,
            RANDSEED                 => 43526,
            LATENCY_LOW_PROBABILITY  => 95,
            LATENCY_ZERO_PROBABILITY => 80
        ) port map (
            i_clk        => clk300,
            i_rst_n      => rst_n,
            axi_awaddr   => HBM_axi_vis_aw(i).addr(31 downto 0),
            axi_awid     => HBM_axi_vis_awid(i),
            axi_awlen    => HBM_axi_vis_aw(i).len,
            axi_awsize   => HBM_axi_vis_awsize(i),
            axi_awburst  => HBM_axi_vis_awburst(i),
            axi_awlock   => HBM_axi_vis_awlock(i),
            axi_awcache  => HBM_axi_vis_awcache(i),
            axi_awprot   => HBM_axi_vis_awprot(i),
            axi_awqos    => HBM_axi_vis_awqos(i),
            axi_awregion => HBM_axi_vis_awregion(i),
            axi_awvalid  => HBM_axi_vis_aw(i).valid,
            axi_awready  => HBM_axi_vis_awready(i),
            axi_wdata    => HBM_axi_vis_w(i).data(255 downto 0),
            axi_wstrb    => HBM_axi_vis_wstrb(i)(31 downto 0),
            axi_wlast    => HBM_axi_vis_w(i).last,
            axi_wvalid   => HBM_axi_vis_w(i).valid,
            axi_wready   => HBM_axi_vis_wready(i),
            axi_bresp    => HBM_axi_vis_b(i).resp,
            axi_bvalid   => HBM_axi_vis_b(i).valid,
            axi_bready   => HBM_axi_vis_bready(i),
            axi_bid      => HBM_axi_vis_bid(i),
            axi_araddr   => HBM_axi_vis_ar(i).addr(31 downto 0),
            axi_arlen    => HBM_axi_vis_ar(i).len,
            axi_arsize   => HBM_axi_vis_arsize(i),
            axi_arburst  => HBM_axi_vis_arburst(i),
            axi_arlock   => HBM_axi_vis_arlock(i),
            axi_arcache  => HBM_axi_vis_arcache(i),
            axi_arprot   => HBM_axi_vis_arprot(i),
            axi_arvalid  => HBM_axi_vis_ar(i).valid,
            axi_arready  => HBM_axi_vis_arready(i),
            axi_arqos    => HBM_axi_vis_arqos(i),
            axi_arid     => HBM_axi_vis_arid(i),
            axi_arregion => HBM_axi_vis_arregion(i),
            axi_rdata    => HBM_axi_vis_r(i).data(255 downto 0),
            axi_rresp    => HBM_axi_vis_r(i).resp,
            axi_rlast    => HBM_axi_vis_r(i).last,
            axi_rvalid   => HBM_axi_vis_r(i).valid,
            axi_rready   => HBM_axi_vis_rready(i),
            i_write_to_disk      => '0',
            i_fname              => "",
            i_write_to_disk_addr => 0,
            i_write_to_disk_size => 0,
            i_init_mem           => '0',
            i_init_fname         => ""
        );
    end generate;

    ---------------------------------------------------------------------------
    -- AXI bus tie-offs
    ---------------------------------------------------------------------------
    axi_hbm_gen : for i in 0 to 1 generate
        HBM_axi_awsize(i)   <= get_axi_size(HBM_DATA_WIDTH);
        HBM_axi_awburst(i)  <= "01";
        HBM_axi_bready(i)   <= '1';
        HBM_axi_wstrb(i)    <= (others => '1');
        HBM_axi_arsize(i)   <= get_axi_size(HBM_DATA_WIDTH);
        HBM_axi_arburst(i)  <= "01";
        HBM_axi_arlock(i)   <= "00";
        HBM_axi_awlock(i)   <= "00";
        HBM_axi_awcache(i)  <= "0011";
        HBM_axi_awprot(i)   <= "000";
        HBM_axi_awqos(i)    <= "0000";
        HBM_axi_awregion(i) <= "0000";
        HBM_axi_arcache(i)  <= "0011";
        HBM_axi_arprot(i)   <= "000";
        HBM_axi_arqos(i)    <= "0000";
        HBM_axi_arregion(i) <= "0000";
        HBM_axi_awid(i)(0)  <= '0';
        HBM_axi_arid(i)(0)  <= '0';
        HBM_axi_bid(i)(0)   <= '0';

        HBM_axi_vis_awsize(i)   <= get_axi_size(HBM_DATA_WIDTH);
        HBM_axi_vis_awburst(i)  <= "01";
        HBM_axi_vis_bready(i)   <= '1';
        HBM_axi_vis_wstrb(i)    <= (others => '1');
        HBM_axi_vis_arsize(i)   <= get_axi_size(HBM_DATA_WIDTH);
        HBM_axi_vis_arburst(i)  <= "01";
        HBM_axi_vis_arlock(i)   <= "00";
        HBM_axi_vis_awlock(i)   <= "00";
        HBM_axi_vis_awcache(i)  <= "0011";
        HBM_axi_vis_awprot(i)   <= "000";
        HBM_axi_vis_awqos(i)    <= "0000";
        HBM_axi_vis_awregion(i) <= "0000";
        HBM_axi_vis_arcache(i)  <= "0011";
        HBM_axi_vis_arprot(i)   <= "000";
        HBM_axi_vis_arqos(i)    <= "0000";
        HBM_axi_vis_arregion(i) <= "0000";
        HBM_axi_vis_awid(i)(0)  <= '0';
        HBM_axi_vis_arid(i)(0)  <= '0';
        HBM_axi_vis_bid(i)(0)   <= '0';
    end generate;

    ---------------------------------------------------------------------------
    -- 16 GB CT2 HBM model (filterbank data -> correlator)
    ---------------------------------------------------------------------------
    HBM16G_2 : entity correlator_lib.HBM_axi_TwoInterface_tbModel
    generic map (
        AXI_ADDR_WIDTH           => 34,
        AXI_ID_WIDTH             => 1,
        AXI_DATA_WIDTH           => 256,
        READ_QUEUE_SIZE          => 16,
        MIN_LAG                  => 60,
        INCLUDE_PROTOCOL_CHECKER => TRUE,
        RANDSEED                 => 43526,
        LATENCY_LOW_PROBABILITY  => 99,
        LATENCY_ZERO_PROBABILITY => 80,
        LATENCY_LOW_PROBABILITY2 => 99,
        LATENCY_ZERO_PROBABILITY2 => 82
    ) port map (
        i_clk        => clk300,
        i_rst_n      => rst_n,
        axi_awaddr   => HBM_axi_aw(0).addr(33 downto 0),
        axi_awid     => HBM_axi_awid(0),
        axi_awlen    => HBM_axi_aw(0).len,
        axi_awsize   => HBM_axi_awsize(0),
        axi_awburst  => HBM_axi_awburst(0),
        axi_awlock   => HBM_axi_awlock(0),
        axi_awcache  => HBM_axi_awcache(0),
        axi_awprot   => HBM_axi_awprot(0),
        axi_awqos    => HBM_axi_awqos(0),
        axi_awregion => HBM_axi_awregion(0),
        axi_awvalid  => HBM_axi_aw(0).valid,
        axi_awready  => HBM_axi_awready(0),
        axi_wdata    => HBM_axi_w(0).data(255 downto 0),
        axi_wstrb    => HBM_axi_wstrb(0)(31 downto 0),
        axi_wlast    => HBM_axi_w(0).last,
        axi_wvalid   => HBM_axi_w(0).valid,
        axi_wready   => HBM_axi_wready(0),
        axi_bresp    => HBM_axi_b(0).resp,
        axi_bvalid   => HBM_axi_b(0).valid,
        axi_bready   => HBM_axi_bready(0),
        axi_bid      => HBM_axi_bid(0),
        axi_araddr   => HBM_axi_ar(0).addr(33 downto 0),
        axi_arlen    => HBM_axi_ar(0).len,
        axi_arsize   => HBM_axi_arsize(0),
        axi_arburst  => HBM_axi_arburst(0),
        axi_arlock   => HBM_axi_arlock(0),
        axi_arcache  => HBM_axi_arcache(0),
        axi_arprot   => HBM_axi_arprot(0),
        axi_arvalid  => HBM_axi_ar(0).valid,
        axi_arready  => HBM_axi_arready(0),
        axi_arqos    => HBM_axi_arqos(0),
        axi_arid     => HBM_axi_arid(0),
        axi_arregion => HBM_axi_arregion(0),
        axi_rdata    => HBM_axi_r(0).data(255 downto 0),
        axi_rresp    => HBM_axi_r(0).resp,
        axi_rlast    => HBM_axi_r(0).last,
        axi_rvalid   => HBM_axi_r(0).valid,
        axi_rready   => HBM_axi_rready(0),
        axi2_awaddr   => HBM_axi_aw(1).addr(33 downto 0),
        axi2_awid     => HBM_axi_awid(1),
        axi2_awlen    => HBM_axi_aw(1).len,
        axi2_awsize   => HBM_axi_awsize(1),
        axi2_awburst  => HBM_axi_awburst(1),
        axi2_awlock   => HBM_axi_awlock(1),
        axi2_awcache  => HBM_axi_awcache(1),
        axi2_awprot   => HBM_axi_awprot(1),
        axi2_awqos    => HBM_axi_awqos(1),
        axi2_awregion => HBM_axi_awregion(1),
        axi2_awvalid  => HBM_axi_aw(1).valid,
        axi2_awready  => HBM_axi_awready(1),
        axi2_wdata    => HBM_axi_w(1).data(255 downto 0),
        axi2_wstrb    => HBM_axi_wstrb(1)(31 downto 0),
        axi2_wlast    => HBM_axi_w(1).last,
        axi2_wvalid   => HBM_axi_w(1).valid,
        axi2_wready   => HBM_axi_wready(1),
        axi2_bresp    => HBM_axi_b(1).resp,
        axi2_bvalid   => HBM_axi_b(1).valid,
        axi2_bready   => HBM_axi_bready(1),
        axi2_bid      => HBM_axi_bid(1),
        axi2_araddr   => HBM_axi_ar(1).addr(33 downto 0),
        axi2_arlen    => HBM_axi_ar(1).len,
        axi2_arsize   => HBM_axi_arsize(1),
        axi2_arburst  => HBM_axi_arburst(1),
        axi2_arlock   => HBM_axi_arlock(1),
        axi2_arcache  => HBM_axi_arcache(1),
        axi2_arprot   => HBM_axi_arprot(1),
        axi2_arvalid  => HBM_axi_ar(1).valid,
        axi2_arready  => HBM_axi_arready(1),
        axi2_arqos    => HBM_axi_arqos(1),
        axi2_arid     => HBM_axi_arid(1),
        axi2_arregion => HBM_axi_arregion(1),
        axi2_rdata    => HBM_axi_r(1).data(255 downto 0),
        axi2_rresp    => HBM_axi_r(1).resp,
        axi2_rlast    => HBM_axi_r(1).last,
        axi2_rvalid   => HBM_axi_r(1).valid,
        axi2_rready   => HBM_axi_rready(1),
        -- HBM dump: triggered by write_HBM_to_disk2 at g_SIM_DURATION_US
        i_write_to_disk      => write_HBM_to_disk2,
        i_fname              => g_HBM_DUMP_FILE,
        i_write_to_disk_addr => 0,
        i_write_to_disk_size => g_HBM_DUMP_BYTES,
        i_init_mem           => '0',
        i_init_fname         => ""
    );

end Behavioral;
