----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: david humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 08/04/2022 09:29:40 AM
-- Module Name: corr_ct2_dout - Behavioral
-- Description: 
--  Readout to the correlator.
-- 
-- Readout Pattern:
--
-- For tile = 0:3   � Can stop before 3, e.g. only one tile if there is <= 256 virtual channels.
--     For fine_base = 0 : integration_channels : 3456
--         For time_group = 0:3    � each time_group is 64 time samples, i.e. 283 ms
--             -- Depending on integration_time, Long Term Accumulator may dump for every time group, or only for the last time group.
--             For fine_channel = fine_base + (0:integration_channels)
--                -- time samples are grouped in blocks of 32 in the HBM
--                *Read 2 HBM blocks with 32 time samples each.
--                -Tile 0 : get virtual channels = 0:255
--                -Tile 1 : get virtual channels = 256:511
--                -Tile 2 : get virtual channels = 0:511
--                -Tile 3 : get virtual channels = 0:511
--
-- HBM addressing:
-- 32 bit address needed to address 3 Gbytes:
--      - bits 8:0 = address within a  512 byte data block written in a single burst to the HBM
--      - bits 15:9 = 128 different groups of virtual channels (4 virtual channels in each HBM write)
--          *!! Using these address bits is critical, since it allows the readout to read multiple 512-byte blocks at a time.
--           !! Readout can thus read at the full HBM rate, close to 100Gb/sec.
--           !! Write data rate is 25.6Gb/sec, so this means the readout can read the data 3 or 4 times.
--           !! Multiple reads of the same data reduces the buffer memory required in the correlator long term accumulator.
--      - bits 27:16 = 3456 different fine channels
--      - bits 31:28 = 12 blocks of 32 times (2 buffers) * (192 times per buffer) / (32 times per 512 byte HBM write) 
--          - So bits 31:28 run from 0 to 11, for 3 Gbytes of memory, with 0 to 5 being the first 192 time samples, and 6-11 being the second 192 time samples.
----------------------------------------------------------------------------------

library IEEE, ct_lib, DSP_top_lib, common_lib, axi4_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
USE axi4_lib.axi4_full_pkg.ALL;
Library xpm;
use xpm.vcomponents.all;

entity corr_ct2_dout is
    Port(
        -- Only uses the 300 MHz clock.
        i_axi_clk   : in std_logic;
        i_start     : in std_logic; -- start reading out data to the correlators
        i_buffer    : in std_logic; -- which of the double buffers to read out ?
        i_virtualChannels : in std_logic_vector(11 downto 0); -- How many virtual channels are there in this buffer ? (NOTE this buffer, not both buffers).
        i_fineIntegrations : in std_logic_vector(4 downto 0); -- Number of fine channels to integrate, max 24.
        ---------------------------------------------------------------
        -- Data out to the correlator arrays
        --
        -- correlator 0 is ready to receive a new block of data. This will go low once data starts to be received.
        -- A block of data consists of data for 64 times, and up to 512 virtual channels.
        i_cor_ready : in std_logic;  
        -- Each 256 bit word : two time samples, 4 consecutive virtual channels
        -- (31:0) = time 0, virtual channel 0; (63:32) = time 0, virtual channel 1; (95:64) = time 0, virtual channel 2; (127:96) = time 0, virtual channel 3;
        -- (159:128) = time 1, virtual channel 0; (191:160) = time 1, virtual channel 1; (223:192) = time 1, virtual channel 2; (255:224) = time 1, virtual channel 3;
        o_cor_data  : out std_logic_vector(255 downto 0); 
        -- meta data
        o_cor_time : out std_logic_vector(7 downto 0); -- time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
        o_cor_VC   : out std_logic_vector(11 downto 0); -- first of the 4 virtual channels in o_cor0_data
        o_cor_FC   : out std_logic_vector(11 downto 0); -- which 226 Hz fine channel is this ? 0 to 3455.
        o_cor_triangle : out std_logic_vector(3 downto 0); -- which correlator triangle is this data for ? 0 to 3 for modes that don't use substations.
        o_cor_valid : out std_logic;
        o_cor_last  : out std_logic;  -- last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
        o_cor_final : out std_logic;  -- Indicates that at the completion of processing the last block of correlator data, the integration is complete.
        ----------------------------------------------------------------
        -- read interfaces for the HBM
        o_HBM_axi_ar      : out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_arready : in  std_logic;
        i_HBM_axi_r       : in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_rready  : out std_logic
    );
end corr_ct2_dout;

architecture Behavioral of corr_ct2_dout is

    type ar_fsm_type is (check_arFIFO, set_ar, wait_ar, update_addr, next_fine, next_tile, done);
    signal ar_fsm, ar_fsm_del1 : ar_fsm_type := done;
    signal readBuffer : std_logic := '0';
    signal totalVirtualChannels : std_logic_vector(11 downto 0);
    signal totalFineChannels : std_logic_vector(11 downto 0);
    signal fineIntegrationsMinus1, curFineChannelOffset : std_logic_vector(4 downto 0);
    signal lastFineChannelBase, curFineChannelBase, curFineChannel : std_logic_vector(11 downto 0);
    signal curVirtualChannelx16 : std_logic_vector(4 downto 0);
    signal curTriangle : std_logic_vector(1 downto 0);
    signal curTimeGroup : std_logic_vector(3 downto 0);
    type readout_fsm_type is (idle, wait_data, send_data, signal_correlator, wait_correlator_ready);
    signal readout_fsm : readout_fsm_type := idle;
    signal cor_valid : std_logic;
    signal sendCount, sendCountDel1 : std_logic_vector(7 downto 0);
    signal readoutTriangle : std_logic_vector(1 downto 0);
    signal readoutFineChannel : std_logic_vector(11 downto 0);
    signal readoutTimeGroup : std_logic_vector(3 downto 0);
    signal readoutVCx16 : std_logic_vector(4 downto 0);
    signal readoutKey : std_logic_vector(1 downto 0);
    signal arFIFO_valid, arFIFO_full, arFIFO_rdEn, arFIFO_wrEn : std_logic;
    signal arFIFO_din, arFIFO_dout : std_logic_Vector(24 downto 0);
    signal dataFIFO_valid, dataFIFO_rdEn, dataFIFO_wrEn, dataFIFO_full : std_logic;
    signal dataFIFO_dout : std_logic_Vector(255 downto 0);
    signal dataFIFO_rdCount : std_logic_vector(10 downto 0);
    signal dataFIFO_wrCount : std_logic_vector(9 downto 0);
 
begin
    
    -- Always read blocks of 2048 bytes = 32 x (512 bit) words.
    -- There is data for 4 stations in each 512 byte block in HBM, so 2048 byte reads 
    -- returns data for 4x4=16 stations, i.e. the minimum amount used by the correlator array.
    o_HBM_axi_ar.len <= "00011111";
    o_HBM_axi_ar.addr(39 downto 32) <= "00000000";
    o_HBM_axi_ar.addr(10 downto 0) <= "00000000000";  -- All reads are 2048 byte aligned.
    
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            if i_start = '1' then
                ar_fsm <= check_arFIFO;
                readBuffer <= i_buffer;
                totalVirtualChannels <= i_virtualChannels;
                totalFineChannels <= std_logic_vector(to_unsigned(3456,16)); -- may be different to 3456 when code allows for substations.
                fineIntegrationsMinus1 <= std_logic_vector(unsigned(i_fineIntegrations) - 1);
                lastFineChannelBase <= std_logic_vector(3456 - resize(unsigned(i_fineIntegrations),12));
                curFineChannelOffset <= (others => '0'); -- number of fine channels within the current integration, typically 0 to 23
                curFineChannelBase <= (others => '0');   -- the fine channel being used is curFineChannelBase + curFineChannelOffset
                curVirtualChannelx16 <= (others => '0');  -- reads are groups of 16 virtual channels.
                curTriangle <= "00";   -- a "triangle" is a set of 256x256 stations that the correlator array is being tiled across.
                curTimeGroup <= "0000"; -- steps through "000", "001", "010", "011", "100", "101" for the 6 groups of 32 times, since data in HBM is written in 512 byte blocks with 32 times. 
            else
                case ar_fsm is
                    when check_arFIFO =>
                        -- check there is space in the ar FIFO
                        if (arFIFO_full = '0') then
                            ar_fsm <= set_ar;
                        end if;
                    
                    when set_ar =>
                        if readBuffer = '0' then
                            o_HBM_axi_ar.addr(31 downto 28) <= curTimeGroup;
                        else
                            o_HBM_axi_ar.addr(31 downto 28) <= std_logic_vector(unsigned(curTimeGroup) + 6);
                        end if;
                        o_HBM_axi_ar.addr(27 downto 16) <= curFineChannel(11 downto 0);
                        o_HBM_axi_ar.addr(15 downto 11) <= curVirtualChannelx16(4 downto 0);
                        o_HBM_axi_ar.valid <= '1';
                        ar_fsm <= wait_ar;
                        
                    when wait_ar =>
                        if i_HBM_axi_arready = '1' then
                            o_HBM_axi_ar.valid <= '0';
                            ar_fsm <= update_addr;
                        end if;
                    
                    when update_addr =>
                        -- Updates to the address implement the loop below :
                        --
                        -- For triangle = 0:3   � Can stop before 3, e.g. only one tile if there is <= 256 virtual channels.
                        --     -- Each triangle from the correlation matrix is up to 256x256 stations.
                        --     For fine_base = 0 : integration_channels : 3456
                        --         For time_group = 0:3    � each time_group is 64 time samples, i.e. 283 ms
                        --             -- Depending on integration_time, Long Term Accumulator may dump for every time group, or only for the last time group.
                        --             For fine_channel = fine_base + (0:integration_channels)
                        --                -- time samples are grouped in blocks of 32 in the HBM
                        --                *Read 2 HBM blocks with 32 time samples each.
                        --                -Tile 0 : get virtual channels = 0:255
                        --                -Tile 1 : get virtual channels = 256:511
                        --                -Tile 2 : get virtual channels = 0:511
                        --                -Tile 3 : get virtual channels = 0:511
                        if curTimeGroup(0) = '0' then
                            curTimeGroup(0) <= '1'; -- get the second block of 32 times
                            ar_fsm <= check_arFIFO;
                        else
                            curTimeGroup(0) <= '0';
                            if curTriangle = "00" then 
                                -- Reading virtual channels 0 -> 255
                                -- So at 15, we have just done the last read for 256 channels (15*16 = 240 = last group of 16 virtual channels).
                                if ((unsigned(curVirtualChannelx16) = 15) or 
                                    ((curVirtualChannelx16(4 downto 0) = totalVirtualChannels(8 downto 4)) and (totalVirtualChannels(11 downto 9) = "000"))) then
                                    curVirtualChannelx16 <= (others => '0');
                                    ar_fsm <= next_fine;
                                else
                                    curVirtualChannelx16 <= std_logic_vector(unsigned(curVirtualChannelx16) + 1);
                                    ar_fsm <= check_arFIFO;
                                end if;
                            else
                                -- reading virtual channels 256 -> 511, or reading all 512 virtual channels.
                                if ((unsigned(curVirtualChannelx16) = 31) or 
                                    ((curVirtualChannelx16(4 downto 0) = totalVirtualChannels(8 downto 4)) and (totalVirtualChannels(11 downto 9) = "000"))) then
                                    curVirtualChannelx16 <= (others => '0');
                                    ar_fsm <= next_fine;
                                else
                                    curVirtualChannelx16 <= std_logic_vector(unsigned(curVirtualChannelx16) + 1);
                                    ar_fsm <= check_arFIFO;
                                end if;
                            end if;
                        end if;
                    
                    when next_fine =>
                        -- Advancing to the next fine channel is a separate state to the update_addr state since at this point we have finished a full block of row and col mem data for the correlator. 
                        if (curFineChannelOffset = fineIntegrationsMinus1) then
                            curFineChannelOffset <= (others => '0');
                            case curTimeGroup(2 downto 1) is -- bits 2:1 selects which of the three blocks of 283 ms we have just read out.
                                when "00" => 
                                    curTimeGroup <= "0010";
                                    ar_fsm <= check_arFIFO;
                                when "01" => 
                                    curTimeGroup <= "0100";
                                    ar_fsm <= check_arFIFO;
                                when others => 
                                    -- Just read out the last 283 ms block of data, go on to the next group of fine channels.
                                    if curFineChannelBase = lastFineChannelBase then
                                        ar_fsm <= next_tile;
                                    else
                                        ar_fsm <= check_arFIFO;
                                        curFineChannelBase <= std_logic_vector(unsigned(curFineChannelBase) + unsigned(fineIntegrationsMinus1) + 1);
                                    end if;
                            end case;
                        else
                            ar_fsm <= check_arFIFO;
                            curFineChannelOffset <= std_logic_vector(unsigned(curFineChannelOffset) + 1);
                        end if;
                        
                    when next_tile =>
                        curFineChannelBase <= (others => '0');
                        curTimeGroup <= (others => '0');
                        curFineChannelOffset <= (others => '0');
                        if (unsigned(totalVirtualChannels) < 256) then
                            ar_fsm <= done;
                        else
                            case curTriangle is
                                when "00" =>
                                    curTriangle <= "01";
                                    curVirtualChannelx16 <= "10000";  -- 16x16 i.e. 256; triangle 1 reads stations 256 to 511.
                                    ar_fsm <= check_arFIFO;
                                when "01" =>
                                    curTriangle <= "10";
                                    curVirtualChannelx16 <= "00000";  -- triangles 2 and 3 need all 512 stations (half for correlator row memories, half for the col memories)
                                    ar_fsm <= check_arFIFO;
                                when "10" =>
                                    curTriangle <= "11";
                                    curVirtualChannelx16 <= "00000";  -- triangles 2 and 3 need all 512 stations (half for correlator row memories, half for the col memories)
                                    ar_fsm <= check_arFIFO;
                                when others =>
                                    ar_fsm <= done;
                            end case;
                        end if;
                    when done =>
                        ar_fsm <= done; -- Wait until we get i_start again.
                end case;
            end if;
            ar_fsm_del1 <= ar_fsm;
            curFineChannel <= std_logic_vector(unsigned(curFineChannelBase) + unsigned(curFineChannelOffset));
            
            -- FIFO to keep meta data associated with each HBM ar request.
            if ar_fsm = set_ar then
                arFIFO_wrEn <= '1';
                arFIFO_din(1 downto 0) <= curTriangle; -- 2 bits
                arFIFO_din(13 downto 2) <= curFineChannel; -- 12 bits
                arFIFO_din(17 downto 14) <= curTimeGroup;  -- 4 bits
                arFIFO_din(22 downto 18) <= curVirtualChannelx16; -- 5 bits.
                arFIFO_din(24 downto 23) <= "00"; -- Indicates a block of 2048 bytes from the HBM
            elsif ar_fsm_del1 = next_fine then
                arFIFO_wrEn <= '1';
                arFIFO_din(23) <= '1';    -- Indicates that a full block of data has been delivered to the correlator, and the correlator has to be run.
                if ar_fsm = next_tile then
                    arFIFO_din(24) <= '1';  -- Indicates that all the time samples and fine channels have been sent, so this is the end of the integration.
                else
                    arFIFO_din(24) <= '0';
                end if;
            else
                arFIFO_wrEn <= '0';
            end if;
            
            
        end if;
    end process;
    
    
    -- arFIFO is read when data is read out of the dataFIFO in this module, so the number of entries in the 
    -- arFIFO is the number of words that will be in the dataFIFO when all the requests have returned from the HBM.
    -- The dataFIFO has space for 512 words, i.e. 16 ar requests (each ar request is 2048 bytes = 32 x 64byte words)
    -- So arFIFO only really needs to be 16 deep.
    arfifoi : xpm_fifo_sync
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
        READ_DATA_WIDTH => 25,      -- DECIMAL
        READ_MODE => "fwft",        -- String
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "1404", -- String; bit 12 = enable data valid flag, bits 2 and 10 enable read and write data counts
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 25,     -- DECIMAL
        WR_DATA_COUNT_WIDTH => 6    -- DECIMAL
    ) port map (
        almost_empty => open,       -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
        almost_full => open,        -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
        data_valid => arFIFO_valid, -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
        dbiterr => open,            -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
        dout => arFIFO_dout,        -- READ_DATA_WIDTH-bit output: Read Data: The output data bus is driven when reading the FIFO.
        empty => open,              -- 1-bit output: Empty Flag: When asserted, this signal indicates that- the FIFO is empty.
        full => arFIFO_full,        -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full.
        overflow => open,           -- 1-bit output: Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected, because the FIFO is full
        prog_empty => open,         -- 1-bit output: Programmable Empty: This signal is asserted when the number of words in the FIFO is less than or equal to the programmable empty threshold value.
        prog_full => open,          -- 1-bit output: Programmable Full: This signal is asserted when the number of words in the FIFO is greater than or equal to the programmable full threshold value.
        rd_data_count => open,      -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
        rd_rst_busy => open,        -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
        sbiterr => open,            -- 1-bit output: Single Bit Error: Indicates that the ECC decoder detected and fixed a single-bit error.
        underflow => open,          -- 1-bit output: Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected because the FIFO is empty.
        wr_ack => open,             -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.
        wr_data_count => open, -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        wr_rst_busy => open,        -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
        din => arFIFO_din,          -- WRITE_DATA_WIDTH-bit input: Write Data: The input data bus used when writing the FIFO.
        injectdbiterr => '0',       -- 1-bit input: Double Bit Error Injection
        injectsbiterr => '0',       -- 1-bit input: Single Bit Error Injection: 
        rd_en => arFIFO_RdEn,       -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO. 
        rst => '0',                 -- 1-bit input: Reset: Must be synchronous to wr_clk.
        sleep => '0',               -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
        wr_clk => i_axi_clk,        -- 1-bit input: Write clock: Used for write operation. wr_clk must be a free running clock.
        wr_en => arFIFO_wrEn        -- 1-bit input: Write Enable: 
    );
    
    arFIFO_rdEN <= '1' when readout_fsm = idle else '0';


    datafifoi : xpm_fifo_sync
    generic map (
        CASCADE_HEIGHT => 0,        -- DECIMAL
        DOUT_RESET_VALUE => "0",    -- String
        ECC_MODE => "no_ecc",       -- String
        FIFO_MEMORY_TYPE => "auto", -- String
        FIFO_READ_LATENCY => 1,     -- DECIMAL
        FIFO_WRITE_DEPTH => 512,    -- DECIMAL
        FULL_RESET_VALUE => 0,      -- DECIMAL
        PROG_EMPTY_THRESH => 10,    -- DECIMAL
        PROG_FULL_THRESH => 10,     -- DECIMAL
        RD_DATA_COUNT_WIDTH => 11,  -- DECIMAL  should be = log2(FIFO_READ_DEPTH) + 1
        READ_DATA_WIDTH => 256,     -- DECIMAL
        READ_MODE => "std",         -- String
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "1404", -- String; bit 12 = enable data valid flag, bits 2 and 10 enable read and write data counts
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 512,    -- DECIMAL
        WR_DATA_COUNT_WIDTH => 10   -- DECIMAL
    ) port map (
        almost_empty => open,      -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
        almost_full => open,       -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
        data_valid => dataFIFO_valid, -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
        dbiterr => open,           -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
        dout => dataFIFO_dout,     -- READ_DATA_WIDTH-bit output: Read Data: The output data bus is driven when reading the FIFO.
        empty => open,             -- 1-bit output: Empty Flag: When asserted, this signal indicates that- the FIFO is empty.
        full => dataFIFO_full,     -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full.
        overflow => open,          -- 1-bit output: Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected, because the FIFO is full
        prog_empty => open,        -- 1-bit output: Programmable Empty: This signal is asserted when the number of words in the FIFO is less than or equal to the programmable empty threshold value.
        prog_full => open,         -- 1-bit output: Programmable Full: This signal is asserted when the number of words in the FIFO is greater than or equal to the programmable full threshold value.
        rd_data_count => dataFIFO_rdCount,     -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
        rd_rst_busy => open,       -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
        sbiterr => open,           -- 1-bit output: Single Bit Error: Indicates that the ECC decoder detected and fixed a single-bit error.
        underflow => open,         -- 1-bit output: Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected because the FIFO is empty.
        wr_ack => open,            -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.
        wr_data_count => dataFIFO_wrCount, -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        wr_rst_busy => open,       -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
        din => i_HBM_axi_r.data,       -- WRITE_DATA_WIDTH-bit input: Write Data: The input data bus used when writing the FIFO.
        injectdbiterr => '0',      -- 1-bit input: Double Bit Error Injection
        injectsbiterr => '0',      -- 1-bit input: Single Bit Error Injection: 
        rd_en => dataFIFO_RdEn,    -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO. 
        rst => '0',                -- 1-bit input: Reset: Must be synchronous to wr_clk.
        sleep => '0',              -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
        wr_clk => i_axi_clk,       -- 1-bit input: Write clock: Used for write operation. wr_clk must be a free running clock.
        wr_en => dataFIFO_wrEn     -- 1-bit input: Write Enable: 
    );
    
    dataFIFO_rdEn <= '1' when readout_fsm = send_data else '0';
    dataFIFO_wrEn <= i_HBM_axi_r.valid and (not dataFIFO_full);
    o_HBM_axi_rready <= not dataFIFO_full;
    
    -- Readout of the ar fifo and data fifo, send data to the correlator
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            
            case readout_fsm is
                when idle =>
                    if arFIFO_valid = '1' then
                        readoutTriangle <= arFIFO_dout(1 downto 0); -- 2 bits
                        readoutFineChannel <= arFIFO_dout(13 downto 2); -- 12 bits
                        readoutTimeGroup <= arFIFO_dout(17 downto 14);  -- 4 bits
                        readoutVCx16 <= arFIFO_dout(22 downto 18);
                        readoutKey <= arFIFO_dout(24 downto 23); -- "00" for normal data, "01" start correlation (end of block for row+col memories), "10" for end of tile = end of integration.
                        if (arFIFO_dout(24 downto 23) = "00") then
                            if (unsigned(dataFIFO_rdCount) >= 64) then
                                -- each ar request is for 32 x 64-byte words = 2048 bytes; at the read side of the data fifo this is 64 words.
                                readout_fsm <= send_data;
                            else
                                readout_fsm <= wait_data;
                            end if;
                        else
                            readout_fsm <= signal_correlator;
                        end if;
                    end if;
                    sendCount <= (others => '0');
                    
                when wait_data =>
                    if (unsigned(dataFIFO_rdCount) >= 64) then
                        readout_fsm <= send_data;
                    end if;
                    sendCount <= (others => '0');
                    
                when send_data =>
                    sendCount <= std_logic_vector(unsigned(sendCount) + 1);
                    if unsigned(sendCount) = 63 then
                        readout_fsm <= idle;
                    end if;
                
                when signal_correlator =>
                    -- send notification to the correlator to run the correlator, or that the correlation is done.
                    readout_fsm <= wait_correlator_ready;
                
                when wait_correlator_ready =>
                    if i_cor_ready = '1' then
                        readout_fsm <= idle;
                    end if;
                
                when others =>
                    readout_fsm <= idle;
            end case;
            
            
            -- Pipeline stage to ensure data output comes from a register
            if (readout_fsm = send_data) then  -- fifo read enable is high in the send_data state, so dataFIFO_dout will be high one clock later.
                cor_valid <= '1';
            else
                cor_valid <= '0';
            end if;
            o_cor_valid <= cor_valid;
            o_cor_data <= dataFIFO_dout;
            
            sendCountDel1 <= sendCount;
            o_cor_time <= readoutTimeGroup(2 downto 0) & sendCountDel1(3 downto 0) & '0'; -- out std_logic_vector(7 downto 0); -- time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
            o_cor_VC   <= "000" & readoutVCx16 & sendCountDel1(5 downto 4) & "00";        -- out std_logic_vector(11 downto 0); -- first of the 4 virtual channels in o_cor_data
            o_cor_FC   <= readoutFineChannel; --  out std_logic_vector(11 downto 0); -- which 226 Hz fine channel is this ? 0 to 3455.
            o_cor_triangle <= "00" & readoutTriangle; --  out std_logic_vector(3 downto 0); -- which correlator triangle is this data for ? 0 to 3 for modes that don't use substations.
            if readout_fsm = signal_correlator and readoutKey(0) = '1' then
                o_cor_last <= '1'; --  out std_logic;  -- last word in a block for correlation; Indicates that the correlator can start processing the data just delivered.
            else
                o_cor_last <= '0';
            end if;
            if readout_fsm = signal_correlator and readoutKey(1) = '1' then
                o_cor_final <= '1';  -- Tells the correlator that the integration is complete.
            else
                o_cor_final <= '0';
            end if;
        end if;
    end process;
    
end Behavioral;
