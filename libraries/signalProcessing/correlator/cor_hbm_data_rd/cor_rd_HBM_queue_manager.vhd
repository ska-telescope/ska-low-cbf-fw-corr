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
use spead_lib.ethernet_pkg.ALL;
library xpm;
use xpm.vcomponents.all;

entity cor_rd_HBM_queue_manager is
    Generic ( 
        DEBUG_ILA               : BOOLEAN := FALSE;
        META_FIFO_WRITE_WIDTH   : INTEGER := 512;
        META_FIFO_READ_WIDTH    : INTEGER := 32;
        META_FIFO_WRITE_DEPTH   : INTEGER := 32;
        META_FIFO_READ_DEPTH    : INTEGER := 128;

        HBM_DATA_DEPTH          : INTEGER := 128;
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
        i_number_of_64b_rds         : in unsigned(16 downto 0);
        o_done                      : out std_logic;

        -- Visibility Data FIFO RD interface
        i_hbm_data_fifo_rd          : in std_logic;
        o_hbm_data_fifo_q           : out std_logic_vector((hbm_data_width-1) downto 0);
        o_hbm_data_fifo_empty       : out std_logic;
        o_hbm_data_fifo_rd_count    : out std_logic_vector(((ceil_log2(hbm_data_depth))) downto 0);

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

COMPONENT ila_0
PORT (
    clk : IN STD_LOGIC;
    probe0 : IN STD_LOGIC_VECTOR(191 DOWNTO 0));
END COMPONENT; 

constant META_OFFSET_256MB  : unsigned(31 downto 0) := x"10000000";

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
signal hbm_meta_fifo_in_reset : std_logic;
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

signal hbm_data_sel_cnt       : unsigned(5 downto 0);

----------------------------------------------------------------------------
-- hbm rd signals
type HBM_reader_fsm_type is     (IDLE, CALC, 
                                RD_META, RD_META_AR, 
                                RD_DATA, RD_DATA_AR, 
                                DATA_2, 
                                CHECK, COMPLETE);
signal HBM_reader_fsm : HBM_reader_fsm_type;

signal hbm_reader_fsm_debug         : std_logic_vector(3 downto 0)  := x"0";
signal hbm_reader_fsm_debug_d       : std_logic_vector(3 downto 0)  := x"0";
signal hbm_reader_fsm_debug_cache   : std_logic_vector(3 downto 0)  := x"0";

-- 512 byte rds
signal meta_data_addr       : unsigned(31 downto 0) := (others => '0');
signal meta_data_quantity   : unsigned(13 downto 0) := (others => '0');

signal vis_data_addr        : unsigned(31 downto 0) := (others => '0');

signal hbm_retrieval_trac   : unsigned(7 downto 0) := (others => '0');
signal hbm_returned_trac    : unsigned(7 downto 0) := (others => '0');

signal hbm_axi_ar_valid     : std_logic := '0';
signal hbm_axi_ar_addr      : std_logic_vector(31 downto 0);
signal hbm_axi_ar_len       : std_logic_vector(7 downto 0);
signal hbm_axi_ar_rdy       : std_logic;

signal hbm_rd_loop_cnt      : unsigned(3 downto 0);

signal HBM_axi_data_valid   : std_logic;
signal HBM_axi_data_last    : std_logic;

begin
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

---------------------------------------------------------------------------    
-- Visibility Data FIFO RD interface
hbm_data_fifo_rd                <= i_hbm_data_fifo_rd;
o_hbm_data_fifo_q               <= hbm_data_fifo_q;
o_hbm_data_fifo_empty           <= hbm_data_fifo_empty;
o_hbm_data_fifo_rd_count        <= hbm_data_fifo_rd_count;

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
        -- if (hbm_axi_ar_valid = '1' AND hbm_axi_ar_rdy = '1') AND (i_HBM_axi_r.valid = '1' AND i_HBM_axi_r.last = '1') then
        --     hbm_retrieval_trac <= hbm_retrieval_trac;
        -- elsif (hbm_axi_ar_valid = '1' AND hbm_axi_ar_rdy = '1') then
        --     hbm_retrieval_trac <= hbm_retrieval_trac + 8;
        -- elsif (i_HBM_axi_r.valid = '1' AND i_HBM_axi_r.last = '1') then
        --     hbm_retrieval_trac <= hbm_retrieval_trac - 8;
        -- end if;

        if (HBM_reader_fsm = IDLE) or (reset = '1') then
            hbm_retrieval_trac  <= (others => '0');
            hbm_returned_trac   <= (others => '0');
        else
            if (hbm_axi_ar_valid = '1' AND hbm_axi_ar_rdy = '1') then
                hbm_retrieval_trac  <= hbm_retrieval_trac + 8;
            end if;

            if (i_HBM_axi_r.valid = '1' AND i_HBM_axi_r.last = '1') then
                hbm_returned_trac   <= hbm_returned_trac + 8;
            end if;
        end if;
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
            
            hbm_axi_ar_valid    <= '0';
            
            hbm_axi_ar_addr     <= x"00000000";
            hbm_rd_loop_cnt     <= x"0";

        else
            
            hbm_reader_fsm_debug_d <= hbm_reader_fsm_debug;

            if (hbm_reader_fsm_debug_d /= hbm_reader_fsm_debug) then
                hbm_reader_fsm_debug_cache <= hbm_reader_fsm_debug_d;
            end if;


            case HBM_reader_fsm is
                when IDLE =>
                    hbm_reader_fsm_debug    <= x"0";
                    if i_begin = '1' then
                        HBM_reader_fsm  <= CALC;
                        -- report back current HBM address in use.
                        o_HBM_curr_addr <= std_logic_vector(i_hbm_base_addr);
                    end if;
                    hbm_rd_loop_cnt     <= x"0";
                    -- META data always stored in upper half of HBM segment.
                    meta_data_addr      <= META_OFFSET_256MB + (x"0" & i_hbm_base_addr(31 downto 4));
                    vis_data_addr       <= i_hbm_base_addr;
                    -- 8 rds per 512KB.
                    meta_data_quantity  <= i_number_of_64b_rds(16 downto 3);

                when CALC =>
                    hbm_reader_fsm_debug    <= x"1";
                    -- assume 1 rd of meta data and 2 of data per 16x16
                    if meta_data_quantity < 8 then
                        meta_data_quantity  <= (others => '0');
                    else
                        meta_data_quantity  <= meta_data_quantity - 8;    
                    end if;
                    HBM_reader_fsm      <= RD_META;

                when RD_META =>
                    hbm_reader_fsm_debug    <= x"2";
                    hbm_axi_ar_addr         <=  std_logic_vector(meta_data_addr);
                    hbm_axi_ar_valid        <= '1';
                    meta_data_addr          <= meta_data_addr + 512;
                        
                    HBM_reader_fsm          <= RD_META_AR;


                when RD_META_AR =>
                    hbm_reader_fsm_debug    <= x"3";
                    if hbm_axi_ar_rdy = '1' then
                        hbm_axi_ar_valid    <= '0';
                        HBM_reader_fsm      <= RD_DATA;
                    end if;

                when RD_DATA =>
                    hbm_reader_fsm_debug    <= x"4";
                    hbm_axi_ar_addr         <=  std_logic_vector(vis_data_addr);
                    hbm_axi_ar_valid        <= '1';

                    vis_data_addr           <= vis_data_addr + 512;

                    HBM_reader_fsm          <= RD_DATA_AR;


                when RD_DATA_AR =>
                    hbm_reader_fsm_debug    <= x"5";
                    if hbm_axi_ar_rdy = '1' then
                        hbm_axi_ar_valid    <= '0';
                        hbm_rd_loop_cnt     <= hbm_rd_loop_cnt + 1;
                        if hbm_rd_loop_cnt = x"F" then
                            HBM_reader_fsm      <= DATA_2;
                        else
                            HBM_reader_fsm      <= RD_DATA;
                        end if;

                    end if;

                when DATA_2 => 
                    hbm_reader_fsm_debug    <= x"6";
                    -- request 8k of data and wait until it is drain to 25% before next loop.
                    if unsigned(hbm_data_fifo_rd_count) < 2048 then
                        HBM_reader_fsm      <= CHECK;
                    end if;


                when CHECK =>
                    hbm_reader_fsm_debug    <= x"7";
                    if meta_data_quantity = 0 then
                        HBM_reader_fsm      <= COMPLETE;
                    else
                        HBM_reader_fsm      <= CALC;
                    end if;

                when COMPLETE =>
                    hbm_reader_fsm_debug    <= x"8";
                    if hbm_retrieval_trac = hbm_returned_trac then
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
-- meta data comes first (512 bytes) then 8182 bytes of correlator data.
--

hbm_sel_proc : process(clk)
begin
    if rising_edge(clk) then
        if (reset = '1') then
            hbm_data_sel        <= '0';
            hbm_data_sel_cnt    <= (others => '0');
        else
            HBM_axi_data_valid  <= i_HBM_axi_r.valid;
            HBM_axi_data_last   <= i_HBM_axi_r.last;

            if  (HBM_reader_fsm = IDLE) OR (hbm_data_sel_cnt = 17) then
                hbm_data_sel        <= '0';
                hbm_data_sel_cnt    <= (others => '0');
            elsif (HBM_axi_data_valid = '1' AND HBM_axi_data_last = '1') then
                hbm_data_sel        <= '1'; 
                hbm_data_sel_cnt    <=  hbm_data_sel_cnt + 1;
            end if;
        end if;
    end if;
end process;

    o_fifo_in_rst       <= hbm_data_fifo_in_reset;

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

-- constant META_FIFO_WRITE_WIDTH : integer := 32;
-- constant META_FIFO_READ_WIDTH  : integer := 64;
-- constant META_FIFO_WRITE_DEPTH : integer := 512;
-- constant META_FIFO_READ_DEPTH  : integer := FIFO_WRITE_DEPTH*WRITE_DATA_WIDTH/READ_DATA_WIDTH;
    hbm_meta_cache_fifo : xpm_fifo_sync
        generic map (
            DOUT_RESET_VALUE    => "0",    
            ECC_MODE            => "no_ecc",
            FIFO_MEMORY_TYPE    => "block", 
            FIFO_READ_LATENCY   => 0,
            FIFO_WRITE_DEPTH    => 64,     
            FULL_RESET_VALUE    => 0,      
            PROG_EMPTY_THRESH   => 0,    
            PROG_FULL_THRESH    => 0,     
            RD_DATA_COUNT_WIDTH => ((ceil_log2(META_FIFO_READ_DEPTH))+1),  
            READ_DATA_WIDTH     => META_FIFO_READ_WIDTH,      
            READ_MODE           => "fwft",  
            SIM_ASSERT_CHK      => 0,      
            USE_ADV_FEATURES    => "1404", 
            WAKEUP_TIME         => 0,      
            WRITE_DATA_WIDTH    => 512,     
            WR_DATA_COUNT_WIDTH => ((ceil_log2(META_FIFO_WRITE_DEPTH))+1)   
        )
        port map (
            rst           => i_fifo_reset, 
            wr_clk        => clk, 
            rd_rst_busy   => open,
            wr_rst_busy   => open,

            --------------------------------
            --rd_data_count => op, 
            rd_en         => hbm_meta_fifo_rd,  
            dout          => hbm_meta_fifo_q,
            empty         => hbm_meta_fifo_empty,
            rd_data_count => hbm_meta_fifo_rd_count,
            data_valid    => open,   
            --------------------------------        
            wr_data_count => open,
            wr_en         => hbm_meta_fifo_wr,
            din           => hbm_meta_fifo_data,
            full          => open,

            almost_empty  => open,  
            almost_full   => open,
            dbiterr       => open, 
            overflow      => open,
            prog_empty    => open, 
            prog_full     => open,

            sbiterr       => open,
            underflow     => open,
            wr_ack        => open,
            sleep         => '0',         
            injectdbiterr => '0',     
            injectsbiterr => '0'        
        );

---------------------------------------------------------------------------
-- debug

hbm_rd_debug : ila_0 PORT MAP (
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
    probe0(97 downto 90)    => hbm_data_fifo_rd_count,
    probe0(98)              => hbm_data_fifo_rd,
    probe0(99)              => hbm_data_fifo_wr,
    
    probe0(100)             => hbm_data_sel,
    probe0(106 downto 101)  => std_logic_vector(hbm_data_sel_cnt),
    probe0(107)             => hbm_meta_fifo_rd,
    probe0(108)             => hbm_meta_fifo_wr,

    probe0(172 downto 109)  => i_HBM_axi_r.data(319 downto 256),
    
    probe0(191 downto 173)  => (others => '0')
    );
    
hbm_wide_rd_ila_debug : ila_0 PORT MAP (
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
    probe0(178 downto 171)  => hbm_data_fifo_wr_count,
    probe0(186 downto 179)  => std_logic_vector(hbm_returned_trac),
    probe0(187)             => hbm_data_fifo_wr,
    probe0(191 downto 188)  => std_logic_vector(hbm_data_sel_cnt(3 downto 0))
    );    


end;