----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 08/14/2022 08:38:07 PM
-- Module Name: LTA_top - Behavioral
-- Description: 
--   Long term accumulator for the correlator. 
--   Accumulates across multiple fine frequency channels and
--   multiple blocks of 64 time samples.
--   Data is stored in a block of 128 ultraRAM blocks
--   (double buffered) * (256 x 256 stations) * (32 + 32 bits complex) * (2x2 dual-pol correlation products)
--   =    2 *             256*256 *               (4+4)                *  2*2 = 4 Mbytes = 128 ultraRAMs (@ 32k per ultraRAM)
-- 
-- 
-- Useful Definitions/Notation :
--    "cell" : refers to a 16x16 station block of correlations. A stations is dual-pol, so each cell has 1024 visibilities.
--    "visibility" : Single complex value from the correlation array. Output of the correlation array is 3+3 bytes, while the accumulation in this module uses 4+4 byte integers.
--    "tile" : Refers to up a block of up to 16x16 cells, i.e. 256x256 stations
-- 
-- 
----------------------------------------------------------------------------------
library IEEE, common_lib, correlator_lib;
use IEEE.STD_LOGIC_1164.ALL;
USE common_lib.common_pkg.ALL;
use IEEE.NUMERIC_STD.ALL;
Library xpm;
use xpm.vcomponents.all;

entity LTA_top is
    port( 
        i_clk : in std_logic;
        i_rst : in std_logic;  -- resets selection of read and write buffers, should not be needed unless something goes very wrong.
        -- Which buffer is used for read + write ?
        --  i_bufSelect : in std_logic;
        ----------------------------------------------------------------------------------------
        -- Write side interface : 
        i_cell    : in std_logic_vector(7 downto 0); -- 16x16 = 256 possible different cells being accumulated in the ultraRAM buffer at a time.
        i_tile    : in std_logic_vector(9 downto 0); -- tile index, passed to the output.
        i_channel : in std_logic_vector(23 downto 0); -- first fine channel index for this correlation
        i_totalStations : in std_logic_vector(15 downto 0);
        i_subarrayBeam : in std_logic_vector(7 downto 0);
        i_badPoly : in std_logic;
        i_tableSelect : in std_logic;
        i_tileTime : in std_logic_vector(1 downto 0);  -- which 283 ms interval this is for
        -- first time this cell is being written to, so just write, don't accumulate with existing value.
        -- i_tile and i_channel are captured when i_first = '1', i_cellStart = '1' and i_wrCell = 0, 
        i_first   : in std_logic; 
        i_last    : in std_logic; -- This is the last integration for the last cell; after this, the buffers switch and the completed cells are read out.
        i_totalTimes : in std_logic_vector(7 downto 0);    -- Total time samples being integrated, e.g. 192. 
        i_totalChannels : in std_logic_vector(6 downto 0); -- Number of channels integrated, typically 24.
        -- valid goes high for a burst of 64 clocks, to get all the data from the correlation array.
        i_valid   : in std_logic; -- indicates valid data, 6 clocks in advance of i_data_del6. Needed since there is a long latency on the ultraRAM reads.
        -- i_valid can be high continuously, i_cellStart indicates the start of the burst of 64 clocks for a particular cell.
        -- Other control signals 
        i_cellStart : in std_logic; 
        -- 16 parrallel data streams with 3+3 byte visibilities from the correlation array. 
        -- i_data_del6(0) has a 6 cycle latency from the other write input control signals
        -- i_data_del6(k) has a 6+k cycle latency;
        i_data_del6 : in t_slv_48_arr(15 downto 0);
        i_centroid_del6 : in t_slv_24_arr(15 downto 0); -- bits 7:0 = samples accumulated, bis 23:8 = time sample sum.
        o_ready : out std_logic; -- if low, don't start a new frame.
        ----------------------------------------------------------------------------------------
        -- Data output 
        -- 256 bit bus on 300 MHz clock.
        i_axi_clk : in std_logic;
        -- o_data is a burst with 1 cell of data - o_visValid = '1' : 
        --   = (16 stations)*(16 stations)*(8 bytes/value (4+4 complex))* (4 correlations (i.e. 2 pol x 2 stations) e.g. (pol 0 station A) x (pol 0 station B)) = 8192 bytes 
        --   = 256 clocks with 256 bits per clock, for one cell of visibilities.
        -- Then centroid data for that cell - o_TCIvalid = '1' : 
        --   = (16 stations) * (16 stations) * (2 bytes) = 512 bytes = 16 clocks with 256 bits per clock.
        o_data    : out std_logic_vector(255 downto 0);
        o_visValid : out std_logic;                   -- o_data is valid visibility data
        o_TCIvalid : out std_logic;                   -- o_data is valid TCI & DV data
        o_dcount  : out std_logic_vector(7 downto 0); -- counts the 256 transfers for one cell of visibilites, or 16 transfers for the centroid data. 
        o_cell    : out std_logic_vector(7 downto 0);  -- a "cell" is a 16x16 station block of correlations
        o_cellLast : out std_logic;                    -- This is the last cell being written out in this tile
        o_tile    : out std_logic_vector(9 downto 0);  -- a "tile" is a 16x16 block of cells, i.e. a 256x256 station correlation. Copy of i_tile input.
        o_channel : out std_logic_vector(23 downto 0); -- first fine channel index for this correlation.
        o_totalStations : out std_logic_vector(15 downto 0); -- 
        o_subarrayBeam : out std_logic_vector(7 downto 0);
        o_badPoly : out std_logic;
        o_tableSelect : out std_logic;
        o_shortIntegration : out std_logic_vector(2 downto 0);
        -- stop sending data; somewhere downstream there is a FIFO that is almost full.
        -- There can be a lag of about 20 clocks between i_stop going high and data stopping.
        i_stop    : in std_logic 
    );
end LTA_top;

architecture Behavioral of LTA_top is
    
    signal accumulator_rdAddr : std_logic_vector(5 downto 0);
    signal accumulator_cell : std_logic_vector(7 downto 0);
    signal data_del7_re_ext : t_slv_32_arr(15 downto 0);
    signal data_del7_im_ext : t_slv_32_arr(15 downto 0);
    signal accumulator_valid : std_logic;
    signal buf0_used, buf1_used, wrBuffer : std_logic := '0';
    signal accumulator_first,  accumulator_firstDel2 : std_logic := '0';
    signal accumulator_firstDel3, accumulator_firstDel4, accumulator_firstDel5, accumulator_firstDel6 : std_logic := '0';
    signal accumulator_firstDel : std_logic_vector(15 downto 0) := x"0000";
    signal accumulator_wrBuffer : std_logic := '0';
    signal accumulator_last : std_logic := '0';
    signal accumulator_tile : std_logic_vector(9 downto 0);
    signal centroid_del7_samples : t_slv_16_arr(15 downto 0);
    signal centroid_del7_timeSum : t_slv_24_arr(15 downto 0);
    
    signal wrVisibilities : t_slv_64_arr(15 downto 0); 
    signal set_buf0_used, set_buf1_used : std_logic := '0';
    
    signal rd_visibilities : t_slv_64_arr(15 downto 0); -- output for each row; first has 4 cycle latency from i_cell, i_readcount, one extra cycle latency for each of the 16 outputs.
    --signal rd_centroid : t_slv_32_arr(15 downto 0); 
    
    signal rdBuffer : std_logic := '0';
    signal rdCellMax : std_logic_vector(7 downto 0);
    type readout_fsm_type is (idle, run_cell, start_readout, wait_fifo, wait_finished, done_readout);
    signal readout_fsm : readout_fsm_type := idle;
    signal buf0_max_cell, buf1_max_cell : std_logic_Vector(7 downto 0);
    signal buf0_tile, buf1_tile : std_logic_vector(9 downto 0);
    
    signal TCI, DV : std_logic_vector(7 downto 0);

    signal integratedVisibilities : std_logic_vector(255 downto 0);
    signal integratedCentroid : std_logic_vector(39 downto 0);
    signal fifo_din : std_logic_vector(295 downto 0);
    
    signal accumulator_totalTimes, buf0_totalTimes, buf1_totalTimes : std_logic_vector(7 downto 0);
    signal accumulator_totalChannels, buf0_totalChannels, buf1_totalChannels : std_logic_vector(6 downto 0);
    signal accumulator_channel, buf0_channel, buf1_channel : std_logic_vector(23 downto 0);
    
    signal readoutCell, readoutElement : std_logic_vector(7 downto 0);
    signal integratedAddr : std_logic_vector(15 downto 0);
    signal fifo_wr_data_count : std_logic_vector(9 downto 0);
    
    signal rdTile : std_logic_vector(9 downto 0);
    signal rdTotaltimes : std_logic_vector(7 downto 0);
    signal rdTotalChannels : std_logic_vector(6 downto 0);
    signal fifo_dout : std_logic_vector(295 downto 0);
    signal rdChannel : std_logic_vector(23 downto 0);
    
    signal cor_to_axi_send : std_logic := '0';
    signal cor_to_axi_src_rcv : std_logic := '0';
    signal cor_to_axi_din : std_logic_vector(84 downto 0);
    
    signal axi_cellMax : std_logic_vector(7 downto 0);
    signal axi_totalTimes : std_logic_vector(7 downto 0);
    signal axi_channel : std_logic_vector(23 downto 0);
    signal axi_totalChannels : std_logic_vector(6 downto 0);
    signal axi_tile : std_logic_vector(9 downto 0);
    signal cor_to_axi_req : std_logic;
    signal cor_to_axi_dout : std_logic_vector(84 downto 0);
    signal fifo_rd_en : std_logic;
    
    signal visReadoutCount_del : t_slv_8_arr(22 downto 0);
    signal fifo_rd_en_Del : std_logic_vector(22 downto 0);
    signal fifo_empty, fifo_full : std_logic;
    signal fifo_rd_data_count : std_logic_vector(9 downto 0);
    signal fifo_wr_en : std_logic;
    signal integratedReadEnDel : std_logic_vector(20 downto 0);
    signal rst_del1 : std_logic;
    type t_data_deliver_fsm is (idle, send_vis_start, send_vis, send_vis_wait, send_tci, send_tci_wait, end_cell, end_last_cell);
    signal data_deliver_fsm : t_data_deliver_fsm := idle;
    
    signal deliver_totalTimes : std_logic_vector(7 downto 0);
    signal deliver_totalChannels : std_logic_vector(6 downto 0);
    signal TCIReadoutCount : std_logic_vector(3 downto 0);
    signal TCIReadoutCount_del : t_slv_4_arr(17 downto 0);
    signal sendTCI_del : std_logic_vector(19 downto 0);
    signal dv_tci_dout : std_logic_vector(255 downto 0);
    
    signal final_visData : std_logic_vector(255 downto 0);
    signal final_visData_valid : std_logic;
    
    signal cellReadoutCount, visReadoutCount : std_logic_vector(7 downto 0);
    signal axi_meta_valid : std_logic;
    signal deliver_cellMax : std_logic_vector(7 downto 0);
    signal cellReadoutCountDel : t_slv_8_arr(15 downto 0);
    signal deliverTileDel : t_slv_10_Arr(15 downto 0);
    signal deliver_tile : std_logic_vector(9 downto 0);
    signal deliverChannelDel : t_slv_24_arr(15 downto 0); 
    signal deliver_channel : std_logic_vector(23 downto 0);
    signal data_output_count : std_logic_vector(7 downto 0);
    signal outputCountReset : std_logic_vector(15 downto 0);
    signal readoutActive : std_logic := '0';
    signal accumulator_totalStations, buf0_totalStations, buf1_totalStations : std_logic_vector(15 downto 0);
    signal accumulator_subarrayBeam, buf0_subarrayBeam, buf1_subarrayBeam : std_logic_vector(7 downto 0);
    signal accumulator_badPoly, buf0_badPoly, buf1_badPoly : std_logic;
    signal accumulator_tableSelect, buf0_tableSelect, buf1_tableSelect : std_logic;
    signal accumulator_tileTime : std_logic_vector(1 downto 0);
    signal deliver_totalStations, axi_totalStations : std_logic_vector(15 downto 0);
    signal deliver_subarrayBeam, axi_subarrayBeam : std_logic_vector(7 downto 0);
    signal axi_badPoly, axi_tableSelect : std_logic;
    signal deliver_badPoly, deliver_tableSelect : std_logic;
    signal rdtotalStations : std_logic_vector(15 downto 0);
    signal rdsubarrayBeam : std_logic_vector(7 downto 0);
    signal rdBadPoly, rdTableSelect : std_logic;
    signal deliverTotalStationsDel : t_slv_16_arr(15 downto 0);
    signal deliverSubarrayBeamDel : t_slv_8_arr(15 downto 0);
    signal deliverBadPolyDel, deliverTableSelectDel : std_logic_vector(15 downto 0);
    signal cellLastDel : std_logic_vector(15 downto 0);
    signal buf0_inUse, buf1_inUse : std_logic := '0';
    signal end_cell_cnt   : unsigned(1 downto 0);
    signal rd_timeSamples, wr_timeSamples : t_slv_16_arr(15 downto 0);
    signal rd_timeSum, wr_timeSum : t_slv_24_arr(15 downto 0);
    signal deliverShortIntegrationDel : std_logic_vector(15 downto 0);
    signal rdTileTime, buf0_tileTime, buf1_tileTime : std_logic_vector(1 downto 0);
    signal deliver_shortIntegrationCount, axi_tileTime : std_logic_vector(1 downto 0);
    signal deliverShortIntegrationCountDel : t_slv_2_arr(15 downto 0);
    
begin
    
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            rst_del1 <= i_rst;
            if i_rst = '1' then
                wrBuffer <= '0';
                set_buf0_used <= '0';
                set_buf1_used <= '0';
            elsif (accumulator_last = '1' and accumulator_rdAddr = "111111" and accumulator_valid = '1') then
                if wrBuffer = '0' then
                    wrBuffer <= '1';
                    set_buf0_used <= '1';  -- cleared when the buffer has been read out...
                    set_buf1_used <= '0';
                    buf0_max_cell <= accumulator_cell; -- number of cells to read out from the accumulator ultraRAM.
                    buf0_tile <= accumulator_tile;
                    buf0_totalTimes <= accumulator_totalTimes;
                    buf0_totalChannels <= accumulator_totalChannels;
                    buf0_channel <= accumulator_channel;
                    buf0_totalStations <= accumulator_totalStations;
                    buf0_subarrayBeam <= accumulator_subarrayBeam;
                    buf0_badPoly <= accumulator_badPoly;
                    buf0_tableSelect <= accumulator_tableSelect;
                    buf0_tileTime <= accumulator_tileTime;
                else
                    wrBuffer <= '0';
                    set_buf0_used <= '0';
                    set_buf1_used <= '1';
                    buf1_max_cell <= accumulator_cell;
                    buf1_tile <= accumulator_tile;
                    buf1_totalTimes <= accumulator_totalTimes;
                    buf1_totalChannels <= accumulator_totalChannels;
                    buf1_channel <= accumulator_channel;
                    buf1_totalStations <= accumulator_totalStations;
                    buf1_subarrayBeam <= accumulator_subarrayBeam;
                    buf1_badPoly <= accumulator_badPoly;
                    buf1_tableSelect <= accumulator_tableSelect;
                    buf1_tileTime <= accumulator_tileTime;
                end if;
            else
                set_buf0_used <= '0';
                set_buf1_used <= '0';
            end if;
            
            if i_rst = '1' then
                -- bufX_used indicates valid data in the buffer available to be read out
                buf0_used <= '0';
                buf1_used <= '0';
                -- bufX_inUse indicates data has started to be written into the buffer
                buf0_inUse <= '0';
                buf1_inUse <= '0';
            else
                if set_buf0_used = '1' then
                    buf0_used <= '1';
                elsif (readout_fsm = done_readout and rdBuffer = '0') then
                    buf0_used <= '0';
                end if;
                
                if accumulator_valid = '1' and wrBuffer = '0' then
                    buf0_inUse <= '1';
                elsif (readout_fsm = done_readout and rdBuffer = '0') then
                    buf0_inUse <= '0';
                end if;
                
                if set_buf1_used = '1' then
                    buf1_used <= '1';
                elsif (readout_fsm = done_readout and rdBuffer = '1') then
                    buf1_used <= '0';
                end if;
                
                if accumulator_valid = '1' and wrBuffer = '1' then
                    buf1_inUse <= '1';
                elsif (readout_fsm = done_readout and rdBuffer = '1') then
                    buf1_inUse <= '0';
                end if;
                
            end if;
            
            if ((buf0_used = '1' or buf0_inUse = '1') and (buf1_used = '1' or buf1_inUse = '1')) then
                o_ready <= '0';
            else
                o_ready <= '1';
            end if;
            
            if i_valid = '1' then
                if i_cellStart = '1' then
                    accumulator_rdAddr(5 downto 0) <= "000000";
                    accumulator_cell <= i_cell;
                    accumulator_totalTimes <= i_totalTimes;
                    accumulator_totalChannels <= i_totalChannels;
                    accumulator_tile <= i_tile;
                    accumulator_first <= i_first;
                    accumulator_last <= i_last;
                    accumulator_wrBuffer <= wrBuffer;
                    accumulator_channel <= i_channel;
                    accumulator_totalStations <= i_totalStations;
                    accumulator_subarrayBeam <= i_subarrayBeam;
                    accumulator_badPoly <= i_badPoly;
                    accumulator_tableSelect <= i_tableSelect;
                    accumulator_tileTime <= i_tileTime;
                elsif accumulator_valid = '1' then
                    accumulator_rdAddr <= std_logic_vector(unsigned(accumulator_rdAddr) + 1);
                end if;
            end if;
            accumulator_valid <= i_valid;
            
            accumulator_firstDel2 <= accumulator_first;
            accumulator_firstDel3 <= accumulator_firstDel2;
            accumulator_firstDel4 <= accumulator_firstDel3;
            accumulator_firstDel5 <= accumulator_firstDel4;
            accumulator_firstDel6 <= accumulator_firstDel5;
            accumulator_firstDel(0) <= accumulator_firstDel6;
            
            accumulator_firstDel(15 downto 1) <= accumulator_firstDel(14 downto 0);  -- each row is an extra clock behind in the data from the ultrams and from the correlator array.
            
            for i in 0 to 15 loop
                data_del7_re_ext(i) <= std_logic_vector(resize(signed(i_data_del6(i)(23 downto 0)),32));
                data_del7_im_ext(i) <= std_logic_vector(resize(signed(i_data_del6(i)(47 downto 24)),32));
                centroid_del7_samples(i) <= std_logic_vector(resize(unsigned(i_centroid_del6(i)(7 downto 0)),16));
                centroid_del7_timeSum(i) <= std_logic_vector(resize(unsigned(i_centroid_del6(i)(23 downto 8)),24));
                if accumulator_firstDel(i) = '1' then
                    wrVisibilities(i)(31 downto 0) <= data_del7_re_ext(i);
                    wrVisibilities(i)(63 downto 32) <= data_del7_im_ext(i);
                    wr_timeSamples(i) <= centroid_del7_samples(i);
                    wr_timeSum(i) <= centroid_del7_timeSum(i);
                else
                    wrVisibilities(i)(31 downto 0) <= std_logic_vector(unsigned(data_del7_re_ext(i)) + unsigned(rd_visibilities(i)(31 downto 0)));
                    wrVisibilities(i)(63 downto 32) <= std_logic_vector(unsigned(data_del7_im_ext(i)) + unsigned(rd_visibilities(i)(63 downto 32)));
                    wr_timeSamples(i) <= std_logic_vector(unsigned(centroid_del7_samples(i)) + unsigned(rd_timeSamples(i))); -- 16 bit sum
                    wr_timeSum(i) <= std_logic_vector(unsigned(centroid_del7_timeSum(i)) + unsigned(rd_timeSum(i)));   -- 24 bit sum
                end if;
            end loop;
            
            --------------------------------------------------------------------------------------
            -- Control readout of the ultraRAM buffer.
            -- Read from ultraRAM buffer, write into the fifo to cross to the axi clock domain and output.
            
            case readout_fsm is
                when idle => 
                    if buf0_used = '1' then
                        rdBuffer <= '0';
                        rdCellMax <= buf0_max_cell;
                        rdTile <= buf0_tile;
                        rdTotaltimes <= buf0_totalTimes;
                        rdTotalChannels <= buf0_totalChannels;
                        rdChannel <= buf0_channel;
                        rdtotalStations <= buf0_totalStations;
                        rdsubarrayBeam <= buf0_subarrayBeam;
                        rdBadPoly <= buf0_badPoly;
                        rdTableSelect <= buf0_tableSelect;
                        rdTileTime <= buf0_tileTime;
                        readout_fsm <= start_readout;
                    elsif buf1_used = '1' then
                        rdBuffer <= '1';
                        rdCellMax <= buf1_max_cell;
                        rdTile <= buf1_tile;
                        rdTotaltimes <= buf1_totalTimes;
                        rdTotalChannels <= buf1_totalChannels;
                        rdChannel <= buf1_channel;
                        rdtotalStations <= buf1_totalStations;
                        rdsubarrayBeam <= buf1_subarrayBeam;
                        rdBadPoly <= buf1_badPoly;
                        rdTableSelect <= buf1_tableSelect;
                        rdTileTime <= buf1_tileTime;
                        readout_fsm <= start_readout;
                    end if;
                    readoutCell <= (others => '0');
                    readoutElement <= (others => '0'); -- 256 elements (i.e. baselines, station pairs) within each cell.
                    
                when start_readout =>
                    readout_fsm <= wait_fifo;
                
                when run_cell => 
                    -- read out a whole cell from the ultraRAM to the FIFO.
                    -- 256 words 
                    --   If the cell is a triangle, then only 136 words have valid data, but we output all 256 anyway; 
                    --   Otherwise the addressing in HBM gets messy. Extra correlations are dumped when read out from the HBM to send to SDP.
                    readoutElement <= std_logic_vector(unsigned(readoutElement) + 1);
                    if (unsigned(readoutElement) = 255) then
                        readoutCell <= std_logic_vector(unsigned(readoutCell) + 1);
                        if (readoutCell = rdCellMax) then
                            readout_fsm <= wait_finished;
                        else
                            readout_fsm <= wait_fifo;
                        end if;
                    end if;
                
                when wait_fifo =>
                    -- fifo has space for 512 words, each 288 bits wide.
                    -- There are 256 words per cell. (256 * 32 bytes = 8192 bytes = 32 rows * 32 cols * (4+4) bytes
                    -- Writes to the FIFO are a whole cell, i.e. blocks of 256 words, so we have to make sure there is enough space in the
                    -- FIFO before starting to read a new cell. The read latency from the ultraRAMs is 20 clocks, so need to take this into 
                    -- account in setting the threshold here.
                    -- Need : space for a whole cell (256 words) + ultraRAM read latency (20 words) + time to update fifo_wr_data_count (4 words) + safety (8 words)) = 
                    if (unsigned(fifo_wr_data_count) < 224) then
                        readout_fsm <= run_cell;
                    end if;
                    
                when wait_finished =>
                    -- wait until all the data has finished being read out of the ultraRAMs.
                    if (unsigned(fifo_wr_data_count) = 0) then 
                        readout_fsm <= done_readout;
                    end if;
                    
                when done_readout =>
                    readout_fsm <= idle;         
            
                when others =>
                    readout_fsm <= idle;
            
            end case;
            
            if (readout_fsm = run_cell) then
                integratedReadEnDel(0) <= '1';
            else
                integratedReadEnDel(0) <= '0';
            end if; 
            integratedReadEnDel(20 downto 1) <= integratedReadEndel(19 downto 0);
            
            -- CDC to get cell, tile, channel, Ntimes, Nchannels to the axi clock domain.
            if readout_fsm = start_readout then
                cor_to_axi_send <= '1';
            elsif (cor_to_axi_src_rcv = '1') then
                cor_to_axi_send <= '0';
            end if;
            cor_to_axi_din(7 downto 0) <= rdCellMax; -- 8 bit  
            cor_to_axi_din(15 downto 8) <= rdTotaltimes; -- 8 bit
            cor_to_axi_din(39 downto 16) <= rdChannel;   -- 24 bits; first channel in the integration
            cor_to_axi_din(46 downto 40) <= rdTotalChannels; -- 7 bit
            cor_to_axi_din(56 downto 47) <= rdTile;    -- 10 bit
            cor_to_axi_din(72 downto 57) <= rdTotalStations;
            cor_to_axi_din(80 downto 73) <= rdsubarrayBeam;
            cor_to_axi_din(81) <= rdBadPoly;
            cor_to_axi_din(82) <= rdTableSelect;
            cor_to_axi_din(84 downto 83) <= rdTileTime;
            if readout_fsm = idle then
                readoutActive <= '0';
            else
                readoutActive <= '1';
            end if;
            
        end if;
    end process;
    
    integratedAddr <= readoutCell & readoutElement;
    
    
    LTAi : entity correlator_lib.LTA_urams
    port map ( 
        i_clk      => i_clk,
        i_wrBuffer => accumulator_wrBuffer, --  in std_logic; -- selects which buffer is used for accumulation (and thus which buffer is used for readout).
        ----------------------------------------------------------------------------------------
        -- read-modify-write interface for the accumulator functionality: 
        -- read address
        i_cell      => accumulator_cell,   -- in (7:0);  16x16 = 256 possible different cells being accumulated in the ultraRAM buffer at a time.
        i_readCount => accumulator_rdAddr, -- in (5:0);  64 different visibilities per row of the correlation matrix. 
        i_valid     => accumulator_valid,  -- in std_logic; i_cell and i_readCount are valid.
        -- Read data --------------------------------
        --  Output for each row; first has 6 cycle latency from i_cell, i_readcount, one extra cycle latency for each of the 16 outputs.
        o_AccumVisibilties => rd_visibilities, --  out t_slv_64_arr(15:0); 
        --  Constant for 4 clocks at a time, since the centroid data is the same for all combinations of polarisations.
        -- Number of samples accumulated can be up to (192 time samples) * (127 frequency channels) = 24384 (15 bits minimum)
        -- Time sum can be up to sum(0:191) * (127 frequency channels) = 2328672 (22 bits minimum)
        o_AccumTimeSamples => rd_timeSamples, -- out t_slv_16_arr(15 downto 0);
        o_AccumTimeSum     => rd_timeSum,     -- out t_slv_24_arr(15 downto 0);
        -- Write data --------------------------------
        --  Must be valid 2 clocks after o_AccumVisibilities, o_AccumCentroid.
        i_wrVisibilities => wrVisibilities, -- in t_slv_64_arr(15 downto 0);
        --  Should be valid for the 4 consecutive clocks where i_wrVisibilities is for the same station pair 
        i_wrTimeSamples => wr_timeSamples,  -- in t_slv_16_arr(15:0);
        i_wrTimeSum     => wr_timeSum,      -- in t_slv_24_arr(15:0);
        ----------------------------------------------------------------------------------------
        -- Data output 
        -- 256 bit bus for visibilities, 16 bit bus for centroid data.
        i_readoutAddr         => integratedAddr,  -- in (15:0); bits 3:0 = cell row, bits 7:4 = cell column, bits 15:8 = cell.
        i_readoutActive       => readoutActive,   -- in std_logic;
        i_readoutBuffer       => rdBuffer,        -- in std_logic;
        o_readoutVisibilities => integratedVisibilities, -- out (255:0); -- 21 clock latency from i_readoutAddr to the data.
        o_readoutCentroid     => integratedCentroid      -- out (39:0); bits 39:16 = time sum, bit 15:0 = time samples
    );
    
    fifo_din(255 downto 0) <= integratedVisibilities;
    fifo_din(295 downto 256) <= integratedCentroid;
    fifo_wr_en <= integratedReadEnDel(20);
    
    -- FIFO to cross to the axi clock domain.
    xpm_fifo_async_inst : xpm_fifo_async
    generic map (
        CASCADE_HEIGHT => 0,        -- DECIMAL
        CDC_SYNC_STAGES => 2,       -- DECIMAL
        DOUT_RESET_VALUE => "0",    -- String
        ECC_MODE => "no_ecc",       -- String
        FIFO_MEMORY_TYPE => "auto", -- String
        FIFO_READ_LATENCY => 1,     -- DECIMAL
        FIFO_WRITE_DEPTH => 512,    -- DECIMAL
        FULL_RESET_VALUE => 0,      -- DECIMAL
        PROG_EMPTY_THRESH => 10,    -- DECIMAL
        PROG_FULL_THRESH => 10,     -- DECIMAL
        RD_DATA_COUNT_WIDTH => 10,  -- DECIMAL
        READ_DATA_WIDTH => 296,     -- DECIMAL
        READ_MODE => "std",         -- String
        RELATED_CLOCKS => 0,        -- DECIMAL
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "0404", -- String
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 296,    -- DECIMAL
        WR_DATA_COUNT_WIDTH => 10   -- DECIMAL
    ) port map (
        almost_empty => open,     -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
        almost_full => open,      -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
        data_valid => open,       -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
        dbiterr => open,          -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
        dout => fifo_dout,        -- READ_DATA_WIDTH-bit output: Read Data: The output data bus is driven when reading the FIFO.
        empty => fifo_empty,      -- 1-bit output: Empty Flag: When asserted, this signal indicates that the FIFO is empty.
        full => fifo_full,        -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full. 
        overflow => open,         -- 1-bit output: Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected, because the FIFO is full. 
        prog_empty => open,       -- 1-bit output: Programmable Empty:
        prog_full => open,         -- 1-bit output: Programmable Full:
        rd_data_count => fifo_rd_data_count, -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
        rd_rst_busy => open,      -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
        sbiterr => open,          -- 1-bit output: Single Bit Error: Indicates that the ECC decoder detected and fixed a single-bit error.
        underflow => open,        -- 1-bit output: Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected because the FIFO is empty.
        wr_ack => open,           -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.
        wr_data_count => fifo_wr_data_count, -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        wr_rst_busy => open,      -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
        din => fifo_din,          -- WRITE_DATA_WIDTH-bit input: Write Data: The input data bus used when writing the FIFO.
        injectdbiterr => '0',     -- 1-bit input: Double Bit Error Injection: Injects a double bit error if the ECC feature is used on block RAMs or UltraRAM macros.
        injectsbiterr => '0',     -- 1-bit input: Single Bit Error Injection: Injects a single bit error if the ECC feature is used on block RAMs or UltraRAM macros.
        rd_clk => i_axi_clk,      -- 1-bit input: Read clock: Used for read operation. rd_clk must be a free running clock.
        rd_en => fifo_rd_en,      -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO. Must be held active-low when rd_rst_busy is active high.
        rst => rst_del1,          -- 1-bit input: Reset: Must be synchronous to wr_clk. The clock(s) can be unstable at the time of applying reset, but reset must be released only after the clock(s) is/are stable.
        sleep => '0',             -- 1-bit input: Dynamic power saving: If sleep is High, the memory/fifo block is in power saving mode.
        wr_clk => i_clk,          -- 1-bit input: Write clock: Used for write operation.
        wr_en => fifo_wr_en       -- 1-bit input: Write Enable: If the FIFO is not full, asserting this signal causes data (on din) to be written to the FIFO. Must be held active-low when rst or wr_rst_busy is active high.
    );
    
    fifo_rd_en <= '1' when data_deliver_fsm = send_vis else '0';
    
    
    -- As data is read out of the fifo, the centroid data is converted to 8 bit DV and 8 bit TCI format
    -- 19 clock latency
    centroid_divi : entity correlator_lib.centroid_divider
    port map (
        i_clk => i_axi_clk, -- in std_logic;
        -- data input
        i_timeSum  => fifo_dout(39+256 downto 16+256), -- in (23:0);
        i_Nsamples => fifo_dout(15+256 downto 0+256),  -- in (15:0);
        -- semi-static inputs
        i_totalTimes    => deliver_totalTimes,    -- in (7:0); -- Total time samples being integrated, e.g. 192. 
        i_totalChannels => deliver_totalChannels, -- in (6:0); -- Number of channels integrated, typically 24.
        -- Outputs,  21 clock latency.
        o_centroid => TCI, -- out (7:0);  -- also known as "TCI" = time centroid interval in the CBF->SDP ICD
        o_weight   => DV   -- out (7:0)   -- also known as "DV" = data valid in the CBF->SDP ICD
    );    
    
    -- Memory to hold the DV and TCI values for a cell.
    -- 512 bytes per cell.
    -- Write side is 16 bits wide x 256 deep.
    -- Read side needs to be 256 bits wide x 16 deep.
    -- Only needs a single buffer, since we read it all out as soon as a full cell is processed, before moving on to the next cell.
    tcii : entity correlator_lib.dv_tci_mem
    port map (
        i_clk => i_axi_clk, -- in std_logic;
        -- data input
        i_DV  => DV,        -- in (7:0);
        i_TCI => TCI,       -- in (7:0);
        i_wrEn => fifo_rd_en_del(22),   -- in std_logic;
        i_wrAddr => visReadoutCount_del(22), -- in (7:0); 256 elements in a correlation cell
        -- data output, 2 cycle latency.
        i_rdAddr => TCIReadoutCount_del(17), -- in (3:0); Using del(17) here to match the delay for the visibility data, so that dv_tci_dout comes directly after final_visData
        o_dout   => dv_tci_dout  -- out (255:0)
    );
    
    
    -- Readout : 
    -- Full cell : 
    --  visibilities    = 256 * 32 bytes = 8192 bytes.
    --  centroid+weight = 256*2 = 512 bytes.
    --  total = 8704 bytes = 272 x (32 byte words) = 136 x (64-byte words)
    -- We always write full cells to the HBM at the output.
    -- The extra correlations for the triangle cells are dropped on readout from the HBM.
    -- This means that all reads and writes to the HBM can be in blocks of at least 512 bytes, and are all 512 byte aligned.
    vis2fpi : entity correlator_lib.vis2fp
    port map (
        i_clk => i_axi_clk, --  in std_logic;
        -- data input
        i_valid        => fifo_rd_en_del(1), -- in std_logic;
        i_vis          => fifo_dout(255 downto 0),      -- in (255:0);
        i_validSamples => fifo_dout(15+256 downto 256), -- in (15:0);
        i_Ntimes       => axi_totalTimes,    -- in (7:0);
        i_Nchannels    => axi_totalChannels, -- in (6:0);
        -- Data output, 16 clock latency
        o_vis   => final_visData, -- out (255:0);
        o_valid => final_visData_valid  -- out std_logic; 16 clock latency.
    );
    
    -- CDC to get cell, tile, channel, Ntimes, Nchannels to the axi clock domain.
    -- This also triggers readout of the FIFO for the whole tile.
    -- The state machine that copies from the ultrarams to the FIFO always waits 
    -- until the FIFO is empty before starting to dump the next tile.
    xpm_cdc_handshake_inst : xpm_cdc_handshake
    generic map (
        DEST_EXT_HSK => 0,   -- DECIMAL; 0=internal handshake, 1=external handshake
        DEST_SYNC_FF => 3,   -- DECIMAL; range: 2-10
        INIT_SYNC_FF => 1,   -- DECIMAL; 0=disable simulation init values, 1=enable simulation init values
        SIM_ASSERT_CHK => 0, -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        SRC_SYNC_FF => 3,    -- DECIMAL; range: 2-10
        WIDTH => 85          -- DECIMAL; range: 1-1024
    ) port map (
        dest_out => cor_to_axi_dout,   -- WIDTH-bit output: Input bus (src_in) synchronized to destination clock domain. This output is registered.
        dest_req => cor_to_axi_req,    -- 1-bit output: Assertion of this signal indicates that new dest_out data has been received and is ready to be used or captured by the destination logic. 
        src_rcv => cor_to_axi_src_rcv, -- 1-bit output: Acknowledgement from destination logic that src_in has been received. 
        dest_ack => '1',          -- 1-bit input: optional; required when DEST_EXT_HSK = 1
        dest_clk => i_axi_clk,         -- 1-bit input: Destination clock.
        src_clk => i_clk,              -- 1-bit input: Source clock.
        src_in => cor_to_axi_din,      -- WIDTH-bit input: Input bus that will be synchronized to the destination clock domain.
        src_send => cor_to_axi_send    -- 1-bit input: Assertion of this signal allows the src_in bus to be synchronized to the destination clock domain. 
    );
    
    
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            -- fsm to read a cell from the FIFO, then read the dv & tci data.
            if (cor_to_axi_req = '1') then
                axi_cellMax <= cor_to_axi_dout(7 downto 0);   -- count of cells to be read out, minus 1.
                axi_totalTimes <= cor_to_axi_dout(15 downto 8); -- number of time samples in the integrations
                axi_channel <= cor_to_axi_dout(39 downto 16);  -- start channel for the integration
                axi_totalChannels <= cor_to_axi_dout(46 downto 40); -- number of channels integrated.
                axi_tile <= cor_to_axi_dout(56 downto 47);          -- index of the tile being read out.
                axi_totalStations <= cor_to_axi_dout(72 downto 57);
                axi_subarrayBeam <= cor_to_axi_dout(80 downto 73);
                axi_badPoly <= cor_to_axi_dout(81);
                axi_tableSelect <= cor_to_axi_dout(82);
                axi_tileTime <= cor_to_axi_dout(84 downto 83);
                axi_meta_valid <= '1';
            elsif data_deliver_fsm = idle then
                axi_meta_valid <= '0';
            end if;
            
            case data_deliver_fsm is
                when idle => 
                    if axi_meta_valid = '1' then
                        data_deliver_fsm <= send_vis_start;
                        deliver_cellMax <= axi_cellMax;
                        deliver_totalTimes <= axi_totalTimes;
                        deliver_channel <= axi_channel;
                        deliver_totalChannels <= axi_totalChannels;
                        deliver_tile <= axi_tile;
                        deliver_totalStations <= axi_totalStations;
                        deliver_subarrayBeam <= axi_subarrayBeam;
                        deliver_badPoly <= axi_badPoly;
                        deliver_tableSelect <= axi_tableSelect;
                        deliver_shortIntegrationCount <= axi_tileTime;
                    end if;
                    cellReadoutCount <= (others => '0'); -- which cell in the tile are we up to ? (0 to axi_cellMax)
                    visReadoutCount <= (others => '0'); -- which visibility in the cell are we up to  (0 to 255 for every cell)
                    TCIReadoutCount <= (others => '0'); -- DV/TCI word. read out words are 256 bits wide, with 16 read out in a burst (16 words * 32 bytes = 1 cell = (1 DV + 1 TCI) * 16 * 16 stations = 512 bytes)
                    end_cell_cnt    <= "00";
                    
                when send_vis_start =>
                    -- check there is data in the FIFO to send.
                    -- Once there is data in the FIFO to send, there should be 256 words to send, because data is 
                    -- written into the FIFO on the correlator clock, which is faster than the axi clock that is used to 
                    -- read it out.
                    if (unsigned(fifo_rd_data_count) > 3) then
                        data_deliver_fsm <= send_vis;
                    end if;
                    visReadoutCount <= (others => '0');
                    
                when send_vis => 
                    visReadoutCount <= std_logic_vector(unsigned(visReadoutCount) + 1);
                    if (unsigned(visReadoutCount) = 255) then
                        data_deliver_fsm <= send_tci_wait;
                    else
                        if i_stop = '1' then
                            data_deliver_fsm <= send_vis_wait;
                        end if;
                    end if;
                    TCIReadoutCount <= (others => '0');
                
                when send_vis_wait => 
                    if i_stop = '0' then
                        data_deliver_fsm <= send_vis;
                    end if;
                
                when send_tci => 
                    -- Actual TCI/DV data comes out ~18 clocks after this, to match the delay on the visibility data through the floating point + scaling module.
                    TCIReadoutCount <= std_logic_vector(unsigned(TCIReadoutCount) + 1);
                    if (unsigned(TCIReadoutCount) = 15) then
                        cellReadoutCount <= std_logic_vector(unsigned(cellReadoutCount) + 1);
                        if (cellReadoutCount = deliver_cellMax) then
                            data_deliver_fsm <= end_last_cell;
                        else
                            data_deliver_fsm <= end_cell;
                        end if;
                    else
                        if i_stop = '1' then
                            data_deliver_fsm <= send_tci_wait;
                        end if;
                    end if;
                    
                when end_cell =>
                    if end_cell_cnt = 2 then
                        data_deliver_fsm <= send_vis_start;
                        end_cell_cnt     <= "00";
                    else
                        end_cell_cnt     <= end_cell_cnt + 1;
                    end if;
                
                when end_last_cell =>
                    -- This state provides one extra clock of idle time prior to processing the 
                    -- next "axi_meta_valid". This is needed to finish sending tci data for the 
                    -- case where axi_meta_valid is already high.
                    data_deliver_fsm <= idle;
                
                when send_tci_wait =>
                    if i_stop = '0' then
                        data_deliver_fsm <= send_tci;
                    end if;
                   
                when others => 
                    data_deliver_fsm <= idle;    
                
            end case;
            
            -- 
            if (final_visData_Valid = '1') then
                o_data <= final_visData;
                o_visValid <= '1';
                o_TCIvalid <= '0';
                
                o_cell <= cellReadoutCountDel(15);
                o_cellLast <= cellLastDel(15);
                o_tile <= deliverTileDel(15);
                o_channel <= deliverChannelDel(15);
                o_totalStations <= delivertotalStationsDel(15);
                o_subarrayBeam <= deliverSubarrayBeamDel(15);
                o_badPoly <= deliverBadPolyDel(15);
                o_tableSelect <= deliverTableSelectDel(15);
                -- 3 bits, top bit = '1' for 283ms integrations, '0' for 849ms integrations
                -- Low 2 bits = which 283ms integration ? "00", "01" or "10"
                o_shortIntegration <= deliverShortIntegrationDel(15) & deliverShortIntegrationCountDel(15);
            else
                o_data <= dv_tci_dout;
                o_visValid <= '0';
                if (sendTCI_del(19) = '1') then
                    o_TCIvalid <= '1';
                else
                    o_TCIvalid <= '0';
                end if;
            end if;
            
            if (outputCountReset(15) = '1') then
                data_output_count <= (others => '0');
            elsif ((final_visData_Valid = '1') or (sendTCI_del(19) = '1')) then
                data_output_count <= std_logic_vector(unsigned(data_output_count) + 1);
            end if;
            o_dCount <= data_output_count;
            
            if (data_deliver_fsm = send_vis_start) then
                outputCountReset(0) <= '1';
            else
                outputCountReset(0) <= '0';
            end if;
            outputCountReset(15 downto 1) <= outputCountReset(14 downto 0);
            
            cellReadoutCountDel(0) <= cellReadoutCount;
            if (cellReadoutCount = deliver_cellMax) then
                cellLastDel(0) <= '1';
            else
                cellLastDel(0) <= '0';
            end if;
            
            cellReadoutCountDel(15 downto 1) <= cellReadoutCountDel(14 downto 0);
            cellLastDel(15 downto 1) <= cellLastDel(14 downto 0);
            deliverTileDel(0) <= deliver_tile;
            deliverTileDel(15 downto 1) <= deliverTileDel(14 downto 0);
            deliverChannelDel(0) <= deliver_channel;
            deliverChannelDel(15 downto 1) <= deliverChannelDel(14 downto 0);
            
            deliverTotalStationsDel(0) <= deliver_totalStations;
            deliverTotalStationsDel(15 downto 1) <= deliverTotalStationsDel(14 downto 0);
            deliverSubarrayBeamDel(0) <= deliver_subarrayBeam;
            deliverSubarrayBeamDel(15 downto 1) <= deliverSubarrayBeamDel(14 downto 0);
            
            deliverBadPolyDel(0) <= deliver_BadPoly;
            deliverBadPolyDel(15 downto 1) <= deliverBadPolyDel(14 downto 0);
            
            delivertableSelectDel(0) <= deliver_tableSelect;
            delivertableSelectDel(15 downto 1) <= deliverTableSelectDel(14 downto 0);
            
            deliverShortIntegrationCountDel(0) <= deliver_ShortIntegrationCount;
            deliverShortIntegrationCountDel(15 downto 1) <= deliverShortIntegrationCountDel(14 downto 0);
            
            if unsigned(deliver_totalTimes) = 192 then
                deliverShortIntegrationDel(0) <= '0'; -- 192 time samples, not a short integration
            else
                deliverShortIntegrationDel(0) <= '1'; -- This is a short integration (64 time samples)
            end if;
            deliverShortIntegrationDel(15 downto 1) <= deliverShortIntegrationDel(14 downto 0);
            
            -- 18 clocks from fifo_rd_en(0) to 
            fifo_rd_en_del(22 downto 1) <= fifo_rd_en_del(21 downto 0);
            sendTCI_del(19 downto 1) <= sendTCI_del(18 downto 0);
            
            visReadoutCount_del(22 downto 1) <= visReadoutCount_del(21 downto 0);
            TCIReadoutCount_del(17 downto 1) <= TCIReadoutCount_del(16 downto 0);
        end if;
    end process;
    
    fifo_rd_en_del(0) <= fifo_rd_en;
    visReadoutCount_del(0) <= visReadoutCount;
    TCIReadoutCount_del(0) <= TCIReadoutCount;
    sendTCI_del(0) <= '1' when data_deliver_fsm = send_tci else '0';
    
end Behavioral;
