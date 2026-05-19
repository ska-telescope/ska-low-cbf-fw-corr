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
        i_row_start                 : in unsigned(12 downto 0);     -- The index of the first row that is available, counts from zero expect 0, 256, 512 etc.
        i_number_of_rows            : in unsigned(8 downto 0);      -- The number of rows available to be read out. Valid range is 1 to 256.
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


-- Cell is 16x16 stations and is written in the following way.
-- C1
-- C2 | C3
-- ...
-- .....
-- 
-- for 257
-- C1 | C2 | ..... | C16  (Add DATA_TILE_OFFSET to get to final) || C17 (AKA T3 - Cell 1)
--
-- Retrieve META and DATA in lots of 16 rows.
-- Meta is a full retrieve of 16 and data will finish on the exact row.


-- This is the address offset for stations > 16,
-- matrix is stripped, retrieve 512 bytes and if more than 16 then need to add 
-- DATA_CELL_OFFSET to get next position.
-- Data Cell = 16 x 16 x 32 bytes = 
constant DATA_CELL_OFFSET       : unsigned(27 downto 0) := x"000_2000"; 

-- when reading across Tiles
-- Tile is 16x16 Cells. And is written in the following way
-- T1                                                   << 256
-- T2  | T3                                             << 512
-- T4  | T5  | T6                                       << 768
-- T7  | T8  | T9  | T10                                << 1024
-- T11 | T12 | T13 | T14 | T15                          << 1280
-- T16 | T17 | T18 | T19 | T20 | T21                    << 1536
-- T22 | T23 | T24 | T25 | T26 | T27 | T28              << 1792
-- T29 | T30 | T31 | T32 | T33 | T34 | T35 | T36        << 2048   ADDR PTRs = 0x100_0000 max.
--
-- Tiles are stored sequentially in HBM, that means tile 1, then tile 2, tile 3, tile 4, etc.
-- T2 = 
-- C1   | C2 | C3 | ..  | C16
-- C17  |   ......      | C32
-- ... 
-- ...
-- C241 |   ......      | C256
--
-- To service a request for 273, expect the following
-- T2 =                         || T3 = 
-- C1   | C2 | C3 | ..  | C16   || C1 |
-- C17  |   ......      | C32   || C2 | C3
-- ...                          ||
-- ...                          ||
-- C241 |   ......      | C256  ||
--
-- To service a request for 528, expect the following
-- T4 =                         || T5 =                         || T6 =
-- C1   | C2 | C3 | ..  | C16   || C1   | C2 | C3 | ..  | C16   || C1 |
-- C17  |   ......      | C32   || C17  |   ......      | C32   || C2 | C3
-- ...                          || ...                          ||
-- ...                          || ...                          ||
-- C241 |   ......      | C256  || C241 |   ......      | C256  ||
--
--
-- Worked example of first row of 257
--
--
--
--
--

-- The next Tile start address offset is
-- 16 x 16 x DATA_CELL_OFFSET(0x2000) = 
constant DATA_TILE_OFFSET       : unsigned(27 downto 0) := x"020_0000"; 

-- Next strip of 16 in a tile offset = 
-- (16 x 16 x 32) x 16 Cells across
constant DATA_TILE_STRIPE_OFFSET: unsigned(27 downto 0) := x"002_0000"; 

-- META ----
-- Meta data starts 256MB after Data.
constant META_OFFSET_256MB      : unsigned(31 downto 0) := x"10000000";

-- Meta Data has the same approach but data is smaller, 2 bytes instead of 32.
-- Therefore META_CELL = 16 x 16 x 2 bytes = 512 byets
constant META_CELL_OFFSET       : unsigned(27 downto 0) := x"0000200";
-- META_TILE = 16 x 16 x 512 = 131072 bytes
constant META_TILE_OFFSET       : unsigned(27 downto 0) := x"002_0000";



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
                                GEN_META_INSTRUCTION, META_GET_TILE, META_GET_CELL, META_TILE_JUMP_ADDR,
                                RD_META, RD_META_AR, CHECK_META, 
                                GEN_DATA_INSTRUCTION, DATA_GET_TILE, DATA_GET_CELL, 
                                RD_DATA, RD_DATA_AR, CHECK_DATA,
                                DATA_SEL,
                                CELL_ROW, COMPLETE,
                                GET_STRIP);
signal HBM_reader_fsm : HBM_reader_fsm_type;

signal hbm_reader_fsm_debug         : std_logic_vector(3 downto 0)  := x"0";
signal hbm_reader_fsm_debug_d       : std_logic_vector(3 downto 0)  := x"0";
signal hbm_reader_fsm_debug_cache   : std_logic_vector(3 downto 0)  := x"0";

-- 512 byte rds
signal meta_data_ptr        : unsigned(27 downto 0) := (others => '0');
signal meta_data_addr       : unsigned(27 downto 0) := (others => '0');
signal meta_data_cache      : unsigned(27 downto 0) := (others => '0');

signal vis_data_ptr         : unsigned(27 downto 0) := (others => '0');
signal vis_data_addr        : unsigned(27 downto 0) := (others => '0');
signal vis_data_cache       : unsigned(27 downto 0) := (others => '0');

signal vis_loop_cnt         : unsigned(7 downto 0) := (others => '0');

signal curr_data_addr       : unsigned(27 downto 0) := (others => '0');
signal addr_request         : std_logic_vector(31 downto 0) := (others => '0');

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

signal rows_process         : unsigned(8 downto 0);
signal rows_position        : unsigned(8 downto 0);
signal cells_required       : unsigned(7 downto 0);
signal cell_row_requests    : unsigned(7 downto 0);

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

signal data_stripe_count    : unsigned(7 downto 0) := x"00";
signal tile_get_tracker     : unsigned(4 downto 0) := "00000";
signal whole_tiles          : unsigned(7 downto 0) := x"00";
signal tiles_retrieved      : unsigned(7 downto 0) := x"00";

signal getting_tile         : std_logic;
signal get_meta_or_data     : std_logic;
signal meta_cells_working   : unsigned(7 downto 0) := x"00";


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
            meta_data_cache     <= (others => '0');
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
            row_cell_offset     <= DATA_CELL_OFFSET;
            next_cell_row       <= DATA_CELL_OFFSET(26 downto 0) & '0';
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

            -- i_row_start                 : in unsigned(12 downto 0);     -- The index of the first row that is available, counts from zero expect 0, 256, 512 etc.
            -- i_number_of_rows            : in unsigned(8 downto 0);      -- The number of rows available to be read out. Valid range is 1 to 256.

            case HBM_reader_fsm is
                when IDLE =>
                    hbm_reader_fsm_debug    <= x"0";
                    hbm_data_sel            <= '0';

                    getting_tile            <= '0';
                    tile_get_tracker        <= 5D"16";

                    if i_begin = '1' then
                        HBM_reader_fsm  <= GET_STRIP;
                        -- report back current HBM address in use.
                        o_HBM_curr_addr <= std_logic_vector(i_hbm_base_addr);
                    end if;
                    --hbm_rd_loop_cnt     <= x"0";
                    -- META data always stored in upper half of HBM segment.
                    meta_data_ptr       <= i_hbm_base_addr(31 downto 4); -- Start address of the meta data is at (i_hbm_base_addr/16 + 256 Mbytes)
                    vis_data_ptr        <= i_hbm_base_addr(27 downto 0);

                    -- Upper number of the vis to retrieve, logic starts at 1 and goal seeks to this.
                    rows_process        <= i_number_of_rows;
                    rows_position       <= (others => '0');
                    -- if less than 256 then not a whole tile is needed
                    -- if more then that is the number of whole tiles.
                    whole_tiles         <= "000" & i_row_start(12 downto 8);
                    tiles_retrieved     <= x"00";

                    data_returned_done  <= '0';

                    meta_cells          <= x"01";

                    -- if 0 meta, 1 vis data.
                    get_meta_or_data    <= '0';

                ---------------------------------------------------------------------------------------
                -- Work out what needs to be retrieved in terms of Tiles and Cells
                -- Look at Row
                -- generate META in lots of 16 rows, and DATA in lots of 16 rows or less if not modulo 16.
                -- meta is retreived in lots of 16 rows and the correct read out is handled in the sub module.
                -- data is more tricky, for reading across a tile, is reading across a cell which is 16x16
                -- 16 across by 32 bytes = 512, then add a cell offset of 8192 to get to the next 16 etc.

                -- META AND DATA ARE DIFFERENT RETREIVAL PATTERNS.
                -- META gets the whole 16x16
                -- DATA gets one line of 1x16
                -- DATA retreival of 257 base lines will be 1 Tile + 1 Cell or 17 Cells.
                -- Effectively the unit of retrieval for DATA is CELLS as the unwanted baselines 
                -- in the last CELL retrieved are discarded by follow on logic in the chain.

                -- Big loop
                -- 16 META
                -- Wait for DATA, flip the HBM write bit
                -- Upto 16 Data
                -- Wait for DATA, flip the HBM write bit
                -- Back to top.

                when GET_STRIP =>
                    hbm_reader_fsm_debug    <= x"1";

                    -- cells required to retrieve post Tile
                    cells_required      <= unsigned("000" & rows_process(8 downto 4)) + 1;


                    meta_data_addr      <= meta_data_ptr;
                    vis_data_addr       <= vis_data_ptr;

                    -- working registers for the 16 loop.
                    meta_to_get         <= x"00";
                    vis_loop_cnt        <= x"00";

                    HBM_reader_fsm      <= GEN_META_INSTRUCTION;
                    

                when GEN_META_INSTRUCTION =>
                    hbm_reader_fsm_debug    <= x"2";

                    if whole_tiles /= tiles_retrieved then
                        HBM_reader_fsm      <= META_GET_TILE;
                        getting_tile        <= '1';
                        tile_get_tracker    <= 5D"16";
                        -- 128MB of addr space as that is all that is available to Data or Vis
                        -- take a copy of current pointer to work along the row with.
                        
                    -- All tiles preceding the remaining cells acquired
                    -- get cells
                    else
                        HBM_reader_fsm      <= META_GET_CELL;
                        getting_tile        <= '0';
                    end if;

                    -- latest TILE ALIGNED Address.
                    meta_data_cache         <= meta_data_addr;

                when META_GET_TILE =>
                    hbm_reader_fsm_debug    <= x"3";

                    tile_get_tracker        <= tile_get_tracker - 1;

                    -- pass current pointer, and prepare next loop incr.
                    addr_request    <= "0001" & std_logic_vector(meta_data_cache);      -- <<< ADD 256MB here.
                    -- next addr is + 512 for met
                    meta_data_cache <= meta_data_cache + 512;
                    -- execute RD
                    HBM_reader_fsm  <= RD_META;

                    -- if we have generated 16->1 requests, then 0 won't be needed
                    -- update the pointer to start of next tile
                    -- incr tiles_retrieved
                    -- go back to make next instruction.
                    if tile_get_tracker = 0 then
                        meta_data_addr  <= meta_data_addr + META_TILE_OFFSET;
                        tiles_retrieved <= tiles_retrieved + 1;
                        HBM_reader_fsm  <= META_TILE_JUMP_ADDR;
                        getting_tile    <= '0';
                    end if;

                when META_TILE_JUMP_ADDR =>
                    hbm_reader_fsm_debug    <= x"4";

                    -- if ALL TILES retrieved, then update the pointer to the start of the next 16
                    -- This is 16 rows (1 Cell below the last transaction) 16 x 16 x 2 x 16 = 8192
                    if (whole_tiles = tiles_retrieved) then
                        meta_data_ptr   <= meta_data_ptr + x"2000";
                    end if;

                    HBM_reader_fsm  <= GEN_META_INSTRUCTION;                    

                when META_GET_CELL =>
                    hbm_reader_fsm_debug    <= x"5";

                    -- need to retrieve a subset of tile. 
                    -- 
                    -- META is stored as a triangle
                    -- so upto 16 rows = 1
                    -- upto 32 = 3
                    -- each subsequent address = +512
                    -- As we are only processing in lots of 16, get 16 at a time
                    -- first pass through will be 1, 2, 3, etc as triangle grows as we go down.

                    
                    -- execute RD, or Move onto DATA for this set of 16.
                    if meta_to_get = meta_cells then    -- escape!
                        -- incr as next loop will be +1
                        meta_cells <= meta_cells + 1;
                        HBM_reader_fsm  <= DATA_SEL;
                    else
                        meta_to_get <= meta_to_get + 1;
                        HBM_reader_fsm  <= RD_META;
                    end if;


                    addr_request    <= "0001" & std_logic_vector(meta_data_cache);
                    -- next addr is + 512 for met
                    meta_data_cache <= meta_data_cache + 512;



                ---------------------------------------------------------------------------------------

                when RD_META =>
                    hbm_reader_fsm_debug    <= x"6";
                    
                    hbm_axi_ar_addr         <= addr_request;
                    hbm_axi_ar_valid        <= '1';
                    HBM_reader_fsm          <= RD_META_AR;


                when RD_META_AR =>
                    hbm_reader_fsm_debug    <= x"7";
                    if hbm_axi_ar_rdy = '1' then
                        hbm_axi_ar_valid    <= '0';
                        HBM_reader_fsm      <= CHECK_META;
                    end if;

                when CHECK_META =>
                    hbm_reader_fsm_debug    <= x"8";
                    -- in TILE LOOP, return.
                    if getting_tile = '1' then
                        HBM_reader_fsm      <= META_GET_TILE;
                    else
                        HBM_reader_fsm      <= META_GET_CELL;
                    end if;
    
                ---------------------------------------------------------------------------------------
                ---------------------------------------------------------------------------------------
                -- META >> DATA >> META >> ..... 
                -- wait for all transaction to return then move to next retrieval and switch
                -- the write bits to relevant RAMs.
                when DATA_SEL =>
                    hbm_reader_fsm_debug    <= x"9";
                    --
                    tiles_retrieved         <= x"00";
                    --
                    if hbm_retrieval_trac = hbm_returned_trac then
                        hbm_data_sel        <= NOT hbm_data_sel;
                        get_meta_or_data    <= NOT get_meta_or_data;

                        if get_meta_or_data = '0' then
                            -- if META, we are going to DATA for that Strip of 16
                            HBM_reader_fsm      <= GEN_DATA_INSTRUCTION;
                            data_stripe_count   <= x"00";
                        else
                            -- if NOT, DATA must be done so time to look for next 16.
                            HBM_reader_fsm      <= GET_STRIP;
                        end if;
                    end if;

                ---------------------------------------------------------------------------------------
                ---------------------------------------------------------------------------------------
                -- Get visibilities
                when GEN_DATA_INSTRUCTION => 
                    hbm_reader_fsm_debug    <= x"A";

                    if rows_position = rows_process then
                        HBM_reader_fsm      <= COMPLETE;
                    elsif data_stripe_count = 16 then
                        HBM_reader_fsm      <= DATA_SEL;
                        -- update ptr to next stripe
                        vis_data_ptr        <= vis_data_ptr + DATA_TILE_STRIPE_OFFSET;
                    else

                        if whole_tiles /= tiles_retrieved then
                            HBM_reader_fsm      <= DATA_GET_TILE;
                            getting_tile        <= '1';
                            tile_get_tracker    <= 5D"16";
                            -- 128MB of addr space as that is all that is available to Data or Vis
                            -- take a copy of current pointer to work along the row with.
                            
                            -- latest TILE ALIGNED Address.
                            vis_data_cache      <= vis_data_addr;

                        else
                            HBM_reader_fsm      <= DATA_GET_CELL;
                            getting_tile        <= '0';
                            rows_position       <= rows_position + 1;
                            cells_required      <= unsigned("000" & rows_position(8 downto 4)) + 1;
                            cell_row_requests   <= x"00";
                        end if;



                    end if;

                when DATA_GET_TILE =>
                    hbm_reader_fsm_debug    <= x"B";

                    tile_get_tracker        <= tile_get_tracker - 1;

                    -- pass current pointer, and prepare next loop incr.
                    addr_request    <= "0000" & std_logic_vector(vis_data_cache); 
                    -- next addr is + 8192 for data row in next CELL.
                    vis_data_cache  <= vis_data_cache + 8192;
                    -- execute RD
                    HBM_reader_fsm  <= RD_DATA;

                    -- if we have generated 16->1 requests, then 0 won't be needed
                    -- update the pointer to start of next tile
                    -- incr tiles_retrieved
                    -- go back to make next instruction.
                    if tile_get_tracker = 0 then
                        vis_data_addr   <= vis_data_addr + DATA_TILE_OFFSET;
                        tiles_retrieved <= tiles_retrieved + 1;
                        HBM_reader_fsm  <= GEN_DATA_INSTRUCTION;
                        getting_tile    <= '0';
                    end if;
                

                when DATA_GET_CELL =>
                    hbm_reader_fsm_debug    <= x"D";
                    -- need to retrieve a subset of tile.(stripe)
                    -- 
                    -- First pass thru will be 16 rows 1 cell   (512)
                    -- 2nd pass thru will be 16 rows 2 cells    (512 + 8192)
                    -- etc
                    
                    -- execute RDs required for line based on cells.
                    if cells_required = cell_row_requests then    -- escape!
                        HBM_reader_fsm      <= GEN_DATA_INSTRUCTION;
                    else
                        cell_row_requests   <= cell_row_requests + 1;
                        HBM_reader_fsm      <= RD_DATA;
                    end if;


                    addr_request    <= "0000" & std_logic_vector(vis_data_cache);
                    -- next addr is + 512 for met
                    vis_data_cache  <= vis_data_cache + 512;


                ---------------------------------------------------------------------------------------
                -- VIS FSM SECTION

                when RD_DATA =>
                    hbm_reader_fsm_debug    <= x"9";
                    
                    if (enable_hbm_read_del = '1') then
                        hbm_axi_ar_addr         <= addr_request;
                        hbm_axi_ar_valid        <= '1';

                        HBM_reader_fsm          <= RD_DATA_AR;
                    end if;

                when RD_DATA_AR =>
                    hbm_reader_fsm_debug    <= x"A";
                    if hbm_axi_ar_rdy = '1' then
                        hbm_axi_ar_valid    <= '0';

                        HBM_reader_fsm      <= CHECK_DATA;
                    end if;

                when CHECK_DATA =>
                    -- in TILE LOOP, return.
                    if getting_tile = '1' then
                        HBM_reader_fsm      <= DATA_GET_TILE;
                    else
                        HBM_reader_fsm      <= DATA_GET_CELL;
                    end if;

                ---------------------------------------------------------------------------------------
                ---------------------------------------------------------------------------------------

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
-- DATA and META Cache.

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