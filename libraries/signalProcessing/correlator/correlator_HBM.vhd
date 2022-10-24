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
        i_tile      : in std_logic_vector(9 downto 0);  -- a "tile" is a 16x16 block of cells, i.e. a 256x256 station correlation.
        i_channel   : in std_logic_vector(15 downto 0); -- first fine channel index for this correlation.
        -- stop sending data; somewhere downstream there is a FIFO that is almost full.
        -- There can be a lag of about 20 clocks between i_stop going high and data stopping.
        o_stop      : out std_logic;
        
        -----------------------------------------------------------------------------------------
        -- Status info
        o_HBM_start : out std_logic_vector(31 downto 0); -- Byte address offset into the HBM buffer where the visibility circular buffer starts.
        o_HBM_end   : out std_logic_vector(31 downto 0); -- byte address offset into the HBM buffer where the visibility circular buffer ends.
        o_HBM_cells : out std_logic_vector(15 downto 0); -- Number of cells currently in the circular buffer.
        o_errors    : out std_logic_vector(3 downto 0); -- bit 0 = aw fifo full; this should never happen.
        -----------------------------------------------------------------------------------------
        -- Packets for SDP, via 100GE
        -- Packets are SPEAD, i.e. they contain the SPEAD data and nothing else (no ethernet, udp or ip headers).
        o_packet_dout  : out std_logic_vector(255 downto 0);
        o_packet_valid : out std_logic;
        i_packet_ready : in std_logic;
        
        -----------------------------------------------------------------------------------------
        -- HBM interface
        -- Write to HBM
        o_axi_aw      : out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_axi_awready : in  std_logic;
        o_axi_w       : out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0))
        i_axi_wready  : in  std_logic;
        i_axi_b       : in  t_axi4_full_b;    -- write response bus : in t_axi4_full_b; (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        -- Reading from HBM
        o_axi_ar      : out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_axi_arready : in  std_logic;
        i_axi_r       : in  t_axi4_full_data; -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
        o_axi_rready  : out std_logic
    );
end correlator_HBM;

architecture Behavioral of correlator_HBM is

    signal visValidDel1, visValidDel2 : std_logic;
    
    signal fifo_wr_ptr : std_logic_vector(14 downto 0); -- 256 MBytes = 32768 blocks of 8192 bytes;
    signal aw_fifo_we : std_logic;
    signal aw_fifo_din : std_logic_vector(39 downto 0);
    signal set_aw : std_logic;
    type aw_fsm_type is (idle, vis_addr1, vis_addr2, TCI_addr);
    signal set_aw_fsm : aw_fsm_type := idle;
    signal cellDel1, curCell : std_logic_vector(7 downto 0);
    signal tileDel1, curTile : std_logic_vector(9 downto 0);
    signal channelDel1, curChannel : std_logic_vector(15 downto 0);
    signal aw_fifo_dout_valid : std_logic;
    signal aw_fifo_dout : std_logic_vector(39 downto 0);
    signal errors_int : std_logic_vector(3 downto 0);
    signal aw_fifo_full : std_logic;
    signal w_fifo_dout_valid : std_logic;
    signal w_fifo_dout : std_logic_vector(513 downto 0);
    signal w_fifo_din : std_logic_vector(256 downto 0);
    signal w_fifo_we : std_logic;
    signal w_fifo_count : std_logic_vector(6 downto 0);
    signal w_fifo_full : std_logic;
    
begin
    
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            visValidDel1 <= i_visValid;
            cellDel1 <= i_cell;
            tileDel1 <= i_tile;
            channelDel1 <= i_channel;
            
            w_fifo_din(255 downto 0) <= i_data;
            if ((i_visValid = '1' and i_dcount(6 downto 0) = "1111111") or (i_TCIvalid = '1' and i_dcount = "00001111")) then
                -- indicates last word in a HBM data transfer.
                -- Occurs twice in the 256 transfers for the data, at i_dcount = x7F and i_dcount = xFF, and once at the end of the TCI data, when i_dcount = 0xf
                w_fifo_din(256) <= '1';
            else
                w_fifo_din(256) <= '0';
            end if;
            w_fifo_we <= i_visValid or i_TCIvalid;
            if unsigned(w_fifo_count) > 32 then
                o_stop <= '1';  -- about 20 clock latency for data to actually stop, so we stop when we still have more than 20 spare spots in the FIFO.
            else
                o_stop <= '0';
            end if;
            
            visValidDel2 <= visValidDel1;
            
            if visValidDel1 = '1' and visValidDel2 = '0' then
                curCell <= cellDel1;
                curTile <= tileDel1;
                curChannel <= channelDel1;
                set_aw <= '1';
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
                    errors_int(0) <= '1';
                end if;
                if w_fifo_full = '1' then
                    errors_int(1) <= '1';
                end if;
            end if;
            
        end if;
    end process;
    
    o_errors <= errors_int;
    
    -- FIFO to convert the data to 512 bits wide, and interface to the o_axi_w bus.
    wdata_fifo_i : xpm_fifo_sync
    generic map (
        CASCADE_HEIGHT => 0,        -- DECIMAL
        DOUT_RESET_VALUE => "0",    -- String
        ECC_MODE => "no_ecc",       -- String
        FIFO_MEMORY_TYPE => "distributed", -- String
        FIFO_READ_LATENCY => 0,     -- DECIMAL
        FIFO_WRITE_DEPTH => 64,   -- DECIMAL
        FULL_RESET_VALUE => 0,      -- DECIMAL
        PROG_EMPTY_THRESH => 10,    -- DECIMAL
        PROG_FULL_THRESH => 10,     -- DECIMAL
        RD_DATA_COUNT_WIDTH => 6,   -- DECIMAL
        READ_DATA_WIDTH => 514,     -- DECIMAL
        READ_MODE => "fwft",         -- String
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "1707", -- String -- bit 12 enables data valid flag; 
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 257,     -- DECIMAL
        WR_DATA_COUNT_WIDTH => 7    -- DECIMAL
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
        rst => open,                    -- 1-bit input: Reset: Must be synchronous to wr_clk. 
        sleep => '0',                   -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
        wr_clk => i_axi_clk,            -- 1-bit input: Write clock: Used for write operation. 
        wr_en => w_fifo_we              -- 1-bit input: Write Enable: If the FIFO is not full, asserting this signal causes data (on din) to be written to the FIFO 
    );
    
    o_axi_w.valid <= w_fifo_dout_valid;
    o_axi_w.data <= w_fifo_dout(512 downto 257) & w_fifo_dout(255 downto 0); 
    o_axi_w.last <= w_fifo_dout(513);
    
    
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
        WR_DATA_COUNT_WIDTH => 7    -- DECIMAL
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
        rst => open,                    -- 1-bit input: Reset: Must be synchronous to wr_clk. 
        sleep => '0',                   -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
        wr_clk => i_axi_clk,            -- 1-bit input: Write clock: Used for write operation. 
        wr_en => aw_fifo_we             -- 1-bit input: Write Enable: If the FIFO is not full, asserting this signal causes data (on din) to be written to the FIFO 
    );
    
    o_axi_aw.valid <= aw_fifo_dout_valid;
    o_axi_aw.addr(31 downto 0)  <= aw_fifo_dout(31 downto 0);
    o_axi_aw.addr(39 downto 32) <= "00000000";
    o_axi_aw.len <= aw_fifo_dout(39 downto 32);
    
    
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            
            
        end if;
    end process;
    
    
    

end Behavioral;




-- XPM_FIFO instantiation template for Synchronous FIFO configurations
-- Refer to the targeted device family architecture libraries guide for XPM_FIFO documentation
-- =======================================================================================================================

-- Parameter usage table, organized as follows:
-- +---------------------------------------------------------------------------------------------------------------------+
-- | Parameter name       | Data type          | Restrictions, if applicable                                             |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Description                                                                                                         |
-- +---------------------------------------------------------------------------------------------------------------------+
-- +---------------------------------------------------------------------------------------------------------------------+
-- | CASCADE_HEIGHT       | Integer            | Range: 0 - 64. Default value = 0.                                       |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | 0- No Cascade Height, Allow Vivado Synthesis to choose.                                                             |
-- | 1 or more - Vivado Synthesis sets the specified value as Cascade Height.                                            |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | DOUT_RESET_VALUE     | String             | Default value = 0.                                                      |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Reset value of read data path.                                                                                      |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | ECC_MODE             | String             | Allowed values: no_ecc, en_ecc. Default value = no_ecc.                 |
-- |---------------------------------------------------------------------------------------------------------------------|
-- |                                                                                                                     |
-- |   "no_ecc" - Disables ECC                                                                                           |
-- |   "en_ecc" - Enables both ECC Encoder and Decoder                                                                   |
-- |                                                                                                                     |
-- | NOTE: ECC_MODE should be "no_ecc" if FIFO_MEMORY_TYPE is set to "auto". Violating this may result incorrect behavior.|
-- +---------------------------------------------------------------------------------------------------------------------+
-- | FIFO_MEMORY_TYPE     | String             | Allowed values: auto, block, distributed, ultra. Default value = auto.  |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Designate the fifo memory primitive (resource type) to use-                                                         |
-- |                                                                                                                     |
-- |   "auto"- Allow Vivado Synthesis to choose                                                                          |
-- |   "block"- Block RAM FIFO                                                                                           |
-- |   "distributed"- Distributed RAM FIFO                                                                               |
-- |   "ultra"- URAM FIFO                                                                                                |
-- |                                                                                                                     |
-- | NOTE: There may be a behavior mismatch if Block RAM or Ultra RAM specific features, like ECC or Asymmetry, are selected with FIFO_MEMORY_TYPE set to "auto".|
-- +---------------------------------------------------------------------------------------------------------------------+
-- | FIFO_READ_LATENCY    | Integer            | Range: 0 - 100. Default value = 1.                                      |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Number of output register stages in the read data path                                                              |
-- |                                                                                                                     |
-- |   If READ_MODE = "fwft", then the only applicable value is 0                                                        |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | FIFO_WRITE_DEPTH     | Integer            | Range: 16 - 4194304. Default value = 2048.                              |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Defines the FIFO Write Depth, must be power of two                                                                  |
-- |                                                                                                                     |
-- |   In standard READ_MODE, the effective depth = FIFO_WRITE_DEPTH                                                     |
-- |   In First-Word-Fall-Through READ_MODE, the effective depth = FIFO_WRITE_DEPTH+2                                    |
-- |                                                                                                                     |
-- | NOTE: The maximum FIFO size (width x depth) is limited to 150-Megabits.                                             |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | FULL_RESET_VALUE     | Integer            | Range: 0 - 1. Default value = 0.                                        |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Sets full, almost_full and prog_full to FULL_RESET_VALUE during reset                                               |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | PROG_EMPTY_THRESH    | Integer            | Range: 3 - 4194304. Default value = 10.                                 |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specifies the minimum number of read words in the FIFO at or below which prog_empty is asserted.                    |
-- |                                                                                                                     |
-- |   Min_Value = 3 + (READ_MODE_VAL*2)                                                                                 |
-- |   Max_Value = (FIFO_WRITE_DEPTH-3) - (READ_MODE_VAL*2)                                                              |
-- |                                                                                                                     |
-- | If READ_MODE = "std", then READ_MODE_VAL = 0; Otherwise READ_MODE_VAL = 1.                                          |
-- | NOTE: The default threshold value is dependent on default FIFO_WRITE_DEPTH value. If FIFO_WRITE_DEPTH value is      |
-- | changed, ensure the threshold value is within the valid range though the programmable flags are not used.           |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | PROG_FULL_THRESH     | Integer            | Range: 3 - 4194301. Default value = 10.                                 |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specifies the maximum number of write words in the FIFO at or above which prog_full is asserted.                    |
-- |                                                                                                                     |
-- |   Min_Value = 3 + (READ_MODE_VAL*2*(FIFO_WRITE_DEPTH/FIFO_READ_DEPTH))                                              |
-- |   Max_Value = (FIFO_WRITE_DEPTH-3) - (READ_MODE_VAL*2*(FIFO_WRITE_DEPTH/FIFO_READ_DEPTH))                           |
-- |                                                                                                                     |
-- | If READ_MODE = "std", then READ_MODE_VAL = 0; Otherwise READ_MODE_VAL = 1.                                          |
-- | NOTE: The default threshold value is dependent on default FIFO_WRITE_DEPTH value. If FIFO_WRITE_DEPTH value is      |
-- | changed, ensure the threshold value is within the valid range though the programmable flags are not used.           |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | RD_DATA_COUNT_WIDTH  | Integer            | Range: 1 - 23. Default value = 1.                                       |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specifies the width of rd_data_count. To reflect the correct value, the width should be log2(FIFO_READ_DEPTH)+1.    |
-- |                                                                                                                     |
-- |   FIFO_READ_DEPTH = FIFO_WRITE_DEPTH*WRITE_DATA_WIDTH/READ_DATA_WIDTH                                               |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | READ_DATA_WIDTH      | Integer            | Range: 1 - 4096. Default value = 32.                                    |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Defines the width of the read data port, dout                                                                       |
-- |                                                                                                                     |
-- |   Write and read width aspect ratio must be 1:1, 1:2, 1:4, 1:8, 8:1, 4:1 and 2:1                                    |
-- |   For example, if WRITE_DATA_WIDTH is 32, then the READ_DATA_WIDTH must be 32, 64,128, 256, 16, 8, 4.               |
-- |                                                                                                                     |
-- | NOTE:                                                                                                               |
-- |                                                                                                                     |
-- |   READ_DATA_WIDTH should be equal to WRITE_DATA_WIDTH if FIFO_MEMORY_TYPE is set to "auto". Violating this may result incorrect behavior. |
-- |   The maximum FIFO size (width x depth) is limited to 150-Megabits.                                                 |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | READ_MODE            | String             | Allowed values: std, fwft. Default value = std.                         |
-- |---------------------------------------------------------------------------------------------------------------------|
-- |                                                                                                                     |
-- |   "std"- standard read mode                                                                                         |
-- |   "fwft"- First-Word-Fall-Through read mode                                                                         |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | SIM_ASSERT_CHK       | Integer            | Range: 0 - 1. Default value = 0.                                        |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | 0- Disable simulation message reporting. Messages related to potential misuse will not be reported.                 |
-- | 1- Enable simulation message reporting. Messages related to potential misuse will be reported.                      |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | USE_ADV_FEATURES     | String             | Default value = 0707.                                                   |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Enables data_valid, almost_empty, rd_data_count, prog_empty, underflow, wr_ack, almost_full, wr_data_count,         |
-- | prog_full, overflow features.                                                                                       |
-- |                                                                                                                     |
-- |   Setting USE_ADV_FEATURES[0] to 1 enables overflow flag; Default value of this bit is 1                            |
-- |   Setting USE_ADV_FEATURES[1] to 1 enables prog_full flag; Default value of this bit is 1                           |
-- |   Setting USE_ADV_FEATURES[2] to 1 enables wr_data_count; Default value of this bit is 1                            |
-- |   Setting USE_ADV_FEATURES[3] to 1 enables almost_full flag; Default value of this bit is 0                         |
-- |   Setting USE_ADV_FEATURES[4] to 1 enables wr_ack flag; Default value of this bit is 0                              |
-- |   Setting USE_ADV_FEATURES[8] to 1 enables underflow flag; Default value of this bit is 1                           |
-- |   Setting USE_ADV_FEATURES[9] to 1 enables prog_empty flag; Default value of this bit is 1                          |
-- |   Setting USE_ADV_FEATURES[10] to 1 enables rd_data_count; Default value of this bit is 1                           |
-- |   Setting USE_ADV_FEATURES[11] to 1 enables almost_empty flag; Default value of this bit is 0                       |
-- |   Setting USE_ADV_FEATURES[12] to 1 enables data_valid flag; Default value of this bit is 0                         |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | WAKEUP_TIME          | Integer            | Range: 0 - 2. Default value = 0.                                        |
-- |---------------------------------------------------------------------------------------------------------------------|
-- |                                                                                                                     |
-- |   0 - Disable sleep                                                                                                 |
-- |   2 - Use Sleep Pin                                                                                                 |
-- |                                                                                                                     |
-- | NOTE: WAKEUP_TIME should be 0 if FIFO_MEMORY_TYPE is set to "auto". Violating this may result incorrect behavior.   |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | WRITE_DATA_WIDTH     | Integer            | Range: 1 - 4096. Default value = 32.                                    |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Defines the width of the write data port, din                                                                       |
-- |                                                                                                                     |
-- |   Write and read width aspect ratio must be 1:1, 1:2, 1:4, 1:8, 8:1, 4:1 and 2:1                                    |
-- |   For example, if WRITE_DATA_WIDTH is 32, then the READ_DATA_WIDTH must be 32, 64,128, 256, 16, 8, 4.               |
-- |                                                                                                                     |
-- | NOTE:                                                                                                               |
-- |                                                                                                                     |
-- |   WRITE_DATA_WIDTH should be equal to READ_DATA_WIDTH if FIFO_MEMORY_TYPE is set to "auto". Violating this may result incorrect behavior.|
-- |   The maximum FIFO size (width x depth) is limited to 150-Megabits.                                                 |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | WR_DATA_COUNT_WIDTH  | Integer            | Range: 1 - 23. Default value = 1.                                       |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specifies the width of wr_data_count. To reflect the correct value, the width should be log2(FIFO_WRITE_DEPTH)+1.   |
-- +---------------------------------------------------------------------------------------------------------------------+

-- Port usage table, organized as follows:
-- +---------------------------------------------------------------------------------------------------------------------+
-- | Port name      | Direction | Size, in bits                         | Domain  | Sense       | Handling if unused     |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Description                                                                                                         |
-- +---------------------------------------------------------------------------------------------------------------------+
-- +---------------------------------------------------------------------------------------------------------------------+
-- | almost_empty   | Output    | 1                                     | wr_clk  | Active-high | DoNotCare              |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to|
-- | empty.                                                                                                              |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | almost_full    | Output    | 1                                     | wr_clk  | Active-high | DoNotCare              |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.|
-- +---------------------------------------------------------------------------------------------------------------------+
-- | data_valid     | Output    | 1                                     | wr_clk  | Active-high | DoNotCare              |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).        |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | dbiterr        | Output    | 1                                     | wr_clk  | Active-high | DoNotCare              |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.|
-- +---------------------------------------------------------------------------------------------------------------------+
-- | din            | Input     | WRITE_DATA_WIDTH                      | wr_clk  | NA          | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Write Data: The input data bus used when writing the FIFO.                                                          |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | dout           | Output    | READ_DATA_WIDTH                       | wr_clk  | NA          | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Read Data: The output data bus is driven when reading the FIFO.                                                     |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | empty          | Output    | 1                                     | wr_clk  | Active-high | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Empty Flag: When asserted, this signal indicates that the FIFO is empty.                                            |
-- | Read requests are ignored when the FIFO is empty, initiating a read while empty is not destructive to the FIFO.     |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | full           | Output    | 1                                     | wr_clk  | Active-high | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Full Flag: When asserted, this signal indicates that the FIFO is full.                                              |
-- | Write requests are ignored when the FIFO is full, initiating a write when the FIFO is full is not destructive       |
-- | to the contents of the FIFO.                                                                                        |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | injectdbiterr  | Input     | 1                                     | wr_clk  | Active-high | Tie to 1'b0            |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Double Bit Error Injection: Injects a double bit error if the ECC feature is used on block RAMs or                  |
-- | UltraRAM macros.                                                                                                    |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | injectsbiterr  | Input     | 1                                     | wr_clk  | Active-high | Tie to 1'b0            |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Single Bit Error Injection: Injects a single bit error if the ECC feature is used on block RAMs or                  |
-- | UltraRAM macros.                                                                                                    |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | overflow       | Output    | 1                                     | wr_clk  | Active-high | DoNotCare              |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected,              |
-- | because the FIFO is full. Overflowing the FIFO is not destructive to the contents of the FIFO.                      |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | prog_empty     | Output    | 1                                     | wr_clk  | Active-high | DoNotCare              |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Programmable Empty: This signal is asserted when the number of words in the FIFO is less than or equal              |
-- | to the programmable empty threshold value.                                                                          |
-- | It is de-asserted when the number of words in the FIFO exceeds the programmable empty threshold value.              |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | prog_full      | Output    | 1                                     | wr_clk  | Active-high | DoNotCare              |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Programmable Full: This signal is asserted when the number of words in the FIFO is greater than or equal            |
-- | to the programmable full threshold value.                                                                           |
-- | It is de-asserted when the number of words in the FIFO is less than the programmable full threshold value.          |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | rd_data_count  | Output    | RD_DATA_COUNT_WIDTH                   | wr_clk  | NA          | DoNotCare              |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Read Data Count: This bus indicates the number of words read from the FIFO.                                         |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | rd_en          | Input     | 1                                     | wr_clk  | Active-high | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO.        |
-- |                                                                                                                     |
-- |   Must be held active-low when rd_rst_busy is active high.                                                          |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | rd_rst_busy    | Output    | 1                                     | wr_clk  | Active-high | DoNotCare              |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.                     |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | rst            | Input     | 1                                     | wr_clk  | Active-high | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Reset: Must be synchronous to wr_clk. The clock(s) can be unstable at the time of applying reset, but reset must be released only after the clock(s) is/are stable.|
-- +---------------------------------------------------------------------------------------------------------------------+
-- | sbiterr        | Output    | 1                                     | wr_clk  | Active-high | DoNotCare              |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Single Bit Error: Indicates that the ECC decoder detected and fixed a single-bit error.                             |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | sleep          | Input     | 1                                     | NA      | Active-high | Tie to 1'b0            |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.                              |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | underflow      | Output    | 1                                     | wr_clk  | Active-high | DoNotCare              |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected                     |
-- | because the FIFO is empty. Under flowing the FIFO is not destructive to the FIFO.                                   |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | wr_ack         | Output    | 1                                     | wr_clk  | Active-high | DoNotCare              |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.    |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | wr_clk         | Input     | 1                                     | NA      | Rising edge | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Write clock: Used for write operation. wr_clk must be a free running clock.                                         |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | wr_data_count  | Output    | WR_DATA_COUNT_WIDTH                   | wr_clk  | NA          | DoNotCare              |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Write Data Count: This bus indicates the number of words written into the FIFO.                                     |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | wr_en          | Input     | 1                                     | wr_clk  | Active-high | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Write Enable: If the FIFO is not full, asserting this signal causes data (on din) to be written to the FIFO         |
-- |                                                                                                                     |
-- |   Must be held active-low when rst or wr_rst_busy or rd_rst_busy is active high                                     |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | wr_rst_busy    | Output    | 1                                     | wr_clk  | Active-high | DoNotCare              |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.                   |
-- +---------------------------------------------------------------------------------------------------------------------+


-- xpm_fifo_sync : In order to incorporate this function into the design,
--     VHDL      : the following instance declaration needs to be placed
--   instance    : in the body of the design code.  The instance name
--  declaration  : (xpm_fifo_sync_inst) and/or the port declarations after the
--     code      : "=>" declaration maybe changed to properly reference and
--               : connect this function to the design.  All inputs and outputs
--               : must be connected.

--    Library    : In addition to adding the instance declaration, a use
--  declaration  : statement for the UNISIM.vcomponents library needs to be
--      for      : added before the entity declaration.  This library
--    Xilinx     : contains the component declarations for all Xilinx
--  primitives   : primitives and points to the models that will be used
--               : for simulation.

--  Please reference the appropriate libraries guide for additional information on the XPM modules.

--  Copy the following two statements and paste them before the
--  Entity declaration, unless they already exist.


-- <-----Cut code below this line and paste into the architecture body---->

   -- xpm_fifo_sync: Synchronous FIFO
   -- Xilinx Parameterized Macro, version 2021.2

   -- End of xpm_fifo_sync_inst instantiation
				
			
