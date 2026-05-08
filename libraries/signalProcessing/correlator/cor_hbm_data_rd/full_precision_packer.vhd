----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: April 2026
-- Design Name: 
-- Module Name: half_precision_packer
-- Description: 
-- 
-- 
-- Half precision will require a pipeline of at least 5 and will wrap around at 9 steps.
--
--
--
----------------------------------------------------------------------------------

library IEEE, correlator_lib, common_lib, spead_lib, signal_processing_common, xpm;

use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use common_lib.common_pkg.ALL;
use xpm.vcomponents.ALL;


entity full_precision_packer is
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
end full_precision_packer;

architecture Behavioral of full_precision_packer is

signal sorted_data      : std_logic_vector(271 downto 0);
signal sorted_data_wr   : std_logic;
signal reset_int        : std_logic;

signal half_p_data      : std_logic_vector(127 downto 0);
signal half_p_valid     : std_logic_vector(7 downto 0);

constant half_p_steps   : INTEGER := 4;
signal half_p_pipe      : t_slv_272_arr((half_p_steps-1) downto 0);

signal packed_wr        : std_logic := '0';

signal bytes_in_pipeline_tracker    : unsigned(7 downto 0) := x"00";

signal gearbox_position             : unsigned(7 downto 0) := x"00";

signal aligned_data     : std_logic_vector(511 downto 0) := (others => '0');
signal aligned_data_wr  : std_logic := '0';

signal total_bytes_added_to_heap    : unsigned(31 downto 0) := x"00000000";
signal output_writes_required       : unsigned(31 downto 0) := x"00000000";

signal trigger_final_drain          : std_logic_vector(1 downto 0) := "00";

signal finished_pack        : std_logic_vector(3 downto 0) := x"0";

signal enable_check         : std_logic;

begin

--------------------------------------------------------

reg_proc : process(clk)
begin
    if rising_edge(clk) then
        reset_int   <= reset;

        sorted_data     <= i_sorted_data;
        sorted_data_wr  <= i_sorted_data_wr;

        o_data_out      <= aligned_data;
        o_data_valid    <= aligned_data_wr;

        o_finished_pack <= finished_pack(3);

        -- data is sorted before it arrives here, it is a mixture of 
        -- continous writes and then a gap when data is being dropped from the matrix read out.
        -- add data to the packing pipeline after it has been through the f_to_f and gate that on writes.

        -- create pipeline post f_to_f converter for packing logic
        if sorted_data_wr = '1' OR (trigger_final_drain(1) = '1') then
            half_p_pipe(0)                          <= sorted_data;
            half_p_pipe((half_p_steps-1) downto 1)  <= half_p_pipe((half_p_steps-2) downto 0);
        end if;

        -- after f_to_f, stack up the data
        -- add 34 bytes per input
        -- subtract 64 when packed vector writen
        -- subtract 30 when input and vector written occur same cycle.
        if ((sorted_data_wr = '1') OR (trigger_final_drain(1) = '1')) AND (packed_wr = '1') then
            bytes_in_pipeline_tracker   <= bytes_in_pipeline_tracker - 30;
        elsif (packed_wr = '1') then
            bytes_in_pipeline_tracker   <= bytes_in_pipeline_tracker - 64;
        elsif ((sorted_data_wr = '1') OR (trigger_final_drain(1) = '1')) then
            bytes_in_pipeline_tracker   <= bytes_in_pipeline_tracker + 34;
        end if;

        if bytes_in_pipeline_tracker >= 64 then
            if gearbox_position = 17 then
                gearbox_position    <= x"01";
            else
                gearbox_position    <= gearbox_position + 1;
            end if;
        end if;

        -- create a total bytes count
        -- this will be matched against the programmed heap size
        -- and when that is true, any transfers less than the 8192
        -- or less than 64 byte transfers will be pushed through.
        
        if (sorted_data_wr = '1') OR (trigger_final_drain(1) = '1') then
            total_bytes_added_to_heap   <= total_bytes_added_to_heap + 34;
            enable_check                <= '1';
        end if;

        output_writes_required  <= i_heap_size;

        -- need to flush out an aligned vector.
        if (total_bytes_added_to_heap(31 downto 6) = output_writes_required(31 downto 6)) AND (enable_check = '1') then
            -- allow a few cycles to flush final data if not 64 byte aligned 
            -- when packed onto vector
            -- there are 2 x 34 byte vectors per.
            finished_pack(0)    <= '1';

            if (i_heap_size(5 downto 0) /= "000000") then
                trigger_final_drain <= trigger_final_drain(0) & (NOT trigger_final_drain(0));
            end if;
        end if;

        finished_pack(3 downto 1)   <= finished_pack(2 downto 0);

        if reset_int = '1' then
            gearbox_position            <= x"01";
            total_bytes_added_to_heap   <= x"00000000";
            trigger_final_drain         <= "01";
            finished_pack               <= x"0";
            bytes_in_pipeline_tracker   <= x"00";
            enable_check                <= '0';
            output_writes_required      <= x"00000000";
        end if;
    end if;
end process;

packed_wr   <= '1' when ((bytes_in_pipeline_tracker >= 64)) else '0';

--trigger_final_drain <= '1' when (total_bytes_added_to_heap(31 downto 6) = output_writes_required(31 downto 6)) AND (enable_check = '1') else '0';

--------------------------------------------------------
p_gear_box : process(clk)
begin
    if rising_edge(clk) then
        aligned_data_wr     <= packed_wr;

        if reset_int = '1' then
            aligned_data_wr <= '0';
        end if;

        if (gearbox_position = 1) then
            aligned_data    <=                                  half_p_pipe(1)                   &   half_p_pipe(0)(271 downto 32);
        end if;
        if (gearbox_position = 2) then
            aligned_data    <= half_p_pipe(2)(31 downto 0)    & half_p_pipe(1)                   &   half_p_pipe(0)(271 downto 64);
        end if;
        if (gearbox_position = 3) then
            aligned_data    <= half_p_pipe(2)(63 downto 0)    & half_p_pipe(1)                   &   half_p_pipe(0)(271 downto 96);
        end if;
        if (gearbox_position = 4) then
            aligned_data    <= half_p_pipe(2)(95 downto 0)    & half_p_pipe(1)                   &   half_p_pipe(0)(271 downto 128);
        end if;
        if (gearbox_position = 5) then
            aligned_data    <= half_p_pipe(2)(127 downto 0)   & half_p_pipe(1)                   &   half_p_pipe(0)(271 downto 160);
        end if;
        if (gearbox_position = 6) then
            aligned_data    <= half_p_pipe(2)(159 downto 0)   & half_p_pipe(1)                   &   half_p_pipe(0)(271 downto 192);
        end if;
        if (gearbox_position = 7) then
            aligned_data    <= half_p_pipe(2)(191 downto 0)   & half_p_pipe(1)                   &   half_p_pipe(0)(271 downto 224);
        end if;
        if (gearbox_position = 8) then
            aligned_data    <= half_p_pipe(2)(223 downto 0)   & half_p_pipe(1)                   &   half_p_pipe(0)(271 downto 256);
        end if;
        if (gearbox_position = 9) then
            aligned_data    <=                                  half_p_pipe(1)(255 downto 0)     & half_p_pipe(0)(271 downto 16);
        end if;
        if (gearbox_position = 10) then
            aligned_data    <= half_p_pipe(2)(15 downto 0)    & half_p_pipe(1)                   &   half_p_pipe(0)(271 downto 48);
        end if;
        if (gearbox_position = 11) then
            aligned_data    <= half_p_pipe(2)(47 downto 0)    & half_p_pipe(1)                   &   half_p_pipe(0)(271 downto 80);
        end if;
        if (gearbox_position = 12) then
            aligned_data    <= half_p_pipe(2)(79 downto 0)    & half_p_pipe(1)                   &   half_p_pipe(0)(271 downto 112);
        end if;
        if (gearbox_position = 13) then
            aligned_data    <= half_p_pipe(2)(111 downto 0)   & half_p_pipe(1)                   &   half_p_pipe(0)(271 downto 144);
        end if;
        if (gearbox_position = 14) then
            aligned_data    <= half_p_pipe(2)(143 downto 0)   & half_p_pipe(1)                   &   half_p_pipe(0)(271 downto 176);
        end if;
        if (gearbox_position = 15) then
            aligned_data    <= half_p_pipe(2)(175 downto 0)   & half_p_pipe(1)                   &   half_p_pipe(0)(271 downto 208);
        end if;
        if (gearbox_position = 16) then
            aligned_data    <= half_p_pipe(2)(207 downto 0)   & half_p_pipe(1)                   &   half_p_pipe(0)(271 downto 240);
        end if;
        if (gearbox_position = 17) then
            aligned_data    <=                                  half_p_pipe(1)(239 downto 0)     & half_p_pipe(0);
        end if;

    end if;
end process;

--------------------------------------------------------

end Behavioral;
