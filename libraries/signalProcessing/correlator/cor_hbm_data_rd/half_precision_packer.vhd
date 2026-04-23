----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: April 2026
-- Design Name: 
-- Module Name: half_precision_packer
-- Description: 
-- 
-- This module takes in the sorted data from the 16x16 matrix and packs it 64 byets.
--
-- Half precision will require a pipeline of at least 5 and will wrap around at 9 steps.
--
----------------------------------------------------------------------------------

library IEEE, correlator_lib, common_lib, spead_lib, signal_processing_common, xpm;

use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use common_lib.common_pkg.ALL;
use xpm.vcomponents.ALL;


entity half_precision_packer is
    port (
        clk                 : in STD_LOGIC;
        reset               : in STD_LOGIC;

        ------------------------------------------------------
        -- data from the picker FSM
        i_sorted_data       : in STD_LOGIC_VECTOR(271 downto 0);
        i_sorted_data_wr    : in STD_LOGIC;

        o_data_out          : out STD_LOGIC_VECTOR(511 downto 0);
        o_data_valid        : out STD_LOGIC;

        i_heap_size         : in UNSIGNED(31 downto 0);
        o_finished_pack     : out STD_LOGIC
    );
end half_precision_packer;

architecture Behavioral of half_precision_packer is

component float32_to_float16 is
    port (
        clk                 : in STD_LOGIC;
        reset               : in STD_LOGIC;
        
        i_valid             : in STD_LOGIC;
        i_data_in           : in STD_LOGIC_VECTOR(31 downto 0);

        ------------------------------------------------------

        o_valid             : out STD_LOGIC;
        o_data_out          : out STD_LOGIC_VECTOR(15 downto 0)
    );
end component;

signal sorted_data      : std_logic_vector(255 downto 0);
signal sorted_data_wr   : std_logic;
signal reset_int        : std_logic;

signal half_p_data      : std_logic_vector(127 downto 0);
signal half_p_valid     : std_logic_vector(7 downto 0);

signal valid_del        : std_logic_vector(7 downto 0);

constant cycles_from_input : INTEGER := 8;
signal meta_data_pipe   : t_slv_16_arr((cycles_from_input-1) downto 0);

constant half_p_steps   : INTEGER := 6;
signal half_p_pipe      : t_slv_144_arr((half_p_steps-1) downto 0);

signal packed_wr        : std_logic := '0';

signal bytes_in_pipeline_tracker    : unsigned(7 downto 0) := x"00";

signal gearbox_position             : unsigned(7 downto 0) := x"00";

signal aligned_data     : std_logic_vector(511 downto 0) := (others => '0');
signal aligned_data_wr  : std_logic := '0';

signal total_bytes_added_to_heap    : unsigned(31 downto 0) := x"00000000";

signal trigger_final_drain  : std_logic := '0';

signal sample_per_output_tracker    : unsigned(1 downto 0) := "00";

signal finished_pack        : std_logic_vector(3 downto 0) := x"0";

begin

--------------------------------------------------------

reg_proc : process(clk)
begin
    if rising_edge(clk) then
        reset_int   <= reset;

        sorted_data     <= i_sorted_data(271 downto 16);
        sorted_data_wr  <= i_sorted_data_wr;

        o_data_out      <= aligned_data;
        o_data_valid    <= aligned_data_wr;

        o_finished_pack <= finished_pack(3);


        meta_data_pipe(0)                               <= i_sorted_data(15 downto 0);
        meta_data_pipe(cycles_from_input-1 downto 1)    <= meta_data_pipe(cycles_from_input-2 downto 0);
        -- data is sorted before it arrives here, it is a mixture of 
        -- continous writes and then a gap when data is being dropped from the matrix read out.
        -- add data to the packing pipeline after it has been through the f_to_f and gate that on writes.

        -- create pipeline post f_to_f converter for packing logic
        if half_p_valid(1) = '1' OR (trigger_final_drain = '1') then
            half_p_pipe(0)                          <= (half_p_data & meta_data_pipe(cycles_from_input-1));
            half_p_pipe((half_p_steps-1) downto 1)  <= half_p_pipe((half_p_steps-2) downto 0);
        end if;

        -- after f_to_f, stack up the data
        -- add 18 bytes per input
        -- subtract 64 when packed vector writen
        -- subtract 46 when input and vector written occur same cycle.
        if ((half_p_valid(0) = '1') OR (trigger_final_drain = '1')) AND (packed_wr = '1') then
            bytes_in_pipeline_tracker   <= bytes_in_pipeline_tracker - 46;
        elsif (packed_wr = '1') then
            bytes_in_pipeline_tracker   <= bytes_in_pipeline_tracker - 64;
        elsif ((half_p_valid(0) = '1') OR (trigger_final_drain = '1')) then
            bytes_in_pipeline_tracker   <= bytes_in_pipeline_tracker + 18;
        end if;

        if bytes_in_pipeline_tracker >= 64 then
            if gearbox_position = 9 then
                gearbox_position    <= x"01";
            else
                gearbox_position    <= gearbox_position + 1;
            end if;
        end if;

        -- create a total bytes count
        -- this will be matched against the programmed heap size
        -- and when that is true, any transfers less than the 8192
        -- or less than 64 byte transfers will be pushed through.
        valid_del   <= valid_del(6 downto 0) & half_p_valid(2);
        if half_p_valid(2) = '1' then
            total_bytes_added_to_heap   <= total_bytes_added_to_heap + 18;
        end if;

        -- total number of visibility bytes packed matches the programmed size,
        -- need to flush out an aligned vector.
        if half_p_valid(3) = '1' then
            sample_per_output_tracker   <= sample_per_output_tracker + 1;
        elsif (total_bytes_added_to_heap >= i_heap_size) then
            -- allow a few cycles to flush final data if not 64 byte aligned 
            -- when packed onto vector
            -- there are 4 x 18 byte vectors per.
            finished_pack(0)    <= '1';
            if (sample_per_output_tracker /= "00") then
                trigger_final_drain <= '1';
                sample_per_output_tracker   <= sample_per_output_tracker + 1;
            else
                trigger_final_drain <= '0';
            end if;
        end if;

        finished_pack(3 downto 1)   <= finished_pack(2 downto 0);

        if reset_int = '1' then
            gearbox_position            <= x"01";
            total_bytes_added_to_heap   <= x"00000000";
            trigger_final_drain         <= '0';
            sample_per_output_tracker   <= "00";
            finished_pack               <= x"0";
        end if;
    end if;
end process;

packed_wr   <= '1' when ((bytes_in_pipeline_tracker >= 64)) else '0';

--------------------------------------------------------
p_gear_box : process(clk)
begin
    if rising_edge(clk) then
        aligned_data_wr     <= packed_wr;

        if reset_int = '1' then
            aligned_data_wr <= '0';
        end if;

        -- 9 stage gearbox, 32 sameples wraps around in positions.
        -- 18 bytes per sample, and split across beats.
        --
        -- 1.       S1      +       S2      +       S3      +       S4(10)
        -- 2.       S4(8)   +       S5      +       S6      +       S7      +       S8(2)
        -- 3.       S8(16)  +       S9      +       S10     +       S11(12)
        -- 4.       S11(6)  +       S12     +       S13     +       S14     +       S15(4)
        -- 5.       S15(14) +       S16     +       S17     +       S18(14)
        -- 6.       S18(4)  +       S19     +       S20     +       S21     +       S22(6)
        -- 7.       S22(12) +       S23     +       S24     +       S24(16)
        -- 8.       S25(2)  +       S26     +       S27     +       S27     +       S28(8)
        -- 9.       S29(10) +       S30     +       S31     +       S32

        if (gearbox_position = 1) then
            aligned_data    <= half_p_pipe(3) & half_p_pipe(2) & half_p_pipe(1) & half_p_pipe(0)(143 downto 64);
        end if;
        if (gearbox_position = 2) then
            aligned_data    <= half_p_pipe(4)(63 downto 0) & half_p_pipe(3) & half_p_pipe(2) & half_p_pipe(1) & half_p_pipe(0)(143 downto 128);
        end if;
        if (gearbox_position = 3) then
            aligned_data    <= half_p_pipe(3)(127 downto 0) & half_p_pipe(2) & half_p_pipe(1) & half_p_pipe(0)(143 downto 48);
        end if;
        if (gearbox_position = 4) then
            aligned_data    <= half_p_pipe(4)(47 downto 0) & half_p_pipe(3) & half_p_pipe(2) & half_p_pipe(1) & half_p_pipe(0)(143 downto 112);
        end if;
        if (gearbox_position = 5) then
            aligned_data    <= half_p_pipe(3)(111 downto 0) & half_p_pipe(2) & half_p_pipe(1) & half_p_pipe(0)(143 downto 32);
        end if;
        if (gearbox_position = 6) then
            aligned_data    <= half_p_pipe(4)(31 downto 0) & half_p_pipe(3) & half_p_pipe(2) & half_p_pipe(1) & half_p_pipe(0)(143 downto 96);
        end if;
        if (gearbox_position = 7) then
            aligned_data    <= half_p_pipe(3)(95 downto 0) & half_p_pipe(2) & half_p_pipe(1) & half_p_pipe(0)(143 downto 16);
        end if;
        if (gearbox_position = 8) then
            aligned_data    <= half_p_pipe(4)(15 downto 0) & half_p_pipe(3) & half_p_pipe(2) & half_p_pipe(1) & half_p_pipe(0)(143 downto 80);
        end if;
        if (gearbox_position = 9) then
            aligned_data    <= half_p_pipe(3)(79 downto 0) & half_p_pipe(2) & half_p_pipe(1) & half_p_pipe(0);
        end if;

    end if;
end process;

--------------------------------------------------------
-- convert full to half precision.
gen_converter : for i in 0 to 7 generate
    i_f_to_f : float32_to_float16 port map (
        clk         => clk,
        reset       => reset_int,
        
        i_valid     => sorted_data_wr,
        i_data_in   => sorted_data((31 + (32*i)) downto (0 + (32*i))),

        ------------------------------------------------------

        o_valid     => half_p_valid(i),
        o_data_out  => half_p_data((15 + (16*i)) downto (0 + (16*i)))
    );

end generate;

end Behavioral;
