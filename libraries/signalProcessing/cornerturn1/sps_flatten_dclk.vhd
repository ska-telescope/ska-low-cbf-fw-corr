----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 12/18/2025 09:42:50 PM
-- Module Name: sps_flatten_dclk - Behavioral
-- Description: 
--   derippling filter, with DSPs running at double the clock speed to reduce DSP usage.
-- 
----------------------------------------------------------------------------------
library IEEE, common_lib;
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
        s_axis_config_tdata : in std_logic_vector(1 downto 0); -- 3 filters available
        --
        m_axis_data_tvalid : out std_logic; --
        m_axis_data_tdata  : out std_logic_vector(15 downto 0); --
        m_axis_data_tuser  : out std_logic
    );
end sps_flatten_dclk;

architecture Behavioral of sps_flatten_dclk is

    -- constants to hold half the filter + the central value
    -- Filters are assumed to be symmetric
    type ftap_t is array(24 downto 0) of integer;
    constant ftaps0 : ftap_t := (0,  0,  0,   0,  0,   0,   0,   0,  0,    0,    0,    0,    0,    0,   0,     0,    0,     0,    0,     0,    0,     0,    0,     0, 65536);
    constant ftaps1 : ftap_t := (3, -6, 10, -16, 24, -34,  46, -61, 98, -128,  173, -229,  300, -387, 488,  -621, 1881, -1705, 2110, -2498, 2861, -3172, 3411, -3562, 69172);
    constant ftaps2 : ftap_t := (1, -2,  4,  -7, 12, -21,  36, -51, 78, -111,  155, -213,  284, -362, 652, -1263, 1209, -1653, 1944, -2288, 2583, -2843, 3040, -3165, 68751);
    -- 10 DSP total :           | 1 DSP                  |1 DSP       |1 DSP      |1 DSP      |1 DSP     |1 DSP       |1 DSP       |1 DSP       |1 DSP       |1 DSP        |
    --                          | double rate            |single rate |double rate|
    --                          | use 8x9bit dot product |dot product |           |
    
    signal delay_line : t_slv_8_arr(48 downto 0);
    signal dsum : t_slv_9_arr(24 downto 0);
    
begin
    
    process(aclk)
    begin
        if rising_edge(aclk) then
            if s_axis_data_tvalid = '1' then
                delay_line(0) <= s_axis_data_tdata;
                delay_line(48 downto 1) <= delay_line(47 downto 0);
            end if;
            
            
        end if;
    end process;

    -- symmetric filter, add values on opposite sides of the center
    dsum_gen : for i in 0 to 23 generate
        dsum(i) <= std_logic_vector(resize(signed(delay_line(i)),9) + resize(signed(delay_line(48-i)),9));
    end generate;
    dsum(24) <= std_logic_vector(resize(signed(delay_line(24)),9)); -- center value
    
end Behavioral;
