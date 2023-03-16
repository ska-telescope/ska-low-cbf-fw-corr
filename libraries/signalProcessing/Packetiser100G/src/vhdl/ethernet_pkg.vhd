----------------------------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
----------------------------------------------------------------------------------------------------
--
-- Ethernet frames, headers etc
--
----------------------------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.all;
use IEEE.numeric_std.all;

PACKAGE ethernet_pkg IS

constant c_ones_nibble  : std_logic_vector(3 downto 0) 	:= "1111";
constant c_ones_byte 	: std_logic_vector(7 downto 0) 	:= c_ones_nibble & c_ones_nibble;
constant c_ones_word 	: std_logic_vector(15 downto 0) := c_ones_byte & c_ones_byte;
constant c_ones_dword 	: std_logic_vector(31 downto 0) := c_ones_word & c_ones_word;
constant c_ones_qword 	: std_logic_vector(63 downto 0) := c_ones_dword & c_ones_dword;
constant c_ones_512 	: std_logic_vector(511 downto 0) := ( others => '1');

constant zero_nibble    : std_logic_vector(3 downto 0) 	:= "0000";
constant zero_byte 	    : std_logic_vector(7 downto 0) 	:= zero_nibble & zero_nibble;
constant zero_word 	    : std_logic_vector(15 downto 0) := zero_byte & zero_byte;
constant zero_dword 	: std_logic_vector(31 downto 0) := zero_word & zero_word;
constant zero_qword 	: std_logic_vector(63 downto 0) := zero_dword & zero_dword;
constant zero_32 	    : std_logic_vector(31 downto 0) := zero_word & zero_word;
constant zero_64    	: std_logic_vector(63 downto 0) := zero_dword & zero_dword;
constant zero_128 	    : std_logic_vector(127 downto 0):= zero_qword & zero_qword;
constant zero_256 	    : std_logic_vector(255 downto 0):= zero_128 & zero_128;
constant zero_512       : std_logic_vector(511 downto 0):= zero_256 & zero_256;

constant one_nibble     : std_logic_vector(3 downto 0) 	:= "0001";
constant one_byte 	    : std_logic_vector(7 downto 0) 	:= zero_nibble & one_nibble;
constant one_word 	    : std_logic_vector(15 downto 0) := zero_byte & one_byte;
constant one_dword 	    : std_logic_vector(31 downto 0) := zero_word & one_word;


type ethernet_frame is record
    dst_mac     : std_logic_vector(47 downto 0);
    src_mac     : std_logic_vector(47 downto 0);
    eth_type    : std_logic_vector(15 downto 0);
end record;

type IPv4_header is record
    version         : std_logic_vector(3 downto 0);
    header_length   : std_logic_vector(3 downto 0);
    type_of_service : std_logic_vector(7 downto 0);
    total_length    : std_logic_vector(15 downto 0);
    id              : std_logic_vector(15 downto 0);
    ip_flags        : std_logic_vector(2 downto 0);
    fragment_off    : std_logic_vector(12 downto 0);
    TTL             : std_logic_vector(7 downto 0);
    protocol        : std_logic_vector(7 downto 0);
    header_chk_sum  : std_logic_vector(15 downto 0);
    src_addr        : std_logic_vector(31 downto 0);
    dst_addr        : std_logic_vector(31 downto 0);
end record;

type UDP_header is record
    src_port    : std_logic_vector(15 downto 0);
    dst_port    : std_logic_vector(15 downto 0);
    length      : std_logic_vector(15 downto 0);
    checksum    : std_logic_vector(15 downto 0);
end record;

type packetiser_stream_in is record
    data_clk                : std_logic;
    data_in_wr              : std_logic;
    data                    : std_logic_vector(511 downto 0);
    bytes_to_transmit       : std_logic_vector(13 downto 0);
    
    -- PST signals are passed with data to make headers on the fly. Zero out for other packet types.
    PST_virtual_channel     : std_logic_vector(9 downto 0);
    PST_beam                : std_logic_vector(7 downto 0);
    PST_time_ref            : std_logic_vector(36 downto 0);
end record;

type packetiser_stream_out is record
    data_in_rdy             : std_logic;    -- Ready to receive data, FIFO feedback.
    
    in_rst                  : std_logic;    -- CMAC/Packetiser logic in reset
end record;

type packetiser_config_in is record
    config_data_clk         : std_logic;
    config_data             : std_logic_vector(31 downto 0);
    config_data_addr        : std_logic_vector(14 downto 0);    -- If connected to ARGs, that is byte addressing, this is 32 bit addressing.
    config_data_en          : std_logic;
    config_data_wr          : std_logic;
end record;

type packetiser_config_out is record
    config_data_valid       : std_logic;
    config_data_out         : std_logic_vector(31 downto 0);
end record;

type packetiser_stream_ctrl is record
    instruct                : std_logic_vector(31 downto 0);
end record;

type packetiser_stats is record
    valid_packets           : std_logic_vector(31 downto 0);
    invalid_packets         : std_logic_vector(31 downto 0);
    disregarded_packets     : std_logic_vector(31 downto 0);
    packets_sent_to_cmac    : std_logic_vector(31 downto 0);
end record;

TYPE t_packetiser_stream_in     IS ARRAY (INTEGER RANGE <>) OF packetiser_stream_in;  
TYPE t_packetiser_stream_out    IS ARRAY (INTEGER RANGE <>) OF packetiser_stream_out;

TYPE t_packetiser_config_in     IS ARRAY (INTEGER RANGE <>) OF packetiser_config_in;  
TYPE t_packetiser_config_out    IS ARRAY (INTEGER RANGE <>) OF packetiser_config_out;  

TYPE t_packetiser_stream_ctrl   IS ARRAY (INTEGER RANGE <>) OF packetiser_stream_ctrl;

TYPE t_ethernet_frame           IS ARRAY (INTEGER RANGE <>) OF ethernet_frame;
TYPE t_IPv4_header              IS ARRAY (INTEGER RANGE <>) OF IPv4_header;
TYPE t_UDP_header               IS ARRAY (INTEGER RANGE <>) OF UDP_header;

TYPE t_packetiser_stats         IS ARRAY (INTEGER RANGE <>) OF packetiser_stats;

---- Constants
constant null_packetiser_stream_in : packetiser_stream_in := ( 
                                                            data_clk            => '0',
                                                            data_in_wr          => '0',
                                                            data                => (others=>'0'),
                                                            bytes_to_transmit   => (others=>'0'),
                                                            PST_virtual_channel => (others=>'0'),
                                                            PST_beam            => (others=>'0'),
                                                            PST_time_ref        => (others=>'0')
                                                            );

constant null_packetiser_stream_out : packetiser_stream_out := (
                                                            data_in_rdy => '0',
                                                            in_rst      => '0'
                                                           );
                                                           

constant null_packetiser_config_in : packetiser_config_in := (
                                                            config_data_clk     => '0',
                                                            config_data         => (others=>'0'),
                                                            config_data_addr    => (others=>'0'),
                                                            config_data_en      => '0',
                                                            config_data_wr      => '0'
                                                            );

constant null_packetiser_config_out : packetiser_config_out := (
                                                            config_data_valid   => '0',
                                                            config_data_out     => (others=>'0')
                                                            );

constant null_packetiser_stream_ctrl : packetiser_stream_ctrl := ( 
                                                            instruct            => (others=>'0')
                                                            );


constant null_ethernet_frame : ethernet_frame := (
                                dst_mac         => (others=>'0'),
                                src_mac         => (others=>'0'),
                                eth_type        => (others=>'0')
                                );
                                
constant null_ipv4_header : IPv4_header := (
                                version         => (others=>'0'),
                                header_length   => (others=>'0'),
                                type_of_service => (others=>'0'),
                                total_length    => (others=>'0'),
                                id              => (others=>'0'),
                                ip_flags        => (others=>'0'),
                                fragment_off    => (others=>'0'),
                                TTL             => (others=>'0'),
                                protocol        => (others=>'0'),
                                header_chk_sum  => (others=>'0'),
                                src_addr        => (others=>'0'),
                                dst_addr        => (others=>'0')
                                );

constant null_UDP_header : UDP_header := (
                                src_port        => (others=>'0'),
                                dst_port        => (others=>'0'),
                                length          => (others=>'0'),
                                checksum        => (others=>'0')
                                );
                                
constant default_ethernet_frame : ethernet_frame := (
                                dst_mac         => x"DEAD0FEE0BEE",
                                src_mac         => x"BEEF00C0FFEE",
                                eth_type        => x"0800"
                                );
                                
constant default_ipv4_header : IPv4_header := (
                                version         => x"4",
                                header_length   => x"5",
                                type_of_service => x"00",
                                total_length    => x"18AC",
                                id              => x"DEAD",
                                ip_flags        => "010",
                                fragment_off    => (others=>'0'),
                                TTL             => x"40",
                                protocol        => x"11",
                                header_chk_sum  => x"2F90",
                                src_addr        => x"C0A80065",     -- 192.168.0.101
                                dst_addr        => x"C0A80066"      -- 192.168.0.102
                                );

constant default_ipv4_header_2 : IPv4_header := (
                                version         => x"4",
                                header_length   => x"5",
                                type_of_service => x"00",
                                total_length    => x"18AC",
                                id              => x"ABBA",
                                ip_flags        => "010",
                                fragment_off    => (others=>'0'),
                                TTL             => x"40",
                                protocol        => x"11",
                                header_chk_sum  => x"2F90",
                                src_addr        => x"C0A80065",     -- 192.168.0.101
                                dst_addr        => x"C0A80067"      -- 192.168.0.103
                                );
                                
constant default_ipv4_header_3 : IPv4_header := (
                                version         => x"4",
                                header_length   => x"5",
                                type_of_service => x"00",
                                total_length    => x"18AC",
                                id              => x"ACDC",
                                ip_flags        => "010",
                                fragment_off    => (others=>'0'),
                                TTL             => x"40",
                                protocol        => x"11",
                                header_chk_sum  => x"2F90",
                                src_addr        => x"C0A80065",     -- 192.168.0.101
                                dst_addr        => x"C0A80068"      -- 192.168.0.104
                                );                                
constant default_UDP_header : UDP_header := (
                                src_port        => x"270F",         -- 9999
                                dst_port        => x"2526",         -- 9510
                                length          => x"1898",         -- 6296
                                checksum        => (others=>'0')
                                );

constant t_default_IPv4_header : t_IPv4_header(2 downto 0) := ( default_ipv4_header,
                                                                default_ipv4_header_2,
                                                                default_ipv4_header_3
                                                                );                                                            
end ethernet_pkg;