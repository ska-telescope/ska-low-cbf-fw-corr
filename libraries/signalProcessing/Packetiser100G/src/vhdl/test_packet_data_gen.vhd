----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: 13.10.2021
-- Design Name: 
-- Module Name: test_packet_data_gen - rtl
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


library IEEE, xpm, PSR_Packetiser_lib, common_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use PSR_Packetiser_lib.ethernet_pkg.ALL;
use PSR_Packetiser_lib.CbfPsrHeader_pkg.ALL;
use xpm.vcomponents.all;
USE common_lib.common_pkg.ALL;
library technology_lib;
USE technology_lib.tech_mac_100g_pkg.ALL;


entity test_packet_data_gen is
    Generic (
        g_INSTANCE                      : INTEGER := 0;
        g_DEBUG_ILA                     : BOOLEAN := FALSE
    );    
    Port ( 
        i_clk                           : in std_logic;
        i_rst                           : in std_logic;
    
        i_enable_test_generator         : in std_logic;
        i_enabe_limited_runs            : in std_logic;
        
        i_packet_generator_runs         : in std_logic_vector(31 downto 0);
        i_packet_generator_time_between : in std_logic_vector(31 downto 0);
        i_packet_generator_no_of_beams  : in std_logic_vector(3 downto 0);
        
        i_data_to_player_rdy            : in std_logic;
        
        o_test_beam_number              : out std_logic_vector(3 downto 0);     -- This is created for test data as the P4 routes on it.
        o_test_data                     : out std_logic_vector(511 downto 0);
        o_test_data_wr                  : out std_logic
    );
end test_packet_data_gen;

architecture rtl of test_packet_data_gen is
COMPONENT ila_0
PORT (
    clk : IN STD_LOGIC;
    probe0 : IN STD_LOGIC_VECTOR(191 DOWNTO 0));
END COMPONENT;

-- 512 bits = 16 x 32 bit dwords
constant test_data_dword_default  : t_slv_32_arr(15 downto 0) := (x"00000001", x"00000002", x"00000003", x"00000004", x"00000005", x"00000006", x"00000007", x"00000008",
                                                                  x"00000009", x"0000000A", x"0000000B", x"0000000C", x"0000000D", x"0000000E", x"0000000F", x"00000010");
                                                                  
constant test_data_default_z      : t_slv_32_arr(15 downto 0) := (x"00000000", x"00000001", x"00000002", x"00000003", x"00000004", x"00000005", x"00000006", x"00000007", 
                                                                  x"00000008", x"00000009", x"0000000A", x"0000000B", x"0000000C", x"0000000D", x"0000000E", x"0000000F");                                                                  
                                                                  
constant test_data_dword_b_pat    : t_slv_32_arr(15 downto 0) := (x"03020100", x"07060504", x"0B0A0908", x"0F0E0D0C", x"13121110", x"17161514", x"1B1A1918", x"1F1E1D1C",
                                                                  x"23222120", x"27262524", x"2B2A2928", x"2F2E2D2C", x"33323130", x"37363534", x"3B3A3938", x"3F3E3D3C");

-- 512 bits = 16 x 32 bit dwords
constant test_data_dword_layout   : t_slv_32_arr(15 downto 0) := (x"00000004", x"00000003", x"00000002", x"00000001", x"00000008", x"00000007", x"00000006", x"00000005",
                                                                  x"0000000C", x"0000000B", x"0000000A", x"00000009", x"00000010", x"0000000F", x"0000000E", x"0000000D");
                                                                                                                                    
signal test_data_dword          : t_slv_32_arr(15 downto 0);

signal test_count               : integer := 0;

signal test_cycles_between      : std_logic_vector(31 downto 0);
signal test_byte                : std_logic_vector(7 downto 0);
signal test_dword_lower         : std_logic_vector(31 downto 0) := x"00000002";
signal test_dword_upper         : std_logic_vector(31 downto 0) := x"00000001";
signal test_word_loop           : std_logic_vector(15 downto 0);
signal test_runs                : std_logic_vector(31 downto 0);
signal test_beam_number         : std_logic_vector(3 downto 0);

signal test_data                : std_logic_vector(511 downto 0);
signal test_data_d1             : std_logic_vector(511 downto 0);
signal test_data_d2             : std_logic_vector(511 downto 0);
signal test_data_dout           : std_logic_vector(511 downto 0);
signal test_data_valid          : std_logic;
signal test_data_valid_d1       : std_logic;
signal test_data_valid_d2       : std_logic;
signal test_data_valid_d3       : std_logic;

type test_mode_statemachine is (IDLE, RUN);
signal test_mode_sm : test_mode_statemachine;

signal enable_test_generator    : std_logic;
signal enable_limited_runs      : std_logic;

signal packet_generator_runs            : std_logic_vector(31 downto 0);
signal packet_generator_time_between    : std_logic_vector(31 downto 0);
signal packet_generator_no_of_beams     : std_logic_vector(3 downto 0);

signal ila_test_count           : std_logic_vector(7 downto 0);

signal test_data_remain         : std_logic_vector(79 downto 0);

begin


ctrl_proc : process(i_clk)
begin
    if rising_edge(i_clk) then
        enable_test_generator   <= i_enable_test_generator;
        enable_limited_runs     <= i_enabe_limited_runs;
        
        packet_generator_runs           <= i_packet_generator_runs;
        packet_generator_time_between   <= i_packet_generator_time_between;
        packet_generator_no_of_beams    <= i_packet_generator_no_of_beams;
    end if;
end process;


o_test_data         <= test_data_dout;
o_test_data_wr      <= test_data_valid_d3;
o_test_beam_number  <= test_beam_number;

test_gen : for i in 0 to 15 generate

    test_data_proc : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if test_mode_sm = IDLE then
                test_data_dword(i)     <= test_data_dword_layout(i);
            elsif test_data_valid = '1' then
                test_data_dword(i)  <= std_logic_vector(unsigned(test_data_dword(i)) + x"00000010");
            end if;
        end if;
    end process;
end generate;

-- send ~~10 packets per second.
test_proc : process(i_clk)
begin
    if rising_edge(i_clk) then
        if enable_test_generator = '0' then
            test_count          <= 0;
            test_cycles_between <= zero_dword;
            test_data           <= zero_512;
            test_data_valid     <= '0';
            test_data_valid_d1  <= '0';
            test_data_valid_d2  <= '0';
            test_data_valid_d3  <= '0';
            test_byte           <= one_byte;
            test_word_loop      <= x"0001";
            test_runs           <= X"00000000";
            test_beam_number    <= x"0";        -- this will emulate 16 beams
            test_mode_sm        <= IDLE;
        else
           
           test_data_valid_d1 <= test_data_valid;
           test_data_valid_d2 <= test_data_valid_d1;
           test_data_valid_d3 <= test_data_valid_d2;
           
           test_data_d1(127 downto 0)   <= test_data_remain             & test_data(127 downto 80); 
           test_data_d1(255 downto 128) <= test_data(79 downto 0)       & test_data(255 downto 208);
           test_data_d1(383 downto 256) <= test_data(207 downto 128)    & test_data(383 downto 336);
           test_data_d1(511 downto 384) <= test_data(335 downto 256)    & test_data(511 downto 464);
           
           test_data_remain(79 downto 0)<= test_data(463 downto 384);
           
           
           
           
           test_data_dout      <= test_data_d1;--test_data(431 downto 0) & test_data_d1(511 downto 432);
           
            case test_mode_sm is
                when IDLE =>
                    if (test_cycles_between = packet_generator_time_between) then
                        if ((enable_limited_runs = '0')) OR ((test_runs < packet_generator_runs) AND enable_limited_runs = '1') then
                            test_count          <= 0;
                            test_cycles_between <= zero_dword;
                            test_mode_sm        <= RUN;
                        end if;
                    elsif i_data_to_player_rdy = '1' then
                        test_cycles_between <= std_logic_vector(unsigned(test_cycles_between) + 1);
                    end if;
                    
                
                when RUN =>
                    test_count              <= test_count + 1;

                    -- test pattern generate
                    -- 512 bit/ 64 byte wide test data, for PST this is 6192 bytes = 96.75, so 97 writes.
                    -- 97 + sacle data = 98 writes
                    if test_data_valid = '1' then
                        test_data           <=  test_beam_number & test_word_loop(11 downto 0) & test_data_dword(0)(15 downto 0) & 
                                                test_beam_number & test_word_loop(11 downto 0) & test_data_dword(1)(15 downto 0) &
                                                test_beam_number & test_word_loop(11 downto 0) & test_data_dword(2)(15 downto 0) &
                                                test_beam_number & test_word_loop(11 downto 0) & test_data_dword(3)(15 downto 0) &
                                                test_beam_number & test_word_loop(11 downto 0) & test_data_dword(4)(15 downto 0) &
                                                test_beam_number & test_word_loop(11 downto 0) & test_data_dword(5)(15 downto 0) &
                                                test_beam_number & test_word_loop(11 downto 0) & test_data_dword(6)(15 downto 0) &
                                                test_beam_number & test_word_loop(11 downto 0) & test_data_dword(7)(15 downto 0) &
                                                test_beam_number & test_word_loop(11 downto 0) & test_data_dword(8)(15 downto 0) &
                                                test_beam_number & test_word_loop(11 downto 0) & test_data_dword(9)(15 downto 0) &
                                                test_beam_number & test_word_loop(11 downto 0) & test_data_dword(10)(15 downto 0) &
                                                test_beam_number & test_word_loop(11 downto 0) & test_data_dword(11)(15 downto 0) &
                                                test_beam_number & test_word_loop(11 downto 0) & test_data_dword(12)(15 downto 0) &
                                                test_beam_number & test_word_loop(11 downto 0) & test_data_dword(13)(15 downto 0) &
                                                test_beam_number & test_word_loop(11 downto 0) & test_data_dword(14)(15 downto 0) &
                                                test_beam_number & test_word_loop(11 downto 0) & test_data_dword(15)(15 downto 0);
--                        test_data           <=  test_data_dword(0)(31 downto 0) & 
--                                                test_data_dword(1)(31 downto 0) &
--                                                test_data_dword(2)(31 downto 0) &
--                                                test_data_dword(3)(31 downto 0) &
--                                                test_data_dword(4)(31 downto 0) &
--                                                test_data_dword(5)(31 downto 0) &
--                                                test_data_dword(6)(31 downto 0) &
--                                                test_data_dword(7)(31 downto 0) &
--                                                test_data_dword(8)(31 downto 0) &
--                                                test_data_dword(9)(31 downto 0) &
--                                                test_data_dword(10)(31 downto 0) &
--                                                test_data_dword(11)(31 downto 0) &
--                                                test_data_dword(12)(31 downto 0) &
--                                                test_data_dword(13)(31 downto 0) &
--                                                test_data_dword(14)(31 downto 0) &
--                                                test_data_dword(15)(31 downto 0);                                                
                    else
                        test_data           <= x"FFFFFFFF005547EE" & x"FFFFFFFF005547EE" & zero_128 & zero_128 & zero_128; -- test leading meta data.
                    end if;
                    
                    -- 6192 bytes = 774 writes
                    -- With a leading write for scale data so 775.
                    if (test_count = 10) then
                        test_data_valid     <= '1';
                    elsif (test_count = 107) then
                        test_data_valid     <= '0';
                    end if;
                    
                    if (test_count = 115) then
                        if packet_generator_no_of_beams = test_beam_number then
                            test_beam_number    <= zero_nibble;
                        else
                            test_beam_number    <= std_logic_vector(unsigned(test_beam_number) + 1);
                        end if;
                    end if;
                    
                    if (test_count = 120) then
                        test_mode_sm        <= IDLE;
                        test_count          <= 0;
                        test_runs           <= std_logic_vector(unsigned(test_runs) + 1);
                        
                        if test_beam_number = x"0" then
                            test_word_loop  <= std_logic_vector(unsigned(test_word_loop) + 1);
                        end if;
                    end if;
                    
                    
                when OTHERS =>
                    test_mode_sm <= IDLE;
            
            end case;
        end if;
    end if;
end process;

ila_test_count <= std_logic_vector(to_unsigned(test_count,8));

test_packet_ila : IF g_DEBUG_ILA GENERATE

    packetiser_ila : ila_0
    port map (
        clk                     => i_clk, 
        probe0(0)               => test_data_valid, 
        probe0(32 downto 1)     => test_cycles_between, 
        probe0(40 downto 33)    => ila_test_count, 
        probe0(44 downto 41)    => test_beam_number,
        probe0(45)              => test_data_valid_d1, 
        probe0(46)              => enable_test_generator,
        probe0(191 downto 47)  => (others => '0')
    );
    
END GENERATE;    
    
end rtl;
