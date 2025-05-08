----------------------------------------------------------------------------------
-- Company: CSIRO - CASS 
-- Engineer: David Humphrey
-- 
-- Create Date: 15.11.2018 14:15:15
-- Module Name: fb_DSP - Behavioral
-- Description: 
--  FIR filter.
--  Input is assumed staggered by 1 clock (e.g. sample 9 arrives 9 clocks after sample 1), so that 
--  the adders in the DSPs can be used for the adder tree in the FIR filter.
--
-- From the DSP guide, UG579, on designing for low power (page 59) -
--  * Use the M register.
--  * Use the cascade paths between DSPs
--  * Put operands in the most significant bits, tie the lower bits to zero.
--  * If a multiplier input is a constant, it should go on the B input. (although this does not apply here, since inputs are not constants)
--
-- Latency is 3 clocks from the last data sample (or TAPS + 3 clocks from the first data sample).
----------------------------------------------------------------------------------
library IEEE, common_lib, filterbanks_lib, correlator_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use common_lib.common_pkg.all;
use correlator_lib.target_fpga_pkg.ALL;

entity fb_DSP25 is
    generic (
        TAPS : integer := 12  -- The module instantiates this number of DSP
    );
    port(
        clk : in std_logic;
        data_i : in t_slv_16_arr((TAPS-1) downto 0);
        coef_i : in t_slv_18_arr((TAPS-1) downto 0);
        data_o : out std_logic_vector(24 downto 0)
    );
end fb_DSP25;

architecture Behavioral of fb_DSP25 is

    -- DSP with 3 clock latency.
    -- Function is pcout = p = A*B + PCIN
    -- pcout is the dedicated routing to the next DSP in the column. It can only be connected to PCIN in the next DSP.
    -- p is the normal output available to the rest of the fabric.
    -- Tcl:
    --  create_ip -name xbip_dsp48_macro -vendor xilinx.com -library ip -version 3.0 -module_name DSP_AxB_plus_PCIN -dir C:/projects/perentie/xilinx_test_projects/filterbank_ip
    --  set_property -dict [list CONFIG.Component_Name {DSP_AxB_plus_PCIN} CONFIG.instruction1 {A*B+PCIN} CONFIG.pipeline_options {Expert} CONFIG.areg_4 {false} CONFIG.breg_4 {false} CONFIG.a_width {27} CONFIG.has_pcout {true} CONFIG.areg_3 {true} CONFIG.breg_3 {true} CONFIG.creg_3 {false} CONFIG.creg_4 {false} CONFIG.creg_5 {false} CONFIG.mreg_5 {true} CONFIG.preg_6 {true} CONFIG.d_width {18} CONFIG.a_binarywidth {0} CONFIG.b_width {18} CONFIG.b_binarywidth {0} CONFIG.concat_width {48} CONFIG.concat_binarywidth {0} CONFIG.c_binarywidth {0} CONFIG.pcin_binarywidth {0}] [get_ips DSP_AxB_plus_PCIN]
    component DSP_AxB_plus_PCIN
    port (
        clk   : in std_logic;
        pcin  : in std_logic_vector(47 downto 0);
        a     : in std_logic_vector(26 downto 0);
        b     : in std_logic_vector(17 downto 0);
        pcout : out std_logic_vector(47 downto 0);
        p     : out std_logic_vector(47 downto 0));
    end component;
    
    -- DSP with 3 clock latency, first in the chain has no pcin
    -- Tcl:
    --  create_ip -name xbip_dsp48_macro -vendor xilinx.com -library ip -version 3.0 -module_name DSP_AxB -dir C:/projects/perentie/xilinx_test_projects/filterbank_ip
    --  set_property -dict [list CONFIG.Component_Name {DSP_AxB} CONFIG.instruction1 {A*B} CONFIG.pipeline_options {Expert} CONFIG.areg_4 {false} CONFIG.breg_4 {false} CONFIG.a_width {27} CONFIG.has_pcout {true} CONFIG.areg_3 {true} CONFIG.breg_3 {true} CONFIG.creg_3 {false} CONFIG.creg_4 {false} CONFIG.creg_5 {false} CONFIG.mreg_5 {true} CONFIG.preg_6 {true} CONFIG.d_width {18} CONFIG.a_binarywidth {0} CONFIG.b_width {18} CONFIG.b_binarywidth {0} CONFIG.concat_width {48} CONFIG.concat_binarywidth {0} CONFIG.c_binarywidth {0} CONFIG.pcin_binarywidth {0} CONFIG.p_full_width {45} CONFIG.p_width {45} CONFIG.p_binarywidth {0}] [get_ips DSP_AxB]
    component DSP_AxB
    port (
        clk   : in std_logic;
        a     : in std_logic_vector(26 downto 0);
        b     : in std_logic_vector(17 downto 0);
        pcout : out std_logic_vector(47 downto 0);
        p     : out std_logic_vector(44 downto 0));
    end component;
    
    -- Versal versions have a 58 bit wide accumulator.
    component DSP_AxB_versal
    port (
        clk   : in std_logic;
        a     : in std_logic_vector(26 downto 0);
        b     : in std_logic_vector(17 downto 0);
        pcout : out std_logic_vector(57 downto 0);
        p     : out std_logic_vector(44 downto 0));
    end component;

    component DSP_AxB_plus_PCIN_versal
    port (
        clk   : in std_logic;
        pcin  : in std_logic_vector(57 downto 0);
        a     : in std_logic_vector(26 downto 0);
        b     : in std_logic_vector(17 downto 0);
        pcout : out std_logic_vector(57 downto 0);
        p     : out std_logic_vector(57 downto 0));
    end component;
    
    signal pc : t_slv_48_arr((TAPS-1) downto 0);
    TYPE t_slv_58_arr      IS ARRAY (INTEGER RANGE <>) OF STD_LOGIC_VECTOR(57 DOWNTO 0);
    signal pc58 : t_slv_58_arr((TAPS-1) downto 0);
    signal dataFull : t_slv_27_arr((TAPS-1) downto 0);
    signal finalSum : std_logic_vector(57 downto 0);
    
    signal intPart : std_logic_vector(15 downto 0);
    signal fracPart : std_logic_vector(8 downto 0);
    
begin

usplus_gen : IF (C_TARGET_DEVICE = "U55") GENERATE
    -- First filter tap (no pcin)
    dsp_first : DSP_AxB
    port map (
        clk  => clk,
        a    => dataFull(0), -- in(26:0)
        b    => coef_i(0),   -- in(17:0)
        pcout => pc(0),      -- out(47:0)
        p     => open        -- out(44:0)
    );
    
    dataFull(0) <= data_i(0) & "00000000000";
    
    -- Middle filter taps
    DSPGen : for i in 1 to (TAPS - 2) generate
        
        dataFull(i) <= data_i(i) & "00000000000";
        
        dspinst : DSP_AxB_plus_PCIN
        port map (
            clk  => clk,
            pcin => pc(i-1),     -- in(47:0)
            a    => dataFull(i), -- in(26:0)
            b    => coef_i(i),   -- in(17:0)
            pcout => pc(i),      -- out(47:0)
            p     => open        -- out(47:0)
        );
        
    end generate;
    
    -- Last filter tap
    dataFull(TAPS - 1) <= data_i(TAPS - 1) & "00000000000";
    dsp_last : DSP_AxB_plus_PCIN
    port map (
        clk  => clk,
        pcin => pc(TAPS-2),         -- in(47:0)
        a    => dataFull(TAPS - 1), -- in(26:0)
        b    => coef_i(TAPS - 1),   -- in(17:0)
        pcout => open,              -- out(47:0)
        p     => finalSum(47 downto 0)           -- out(47:0)
    );
END GENERATE;

versal_gen : IF (C_TARGET_DEVICE = "V80") GENERATE
    -- First filter tap (no pcin)
    dsp_first : DSP_AxB_versal
    port map (
        clk  => clk,
        a    => dataFull(0), -- in(26:0)
        b    => coef_i(0),   -- in(17:0)
        pcout => pc58(0),      -- out(47:0)
        p     => open        -- out(44:0)
    );
    
    dataFull(0) <= data_i(0) & "00000000000";
    
    -- Middle filter taps
    DSPGen : for i in 1 to (TAPS - 2) generate
        
        dataFull(i) <= data_i(i) & "00000000000";
        
        dspinst : DSP_AxB_plus_PCIN_versal
        port map (
            clk  => clk,
            pcin => pc58(i-1),     -- in(47:0)
            a    => dataFull(i), -- in(26:0)
            b    => coef_i(i),   -- in(17:0)
            pcout => pc58(i),      -- out(47:0)
            p     => open        -- out(47:0)
        );
        
    end generate;
    
    -- Last filter tap
    dataFull(TAPS - 1) <= data_i(TAPS - 1) & "00000000000";
    dsp_last : DSP_AxB_plus_PCIN_versal
    port map (
        clk  => clk,
        pcin => pc58(TAPS-2),         -- in(47:0)
        a    => dataFull(TAPS - 1), -- in(26:0)
        b    => coef_i(TAPS - 1),   -- in(17:0)
        pcout => open,              -- out(47:0)
        p     => finalSum           -- out(47:0)
    );
END GENERATE;
    
    -- FIR scaling :
    --  The deripple filter scales up by a factor of x128 (maximum output from the deripple filter is about x160)
    --  So largest input data is ~ 160 * 128 = 20480
    --  Largest filter tap is about 76000
    --  Largest possible output of a single multiplication is 76000 * 20480 = 1.56 * 10^9
    --  data_i is additionally scaled up by a factor of 2048 (zero padding above to get "dataFull" from "data_i")
    --  From SPS data to the output of this module, rms scaling :
    --   = (sps data) * (128 (deripple)) * (65536 (this FIR filter)) * (2048 (scale up to left-align)) / (2^19 final scaling below) 
    --   = (sps data) * 2^15
    --
    --  Note : The maximum value for the SPS data is 127, peak values for the filters can scale up by a factor of about 1.5,
    --         so the peak output value is about 1.5 * 127 * 2^15, which fit in the 25 bit output, so it cannot saturate.
    --  
    
    data_o <= finalSum(43 downto 19);
    
end Behavioral;
