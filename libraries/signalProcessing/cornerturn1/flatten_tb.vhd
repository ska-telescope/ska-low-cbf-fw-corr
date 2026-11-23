----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
--
-- Module Name: flatten_tb - Behavioral
-- Description:
--   Testbench for the deripple (flattening) FIR filter.
--   Runs both the Xilinx FIR compiler (sps_flatten, U55 reference) and the
--   custom double-rate implementation (sps_flatten_dclk, V80) in parallel
--   with identical inputs, then compares their tdata and tuser outputs.
--
--   Clocks are generated using the Versal MBUFGCE primitive (same approach
--   as ct1_v80_tb.vhd) so the phase relationship between the 100 MHz and
--   200 MHz clocks matches the real hardware.
--
--   valid_in is held low for the first 256 clocks of clk100 to allow the
--   Xilinx simulation model to complete its internal initialisation.
--
--   g_DATA_SELECT = 0 : single 0x40 impulse (original behaviour)
--   g_DATA_SELECT = 1 : continuous pseudo-random data from a 16-bit LFSR
--
--   Self-checking: any data or tuser mismatch is printed and counted.
--   A PASS / FAIL summary is printed at simulation end.
----------------------------------------------------------------------------------

library IEEE, UNISIM, ct_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
use UNISIM.vcomponents.all;
use std.textio.all;

entity flatten_tb is
    generic (
        g_DATA_SELECT : integer := 1; -- 0 = impulse, 1 = pseudo-random LFSR
        -- Simulation time in microseconds at which the PASS/FAIL summary is
        -- printed. Must be less than the xsim.simulate.runtime of the run.
        g_REPORT_US   : integer := 98
    );
end flatten_tb;

architecture Behavioral of flatten_tb is

    ---------------------------------------------------------------------------
    -- Clocks.
    -- A 200 MHz raw oscillator is divided by the Versal MBUFGCE primitive
    -- (same pattern as ct1_v80_tb.vhd) to produce clk200 (O1 = I) and
    -- clk100 (O2 = I/2).  This creates the same low-skew, phase-aligned
    -- relationship between the two clocks as on real hardware.
    ---------------------------------------------------------------------------
    signal clock_200_no_buffer : std_logic := '0';
    signal clk100 : std_logic;
    signal clk200 : std_logic;

    ---------------------------------------------------------------------------
    -- Xilinx FIR compiler (U55 reference)
    ---------------------------------------------------------------------------
    component sps_flatten
    port (
        aclk                 : in  std_logic;
        s_axis_data_tvalid   : in  std_logic;
        s_axis_data_tready   : out std_logic;
        s_axis_data_tdata    : in  std_logic_vector(7 downto 0);
        s_axis_data_tuser    : in  std_logic_vector(0 downto 0);
        s_axis_config_tvalid : in  std_logic;
        s_axis_config_tready : out std_logic;
        s_axis_config_tdata  : in  std_logic_vector(7 downto 0);
        m_axis_data_tvalid   : out std_logic;
        m_axis_data_tdata    : out std_logic_vector(15 downto 0);
        m_axis_data_tuser    : out std_logic_vector(0 downto 0));
    end component;

    ---------------------------------------------------------------------------
    -- Stimulus signals
    ---------------------------------------------------------------------------
    signal ccount        : unsigned(15 downto 0) := (others => '0');
    signal startup_count : unsigned(8 downto 0)  := (others => '0');
    signal startup_done  : std_logic := '0';

    signal din           : std_logic_vector(7 downto 0)  := (others => '0');
    signal valid_in      : std_logic := '0';
    signal tuser         : std_logic_vector(0 downto 0)  := "0";
    signal config_tdata  : std_logic_vector(7 downto 0)  := x"01"; -- TPM 16d
    signal config_tvalid : std_logic := '0';
    signal config_tready : std_logic;

    -- 16-bit Fibonacci LFSR: poly x^16+x^15+x^13+x^4+1, maximal-length 65535
    signal lfsr : std_logic_vector(15 downto 0) := x"ACDE"; -- non-zero seed

    ---------------------------------------------------------------------------
    -- Filter outputs
    ---------------------------------------------------------------------------
    signal valid_out      : std_logic;
    signal dout           : std_logic_vector(15 downto 0);
    signal tuser_out      : std_logic_vector(0 downto 0);

    signal valid_out_dclk : std_logic;
    signal dout_dclk      : std_logic_vector(15 downto 0);
    signal tuser_out_dclk : std_logic_vector(0 downto 0);

    ---------------------------------------------------------------------------
    -- Checker state
    ---------------------------------------------------------------------------
    signal clk_num        : integer := 0;
    signal data_mismatch  : integer := 0;
    signal tuser_mismatch : integer := 0;
    -- A mismatch count of zero only means something if the two filters were
    -- actually compared on real data. compare_count counts the clocks where
    -- both filters were valid; nonzero_count counts those carrying non-zero
    -- data. The summary fails the test if either is zero.
    signal compare_count  : integer := 0;
    signal nonzero_count  : integer := 0;
    signal mismatch : std_logic := '0';

begin

    ---------------------------------------------------------------------------
    -- 200 MHz free-running oscillator → MBUFGCE → clk200 (200 MHz) + clk100
    ---------------------------------------------------------------------------
    clock_200_no_buffer <= not clock_200_no_buffer after 2.5 ns;

    MBUFGCE_inst : MBUFGCE
    generic map (
        CE_TYPE        => "SYNC",
        IS_CE_INVERTED => '0',
        IS_I_INVERTED  => '0',
        MODE           => "PERFORMANCE"  -- O1=I, O2=I/2, O3=I/4, O4=I/8
    )
    port map (
        O1       => clk200,
        O2       => clk100,
        O3       => open,
        O4       => open,
        CE       => '1',
        CLRB_LEAF => '1',
        I        => clock_200_no_buffer
    );

    ---------------------------------------------------------------------------
    -- Startup delay, counter, config pulse
    ---------------------------------------------------------------------------

    process(clk100)
    begin
        if rising_edge(clk100) then
            clk_num <= clk_num + 1;

            -- Hold valid_in low for first 256 clocks so the Xilinx simulation
            -- model finishes its internal initialisation before data arrives.
            if startup_done = '0' then
                if startup_count = 255 then
                    startup_done <= '1';
                else
                    startup_count <= startup_count + 1;
                end if;
            else
                ccount <= ccount + 1;
            end if;

            -- Config pulse fires during the startup delay (when valid_in is still
            -- '0') so the Xilinx FIR IP has loaded its coefficient set before
            -- any data arrives.  If it fired after valid_in goes high (as it
            -- would at ccount=16 in LFSR mode), the first samples would pass
            -- through with different configs in the two filters.
            if startup_done = '0' and startup_count = 16 then
                config_tvalid <= '1';
            else
                config_tvalid <= '0';
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- LFSR (advances every valid clock)
    ---------------------------------------------------------------------------
    process(clk100)
        variable fb : std_logic;
    begin
        if rising_edge(clk100) then
            if valid_in = '1' then
                fb   := lfsr(15) xor lfsr(14) xor lfsr(12) xor lfsr(3);
                lfsr <= lfsr(14 downto 0) & fb;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Stimulus: impulse mode (g_DATA_SELECT = 0)
    -- Single 0x40 sample at the start of each 512-clock valid burst.
    ---------------------------------------------------------------------------
    gen_pulse : if g_DATA_SELECT = 0 generate
        -- valid_in is high for the upper half of every 512-clock ccount cycle,
        -- i.e. when ccount(8) = '1'. The impulse must therefore sit on the
        -- FIRST clock of that window, ccount(8 downto 0) = "100000000".
        -- It used to be placed at ccount(8 downto 0) = "000000000", which
        -- forces ccount(8) = '0' and hence valid_in = '0', so the impulse was
        -- never shifted into either filter and both produced only zeros --
        -- the mode reported 0 mismatches without comparing anything.
        din      <= x"40" when (startup_done = '1' and ccount(8 downto 0) = "100000000") else x"00";
        valid_in <= startup_done and ccount(8);
        -- Flag only the impulse sample itself. The tuser comparison then also
        -- checks that both filters delay the side channel by the same number
        -- of clocks as the data, rather than holding tuser high throughout.
        tuser(0) <= '1' when (startup_done = '1' and ccount(8 downto 0) = "100000000") else '0';
    end generate;

    ---------------------------------------------------------------------------
    -- Stimulus: pseudo-random mode (g_DATA_SELECT = 1)
    -- Continuous valid stream from the 16-bit LFSR once startup is done.
    ---------------------------------------------------------------------------
    gen_lfsr : if g_DATA_SELECT = 1 generate
        din      <= lfsr(7 downto 0);
        valid_in <= startup_done;
        tuser(0) <= lfsr(15);  -- pseudo-random flag, ~50 % duty cycle
    end generate;

    ---------------------------------------------------------------------------
    -- DUT 1: Xilinx FIR compiler (U55 reference)
    ---------------------------------------------------------------------------
    xi_inst : sps_flatten
    port map (
        aclk                 => clk100,
        s_axis_data_tvalid   => valid_in,
        s_axis_data_tready   => open,
        s_axis_data_tdata    => din,
        s_axis_data_tuser    => tuser,
        s_axis_config_tvalid => config_tvalid,
        s_axis_config_tready => config_tready,
        s_axis_config_tdata  => config_tdata,
        m_axis_data_tvalid   => valid_out,
        m_axis_data_tdata    => dout,
        m_axis_data_tuser    => tuser_out
    );

    ---------------------------------------------------------------------------
    -- DUT 2: custom double-rate FIR (V80)
    ---------------------------------------------------------------------------
    v80_inst : entity ct_lib.sps_flatten_dclk
    port map (
        aclk                => clk100,
        aclk_x2             => clk200,
        s_axis_data_tvalid  => valid_in,
        s_axis_data_tdata   => din,
        s_axis_data_tuser   => tuser,
        s_axis_config_tdata => config_tdata,
        m_axis_data_tvalid  => valid_out_dclk,
        m_axis_data_tdata   => dout_dclk,
        m_axis_data_tuser   => tuser_out_dclk
    );

    ---------------------------------------------------------------------------
    -- Self-checking: compare outputs whenever both filters are simultaneously
    -- producing valid data.
    ---------------------------------------------------------------------------
    check_proc : process(clk100)
        variable L : line;
    begin
        if rising_edge(clk100) then
        
            if (valid_out /= valid_out_dclk) or 
               ((valid_out = '1' or valid_out_dclk = '1') and (dout /= dout_dclk)) then
                mismatch <= '1';
            else
                mismatch <= '0';
            end if;
        
            if valid_out = '1' and valid_out_dclk = '1' then

                compare_count <= compare_count + 1;
                if dout /= x"0000" or dout_dclk /= x"0000" then
                    nonzero_count <= nonzero_count + 1;
                end if;

                if dout /= dout_dclk then
                    data_mismatch <= data_mismatch + 1;
                    write(L, string'("DATA  MISMATCH clk="));
                    write(L, clk_num);
                    write(L, string'("  Xilinx=0x"));
                    hwrite(L, dout);
                    write(L, string'("  V80=0x"));
                    hwrite(L, dout_dclk);
                    writeline(output, L);
                end if;

                if tuser_out /= tuser_out_dclk then
                    tuser_mismatch <= tuser_mismatch + 1;
                    write(L, string'("TUSER MISMATCH clk="));
                    write(L, clk_num);
                    write(L, string'("  Xilinx="));
                    write(L, std_logic'image(tuser_out(0)));
                    write(L, string'("  V80="));
                    write(L, std_logic'image(tuser_out_dclk(0)));
                    writeline(output, L);
                end if;

            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Summary and simulation end
    ---------------------------------------------------------------------------
    report_proc : process
        variable L : line;
    begin
        -- Printed before the end of the run; g_REPORT_US must be less than the
        -- simulation runtime set by the calling script.
        wait for g_REPORT_US * 1 us;
        write(L, string'("=== flatten_tb result ===")); writeline(output, L);
        write(L, string'("g_DATA_SELECT     = ")); write(L, g_DATA_SELECT); writeline(output, L);
        write(L, string'("Samples compared  = ")); write(L, compare_count);  writeline(output, L);
        write(L, string'("Non-zero outputs  = ")); write(L, nonzero_count);  writeline(output, L);
        write(L, string'("Data mismatches   = ")); write(L, data_mismatch);  writeline(output, L);
        write(L, string'("Tuser mismatches  = ")); write(L, tuser_mismatch); writeline(output, L);
        if compare_count = 0 then
            write(L, string'("FAIL: the two filters were never valid on the same clock - nothing was compared."));
        elsif nonzero_count = 0 then
            write(L, string'("FAIL: every compared sample was zero - the stimulus never reached the filters."));
        elsif data_mismatch = 0 and tuser_mismatch = 0 then
            write(L, string'("PASS: sps_flatten and sps_flatten_dclk outputs are identical."));
        else
            write(L, string'("FAIL: outputs differ."));
        end if;
        writeline(output, L);
        wait;
    end process;

end Behavioral;
