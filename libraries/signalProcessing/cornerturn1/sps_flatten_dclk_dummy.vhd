----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 12/18/2025 09:42:50 PM
-- Module Name: sps_flatten_dclk - Behavioral
-- Description: 
--   dummy version of derippling filter used in the v80, included to prevent vivado simulator complaining when simulating U55 code.
--  
----------------------------------------------------------------------------------
library IEEE, common_lib, ct_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use common_lib.common_pkg.ALL;

entity sps_flatten_dclk is
    Port (
        aclk    : in std_logic;
        aclk_x2 : in std_logic; -- synchronous clock at double the speed of aclk
        s_axis_data_tvalid : in std_logic;
        s_axis_data_tdata  : in std_logic_vector(7 downto 0); --
        s_axis_data_tuser  : in std_logic_vector(0 downto 0); -- 
        --
        s_axis_config_tdata : in std_logic_vector(7 downto 0); -- 3 filters available
        --
        m_axis_data_tvalid : out std_logic; --
        m_axis_data_tdata  : out std_logic_vector(15 downto 0); --
        m_axis_data_tuser  : out std_logic_vector(0 downto 0) -- 
    );
end sps_flatten_dclk;

architecture Behavioral of sps_flatten_dclk is

    
begin
    
    m_axis_data_tvalid <= '0';
    m_axis_data_tdata <= (others => '0');
    m_axis_data_tuser(0) <= '0';
    
end Behavioral;
