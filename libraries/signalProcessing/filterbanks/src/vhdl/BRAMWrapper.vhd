----------------------------------------------------------------------------------
-- Company: CSIRO - CASS
-- Engineer: David Humphey
-- 
-- Create Date: 04.12.2018 10:34:03
-- Module Name: URAMWrapper - Behavioral
-- Description: 
--   Wrapper to instantiate a single simple dual port BRAM with initialisation,
-- since versal doesn't have a bram IP block.
-- 
-- Used to replace this IP block:
-- create_ip -name blk_mem_gen -vendor xilinx.com -library ip -module_name CFB_ROM1
-- set_property -dict [
--   list CONFIG.Component_Name {CFB_ROM1} 
--   CONFIG.Memory_Type {True_Dual_Port_RAM} 
--   CONFIG.Write_Width_A {18} 
--   CONFIG.Write_Depth_A {4096} 
--   CONFIG.Read_Width_A {18} 
--   CONFIG.Enable_A {Always_Enabled} 
--   CONFIG.Write_Width_B {18} 
--   CONFIG.Read_Width_B {18} 
--   CONFIG.Enable_B {Always_Enabled} 
--   CONFIG.Register_PortB_Output_of_Memory_Primitives {true} 
--   CONFIG.Load_Init_File {true} 
--   CONFIG.Coe_File "$coepath/correlatorFIRTaps1.coe" 
--   CONFIG.Port_B_Clock {100} 
--   CONFIG.Port_B_Write_Rate {50} 
--   CONFIG.Port_B_Enable_Rate {100} 
--   CONFIG.Collision_Warnings {GENERATE_X_ONLY} 
--   CONFIG.Disable_Collision_Warnings {true} 
--   CONFIG.Disable_Out_of_Range_Warnings {true}] [get_ips CFB_ROM1]
--
-- Key parameters
--  - 2 clock read latency from both ports
--  - (18 bits wide) x (4096 deep)
--  - initialised with a text file.
--  
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
Library xpm;
use xpm.vcomponents.all;
--use IEEE.NUMERIC_STD.ALL;

entity BRAMWrapper is
    generic(
        g_INIT_FILE : string
    );
    port(
        -- Port A, register reads and writes 
        clka  : in std_logic; -- => FIRTapClk,
        wea   : in std_logic_vector(0 downto 0); -- => FIRTapsWE(0),
        addra : in std_logic_vector(11 downto 0); -- => FIRTapRegAddr,
        dina  : in std_logic_vector(17 downto 0); -- => FIRTapRegWrData,
        douta : out std_logic_vector(17 downto 0); --=> FIRTapRegRdData(0),
        -- Port B, read by the filterbank. 
        clkb  : in std_logic; -- => clk,
        addrb : in std_logic_vector(11 downto 0); -- => romAddrDel(0),
        doutb : out std_logic_vector(17 downto 0) -- => coef_o(0)
    );
end BRAMWrapper;

architecture Behavioral of BRAMWrapper is

    signal weSLV    : std_logic_vector(0 downto 0);
    signal dinb     : std_logic_vector(17 downto 0);

begin

    weSLV <= wea;
    
    -- xpm_memory_tdpram: True Dual Port RAM
    -- Xilinx Parameterized Macro, version 2023.2
    xpm_memory_tdpram_inst : xpm_memory_tdpram
    generic map (
        ADDR_WIDTH_A => 12,         -- DECIMAL
        ADDR_WIDTH_B => 12,         -- DECIMAL
        AUTO_SLEEP_TIME => 0,       -- DECIMAL
        BYTE_WRITE_WIDTH_A => 18,   -- DECIMAL
        BYTE_WRITE_WIDTH_B => 18,   -- DECIMAL
        CASCADE_HEIGHT => 0,        -- DECIMAL
        CLOCKING_MODE => "independent_clock", -- String
        ECC_BIT_RANGE => "7:0",     -- String
        ECC_MODE => "no_ecc",       -- String
        ECC_TYPE => "none",         -- String
        IGNORE_INIT_SYNTH => 0,     -- DECIMAL, 0 = use initialisation for both synth and for simulation.
        MEMORY_INIT_FILE => g_INIT_FILE,      -- String
        MEMORY_INIT_PARAM => "",        -- empty string (="") indicates use of MEMORY_INIT_FILE generic
        MEMORY_OPTIMIZATION => "true", -- String
        MEMORY_PRIMITIVE => "block",   -- String
        MEMORY_SIZE => 73728,          -- DECIMAL, 18 * 4096 = 73728
        MESSAGE_CONTROL => 0,      -- DECIMAL
        RAM_DECOMP => "auto",      -- String
        READ_DATA_WIDTH_A => 18,   -- DECIMAL
        READ_DATA_WIDTH_B => 18,   -- DECIMAL
        READ_LATENCY_A => 2,       -- DECIMAL
        READ_LATENCY_B => 2,       -- DECIMAL
        READ_RESET_VALUE_A => "0", -- String
        READ_RESET_VALUE_B => "0", -- String
        RST_MODE_A => "SYNC",      -- String
        RST_MODE_B => "SYNC",      -- String
        SIM_ASSERT_CHK => 0,       -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_EMBEDDED_CONSTRAINT => 0, -- DECIMAL
        USE_MEM_INIT => 0,         -- DECIMAL
        USE_MEM_INIT_MMI => 0,     -- DECIMAL
        WAKEUP_TIME => "disable_sleep",  -- String
        WRITE_DATA_WIDTH_A => 18,  -- DECIMAL
        WRITE_DATA_WIDTH_B => 18,  -- DECIMAL
        WRITE_MODE_A => "no_change", -- String
        WRITE_MODE_B => "no_change", -- String
        WRITE_PROTECT => 1           -- DECIMAL
     ) port map (
        dbiterra => open,   -- 1-bit output: Status signal to indicate double bit error occurrence
        dbiterrb => open,   -- 1-bit output: Status signal to indicate double bit error occurrence
        douta => douta,     -- READ_DATA_WIDTH_A-bit output: Data output for port A read operations.
        doutb => doutb,     -- READ_DATA_WIDTH_B-bit output: Data output for port B read operations.
        sbiterra => open,   -- 1-bit output: Status signal to indicate single bit error occurrence
        sbiterrb => open,   -- 1-bit output: Status signal to indicate single bit error occurrence
        addra => addra,     -- ADDR_WIDTH_A-bit input: Address for port A write and read operations.
        addrb => addrb,     -- ADDR_WIDTH_B-bit input: Address for port B write and read operations.
        clka => clka,       -- 1-bit input: Clock signal for port A. Also clocks port B when parameter CLOCKING_MODE is "common_clock".
        clkb => clkb,       -- 1-bit input: Clock signal for port B when parameter CLOCKING_MODE is "independent_clock".
        dina => dina,       -- WRITE_DATA_WIDTH_A-bit input: Data input for port A write operations.
        dinb => dinb,       -- WRITE_DATA_WIDTH_B-bit input: Data input for port B write operations.
        ena => '1',         -- 1-bit input: Memory enable signal for port A.
        enb => '1',         -- 1-bit input: Memory enable signal for port B. 
        injectdbiterra => '0', -- 1-bit input: Controls double bit error injection 
        injectdbiterrb => '0', -- 1-bit input: Controls double bit error injection 
        injectsbiterra => '0', -- 1-bit input: Controls single bit error injection 
        injectsbiterrb => '0', -- 1-bit input: Controls single bit error injection 
        regcea => '1',         -- 1-bit input: Clock Enable for the last register stage on the output data path.
        regceb => '1',         -- 1-bit input: Clock Enable for the last register stage on the output data path.
        rsta => '0',           -- 1-bit input: Reset signal for the final port A output register stage. 
        rstb => '0',           -- 1-bit input: Reset signal for the final port B output register stage.
        sleep => '0',          -- 1-bit input: sleep signal to enable the dynamic power saving feature.
        wea => weSLV,          -- WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-bit input: Write enable vector for port A input data port dina.
        web => "0"             -- WRITE_DATA_WIDTH_B/BYTE_WRITE_WIDTH_B-bit input: Write enable vector for port B input data port dinb.
    );    
   
end Behavioral;
