----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 08/30/2022 03:38:16 PM
-- Module Name: correlator_HBM - Behavioral
-- Description: 
--  (1) Write data from the long term accumulator into the HBM.
--  (2) Read data out of the HBM and create packets to send to SDP.
--
--
-- Data in HBM :
--  A cell is 16x16 dual-pol stations :
--   - 32x32 visibilities = 1024 visibilities @ 4+4 bytes each = 8192 bytes
--     Delivered to this module as 256 transfers of 256 bits each.
--   - TCI data : 256 x 2 bytes = 512 bytes, delivered as 16 transfers of 256 bits.
--  A tile is up to 16x16 cells.
--   - 256 cells = 256 * 8192 bytes = 2 MBytes for visibilities
--               = 256 * 512 bytes = 128 kBytes for TCI data.
-- 
-- Data can be forwarded once we have a full row of tiles for a particular correlation.
-- The maximum number of tiles in a row is 16 (16 x 256 stations = a strip with 4096 stations)
-- 
-- The HBM is treated as a circular buffer, with cells written sequentially into the buffer.
-- First 256 MBytes is used for visibilities circular buffer, then 16 Mbytes for the TCI data.
--  256 MBytes / (8192 bytes/cell) = 32768 cells to fill the circular buffer.
--  
--
--
--
-- Data output 
--  Data words are constructed with :
--      1 sample  = 8  single precision values (4 complex values) - all correlations between two dual-pol stations.
--                  +2 bytes of TCI (time centroid) and FD (fraction of data)
--                = 34 bytes.
--  The output bus is 32 bytes wide, so for simplicity the default packet size is a multiple of 16 samples
--  (since 16 * 34 bytes = 544 bytes = 17 x 32 byte words)
--  The final packet for a particular subarray will typically have less samples than the other packets, 
--  since subarray can be of arbitrary size.
--  Default output packet size is :
--    
--  
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
Library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;
Library xpm;
use xpm.vcomponents.all;

entity correlator_HBM is
    generic (
        -- Number of samples in most packets. Each sample is 34 bytes of data. 
        -- The last packet in a subarray will typically have less samples, since a given subarray 
        -- does not have any particular total length.
        g_PACKET_SAMPLES_DIV16 : integer  -- actual number of samples in the packet is this value x16  
    ); 
    Port ( 
        i_axi_clk : in std_logic;
        i_axi_rst : in std_logic;
        ----------------------------------------------------------------------------------------
        -- Data in from the long term accumulator
        -- Each cell is sent as 256 clocks of data with i_visValid = '1', then 16 clocks of data with i_TCIvalid = '1'.
        i_data      : in std_logic_vector(255 downto 0);
        i_visValid  : in std_logic;                     -- o_data is valid visibility data
        i_TCIvalid  : in std_logic;                     -- o_data is valid TCI & DV data
        i_dcount    : in std_logic_vector(7 downto 0);  -- counts the 256 transfers for one cell of visibilites, or 16 transfers for the centroid data. 
        i_cell      : in std_logic_vector(7 downto 0);  -- a "cell" is a 16x16 station block of correlations
        i_cellLast  : in std_logic;                     -- Last cell for this tile.
        -- a "tile" is a 16x16 block of cells, i.e. a 256x256 station correlation.
        -- bits 3:0 = tile column, bits 7:4 = tile row, bits 9:8 = "00";
        i_tile      : in std_logic_vector(9 downto 0);  
        i_channel   : in std_logic_vector(23 downto 0); -- first fine channel index for this correlation.
        i_totalStations : in std_logic_vector(15 downto 0); -- total number of stations in this subarray-beam
        i_subarrayBeam : in std_logic_vector(7 downto 0);   -- Index into the subarray-beam table.
        i_badPoly : in std_logic;
        -- stop sending data; somewhere downstream there is a FIFO that is almost full.
        -- There can be a lag of about 20 clocks between o_stop going high and data stopping.
        o_stop      : out std_logic;
        
        -----------------------------------------------------------------------------------------
        -- Status info
        o_HBM_end   : out std_logic_vector(31 downto 0); -- byte address offset into the HBM buffer where the visibility circular buffer ends.
        o_errors    : out std_logic_vector(3 downto 0); -- bit 0 = aw fifo full; this should never happen.
        -----------------------------------------------------------------------------------------
        -- Readout bus "ro"
        -- Notifies the SPEAD packet generation module that data is available in the HBM to be read out.
        -- This bus is on the i_axi_clk domain (i.e. same clock as the HBM interface).
        
        -- Byte address in HBM of the start of a strip from the visibility matrix.
        -- Start address of the meta data is at (o_HBM_start_addr/16 + 256 Mbytes)
        o_ro_HBM_start_addr : out std_logic_vector(31 downto 0);
        -- Index of the subarray-beam,
        -- This is the address into the table in the second corner turn. Valid range is 0 up.
        o_ro_subarray : out std_logic_vector(7 downto 0);
        -- output frequency index. Count of the frequency channels being generated
        -- by the correlator. Counts from 0.
        o_ro_freq_index : out std_logic_vector(16 downto 0);
        -- Some kind of timestamp. Will be the same for all subarrays within a single 849 ms 
        -- integration time.
        o_ro_time_ref : out std_logic_vector(63 downto 0);
        -- The first of the block of rows in the visibility matrix that is now available for readout.
        -- Counts from 0. 
        -- The number of columns to read out for the first row will be (o_row + 1).
        -- The number of columns to read out for the last row in this strip will be (o_row + o_row_count)
        o_ro_row : out std_logic_vector(12 downto 0);
        -- The number of rows to read out. Valid range is 1 up to 256.
        o_ro_row_count : out std_logic_vector(8 downto 0);
        -- bad poly indicates that some or all of the data used did not have a valid delay polynomial.
        o_ro_bad_poly : out std_logic;
        -- valid indicates that the other signals are valid. 
        -- valid will pulse high for 1 clock cycle when a strip of data from the visibility matrix is available.
        o_ro_valid : out std_logic;
        -----------------------------------------------------------------------------------------
        -- HBM interface
        -- Write to HBM
        o_axi_aw      : out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_axi_awready : in  std_logic;
        o_axi_w       : out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_axi_wready  : in  std_logic;
        i_axi_b       : in  t_axi4_full_b -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
    );
end correlator_HBM;

architecture Behavioral of correlator_HBM is

    signal visValidDel1, visValidDel2 : std_logic;
    
    signal fifo_wr_ptr, start_of_row_ptr : std_logic_vector(14 downto 0) := (others => '0'); -- 256 MBytes = 32768 blocks of 8192 bytes;
    signal aw_fifo_we : std_logic;
    signal aw_fifo_din : std_logic_vector(39 downto 0);
    signal set_aw : std_logic;
    type aw_fsm_type is (idle, vis_addr1, vis_addr2, TCI_addr);
    signal set_aw_fsm : aw_fsm_type := idle;
    signal cellDel1, curCell : std_logic_vector(7 downto 0);
    signal tileDel1, curTile : std_logic_vector(9 downto 0);
    signal channelDel1, curChannel : std_logic_vector(23 downto 0);
    signal aw_fifo_dout_valid : std_logic;
    signal aw_fifo_dout : std_logic_vector(39 downto 0);
    signal errors_int : std_logic_vector(3 downto 0);
    signal aw_fifo_full : std_logic;
    signal w_fifo_dout_valid : std_logic;
    signal w_fifo_dout : std_logic_vector(513 downto 0);
    signal w_fifo_din : std_logic_vector(513 downto 0);
    signal w_fifo_we : std_logic;
    signal w_fifo_count : std_logic_vector(9 downto 0);
    signal w_fifo_full : std_logic;
    signal dcountDel1 : std_logic_vector(7 downto 0);
    signal subarrayBeamDel1 : std_logic_vector(7 downto 0);
    signal badPolyDel1 : std_logic;
    signal lastStationDel1 : std_logic_vector(15 downto 0);
    signal cellLastDel1 : std_logic;
    
    signal SPEAD_trigger_we : std_logic;
    signal SPEAD_trigger_din, SPEAD_trigger_dout : std_logic_vector(55 downto 0);
    signal SPEAD_trigger_rd_Del1, SPEAD_trigger_rd, SPEAD_trigger_full, SPEAD_trigger_empty : std_logic;
    signal ro_rows_minus1 : std_logic_vector(8 downto 0);
    
begin
    
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            visValidDel1 <= i_visValid;
            dcountDel1 <= i_dcount;
            cellDel1 <= i_cell;
            cellLastDel1 <= i_cellLast;
            tileDel1 <= i_tile;
            channelDel1 <= i_channel;
            subarrayBeamDel1 <= i_subarrayBeam;
            badPolyDel1 <= i_badPoly;
            lastStationDel1 <= std_logic_vector(unsigned(i_totalStations) - 1);
            
            o_HBM_end <= "0000" & fifo_wr_ptr & "0000000000000";
            
            if i_dcount(0) = '0' then
                w_fifo_din(255 downto 0) <= i_data;
            else
                w_fifo_din(511 downto 256) <= i_data;
            end if;
            if ((i_visValid = '1' and i_dcount(6 downto 0) = "1111111") or (i_TCIvalid = '1' and i_dcount = "00001111")) then
                -- indicates last word in a HBM data transfer.
                -- Occurs twice in the 256 transfers for the data, at i_dcount = x7F and i_dcount = xFF, and once at the end of the TCI data, when i_dcount = 0xf
                w_fifo_din(512) <= '1';
            else
                -- Not the last word in the HBM data transfer
                w_fifo_din(512) <= '0';
            end if;
            
            if ((i_TCIvalid = '1' and i_dcount = "00001111") and
                (tileDel1(7 downto 4) = tileDel1(3 downto 0)) and 
                (cellLastDel1 = '1')) then
                -- If this cell is the last cell in the tile, and this tile is the last 
                -- tile in a row of tiles, then notify the SPEAD packet generator.
                -- If tile row (=tileDel1(7 downto 4)) and tile column (= tileDel1(3 downto 0)) 
                -- are the same, then we are at the end of the row of tiles. 
                w_fifo_din(513) <= '1'; -- signals that the SPEAD_trigger_fifo should be read
                SPEAD_trigger_we <= '1'; -- signals SPEAD packet generator
                SPEAD_trigger_din(19 downto 0) <= channelDel1(19 downto 0);  -- 20 bits; 
                SPEAD_trigger_din(27 downto 20) <= subarrayBeamDel1; --
                SPEAD_trigger_din(31 downto 28) <= tileDel1(7 downto 4); -- The first row in this tile
                
                -- Number of rows to read out 
                if lastStationDel1(11 downto 8) = tileDel1(7 downto 4) then
                    -- This is the last row of tiles.
                    -- Value = (number of rows to read out) - 1
                    SPEAD_trigger_din(39 downto 32) <= lastStationDel1(7 downto 0);
                else
                    -- Not the last row of tiles, so read the whole 256 stations from the tiles.
                    SPEAD_trigger_din(39 downto 32) <= "11111111"; -- 256-1 = 255 = 0xFF
                end if;
                -- The address in HBM for SPEAD packetiser to start reading from.
                SPEAD_trigger_din(54 downto 40) <= start_of_row_ptr;
                SPEAD_trigger_din(55) <= badpolyDel1;
            else
                -- Do not trigger reading of the SPEAD_trigger_fifo 
                w_fifo_din(513) <= '0';
                SPEAD_trigger_we <= '0';
            end if;
            
            -- write a 513 bit word for every second 256 bit input word.
            w_fifo_we <= (i_visValid or i_TCIvalid) and i_dcount(0); 
            
            -- There is about 20 clocks latency for data to stop after o_stop is high.
            -- So we stop when we still have space for more than 20 new 256-bit words in the FIFO.
            if unsigned(w_fifo_count) > 400 then
                o_stop <= '1';
            else
                o_stop <= '0';
            end if;
            
            visValidDel2 <= visValidDel1;
            
            if visValidDel1 = '1' and dcountDel1 = "00000000" then
                curCell <= cellDel1;
                curTile <= tileDel1;
                set_aw <= '1';
                -- If this is the first cell in a row of tiles, then save the fifo wr pointer,
                -- so it can be passed to the SPEAD readout at the end of this row of tiles.
                -- tileDel1(3:0) is the column for this tile, so when it is zero we are at
                -- the start of the strip of tiles.
                if (cellDel1 = "00000000" and tileDel1(3 downto 0) = "0000") then
                    start_of_row_ptr <= fifo_wr_ptr;
                end if;
            else
                set_aw <= '0';
            end if;
            
            case set_aw_fsm is
                when idle => 
                    if set_aw = '1' then
                        set_aw_fsm <= vis_addr1;
                    end if;
                    aw_fifo_we <= '0';
                    aw_fifo_din <= (others => '0');
                
                when vis_addr1 =>
                    aw_fifo_din(31 downto 28) <= "0000"; -- bits 31:28 select the 256 MByte base address; Visibilities go in the low 256 MBytes.
                    aw_fifo_din(27 downto 0) <= fifo_wr_ptr & "0000000000000"; -- the address to write to; fifo_wr_ptr is in units of cells; for visibility data, that is units of 8 kbytes.
                    aw_fifo_din(39 downto 32) <= "00111111"; -- aw_len = 4 kbytes = 64 x (64 byte words)
                    aw_fifo_we <= '1';
                    set_aw_fsm <= vis_addr2;
                
                when vis_addr2 =>
                    aw_fifo_din(31 downto 28) <= "0000"; -- second half of the visibility data;
                    aw_fifo_din(27 downto 0) <= fifo_wr_ptr & "1000000000000"; -- the address to write to; fifo_wr_ptr is in units of cells; for visibility data, that is units of 8 kbytes. This is the second block of 4 kbytes for the cell.
                    aw_fifo_din(39 downto 32) <= "00111111"; -- aw_len = 4 kbytes = 64 x (64 byte words)
                    aw_fifo_we <= '1';
                    set_aw_fsm <= TCI_Addr;
                
                when TCI_addr => 
                    aw_fifo_din(31 downto 28) <= "0001";  -- TCI data FIFO is offset by 256 Mbytes from the start of the buffer.
                    aw_fifo_din(27 downto 24) <= "0000";  -- Only use 16 Mbytes for the TCI data, since it is 1/16th the size of the visibility data.
                    aw_fifo_din(23 downto 0) <= fifo_wr_ptr & "000000000"; -- 512 bytes per block of data; so 9 zeros in the address.
                    aw_fifo_din(39 downto 32) <= "00000111";   -- aw_len = 512 bytes = 8 x (64 byte words)
                    aw_fifo_we <= '1';

                    -- update the write pointer;
                    fifo_wr_ptr <= std_logic_vector(unsigned(fifo_wr_ptr) + 1);
                    set_aw_fsm <= idle;
                
                when others =>
                    set_aw_fsm <= idle;
                    
            end case;
            
            if i_axi_rst = '1' then
                errors_int <= "0000";
            else
                if aw_fifo_full = '1' then
                    -- this should be impossible, since the data fifo can only buffer up
                    -- at most 4 cells, at which point it will stall the sending of 
                    -- more data to this module. 
                    -- 4 cells = 12 aw requests, so cannot fill the 32-deep aw FIFO.
                    errors_int(0) <= '1';
                end if;
                if w_fifo_full = '1' then
                    errors_int(1) <= '1';
                end if;
                if SPEAD_trigger_full = '1' then
                    errors_int(2) <= '1';
                end if;
                if SPEAD_trigger_empty = '1' and SPEAD_trigger_rd = '1' then
                    errors_int(3) <= '1';
                end if;
            end if;
            
        end if;
    end process;
    
    o_errors <= errors_int;
    
    -- FIFO to convert the data to 512 bits wide, and interface to the o_axi_w bus.
    -- The FIFO has space for 32 x 512 bits = 2048 bytes.
    wdata_fifo_i : xpm_fifo_sync
    generic map (
        CASCADE_HEIGHT => 0,        -- DECIMAL
        DOUT_RESET_VALUE => "0",    -- String
        ECC_MODE => "no_ecc",       -- String
        FIFO_MEMORY_TYPE => "auto", -- String
        FIFO_READ_LATENCY => 0,     -- DECIMAL
        FIFO_WRITE_DEPTH => 512,     -- DECIMAL
        FULL_RESET_VALUE => 0,      -- DECIMAL
        PROG_EMPTY_THRESH => 10,    -- DECIMAL
        PROG_FULL_THRESH => 10,     -- DECIMAL
        RD_DATA_COUNT_WIDTH => 10,  -- DECIMAL
        READ_DATA_WIDTH => 514,     -- DECIMAL
        READ_MODE => "fwft",        -- String
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "1707", -- String -- bit 12 enables data valid flag; 
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 514,    -- DECIMAL
        WR_DATA_COUNT_WIDTH => 10   -- DECIMAL
    ) port map (
        almost_empty => open,           -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
        almost_full => open,            -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
        data_valid => w_fifo_dout_valid, -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
        dbiterr => open,                -- 1-bit output: Double Bit Error
        dout => w_fifo_dout,            -- READ_DATA_WIDTH-bit output: Read Data: The output data bus is driven when reading the FIFO.
        empty => open,                  -- 1-bit output: Empty Flag: When asserted, this signal indicates that the FIFO is empty. 
        full => w_fifo_full,            -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full. 
        overflow => open,               -- 1-bit output: Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected, because the FIFO is full. 
        prog_empty => open,             -- 1-bit output: Programmable Empty: 
        prog_full => open,              -- 1-bit output: Programmable Full: 
        rd_data_count => open,          -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
        rd_rst_busy => open,            -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
        sbiterr => open,                -- 1-bit output: Single Bit Error: 
        underflow => open,              -- 1-bit output: Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected because the FIFO is empty. 
        wr_ack => open,                 -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.
        wr_data_count => w_fifo_count,  -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        wr_rst_busy => open,            -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
        din => w_fifo_din,              -- WRITE_DATA_WIDTH-bit input: Write Data: The input data bus used when writing the FIFO.
        injectdbiterr => '0',           -- 1-bit input: Double Bit Error Injection: Injects a double bit error if the ECC feature is used on block RAMs or UltraRAM macros.
        injectsbiterr => '0',           -- 1-bit input: Single Bit Error Injection: Injects a single bit error if the ECC feature is used on block RAMs or UltraRAM macros.
        rd_en => i_axi_wready,          -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO. 
        rst => '0',                    -- 1-bit input: Reset: Must be synchronous to wr_clk. 
        sleep => '0',                   -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
        wr_clk => i_axi_clk,            -- 1-bit input: Write clock: Used for write operation. 
        wr_en => w_fifo_we              -- 1-bit input: Write Enable: If the FIFO is not full, asserting this signal causes data (on din) to be written to the FIFO 
    );
    
    o_axi_w.valid <= w_fifo_dout_valid;
    o_axi_w.data <= w_fifo_dout(511 downto 0); 
    o_axi_w.last <= w_fifo_dout(512);
    
    
    -- FIFO for aw commands.
    -- 8192 bytes of visibility data per cell; this module generates 2 aw commands of 4096 bytes each.
    -- 512 bytes of TCI data per cell; this module generates 1 aw command for the 512 bytes.
    -- FIFO to convert the data to 512 bits wide, and interface to the o_axi_w bus.
    aw_fifoi : xpm_fifo_sync
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
        READ_DATA_WIDTH => 40,       -- DECIMAL
        READ_MODE => "fwft",         -- String
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "1707", -- String -- bit 12 enables data valid flag; 
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 40,     -- DECIMAL
        WR_DATA_COUNT_WIDTH => 6    -- DECIMAL
    ) port map (
        almost_empty => open,           -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
        almost_full => open,            -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
        data_valid => aw_fifo_dout_valid, -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
        dbiterr => open,                -- 1-bit output: Double Bit Error
        dout => aw_fifo_dout,           -- READ_DATA_WIDTH-bit output: Read Data: The output data bus is driven when reading the FIFO.
        empty => open,                  -- 1-bit output: Empty Flag: When asserted, this signal indicates that the FIFO is empty. 
        full => aw_fifo_full,           -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full. 
        overflow => open,               -- 1-bit output: Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected, because the FIFO is full. 
        prog_empty => open,             -- 1-bit output: Programmable Empty: 
        prog_full => open,              -- 1-bit output: Programmable Full: 
        rd_data_count => open,          -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
        rd_rst_busy => open,            -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
        sbiterr => open,                -- 1-bit output: Single Bit Error: 
        underflow => open,              -- 1-bit output: Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected because the FIFO is empty. 
        wr_ack => open,                 -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.
        wr_data_count => open,          -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        wr_rst_busy => open,            -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
        din => aw_fifo_din,             -- WRITE_DATA_WIDTH-bit input: Write Data: The input data bus used when writing the FIFO.
        injectdbiterr => '0',           -- 1-bit input: Double Bit Error Injection: Injects a double bit error if the ECC feature is used on block RAMs or UltraRAM macros.
        injectsbiterr => '0',           -- 1-bit input: Single Bit Error Injection: Injects a single bit error if the ECC feature is used on block RAMs or UltraRAM macros.
        rd_en => i_axi_awready,         -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO. 
        rst => '0',                    -- 1-bit input: Reset: Must be synchronous to wr_clk. 
        sleep => '0',                   -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
        wr_clk => i_axi_clk,            -- 1-bit input: Write clock: Used for write operation. 
        wr_en => aw_fifo_we             -- 1-bit input: Write Enable: If the FIFO is not full, asserting this signal causes data (on din) to be written to the FIFO 
    );
    
    o_axi_aw.valid <= aw_fifo_dout_valid;
    o_axi_aw.addr(31 downto 0)  <= aw_fifo_dout(31 downto 0);
    o_axi_aw.addr(39 downto 32) <= "00000000";
    o_axi_aw.len <= aw_fifo_dout(39 downto 32);
    
    
    speadTrigger_fifoi : xpm_fifo_sync
    generic map (
        CASCADE_HEIGHT => 0,        -- DECIMAL
        DOUT_RESET_VALUE => "0",    -- String
        ECC_MODE => "no_ecc",       -- String
        FIFO_MEMORY_TYPE => "distributed", -- String
        FIFO_READ_LATENCY => 1,     -- DECIMAL
        FIFO_WRITE_DEPTH => 32,     -- DECIMAL
        FULL_RESET_VALUE => 0,      -- DECIMAL
        PROG_EMPTY_THRESH => 10,    -- DECIMAL
        PROG_FULL_THRESH => 10,     -- DECIMAL
        RD_DATA_COUNT_WIDTH => 6,   -- DECIMAL
        READ_DATA_WIDTH => 56,      -- DECIMAL
        READ_MODE => "std",         -- String
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "1707", -- String -- bit 12 enables data valid flag; 
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 56,     -- DECIMAL
        WR_DATA_COUNT_WIDTH => 6    -- DECIMAL
    ) port map (
        almost_empty => open,       -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
        almost_full => open,        -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
        data_valid => open, -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
        dbiterr => open,            -- 1-bit output: Double Bit Error
        dout => SPEAD_trigger_dout, -- READ_DATA_WIDTH-bit output: Read Data: The output data bus is driven when reading the FIFO.
        empty => SPEAD_trigger_empty, -- 1-bit output: Empty Flag: When asserted, this signal indicates that the FIFO is empty. 
        full => SPEAD_trigger_full, -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full. 
        overflow => open,           -- 1-bit output: Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected, because the FIFO is full. 
        prog_empty => open,         -- 1-bit output: Programmable Empty: 
        prog_full => open,          -- 1-bit output: Programmable Full: 
        rd_data_count => open,      -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
        rd_rst_busy => open,        -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
        sbiterr => open,            -- 1-bit output: Single Bit Error: 
        underflow => open,          -- 1-bit output: Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected because the FIFO is empty. 
        wr_ack => open,             -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.
        wr_data_count => open,      -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        wr_rst_busy => open,        -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
        din => SPEAD_trigger_din,   -- WRITE_DATA_WIDTH-bit input: Write Data: The input data bus used when writing the FIFO.
        injectdbiterr => '0',       -- 1-bit input: Double Bit Error Injection: Injects a double bit error if the ECC feature is used on block RAMs or UltraRAM macros.
        injectsbiterr => '0',       -- 1-bit input: Single Bit Error Injection: Injects a single bit error if the ECC feature is used on block RAMs or UltraRAM macros.
        rd_en => SPEAD_trigger_rd,  -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO. 
        rst => '0',                 -- 1-bit input: Reset: Must be synchronous to wr_clk. 
        sleep => '0',               -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
        wr_clk => i_axi_clk,        -- 1-bit input: Write clock: Used for write operation. 
        wr_en => SPEAD_trigger_we   -- 1-bit input: Write Enable: If the FIFO is not full, asserting this signal causes data (on din) to be written to the FIFO 
    );    
    
    ro_rows_minus1 <= '0' & SPEAD_trigger_dout(39 downto 32);
    
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            if w_fifo_dout_valid = '1' and i_axi_wready = '1' and w_fifo_dout(513) = '1' then
                SPEAD_trigger_rd <= '1';
            else
                SPEAD_trigger_rd <= '0';
            end if;
            SPEAD_trigger_rd_Del1 <= SPEAD_trigger_rd;
            
            if SPEAD_trigger_rd_Del1 = '1' then
                -- output frequency index. Count of the frequency channels being generated
                -- by the correlator. Counts from 0.
                o_ro_freq_index <= SPEAD_trigger_dout(16 downto 0); -- out std_logic_vector(16 downto 0);            
                -- Index of the subarray-beam,
                -- This is the address into the table in the second corner turn. Valid range is 0 up.
                o_ro_subarray <= SPEAD_trigger_dout(27 downto 20);            
                -- The first of the block of rows in the visibility matrix that is now available for readout.
                -- Counts from 0. 
                -- The number of columns to read out for the first row will be (o_row + 1).
                -- The number of columns to read out for the last row in this strip will be (o_row + o_row_count)
                o_ro_row <= '0' & SPEAD_trigger_dout(31 downto 28) & "00000000";
                -- The number of rows to read out. Valid range is 1 up to 256.
                o_ro_row_count <= std_logic_vector(unsigned(ro_rows_minus1) + 1); --  out (8:0);               
                -- Byte address of the start of the row of tiles in HBM.
                o_ro_HBM_start_addr <= "0000" & SPEAD_trigger_dout(54 downto 40) & "0000000000000"; -- out (31:0);

                o_ro_badPoly <= SPEAD_trigger_dout(55);
                -- Some kind of timestamp. Will be the same for all subarrays within a single 849 ms 
                -- integration time.
                o_ro_time_ref <= (others => '0'); -- TODO - work out how this should be set.

                -- valid indicates that the other signals are valid. 
                -- valid will pulse high for 1 clock cycle when a strip of data from the visibility matrix is available.
                o_ro_valid <= '1';
            else
                o_ro_valid <= '0';
            end if;
            
        end if;
    end process;
    
end Behavioral;
