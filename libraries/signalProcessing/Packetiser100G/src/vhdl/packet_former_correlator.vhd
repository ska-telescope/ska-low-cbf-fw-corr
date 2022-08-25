----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: May 2022
-- Design Name: Atomic COTS
-- Module Name: packet_former_correlator
-- Target Devices: Alveo U55 
-- Tool Versions: 2021.2
-- 
-- Ethernet Frame + IP header + UDP Header + UDP payload as per 512 bit interface with
-- these will map to the SOSI interface differently. lower byte to upper byte of 128 bit interface and continue that pattern.


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

library UNISIM;
use UNISIM.VComponents.all;

entity packet_former_correlator is
    Generic (
        g_INSTANCE                  : INTEGER := 0;
        g_DEBUG_ILA                 : BOOLEAN := FALSE;
        g_TEST_PACKET_GEN           : BOOLEAN := TRUE;
        g_LBUS_CMAC                 : BOOLEAN := TRUE;
        g_LE_DATA_SWAPPING          : BOOLEAN := FALSE
    
    );
    Port ( 
        i_clk400            : in std_logic;
        i_reset_400         : in std_logic;
        
        ---------------------------
        -- Stream interface
        i_packetiser_data_in    : in packetiser_stream_in;
        o_packetiser_data_out   : out packetiser_stream_out;
    
        i_packetiser_reg_in     : in packetiser_config_in;
        o_packetiser_reg_out    : out packetiser_config_out;
        
        i_packetiser_ctrl       : in packetiser_stream_ctrl;


        -- Aligned packet for transmitting
        o_bytes_to_transmit     : out STD_LOGIC_VECTOR(13 downto 0);     -- 
        o_data_to_player        : out STD_LOGIC_VECTOR(511 downto 0);
        o_data_to_player_wr     : out STD_LOGIC;
        i_data_to_player_rdy    : in STD_LOGIC;
    
        -- debug
        o_stream_enable         : out std_logic   -- pulse high when a bad packet length is detected.
    
    );
    
    -- prevent optimisation 
    attribute keep_hierarchy : string;
    attribute keep_hierarchy of packet_former_correlator : entity is "yes";    
    
end packet_former_correlator;

architecture RTL of packet_former_correlator is

    COMPONENT ila_0
    PORT (
   	    clk : IN STD_LOGIC;
   	    probe0 : IN STD_LOGIC_VECTOR(191 DOWNTO 0));
    END COMPONENT;

    COMPONENT ila_1
    PORT (
        clk : IN STD_LOGIC;
        probe0 : IN STD_LOGIC_VECTOR(575 DOWNTO 0)
        );
    END COMPONENT;
    
constant ETHERNET_HEADER_BYTES  : integer := 14;
constant IPV4_HEADER_BYTES      : integer := 20;
constant UDP_HEADER_BYTES       : integer := 8;
constant CORRELATOR_HEADER      : integer := 16;
constant CORRELATOR_DATA        : integer := 6912;
constant TOTAL_BYTES            : integer := ETHERNET_HEADER_BYTES + IPV4_HEADER_BYTES + UDP_HEADER_BYTES + CORRELATOR_HEADER + CORRELATOR_DATA;

signal BYTE_CHECK               : integer := 0;

signal PACKET_COUNTER           : integer := 0;

signal psn_beam_index_update    : integer range 0 to 15;
signal psn_beam_index_header_rd : integer range 0 to 15;


signal ethernet_info            : ethernet_frame;
signal ipv4_info                : IPv4_header;
signal udp_info                 : UDP_header;
signal PsrPacket_info           : CbfPsrHeader;


signal quad_0           : std_logic_vector(127 downto 0);
signal quad_1           : std_logic_vector(127 downto 0);
signal quad_2           : std_logic_vector(127 downto 0);
signal quad_3           : std_logic_vector(127 downto 0);
signal quad_pack        : std_logic_vector(511 downto 0);

signal quad_lbus        : std_logic_vector(511 downto 0);
signal quad_saxi        : std_logic_vector(511 downto 0);

signal header_data_1    : std_logic_vector(511 downto 0);
signal header_data_2    : std_logic_vector(511 downto 0);
signal header_data_3    : std_logic_vector(511 downto 0);

signal sig_data_d1_l    : std_logic_vector(255 downto 0);
signal sig_data_d1_u    : std_logic_vector(255 downto 0);
signal sig_data_d1      : std_logic_vector(511 downto 0);
signal sig_data_d2      : std_logic_vector(511 downto 0);
signal sig_data_d_le    : std_logic_vector(511 downto 0);

signal sig_data_to_quad : std_logic_vector(511 downto 0);
signal sig_data_sel     : std_logic_vector(511 downto 0);

signal valid_delay      : std_logic_vector(8 downto 0);

signal quad_wr          : std_logic := '0';

signal quad_wr_vec      : std_logic_vector(2 downto 0);

signal to_packet_data           : std_logic_vector(511 downto 0);
signal to_packet_data_valid     : std_logic;

type packet_statemachine is (IDLE, HEADER_1, HEADER_2, HEADER_3, DATA, FINISH);
signal packet_sm : packet_statemachine;


signal enable_test_generator         : std_logic;
signal enabe_limited_runs            : std_logic;
signal enable_packetiser             : std_logic;
        
signal packet_generator_runs         : std_logic_vector(31 downto 0);
signal packet_generator_time_between : std_logic_vector(31 downto 0);
signal packet_generator_no_of_beams  : std_logic_vector(3 downto 0);


--signal psn_index                                : integer;

constant adder_b            : std_logic_vector(63 downto 0) := zero_dword & one_dword;
signal math_result          : std_logic_vector(64 downto 0);
signal begin_math           : std_logic;
signal math_done            : std_logic;


signal test_data                        : std_logic_vector(511 downto 0);
signal test_data_wr                     : std_logic;
signal test_beam_number                 : std_logic_vector(3 downto 0);

signal data_valid_int                   : std_logic;
signal data_int                         : std_logic_vector(63 downto 0);

signal reset_enable                     : std_logic_vector(3 downto 0);
signal trigger_dump                     : std_logic;

signal beam_cache_check_reg             : std_logic_vector(15 downto 0);
signal virtual_channel_cache_check_reg  : std_logic_vector(9 downto 0);

type inc_data_statemachine is (IDLE, DATA, FLUSH_FIFO, FINISH);
signal inc_data_sm : inc_data_statemachine;

type process_data_statemachine is (IDLE, DATA);
signal process_data_sm : process_data_statemachine;

signal process_data_count               : integer range 0 to 1023 := 0;

attribute MARK_DEBUG : string;
attribute KEEP : string;

begin
---------------------------------------------------------------------------------------------------
-- output mappings

o_packetiser_data_out.data_in_rdy   <= enable_packetiser AND i_data_to_player_rdy;
o_packetiser_data_out.in_rst        <= '0';  

o_bytes_to_transmit     <= std_logic_vector(to_unsigned(TOTAL_BYTES,14));

o_data_to_player        <= quad_pack;
o_data_to_player_wr     <= quad_wr;

o_stream_enable         <= enable_packetiser;
---------------------------------------------------------------------------------------------------
-- CONFIG RAMs

config_bridge : entity PSR_Packetiser_lib.stream_config_wrapper
    Generic Map
    (
        g_INSTANCE  => g_INSTANCE
    )
    Port Map
    ( 
        i_clk400                    => i_clk400,
        i_reset_400                 => i_reset_400,
        
        i_packetiser_data_in        => i_packetiser_data_in,
        i_packetiser_reg_in         => i_packetiser_reg_in,
        o_packetiser_reg_out        => o_packetiser_reg_out,
        i_packetiser_ctrl           => i_packetiser_ctrl,
    
        enable_test_generator         => enable_test_generator,
        enabe_limited_runs            => enabe_limited_runs,
        enable_packetiser             => enable_packetiser,
        
        ethernet_config               => ethernet_info,
        ipv4_config                   => ipv4_info,
        udp_config                    => udp_info,
        PsrPacket_config              => PsrPacket_info,
        
        packet_generator_runs         => packet_generator_runs,
        packet_generator_time_between => packet_generator_time_between,
        packet_generator_no_of_beams  => packet_generator_no_of_beams
    );
    
    
temp_reset_proc : process(i_clk400)
begin
    if rising_edge(i_clk400) then
--        packet_generator_runs           <= x"00000002";
--        packet_generator_time_between   <= x"00000100";
--        packet_generator_no_of_beams    <= x"7";
        
--        ethernet_info                   <= ethernet_config;
--        ipv4_info                       <= ipv4_config;
--        udp_info                        <= udp_config;
--        PsrPacket_info                  <= PsrPacket_config;
        
    end if;
end process;

---------------------------------------------------------------------------------------------------


Test_logic_GEN : if g_TEST_PACKET_GEN GENERATE

psr_test_gen : entity PSR_Packetiser_lib.test_packet_data_gen 
    Generic Map
    (
        g_INSTANCE  => g_INSTANCE
    )
    Port Map
    ( 
        i_clk                           => i_clk400,
        i_rst                           => i_reset_400,
    
        i_enable_test_generator         => enable_test_generator,
        i_enabe_limited_runs            => enabe_limited_runs,
        
        i_packet_generator_runs         => packet_generator_runs,
        i_packet_generator_time_between => packet_generator_time_between,
        i_packet_generator_no_of_beams  => packet_generator_no_of_beams,
        
        i_data_to_player_rdy            => i_data_to_player_rdy,
        
        o_test_beam_number              => test_beam_number,
        o_test_data                     => test_data,
        o_test_data_wr                  => test_data_wr
    );
end generate;

---------------------------------------------------------------------------------------------------
-- Data from incoming or test generator
        
        
data_select_proc : process(i_clk400)
begin
    if rising_edge(i_clk400) then
        if enable_test_generator = '1' then
            to_packet_data          <= test_data;
            to_packet_data_valid    <= test_data_wr;
            
        else
            to_packet_data          <= i_packetiser_data_in.data;
            to_packet_data_valid    <= i_packetiser_data_in.data_in_wr;
            
        end if;
    end if;
end process;



incoming_data_delay : process(i_clk400)
begin
    if rising_edge(i_clk400) then
        if i_reset_400 = '1' then
            valid_delay         <= zero_byte & '0';
            
            sig_data_to_quad    <= zero_512;
            sig_data_d_le       <= zero_512;
            sig_data_d1         <= zero_512;
            sig_data_d2         <= zero_512;
            sig_data_sel        <= zero_512;
            
            sig_data_d1_l       <= zero_256;
            sig_data_d1_u       <= zero_256;
        else
            sig_data_d1_u                   <= to_packet_data(511 downto 256);
            sig_data_d1_l                   <= to_packet_data(255 downto 0);
            
            sig_data_d1                     <= to_packet_data;
            sig_data_d2                     <= sig_data_d1;
            
            -- split the little Endian byte swap into two 256 bits and recombine.
            sig_data_d_le(511 downto 256)   <=  sig_data_d1_u(247 downto 240) & sig_data_d1_u(255 downto 248)   & sig_data_d1_u(231 downto 224)   & sig_data_d1_u(239 downto 232) & 
                                                sig_data_d1_u(215 downto 208) & sig_data_d1_u(223 downto 216)   & sig_data_d1_u(199 downto 192)   & sig_data_d1_u(207 downto 200) &
                                                
                                                sig_data_d1_u(183 downto 176) & sig_data_d1_u(191 downto 184)   & sig_data_d1_u(167 downto 160)   & sig_data_d1_u(175 downto 168) & 
                                                sig_data_d1_u(151 downto 144) & sig_data_d1_u(159 downto 152)   & sig_data_d1_u(135 downto 128)   & sig_data_d1_u(143 downto 136) &
                                                
                                                sig_data_d1_u(119 downto 112) & sig_data_d1_u(127 downto 120)   & sig_data_d1_u(103 downto 96)    & sig_data_d1_u(111 downto 104) & 
                                                sig_data_d1_u(87 downto 80)   & sig_data_d1_u(95 downto 88)     & sig_data_d1_u(71 downto 64)     & sig_data_d1_u(79 downto 72) &
                                                
                                                sig_data_d1_u(55 downto 48)   & sig_data_d1_u(63 downto 56)     & sig_data_d1_u(39 downto 32)     & sig_data_d1_u(47 downto 40) & 
                                                sig_data_d1_u(23 downto 16)   & sig_data_d1_u(31 downto 24)     & sig_data_d1_u(7 downto 0)       & sig_data_d1_u(15 downto 8);
                                                
            sig_data_d_le(255 downto 0)     <=  sig_data_d1_l(247 downto 240) & sig_data_d1_l(255 downto 248)   & sig_data_d1_l(231 downto 224)   & sig_data_d1_l(239 downto 232) & 
                                                sig_data_d1_l(215 downto 208) & sig_data_d1_l(223 downto 216)   & sig_data_d1_l(199 downto 192)   & sig_data_d1_l(207 downto 200) &
                                                
                                                sig_data_d1_l(183 downto 176) & sig_data_d1_l(191 downto 184)   & sig_data_d1_l(167 downto 160)   & sig_data_d1_l(175 downto 168) & 
                                                sig_data_d1_l(151 downto 144) & sig_data_d1_l(159 downto 152)   & sig_data_d1_l(135 downto 128)   & sig_data_d1_l(143 downto 136) &
                                                
                                                sig_data_d1_l(119 downto 112) & sig_data_d1_l(127 downto 120)   & sig_data_d1_l(103 downto 96)    & sig_data_d1_l(111 downto 104) & 
                                                sig_data_d1_l(87 downto 80)   & sig_data_d1_l(95 downto 88)     & sig_data_d1_l(71 downto 64)     & sig_data_d1_l(79 downto 72) &
                                                
                                                sig_data_d1_l(55 downto 48)   & sig_data_d1_l(63 downto 56)     & sig_data_d1_l(39 downto 32)     & sig_data_d1_l(47 downto 40) & 
                                                sig_data_d1_l(23 downto 16)   & sig_data_d1_l(31 downto 24)     & sig_data_d1_l(7 downto 0)       & sig_data_d1_l(15 downto 8);                                                
            
            -- COMPILE TIME SWTICH FOR THE MOMENT
            if g_LE_DATA_SWAPPING = TRUE then                                   
                sig_data_sel <= sig_data_d_le;
            else
                sig_data_sel <= sig_data_d2;
            end if;
            
            sig_data_to_quad     <= sig_data_sel;
            
            valid_delay(0)                  <= to_packet_data_valid;
            valid_delay(8 downto 1)         <= valid_delay(7 downto 0);
            
            

        end if;
    end if;
end process;



make_a_packet_sm : process(i_clk400)
begin
    if rising_edge(i_clk400) then
        if i_reset_400 = '1' then
            packet_sm       <= IDLE;
            quad_0          <= zero_128;
            quad_1          <= zero_128;
            quad_2          <= zero_128;
            quad_3          <= zero_128;
            quad_wr_vec     <= "000";
        else        
            case packet_sm is
                when IDLE =>
                    if (enable_packetiser = '1') and valid_delay(3 downto 0) = "0111" then      -- look for edge so you don't send less than full packet when enabling SM.
                        packet_sm <= HEADER_1;
                    end if;
                
                when HEADER_1 => 
                    packet_sm <= HEADER_2;
                    
                when HEADER_2 => 
                    packet_sm <= HEADER_3;
                    
                when HEADER_3 => 
                    packet_sm <= DATA;
                
                when DATA =>
                    if valid_delay(3) = '0' then
                        packet_sm <= FINISH;
                    end if;
                
                when FINISH =>
                    packet_sm       <= IDLE;
                
                when OTHERS =>
                    packet_sm <= IDLE;
    
            end case;            
        
            -- The ICD calls for a mix of Big and Little Endian, the packet header - Ethernet/IPV4/UDP all big, UDP payload is little
            -- There are some byte swaps in the CMAC IPcore.
            -- passing a vector will give you big endian.
            -- byte swapping on the feeding vector required for little en
            if packet_sm = HEADER_1 then
                -- Packet 1st cycle
                quad_0 <= header_data_1(127 downto 0); 
                quad_1 <= header_data_1(255 downto 128);
                quad_2 <= header_data_1(383 downto 304) & sig_data_to_quad(303 downto 256);
                quad_3 <= sig_data_to_quad(511 downto 384);
                
--            elsif packet_sm = HEADER_2 then
--                -- Packet 2nd cycle
--                quad_0 <= header_data_2(127 downto 0); 
--                quad_1 <= header_data_2(255 downto 128);
--                quad_2 <= header_data_2(383 downto 256);
--                quad_3 <= header_data_2(511 downto 384);
            
--            elsif packet_sm = HEADER_3 then
--                -- Packet 2nd cycle
--                quad_0 <= header_data_3(127 downto 48) & sig_data_to_quad(47 downto 0); 
--                quad_1 <= sig_data_to_quad(255 downto 128);
--                quad_2 <= sig_data_to_quad(383 downto 256);
--                quad_3 <= sig_data_to_quad(511 downto 384);
            else
                quad_0 <= sig_data_to_quad(127 downto 0); 
                quad_1 <= sig_data_to_quad(255 downto 128);
                quad_2 <= sig_data_to_quad(383 downto 256);
                quad_3 <= sig_data_to_quad(511 downto 384);
            end if;
    
                                
--            quad_pack   <= quad_3 & quad_2 & quad_1 & quad_0;
            --quad_wr     <= valid_delay(4);
            
            -- need to add 2 wr cycles for the the ethernet header and UDP and PSR meta to the data payload.
            if valid_delay(4) = '1' then
                quad_wr_vec <= "100";
            else
                quad_wr_vec <= quad_wr_vec(1 downto 0) & '0';
            end if;
        end if;
    end if;
end process;

quad_lbus   <= quad_3 & quad_2 & quad_1 & quad_0;
quad_wr     <= quad_wr_vec(2);
-----------
-- LBUS, first byte is 127 ->120, then 119 -> 112 etc down to 0, then 255 -> 248 down to 128 and so on.
-- Streaming AXI is 7 -> 0, 15 -> 8, etc to 511.
-- no quads in streaming AXI.

Lbus_GEN : IF (g_LBUS_CMAC) GENERATE
    noswap_proc : process(i_clk400)
        begin
            if rising_edge(i_clk400) then
                quad_pack   <= quad_lbus;
            end if;
        end process;
END GENERATE;

                
Lbus_to_S_AXI_GEN : IF (NOT g_LBUS_CMAC) GENERATE
-- Swap from LBUS to S_AXI 
    QUAD: for n in 0 to 3 generate
        BYTE: for i in 0 to 15 generate
            swap_proc : process(i_clk400)
            begin
                if rising_edge(i_clk400) then
                    quad_pack(((128*n) + (i*8)+7) downto ((128*n)+(i*8)))   <= quad_lbus(((128*n) + 127 - (i*8)) downto ((128*n) + 127 - (i*8) - 7));
                end if;
            end process;
        end generate;
    end generate;
END GENERATE;                

--swapped_packetiser_data((128*n + 127 - i*8) downto (128*n + 127 - i*8 -7)) <= packetiser_data((128*n + i*8+7) downto (128*n+i*8));
byte_write_check_proc : process(i_clk400)
begin
    if rising_edge(i_clk400) then
        if quad_wr = '1' then
            BYTE_CHECK <= BYTE_CHECK + 64;
        else
            BYTE_CHECK <= 0;
        end if;
    end if;
end process;



---------------------------------------------------------------------------------------------------------------------------------------    
-- 512 bit / 64 byte header assembly.
header_proc : process(i_clk400)
begin
    if rising_edge(i_clk400) then
    
        -- ONLY update headers when SM in IDLE not args update. 
        if (enable_packetiser = '1' AND (packet_sm = IDLE OR packet_sm = HEADER_1)) then
        --if ((packet_sm = IDLE OR packet_sm = HEADER_1)) then
            header_data_1(127 downto 0)   <=    ethernet_info.dst_mac & 
                                                ethernet_info.src_mac & 
                                                ethernet_info.eth_type & 
                                                ipv4_info.version & 
                                                ipv4_info.header_length & 
                                                ipv4_info.type_of_service; 
            header_data_1(255 downto 128) <=    ipv4_info.total_length & 
                                                ipv4_info.id & 
                                                ipv4_info.ip_flags & 
                                                ipv4_info.fragment_off & 
                                                ipv4_info.TTL & 
                                                ipv4_info.protocol & 
                                                ipv4_info.header_chk_sum & 
                                                ipv4_info.src_addr & 
                                                ipv4_info.dst_addr(31 downto 16);
            header_data_1(383 downto 256) <=    ipv4_info.dst_addr(15 downto 0) & 
                                                udp_info.src_port & 
                                                udp_info.dst_port & 
                                                udp_info.length & 
                                                udp_info.checksum & 
                                                zero_word & zero_dword;
            header_data_1(511 downto 384) <=    zero_qword & zero_qword; 

    ----------------------------
            header_data_2(127 downto 0)   <=    zero_qword & zero_qword; 
 
            header_data_2(255 downto 128) <=    zero_qword & zero_qword; 
 
            header_data_2(383 downto 256) <=    zero_qword & zero_qword; 

            header_data_2(511 downto 384) <=    zero_qword & zero_qword; 
                                                
    ----------------------------
            header_data_3(127 downto 0)   <=    zero_qword & zero_qword;                                      
            header_data_3(255 downto 128) <=    zero_qword & zero_qword;  
            header_data_3(383 downto 256) <=    zero_qword & zero_qword; 
            header_data_3(511 downto 384) <=    zero_qword & zero_qword;

          end if;                                  
    end if;
end process;


---------------------------------------------------------------------------------------------------------------------------------------
-- ILA for debugging
ILA_GEN : if g_DEBUG_ILA GENERATE
    packetiser_ila : ila_0
        port map (
            clk                     => i_clk400, 
            probe0(47 downto 0)     => ethernet_info.dst_mac, 
            probe0(95 downto 48)    => ethernet_info.src_mac, 
            probe0(111 downto 96)   => ethernet_info.eth_type, 
            probe0(115 downto 112)  => ipv4_info.version,
            probe0(119 downto 116)  => ipv4_info.header_length, 
            probe0(127 downto 120)  => ipv4_info.type_of_service,
            probe0(129 downto 128)  => (others => '0'),
            probe0(130)             => test_data_wr,
            probe0(131)             => i_data_to_player_rdy,
            probe0(132)             => enable_test_generator,
            probe0(133)             => enabe_limited_runs,
            probe0(134)             => enable_packetiser,
            probe0(135)             => valid_delay(3),
            probe0(136)             => quad_wr,
            probe0(168 downto 137)  => packet_generator_time_between,
            probe0(191 downto 169)  => (others => '0')
        );
END GENERATE;


end RTL;
