LIBRARY ieee;
USE ieee.std_logic_1164.all;

PACKAGE version_pkg IS
    constant C_FIRMWARE_MAJOR_VERSION        : std_logic_vector(15 downto 0) := x"0000";
    constant C_FIRMWARE_MINOR_VERSION        : std_logic_vector(15 downto 0) := x"0001";
    constant C_FIRMWARE_PATCH_VERSION        : std_logic_vector(15 downto 0) := x"0000";                                              
end version_pkg;
