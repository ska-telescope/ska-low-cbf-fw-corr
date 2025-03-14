----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 02/04/2025 01:56:24 PM
-- Design Name: 
-- Module Name: flatten_tb - Behavioral
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
use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity flatten_tb is
--  Port ( );
end flatten_tb;

architecture Behavioral of flatten_tb is

    signal clk100 : std_logic := '0';

    component sps_flatten
    port (
        aclk               : in std_logic;
        s_axis_data_tvalid : in std_logic;
        s_axis_data_tready : out std_logic;
        s_axis_data_tdata  : in std_logic_vector(7 downto 0);
        s_axis_config_tvalid : in  std_logic;
        s_axis_config_tready : out std_logic;
        s_axis_config_tdata  : in  std_logic_vector(7 downto 0);
        m_axis_data_tvalid : out std_logic;
        m_axis_data_tdata  : out std_logic_vector(15 downto 0));
    end component;
    
    signal ccount : std_logic_vector(15 downto 0) := x"0000";
    signal tready : std_logic;
    signal din : std_logic_vector(7 downto 0);
    signal valid_out : std_logic;
    signal dout : std_logic_vector(15 downto 0);
    signal valid_in : std_logic;
    signal config_tdata : std_logic_vector(7 downto 0);
    signal config_tready, config_tvalid : std_logic;
    
begin
    
    clk100 <= not clk100 after 5 ns;
    
    process(clk100)
    begin
        if rising_Edge(clk100) then
            ccount <= std_logic_vector(unsigned(ccount) + 1);
            if ccount(7 downto 0) = "10000000" then
                config_tvalid <= '1';
            else
                config_tvalid <= '0';
            end if;
        end if;
    end process;
    
    din <= "01000000" when ccount(8 downto 0) = "100000000" else (others => '0');
    valid_in <= ccount(8);
    
    config_tdata <= "00000000";
    --config_tvalid <= '0';
    
    flatteni : sps_flatten
    port map (
        aclk => clk100,
        s_axis_data_tvalid => valid_in,
        s_axis_data_tready => tready,
        s_axis_data_tdata => din,
        s_axis_config_tvalid => config_tvalid,     -- IN STD_LOGIC;
        s_axis_config_tready => config_tready,  -- OUT STD_LOGIC;
        s_axis_config_tdata  => config_tdata, --  IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        m_axis_data_tvalid => valid_out,
        m_axis_data_tdata => dout
    );
    
    
    
end Behavioral;
