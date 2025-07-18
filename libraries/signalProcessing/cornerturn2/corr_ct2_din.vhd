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
-- Data from the filterbank comes in 3456 clock long packets, with 3456 fine channels.
-- Data comes in bursts of 64 packets, for 64 consecutive time samples for a single set of 4 virtual channels.
-- On receiving the first packet in a burst, we look up the virtual channel in the "vc_demap" table.
-- This tells us :
--   First 32-bit word : Info about which subarray-beam this is used for. 
--          * i_demap_SB_index     = 8-bit subarray-beam id, used to look up the correct entry in the subarray-beam table
--          * i_demap_station      = 12-bit station within this subarray-beam; this is the index of the station as used by the correlator
--          * i_demap_skyFrequency = 9-bit sky frequency
--          * i_demap_valid        = 1-bit valid; if this bit is not set, then these virtual channels will be dropped.
--   Second 32-bit word : Info about which fine channel data to send out on the 100GE link.
--   
-- Once we have the subarray-beam from the vc_demap table, we look it up in the subarray-beam (SB) table, which give us :
--     * i_SB_stations      : The number of (sub)stations in this subarray-beam.
--     * i_SB_coarseStart   : The first coarse channel in this subarray-beam in this Alveo
--     * i_SB_fineStart     : The index of the first fine channel
--     * i_SB_N_fine        : The number of fine channels to use for this subarray-beam (starting from i_SB_coarseStart, i_SB_fineStart)
--     * i_SB_HBM_base_Addr : The base address in HBM to write this data to; somewhere in a 1.5 Gbyte block of memory.
--     * i_SB_valid
-- We then have to calculate the address to write 512 byte data blocks to, for each fine channel :
-- 
--     HBM address = i_SB_HBM_base_Addr + 
--                   512 * [(demap_station/4) +
--                          (fine_channel - (i_SB_coarseStart * 3456 + i_SB_fineStart)) * i_SB_stations + 
--                          time * i_SB_N_fine * i_SB_stations * 512]
--  where:
--   fine_channel = demap_skyFrequency + 0:3455
--           time = 0 to 5, for 6 blocks of 32 time samples each (there are 32 time samples in a 512 byte block written to the HBM).
--                  Note 6 x 32 = 192 time samples total = 849 ms of data.
-- i.e. group first by station, then by fine channel, then by time sample.
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
        i_virtualChannel  : in t_slv_16_arr(3 downto 0); -- 4 virtual channels, one for each of the filterbank data streams.
        i_bad_poly        : in std_logic;
        i_lastChannel     : in std_logic;
        i_HeaderValid     : in std_logic_vector(3 downto 0);
        i_data            : in t_ctc_output_payload_arr(3 downto 0); -- 8 bit data; fields are Hpol.re, .Hpol.im, .Vpol.re, .Vpol.im, for each of i_data(0), i_data(1), i_data(2), i_data(3)
        i_dataValid       : in std_logic;
        o_trigger_readout : out std_logic; -- Just received the last packet in a frame for a particular virtual channel.
        o_trigger_buffer  : out std_logic;
        o_trigger_frameCount : out std_logic_vector(31 downto 0);
        -- interface to the bad poly memory
        o_bp_addr0    : out std_logic_vector(7 downto 0); -- one entry per subarray beam, double buffered, 128 subarray beams in buffer 0 so 256 deep.
        o_bp_wr_en0   : out std_logic;
        o_bp_wr_data0 : out std_logic;
        o_bp_addr1    : out std_logic_vector(7 downto 0); -- one entry per subarray beam, double buffered, 128 subarray beams in buffer 1 so 256 deep.
        o_bp_wr_en1   : out std_logic;
        o_bp_wr_data1 : out std_logic;
        --------------------------------------------------------------------
        -- interface to the demap table 
        o_vc_demap_rd_addr   : out std_logic_vector(7 downto 0);
        o_vc_demap_req       : out std_logic;  -- request a read from address o_vc_demap_rd_addr
        i_demap_data_valid   : in  std_logic;  -- Read data below (i_demap* signals) is valid.
        i_demap_SB_index     : in std_logic_vector(7 downto 0);  -- index into the subarray-beam table.
        i_demap_station      : in std_logic_vector(11 downto 0); -- station index within the subarray-beam.
        i_demap_skyFrequency : in std_logic_vector(8 downto 0);  -- sky frequency.
        i_demap_valid        : in std_logic;                     -- This entry in the demap table is valid.
        i_demap_fw_start     : in std_logic_vector(11 downto 0);  -- first fine channel to forward as a packet to the 100GE
        i_demap_fw_end       : in std_logic_vector(11 downto 0); -- Last fine channel to forward as a packet to the 100GE
        i_demap_fw_dest      : in std_logic_vector(7 downto 0);  -- Tag for the packet. 
        -- Interface to the subarray_beam table
        o_SB_addr           : out std_logic_vector(7 downto 0);  -- 256 entries; first 128 entries for the first HBM interface (=first correlator instance), second 128 entries for the second HBM interface (=second correlator instance).
        o_SB_req            : out std_logic;
        i_SB_valid          : in std_logic;
        -- returned subarray beam ("SB") data :
        i_SB_stations       : in std_logic_vector(15 downto 0);  -- The number of (sub)stations in this subarray-beam
        i_SB_coarseStart    : in std_logic_vector(15 downto 0);  -- The first coarse channel in this subarray-beam
        i_SB_fineStart      : in std_logic_vector(15 downto 0);  -- readout_buf1_fineStart, -- the first fine channel in this subarray-beam
        i_SB_n_fine         : in std_logic_vector(23 downto 0);  -- The number of fine channels in this subarray-beam
        i_SB_HBM_base_addr  : in std_logic_vector(31 downto 0);  -- base address in HBM for this subarray-beam.
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
end corr_ct2_din;

architecture Behavioral of corr_ct2_din is
    
    signal bufDout : t_slv_128_arr(3 downto 0);
    signal bufWE, bufWEFinal, bufWEFinal_del1 : std_logic_vector(3 downto 0);
    signal bufWE_slv : t_slv_1_arr(3 downto 0);
    signal bufWrAddr, bufWrAddrFinal, bufWrAddrFinal_del1 : std_logic_vector(15 downto 0);
    signal bufWrData, bufWrDataFinal, bufWrDataFinal_del1 : std_logic_vector(127 downto 0);
    signal bufRdAddr : std_logic_vector(15 downto 0);
    
    signal timeStep : std_logic_vector(5 downto 0);
    signal dataValidDel1, dataValidDel2 : std_logic := '0';
    signal copyToHBM : std_logic := '0';
    
    type copy_fsm_t is (start, set_aw, wait_HBM1_aw_rdy, wait_HBM0_aw_rdy, skip_rdy, get_next_addr, idle);
    signal copy_fsm : copy_fsm_t := idle;
    signal copyToHBM_buffer : std_logic;
   -- signal copyToHBM_channelGroup : std_logic_vector(7 downto 0);
    signal copy_buffer : std_logic := '0';
    --signal copy_channelGroup : std_logic_vector(7 downto 0);
    signal copyToHBM_time : std_logic_vector(2 downto 0);
    signal copy_time : std_logic_vector(2 downto 0);
    signal fineChannel, fineChannel_del1 : std_logic_vector(11 downto 0);
    signal virtualChannel, virtualChannel1, virtualChannel2, virtualChannel3 : std_logic_vector(15 downto 0);
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
    
    signal demap_station, copyToHBM_station, copy_station : std_logic_vector(11 downto 0);  -- station index within the subarray-beam.
    signal demap_skyFrequency, copyToHBM_skyFrequency, copy_skyFrequency : std_logic_vector(8 downto 0);  -- sky frequency.
    signal demap_valid        : std_logic;                      -- This entry in the demap table is valid.
    signal demap_fw_start     : std_logic_vector(11 downto 0);  -- first fine channel to forward as a packet to the 100GE
    signal demap_fw_end       : std_logic_vector(11 downto 0);  -- Last fine channel to forward as a packet to the 100GE
    signal demap_fw_dest      : std_logic_vector(7 downto 0);   -- Tag for the packet.
    signal SB_stations, copyToHBM_SB_stations, copy_SB_stations : std_logic_vector(15 downto 0);  -- The number of (sub)stations in this subarray-beam
    signal SB_coarseStart, copyToHBM_SB_coarseStart, copy_SB_coarseStart : std_logic_vector(15 downto 0);  -- The first coarse channel in this subarray-beam
    signal SB_fineStart, copyToHBM_SB_fineStart, copy_SB_fineStart, copy_fineChannel : std_logic_vector(15 downto 0);  -- readout_buf1_fineStart, -- the first fine channel in this subarray-beam
    signal SB_n_fine, copyToHBM_SB_n_fine, copy_SB_n_fine         : std_logic_vector(23 downto 0);  -- The number of fine channels in this subarray-beam
    signal SB_HBM_base_addr, copyToHBM_SB_HBM_base_addr, copy_SB_HBM_base_addr : std_logic_vector(31 downto 0);  --
    
    signal SB_req : std_logic := '0';
    signal SB_addr : std_logic_vector(7 downto 0);
    
    signal HBM_base_plus_station : std_logic_vector(31 downto 0);
    signal N_fine_x_stations_full : signed(39 downto 0);
    signal N_fine_x_stations : std_logic_vector(25 downto 0);
    signal sof_del1 : std_logic := '0';
    signal time_block : std_logic_vector(3 downto 0);
    signal N_fine_x_stations_x_time : signed(29 downto 0);
    signal N_fine_x_stations_x_time_x512 : std_logic_vector(31 downto 0);
    signal copy_SB_HBM_sel, copyToHBM_SB_HBM_sel : std_logic;
    signal get_addr : std_logic;
    signal HBM_addr : std_logic_vector(31 downto 0);
    signal HBM_addr_bad, HBM_fine_high, HBM_Addr_valid : std_logic;
    signal fineChannel_ext : std_logic_vector(23 downto 0);
    signal sof_hold : std_logic := '0';
    signal trigger_demap_rd : std_logic := '0';
    signal HBM_axi_aw : t_axi4_full_addr_arr(1 downto 0);
    signal HBM_fine_remaining : std_logic_vector(11 downto 0);
    signal trigger_copyData_fsm, first_aw : std_logic := '0';
    signal copyData_fineChannel_Start : std_logic_vector(15 downto 0);
    signal copyData_NFine_Start, copyData_fineRemaining : std_logic_vector(11 downto 0);
    signal copyData_fineChannel_Start_x8 : std_logic_vector(15 downto 0);
    signal trigger_readout, last_virtual_channel : std_logic := '0';
    signal last_word_in_frame : std_logic_vector(15 downto 0) := x"0000";
    signal copyData_trigger, copy_trigger, copyToHBM_trigger, trigger_buffer : std_logic := '0';
    signal cbuffer : std_logic_vector(15 downto 0);
    signal copydata_buffer : std_logic := '0';
    signal copyToHBM_count, copydata_count : std_logic_vector(15 downto 0);
    signal copy_fsm_dbg : std_logic_vector(3 downto 0);
    signal copyData_fsm_dbg : std_logic_vector(3 downto 0);
    signal fifo_rst : std_logic := '0';
    signal copy_fsm_dbg_at_start : std_logic_vector(3 downto 0) := "1111";
    signal in_set_aw_count : std_logic_vector(7 downto 0) := x"00";
    signal copy_fsm_stuck : std_logic;
    signal virtualChannel0Del1, virtualChannel3Del1 : std_logic_vector(15 downto 0);

    signal wait_HBMX_aw_rdy_stuck       : std_logic;
    signal wait_HBMX_aw_rdy_stuck_cnt   : unsigned(15 downto 0) := x"0000";
    signal trigger_frameCount, recent_frameCount : std_logic_vector(31 downto 0);
    
    COMPONENT ila_0
    PORT (
   	    clk : IN STD_LOGIC;
   	    probe0 : IN STD_LOGIC_VECTOR(191 DOWNTO 0));
    END COMPONENT;
    
    signal bad_poly_buffer : std_logic;
    signal bp_addr0, bp_addr1 : std_logic_vector(6 downto 0);
    type t_bad_poly_fsm is (clear_memory, check_bad, set_bad, idle, wait_check_bad);
    signal bad_poly_fsm : t_bad_poly_fsm := idle;
    signal bp_wr_en0, bp_wr_en1, bp_wr_data0, bp_wr_data1, bad_poly_del1, bad_poly : std_logic;
    signal bad_poly_wait_count : std_logic_vector(7 downto 0);
    
    signal max_copyAW_time : std_logic_vector(31 downto 0); -- time required to put out all the addresses
    signal max_copyData_readout_time : std_logic_vector(31 downto 0); -- time required to put out all the data
    signal minimum_time_between_wr_triggers : std_logic_Vector(31 downto 0); -- minimum time available
    signal wr_overflow : std_logic_vector(31 downto 0);
    signal copyAW_time, copydata_readout_time, time_between_wr_triggers : std_logic_vector(31 downto 0);
    signal insert_dbg : std_logic;
    
begin
    
    o_status1(15 downto 0) <= copyToHBM_count;
    o_status1(19 downto 16) <= copy_fsm_dbg;
    o_status1(23 downto 20) <= copyData_fsm_dbg;
    o_status1(29 downto 24) <= dataFIFO_dataCount(0);
    o_status1(30) <= first_aw;
    o_status1(31) <= copy_fsm_stuck;
    
    o_status2(15 downto 0) <= copydata_count;
    o_status2(19 downto 16) <= copy_fsm_dbg_at_start;
    o_status2(31 downto 20) <= copy_finechannel(11 downto 0);
    
    o_SB_req <= SB_req;
    o_SB_addr <= SB_addr;
    
    o_bp_addr0 <= bad_poly_buffer & bp_addr0;
    o_bp_addr1 <= bad_poly_buffer & bp_addr1;
    o_bp_wr_en0 <= bp_wr_en0;
    o_bp_wr_en1 <= bp_wr_en1;
    o_bp_wr_data0 <= bp_wr_data0;
    o_bp_wr_data1 <= bp_wr_data1;
    
    process(i_axi_clk)
        variable demap_station_x128 : std_logic_vector(31 downto 0);
    begin
        if rising_edge(i_axi_clk) then
            dataValidDel1 <= i_dataValid;
            dataValidDel2 <= dataValidDel1;
            
            virtualChannel0Del1 <= i_virtualChannel(0);
            virtualChannel3Del1 <= i_virtualChannel(3);
            
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
                bp_addr0 <= (others => '0');
                bp_addr1 <= (others => '0');
                bp_wr_en0 <= '1';
                bp_wr_en1 <= '1';
                bad_poly <= bad_poly_del1;
                bp_wr_data0 <= '0';
                bp_wr_data1 <= '0';
            else
                case bad_poly_fsm is
                    when clear_memory =>
                        bp_addr0 <= std_logic_vector(unsigned(bp_addr0) + 1);
                        bp_addr1 <= std_logic_vector(unsigned(bp_addr1) + 1);
                        if unsigned(bp_addr0) = 127 then
                            bad_poly_fsm <= check_bad;
                            bp_wr_en0 <= '0';
                            bp_wr_en1 <= '0';
                        else
                            bp_wr_en0 <= '1';
                            bp_wr_en1 <= '1';
                        end if;
                        
                    when check_bad =>
                        if demap_valid = '1' and bad_poly = '1' then
                            bad_poly_fsm <= set_bad;
                        else
                            bad_poly_fsm <= idle;
                        end if;
                        bp_wr_en0 <= '0';
                        bp_wr_en1 <= '0';
                        
                    when set_bad =>
                        bp_addr0(6 downto 0) <= SB_addr(6 downto 0);
                        bp_addr1(6 downto 0) <= SB_addr(6 downto 0);
                        bp_wr_data0 <= '1';
                        bp_wr_data1 <= '1';
                        if SB_addr(7) = '0' then
                            bp_wr_en0 <= '1';
                            bp_wr_en1 <= '0';
                        else
                            bp_wr_en0 <= '1';
                            bp_wr_en1 <= '0';
                        end if;
                        bad_poly_fsm <= idle;
                        
                    when idle =>
                        if dataValidDel1 = '1' and dataValidDel2 = '0' then
                            bad_poly <= bad_poly_del1;
                            bad_poly_fsm <= wait_check_bad;
                        end if;
                        bad_poly_wait_count <= (others => '0');
                        bp_wr_data0 <= '0';
                        bp_wr_data1 <= '0';
                        bp_wr_en0 <= '0';
                        bp_wr_en1 <= '0';
                    
                    when wait_check_bad =>
                        -- wait for a while so that reading of the demap table is complete
                        if unsigned(bad_poly_wait_count) > 127 then
                            bad_poly_fsm <= check_bad;
                        else
                            bad_poly_wait_count <= std_logic_vector(unsigned(bad_poly_wait_count) + 1);
                        end if;
                        bp_wr_data0 <= '0';
                        bp_wr_data1 <= '0';
                        bp_wr_en0 <= '0';
                        bp_wr_en1 <= '0';
                    
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
                virtualChannel1 <= std_logic_vector(unsigned(virtualChannel0Del1) + 1);
                virtualChannel2 <= std_logic_vector(unsigned(virtualChannel0Del1) + 2);
                virtualChannel3 <= std_logic_vector(unsigned(virtualChannel0Del1) + 3);
                last_virtual_channel <= i_lastchannel;
                frameCount_mod3 <= i_frameCount_mod3;
                frameCount_849ms <= i_frameCount_849ms;
                trigger_demap_rd <= '1';
                lastTime <= '0';
            elsif dataValidDel1 = '0' and dataValidDel2 = '1' then
                -- falling edge of i_dataValid
                trigger_demap_rd <= '0';
                timeStep <= std_logic_vector(unsigned(timeStep) + 1);
                if timeStep = "111111" then
                    lastTime <= '1';
                else
                    lastTime <= '0';
                end if;
            else
                trigger_demap_rd <= '0';
            end if;
            
            sof_del1 <= i_sof;
            if trigger_demap_rd = '1' then
                o_vc_demap_rd_addr <= virtualChannel(9 downto 2);
                o_vc_demap_req <= '1';
            else
                o_vc_demap_req <= '0'; 
            end if;
            
            if i_demap_Data_valid = '1' then
                demap_station <= i_demap_station;   -- in (11:0); Station index within the subarray-beam.
                demap_skyFrequency <= i_demap_skyFrequency; -- in (8:0); Sky frequency.
                demap_valid <= i_demap_valid;       -- in std_logic; This entry in the demap table is valid.
                demap_fw_start <= i_demap_fw_start; -- in (11:0); First fine channel to forward as a packet to the 100GE
                demap_fw_end <= i_demap_fw_end;     -- in (11:0); Last fine channel to forward as a packet to the 100GE
                demap_fw_dest <= i_demap_fw_dest;   -- in (7:0);  Tag for the packet.
                SB_req <= '1';
                SB_addr <= i_demap_SB_index(7 downto 0); -- in (7:0);  Index into the subarray-beam table.
            elsif i_SB_valid = '1' then
                SB_req <= '0';
                SB_stations <= i_SB_stations;       -- in (15:0); The number of (sub)stations in this subarray-beam
                SB_coarseStart <= i_SB_coarseStart; -- in (15:0); The first coarse channel in this subarray-beam
                SB_fineStart <= i_SB_fineStart;     -- in (15:0); readout_buf1_fineStart, -- the first fine channel in this subarray-beam
                SB_n_fine <= i_SB_n_fine;           -- in (23:0); The number of fine channels in this subarray-beam
                SB_HBM_base_addr <= i_SB_HBM_base_addr;  -- in (31:0); Base address in HBM for this subarray-beam.
                -- this value gets registered at some point just after getting the first 
                time_block <= '0' & frameCount_mod3 & timeStep(5); -- blocks of 32 times;
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
            fineChannel_del1 <= fineChannel;
            
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
            
            -----------------------------------------
            -- Insert debug data if requested
            bufWEFinal_del1 <= bufWEFinal;
            bufWrAddrFinal_del1 <= bufWrAddrFinal;
            insert_dbg <= i_insert_dbg;
            if (insert_dbg = '1') then
                bufWrDataFinal_del1(9 downto 0) <= virtualChannel(9 downto 0);
                bufWrDataFinal_del1(21 downto 10) <= fineChannel_del1(11 downto 0);
                bufWrDataFinal_del1(27 downto 22) <= timeStep(5 downto 0);
                bufWrDataFinal_del1(29 downto 28) <= frameCount_mod3(1 downto 0);
                bufWrDataFinal_del1(31 downto 30) <= frameCount_849ms(1 downto 0);
                --
                bufWrDataFinal_del1(32+9 downto 32+0) <= virtualChannel1(9 downto 0);
                bufWrDataFinal_del1(32+21 downto 32+10) <= fineChannel_del1(11 downto 0);
                bufWrDataFinal_del1(32+27 downto 32+22) <= timeStep(5 downto 0);
                bufWrDataFinal_del1(32+29 downto 32+28) <= frameCount_mod3(1 downto 0);
                bufWrDataFinal_del1(32+31 downto 32+30) <= frameCount_849ms(1 downto 0);
                --
                bufWrDataFinal_del1(64+9 downto 64+0) <= virtualChannel2(9 downto 0);
                bufWrDataFinal_del1(64+21 downto 64+10) <= fineChannel_del1(11 downto 0);
                bufWrDataFinal_del1(64+27 downto 64+22) <= timeStep(5 downto 0);
                bufWrDataFinal_del1(64+29 downto 64+28) <= frameCount_mod3(1 downto 0);
                bufWrDataFinal_del1(64+31 downto 64+30) <= frameCount_849ms(1 downto 0);
                --
                bufWrDataFinal_del1(96+9 downto 96+0) <= virtualChannel3(9 downto 0);
                bufWrDataFinal_del1(96+21 downto 96+10) <= fineChannel_del1(11 downto 0);
                bufWrDataFinal_del1(96+27 downto 96+22) <= timeStep(5 downto 0);
                bufWrDataFinal_del1(96+29 downto 96+28) <= frameCount_mod3(1 downto 0);
                bufWrDataFinal_del1(96+31 downto 96+30) <= frameCount_849ms(1 downto 0);
            else
                bufWrDataFinal_del1 <= bufWrDataFinal;
            end if;
            
            ------------------------------------------
            -- Trigger copying of data to the HBM.
            --  This occurs once we have buffered up 32 time samples, for 4 virtual channels, for all 3456 fine channels.
            --  So we have 3456 blocks of 512 bytes to send to the HBM.
            
            if i_dataValid = '0' and dataValidDel1 = '1' and timeStep(4 downto 0) = "11111" then
                copyToHBM <= demap_valid;
                copyToHBM_buffer <= frameCount_849ms(0); -- every 849 ms, alternate halfs within each 3 Gbyte HBM buffer.
                recent_frameCount <= frameCount_849ms;
                -- Parameters for this block of data :
                copyToHBM_time(0) <= timeStep(5); -- first or second half of the 64 time samples per first corner turn frame.
                copyToHBM_time(2 downto 1) <= frameCount_mod3;
                copyToHBM_station <= demap_station;
                copyToHBM_skyFrequency <= demap_skyFrequency;
                -- Parameters for this subarray-beam.
                copyToHBM_SB_stations <= SB_stations;
                copyToHBM_SB_coarseStart <= SB_coarseStart;
                copyToHBM_SB_fineStart <= SB_fineStart;
                copyToHBM_SB_n_fine <= SB_n_fine;
                copyToHBM_SB_HBM_base_addr <= SB_HBM_base_addr;
                copyToHBM_SB_HBM_sel <= SB_addr(7); -- The top bit of the subarray-beam address selects which correlator instance the data is for.
                if (timeStep(5) = '1' and frameCount_mod3 = "10" and last_virtual_channel = '1') then
                    -- trigger readout to the correlators once this data is written to the HBM
                    copyToHBM_trigger <= '1';
                else
                    copyToHBM_trigger <= '0';
                end if;
            else
                copyToHBM <= '0';
            end if;
            
            if copyToHBM = '1' then
                copyToHBM_count <= std_logic_vector(unsigned(copyToHBM_count) + 1);
            end if;
            if trigger_copyData_fsm = '1' then
                copydata_count <= std_logic_vector(unsigned(copydata_count) + 1);
            end if;
            
            if copyToHBM = '1' then
                copy_fsm_dbg_at_start <= copy_fsm_dbg;
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
            addra                   => bufWrAddrFinal_del1,
            dina                    => bufWrDataFinal_del1,
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
        bufWE_slv(i)(0) <= bufWEFinal_del1(i);
    end generate;
    
    -- At completion of 32 times, copy data from the ultraRAM buffer to the HBM
    hbm_addri : entity ct_lib.get_ct2_HBM_addr
    port map(
        i_axi_clk => i_axi_clk, --  in std_logic;
        -- Values from the Subarray-beam table
        i_SB_HBM_base_Addr => copy_SB_HBM_base_addr, -- in (31:0); Base address in HBM for this subarray-beam
        i_SB_coarseStart   => copy_SB_coarseStart(8 downto 0), -- in (8:0);  First coarse channel for this subarray-beam, x781.25 kHz to get the actual sky frequency 
        i_SB_fineStart     => copy_SB_fineStart(11 downto 0),  -- in (11:0); First fine channel for this subarray-beam, runs from 0 to 3455
        i_SB_stations      => copy_SB_stations,      -- in (15:0); Total number of stations in this subarray-beam
        i_SB_N_fine        => copy_SB_N_fine, -- in (23:0); Total number of fine channels to store for this subarray-beam
        -- Values for this particular block of 512 bytes. Each block of 512 bytes is 4 stations, 32 time samples ((4stations)*(32timesamples)*(2pol)*(1byte)(2(complex)) = 512 bytes)
        i_coarse_channel   => copy_skyFrequency, -- in (8:0); Coarse channel for this block, x781.25kHz to get the actual sky frequency (so is comparable to i_SB_coarseStart
        i_fine_channel     => fineChannel_ext,   -- in (23:0); Fine channel for this block.
        i_station          => copy_station, -- in (11:0); Index of this station within the subarray
        i_time_block       => copy_time,    -- in (2:0);  Which time block this is for; 0 to 5. Each time block is 32 time samples.
        i_buffer           => copy_buffer,  -- in std_logic; -- Which half of the buffer to calculate for (each half is 1.5 Gbytes)
        -- All above data is valid, do the calculation.
        i_valid            => get_addr, -- in std_logic;
        -- Resulting address in the HBM, after 8 cycles latency.
        o_HBM_addr         => HBM_addr, -- out (31:0);
        o_out_of_range     => HBM_addr_bad,   -- out std_logic; Indicates that the values for (i_coarse_channel, i_fine_channel, i_station, i_time_block) are out of range, and thus o_HBM_addr is not valid.
        o_fine_high        => HBM_fine_high,  -- out std_logic; Indicates that the fine channel selected is higher than the maximum fine channel (i.e. > (i_SB_coarseStart * 3456 + i_SB_fineStart))
        o_fine_remaining   => HBM_fine_remaining, -- out (11:0); Number of fine channels remaining to send for this coarse channel.
        o_valid            => HBM_addr_valid  -- out std_logic; Some fixed number of clock cycles after i_valid.
    );
    
    fineChannel_ext <= x"00" & copy_fineChannel;
    
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
        
            if (copy_fsm = set_aw) then
                if (unsigned(in_set_aw_count) < 255) then
                    in_set_aw_count <= std_logic_vector(unsigned(in_set_aw_count) + 1);
                end if;
            else
                in_set_aw_count <= (others => '0');
            end if;
            if (unsigned(in_set_aw_count) > 16) then
                copy_fsm_stuck <= '1';
            else
                copy_fsm_stuck <= '0';
            end if;
            
            if (copy_fsm = wait_HBM0_aw_rdy) OR (copy_fsm = wait_HBM1_aw_rdy) then
                wait_HBMX_aw_rdy_stuck_cnt  <= wait_HBMX_aw_rdy_stuck_cnt + 1;
            else
                wait_HBMX_aw_rdy_stuck_cnt  <= x"0000";
            end if;

            if wait_HBMX_aw_rdy_stuck_cnt > 1000 then
                wait_HBMX_aw_rdy_stuck <= '1';
            else
                wait_HBMX_aw_rdy_stuck <= '0';
            end if;
        
            -- fsm to generate write addresses
            if i_rst = '1' then
                copy_fsm <= idle;
            elsif copyToHBM = '1' then
                copy_fsm <= start;
                -- Which half of each 3Gbyte buffer to write to in the HBM. 
                -- 1.5 Gbytes of data = 849 ms of data for (typically, up to) 512 stations.
                copy_buffer <= copyToHBM_buffer;
                -- Which group of times within the corner turn 
                -- 6 possible values, 0 to 5, corresponding to times of 
                -- (0-31, 32-63, 64-95, 96-127, 128-159, 160-191)
                copy_time <= copyToHBM_time;
                copy_trigger <= copyToHBM_trigger;
                copy_station <= copyToHBM_station;
                copy_skyFrequency <= copyToHBM_skyFrequency;
                if copyToHBM_skyFrequency = copyToHBM_SB_coarseStart(8 downto 0) then
                    copy_fineChannel <= copyToHBM_SB_fineStart;
                else
                    copy_fineChannel <= (others => '0');
                end if;
                -- Parameters for this subarray-beam.
                copy_SB_stations <= copyToHBM_SB_stations;
                copy_SB_coarseStart <= copyToHBM_SB_coarseStart;
                copy_SB_fineStart <= copyToHBM_SB_fineStart;
                copy_SB_n_fine <= copyToHBM_SB_n_fine;
                copy_SB_HBM_base_addr <= copyToHBM_SB_HBM_base_addr;
                copy_SB_HBM_sel <= copyToHBM_SB_HBM_sel; -- Get which HBM iterface this is going to. 
                first_aw <= '1';
                trigger_copyData_fsm <= '0';
                copy_fsm_dbg <= "0000";
            else
                case copy_fsm is
                    when start =>
                        copy_fsm_dbg <= "0001";
                        copy_fsm <= set_aw;
                        HBM_axi_aw(0).valid <= '0';
                        HBM_axi_aw(1).valid <= '0';
                        get_addr <= '1';
                        trigger_copyData_fsm <= '0';
                    
                    when set_aw =>
                        copy_fsm_dbg <= "0010";
                        if HBM_addr_valid = '1' then
                            -- Address is calculated in the "get_ct2_HBM_addr" module above, see comments in that file.
                            HBM_axi_aw(0).addr(31 downto 9) <= HBM_addr(31 downto 9);
                            HBM_axi_aw(1).addr(31 downto 9) <= HBM_addr(31 downto 9);
                            if HBM_fine_high = '0' then
                                if (copy_SB_HBM_sel = '0') then
                                    HBM_axi_aw(0).valid <= '1';
                                    HBM_axi_aw(1).valid <= '0';
                                    copy_fsm <= wait_HBM0_aw_rdy;
                                else
                                    HBM_axi_aw(1).valid <= '1';
                                    HBM_axi_aw(0).valid <= '0';
                                    copy_fsm <= wait_HBM1_aw_rdy;
                                end if;
                            else
                                HBM_axi_aw(1).valid <= '0';
                                HBM_axi_aw(0).valid <= '0';
                                copy_fsm <= skip_rdy;
                            end if;
                            
                            -- Trigger copying out of the data packets to the fifos that go to the HBM
                            -- for the axi w bus.
                            first_aw <= '0';
                            if first_aw = '1' and HBM_fine_high = '0' then 
                                copyData_fineChannel_Start <= copy_fineChannel;
                                copyData_NFine_Start <= HBM_fine_remaining;
                                trigger_copyData_fsm <= '1';
                            else
                                trigger_copyData_fsm <= '0';
                            end if;
                            -- update for the next address
                            copy_fineChannel <= std_logic_vector(unsigned(copy_fineChannel) + 1);
                        else
                            get_addr <= '0';
                        end if;
                        
                    when wait_HBM0_aw_rdy =>
                        copy_fsm_dbg <= "0011";
                        get_addr <= '0';
                        trigger_copyData_fsm <= '0';
                        if i_HBM_axi_awready(0) = '1' then
                            HBM_axi_aw(0).valid <= '0';
                            copy_fsm <= get_next_addr;
                        end if;
                    
                    when wait_HBM1_aw_rdy =>
                        copy_fsm_dbg <= "0100";
                        get_addr <= '0';
                        if i_HBM_axi_awready(1) = '1' then
                            HBM_axi_aw(1).valid <= '0';
                            copy_fsm <= get_next_addr;
                        end if;
                        trigger_copyData_fsm <= '0';
                    
                    when skip_rdy => -- no request issued to the HBM because the fine channel is not being stored (i.e. HBM_fine_high = '1')
                        copy_fsm_dbg <= "0101";
                        get_Addr <= '0';
                        HBM_axi_aw(1).valid <= '0';
                        HBM_axi_aw(0).valid <= '0';
                        trigger_copyData_fsm <= '0';
                        -- if this fine channel is not being stored, then none of the others are either, so we are done.
                        copy_fsm <= idle;
                    
                    when get_next_addr =>
                        copy_fsm_dbg <= "0110";
                        HBM_axi_aw(0).valid <= '0';
                        HBM_axi_aw(1).valid <= '0';
                        trigger_copyData_fsm <= '0';
                        if (unsigned(copy_fineChannel) = 3456) then
                            copy_fsm <= idle;
                            get_addr <= '0';
                        else
                            copy_fsm <= set_aw;
                            get_addr <= '1';
                        end if;
                        
                    when idle => 
                        copy_fsm_dbg <= "0111";
                        get_Addr <= '0';
                        trigger_copyData_fsm <= '0';
                        HBM_axi_aw(0).valid <= '0';
                        HBM_axi_aw(1).valid <= '0';
                        HBM_axi_aw(0).addr(31 downto 9) <= (others => '0');
                        HBM_axi_aw(1).addr(31 downto 9) <= (others => '0');
                        copy_fsm <= idle; -- stay here until we get "copyToHBM" signal
                        
                    when others => 
                        copy_fsm_dbg <= "1000";
                        copy_fsm <= idle;                        
                        
                end case;
            end if;
            
            -- Copy data from the ultraRAM buffer to the FIFOs.
            -- Needed to meet the axi interface spec, since we have a large latency on reads from the ultraRAM.
            fifo_rst <= i_rst;
            if i_rst = '1' then
                copyData_fsm <= idle;
            elsif trigger_copyData_fsm = '1' then
                copyData_fsm_dbg <= "0000";
                copyData_fsm <= running;
                copyData_trigger <= copy_trigger;
                copyData_buffer <= copy_buffer;
                -- Only copy the fine channels that we are using.
                copyData_fineRemaining <= copyData_NFine_Start;
                
                if copyToHBM_time(0) = '0' then
                    -- Time blocks 0, 2, 4, 6, 8 and 10 are in the first half of the ultraRAM buffer.
                    bufRdAddr <= copyData_fineChannel_Start_x8;
                else
                    bufRdAddr <= std_logic_vector(to_unsigned(28672,16) + unsigned(copyData_fineChannel_Start_x8));
                end if;
                -- In total there are up to (3456 fine channels) x (8 ultraRAM words per channel) = 27648 words. 
                -- There are up to 3456 bursts to the HBM, with 8 words per HBM write burst.
                -- bufRdCount counts the 8 words in a burst, 
                -- copyData_fineRemaining keeps track of how many fine channels are remaining to be sent.
                bufRdCount <= (others => '0');
            else
                case copyData_fsm is                
                    when running =>
                        copyData_fsm_dbg <= "0001";
                        bufRdAddr <= std_logic_vector(unsigned(bufRdAddr) + 1);
                        bufRdCount <= std_logic_vector(unsigned(bufRdCount) + 1);
                        if bufRdCount = "111" then
                            copyData_fineRemaining <= std_logic_vector(unsigned(copyData_fineRemaining) - 1);
                        end if;
                        if ((unsigned(copyData_fineRemaining) = 1) and (bufRdCount = "111")) then
                            copyData_fsm <= idle;
                        elsif (unsigned(fifo_size_plus_pending) > 21) then
                            -- total space in the FIFO is 32, stop at 21 since there is some lag between fifo write occurring and fifo_size_plus_pending incrementing.
                            copyData_fsm <= wait_fifo;
                        end if;
                        
                    when wait_fifo =>
                        copyData_fsm_dbg <= "0010";
                        -- Wait until there is space in the FIFO.
                        if (unsigned(fifo_size_plus_pending) < 21) then
                            copyData_fsm <= running;
                        end if;
                    
                    when idle =>
                        copyData_fsm_dbg <= "0011";
                        copyData_fsm <= idle;
                        
                end case;
            end if;
            
            if (copyData_fsm = running and copy_SB_HBM_sel = '0') then
                dataFIFO0_wrEn(0) <= '1';
            else
                dataFIFO0_wrEn(0) <= '0';
            end if;
            if (copyData_fsm = running and copy_SB_HBM_sel = '1') then
                dataFIFO1_wrEn(0) <= '1';
            else
                dataFIFO1_wrEn(0) <= '0';
            end if;
            
            if copyData_fsm = running and bufRdCount(2 downto 0) = "111" then
                last(0) <= '1'; -- last word in an 8 word HBM burst.
                if ((unsigned(copyData_fineRemaining) = 1) and (copyData_trigger = '1')) then
                    last_word_in_frame(0) <= '1';
                else
                    last_word_in_frame(0) <= '0';
                end if;
                cbuffer(0) <= copydata_buffer;
            else
                last(0) <= '0';
                last_word_in_frame(0) <= '0';
            end if;
            last(15 downto 1) <= last(14 downto 0);
            last_word_in_frame(15 downto 1) <= last_word_in_frame(14 downto 0);
            cbuffer(15 downto 1) <= cbuffer(14 downto 0);
            
            -- 16 clock latency to read the ultraRAM buffer.
            dataFIFO0_wrEn(15 downto 1) <= dataFIFO0_wrEn(14 downto 0);
            dataFIFO1_wrEn(15 downto 1) <= dataFIFO1_wrEn(14 downto 0);
            
            -- Need to know how many writes to the FIFO are pending, due to the large latency in reading the ultraRAM buffer.
            fifo_size_plus_pending0 <= std_logic_vector(unsigned(pending0) + unsigned(dataFIFO_dataCount(0)));
            fifo_size_plus_pending1 <= std_logic_vector(unsigned(pending1) + unsigned(dataFIFO_dataCount(1)));
            
            if copy_SB_HBM_sel = '0' then
                fifo_size_plus_pending <= fifo_size_plus_pending0;
            else
                fifo_size_plus_pending <= fifo_size_plus_pending1;
            end if;
            
            dataFIFO_wrEn(0) <= dataFIFO0_wrEn(15);
            dataFIFO_wrEn(1) <= dataFIFO1_wrEn(15);
            dataFIFO_din(0) <= cbuffer(15) & last_word_in_frame(15) & last(15) & bufDout(3) & bufDout(2) & bufDout(1) & bufDout(0);
            dataFIFO_din(1) <= cbuffer(15) & last_word_in_frame(15) & last(15) & bufDout(3) & bufDout(2) & bufDout(1) & bufDout(0);
            
            --------------------------------------------------------
            -- Keep track of things for registers:
            --   - minimum time between copy triggers
            --   - Max time for a readout
            --   - overwrite occurred - read trigger while still writing
            --
            if copyToHBM = '1' then
                time_between_wr_triggers <= (others => '0');
            elsif time_between_wr_triggers(31) = '0' then
                time_between_wr_triggers <= std_logic_vector(unsigned(time_between_wr_triggers) + 1);
            end if;
            
            if i_rst = '1' then
                minimum_time_between_wr_triggers <= (others => '1');
            elsif copyToHBM = '1' and (unsigned(time_between_wr_triggers) < unsigned(minimum_time_between_wr_triggers)) then
                minimum_time_between_wr_triggers <= time_between_wr_triggers;
            end if;
            
            if trigger_copyData_fsm = '1' then
                copydata_readout_time <= (others => '0');
            elsif copydata_fsm /= idle then
                copydata_readout_time <= std_logic_vector(unsigned(copydata_readout_time) + 1);
            end if;
            
            if i_rst = '1' then
                max_copydata_readout_time <= (others => '0');
            elsif trigger_copyData_fsm = '1' and (unsigned(copydata_readout_time) > unsigned(max_copydata_readout_time)) then
                max_copydata_readout_time <= copydata_readout_time;
            end if;
            
            if copyToHBM = '1' then
                copyAW_time <= (others => '0');
            elsif copy_fsm /= idle then
                copyAW_time <= std_logic_vector(unsigned(copyAW_time) + 1);
            end if;
            
            if i_rst = '1' then
                max_copyAW_time <= (others => '0');
            elsif copyToHBM = '1' and (unsigned(copyAW_time) > unsigned(max_copyAW_time)) then
                max_copyAW_time <= copyAW_time;
            end if;
            
            if i_rst = '1' then
                wr_overflow <= (others => '0');
            elsif wr_overflow(1 downto 0) = "00" then
                if trigger_copydata_fsm = '1' and copyData_fsm /= idle then
                    wr_overflow(0) <= '1';
                    wr_overflow(15 downto 4) <= copydata_fineRemaining;
                end if;
                if copyToHBM = '1' and copy_fsm /= idle then
                    wr_overflow(1) <= '1';
                    wr_overflow(31 downto 20) <= copy_fineChannel(11 downto 0);
                end if;
            end if;
            
            o_max_copyAW_time <= max_copyAW_time;  -- time required to put out all the addresses
            o_max_copyData_time <= max_copydata_readout_time; -- time required to put out all the data
            o_min_trigger_interval <= minimum_time_between_wr_triggers; -- minimum time available
            o_wr_overflow <= wr_overflow; -- overflow + debug info when the overflow occurred.
            
        end if;
    end process;

    copyData_fineChannel_Start_x8 <= copyData_fineChannel_Start(12 downto 0) & "000";

    -- Number of ones in the wrEN vector is the number of pending writes to the fifo,
    -- due to the latency of the ultraRAM buffer.
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
        -- 514 wide :
        --   511:0  = data
        --   512    = last in axi transaction
        --   513    = last in the frame, on readout this triggers read of the data.
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
            READ_DATA_WIDTH => 515,     -- DECIMAL
            READ_MODE => "fwft",        -- String
            SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
            USE_ADV_FEATURES => "1404", -- String; bit 12 = enable data valid flag, bits 2 and 10 enable read and write data counts
            WAKEUP_TIME => 0,           -- DECIMAL
            WRITE_DATA_WIDTH => 515,    -- DECIMAL
            WR_DATA_COUNT_WIDTH => 6    -- DECIMAL
        )
        port map (
            almost_empty => open,     -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
            almost_full => open,      -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
            data_valid => dataFIFO_valid(i), -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
            dbiterr => open,          -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
            dout => dataFIFO_dout(i), -- READ_DATA_WIDTH-bit output: Read Data: The output data bus is driven when reading the FIFO.
            empty => open,            -- 1-bit output: Empty Flag: When asserted, this signal indicates that- the FIFO is empty.
            full => open,             -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full.
            overflow => open,         -- 1-bit output: Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected, because the FIFO is full
            prog_empty => open,       -- 1-bit output: Programmable Empty: This signal is asserted when the number of words in the FIFO is less than or equal to the programmable empty threshold value.
            prog_full => open,        -- 1-bit output: Programmable Full: This signal is asserted when the number of words in the FIFO is greater than or equal to the programmable full threshold value.
            rd_data_count => open, -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
            rd_rst_busy => open,   -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
            sbiterr => open,       -- 1-bit output: Single Bit Error: Indicates that the ECC decoder detected and fixed a single-bit error.
            underflow => open,     -- 1-bit output: Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected because the FIFO is empty.
            wr_ack => open,        -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.
            wr_data_count => dataFIFO_dataCount(i), -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
            wr_rst_busy => open,     -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
            din => dataFIFO_din(i),  -- WRITE_DATA_WIDTH-bit input: Write Data: The input data bus used when writing the FIFO.
            injectdbiterr => '0', -- 1-bit input: Double Bit Error Injection
            injectsbiterr => '0', -- 1-bit input: Single Bit Error Injection: 
            rd_en => dataFIFO_RdEn(i), -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO. 
            rst => fifo_rst,      -- 1-bit input: Reset: Must be synchronous to wr_clk.
            sleep => '0',         -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
            wr_clk => i_axi_clk,  -- 1-bit input: Write clock: Used for write operation. wr_clk must be a free running clock.
            wr_en => dataFIFO_wrEn(i) -- 1-bit input: Write Enable: 
        );
    
    end generate;
    

    o_HBM_axi_w(0).data <= dataFIFO_dout(0)(511 downto 0);
    o_HBM_axi_w(0).last <= dataFIFO_dout(0)(512);
    o_HBM_axi_w(0).valid <= dataFIFO_valid(0);
    o_HBM_axi_w(0).resp <= "00";
    
    o_HBM_axi_w(1).data <= dataFIFO_dout(1)(511 downto 0);
    o_HBM_axi_w(1).last <= dataFIFO_dout(1)(512);
    o_HBM_axi_w(1).valid <= dataFIFO_valid(1);
    o_HBM_axi_w(1).resp <= "00";

    HBM_axi_aw(0).len <= "00000111";  -- Always 8 x 64 byte words per burst.
    HBM_axi_aw(0).addr(39 downto 32) <= "00000000";  -- 3 Gbyte piece of HBM; so bits 39:32 are 0.
    HBM_axi_aw(0).addr(8 downto 0)   <= "000000000";
    HBM_axi_aw(1).len <= "00000111";  -- Always 8 x 64 byte words per burst.
    HBM_axi_aw(1).addr(39 downto 32) <= "00000000";  -- 3 Gbyte piece of HBM; so bits 39:32 are 0.
    HBM_axi_aw(1).addr(8 downto 0)   <= "000000000";
    
    o_HBM_axi_aw(0) <= HBM_axi_aw(0);
    o_HBM_axi_aw(1) <= HBM_axi_aw(1);
    
    dataFIFO_rden(0) <= dataFIFO_valid(0) and i_HBM_axi_wready(0);
    dataFIFO_rden(1) <= dataFIFO_valid(1) and i_HBM_axi_wready(1);
    
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            if ((dataFIFO_rden(0) = '1' and dataFIFO_dout(0)(513) = '1') or 
                (dataFIFO_rden(1) = '1' and dataFIFO_dout(1)(513) = '1')) then
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
    
    

    generate_debug_ila : IF g_DEBUG_ILA GENERATE
        ct2_ila : ila_0
        port map (
            clk => i_axi_clk,
            probe0(15 downto 0) => copyToHBM_count,
            probe0(19 downto 16) => copy_fsm_dbg,
            probe0(23 downto 20) => copyData_fsm_dbg,
            probe0(29 downto 24) => dataFIFO_dataCount(0),
            probe0(30) => first_aw,
            probe0(31) => copy_fsm_stuck,
            probe0(47 downto 32) => copydata_count,
            probe0(59 downto 48) => copy_finechannel(11 downto 0),
            probe0(60) => get_addr,
            probe0(61) => HBM_addr_valid,
            probe0(62) => HBM_addr_bad,
            probe0(63) => HBM_fine_high,
            probe0(95 downto 64) => HBM_addr,
            probe0(96) => dataFIFO_valid(0),
            probe0(97) => dataFIFO_valid(1),
            probe0(100 downto 98) => dataFIFO_dout(0)(514 downto 512),
            probe0(103 downto 101) => dataFIFO_dout(1)(514 downto 512),
            probe0(104) => HBM_axi_aw(0).valid,
            probe0(105) => HBM_axi_aw(1).valid,
            probe0(137 downto 106) => HBM_axi_aw(0).addr(31 downto 0),
            probe0(138) => i_HBM_axi_awready(0),
            probe0(139) => i_HBM_axi_awready(1),
            probe0(140) => last_virtual_channel,
            probe0(141) => copyToHBM_trigger,
            probe0(149 downto 142) => i_virtualChannel(0)(7 downto 0),
            probe0(157 downto 150) => i_virtualChannel(1)(7 downto 0),
            probe0(165 downto 158) => i_virtualChannel(2)(7 downto 0),
            probe0(167 downto 166) => i_frameCount_mod3,
            probe0(171 downto 168) => i_HeaderValid,
            probe0(172) => i_lastChannel,
            probe0(176 downto 173) => i_frameCount_849ms(3 downto 0),
            probe0(191 downto 177) => (others => '0') 
        );
        
        ct2_pt2_ila : ila_0
        port map (
            clk => i_axi_clk,
            probe0(15 downto 0) => copyToHBM_count,
            probe0(19 downto 16) => copy_fsm_dbg,
            probe0(23 downto 20) => copyData_fsm_dbg,
            probe0(29 downto 24) => dataFIFO_dataCount(0),

            probe0(45 downto 30) => last_word_in_frame,
            probe0(57 downto 46) => copyData_fineRemaining,
            probe0(58) => copyData_trigger,

            probe0(61 downto 59) => bufRdCount,

            probe0(62) => trigger_copyData_fsm,
            probe0(68 downto 63) => dataFIFO_dataCount(1),
            probe0(70 downto 69) => dataFIFO_wrEn,
            
            probe0(71) => wait_HBMX_aw_rdy_stuck,
            probe0(72) => copy_trigger,
            probe0(73) => copyToHBM,

            probe0(74) => i_HBM_axi_b(0).valid,
            probe0(75) => i_HBM_axi_b(1).valid,

            probe0(77 downto 76) => i_HBM_axi_b(0).resp,
            probe0(79 downto 78) => i_HBM_axi_b(1).resp,

            probe0(81 downto 80) => i_HBM_axi_wready,

            probe0(87 downto 82) => fifo_size_plus_pending,
            probe0(88) => copy_SB_HBM_sel,

            probe0(95 downto 89) => ( others => '0' ),

            probe0(96) => dataFIFO_valid(0),
            probe0(97) => dataFIFO_valid(1),
            probe0(100 downto 98) => dataFIFO_dout(0)(514 downto 512),
            probe0(103 downto 101) => dataFIFO_dout(1)(514 downto 512),
            probe0(104) => HBM_axi_aw(0).valid,
            probe0(105) => HBM_axi_aw(1).valid,
            probe0(137 downto 106) => HBM_axi_aw(0).addr(31 downto 0),
            probe0(138) => i_HBM_axi_awready(0),
            probe0(139) => i_HBM_axi_awready(1),
            probe0(140) => last_virtual_channel,
            probe0(141) => copyToHBM_trigger,

            probe0(157 downto 142) => dataFIFO0_wrEn,
            probe0(173 downto 158) => dataFIFO1_wrEn,
            probe0(183 downto 174) => i_virtualChannel(2)(9 downto 0),
            probe0(191 downto 184) => i_virtualChannel(3)(7 downto 0)
        );
    END GENERATE;    
    
end Behavioral;
