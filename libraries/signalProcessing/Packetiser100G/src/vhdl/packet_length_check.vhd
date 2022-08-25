----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- Create Date: 30.10.2021 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- Logic to check expected packet lenth of incoming data stream matches format.
--
-- Also pre-align the data before writing into FIFO, assuming single clock domain but this can be scaled to two easily.
--
--
-- It wil cache the data and play it out when the arbiter selects this interface.
-- there are 3 streams in a PST playout.
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

entity packet_length_check is
    Generic (
        FIFO_CACHE_DEPTH                : integer := 1024
    );
    Port ( 
        i_clk400                        : in std_logic;
        i_reset_400                     : in std_logic;
    
        o_invalid_packet                : out std_logic;
        
        i_stream_enable                 : in std_logic;
        i_wr_to_cmac                    : in std_logic;
        
        o_stats                         : out packetiser_stats;
        
        o_fifo_data_used                : out std_logic_vector(ceil_log2(FIFO_CACHE_DEPTH) downto 0);
    
        i_packetiser_data_in            : in packetiser_stream_in;
        o_packetiser_data_out           : out packetiser_stream_out;
        
        o_packetiser_data_to_former     : out packetiser_stream_in;
        i_packetiser_data_to_former     : in packetiser_stream_out
        
    );
end packet_length_check;

architecture rtl of packet_length_check is

signal shift_in             : std_logic_vector(511 downto 0) := zero_512;
signal shift_remain         : std_logic_vector(79 downto 0);    -- 80 bits, absed on where PST header finishes in LBUS.
signal shift_in_d1          : std_logic_vector(511 downto 0) := zero_512;
signal shift_cache          : std_logic_vector(63 downto 0);

signal fifo_data            : std_logic_vector(511 downto 0);
signal fifo_wr              : std_logic;
signal fifo_rd              : std_logic;
signal fifo_q               : std_logic_vector(511 downto 0);
signal fifo_reset           : std_logic;
signal fifo_empty           : std_logic;
signal fifo_rd_count        : std_logic_vector(ceil_log2(FIFO_CACHE_DEPTH) downto 0);

constant BUFF_FIFO_WIDTH        : integer := 64;
signal buff_fifo_data           : std_logic_vector((BUFF_FIFO_WIDTH - 1) downto 0);
signal buff_fifo_wr             : std_logic;
signal buff_fifo_rd             : std_logic;
signal buff_fifo_q              : std_logic_vector((BUFF_FIFO_WIDTH - 1) downto 0);
signal buff_fifo_empty          : std_logic;
      

signal data_valid_int               : std_logic;
signal data_valid_int_d1            : std_logic_vector(5 downto 0);

signal PST_virtual_channel_cache    : std_logic_vector(9 downto 0);
signal PST_beam_cache               : std_logic_vector(7 downto 0);
signal PST_time_ref_cache           : std_logic_vector(36 downto 0);

signal reset_enable                 : std_logic_vector(3 downto 0);
signal trigger_dump                 : std_logic;

signal signal_data_wr_count         : integer range 0 to 1023 := 0;
signal signal_data_wr_count_cache   : integer range 0 to 1023 := 0;

signal fifo_wr_every_8              : std_logic_vector(3 downto 0);

type inc_data_statemachine is (IDLE, DATA, FLUSH_FIFO, FINISH, HAND_OFF);
signal inc_data_sm : inc_data_statemachine;
signal inc_data_sm_d : inc_data_statemachine;

signal invalid_packet               : std_logic;

signal process_data_count           : integer range 0 to 1023 := 0;

signal valid_packet_counter                     : std_logic_vector(31 downto 0) := zero_dword;
signal invalid_packet_counter                   : std_logic_vector(31 downto 0) := zero_dword;
signal disregarded_packets_master_enable        : std_logic_vector(31 downto 0) := zero_dword;
signal packets_to_ethernet_serialiser_counter   : std_logic_vector(31 downto 0) := zero_dword;

signal wr_to_cmac_d                 : std_logic;

begin

inc_processing : process(i_clk400)
begin
    if rising_edge(i_clk400) then
        shift_cache                     <= i_packetiser_data_in.data(63 downto 0);
        -- SHIFT in 64 bit data for 512
        if (fifo_wr_every_8(2 downto 0) = "010") then --OR (i_packetiser_data_in.data_in_wr = '1' AND data_valid_int = '0') then
            shift_in(127 downto 0)      <= shift_cache & i_packetiser_data_in.data(63 downto 0);
        end if;
        if fifo_wr_every_8(2 downto 0)  = "100" then
            shift_in(255 downto 128)    <= shift_cache & i_packetiser_data_in.data(63 downto 0);
        end if;
        if fifo_wr_every_8(2 downto 0)  = "110" then
            shift_in(383 downto 256)    <= shift_cache & i_packetiser_data_in.data(63 downto 0);
        end if;
        if fifo_wr_every_8(2 downto 0)  = "000" then
            shift_in(511 downto 384)    <= shift_cache & i_packetiser_data_in.data(63 downto 0);
        end if; 

        -- align based on LBUS and header
        shift_in_d1(127 downto 0)   <= shift_remain                & shift_in(127 downto 80); 
        shift_in_d1(255 downto 128) <= shift_in(79 downto 0)       & shift_in(255 downto 208);
        shift_in_d1(383 downto 256) <= shift_in(207 downto 128)    & shift_in(383 downto 336);
        shift_in_d1(511 downto 384) <= shift_in(335 downto 256)    & shift_in(511 downto 464);
        
        shift_remain(79 downto 0)   <= shift_in(463 downto 384);
        
        
        --shift_in_d1                 <= shift_in_d1; 

        if i_packetiser_data_in.data_in_wr = '1' OR data_valid_int_d1(4) = '1' then         -- valid delay to capture trailing.
            fifo_wr_every_8           <= std_logic_vector(unsigned(fifo_wr_every_8) + 1);
        else
            fifo_wr_every_8           <= x"0";
        end if;
        
        
        fifo_wr     <= ((NOT fifo_wr_every_8(2)) AND (fifo_wr_every_8(1)) AND (NOT fifo_wr_every_8(0)) AND data_valid_int_d1(5));  -- writing every 8 as we are converting 64 to 512

        fifo_data   <= shift_in_d1; --shift_in(431 downto 0) & shift_in_d1(511 downto 432);
           
    end if;
end process;

o_packetiser_data_out.data_in_rdy               <= i_packetiser_data_to_former.data_in_rdy;

o_packetiser_data_out.in_rst                    <= '0'; 


--------------------------------------------------------
-- To data former
o_packetiser_data_to_former.data_clk            <= '0';             --NOT USED
o_packetiser_data_to_former.data_in_wr          <= fifo_rd;
o_packetiser_data_to_former.data(511 downto 0)  <= fifo_q;
o_packetiser_data_to_former.bytes_to_transmit   <= "00" & x"000";   --NOT USED

o_packetiser_data_to_former.PST_virtual_channel <= PST_virtual_channel_cache;
o_packetiser_data_to_former.PST_beam            <= PST_beam_cache;
o_packetiser_data_to_former.PST_time_ref        <= PST_time_ref_cache;


o_invalid_packet                                <= invalid_packet;
--------------------------------------------------------------------------------
-- capture packet from the signal processing.
-- if not 775 deep for PST, then reset the FIFO

byte_check : process(i_clk400)
begin
    if rising_edge(i_clk400) then
        data_valid_int                  <= i_packetiser_data_in.data_in_wr;
        data_valid_int_d1(0)            <= data_valid_int;
        data_valid_int_d1(5 downto 1)   <= data_valid_int_d1(4 downto 0);
        
        -- if invalid packet is detected then skip this streams turn
        inc_data_sm_d <= inc_data_sm;
        
        

        --if i_packetiser_data_to_former.data_in_rdy = '0' then
        if i_reset_400 = '1' then
            inc_data_sm                 <= IDLE;
            --data_valid_int              <= '0';
            reset_enable                <= x"0";
            process_data_count          <= 0;
            fifo_rd                     <= '0';
            invalid_packet              <= '0';
            
            buff_fifo_wr                <= '0';
            buff_fifo_rd                <= '0';
        else
            case inc_data_sm is
                when IDLE => 
                    -- transfer finished, check length
--                    if data_valid_int_d1(2 downto 0) = "100" AND fifo_empty = '0' then
--                        inc_data_sm <= DATA;
--                    end if;
                    
                    -- assume once the right amount of data is in there we can stream.
                    if fifo_rd_count >= "00001100001" AND (i_packetiser_data_to_former.data_in_rdy = '1') then -- 97
                        inc_data_sm <= DATA;
                    end if;
                    
                    reset_enable        <= x"0";
                    process_data_count  <= 0;
                    fifo_rd             <= '0';
                    buff_fifo_rd        <= '0';
                
                when DATA =>
                    if signal_data_wr_count_cache = 775 then  -- all good!
                        inc_data_sm     <= FINISH;
                    else                                -- probably bad!
                        inc_data_sm     <= FLUSH_FIFO;
                        --reset_enable    <= x"F";
                        invalid_packet  <= '1';
                    end if;
                
                when FLUSH_FIFO => 
                    reset_enable    <= reset_enable(2 downto 0) & '0';
                    invalid_packet  <= '0';
                    if reset_enable(3) = '0' then
                        inc_data_sm     <= IDLE;
                    end if;
                    
                when FINISH => 
                   -- logic for draining the input FIFO, from this point we assume there is no error to recover from.
                    process_data_count  <= process_data_count + 1;
                    
                    if process_data_count = 97 then  -- all done!
                        inc_data_sm     <= HAND_OFF;
                        fifo_rd         <= '0';
                        buff_fifo_rd    <= '1';
                    else
                        fifo_rd         <= '1';
                    end if;

                when HAND_OFF => 
                    process_data_count  <= process_data_count + 1;
                    buff_fifo_rd        <= '0';
                    
                    if process_data_count = 110 then  -- wait for it to flow through arbiter, feedback from player
                        inc_data_sm     <= IDLE;
                    end if;
                
                when others =>
                    inc_data_sm <= IDLE;
                
            end case;
            
            ----------------------------------------------------------------------
            -- cache the beam ID, at start of frame streaming into FIFO
            if i_packetiser_data_in.data_in_wr = '1' AND data_valid_int = '0' then
                buff_fifo_wr    <= '1';
            else
                buff_fifo_wr    <= '0';
            end if;
        
        end if;
        
        
        if data_valid_int = '1' then
            signal_data_wr_count        <= signal_data_wr_count + 1;
        elsif data_valid_int_d1(1 downto 0) = "10" then
            signal_data_wr_count        <= 0;
            signal_data_wr_count_cache  <= signal_data_wr_count;
        end if;

    end if;
end process;




-- also need to track which beam number is being written, update the counter.
-- normal operation is that 1 beam number will be written for 775, an error condition is that beam can be merged to one long write.
-- either twice the expected writes (775 + 775) or a subset of 775 and then a full 775 
--------------------------------------------------------------------------------
-- adv_feature bits, 0 = overflow, 1 = prog_full_flag, 2 = wr_data_cnt, 3 = almost_full_flg, 4 = wr_ack, 8 = underflow, 9 = prog_empty, 10 = rd_data_count, 11 = almost empty, 12 = data_valid

fifo_reset <= i_reset_400 or reset_enable(3);

incoming_buffer_fifo : entity PSR_Packetiser_lib.xpm_fifo_wrapper
    Generic map (
        FIFO_DEPTH      => FIFO_CACHE_DEPTH,
        DATA_WIDTH      => 512
    )
    Port Map ( 
        fifo_reset      => fifo_reset,
        -- RD    
        fifo_rd_clk     => i_clk400,
        fifo_rd         => fifo_rd,
        fifo_q          => fifo_q,
        fifo_q_valid    => open,
        fifo_empty      => fifo_empty,
        fifo_rd_count   => fifo_rd_count,
        -- WR        
        fifo_wr_clk     => i_clk400,
        fifo_wr         => fifo_wr,
        fifo_data       => fifo_data,
        fifo_full       => open,
        fifo_wr_count   => open
    );

o_fifo_data_used        <= fifo_rd_count;


metadata_buffer_fifo : entity PSR_Packetiser_lib.xpm_fifo_wrapper
    Generic map (
        FIFO_DEPTH      => 16,
        DATA_WIDTH      => BUFF_FIFO_WIDTH
    )
    Port Map ( 
        fifo_reset      => fifo_reset,
        -- RD    
        fifo_rd_clk     => i_clk400,
        fifo_rd         => buff_fifo_rd,
        fifo_q          => buff_fifo_q,
        fifo_q_valid    => open,
        fifo_empty      => buff_fifo_empty,
        fifo_rd_count   => open,
        -- WR        
        fifo_wr_clk     => i_clk400,
        fifo_wr         => buff_fifo_wr,
        fifo_data       => buff_fifo_data,
        fifo_full       => open,
        fifo_wr_count   => open
    );

buff_fifo_data              <= '0' & x"00" & i_packetiser_data_in.PST_time_ref & i_packetiser_data_in.PST_virtual_channel & i_packetiser_data_in.PST_Beam;

PST_virtual_channel_cache   <= buff_fifo_q(17 downto 8);
PST_beam_cache              <= buff_fifo_q(7 downto 0);
PST_time_ref_cache          <= buff_fifo_q(54 downto 18);
        
---------------------------------------------------------------------------------------------------------------------------------------
-- module statistics

o_stats.valid_packets           <= valid_packet_counter;
o_stats.invalid_packets         <= invalid_packet_counter;
o_stats.disregarded_packets     <= disregarded_packets_master_enable;
o_stats.packets_sent_to_cmac    <= packets_to_ethernet_serialiser_counter;


stats_proc : process(i_clk400)
begin
    if rising_edge(i_clk400) then
        if i_reset_400 = '1' then
            valid_packet_counter                    <= zero_dword;
            invalid_packet_counter                  <= zero_dword;
            disregarded_packets_master_enable       <= zero_dword;
            packets_to_ethernet_serialiser_counter  <= zero_dword;
        else
            if i_stream_enable = '1' then
                if ((inc_data_sm = IDLE) AND (inc_data_sm_d = HAND_OFF))  then
                    valid_packet_counter    <= std_logic_vector(unsigned(valid_packet_counter) + 1);
                end if;

                if ((inc_data_sm = IDLE) AND (inc_data_sm_d = FLUSH_FIFO)) then
                    invalid_packet_counter  <= std_logic_vector(unsigned(invalid_packet_counter) + 1);
                end if;

            else
                if (data_valid_int_d1(1 downto 0) = "01") then
                    disregarded_packets_master_enable  <= std_logic_vector(unsigned(disregarded_packets_master_enable) + 1);
                end if;
            end if;
            
            wr_to_cmac_d <= i_wr_to_cmac;
            
            if (i_wr_to_cmac = '1' AND wr_to_cmac_d = '0') then
                packets_to_ethernet_serialiser_counter  <= std_logic_vector(unsigned(packets_to_ethernet_serialiser_counter) + 1);
            end if;

        end if;
    end if;
end process;



end rtl;
