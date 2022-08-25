----------------------------------------------------------------------------------
-- Company:     CSIRO
-- Create Date: Nov 2020
-- Engineer:    Giles Babich
--
-- 
-- 
-- Setup for 32-bit CDC, for register feeding.
-- 
----------------------------------------------------------------------------------


library IEEE, XPM;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use xpm.vcomponents.all;

library UNISIM;
use UNISIM.VComponents.all;


entity sync_vector is
    generic (
        WIDTH : integer   := 32
    );
    Port ( 
        clock_a_rst : in std_logic;
        Clock_a     : in std_logic;
        Clock_b     : in std_logic;
        data_in     : in std_logic_vector((WIDTH-1) downto 0);
        data_out    : out std_logic_vector((WIDTH-1) downto 0)
    );
end sync_vector;

architecture rtl of sync_vector is

signal data_in_int  : std_logic_vector((WIDTH-1) downto 0) := (others => '0');

signal data_wr : std_logic;

signal data_rd : std_logic;

signal data_empty : std_logic;

signal data_q       : std_logic_vector((WIDTH-1) downto 0);

type drain_statemachine is (IDLE, RUN);
signal drain_sm : drain_statemachine;

signal clock_b_rst : std_logic;

signal fifo_wr_busy : std_logic;

signal reset_combo_a : std_logic;

begin


reset_combo_a <= clock_a_rst OR fifo_wr_busy;

update_fifo_proc : process(clock_a)
begin
    if rising_edge(clock_a) then
        if reset_combo_a = '1' then
            data_wr <= '0';
        else
            data_in_int <= data_in;
        
            if data_in_int /= data_in then
                data_wr <= '1';
            else
                data_wr <= '0';
            end if;
        end if;
    end if;
end process;


------------------------------------------
-- sync reset to clock B domain

-- notify packet complete to MAC Clock Domain
    xpm_cdc_pulse_inst : xpm_cdc_single
    generic map (
        DEST_SYNC_FF    => 2,   
        INIT_SYNC_FF    => 1,   
        SRC_INPUT_REG   => 1,   
        SIM_ASSERT_CHK  => 0    
    )
    port map (
        dest_clk        => clock_b,   
        dest_out        => clock_b_rst,         
        src_clk         => clock_a,    
        src_in          => reset_combo_a
    );
-------------------------------------------

latest_value_proc : process(clock_b)
begin
    if rising_edge(clock_b) then
        if clock_b_rst = '1' then
            drain_sm    <= IDLE;
            data_out    <= (others => '0');
        else
            case drain_sm is
                when IDLE =>
                    if data_empty = '0' then
                        data_rd     <= '1';
                        drain_sm    <= RUN;
                        data_out    <= data_q;
                    else
                        data_rd     <= '0';
                    end if;
                    
                when RUN =>
                    data_rd     <= '0';
                    drain_sm    <= IDLE;
                
                when others =>
                    drain_sm    <= IDLE;
            end case;
        end if;
    end if;
end process;



CDC_fifo : xpm_fifo_async
    generic map (
        CDC_SYNC_STAGES         => 3,
        DOUT_RESET_VALUE        => "0",
        ECC_MODE                => "no_ecc",
        FIFO_MEMORY_TYPE        => "distributed",
        FIFO_READ_LATENCY       => 0,
        FIFO_WRITE_DEPTH        => 16,
        FULL_RESET_VALUE        => 0,
        READ_DATA_WIDTH         => WIDTH, --32,
        READ_MODE               => "std",
        RELATED_CLOCKS          => 0,
        SIM_ASSERT_CHK          => 0,
        USE_ADV_FEATURES        => "0000",
        WAKEUP_TIME             => 0,
        WRITE_DATA_WIDTH        => WIDTH --32
    )
    port map (
        rst             => clock_a_rst,    -- 1-bit input: Reset: Must be synchronous to wr_clk.
        
        rd_clk          => Clock_b,   -- 1-bit input: Read clock: Used for read operation.
        rd_en           => data_rd,
        dout            => data_q,        -- READ_DATA_WIDTH-bit output: Read Data.
        
        empty           => data_empty,      -- 1-bit output: Empty Flag: When asserted, this signal indicates that the FIFO is empty.
        wr_clk          => Clock_a, -- 1-bit input: Write clock
        wr_en           => data_wr, 
        din             => data_in_int,       -- WRITE_DATA_WIDTH-bit input: Write Data.
        
        data_valid      => open,
        rd_data_count   => open, -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
        full            => open,  -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full.
        wr_data_count   => open, -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        
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
        wr_rst_busy     => fifo_wr_busy,  -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO is busy with reset
        injectdbiterr   => '0', -- 1-bit input: Double Bit Error Injection: Injects a double bit error.
        injectsbiterr   => '0', -- 1-bit input: Single Bit Error Injection
        sleep           => '0'         -- 1-bit input: Dynamic power saving
    );


end rtl;
