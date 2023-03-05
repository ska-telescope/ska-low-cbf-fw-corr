----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 08/19/2022 11:55:56 AM
-- Module Name: dv_tci_mem - Behavioral
-- Description: 
--   Memory for storing the data valid ("DV") and time centroid interval (TCI) for a 
-- cell from the correlator.
-- 
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
Library xpm;
use xpm.vcomponents.all;

entity dv_tci_mem is
    port(
        i_clk : in std_logic;
        -- data input
        i_DV : in std_logic_vector(7 downto 0);
        i_TCI : in std_logic_vector(7 downto 0);
        i_wrEn : in std_logic;
        i_wrAddr : in std_logic_vector(7 downto 0); -- 256 elements in a correlation cell
        -- data output, 2 cycle latency.
        i_rdAddr : in std_logic_vector(3 downto 0);
        o_dout : out std_logic_vector(255 downto 0)
    );
end dv_tci_mem;

architecture Behavioral of dv_tci_mem is
    
    signal din : std_logic_vector(15 downto 0);
    type t_wren is array(15 downto 0) of std_logic_vector(0 downto 0);
    signal wrEn : t_wrEn;
    signal wrAddr : std_logic_vector(3 downto 0);
    type t_dout is array(15 downto 0) of std_logic_vector(15 downto 0);
    signal dout : t_dout;
    
begin

    process(i_clk)
    begin
        if rising_edge(i_clk) then
            din <= i_TCI & i_DV;
            wrAddr <= i_wrAddr(7 downto 4);
            for m in 0 to 15 loop
                if (unsigned(i_wrAddr(3 downto 0)) = m) then
                    wrEn(m) <= "1";
                else
                    wrEn(m) <= "0";
                end if;
            end loop;
            
            for m in 0 to 15 loop
                o_dout(m*16 + 15 downto (m*16)) <= dout(m);
            end loop;
        end if;
    end process;
    
    
    memgeni : for i in 0 to 15 generate
    
        xpm_memory_sdpram_inst : xpm_memory_sdpram
        generic map (
            ADDR_WIDTH_A => 4,               -- DECIMAL
            ADDR_WIDTH_B => 4,               -- DECIMAL
            AUTO_SLEEP_TIME => 0,            -- DECIMAL
            BYTE_WRITE_WIDTH_A => 16,        -- DECIMAL
            CASCADE_HEIGHT => 0,             -- DECIMAL
            CLOCKING_MODE => "common_clock", -- String
            ECC_MODE => "no_ecc",            -- String
            MEMORY_INIT_FILE => "none",      -- String
            MEMORY_INIT_PARAM => "0",        -- String
            MEMORY_OPTIMIZATION => "true",   -- String
            MEMORY_PRIMITIVE => "distributed", -- String
            MEMORY_SIZE => 256,              -- DECIMAL; 16 deep x 16 bit wide = 256 bits
            MESSAGE_CONTROL => 0,            -- DECIMAL
            READ_DATA_WIDTH_B => 16,         -- DECIMAL
            READ_LATENCY_B => 1,             -- DECIMAL
            READ_RESET_VALUE_B => "0",       -- String
            RST_MODE_A => "SYNC",            -- String
            RST_MODE_B => "SYNC",            -- String
            SIM_ASSERT_CHK => 0,             -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
            USE_EMBEDDED_CONSTRAINT => 0,    -- DECIMAL
            USE_MEM_INIT => 1,               -- DECIMAL
            USE_MEM_INIT_MMI => 0,           -- DECIMAL
            WAKEUP_TIME => "disable_sleep",  -- String
            WRITE_DATA_WIDTH_A => 16,        -- DECIMAL
            WRITE_MODE_B => "read_first",    -- String
            WRITE_PROTECT => 1               -- DECIMAL
        ) port map (
            dbiterrb => open,        -- 1-bit output: Status signal to indicate double bit error occurrence on the data output of port B.
            doutb => dout(i),        -- READ_DATA_WIDTH_B-bit output: Data output for port B read operations.
            sbiterrb => open,        -- 1-bit output: Status signal to indicate single bit error occurrence on the data output of port B.
            addra => wrAddr,         -- ADDR_WIDTH_A-bit input: Address for port A write operations.
            addrb => i_rdAddr,       -- ADDR_WIDTH_B-bit input: Address for port B read operations.
            clka => i_clk,           -- 1-bit input: Clock signal for port A. Also clocks port B when parameter CLOCKING_MODE is "common_clock".
            clkb => i_clk,           -- 1-bit input: Clock signal for port B when parameter CLOCKING_MODE is "independent_clock". Unused when parameter CLOCKING_MODE is "common_clock".
            dina => din,             -- WRITE_DATA_WIDTH_A-bit input: Data input for port A write operations.
            ena => '1',              -- 1-bit input: Memory enable signal for port A. Must be high on clock cycles when write operations are initiated. Pipelined internally.
            enb => '1',              -- 1-bit input: Memory enable signal for port B. Must be high on clock cycles when read operations are initiated. Pipelined internally.
            injectdbiterra => '0',   -- 1-bit input: Controls double bit error injection on input data when ECC enabled
            injectsbiterra => '0',   -- 1-bit input: Controls single bit error injection on input data when ECC enabled 
            regceb => '1',           -- 1-bit input: Clock Enable for the last register stage on the output data path.
            rstb => '0',             -- 1-bit input: Reset signal for the final port B output register stage. 
            sleep => '0',            -- 1-bit input: sleep signal to enable the dynamic power saving feature.
            wea => wrEn(i)           -- WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-bit input: Write enable vector for port A input data port dina. 1 bit wide when word-wide writes are used.
        );
        
    end generate;

end Behavioral;
