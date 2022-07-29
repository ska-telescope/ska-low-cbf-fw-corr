----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: 28.10.2021
-- Design Name: 
-- Module Name: xpm_fifo_wrapper - rtl
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Additional Comments:
-- Wrapper to make this resource appear in heirarchy.
--
-- FUNCTION ceil_log2(n : NATURAL) RETURN NATURAL;
----------------------------------------------------------------------------------


library IEEE, common_lib, xpm;
use IEEE.STD_LOGIC_1164.ALL;
USE common_lib.common_pkg.ALL;
use IEEE.NUMERIC_STD.ALL;
use xpm.vcomponents.all;


entity xpm_fifo_wrapper is
    Generic (
        FIFO_DEPTH      : INTEGER := 16;
        DATA_WIDTH      : INTEGER := 16
    );
    Port ( 
        fifo_reset      : IN STD_LOGIC;
        -- RD    
        fifo_rd_clk     : IN STD_LOGIC;
        fifo_rd         : IN STD_LOGIC;
        fifo_q          : OUT STD_LOGIC_VECTOR((DATA_WIDTH-1) downto 0);
        fifo_q_valid    : OUT STD_LOGIC;
        fifo_empty      : OUT STD_LOGIC;
        fifo_rd_count   : OUT STD_LOGIC_VECTOR(ceil_log2(FIFO_DEPTH) downto 0);
        -- WR        
        fifo_wr_clk     : IN STD_LOGIC;
        fifo_wr         : IN STD_LOGIC;
        fifo_data       : IN STD_LOGIC_VECTOR((DATA_WIDTH-1) downto 0);
        fifo_full       : OUT STD_LOGIC;
        fifo_wr_count   : OUT STD_LOGIC_VECTOR(ceil_log2(FIFO_DEPTH) downto 0) 
    );
end xpm_fifo_wrapper;

architecture rtl of xpm_fifo_wrapper is

begin

CDC_fifo : xpm_fifo_async
    generic map (
        CDC_SYNC_STAGES         => 3,       -- DECIMAL
        DOUT_RESET_VALUE        => "0",    -- String
        ECC_MODE                => "no_ecc",       -- String
        FIFO_MEMORY_TYPE        => "BLOCK", -- String
        FIFO_READ_LATENCY       => 0,     -- DECIMAL
        FIFO_WRITE_DEPTH        => FIFO_DEPTH,   -- DECIMAL
        FULL_RESET_VALUE        => 0,      -- DECIMAL
        PROG_EMPTY_THRESH       => 0,    -- DECIMAL
        PROG_FULL_THRESH        => 10,     -- DECIMAL
        RD_DATA_COUNT_WIDTH     => ((ceil_log2(FIFO_DEPTH))+1),   -- DECIMAL
        READ_DATA_WIDTH         => DATA_WIDTH,      -- DECIMAL
        READ_MODE               => "fwft",         -- String
        RELATED_CLOCKS          => 0,        -- DECIMAL
        SIM_ASSERT_CHK          => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES        => "0404", -- String. bit 2 and bit 10 enables write data count and read data count
        WAKEUP_TIME             => 0,           -- DECIMAL
        WRITE_DATA_WIDTH        => DATA_WIDTH,     -- DECIMAL
        WR_DATA_COUNT_WIDTH     => ((ceil_log2(FIFO_DEPTH))+1)    -- DECIMAL
    )
    port map (
        rst             => fifo_reset,    -- 1-bit input: Reset: Must be synchronous to wr_clk.
        
        rd_clk          => fifo_rd_clk,   -- 1-bit input: Read clock: Used for read operation.
        rd_en           => fifo_rd,
        dout            => fifo_q,        -- READ_DATA_WIDTH-bit output: Read Data.
        data_valid      => fifo_q_valid,
        empty           => fifo_empty,      -- 1-bit output: Empty Flag: When asserted, this signal indicates that the FIFO is empty.
        rd_data_count(ceil_log2(FIFO_DEPTH) downto 0)   => fifo_rd_count, -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
                
        wr_clk          => fifo_wr_clk, -- 1-bit input: Write clock
        wr_en           => fifo_wr, 
        din             => fifo_data,       -- WRITE_DATA_WIDTH-bit input: Write Data.
        full            => fifo_full,  -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full.
        wr_data_count(ceil_log2(FIFO_DEPTH) downto 0)   => fifo_wr_count, -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        
        almost_empty    => open,       -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
        almost_full     => open,        -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
        dbiterr         => open,            -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
        overflow        => open,     -- 1-bit output: Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected, because the FIFO is full.
        prog_empty      => open,   -- 1-bit output: Programmable Empty: 
        prog_full       => open,    -- 1-bit output: Programmable Full
        rd_rst_busy     => open,  -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
        sbiterr         => open,      -- 1-bit output: Single Bit Error: Indicates that the ECC decoder detected and fixed a single-bit error.
        underflow       => open,    -- 1-bit output: Underflow: Indicates that the read request (rd_en).
        wr_ack          => open,       -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock succeeded.
        wr_rst_busy     => open,  -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO is busy with reset
        injectdbiterr   => '0', -- 1-bit input: Double Bit Error Injection: Injects a double bit error.
        injectsbiterr   => '0', -- 1-bit input: Single Bit Error Injection
        sleep           => '0'         -- 1-bit input: Dynamic power saving
    );

end rtl;
