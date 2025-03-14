----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 02/25/2025 03:15:13 PM
-- Design Name: 
-- Module Name: flatten_test - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
--use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity flatten_test is
    Port(
        clk : in std_logic;
        -----------------------------------------------------------
        -- Data in
        i_sof     : in std_logic;
        i_data    : in std_logic_vector(7 downto 0);
        i_valid   : in std_logic;
        i_tvalid : in std_logic;
        i_flatten_disable : in std_logic; -- '1' to disable the flattening filter.
        -- data out
        o_data : out std_logic_vector(15 downto 0);
        o_valid : out std_logic
     );
end flatten_test;

architecture Behavioral of flatten_test is

    component sps_flatten
    port (
        aclk               : in std_logic;
        s_axis_data_tvalid : in std_logic;
        s_axis_data_tready : out std_logic;
        s_axis_data_tdata  : in std_logic_vector(7 downto 0);
        s_axis_config_tvalid : IN STD_LOGIC;
        s_axis_config_tready : OUT STD_LOGIC;
        s_axis_config_tdata : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        m_axis_data_tvalid : out std_logic;
        m_axis_data_tdata  : out std_logic_vector(15 downto 0));
    end component;
    
    signal tdata_full : std_logic_vector(7 downto 0);

begin

    tdata_full <= "0000000" & i_flatten_disable;
    
    si : sps_flatten
    port map (
        aclk => clk,
        s_axis_data_tvalid => i_valid,
        s_axis_data_tready => open,
        s_axis_data_tdata => i_data,
        --
        s_axis_config_tvalid => i_tvalid, -- : IN STD_LOGIC;
        s_axis_config_tready => open, -- : OUT STD_LOGIC;
        s_axis_config_tdata => tdata_full, -- : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        --
        m_axis_data_tvalid => o_valid,
        m_axis_data_tdata => o_data
    );
    
    
end Behavioral;
