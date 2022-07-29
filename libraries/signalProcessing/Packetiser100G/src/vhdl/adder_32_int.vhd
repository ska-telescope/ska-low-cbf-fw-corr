----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: Jan 2021
-- Design Name: Atomic COTS
-- Module Name: adder_32_int
-- Target Devices: Alveo U50 
-- Tool Versions: 2020.1
-- 
-- take a 64 bit number and perform adds on 32 bit chunks.
----------------------------------------------------------------------------------


library IEEE, PSR_Packetiser_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use PSR_Packetiser_lib.ethernet_pkg.ALL;
use PSR_Packetiser_lib.CbfPsrHeader_pkg.ALL;
library UNISIM;
use UNISIM.VComponents.all;

entity adder_32_int is
    Generic (
        INPUT_OUTPUT_WIDTH : integer := 64
    
    );
    Port ( 
        i_clock     : in std_logic;
        i_en        : in std_logic;
        
        i_adder_a   : in std_logic_vector((INPUT_OUTPUT_WIDTH-1) downto 0);
        i_adder_b   : in std_logic_vector((INPUT_OUTPUT_WIDTH-1) downto 0);
        i_begin     : in std_logic;        
    
        o_result    : out std_logic_vector((INPUT_OUTPUT_WIDTH) downto 0);
        o_valid     : out std_logic
    
    
    );
    
    -- prevent optimisation 
    attribute keep_hierarchy : string;
    attribute keep_hierarchy of adder_32_int : entity is "yes";
    
end adder_32_int;

architecture rtl of adder_32_int is
signal clk          : std_logic;

signal adder_a_reg  : std_logic_vector((INPUT_OUTPUT_WIDTH-1) downto 0);
signal adder_b_reg  : std_logic_vector((INPUT_OUTPUT_WIDTH-1) downto 0);

signal temp_result_lower    : std_logic_vector((INPUT_OUTPUT_WIDTH/2) downto 0);
signal temp_result_upper    : std_logic_vector((INPUT_OUTPUT_WIDTH/2) downto 0);
signal temp_result          : std_logic_vector((INPUT_OUTPUT_WIDTH/2) downto 0);

signal output_reg           : std_logic_vector((INPUT_OUTPUT_WIDTH) downto 0);
signal output_valid         : std_logic;

type adder_statemachine is (IDLE, ADD_1, ADD_2, FINISH);
signal adder_sm : adder_statemachine;

begin

clk <= i_clock;

input_reg_proc : process(clk)
begin
    if rising_edge(clk) then
        adder_a_reg <= i_adder_a;
        adder_b_reg <= i_adder_b;
    end if;
end process;

add_proc : process(clk)
begin
    if rising_edge(clk) then
        if i_en = '0' then
            adder_sm        <= IDLE;
            output_valid    <= '0';
        else
        
            case adder_sm is
                when IDLE =>
                    output_valid        <= '0';
                    if i_begin = '1' then
                        adder_sm <= ADD_1;
                    end if;
                
                when ADD_1 =>
                    adder_sm <= ADD_2;
                    temp_result_lower   <= std_logic_vector(unsigned(('0' & adder_a_reg(31 downto 0)))  + unsigned(('0' & adder_b_reg(31 downto 0))));
                    temp_result_upper   <= std_logic_vector(unsigned(('0' & adder_a_reg(63 downto 32))) + unsigned(('0' & adder_b_reg(63 downto 32))));
        
                when ADD_2 =>
                    adder_sm <= FINISH;
                    temp_result         <= std_logic_vector(unsigned(temp_result_upper) + unsigned(zero_dword & temp_result_lower(32)));
                    
                when FINISH =>
                    adder_sm <= IDLE;
                    output_reg          <= temp_result & temp_result_lower(31 downto 0);
                    output_valid        <= '1';
        
                when OTHERS =>
                    adder_sm <= IDLE;
            end case;
        end if;
    end if;
end process;

o_result    <= output_reg;
o_valid     <= output_valid;

end rtl;
