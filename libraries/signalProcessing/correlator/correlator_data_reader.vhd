----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: 02/04/2023 04:22:23 PM
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
--      SM handling the HBM read
--      FIFO catching Vis Data
--      FIFO catching Meta Data
--      SM packing the data.
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

library IEEE, correlator_lib, common_lib, PSR_Packetiser_lib, signal_processing_common;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
Library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;
USE common_lib.common_pkg.ALL;
use PSR_Packetiser_lib.ethernet_pkg.ALL;

entity correlator_data_reader is
    Generic ( 
        DEBUG_ILA           : BOOLEAN := FALSE;
        SPEAD_DATA_WIDTH    : INTEGER := 256

    );
    Port ( 
        -- clock used for all data input and output from this module (300 MHz)
        i_axi_clk           : in std_logic;
        i_axi_rst           : in std_logic;

        i_local_reset       : in std_logic;

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
        
        -- Packed up Correlator Data.
        o_spead_data        : out std_logic_vector((SPEAD_DATA_WIDTH-1) downto 0);
        i_spead_data_rd     : in std_logic;                         -- FWFT FIFO
        o_current_array     : out std_logic_vector(7 downto 0);     -- max of 16 zooms x 8 sub arrays = 128, zero-based.
        o_spead_data_rdy    : out std_logic;
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


-- HBM data from correlator.
constant hbm_data_width       : INTEGER := 512;
constant hbm_data_depth       : INTEGER := 128;    -- choosen at random, hopefully not 64 aub arrays waiting to be read.

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

-- HBM data from correlator.
constant hbm_meta_width       : INTEGER := 512;
constant hbm_meta_depth       : INTEGER := 32;    -- choosen at random, hopefully not 64 aub arrays waiting to be read.

signal hbm_meta_fifo_in_reset : std_logic;
signal hbm_meta_fifo_rd       : std_logic;
signal hbm_meta_fifo_q        : std_logic_vector((hbm_meta_width-1) downto 0);
signal hbm_meta_fifo_q_valid  : std_logic;
signal hbm_meta_fifo_empty    : std_logic;
signal hbm_meta_fifo_rd_count : std_logic_vector(((ceil_log2(hbm_meta_depth))) downto 0);
-- WR        
signal hbm_meta_fifo_wr       : std_logic;
signal hbm_meta_fifo_data     : std_logic_vector((hbm_meta_width-1) downto 0);
signal hbm_meta_fifo_full     : std_logic;
signal hbm_meta_fifo_wr_count : std_logic_vector(((ceil_log2(hbm_meta_depth))) downto 0);

signal hbm_data_sel           : std_logic;
signal hbm_meta_sel           : std_logic;

-- Packed data to SPEAD packets
constant packed_width       : INTEGER := 272;   -- 34 bytes = 32 data + 2 meta.
constant packed_depth       : INTEGER := 256;    -- choosen at random, hopefully not 64 aub arrays waiting to be read.

signal packed_fifo_in_reset : std_logic;
signal packed_fifo_rd       : std_logic;
signal packed_fifo_q        : std_logic_vector((packed_width-1) downto 0);
signal packed_fifo_q_valid  : std_logic;
signal packed_fifo_empty    : std_logic;
signal packed_fifo_rd_count : std_logic_vector(((ceil_log2(packed_depth))) downto 0);
-- WR        
signal packed_fifo_wr       : std_logic;
signal packed_fifo_data     : std_logic_vector((packed_width-1) downto 0);
signal packed_fifo_full     : std_logic;
signal packed_fifo_wr_count : std_logic_vector(((ceil_log2(packed_depth))) downto 0);


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
signal HBM_reads                : unsigned(16 downto 0);

signal HBM_start_addr           : std_logic_vector(31 downto 0) := (others => '0');

--------------------------------------------------------------------------------
-- HBM rd signals
signal rd_addr                  : std_logic_vector(31 downto 0) := (others => '0');
signal rd_addr_req              : std_logic := '0';
signal hbm_addr_rd_rdy          : std_logic;

--------------------------------------------------------------------------------
-- HBM wr signals
type HBM_wr_tracker_fsm_type is (idle, load, check, complete);
signal HBM_wr_tracker_fsm : HBM_wr_tracker_fsm_type;

--------------------------------------------------------------------------------
-- Pack SM signals
type pack_it_fsm_type is   (IDLE, LOOPS, CALC, MATH, PROCESSING, RD_DRAIN, COMPLETE);
signal pack_it_fsm : pack_it_fsm_type;

signal meta_data_cache          : std_logic_vector(255 downto 0);
signal hbm_data_cache           : std_logic_vector(255 downto 0);
signal hbm_data_cache_2         : std_logic_vector(255 downto 0);

signal packed                   : std_logic_vector(255 downto 0);
signal pack_count               : unsigned(7 downto 0) := (others => '0');

signal meta_data_rd             : unsigned(3 downto 0) := (others => '0');

signal data_rd_counter          : unsigned(12 downto 0) := (others => '0');
signal data_wr_counter          : unsigned(12 downto 0) := (others => '0');

signal strut_counter            : integer := 0;

signal hbm_data_cache_sel       : std_logic;
signal hbm_data_rd_en           : std_logic;
signal pack_start               : std_logic;

signal row_count_rd_out         : unsigned(12 downto 0);
signal small_matrix_tracker     : unsigned(3 downto 0);
signal matrix_tracker           : unsigned(9 downto 0);

TYPE segments_hbm_triangle IS ARRAY (INTEGER RANGE <>) OF UNSIGNED(3 DOWNTO 0);
TYPE data_hbm_triangle IS ARRAY (INTEGER RANGE <>) OF UNSIGNED(7 DOWNTO 0);
--constant write_per_line         : data_hbm_triangle(0 to 15)    := (x"01",x"02",x"03",x"04",x"05",x"06",x"07",x"08",x"09",x"0A",x"0B",x"0C",x"0D",x"0E",x"0F",x"10");
--constant read_skip_per_line     : data_hbm_triangle(0 to 15)    := (x"08",x"08",x"07",x"07",x"06",x"06",x"05",x"05",x"04",x"04",x"03",x"03",x"02",x"02",x"01",x"01");
--constant read_keep_per_line     : data_hbm_triangle(0 to 15)    := (x"02",x"02",x"04",x"04",x"06",x"06",x"08",x"08",x"0A",x"0A",x"0C",x"0C",x"0E",x"0E",x"10",x"10");
constant write_per_line         : segments_hbm_triangle(0 to 15)    := (x"0",x"1",x"2",x"3",x"4",x"5",x"6",x"7",x"8",x"9",x"A",x"B",x"C",x"D",x"E",x"F");
constant read_skip_per_line     : segments_hbm_triangle(0 to 15)    := (x"7",x"7",x"6",x"6",x"5",x"5",x"4",x"4",x"3",x"3",x"2",x"2",x"1",x"1",x"0",x"0");
constant read_keep_per_line     : segments_hbm_triangle(0 to 15)    := (x"0",x"0",x"1",x"1",x"2",x"2",x"3",x"3",x"4",x"4",x"5",x"5",x"6",x"6",x"7",x"7");


--------------------------------------------------------------------------------


begin
    -- HBM addr
    o_HBM_axi_ar.addr       <= zero_byte & std_logic_vector(rd_addr);
    o_HBM_axi_ar.valid      <= rd_addr_req;
    o_HBM_axi_ar.len        <= x"07";               -- read 512 bytes initially.
    hbm_addr_rd_rdy         <= i_HBM_axi_arready;

    -- HBM data
    o_HBM_axi_rready        <= '1';
    
    clk                     <= i_axi_clk;
    reset                   <= i_axi_rst OR i_local_reset;

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
                cor_triangle_fsm    <= idle;
                meta_cache_fifo_rd  <= '0';
                HBM_reads           <= (others => '0');
                pack_start          <= '0';
            else
                case cor_triangle_fsm is
                    when idle => 
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
                        -- TODO !!!!!!!
                        -- code for RAM lookup for sub array enable.
                        -- skip if not enabled, after checking if the last pass through was for different sub array.
                        -- pass through initially.
                        cor_triangle_fsm        <= calculate_reads;
                        HBM_start_addr          <= cor_tri_hbm_start_addr;

                    when calculate_reads => 
                        -- cor_tri_row_count is indicating where the edge of the triangle is, ie how many rows,
                        -- 512 bytes per row. 64 bytes per read on the interface so 8 per line.
                        -- so row_count needs to << 3.
                        -- for 16 rows 8 rds per row = 16 x 8 = 128 rds per square.
                        -- for a 4096 cor, rds will be 256 squares  * 128 rds
                        -- cor_tri_row is effectively a multiplier.
                        -- max requests = 4096 col x 32 bytes x 16 rows = 2 MB (last section of a 4096x4096 correlation)
                        cor_read_data <= cor_read_data + (cor_tri_row_count & "000");

                        -- meta data is packed, 64 bytes = 32 correlations.
                        -- 8 reads per 512 bytes (as a HBM min). Therefore 1 read = 256 lots of meta data.

                        if cor_tri_row = 0 then
                            cor_triangle_fsm    <= complete;
                        else
                            cor_tri_row         <= cor_tri_row - 1;
                        end if;
                                           
                    when complete => 
                        cor_tri_row             <= unsigned(meta_cache_fifo_q(133 downto 121));
                        pack_start              <= '1';


                        cor_triangle_fsm        <= pop_instruction;
                    
                    
                    when pop_instruction => 
                        meta_cache_fifo_rd      <= '1';
                        last_instruct_subarray  <= cor_tri_sub_array;

                        if pack_it_fsm = COMPLETE then
                            cor_triangle_fsm        <= cleanup;
                        end if;

                    when cleanup => 
                        meta_cache_fifo_rd      <= '0';
                        cor_triangle_fsm        <= idle;

                    WHEN OTHERS => 
                        cor_triangle_fsm        <= idle;

                end case;
            end if;

        end if;
    end process;

    ---------------------------------------------------------------------------
-- DATA cache
    hbm_data_sel <= '1';

    hbm_data_fifo_data  <= i_HBM_axi_r.data;
    hbm_data_fifo_wr    <= i_HBM_axi_r.valid AND hbm_data_sel;

    hbm_data_cache_fifo : entity signal_processing_common.xpm_sync_fifo_wrapper
    Generic map (
        FIFO_MEMORY_TYPE    => "block",
        READ_MODE           => "fwft",
        FIFO_DEPTH          => hbm_data_depth,
        DATA_WIDTH          => hbm_data_width
    )
    Port map ( 
        fifo_reset          => reset,
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
    hbm_meta_fifo_wr    <= i_HBM_axi_r.valid AND hbm_meta_sel;

    hbm_meta_cache_fifo : entity signal_processing_common.xpm_sync_fifo_wrapper
    Generic map (
        FIFO_MEMORY_TYPE    => "block",
        READ_MODE           => "fwft",
        FIFO_DEPTH          => hbm_meta_depth,
        DATA_WIDTH          => hbm_meta_width
    )
    Port map ( 
        fifo_reset          => reset,
        fifo_clk            => clk,
        fifo_in_reset       => hbm_meta_fifo_in_reset,
        -- RD    
        fifo_rd             => hbm_meta_fifo_rd,
        fifo_q              => hbm_meta_fifo_q,
        fifo_q_valid        => hbm_meta_fifo_q_valid,
        fifo_empty          => hbm_meta_fifo_empty,
        fifo_rd_count       => hbm_meta_fifo_rd_count,
        -- WR        
        fifo_wr             => hbm_meta_fifo_wr,
        fifo_data           => hbm_meta_fifo_data,
        fifo_full           => hbm_meta_fifo_full,
        fifo_wr_count       => hbm_meta_fifo_wr_count
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
                meta_data_cache     <= x"DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF" ;
                pack_it_fsm         <= IDLE;
                packed_fifo_wr      <= '0';
                meta_data_rd        <= x"F";
                hbm_data_cache_sel  <= '0';
                hbm_data_fifo_rd    <= '0';
                data_rd_counter     <= ( others => '0' );
                data_wr_counter     <= ( others => '0' );
                row_count_rd_out    <= ( others => '0' );
                hbm_data_rd_en      <= '0';
            else

                case pack_it_fsm is
                    when IDLE =>
                        --if pack_start = '1' and hbm_meta_fifo_empty = '0' and hbm_data_fifo_empty = '0' then
                        if pack_start = '1' and hbm_data_fifo_empty = '0' then
                            pack_it_fsm     <= LOOPS;
                        end if;
                        packed_fifo_wr      <= '0';
                        strut_counter       <= 0;
                        hbm_data_cache_sel  <= '0';
                        row_count_rd_out    <= cor_tri_row_count + cor_tri_row;
                        small_matrix_tracker<= x"0";
                        matrix_tracker      <= cor_tri_row(12 downto 3); --(others => '0');
                        hbm_data_rd_en      <= '0';

                    when LOOPS =>
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
                        
                    when CALC =>
                        -- Mux into vector the starting row number and add to end the number of reads for the triangle on 16x16 basis.
                        data_rd_counter(12 downto 0)    <= matrix_tracker(9 downto 0) & read_keep_per_line(strut_counter)(2 downto 0);
                        data_wr_counter(12 downto 0)    <= matrix_tracker(8 downto 0) & write_per_line(strut_counter)(3 downto 0);
                        hbm_data_rd_en      <= '1';

                        pack_it_fsm         <= PROCESSING;

                    -- READING data to be packed along a ROW.
                    when PROCESSING =>
                        packed_fifo_wr      <= '1';
                        
                        hbm_data_cache_sel  <= NOT hbm_data_cache_sel;
                        if hbm_data_cache_sel = '0' then
                            hbm_data_cache      <= hbm_data_fifo_q(255 downto 0);
                        else
                            hbm_data_cache      <= hbm_data_fifo_q(511 downto 256);
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
                        packed_fifo_wr      <= '0';
                        hbm_data_cache_sel  <= '0';
                        if data_rd_counter = 0 then
                            if strut_counter = small_matrix_tracker then
                                strut_counter       <= 0;
                                if row_count_rd_out(7 downto 0) = 0 then
                                    pack_it_fsm         <= COMPLETE;
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
                        pack_it_fsm         <= IDLE;

                    when OTHERS =>
                        pack_it_fsm         <= IDLE;

                end case;


                
                if meta_data_rd = 0 then
                    --meta_data_cache     <= x"DEADBEEFDEADBEEFDEADBEEFDEADBEEFAAAABBBBCCCCDDDDEEEEFFFFDEADBEEF" ;
                    meta_data_cache     <= x"DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF" ;
                    meta_data_rd        <= x"F";
                elsif packed_fifo_wr = '1' then
                    meta_data_cache     <= zero_word & meta_data_cache(255 downto 16);
                    meta_data_rd        <= meta_data_rd - 1;
                end if;

            end if;
        end if;
    end process;

    packed_fifo_data    <= hbm_data_cache & meta_data_cache(15 downto 0);
    ---------------------------------------------------------------------------

    packed_cache_fifo : entity signal_processing_common.xpm_sync_fifo_wrapper
    Generic map (
        FIFO_MEMORY_TYPE    => "block",
        READ_MODE           => "fwft",
        FIFO_DEPTH          => packed_depth,
        DATA_WIDTH          => packed_width
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
        fifo_wr             => packed_fifo_wr,
        fifo_data           => packed_fifo_data,
        fifo_full           => packed_fifo_full,
        fifo_wr_count       => packed_fifo_wr_count
    );    
    
end Behavioral;
