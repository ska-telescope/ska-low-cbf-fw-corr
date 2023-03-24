----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au) & Norbert Abel
-- 
-- Create Date: 13.03.2020 09:47:34
-- Module Name: ct_atomic_pst_in - Behavioral
-- Description: 
--  First stage corner turn (between LFAA ingest and the filterbanks) 
--  The corner turn takes data for all channels for some number of stations, buffers the data, 
--  and outputs data in bursts for each channel. Burst length is programmable via MACE.
-- 
-- INPUT DATA [x1]:
-- for time = ... (forever)
--    for coarse_group = 1:384/8-1  (order of the coarse groups may vary)
--       for coarse = 1:8
--          for time = 1:2:2048
--             [[ts0, pol0], [ts0, pol1], [ts1, pol0], [ts1, pol1]]
--
-- OUTPUT DATA:
-- Output <BURST LENGTH> and <PRELOAD LENGTH> is configurable via MACE.
-- for coarse = <order defined by a table, programmed via MACE>
--    for time = 1:(<BURST LENGTH> + <PRELOAD LENGTH>)x4096
--       if station_group == 1: [station0, pol0], [station0, pol1]
--
----------------------------------------------------------------------------------
-- Structure
-- ---------
-- This is the top level of the corner turn; it contains :
--  + Timing controls; i.e. when to start reading data out of the buffer.
--  + Registers
--  + Logic to write data to the HBM.
--  + corner turn readout.
--
--  The corner turn supports up to 1024 virtual channels. It is agnostic about what the virtual channels represent, e.g.
--    - 512 stations * 2 coarse channels
--    - 8 stations * 128 coarse channels
--
--  The corner turn uses 3 buffers of 1 Gbyte each.
--  
--  Within a 1 Gbyte buffer: 
--   * 1 GByte/1024 channels = 1 Mbyte per channel
--     - Each LFAA packet is 8192 bytes, so 1 Mbyte = 128 LFAA packets
--     - Each LFAA packet is 2.21184ms, so 128 LFAA packets = 283.115 ms
--   * Address of a packet within the buffer = (virtual_channel) * 1 Mbyte + packet_count
--     - i.e. byte address within a buffer has 
--          - bits 12:0 = byte within an LFAA packet (LFAA packets are 8192 bytes)
--          - bits 19:13 = packet count within the buffer (up to 128 LFAA packets per buffer)
--          - bits 29:20 = virtual channel
--   * The total number of LFAA packets per buffer is configurable via a generic, up to a maximum of 128.
--   
--  A shadow memory keeps track of which LFAA packets have been written to the memory.
--  (1 Gbyte)/(8192 bytes) = 2^30/2^13 = 2^17 = 131072 blocks.
--  1 ultraRAM = 32 kbytes = 262144 bits. So 2 ultraRAMs are used as the shadow memory.
--  
----------------------------------------------------------------------------------
-- Timing
--  There are two modes for timing of output data :
--   (1) Timed output
--        Output frames start based on the clock
--   (2) Non-timed output
--        Output frames start when we get an incoming packet with a count past some threshold.
--
----------------------------------------------------------------------------------
-- Default Numbers:
--  LFAA time samples = 1080 ns
--  LFAA bandwidth/coarse channel = 1/1080ns = 925.925 KHz
--  LFAA input blocks = 2048 time samples = 2.21184 ms
--  
-- Correlator filterbank output:
--   Output is in 4096 sample blocks. 
--
--   For g_LFAA_BLOCKS_PER_FRAME = 32 LFAA blocks:    <-- This case requires a higher clock rate due to the higher filterbank preload overhead.
--     32 LFAA blocks = 32 * 2.2ms = 70.4 ms
--     32 LFAA blocks = 16 output blocks
--     Preload samples = 4096 * 11 = 11 output blocks
--     4096 sample output blocks per second = (1024 channels) * (16+11) / 70.77888 ms  = 390625 (4096 sample blocks/second)
--     Used clock cycles on the output bus (4 dual-pol channels per cycle) = (390625/4) * 4096 = 400,000,000 (used clock cycles per second)
--
--   For g_LFAA_BLOCKS_PER_FRAME = 128 LFAA blocks:
--     128 LFAA blocks = 128 * 2.2ms = 283.115520 ms
--     128 LFAA blocks = 64 output blocks
--     Preload samples = 4096 * 11 = 11 output blocks
--     4096 sample output blocks per second = (1024 channels) * (64+11) / 283.11552 ms  = 271270 (4096 sample blocks/second)
--     Used clock cycles on the output bus (4 dual-pol channels per cycle) = (271270/4) * 4096 = 277,777,777 (used clock cycles per second)   
--
--
--   So for correlator filterbanks running at 300 MHz
--     - Packets/second = 271270  (note 4096 time samples/packet)
--     - Clocks/second = 300,000,000
--     - Clocks/packet = 4423  (maximum allowed)
--
----------------------------------------------------------------------------------

library IEEE, ct_lib, common_lib, xpm;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
library DSP_top_lib;
use DSP_top_lib.DSP_top_pkg.all;
USE ct_lib.corr_ct1_reg_pkg.ALL;
USE common_lib.common_pkg.ALL;
use xpm.vcomponents.all;

Library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;

entity corr_ct1_top is
    generic (
        -- Number of SPS packets per frame (for a single virtual channel) for the correlator output.
        -- Each LFAA block is 2048 time samples. 
        -- Default value is 128.
        -- (128 LFAA packets) x (8192 bytes / LFAA packet) x (1024 virtual channels) = 2^30 bytes = 1 Gbyte per buffer.
        -- We need to have a full set of preload data for the filterbanks in a buffer, i.e. 11*4096 samples. = 22 x 2048
        -- 
        -- Number of LFAA blocks per frame; 
        --   - Can use 32 for simulation of the LFAA ingest, 1st corner turn and filterbank
        --     32 is the minimum possible value because otherwise there is insufficient data for the filterbank preload.
        --   - full build must use 128. The second stage corner turn only supports 128.
        g_SPS_PACKETS_PER_FRAME : integer := 128   
    );
    port (
        -- shared memory interface clock (300 MHz)
        i_shared_clk     : in std_logic;
        i_shared_rst     : in std_logic;
        -- Registers (uses the shared memory clock)
        i_saxi_mosi       : in  t_axi4_lite_mosi; -- MACE IN
        o_saxi_miso       : out t_axi4_lite_miso; -- MACE OUT
        -- other config (comes from LFAA ingest module).
        i_virtualChannels   : in std_logic_vector(10 downto 0); -- total virtual channels 
        o_rst               : out std_logic;  -- reset from the register module, copied out to be used downstream.
        o_validMemRstActive : out std_logic;  -- reset is in progress, don't send data; Only used in the testbench. Reset takes about 20us.
        -- Headers for each valid packet received by the LFAA ingest.
        -- LFAA packets are about 8300 bytes long, so at 100Gbps each LFAA packet is about 660 ns long. This is about 200 of the interface clocks (@300MHz)
        -- These signals use i_shared_clk
        i_virtualChannel : in std_logic_vector(15 downto 0); -- Single number which incorporates both the channel and station; this module supports values in the range 0 to 1023.
        i_packetCount    : in std_logic_vector(31 downto 0);
        i_valid          : in std_logic;        
        
        ------------------------------------------------------------------------------------
        -- Data output, to go to the filterbanks.
        -- Data bus output to the Filterbanks
        -- 8 Outputs, each complex data, 8 bit real, 8 bit imaginary.
        --FB_clk  : in std_logic;  -- interface runs off i_shared_clk
        o_sof   : out std_logic;   -- Start of frame, occurs for every new set of channels.
        o_sofFull : out std_logic; -- Start of a full frame, i.e. 128 LFAA packets worth.
        o_data0  : out t_slv_8_arr(1 downto 0);
        o_data1  : out t_slv_8_arr(1 downto 0);
        o_meta01 : out t_CT1_META_out; --   - .HDeltaP(15:0), .VDeltaP(15:0), .frameCount(31:0), virtualChannel(15:0), .valid
        o_data2  : out t_slv_8_arr(1 downto 0);
        o_data3  : out t_slv_8_arr(1 downto 0);
        o_meta23 : out t_CT1_META_out;
        o_data4  : out t_slv_8_arr(1 downto 0);
        o_data5  : out t_slv_8_arr(1 downto 0);
        o_meta45 : out t_CT1_META_out;
        o_data6  : out t_slv_8_arr(1 downto 0);
        o_data7  : out t_slv_8_arr(1 downto 0);
        o_meta67 : out t_CT1_META_out;
        o_valid : out std_logic;
        -------------------------------------------------------------
        -- AXI bus to the shared memory. 
        -- This has the aw, b, ar and r buses (the w bus is on the output of the LFAA decode module)
        -- w bus - write data
        o_m01_axi_aw : out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m01_axi_awready : in std_logic;
        -- b bus - write response
        i_m01_axi_b  : in t_axi4_full_b;   -- (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        -- ar bus - read address
        o_m01_axi_ar      : out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m01_axi_arready : in std_logic;
        -- r bus - read data
        i_m01_axi_r       : in  t_axi4_full_data;
        o_m01_axi_rready  : out std_logic
    );
    
    -- prevent optimisation across module boundaries.
    attribute keep_hierarchy : string;
    attribute keep_hierarchy of corr_ct1_top : entity is "yes";    
    
end corr_ct1_top;

architecture Behavioral of corr_ct1_top is
    
    -- Bus to communicate HBM addresses to the input buffer (ct_vfc_input_buffer) from the memory allocation module (ct_vfc_malloc)
    signal writePacketCount : std_logic_vector(31 downto 0);  -- Packet count from the packet header
    signal writeChannel : std_logic_vector(15 downto 0);  -- virtual channel from the packet header
    signal writePacketCountValid : std_logic;                      -- Goes high to indicate o_packet_count is valid, and stays high until a response comes back
    signal writeAddress : std_logic_vector(23 downto 0); -- Address to write this packet to, in units of 8192 bytes.
    signal writeOK : std_logic;                     -- Write address is valid; if low, then the packet should be dropped as it is either too early or too late.
    signal writeAddressValid : std_logic;
    
    -- register interface
    signal config_rw : t_config_rw;
    signal config_ro : t_config_ro;
    
    --type config_fields_rw_v is array(0 to g_N_STATIONS-1) of t_config_rw;
    --signal global_config_fields_rw_del : config_fields_rw_v;
    signal freeMax : std_logic_vector(23 downto 0);
    
    signal hbm_ready : std_logic;
    signal fullReset, fullResetDel1, fullResetDel2, fullResetDel3, fullResetDel4, fullResetDel5, fullResetDel6 : std_logic;
    signal useNewConfig, useNewConfigDel1, useNewConfigDel2, loadNewConfig : std_logic := '0';
    
    signal validMemWriteAddr : std_logic_vector(18 downto 0);
    signal validMemWrEn : std_logic;
    signal validMemReadAddr : std_logic_vector(18 downto 0);
    signal validMemReadData : std_logic;
    
    signal config_table0_in : t_config_table_0_ram_in;
    signal config_table0_out : t_config_table_0_ram_out;
    
    signal config_table1_in : t_config_table_1_ram_in;
    signal config_table1_out : t_config_table_1_ram_out;
    
    signal output_count_in  : t_config_correlator_output_count_ram_in;
    signal output_count_out : t_config_correlator_output_count_ram_out;
    
    signal virtualChannel : std_logic_vector(15 downto 0);
    signal packetCount : std_logic_vector(32 downto 0);
    type input_fsm_type is (idle, check_range, packet_early, packet_late, generate_aw, generate_aw_wait);
    signal input_fsm : input_fsm_type;
    
    signal AWFIFO_dout : std_logic_vector(31 downto 0);
    signal AWFIFO_empty : std_logic;
    signal AWFIFO_full : std_logic;
    signal AWFIFO_RdDataCount : std_logic_vector(9 downto 0);
    signal AWFIFO_WrDataCount : std_logic_vector(9 downto 0);
    signal AWFIFO_din : std_logic_vector(31 downto 0);
    signal AWFIFO_rst : std_logic;
    signal AWFIFO_wrEn : std_logic;
    signal awStop : std_logic := '0';
    signal awCount : std_logic_vector(3 downto 0) := "0000";
    signal LFAAAddr : std_logic_vector(31 downto 0) := (others => '0');  
    
    signal scanStartPacketCountExt : std_logic_vector(32 downto 0);
    signal packetCountBuffer0, packetCountBuffer1, packetCountBuffer2 : std_logic_vector(32 downto 0);
    signal currentWrBuffer, currentRdBuffer : std_logic_vector(1 downto 0) := "00";
    signal minPacketCount, maxPacketCount : std_logic_vector(32 downto 0);
    signal frameCountReadTrigger, untimedFrameCountStart : std_logic_vector(32 downto 0);
    signal triggerRead, readStart : std_logic := '0';
    signal readBuffer, previousBuffer : std_logic_vector(1 downto 0);
    signal packetCountRdBuffer : std_logic_vector(31 downto 0);
    signal buf0offset, buf1offset, buf2offset : std_logic_vector(32 downto 0);
    signal resetDel2, resetDel1 : std_logic := '0';
    signal validMemSetWrAddr : std_logic_vector(18 downto 0);
    signal validMemSetWrEn : std_logic;
    signal earlyCount : std_logic_vector(15 downto 0) := (others => '0');
    signal lateCount : std_logic_vector(15 downto 0) := (others => '0');
    signal duplicate : std_logic;
    signal duplicateCount : std_logic_vector(7 downto 0) := (others => '0');
    signal dataMissing : std_logic;
    signal missingCount : std_logic_vector(19 downto 0) := (others => '0');
    signal NChannels : std_logic_vector(11 downto 0) := x"400";
    signal clocksPerPacket : std_logic_vector(15 downto 0);
    signal delayTableAddr : std_logic_vector(11 downto 0);
    signal packetCountSwitch : std_logic_vector(32 downto 0);
    signal tableSelect : std_logic;
    signal delayTableData : std_logic_vector(31 downto 0);
    signal haltpacketCountExt : std_logic_vector(32 downto 0);
    signal running : std_logic := '0';
    signal startPacket : std_logic_vector(31 downto 0);
    
    signal chan0, chan1, chan2, chan3 : std_logic_vector(9 downto 0);
    signal ok0, ok1, ok2, ok3 : std_logic := '0';
    signal validOut : std_logic;
    signal validOutDel : std_logic;
    signal outputCountAddr : std_logic_vector(9 downto 0);
    signal outputCountWrData : std_logic_vector(31 downto 0);
    signal outputCountRdDat : std_logic_vector(31 downto 0);
    signal outputCountWrEn : std_logic;
    type validBlocks_fsm_type is (idle, clear_all_start, clear_all_run, readChan0, readChan0Wait0, readChan0Wait1, 
        readChan0Wait2, writeChan0, readChan1, readChan1Wait0, readChan1Wait1, readChan1Wait2, writeChan1, 
        readChan2, readChan2Wait0, readChan2Wait1, readChan2Wait2, writeChan2,
        readChan3, readChan3Wait0, readChan3Wait1, readChan3Wait2, writeChan3);
    signal validBlocks_fsm : validBlocks_fsm_type := idle;
    signal meta01, meta23, meta45, meta67 : t_CT1_META_out;
    signal data0, data1, data2, data3, data4, data5, data6, data7 : t_slv_8_arr(1 downto 0);
    signal FBClk_rst : std_logic;
    signal haltPacketCountEqZero : std_logic;
    signal table0Rd_dat, table1Rd_dat : std_logic_vector(31 downto 0);
    signal validMemRstActive : std_logic;
    signal AWFIFO_rst_del2, AWFIFO_rst_del1 : std_logic;
    
    component ila_beamData
    port (
        clk : in std_logic;
        probe0 : in std_logic_vector(119 downto 0)); 
    end component;
    
    signal valid_del1 : std_logic;
    signal input_packets : std_logic_vector(31 downto 0) := x"00000000";
    signal startup_enable : std_logic := '0';
    
begin
    
    o_validMemRstActive <= validMemRstActive;
    
    ------------------------------------------------------------------------------------
    -- CONFIG (TO/FROM MACE)
    ------------------------------------------------------------------------------------
    -- + create internal resets
    -- + connect config & error signals to MACE 
    -- Note : This relies on the "number_of_slaves" field being set correctly in ct_vfc.peripheral.yaml; it should match g_N_STATIONs
    -- 
    ------------------------------------------------------------------------------------
    E_TOP_CONFIG : entity ct_lib.corr_ct1_reg
    port map (
        MM_CLK  => i_shared_clk, -- in std_logic;
        MM_RST  => i_shared_rst, -- in std_logic;
        SLA_IN  => i_saxi_mosi,  -- IN    t_axi4_lite_mosi;
        SLA_OUT => o_saxi_miso,  -- OUT   t_axi4_lite_miso;

        CONFIG_FIELDS_RW   => config_rw, -- OUT t_config_rw;
        CONFIG_FIELDS_RO   => config_ro, -- IN  t_config_ro;
        
        CONFIG_TABLE_0_IN  => config_table0_in, -- IN  t_config_table_0_ram_in;
		CONFIG_TABLE_0_OUT => config_table0_out, -- OUT t_config_table_0_ram_out;
		CONFIG_TABLE_1_IN  => config_table1_in, -- IN  t_config_table_1_ram_in;
		CONFIG_TABLE_1_OUT => config_table1_out, -- OUT t_config_table_1_ram_out;
        
        CONFIG_CORRELATOR_OUTPUT_COUNT_IN => output_count_in,   -- IN  t_config_psspst_output_count_ram_in;
		CONFIG_CORRELATOR_OUTPUT_COUNT_OUT => output_count_out  -- OUT t_config_psspst_output_count_ram_out
    );
    
    config_table0_in.adr <= delayTableAddr;
    config_table0_in.wr_dat <= (others => '0');
    config_table0_in.wr_en <= '0';
    config_table0_in.rd_en <= '1';
    config_table0_in.clk <= i_shared_clk;
    config_table0_in.rst <= '0';
    
    config_table1_in.adr <= delayTableAddr;
    config_table1_in.wr_dat <= (others => '0');
    config_table1_in.wr_en <= '0';
    config_table1_in.rd_en <= '1';
    config_table1_in.clk <= i_shared_clk;
    config_table1_in.rst <= '0';
	
    config_ro.running <= running; -- std_logic;
    config_ro.frame_count_buffer0 <= packetCountBuffer0(31 downto 0);  -- std_logic_vector(31 downto 0);
    config_ro.frame_count_buffer1 <= packetCountBuffer1(31 downto 0);  -- std_logic_vector(31 downto 0);
    config_ro.frame_count_buffer2 <= packetCountBuffer2(31 downto 0);  -- std_logic_vector(31 downto 0);
    config_ro.active_table <= tableSelect;         -- std_logic;
    config_ro.input_late_count <= lateCount;     -- std_logic_vector(15 downto 0);
    config_ro.input_too_soon_count <= earlyCount; -- std_logic_vector(15 downto 0);
    config_ro.duplicates <= duplicateCount; -- std_logic_vector(7 downto 0);
    config_ro.missing_blocks <= missingCount(19 downto 4); -- std_logic_vector(15 downto 0); Drop low 4 bits since each missing block is reported 16 times.
    config_ro.error_input_overflow <= '0'; -- std_logic;
    config_ro.error_ctc_underflow <= '0'; -- std_logic;
    config_ro.input_packets <= input_packets;
    
    --------------------------------------------------------------------------------------------
    -- Processing of input headers (i_virtualChannel, i_packetCount, i_valid) to generate write addresses
    process(i_shared_clk)
    begin
        if rising_edge(i_shared_clk) then
            
            valid_del1 <= i_valid;
            if valid_del1 = '1' then
                input_packets <= std_logic_vector(unsigned(input_packets) + 1);
            end if;
            
            case input_fsm is
                when idle =>
                    if i_valid = '1' then
                        virtualChannel <= i_virtualChannel;
                        packetCount <= '0' & i_packetCount;  -- Used as a signed value, since we can have negative packet counts for minPacketCount at the start of a run. 
                        input_fsm <= check_range;
                    end if;
                    awCount <= "0000";
                    AWFIFO_wrEn <= '0';
                
                when check_range =>
                    -- check the packet count is not too early or too late
                    AWFIFO_wrEn <= '0';
                    if (signed(packetCount) < signed(minPacketCount)) then
                        input_fsm <= packet_early;
                    elsif (signed(packetCount) > signed(maxPacketCount)) then
                        input_fsm <= packet_late;
                    else
                        input_fsm <= generate_aw_wait; -- Don't go straight to generate_aw, since we need an extra clock to calculate the address.
                    end if;
                    
                when packet_early =>
                    -- signal an error - packet was too early.
                    AWFIFO_wrEn <= '0';
                    input_fsm <= idle;
                    
                when packet_late =>
                    -- signal an error - packet was too late.
                    AWFIFO_wrEn <= '0';
                    input_fsm <= idle;
                
                when generate_aw =>
                    -- Put the write addresses into the FIFO
                    -- Generates 16 write addresses, each 8 beats.
                    -- 16 writes * 8 beats * 64 bytes/beat = 8192 bytes
                    if awStop = '0' then
                        awFIFO_din(31 downto 13) <= LFAAAddr(31 downto 13);
                        awFIFO_din(12 downto 9) <= awCount;
                        awFIFO_din(8 downto 0) <= "000000000";  -- each burst is 8 beats * 64 bytes = 512 bytes, so all writes are 512 byte aligned.
                        awCount <= std_logic_vector(unsigned(awCount) + 1);
                        AWFIFO_wrEn <= '1';
                        if awCount = "1111" then
                            input_fsm <= idle;
                        end if;
                    else
                        input_fsm <= generate_aw_wait;
                        AWFIFO_wrEn <= '0';
                    end if;
                    
                when generate_aw_wait =>
                    -- wait until space is available in the FIFO
                    if awStop = '0' then
                        input_fsm <= generate_aw;
                    end if;
                    AWFIFO_wrEn <= '0';
                    
                when others =>
                    input_fsm <= idle;
            end case;
            
            if (unsigned(AWFIFO_WrDataCount) > 500) then
                awStop <= '1';
            else
                awStop <= '0';
            end if;
            
            if (unsigned(config_rw.halt_packet_count) = 0) then
                haltPacketCountEqZero <= '1';   -- when zero, never halt.
            else
                haltPacketCountEqZero <= '0';
            end if; 
            
            if input_fsm = check_range then
                if ((signed(packetCount) >= signed(scanStartPacketCountExt)) and
                    (haltPacketCountEqZero = '1' or (signed(packetCount) < signed(haltpacketCountExt)))) then
                    running <= '1';
                else
                    running <= '0';
                end if;
            end if;
            
            -- Get the memory address to write the packet to.
            LFAAAddr(12 downto 0) <= "0000000000000"; -- 8192 bytes per LFAA packet, so low 13 bits are zeros.
            LFAAAddr(29 downto 20) <= virtualChannel(9 downto 0);
            
            buf0offset <= std_logic_vector(signed(packetCount) - signed(packetCountBuffer0));
            buf1offset <= std_logic_vector(signed(packetCount) - signed(packetCountBuffer1));
            buf2offset <= std_logic_vector(signed(packetCount) - signed(packetCountBuffer2));
            
            -- Select which of the 4 buffers to use. This is still qualified in the state machine by checks on whether the packet is in range.
            if ((signed(buf0offset) >= 0) and (signed(buf0offset) < g_SPS_PACKETS_PER_FRAME)) then
                LFAAAddr(31 downto 30) <= "00";
                LFAAAddr(19 downto 13) <= buf0offset(6 downto 0);
            elsif ((signed(buf1offset) >= 0) and (signed(buf1offset) < g_SPS_PACKETS_PER_FRAME)) then
                LFAAAddr(31 downto 30) <= "01";
                LFAAAddr(19 downto 13) <= buf1offset(6 downto 0);
            else -- if ((signed(buf2offset) >= 0) and (signed(buf2offset) < g_LFAA_BLOCKS_PER_FRAME)) then
                LFAAAddr(31 downto 30) <= "10";
                LFAAAddr(19 downto 13) <= buf2offset(6 downto 0);
            end if;
            
            ----------------------------------------------------------------------
            -- Buffer management
            -- Two options for managing the four buffers :
            --  (1) Untimed.
            --       - At startup, the first three buffers are assigned to start at packet counts of
            --           buffer "10" : config_rw.scanstartpacketcount - g_LFAA_BLOCKS_PER_FRAME,
            --           buffer "00" : config_rw.scanstartpacketcount, 
            --           buffer "01" : config_rw.scanstartpacketcount + g_LFAA_BLOCKS_PER_FRAME,
            --       - When we receive a packet with a packet count that places it in buffer "01",
            --         with a frame count within the buffer >= config_rw.untimed_framecount_start, 
            --         then we start reading from buffer "00", with preload from buffer "10".
            --         
            --  (2) Timed.
            --  
            untimedFrameCountStart(15 downto 0) <= config_rw.untimed_framecount_start;
            untimedFrameCountStart(32 downto 16) <= (others => '0');
            
            if resetDel1 = '1' and resetDel2 = '0' then
                currentWrBuffer <= "00";
                currentRdBuffer <= "10";   -- although we don't actually do a read out on the first frame
                packetCountBuffer0 <= scanStartPacketCountExt;
                packetCountBuffer1 <= std_logic_vector(signed(scanStartPacketCountExt) + g_SPS_PACKETS_PER_FRAME);  -- Next frame
                packetCountBuffer2 <= std_logic_vector(signed(scanStartPacketCountExt) - g_SPS_PACKETS_PER_FRAME);  -- Previous frame
                frameCountReadTrigger <= std_logic_vector(signed(scanStartPacketCountExt) + g_SPS_PACKETS_PER_FRAME + signed(untimedFrameCountStart));
                minPacketCount <= std_logic_vector(signed(scanStartPacketCountExt) - 2); -- -2 so that it includes the preload data.
                maxPacketCount <= std_logic_vector(signed(scanStartPacketCountExt) + 3*g_SPS_PACKETS_PER_FRAME - 2); -- -2 so we don't overwrite preload data for the current frame being read out with future data.
                triggerRead <= '0';
            elsif ((input_fsm = check_range) and (signed(packetCount) >= signed(frameCountReadTrigger))) then 
                -- Advance to the next frame
                currentRdBuffer <= currentWrBuffer;
                case currentWrBuffer is
                    when "00" => currentWrBuffer <= "01";
                    when "01" => currentWrBuffer <= "10";
                    when others => currentWrBuffer <= "00";
                end case;
                frameCountReadTrigger <= std_logic_vector(unsigned(frameCountReadTrigger) + g_SPS_PACKETS_PER_FRAME);
                if currentWrBuffer = "00" then
                    -- We are far enough into buffer 1 to start reading from buffer 0, with preload data coming from buffer 2.
                    -- For the purpose of writing new LFAA data, advance buffer 2 (although the end of buffer2 is still used for preload data). 
                    packetCountBuffer2 <= std_logic_vector(unsigned(packetCountBuffer2) + 3 * g_SPS_PACKETS_PER_FRAME);
                elsif currentWrBuffer = "01" then
                    packetCountBuffer0 <= std_logic_vector(unsigned(packetCountBuffer0) + 3 * g_SPS_PACKETS_PER_FRAME);
                else
                    packetCountBuffer1 <= std_logic_vector(unsigned(packetCountBuffer1) + 3 * g_SPS_PACKETS_PER_FRAME);
                end if;
                minPacketCount <= std_logic_vector(unsigned(minPacketCount) + g_SPS_PACKETS_PER_FRAME);
                maxPacketCount <= std_logic_vector(unsigned(maxPacketCount) + g_SPS_PACKETS_PER_FRAME);
                triggerRead <= '1';
            else
                triggerRead <= '0';
            end if;
            
            if resetDel1 = '1' and resetDel2 = '0' then
                NChannels <= '0' & i_virtualChannels;
                clocksPerPacket <= config_rw.output_cycles;
            end if;
            
            resetDel1 <= config_rw.full_reset;
            resetDel2 <= resetDel1;
            if resetDel1 = '1' and resetDel2 = '0' then
                AWFIFO_rst <= '1';
            else
                AWFIFO_rst <= '0';
            end if;
            if resetDel1 = '0' and resetDel2 = '1' then
                startup_enable <= '1';
            end if;
            o_rst <= resetDel2;
            
            if AWFIFO_rst = '1' then
                earlyCount <= (others => '0');
                lateCount <= (others => '0');
                duplicateCount <= (others => '0');
                missingCount <= (others => '0');
            else
                if input_fsm = packet_early then
                    if earlyCount = "1111111111111111" then
                        earlyCount <= "1000000000000000"; -- make top bit sticky.
                    else
                        earlyCount <= std_logic_vector(unsigned(earlyCount) + 1); 
                    end if;
                end if;
                if input_fsm = packet_late then
                    if lateCount = "1111111111111111" then
                        lateCount <= "1000000000000000";
                    else
                        lateCount <= std_logic_vector(unsigned(lateCount) + 1);
                    end if;
                end if;
                if duplicate = '1' then
                    if duplicateCount = "11111111" then
                        duplicateCount <= "10000000";
                    else
                        duplicateCount <= std_logic_vector(unsigned(duplicateCount) + 1);
                    end if;
                end if;
                if dataMissing = '1' then
                    if missingCount = "11111111111111111111" then
                        missingCount <= "10000000000000000000";
                    else
                        missingCount <= std_logic_vector(unsigned(missingCount) + 1);
                    end if;
                end if;
            end if;
            
            -- Control signals to the readout module
            readStart <= triggerRead and running and startup_enable;
            readBuffer <= currentRdBuffer;
            case currentRdBuffer is
                -- 3 buffers, "00","01" and "10", so prior to "00" was "10".
                when "00" => previousBuffer <= "10";
                when "01" => previousBuffer <= "00";
                when "10" => previousBuffer <= "01";
                when others => previousBuffer <= "00";  -- should be impossible.
            end case;
            if currentRdBuffer = "00" then
                packetCountRdBuffer <= packetCountBuffer0(31 downto 0);
            elsif currentRdBuffer = "01" then
                packetCountRdBuffer <= packetCountBuffer1(31 downto 0);
            else --  currentRdBuffer = "10" then
                packetCountRdBuffer <= packetCountBuffer2(31 downto 0);
            end if;
            
            packetCountSwitch <= '0' & config_rw.packet_count;
            if resetDel1 = '1' then
                tableSelect <= config_rw.table_select;
            elsif readStart = '1' then
                if (unsigned(packetCountSwitch) = 0 or (unsigned(packetCountSwitch) >= unsigned(packetCountRdBuffer))) then
                    tableSelect <= config_rw.table_select;
                end if;
            end if;
            
            if tableSelect = '0' then
                startPacket <= config_rw.table0_startpacket;
            else
                startPacket <= config_rw.table1_startpacket;
            end if;
            
            table0Rd_dat <= config_table0_out.rd_dat;
            table1Rd_dat <= config_table1_out.rd_dat;
            
            if tableSelect = '0' then
                delayTableData <= table0Rd_dat;
            else
                delayTableData <= table1Rd_dat;
            end if;
        end if;
    end process;
    
    scanStartPacketCountExt <= '0' & config_rw.scanstartpacketcount;
    haltpacketCountExt <= '0' & config_rw.halt_packet_count;
    
    -- FIFO for write addresses 
    -- Input to the fifo comes from "input_fsm". It is read as fast as addresses are accepted by the shared memory bus.
    fifo_aw_inst : xpm_fifo_sync
    generic map (
        DOUT_RESET_VALUE => "0",    -- String
        ECC_MODE => "no_ecc",       -- String
        FIFO_MEMORY_TYPE => "auto", -- String
        FIFO_READ_LATENCY => 1,     -- DECIMAL
        FIFO_WRITE_DEPTH => 512,     -- DECIMAL; Allow up to 32 outstanding write requests.
        FULL_RESET_VALUE => 0,      -- DECIMAL
        PROG_EMPTY_THRESH => 10,    -- DECIMAL
        PROG_FULL_THRESH => 10,     -- DECIMAL
        RD_DATA_COUNT_WIDTH => 10,  -- DECIMAL
        READ_DATA_WIDTH => 32,      -- DECIMAL
        READ_MODE => "fwft",        -- String
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "0404", -- String  -- bit 2 and bit 10 enables write data count and read data count
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 32,     -- DECIMAL
        WR_DATA_COUNT_WIDTH => 10   -- DECIMAL
    )
    port map (
        almost_empty => open,     -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
        almost_full => open,      -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
        data_valid => open,       -- Need to set bit 12 of "USE_ADV_FEATURES" to enable this output. 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
        dbiterr => open,          -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
        dout => AWFIFO_dout,      -- READ_DATA_WIDTH-bit output: Read Data: The output data bus is driven when reading the FIFO.
        empty => AWFIFO_empty,    -- 1-bit output: Empty Flag: When asserted, this signal indicates that- the FIFO is empty.
        full => AWFIFO_full,      -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full.
        overflow => open,         -- 1-bit output: Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected, because the FIFO is full
        prog_empty => open,       -- 1-bit output: Programmable Empty: This signal is asserted when the number of words in the FIFO is less than or equal to the programmable empty threshold value.
        prog_full => open,        -- 1-bit output: Programmable Full: This signal is asserted when the number of words in the FIFO is greater than or equal to the programmable full threshold value.
        rd_data_count => AWFIFO_RdDataCount, -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
        rd_rst_busy => open,      -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
        sbiterr => open,          -- 1-bit output: Single Bit Error: Indicates that the ECC decoder detected and fixed a single-bit error.
        underflow => open,        -- 1-bit output: Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected because the FIFO is empty.
        wr_ack => open,           -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.
        wr_data_count => AWFIFO_WrDataCount, -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        wr_rst_busy => open,      -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
        din => AWFIFO_din,        -- WRITE_DATA_WIDTH-bit input: Write Data: The input data bus used when writing the FIFO.
        injectdbiterr => '0',     -- 1-bit input: Double Bit Error Injection
        injectsbiterr => '0',     -- 1-bit input: Single Bit Error Injection: 
        rd_en => i_m01_axi_awready, -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO. 
        rst => AWFIFO_rst,        -- 1-bit input: Reset: Must be synchronous to wr_clk.
        sleep => '0',             -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
        wr_clk => i_shared_clk,   -- 1-bit input: Write clock: Used for write operation. wr_clk must be a free running clock.
        wr_en => AWFIFO_wrEn      -- 1-bit input: Write Enable: 
    );
    
    o_m01_axi_aw.valid <= not AWFIFO_empty; --  out std_logic;
    o_m01_axi_aw.addr  <= x"00" & AWFIFO_dout(31 downto 0); -- out std_logic_vector(29 downto 0);
    -- Number of beats in a burst -1; 
    -- 8 beats * 64 byte wide bus = 512 bytes per burst, so 16 bursts for a full LFAA packet of 8192 bytes.
    -- Warning : The "wlast" signal generated in the LFAA ingest module (in "LFAAProcess100G.vhd") assumes that this value is 7 (=8 beats per burst).
    o_m01_axi_aw.len   <= "00000111"; -- out std_logic_vector(7 downto 0); 
    
    -----------------------------------------------------------------------------------------------
    -- Valid memory keeps track of whether data has been written to each 8192 byte block in the shared memory.
    -- One valid bit for every 8192 bytes.
    -- 1Gbyte/8192 bytes = 2^30/2^13 = 2^17 bits
    -- 
    
    -- When the last write address goes for an LFAA packet, then we assume we are done writing and can set the bit in the valid memory.
    process(i_shared_clk)
    begin
        if rising_edge(i_shared_clk) then
            if (AWFIFO_empty = '0') and (i_m01_axi_awready = '1') and (AWFIFO_dout(12 downto 9) = "1111") then
                validMemSetWrEn <= '1';
                validMemSetWrAddr <= AWFIFO_dout(31 downto 13);
            else
                validMemSetWrEn <= '0';
            end if;
        end if;
    end process;
    
    validmemInst : entity ct_lib.corr_ct1_valid
    port map (
        i_clk => i_shared_clk,
        i_rst => AWFIFO_rst,
        o_rstActive => validMemRstActive,
        -- Set valid
        i_setAddr   => validMemSetWrAddr,  -- in(18:0)
        i_setValid  => validMemSetWrEn,    -- in std_logic;
        o_duplicate => duplicate,          -- out std_logic;
        -- clear valid
        i_clearAddr => validMemWriteAddr,  -- in(18:0)
        i_clearValid => validMemWrEn,      -- in std_logic;
        -- Read contents
        i_readAddr => validMemReadAddr,    -- in(18:0)
        o_readData => validMemReadData     -- out std_logic;
    );
    
    -----------------------------------------------------------------------------------------------
    -- readout of a frame
    
    readout : entity ct_lib.corr_ct1_readout
    generic map (
        g_SPS_PACKETS_PER_FRAME => g_SPS_PACKETS_PER_FRAME
    )
    port map (
        shared_clk => i_shared_clk, -- in std_logic; Shared memory clock
        i_rst      => AWFIFO_rst,
        -- input signals to trigger reading of a buffer
        i_currentBuffer => readBuffer,        -- in(1:0);
        i_previousBuffer => previousBuffer,   -- in(1:0);
        i_readStart => readStart,             -- in std_logic; -- Pulse to start readout from readBuffer
        i_packetCount => packetCountRdBuffer, -- in(31:0)
        i_Nchannels => NChannels,             -- in(11:0); -- Total number of virtual channels to read out,
        i_clocksPerPacket => clocksPerPacket, -- in(15:0)
        -- Reading Coarse and fine delay info from the registers
        -- In the registers, word 0, bits 15:0  = Coarse delay, word 0 bits 31:16 = Hpol DeltaP, word 1 bits 15:0 = Vpol deltaP, word 1 bits 31:16 = deltaDeltaP
        o_delayTableAddr => delayTableAddr, -- out std_logic_vector(10 downto 0); -- 2 addresses per virtual channel, up to 1024 virtual channels
        i_delayTableData => delayTableData, -- in std_logic_vector(31 downto 0); -- Data from the delay table with 3 cycle latency. 
        i_startPacket    => startPacket,    -- in std_logic_vector(31 downto 0) -- LFAA Packet count that the fine delays in the delay table are relative to. Fine delays are based on the first LFAA sample that contributes to a given filterbank output
        
        -- Read and write to the valid memory, to check the place we are reading from in the HBM has valid data
        o_validMemReadAddr => validMemReadAddr, -- out (18 downto 0); -- 8192 bytes per LFAA packet, 1 GByte of memory, so 1Gbyte/8192 bytes = 2^30/2^13 = 2^17
        i_validMemReadData => validMemReadData, -- in std_logic;  -- read data returned 3 clocks later.
        o_validMemWriteAddr => validMemWriteAddr, -- out (18:0); -- write always clear the memory (mark the block as invalid).
        o_validMemWrEn      => validMemWrEn,      -- out std_logic;
        
        -- Data output to the filterbanks
        -- FB_clk  => FB_clk,  -- in std_logic; Interface runs off shared_clk
        o_sof   => o_sof,   -- out std_logic; start of frame.
        o_sofFull => o_sofFull, -- out std_logic; -- start of a full frame, i.e. 60ms of data.
        
        o_HPol0 => data0,  -- out t_slv_8_arr(1 downto 0);
        o_VPol0 => data1,  -- out t_slv_8_arr(1 downto 0);
        o_meta0 => meta01, -- out t_CT1_META_out;
        
        o_HPol1 => data2,  -- out t_slv_8_arr(1 downto 0);
        o_VPol1 => data3,  -- out t_slv_8_arr(1 downto 0);
        o_meta1 => meta23, -- out t_CT1_META_out;
        
        o_HPol2 => data4,  -- out t_slv_8_arr(1 downto 0);
        o_VPol2 => data5,  -- out t_slv_8_arr(1 downto 0);
        o_meta2 => meta45, -- out t_CT1_META_out;
        
        o_HPol3 => data6,  -- 
        o_Vpol3 => data7,  --
        o_meta3 => meta67, --
        
        o_valid => validOut, -- out std_logic;
        
        -- AXI read address and data input buses
        -- ar bus - read address
        o_axi_ar      => o_m01_axi_ar,      -- out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_axi_arready => i_m01_axi_arready, -- in std_logic;
        -- r bus - read data
        i_axi_r       => i_m01_axi_r,      -- in  t_axi4_full_data;
        o_axi_rready  => o_m01_axi_rready, -- out std_logic;
        -- errors and debug
        -- Flag an error; we were asked to start reading but we haven't finished reading the previous frame.
        o_readOverflow => open,       -- out std_logic -- pulses high in the shared_clk domain.
        o_Unexpected_rdata => open,   -- out std_logic -- data was returned from the HBM that we didn't expect (i.e. no read request was put in for it)
        o_dataMissing => dataMissing  -- out std_logic -- Read from a HBM address that we haven't written data to. Most reads are 8 beats = 8*64 = 512 bytes, so this will go high 16 times per missing LFAA packet.
    );
    o_data0 <= data0;
    o_data1 <= data1;
    o_data2 <= data2;
    o_data3 <= data3;
    o_data4 <= data4;
    o_data5 <= data5;
    o_data6 <= data6;
    o_data7 <= data7;
    o_valid <= validOut;
    o_meta01 <= meta01;
    o_meta23 <= meta23;
    o_meta45 <= meta45;
    o_meta67 <= meta67;
    
    
    -- Everything on the same clock domain;
    process(i_shared_clk)
    begin
        if rising_edge(i_shared_clk) then
            AWFIFO_rst_del1 <= AWFIFO_rst;
            AWFIFO_rst_del2 <= AWFIFO_rst_del1;
            FBClk_rst <= AWFIFO_rst_del1 and (not AWFIFO_rst_del2);
        end if;
    end process;
    
    -- Count valid blocks output to the filterbanks for each channel
    process(i_shared_clk)
    begin
        if rising_edge(i_shared_clk) then
            validOutdel <= validOut;
            
            outputCountRdDat <= output_count_out.rd_dat;
            
            -- fsm to go through and do read-modify-write for each of the output channels to count valid packets.
            if FBClk_rst = '1' then
                validBlocks_fsm <= clear_all_start;
            else
                case validBlocks_fsm is
                    when idle =>
                        if validOut = '1' and validOutdel = '0' then
                            chan0 <= meta01.virtualChannel(9 downto 0);
                            chan1 <= meta23.virtualChannel(9 downto 0);
                            chan2 <= meta45.virtualChannel(9 downto 0);
                            chan3 <= meta67.virtualChannel(9 downto 0);
                            if data0(0) = "10000000" then
                                -- first sample in the packet is flagged,
                                -- either data was missing or it is RFI
                                ok0 <= '0';
                            else
                                ok0 <= '1';
                            end if;
                            if data2(0) = "10000000" then
                                ok1 <= '0';
                            else
                                ok1 <= '1';
                            end if;
                            if data4(0) = "10000000" then
                                ok2 <= '0';
                            else
                                ok2 <= '1';
                            end if;
                            if data6(0) = "10000000" then
                                ok3 <= '0';
                            else
                                ok3 <= '1';
                            end if;
                            validBlocks_fsm <= readChan0;
                        end if;
                        outputCountWrEn <= '0';
                        
                    when clear_all_start =>
                        outputCountAddr <= (others => '0');
                        outputCountWrData <= (others => '0');
                        outputCountWrEn <= '1';
                        validBlocks_fsm <= clear_all_run;
                        
                    when clear_all_run => 
                        outputCountAddr <= std_logic_vector(unsigned(outputCountAddr) + 1);
                        if outputCountAddr = "1111111111" then
                            validBlocks_fsm <= idle;
                            outputCountWrEn <= '0';
                        end if;
                        
                    when readChan0 =>
                        validBlocks_fsm <= readChan0Wait0;
                        outputCountAddr <= chan0;
                        outputCountWrEn <= '0';
                    
                    when readChan0Wait0 =>  -- address to the memory is correct for chan0 in this state
                        validBlocks_fsm <= readChan0Wait1;
                        outputCountWrEn <= '0';
                    
                    when readChan0Wait1 =>
                        validBlocks_fsm <= readChan0Wait2;
                        outputCountWrEn <= '0';
                    
                    when readChan0Wait2 =>
                        validBlocks_fsm <= writeChan0;
                        outputCountWrEn <= '0';
                    
                    when writeChan0 =>   -- read data for chan0 is valid in this state.
                        validBlocks_fsm <= readChan1;
                        outputCountWrData <= std_logic_vector(unsigned(outputCountRdDat) + 1);
                        outputCountWrEn <= ok0;
                        
                    when readChan1 =>
                        validBlocks_fsm <= readChan1Wait0;
                        outputCountWrEn <= '0';
                        outputCountAddr <= chan1;
                    
                    when readChan1Wait0 =>
                        validBlocks_fsm <= readChan1Wait1;
                        outputCountWrEn <= '0';
                    
                    when readChan1Wait1 =>
                        validBlocks_fsm <= readChan1Wait2;
                        outputCountWrEn <= '0';
                    
                    when readChan1Wait2 =>
                        validBlocks_fsm <= writeChan1;
                        outputCountWrEn <= '0';
                        
                    when writeChan1 =>
                        validBlocks_fsm <= readChan2;
                        outputCountWrData <= std_logic_vector(unsigned(outputCountRdDat) + 1);
                        outputCountWrEn <= ok1;
                    
                    when readChan2 =>
                        validBlocks_fsm <= readChan2Wait0;
                        outputCountWrEn <= '0';
                        outputCountAddr <= chan2;
                    
                    when readChan2Wait0 =>
                        validBlocks_fsm <= readChan2Wait1;
                        outputCountWrEn <= '0';
                    
                    when readChan2Wait1 =>
                        validBlocks_fsm <= readChan2Wait2;
                        outputCountWrEn <= '0';
                    
                    when readChan2Wait2 =>
                        validBlocks_fsm <= writeChan2;
                        outputCountWrEn <= '0';
                    
                    when writeChan2 =>
                        validBlocks_fsm <= readChan3;
                        outputCountWrData <= std_logic_vector(unsigned(outputCountRdDat) + 1);
                        outputCountWrEn <= ok2;
                    
                    when readChan3 =>
                        validBlocks_fsm <= readChan3Wait0;
                        outputCountWrEn <= '0';
                        outputCountAddr <= chan3;
                    
                    when readChan3Wait0 =>
                        validBlocks_fsm <= readChan3Wait1;
                        outputCountWrEn <= '0';
                    
                    when readChan3Wait1 =>
                        validBlocks_fsm <= readChan3Wait2;
                        outputCountWrEn <= '0';
                    
                    when readChan3Wait2 =>
                        validBlocks_fsm <= writeChan3;
                        outputCountWrEn <= '0';
                    
                    when writeChan3 =>
                        validBlocks_fsm <= idle;
                        outputCountWrData <= std_logic_vector(unsigned(outputCountRdDat) + 1);
                        outputCountWrEn <= ok3;
                        
                    when others =>
                        validBlocks_fsm <= idle;
                end case;
            end if;
        end if;
    end process;
    
    output_count_in.adr <= outputCountAddr;
    output_count_in.wr_dat <= outputCountWrData;
    output_count_in.wr_en <= outputCountWrEn;
    output_count_in.rd_en <= '1';
    output_count_in.clk <= i_shared_clk;
    output_count_in.rst <= '0';
    
    
end Behavioral;
