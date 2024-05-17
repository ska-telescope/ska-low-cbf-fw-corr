----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: April 2024
-- Design Name: 
-- Module Name: cor_rd_meta_mem
-- Description: 
-- 
-- 
-- META data is written in 512 bytes lots, per 16x16 array
-- 8 - RD requests are returned for a single 512 byte.
-- 
-- 512 bytes chosen for efficiency.
-- 2 bytes per visibility
--
-- Using 8 URAMs, the data will be stripped across them.
-- URAMs - 64w (8 byte) x 4096 d
--  1       2       3       4       5       6       7       8
--      1st row of 16           |       2nd row of 16
--      3rd row of 16           |       4th row of 16
--          ....                            ....
--      15th row of 16          |       16th row of 16
--  
--
--  2 - CELL rows
--      1st row of 17           |       2nd row of 17
--      1st row of 18           |       2nd row of 18
--      1st row of 19           |       2nd row of 19
--      1st row of 20           |       2nd row of 20
--  
--  3 - CELL rows
--      1st row of 33           |       2nd row of 33
--      3rd row of 33           |       1st row of 34
--      2nd row of 34           |       3rd row of 34
--      1st row of 35           |       2nd row of 35
--      3rd row of 35           |       1st row of 36
--
-- 
-- 
-- retrieval is per cell before next. 8 beats of 64 bytes = CELL
-- Whole CELLS are retrieved.
-- HBM writes into two 256 bit wide FIFOs to cache the retrieval
-- FIFOs are then drained and written to the 8 URAM arrangement as per the above pattern.
-- Creative circuit to drain the two FIFOs and place in the relevant URAM groups.
--
-- Data is then read out of the URAMs with a pointer that moves along the 8 URAMs getting 2 bytes at a time.

-- Use upper bits of number of rows to work out the offset... ie where to put first row of 33 then 34 then 35 
-- Need starting row as a base offset.
----------------------------------------------------------------------------------

library IEEE, correlator_lib, common_lib, spead_lib, signal_processing_common;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
Library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;
USE common_lib.common_pkg.ALL;
library xpm;
use xpm.vcomponents.all;


entity cor_rd_meta_mem is
    port (
        clk                 : in STD_LOGIC;
        reset               : in STD_LOGIC;

        i_row_start         : in unsigned(12 downto 0);     -- The index of the first row that is available, counts from zero.
        i_number_of_rows    : in unsigned(8 downto 0); -- The number of rows available to be read out. Valid range is 1 to 256.
        
        i_start             : in STD_LOGIC;
        o_ready             : out STD_LOGIC;
        o_complete          : out STD_LOGIC;

        ------------------------------------------------------
        -- data from the HBM
        i_hbm_data          : in STD_LOGIC_VECTOR(511 downto 0);
        i_hbm_data_wr       : in STD_LOGIC;

        i_next_meta         : in STD_LOGIC;
        o_data_out          : out STD_LOGIC_VECTOR(31 downto 0)
    );
end cor_rd_meta_mem;

architecture Behavioral of cor_rd_meta_mem is

constant positions_per_row   : integer := 16;

signal current_row      : unsigned(8 downto 0);
signal cells_per_row    : unsigned(7 downto 0);
signal rows_to_read     : unsigned(8 downto 0);

signal ram_wren         : STD_LOGIC_VECTOR(3 downto 0);     -- 2 URAMs share 1 write vector.

signal HBM_data_a       : std_logic_vector(511 downto 0);
signal HBM_addr_a       : std_logic_vector(11 downto 0);
signal HBM_wren_a       : std_logic;
signal HBM_data_b       : std_logic_vector(511 downto 0);
signal HBM_data_b_cache : std_logic_vector(511 downto 0);
signal HBM_addr_b       : std_logic_vector(11 downto 0);

signal meta_rd_addr     : std_logic_vector(12 downto 0);
signal meta_rd_addr_cache     : std_logic_vector(12 downto 0);

signal meta_sel         : std_logic;

type meta_fsm_type is   (IDLE, INIT_OFFSET, CURRENT_OFFSET,
                         READ_LINE, CHECK, ADJ_CELL,
                         COMPLETE);
signal meta_fsm : meta_fsm_type;

signal row_data         : std_logic_vector(255 downto 0);
signal row_data_ptr     : integer;

signal meta_addr_jump   : unsigned(12 downto 0);
signal step_to_next     : unsigned(12 downto 0);
begin

-------------------------------------------------------------------------------------------
-- Write Pointer for RAMS, take it as cell at a time and will jump the readout.
process(clk, reset)
begin
    if rising_edge(clk) then
        if reset = '1' then
            -- assuming reset is toggled after each triangle read out.
            HBM_addr_a  <= (others => '0');
        else
            if i_hbm_data_wr = '1' then
                HBM_addr_a  <= std_logic_vector(unsigned(HBM_addr_a) + 1);
            end if;
        end if;
    end if;
end process;

HBM_data_a      <= i_hbm_data;
HBM_wren_a      <= i_hbm_data_wr;

------------------------------------------------------------------------------------------
-- Read out process.
process(clk, reset)
begin
    if reset = '1' then
        current_row             <= (others => '0');
        cells_per_row           <= (others => '0');
        rows_to_read            <= (others => '0');

        meta_rd_addr            <= (others => '0');
        meta_rd_addr_cache      <= (others => '0');

        meta_addr_jump          <= (others => '0');

        meta_fsm        <= IDLE;
        o_ready         <= '0';
        o_complete      <= '0';
        row_data_ptr    <= 0;
        
    elsif rising_edge(clk) then

        case meta_fsm is
            when IDLE =>
                if i_start = '1' then
                    meta_fsm                <= INIT_OFFSET;
                    rows_to_read            <= unsigned(i_number_of_rows) - 1;
                    meta_rd_addr_cache      <= (others => '0');
                    meta_rd_addr            <= (others => '0');
                    current_row             <= (others => '0'); --x"00" & '1';       -- literal and always start on the first.
                    meta_addr_jump          <= '0' & x"010";
                    step_to_next            <= '0' & x"020";

                    o_ready                 <= '1';
                end if;

            when INIT_OFFSET =>
                meta_fsm <= CURRENT_OFFSET;
                -- create logic for offsets starting above 0, ie 256/512/1024 correlations.
                -- eg
                --cells_per_row   <= "000" & rows_to_read(8 downto 4);

            when CURRENT_OFFSET =>
                meta_fsm            <= READ_LINE;
                -- cells to read out per line, 1-16 = 1, 17-32 = 2, etc
                cells_per_row       <= "000" & current_row(8 downto 4);

                if current_row = 0 then

                elsif (current_row(3 downto 0) = "0000") then
                    meta_rd_addr        <= std_logic_vector(meta_addr_jump);
                    meta_rd_addr_cache  <= std_logic_vector(meta_addr_jump);
                    meta_addr_jump      <= meta_addr_jump + step_to_next;
                    step_to_next        <= step_to_next + 16;
                else
                    meta_rd_addr_cache  <= meta_rd_addr;
                end if;


            when READ_LINE =>
                if row_data_ptr = 7 then
                    if cells_per_row /= 0 then
                        meta_rd_addr    <= std_logic_vector(unsigned(meta_rd_addr) + 16);
                        cells_per_row   <= cells_per_row - 1;
                        meta_fsm        <= ADJ_CELL;
                    else
                        meta_fsm        <= CHECK;
                        meta_rd_addr    <= std_logic_vector(unsigned(meta_rd_addr_cache) + 1);
                    end if;
                end if;
            
            when ADJ_CELL =>
                meta_fsm        <= READ_LINE;

            when CHECK =>
                -- increment the RAM rd addr and vector ptr.
                --meta_rd_addr    <= std_logic_vector(unsigned(meta_rd_addr) + 1);
                current_row     <= current_row + 1;

                if current_row = rows_to_read then
                    meta_fsm    <= COMPLETE;
                else
                    meta_fsm    <= CURRENT_OFFSET;
                end if;

            when COMPLETE =>
                o_complete  <= '1';


            when OTHERS => meta_fsm <= IDLE;
        end case;

        if i_next_meta = '1' then
            if row_data_ptr = 7 then
                row_data_ptr <= 0;
            else
                row_data_ptr <= row_data_ptr + 1;
            end if;
        end if;

        meta_sel    <= meta_rd_addr(0);

    end if;
end process;

-- read out is right to left on the vector stepping in lots of 2 bytes.
-- 15 -> 0, then 31 -> 16
-- divide the 512 bits into two and use lower bit on addr vector to choose, 0 = 255 -> 0
HBM_data_b_cache    <= HBM_data_b;

row_data    <=  HBM_data_b_cache(511 downto 256) when meta_sel = '1' else
                HBM_data_b_cache(255 downto 0);

HBM_addr_b  <=  meta_rd_addr(12 downto 1);

o_data_out  <= row_data((31 + (row_data_ptr*32)) downto (0 + (row_data_ptr*32)));

uram_gen : FOR i in 0 to 7 GENERATE
    uram_mem : entity signal_processing_common.memory_tdp_wrapper
        GENERIC map (
            MEMORY_INIT_FILE    => "none",
            MEMORY_PRIMITIVE    => "ultra", -- "auto", "distributed", "block" or "ultra" ;
            CLOCKING_MODE       => "common_clock",
            g_NO_OF_ADDR_BITS   => 12,        -- 4096
            g_D_Q_WIDTH         => 64,
            g_READ_LATENCY_B    => 1
    
        )
        Port map ( 
            clk_a           => clk,
            clk_b           => clk,
        
            data_a          => HBM_data_a((63 + (i*64)) downto (0 + (i*64))),
            addr_a          => HBM_addr_a,
            data_a_wr       => HBM_wren_a,
            data_a_q        => OPEN,
    
            data_b          => (Others => '0'),
            addr_b          => HBM_addr_b,
            data_b_wr       => '0',
            data_b_q        => HBM_data_b((63 + (i*64)) downto (0 + (i*64)))
        
        );

END GENERATE;


end Behavioral;
