----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: 02/02/2023 04:22:23 PM
-- Design Name: 
-- Module Name: correlator_data_reader - Behavioral
--  
-- Description: 
-- 
-- Read from HBM, de-triangle the data structure and provide data to SPEAD packet logic creator.
-- 
-- Flow of the file
--      FIFO Cache input instructions
--      SM handling the instruction
--      HBM queue manager
--          SM handling the HBM reads and buffer levels
--          FIFO catching Vis Data
--          FIFO catching Meta Data
--      SM handling the reading of Vis and Meta Caches and packing this data
--      68 Byte into 64 Byte gearboxing to pack Vis+Meta data into 512w vector.
--      FIFO packed data for packetiser.
-- 
-- Notes on HBM layout + Cor config
--
-- if i_row = 0 and i_row_count = 9, then the number of columns read out is 1, then 2, ... up to 9 for the last row.
-- you are assuming I read out 9 rows so it takes on the shape of a triangle.
--
-- Or is i_row = 256, i_row_count = 20, then the number of columns read out is 256, 257, ... up to 276
-- i_row will always be a multiple of 256, since that is the size of the strip of the matrix that the readout gets notified on.
--
-- One valid signal for all the signals. i_data_valid indicates the location in HBM of the start of a new strip from the correlations, 
-- the starting row of the strip and the number of valid rows.
-- 
-- index into the subarry table ( 0 based) and frequency offset (also zero based)
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
use spead_lib.ethernet_pkg.ALL;
use spead_lib.hbm_read_hbm_rd_debug_reg_pkg.ALL;

entity correlator_data_reader is
    Generic ( 
        DEBUG_ILA           : BOOLEAN := FALSE;
        HBM_META_DEPTH      : INTEGER := 16;
        HBM_DATA_DEPTH      : INTEGER := 128

    );
    Port ( 
        -- clock used for all data input and output from this module (300 MHz)
        i_axi_clk           : in std_logic;
        i_axi_rst           : in std_logic;

        i_local_reset       : in std_logic;

        -- debug
        i_spead_hbm_rd_lite_axi_mosi : in t_axi4_lite_mosi; 
        o_spead_hbm_rd_lite_axi_miso : out t_axi4_lite_miso;

        -- config of current sub/freq data read
        i_hbm_start_addr    : in std_logic_vector(31 downto 0);     -- Byte address in HBM of the start of a strip from the visibility matrix.
                                                                    -- Start address of the meta data is at (i_HBM_start_addr/16 + 256 Mbytes)
        i_sub_array         : in std_logic_vector(7 downto 0);      -- max of 16 zooms x 8 sub arrays = 128
        i_freq_index        : in std_logic_vector(16 downto 0);
        i_data_valid        : in std_logic;
        i_time_ref          : in std_logic_vector(63 downto 0);     -- Some kind of timestamp. Will be the same for all subarrays within a single 849 ms
                                                                    -- integration time.
        i_row               : in std_logic_vector(12 downto 0);     -- The index of the first row that is available, counts from zero.
        i_row_count         : in std_logic_vector(8 downto 0);      -- The number of rows available to be read out. Valid range is 1 to 256.

        o_HBM_curr_addr     : out std_logic_vector(31 downto 0);     -- current start HBM address being processed, feedback bus for correlator logic.

        -- HBM read interface
        o_HBM_axi_ar        : out t_axi4_full_addr;                 -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_arready   : in  std_logic;
        i_HBM_axi_r         : in  t_axi4_full_data;                 -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_rready    : out std_logic;
        
        -- Packed up Correlator Data + debug
        o_fsm_debugs        : out t_slv_4_arr(2 downto 0);
        o_spead_data        : out std_logic_vector(511 downto 0);
        i_spead_data_rd     : in std_logic;                         -- FWFT FIFO
        o_current_array     : out std_logic_vector(7 downto 0);     -- max of 16 zooms x 8 sub arrays = 128, zero-based.
        o_spead_data_rdy    : out std_logic;
        o_byte_count        : out std_logic_vector(13 downto 0);
        i_enabled_array     : in std_logic_vector(7 downto 0);      -- max of 16 zooms x 8 sub arrays = 128, zero-based.
        o_freq_index        : out std_logic_vector(16 downto 0);
        o_time_ref          : out std_logic_vector(63 downto 0)

    );
end correlator_data_reader;

architecture Behavioral of correlator_data_reader is

signal clk                      : std_logic;
signal reset                    : std_logic;

-- metadata from correlator.
constant meta_cache_width       : INTEGER := 32 + 8 + 17 + 64 + 13 + 9;
constant meta_cache_depth       : INTEGER := 64;    -- choosen at random, hopefully not 64 aub arrays waiting to be read.

signal meta_cache_fifo_in_reset : std_logic;
signal meta_cache_fifo_rd       : std_logic;
signal meta_cache_fifo_q        : std_logic_vector((meta_cache_width-1) downto 0);
signal meta_cache_fifo_q_valid  : std_logic;
signal meta_cache_fifo_empty    : std_logic;
signal meta_cache_fifo_rd_count : std_logic_vector(((ceil_log2(meta_cache_depth))) downto 0);
-- WR        
signal meta_cache_fifo_wr       : std_logic;
signal meta_cache_fifo_data     : std_logic_vector((meta_cache_width-1) downto 0);
signal meta_cache_fifo_full     : std_logic;
signal meta_cache_fifo_wr_count : std_logic_vector(((ceil_log2(meta_cache_depth))) downto 0);


constant hbm_data_width       : INTEGER := 512;
-- VIS data from correlator.
signal hbm_data_fifo_rd       : std_logic;
signal hbm_data_fifo_q        : std_logic_vector((hbm_data_width-1) downto 0);
signal hbm_data_fifo_empty    : std_logic;
signal hbm_data_fifo_rd_count : std_logic_vector(((ceil_log2(hbm_data_depth))) downto 0);

-- META data from correlator.
constant META_FIFO_WRITE_WIDTH : integer := 512;
constant META_FIFO_READ_WIDTH  : integer := 32;
constant META_FIFO_WRITE_DEPTH : integer := 32;
constant META_FIFO_READ_DEPTH  : integer := META_FIFO_WRITE_DEPTH * META_FIFO_WRITE_WIDTH / META_FIFO_READ_WIDTH;

signal hbm_meta_fifo_rd       : std_logic;
signal hbm_meta_fifo_q        : std_logic_vector((META_FIFO_READ_WIDTH-1) downto 0);
signal hbm_meta_fifo_empty    : std_logic;
signal hbm_meta_fifo_rd_count : std_logic_vector(((ceil_log2(META_FIFO_READ_DEPTH))) downto 0);

--------------------------------------------------------------------------------
-- Packed data to SPEAD packets
constant packed_width       : INTEGER := 512;   -- 34 bytes = 32 data + 2 meta.
constant packed_depth       : INTEGER := 512;    -- choosen at random, hopefully not 64 aub arrays waiting to be read.

signal packed_fifo_in_reset : std_logic;
signal packed_fifo_rd       : std_logic;
signal packed_fifo_q        : std_logic_vector((packed_width-1) downto 0);
signal packed_fifo_q_valid  : std_logic;
signal packed_fifo_empty    : std_logic;
signal packed_fifo_rd_count : std_logic_vector(((ceil_log2(packed_depth))) downto 0);
-- WR        
signal packed_fifo_wr       : std_logic;
signal packed_fifo_data     : std_logic_vector(271 downto 0);
signal packed_fifo_full     : std_logic;
signal packed_fifo_wr_count : std_logic_vector(((ceil_log2(packed_depth))) downto 0);

signal packed_fifo_data_d1  : std_logic_vector(271 downto 0);
signal packed_fifo_data_d2  : std_logic_vector(271 downto 0);
signal packed_fifo_data_d3  : std_logic_vector(271 downto 0);

signal bytes_to_packetise   : unsigned(13 downto 0) := (others => '0');
signal bytes_to_process     : unsigned(13 downto 0) := (others => '0');

signal send_spead_data      : std_logic_vector(1 downto 0) := "00";

signal pack_counter         : unsigned(5 downto 0);
signal pack_counter_d       : unsigned(5 downto 0);
signal pack_wr              : std_logic;

signal aligned_packed_fifo_data     : std_logic_vector(511 downto 0);
signal aligned_packed_fifo_data_d   : std_logic_vector(511 downto 0);

signal aligned_packed_wr_d          : std_logic;
signal aligned_packed_wr            : std_logic;
signal trigger_final_write          : std_logic;

signal packed_wr_enable             : std_logic_vector(1 downto 0) := "00";

--------------------------------------------------------------------------------
-- triangle signals
type cor_triangle_fsm_type is   (idle, check_enable, calculate_reads, 
                                complete, pop_instruction, cleanup);
signal cor_triangle_fsm : cor_triangle_fsm_type;

signal last_instruct_subarray   : std_logic_vector(7 downto 0);
signal cor_tri_time_ref         : std_logic_vector(63 downto 0);
signal cor_tri_hbm_start_addr   : std_logic_vector(31 downto 0);
signal cor_tri_sub_array        : std_logic_vector(7 downto 0);
signal cor_tri_freq_index       : std_logic_vector(16 downto 0);
signal cor_tri_row              : unsigned(12 downto 0);
signal cor_tri_row_count        : unsigned(8 downto 0);

signal cor_read_data            : unsigned(16 downto 0);
signal cor_read_meta            : unsigned(16 downto 0);

signal hbm_rq_complete          : std_logic;

--------------------------------------------------------------------------------
-- sm debug
signal pack_it_fsm_debug            : std_logic_vector(3 downto 0)  := x"0";
signal cor_tri_fsm_debug            : std_logic_vector(3 downto 0)  := x"0";

signal hbm_reader_fsm_debug         : std_logic_vector(3 downto 0);
signal hbm_reader_fsm_debug_cache   : std_logic_vector(3 downto 0);

signal debug_instruction_writes : unsigned(31 downto 0)         := (others => '0');

signal hbm_rd_debug_ro          : t_hbm_rd_debug_ro;
--------------------------------------------------------------------------------
-- Pack SM signals
type pack_it_fsm_type is   (IDLE, LOOPS, CALC, MATH, PROCESSING, RD_DRAIN, COMPLETE);
signal pack_it_fsm : pack_it_fsm_type;

signal meta_data_cache          : std_logic_vector(15 downto 0);
signal hbm_data_cache           : std_logic_vector(255 downto 0);
signal hbm_data_cache_le        : std_logic_vector(255 downto 0);

signal packed                   : std_logic_vector(255 downto 0);
signal pack_count               : unsigned(7 downto 0) := (others => '0');

signal meta_data_rd             : unsigned(3 downto 0) := (others => '0');

signal data_rd_counter          : unsigned(12 downto 0) := (others => '0');
signal data_wr_counter          : unsigned(12 downto 0) := (others => '0');

signal strut_counter            : integer := 0;

signal hbm_data_cache_sel       : std_logic;
signal hbm_data_rd_en           : std_logic;
signal pack_start               : std_logic;
signal hbm_start                : std_logic;

signal row_count_rd_out         : unsigned(12 downto 0);
signal small_matrix_tracker     : unsigned(3 downto 0);
signal matrix_tracker           : unsigned(9 downto 0);

signal reset_cache_fifos        : std_logic;
signal cache_fifos_in_reset     : std_logic;

TYPE segments_hbm_triangle IS ARRAY (INTEGER RANGE <>) OF UNSIGNED(3 DOWNTO 0);
TYPE data_hbm_triangle IS ARRAY (INTEGER RANGE <>) OF UNSIGNED(7 DOWNTO 0);
constant write_per_line         : segments_hbm_triangle(0 to 15)    := (x"0",x"1",x"2",x"3",x"4",x"5",x"6",x"7",x"8",x"9",x"A",x"B",x"C",x"D",x"E",x"F");
constant read_skip_per_line     : segments_hbm_triangle(0 to 15)    := (x"7",x"7",x"6",x"6",x"5",x"5",x"4",x"4",x"3",x"3",x"2",x"2",x"1",x"1",x"0",x"0");
constant read_keep_per_line     : segments_hbm_triangle(0 to 15)    := (x"0",x"0",x"1",x"1",x"2",x"2",x"3",x"3",x"4",x"4",x"5",x"5",x"6",x"6",x"7",x"7");


--------------------------------------------------------------------------------
begin
    
    clk                     <= i_axi_clk;
    reset                   <= i_axi_rst OR i_local_reset;

    o_current_array         <= cor_tri_sub_array;
    o_freq_index            <= cor_tri_freq_index;
    o_time_ref              <= cor_tri_time_ref;

    o_fsm_debugs(0)         <= pack_it_fsm_debug;
    o_fsm_debugs(1)         <= cor_tri_fsm_debug;
    o_fsm_debugs(2)         <= hbm_reader_fsm_debug;
    ---------------------------------------------------------------------------
    meta_reg_proc : process(clk)
    begin
        if rising_edge(clk) then
            meta_cache_fifo_wr      <= i_data_valid;

            meta_cache_fifo_data    <=  i_row_count &           -- std_logic_vector(8 downto 0)
                                        i_row(12 downto 0) &    -- std_logic_vector(12 downto 0), always a multiple of 256.
                                        i_freq_index &          -- std_logic_vector(16 downto 0)
                                        i_sub_array &           -- std_logic_vector(7 downto 0)
                                        i_hbm_start_addr &      -- std_logic_vector(31 downto 0)
                                        i_time_ref;             -- std_logic_vector(63 downto 0)              
        end if;
    end process;
    ---------------------------------------------------------------------------
    -- cache incoming sub array information in FIFO.
    meta_cache : entity signal_processing_common.xpm_sync_fifo_wrapper
    Generic map (
        FIFO_MEMORY_TYPE    => "block",
        READ_MODE           => "fwft",
        FIFO_DEPTH          => meta_cache_depth,
        DATA_WIDTH          => meta_cache_width
    )
    Port map ( 
        fifo_reset          => reset,
        fifo_clk            => clk,
        fifo_in_reset       => meta_cache_fifo_in_reset,
        -- RD    
        fifo_rd             => meta_cache_fifo_rd,
        fifo_q              => meta_cache_fifo_q,
        fifo_q_valid        => meta_cache_fifo_q_valid,
        fifo_empty          => meta_cache_fifo_empty,
        fifo_rd_count       => meta_cache_fifo_rd_count,
        -- WR        
        fifo_wr             => meta_cache_fifo_wr,
        fifo_data           => meta_cache_fifo_data,
        fifo_full           => meta_cache_fifo_full,
        fifo_wr_count       => meta_cache_fifo_wr_count
    );
    ---------------------------------------------------------------------------
    -- SM to process correlated data.
    SM_data_config_proc : process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                cor_tri_fsm_debug   <= x"F";
                cor_triangle_fsm    <= idle;
                meta_cache_fifo_rd  <= '0';
                pack_start          <= '0';
                hbm_start           <= '0';
                cor_tri_row         <= ( others => '0' );
                cor_tri_row_count   <= ( others => '0' );
            else
                case cor_triangle_fsm is
                    when idle => 
                        cor_tri_fsm_debug       <= x"0";
                        meta_cache_fifo_rd      <= '0';
                        cor_read_data           <= ( others => '0' );
                        cor_read_meta           <= ( others => '0' );
                        pack_start              <= '0';

                        if meta_cache_fifo_empty = '0' then
                            cor_triangle_fsm        <= check_enable;
                            cor_tri_time_ref        <= meta_cache_fifo_q(63 downto 0);
                            cor_tri_hbm_start_addr  <= meta_cache_fifo_q(95 downto 64);
                            cor_tri_sub_array       <= meta_cache_fifo_q(103 downto 96);
                            cor_tri_freq_index      <= meta_cache_fifo_q(120 downto 104);
                            cor_tri_row             <= unsigned(meta_cache_fifo_q(133 downto 121));
                            cor_tri_row_count       <= unsigned(meta_cache_fifo_q(142 downto 134));
                        end if;

                    when check_enable =>
                        cor_tri_fsm_debug   <= x"1";
                        -- TODO !!!!!!!
                        -- code for RAM lookup for sub array enable.
                        -- skip if not enabled, after checking if the last pass through was for different sub array.
                        -- pass through initially.
                        cor_triangle_fsm        <= calculate_reads;

                    when calculate_reads => 
                        cor_tri_fsm_debug   <= x"2";
                        -- cor_tri_row_count is indicating where the edge of the triangle is, ie how many rows,
                        -- 512 bytes per row. 64 bytes per read on the interface so 8 per line.
                        -- so row_count needs to << 3.
                        -- for 16 rows 8 rds per row = 16 x 8 = 128 (64 Byte) rds per square.
                        -- for a 4096 cor, rds will be 256 squares  * 128 rds = 32768
                        -- cor_tri_row is effectively a multiplier.
                        -- max requests = 4096 col x 32 bytes x 16 rows = 2 MB (last section of a 4096x4096 correlation)
                        cor_read_data <= cor_read_data + (cor_tri_row_count & "000");

                        -- meta data is packed, 64 bytes = 32 correlations.
                        -- 8 reads per 512 bytes (as a HBM min). Therefore 1 read = 256 lots of meta data.

                        if cor_tri_row = 0 then
                            cor_triangle_fsm    <= complete;
                            hbm_start           <= '1';
                        else
                            cor_tri_row         <= cor_tri_row - 1;
                        end if;
                                           
                    when complete => 
                        cor_tri_fsm_debug       <= x"3";
                        hbm_start               <= '0';
                        cor_tri_row             <= unsigned(meta_cache_fifo_q(133 downto 121));
                        pack_start              <= '1';


                        cor_triangle_fsm        <= pop_instruction;
                    
                    
                    when pop_instruction => 
                        cor_tri_fsm_debug       <= x"4";
                        last_instruct_subarray  <= cor_tri_sub_array;

                        if pack_it_fsm = COMPLETE then
                            cor_triangle_fsm        <= cleanup;
                            meta_cache_fifo_rd      <= '1';
                        end if;

                    when cleanup => 
                        cor_tri_fsm_debug       <= x"5";
                        -- not ready until all data passed off to the packetiser.
                        if packed_fifo_empty = '1' then
                            meta_cache_fifo_rd      <= '0';
                            cor_triangle_fsm        <= idle;
                        end if;

                    WHEN OTHERS => 
                        cor_triangle_fsm        <= idle;

                end case;
            end if;

        end if;
    end process;


    ---------------------------------------------------------------------------
    RD_manager : entity correlator_lib.cor_rd_HBM_queue_manager generic map ( 
            DEBUG_ILA               => FALSE,

            META_FIFO_WRITE_WIDTH   => META_FIFO_WRITE_WIDTH,
            META_FIFO_READ_WIDTH    => META_FIFO_READ_WIDTH,
            META_FIFO_WRITE_DEPTH   => META_FIFO_WRITE_DEPTH,
            META_FIFO_READ_DEPTH    => META_FIFO_READ_DEPTH,

            HBM_DATA_DEPTH          => 128,
            HBM_DATA_WIDTH          => 512
        )
        port map ( 
            -- clock used for all data input and output from this module (300 MHz)
            clk                         => clk,
            reset                       => reset,
    
            i_fifo_reset                => reset_cache_fifos,
            o_fifo_in_rst               => cache_fifos_in_reset,
    
            -- HBM config
            i_begin                     => hbm_start,
            i_hbm_base_addr             => unsigned(cor_tri_hbm_start_addr),
            i_number_of_64b_rds         => cor_read_data,
            o_done                      => hbm_rq_complete,

            -- Visibility Data FIFO RD interface
            i_hbm_data_fifo_rd          => hbm_data_fifo_rd,
            o_hbm_data_fifo_q           => hbm_data_fifo_q,
            o_hbm_data_fifo_empty       => hbm_data_fifo_empty,
            o_hbm_data_fifo_rd_count    => hbm_data_fifo_rd_count,
    
            -- Meta Data FIFO RD interface
            i_hbm_meta_fifo_rd          => hbm_data_fifo_rd,    -- SAME cadence used due to same data width ratios.
            o_hbm_meta_fifo_q           => hbm_meta_fifo_q, 
            o_hbm_meta_fifo_empty       => hbm_meta_fifo_empty,
            o_hbm_meta_fifo_rd_count    => hbm_meta_fifo_rd_count,
    
            -- feedback to pass to Correlator
            o_HBM_curr_addr             => o_HBM_curr_addr,
    
            -- debug
            o_hbm_reader_fsm_debug          => hbm_reader_fsm_debug,
            o_hbm_reader_fsm_debug_cache    => hbm_reader_fsm_debug_cache,

            -- HBM read interface
            o_HBM_axi_ar                => o_HBM_axi_ar,
            i_HBM_axi_arready           => i_HBM_axi_arready,
            i_HBM_axi_r                 => i_HBM_axi_r,
            o_HBM_axi_rready            => o_HBM_axi_rready
    
        );


    ---------------------------------------------------------------------------
    -- Visibility (32 byte) + Meta data (2 byte) packed into 34 byte wide FIFO.
    -- Converting the triangle layout in HBM into Vis + Meta to be packed later into SPEAD.
    -- This does all the work of converting the TILE and CELL layout into a stream.
    -- The dimensions of the correlation are divided up into 16x16.
    -- 16x16
    -- 16x16, 16x16
    -- 16x16, 16x16, 16x16
    -- ....
    -- down to 256
    --
    -- Configs are passed in on a 256x256 basis (CELL)
    -- all writes are 256 aligned, gate the writing based on row and row_count
    -- i_row               : in std_logic_vector(12 downto 0);     -- The index of the first row that is available, counts from zero.
    -- i_row_count         : in std_logic_vector(8 downto 0);      -- The number of rows available to be read out. Valid range is 1 to 256.

    pack_process : process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                pack_it_fsm_debug   <= x"F";
                pack_it_fsm         <= IDLE;
                packed_fifo_wr      <= '0';
                meta_data_rd        <= x"F";
                hbm_data_cache_sel  <= '0';
                hbm_data_fifo_rd    <= '0';
                data_rd_counter     <= ( others => '0' );
                data_wr_counter     <= ( others => '0' );
                row_count_rd_out    <= ( others => '0' );
                hbm_data_cache      <= ( others => '0' );
                meta_data_cache     <= ( others => '0' );
                hbm_data_rd_en      <= '0';
                reset_cache_fifos   <= '0';
            else

                case pack_it_fsm is
                    when IDLE =>
                        pack_it_fsm_debug   <= x"0";
                        --if pack_start = '1' and hbm_meta_fifo_empty = '0' and hbm_data_fifo_empty = '0' then
                        if pack_start = '1' and hbm_data_fifo_empty = '0' then
                            pack_it_fsm         <= LOOPS;
                            row_count_rd_out    <= cor_tri_row_count + cor_tri_row;
                        end if;
                        packed_fifo_wr      <= '0';
                        strut_counter       <= 0;
                        hbm_data_cache_sel  <= '0';
                        small_matrix_tracker<= x"0";
                        matrix_tracker      <= cor_tri_row(12 downto 3); --(others => '0');
                        hbm_data_rd_en      <= '0';

                    when LOOPS =>
                        pack_it_fsm_debug   <= x"1";
                        if unsigned(hbm_data_fifo_rd_count) > 120 then
                            -- chop up the cell into 16 row lots.
                            -- if less then process remaining and set exit condition of 0.
                            if row_count_rd_out(8 downto 0) > 16 then
                                small_matrix_tracker            <= x"F";
                                row_count_rd_out(12 downto 8)   <= "00000";
                                row_count_rd_out(7 downto 0)    <= row_count_rd_out(7 downto 0) - 16;
                            else
                                if row_count_rd_out(3 downto 0) = x"0" then
                                    small_matrix_tracker        <= x"0";
                                else
                                    small_matrix_tracker        <= row_count_rd_out(3 downto 0) - 1;
                                end if;
                                row_count_rd_out                <= (others => '0');
                            end if;

                            pack_it_fsm                 <= CALC;
                        end if;

                    when CALC =>
                        pack_it_fsm_debug   <= x"2";
                        if unsigned(packed_fifo_wr_count) < 256 then
                            -- Mux into vector the starting row number and add to end the number of reads for the triangle on 16x16 basis.
                            data_rd_counter(12 downto 0)    <= matrix_tracker(9 downto 0) & read_keep_per_line(strut_counter)(2 downto 0);
                            data_wr_counter(12 downto 0)    <= matrix_tracker(8 downto 0) & write_per_line(strut_counter)(3 downto 0);
                            hbm_data_rd_en      <= '1';

                            pack_it_fsm         <= PROCESSING;
                        end if;

                    -- READING data to be packed along a ROW.
                    when PROCESSING =>
                        pack_it_fsm_debug   <= x"3";
                        packed_fifo_wr      <= '1';
                        
                        hbm_data_cache_sel  <= NOT hbm_data_cache_sel;
                        if hbm_data_cache_sel = '0' then
                            hbm_data_cache      <= hbm_data_fifo_q(255 downto 0);
                            meta_data_cache     <= hbm_meta_fifo_q(15 downto 0);
                        else
                            hbm_data_cache      <= hbm_data_fifo_q(511 downto 256);
                            meta_data_cache     <= hbm_meta_fifo_q(31 downto 16);
                        end if;

                        hbm_data_fifo_rd    <= hbm_data_rd_en and (NOT hbm_data_cache_sel);

                        if hbm_data_fifo_rd = '1' then
                            if data_rd_counter = 0 then
                                hbm_data_rd_en  <= '0';
                            else
                                data_rd_counter <= data_rd_counter - 1;   
                            end if;
                        end if;

                        -- Update tracking counters based on wr signal.
                        if packed_fifo_wr = '1' then
                            if data_wr_counter = 0 then
                                pack_it_fsm         <= RD_DRAIN;
                                packed_fifo_wr      <= '0';
                                data_rd_counter     <= '0' & x"00" & read_skip_per_line(strut_counter);
                            else
                                
                                data_wr_counter     <= data_wr_counter - 1;
                            end if;
                        end if;
                        
                    -- DRAIN the remaining elements in the last 512 bytes of the row that are not used.
                    when RD_DRAIN =>
                        pack_it_fsm_debug   <= x"4";
                        packed_fifo_wr      <= '0';
                        hbm_data_cache_sel  <= '0';
                        if data_rd_counter = 0 then
                            if strut_counter = small_matrix_tracker then
                                strut_counter       <= 0;
                                if row_count_rd_out(7 downto 0) = 0 then
                                    pack_it_fsm         <= COMPLETE;
                                    reset_cache_fifos   <= '1';
                                else
                                    pack_it_fsm         <= LOOPS;
                                    matrix_tracker      <= matrix_tracker + 1;
                                end if;
                            else
                                strut_counter       <= strut_counter + 1;
                                pack_it_fsm         <= CALC;
                                data_rd_counter     <= (others => '0');
                            end if;
                            hbm_data_fifo_rd    <= '0';
                        else
                            data_rd_counter     <= data_rd_counter - 1;
                            hbm_data_fifo_rd    <= '1';
                        end if;
                        
                    when COMPLETE =>
                        pack_it_fsm_debug   <= x"5";
                        reset_cache_fifos   <= '0';
                        
                        if (cache_fifos_in_reset = '0') AND (reset_cache_fifos = '0') then
                            pack_it_fsm         <= IDLE;
                        end if;

                    when OTHERS =>
                        pack_it_fsm         <= IDLE;

                end case;

            end if;
        end if;
    end process;

    --packed_fifo_data    <= hbm_data_cache & meta_data_cache;
    packed_fifo_data    <= hbm_data_cache_le & meta_data_cache;
---------------------------------------------------------------------------
-- LE swapping of the vis_data
-- data is lots of single precision floats, bring lowest 32 bits to the top and then LE swap that.
-- repeat across the 256 bits.

hbm_data_cache_le   <=  hbm_data_cache(7 downto 0) &        hbm_data_cache(15 downto 8) &       hbm_data_cache(23 downto 16) &      hbm_data_cache(31 downto 24) & 
                        hbm_data_cache(39 downto 32) &      hbm_data_cache(47 downto 40) &      hbm_data_cache(55 downto 48) &      hbm_data_cache(63 downto 56) & 
                        hbm_data_cache(71 downto 64) &      hbm_data_cache(79 downto 72) &      hbm_data_cache(87 downto 80) &      hbm_data_cache(95 downto 88) & 
                        hbm_data_cache(103 downto 96) &     hbm_data_cache(111 downto 104) &    hbm_data_cache(119 downto 112) &    hbm_data_cache(127 downto 120) & 
                        hbm_data_cache(135 downto 128) &    hbm_data_cache(143 downto 136) &    hbm_data_cache(151 downto 144) &    hbm_data_cache(159 downto 152) & 
                        hbm_data_cache(167 downto 160) &    hbm_data_cache(175 downto 168) &    hbm_data_cache(183 downto 176) &    hbm_data_cache(191 downto 184) & 
                        hbm_data_cache(199 downto 192) &    hbm_data_cache(207 downto 200) &    hbm_data_cache(215 downto 208) &    hbm_data_cache(223 downto 216) & 
                        hbm_data_cache(231 downto 224) &    hbm_data_cache(239 downto 232) &    hbm_data_cache(247 downto 240) &    hbm_data_cache(255 downto 248); 

---------------------------------------------------------------------------
-- align the data to 64bytes, from 2 x 34 bytes

align_64b_proc : process(clk)
begin
    if rising_edge(clk) then
        if cor_triangle_fsm = idle OR reset = '1' then
            pack_counter                <= (others => '0');
            pack_counter_d              <= (others => '0');
            packed_fifo_data_d1         <= (others => '0');
            packed_fifo_data_d2         <= (others => '0');
            packed_fifo_data_d3         <= (others => '0');
            aligned_packed_fifo_data_d  <= (others => '0');
            packed_wr_enable            <= "00";
            trigger_final_write         <= '0';
            aligned_packed_wr_d         <= '0';
        else
            if packed_fifo_wr = '1' then
                packed_fifo_data_d1     <= packed_fifo_data;
                packed_fifo_data_d2     <= packed_fifo_data_d1;
                packed_fifo_data_d3     <= packed_fifo_data_d2;
                pack_counter            <= pack_counter + 1;

                packed_wr_enable(0)     <= '1';
                packed_wr_enable(1)     <= packed_wr_enable(0);
            elsif reset_cache_fifos = '1' then
                pack_counter            <= pack_counter + 2;
                packed_fifo_data_d1     <= (others => '0');
                packed_fifo_data_d2     <= packed_fifo_data;
                packed_fifo_data_d3     <= packed_fifo_data_d1;
                trigger_final_write     <= '1';
            else
                trigger_final_write     <= '0';
            end if;

            pack_counter_d              <= pack_counter;

            aligned_packed_wr_d         <= aligned_packed_wr AND packed_wr_enable(1);
            aligned_packed_fifo_data_d  <= aligned_packed_fifo_data;
        end if;
    end if;
end process;

pack_wr     <= '1' when pack_counter_d /= pack_counter else '0';


aligned_packed_fifo_data    <=                                        packed_fifo_data_d2                   &   packed_fifo_data_d1(271 downto 32)  when pack_counter = 2 else
                                packed_fifo_data_d3(31 downto 0)    & packed_fifo_data_d2                   &   packed_fifo_data_d1(271 downto 64)  when pack_counter = 4 else
                                packed_fifo_data_d3(63 downto 0)    & packed_fifo_data_d2                   &   packed_fifo_data_d1(271 downto 96)  when pack_counter = 6 else
                                packed_fifo_data_d3(95 downto 0)    & packed_fifo_data_d2                   &   packed_fifo_data_d1(271 downto 128) when pack_counter = 8 else
                                packed_fifo_data_d3(127 downto 0)   & packed_fifo_data_d2                   &   packed_fifo_data_d1(271 downto 160) when pack_counter = 10 else
                                packed_fifo_data_d3(159 downto 0)   & packed_fifo_data_d2                   &   packed_fifo_data_d1(271 downto 192) when pack_counter = 12 else
                                packed_fifo_data_d3(191 downto 0)   & packed_fifo_data_d2                   &   packed_fifo_data_d1(271 downto 224) when pack_counter = 14 else
                                packed_fifo_data_d3(223 downto 0)   & packed_fifo_data_d2                   &   packed_fifo_data_d1(271 downto 256) when pack_counter = 16 else
                                packed_fifo_data_d3(255 downto 0)   & packed_fifo_data_d2(271 downto 16)                                            when pack_counter = 18 else

                                packed_fifo_data_d3(15 downto 0)    & packed_fifo_data_d2                   &   packed_fifo_data_d1(271 downto 48)  when pack_counter = 19 else

                                packed_fifo_data_d3(47 downto 0)    & packed_fifo_data_d2                   &   packed_fifo_data_d1(271 downto 80)  when pack_counter = 21 else
                                packed_fifo_data_d3(79 downto 0)    & packed_fifo_data_d2                   &   packed_fifo_data_d1(271 downto 112) when pack_counter = 23 else
                                packed_fifo_data_d3(111 downto 0)   & packed_fifo_data_d2                   &   packed_fifo_data_d1(271 downto 144) when pack_counter = 25 else
                                packed_fifo_data_d3(143 downto 0)   & packed_fifo_data_d2                   &   packed_fifo_data_d1(271 downto 176) when pack_counter = 27 else
                                packed_fifo_data_d3(175 downto 0)   & packed_fifo_data_d2                   &   packed_fifo_data_d1(271 downto 208) when pack_counter = 29 else
                                packed_fifo_data_d3(207 downto 0)   & packed_fifo_data_d2                   &   packed_fifo_data_d1(271 downto 240) when pack_counter = 31 else
                                packed_fifo_data_d3(239 downto 0)   & packed_fifo_data_d2                                                           when pack_counter = 1;

aligned_packed_wr           <= '1' when (pack_wr = '1' OR trigger_final_write = '1') AND    (pack_counter = 2 OR
                                                                                                pack_counter = 4 OR
                                                                                                pack_counter = 6 OR
                                                                                                pack_counter = 8 OR
                                                                                                pack_counter = 10 OR
                                                                                                pack_counter = 12 OR
                                                                                                pack_counter = 14 OR
                                                                                                pack_counter = 16 OR
                                                                                                pack_counter = 18 OR
                                                                                                pack_counter = 19 OR
                                                                                                pack_counter = 21 OR
                                                                                                pack_counter = 23 OR
                                                                                                pack_counter = 25 OR
                                                                                                pack_counter = 27 OR
                                                                                                pack_counter = 29 OR
                                                                                                pack_counter = 31 OR
                                                                                                pack_counter = 1) else
                                '0';


    ---------------------------------------------------------------------------

    packed_cache_fifo : entity signal_processing_common.xpm_sync_fifo_wrapper
    Generic map (
        FIFO_MEMORY_TYPE    => "uram",
        READ_MODE           => "fwft",
        FIFO_DEPTH          => packed_depth,    -- 512
        DATA_WIDTH          => packed_width     -- 512
    )
    Port map ( 
        fifo_reset          => reset,
        fifo_clk            => clk,
        fifo_in_reset       => packed_fifo_in_reset,
        -- RD    
        fifo_rd             => packed_fifo_rd,
        fifo_q              => packed_fifo_q,
        fifo_q_valid        => packed_fifo_q_valid,
        fifo_empty          => packed_fifo_empty,
        fifo_rd_count       => packed_fifo_rd_count,
        -- WR        
        fifo_wr             => aligned_packed_wr_d,
        fifo_data           => aligned_packed_fifo_data_d,
        fifo_full           => packed_fifo_full,
        fifo_wr_count       => packed_fifo_wr_count
    );    
    

    o_spead_data        <= packed_fifo_q;
    packed_fifo_rd      <= i_spead_data_rd;


    ---------------------------------------------------------------------------
    -- PROC to push data to packetiser.
    
    push_proc : process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                bytes_to_process        <= ( others => '0');
                send_spead_data         <= "00";
            else
                if unsigned(packed_fifo_rd_count) >= 256 then   -- packets of 8kish when dealing with larger stations
                    send_spead_data     <= "01";
                    bytes_to_packetise  <= 14D"8704";           -- stream out 256 reads of 34 bytes.
                elsif (pack_it_fsm = COMPLETE)  then            -- force drain
                    send_spead_data     <= "01";
                    bytes_to_packetise  <= bytes_to_process;
                else
                    send_spead_data <= send_spead_data(0) & '0';
                end if;

                if (pack_it_fsm = IDLE)  then
                    bytes_to_process <= ( others => '0');
                elsif packed_fifo_rd = '1' then
                    bytes_to_process <= bytes_to_process - 64;
                elsif packed_fifo_wr = '1' then
                    bytes_to_process <= bytes_to_process + 34;
                end if;
            end if;

        end if;
    end process;

    o_spead_data_rdy    <= send_spead_data(1);
    o_byte_count        <= std_logic_vector(bytes_to_packetise);

    ---------------------------------------------------------------------------
    -- debug
    

    debug_proc : process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                debug_instruction_writes    <= (others => '0');
            else
                if meta_cache_fifo_wr = '1' then
                    debug_instruction_writes    <= debug_instruction_writes + 1;
                end if;
            end if;
        end if;
    end process;

    -- ARGs
    ARGS_register_Packetiser : entity spead_lib.hbm_read_hbm_rd_debug_reg 
    PORT MAP (
        -- AXI Lite signals, 300 MHz Clock domain
        MM_CLK                          => i_axi_clk,
        MM_RST                          => i_axi_rst,
        
        SLA_IN                          => i_spead_hbm_rd_lite_axi_mosi,
        SLA_OUT                         => o_spead_hbm_rd_lite_axi_miso,

        HBM_RD_DEBUG_FIELDS_RO          => hbm_rd_debug_ro
    
    );

    hbm_rd_debug_ro.debug_pack_it_fsm           <= pack_it_fsm_debug;
    hbm_rd_debug_ro.debug_cor_tri_fsm			<= cor_tri_fsm_debug;
    hbm_rd_debug_ro.debug_hbm_reader_fsm		<= hbm_reader_fsm_debug;
    hbm_rd_debug_ro.debug_hbm_reader_fsm_cache  <= hbm_reader_fsm_debug_cache;
    hbm_rd_debug_ro.subarray_instruction_writes	<= std_logic_vector(debug_instruction_writes);
    

end Behavioral;
