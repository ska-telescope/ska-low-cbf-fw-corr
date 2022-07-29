LIBRARY ieee;
USE ieee.std_logic_1164.all;

PACKAGE CbfPsrHeader_pkg IS

TYPE t_CbfPsrHeader_scale_arr IS ARRAY(0 TO 4-1) OF STD_LOGIC_VECTOR(32-1 DOWNTO 0);
TYPE t_CbfPsrHeader_offset_arr IS ARRAY(0 TO 4-1) OF STD_LOGIC_VECTOR(32-1 DOWNTO 0);

TYPE CbfPsrHeader IS RECORD
    packet_sequence_number : STD_LOGIC_VECTOR(64-1 DOWNTO 0);
    timestamp_attoseconds : STD_LOGIC_VECTOR(64-1 DOWNTO 0);
    timestamp_seconds : STD_LOGIC_VECTOR(32-1 DOWNTO 0);
    channel_separation : STD_LOGIC_VECTOR(32-1 DOWNTO 0);
    first_channel_frequency : STD_LOGIC_VECTOR(64-1 DOWNTO 0);
    scale : t_CbfPsrHeader_scale_arr;
    first_channel_number : STD_LOGIC_VECTOR(32-1 DOWNTO 0);
    channels_per_packet : STD_LOGIC_VECTOR(16-1 DOWNTO 0);
    valid_channels_per_packet : STD_LOGIC_VECTOR(16-1 DOWNTO 0);
    number_of_time_samples : STD_LOGIC_VECTOR(16-1 DOWNTO 0);
    beam_number : STD_LOGIC_VECTOR(16-1 DOWNTO 0);
    magic_word : STD_LOGIC_VECTOR(32-1 DOWNTO 0);
    packet_destination : STD_LOGIC_VECTOR(8-1 DOWNTO 0);
    data_precision : STD_LOGIC_VECTOR(8-1 DOWNTO 0);
    number_of_power_samples_averaged : STD_LOGIC_VECTOR(8-1 DOWNTO 0);
    number_of_time_samples_weight : STD_LOGIC_VECTOR(8-1 DOWNTO 0);
    oversampling_ratio_numerator : STD_LOGIC_VECTOR(8-1 DOWNTO 0);
    oversampling_ratio_denominator : STD_LOGIC_VECTOR(8-1 DOWNTO 0);
    beamformer_version : STD_LOGIC_VECTOR(16-1 DOWNTO 0);
    scan_id : STD_LOGIC_VECTOR(64-1 DOWNTO 0);
    offset : t_CbfPsrHeader_offset_arr;
END RECORD;

type psr_packetiser_constants is record
    channels_per_packet             : STD_LOGIC_VECTOR(16-1 DOWNTO 0);
    valid_channels_per_packet       : STD_LOGIC_VECTOR(16-1 DOWNTO 0);
    number_of_time_samples          : STD_LOGIC_VECTOR(16-1 DOWNTO 0);
    oversampling_ratio_numerator    : STD_LOGIC_VECTOR(8-1 DOWNTO 0);
    oversampling_ratio_denominator  : STD_LOGIC_VECTOR(8-1 DOWNTO 0);
end record;

constant PST_metadata_constants : psr_packetiser_constants := (
                                    channels_per_packet             => x"0018",     --24
                                    valid_channels_per_packet       => x"0018",     --24
                                    number_of_time_samples          => x"0020",     --32
                                    oversampling_ratio_numerator    => x"04",
                                    oversampling_ratio_denominator  => x"03"
                                    );

constant null_scale : t_CbfPsrHeader_scale_arr := ((0) => (others=>'0'),
                                                   (1) => (others=>'0'),
                                                   (2) => (others=>'0'),
                                                   (3) => (others=>'0')
                                                   );
                                                   
constant null_offset : t_CbfPsrHeader_offset_arr :=     ((0) => (others=>'0'),
                                                         (1) => (others=>'0'),
                                                         (2) => (others=>'0'),
                                                         (3) => (others=>'0')
                                                         );                                                   

constant null_CbfPsrHeader : CbfPsrHeader := (
                                packet_sequence_number              => (others=>'0'),
                                timestamp_attoseconds               => (others=>'0'),
                                timestamp_seconds                   => (others=>'0'),
                                channel_separation                  => (others=>'0'),
                                first_channel_frequency             => (others=>'0'),
                                scale                               => null_scale,
                                first_channel_number                => (others=>'0'),
                                channels_per_packet                 => (others=>'0'),
                                valid_channels_per_packet           => (others=>'0'),
                                number_of_time_samples              => (others=>'0'),
                                beam_number                         => (others=>'0'),
                                magic_word                          => (others=>'0'),
                                packet_destination                  => (others=>'0'),
                                data_precision                      => (others=>'0'),
                                number_of_power_samples_averaged    => (others=>'0'),
                                number_of_time_samples_weight       => (others=>'0'),
                                oversampling_ratio_numerator        => (others=>'0'),
                                oversampling_ratio_denominator      => (others=>'0'),
                                beamformer_version                  => (others=>'0'),
                                scan_id                             => (others=>'0'),
                                offset                              => null_offset
                                );

-----------------------------
-- default values for system powerup no software config

constant default_scale : t_CbfPsrHeader_scale_arr := (  (0) => x"BADDCAFE",
                                                        (1) => x"BBAACAFF",
                                                        (2) => x"BADDCCFE",
                                                        (3) => x"BADCAFFE"
                                                      );
                                                   
constant default_offset : t_CbfPsrHeader_offset_arr :=  ((0) =>  x"11111111",
                                                         (1) =>  x"22222222",
                                                         (2) =>  x"33333333",
                                                         (3) =>  x"44444444"
                                                         );         
                                                         
constant default_PSTHeader : CbfPsrHeader := (
                                packet_sequence_number              => x"0000000000000001",
                                timestamp_attoseconds               => x"AD000000000000AD",
                                timestamp_seconds                   => x"BCBCBCBC",
                                channel_separation                  => x"50505050",
                                first_channel_frequency             => x"31415926535900FF",
                                scale                               => default_scale,
                                first_channel_number                => x"31415926",
                                channels_per_packet                 => PST_metadata_constants.channels_per_packet,
                                valid_channels_per_packet           => PST_metadata_constants.valid_channels_per_packet,
                                number_of_time_samples              => PST_metadata_constants.number_of_time_samples,
                                beam_number                         => x"0000",
                                magic_word                          => x"ABBADABA",
                                packet_destination                  => x"FF",
                                data_precision                      => x"CC",
                                number_of_power_samples_averaged    => x"34",
                                number_of_time_samples_weight       => x"56",
                                oversampling_ratio_numerator        => PST_metadata_constants.oversampling_ratio_numerator,
                                oversampling_ratio_denominator      => PST_metadata_constants.oversampling_ratio_denominator,
                                beamformer_version                  => x"0666",
                                scan_id                             => x"1D1D1D1D1D1D1D1D",
                                offset                              => default_offset
                                );


end CbfPsrHeader_pkg;