----------------------------------------------------------------------------------
-- Module Name: rfi_flatten_tb - Behavioral
-- Description:
--   Targeted test for the V80 RFI-flag timing bug in sps_flatten_dclk.
--
--   The system-level symptom is that a small number of samples near an RFI
--   event are corrupted.  flattening_wrapper.vhd replaces output samples with
--   0x8000 by checking flagged_del(c_FIR_LATENCY) where c_FIR_LATENCY = 24.
--   flagged_del is driven by m_axis_data_tuser from the filter and is only
--   correct if tuser is time-aligned with tdata.
--
--   Test method (identity-filter impulse):
--     Config "00" selects the identity filter: all coefficients are 0 except
--     the centre tap (index 24) = 65536.  A unit impulse therefore produces
--     exactly one large output sample, at the hardware pipeline latency.
--
--     We send an impulse (data=0x40, tuser=1) at a known sample.
--     We then find:
--       peak_clk  -- the output clock at which |tdata| is maximum
--       user_clk  -- the output clock at which tuser first goes high
--
--     If the DSP path latency matches the tuser shift-register depth (tap 12
--     => 13 clocks), then peak_clk == user_clk.
--     If they differ by N, flattening_wrapper uses flagged_del(24-N) and marks
--     the wrong output sample as 0x8000.
--
--   To run: open build/v80_ct1_tb/v80_ct1_tb_top.xpr in Vivado, add this file
--   to simulation sources (ct_lib), set rfi_flatten_tb as the top simulation
--   entity, and run behavioural simulation.
----------------------------------------------------------------------------------

library IEEE, ct_lib, common_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use std.textio.all;
use common_lib.common_pkg.all;

entity rfi_flatten_tb is
end rfi_flatten_tb;

architecture Behavioral of rfi_flatten_tb is

    ---------------------------------------------------------------------------
    -- Clocks: aclk 100 MHz, aclk_x2 200 MHz, phase-aligned so that every
    -- aclk rising edge coincides with an aclk_x2 rising edge.
    ---------------------------------------------------------------------------
    signal aclk    : std_logic := '0';
    signal aclk_x2 : std_logic := '0';

    ---------------------------------------------------------------------------
    -- Filter inputs
    ---------------------------------------------------------------------------
    signal s_tvalid : std_logic := '0';
    signal s_tdata  : std_logic_vector(7 downto 0) := (others => '0');
    signal s_tuser  : std_logic_vector(0 downto 0) := "0";
    -- Config "00" = identity filter: only the centre tap (index 24) = 65536.
    -- This gives a single-sample non-zero response to an impulse, making the
    -- peak clock unambiguous.
    signal s_config : std_logic_vector(7 downto 0) := x"00";

    ---------------------------------------------------------------------------
    -- sps_flatten_dclk outputs
    ---------------------------------------------------------------------------
    signal m_tvalid : std_logic;
    signal m_tdata  : std_logic_vector(15 downto 0);
    signal m_tuser  : std_logic_vector(0 downto 0);

    ---------------------------------------------------------------------------
    -- Test bookkeeping
    ---------------------------------------------------------------------------
    -- Sample count (valid-gated).
    signal sample_num : integer := 0;
    -- Absolute rising-edge counter.
    signal clk_num    : integer := 0;

    -- The sample at which the first RFI impulse is injected.
    constant C_IMPULSE_SAMPLE : integer := 80;

    -- Start watching output only after the impulse is sent.
    signal armed      : std_logic := '0';
    -- Capture each measurement only once.
    signal peak_done  : std_logic := '0';
    signal user_done  : std_logic := '0';

    signal peak_clk   : integer := 0;   -- clock of largest |tdata|
    signal user_clk   : integer := 0;   -- clock of first tuser='1'
    signal peak_val   : integer := 0;   -- largest |tdata| seen so far

begin

    ---------------------------------------------------------------------------
    -- Clock generation
    -- aclk_x2 toggles every 2.5 ns => 200 MHz.
    -- aclk    toggles every 5.0 ns => 100 MHz.
    -- Both start at '0' so their first rising edges are coincident.
    ---------------------------------------------------------------------------
    aclk_x2 <= not aclk_x2 after 2.5 ns;
    aclk    <= not aclk    after 5.0 ns;

    ---------------------------------------------------------------------------
    -- Stimulus
    ---------------------------------------------------------------------------
    stim : process(aclk)
    begin
        if rising_edge(aclk) then
            clk_num <= clk_num + 1;

            -- Assert valid from clock 10 onwards.
            if clk_num >= 10 then
                s_tvalid <= '1';
            end if;

            -- Count valid samples.
            if s_tvalid = '1' then
                sample_num <= sample_num + 1;
            end if;

            -- Default: zero data, no RFI flag.
            s_tdata <= (others => '0');
            s_tuser <= "0";

            -- Inject RFI impulse: non-zero data AND tuser='1' at the same
            -- sample.  We use 0x40 so the peak is easily visible in the data,
            -- but we zero data to 0x00 when testing tuser propagation alone.
            -- In the real design flattening_wrapper sends data=0x00/tuser=1
            -- for a 0x80 input; here we keep the impulse in data as well so we
            -- can find the peak clock.
            if s_tvalid = '1' and sample_num = C_IMPULSE_SAMPLE then
                s_tdata <= x"40";
                s_tuser <= "1";
                armed   <= '1';
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- DUT: sps_flatten_dclk (V80 custom FIR)
    ---------------------------------------------------------------------------
    dut : entity ct_lib.sps_flatten_dclk
    port map (
        aclk                => aclk,
        aclk_x2             => aclk_x2,
        s_axis_data_tvalid  => s_tvalid,
        s_axis_data_tdata   => s_tdata,
        s_axis_data_tuser   => s_tuser,
        s_axis_config_tdata => s_config,
        m_axis_data_tvalid  => m_tvalid,
        m_axis_data_tdata   => m_tdata,
        m_axis_data_tuser   => m_tuser
    );

    ---------------------------------------------------------------------------
    -- Measurement and self-check
    ---------------------------------------------------------------------------
    measure : process(aclk)
        variable abs_val : integer;
        variable L       : line;
    begin
        if rising_edge(aclk) then
            if m_tvalid = '1' and armed = '1' then

                abs_val := abs(to_integer(signed(m_tdata)));

                -- Track the clock at which the output is largest (impulse peak).
                if abs_val > peak_val then
                    peak_val  <= abs_val;
                    peak_clk  <= clk_num;
                    peak_done <= '1';
                end if;

                -- Record the first clock at which tuser goes high.
                if m_tuser(0) = '1' and user_done = '0' then
                    user_clk  <= clk_num;
                    user_done <= '1';
                end if;

            end if;

            -- Print results 60 clocks after the peak has stabilised.
            if peak_done = '1' and user_done = '1' and
               clk_num = peak_clk + 60 then

                write(L, string'("=== sps_flatten_dclk RFI timing check ==="));
                writeline(output, L);
                write(L, string'("  tdata peak  : clock "));
                write(L, peak_clk);
                write(L, string'("  (value = "));
                write(L, peak_val);
                write(L, string'(")"));
                writeline(output, L);
                write(L, string'("  tuser = '1' : clock "));
                write(L, user_clk);
                writeline(output, L);
                write(L, string'("  offset (tuser_clk - peak_clk) = "));
                write(L, user_clk - peak_clk);
                writeline(output, L);

                -- For the identity filter (only the centre tap, index 24, is
                -- non-zero) the output peak is at T_impulse + L + 24, where L
                -- is the pipeline latency.  tuser goes high at T_impulse + L.
                -- So the expected offset is always -24, regardless of L.
                -- At the peak clock, flagged_del(24) looks back 24 clocks and
                -- finds tuser='1' — the correct sample gets 0x8000.
                if (user_clk - peak_clk) = -24 then
                    write(L, string'("  PASS: offset is -24 as expected."));
                    writeline(output, L);
                    write(L, string'("  flagged_del(24) will mark the correct output sample."));
                    writeline(output, L);
                else
                    write(L, string'("  FAIL: offset should be -24 but is "));
                    write(L, user_clk - peak_clk);
                    write(L, string'(" clocks."));
                    writeline(output, L);
                    write(L, string'("  => flagged_del(24) marks the wrong output sample."));
                    writeline(output, L);
                end if;

                write(L, string'("========================================="));
                writeline(output, L);
            end if;

        end if;
    end process;

    ---------------------------------------------------------------------------
    -- End simulation.
    ---------------------------------------------------------------------------
    sim_end : process
    begin
        wait for 25 us;
        report "Simulation end" severity failure;
    end process;

end Behavioral;
