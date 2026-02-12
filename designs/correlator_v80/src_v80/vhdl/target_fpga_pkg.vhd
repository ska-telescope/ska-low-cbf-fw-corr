LIBRARY ieee, common_lib;
USE ieee.std_logic_1164.all;
USE common_lib.common_pkg.ALL;

PACKAGE target_fpga_pkg IS
    constant C_TARGET_DEVICE        : STRING := "V80";
    constant C_ARGS_RD_LATENCY      : INTEGER := 2;
    
    -- base address of the HBM that each interface talks to for the V80
    -- The V80 contains 32GB of HBM
    -- Base address for this is 0x40_0000_0000  (From Xilinx Doc PG313)
    -- so e.g.                  0x40_4000_0000  = base +1 GByte
    --                          0x41_0000_0000  = base +4 GBytes
    --                          0x47_C000_0000  = base +31 GBytes
    --
    -- HBM memory used in the V80 :
    --  Module                        HBM memory size    Address within 32 GByte space
    --  ------                        ---------------    -----------------------------
    --  CT1                           9 GBytes           16 to 25 GBytes
    --  Statistics                    1 GByte            25 to 26 GBytes
    --  CT2                           16 GBytes          0 to 16  GBytes
    --  Correlator Visibility buffer  6 GBytes           26 to 32 GBytes
    -- 
    -- Only bits 63:28 of these constants are used. i.e. the base address is specified in 256 MByte blocks.
    constant c_V80_HBM_BASE_CT1_ADDR   : std_logic_vector(63 downto 0) :=  x"0000004400000000";   -- 16 GBytes
    constant c_V80_HBM_BASE_STATISTICS : std_logic_vector(63 downto 0) :=  x"0000004640000000";   -- 25 GBytes
    constant c_V80_HBM_ILA_ADDR        : std_logic_vector(63 downto 0) :=  x"0000004660000000";   -- 25.5 GByte
    constant c_V80_HBM_BASE_CT2_ADDR   : std_logic_vector(63 downto 0) :=  x"0000004000000000";   -- 0 GBytes = Start of HBM memory
    constant c_V80_HBM_BASE_VIS_ADDR   : t_slv_64_arr(5 downto 0)      := (x"0000004680000000",   -- 26 Gbytes
                                                                           x"00000046C0000000",   -- 27 GBytes
                                                                           x"0000004700000000",   -- 28 GBytes
                                                                           x"0000004740000000",   -- 29 GBytes
                                                                           x"0000004780000000",   -- 30 GBytes
                                                                           x"00000047C0000000");  -- 31 GBytes
    -- two HBM interfaces to write SPS data into the HBM from the 200GE
    -- Place these in SLR1 near the ethernet MAC. Writes over the VNOC get high bandwidth even from a different SLR.
    constant c_V80_HBM_SPS_DECODE_VNOC0 : boolean := True;
    constant c_V80_HBM_SPS_DECODE_VNOC1 : boolean := True;
    
    -- SPS statistics
    constant c_V80_STATISTICS_VNOC : boolean := True;
    
    -- Two HBM interfaces for CT1 to read data from the HBM to send to the filterbanks 
    constant c_V80_HBM_CT1_READ_VNOC0 : boolean := false;
    constant c_V80_HBM_CT1_READ_VNOC1 : boolean := false;
    
    constant c_V80_HBM_BASE_CT2_WRITE0_VNOC : boolean := false; -- true to use VNOC, false to use dedicated HBM interfaces at the top of SLR0
    constant c_V80_HBM_BASE_CT2_WRITE1_VNOC : boolean := false;
    -- HBM ILA
    constant c_V80_HBM_ILA_VNOC : boolean := false;

    -- up to 6 correlator instances
    -- Correlator read from CT2
    constant c_CORRELATOR_VNOC : t_boolean_arr(5 downto 0) := (true, true, true, true, true, false);
    -- Correlator visibility write to HBM
    constant c_VIS_VNOC : t_boolean_arr(5 downto 0) := (true, true, true, true, true, false);
    -- Correlator visibility read from HBM
    constant c_VIS_RD_VNOC : t_boolean_arr(5 downto 0) := (true, true, true, true, true, true);
    -- correlator visibility read from HBM
    constant c_V80_HBM_BASE_CT2_READ_VNOC : boolean := true; -- true to use VNOC, false to use dedicated HBM interfaces at the top of SLR0
    
end target_fpga_pkg;
