----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 06/04/2023 09:09:03 AM
-- Module Name: poly_cur_val_bram - Behavioral
-- Description: 
--  Wrapper for a simple dual port BRAM, 512 deep by 64 bits wide
-- 
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
Library xpm;
use xpm.vcomponents.all;

entity poly_cur_val_bram is
    Port(
        clk : in std_logic;
        -- Write side
        wrAddr : in std_logic_vector(8 downto 0);
        wrEn : in std_logic;
        wrData : in std_logic_vector(63 downto 0);
        -- Read side, 3 clock latency
        rdAddr : in std_logic_vector(8 downto 0);
        rdData : out std_logic_vector(63 downto 0)
     );
end poly_cur_val_bram;

architecture Behavioral of poly_cur_val_bram is

    signal wrEn_slv : std_logic_vector(0 downto 0);

begin

    wrEn_slv(0) <= wrEn;

    -- Xilinx Parameterized Macro, version 2022.2
    xpm_memory_sdpram_inst : xpm_memory_sdpram
    generic map (
        ADDR_WIDTH_A => 9,               -- DECIMAL
        ADDR_WIDTH_B => 9,               -- DECIMAL
        AUTO_SLEEP_TIME => 0,            -- DECIMAL
        BYTE_WRITE_WIDTH_A => 64,        -- DECIMAL
        CASCADE_HEIGHT => 0,             -- DECIMAL
        CLOCKING_MODE => "common_clock", -- String
        ECC_MODE => "no_ecc",            -- String
        MEMORY_INIT_FILE => "none",      -- String
        MEMORY_INIT_PARAM => "0",        -- String
        MEMORY_OPTIMIZATION => "true",   -- String
        MEMORY_PRIMITIVE => "auto",      -- String
        MEMORY_SIZE => 32768,            -- DECIMAL 64*512 = 32768 
        MESSAGE_CONTROL => 0,            -- DECIMAL
        READ_DATA_WIDTH_B => 64,         -- DECIMAL
        READ_LATENCY_B => 3,             -- DECIMAL
        READ_RESET_VALUE_B => "0",       -- String
        RST_MODE_A => "SYNC",            -- String
        RST_MODE_B => "SYNC",            -- String
        SIM_ASSERT_CHK => 0,             -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_EMBEDDED_CONSTRAINT => 0,    -- DECIMAL
        USE_MEM_INIT => 1,               -- DECIMAL
        USE_MEM_INIT_MMI => 0,           -- DECIMAL
        WAKEUP_TIME => "disable_sleep",  -- String
        WRITE_DATA_WIDTH_A => 64,        -- DECIMAL
        WRITE_MODE_B => "no_change",     -- String
        WRITE_PROTECT => 1               -- DECIMAL
    ) port map (
        clkb  => clk,
        addrb => rdAddr,  -- ADDR_WIDTH_B-bit input: Address for port B read operations.
        doutb => rdData,  -- READ_DATA_WIDTH_B-bit output: Data output for port B read operations.
        --
        clka  => clk,      
        addra => wrAddr,      -- ADDR_WIDTH_A-bit input: Address for port A write operations
        dina  => wrData,      -- WRITE_DATA_WIDTH_A-bit input: Data input for port A write operations            
        wea   => wrEn_slv,
        --
        ena => '1',
        enb => '1',
        injectdbiterra => '0',
        injectsbiterra => '0',
        regceb => '1',
        rstb => '0',
        sleep => '0',
        dbiterrb => open,
        sbiterrb => open
   );

end Behavioral;
