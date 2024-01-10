---------------------------------------------------------------------------------------
--
--  This file was automatically generated from ARGS config file
-- <fpga_name>.fpga.yaml
-- <{list peripheral.yaml used including FPN}>
--  and template file template_bus_top.vhd
--
--  This is the instantiation template for the <lib_name> FPGA design.
--
--
---------------------------------------------------------------------------------------

LIBRARY IEEE, axi4_lib, common_lib, technology_lib;
USE IEEE.std_logic_1164.ALL;
USE IEEE.numeric_std.ALL;
USE axi4_lib.axi4_lite_pkg.ALL;
USE axi4_lib.axi4_full_pkg.ALL;
USE common_lib.common_pkg.ALL;
USE work.<fpga_name>_bus_pkg.ALL;

-------------------------------------------------------------------------------
--                              ENTITY STATEMENT                             --
-------------------------------------------------------------------------------

ENTITY <fpga_name>_noc_bus_top IS
    PORT (
        CLK             : IN STD_LOGIC;
        RST             : IN STD_LOGIC;
        -- single wire for inter noc interface, vivado does some magic to hook up inside the noc.
        S00_INI_0_internoc : in STD_LOGIC_VECTOR ( 0 to 0 );
        MSTR_IN_LITE    : IN t_axi4_lite_miso_arr(0 TO c_nof_lite_slaves-1);
        MSTR_OUT_LITE   : OUT t_axi4_lite_mosi_arr(0 TO c_nof_lite_slaves-1);
        MSTR_IN_FULL    : IN t_axi4_full_miso_arr(0 TO c_nof_full_slaves-1);
        MSTR_OUT_FULL   : OUT t_axi4_full_mosi_arr(0 TO c_nof_full_slaves-1)
    );
END <fpga_name>_noc_bus_top;

ARCHITECTURE RTL OF <fpga_name>_noc_bus_top IS

    ---------------------------------------------------------------------------
    --                         SIGNAL DECLARATIONS                           --
    ---------------------------------------------------------------------------
    SIGNAL rstn : std_logic;

BEGIN
    rstn <= NOT RST;

    <fpga_name>_bd_inst : ENTITY work.<fpga_name>_bd_wrapper
    PORT MAP (
        ACLK    => CLK,
        ARESETN => rstn,
        S00_INI_0_internoc  => S00_INI_0_internoc, -- in STD_LOGIC_VECTOR ( 0 to 0 );
        <{master_interfaces}>
    );

END RTL;