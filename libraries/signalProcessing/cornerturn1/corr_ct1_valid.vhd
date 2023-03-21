----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 29.09.2020 11:24:19
-- Module Name: ct_valid_memory - Behavioral
-- Description: 
--   Valid Memory.
--   Keeps track of which blocks of 8192 bytes in the HBM are valid.
--   4Gbyte/8192 bytes = 2^32 / 2^13 = 2^19 locations.
--   Uses 2 UltraRAMs.
--   The memory has two ports. 
--     - "set" and "clear" share one port. Set has priority. 
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
Library xpm;
use xpm.vcomponents.all;

entity corr_ct1_valid is
    port (
        i_clk  : in std_logic;
        i_rst  : in std_logic;
        o_rstActive : out std_logic; -- high for 4096 clocks after a rising edge on i_rst.
        -- Set valid
        i_setAddr  : in std_logic_vector(18 downto 0); 
        i_setValid : in std_logic;  -- There must be at least one idle clock between set requests.
        o_duplicate : out std_logic;
        -- clear valid
        i_clearAddr : in std_logic_vector(18 downto 0);
        i_clearValid : in std_logic; -- There must be at least one idle clock between clear requests.
        -- Read contents, fixed 5 clock latency
        i_readAddr : in std_logic_vector(18 downto 0);
        o_readData : out std_logic
    );
end corr_ct1_valid;

architecture Behavioral of corr_ct1_valid is
    
    signal wea : std_logic_vector(0 downto 0);
    signal addra : std_logic_vector(18 downto 0);
    signal dina : std_logic_vector(127 downto 0);
    signal clearPending : std_logic := '0';
    signal clearAddr : std_logic_vector(18 downto 0) := (others => '0');    
    
    signal doutb : std_logic_vector(127 downto 0);
    signal dinb : std_logic_vector(127 downto 0);
    signal web : std_logic_vector(0 downto 0);
    signal addrb : std_logic_vector(18 downto 0);
    signal rstDel1, rstDel2 : std_logic;
    signal rstActive : std_logic := '0';
    signal douta : std_logic_vector(127 downto 0);
    
    signal setValidDel1, setValidDel2, setValidDel3 : std_logic;

    signal set_fifo_dout : std_logic_vector(18 downto 0);
    signal set_fifo_empty, set_fifo_full : std_logic;
    signal set_fifo_wr_data_count : std_logic_vector(4 downto 0);
    signal set_fifo_rd_en : std_logic;

    signal clear_fifo_dout : std_logic_vector(18 downto 0);
    signal clear_fifo_empty, clear_fifo_full : std_logic;
    signal clear_fifo_wr_data_count : std_logic_vector(4 downto 0);
    signal clear_fifo_rd_en : std_logic;
    
    signal addrbLowDel1 : std_logic_vector(6 downto 0);
    signal addrbLowDel2_6_3 : std_logic_Vector(3 downto 0);
    signal addrbLowDel2_2_0 : std_logic_Vector(2 downto 0);
    signal addrblowDel3_2_0 : std_logic_Vector(2 downto 0);
    signal readData8 : std_logic_vector(7 downto 0);
    
    type setclear_fsm_type is (idle, read_set_fifo, get_set_addr, wait_set_data0, wait_set_Data1, get_set_data, set_bit, read_clear_fifo, get_clear_addr, wait_clear_data0, wait_clear_Data1, get_clear_data, clear_bit);
    signal setclear_fsm : setclear_fsm_type := idle;
    
begin
    
    -- FIFOs for set and clear requests, since they take a few clocks to process, and can occur at the same time.
    -- Processing a set or clear request requires a read-modify-write operation on the memory, since it is 128 bits wide.
    set_xpm_fifo_sync_inst : xpm_fifo_sync
    generic map (
        CASCADE_HEIGHT => 0,        -- DECIMAL
        DOUT_RESET_VALUE => "0",    -- String
        ECC_MODE => "no_ecc",       -- String
        FIFO_MEMORY_TYPE => "distributed", -- String
        FIFO_READ_LATENCY => 1,     -- DECIMAL
        FIFO_WRITE_DEPTH => 16,     -- DECIMAL
        FULL_RESET_VALUE => 0,      -- DECIMAL
        PROG_EMPTY_THRESH => 10,    -- DECIMAL
        PROG_FULL_THRESH => 10,     -- DECIMAL
        RD_DATA_COUNT_WIDTH => 1,   -- DECIMAL
        READ_DATA_WIDTH => 19,      -- DECIMAL
        READ_MODE => "std",         -- String
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "0004", -- String; 0x0004 only enables the write data count.
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 19,     -- DECIMAL
        WR_DATA_COUNT_WIDTH => 5    -- DECIMAL
    ) port map (
        almost_empty => open,   -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
        almost_full => open,    -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
        data_valid => open,     -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
        dbiterr => open,        -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
        dout => set_fifo_dout,  -- READ_DATA_WIDTH-bit output: Read Data: The output data bus is driven when reading the FIFO.
        empty => set_fifo_empty,-- 1-bit output: Empty Flag: When asserted, this signal indicates that the FIFO is empty. 
        full => set_fifo_full,  -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full. 
        overflow => open,       -- 1-bit output: Overflow
        prog_empty => open,     -- 1-bit output: Programmable Empty: 
        prog_full => open,      -- 1-bit output: Programmable Full:
        rd_data_count => open,  -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
        rd_rst_busy => open,    -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
        sbiterr => open,        -- 1-bit output: Single Bit Error
        underflow => open,      -- 1-bit output: Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected because the FIFO is empty. Under flowing the FIFO is not destructive to the FIFO.
        wr_ack => open,         -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.
        wr_data_count => set_fifo_wr_data_count, -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        wr_rst_busy => open,    -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
        din => i_setAddr,       -- WRITE_DATA_WIDTH-bit input: Write Data: The input data bus used when writing the FIFO.
        injectdbiterr => '0',   -- 1-bit input: Double Bit Error Injection
        injectsbiterr => '0',   -- 1-bit input: Single Bit Error Injection
        rd_en => set_fifo_rd_en, -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO. 
        rst => i_rst,            -- 1-bit input: Reset: Must be synchronous to wr_clk.
        sleep => '0',            -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
        wr_clk => i_clk,        -- 1-bit input: Write clock
        wr_en => i_setValid     -- 1-bit input: Write Enable:
    );
    
    clear_xpm_fifo_sync_inst : xpm_fifo_sync
    generic map (
        CASCADE_HEIGHT => 0,        -- DECIMAL
        DOUT_RESET_VALUE => "0",    -- String
        ECC_MODE => "no_ecc",       -- String
        FIFO_MEMORY_TYPE => "distributed", -- String
        FIFO_READ_LATENCY => 1,     -- DECIMAL
        FIFO_WRITE_DEPTH => 16,     -- DECIMAL
        FULL_RESET_VALUE => 0,      -- DECIMAL
        PROG_EMPTY_THRESH => 10,    -- DECIMAL
        PROG_FULL_THRESH => 10,     -- DECIMAL
        RD_DATA_COUNT_WIDTH => 1,   -- DECIMAL
        READ_DATA_WIDTH => 19,      -- DECIMAL
        READ_MODE => "std",         -- String
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "0004", -- String; 0x0004 only enables the write data count.
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 19,     -- DECIMAL
        WR_DATA_COUNT_WIDTH => 5    -- DECIMAL
    ) port map (
        almost_empty => open,   -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
        almost_full => open,    -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
        data_valid => open,     -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
        dbiterr => open,        -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
        dout => clear_fifo_dout,  -- READ_DATA_WIDTH-bit output: Read Data: The output data bus is driven when reading the FIFO.
        empty => clear_fifo_empty,-- 1-bit output: Empty Flag: When asserted, this signal indicates that the FIFO is empty. 
        full => clear_fifo_full,  -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full. 
        overflow => open,       -- 1-bit output: Overflow
        prog_empty => open,     -- 1-bit output: Programmable Empty: 
        prog_full => open,      -- 1-bit output: Programmable Full:
        rd_data_count => open,  -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
        rd_rst_busy => open,    -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
        sbiterr => open,        -- 1-bit output: Single Bit Error
        underflow => open,      -- 1-bit output: Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected because the FIFO is empty. Under flowing the FIFO is not destructive to the FIFO.
        wr_ack => open,         -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.
        wr_data_count => clear_fifo_wr_data_count, -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        wr_rst_busy => open,    -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
        din => i_clearAddr,       -- WRITE_DATA_WIDTH-bit input: Write Data: The input data bus used when writing the FIFO.
        injectdbiterr => '0',   -- 1-bit input: Double Bit Error Injection
        injectsbiterr => '0',   -- 1-bit input: Single Bit Error Injection
        rd_en => clear_fifo_rd_en, -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO. 
        rst => i_rst,            -- 1-bit input: Reset: Must be synchronous to wr_clk.
        sleep => '0',            -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
        wr_clk => i_clk,        -- 1-bit input: Write clock
        wr_en => i_clearValid     -- 1-bit input: Write Enable:
    );        
    
    set_fifo_rd_en <= '1' when setclear_fsm = read_set_fifo else '0';
    clear_fifo_rd_en <= '1' when setclear_fsm = read_clear_fifo else '0';
    
    -- Set and clear requests can clash, but will never be back-to-back, so we just need a single register to hold over 
    -- a set request to the next clock cycle.
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            
            if i_rst = '1' then
                wea(0) <= '0';
                addra <= (others => '0');
                dina <= (others => '0');
                setclear_fsm <= idle;
            else
                case setclear_fsm is
                    when idle =>
                        if set_fifo_empty = '0' then
                            setclear_fsm <= read_set_fifo;
                        elsif clear_fifo_empty = '0' then
                            setclear_fsm <= read_clear_fifo;
                        end if;
                        wea(0) <= '0';
               
                    --------------------------------------------------------------
                    -- Read-modify-write to set a bit
                    when read_set_fifo =>
                        setclear_fsm <= get_set_addr;
                        wea(0) <= '0';
                        
                    when get_set_addr =>
                        addra <= set_fifo_dout;
                        setclear_fsm <= wait_set_data0;
                        wea(0) <= '0';
                    
                    when wait_set_data0 =>
                        setclear_fsm <= wait_set_data1;
                        wea(0) <= '0';
                        
                    when wait_set_data1 =>
                        setclear_fsm <= get_set_data;
                        wea(0) <= '0';
                        
                    when get_set_data =>
                        dina <= douta;
                        setclear_fsm <= set_bit;
                        wea(0) <= '0';
                        
                    when set_bit =>
                        dina(to_integer(unsigned(addra(6 downto 0)))) <= '1';
                        wea(0) <= '1';
                        setclear_fsm <= idle;
                    
                    --------------------------------------------------------------
                    -- read-modify-write to clear a bit
                    when read_clear_fifo =>
                        setclear_fsm <= get_clear_addr;
                        wea(0) <= '0';
                        
                    when get_clear_addr =>
                        addra <= clear_fifo_dout;
                        setclear_fsm <= wait_clear_data0;
                        wea(0) <= '0';
                        
                    when wait_clear_data0 =>
                        setclear_fsm <= wait_clear_data1;
                        wea(0) <= '0';
                    
                    when wait_clear_data1 =>
                        setclear_fsm <= get_clear_data;
                        wea(0) <= '0';
                    
                    when get_clear_data =>
                        dina <= douta;
                        setclear_fsm <= clear_bit;
                        wea(0) <= '0';
                        
                    when clear_bit =>
                        dina(to_integer(unsigned(addra(6 downto 0)))) <= '0';
                        wea(0) <= '1';
                        setclear_fsm <= idle;
                        
                    when others => 
                        setclear_fsm <= idle;
                        
                end case;
                
            end if;
            
            if setclear_fsm = set_bit and (dina(to_integer(unsigned(addra(6 downto 0)))) = '1') then
                -- i.e. setting the bit, but the bit was already set.
                o_duplicate <= '1';
            else
                o_duplicate <= '0';
            end if;
            
            rstDel1 <= i_rst;
            rstDel2 <= rstDel1;
            if rstDel1 = '1' and rstDel2 = '0' then -- rising edge of reset
                addrb <= (others => '0');
                rstActive <= '1';
                web(0) <= '1';
            elsif rstActive = '1' then
                addrb <= std_logic_vector(unsigned(addrb) + 128); -- high order bits of the address for writing 32-bit wide words
                if addrb(18 downto 7) = "111111111111" then
                    rstActive <= '0';
                    web(0) <= '0';
                end if;
            else
                addrb <= i_readAddr;
                web(0) <= '0';
            end if;

            addrbLowDel1 <= addrb(6 downto 0);
            addrbLowDel2_6_3 <= addrbLowDel1(6 downto 3);
            addrbLowDel2_2_0 <= addrbLowDel1(2 downto 0);
            addrbLowDel3_2_0 <= addrbLowDel2_2_0;
            
            readData8 <= doutb((to_integer(unsigned(addrbLowDel2_6_3))*8 + 7) downto (to_integer(unsigned(addrbLowDel2_6_3))*8));
            o_readData <= readData8(to_integer(unsigned(addrbLowDel3_2_0)));
            
            o_rstActive <= i_rst or rstDel1 or rstDel2 or rstActive;
            
        end if;
    end process;
    
    
    xpm_memory_tdpram_inst : xpm_memory_tdpram
    generic map (
        ADDR_WIDTH_A => 12,              -- DECIMAL
        ADDR_WIDTH_B => 12,              -- DECIMAL
        AUTO_SLEEP_TIME => 0,            -- DECIMAL
        BYTE_WRITE_WIDTH_A => 128,       -- Same width as data width, so single bit write enable.
        BYTE_WRITE_WIDTH_B => 128,       -- 
        CASCADE_HEIGHT => 0,             -- DECIMAL
        CLOCKING_MODE => "common_clock", -- String
        ECC_MODE => "no_ecc",            -- String
        MEMORY_INIT_FILE => "none",      -- String
        MEMORY_INIT_PARAM => "0",        -- String
        MEMORY_OPTIMIZATION => "true",   -- String
        MEMORY_PRIMITIVE => "ultra",     -- String
        MEMORY_SIZE => 524288,           -- DECIMAL; total size in bits; 4096 x 128 = 524288
        MESSAGE_CONTROL => 0,            -- DECIMAL
        READ_DATA_WIDTH_A => 128,        -- DECIMAL
        READ_DATA_WIDTH_B => 128,        -- DECIMAL
        READ_LATENCY_A => 2,             -- DECIMAL
        READ_LATENCY_B => 2,             -- DECIMAL
        READ_RESET_VALUE_A => "0",       -- String
        READ_RESET_VALUE_B => "0",       -- String
        RST_MODE_A => "SYNC",            -- String
        RST_MODE_B => "SYNC",            -- String
        SIM_ASSERT_CHK => 0,             -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_EMBEDDED_CONSTRAINT => 0,    -- DECIMAL
        USE_MEM_INIT => 0,               -- DECIMAL
        USE_MEM_INIT_MMI => 0,           -- DECIMAL
        WAKEUP_TIME => "disable_sleep",  -- String
        WRITE_DATA_WIDTH_A => 128,       -- DECIMAL
        WRITE_DATA_WIDTH_B => 128,       -- DECIMAL
        WRITE_MODE_A => "no_change",     -- String; options are : "no_change", "read_first", "write_first"
        WRITE_MODE_B => "no_change",     -- String
        WRITE_PROTECT => 1               -- DECIMAL
    )
    port map (
        dbiterra => open,  -- 1-bit output: Status signal to indicate double bit error occurrence on the data output of port A.
        dbiterrb => open,  -- 1-bit output: Status signal to indicate double bit error occurrence on the data output of port A.
        douta => douta,    -- READ_DATA_WIDTH_A-bit output: Data output for port A read operations.
        doutb => doutb,    -- READ_DATA_WIDTH_B-bit output: Data output for port B read operations.
        sbiterra => open,  -- 1-bit output: Status signal to indicate single bit error occurrence on the data output of port A.
        sbiterrb => open,  -- 1-bit output: Status signal to indicate single bit error occurrence on the data output of port B.
        addra => addra(18 downto 7), -- ADDR_WIDTH_A-bit input: Address for port A write and read operations.
        addrb => addrb(18 downto 7), -- ADDR_WIDTH_B-bit input: Address for port B write and read operations.
        clka => i_clk,     -- 1-bit input: Clock signal for port A. Also clocks port B when parameter CLOCKING_MODE is "common_clock".
        clkb => i_clk,     -- 1-bit input: Unused when parameter CLOCKING_MODE is "common_clock".
        dina => dina,      -- WRITE_DATA_WIDTH_A-bit input: Data input for port A write operations.
        dinb => dinb,      -- WRITE_DATA_WIDTH_B-bit input: Data input for port B write operations.
        ena => '1',        -- 1-bit input: Memory enable signal for port A. Must be high on clock cycles when read or write operations are initiated. Pipelined internally.
        enb => '1',        -- 1-bit input: Memory enable signal for port B. Must be high on clock cycles when read or write operations are initiated. Pipelined internally.
        injectdbiterra => '0', -- 1-bit input: Controls double bit error injection on input data when ECC enabled 
        injectdbiterrb => '0', -- 1-bit input: Controls double bit error injection on input data when ECC enabled 
        injectsbiterra => '0', -- 1-bit input: Controls single bit error injection on input data when ECC enabled 
        injectsbiterrb => '0', -- 1-bit input: Controls single bit error injection on input data when ECC enabled 
        regcea => '1',         -- 1-bit input: Clock Enable for the last register stage on the output data path.
        regceb => '1',         -- 1-bit input: Clock Enable for the last register stage on the output data path.
        rsta => '0',           -- 1-bit input: Reset signal for the final port A output register stage. 
        rstb => '0',           -- 1-bit input: Reset signal for the final port B output register stage.
        sleep => '0',          -- 1-bit input: sleep signal to enable the dynamic power saving feature.
        wea => wea,   -- WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-bit input: Write enable vector for port A input data port dina.
        web => web    -- 
    );
    dinb <= (others => '0'); -- only used to reset the memory. 
        
end Behavioral;

