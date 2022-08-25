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

entity corr_ct2_din is
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
        -- frame count is the same for all simultaneous output streams.
        -- frameCount is the count of 1st corner turn frames, i.e. 283 ms pieces of data.
        i_frameCount_mod3 : in std_logic_vector(1 downto 0);  -- which of the three first corner turn frames is this, out of the 3 that make up a 849 ms integration. "00", "01", or "10".
        i_frameCount      : in std_logic_vector(31 downto 0); -- which 849 ms integration is this ?
        i_virtualChannel : in t_slv_16_arr(3 downto 0); -- 4 virtual channels, one for each of the filterbank data streams.
        i_HeaderValid : in std_logic_vector(3 downto 0);
        i_data        : in t_ctc_output_payload_arr(3 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), i_data(2), i_data(3)
        i_dataValid   : in std_logic;
        
        -- AXI interface to the HBM
        -- Corner turn between filterbanks and correlator
        -- two HBM interfaces
        i_axi_clk : in std_logic;
        -- 3 Gbytes for virtual channels 0-511
        o_HBM0_axi_aw      : out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM0_axi_awready : in  std_logic;
        o_HBM0_axi_w       : out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_HBM0_axi_wready  : in  std_logic;
        i_HBM0_axi_b       : in  t_axi4_full_b;     -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        -- 3 Gbytes for virtual channels 512-1023
        o_HBM1_axi_aw      : out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM1_axi_awready : in  std_logic;
        o_HBM1_axi_w       : out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_HBM1_axi_wready  : in  std_logic;
        i_HBM1_axi_b       : in  t_axi4_full_b     -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
    );
end corr_ct2_din;

architecture Behavioral of corr_ct2_din is
    
    signal bufDout : t_slv_128_arr(3 downto 0);
    signal bufWE, bufWEFinal : std_logic_vector(3 downto 0);
    signal bufWE_slv : t_slv_1_arr(3 downto 0);
    signal bufWrAddr, bufWrAddrFinal : std_logic_vector(15 downto 0);
    signal bufWrData, bufWrDataFinal : std_logic_vector(127 downto 0);
    signal bufRdAddr : std_logic_vector(15 downto 0);
    
    signal copy_fine : std_logic_vector(11 downto 0);
    signal timeStep : std_logic_vector(5 downto 0);
    signal dataValidDel1, dataValidDel2 : std_logic := '0';
    signal copyToHBM : std_logic := '0';
    
    type copy_fsm_t is (start, set_aw, wait_HBM1_aw_rdy, wait_HBM0_aw_rdy, get_next_addr, idle);
    signal copy_fsm : copy_fsm_t := idle;
    signal copyToHBM_buffer : std_logic;
    signal copyToHBM_channelGroup : std_logic_vector(7 downto 0);
    signal copy_buffer : std_logic := '0';
    signal copy_channelGroup : std_logic_vector(7 downto 0);
    signal copyToHBM_time : std_logic_vector(2 downto 0);
    signal copy_time : std_logic_vector(3 downto 0);
    signal fineChannel : std_logic_vector(11 downto 0);
    signal virtualChannel : std_logic_vector(15 downto 0);
    signal frameCount_mod3 : std_logic_vector(1 downto 0);
    signal frameCount : std_logic_vector(31 downto 0);
    
    signal dataFIFO_valid : std_logic_vector(1 downto 0);
    signal dataFIFO_dout : t_slv_513_arr(1 downto 0);
    signal dataFIFO_dataCount : t_slv_6_arr(1 downto 0);
    signal dataFIFO_din : t_slv_513_arr(1 downto 0);
    signal dataFIFO_rdEn : std_logic_vector(1 downto 0);
    signal dataFIFO_wrEn : std_logic_vector(1 downto 0);
    
    signal fifo_size_plus_pending, fifo_size_plus_pending1, fifo_size_plus_pending0 : std_logic_vector(5 downto 0);
    signal dataFIFO0_wrEn, dataFIFO1_wrEn : std_logic_vector(15 downto 0) := (others => '0');
    signal HBM_selection : std_logic := '0';
    type copyData_fsm_type is (running, wait_fifo, idle);
    signal copyData_fsm : copyData_fsm_type := idle;
    signal bufRdCount : std_logic_Vector(15 downto 0) := (others => '0');
    signal pending0, pending1 : std_logic_vector(5 downto 0);
    signal last : std_logic_vector(15 downto 0);
    
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
                virtualChannel <= i_virtualChannel(0); -- Just use the first filterbanks virtual channel, this module assumes that i_virtualChannel(0), (1), (2), and (3) are consecutive values.
                frameCount_mod3 <= i_frameCount_mod3;
                frameCount <= i_frameCount;
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
            
            dataValidDel1 <= i_dataValid;
            if i_dataValid = '1' then
                if dataValidDel1 = '0' then
                    fineChannel <= (others => '0');  -- fineChannel aligns with the data in bufWrData
                else
                    fineChannel <= std_logic_vector(unsigned(fineChannel) + 1);
                end if;
            end if;
            
            bufWrDataFinal <= bufWrData;
            if (timeStep(5) = '0') then
                -- 64 time samples per corner turn; first 32 times go to the first half of the memory.
                bufWrAddrFinal <= bufWrAddr;
            else
                -- Second 32 times go to the second half of the memory,
                -- which starts at 7*4096 = 28672
                -- (There is an unused gap between the two halves of the buffers, since each half only uses 8*3456 = 27648 entries.
                bufWrAddrFinal <= std_logic_vector(unsigned(bufWrAddr) + 28672);  
            end if;
            bufWEFinal <= bufWE;
            
            ------------------------------------------
            -- Trigger copying of data to the HBM.
            if i_dataValid = '0' and dataValidDel1 = '1' and timeStep(4 downto 0) = "11111" then
                copyToHBM <= '1';
                copyToHBM_buffer <= frameCount(0); -- every 849 ms, alternate 3 Gbyte HBM buffers.
                copyToHBM_channelGroup <= virtualChannel(9 downto 2); -- up to 256 groups of 4 channels
                copyToHBM_time(0) <= timeStep(5); -- first or second half of the 64 time samples per first corner turn frame.
                copyToHBM_time(2 downto 1) <= frameCount_mod3;
            else
                copyToHBM <= '0';
            end if;
            
        end if;
    end process;
    
    bufWrAddr(15) <= '0'; -- This is the address within the first half of the buffer. Next pipeline stage puts it in the second buffer.
    bufWrAddr(14 downto 3) <= fineChannel;
    bufWrAddr(2 downto 0) <= timeStep(4 downto 2);
    
    -- ultraRAM buffer
    bufGen : for i in 0 to 3 generate 
        -- Note: in ultrascale+ devices, (Alveo U50, u55)
        -- there are 5 UltraRAM columns per SLR, with 64 ultraRAMs in each column. 
        buffer_to_100G_inst : xpm_memory_sdpram
        generic map (    
            -- Common module generics
            MEMORY_SIZE             => 7340032,        -- Total memory size in bits; 28 ultraRAMs, 14x2 = 57344 x 128 = 7340032
            MEMORY_PRIMITIVE        => "ultra",        -- string; "auto", "distributed", "block" or "ultra" ;
            CLOCKING_MODE           => "common_clock", -- string; "common_clock", "independent_clock" 
            MEMORY_INIT_FILE        => "none",         -- string; "none" or "<filename>.mem" 
            MEMORY_INIT_PARAM       => "",             -- string;
            USE_MEM_INIT            => 0,              -- integer; 0,1
            WAKEUP_TIME             => "disable_sleep",-- string; "disable_sleep" or "use_sleep_pin" 
            MESSAGE_CONTROL         => 0,              -- integer; 0,1
            ECC_MODE                => "no_ecc",       -- string; "no_ecc", "encode_only", "decode_only" or "both_encode_and_decode" 
            AUTO_SLEEP_TIME         => 0,              -- Do not Change
            USE_EMBEDDED_CONSTRAINT => 0,              -- integer: 0,1
            MEMORY_OPTIMIZATION     => "true",         -- string; "true", "false" 
        
            -- Port A module generics
            WRITE_DATA_WIDTH_A      => 128,            -- positive integer
            BYTE_WRITE_WIDTH_A      => 128,            -- integer; 8, 9, or WRITE_DATA_WIDTH_A value
            ADDR_WIDTH_A            => 16,             -- positive integer
        
            -- Port B module generics
            READ_DATA_WIDTH_B       => 128,            -- positive integer
            ADDR_WIDTH_B            => 16,             -- positive integer
            READ_RESET_VALUE_B      => "0",            -- string
            READ_LATENCY_B          => 16,             -- non-negative integer; Need one clock for every cascaded ultraRAM.
            WRITE_MODE_B            => "read_first")   -- string; "write_first", "read_first", "no_change" 
        port map (
            -- Common module ports
            sleep                   => '0',
            -- Port A (Write side)
            clka                    => i_axi_clk,  -- Filterbank clock, 300 MHz
            ena                     => '1',
            wea                     => bufWE_slv(i),
            addra                   => bufWrAddrFinal,
            dina                    => bufWrDataFinal,
            injectsbiterra          => '0',
            injectdbiterra          => '0',
            -- Port B (read side)
            clkb                    => i_axi_clk,  -- HBM interface side, also 300 MHz.
            rstb                    => '0',
            enb                     => '1',
            regceb                  => '1',
            addrb                   => bufRdAddr,
            doutb                   => bufDout(i),
            sbiterrb                => open,
            dbiterrb                => open
        );
        bufWE_slv(i)(0) <= bufWEFinal(i);
    end generate;
    
    -- At completion of 32 times, copy data from the ultraRAM buffer to the HBM
    o_HBM0_axi_aw.len <= "00000111";  -- Always 8 x 64 byte words per burst.
    o_HBM1_axi_aw.len <= "00000111";
    o_HBM0_axi_aw.addr(39 downto 32) <= "00000000";  -- 3 Gbyte piece of HBM; so bits 39:32 are 0.
    o_HBM0_axi_aw.addr(8 downto 0)   <= "000000000";
    
    o_HBM1_axi_aw.addr(39 downto 32) <= "00000000";
    o_HBM1_axi_aw.addr(8 downto 0)   <= "000000000";
    
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            -- fsm to generate write addresses
            if copyToHBM = '1' then
                copy_fsm <= start;
                copy_buffer <= copyToHBM_buffer;   -- Which 3Gbyte (= 849ms) buffer to write to in the HBM.
                copy_fine <= (others => '0');
                copy_channelGroup <= copyToHBM_channelGroup; -- Up to 256 groups of 4 channels
                copy_time <= '0' & copyToHBM_time;           -- Which group of times within the corner turn (6 possible value, 0 to 5, corresponding to times of (0-31, 32-63, 64-95, 96-127, 128-159, 160-191))
            else
                case copy_fsm is
                    when start => 
                        copy_fsm <= set_aw;
                        o_HBM0_axi_aw.valid <= '0';
                        o_HBM1_axi_aw.valid <= '0';
                    
                    when set_aw =>
                        -- Address :
                        -- - bits 8:0 = address within a  512 byte data block written in a single burst to the HBM
                        -- - bits 15:9 = 128 different groups of virtual channels (4 virtual channels in each HBM write)
                        -- - bits 27:16 = 3456 different fine channels
                        -- - bits 31:28 = 12 blocks of 32 times (2 buffers) * (192 times per buffer) / (32 times per 512 byte HBM write) 
                        -- - So bits 31:28 run from 0 to 11, for 3 Gbytes of memory, with 0 to 5 being the first 192 time samples, and 6-11 being the second 192 time samples.
                        if copy_buffer = '0' then
                            -- first 1.5 Gbytes within the HBM buffer
                            o_HBM0_axi_aw.addr(31 downto 28) <= copy_time;
                            o_HBM1_axi_aw.addr(31 downto 28) <= copy_time;
                        else
                            -- second 1.5 Gbytes within the HBM buffer.
                            o_HBM0_axi_aw.addr(31 downto 28) <= std_logic_vector(unsigned(copy_time) + 6);
                            o_HBM1_axi_aw.addr(31 downto 28) <= std_logic_vector(unsigned(copy_time) + 6);
                        end if;
                        o_HBM0_axi_aw.addr(27 downto 16) <= copy_fine;
                        o_HBM0_axi_aw.addr(15 downto 9) <= copy_channelGroup(6 downto 0);
                        o_HBM1_axi_aw.addr(27 downto 16) <= copy_fine;
                        o_HBM1_axi_aw.addr(15 downto 9) <= copy_channelGroup(6 downto 0);
                        
                        if (copy_channelGroup(7) = '0') then
                            o_HBM0_axi_aw.valid <= '1'; -- first half of the channels go to the first memory.
                            o_HBM1_axi_aw.valid <= '0';
                            copy_fsm <= wait_HBM0_aw_rdy;
                        else
                            o_HBM1_axi_aw.valid <= '1';
                            o_HBM0_axi_aw.valid <= '0';
                            copy_fsm <= wait_HBM1_aw_rdy;
                        end if;
                        
                    when wait_HBM0_aw_rdy =>
                        if i_HBM0_axi_awready = '1' then
                            o_HBM0_axi_aw.valid <= '0';
                            copy_fsm <= get_next_addr;
                        end if;
                    
                    when wait_HBM1_aw_rdy =>
                        if i_HBM1_axi_awready = '1' then
                            o_HBM1_axi_aw.valid <= '0';
                            copy_fsm <= get_next_addr;
                        end if;
                    
                    when get_next_addr =>
                        copy_fine <= std_logic_vector(unsigned(copy_fine) + 1);
                        o_HBM0_axi_aw.valid <= '0';
                        o_HBM1_axi_aw.valid <= '0';
                        if (unsigned(copy_fine) = 3455) then
                            copy_fsm <= idle;
                        else
                            copy_fsm <= set_aw;
                        end if;
                        
                    when idle => 
                        o_HBM0_axi_aw.valid <= '0';
                        o_HBM1_axi_aw.valid <= '0';
                        copy_fsm <= idle; -- stay here until we get "copyToHBM" signal
                        
                    when others => 
                        copy_fsm <= idle;                        
                        
                end case;
            end if;
            
            -- Copy data from the ultraRAM buffer to the FIFOs.
            -- Needed to meet the axi interface spec, since we have a large latency on reads from the ultraRAM.
            if copyToHBM = '1' then
                copyData_fsm <= running;
                HBM_selection <= copyToHBM_channelGroup(7); -- Which of the two HBM interfaces is this write going to ?
                if copyToHBM_time(0) = '0' then
                    -- Time blocks 0, 2, 4, 6, 8 and 10 are in the first half of the ultraRAM buffer.
                    bufRdAddr <= (others => '0');
                else
                    bufRdAddr <= std_logic_vector(to_unsigned(28672,16));
                end if;
                bufRdCount <= (others => '0'); -- counts through the (3456 fine channels) x (8 ultraRAM words per channel) = 27648 words. 3456 bursts to the HBM, with 8 words per HBM write burst.
            else
                case copyData_fsm is                
                    when running => 
                        bufRdAddr <= std_logic_vector(unsigned(bufRdAddr) + 1);
                        bufRdCount <= std_logic_vector(unsigned(bufRdCount) + 1);
                        if (unsigned(bufRdCount) = 27647) then
                            copyData_fsm <= idle;
                        elsif (unsigned(fifo_size_plus_pending) > 21) then
                            -- total space in the FIFO is 32, stop at 21 since there is some lag between fifo write occurring and fifo_size_plus_pending incrementing.
                            copyData_fsm <= wait_fifo;
                        end if;
                        
                    when wait_fifo =>
                        -- Wait until there is space in the FIFO.
                        if (unsigned(fifo_size_plus_pending) < 21) then
                            copyData_fsm <= running;
                        end if;
                    
                    when idle =>
                        copyData_fsm <= idle;
                        
                end case;
            end if;
            
            if (copyData_fsm = running and HBM_selection = '0') then
                dataFIFO0_wrEn(0) <= '1';
            else
                dataFIFO0_wrEn(0) <= '0';
            end if;
            if (copyData_fsm = running and HBM_selection = '1') then
                dataFIFO1_wrEn(0) <= '1';
            else
                dataFIFO1_wrEn(0) <= '0';
            end if;
            
            if copyData_fsm = running and bufRdCount(2 downto 0) = "111" then
                last(0) <= '1'; -- last word in an 8 word HBM burst.
            else
                last(0) <= '0';
            end if;
            last(15 downto 1) <= last(14 downto 0);
            
            -- 16 clock latency to read the ultraRAM buffer.
            dataFIFO0_wrEn(15 downto 1) <= dataFIFO0_wrEn(14 downto 0);
            dataFIFO1_wrEn(15 downto 1) <= dataFIFO0_wrEn(14 downto 0);
            
            -- Need to know how many writes to the FIFO are pending, due to the large latency in reading the ultraRAM buffer.
            fifo_size_plus_pending0 <= std_logic_vector(unsigned(pending0) + unsigned(dataFIFO_dataCount(0)));
            fifo_size_plus_pending1 <= std_logic_vector(unsigned(pending1) + unsigned(dataFIFO_dataCount(1)));
            
            if HBM_selection = '0' then
                fifo_size_plus_pending <= fifo_size_plus_pending0;
            else
                fifo_size_plus_pending <= fifo_size_plus_pending1;
            end if;
            
            dataFIFO_wrEn(0) <= dataFIFO0_wrEn(15);
            dataFIFO_wrEN(1) <= dataFIFO1_wrEn(15);
            dataFIFO_din <= last(15) & bufDout(3) & bufDout(2) & bufDout(1) & bufDout(0);
            
        end if;
    end process;

    -- number of ones in the wrEN vector is the number of pending writes to the fifo, due to the latency of the ultraRAM buffer.
    one_count1 : entity ct_lib.ones_count16
    port map (
        clk   => i_axi_clk, --  in std_logic;
        i_vec => dataFIFO0_wrEn, -- in std_logic_vector(15 downto 0);
        o_ones_count => pending0  --  out std_logic_vector(5 downto 0)
    );

    one_count2 : entity ct_lib.ones_count16
    port map (
        clk   => i_axi_clk, --  in std_logic;
        i_vec => dataFIFO1_wrEn, -- in std_logic_vector(15 downto 0);
        o_ones_count => pending1  --  out std_logic_vector(5 downto 0)
    );

    
    dfifoGen : for i in 0 to 1 generate
        -- data FIFOs to interface to the HBM axi bus
        -- Accounts for the long read latency from the big ultraRAM memory.
        -- 513 wide :
        --   511:0  = data
        --   512    = last in axi transaction
        xpm_fifo_sync_inst : xpm_fifo_sync
        generic map (
            CASCADE_HEIGHT => 0,        -- DECIMAL
            DOUT_RESET_VALUE => "0",    -- String
            ECC_MODE => "no_ecc",       -- String
            FIFO_MEMORY_TYPE => "distributed", -- String
            FIFO_READ_LATENCY => 0,     -- DECIMAL
            FIFO_WRITE_DEPTH => 32,     -- DECIMAL
            FULL_RESET_VALUE => 0,      -- DECIMAL
            PROG_EMPTY_THRESH => 10,    -- DECIMAL
            PROG_FULL_THRESH => 10,     -- DECIMAL
            RD_DATA_COUNT_WIDTH => 6,   -- DECIMAL
            READ_DATA_WIDTH => 513,     -- DECIMAL
            READ_MODE => "fwft",        -- String
            SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
            USE_ADV_FEATURES => "1404", -- String; bit 12 = enable data valid flag, bits 2 and 10 enable read and write data counts
            WAKEUP_TIME => 0,           -- DECIMAL
            WRITE_DATA_WIDTH => 513,    -- DECIMAL
            WR_DATA_COUNT_WIDTH => 6    -- DECIMAL
        )
        port map (
            almost_empty => open,     -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
            almost_full => open,      -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
            data_valid => dataFIFO_valid(i), -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
            dbiterr => open,          -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
            dout => dataFIFO_dout(i),                   -- READ_DATA_WIDTH-bit output: Read Data: The output data bus is driven when reading the FIFO.
            empty => open,                 -- 1-bit output: Empty Flag: When asserted, this signal indicates that- the FIFO is empty.
            full => open,                   -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full.
            overflow => open,           -- 1-bit output: Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected, because the FIFO is full
            prog_empty => open,       -- 1-bit output: Programmable Empty: This signal is asserted when the number of words in the FIFO is less than or equal to the programmable empty threshold value.
            prog_full => open,         -- 1-bit output: Programmable Full: This signal is asserted when the number of words in the FIFO is greater than or equal to the programmable full threshold value.
            rd_data_count => open, -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
            rd_rst_busy => open,     -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
            sbiterr => open,             -- 1-bit output: Single Bit Error: Indicates that the ECC decoder detected and fixed a single-bit error.
            underflow => open,         -- 1-bit output: Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected because the FIFO is empty.
            wr_ack => open,               -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.
            wr_data_count => dataFIFO_dataCount(i), -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
            wr_rst_busy => open,     -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
            din => dataFIFO_din(i),                     -- WRITE_DATA_WIDTH-bit input: Write Data: The input data bus used when writing the FIFO.
            injectdbiterr => '0', -- 1-bit input: Double Bit Error Injection
            injectsbiterr => '0', -- 1-bit input: Single Bit Error Injection: 
            rd_en => dataFIFO_RdEn(i),       -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO. 
            rst => '0',           -- 1-bit input: Reset: Must be synchronous to wr_clk.
            sleep => '0',         -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
            wr_clk => i_axi_clk,     -- 1-bit input: Write clock: Used for write operation. wr_clk must be a free running clock.
            wr_en => dataFIFO_wrEn(i)     -- 1-bit input: Write Enable: 
        );
    
    end generate;
    

    o_HBM0_axi_w.data <= dataFIFO_dout(0)(511 downto 0);
    o_HBM0_axi_w.last <= dataFIFO_dout(0)(512);
    o_HBM0_axi_w.valid <= dataFIFO_valid(0);
    o_HBM0_axi_w.resp <= "00";
    
    o_HBM1_axi_w.data <= dataFIFO_dout(1)(511 downto 0);
    o_HBM1_axi_w.last <= dataFIFO_dout(1)(512);
    o_HBM1_axi_w.valid <= dataFIFO_valid(1);
    o_HBM1_axi_w.resp <= "00";
    
    dataFIFO_rden(0) <= dataFIFO_valid(0) and i_HBM0_axi_wready;
    dataFIFO_rden(1) <= dataFIFO_valid(1) and i_HBM1_axi_wready;
    
end Behavioral;

