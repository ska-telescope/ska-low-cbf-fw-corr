----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 30.10.2020 22:21:03
-- Module Name: ct_atomic_cor_out - Behavioral
-- Description: 
--    Corner turn between the filterbanks and the correlator for SKA correlator processing. 
--    This module is responsible for writing data from the filterbanks into the HBM.
-- 
-- Data coming in from the filterbanks :
--   4 dual-pol channels, with burst of 3456 fine channels at a time.
--   Total number of bytes per clock coming in is  (4 channels)*(2 pol)*(2 complex) = 16 bytes.
--   with roughly 3456 out of every 4096 clocks active.
--   Total data rate in is thus roughly (16 bytes * 8 bits)*3456/4096 * 300 MHz = 32.4 Gb/sec (this is the average data rate while data is flowing)
--   Actual total data rate in is (3456/4096 fine channels used) * (1/1080ns sampling period) * (32 bits/sample) * (1024 channels) = 25.6 Gb/sec 
--
-- Storing to HBM and incoming ultraRAM buffering
--   See comments in the level above, ct_atomic_cor_wrapper.vhd
--   
--   
--   
----------------------------------------------------------------------------------
library IEEE, ct_lib, DSP_top_lib, common_lib, axi4_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use DSP_top_lib.DSP_top_pkg.all;
USE common_lib.common_pkg.ALL;
USE axi4_lib.axi4_full_pkg.ALL;
Library xpm;
use xpm.vcomponents.all;

entity ct_atomic_cor_out_din is
    generic (
        g_USE_META : boolean := FALSE  -- Put meta data into the memory in place of the actual data, to make it easier to find bugs in the corner turn. 
    );
    port(
        -- Parameters, in the i_axi_clk domain.
        i_stations : in std_logic_vector(10 downto 0); -- up to 1024 stations
        i_coarse   : in std_logic_vector(9 downto 0);  -- Number of coarse channels.
        i_virtualChannels : in std_logic_vector(10 downto 0); -- total virtual channels (= i_stations * i_coarse)
        -- Registers AXI Lite Interface (uses i_axi_clk)
        
        -- Data in from the correlator filterbanks; bursts of 3456 clocks for each channel.
        -- 
        i_sof          : in std_logic; -- pulse high at the start of every frame. (1 frame is typically 283 ms of data).
        i_frameCount     : in std_logic_vector(36 downto 0); -- frame count is the same for all simultaneous output streams.
        i_virtualChannel : in t_slv_16_arr(3 downto 0); -- 4 virtual channels, one for each of the filterbank data streams.
        i_HeaderValid : in std_logic_vector(3 downto 0);
        i_data        : in t_ctc_output_payload_arr(3 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), i_data(2), i_data(3)
        i_dataValid   : in std_logic;
        
        -- AXI interface to the HBM
        -- Corner turn between filterbanks and correlator
        -- aw bus = write address
        i_axi_clk : in std_logic;
        o_axi_aw      : out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_axi_awready : in  std_logic;
        o_axi_w       : out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_axi_wready  : in  std_logic;
        i_axi_b       : in  t_axi4_full_b     -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
    );
end ct_atomic_cor_out_din;

architecture Behavioral of ct_atomic_cor_out_din is
    
    signal bufDout : t_slv_128_arr(3 downto 0);
    signal bufWE : std_logic_vector(3 downto 0);
    signal bufWE_slv : t_slv_1_arr(3 downto 0);
    signal bufWrAddr : std_logic_vector(15 downto 0);
    signal bufWrData : std_logic_vector(127 downto 0);
    signal bufRdAddr : std_logic_vector(15 downto 0);
    
    signal copy_fine : std_logic_vector(11 downto 0);
    signal timeStep : std_logic_vector(5 downto 0);
    signal dataValidDel1, dataValidDel2 : std_logic := '0';
    signal copyToHBM : std_logic := '0';
    
    type copy_fsm_t is (start, set_aw, wait_aw_rdy, get_next_addr, idle);
    signal copy_fsm : copy_fsm_t := idle;
    signal copyToHBM_buffer : std_logic;
    signal copyToHBM_channelGroup : std_logic_vector(7 downto 0);
    signal copy_buffer : std_logic := '0';
    signal copy_channelGroup : std_logic_vector(7 downto 0);
    signal copyToHBM_time : std_logic_vector(2 downto 0);
    signal copy_time : std_logic_vector(3 downto 0);
    
begin
    
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            dataValidDel1 <= i_dataValid;
            dataValidDel2 <= dataValidDel1;
        
            if i_sof = '1' then
                -- time step for the next packet from the filterbanks, counts 0 to 63
                -- (There are 64 time samples per first stage corner turn frame)
                timeStep <= (others => '0');
            elsif dataValidDel1 = '0' and dataValidDel2 = '1' then
                timeStep <= std_logic_vector(unsigned(timeStep) + 1);
            end if;
            
            bufWrData(15 downto 0) <= i_data(0).Hpol.im & i_data(0).Hpol.re;
            bufWrData(31 downto 16) <= i_data(0).Vpol.im & i_data(0).Vpol.re;
            bufWrData(47 downto 32) <= i_data(1).Hpol.im & i_data(1).Hpol.re;
            bufWrData(63 downto 48) <= i_data(1).Vpol.im & i_data(1).Vpol.re;
            bufWrData(79 downto 64) <= i_data(2).Hpol.im & i_data(2).Hpol.re;
            bufWrData(95 downto 80) <= i_data(2).Vpol.im & i_data(2).Vpol.re;
            bufWrData(111 downto 96) <= i_data(3).Hpol.im & i_data(3).Hpol.re;
            bufWrData(127 downto 112) <= i_data(3).Vpol.im & i_data(3).Vpol.re;
            
            if i_dataValid = '1' then
                case timeStep(1 downto 0) is
                    when "00" => bufWE <= "0001";
                    when "01" => bufWE <= "0010";
                    when "10" => bufWE <= "0100";
                    when others => bufWE <= "1000";
                end case;
            else
                bufWE <= "0000";
            end if;
            
            --!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            -- fix these -----------------------------
            copyToHBM <= '0';
            copyToHBM_buffer <= '0';
            copyToHBM_channelGroup <= (others => '0');
            copyToHBM_time <= "000";
            
        end if;
    end process;
    
    
    -- ultraRAM buffer
    bufGen : for i in 0 to 3 generate 
        -- Note: in ultrascale+ devices, (Alveo U50, u55)
        -- there are 5 UltraRAM columns per SLR, with 64 ultraRAMs in each column. 
        buffer_to_100G_inst : xpm_memory_sdpram
        generic map (    
            -- Common module generics
            MEMORY_SIZE             => 1048576,        -- Total memory size in bits; 28 ultraRAMs, 14x2 = 57344 x 128 = 7340032
            MEMORY_PRIMITIVE        => "ultra",        --string; "auto", "distributed", "block" or "ultra" ;
            CLOCKING_MODE           => "common_clock", --string; "common_clock", "independent_clock" 
            MEMORY_INIT_FILE        => "none",         --string; "none" or "<filename>.mem" 
            MEMORY_INIT_PARAM       => "",             --string;
            USE_MEM_INIT            => 0,              --integer; 0,1
            WAKEUP_TIME             => "disable_sleep",--string; "disable_sleep" or "use_sleep_pin" 
            MESSAGE_CONTROL         => 0,              --integer; 0,1
            ECC_MODE                => "no_ecc",       --string; "no_ecc", "encode_only", "decode_only" or "both_encode_and_decode" 
            AUTO_SLEEP_TIME         => 0,              --Do not Change
            USE_EMBEDDED_CONSTRAINT => 0,              --integer: 0,1
            MEMORY_OPTIMIZATION     => "true",         --string; "true", "false" 
        
            -- Port A module generics
            WRITE_DATA_WIDTH_A      => 128,            --positive integer
            BYTE_WRITE_WIDTH_A      => 128,            --integer; 8, 9, or WRITE_DATA_WIDTH_A value
            ADDR_WIDTH_A            => 16,             --positive integer
        
            -- Port B module generics
            READ_DATA_WIDTH_B       => 128,            --positive integer
            ADDR_WIDTH_B            => 16,             --positive integer
            READ_RESET_VALUE_B      => "0",            --string
            READ_LATENCY_B          => 16,             -- non-negative integer; Need one clock for every cascaded ultraRAM.
            WRITE_MODE_B            => "read_first")    --string; "write_first", "read_first", "no_change" 
        port map (
            -- Common module ports
            sleep                   => '0',
            -- Port A (Write side)
            clka                    => i_axi_clk,  -- clock for the shared memory, 300 MHz
            ena                     => '1',
            wea                     => bufWE_slv(i),
            addra                   => bufWrAddr,
            dina                    => bufWrData,
            injectsbiterra          => '0',
            injectdbiterra          => '0',
            -- Port B (read side)
            clkb                    => i_axi_clk,  -- Filterbank clock, also 300 MHz.
            rstb                    => '0',
            enb                     => '1',
            regceb                  => '1',
            addrb                   => bufRdAddr,
            doutb                   => bufDout(i),
            sbiterrb                => open,
            dbiterrb                => open
        );
        bufWE_slv(i)(0) <= bufWE(i);
    end generate;
    
    -- At completion of 32 times, copy data from the ultraRAM buffer to the HBM
    o_axi_aw.len <= "00000111";  -- Always 8 x 64 byte words per burst.
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            -- fsm to generate write addresses
            if copyToHBM = '1' then
                copy_fsm <= start;
                copy_buffer <= copyToHBM_buffer;
                copy_fine <= (others => '0');
                copy_channelGroup <= copyToHBM_channelGroup; -- up to 256 groups of 4 channels
                copy_time <= '0' & copyToHBM_time; -- Which group of times within the corner turn (6 possible value, 0 to 5, corresponding to times of (0-31, 32-63, 64-95, 96-127, 128-159, 160-191))
            else
                case copy_fsm is
                    when start => 
                        copy_fsm <= set_aw;
                        o_axi_aw.valid <= '0';
                    
                    when set_aw =>
                        o_axi_aw.addr(39 downto 33) <= "0000000";
                        if copy_buffer = '0' then
                            -- first 3 Gbyte HBM buffer
                            o_axi_aw.addr(32 downto 29) <= copy_time;
                        else
                            o_axi_aw.addr(32 downto 29) <= std_logic_vector(unsigned(copy_time) + 6);
                        end if;
                        o_axi_aw.addr(28 downto 17) <= copy_fine;
                        o_axi_aw.addr(16 downto 9) <= copy_channelGroup;
                        o_axi_aw.addr(8 downto 0) <= "000000000";
                        o_axi_aw.valid <= '1';
                        copy_fsm <= wait_aw_rdy;
                        
                    when wait_aw_rdy =>
                        if i_axi_awready = '1' then
                            o_axi_aw.valid <= '0';
                            copy_fsm <= get_next_addr;
                        end if;
                    
                    when get_next_addr =>
                        copy_fine <= std_logic_vector(unsigned(copy_fine) + 1);
                        o_axi_aw.valid <= '0';
                        if (unsigned(copy_fine) = 3455) then
                            copy_fsm <= idle;  -- ?? maybe ?
                        end if;
                        
                    when idle => 
                        o_axi_aw.valid <= '0';
                        copy_fsm <= idle; -- stay here until we get "copyBufToHBM" signal
                        
                    when others => 
                        copy_fsm <= idle;                        
                        
                end case;
            end if;
            
            -- Copy data from the ultraRAM buffer to a FIFO.
            -- Needed to meet the axi interface spec, since we have a large latency on reads from the ultraRAM.
            
           
            
             
        end if;
    end process;
    
    -- data FIFO to interface to the HBM axi bus

    o_axi_w.valid <= '0';
    o_axi_w.data <= (others => '0');
    o_axi_w.last <= '0';
    o_axi_w.resp <= "00";
    
end Behavioral;
