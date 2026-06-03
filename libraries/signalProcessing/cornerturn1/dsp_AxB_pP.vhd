----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 12/19/2025 02:20:08 PM
-- Module Name: dsp_dotproduct - Behavioral
-- Description: 
--  Instantiate a versal DSP58 configured to use the dot product function
-- 
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
Library UNISIM;
use UNISIM.vcomponents.all;

entity dsp_AxB_pP is
    port(
        clk : in std_logic;
        i_data18 : in std_logic_vector(17 downto 0); -- 18 bit signed value
        i_data8_0 : in std_logic_vector(7 downto 0); -- 8 bit signed value
        i_data8_1 : in std_logic_vector(7 downto 0); -- 8 bit signed value
        i_accumulate : in std_logic;  -- high to add to the previous dotproduct result, otherwise clear the previous result
        o_product : out std_logic_vector(27 downto 0) -- Accumulated sum of i_data18 * (i_data8_0 + i_data8_1)
    );
end dsp_AxB_pP;

architecture Behavioral of dsp_AxB_pP is

    signal P : std_logic_vector(57 downto 0);
    signal A : std_logic_vector(33 downto 0);
    signal ALUMODE : std_logic_vector(3 downto 0);
    signal CARRYINSEL : std_logic_vector(2 downto 0);
    signal INMODE : std_logic_vector(4 downto 0);
    signal NEGATE : std_logic_vector(2 downto 0);
    signal OPMODE : std_logic_vector(8 downto 0);
    signal PCIN : std_logic_vector(57 downto 0);
    
begin

    -- DSP58: 58-bit Multi-Functional Arithmetic Block
    --        Versal HBM Series
    -- Xilinx HDL Language Template, version 2025.1
    DSP58_inst : DSP58
    generic map (
        -- Feature Control Attributes: Data Path Selection
        AMULTSEL => "A",      -- Selects A input to multiplier (A, AD)
        A_INPUT => "DIRECT",  -- Selects A input source, "DIRECT" (A port) or "CASCADE" (ACIN port)
        BMULTSEL => "B",      -- Selects B input to multiplier (AD, B)
        B_INPUT => "DIRECT",  -- Selects B input source, "DIRECT" (B port) or "CASCADE" (BCIN port)
        DSP_MODE => "INT24",   -- INT8 for dot product. Configures DSP to a particular mode of operation. Set to INT24 for legacy mode.
        PREADDINSEL => "A",                -- Selects input to pre-adder (A, B)
        RND => "00" & X"00000000000000",   -- Rounding Constant
        USE_MULT => "MULTIPLY",            -- Select multiplier usage (DYNAMIC, MULTIPLY, NONE)
        USE_SIMD => "ONE58",               -- SIMD selection (FOUR12, ONE58, TWO24)
        USE_WIDEXOR => "FALSE",            -- Use the Wide XOR function (FALSE, TRUE)
        XORSIMD => "XOR24_34_58_116",      -- Mode of operation for the Wide XOR (XOR12_22, XOR24_34_58_116)
        -- Pattern Detector Attributes: Pattern Detection Configuration
        AUTORESET_PATDET => "NO_RESET",      -- NO_RESET, RESET_MATCH, RESET_NOT_MATCH
        AUTORESET_PRIORITY => "RESET",       -- Priority of AUTORESET vs. CEP (CEP, RESET).
        MASK => "00" & X"ffffffffffffff",    -- 58-bit mask value for pattern detect (1=ignore)
        PATTERN => "00" & X"00000000000000", -- 58-bit pattern match for pattern detect
        SEL_MASK => "MASK",                -- C, MASK, ROUNDING_MODE1, ROUNDING_MODE2
        SEL_PATTERN => "PATTERN",          -- Select pattern value (C, PATTERN)
        USE_PATTERN_DETECT => "NO_PATDET", -- Enable pattern detect (NO_PATDET, PATDET)
        -- Programmable Inversion Attributes: Specifies built-in programmable inversion on specific pins
        IS_ALUMODE_INVERTED => "0000",     -- Optional inversion for ALUMODE
        IS_CARRYIN_INVERTED => '0',        -- Optional inversion for CARRYIN
        IS_CLK_INVERTED => '0',            -- Optional inversion for CLK
        IS_INMODE_INVERTED => "00000",     -- Optional inversion for INMODE
        IS_NEGATE_INVERTED => "000",       -- Optional inversion for NEGATE
        IS_OPMODE_INVERTED => "000000000", -- Optional inversion for OPMODE
        IS_RSTALLCARRYIN_INVERTED => '0',  -- Optional inversion for RSTALLCARRYIN
        IS_RSTALUMODE_INVERTED => '0',     -- Optional inversion for RSTALUMODE
        IS_RSTA_INVERTED => '0',           -- Optional inversion for RSTA
        IS_RSTB_INVERTED => '0',           -- Optional inversion for RSTB
        IS_RSTCTRL_INVERTED => '0',        -- Optional inversion for STCONJUGATE_A
        IS_RSTC_INVERTED => '0',           -- Optional inversion for RSTC
        IS_RSTD_INVERTED => '0',           -- Optional inversion for RSTD
        IS_RSTINMODE_INVERTED => '0',      -- Optional inversion for RSTINMODE
        IS_RSTM_INVERTED => '0',           -- Optional inversion for RSTM
        IS_RSTP_INVERTED => '0',           -- Optional inversion for RSTP
        -- Register Control Attributes: Pipeline Register Configuration
        ACASCREG => 1,                     -- Number of pipeline stages between A/ACIN and ACOUT (0-2)
        ADREG => 1,                        -- Pipeline stages for pre-adder (0-1)
        ALUMODEREG => 1,                   -- Pipeline stages for ALUMODE (0-1)
        AREG => 1,                         -- Pipeline stages for A (0-2)
        BCASCREG => 1,                     -- Number of pipeline stages between B/BCIN and BCOUT (0-2)
        BREG => 1,                         -- Pipeline stages for B (0-2)
        CARRYINREG => 1,                   -- Pipeline stages for CARRYIN (0-1)
        CARRYINSELREG => 1,                -- Pipeline stages for CARRYINSEL (0-1)
        CREG => 1,                         -- Pipeline stages for C (0-1)
        DREG => 1,                         -- Pipeline stages for D (0-1)
        INMODEREG => 1,                    -- Pipeline stages for INMODE (0-1)
        MREG => 1,                         -- Multiplier pipeline stages (0-1)
        OPMODEREG => 1,                    -- Pipeline stages for OPMODE (0-1)
        PREG => 1,                         -- Number of pipeline stages for P (0-1)
        RESET_MODE => "SYNC"               -- Selection of synchronous or asynchronous reset. (ASYNC, SYNC).
    ) port map (
        -- Cascade outputs: Cascade Ports
        ACOUT => open,          -- 34-bit output: A port cascade
        BCOUT => open,          -- 24-bit output: B cascade
        CARRYCASCOUT => open,   -- 1-bit output: Cascade carry
        MULTSIGNOUT => open,    -- 1-bit output: Multiplier sign cascade
        PCOUT => open,          -- 58-bit output: Cascade output
        -- Control outputs: Control Inputs/Status Bits
        OVERFLOW => open,       -- 1-bit output: Overflow in add/acc
        PATTERNBDETECT => open, -- 1-bit output: Pattern bar detect
        PATTERNDETECT => open,  -- 1-bit output: Pattern detect
        UNDERFLOW => open,      -- 1-bit output: Underflow in add/acc
        -- Data outputs: Data Ports
        CARRYOUT => open,       -- 4-bit output: Carry
        P => P,                 -- 58-bit output: Primary data
        XOROUT => open,         -- 8-bit output: XOR data
        -- Cascade inputs: Cascade Ports
        ACIN => (others => '0'),    -- 34-bit input: A cascade data
        BCIN => (others => '0'),    -- 24-bit input: B cascade
        CARRYCASCIN => '0',         -- 1-bit input: Cascade carry
        MULTSIGNIN => '0',          -- 1-bit input: Multiplier sign cascade
        PCIN => PCIN,    -- 58-bit input: P cascade
        -- Control inputs: Control Inputs/Status Bits
        ALUMODE => ALUMODE,       -- 4-bit input: ALU control
        CARRYINSEL => CARRYINSEL, -- 3-bit input: Carry select
        CLK => CLK,           -- 1-bit input: Clock
        INMODE => INMODE,     -- 5-bit input: INMODE control
        NEGATE => NEGATE,     -- 3-bit input: Negates the input of the multiplier
        OPMODE => OPMODE,     -- 9-bit input: Operation mode
        -- Data inputs: Data Ports
        A => A,               -- 34-bit input: A data
        B => i_data8,         -- 24-bit input: B data
        C => (others => '0'), -- 58-bit input: C data
        CARRYIN => '0',       -- 1-bit input: Carry-in
        D => (others => '0'), -- 27-bit input: D data
        -- Reset/Clock Enable inputs: Reset/Clock Enable Inputs
        ASYNC_RST => '0',     -- 1-bit input: Asynchronous reset for all registers.
        CEA1 => '1',          -- 1-bit input: Clock enable for 1st stage AREG
        CEA2 => '1',          -- 1-bit input: Clock enable for 2nd stage AREG
        CEAD => '1',          -- 1-bit input: Clock enable for ADREG
        CEALUMODE => '1',     -- 1-bit input: Clock enable for ALUMODE
        CEB1 => '1',          -- 1-bit input: Clock enable for 1st stage BREG
        CEB2 => '1',          -- 1-bit input: Clock enable for 2nd stage BREG
        CEC => '1',           -- 1-bit input: Clock enable for CREG
        CECARRYIN => '1',     -- 1-bit input: Clock enable for CARRYINREG
        CECTRL => '1',        -- 1-bit input: Clock enable for OPMODEREG and CARRYINSELREG
        CED => '1',           -- 1-bit input: Clock enable for DREG
        CEINMODE => '1',      -- 1-bit input: Clock enable for INMODEREG
        CEM => '1',           -- 1-bit input: Clock enable for MREG
        CEP => '1',           -- 1-bit input: Clock enable for PREG
        RSTA => '0',          -- 1-bit input: Reset for AREG
        RSTALLCARRYIN => '0', -- 1-bit input: Reset for CARRYINREG
        RSTALUMODE => '0',    -- 1-bit input: Reset for ALUMODEREG
        RSTB => '0',          -- 1-bit input: Reset for BREG
        RSTC => '0',          -- 1-bit input: Reset for CREG
        RSTCTRL => '0',       -- 1-bit input: Reset for OPMODEREG and CARRYINSELREG
        RSTD => '0',          -- 1-bit input: Reset for DREG and ADREG
        RSTINMODE => '0',     -- 1-bit input: Reset for INMODE register
        RSTM => '0',          -- 1-bit input: Reset for MREG
        RSTP => '0'           -- 1-bit input: Reset for PREG
    );
    
    A(26 downto 0) <= i_data9;
    A(33 downto 27) <= "0000000";
    PCIN(57 downto 0) <= (others => '0');
    
    ALUMODE <= "0000"; -- configure post-multiplier adder to just add up 
    CARRYINSEL <= "000"; -- selects CARRYIN, which is tied to zero.
    INMODE <= "00000";
    NEGATE <= "000";
    OPMODE(8 downto 7) <= "00";  -- selects 0 for the W multiplexer output
    OPMODE(1 downto 0) <= "01";  -- selects multiplier for the X multiplexer output
    OPMODE(3 downto 2) <= "01";  -- selects multiplier for the Y multiplexer output
    
    -- OPMODE 6:4 selects the Z multiplexer output, here either 0 or P
    -- Document AM004 seems to say that opmode(6:4) = "010" should be used to accumulate the result
    -- in the P register, but it only works with opmode(6:4) = "100", which am004 says is for 
    -- "MACC extend only", which refers to 116 bit accumulation using two DSPs
    OPMODE(4) <= '0';
    OPMODE(5) <= '0';
    process(clk)
    begin
        if rising_Edge(clk) then
            OPMODE(6) <= i_accumulate;  -- one pipeline stage is needed to align with the input data.
        end if;
    end process;
    o_dotproduct <= P(23 downto 0);

end Behavioral;
