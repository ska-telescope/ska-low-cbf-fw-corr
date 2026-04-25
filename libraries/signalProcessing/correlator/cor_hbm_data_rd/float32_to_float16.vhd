----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: March 2026
-- Design Name: 
-- Module Name: float32_to_float16
-- Description: 
-- 
-- 
-- Encoding procedure : 
--
--     Start with the single precision floating point value
--     Divide by 2^14. This can be implemented by subtracting 14 from the exponent of the single precision value (bits 30:23 in the single precision number)
--     Use standard IP to convert single precision to half precision
--
-- Wrap to zero if the subtraction goes negative.
--
-- Used fixed length IP.
--
-- 32 bit floating point is 1S, 8E, 23M
--
----------------------------------------------------------------------------------

library IEEE, correlator_lib, common_lib, spead_lib, signal_processing_common;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
Library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;
USE common_lib.common_pkg.ALL;
library xpm;
use xpm.vcomponents.all;


entity float32_to_float16 is
    generic (
        g_SIM               : BOOLEAN := FALSE
    );
    port (
        clk                 : in STD_LOGIC;
        reset               : in STD_LOGIC;
        
        i_valid             : in STD_LOGIC;
        i_data_in           : in STD_LOGIC_VECTOR(31 downto 0);

        ------------------------------------------------------

        o_valid             : out STD_LOGIC;
        o_data_out          : out STD_LOGIC_VECTOR(15 downto 0)
    );
end float32_to_float16;

architecture Behavioral of float32_to_float16 is

COMPONENT float32_float16_ip
    PORT (
        aclk                    : IN STD_LOGIC;
        s_axis_a_tvalid         : IN STD_LOGIC;
        s_axis_a_tdata          : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
        m_axis_result_tvalid    : OUT STD_LOGIC;
        m_axis_result_tdata     : OUT STD_LOGIC_VECTOR(15 DOWNTO 0) 
    );
END COMPONENT;

signal data_in          : STD_LOGIC_VECTOR(31 downto 0);
signal data_del1        : STD_LOGIC_VECTOR(31 downto 0);
signal data_del2        : STD_LOGIC_VECTOR(31 downto 0);
signal float_conv_q     : STD_LOGIC_VECTOR(15 downto 0);

signal data_valid       : STD_LOGIC_VECTOR(7 downto 0) := x"00";

signal sim_data         : t_slv_16_arr(2 downto 0);
signal sim_data_valid   : STD_LOGIC_VECTOR(2 downto 0);

begin

p_data_reg : process(clk)
begin
    if rising_edge(clk) then
        ----------------------
        -- 1
        data_in             <= i_data_in;
        data_valid(0)       <= i_valid;

        ----------------------
        -- 2 - subtract 14
        -- Sign
        data_del1(31)           <= data_in(31);
        data_valid(1)           <= data_valid(0);

        -- Exp
        -- if less than 14 this will wrap, zero out.
        if (unsigned(data_in(30 downto 23)) <= 13) then
            data_del1(30 downto 23) <= x"00";
        else
            data_del1(30 downto 23) <= std_logic_vector(unsigned(data_in(30 downto 23)) - 14);
        end if;

        -- Man
        data_del1(22 downto 0)  <= data_in(22 downto 0);

        ----------------------
        -- 3
        data_del2               <= data_del1;
        data_valid(2)           <= data_valid(1);

        -- x
        o_data_out              <= float_conv_q;
        o_valid                 <= data_valid(3);
    end if;
end process;

--gen_conv : if (NOT g_SIM) GENERATE
    i_float_conv : float32_float16_ip
        PORT MAP (
            aclk                    => clk,
            s_axis_a_tvalid         => data_valid(2),
            s_axis_a_tdata          => data_del2,
            m_axis_result_tvalid    => data_valid(3),
            m_axis_result_tdata     => float_conv_q
        );
--END GENERATE;

gen_sim_conv : if (g_SIM) GENERATE

p_sim_reg : process(clk)
begin
    if rising_edge(clk) then
        sim_data(0)         <= data_del2(15 downto 0);
        sim_data_valid(0)   <= data_valid(2);
        
        sim_data(1)         <= sim_data(0);
        sim_data_valid(1)   <= sim_data_valid(0);
        
        float_conv_q        <= sim_data(1);
        data_valid(3)       <= sim_data_valid(1);
    
    end if;
end process;
    
END GENERATE;

end Behavioral;
