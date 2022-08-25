----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: Nov 2020
-- Design Name: Atomic COTS
-- Module Name: packet_former - RTL
-- Target Devices: Alveo U50 
-- Tool Versions: 2020.1
-- 
--Ethernet Frame + IP header + UDP Header + UDP payload as per 512 bit interface with
-- these will map to the SOSI interface differently. lower byte to upper byte of 128 bit interface and continue that pattern.
-- using capture from LFAAProcess100G as a guide
--# FIRST CYCLE 
--127 -> 0                            bytes (16 per int)      
--47 -> 0     = Dest Mac              6
--95 -> 48    = Source Mac addr       6
--111 -> 96   = Type                  2
--115 -> 112  = Version               1/2     (Start of IPv4 Header, 20 Bytes)  
--119 -> 116  = IHL                   1/2
--127 -> 120  = Type of Service       1

--255 -> 128
--143 -> 128  = Total Length          2
--159 -> 144  = Identification        2
--175 -> 160  = Flag + Frag off       2       (will hard code to not fragment)
--183 -> 176  = TTL                   1
--191 -> 184  = Protocol              1
--207 -> 192  = Header Checksum       2
--239 -> 208  = Source Address        4
--255 -> 240  = Dest Addr upper       2

--383 -> 256
--271 -> 256  = Dest Addr lower       2
--287 -> 272  = Source Port           2       (Start of UDP Header, 8 Bytes)
--303 -> 288  = Dest Port             2
--319 -> 304  = Length                2
--335 -> 320  = Checksum              2
--383 -> 336  = Pkt Seq Num upper     6       (Start of UDP Payload, Meta Data next 64 bytes)

--511 -> 384
--Pkt Seq Num lower             2
--Time from int sec             8                         
--Time from Epoch       		4
--channel separation upper		2

--# SECOND CYCLE
--127 -> 0
--channel separation lower		2
--first channel freq			8
--scale_1                       4
--scale_2 upper                 2

--255 -> 128
--scale_2 lower                 2
--scale_3                       4
--scale_4                       4
--First channel number			4
--channels per packet			2
 
--383 -> 256
--valid channels per packet     2
--no. time samples              2
--beam number                   2
--magic number                  4
--pkt destination               1
--data precision                1
--power average                 1
--ts per rel wt                 1
--O/S Numerator                 1
--O/S Denominator			    1

--511 -> 384
--Beamformer Version			2
--SCAN ID                       8
--Offset 1                      4
--Offset 2 upper                2


--# THIRD CYCLE
--127 -> 0
--Offset 2 lower                2
--Offset 3                      4
--Offset 4                      4
-- 6 bytes from live data pipe  6       

--255 -> 128
-- 16 bytes live data			16

--383 -> 256
-- 16 bytes live data			16

--511 -> 384
-- 16 bytes live data			16


--pattern gen for 64 bit interface

--1           2
--3           4

--Maps to

--a b c d         6 7 8 9         2 3 4 5         meta_end  1
--1a 1b 1c 1d     16 17 18 19     12 13 14 15     1e 1f 10 11

-- Rest of cycles
-- assume that data on the 64 bit interface will all be valid.
-- LOW PST = 6334 bytes.
-- subtract 4 bytes which are CRC done automatically by 100G core.
-- 6330 - 14 Ethernet - 20 IPv4 - 8 UDP - 96 UDP header = 6192
-- 6192 bytes on 64 bit data interface = 774 writes
-- 48 bytes(6 writes) are realtive weight, rest is data.

--=((8*$B$1)-1)+(32*A2)
--	3	2	4	3	1	0	2	1
--0	23	16	31	24	7	0	15	8
--1	55	48	63	56	39	32	47	40
--2	87	80	95	88	71	64	79	72
--3	119	112	127	120	103	96	111	104
--4	151	144	159	152	135	128	143	136
--5	183	176	191	184	167	160	175	168
--6	215	208	223	216	199	192	207	200
--7	247	240	255	248	231	224	239	232

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

entity packet_former is
    Generic (
        g_INSTANCE                  : INTEGER := 0;
        g_DEBUG_ILA                 : BOOLEAN := FALSE;
        g_TEST_PACKET_GEN           : BOOLEAN := TRUE;
        g_LBUS_CMAC                 : BOOLEAN := TRUE;
        g_LE_DATA_SWAPPING          : BOOLEAN := FALSE;
        
        g_PST_beamformer_version    : STD_LOGIC_VECTOR(15 DOWNTO 0) := x"0014";
        
        g_PSN_BEAM_REGISTERS        : INTEGER := 16;
        METADATA_HEADER_BYTES       : INTEGER := 96;
        WEIGHT_CHAN_SAMPLE_BYTES    : INTEGER := 6192      -- 6192 for LOW PST, 4626 for LOW PSS
           
    
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

        o_testmode              : out std_logic;

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
    attribute keep_hierarchy of packet_former : entity is "yes";    
    
end packet_former;

architecture RTL of packet_former is

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
constant TOTAL_BYTES            : integer := ETHERNET_HEADER_BYTES + IPV4_HEADER_BYTES + UDP_HEADER_BYTES + METADATA_HEADER_BYTES + WEIGHT_CHAN_SAMPLE_BYTES;   --6330,6272,2154,2140

constant META_FROM_SIG_PROC     : integer := 8; -- leading write on the data port for scale meta data to be placed into packet header.
constant BYTES_FROM_SIGNAL_PROC : integer := (WEIGHT_CHAN_SAMPLE_BYTES + META_FROM_SIG_PROC) / 8;

signal BYTE_CHECK               : integer := 0;

signal PACKET_COUNTER           : integer := 0;

signal psn_beam_index_update    : integer range 0 to 15;
signal psn_beam_index_header_rd : integer range 0 to 15;

signal little_endian_PsrPacket  : CbfPsrHeader;



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

signal scale_1              : std_logic_vector(31 downto 0);
signal beam_internal        : std_logic_vector(15 downto 0);

signal packet_sequence_number                   : std_logic_vector(63 downto 0) := zero_qword;

signal packet_sequence_number_beams             : t_slv_64_arr((g_PSN_BEAM_REGISTERS-1) downto 0);
signal packet_sequence_number_toupdate          : std_logic_vector(63 downto 0) := zero_qword;

--signal psn_index                                : integer;

signal adder_b            : std_logic_vector(63 downto 0) := zero_dword & one_dword;
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

o_testmode              <= enable_test_generator;
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
            
            beam_internal           <= zero_byte & zero_nibble & test_beam_number; --PsrPacket_config.beam_number;
        else
            to_packet_data          <= i_packetiser_data_in.data;
            to_packet_data_valid    <= i_packetiser_data_in.data_in_wr;
            
            beam_internal           <= zero_byte & i_packetiser_data_in.PST_beam;
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
            
            

            
            if valid_delay(2 downto 0) = "001" then
                -- intercept scale_1 from signal processing stream.
                scale_1 <= sig_data_d1(79 downto 48);
            end if;
            
            -- update the beam counter after a few cycles into signa; data coming into module.
            if valid_delay(4 downto 3) = "01" then
                begin_math <= '1';
            else
                begin_math <= '0';
            end if;

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
                    if (enable_packetiser = '1') and valid_delay(2 downto 0) = "001" then      -- look for edge so you don't send less than full packet when enabling SM.
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
                quad_2 <= header_data_1(383 downto 256);
                quad_3 <= header_data_1(511 downto 384);
                
            elsif packet_sm = HEADER_2 then
                -- Packet 2nd cycle
                quad_0 <= header_data_2(127 downto 0); 
                quad_1 <= header_data_2(255 downto 128);
                quad_2 <= header_data_2(383 downto 256);
                quad_3 <= header_data_2(511 downto 384);
            
            elsif packet_sm = HEADER_3 then
                -- Packet 2nd cycle
                quad_0 <= header_data_3(127 downto 48) & sig_data_to_quad(47 downto 0); 
                quad_1 <= sig_data_to_quad(255 downto 128);
                quad_2 <= sig_data_to_quad(383 downto 256);
                quad_3 <= sig_data_to_quad(511 downto 384);
            else
                quad_0 <= sig_data_to_quad(127 downto 0); 
                quad_1 <= sig_data_to_quad(255 downto 128);
                quad_2 <= sig_data_to_quad(383 downto 256);
                quad_3 <= sig_data_to_quad(511 downto 384);
            end if;
    
                                
--            quad_pack   <= quad_3 & quad_2 & quad_1 & quad_0;
            --quad_wr     <= valid_delay(4);
            
            -- need to add 2 wr cycles for the the ethernet header and UDP and PSR meta to the data payload.
            if valid_delay(2) = '1' then
                quad_wr_vec <= "111";
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
-- as per ICD, each packet shall be unique by a combination of packet sequence number, beam number and first channel freq.
-- first channel freq is a static mapping as per ARGs memory interface one level up.
-- therefore each beam has an incrementing PSN on a per beam basis.
-- for PST implementation we are going to assume 16, and increment the beam once it has been sent in the packetiser.


beam_cache_check_reg <= beam_internal;

-- generate 16 registers and init structures.
PSN_gen : for i in 0 to (g_PSN_BEAM_REGISTERS-1) generate
signal psn_per_beam_const   : std_logic_vector(7 downto 0);
begin
    psn_per_beam_const <= std_logic_vector(to_unsigned(i,8));
    
    psn_per_beam_proc : process(i_clk400)
    begin
        if rising_edge(i_clk400) then
            -- load the psn from software config, if zeroed then this acts a reset.
            if (enable_packetiser = '0') then
                packet_sequence_number_beams(i)     <= PsrPacket_info.packet_sequence_number;
            elsif math_done = '1' AND (beam_cache_check_reg(7 downto 0) = psn_per_beam_const) then      -- once packet sent, based on BEAM number, increase the number
                packet_sequence_number_beams(i)     <= math_result(63 downto 0);
            end if;
        end if;
    end process;

end generate;  

-- update PSN after packet.
psn_update_proc : process(i_clk400)
begin
    if rising_edge(i_clk400) then
        packet_sequence_number_toupdate <= packet_sequence_number_beams(psn_beam_index_update);
    end if;
end process;

psn_beam_index_update                   <= to_integer(unsigned(beam_cache_check_reg(3 downto 0)));


PSN_adder : entity PSR_Packetiser_lib.adder_32_int 
Port map ( 
        i_clock     => i_clk400,
        i_en        => enable_packetiser,
        
        i_adder_a   => packet_sequence_number_toupdate,
        i_adder_b   => adder_b,
        i_begin     => begin_math,        
    
        o_result    => math_result,
        o_valid     => math_done
    
    );

--math_result(63 downto 0)    <= packet_sequence_number_toupdate;
---------------------------------------------------------------------------------------------------------------------------------------
-- Timestamp for the PSR packetiser output is
--    At the start of the observation there is a 120ms window where software will look at incoming LFAA packet, retrieve a LFAA PSN and real time reference from the incoming SPEAD packet and populated these to registers in the packetiser.
--        These two variables need to be the first of 3 LFAA sample blocks that are used for beamforming.
--    Beamformer will provide the LFAA PSN of the first LFAA block when writing the voltage samples to the packetiser.
--    Math for this is
--        LFAA PSN from BF - LFAA PSN in register from beginning of observation = X (This should be a number that is divisible by 3)
--        X * 2.211840ms (time of a PSR packet) = Y
--        Y + (coarse delay * 69120ns) = Z .. where coarse delay is (5 bits from packetcount 4:0)
--        Z + LFAA time reference from the beginning of the observation.

-- This will require coarse delay on a per beam basis, software will provide the coarse delay * 69120 as a register value.




---------------------------------------------------------------------------------------------------------------------------------------    
-- 512 bit / 64 byte header assembly.
psn_beam_index_header_rd        <= to_integer(unsigned(beam_internal(3 downto 0)));
header_proc : process(i_clk400)
begin
    if rising_edge(i_clk400) then
        -- assign the packet_sequence_number based on BEAM ID
        packet_sequence_number  <= packet_sequence_number_beams(psn_beam_index_header_rd);
    
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
                                                little_endian_PsrPacket.packet_sequence_number(63 downto 16);
            header_data_1(511 downto 384) <=    little_endian_PsrPacket.packet_sequence_number(15 downto 0) & 
                                                little_endian_PsrPacket.timestamp_attoseconds & 
                                                little_endian_PsrPacket.timestamp_seconds &
                                                little_endian_PsrPacket.channel_separation(31 downto 16);
    ----------------------------
            header_data_2(127 downto 0)   <=    little_endian_PsrPacket.channel_separation(15 downto 0) & 
                                                little_endian_PsrPacket.first_channel_frequency & 
                                                little_endian_PsrPacket.scale(0) & --PsrPacket_info.scale(0) & 
                                                little_endian_PsrPacket.scale(1)(31 downto 16); 
            header_data_2(255 downto 128) <=    little_endian_PsrPacket.scale(1)(15 downto 0) & 
                                                little_endian_PsrPacket.scale(2) & 
                                                little_endian_PsrPacket.scale(3) & 
                                                little_endian_PsrPacket.first_channel_number & 
                                                little_endian_PsrPacket.channels_per_packet; 
            header_data_2(383 downto 256) <=    little_endian_PsrPacket.valid_channels_per_packet & 
                                                little_endian_PsrPacket.number_of_time_samples & 
                                                little_endian_PsrPacket.beam_number & 
                                                little_endian_PsrPacket.magic_word & 
                                                little_endian_PsrPacket.packet_destination & 
                                                little_endian_PsrPacket.data_precision &
                                                little_endian_PsrPacket.number_of_power_samples_averaged &
                                                little_endian_PsrPacket.number_of_time_samples_weight &
                                                little_endian_PsrPacket.oversampling_ratio_numerator &
                                                little_endian_PsrPacket.oversampling_ratio_denominator;
            header_data_2(511 downto 384) <=    little_endian_PsrPacket.beamformer_version & 
                                                little_endian_PsrPacket.scan_id & 
                                                little_endian_PsrPacket.offset(0) &
                                                little_endian_PsrPacket.offset(1)(31 downto 16);
    ----------------------------
            header_data_3(127 downto 0)   <=    little_endian_PsrPacket.offset(1)(15 downto 0) & 
                                                little_endian_PsrPacket.offset(2) & 
                                                little_endian_PsrPacket.offset(3) & 
                                                zero_dword & zero_word;                                             
            header_data_3(255 downto 128) <=    zero_qword & zero_qword;  
            header_data_3(383 downto 256) <=    zero_qword & zero_qword; 
            header_data_3(511 downto 384) <=    zero_qword & zero_qword;

          end if;                                  
    end if;
end process;

---------------------------------------------------------------------------------------------------------------------------------------
-- Big endian into the 100G core, little endian mapping on a per field basis if field greater than a byte

little_endian_PsrPacket.packet_sequence_number              <= packet_sequence_number(7 downto 0) & packet_sequence_number(15 downto 8) & packet_sequence_number(23 downto 16) & packet_sequence_number(31 downto 24) &
                                                               packet_sequence_number(39 downto 32) & packet_sequence_number(47 downto 40) & packet_sequence_number(55 downto 48) & packet_sequence_number(63 downto 56);
                                                               
little_endian_PsrPacket.timestamp_attoseconds               <= PsrPacket_info.timestamp_attoseconds(7 downto 0) & PsrPacket_info.timestamp_attoseconds(15 downto 8) & PsrPacket_info.timestamp_attoseconds(23 downto 16) & PsrPacket_info.timestamp_attoseconds(31 downto 24) &
                                                               PsrPacket_info.timestamp_attoseconds(39 downto 32) & PsrPacket_info.timestamp_attoseconds(47 downto 40) & PsrPacket_info.timestamp_attoseconds(55 downto 48) & PsrPacket_info.timestamp_attoseconds(63 downto 56);
                                                               
little_endian_PsrPacket.timestamp_seconds                   <= PsrPacket_info.timestamp_seconds(7 downto 0) & PsrPacket_info.timestamp_seconds(15 downto 8) & PsrPacket_info.timestamp_seconds(23 downto 16) & PsrPacket_info.timestamp_seconds(31 downto 24);

little_endian_PsrPacket.channel_separation                  <= PsrPacket_info.channel_separation(7 downto 0) & PsrPacket_info.channel_separation(15 downto 8) & PsrPacket_info.channel_separation(23 downto 16) & PsrPacket_info.channel_separation(31 downto 24);

little_endian_PsrPacket.first_channel_frequency             <= PsrPacket_info.first_channel_frequency(7 downto 0) & PsrPacket_info.first_channel_frequency(15 downto 8) & PsrPacket_info.first_channel_frequency(23 downto 16) & PsrPacket_info.first_channel_frequency(31 downto 24) &
                                                               PsrPacket_info.first_channel_frequency(39 downto 32) & PsrPacket_info.first_channel_frequency(47 downto 40) & PsrPacket_info.first_channel_frequency(55 downto 48) & PsrPacket_info.first_channel_frequency(63 downto 56);

little_endian_PsrPacket.scale(0)                            <= scale_1(7 downto 0) & scale_1(15 downto 8) & scale_1(23 downto 16) & scale_1(31 downto 24);
little_endian_PsrPacket.scale(1)                            <= PsrPacket_info.scale(1)(7 downto 0) & PsrPacket_info.scale(1)(15 downto 8) & PsrPacket_info.scale(1)(23 downto 16) & PsrPacket_info.scale(1)(31 downto 24);
little_endian_PsrPacket.scale(2)                            <= PsrPacket_info.scale(2)(7 downto 0) & PsrPacket_info.scale(2)(15 downto 8) & PsrPacket_info.scale(2)(23 downto 16) & PsrPacket_info.scale(2)(31 downto 24);
little_endian_PsrPacket.scale(3)                            <= PsrPacket_info.scale(3)(7 downto 0) & PsrPacket_info.scale(3)(15 downto 8) & PsrPacket_info.scale(3)(23 downto 16) & PsrPacket_info.scale(3)(31 downto 24); 

little_endian_PsrPacket.first_channel_number                <= PsrPacket_info.first_channel_number(7 downto 0) & PsrPacket_info.first_channel_number(15 downto 8) & PsrPacket_info.first_channel_number(23 downto 16) & PsrPacket_info.first_channel_number(31 downto 24);

little_endian_PsrPacket.channels_per_packet                 <= PsrPacket_info.channels_per_packet(7 downto 0) & PsrPacket_info.channels_per_packet(15 downto 8);
little_endian_PsrPacket.valid_channels_per_packet           <= PsrPacket_info.valid_channels_per_packet(7 downto 0) & PsrPacket_info.valid_channels_per_packet(15 downto 8);
little_endian_PsrPacket.number_of_time_samples              <= PsrPacket_info.number_of_time_samples(7 downto 0) & PsrPacket_info.number_of_time_samples(15 downto 8);
little_endian_PsrPacket.beam_number                         <= beam_internal(7 downto 0) & beam_internal(15 downto 8);
 
little_endian_PsrPacket.magic_word                          <= PsrPacket_info.magic_word(7 downto 0) & PsrPacket_info.magic_word(15 downto 8) & PsrPacket_info.magic_word(23 downto 16) & PsrPacket_info.magic_word(31 downto 24);
-- BYTE FIELDS Start
little_endian_PsrPacket.packet_destination                  <= PsrPacket_info.packet_destination;
little_endian_PsrPacket.data_precision                      <= PsrPacket_info.data_precision; 
little_endian_PsrPacket.number_of_power_samples_averaged    <= PsrPacket_info.number_of_power_samples_averaged; 
little_endian_PsrPacket.number_of_time_samples_weight       <= PsrPacket_info.number_of_time_samples_weight;
little_endian_PsrPacket.oversampling_ratio_numerator        <= PsrPacket_info.oversampling_ratio_numerator;             
little_endian_PsrPacket.oversampling_ratio_denominator      <= PsrPacket_info.oversampling_ratio_denominator;
-- BYTE FIELDS Finish
little_endian_PsrPacket.beamformer_version                  <= PsrPacket_info.beamformer_version(7 downto 0) & PsrPacket_info.beamformer_version(15 downto 8);
little_endian_PsrPacket.scan_id                             <= PsrPacket_info.scan_id(7 downto 0) & PsrPacket_info.scan_id(15 downto 8) & PsrPacket_info.scan_id(23 downto 16) & PsrPacket_info.scan_id(31 downto 24) &
                                                               PsrPacket_info.scan_id(39 downto 32) & PsrPacket_info.scan_id(47 downto 40) & PsrPacket_info.scan_id(55 downto 48) & PsrPacket_info.scan_id(63 downto 56);
                                                               
little_endian_PsrPacket.offset(0)                           <= PsrPacket_info.offset(0)(7 downto 0) & PsrPacket_info.offset(0)(15 downto 8) & PsrPacket_info.offset(0)(23 downto 16) & PsrPacket_info.offset(0)(31 downto 24);
little_endian_PsrPacket.offset(1)                           <= PsrPacket_info.offset(1)(7 downto 0) & PsrPacket_info.offset(1)(15 downto 8) & PsrPacket_info.offset(1)(23 downto 16) & PsrPacket_info.offset(1)(31 downto 24); 
little_endian_PsrPacket.offset(2)                           <= PsrPacket_info.offset(2)(7 downto 0) & PsrPacket_info.offset(2)(15 downto 8) & PsrPacket_info.offset(2)(23 downto 16) & PsrPacket_info.offset(2)(31 downto 24);
little_endian_PsrPacket.offset(3)                           <= PsrPacket_info.offset(3)(7 downto 0) & PsrPacket_info.offset(3)(15 downto 8) & PsrPacket_info.offset(3)(23 downto 16) & PsrPacket_info.offset(3)(31 downto 24);


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
