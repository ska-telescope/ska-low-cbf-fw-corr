---------------------------------------------------------------------------------------
--
--  This file was automatically generated from ARGS config file <lib>.peripheral.yaml
--  and template file template_reg_axi4.vho
--
--  This is the instantiation template for the <lib_name> register slave.
--
--
---------------------------------------------------------------------------------------
LIBRARY <lib>_lib;
USE <lib>_lib.<lib_name>_reg_pkg.ALL;

ENTITY <lib>_lib.<lib_name>_reg 
    PORT MAP (
        CLK            <tabs>=> ,
        RST            <tabs>=> ,
        noc_wren       <tabs>=> ,
        noc_rden       <tabs>=> ,
        noc_wr_adr     <tabs>=> ,
        noc_wr_dat     <tabs>=> ,
        noc_rd_adr     <tabs>=> ,
        noc_rd_dat     <tabs>=> ,
        <{slave_ports}>             

        );
