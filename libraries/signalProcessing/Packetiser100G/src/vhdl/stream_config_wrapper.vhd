----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: 30.10.2021
-- Design Name: 
-- Module Name: stream_config_wrapper - rtl
--
--
-- Additional Comments:
-- Wrapper for host/ARGs instructions.
-- 
----------------------------------------------------------------------------------


library IEEE, xpm, PSR_Packetiser_lib, common_lib, signal_processing_common;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use PSR_Packetiser_lib.ethernet_pkg.ALL;
use PSR_Packetiser_lib.CbfPsrHeader_pkg.ALL;
use xpm.vcomponents.all;
USE common_lib.common_pkg.ALL;
library technology_lib;
USE technology_lib.tech_mac_100g_pkg.ALL;
USE PSR_Packetiser_lib.Packetiser_packetiser_reg_pkg.ALL;

library UNISIM;
use UNISIM.VComponents.all;

entity stream_config_wrapper is
    Generic (
        beamformer_version      : STD_LOGIC_VECTOR(15 DOWNTO 0) := x"0014";
        g_INSTANCE              : INTEGER := 0
        
    );
    Port ( 
        i_clk400                : in std_logic;
        i_reset_400             : in std_logic;
        
        ---------------------------
            
        i_packetiser_reg_in           : in packetiser_config_in;
        o_packetiser_reg_out          : out packetiser_config_out;
        
        i_packetiser_data_in          : in packetiser_stream_in;
        
        i_packetiser_ctrl             : in packetiser_stream_ctrl;
        
        ethernet_config               : out ethernet_frame;
        ipv4_config                   : out IPv4_header;
        udp_config                    : out UDP_header;
        PsrPacket_config              : out CbfPsrHeader;
    
    
        enable_test_generator         : out std_logic;
        enabe_limited_runs            : out std_logic;
        enable_packetiser             : out std_logic;
        
        packet_generator_runs         : out std_logic_vector(31 downto 0);
        packet_generator_time_between : out std_logic_vector(31 downto 0);
        packet_generator_no_of_beams  : out std_logic_vector(3 downto 0)
    
    
    );
end stream_config_wrapper;

architecture rtl of stream_config_wrapper is
COMPONENT packetiser_bram_1024d_32w_tdp IS
  PORT (
    clka : IN STD_LOGIC;
    ena : IN STD_LOGIC;
    wea : IN STD_LOGIC_VECTOR(0 DOWNTO 0);
    addra : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
    dina : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
    douta : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    clkb : IN STD_LOGIC;
    enb : IN STD_LOGIC;
    web : IN STD_LOGIC_VECTOR(0 DOWNTO 0);
    addrb : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
    dinb : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
    doutb : OUT STD_LOGIC_VECTOR(31 DOWNTO 0)
  );
END COMPONENT;

-- DEFAULT VALUES FOR MINIMUM SETUP    
signal ethernet_config_int      : ethernet_frame    := default_ethernet_frame;
signal ipv4_config_int          : IPv4_header       := t_default_IPv4_header(g_INSTANCE);
signal udp_config_int           : UDP_header        := default_UDP_header;
signal PsrPacket_config_int     : CbfPsrHeader      := default_PSTHeader;

signal ipv4_chk_sum_calc        : std_logic_vector(31 downto 0);
signal ipv4_asm                 : std_logic_vector(15 downto 0);

signal clock            : std_logic;

signal load_count       : std_logic_vector(7 downto 0) := zero_byte;

signal packetiser_param_wren    : std_logic;
signal vc_to_freq_upper_wren    : std_logic;
signal vc_to_freq_lower_wren    : std_logic;
signal first_chan_num_mapper_wren : std_logic;

signal packetiser_rdata         : std_logic_vector(31 downto 0);
signal vc_to_freq_upper_rdata   : std_logic_vector(31 downto 0);
signal vc_to_freq_lower_rdata   : std_logic_vector(31 downto 0);
signal first_chan_num_mapper_rdata : std_logic_vector(31 downto 0);

signal Packetiser_parameter_ram_en      : std_logic;
signal Packetiser_parameter_ram_wr      : std_logic_vector(0 downto 0);
signal Packetiser_parameter_ram_addr    : std_logic_vector(9 downto 0);
signal Packetiser_parameter_ram_data    : std_logic_vector(31 downto 0);
signal Packetiser_parameter_ram_q       : std_logic_vector(31 downto 0);

signal vc_to_freq_en            : std_logic;
signal vc_to_freq_wr            : std_logic;
signal vc_to_freq_addr          : std_logic_vector(9 downto 0);
signal vc_to_freq_data          : std_logic_vector(31 downto 0);
signal vc_to_freq_upper_q       : std_logic_vector(31 downto 0);
signal vc_to_freq_lower_q       : std_logic_vector(31 downto 0);

signal vc_remapper_address      : std_logic_vector(9 downto 0);
signal first_chan_num_mapper_q  : std_logic_vector(31 downto 0);

signal bram_rst         : STD_LOGIC;
signal bram_clk         : STD_LOGIC;
signal bram_en          : STD_LOGIC;
signal bram_we_byte     : STD_LOGIC_VECTOR(3 DOWNTO 0);
signal bram_we          : STD_LOGIC_VECTOR(0 DOWNTO 0);
signal bram_addr        : STD_LOGIC_VECTOR(14 DOWNTO 0);
signal bram_wrdata      : STD_LOGIC_VECTOR(31 DOWNTO 0);
signal bram_rddata      : STD_LOGIC_VECTOR(31 DOWNTO 0);

signal bram_rd_mux_d1   : std_logic_vector(2 downto 0);
signal bram_rd_mux_d2   : std_logic_vector(2 downto 0);
signal bram_rd_mux_d3   : std_logic_vector(2 downto 0);

signal bram_en_shift    : std_logic;
signal bram_en_ram      : STD_LOGIC;

signal enable_packetiser_int        : std_logic;
signal enable_test_generator_int    : std_logic;
signal enabe_limited_runs_int       : std_logic;
signal packetiser_use_defaults      : std_logic;

signal packet_generator_runs_int           : std_logic_vector(31 downto 0) := x"00000010";
signal packet_generator_time_between_int   : std_logic_vector(31 downto 0) := x"00002000";
signal packet_generator_no_of_beams_int    : std_logic_vector(3 downto 0)  := x"7";

type frame_data_statemachine is (IDLE, LOAD, RUN);
signal frame_data_sm : frame_data_statemachine;

begin

sync_packet_registers_sig : entity signal_processing_common.sync
    Generic Map (
        USE_XPM     => true,
        WIDTH       => 4
    )
    Port Map ( 
        Clock_a                 => i_packetiser_reg_in.config_data_clk,
        Clock_b                 => i_clk400,
        data_in(0)              => i_packetiser_ctrl.instruct(0),
        data_in(1)              => i_packetiser_ctrl.instruct(1),
        data_in(2)              => i_packetiser_ctrl.instruct(2),
        data_in(3)              => i_packetiser_ctrl.instruct(3),
        data_out(0)             => enable_packetiser_int,
        data_out(1)             => enable_test_generator_int,
        data_out(2)             => enabe_limited_runs_int,
        data_out(3)             => packetiser_use_defaults
    );
    
--------------------------------------------------------------------------
-- parameter rams

bram_clk        <= i_packetiser_reg_in.config_data_clk;
bram_wrdata     <= i_packetiser_reg_in.config_data;
bram_addr       <= i_packetiser_reg_in.config_data_addr;
bram_we(0)      <= i_packetiser_reg_in.config_data_wr;  
bram_en         <= i_packetiser_reg_in.config_data_en;

--bram_we(0)              <= bram_we_byte(3) AND bram_we_byte(2) AND bram_we_byte(1) AND bram_we_byte(0);

packetiser_param_wren   <=  '1' when (bram_addr(14 downto 12) = "000") AND bram_we(0) = '1' else
                            '0';

vc_to_freq_lower_wren   <=  '1' when (bram_addr(14 downto 12) = "001") AND bram_we(0) = '1' else
                            '0';
                            
vc_to_freq_upper_wren   <=  '1' when (bram_addr(14 downto 12) = "010") AND bram_we(0) = '1' else
                            '0';

first_chan_num_mapper_wren  <=  '1' when (bram_addr(14 downto 12) = "011") AND bram_we(0) = '1' else
                                '0';

bram_return_data_proc : process(bram_clk)
begin
    if rising_edge(bram_clk) then
        bram_rd_mux_d1 <= bram_addr(14 downto 12);
        bram_rd_mux_d2 <= bram_rd_mux_d1;
        
        if bram_rd_mux_d2 = "000" then
            bram_rddata <= packetiser_rdata;
        elsif bram_rd_mux_d2 = "001" then
            bram_rddata <= vc_to_freq_lower_rdata;
        elsif bram_rd_mux_d2 = "010" then
            bram_rddata <= vc_to_freq_upper_rdata;
        else
            bram_rddata <= first_chan_num_mapper_rdata;
        end if;

        if bram_en = '1' then       -- power optimisation
            bram_en_shift <= '1';
        else
            bram_en_shift <= '0';
        end if;
    end if;
end process;

o_packetiser_reg_out.config_data_out <= bram_rddata;

bram_en_ram <= '1' when bram_en = '1' else
                bram_en_shift;


packetiser_params : packetiser_bram_1024d_32w_tdp
PORT MAP (
    --
    clka            => bram_clk,
    ena             => bram_en_ram,
    wea(0)          => packetiser_param_wren,
    addra           => bram_addr(11 downto 2),
    dina            => bram_wrdata,
    douta           => packetiser_rdata,    
    
    clkb            => i_clk400,
    enb             => Packetiser_parameter_ram_en,
    web             => Packetiser_parameter_ram_wr,
    addrb           => Packetiser_parameter_ram_addr,
    dinb            => Packetiser_parameter_ram_data,
    doutb           => Packetiser_parameter_ram_q
  );


vc_to_freq_upper : packetiser_bram_1024d_32w_tdp
PORT MAP (
    --
    clka            => bram_clk,
    ena             => bram_en_ram,
    wea(0)          => vc_to_freq_upper_wren,
    addra           => bram_addr(11 downto 2),
    dina            => bram_wrdata,
    douta           => vc_to_freq_upper_rdata,    
    
    clkb            => i_clk400,
    enb             => vc_to_freq_en,
    web(0)          => vc_to_freq_wr,
    addrb           => vc_remapper_address,--vc_to_freq_addr,
    dinb            => vc_to_freq_data,
    doutb           => vc_to_freq_upper_q
  );
  
vc_to_freq_lower : packetiser_bram_1024d_32w_tdp
PORT MAP (
    --
    clka            => bram_clk,
    ena             => bram_en_ram,
    wea(0)          => vc_to_freq_lower_wren,
    addra           => bram_addr(11 downto 2),
    dina            => bram_wrdata,
    douta           => vc_to_freq_lower_rdata,    
    
    clkb            => i_clk400,
    enb             => vc_to_freq_en,
    web(0)          => vc_to_freq_wr,
    addrb           => vc_remapper_address,--vc_to_freq_addr,
    dinb            => vc_to_freq_data,
    doutb           => vc_to_freq_lower_q
  );

vc_to_freq_en       <= '1';
vc_to_freq_wr       <= '0';     -- don't write to the RAM, dual port for software verification.

vc_remapper_address <= i_packetiser_data_in.PST_virtual_channel;

vc_to_freq_data     <= zero_dword;

--first_chan_freq     <= vc_to_freq_upper_q & vc_to_freq_lower_q;


first_chan_num_mapper : packetiser_bram_1024d_32w_tdp
PORT MAP (
    --
    clka            => bram_clk,
    ena             => bram_en_ram,
    wea(0)          => first_chan_num_mapper_wren,
    addra           => bram_addr(11 downto 2),
    dina            => bram_wrdata,
    douta           => first_chan_num_mapper_rdata,    
    
    clkb            => i_clk400,
    enb             => vc_to_freq_en,
    web(0)          => vc_to_freq_wr,
    addrb           => vc_remapper_address,
    dinb            => vc_to_freq_data,
    doutb           => first_chan_num_mapper_q
  );
  



--------------------------------------------------------------------------

Packetiser_parameter_ram_addr               <= "000" & load_count(7 downto 1);


load_frame_fields_proc : process(i_clk400)
begin        
    if rising_edge(i_clk400) then
        if i_reset_400 = '1' then
            frame_data_sm                   <= IDLE;
            load_count                      <= zero_byte;
            Packetiser_parameter_ram_wr(0)  <= '0';
            Packetiser_parameter_ram_en     <= '0';
            Packetiser_parameter_ram_data   <= zero_dword;
            ethernet_config_int             <= default_ethernet_frame;
            ipv4_config_int                 <= t_default_IPv4_header(g_INSTANCE);
            udp_config_int                  <= default_UDP_header;
            PsrPacket_config_int            <= default_PSTHeader;
        else
            PsrPacket_config_int.channels_per_packet            <= PST_metadata_constants.channels_per_packet;
            PsrPacket_config_int.valid_channels_per_packet      <= PST_metadata_constants.valid_channels_per_packet;
            PsrPacket_config_int.number_of_time_samples         <= PST_metadata_constants.number_of_time_samples;
            PsrPacket_config_int.oversampling_ratio_numerator   <= PST_metadata_constants.oversampling_ratio_numerator;
            PsrPacket_config_int.oversampling_ratio_denominator <= PST_metadata_constants.oversampling_ratio_denominator;
            
            PsrPacket_config_int.beamformer_version             <= beamformer_version;
            PsrPacket_config_int.first_channel_number           <= first_chan_num_mapper_q;
            PsrPacket_config_int.first_channel_frequency        <= vc_to_freq_upper_q & vc_to_freq_lower_q;
            
            case frame_data_sm is
                when IDLE =>
                    -- look for enabler, load values then trigger PSR
                    if enable_packetiser_int = '1' then
                        frame_data_sm           <= LOAD;
                        ethernet_config_int     <= default_ethernet_frame;
                        ipv4_config_int         <= t_default_IPv4_header(g_INSTANCE);
                        udp_config_int          <= default_UDP_header;
                        PsrPacket_config_int    <= default_PSTHeader;
                        
                        if packetiser_use_defaults = '1' then
                            load_count              <= x"5F";
                        else
                            load_count              <= zero_byte;
                        end if;
                    end if;
                    Packetiser_parameter_ram_wr(0)  <= '0';                    
                    enable_test_generator           <= '0';
                    enabe_limited_runs              <= '0';
                    enable_packetiser               <= '0';
                    
                    Packetiser_parameter_ram_en     <= '1';
                    Packetiser_parameter_ram_data   <= zero_dword;
                    
                    ipv4_chk_sum_calc               <= zero_dword;
                    
                when LOAD =>
                    load_count                  <= std_logic_vector(unsigned(load_count) + 1);

                    if load_count = x"02" then                                                                  -- RAM address 0
                        ethernet_config_int.dst_mac(31 downto 0)    <= Packetiser_parameter_ram_q;
                    end if;
                    if load_count = x"04" then                                                                  -- RAM address 1
                        ethernet_config_int.dst_mac(47 downto 32)   <= Packetiser_parameter_ram_q(15 downto 0);
                    end if;
                    if load_count = x"06" then                                                                  -- RAM address 2
                        ethernet_config_int.src_mac(31 downto 0)    <= Packetiser_parameter_ram_q;
                    end if;
                    if load_count = x"08" then                                                                  -- RAM address 3
                        ethernet_config_int.src_mac(47 downto 32)   <= Packetiser_parameter_ram_q(15 downto 0);
                    end if;
                    if load_count = x"0A" then                                                                  -- RAM address 4
                        ethernet_config_int.eth_type                <= Packetiser_parameter_ram_q(15 downto 0);
                    end if;
                    if load_count = x"0C" then                                                                  -- RAM address 5
                        --ipv4_config_int.version                     <= Packetiser_parameter_ram_q(31 downto 28);
                        --ipv4_config_int.header_length               <= Packetiser_parameter_ram_q(27 downto 24);
                        ipv4_config_int.type_of_service             <= Packetiser_parameter_ram_q(23 downto 16);
                        ipv4_config_int.total_length                <= Packetiser_parameter_ram_q(15 downto 0);
                        
                    end if;
                    if load_count = x"0E" then                                                                  -- RAM address 6
                        ipv4_config_int.id                          <= Packetiser_parameter_ram_q(31 downto 16);
                        --ipv4_config_int.ip_flags                    <= Packetiser_parameter_ram_q(15 downto 13);
                        --ipv4_config_int.fragment_off                <= Packetiser_parameter_ram_q(12 downto 0);
                    end if;
                    if load_count = x"10" then                                                                  -- RAM address 7
                        ipv4_config_int.TTL                         <= Packetiser_parameter_ram_q(31 downto 24);
                        ipv4_config_int.protocol                    <= Packetiser_parameter_ram_q(23 downto 16);
                        --ipv4_config_int.header_chk_sum              <= Packetiser_parameter_ram_q(15 downto 0);
                    end if;
                    if load_count = x"12" then                                                                  -- RAM address 8
                        ipv4_config_int.src_addr                    <= Packetiser_parameter_ram_q; 
                    end if;
                    if load_count = x"14" then                                                                  -- RAM address 9
                        ipv4_config_int.dst_addr                    <= Packetiser_parameter_ram_q;
                    end if;
                    if load_count = x"16" then                                                                  -- RAM address 10
                        udp_config_int.src_port                     <= Packetiser_parameter_ram_q(31 downto 16); 
                        udp_config_int.dst_port                     <= Packetiser_parameter_ram_q(15 downto 0);
                    end if;
                    if load_count = x"18" then                                                                  -- RAM address 11
                        udp_config_int.length                       <= Packetiser_parameter_ram_q(31 downto 16); 
                        udp_config_int.checksum                     <= Packetiser_parameter_ram_q(15 downto 0);
                    end if;
                    if load_count = x"1A" then                                                                  -- RAM address 12
                        PsrPacket_config_int.packet_sequence_number(63 downto 32)   <= Packetiser_parameter_ram_q;
                    end if;
                    if load_count = x"1C" then                                                                  -- RAM address 13
                        PsrPacket_config_int.packet_sequence_number(31 downto 0)    <= Packetiser_parameter_ram_q;
                    end if;
                    if load_count = x"1E" then                                                                  -- RAM address 14
                        PsrPacket_config_int.timestamp_attoseconds(63 downto 32)    <= Packetiser_parameter_ram_q;
                    end if;
                    if load_count = x"20" then                                                                  -- RAM address 15
                        PsrPacket_config_int.timestamp_attoseconds(31 downto 0)     <= Packetiser_parameter_ram_q;
                    end if;
                    if load_count = x"22" then                                                                  -- RAM address 16
                        PsrPacket_config_int.timestamp_seconds                      <= Packetiser_parameter_ram_q;
                    end if;
                    if load_count = x"24" then                                                                  -- RAM address 17
                        PsrPacket_config_int.channel_separation                     <= Packetiser_parameter_ram_q;
                    end if;
--                    if load_count = x"26" then                                                                  -- RAM address 18
--                        PsrPacket_config_int.first_channel_frequency(63 downto 32)  <= Packetiser_parameter_ram_q;
--                    end if;
--                    if load_count = x"28" then                                                                  -- RAM address 19
--                        PsrPacket_config_int.first_channel_frequency(31 downto 0)   <= Packetiser_parameter_ram_q;
--                    end if;
                    if load_count = x"2A" then                                                                  -- RAM address 20
                        PsrPacket_config_int.scale(0)                               <= Packetiser_parameter_ram_q;
                    end if;
                    if load_count = x"2C" then                                                                  -- RAM address 21
                        PsrPacket_config_int.scale(1)                               <= Packetiser_parameter_ram_q;
                    end if;
                    if load_count = x"2E" then                                                                  -- RAM address 22
                        PsrPacket_config_int.scale(2)                               <= Packetiser_parameter_ram_q;
                    end if;
                    if load_count = x"30" then                                                                  -- RAM address 23
                        PsrPacket_config_int.scale(3)                               <= Packetiser_parameter_ram_q;
                    end if;
--                    if load_count = x"32" then                                                                  -- RAM address 24
--                        PsrPacket_config_int.first_channel_number                   <= Packetiser_parameter_ram_q;
--                    end if;
--                    if load_count = x"34" then                                                                  -- RAM address 25
--                        PsrPacket_config_int.channels_per_packet                    <= Packetiser_parameter_ram_q(15 downto 0);
--                    end if;
--                    if load_count = x"36" then                                                                  -- RAM address 26
--                        PsrPacket_config_int.valid_channels_per_packet              <= Packetiser_parameter_ram_q(15 downto 0);
--                    end if;
--                    if load_count = x"38" then                                                                  -- RAM address 27
--                        PsrPacket_config_int.number_of_time_samples                 <= Packetiser_parameter_ram_q(15 downto 0);
--                    end if;
                    if load_count = x"3A" then                                                                  -- RAM address 28
                        PsrPacket_config_int.beam_number                            <= Packetiser_parameter_ram_q(15 downto 0);
                    end if;
                    if load_count = x"3C" then                                                                  -- RAM address 29
                        PsrPacket_config_int.magic_word                             <= Packetiser_parameter_ram_q;
                    end if;
                    if load_count = x"3E" then                                                                  -- RAM address 30
                        PsrPacket_config_int.packet_destination                     <= Packetiser_parameter_ram_q(7 downto 0);
                    end if;
                    if load_count = x"40" then                                                                  -- RAM address 31
                        PsrPacket_config_int.data_precision                         <= Packetiser_parameter_ram_q(7 downto 0);
                    end if;
                    if load_count = x"42" then                                                                  -- RAM address 32
                        PsrPacket_config_int.number_of_power_samples_averaged       <= Packetiser_parameter_ram_q(7 downto 0);
                    end if;
                    if load_count = x"44" then                                                                  -- RAM address 33
                        PsrPacket_config_int.number_of_time_samples_weight          <= Packetiser_parameter_ram_q(7 downto 0);
                    end if;
--                    if load_count = x"46" then                                                                  -- RAM address 34
--                        PsrPacket_config_int.oversampling_ratio_numerator           <= Packetiser_parameter_ram_q(7 downto 0);
--                    end if;
--                    if load_count = x"48" then                                                                  -- RAM address 35
--                        PsrPacket_config_int.oversampling_ratio_denominator         <= Packetiser_parameter_ram_q(7 downto 0);
--                    end if;
--                    if load_count = x"4A" then                                                                  -- RAM address 36
--                        PsrPacket_config_int.beamformer_version                     <= Packetiser_parameter_ram_q(15 downto 0);
--                    end if;
                    if load_count = x"4C" then                                                                  -- RAM address 37
                        PsrPacket_config_int.scan_id(63 downto 32)                  <= Packetiser_parameter_ram_q;
                    end if;
                    if load_count = x"4E" then                                                                  -- RAM address 38
                        PsrPacket_config_int.scan_id(31 downto 0)                   <= Packetiser_parameter_ram_q;
                    end if;
                    if load_count = x"50" then                                                                  -- RAM address 39
                        PsrPacket_config_int.offset(0)                              <= Packetiser_parameter_ram_q;
                    end if;
                    if load_count = x"52" then                                                                  -- RAM address 40
                        PsrPacket_config_int.offset(1)                              <= Packetiser_parameter_ram_q;
                    end if;
                    if load_count = x"54" then                                                                  -- RAM address 41
                        PsrPacket_config_int.offset(2)                              <= Packetiser_parameter_ram_q;
                    end if;
                    if load_count = x"56" then                                                                  -- RAM address 42
                        PsrPacket_config_int.offset(3)                              <= Packetiser_parameter_ram_q;
                    end if;
                
                    -- PACKET GENERATOR PARAMETERS
                
                    if load_count = x"58" then                                                                  -- RAM address 43
                        packet_generator_runs_int                               <= Packetiser_parameter_ram_q;
                    end if;
                    if load_count = x"5A" then                                                                  -- RAM address 44
                        packet_generator_time_between_int                       <= Packetiser_parameter_ram_q;
                    end if;
                    if load_count = x"5C" then                                                                  -- RAM address 45
                        packet_generator_no_of_beams_int                        <= Packetiser_parameter_ram_q(3 downto 0);
                    end if;
                
-- begin header checksum                
                    if load_count = x"60" then
                        ipv4_asm                            <= ipv4_config_int.version & ipv4_config_int.header_length & ipv4_config_int.type_of_service;
                    end if;
                    if load_count = x"61" then
                        ipv4_chk_sum_calc                   <= std_logic_vector(unsigned(ipv4_chk_sum_calc) + unsigned(ipv4_asm));
                    end if;
                
                    if load_count = x"62" then
                        ipv4_asm                            <= ipv4_config_int.total_length;
                    end if;
                    if load_count = x"63" then
                        ipv4_chk_sum_calc                   <= std_logic_vector(unsigned(ipv4_chk_sum_calc) + unsigned(ipv4_asm));
                    end if;
                    
                    if load_count = x"64" then
                        ipv4_asm                            <= ipv4_config_int.id;
                    end if;
                    if load_count = x"65" then
                        ipv4_chk_sum_calc                   <= std_logic_vector(unsigned(ipv4_chk_sum_calc) + unsigned(ipv4_asm));
                    end if;
                    
                    if load_count = x"66" then
                        ipv4_asm                            <= ipv4_config_int.ip_flags & ipv4_config_int.fragment_off;
                    end if;
                    if load_count = x"67" then
                        ipv4_chk_sum_calc                   <= std_logic_vector(unsigned(ipv4_chk_sum_calc) + unsigned(ipv4_asm));
                    end if;
                    
                    if load_count = x"68" then
                        ipv4_asm                            <= ipv4_config_int.TTL & ipv4_config_int.protocol;
                    end if;
                    if load_count = x"69" then
                        ipv4_chk_sum_calc                   <= std_logic_vector(unsigned(ipv4_chk_sum_calc) + unsigned(ipv4_asm));
                    end if;

                    if load_count = x"6A" then
                        ipv4_asm                            <= ipv4_config_int.src_addr(15 downto 0);
                    end if;
                    if load_count = x"6B" then
                        ipv4_chk_sum_calc                   <= std_logic_vector(unsigned(ipv4_chk_sum_calc) + unsigned(ipv4_asm));
                    end if;
                    
                    if load_count = x"6C" then
                        ipv4_asm                            <= ipv4_config_int.dst_addr(15 downto 0);
                    end if;
                    if load_count = x"6D" then
                        ipv4_chk_sum_calc                   <= std_logic_vector(unsigned(ipv4_chk_sum_calc) + unsigned(ipv4_asm));
                    end if;

                    if load_count = x"6E" then
                        ipv4_asm                            <= ipv4_config_int.src_addr(31 downto 16);
                    end if;
                    if load_count = x"6F" then
                        ipv4_chk_sum_calc                   <= std_logic_vector(unsigned(ipv4_chk_sum_calc) + unsigned(ipv4_asm));
                    end if;
                    
                    if load_count = x"70" then
                        ipv4_asm                            <= ipv4_config_int.dst_addr(31 downto 16);
                    end if;
                    if load_count = x"71" then
                        ipv4_chk_sum_calc                   <= std_logic_vector(unsigned(ipv4_chk_sum_calc) + unsigned(ipv4_asm));
                    end if;

                    if load_count = x"72" then
                        ipv4_chk_sum_calc                   <= zero_word & std_logic_vector(unsigned(ipv4_chk_sum_calc(15 downto 0)) + unsigned(ipv4_chk_sum_calc(31 downto 16)));
                    end if;
                
                    if load_count = x"73" then
                        ipv4_chk_sum_calc                   <= NOT ipv4_chk_sum_calc;
                    end if;
                
                    if load_count = x"74" then
                        ipv4_config_int.header_chk_sum      <= ipv4_chk_sum_calc(15 downto 0);
                    end if;
                    
                
                    if load_count = x"81" then
                        frame_data_sm       <= RUN;
                    end if;
                    
                when RUN =>
                    enable_test_generator           <= enable_test_generator_int;
                    enabe_limited_runs              <= enabe_limited_runs_int;
                    enable_packetiser               <= '1';
                    
                    if enable_packetiser_int = '0' then
                        frame_data_sm       <= IDLE;
                    end if;
                    
                when OTHERS =>
                    frame_data_sm       <= IDLE;
                    
            end case;
        end if;
    end if;
end process;


packet_generator_runs               <= packet_generator_runs_int;
packet_generator_time_between       <= packet_generator_time_between_int;
packet_generator_no_of_beams        <= packet_generator_no_of_beams_int;





ethernet_config     <= ethernet_config_int;
ipv4_config         <= ipv4_config_int;
udp_config          <= udp_config_int;
PsrPacket_config    <= PsrPacket_config_int;  


end rtl;
