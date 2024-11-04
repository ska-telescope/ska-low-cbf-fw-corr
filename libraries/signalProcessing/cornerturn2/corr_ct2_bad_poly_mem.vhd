----------------------------------------------------------------------------------
-- Company:  CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 28/10/2024
-- Module Name: corr_ct2_bad_poly_mem - Behavioral
-- Description: 
--  Two 256 deep x 1 bit wide distributed memories
--  
----------------------------------------------------------------------------------
library IEEE, xpm;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use xpm.vcomponents.all;

entity corr_ct2_bad_poly_mem is
    port (
        clk : in std_logic;
        -- First memory
        wr_addr0 : in std_logic_vector(7 downto 0);
        wr_en0 : in std_logic;
        wr_data0 : in std_logic;
        rd_addr0 : in std_logic_vector(7 downto 0);
        rd_data0 : out std_logic; -- 2 clock read latency
        -- Second memory
        wr_addr1 : in std_logic_vector(7 downto 0);
        wr_en1 : in std_logic;
        wr_data1 : in std_logic;
        rd_addr1 : in std_logic_vector(7 downto 0);
        rd_data1 : out std_logic  -- 2 clock read latency
    );
end corr_ct2_bad_poly_mem;

architecture Behavioral of corr_ct2_bad_poly_mem is
    
    signal rd_data0_slv : std_logic_vector(0 downto 0);
    signal rd_data1_slv : std_logic_vector(0 downto 0);
    signal wr_data0_slv : std_logic_vector(0 downto 0);
    signal wr_data1_slv : std_logic_vector(0 downto 0);
    signal wr_en0_slv, wr_en1_slv : std_logic_vector(0 downto 0);
    
begin
    
    xpm_memory_sdpram_inst : xpm_memory_sdpram
    generic map (
        ADDR_WIDTH_A => 8,               -- DECIMAL
        ADDR_WIDTH_B => 8,               -- DECIMAL
        AUTO_SLEEP_TIME => 0,            -- DECIMAL
        BYTE_WRITE_WIDTH_A => 1,         -- DECIMAL
        CASCADE_HEIGHT => 0,             -- DECIMAL
        CLOCKING_MODE => "common_clock", -- String
        ECC_MODE => "no_ecc",            -- String
        MEMORY_INIT_FILE => "none",      -- String
        MEMORY_INIT_PARAM => "0",        -- String
        MEMORY_OPTIMIZATION => "true",   -- String
        MEMORY_PRIMITIVE => "distributed", -- String
        MEMORY_SIZE => 256,              -- DECIMAL
        MESSAGE_CONTROL => 0,            -- DECIMAL
        READ_DATA_WIDTH_B => 1,          -- DECIMAL
        READ_LATENCY_B => 2,             -- DECIMAL
        READ_RESET_VALUE_B => "0",       -- String
        RST_MODE_A => "SYNC",            -- String
        RST_MODE_B => "SYNC",            -- String
        SIM_ASSERT_CHK => 1,             -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_EMBEDDED_CONSTRAINT => 0,    -- DECIMAL
        USE_MEM_INIT => 1,               -- DECIMAL
        USE_MEM_INIT_MMI => 0,           -- DECIMAL
        WAKEUP_TIME => "disable_sleep",  -- String
        WRITE_DATA_WIDTH_A => 1,         -- DECIMAL
        WRITE_MODE_B => "read_first",     -- String
        WRITE_PROTECT => 1               -- DECIMAL
    ) port map (
        dbiterrb => open,   -- 1-bit output: Status signal to indicate double bit error occurrence
        doutb => rd_data0_slv,  -- READ_DATA_WIDTH_B-bit output: Data output for port B read operations.
        sbiterrb => open,   -- 1-bit output: Status signal to indicate single bit error occurrence
        addra => wr_addr0,  -- ADDR_WIDTH_A-bit input: Address for port A write operations.
        addrb => rd_addr0,  -- ADDR_WIDTH_B-bit input: Address for port B read operations.
        clka => clk,        -- 1-bit input: Clock signal for port A. Also clocks port B when parameter CLOCKING_MODE is "common_clock".
        clkb => clk,        -- 1-bit input: Clock signal for port B 
        dina => wr_data0_slv,   -- WRITE_DATA_WIDTH_A-bit input: Data input for port A write operations.
        ena => '1',         -- 1-bit input: Memory enable signal for port A.
        enb => '1',         -- 1-bit input: Memory enable signal for port B. 
        injectdbiterra => '0', -- 1-bit input: Controls double bit error injection on input data 
        injectsbiterra => '0', -- 1-bit input: Controls single bit error injection 
        regceb => '1',      -- 1-bit input: Clock Enable for the last register stage on the output data path.
        rstb => '0',        -- 1-bit input: Reset signal for the final port B output register stage. 
        sleep => '0',       -- 1-bit input: sleep signal to enable the dynamic power saving feature.
        wea => wr_en0_slv   -- WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-bit input: Write enable vector for port A input data port dina. 
    );
    
    rd_data0 <= rd_data0_slv(0);
    wr_data0_slv(0) <= wr_data0;
    wr_en0_slv(0) <= wr_en0;
    
    
    xpm_memory_sdpram2_inst : xpm_memory_sdpram
    generic map (
        ADDR_WIDTH_A => 8,               -- DECIMAL
        ADDR_WIDTH_B => 8,               -- DECIMAL
        AUTO_SLEEP_TIME => 0,            -- DECIMAL
        BYTE_WRITE_WIDTH_A => 1,         -- DECIMAL
        CASCADE_HEIGHT => 0,             -- DECIMAL
        CLOCKING_MODE => "common_clock", -- String
        ECC_MODE => "no_ecc",            -- String
        MEMORY_INIT_FILE => "none",      -- String
        MEMORY_INIT_PARAM => "0",        -- String
        MEMORY_OPTIMIZATION => "true",   -- String
        MEMORY_PRIMITIVE => "distributed", -- String
        MEMORY_SIZE => 256,              -- DECIMAL
        MESSAGE_CONTROL => 0,            -- DECIMAL
        READ_DATA_WIDTH_B => 1,          -- DECIMAL
        READ_LATENCY_B => 2,             -- DECIMAL
        READ_RESET_VALUE_B => "0",       -- String
        RST_MODE_A => "SYNC",            -- String
        RST_MODE_B => "SYNC",            -- String
        SIM_ASSERT_CHK => 0,             -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_EMBEDDED_CONSTRAINT => 0,    -- DECIMAL
        USE_MEM_INIT => 1,               -- DECIMAL
        USE_MEM_INIT_MMI => 0,           -- DECIMAL
        WAKEUP_TIME => "disable_sleep",  -- String
        WRITE_DATA_WIDTH_A => 1,         -- DECIMAL
        WRITE_MODE_B => "read_first",     -- String
        WRITE_PROTECT => 1               -- DECIMAL
    ) port map (
        dbiterrb => open,   -- 1-bit output: Status signal to indicate double bit error occurrence
        doutb => rd_data1_slv, -- READ_DATA_WIDTH_B-bit output: Data output for port B read operations.
        sbiterrb => open,   -- 1-bit output: Status signal to indicate single bit error occurrence
        addra => wr_addr1,  -- ADDR_WIDTH_A-bit input: Address for port A write operations.
        addrb => rd_addr1,  -- ADDR_WIDTH_B-bit input: Address for port B read operations.
        clka => clk,        -- 1-bit input: Clock signal for port A. Also clocks port B when parameter CLOCKING_MODE is "common_clock".
        clkb => clk,        -- 1-bit input: Clock signal for port B 
        dina => wr_data1_slv,   -- WRITE_DATA_WIDTH_A-bit input: Data input for port A write operations.
        ena => '1',         -- 1-bit input: Memory enable signal for port A.
        enb => '1',         -- 1-bit input: Memory enable signal for port B. 
        injectdbiterra => '0', -- 1-bit input: Controls double bit error injection on input data 
        injectsbiterra => '0', -- 1-bit input: Controls single bit error injection 
        regceb => '1',      -- 1-bit input: Clock Enable for the last register stage on the output data path.
        rstb => '0',        -- 1-bit input: Reset signal for the final port B output register stage. 
        sleep => '0',       -- 1-bit input: sleep signal to enable the dynamic power saving feature.
        wea => wr_en1_slv   -- WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-bit input: Write enable vector for port A input data port dina. 
    );
    
    rd_data1 <= rd_data1_slv(0);
    wr_data1_slv(0) <= wr_data1;
    wr_en1_slv(0) <= wr_en1;
    
end Behavioral;
