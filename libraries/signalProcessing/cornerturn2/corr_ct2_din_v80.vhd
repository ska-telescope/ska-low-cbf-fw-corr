----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 28 Jan 2026
-- Module Name: corr_ct2_din_v80 - Behavioral (modified from the previous U55C version : corr_ct2_din.vhd)
-- Description: 
--    Corner turn between the filterbanks and the correlator for SKA correlator processing. 
--    This module is responsible for writing data from the filterbanks into the HBM.
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

entity corr_ct2_din_v80 is
    generic (
        g_DEBUG_ILA     : BOOLEAN := FALSE;    
        g_USE_META      : boolean := FALSE   -- Put meta data into the memory in place of the actual data, to make it easier to find bugs in the corner turn. 
    );
    port(
        i_rst : in std_logic;
        -- Data in from the correlator filterbanks; bursts of 3456 clocks for each channel.
        i_sof          : in std_logic; -- pulse high at the start of every new set of virtual channels
        -- frame count is the same for all simultaneous output streams.
        -- frameCount is the count of 1st corner turn frames, i.e. 283 ms pieces of data.
        i_frameCount_mod3 : in std_logic_vector(1 downto 0);  -- which of the three first corner turn frames is this, out of the 3 that make up a 849 ms integration. "00", "01", or "10".
        i_frameCount_849ms : in std_logic_vector(31 downto 0); -- which 849 ms integration is this ?
        i_virtualChannel0  : in std_logic_vector(15 downto 0); -- first of 12 virtual channels, one for each of the filterbank data streams.
        i_bad_poly        : in std_logic_vector(2 downto 0);
        i_lastChannel     : in std_logic;
        i_HeaderValid     : in std_logic_vector(11 downto 0);
        i_data            : in t_ctc_output_payload_arr(11 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0) to i_data(11)
        i_dataValid       : in std_logic;
        o_trigger_readout : out std_logic; -- Just received the last packet in a frame for a particular virtual channel.
        o_trigger_buffer  : out std_logic;
        o_trigger_frameCount : out std_logic_vector(31 downto 0);
        -- interface to the bad poly memories - one for each of the 6 possible correlator cores
        o_bp_addr     : out std_logic_vector(7 downto 0); -- same address for all 6 memories; 7 bit wide selects which of 128 correlations possible for each correlator core
        o_bp_wr_en    : out std_logic_vector(5 downto 0);
        o_bp_wr_data  : out std_logic; -- same write data for all 6 memories
        --------------------------------------------------------------------
        -- interface to the demap table 
        o_vc_demap_rd_addr   : out std_logic_vector(9 downto 0); -- 3072 virtual channels in groups of 4, so 768 entries are needed in the demap table
        o_vc_demap_req       : out std_logic_vector(2 downto 0); -- request a read from address o_vc_demap_rd_addr. 3 bit wide to identify 3 different requests.
        i_demap_data_valid   : in  std_logic_vector(2 downto 0); -- Read data below (i_demap* signals) is valid, for the corresponding request 
        i_demap_SB_index     : in std_logic_vector(9 downto 0);  -- index into the subarray-beam table.
        i_demap_station      : in std_logic_vector(11 downto 0); -- station index within the subarray-beam.
        i_demap_skyFrequency : in std_logic_vector(8 downto 0);  -- sky frequency.
        i_demap_valid        : in std_logic;                     -- This entry in the demap table is valid.
        -- Interface to the subarray_beam table
        -- Up to 768 entries; 128 entries for each of up to 6 correlators.
        o_SB_addr           : out std_logic_vector(9 downto 0); 
        o_SB_req            : out std_logic;
        i_SB_valid          : in std_logic;
        -- returned subarray beam ("SB") data :
        i_SB_stations       : in std_logic_vector(15 downto 0);  -- The number of (sub)stations in this subarray-beam
        i_SB_coarseStart    : in std_logic_vector(15 downto 0);  -- The first coarse channel in this subarray-beam
        i_SB_fineStart      : in std_logic_vector(15 downto 0);  -- readout_buf1_fineStart, -- the first fine channel in this subarray-beam
        i_SB_n_fine         : in std_logic_vector(23 downto 0);  -- The number of fine channels in this subarray-beam
        i_SB_HBM_base_addr  : in std_logic_vector(31 downto 0);  -- base address in HBM for this subarray-beam, in units of 4 bytes
        -------------------------------------------------------------------
        -- Status
        o_status1 : out std_logic_vector(31 downto 0);
        o_status2 : out std_logic_vector(31 downto 0);
        --
        o_max_copyAW_time : out std_logic_vector(31 downto 0); -- time required to put out all the addresses
        o_max_copyData_time : out std_logic_vector(31 downto 0); -- time required to put out all the data
        o_min_trigger_interval : out std_logic_Vector(31 downto 0); -- minimum time available
        o_wr_overflow : out std_logic_vector(31 downto 0); --overflow + debug info when the overflow occurred.
        --
        i_insert_dbg : in std_logic;
        -------------------------------------------------------------------
        -- AXI interface to the HBM
        -- Corner turn between filterbanks and correlator
        -- two HBM interfaces
        i_axi_clk : in std_logic;
        -- 3 Gbytes for virtual channels 0-511
        o_HBM_axi_aw      : out t_axi4_full_addr_arr(1 downto 0); -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_awready : in  std_logic_vector(1 downto 0);
        o_HBM_axi_w       : out t_axi4_full_data_arr(1 downto 0); -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_HBM_axi_wready  : in  std_logic_vector(1 downto 0);
        i_HBM_axi_b       : in  t_axi4_full_b_arr(1 downto 0)     -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
    );
end corr_ct2_din_v80;

architecture Behavioral of corr_ct2_din_v80 is
    
    signal bufDout : t_slv_128_arr(3 downto 0);
    signal bufWEFinal, bufWEFinal_del1 : std_logic_vector(3 downto 0);
    signal bufWE_slv : t_slv_1_arr(11 downto 0);
    signal bufWrAddr, bufWrAddrFinal, bufWrAddrFinal_del1 : std_logic_vector(14 downto 0);
    signal bufWrData, bufWrDataFinal, bufWrDataFinal_del1 : t_slv_128_arr(2 downto 0);
    signal bufRdAddr : t_slv_15_arr(1 downto 0);
    
    signal timeStep : std_logic_vector(5 downto 0);
    signal dataValidDel1, dataValidDel2 : std_logic := '0';
    signal copyToHBM : std_logic_vector(2 downto 0) := "000";
    
    type copy_fsm_t is (start, set_aw, wait_HBM1_aw_rdy, wait_HBM0_aw_rdy, skip_rdy, get_next_addr, idle);
    signal copy_fsm : copy_fsm_t := idle;
    signal copyToHBM_buffer : std_logic;
   -- signal copyToHBM_channelGroup : std_logic_vector(7 downto 0);
    signal copy_buffer : std_logic := '0';
    --signal copy_channelGroup : std_logic_vector(7 downto 0);
    signal copyToHBM_time : std_logic_vector(2 downto 0);
    signal copy_time : std_logic_vector(2 downto 0);
    signal fineChannel, fineChannel_del1 : std_logic_vector(11 downto 0);
    signal virtualChannel : std_logic_vector(15 downto 0);
    signal frameCount_mod3 : std_logic_vector(1 downto 0);
    signal frameCount_849ms : std_logic_vector(31 downto 0);
    
    signal dataFIFO_valid : std_logic_vector(1 downto 0);
    type t_slv_515_arr     is array (integer range <>) of std_logic_vector(514 downto 0);
    signal dataFIFO_dout : t_slv_515_arr(1 downto 0);
    signal dataFIFO_dataCount : t_slv_6_arr(1 downto 0);
    signal dataFIFO_din : t_slv_515_arr(1 downto 0);
    signal dataFIFO_rdEn : std_logic_vector(1 downto 0);
    signal dataFIFO_wrEn : std_logic_vector(1 downto 0);
    
    signal fifo_size_plus_pending, fifo_size_plus_pending1, fifo_size_plus_pending0 : std_logic_vector(5 downto 0);
    signal dataFIFO0_wrEn, dataFIFO1_wrEn : std_logic_vector(15 downto 0) := (others => '0');
    
    type copyData_fsm_type is (running, wait_fifo, idle);
    signal copyData_fsm : copyData_fsm_type := idle;
    signal bufRdCount : std_logic_vector(2 downto 0) := (others => '0');
    signal pending0, pending1 : std_logic_vector(5 downto 0);
    signal last : std_logic_vector(15 downto 0);
    signal lastTime : std_logic := '0';
    
    signal demap_station, copyToHBM_station : t_slv_12_arr(2 downto 0);
    signal copy_station : std_logic_vector(11 downto 0);  -- station index within the subarray-beam.
    signal demap_skyFrequency, copyToHBM_skyFrequency : t_slv_9_arr(2 downto 0);
    signal copy_skyFrequency : std_logic_vector(8 downto 0);  -- sky frequency.
    signal demap_valid : std_logic_vector(2 downto 0);                      -- This entry in the demap table is valid.
    signal SB_stations, copyToHBM_SB_stations : t_slv_16_arr(2 downto 0);
    signal copy_SB_stations : std_logic_vector(15 downto 0);  -- The number of (sub)stations in this subarray-beam
    signal SB_coarseStart, copyToHBM_SB_coarseStart : t_slv_16_arr(2 downto 0);
    signal copy_SB_coarseStart : std_logic_vector(15 downto 0);  -- The first coarse channel in this subarray-beam
    signal SB_fineStart, copyToHBM_SB_fineStart : t_slv_16_arr(2 downto 0);
    signal copy_SB_fineStart, copy_fineChannel : std_logic_vector(15 downto 0);  -- readout_buf1_fineStart, -- the first fine channel in this subarray-beam
    signal SB_n_fine, copyToHBM_SB_n_fine : t_slv_24_arr(2 downto 0);
    signal copy_SB_n_fine : std_logic_vector(23 downto 0);  -- The number of fine channels in this subarray-beam
    signal SB_HBM_base_addr : t_slv_32_arr(2 downto 0);
    signal copyToHBM_SB_HBM_base_addr : t_slv_36_arr(2 downto 0);
    signal copy_SB_HBM_base_addr : std_logic_vector(31 downto 0);  --
    
    signal SB_req : std_logic := '0';
    signal demap_SB_addr : t_slv_10_arr(2 downto 0);
    signal SB_addr : std_logic_vector(9 downto 0);
    
    signal HBM_base_plus_station : std_logic_vector(31 downto 0);
    signal N_fine_x_stations_full : signed(39 downto 0);
    signal N_fine_x_stations : std_logic_vector(25 downto 0);
    signal sof_del1 : std_logic := '0';
    signal time_block : std_logic_vector(3 downto 0);
    signal N_fine_x_stations_x_time : signed(29 downto 0);
    signal N_fine_x_stations_x_time_x512 : std_logic_vector(31 downto 0);
    signal copy_SB_HBM_sel : std_logic;
    --signal copyToHBM_SB_HBM_sel : std_logic; -- not needed with unified memory model for all correlator instances ?
    signal get_addr : std_logic;
    signal HBM_addr : std_logic_vector(31 downto 0);
    signal HBM_addr_bad, HBM_fine_high, HBM_Addr_valid : std_logic;
    signal fineChannel_ext : std_logic_vector(23 downto 0);
    signal sof_hold : std_logic := '0';
    signal trigger_demap_rd, trigger_demap_rd_del1, trigger_demap_rd_del2 : std_logic := '0';
    signal HBM_axi_aw : t_axi4_full_addr_arr(1 downto 0);
    signal HBM_fine_remaining : std_logic_vector(11 downto 0);
    signal trigger_copyData_fsm, first_aw : std_logic := '0';
    signal copyData_fineChannel_Start : std_logic_vector(15 downto 0);
    signal copyData_NFine_Start, copyData_fineRemaining : std_logic_vector(11 downto 0);
    signal copyData_fineChannel_Start_x8 : std_logic_vector(15 downto 0);
    signal trigger_readout, last_virtual_channel : std_logic := '0';
    signal last_word_in_frame : std_logic_vector(15 downto 0) := x"0000";
    signal copyData_trigger, copy_trigger, copyToHBM_trigger_readout, trigger_buffer : std_logic := '0';
    signal cbuffer : std_logic_vector(15 downto 0);
    signal copydata_buffer : std_logic := '0';
    signal copyToHBM_count, copydata_count : std_logic_vector(15 downto 0);
    signal copy_fsm_dbg : std_logic_vector(3 downto 0);
    signal copyData_fsm_dbg : std_logic_vector(3 downto 0);
    signal fifo_rst : std_logic := '0';
    signal copy_fsm_dbg_at_start : std_logic_vector(3 downto 0) := "1111";
    signal in_set_aw_count : std_logic_vector(7 downto 0) := x"00";
    signal copy_fsm_stuck : std_logic;
    signal virtualChannel0Del1 : std_logic_vector(15 downto 0);

    signal wait_HBMX_aw_rdy_stuck       : std_logic;
    signal wait_HBMX_aw_rdy_stuck_cnt   : unsigned(15 downto 0) := x"0000";
    signal trigger_frameCount, recent_frameCount : std_logic_vector(31 downto 0);
    
    COMPONENT ila_0
    PORT (
   	    clk : IN STD_LOGIC;
   	    probe0 : IN STD_LOGIC_VECTOR(191 DOWNTO 0));
    END COMPONENT;
    
    signal bad_poly_buffer : std_logic;
    
    --signal bp_addr0, bp_addr1 : std_logic_vector(6 downto 0);
    signal bp_addr : std_logic_vector(6 downto 0);
    type t_bad_poly_fsm is (clear_memory, check_bad0, set_bad0, check_bad1, set_bad1, check_bad2, set_bad2, idle, wait_check_bad);
    signal bad_poly_fsm : t_bad_poly_fsm := idle;
    signal bp_wr_en : std_logic_vector(5 downto 0);
    signal bad_poly_del1, bad_poly : std_logic_vector(2 downto 0);
    signal bp_wr_data  : std_logic;
    signal bad_poly_wait_count : std_logic_vector(7 downto 0);
    
    signal max_copyAW_time : std_logic_vector(31 downto 0); -- time required to put out all the addresses
    signal max_copyData_readout_time : std_logic_vector(31 downto 0); -- time required to put out all the data
    signal minimum_time_between_wr_triggers : std_logic_Vector(31 downto 0); -- minimum time available
    signal wr_overflow : std_logic_vector(31 downto 0);
    signal copyAW_time, copydata_readout_time, time_between_wr_triggers : std_logic_vector(31 downto 0);
    signal insert_dbg : std_logic;
    
    type SB_req_fsm_t is (get_SB0, wait_SB0, get_SB1, wait_SB1, get_SB2, wait_SB2, done);
    signal SB_req_fsm : SB_req_fsm_t := done;
    
    signal bufDout_even_0_3, bufDout_even_4_7, bufDout_even_8_11 : std_logic_vector(255 downto 0);
    signal bufDout_odd_0_3, bufDout_odd_4_7, bufDout_odd_8_11 : std_logic_vector(255 downto 0);
    signal copyToHBM_done_odd, copyToHBM_done_even : std_logic;
    
begin
    
    o_SB_req <= SB_req;
    o_SB_addr <= SB_addr;
    
    o_bp_addr <= bad_poly_buffer & bp_addr;
    o_bp_wr_en <= bp_wr_en;
    o_bp_wr_data <= bp_wr_data;
    
    process(i_axi_clk)
        variable demap_station_x128 : std_logic_vector(31 downto 0);
    begin
        if rising_edge(i_axi_clk) then
            dataValidDel1 <= i_dataValid;
            dataValidDel2 <= dataValidDel1;
            
            virtualChannel0Del1 <= i_virtualChannel0;
            
            ---------------------------------------------------------------------
            -- Bad poly tracking
            -- If there was no valid polynomial, then this module is notified via the i_bad_poly input.
            -- i_bad_poly is driven along with i_dataValid, for each packet coming in.
            -- bad_poly is tracked separately for each subarray-beam.
            -- The flag is stored in the bad_poly memory in the level above this module. 
            -- For the first packet in an 849ms frame, we clear the entire bad_poly memory.
            -- Thereafter, if a bad polynomial is found, then the bad_poly bit is set in the memory for 
            -- the corresponding subarray-beam. 
            bad_poly_del1 <= i_bad_poly;
            
            if sof_hold = '1' and dataValidDel1 = '1' and i_frameCount_mod3 = "00" and unsigned(virtualChannel0Del1) = 0 then
                -- first data in first 283ms frame (out of an 849ms frame) for the first virtual channel, clear the bad_poly memory
                bad_poly_fsm <= clear_memory;
                bad_poly_buffer <= i_frameCount_849ms(0); -- Which buffer we are writing to in the bad_poly memory
                bp_addr <= (others => '0');
                bp_wr_en <= (others => '0');
                bad_poly <= bad_poly_del1;
                bp_wr_data <= '0';
            else
                case bad_poly_fsm is
                    when clear_memory =>
                        bp_addr <= std_logic_vector(unsigned(bp_addr) + 1);
                        if unsigned(bp_addr) = 127 then
                            bad_poly_fsm <= check_bad0;
                            bp_wr_en <= (others => '0');
                        else
                            bp_wr_en <= (others => '1');
                        end if;
                    
                    when check_bad0 => -- Check if the polynomials were ok for the first group of 4 virtual channels being processed
                        if demap_valid(0) = '1' and bad_poly(0) = '1' then
                            bad_poly_fsm <= set_bad0;
                        else
                            bad_poly_fsm <= check_bad1;
                        end if;
                        bp_wr_en <= (others => '0');
                        
                    when set_bad0 =>  
                        bp_addr(6 downto 0) <= demap_SB_addr(0)(6 downto 0);
                        bp_wr_data <= '1';
                        case demap_SB_addr(0)(9 downto 7) is
                            when "000" => bp_wr_en <= "000001";
                            when "001" => bp_wr_en <= "000010";
                            when "010" => bp_wr_en <= "000100";
                            when "011" => bp_wr_en <= "001000";
                            when "100" => bp_wr_en <= "010000";
                            when "101" => bp_wr_en <= "100000";
                            when others => bp_wr_en <= (others => '0');
                        end case;
                        bad_poly_fsm <= check_bad1;
                   
                   when check_bad1 => -- Check if the polynomials were ok for the second group of 4 virtual channels being processed
                        if demap_valid(1) = '1' and bad_poly(1) = '1' then
                            bad_poly_fsm <= set_bad1;
                        else
                            bad_poly_fsm <= check_bad2;
                        end if;
                        bp_wr_en <= (others => '0');
                        
                    when set_bad1 =>
                        bp_addr(6 downto 0) <= demap_SB_addr(1)(6 downto 0);
                        bp_wr_data <= '1';
                        case demap_SB_addr(1)(9 downto 7) is
                            when "000" => bp_wr_en <= "000001";
                            when "001" => bp_wr_en <= "000010";
                            when "010" => bp_wr_en <= "000100";
                            when "011" => bp_wr_en <= "001000";
                            when "100" => bp_wr_en <= "010000";
                            when "101" => bp_wr_en <= "100000";
                            when others => bp_wr_en <= (others => '0');
                        end case;
                        bad_poly_fsm <= check_bad2;
                    
                    when check_bad2 => -- Check if the polynomials were ok for the third group of 4 virtual channels being processed
                        if demap_valid(2) = '1' and bad_poly(2) = '1' then
                            bad_poly_fsm <= set_bad2;
                        else
                            bad_poly_fsm <= idle;
                        end if;
                        bp_wr_en <= (others => '0');
                        
                    when set_bad2 =>
                        bp_addr(6 downto 0) <= demap_SB_addr(2)(6 downto 0);
                        bp_wr_data <= '1';
                        case demap_SB_addr(2)(9 downto 7) is
                            when "000" => bp_wr_en <= "000001";
                            when "001" => bp_wr_en <= "000010";
                            when "010" => bp_wr_en <= "000100";
                            when "011" => bp_wr_en <= "001000";
                            when "100" => bp_wr_en <= "010000";
                            when "101" => bp_wr_en <= "100000";
                            when others => bp_wr_en <= (others => '0');
                        end case;
                        bad_poly_fsm <= idle;
                    
                    when idle =>
                        if dataValidDel1 = '1' and dataValidDel2 = '0' then
                            bad_poly <= bad_poly_del1;
                            bad_poly_fsm <= wait_check_bad;
                        end if;
                        bad_poly_wait_count <= (others => '0');
                        bp_wr_data <= '0';
                        bp_wr_en <= (others => '0');
                    
                    when wait_check_bad =>
                        -- wait for a while so that reading of the demap table is complete
                        if unsigned(bad_poly_wait_count) > 127 then
                            bad_poly_fsm <= check_bad0;
                        else
                            bad_poly_wait_count <= std_logic_vector(unsigned(bad_poly_wait_count) + 1);
                        end if;
                        bp_wr_data <= '0';
                        bp_wr_en <= (others => '0');
                    
                    when others =>
                        bad_poly_fsm <= idle;
                end case;
            end if;
            
            ------------------------------------------------------------------------------
            
            if i_rst = '1' then
                timeStep <= (others => '0');
                trigger_demap_rd <= '0';
                sof_hold <= '0';
                lastTime <= '0';
            elsif i_sof = '1' then
                sof_hold <= '1';
                -- time step for the next packet from the filterbanks, counts 0 to 63
                -- (There are 64 time samples per first stage corner turn frame)
                timeStep <= (others => '0');
                trigger_demap_rd <= '0';
            elsif sof_hold = '1' and dataValidDel1 = '1' then
                sof_hold <= '0';
                -- Just use the first filterbanks virtual channel.
                -- This module assumes that i_virtualChannel(0), (1), (2), and (3) are consecutive values.
                virtualChannel <= virtualChannel0Del1;
                last_virtual_channel <= i_lastchannel;
                frameCount_mod3 <= i_frameCount_mod3;
                frameCount_849ms <= i_frameCount_849ms;
                trigger_demap_rd <= '1';
                lastTime <= '0';
            elsif dataValidDel1 = '0' and dataValidDel2 = '1' then
                -- falling edge of i_dataValid
                trigger_demap_rd <= '0';
                timeStep <= std_logic_vector(unsigned(timeStep) + 1);
                if timeStep = "111111" then  -- timestep runs 0 to 63 for each 283ms CT1 frame
                    lastTime <= '1';
                else
                    lastTime <= '0';
                end if;
            else
                trigger_demap_rd <= '0';
            end if;
            
            trigger_demap_rd_del1 <= trigger_demap_rd;
            trigger_demap_rd_del2 <= trigger_demap_rd_del1;
            
            sof_del1 <= i_sof;
            if trigger_demap_rd = '1' then
                o_vc_demap_rd_addr <= virtualChannel(11 downto 2);
                o_vc_demap_req <= "001";
            elsif trigger_demap_rd_del1 = '1' then -- Read demap table for the second group of 4 virtual channels
                o_vc_demap_rd_addr <= std_logic_vector(unsigned(virtualChannel(11 downto 2)) + 1);
                o_vc_demap_req <= "010";
            elsif trigger_demap_rd_del2 = '1' then -- Read demap table for the third group of 4 virtual channels
                o_vc_demap_rd_addr <= std_logic_vector(unsigned(virtualChannel(11 downto 2)) + 2);
                o_vc_demap_req <= "100";
            else
                o_vc_demap_req <= "000"; 
            end if;
            
            if i_demap_Data_valid(0) = '1' then
                demap_station(0) <= i_demap_station;   -- in (11:0); Station index within the subarray-beam.
                demap_skyFrequency(0) <= i_demap_skyFrequency; -- in (8:0); Sky frequency.
                demap_valid(0) <= i_demap_valid;       -- in std_logic; This entry in the demap table is valid.
                demap_SB_addr(0) <= i_demap_SB_index(9 downto 0); --  Index into the subarray-beam table.
            end if;
            if i_demap_Data_valid(1) = '1' then
                demap_station(1) <= i_demap_station;   -- in (11:0); Station index within the subarray-beam.
                demap_skyFrequency(1) <= i_demap_skyFrequency; -- in (8:0); Sky frequency.
                demap_valid(1) <= i_demap_valid;       -- in std_logic; This entry in the demap table is valid.
                demap_SB_addr(1) <= i_demap_SB_index(9 downto 0); --  Index into the subarray-beam table.
            end if;
            if i_demap_Data_valid(2) = '1' then
                demap_station(2) <= i_demap_station;   -- in (11:0); Station index within the subarray-beam.
                demap_skyFrequency(2) <= i_demap_skyFrequency; -- in (8:0); Sky frequency.
                demap_valid(2) <= i_demap_valid;       -- in std_logic; This entry in the demap table is valid.
                demap_SB_addr(2) <= i_demap_SB_index(9 downto 0); --  Index into the subarray-beam table.
            end if;
               
            if i_demap_Data_valid(0) = '1' then
                SB_req_fsm <= get_SB0;
            else
                case SB_req_fsm is
                    when get_SB0 =>
                        SB_req <= '1';
                        SB_req_fsm <= wait_SB0;
                        SB_addr <= demap_SB_addr(0);
                        
                    when wait_SB0 =>
                        if i_SB_valid = '1' then
                            SB_req <= '0';
                            SB_req_fsm <= get_SB1;
                            SB_stations(0) <= i_SB_stations;       -- in (15:0); The number of (sub)stations in this subarray-beam
                            SB_coarseStart(0) <= i_SB_coarseStart; -- in (15:0); The first coarse channel in this subarray-beam
                            SB_fineStart(0) <= i_SB_fineStart;     -- in (15:0); readout_buf1_fineStart, -- the first fine channel in this subarray-beam
                            SB_n_fine(0) <= i_SB_n_fine;           -- in (23:0); The number of fine channels in this subarray-beam
                            SB_HBM_base_addr(0) <= i_SB_HBM_base_addr;  -- in (31:0); Base address in HBM for this subarray-beam.
                            -- this value gets registered at some point just after getting the first 
                            time_block <= '0' & frameCount_mod3 & timeStep(5); -- blocks of 32 times;
                        end if;
                        
                    when get_SB1 =>
                        SB_req <= '1';
                        SB_req_fsm <= wait_SB1;
                        SB_addr <= demap_SB_addr(1);
                        
                    when wait_SB1 =>
                        if i_SB_valid = '1' then
                            SB_req <= '0';
                            SB_req_fsm <= get_SB2;
                            SB_stations(1) <= i_SB_stations;       -- in (15:0); The number of (sub)stations in this subarray-beam
                            SB_coarseStart(1) <= i_SB_coarseStart; -- in (15:0); The first coarse channel in this subarray-beam
                            SB_fineStart(1) <= i_SB_fineStart;     -- in (15:0); readout_buf1_fineStart, -- the first fine channel in this subarray-beam
                            SB_n_fine(1) <= i_SB_n_fine;           -- in (23:0); The number of fine channels in this subarray-beam
                            SB_HBM_base_addr(1) <= i_SB_HBM_base_addr;  -- in (31:0); Base address in HBM for this subarray-beam.
                        end if;
                        
                    when get_SB2 =>
                        SB_req <= '1';
                        SB_req_fsm <= wait_SB2;
                        SB_addr <= demap_SB_addr(2);
                        
                    when wait_SB2 =>
                        if i_SB_valid = '1' then
                            SB_req <= '0';
                            SB_req_fsm <= done;
                            SB_stations(2) <= i_SB_stations;       -- in (15:0); The number of (sub)stations in this subarray-beam
                            SB_coarseStart(2) <= i_SB_coarseStart; -- in (15:0); The first coarse channel in this subarray-beam
                            SB_fineStart(2) <= i_SB_fineStart;     -- in (15:0); readout_buf1_fineStart, -- the first fine channel in this subarray-beam
                            SB_n_fine(2) <= i_SB_n_fine;           -- in (23:0); The number of fine channels in this subarray-beam
                            SB_HBM_base_addr(2) <= i_SB_HBM_base_addr;  -- in (31:0); Base address in HBM for this subarray-beam.
                        end if;
                        
                    when done =>
                        SB_req <= '0';
                        SB_req_fsm <= done;
                        
                    when others => 
                        SB_req_fsm <= done;
                        
                end case;
            end if;
            
            bufWrData(0)(15 downto 0) <= i_data(0).Hpol.im & i_data(0).Hpol.re;
            bufWrData(0)(31 downto 16) <= i_data(0).Vpol.im & i_data(0).Vpol.re;
            bufWrData(0)(47 downto 32) <= i_data(1).Hpol.im & i_data(1).Hpol.re;
            bufWrData(0)(63 downto 48) <= i_data(1).Vpol.im & i_data(1).Vpol.re;
            bufWrData(0)(79 downto 64) <= i_data(2).Hpol.im & i_data(2).Hpol.re;
            bufWrData(0)(95 downto 80) <= i_data(2).Vpol.im & i_data(2).Vpol.re;
            bufWrData(0)(111 downto 96) <= i_data(3).Hpol.im & i_data(3).Hpol.re;
            bufWrData(0)(127 downto 112) <= i_data(3).Vpol.im & i_data(3).Vpol.re;
            
            bufWrData(1)(15 downto 0) <= i_data(4).Hpol.im & i_data(4).Hpol.re;
            bufWrData(1)(31 downto 16) <= i_data(4).Vpol.im & i_data(4).Vpol.re;
            bufWrData(1)(47 downto 32) <= i_data(5).Hpol.im & i_data(5).Hpol.re;
            bufWrData(1)(63 downto 48) <= i_data(5).Vpol.im & i_data(5).Vpol.re;
            bufWrData(1)(79 downto 64) <= i_data(6).Hpol.im & i_data(6).Hpol.re;
            bufWrData(1)(95 downto 80) <= i_data(6).Vpol.im & i_data(6).Vpol.re;
            bufWrData(1)(111 downto 96) <= i_data(7).Hpol.im & i_data(7).Hpol.re;
            bufWrData(1)(127 downto 112) <= i_data(7).Vpol.im & i_data(7).Vpol.re;
            
            bufWrData(2)(15 downto 0) <= i_data(8).Hpol.im & i_data(8).Hpol.re;
            bufWrData(2)(31 downto 16) <= i_data(8).Vpol.im & i_data(8).Vpol.re;
            bufWrData(2)(47 downto 32) <= i_data(9).Hpol.im & i_data(9).Hpol.re;
            bufWrData(2)(63 downto 48) <= i_data(9).Vpol.im & i_data(9).Vpol.re;
            bufWrData(2)(79 downto 64) <= i_data(10).Hpol.im & i_data(10).Hpol.re;
            bufWrData(2)(95 downto 80) <= i_data(10).Vpol.im & i_data(10).Vpol.re;
            bufWrData(2)(111 downto 96) <= i_data(11).Hpol.im & i_data(11).Hpol.re;
            bufWrData(2)(127 downto 112) <= i_data(11).Vpol.im & i_data(11).Vpol.re;
            
            
            -- write enable is indexed by (6*i + 2*j + k) where
            --   k = 0-1 = even and odd time samples
            --   j = 0-2 = group of virtual channels (0-3, 4-7, 8-11)
            --   i = 0-1 = even and odd indexed fine channels
            -- 
            --      | WrEn="000000000001" | WrEn="000000000010" | WrEn="000000000100" | WrEn="000000001000" | WrEn="000000010000"  | WrEn="000000100000"  |   <-- Write enable vector for the memory blocks (for even indexed channels)
            --      |128 bits = 4 channels|
            --      |  * 2 pol * 2 complex|
            -- Addr |---------------------|---------------------|---------------------|---------------------|----------------------|----------------------|
            --      |          ...        |          ...        |          ...        |          ...        |          ...         |          ...         |
            --      |---------------------|---------------------|---------------------|---------------------|----------------------|----------------------|  ----
            --  7   | fine=0,t=14,chan0-3 | fine=0,t=15,chan0-3 | fine=0,t=14,chan4-7 | fine=0,t=15,chan4-7 | fine=0,t=14,chan8-11 | fine=0,t=15,chan8-11 |
            --  6   | fine=0,t=12,chan0-3 | fine=0,t=13,chan0-3 | fine=0,t=12,chan4-7 | fine=0,t=13,chan4-7 | fine=0,t=12,chan8-11 | fine=0,t=13,chan8-11 |
            --  5   | fine=0,t=10,chan0-3 | fine=0,t=11,chan0-3 | fine=0,t=10,chan4-7 | fine=0,t=11,chan4-7 | fine=0,t=10,chan8-11 | fine=0,t=11,chan8-11 |
            --  4   | fine=0,t=8,chan0-3  | fine=0,t=9,chan0-3  | fine=0,t=8,chan4-7  | fine=0,t=9,chan4-7  | fine=0,t=8,chan8-11  | fine=0,t=9,chan8-11  | HBM packets for fine channel 0 
            --  3   | fine=0,t=6,chan0-3  | fine=0,t=7,chan0-3  | fine=0,t=6,chan4-7  | fine=0,t=7,chan4-7  | fine=0,t=6,chan8-11  | fine=0,t=7,chan8-11  |
            --  2   | fine=0,t=4,chan0-3  | fine=0,t=5,chan0-3  | fine=0,t=4,chan4-7  | fine=0,t=5,chan4-7  | fine=0,t=4,chan8-11  | fine=0,t=5,chan8-11  |
            --  1   | fine=0,t=2,chan0-3  | fine=0,t=3,chan0-3  | fine=0,t=2,chan4-7  | fine=0,t=3,chan4-7  | fine=0,t=2,chan8-11  | fine=0,t=3,chan8-11  |
            --  0   | fine=0,t=0,chan0-3  | fine=0,t=1,chan0-3  | fine=0,t=0,chan4-7  | fine=0,t=1,chan4-7  | fine=0,t=0,chan8-11  | fine=0,t=1,chan8-11  |
            --      |---------------------|---------------------|---------------------|---------------------|----------------------|----------------------|
            --          bufDout(0)              bufDout(1)           bufDout(2)             bufDout(3)              bufDout(4)            bufDout(5)          and bufDout(6 to 11) for odd-indexed fine channels
            --
            -- pipeline : i_dataValid -> dataValidDel1 ->
            --                           fineChannel   -> fineChannel_del1
            --                                            bufWrDataFinal -> bufWrDataFinal_del1
            --                                            bufWEFinal     -> bufWEFinal_del1
            if i_dataValid = '1' then
                if (fineChannel(0) = '0' and timeStep(0) = '0') then
                    bufWEFinal <= "000000010101";
                elsif (fineChannel(0) = '0' and timeStep(0) = '1') then
                    bufWEFinal <= "000000101010";
                elsif (fineChannel(0) = '1' and timeStep(0) = '0') then
                    bufWEFinal <= "010101000000";
                else  -- (fineChannel(0) = '1' and timeStep(0) = '1') then
                    bufWEFinal <= "101010000000";
                end if;
            else
                bufWEFinal <= "000000000000";
            end if;
            
            dataValidDel1 <= i_dataValid;
            if i_dataValid = '1' then
                if dataValidDel1 = '0' then
                    fineChannel <= (others => '0');  -- fineChannel aligns with the data in bufWrData
                else
                    fineChannel <= std_logic_vector(unsigned(fineChannel) + 1);
                end if;
            end if;
            fineChannel_del1 <= fineChannel;
            
            bufWrDataFinal <= bufWrData;
            if (timeStep(4) = '0') then
                -- 64 time samples per corner turn; 1st and 3rd group of 16 times go to the first half of the memory.
                bufWrAddrFinal <= bufWrAddr;
            else
                -- 2nd and 4th group of 16 times go to the second half of the memory,
                -- which starts at 3.5*4096 = 14336
                -- There is an unused gap between the two halves of the buffers, since each half only uses 8*1728 = 13824 entries
                bufWrAddrFinal <= std_logic_vector(unsigned(bufWrAddr) + 14336);
            end if;
            
            -----------------------------------------
            -- Insert debug data if requested
            bufWEFinal_del1 <= bufWEFinal;
            bufWrAddrFinal_del1 <= bufWrAddrFinal;
            insert_dbg <= i_insert_dbg;
            if (insert_dbg = '1') then
                bufWrDataFinal_del1(0)(9 downto 0) <= virtualChannel(9 downto 0);
                bufWrDataFinal_del1(0)(21 downto 10) <= fineChannel_del1(11 downto 0);
                bufWrDataFinal_del1(0)(27 downto 22) <= timeStep(5 downto 0);
                bufWrDataFinal_del1(0)(29 downto 28) <= frameCount_mod3(1 downto 0);
                bufWrDataFinal_del1(0)(31 downto 30) <= frameCount_849ms(1 downto 0);
                --
                bufWrDataFinal_del1(0)(32+11 downto 32+0) <= std_logic_vector(unsigned(virtualChannel(11 downto 0)) + 1);
                bufWrDataFinal_del1(0)(32+21 downto 32+12) <= fineChannel_del1(9 downto 0);
                bufWrDataFinal_del1(0)(32+27 downto 32+22) <= timeStep(5 downto 0);
                bufWrDataFinal_del1(0)(32+29 downto 32+28) <= frameCount_mod3(1 downto 0);
                bufWrDataFinal_del1(0)(32+31 downto 32+30) <= frameCount_849ms(1 downto 0);
                --
                bufWrDataFinal_del1(0)(64+11 downto 64+0) <= std_logic_vector(unsigned(virtualChannel(11 downto 0)) + 2);
                bufWrDataFinal_del1(0)(64+21 downto 64+12) <= fineChannel_del1(9 downto 0);
                bufWrDataFinal_del1(0)(64+27 downto 64+22) <= timeStep(5 downto 0);
                bufWrDataFinal_del1(0)(64+29 downto 64+28) <= frameCount_mod3(1 downto 0);
                bufWrDataFinal_del1(0)(64+31 downto 64+30) <= frameCount_849ms(1 downto 0);
                --
                bufWrDataFinal_del1(0)(96+11 downto 96+0) <= std_logic_vector(unsigned(virtualChannel(11 downto 0)) + 3);
                bufWrDataFinal_del1(0)(96+21 downto 96+12) <= fineChannel_del1(9 downto 0);
                bufWrDataFinal_del1(0)(96+27 downto 96+22) <= timeStep(5 downto 0);
                bufWrDataFinal_del1(0)(96+29 downto 96+28) <= frameCount_mod3(1 downto 0);
                bufWrDataFinal_del1(0)(96+31 downto 96+30) <= frameCount_849ms(1 downto 0);
                
                bufWrDataFinal_del1(1)(9 downto 0) <= std_logic_vector(unsigned(virtualChannel(9 downto 0)) + 4);
                bufWrDataFinal_del1(1)(21 downto 10) <= fineChannel_del1(11 downto 0);
                bufWrDataFinal_del1(1)(27 downto 22) <= timeStep(5 downto 0);
                bufWrDataFinal_del1(1)(29 downto 28) <= frameCount_mod3(1 downto 0);
                bufWrDataFinal_del1(1)(31 downto 30) <= frameCount_849ms(1 downto 0);
                --
                bufWrDataFinal_del1(1)(32+11 downto 32+0) <= std_logic_vector(unsigned(virtualChannel(11 downto 0)) + 5);
                bufWrDataFinal_del1(1)(32+21 downto 32+12) <= fineChannel_del1(9 downto 0);
                bufWrDataFinal_del1(1)(32+27 downto 32+22) <= timeStep(5 downto 0);
                bufWrDataFinal_del1(1)(32+29 downto 32+28) <= frameCount_mod3(1 downto 0);
                bufWrDataFinal_del1(1)(32+31 downto 32+30) <= frameCount_849ms(1 downto 0);
                --
                bufWrDataFinal_del1(1)(64+11 downto 64+0) <= std_logic_vector(unsigned(virtualChannel(11 downto 0)) + 6);
                bufWrDataFinal_del1(1)(64+21 downto 64+12) <= fineChannel_del1(9 downto 0);
                bufWrDataFinal_del1(1)(64+27 downto 64+22) <= timeStep(5 downto 0);
                bufWrDataFinal_del1(1)(64+29 downto 64+28) <= frameCount_mod3(1 downto 0);
                bufWrDataFinal_del1(1)(64+31 downto 64+30) <= frameCount_849ms(1 downto 0);
                --
                bufWrDataFinal_del1(1)(96+11 downto 96+0) <= std_logic_vector(unsigned(virtualChannel(11 downto 0)) + 7);
                bufWrDataFinal_del1(1)(96+21 downto 96+12) <= fineChannel_del1(9 downto 0);
                bufWrDataFinal_del1(1)(96+27 downto 96+22) <= timeStep(5 downto 0);
                bufWrDataFinal_del1(1)(96+29 downto 96+28) <= frameCount_mod3(1 downto 0);
                bufWrDataFinal_del1(1)(96+31 downto 96+30) <= frameCount_849ms(1 downto 0);
                
                bufWrDataFinal_del1(2)(9 downto 0) <= std_logic_vector(unsigned(virtualChannel(9 downto 0)) + 8);
                bufWrDataFinal_del1(2)(21 downto 10) <= fineChannel_del1(11 downto 0);
                bufWrDataFinal_del1(2)(27 downto 22) <= timeStep(5 downto 0);
                bufWrDataFinal_del1(2)(29 downto 28) <= frameCount_mod3(1 downto 0);
                bufWrDataFinal_del1(2)(31 downto 30) <= frameCount_849ms(1 downto 0);
                --
                bufWrDataFinal_del1(2)(32+11 downto 32+0) <= std_logic_vector(unsigned(virtualChannel(11 downto 0)) + 9);
                bufWrDataFinal_del1(2)(32+21 downto 32+12) <= fineChannel_del1(9 downto 0);
                bufWrDataFinal_del1(2)(32+27 downto 32+22) <= timeStep(5 downto 0);
                bufWrDataFinal_del1(2)(32+29 downto 32+28) <= frameCount_mod3(1 downto 0);
                bufWrDataFinal_del1(2)(32+31 downto 32+30) <= frameCount_849ms(1 downto 0);
                --
                bufWrDataFinal_del1(2)(64+11 downto 64+0) <= std_logic_vector(unsigned(virtualChannel(11 downto 0)) + 10);
                bufWrDataFinal_del1(2)(64+21 downto 64+12) <= fineChannel_del1(9 downto 0);
                bufWrDataFinal_del1(2)(64+27 downto 64+22) <= timeStep(5 downto 0);
                bufWrDataFinal_del1(2)(64+29 downto 64+28) <= frameCount_mod3(1 downto 0);
                bufWrDataFinal_del1(2)(64+31 downto 64+30) <= frameCount_849ms(1 downto 0);
                --
                bufWrDataFinal_del1(2)(96+11 downto 96+0) <= std_logic_vector(unsigned(virtualChannel(11 downto 0)) + 11);
                bufWrDataFinal_del1(2)(96+21 downto 96+12) <= fineChannel_del1(9 downto 0);
                bufWrDataFinal_del1(2)(96+27 downto 96+22) <= timeStep(5 downto 0);
                bufWrDataFinal_del1(2)(96+29 downto 96+28) <= frameCount_mod3(1 downto 0);
                bufWrDataFinal_del1(2)(96+31 downto 96+30) <= frameCount_849ms(1 downto 0);
            else
                bufWrDataFinal_del1 <= bufWrDataFinal;
            end if;
            
            ------------------------------------------
            -- Trigger copying of data to the HBM.
            --  This occurs once we have buffered up 16 time samples, for 12 virtual channels, for all 3456 fine channels.
            --  So we have (3 [groups of 4 virtual channels]) x (3456 fine channels) x 256 bytes to send to the HBM.
            
            if i_dataValid = '0' and dataValidDel1 = '1' and timeStep(3 downto 0) = "1111" then
                copyToHBM <= demap_valid;
                copyToHBM_buffer <= frameCount_849ms(0); -- every 849 ms, alternate halfs within each 3 Gbyte HBM buffer.
                recent_frameCount <= frameCount_849ms;
                -- Parameters for this block of data :
                copyToHBM_time(1 downto 0) <= timeStep(5 downto 4); -- which of the 4 groups of 16 time samples out of the 64 time samples per first corner turn frame.
                copyToHBM_time(3 downto 2) <= frameCount_mod3;
                copyToHBM_station <= demap_station;
                copyToHBM_skyFrequency <= demap_skyFrequency;
                -- Parameters for this subarray-beam.
                copyToHBM_SB_stations <= SB_stations;
                copyToHBM_SB_coarseStart <= SB_coarseStart;
                copyToHBM_SB_fineStart <= SB_fineStart;
                copyToHBM_SB_n_fine <= SB_n_fine;
                -- The base address from the subarray-beam table is a 32-bit value in units of 4-bytes
                -- Convert to byte address, 36-bits wide.
                copyToHBM_SB_HBM_base_addr(0) <= "00" & SB_HBM_base_addr(0) & "00";
                copyToHBM_SB_HBM_base_addr(1) <= "00" & SB_HBM_base_addr(1) & "00";
                copyToHBM_SB_HBM_base_addr(2) <= "00" & SB_HBM_base_addr(2) & "00";
                -- copyToHBM_SB_HBM_sel is not needed with unified memory model; just controlled by the memory address that we write to.
                --copyToHBM_SB_HBM_sel <= SB_addr(7); -- The top bit of the subarray-beam address selects which correlator instance the data is for.
                if (timeStep(5 downto 4) = "11" and frameCount_mod3 = "10" and last_virtual_channel = '1') then
                    -- trigger readout to the correlators once this data is written to the HBM
                    copyToHBM_trigger_readout <= '1';
                else
                    copyToHBM_trigger_readout <= '0';
                end if;
            else
                copyToHBM <= "000";
            end if;
            
            if copyToHBM /= "000" then
                copyToHBM_count <= std_logic_vector(unsigned(copyToHBM_count) + 1);
            end if;
            if trigger_copyData_fsm = '1' then
                copydata_count <= std_logic_vector(unsigned(copydata_count) + 1);
            end if;
            
            if copyToHBM /= "000" then
                copy_fsm_dbg_at_start <= copy_fsm_dbg;
            end if;
            
        end if;
    end process;
    
    bufWrAddr(14) <= '0'; -- This is the address within the first half of the buffer. The next pipeline stage puts it in the second buffer if needed.
    bufWrAddr(13 downto 3) <= fineChannel(11 downto 1);
    bufWrAddr(2 downto 0) <= timeStep(3 downto 1);
    
    -- ultraRAM buffer
    buf_even_odd_fine_gen : for i in 0 to 1 generate
        -- One buffer for even indexed and one for odd indexed fine channels
        buf_vchan_gen : for j in 0 to 2 generate
            -- 3 instances, one for each of the incoming virtual channels 0-3, 4-7 and 8-11
            buf_even_odd_time_gen : for k in 0 to 1 generate
                ct2_input_bufi : xpm_memory_sdpram
                generic map (    
                    -- Common module generics
                    MEMORY_SIZE             => 3670016,        -- Total memory size in bits; 14 ultraRAMs, 14 x 4096 x 64 = 7 x 4096 x 128 = 28672 * 128 = 3670016
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
                    ADDR_WIDTH_A            => 15,             -- positive integer; 7 ultraRAMs deep x 2 wide = (28672 addresses) x (128 bits)
                
                    -- Port B module generics
                    READ_DATA_WIDTH_B       => 128,            -- positive integer
                    ADDR_WIDTH_B            => 15,             -- positive integer
                    READ_RESET_VALUE_B      => "0",            -- string
                    READ_LATENCY_B          => 8,              -- non-negative integer; Need one clock for every cascaded ultraRAM.
                    WRITE_MODE_B            => "read_first")   -- string; "write_first", "read_first", "no_change" 
                port map (
                    -- Common module ports
                    sleep                   => '0',
                    -- Port A (Write side)
                    clka                    => i_axi_clk,  -- Filterbank clock, 300 MHz
                    ena                     => '1',
                    wea                     => bufWE_slv(6*i + 2*j + k),
                    addra                   => bufWrAddrFinal_del1,
                    dina                    => bufWrDataFinal_del1(j),
                    injectsbiterra          => '0',
                    injectdbiterra          => '0',
                    -- Port B (read side)
                    clkb                    => i_axi_clk,  -- HBM interface side, also 300 MHz.
                    rstb                    => '0',
                    enb                     => '1',
                    regceb                  => '1',
                    addrb                   => bufRdAddr(i),
                    doutb                   => bufDout(6*i + 2*j + k),
                    sbiterrb                => open,
                    dbiterrb                => open
                );
                bufWE_slv(6*i + 2*j + k)(0) <= bufWEFinal_del1(6*i + 2*j + k);
            
            end generate;
        end generate;
    end generate;
    
    bufDout_even_0_3  <= bufDout(1) & bufDout(0);
    bufDout_even_4_7  <= bufDout(3) & bufDout(2);
    bufDout_even_8_11 <= bufDout(5) & bufDout(4);
    
    bufDout_odd_0_3  <= bufDout(7) & bufDout(6);
    bufDout_odd_4_7  <= bufDout(9) & bufDout(8);
    bufDout_odd_8_11 <= bufDout(11) & bufDout(10);
    
    
    -----------------------------------------------------------------------------------------------
    -- At completion of 16 time samples, copy data from the ultraRAM buffer to the HBM
    
    uram_readout_fine_even_i : entity ct_lib.corr_ct2_din2HBM_v80
    generic map (
        g_DEBUG_ILA => False, -- BOOLEAN := FALSE;
        g_ODD_FINE => '0'     -- std_logic := '0';  This module works through half the fine channels (3456/2 = 1728). Set this to 1 to process odd-indexed fine channels, or 0 for the even-indexed fine channels
    ) port map (
        i_rst     => i_rst,     -- in std_logic;
        i_axi_clk => i_axi_clk, -- in std_logic;
        --------------------------------------------------------------------
        -- Instructions in to copy data to HBM
        -- one bit for each group of 4 virtual channels. 
        -- Goes high for a single clock cycle. e.g. if all three groups of virtual channels are available, this will go to "111" for one clock
        i_copyToHBM => copyToHBM, -- in (2:0);
        -- Which half of the HBM to write to. Switches every 849ms. 
        i_copyToHBM_buffer => copyToHBM_buffer, -- in std_logic;
        -- which group of 16 time samples we are up to. In total there are 12 groups of 16 times samples, for 12*16 = 192 time samples per 849ms frame
        i_copyToHBM_time   => copyToHBM_time,   -- in (3:0);
        -- index of the station within the subarray, for each of the 3 groups of 4 stations
        i_copyToHBM_station => copyToHBM_station, -- in t_slv_12_arr(2 downto 0);
        -- frequency channel for each of the 3 groups of station. 0 to 511, in units of 781.25 KHz
        i_copyToHBM_skyFrequency => copyToHBM_skyFrequency, --  in t_slv_9_arr(2 downto 0);
        --
        i_copyToHBM_SB_stations => copyToHBM_SB_stations,       -- in t_slv_16_arr(2 downto 0);
        i_copyToHBM_SB_coarseStart => copyToHBM_SB_coarseStart, -- in t_slv_16_arr(2 downto 0);
        i_copyToHBM_SB_fineStart   => copyToHBM_SB_fineStart,   -- in t_slv_16_arr(2 downto 0);
        i_copyToHBM_SB_n_fine      => copyToHBM_SB_n_fine,      -- in t_slv_24_arr(2 downto 0);
        i_copyToHBM_SB_HBM_base_addr => copyToHBM_SB_HBM_base_addr, -- in t_slv_36_arr(2 downto 0);
        -- trigger readout to the correlators once this data is written to the HBM
        i_copyToHBM_trigger_readout => copyToHBM_trigger_readout,  -- in std_logic;
        -- Indicate readout is complete
        o_copyToHBM_done => copyToHBM_done_even, --  out std_logic;
        -------------------------------------------------------------------
        -- Read from the ultraRAM buffer
        o_uram_rd_addr => bufRdAddr(0),     -- out (14:0);
        -- 3 x 256 bit wide buses, for groups of stations 0-3, 4-7, 8-11
        -- 8 clock read latency from o_uram_rd_addr to i_uram_rd_dataX_X
        i_uram_rd_data0_3  => bufDout_even_0_3,  -- in (255:0);
        i_uram_rd_data4_7  => bufDout_even_4_7,  -- in (255:0);
        i_uram_rd_data8_11 => bufDout_even_8_11, -- in (255:0);
        -------------------------------------------------------------------
        -- Status
        o_status1  => o_status1, -- out (31:0);  -- fifo counts and fsm states
        o_max_copyData_time => o_max_copyData_time,        -- out (31:0); Time required to put out all the data
        o_min_trigger_interval => o_min_trigger_interval,  -- out (31:0); Minimum time available
        o_wr_overflow => o_wr_overflow,                    -- out (31:0); overflow + debug info when the overflow occurred.
        -------------------------------------------------------------------
        -- AXI interface to the HBM
        -- Corner turn between filterbanks and correlator
        o_HBM_axi_aw      => o_HBM_axi_aw(0), --  out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_awready => i_HBM_axi_awready(0), -- in  std_logic;
        o_HBM_axi_w       => o_HBM_axi_w(0),       -- out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_HBM_axi_wready  => i_HBM_axi_wready(0),  -- in  std_logic;
        i_HBM_axi_b       => i_HBM_axi_b(0)        -- in  t_axi4_full_b     -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
    );
    
    uram_readout_fine_odd_i : entity ct_lib.corr_ct2_din2HBM_v80
    generic map (
        g_DEBUG_ILA => False, -- BOOLEAN := FALSE;
        g_ODD_FINE => '1'     -- std_logic := '0';  -- This module works through half the fine channels (3456/2 = 1728). Set this to 1 to process odd-indexed fine channels, or 0 for the even-indexed fine channels
    ) port map (
        i_rst     => i_rst,     -- in std_logic;
        i_axi_clk => i_axi_clk, -- in std_logic;
        --------------------------------------------------------------------
        -- Instructions in to copy data to HBM
        -- one bit for each group of 4 virtual channels. 
        -- Goes high for a single clock cycle. e.g. if all three groups of virtual channels are available, this will go to "111" for one clock
        i_copyToHBM => copyToHBM, -- in (2:0);
        -- Which half of the HBM to write to. Switches every 849ms. 
        i_copyToHBM_buffer => copyToHBM_buffer, -- in std_logic;
        -- which group of 16 time samples we are up to. In total there are 12 groups of 16 times samples, for 12*16 = 192 time samples per 849ms frame
        i_copyToHBM_time   => copyToHBM_time,   -- in (3:0);
        -- index of the station within the subarray, for each of the 3 groups of 4 stations
        i_copyToHBM_station => copyToHBM_station, -- in t_slv_12_arr(2 downto 0);
        -- frequency channel for each of the 3 groups of station. 0 to 511, in units of 781.25 KHz
        i_copyToHBM_skyFrequency => copyToHBM_skyFrequency, --  in t_slv_9_arr(2 downto 0);
        --
        i_copyToHBM_SB_stations => copyToHBM_SB_stations,       -- in t_slv_16_arr(2 downto 0);
        i_copyToHBM_SB_coarseStart => copyToHBM_SB_coarseStart, -- in t_slv_16_arr(2 downto 0);
        i_copyToHBM_SB_fineStart   => copyToHBM_SB_fineStart,   -- in t_slv_16_arr(2 downto 0);
        i_copyToHBM_SB_n_fine      => copyToHBM_SB_n_fine,      -- in t_slv_24_arr(2 downto 0);
        i_copyToHBM_SB_HBM_base_addr => copyToHBM_SB_HBM_base_addr, -- in t_slv_36_arr(2 downto 0);
        -- trigger readout to the correlators once this data is written to the HBM
        i_copyToHBM_trigger_readout => copyToHBM_trigger_readout,  -- in std_logic;
        -- Indicate readout is complete
        o_copyToHBM_done => copyToHBM_done_odd, --  out std_logic;
        -------------------------------------------------------------------
        -- Read from the ultraRAM buffer
        o_uram_rd_addr => bufRdAddr(1),     -- out (14:0);
        -- 3 x 256 bit wide buses, for groups of stations 0-3, 4-7, 8-11
        -- 8 clock read latency from o_uram_rd_addr to i_uram_rd_dataX_X
        i_uram_rd_data0_3  => bufDout_odd_0_3,  -- in (255:0);
        i_uram_rd_data4_7  => bufDout_odd_4_7,  -- in (255:0);
        i_uram_rd_data8_11 => bufDout_odd_8_11, -- in (255:0);
        -------------------------------------------------------------------
        -- Status
        o_status1           => o_status2, -- out (31:0); fifo counts and fsm states
        o_max_copyData_time => open,      -- out (31:0); Time required to put out all the data
        o_min_trigger_interval => open,   -- out (31:0); Minimum time available
        o_wr_overflow => open,            -- out (31:0); overflow + debug info when the overflow occurred.
        -------------------------------------------------------------------
        -- AXI interface to the HBM
        -- Corner turn between filterbanks and correlator
        o_HBM_axi_aw      => o_HBM_axi_aw(1),      -- out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_HBM_axi_awready => i_HBM_axi_awready(1), -- in  std_logic;
        o_HBM_axi_w       => o_HBM_axi_w(1),       -- out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_HBM_axi_wready  => i_HBM_axi_wready(1),  -- in  std_logic;
        i_HBM_axi_b       => i_HBM_axi_b(1)        -- in  t_axi4_full_b     -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
    );
    
    
    -- Trigger the readout of 849ms of data to the correlator cores
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            if (copyToHBM_done_odd = '1') then
                trigger_readout <= '1';
                trigger_frameCount <= recent_frameCount;
                if dataFIFO_rden(0) = '1' then
                    trigger_buffer <= dataFIFO_dout(0)(514);
                else
                    trigger_buffer <= dataFIFO_dout(1)(514);
                end if;
            else
                trigger_readout <= '0';
            end if;
        end if;
    end process;
    
    o_trigger_readout <= trigger_readout;
    o_trigger_buffer <= trigger_buffer;
    o_trigger_frameCount <= trigger_frameCount;
    
    
--    generate_debug_ila : IF g_DEBUG_ILA GENERATE
--        ct2_ila : ila_0
--        port map (
--            clk => i_axi_clk,
--            probe0(15 downto 0) => copyToHBM_count,
--            probe0(19 downto 16) => copy_fsm_dbg,
--            probe0(23 downto 20) => copyData_fsm_dbg,
--            probe0(29 downto 24) => dataFIFO_dataCount(0),
--            probe0(30) => first_aw,
--            probe0(31) => copy_fsm_stuck,
--            probe0(47 downto 32) => copydata_count,
--            probe0(59 downto 48) => copy_finechannel(11 downto 0),
--            probe0(60) => get_addr,
--            probe0(61) => HBM_addr_valid,
--            probe0(62) => HBM_addr_bad,
--            probe0(63) => HBM_fine_high,
--            probe0(95 downto 64) => HBM_addr,
--            probe0(96) => dataFIFO_valid(0),
--            probe0(97) => dataFIFO_valid(1),
--            probe0(100 downto 98) => dataFIFO_dout(0)(514 downto 512),
--            probe0(103 downto 101) => dataFIFO_dout(1)(514 downto 512),
--            probe0(104) => HBM_axi_aw(0).valid,
--            probe0(105) => HBM_axi_aw(1).valid,
--            probe0(137 downto 106) => HBM_axi_aw(0).addr(31 downto 0),
--            probe0(138) => i_HBM_axi_awready(0),
--            probe0(139) => i_HBM_axi_awready(1),
--            probe0(140) => last_virtual_channel,
--            probe0(141) => copyToHBM_trigger_readout,
--            probe0(149 downto 142) => i_virtualChannel(0)(7 downto 0),
--            probe0(157 downto 150) => i_virtualChannel(1)(7 downto 0),
--            probe0(165 downto 158) => i_virtualChannel(2)(7 downto 0),
--            probe0(167 downto 166) => i_frameCount_mod3,
--            probe0(171 downto 168) => i_HeaderValid,
--            probe0(172) => i_lastChannel,
--            probe0(176 downto 173) => i_frameCount_849ms(3 downto 0),
--            probe0(191 downto 177) => (others => '0') 
--        );
        
--        ct2_pt2_ila : ila_0
--        port map (
--            clk => i_axi_clk,
--            probe0(15 downto 0) => copyToHBM_count,
--            probe0(19 downto 16) => copy_fsm_dbg,
--            probe0(23 downto 20) => copyData_fsm_dbg,
--            probe0(29 downto 24) => dataFIFO_dataCount(0),

--            probe0(45 downto 30) => last_word_in_frame,
--            probe0(57 downto 46) => copyData_fineRemaining,
--            probe0(58) => copyData_trigger,

--            probe0(61 downto 59) => bufRdCount,

--            probe0(62) => trigger_copyData_fsm,
--            probe0(68 downto 63) => dataFIFO_dataCount(1),
--            probe0(70 downto 69) => dataFIFO_wrEn,
            
--            probe0(71) => wait_HBMX_aw_rdy_stuck,
--            probe0(72) => copy_trigger,
--            probe0(73) => copyToHBM,

--            probe0(74) => i_HBM_axi_b(0).valid,
--            probe0(75) => i_HBM_axi_b(1).valid,

--            probe0(77 downto 76) => i_HBM_axi_b(0).resp,
--            probe0(79 downto 78) => i_HBM_axi_b(1).resp,

--            probe0(81 downto 80) => i_HBM_axi_wready,

--            probe0(87 downto 82) => fifo_size_plus_pending,
--            probe0(88) => copy_SB_HBM_sel,

--            probe0(95 downto 89) => ( others => '0' ),

--            probe0(96) => dataFIFO_valid(0),
--            probe0(97) => dataFIFO_valid(1),
--            probe0(100 downto 98) => dataFIFO_dout(0)(514 downto 512),
--            probe0(103 downto 101) => dataFIFO_dout(1)(514 downto 512),
--            probe0(104) => HBM_axi_aw(0).valid,
--            probe0(105) => HBM_axi_aw(1).valid,
--            probe0(137 downto 106) => HBM_axi_aw(0).addr(31 downto 0),
--            probe0(138) => i_HBM_axi_awready(0),
--            probe0(139) => i_HBM_axi_awready(1),
--            probe0(140) => last_virtual_channel,
--            probe0(141) => copyToHBM_trigger_readout,

--            probe0(157 downto 142) => dataFIFO0_wrEn,
--            probe0(173 downto 158) => dataFIFO1_wrEn,
--            probe0(183 downto 174) => i_virtualChannel(2)(9 downto 0),
--            probe0(191 downto 184) => i_virtualChannel(3)(7 downto 0)
--        );
--    END GENERATE;    
    
end Behavioral;
