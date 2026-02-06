----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 28 Jan 2026
-- Module Name: corr_ct2_din2HBM_v80 - Behavioral (modified from the previous U55C version : corr_ct2_din.vhd)
-- Description: 
--    Corner turn between the filterbanks and the correlator for SKA correlator processing. 
--    This module copies data out of the ultraRAM buffer into the HBM.
--    A single HBM interface is implemented, for either even or odd-indexed fine channels.
--     - Even and odd indexed fine channels have their own ultraRAM buffer 
--    Tasks :
--        - For each of 3 groups of 4 virtual channels ;=:
--          - Generate the read address to the ultraRAM buffer
--          - Generate the HBM address to write to
--        - FIFOs for the AW bus and the wdata buses
--        - 256 bit wide interface to the HBM
--    
--    Data flow :
--     - An instruction comes in indicating that 16 time samples have been captured in the ultraRAM buffer
--        - meta data for each of 3 groups of 4 virtual channels is also provided
--     - state machine steps through all 1728 fine channels, and generates write addresses to HBM if required 
--        - There are 3456 fine channels per coarse channel, but each instance of this module only deals with even or odd indexed fine channels
--
--
--
--
--
-- Data coming in from the filterbanks :
--   12 dual-pol channels, with burst of 3456 fine channels at a time.
--   Total number of bytes per clock coming in is (12 channels)*(2 pol)*(2 complex) = 48 bytes.
--   with roughly 3456 out of every 4096 clocks active.
--   Total data rate in is thus roughly (48 bytes * 8 bits)*3456/4096 * 300 MHz = 97 Gb/sec (this is the average data rate while data is flowing)
--   Long term average data rate in = (3456/4096 fine channels used) * (1/1080ns sampling period) * (32 bits/sample) * (1024 channels) = 77 Gb/sec 
--
-- Storing to HBM and incoming ultraRAM buffering
--   See comments in the level above, corr_ct2_top_v80.vhd
--      
-- Data from the filterbank comes in 3456 clock long packets, with 3456 fine channels.
-- Data comes in bursts of 64 packets, for 64 consecutive time samples for a set of 12 virtual channels.
-- On receiving the first packet in a burst, we look up the virtual channel in the "vc_demap" table for each of the 3 groups of 4 virtual channels.
-- This tells us :
--   First 32-bit word : Info about which subarray-beam this is used for. 
--          * i_demap_SB_index     = 8-bit subarray-beam id, used to look up the correct entry in the subarray-beam table
--          * i_demap_station      = 12-bit station within this subarray-beam; this is the index of the station as used by the correlator
--          * i_demap_skyFrequency = 9-bit sky frequency
--          * i_demap_valid        = 1-bit valid; if this bit is not set, then these virtual channels will be dropped.
--   Second 32-bit word : Info about which fine channel data to send out on the 100GE link (Unused).
--   
-- Once we have the subarray-beam from the vc_demap table, we look it up in the subarray-beam (SB) table, which give us :
--     * i_SB_stations      : The number of (sub)stations in this subarray-beam.
--     * i_SB_coarseStart   : The first coarse channel in this subarray-beam in this Alveo
--     * i_SB_fineStart     : The index of the first fine channel
--     * i_SB_N_fine        : The number of fine channels to use for this subarray-beam (starting from i_SB_coarseStart, i_SB_fineStart)
--     * i_SB_HBM_base_Addr : The base address in HBM to write this data to; somewhere in a 9 Gbyte block of memory.
--                            The address is in units of 4 bytes, so 32 bit address is sufficient for 16 GBytes of memory.
--     * i_SB_valid
-- We then have to calculate the address of each 256 byte data block.
-- Data is stored in a 3-D array indexed by [time,fine_channel,(demap_station/4)]
-- grouped by station first, then fine_channel and lastly time sample block, so:
-- 
--  HBM address (in bytes) = 
--   i_SB_HBM_base_Addr + 256 * [(demap_station/4) +
--                               (fine_channel - (i_SB_coarseStart * 3456 + i_SB_fineStart)) * i_SB_stations + 
--                               time * i_SB_N_fine * i_SB_stations]
--  where:
--   fine_channel = demap_skyFrequency + 0:3455
--           time = 0 to 11, for 12 blocks of 16 time samples each (there are 16 time samples in a 256 byte block written to the HBM).
--                  Note 12 x 16 = 192 time samples total = 849 ms of data.
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

entity corr_ct2_din2HBM_v80 is
    generic (
        g_DEBUG_ILA : BOOLEAN := FALSE;
        g_ODD_FINE  : std_logic := '0'  -- This module works through half the fine channels (3456/2 = 1728). Set this to 1 to process odd-indexed fine channels, or 0 for the even-indexed fine channels
    );
    port(
        i_rst : in std_logic;
        i_axi_clk : in std_logic;
        --------------------------------------------------------------------
        -- Instructions in to copy data to HBM
        -- one bit for each group of 4 virtual channels. 
        -- Goes high for a single clock cycle. e.g. if all three groups of virtual channels are available, this will go to "111" for one clock
        i_copyToHBM : in std_logic_Vector(2 downto 0);
        -- Which half of the HBM to write to. Switches every 849ms. 
        i_copyToHBM_buffer : in std_logic;
        -- which group of 16 time samples we are up to. In total there are 12 groups of 16 times samples, for 12*16 = 192 time samples per 849ms frame
        i_copyToHBM_time : in std_logic_vector(3 downto 0);
        -- index of the station within the subarray, for each of the 3 groups of 4 stations
        i_copyToHBM_station : in t_slv_12_arr(2 downto 0);
        -- frequency channel for each of the 3 groups of station. 0 to 511, in units of 781.25 KHz
        i_copyToHBM_skyFrequency : in t_slv_9_arr(2 downto 0);
        --
        i_copyToHBM_SB_stations :  in t_slv_16_arr(2 downto 0);
        i_copyToHBM_SB_coarseStart : in t_slv_16_arr(2 downto 0);
        i_copyToHBM_SB_fineStart : in t_slv_16_arr(2 downto 0);
        i_copyToHBM_SB_n_fine : in t_slv_24_arr(2 downto 0);
        i_copyToHBM_SB_HBM_base_addr : in t_slv_36_arr(2 downto 0);
        -- trigger readout of 849ms frame to the correlators once this data is written to the HBM
        i_copyToHBM_trigger_readout : in std_logic;
        -- i_copyToHBM_trigger_readout propagates to this output to indicate copying to HBM is complete and readout of the 849ms frame can start
        o_copyToHBM_done : out std_logic;
        -------------------------------------------------------------------
        -- Read from the ultraRAM buffer
        o_uram_rd_addr : out std_logic_vector(14 downto 0);
        -- 3 x 256 bit wide buses, for groups of stations 0-3, 4-7, 8-11
        -- 8 clock read latency from o_uram_rd_addr to i_uram_rd_dataX_X
        i_uram_rd_data0_3 : in std_logic_vector(255 downto 0);
        i_uram_rd_data4_7 : in std_logic_vector(255 downto 0);
        i_uram_rd_data8_11: in std_logic_vector(255 downto 0);
        -------------------------------------------------------------------
        -- Status
        o_status1 : out std_logic_vector(31 downto 0);  -- fifo counts and fsm states
        o_max_copyData_time : out std_logic_vector(31 downto 0); -- time required to put out all the data
        o_min_trigger_interval : out std_logic_Vector(31 downto 0); -- minimum time available
        o_wr_overflow : out std_logic_vector(31 downto 0); --overflow + debug info when the overflow occurred.
        -------------------------------------------------------------------
        -- AXI interface to the HBM
        -- Corner turn between filterbanks and correlator
        o_HBM_axi_aw      : out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_awready : in  std_logic;
        o_HBM_axi_w       : out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_HBM_axi_wready  : in  std_logic;
        i_HBM_axi_b       : in  t_axi4_full_b     -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
    );
end corr_ct2_din2HBM_v80;

architecture Behavioral of corr_ct2_din2HBM_v80 is
    
    
    type  aw_fsm_t is (get_addr0, get_Addr1, get_addr2, wait_addr0, addr1, addr2, done);
    signal aw_fsm, aw_fsm_del1 : aw_fsm_t := done;
    
    type wdataCopy_fsm_t is (idle, copyData, wait_FIFO);
    signal wdataCopy_fsm : wdataCopy_fsm_t := idle;
    
    signal copyToHBM_buffer : std_logic;
    signal copyToHBM_time : std_logic_vector(3 downto 0);
    signal copyToHBM_station : t_slv_12_arr(2 downto 0);
    signal copyToHBM_skyFrequency : t_slv_9_arr(2 downto 0);
    signal copyToHBM_SB_stations  : t_slv_16_arr(2 downto 0);
    signal copyToHBM_SB_coarseStart : t_slv_16_arr(2 downto 0);
    signal copyToHBM_SB_fineStart : t_slv_16_arr(2 downto 0);
    signal copyToHBM_SB_n_fine : t_slv_24_arr(2 downto 0);
    signal copyToHBM_SB_HBM_base_addr : t_slv_36_arr(2 downto 0);
    signal copyToHBM_trigger_readout : std_logic;
    
    signal SB_HBM_base_addr : std_logic_vector(35 downto 0);
    signal SB_coarseStart : std_logic_vector(8 downto 0);
    signal SB_fineStart : std_logic_vector(11 downto 0);
    signal SB_stations : std_logic_vector(15 downto 0);
    signal SB_N_fine : std_logic_vector(23 downto 0);
    signal skyFrequency : std_logic_vector(8 downto 0);
    signal uram_fine : std_logic_vector(10 downto 0);
    signal fine_ext : std_logic_vector(23 downto 0);
    signal cur_station : std_logic_vector(11 downto 0);
    signal wcopy_fifo_space_available, wdata_FIFO_space_available : std_logic := '0';
    signal vc_block_select : std_logic_vector(1 downto 0);
    signal vc_block_select_del : t_slv_2_arr(6 downto 0);
    signal wCopyFIFO_WrCount : std_logic_vector(6 downto 0);
    signal awFIFO_WrCount : std_logic_vector(9 downto 0);
    signal aw_fsm_dbg : std_logic_vector(3 downto 0);
    signal wdataCopy_fsm_dbg : std_logic_vector(1 downto 0);
    signal time_between_wr_triggers, minimum_time_between_wr_triggers, copydata_readout_time, max_copydata_readout_time, wr_overflow : std_logic_vector(31 downto 0);
    signal get_addr : std_logic := '0';
    signal wcopyFIFO_din : std_logic_vector(14 downto 0);
    signal calc_HBM_addr : std_logic_vector(35 downto 0);
    signal awFIFO_din, awFIFO_dout : std_logic_vector(35 downto 0);
    signal awFIFO_wrEn, awFIFO_rdEn, awFIFO_valid, awFIFO_empty : std_logic;
    signal addr_valid, calc_HBM_addr_out_of_range, calc_HBM_fine_high : std_logic;
    signal wCopyfifo_rst, awfifo_rst, wdatafifo_rst, aw_fifo_space_available : std_logic;
    signal wCopyFIFO_valid : std_logic;
    signal wCopyFIFO_dout : std_logic_vector(14 downto 0);
    signal wCopyFIFO_empty, wCopyFIFO_RdEn : std_logic;
    signal wdataFIFO_WrCount : std_logic_vector(9 downto 0);
    signal uram_rd_addr, uram_base_addr : std_logic_vector(14 downto 0);
    signal uram_rd_addr_offset : std_logic_vector(2 downto 0);
    signal last_write_pending_del1, last_write_pending : std_logic := '0';
    signal uram_addr_valid_del : std_logic_vector(7 downto 0) := x"00";
    signal wdataFIFO_din, wdataFIFO_dout : std_logic_vector(256 downto 0);
    signal last_del : std_logic_vector(7 downto 0);
    signal wdataFIFO_wrEn : std_logic := '0';
    signal wdataFIFO_valid, wdataFIFO_RdEn : std_logic := '0';
    
begin
    
    -- Once something goes into awFIFO, then the axi standard will be broken 
    wCopyfifo_rst <= '0';
    awfifo_rst <= '0';
    wdatafifo_rst <= '0';
    
    hbm_addri : entity ct_lib.get_ct2_HBM_addr_v80
    generic map (
        g_BUFFER_OFFSET => x"240000000"  -- Each half of the buffer in the v80 is 9 Gbytes; 
    ) port map (
        i_axi_clk => i_axi_clk, --  in std_logic;
        -- Values from the Subarray-beam table
        i_SB_HBM_base_Addr => SB_HBM_base_addr, --  in std_logic_vector(35 downto 0); -- Base address in HBM for this subarray-beam
        i_SB_coarseStart   => SB_coarseStart(8 downto 0), --  in std_logic_vector(8 downto 0);  -- First coarse channel for this subarray-beam, x781.25 kHz to get the actual sky frequency 
        i_SB_fineStart     => SB_fineStart(11 downto 0), -- in std_logic_vector(11 downto 0); -- First fine channel for this subarray-beam, runs from 0 to 3455
        i_SB_stations      => SB_stations, -- in std_logic_vector(15 downto 0); -- Total number of stations in this subarray-beam
        i_SB_N_fine        => SB_N_fine, -- in std_logic_vector(23 downto 0); -- Total number of fine channels to store for this subarray-beam
        -- Values for this particular block of 256 bytes. Each block of 256 bytes is 4 stations, 16 time samples ((4 stations)*(16 timesamples)*(2 pol)*(1 byte)(2 (complex)) = 256 bytes)
        i_coarse_channel   => skyFrequency, --  in std_logic_vector(8 downto 0);  -- coarse channel for this block, x781.25kHz to get the actual sky frequency (so is comparable to i_SB_coarseStart
        i_fine_channel     => fine_ext, --  in std_logic_vector(23 downto 0); -- fine channel for this block; Actual channel referred to is i_coarse_channel*3456 + i_fine_channel, so it is ok for this to be more than 3455.
        i_station          => cur_station, --  in std_logic_vector(11 downto 0); -- Index of this station within the subarray; low 2 bits are ignored.
        i_time_block       => copyToHBM_time,   -- in std_logic_vector(3 downto 0);  -- Which time block this is for; 0 to 11. Each time block is 16 time samples.
        i_buffer           => copyToHBM_buffer, -- in std_logic; -- Which half of the buffer to calculate for - add g_BUFFER_OFFSET if this is '1'
        -- All above data is valid, do the calculation.
        i_valid            => get_addr, -- in std_logic;
        -- Resulting address in the HBM, after 8 cycles latency.
        o_HBM_addr     => calc_HBM_addr, -- out std_logic_vector(35 downto 0); -- byte address in HBM, always 256-byte aligned (so low 8 bits will always be 0s).
        o_out_of_range => calc_HBM_addr_out_of_range, -- out std_logic; -- indicates that the values for (i_coarse_channel, i_fine_channel, i_station, i_time_block) are out of range, and thus o_HBM_addr is not valid.
        o_fine_high    => calc_HBM_fine_high, --  out std_logic; -- indicates that the fine channel selected is higher than the maximum fine channel (i.e. > (i_SB_coarseStart * 3456 + i_SB_fineStart))
        o_fine_remaining => open,     --  out std_logic_vector(11 downto 0); -- Number of fine channels remaining to send for this coarse channel.
        o_valid        => addr_valid  -- out std_logic -- 8 clock cycles after i_valid.
    );
    
    fine_ext <= "000000000000" & uram_fine & g_ODD_FINE;
    
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            
            if i_copyToHBM /= "000" then
                -- fsm counts through all the fine channels, from 0 to 1727
                uram_fine <= (others => '0');
                copyToHBM_buffer <= i_copyToHBM_buffer; -- in std_logic;
                -- which group of 16 time samples we are up to. In total there are 12 groups of 16 times samples, for 12*16 = 192 time samples per 849ms frame
                copyToHBM_time <= i_copyToHBM_time; -- in std_logic_vector(3 downto 0);
                -- index of the station within the subarray, for each of the 3 groups of 4 stations
                copyToHBM_station <= i_copyToHBM_station; -- : in t_slv_12_arr(2 downto 0);
                -- frequency channel for each of the 3 groups of station. 0 to 511, in units of 781.25 KHz
                copyToHBM_skyFrequency <= i_copyToHBM_skyFrequency; --  : in t_slv_9_arr(2 downto 0);
                --
                copyToHBM_SB_stations <= i_copyToHBM_SB_stations; --  in t_slv_16_arr(2 downto 0);
                copyToHBM_SB_coarseStart <= i_copyToHBM_SB_coarseStart; -- : in t_slv_16_arr(2 downto 0);
                copyToHBM_SB_fineStart <= i_copyToHBM_SB_fineStart; --: in t_slv_16_arr(2 downto 0);
                copyToHBM_SB_n_fine <= i_copyToHBM_SB_n_fine;-- : in t_slv_24_arr(2 downto 0);
                copyToHBM_SB_HBM_base_addr <= i_copyToHBM_SB_HBM_base_addr; -- : in t_slv_36_arr(2 downto 0);
                -- trigger readout to the correlators once this data is written to the HBM
                copyToHBM_trigger_readout <= i_copyToHBM_trigger_readout; --  : in std_logic;
                
                aw_fsm <= get_addr0;
                aw_fsm_dbg <= "0000";
                wcopyFIFO_din <= (others => '0');
                get_addr <= '0';
            else
                case aw_fsm is
                    when get_addr0 =>
                        SB_HBM_base_addr <= copyToHBM_SB_HBM_base_addr(0);
                        SB_coarseStart <= copyToHBM_SB_coarseStart(0)(8 downto 0);
                        SB_fineStart <= copyToHBM_SB_fineStart(0)(11 downto 0);
                        SB_stations <= copyToHBM_SB_stations(0);
                        SB_n_fine <= copyToHBM_SB_n_fine(0);
                        skyFrequency <= copyToHBM_skyFrequency(0);
                        cur_station <= copyToHBM_station(0);
                        get_addr <= '1';
                        awFIFO_wrEn <= '0';
                        aw_fsm <= get_addr1;
                        aw_fsm_dbg <= "0001";
                       
                    when get_addr1 =>
                        SB_HBM_base_addr <= copyToHBM_SB_HBM_base_addr(1);
                        SB_coarseStart <= copyToHBM_SB_coarseStart(1)(8 downto 0);
                        SB_fineStart <= copyToHBM_SB_fineStart(1)(11 downto 0);
                        SB_stations <= copyToHBM_SB_stations(1);
                        SB_n_fine <= copyToHBM_SB_n_fine(1);
                        skyFrequency <= copyToHBM_skyFrequency(1);
                        cur_station <= copyToHBM_station(1);
                        get_addr <= '1';
                        awFIFO_wrEn <= '0';
                        aw_fsm <= get_addr2;
                        aw_fsm_dbg <= "0010";
                        
                    when get_addr2 =>
                        SB_HBM_base_addr <= copyToHBM_SB_HBM_base_addr(2);
                        SB_coarseStart <= copyToHBM_SB_coarseStart(2)(8 downto 0);
                        SB_fineStart <= copyToHBM_SB_fineStart(2)(11 downto 0);
                        SB_stations <= copyToHBM_SB_stations(2);
                        SB_n_fine <= copyToHBM_SB_n_fine(2);
                        skyFrequency <= copyToHBM_skyFrequency(2);
                        cur_station <= copyToHBM_station(2);
                        get_addr <= '1';
                        awFIFO_wrEn <= '0';
                        aw_fsm <= wait_addr0;
                        aw_fsm_dbg <= "0011";
                        
                    when wait_addr0 =>
                        -- Get the address in HBM for fine channel uram_fine and virtual channels 0 to 3
                        get_addr <= '0';
                        if addr_valid = '1' then
                            awFIFO_din <= calc_HBM_addr;
                            wcopyFIFO_din <= copyToHBM_trigger_readout & copyToHBM_time(0) & "00" & uram_fine;
                            if calc_HBM_addr_out_of_range = '0' and calc_HBM_fine_high = '0' then
                                awFIFO_wrEn <= '1';
                            else
                                awFIFO_wrEn <= '0';
                            end if;
                            aw_fsm <= addr1;
                        else
                            awFIFO_wrEn <= '0';
                        end if;
                        aw_fsm_dbg <= "0100";
                        
                    when addr1 =>
                        -- Get the address in HBM for fine channel uram_fine and virtual channels 4 to 7
                        awFIFO_din <= calc_HBM_addr;
                        wcopyFIFO_din <= copyToHBM_trigger_readout & copyToHBM_time(0) & "01" & uram_fine;
                        if calc_HBM_addr_out_of_range = '0' and calc_HBM_fine_high = '0' then
                            awFIFO_wrEn <= '1';
                        else
                            awFIFO_wrEn <= '0';
                        end if;
                        aw_fsm <= addr2;
                        get_addr <= '0';
                        aw_fsm_dbg <= "0101";
                        
                    when addr2 =>
                        -- Get the address in HBM for fine channel uram_fine and virtual channels 8 to 11
                        awFIFO_din <= calc_HBM_addr;
                        wcopyFIFO_din <= copyToHBM_trigger_readout & copyToHBM_time(0) & "10" & uram_fine;
                        if calc_HBM_addr_out_of_range = '0' and calc_HBM_fine_high = '0' then
                            awFIFO_wrEn <= '1';
                        else
                            awFIFO_wrEn <= '0';
                        end if;
                        if aw_fifo_space_available = '1' and wcopy_fifo_space_available = '1' then
                            if unsigned(uram_fine) = 1727 then
                                aw_fsm <= done;
                            else
                                uram_fine <= std_logic_vector(unsigned(uram_fine) + 1);
                                aw_fsm <= get_addr0;
                            end if;
                        end if;
                        get_addr <= '0';
                        aw_fsm_dbg <= "0110";
                        
                    when done =>
                        aw_fsm <= done;
                        aw_fsm_dbg <= "0111";
                        
                    when others => 
                        aw_fsm <= done;
                end case;
            end if;
            
            -------------------------------------------------------------------------------
            -- Check that there is space in both fifos for at least another 3 entries
            if (unsigned(wCopyFIFO_WrCount) < 56) then
                wcopy_fifo_space_available <= '1';
            else
                wcopy_fifo_space_available <= '0';
            end if;
            
            if (unsigned(awFIFO_WrCount) < 500) then
                aw_fifo_space_available <= '1';
            else
                aw_fifo_space_available <= '0';
            end if;
            ------------------------------------------------------------------------------
            
        end if;
    end process;
    
    
    -- FIFO for aw requests
    xpm_awfifo_sync_inst : xpm_fifo_sync
    generic map (
        CASCADE_HEIGHT => 0,        -- DECIMAL
        DOUT_RESET_VALUE => "0",    -- String
        ECC_MODE => "no_ecc",       -- String
        FIFO_MEMORY_TYPE => "auto", -- String
        FIFO_READ_LATENCY => 0,     -- DECIMAL
        FIFO_WRITE_DEPTH => 512,    -- DECIMAL
        FULL_RESET_VALUE => 0,      -- DECIMAL
        PROG_EMPTY_THRESH => 10,    -- DECIMAL
        PROG_FULL_THRESH => 10,     -- DECIMAL
        RD_DATA_COUNT_WIDTH => 10,   -- DECIMAL
        READ_DATA_WIDTH => 36,      -- DECIMAL
        READ_MODE => "fwft",        -- String
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "1404", -- String; bit 12 = enable data valid flag, bits 2 and 10 enable read and write data counts
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 36,     -- DECIMAL
        WR_DATA_COUNT_WIDTH => 10   -- DECIMAL
    ) port map (
        almost_empty => open,     -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
        almost_full => open,      -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
        data_valid => awFIFO_valid, -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
        dbiterr => open,          -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
        dout => awFIFO_dout,      -- READ_DATA_WIDTH-bit output: Read Data: The output data bus is driven when reading the FIFO.
        empty => awFIFO_empty,    -- 1-bit output: Empty Flag: When asserted, this signal indicates that- the FIFO is empty.
        full => open,             -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full.
        overflow => open,         -- 1-bit output: Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected, because the FIFO is full
        prog_empty => open,       -- 1-bit output: Programmable Empty: This signal is asserted when the number of words in the FIFO is less than or equal to the programmable empty threshold value.
        prog_full => open,        -- 1-bit output: Programmable Full: This signal is asserted when the number of words in the FIFO is greater than or equal to the programmable full threshold value.
        rd_data_count => open, -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
        rd_rst_busy => open,   -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
        sbiterr => open,       -- 1-bit output: Single Bit Error: Indicates that the ECC decoder detected and fixed a single-bit error.
        underflow => open,     -- 1-bit output: Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected because the FIFO is empty.
        wr_ack => open,        -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.
        wr_data_count => awFIFO_WrCount, -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        wr_rst_busy => open,     -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
        din => awFIFO_din,  -- WRITE_DATA_WIDTH-bit input: Write Data: The input data bus used when writing the FIFO.
        injectdbiterr => '0', -- 1-bit input: Double Bit Error Injection
        injectsbiterr => '0', -- 1-bit input: Single Bit Error Injection: 
        rd_en => awFIFO_RdEn, -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO. 
        rst => awfifo_rst,      -- 1-bit input: Reset: Must be synchronous to wr_clk.
        sleep => '0',         -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
        wr_clk => i_axi_clk,  -- 1-bit input: Write clock: Used for write operation. wr_clk must be a free running clock.
        wr_en => awFIFO_wrEn  -- 1-bit input: Write Enable: 
    );
    
    
    o_HBM_axi_aw.addr <= "0000" & awFIFO_dout; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
    o_HBM_axi_aw.valid <= awFIFO_valid;
    o_HBM_axi_aw.len <= "00000111"; -- all writes are 8 x 32-byte words
    awFIFO_rdEn <= i_HBM_axi_awready and awFIFO_valid;
    
    -- fifo with instruction to the wdata_copy fsm to copy a 256 byte block from the uram buffer to the wdata bus
    -- 15 bits wide :
    --   bits 10:0 = fine channel to copy, 
    --   bits 12:11 = group of virtual channels to copy, "00" = virtual channels 0-3, "01" = virtual channels 4-7, "10" = virtual channels 8-11
    --   bit  13 = which half of the ultraRAM buffer to read from
    --   bit  14 = last instruction in an 849ms correlator frame
    xpm_wdatacopy_fifo_sync_inst : xpm_fifo_sync
    generic map (
        CASCADE_HEIGHT => 0,        -- DECIMAL
        DOUT_RESET_VALUE => "0",    -- String
        ECC_MODE => "no_ecc",       -- String
        FIFO_MEMORY_TYPE => "distributed", -- String
        FIFO_READ_LATENCY => 0,     -- DECIMAL
        FIFO_WRITE_DEPTH => 64,    -- DECIMAL
        FULL_RESET_VALUE => 0,      -- DECIMAL
        PROG_EMPTY_THRESH => 10,    -- DECIMAL
        PROG_FULL_THRESH => 10,     -- DECIMAL
        RD_DATA_COUNT_WIDTH => 7,   -- DECIMAL
        READ_DATA_WIDTH => 15,      -- DECIMAL
        READ_MODE => "fwft",        -- String
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "1404", -- String; bit 12 = enable data valid flag, bits 2 and 10 enable read and write data counts
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 15,     -- DECIMAL
        WR_DATA_COUNT_WIDTH => 7   -- DECIMAL
    ) port map (
        almost_empty => open,     -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
        almost_full => open,      -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
        data_valid => wCopyFIFO_valid, -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
        dbiterr => open,          -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
        dout => wCopyFIFO_dout,   -- READ_DATA_WIDTH-bit output: Read Data: The output data bus is driven when reading the FIFO.
        empty => wCopyFIFO_empty, -- 1-bit output: Empty Flag: When asserted, this signal indicates that- the FIFO is empty.
        full => open,             -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full.
        overflow => open,         -- 1-bit output: Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected, because the FIFO is full
        prog_empty => open,       -- 1-bit output: Programmable Empty: This signal is asserted when the number of words in the FIFO is less than or equal to the programmable empty threshold value.
        prog_full => open,        -- 1-bit output: Programmable Full: This signal is asserted when the number of words in the FIFO is greater than or equal to the programmable full threshold value.
        rd_data_count => open, -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
        rd_rst_busy => open,   -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
        sbiterr => open,       -- 1-bit output: Single Bit Error: Indicates that the ECC decoder detected and fixed a single-bit error.
        underflow => open,     -- 1-bit output: Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected because the FIFO is empty.
        wr_ack => open,        -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.
        wr_data_count => wCopyFIFO_WrCount, -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        wr_rst_busy => open,     -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
        din => wcopyFIFO_din,  -- WRITE_DATA_WIDTH-bit input: Write Data: The input data bus used when writing the FIFO.
        injectdbiterr => '0', -- 1-bit input: Double Bit Error Injection
        injectsbiterr => '0', -- 1-bit input: Single Bit Error Injection: 
        rd_en => wCopyFIFO_RdEn, -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO. 
        rst => wCopyfifo_rst,      -- 1-bit input: Reset: Must be synchronous to wr_clk.
        sleep => '0',         -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
        wr_clk => i_axi_clk,  -- 1-bit input: Write clock: Used for write operation. wr_clk must be a free running clock.
        wr_en => awFIFO_wrEn  -- 1-bit input: Write Enable: 
    );
    
    wCopyFIFO_RdEn <= '1' when wCopyFIFO_valid = '1' and wdataCopy_fsm = idle else '0';
    uram_base_addr <= '0' & wCopyFIFO_dout(10 downto 0) & "000";  -- 8 words in the ultraRAMs for each 
    o_uram_rd_addr <= uram_rd_addr(14 downto 3) & uram_rd_addr_offset;
    
    process(i_axi_clk)
    begin
        if rising_Edge(i_axi_clk) then
            -- fsm to copy data from the ultraRAM buffer into the output FIFO 
            case wdataCopy_fsm is
                when idle =>
                    if wCopyFIFO_valid = '1' then
                        -- 2nd and 4th group of 16 times go to the second half of the memory,
                        -- which starts at 3.5*4096 = 14336
                        if wCopyFIFO_dout(13) = '0' then
                            uram_rd_addr <= uram_base_addr;
                        else
                            uram_rd_addr <= std_logic_vector(unsigned(uram_base_addr) + 14336);
                        end if;
                        vc_block_select <= wCopyFIFO_dout(12 downto 11); -- Which of the 3 groups of virtual channels to choose.
                        uram_rd_addr_offset <= "000";
                        wdataCopy_fsm <= copyData;
                    end if;
                    wdataCopy_fsm_dbg <= "00";
                
                when copyData =>
                    if uram_rd_addr_offset = "111" then
                        -- check for space in the output FIFO
                        if (wdata_FIFO_space_available = '1') then
                            wdataCopy_fsm <= idle;
                        else
                            wdataCopy_fsm <= wait_FIFO;
                        end if;
                    end if;
                    uram_rd_addr_offset <=  std_logic_vector(unsigned(uram_rd_addr_offset) + 1);
                    wdataCopy_fsm_dbg <= "01";
                    
                when wait_FIFO =>
                    -- check for space in the output FIFO
                    if (wdata_FIFO_space_available = '1') then
                        wdataCopy_fsm <= idle;
                    end if;
                    wdataCopy_fsm_dbg <= "10";
                    
                when others =>
                    wdataCopy_fsm <= idle;
            
            end case;
            
            ----------------------------------------------
            -- determine when the end of an 849ms frame occurs 
            if wdataCopy_fsm = idle and wCopyFIFO_valid = '1' and wCopyFIFO_dout(14) = '1' then
                last_write_pending <= '1';
            elsif aw_fsm = done and wdataCopy_fsm = idle and wCopyFIFO_empty = '1' and awFIFO_empty = '1'  then
                last_write_pending <= '0'; 
            end if;
            last_write_pending_del1 <= last_write_pending;
            if last_write_pending = '0' and last_write_pending_del1 = '1' then                
                o_copyToHBM_done <= '1';
            else
                o_copyToHBM_done <= '0';
            end if;
            -----------------------------------------------
            
            if unsigned(wdataFIFO_WrCount) < 488 then 
                -- There is a latency of about 9 clocks between the fsm and data going into the FIFO
                -- So we need at least 2 lots of 8 words available in the FIFO before getting more data
                wdata_FIFO_space_available <= '1';
            else
                wdata_FIFO_space_available <= '0';
            end if;

            -- Read from the ultraRAM buffer has 8 clock latency
            -- The read address is valid in the state copyData
            if wdataCopy_fsm = copyData then
                uram_addr_valid_del(0) <= '1';
            else
                uram_addr_valid_del(0) <= '0';
            end if;
            if wdataCopy_fsm = copyData and uram_rd_addr_offset = "111" then
                last_del(0) <= '1';
            else
                last_del(0) <= '0';
            end if;
            vc_block_select_del(0) <= vc_block_select;
            
            uram_addr_valid_del(7 downto 1) <= uram_addr_valid_del(5 downto 0);
            vc_block_select_del(7 downto 1) <= vc_block_select_del(5 downto 0);
            last_del(7 downto 1) <= last_del(6 downto 0);
            
            if (vc_block_select_del(7) = "00") then
                wdataFIFO_din(255 downto 0) <=  i_uram_rd_data0_3;
            elsif (vc_block_select_del(7) = "01") then
                wdataFIFO_din(255 downto 0) <= i_uram_rd_data4_7;
            else
                wdataFIFO_din(255 downto 0) <= i_uram_rd_data8_11;
            end if;
            wdataFIFO_din(256) <= last_del(7);
            wdataFIFO_wrEn <= uram_addr_valid_del(7);
            
            --------------------------------------------------------
            -- Keep track of things for registers:
            --   - minimum time between copy triggers
            --   - Max time for a readout
            --   - overwrite occurred - read trigger while still writing
            --
            if i_copyToHBM /= "000" then
                time_between_wr_triggers <= (others => '0');
            elsif time_between_wr_triggers(31) = '0' then
                time_between_wr_triggers <= std_logic_vector(unsigned(time_between_wr_triggers) + 1);
            end if;
            
            if i_rst = '1' then
                minimum_time_between_wr_triggers <= (others => '1');
            elsif i_copyToHBM /= "000" and (unsigned(time_between_wr_triggers) < unsigned(minimum_time_between_wr_triggers)) then
                minimum_time_between_wr_triggers <= time_between_wr_triggers;
            end if;
            
            if i_copyToHBM /= "000" then
                copydata_readout_time <= (others => '0');
            elsif aw_fsm /= done then
                copydata_readout_time <= std_logic_vector(unsigned(copydata_readout_time) + 1);
            end if;
            
            aw_fsm_del1 <= aw_fsm;
            if i_rst = '1' then
                max_copydata_readout_time <= (others => '0');
            elsif (aw_fsm = done and aw_fsm_del1 /= done) and (unsigned(copydata_readout_time) > unsigned(max_copydata_readout_time)) then
                max_copydata_readout_time <= copydata_readout_time;
            end if;
            
            if i_rst = '1' then
                wr_overflow <= (others => '0');
            elsif ((i_copyToHBM /= "000") and (aw_fsm /= done)) then
                wr_overflow(0) <= '1';
                wr_overflow(11 downto 1) <= uram_fine;
                wr_overflow(15 downto 12) <= i_copyToHBM_time;
                wr_overflow(27 downto 16) <= i_copyToHBM_station(0);
                wr_overflow(31 downto 28) <= "0000";
            end if;
            
            o_max_copyData_time <= max_copydata_readout_time; -- time required to put out all the data
            o_min_trigger_interval <= minimum_time_between_wr_triggers; -- minimum time available
            o_wr_overflow <= wr_overflow; -- overflow + debug info when the overflow occurred.
            
            -------------------------------------------------------------------------------------------------
            
        end if;
    end process;
    
    
    -- FIFO for wdata read from the ultraRAM buffer to go to the wdata bus
    xpm_wdata_fifo_sync_inst : xpm_fifo_sync
    generic map (
        CASCADE_HEIGHT => 0,        -- DECIMAL
        DOUT_RESET_VALUE => "0",    -- String
        ECC_MODE => "no_ecc",       -- String
        FIFO_MEMORY_TYPE => "block", -- String
        FIFO_READ_LATENCY => 0,     -- DECIMAL
        FIFO_WRITE_DEPTH => 512,    -- DECIMAL
        FULL_RESET_VALUE => 0,      -- DECIMAL
        PROG_EMPTY_THRESH => 10,    -- DECIMAL
        PROG_FULL_THRESH => 10,     -- DECIMAL
        RD_DATA_COUNT_WIDTH => 10,  -- DECIMAL
        READ_DATA_WIDTH => 257,     -- DECIMAL
        READ_MODE => "fwft",        -- String
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "1404", -- String; bit 12 = enable data valid flag, bits 2 and 10 enable read and write data counts
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 257,    -- DECIMAL
        WR_DATA_COUNT_WIDTH => 10   -- DECIMAL
    ) port map (
        almost_empty => open,    -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
        almost_full => open,     -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
        data_valid => wdataFIFO_valid, -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
        dbiterr => open,         -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
        dout => wdataFIFO_dout,  -- READ_DATA_WIDTH-bit output: Read Data: The output data bus is driven when reading the FIFO.
        empty => open,           -- 1-bit output: Empty Flag: When asserted, this signal indicates that- the FIFO is empty.
        full => open,            -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full.
        overflow => open,        -- 1-bit output: Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected, because the FIFO is full
        prog_empty => open,      -- 1-bit output: Programmable Empty: This signal is asserted when the number of words in the FIFO is less than or equal to the programmable empty threshold value.
        prog_full => open,       -- 1-bit output: Programmable Full: This signal is asserted when the number of words in the FIFO is greater than or equal to the programmable full threshold value.
        rd_data_count => open,   -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
        rd_rst_busy => open,     -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
        sbiterr => open,         -- 1-bit output: Single Bit Error: Indicates that the ECC decoder detected and fixed a single-bit error.
        underflow => open,       -- 1-bit output: Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected because the FIFO is empty.
        wr_ack => open,          -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.
        wr_data_count => wdataFIFO_WrCount, -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        wr_rst_busy => open,     -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
        din => wdataFIFO_din,    -- WRITE_DATA_WIDTH-bit input: Write Data: The input data bus used when writing the FIFO.
        injectdbiterr => '0',    -- 1-bit input: Double Bit Error Injection
        injectsbiterr => '0',    -- 1-bit input: Single Bit Error Injection: 
        rd_en => wdataFIFO_RdEn, -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO. 
        rst => wdatafifo_rst,    -- 1-bit input: Reset: Must be synchronous to wr_clk.
        sleep => '0',            -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
        wr_clk => i_axi_clk,     -- 1-bit input: Write clock: Used for write operation. wr_clk must be a free running clock.
        wr_en => wdataFIFO_wrEn  -- 1-bit input: Write Enable: 
    );
    
    o_HBM_axi_w.data(511 downto 256) <= (others => '0');
    o_HBM_axi_w.data(255 downto 0) <= wdataFIFO_dout(255 downto 0); -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
    o_HBM_axi_w.last <= wdataFIFO_dout(256);
    o_HBM_axi_w.valid <= wdataFIFO_valid;
    o_HBM_axi_w.resp <= "00";
    wdataFIFO_RdEn <= wdataFIFO_valid and i_HBM_axi_wready;
    
    o_status1(9 downto 0) <= wdataFIFO_wrCount;
    o_status1(16 downto 10) <= wCopyFIFO_WrCount;
    o_status1(26 downto 17) <= awFIFO_WrCount;
    o_status1(29 downto 27) <= aw_fsm_dbg;
    o_status1(31 downto 30) <= wdataCopy_fsm_dbg;
    
end Behavioral;
