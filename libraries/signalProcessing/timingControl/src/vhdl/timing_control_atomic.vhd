----------------------------------------------------------------------------
-- Timing control module for Perentie 
--
-- Functions
--
--  Manages a local version of the time, with a resolution of 10 ns.
--  The local time tracks a master timing source, which can either be MACE or packets coming in on the 100GE interface.
--
--  Features:
--   - 64 bit time stamp output, in units of nanoseconds.
--   - Outputs time in several different clock domain.
--   - The time stamp is corrected using a configurable frequency offset that is applied to the 300MHz clock.
-------------------------------------------------------------------------------

LIBRARY IEEE, common_lib, axi4_lib, UNISIM, DSP_top_lib, timingControl_lib;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE axi4_lib.axi4_lite_pkg.ALL;
USE common_lib.common_pkg.ALL;
use UNISIM.vcomponents.all;
USE timingControl_lib.timingControlA_timingcontrola_reg_pkg.ALL;

use DSP_top_lib.dsp_top_pkg.all;
--use ctc_lib.ctc_pkg.all;

Library xpm;
use xpm.vcomponents.all;

entity timing_control_atomic is
    port (
        -- Registers (uses i_clk300)
        mm_rst  : in std_logic;
        i_sla_in  : in  t_axi4_lite_mosi;
        o_sla_out : out t_axi4_lite_miso;
        -------------------------------------------------------
        -- clocks :
        -- THe 300MHz clock must be 300MHz, since it is used to track the time in ns. However this module will still work if the other clocks are not the frequency implied by their name.
        i_clk300        : in std_logic;  -- 300 MHz processing clock, used for interfaces in the vitis core. This clock is used for tracking the time (3 clocks = 10 ns)
        i_clk400        : in std_logic;  -- 400 MHz processing clock.
        i_clk450        : in std_logic;  -- 450 MHz processing clock.
        i_LFAA100GE_clk : in std_logic;  -- 322 MHz clock from the 100GE core. 
        -- Wall time outputs in each clock domain
        o_clk300_wallTime : out std_logic_vector(63 downto 0); -- wall time in clk300 domain, in nanoseconds
        o_clk400_wallTime : out std_logic_vector(63 downto 0); -- wall time in clk400 domain, in nanoseconds
        o_clk450_wallTime : out std_logic_vector(63 downto 0); -- wall time in the clk450 domain, in nanoseconds
        o_clk100GE_wallTime : out std_logic_vector(63 downto 0); -- wall time in LFAA100GE_clk domain, in nanoseconds
        --------------------------------------------------------
        -- Timing notifications from LFAA ingest module.
        -- This is the wall time according to timing packets coming in on the 100G network. This is in the i_LFAA100GE_clk domain.
        i_100GE_timing_valid : in std_logic;
        i_100GE_timing : in std_logic_vector(63 downto 0)  -- current time in nanoseconds according to UDP timing packets from the switch
    );
end timing_control_atomic;

architecture Behavioral of timing_control_atomic is
    
    signal wallTime : std_logic_vector(63 downto 0) := (others => '0');  -- t_wall_time is a record with .sec and .ns
    signal timing_rw : t_timing_rw;
    signal timing_ro : t_timing_ro;
    signal fixedOffset : std_logic_vector(63 downto 0);
    signal MACESetDel2, MACESetDel1 : std_logic := '0';
    signal wallTimeSend : std_logic := '0';
    signal wallTimeHold : std_logic_vector(63 downto 0);
    
    signal MACETime : std_logic_vector(63 downto 0);
    signal MACETime_set : std_logic;
    signal updateTime : std_logic := '0';
    signal newTime : std_logic_vector(63 downto 0);
    signal recentOffset : std_logic_vector(63 downto 0);
    signal recentOffset32bit : std_logic_vector(31 downto 0);
    signal count3 : std_logic_vector(1 downto 0) := "00";
    signal nsCorrection : integer;
    signal correction : std_logic_vector(31 downto 0);
    signal frequencyOffset : std_logic_vector(31 downto 0);
    
    signal LFAA100GE_clkValid : std_logic;
    signal wallTime100GEClk : std_logic_vector(63 downto 0);
    signal clk400_valid : std_logic;
    signal wallTime_clk400 : std_logic_vector(63 downto 0);
    signal clk450_valid : std_logic;
    signal wallTime_clk450 : std_logic_vector(63 downto 0);
    
begin
    
    process(i_clk300)
    begin
        if rising_edge(i_clk300) then
        
            MACESetDel1 <= MACETime_set;
            MACESetDel2 <= MACESetDel1;
            
            if timing_rw.track_select = '0' then
                if ((MACESetDel2 = '0' and MACESetDel1 = '1') or (MACESetDel2 = '1' and MACESetDel1 = '0')) then
                    updateTime <= '1';
                    newTime <= std_logic_vector(unsigned(MACETime) - unsigned(fixedOffset));
                else
                    updateTime <= '0';
                end if;
            else
                if i_100GE_timing_valid = '1' then
                    updateTime <= '1';
                    newTime <= std_logic_vector(unsigned(i_100GE_timing) - unsigned(fixedOffset));
                else
                    updateTime <= '0';
                end if;
            end if;
            
            if updateTime = '1' then
                wallTime <= newTime;
                recentOffset <= std_logic_vector(unsigned(wallTime)  - unsigned(newTime));
                correction <= (others => '0');
            else
                if count3 = "00" then
                    wallTime <= std_logic_vector(unsigned(wallTime) + 10);
                end if;
                -- frequency offset is in parts per billion.
                -- So if we update the correction every 10ns, then a 1 ns offset corresponds to correction = 100,000,000.
                if count3 = "00" then
                    correction <= std_logic_vector(signed(correction) + signed(frequencyOffset));
                end if;
                if count3 = "01" then
                    if (signed(correction) > 100000000) then
                        nsCorrection <= 1;
                        correction <= std_logic_vector(signed(correction) - 100000000);
                    elsif (signed(correction) < -100000000) then
                        nsCorrection <= -1;
                        correction <= std_logic_vector(signed(correction) + 100000000);
                    else
                        nsCorrection <= 0;
                    end if;
                else
                    nsCorrection <= 0;
                end if;
                if count3 = "10" then
                    wallTime <= std_logic_vector(signed(wallTime) + nsCorrection);
                end if;
                
            end if;
            frequencyOffset(19 downto 0) <= timing_rw.frequency_offset;
            frequencyOffset(31 downto 20) <= frequencyOffset(19) & frequencyOffset(19) & frequencyOffset(19) & frequencyOffset(19) & frequencyOffset(19) & frequencyOffset(19) & frequencyOffset(19) & frequencyOffset(19) & frequencyOffset(19) & frequencyOffset(19) & frequencyOffset(19) & frequencyOffset(19);
            
            if count3 = "00" then
                count3 <= "01";
            elsif count3 = "01" then
                count3 <= "10";
            else -- if count3 = "10" then
                count3 <= "00";
            end if;
            
            
            if (signed(recentOffset) > 2147483647) then
                recentOffset32bit <= x"7fffffff";
            elsif (signed(recentOffset) < -2147483647) then
                recentOffset32bit <= x"80000000";
            else
                recentOffset32bit <= recentOffset(31 downto 0);
            end if;
            
            if count3 = "00" then
                o_clk300_wallTime <= wallTime;
            end if;
        end if;
    end process;
    
    regif : entity timingControl_lib.timingControlA_timingcontrola_reg
    port map (
        MM_CLK        => i_clk300, --  in std_logic;
        MM_RST        => mm_rst, --  in std_logic;
        SLA_IN        => i_sla_in,  -- in t_axi4_lite_mosi;
        SLA_OUT       => o_sla_out, -- out t_axi4_lite_miso;
        TIMING_FIELDS_RW => timing_rw, -- OUT t_timing_rw;
        TIMING_FIELDS_RO => timing_ro  -- IN  t_timing_ro
    );
    
    -- TYPE t_timing_rw is RECORD
    --     track_select	: std_logic; '0' = Track time set by MACE, '1' = track time from UDP packets.
    --     fixed_offset	: std_logic_vector(23 downto 0); Offset in ns between the master time and time in this module.
    --     frequency_offset : std_logic_vector(19 downto 0); frequency offset; Units are parts per 2^32. Value is signed. Maximum frequency offset is +/- 2^19 per 2^32 clocks = +/- 122 ppm.
    --     mace_time_low	: std_logic_vector(31 downto 0); Low 32 bits of the time as specified by MACE
    --     mace_time_high	: std_logic_vector(31 downto 0); High 32 bits of the time as specified by MACE. Transition on top bit triggers an update.
    -- END RECORD;

    -- TYPE t_timing_ro is RECORD
    --     cur_time_low	: std_logic_vector(31 downto 0);
    --     cur_time_high	: std_logic_vector(31 downto 0);
    --     last_time_offset: std_logic_vector(31 downto 0);
    -- END RECORD;
    
    MACETime(31 downto 0) <= timing_rw.mace_time_low;
    MACETime(63 downto 32) <= '0' & timing_rw.mace_time_high(30 downto 0);
    MACETime_set <= timing_rw.mace_time_high(31);
    
    fixedOffset <= x"00000000" & "00000000" & timing_rw.fixed_offset;
    
    timing_ro.cur_time_low <= wallTime(31 downto 0);
    timing_ro.cur_time_high <= wallTime(63 downto 32);
    timing_ro.last_time_offset <= recentOffset32bit;
    
    
    -----------------------------------------------------------------------------
    -------------------------------------------------------------------------------
    -- Get the wall time into the other clock domains
    -- Continuously transfers the current wall clock time to the other clock domains.
    
    process(i_clk300)
    begin
        if rising_edge(i_clk300) then

            if count3 = "00" then
                wallTimeHold <= wallTime;
                wallTimeSend <= not wallTimeSend; -- hold high for 3 clocks, then low for 3 clocks.
            end if;
            
        end if;
    end process;
    
    
    -- xpm_cdc_handshake: Clock Domain Crossing Bus Synchronizer with Full Handshake
    -- Xilinx Parameterized Macro,
    -- This captures the value on src_in on the first cycle where src_send is high.
    -- A single bit crosses the clock domain with resynchronising registers to trigger capture
    -- of the src_in value on another set of registers using dest_clk.
    -- Usage guidelines say that we should wait until src_rcv goes high, then clear src_send,
    -- then wait until src_rcv goes low again before setting src_send.
    -- However, this means it takes many clocks between transfers.
    -- All that really matters is that the single bit synchronising signal (i.e. src_send) is reliably captured in 
    -- the dest_clk domain. If dest_clk is faster than src_clk, then this is guaranteed providing we hold src_send 
    -- unchanged for two clocks.
    -- So we can safely update dest_out every 4 src_clk cycles by driving src_send high two clocks, low two clocks.
    --
    -- Latency through the synchroniser = (1 src_clk cycle) + (DEST_SYNC_FF * dest_clk cycles) + (up to 1 dest_clk_cycle)
    -- e.g. if src_clk period = 4 ns, dest_clk period = 2.5 ns, then latency = 9 to 11.5 ns
    xpm_cdc_handshake1i : xpm_cdc_handshake
    generic map (
        -- Common module generics
        DEST_EXT_HSK   => 0, -- integer; 0=internal handshake, 1=external handshake
        DEST_SYNC_FF   => 2, -- integer; range: 2-10
        INIT_SYNC_FF   => 0, -- integer; 0=disable simulation init values, 1=enable simulation init values
        SIM_ASSERT_CHK => 0, -- integer; 0=disable simulation messages, 1=enable simulation messages. Turn this off so it doesn't complain about violating recommended behaviour or src_send.
        SRC_SYNC_FF    => 2, -- integer; range: 2-10
        WIDTH          => 64 -- integer; range: 1-1024
    )
    port map (
        src_clk  => i_clk300,
        src_in   => wallTimeHold, -- src_in is captured by internal registers on the rising edge of src_send (i.e. in the first src_clk where src_send = '1')
        src_send => wallTimeSend,
        src_rcv  => open,         -- Not used; see discussion above.
        dest_clk => i_LFAA100GE_clk,
        dest_req => LFAA100GE_clkValid,
        dest_ack => '0', -- optional; required when DEST_EXT_HSK = 1
        dest_out => wallTime100GEClk
    );

    process(i_LFAA100GE_clk)
    begin
        if rising_edge(i_LFAA100GE_clk) then
            if LFAA100GE_clkValid = '1' then
                o_clk100GE_wallTime <= wallTime100GEClk;
            end if;
        end if;
    end process;
    

        xpm_cdc_handshake2i : xpm_cdc_handshake
    generic map (
        -- Common module generics
        DEST_EXT_HSK   => 0, -- integer; 0=internal handshake, 1=external handshake
        DEST_SYNC_FF   => 2, -- integer; range: 2-10
        INIT_SYNC_FF   => 0, -- integer; 0=disable simulation init values, 1=enable simulation init values
        SIM_ASSERT_CHK => 0, -- integer; 0=disable simulation messages, 1=enable simulation messages. Turn this off so it doesn't complain about violating recommended behaviour or src_send.
        SRC_SYNC_FF    => 2, -- integer; range: 2-10
        WIDTH          => 64 -- integer; range: 1-1024
    )
    port map (
        src_clk  => i_clk300,
        src_in   => wallTimeHold,  -- src_in is captured by internal registers on the rising edge of src_send (i.e. in the first src_clk where src_send = '1')
        src_send => wallTimeSend,
        src_rcv  => open,          -- Not used; see discussion above.
        dest_clk => i_clk400,
        dest_req => clk400_Valid,
        dest_ack => '0', -- optional; required when DEST_EXT_HSK = 1
        dest_out => wallTime_clk400
    );
    
    process(i_clk400)
    begin
        if rising_edge(i_clk400) then
            if clk400_valid = '1' then
                o_clk400_walltime <= wallTime_clk400;
            end if;
        end if;
    end process;

    xpm_cdc_handshake3i : xpm_cdc_handshake
    generic map (
        -- Common module generics
        DEST_EXT_HSK   => 0, -- integer; 0=internal handshake, 1=external handshake
        DEST_SYNC_FF   => 2, -- integer; range: 2-10
        INIT_SYNC_FF   => 0, -- integer; 0=disable simulation init values, 1=enable simulation init values
        SIM_ASSERT_CHK => 0, -- integer; 0=disable simulation messages, 1=enable simulation messages. Turn this off so it doesn't complain about violating recommended behaviour or src_send.
        SRC_SYNC_FF    => 2, -- integer; range: 2-10
        WIDTH          => 64 -- integer; range: 1-1024
    )
    port map (
        src_clk  => i_clk300,
        src_in   => wallTimeHold,  -- src_in is captured by internal registers on the rising edge of src_send (i.e. in the first src_clk where src_send = '1')
        src_send => wallTimeSend,
        src_rcv  => open,          -- Not used; see discussion above.
        dest_clk => i_clk450,
        dest_req => clk450_Valid,
        dest_ack => '0', -- optional; required when DEST_EXT_HSK = 1
        dest_out => wallTime_clk450
    );
    
    process(i_clk450)
    begin
        if rising_edge(i_clk450) then
            if clk450_valid = '1' then
                o_clk450_walltime <= wallTime_clk450;
            end if;
        end if;
    end process;

    
end Behavioral;
