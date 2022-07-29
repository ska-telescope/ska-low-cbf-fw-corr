LIBRARY ieee;
USE ieee.std_logic_1164.all;

PACKAGE CodifHeader_pkg IS


-- Constructed in transmission order.
TYPE CodifHeader IS RECORD
    -- Word 0
    data_frame                              : STD_LOGIC_VECTOR(31 DOWNTO 0);
    epoch_offset                            : STD_LOGIC_VECTOR(31 DOWNTO 0);
    -- Word 1
    reference_epoch                         : STD_LOGIC_VECTOR(7 DOWNTO 0);
    sample_size                             : STD_LOGIC_VECTOR(7 DOWNTO 0);
    small_fields                            : STD_LOGIC_VECTOR(15 DOWNTO 0);    -- 15   = Not Voltage
                                                                                -- 14   = Invalid
                                                                                -- 13   = Complex
                                                                                -- 12   = Cal Enabled
                                                                                -- 11:8 = Sample Representation
                                                                                -- 7:3  = Version
                                                                                -- 2:0  = Protocol
    reserved_field                          : STD_LOGIC_VECTOR(15 DOWNTO 0);
    alignment_period                        : STD_LOGIC_VECTOR(15 DOWNTO 0);    
    -- Word 2
    thread_ID                               : STD_LOGIC_VECTOR(15 DOWNTO 0);
    group_ID                                : STD_LOGIC_VECTOR(15 DOWNTO 0);
    secondary_ID                            : STD_LOGIC_VECTOR(15 DOWNTO 0);
    station_ID                              : STD_LOGIC_VECTOR(15 DOWNTO 0);    
    -- Word 3
    channels                                : STD_LOGIC_VECTOR(15 DOWNTO 0);
    sample_block_length                     : STD_LOGIC_VECTOR(15 DOWNTO 0);
    data_array_length                       : STD_LOGIC_VECTOR(31 DOWNTO 0);    
    -- Word 4    
    sample_periods_per_alignment_period     : STD_LOGIC_VECTOR(63 DOWNTO 0);
    -- Word 5
    synchronisation_sequence                : STD_LOGIC_VECTOR(31 DOWNTO 0);    
    metadata_ID                             : STD_LOGIC_VECTOR(15 DOWNTO 0);
    metadata_bits_upper                     : STD_LOGIC_VECTOR(15 DOWNTO 0);
    -- Word 6
    metadata_bits_mid                       : STD_LOGIC_VECTOR(63 DOWNTO 0);
    -- Word 7 
    metadata_bits_lower                     : STD_LOGIC_VECTOR(63 DOWNTO 0);   
END RECORD;



constant null_CodifHeader : CodifHeader := (
                                data_frame                              => (others => '0'),
                                epoch_offset                            => (others => '0'),
                                reference_epoch                         => (others => '0'),
                                sample_size                             => (others => '0'),
                                small_fields                            => (others => '0'),
                                reserved_field                          => (others => '0'),    
                                alignment_period                        => (others => '0'),
                                thread_ID                               => (others => '0'),
                                group_ID                                => (others => '0'),
                                secondary_ID                            => (others => '0'),
                                station_ID                              => (others => '0'),
                                channels                                => (others => '0'),                                
                                sample_block_length                     => (others => '0'),
                                data_array_length                       => (others => '0'),
                                sample_periods_per_alignment_period     => (others => '0'),
                                synchronisation_sequence                => (others => '0'),
                                metadata_ID                             => (others => '0'),
                                metadata_bits_upper                     => (others => '0'),
                                metadata_bits_mid                       => (others => '0'),
                                metadata_bits_lower                     => (others => '0')
                                );

end CodifHeader_pkg;