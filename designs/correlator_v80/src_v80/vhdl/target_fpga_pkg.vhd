LIBRARY ieee;
USE ieee.std_logic_1164.all;

PACKAGE target_fpga_pkg IS
    constant C_TARGET_DEVICE        : STRING := "V80";
    constant C_ARGS_RD_LATENCY      : INTEGER := 2;
end target_fpga_pkg;
