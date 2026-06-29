----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
--
-- Module Name: fb_DSP25_versal_tb - Behavioral
-- Description:
--   Compares fb_DSP25 (single-stream reference, uses Versal DSP path when
--   targeting xcv80) against fb_DSP25_versal (double-rate dual-stream V80).
--
--   fb_DSP25_versal processes two streams (i_data0 / i_data1) simultaneously.
--   Two independent fb_DSP25 instances provide the reference for each stream.
--   The two streams are driven by independent 16-bit LFSRs (different seeds)
--   so their data is uncorrelated - any stream swap inside fb_DSP25_versal
--   will produce mismatches on both ports.
--
--   Expected output mapping if the implementation is CORRECT (no swap):
--     fb_DSP25 A  ==  fb_DSP25_versal o_data0   (stream 0)
--     fb_DSP25 B  ==  fb_DSP25_versal o_data1   (stream 1)
--
--   If the outputs ARE swapped:
--     fb_DSP25 A  ==  fb_DSP25_versal o_data1   (stream 0 came out of port 1)
--     fb_DSP25 B  ==  fb_DSP25_versal o_data0   (stream 1 came out of port 0)
--
--   Both mappings are checked and reported so the direction of any swap is
--   unambiguous.
----------------------------------------------------------------------------------

library IEEE, UNISIM, filterbanks_lib, common_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
use UNISIM.vcomponents.all;
use common_lib.common_pkg.all;
use std.textio.all;

entity fb_DSP25_versal_tb is
end fb_DSP25_versal_tb;

architecture Behavioral of fb_DSP25_versal_tb is

    ---------------------------------------------------------------------------
    -- Clocks (same MBUFGCE pattern as ct1_v80_tb)
    ---------------------------------------------------------------------------
    signal clock_200_no_buffer : std_logic := '0';
    signal clk100 : std_logic;
    signal clk200 : std_logic;

    ---------------------------------------------------------------------------
    -- Startup and timing
    ---------------------------------------------------------------------------
    signal startup_count : unsigned(8 downto 0) := (others => '0');
    signal startup_done  : std_logic := '0';
    signal clk_num       : integer := 0;
    -- Number of valid clocks seen; comparison starts after the filter latency.
    -- fb_DSP25 latency = TAPS + 3 = 12 + 3 = 15 clocks from first valid data.
    signal valid_count   : integer := 0;
    signal compare_en    : std_logic := '0';

    ---------------------------------------------------------------------------
    -- 16-bit Fibonacci LFSRs: poly x^16+x^15+x^13+x^4+1, maximal-length 65535
    -- Different seeds give independent uncorrelated data streams.
    ---------------------------------------------------------------------------
    signal lfsr0 : std_logic_vector(15 downto 0) := x"ACDE"; -- stream 0 seed
    signal lfsr1 : std_logic_vector(15 downto 0) := x"1357"; -- stream 1 seed

    ---------------------------------------------------------------------------
    -- Staggered 12-tap shift registers.
    -- data0_shift(0) = newest sample; data0_shift(11) = oldest.
    -- The FIR filter expects this staggering: tap k uses the sample from k
    -- clocks ago.
    ---------------------------------------------------------------------------
    signal data0_shift : t_slv_16_arr(11 downto 0) := (others => (others => '0'));
    signal data1_shift : t_slv_16_arr(11 downto 0) := (others => (others => '0'));

    ---------------------------------------------------------------------------
    -- Filter coefficients (fixed, non-trivial 18-bit signed values).
    -- All 12 taps are non-zero to exercise every DSP in the cascade.
    ---------------------------------------------------------------------------
    signal coef_reg : t_slv_18_arr(11 downto 0) := (
        0  => std_logic_vector(to_signed( 16384, 18)),
        1  => std_logic_vector(to_signed( -8192, 18)),
        2  => std_logic_vector(to_signed(  4096, 18)),
        3  => std_logic_vector(to_signed( -2048, 18)),
        4  => std_logic_vector(to_signed(  1024, 18)),
        5  => std_logic_vector(to_signed(  -512, 18)),
        6  => std_logic_vector(to_signed(   256, 18)),
        7  => std_logic_vector(to_signed(  -128, 18)),
        8  => std_logic_vector(to_signed(    64, 18)),
        9  => std_logic_vector(to_signed(   -32, 18)),
        10 => std_logic_vector(to_signed(    16, 18)),
        11 => std_logic_vector(to_signed(    -8, 18)));

    ---------------------------------------------------------------------------
    -- Filter outputs
    ---------------------------------------------------------------------------
    signal ref0_out : std_logic_vector(24 downto 0);   -- fb_DSP25 A (stream 0)
    signal ref1_out : std_logic_vector(24 downto 0);   -- fb_DSP25 B (stream 1)
    signal dut_out0 : std_logic_vector(24 downto 0);   -- fb_DSP25_versal port 0
    signal dut_out1 : std_logic_vector(24 downto 0);   -- fb_DSP25_versal port 1

    ---------------------------------------------------------------------------
    -- Mismatch counters for all four pairings
    ---------------------------------------------------------------------------
    signal mm_ref0_dut0 : integer := 0;  -- ref0 vs dut0 (correct if no swap)
    signal mm_ref1_dut1 : integer := 0;  -- ref1 vs dut1 (correct if no swap)
    signal mm_ref0_dut1 : integer := 0;  -- ref0 vs dut1 (correct if swap)
    signal mm_ref1_dut0 : integer := 0;  -- ref1 vs dut0 (correct if swap)

begin

    ---------------------------------------------------------------------------
    -- 200 MHz oscillator -> MBUFGCE -> clk200 (200 MHz) + clk100 (100 MHz)
    ---------------------------------------------------------------------------
    clock_200_no_buffer <= not clock_200_no_buffer after 2.5 ns;

    MBUFGCE_inst : MBUFGCE
    generic map (
        CE_TYPE        => "SYNC",
        IS_CE_INVERTED => '0',
        IS_I_INVERTED  => '0',
        MODE           => "PERFORMANCE"
    )
    port map (
        O1        => clk200,
        O2        => clk100,
        O3        => open,
        O4        => open,
        CE        => '1',
        CLRB_LEAF => '1',
        I         => clock_200_no_buffer
    );

    ---------------------------------------------------------------------------
    -- Startup counter and clk_num
    ---------------------------------------------------------------------------
    process(clk100)
    begin
        if rising_edge(clk100) then
            clk_num <= clk_num + 1;
            if startup_done = '0' then
                if startup_count = 255 then
                    startup_done <= '1';
                else
                    startup_count <= startup_count + 1;
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- LFSR 0 - drives stream 0 data
    ---------------------------------------------------------------------------
    process(clk100)
        variable fb : std_logic;
    begin
        if rising_edge(clk100) then
            if startup_done = '1' then
                fb    := lfsr0(15) xor lfsr0(14) xor lfsr0(12) xor lfsr0(3);
                lfsr0 <= lfsr0(14 downto 0) & fb;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- LFSR 1 - drives stream 1 data (different seed, independent sequence)
    ---------------------------------------------------------------------------
    process(clk100)
        variable fb : std_logic;
    begin
        if rising_edge(clk100) then
            if startup_done = '1' then
                fb    := lfsr1(15) xor lfsr1(14) xor lfsr1(12) xor lfsr1(3);
                lfsr1 <= lfsr1(14 downto 0) & fb;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Stagger shift registers.
    -- Each clock the current LFSR value is pushed into position 0 and the
    -- history shifts up, giving:
    --   data_shift(0)  = sample from clock N-1  (one cycle old - VHDL semantics)
    --   data_shift(k)  = sample from clock N-k-1
    ---------------------------------------------------------------------------
    process(clk100)
    begin
        if rising_edge(clk100) then
            if startup_done = '1' then
                data0_shift(11 downto 1) <= data0_shift(10 downto 0);
                data0_shift(0) <= lfsr0;
                data1_shift(11 downto 1) <= data1_shift(10 downto 0);
                data1_shift(0) <= lfsr1;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Enable comparisons after the filter latency (TAPS + 3 = 15 clocks) plus
    -- a few extra cycles margin.
    ---------------------------------------------------------------------------
    process(clk100)
    begin
        if rising_edge(clk100) then
            if startup_done = '1' then
                if valid_count < 30 then
                    valid_count <= valid_count + 1;
                else
                    compare_en <= '1';
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Reference DUT A: fb_DSP25 for stream 0
    ---------------------------------------------------------------------------
    ref_a : entity filterbanks_lib.fb_DSP25
    generic map (TAPS => 12)
    port map (
        clk    => clk100,
        data_i => data0_shift,
        coef_i => coef_reg,
        data_o => ref0_out
    );

    ---------------------------------------------------------------------------
    -- Reference DUT B: fb_DSP25 for stream 1
    ---------------------------------------------------------------------------
    ref_b : entity filterbanks_lib.fb_DSP25
    generic map (TAPS => 12)
    port map (
        clk    => clk100,
        data_i => data1_shift,
        coef_i => coef_reg,
        data_o => ref1_out
    );

    ---------------------------------------------------------------------------
    -- DUT: fb_DSP25_versal processing both streams simultaneously
    ---------------------------------------------------------------------------
    dut : entity filterbanks_lib.fb_DSP25_versal
    port map (
        clk     => clk100,
        clk_2x  => clk200,
        i_data0 => data0_shift,
        i_data1 => data1_shift,
        i_coef  => coef_reg,
        o_data0 => dut_out0,
        o_data1 => dut_out1
    );

    ---------------------------------------------------------------------------
    -- Self-checking: compare all four port pairings every clock.
    ---------------------------------------------------------------------------
    check_proc : process(clk100)
        variable L : line;
    begin
        if rising_edge(clk100) then
            if compare_en = '1' then

                -- Expected-correct pairings (no swap)
                if ref0_out /= dut_out0 then
                    mm_ref0_dut0 <= mm_ref0_dut0 + 1;
                    if mm_ref0_dut0 < 5 then
                        write(L, string'("ref0 vs dut0 MISMATCH clk="));
                        write(L, clk_num);
                        write(L, string'("  ref0=0x")); hwrite(L, ref0_out);
                        write(L, string'("  dut0=0x")); hwrite(L, dut_out0);
                        writeline(output, L);
                    end if;
                end if;

                if ref1_out /= dut_out1 then
                    mm_ref1_dut1 <= mm_ref1_dut1 + 1;
                    if mm_ref1_dut1 < 5 then
                        write(L, string'("ref1 vs dut1 MISMATCH clk="));
                        write(L, clk_num);
                        write(L, string'("  ref1=0x")); hwrite(L, ref1_out);
                        write(L, string'("  dut1=0x")); hwrite(L, dut_out1);
                        writeline(output, L);
                    end if;
                end if;

                -- Swapped pairings (non-zero means swap detected here)
                if ref0_out /= dut_out1 then
                    mm_ref0_dut1 <= mm_ref0_dut1 + 1;
                end if;
                if ref1_out /= dut_out0 then
                    mm_ref1_dut0 <= mm_ref1_dut0 + 1;
                end if;

            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Summary report
    ---------------------------------------------------------------------------
    report_proc : process
        variable L : line;
    begin
        wait for 50 us;
        write(L, string'("=== fb_DSP25_versal_tb result ==="));
        writeline(output, L);
        write(L, string'("Expected-correct pairings (ref0->dut0, ref1->dut1):"));
        writeline(output, L);
        write(L, string'("  ref0 vs dut_out0 mismatches = ")); write(L, mm_ref0_dut0);
        writeline(output, L);
        write(L, string'("  ref1 vs dut_out1 mismatches = ")); write(L, mm_ref1_dut1);
        writeline(output, L);
        write(L, string'("Swapped pairings (ref0->dut1, ref1->dut0):"));
        writeline(output, L);
        write(L, string'("  ref0 vs dut_out1 mismatches = ")); write(L, mm_ref0_dut1);
        writeline(output, L);
        write(L, string'("  ref1 vs dut_out0 mismatches = ")); write(L, mm_ref1_dut0);
        writeline(output, L);
        if mm_ref0_dut0 = 0 and mm_ref1_dut1 = 0 then
            write(L, string'("PASS: o_data0=stream0, o_data1=stream1 (no swap)."));
        elsif mm_ref0_dut1 = 0 and mm_ref1_dut0 = 0 then
            write(L, string'("FAIL (SWAP): o_data0=stream1, o_data1=stream0 - streams are swapped!"));
        else
            write(L, string'("FAIL: mismatches on both pairings - functional error."));
        end if;
        writeline(output, L);
        write(L, string'("================================="));
        writeline(output, L);
        report "Simulation complete" severity failure;
    end process;

end Behavioral;
