----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: 14 Feb 2023
-- Design Name: 
-- Module Name: cor_rd_HBM_queue_manager
--  
-- Description: 
-- This takes in a base address and how many reads
-- and will maintain the two data buffers that need to be interleaved to create SPEAD packets.
-- 
-- Start address of the meta data is at (i_HBM_start_addr/16 + 256 Mbytes)
--
--
--
-- 
-- 
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

entity cor_rd_HBM_queue_manager is
    Generic ( 
        DEBUG_ILA               : BOOLEAN := FALSE;
        META_FIFO_WRITE_WIDTH   : INTEGER := 512;
        META_FIFO_WRITE_DEPTH   : INTEGER := 128;
        META_FIFO_READ_WIDTH    : INTEGER := 32;
        META_FIFO_READ_DEPTH    : INTEGER := 512;

        HBM_DATA_DEPTH          : INTEGER := 4096;
        HBM_DATA_WIDTH          : INTEGER := 512
    );
    Port ( 
        -- clock used for all data input and output from this module (300 MHz)
        clk                         : in std_logic;
        reset                       : in std_logic;

        i_fifo_reset                : in std_logic;
        o_fifo_in_rst               : out std_logic;

        -- HBM config
        i_begin                     : in std_logic;
        i_hbm_base_addr             : in unsigned(31 downto 0);
        i_row_start                 : in unsigned(12 downto 0);     -- The index of the first row that is available, counts from zero.
        i_number_of_rows            : in unsigned(8 downto 0);
        o_done                      : out std_logic;

        -- Visibility Data FIFO RD interface
        i_hbm_data_fifo_rd          : in std_logic;
        o_hbm_data_fifo_q           : out std_logic_vector((hbm_data_width-1) downto 0);
        o_hbm_data_fifo_empty       : out std_logic;
        o_hbm_data_fifo_rd_count    : out std_logic_vector(((ceil_log2(hbm_data_depth))) downto 0);
        o_hbm_data_fifo_q_valid     : out std_logic;

        -- Meta Data FIFO RD interface
        i_hbm_meta_fifo_rd          : in std_logic;
        o_hbm_meta_fifo_q           : out std_logic_vector((META_FIFO_READ_WIDTH-1) downto 0);
        o_hbm_meta_fifo_empty       : out std_logic;
        o_hbm_meta_fifo_rd_count    : out std_logic_vector(((ceil_log2(META_FIFO_READ_DEPTH))) downto 0);

        -- feedback to pass to Correlator
        o_HBM_curr_addr             : out std_logic_vector(31 downto 0);     -- current start HBM address being processed, feedback bus for correlator logic.

        -- debug
        o_hbm_reader_fsm_debug          : out std_logic_vector(3 downto 0);
        o_hbm_reader_fsm_debug_cache    : out std_logic_vector(3 downto 0);

        -- HBM read interface
        o_HBM_axi_ar                : out t_axi4_full_addr;                 -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_arready           : in  std_logic;
        i_HBM_axi_r                 : in  t_axi4_full_data;                 -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_rready            : out std_logic

    );
end cor_rd_HBM_queue_manager;

architecture Behavioral of cor_rd_HBM_queue_manager is

COMPONENT ila_8k
PORT (
    clk : IN STD_LOGIC;
    probe0 : IN STD_LOGIC_VECTOR(191 DOWNTO 0));
END COMPONENT; 

constant META_OFFSET_256MB  : unsigned(31 downto 0) := x"10000000";

-- This is the address offset for stations > 16,
-- matrix is stripped, retrieve 512 bytes and if more than 16 then need to add 
-- CELL_OFFSET to get next position.
constant CELL_OFFSET_ROW    : unsigned(27 downto 0) := x"0002000"; 

-- TYPE meta_hbm_capture IS ARRAY (INTEGER RANGE <>) OF UNSIGNED(7 DOWNTO 0);
-- constant meta_fifo_wrens : meta_hbm_capture(0 to 15)    := (x"01",
--                                                             x"03",
--                                                             x"07",
--                                                             x"0F",
--                                                             x"4",
--                                                             x"5",
--                                                             x"6",
--                                                             x"7",
--                                                             x"8",
--                                                             x"9",
--                                                             x"A",
--                                                             x"B",
--                                                             x"C",
--                                                             x"D",
--                                                             x"E",
--                                                             x"F");


-- HBM data from correlator.
signal hbm_data_fifo_in_reset : std_logic;
signal hbm_data_fifo_rd       : std_logic;
signal hbm_data_fifo_q        : std_logic_vector((hbm_data_width-1) downto 0);
signal hbm_data_fifo_q_valid  : std_logic;
signal hbm_data_fifo_empty    : std_logic;
signal hbm_data_fifo_rd_count : std_logic_vector(((ceil_log2(hbm_data_depth))) downto 0);
-- WR        
signal hbm_data_fifo_wr       : std_logic;
signal hbm_data_fifo_data     : std_logic_vector((hbm_data_width-1) downto 0);
signal hbm_data_fifo_full     : std_logic;
signal hbm_data_fifo_wr_count : std_logic_vector(((ceil_log2(hbm_data_depth))) downto 0);

-- HBM meta from correlator.
signal hbm_meta_rd_rst_busy   : std_logic;
signal hbm_meta_wr_rst_busy   : std_logic;
signal hbm_meta_fifo_rd       : std_logic;
signal hbm_meta_fifo_q        : std_logic_vector((META_FIFO_READ_WIDTH-1) downto 0);
signal hbm_meta_fifo_q_valid  : std_logic;
signal hbm_meta_fifo_empty    : std_logic;
signal hbm_meta_fifo_rd_count : std_logic_vector(((ceil_log2(META_FIFO_READ_DEPTH-1))) downto 0);
-- WR        
signal hbm_meta_fifo_wr       : std_logic;
signal hbm_meta_fifo_data     : std_logic_vector((META_FIFO_WRITE_WIDTH-1) downto 0);
signal hbm_meta_fifo_full     : std_logic;
signal hbm_meta_fifo_wr_count : std_logic_vector(((ceil_log2(META_FIFO_WRITE_DEPTH))) downto 0);

signal hbm_addr_sel           : std_logic;
signal hbm_data_sel           : std_logic;

signal hbm_data_sel_cnt       : unsigned(7 downto 0);

----------------------------------------------------------------------------
-- hbm rd signals
type HBM_reader_fsm_type is     (IDLE, TRACKER, CALC, 
                                RD_META, RD_META_AR, 
                                RD_DATA, RD_DATA_AR, 
                                DATA_2, META_ADDR, DATA_SEL,
                                CELL_ROW, CHECK, COMPLETE);
signal HBM_reader_fsm : HBM_reader_fsm_type;

signal hbm_reader_fsm_debug         : std_logic_vector(3 downto 0)  := x"0";
signal hbm_reader_fsm_debug_d       : std_logic_vector(3 downto 0)  := x"0";
signal hbm_reader_fsm_debug_cache   : std_logic_vector(3 downto 0)  := x"0";

-- 512 byte rds
signal meta_data_addr       : unsigned(27 downto 0) := (others => '0');
signal meta_data_quantity   : unsigned(13 downto 0) := (others => '0');

signal vis_data_addr        : unsigned(27 downto 0) := (others => '0');
signal next_data_addr       : unsigned(27 downto 0) := (others => '0');
signal vis_base             : unsigned(27 downto 0) := (others => '0');

signal curr_data_addr       : unsigned(27 downto 0) := (others => '0');

signal hbm_retrieval_trac   : unsigned(7 downto 0) := (others => '0');
signal hbm_returned_trac    : unsigned(7 downto 0) := (others => '0');
signal hbm_reqs_status      : unsigned(7 downto 0) := (others => '0');

signal hbm_axi_ar_valid     : std_logic := '0';
signal hbm_axi_ar_addr      : std_logic_vector(31 downto 0);
signal hbm_axi_ar_len       : std_logic_vector(7 downto 0);
signal hbm_axi_ar_rdy       : std_logic;

signal hbm_rd_loop_cnt      : unsigned(3 downto 0);

signal HBM_axi_data_valid   : std_logic;
signal HBM_axi_data_last    : std_logic;

signal received_64b         : std_logic;

signal rows_process         : unsigned(8 downto 0);
signal rows_position        : unsigned(8 downto 0);
signal cells_required       : unsigned(8 downto 0);
signal cell_row_requests    : unsigned(6 downto 0);

signal reset_combo          : std_logic;

signal meta_cells           : unsigned(7 downto 0);
signal meta_cell_inc        : unsigned(7 downto 0);
signal meta_to_get          : unsigned(7 downto 0);
signal last_flag_goal       : unsigned(7 downto 0);

signal data_returned_done   : std_logic;
signal meta_data_rd_done    : std_logic;

signal meta_ready           : std_logic;

signal row_cell_offset      : unsigned(27 downto 0) := (others => '0');
signal next_cell_row        : unsigned(27 downto 0) := (others => '0');

signal current_hbm_requests_stored : unsigned(12 downto 0) := (others => '0');

signal enable_hbm_read      : std_logic;
signal enable_hbm_read_del  : std_logic;

begin

reset_combo <= reset OR i_fifo_reset;
---------------------------------------------------------------------------
-- port mappings
o_HBM_axi_ar.valid              <= hbm_axi_ar_valid;
o_HBM_axi_ar.addr(39 downto 32) <= x"00";
o_HBM_axi_ar.addr(31 downto 0)  <= hbm_axi_ar_addr;
o_HBM_axi_ar.len                <= hbm_axi_ar_len;


hbm_axi_ar_rdy                  <= i_HBM_axi_arready;

o_HBM_axi_rready                <= '1';


o_hbm_reader_fsm_debug          <= hbm_reader_fsm_debug;
o_hbm_reader_fsm_debug_cache    <= hbm_reader_fsm_debug_cache;

o_done                          <= data_returned_done;

---------------------------------------------------------------------------    
-- Visibility Data FIFO RD interface
hbm_data_fifo_rd                <= i_hbm_data_fifo_rd;
o_hbm_data_fifo_q               <= hbm_data_fifo_q;
o_hbm_data_fifo_empty           <= hbm_data_fifo_empty;
o_hbm_data_fifo_rd_count        <= hbm_data_fifo_rd_count;
o_hbm_data_fifo_q_valid         <= hbm_data_fifo_q_valid;

-- Meta Data FIFO RD interface
hbm_meta_fifo_rd                <= i_hbm_meta_fifo_rd;
o_hbm_meta_fifo_q               <= hbm_meta_fifo_q;
o_hbm_meta_fifo_empty           <= hbm_meta_fifo_empty;
o_hbm_meta_fifo_rd_count        <= hbm_meta_fifo_rd_count;
---------------------------------------------------------------------------
-- HBM rd state machine
-- retrieve data set from two different locations.
-- Start address of the vis data is i_hbm_base_addr
-- Start address of the meta data is at (i_hbm_base_addr/16 + 256 Mbytes)
--
-- initial design is to read from the HBM in lots of 512 bytes.
-- for each 16x16
-- 512 bytes for all the meta data.
-- 8192 bytes for all the vis.
-- request the meta, then vis, then loop.


-- hbm_axi_ar_addr     <=  std_logic_vector(meta_data_addr) when hbm_addr_sel = '0' else
--                         std_logic_vector(vis_data_addr);
-- number of 64b reads. 512b = 8. minus 1 for bus.
hbm_axi_ar_len      <= x"07";

-- need to keep track of data returns for feedback to upper level SM.
hbm_req_track_proc : process(clk)
begin
    if rising_edge(clk) then
        if (HBM_reader_fsm = IDLE) or (reset = '1') then
            hbm_retrieval_trac  <= (others => '0');
            hbm_returned_trac   <= (others => '0');
            hbm_reqs_status     <= (others => '0');
        else
            if (hbm_axi_ar_valid = '1' AND hbm_axi_ar_rdy = '1') then
                hbm_retrieval_trac  <= hbm_retrieval_trac + 1;
            end if;

            if (i_HBM_axi_r.valid = '1' AND i_HBM_axi_r.last = '1') then
                hbm_returned_trac   <= hbm_returned_trac + 1;
            end if;

            if (hbm_axi_ar_valid = '1' AND hbm_axi_ar_rdy = '1') AND (i_HBM_axi_r.valid = '1' AND i_HBM_axi_r.last = '1') then
                hbm_reqs_status     <= hbm_reqs_status;
            elsif (hbm_axi_ar_valid = '1' AND hbm_axi_ar_rdy = '1') then
                hbm_reqs_status     <= hbm_reqs_status + 1;
            elsif (i_HBM_axi_r.valid = '1' AND i_HBM_axi_r.last = '1') then
                hbm_reqs_status     <= hbm_reqs_status - 1;
            end if;
        end if;
        
        -- space in FIFO
        -- each read request is 512 bytes.
        -- FIFO stores 64 bytes per line so 8 lines.
        -- If FIFO is above 7/8 don't request.
        -- FIFO is 4096 deep = 3584 fill level.
        -- 
        current_hbm_requests_stored <= unsigned(hbm_data_fifo_wr_count) + (hbm_reqs_status & "000");
        
        if (current_hbm_requests_stored > 3584) then
            enable_hbm_read <= '0';
        else
            enable_hbm_read <= '1';
        end if;
        
        enable_hbm_read_del <= enable_hbm_read;
    end if;
end process;

rd_hbm_sm_proc: process (clk)
begin
    if rising_edge(clk) then
        if reset = '1' then
            HBM_reader_fsm      <= IDLE;
            hbm_reader_fsm_debug    <= x"F";
            hbm_reader_fsm_debug_d  <= x"F";
            meta_data_addr      <= (others => '0');
            meta_data_quantity  <= (others => '0');
            vis_data_addr       <= (others => '0');
            o_HBM_curr_addr     <= (others => '0');
            meta_ready          <= '0';
            
            hbm_axi_ar_valid    <= '0';
            
            hbm_axi_ar_addr     <= x"00000000";
            hbm_rd_loop_cnt     <= x"0";
            data_returned_done  <= '0';
            meta_cells          <= x"00";
            meta_cell_inc       <= x"00";
            meta_to_get         <= x"00";
            last_flag_goal      <= x"00";
            hbm_data_sel        <= '0';
            row_cell_offset     <= CELL_OFFSET_ROW;
            next_cell_row       <= CELL_OFFSET_ROW(26 downto 0) & '0';
        else
            
            hbm_reader_fsm_debug_d <= hbm_reader_fsm_debug;

            if (hbm_reader_fsm_debug_d /= hbm_reader_fsm_debug) then
                hbm_reader_fsm_debug_cache <= hbm_reader_fsm_debug_d;
            end if;

            -- This SM controls the retrieval from HBM.
            -- FOR VISIBILITIES.
            -- The approach is, each row of 16 correlations = 512 bytes.
            -- for 16 stations, there will be 16 x 512 requests.
            -- for 17 stations, the 17th row will have an addition row request.
            -- for 33 stations, the 33rd row will have an addition 2 requests.
            --
            -- cell 1
            -- cell 2 | cell 3
            --
            -- where a cell is 16x16 and the top left of cell 3 is 17x17
            --
            -- FOR META 
            -- Get META first, request all the Cells.
            -- This is done at the start.

            case HBM_reader_fsm is
                when IDLE =>
                    hbm_reader_fsm_debug    <= x"0";
                    hbm_data_sel            <= '0';
                    if i_begin = '1' then
                        HBM_reader_fsm  <= CHECK;
                        -- report back current HBM address in use.
                        o_HBM_curr_addr <= std_logic_vector(i_hbm_base_addr);
                    end if;
                    hbm_rd_loop_cnt     <= x"0";
                    -- META data always stored in upper half of HBM segment.
                    meta_data_addr      <= i_hbm_base_addr(31 downto 4); --META_OFFSET_256MB + (x"0" & i_hbm_base_addr(31 downto 4));
                    vis_data_addr       <= i_hbm_base_addr(27 downto 0);
                    vis_base            <= i_hbm_base_addr(27 downto 0);
                    rows_process        <= i_number_of_rows;
                    rows_position       <= 9D"0";
                    data_returned_done  <= '0';

                    meta_cells              <= x"00";
                    meta_cell_inc           <= x"01";
                    meta_to_get             <= "000" & i_number_of_rows(8 downto 4);
                    last_flag_goal          <= x"00";
                    row_cell_offset     <= CELL_OFFSET_ROW;
                    next_cell_row       <= CELL_OFFSET_ROW(26 downto 0) & '0';
                ---------------------------------------------------------------------------------------
                -- Get meta

                when CHECK =>
                    hbm_reader_fsm_debug    <= x"1";
                -- calculate how many CELLS of META data to be retrieved.
                    meta_cell_inc           <= meta_cell_inc + 1;
                    meta_cells              <= meta_cell_inc + meta_cells;
                    last_flag_goal          <= meta_cell_inc + meta_cells - 1;

                    if meta_to_get = 0 then
                        HBM_reader_fsm      <= META_ADDR;
                        meta_cell_inc       <= meta_cells - 1;
                    else
                        meta_to_get         <= meta_to_get - 1;
                    end if;

                    
                when META_ADDR =>
                    hbm_reader_fsm_debug    <= x"2";
                    HBM_reader_fsm          <= RD_META;
                    curr_data_addr          <= meta_data_addr;

                when RD_META =>
                    hbm_reader_fsm_debug    <= x"3";
                    hbm_axi_ar_addr         <= "0001" & std_logic_vector(curr_data_addr);
                    hbm_axi_ar_valid        <= '1';
                        
                    HBM_reader_fsm          <= RD_META_AR;

                when RD_META_AR =>
                    hbm_reader_fsm_debug    <= x"4";
                    if hbm_axi_ar_rdy = '1' then
                        hbm_axi_ar_valid    <= '0';
                        HBM_reader_fsm      <= DATA_2;
                    end if;

                when DATA_2 => 
                    hbm_reader_fsm_debug    <= x"5";
                    meta_data_addr          <= meta_data_addr + 512;

                    if meta_cells = 1 then
                        HBM_reader_fsm      <= DATA_SEL;
                        meta_ready          <= '1';
                    else
                        HBM_reader_fsm      <= META_ADDR;
                        meta_cells          <= meta_cells - 1;
                    end if;
                    -- request 8k of data and wait until it is drain to 50% before next loop.
                    -- elsif unsigned(hbm_data_fifo_rd_count) < 3072 then
                    --     HBM_reader_fsm      <= CHECK;
                    -- end if;

                ---------------------------------------------------------------------------------------
                -- wait for META, then toggle write flag
                when DATA_SEL =>
                    hbm_reader_fsm_debug    <= x"6";
                    if hbm_retrieval_trac = hbm_returned_trac then
                        hbm_data_sel        <= '1';
                        HBM_reader_fsm      <= TRACKER;
                    end if;


                ---------------------------------------------------------------------------------------
                -- Get visibilities
                when CELL_ROW =>
                    hbm_reader_fsm_debug    <= x"C";
                    if std_logic_vector(rows_position(3 downto 0)) = x"0" then
                        row_cell_offset     <= row_cell_offset + next_cell_row;
                        next_cell_row       <= next_cell_row + CELL_OFFSET_ROW;
                        vis_data_addr       <= row_cell_offset + vis_base;
                        
                    end if;
                    HBM_reader_fsm          <= TRACKER;
                
                
                when TRACKER =>
                    hbm_reader_fsm_debug    <= x"7";

                    meta_ready              <= '0';
                    -- if position = number of rows then exit
                    if rows_position = rows_process then
                        HBM_reader_fsm      <= COMPLETE;
                    else
                        HBM_reader_fsm      <= CALC;
                        rows_position       <= rows_position + 1;
                        next_data_addr      <= vis_data_addr;
                        curr_data_addr      <= vis_data_addr;
                        cells_required      <= unsigned("0000" & rows_position(8 downto 4)) + 1;
                    end if;
                    cell_row_requests       <= (others => '0');

                when CALC =>
                    hbm_reader_fsm_debug    <= x"8";
                    -- this is wrapping around and used as an exit condition.
                    if cells_required = cell_row_requests then
                        HBM_reader_fsm      <= CELL_ROW;
                        vis_data_addr       <= vis_data_addr + 512;     -- increment to next row offset.
                    else
                        cell_row_requests   <= cell_row_requests + 1;
                        HBM_reader_fsm      <= RD_DATA;
                        curr_data_addr      <= next_data_addr;
                        next_data_addr      <= next_data_addr + CELL_OFFSET_ROW;   -- the next row is 8192 bytes away in the next cell.  
                    end if;

                when RD_DATA =>
                    hbm_reader_fsm_debug    <= x"9";
                    
                    if (enable_hbm_read_del = '1') then
                        hbm_axi_ar_addr         <= "0000" & std_logic_vector(curr_data_addr);
                        hbm_axi_ar_valid        <= '1';
    
                        HBM_reader_fsm          <= RD_DATA_AR;
                    end if;


                when RD_DATA_AR =>
                    hbm_reader_fsm_debug    <= x"A";
                    if hbm_axi_ar_rdy = '1' then
                        hbm_axi_ar_valid    <= '0';

                        HBM_reader_fsm      <= CALC;
                    end if;


                when COMPLETE =>
                    hbm_reader_fsm_debug    <= x"B";
                    if hbm_retrieval_trac = hbm_returned_trac then
                        data_returned_done  <= '1';
                    end if;
                    if i_fifo_reset = '1' then
                        HBM_reader_fsm <= IDLE;
                    end if;

                when OTHERS =>
                    HBM_reader_fsm <= IDLE;

            end case;
        end if;
    end if;
end process;

---------------------------------------------------------------------------
-- DATA cache
-- DATA is requested in lots of 16x16.
-- meta data comes first, count the last flags to match the requests above.
--

-- received_64b    <= '1' when i_HBM_axi_r.valid = '1' AND i_HBM_axi_r.last = '1' else '0';

-- hbm_sel_proc : process(clk)
-- begin
--     if rising_edge(clk) then
--         if  (HBM_reader_fsm = IDLE) then
--             hbm_data_sel        <= '0';
--         elsif (received_64b = '1') AND last_flag_goal = hbm_data_sel_cnt then
--             hbm_data_sel        <= '1'; 
--         end if;

--         if  (HBM_reader_fsm = IDLE) then
--             hbm_data_sel_cnt    <= x"00";
--         elsif (received_64b = '1') then
--             hbm_data_sel_cnt    <= hbm_data_sel_cnt + 1;
--         end if;
--     end if;
-- end process;

    o_fifo_in_rst       <= hbm_data_fifo_in_reset;

    hbm_data_fifo_data  <= i_HBM_axi_r.data;
    hbm_data_fifo_wr    <= i_HBM_axi_r.valid AND hbm_data_sel;

    -- URAMs have a natural width of 4K x 72 bits
    -- 512W should use 8 URAMs which would give an effectively 4K x 4096
    hbm_data_cache_fifo : entity signal_processing_common.xpm_sync_fifo_wrapper
        Generic map (
            FIFO_MEMORY_TYPE    => "uram",
            READ_MODE           => "fwft",
            FIFO_DEPTH          => hbm_data_depth,
            DATA_WIDTH          => hbm_data_width
        )
        Port map ( 
            fifo_reset          => i_fifo_reset,
            fifo_clk            => clk,
            fifo_in_reset       => hbm_data_fifo_in_reset,
            -- RD    
            fifo_rd             => hbm_data_fifo_rd,
            fifo_q              => hbm_data_fifo_q,
            fifo_q_valid        => hbm_data_fifo_q_valid,
            fifo_empty          => hbm_data_fifo_empty,
            fifo_rd_count       => hbm_data_fifo_rd_count,
            -- WR        
            fifo_wr             => hbm_data_fifo_wr,
            fifo_data           => hbm_data_fifo_data,
            fifo_full           => hbm_data_fifo_full,
            fifo_wr_count       => hbm_data_fifo_wr_count
        );

-- META cache
    hbm_meta_fifo_data  <= i_HBM_axi_r.data;
    hbm_meta_fifo_wr    <= i_HBM_axi_r.valid AND (NOT hbm_data_sel);


    meta_handler : entity correlator_lib.cor_rd_meta_mem 
        port map (
            clk                 => clk,
            reset               => reset_combo,
    
            i_row_start         => i_row_start,
            i_number_of_rows    => i_number_of_rows,
            
            i_start             => meta_ready,
            o_ready             => open,
            o_complete          => meta_data_rd_done,
    
            ------------------------------------------------------
            -- data from the HBM
            i_hbm_data          => hbm_meta_fifo_data,
            i_hbm_data_wr       => hbm_meta_fifo_wr,
    
            i_next_meta         => hbm_meta_fifo_rd,
            o_data_out          => hbm_meta_fifo_q
        );

-- constant META_FIFO_WRITE_WIDTH : integer := 32;
-- constant META_FIFO_READ_WIDTH  : integer := 64;
-- constant META_FIFO_WRITE_DEPTH : integer := 512;
-- constant META_FIFO_READ_DEPTH  : integer := FIFO_WRITE_DEPTH*WRITE_DATA_WIDTH/READ_DATA_WIDTH;

    -- hbm_meta_cache_fifo : xpm_fifo_sync
    --     generic map (
    --         DOUT_RESET_VALUE    => "0",    
    --         ECC_MODE            => "no_ecc",
    --         FIFO_MEMORY_TYPE    => "block", 
    --         FIFO_READ_LATENCY   => 0,
    --         WRITE_DATA_WIDTH    => META_FIFO_WRITE_WIDTH,     
    --         FIFO_WRITE_DEPTH    => 64,     
    --         FULL_RESET_VALUE    => 0,      
    --         PROG_EMPTY_THRESH   => 0,    
    --         PROG_FULL_THRESH    => 0,     
    --         READ_MODE           => "fwft",  
    --         SIM_ASSERT_CHK      => 0,      
    --         USE_ADV_FEATURES    => "1404", 
    --         WAKEUP_TIME         => 0,      
    --         RD_DATA_COUNT_WIDTH => ((ceil_log2(META_FIFO_READ_DEPTH))+1),  
    --         READ_DATA_WIDTH     => META_FIFO_READ_WIDTH,      
    --         WR_DATA_COUNT_WIDTH => ((ceil_log2(META_FIFO_WRITE_DEPTH))+1)   
    --     )
    --     port map (
    --         rst           => i_fifo_reset, 
    --         wr_clk        => clk, 
    --         rd_rst_busy   => hbm_meta_rd_rst_busy,
    --         wr_rst_busy   => hbm_meta_wr_rst_busy,

    --         --------------------------------
    --         --rd_data_count => op, 
    --         rd_en         => hbm_meta_fifo_rd,  
    --         dout          => hbm_meta_fifo_q,
    --         empty         => hbm_meta_fifo_empty,
    --         rd_data_count => hbm_meta_fifo_rd_count,
    --         data_valid    => open,   
    --         --------------------------------        
    --         wr_data_count => open,
    --         wr_en         => hbm_meta_fifo_wr,
    --         din           => hbm_meta_fifo_data,
    --         full          => open,

    --         almost_empty  => open,  
    --         almost_full   => open,
    --         dbiterr       => open, 
    --         overflow      => open,
    --         prog_empty    => open, 
    --         prog_full     => open,

    --         sbiterr       => open,
    --         underflow     => open,
    --         wr_ack        => open,
    --         sleep         => '0',         
    --         injectdbiterr => '0',     
    --         injectsbiterr => '0'        
    --     );

---------------------------------------------------------------------------
-- debug
gen_debug_ila : IF DEBUG_ILA GENERATE
    hbm_rd_debug : ila_8k PORT MAP (
        clk                     => clk,
        probe0(3 downto 0)      => hbm_reader_fsm_debug,
        probe0(35 downto 4)     => hbm_axi_ar_addr,
        probe0(43 downto 36)    => hbm_axi_ar_len,
        probe0(44)              => hbm_axi_ar_valid,
        probe0(45)              => i_HBM_axi_arready,

        probe0(46)              => i_HBM_axi_r.valid,
        probe0(47)              => i_HBM_axi_r.last,
        probe0(49 downto 48)    => i_HBM_axi_r.resp,
        probe0(81 downto 50)    => i_HBM_axi_r.data(31 downto 0),

        probe0(89 downto 82)    => std_logic_vector(hbm_retrieval_trac),
        probe0(97 downto 90)    => (others => '0'),
        probe0(98)              => hbm_data_fifo_rd,
        probe0(99)              => hbm_data_fifo_wr,
        
        probe0(100)             => hbm_data_sel,
        probe0(106 downto 101)  => std_logic_vector(hbm_data_sel_cnt(5 downto 0)),
        probe0(107)             => hbm_meta_fifo_rd,
        probe0(108)             => hbm_meta_fifo_wr,

        probe0(172 downto 109)  => i_HBM_axi_r.data(319 downto 256),
        
        probe0(185 downto 173)  => std_logic_vector(current_hbm_requests_stored),
        probe0(186)             => enable_hbm_read,
        
        probe0(191 downto 187)  => (others => '0')
        );
        
    hbm_wide_rd_ila_debug : ila_8k PORT MAP (
        clk                     => clk,
            
        probe0(127 downto 0)    => i_HBM_axi_r.data(127 downto 0),
        probe0(128)             => i_HBM_axi_r.valid,
        probe0(129)             => i_HBM_axi_r.last,
        probe0(131 downto 130)  => i_HBM_axi_r.resp,

        
        probe0(163 downto 132)  => hbm_axi_ar_addr,
        probe0(164)             => hbm_axi_ar_valid,
        probe0(165)             => i_HBM_axi_arready,
        probe0(169 downto 166)  => hbm_reader_fsm_debug,
        probe0(170)             => hbm_data_sel,
        probe0(178 downto 171)  => (others => '0'),
        probe0(186 downto 179)  => std_logic_vector(hbm_returned_trac),
        probe0(187)             => hbm_data_fifo_wr,
        probe0(191 downto 188)  => std_logic_vector(hbm_data_sel_cnt(3 downto 0))
        );    
END GENERATE;

end;