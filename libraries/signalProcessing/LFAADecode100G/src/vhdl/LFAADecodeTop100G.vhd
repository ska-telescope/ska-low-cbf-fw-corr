------------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 08.03.2019 15:11:37
-- Module Name: LFAADecodeTop - Behavioral
-- Description: 
--  Decode LFAA packets.
-- Assumptions:
--  - No Q-tags for ethernet frames; ethertype field will always be 2 bytes
--  - IPv4 will always be 20 bytes long
--  - 40GE MAC will always put at least 8 bytes of idle time on the data_rx_sosi bus
--
--  
--  The timestamp of the most recent packet for each virtual channel is recorded
--  here with a fractional part using 24 bits, counting from 0 to 15624999, i.e. in units of 64
--  ns, and a 32 bit integer part.
--
-- Structure :
--  - LFAAProcess : Takes in the data from the 40GE interface, validates it and outputs packets 
--                  for downstream processing, with a header that contains the virtual channel.
--  - dummyProcess : Ignores the 100GE interface, and instead outputs packets in accord with the
--                   virtual channel table, with data generated from an LFSR.
--  - muxBlock : Grants either LFAAProcess or dummyProcess access to the virtual channel table 
--               and virtual channel statistics memories, which reside in the registers.
--  - registers : register interface for control and statistics registers, and also for the 
--                virtual channel table and 
--  - ptpBlock : transfer ptp time to the data_clk domain.
------------------------------------------------------------------------------------

library IEEE, axi4_lib, xpm, LFAADecode100G_lib, ctc_lib, dsp_top_lib, technology_lib;
--use ctc_lib.ctc_pkg.all;
use DSP_top_lib.DSP_top_pkg.all;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use axi4_lib.axi4_stream_pkg.ALL;
use axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.ALL;
use xpm.vcomponents.all;
use LFAADecode100G_lib.LFAADecode100G_lfaadecode100G_reg_pkg.ALL;
USE technology_lib.tech_mac_100g_pkg.ALL;

entity LFAADecodeTop100G is
    port(
        -- Data in from the 100GE MAC
        i_axis_tdata   : in std_logic_vector(511 downto 0); -- 64 bytes of data, 1st byte in the packet is in bits 7:0.
        i_axis_tkeep   : in std_logic_vector(63 downto 0);  -- one bit per byte in i_axi_tdata
        i_axis_tlast   : in std_logic;                      
        i_axis_tuser   : in std_logic_vector(79 downto 0);  -- Timestamp for the packet.
        i_axis_tvalid  : in std_logic;
        i_data_clk     : in std_logic;     -- 322 MHz from the 100GE MAC; note 512 bits x 322 MHz = 165 Mbit/sec, so even full rate traffic will have .valid low 1/3rd of the time.
        i_data_rst     : in std_logic;
        -- Data out to corner turn module.
        -- This is just the header for each packet. The data part goes direct to the HBM via the wdata part of the AXI-full bus 
        --  
        o_virtualChannel : out std_logic_vector(15 downto 0); -- Single number which incorporates both the channel and station.
        o_packetCount    : out std_logic_vector(31 downto 0);
        o_valid          : out std_logic;
        -- wdata portion of the AXI-full external interface (should go directly to the external memory)
        o_axi_w         : out t_axi4_full_data; -- w data bus : out t_axi4_full_data; (.valid, .data(511:0), .last, .resp(1:0)) => o_m01_axi_w,    -- w data bus (.wvalid, .wdata, .wlast)
        i_axi_wready    : in std_logic;
        -- Registers AXI Lite Interface
        i_s_axi_mosi     : in t_axi4_lite_mosi;
        o_s_axi_miso     : out t_axi4_lite_miso;
        i_s_axi_clk      : in std_logic;
        i_s_axi_rst      : in std_logic;
        -- registers AXI Full interface
        i_vcstats_MM_IN  : in  t_axi4_full_mosi;
        o_vcstats_MM_OUT : out t_axi4_full_miso;
        -- Output from the registers that are used elsewhere (on i_s_axi_clk)
        o_totalChannels  : out std_logic_vector(11 downto 0);
        -- debug ports
        o_dbg            : out std_logic_vector(13 downto 0)
   );
end LFAADecodeTop100G;

architecture Behavioral of LFAADecodeTop100G is

    signal reg_rw    : t_statctrl_rw;
    signal LFAAreg_count, testReg_count, reg_count : t_statctrl_count;
    
    signal LFAAData_out, testdata_out, data_out : std_logic_vector(127 downto 0);
    signal LFAAValid_out, testValid_out, valid_out : std_logic;
    signal LFAAStationSel_out : std_logic;

    signal data_out_del1, data_out_del2, data_out_del3 : std_logic_vector(127 downto 0);
    signal stationSel_out_del1, stationSel_out_del2, stationSel_out_del3 : std_logic;
    signal valid_out_del1, valid_out_del2, valid_out_del3 : std_logic;
    signal count_out_del1, count_out_del2, count_out_del3 : std_logic_vector(2 downto 0);
    signal data_sum0_del1, data_sum1_del1, data_sum_del2, data_sum_del3 : std_logic_vector(31 downto 0);
    
    signal ptp_hold, ptp_out : std_logic_vector(58 downto 0);
    signal ptp_send : std_logic := '0';
    signal ptp_rcv : std_logic;
    signal ptp_valid : std_logic;
    signal data_clk_vec : std_logic_vector(0 downto 0);
    
    -- One only of the "LFAAProcess" and the "TestProcess" modules controls the memories in the registers.
    signal LFAAVCTable_addr, testVCTable_addr : std_logic_vector(9 downto 0);
    signal LFAAstats_wr_data, testStats_wr_data : std_logic_vector(31 downto 0);
    signal LFAAstats_we, testStats_we : std_logic;
    signal LFAAstats_addr, testStats_addr : std_logic_vector(12 downto 0); 
    signal VCTable_ram_in : t_statctrl_vctable_ram_in;
    signal VCTable_ram_out : t_statctrl_vctable_ram_out;
    
    signal VCStats_ram_in_wr_dat : std_logic_vector(31 downto 0);
    signal VCStats_ram_in_wr_en : std_logic; 
    signal VCStats_ram_in_adr : std_logic_vector(12 downto 0);
    signal VCStats_ram_out_rd_dat : std_logic_vector(31 downto 0);
    
    signal stationSel_out, testStationSel_out : std_logic;
    signal cdcSendCount : std_logic_vector(3 downto 0) := "0000";
    signal cdcSend : std_logic := '0';
    signal cdcSrcIn, cdcDestOut : std_logic_vector(11 downto 0);
    signal cdcDestReq, cdcRcv : std_logic;
    signal AXI_totalChannels : std_logic_vector(11 downto 0);
    
begin
    
    -------------------------------------------------------------------------------------------------
    -- Process packets from the 100GE LFAA input 
    
    LFAAProcessInst : entity LFAADecode100G_lib.LFAAProcess100G
    port map(
        -- Data in from the 100GE MAC
        i_axis_tdata   => i_axis_tdata,
        i_axis_tkeep   => i_axis_tkeep,
        i_axis_tlast   => i_axis_tlast,
        i_axis_tuser   => i_axis_tuser,
        i_axis_tvalid  => i_axis_tvalid,
        i_data_clk     => i_data_clk,     -- in std_logic;     -- 312.5 MHz for 40GE MAC
        i_data_rst     => i_data_rst,     -- in std_logic;
        -- Data out to the memory interface; This is the wdata portion of the AXI full bus.
        i_ap_clk       => i_s_axi_clk,  -- in  std_logic;
        o_axi_w        => o_axi_w,      -- out t_axi4_full_data
        i_axi_wready   => i_axi_wready, -- in std_logic;
        -- Only the header data goes to the corner turn.
        o_virtualChannel => o_virtualChannel, -- out std_logic_vector(15 downto 0); -- Single number which incorporates both the channel and station.
        o_packetCount  => o_packetCount,    -- out std_logic_vector(31 downto 0);
        o_valid        => o_valid,          -- out std_logic;
        -- Interface to the registers
        i_reg_rw       => reg_rw,         -- in t_statctrl_rw;
        o_reg_count    => LFAAreg_count,  -- out t_statctrl_count;
        -- Virtual channel table memory in the registers
        o_searchAddr      => LFAAVCTable_addr,       -- out(11:0); -- read address to the VCTable_ram in the registers.
        i_VCTable_rd_data => VCTable_ram_out.rd_dat, -- in(31:0);  -- read data from VCTable_ram in the registers; assumed valid 2 clocks after searchAddr.
        -- Virtual channel stats in the registers.
        o_statsWrData  => VCStats_ram_in_wr_dat,  -- out(31:0);
        o_statsWE      => VCStats_ram_in_wr_en,   -- out std_logic;
        o_statsAddr    => VCStats_ram_in_adr,     -- out(12:0);
        i_statsRdData  => VCStats_ram_out_rd_dat, -- in(31:0)
        -- debug ports
        o_dbg             => o_dbg   -- out(13:0)
    );
    
    -- VCTable memory inputs
    VCTable_ram_in.rd_en <= '1';
    VCTable_ram_in.clk <= i_data_clk;
    VCTable_ram_in.wr_dat <= (others => '0'); -- STD_LOGIC_VECTOR(31 downto 0); -- never write to the virtual channel table.
    VCTable_ram_in.wr_en <= '0';
    VCTable_ram_in.adr <= LFAAVCTable_addr; -- STD_LOGIC_VECTOR(11 downto 0);
    VCTable_ram_in.rst <= '0';
    
    reg_count <= LFAAreg_count;
    
    ---------------------------------------------------------------------------------------------------
    -- Register interface
    regif : entity work.LFAADecode100G_lfaadecode100G_reg
    --   GENERIC (g_technology : t_technology := c_tech_select_default);
    port map (
        MM_CLK               => i_s_axi_clk, --  IN    STD_LOGIC;
        MM_RST               => i_s_axi_rst, --  IN    STD_LOGIC;
        st_clk_statctrl      => data_clk_vec,
        st_rst_statctrl      => "0",
        SLA_IN               => i_s_axi_mosi, --  IN    t_axi4_lite_mosi;
        SLA_OUT              => o_s_axi_miso, --  OUT   t_axi4_lite_miso;
        statctrl_fields_rw   => reg_rw,       --  out t_statctrl_rw;
        statctrl_fields_count => reg_count,   --  in t_statctrl_count;
        count_rsti           => '0',            -- in std_logic := '0'
        statctrl_VCTable_in  => VCTable_ram_in, -- in t_statctrl_vctable_ram_in;
        statctrl_VCTable_out => VCTable_ram_out -- OUT t_statctrl_vctable_ram_out;
    );
    
    data_clk_vec(0) <= i_data_clk; 

    regif2 : entity work.LFAADecode100G_lfaadecode100G_vcstats_ram
    port map (
        CLK_A       => i_s_axi_clk, -- in STD_LOGIC;
        RST_A       => i_s_axi_rst, -- in STD_LOGIC;
        CLK_B       => i_data_clk,  -- in STD_LOGIC;
        RST_B       => '0',         -- in STD_LOGIC;
        MM_IN       => i_vcstats_MM_IN,  -- in  t_axi4_full_mosi;
        MM_OUT      => o_vcstats_MM_out, -- out t_axi4_full_miso;
        --
        user_we     => VCStats_ram_in_wr_en,  --  in    std_logic;
        user_addr   => VCStats_ram_in_adr,    --  in    std_logic_vector(g_ram_b.adr_w-1 downto 0);
        user_din    => VCStats_ram_in_wr_dat, --  in    std_logic_vector(g_ram_b.dat_w-1 downto 0);
        user_dout   => VCStats_ram_out_rd_dat --  out   std_logic_vector(g_ram_b.dat_w-1 downto 0)  
    );
    
    -----------------------------------------------------------------------------------------------------
    -- Convert to the AXI clock domain and do a division to find the total number of coarse channels.
    -- This generates o_totalStations(10:0), o_totalCoarse(9:0), o_totalChannels(10:0)
    -- from reg_rw.total_stations(15:0) and reg_rw.total_channels(15:0)
    process(i_data_clk)
    begin
        if rising_edge(i_data_clk) then
            cdcSendCount <= std_logic_vector(unsigned(cdcSendCount) + 1);
            if cdcSendCount = "0000" then
                cdcSend <= '1';
            elsif cdcRcv = '1' then
                cdcSend <= '0';
            end if;
            cdcSrcIn(11 downto 0) <= reg_rw.total_channels(11 downto 0);
        end if;
    end process;  
    
    xpm_cdc_handshake_inst : xpm_cdc_handshake
    generic map (
        DEST_EXT_HSK => 0,   -- DECIMAL; 0=internal handshake, 1=external handshake
        DEST_SYNC_FF => 3,   -- DECIMAL; range: 2-10
        INIT_SYNC_FF => 1,   -- DECIMAL; 0=disable simulation init values, 1=enable simulation init values
        SIM_ASSERT_CHK => 0, -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        SRC_SYNC_FF => 3,    -- DECIMAL; range: 2-10
        WIDTH => 12          -- DECIMAL; range: 1-1024
    )
    port map (
        dest_out => cdcDestOut, -- WIDTH-bit output: Input bus (src_in) synchronized to destination clock domain.
        dest_req => cdcDestReq, -- 1-bit output: Assertion of this signal indicates that new dest_out data has been received and is ready to be used or captured by the destination logic. 
        src_rcv => cdcRcv,   -- 1-bit output: Acknowledgement from destination logic that src_in has been received. This signal will be deasserted once destination handshake has fully completed
        dest_ack => '1',         -- 1-bit input: optional; required when DEST_EXT_HSK = 1
        dest_clk => i_s_axi_clk, -- 1-bit input: Destination clock.
        src_clk => i_data_clk,   -- 1-bit input: Source clock.
        src_in => cdcSrcIn,      -- WIDTH-bit input: Input bus that will be synchronized to the destination clock domain.
        src_send => cdcSend      -- 1-bit input: Assertion of this signal allows the src_in bus to be synchronized to the destination clock domain. 
    );
    
    
    process(i_s_axi_clk)
    begin
        if rising_edge(i_s_axi_clk) then
            if cdcDestReq = '1' then
                AXI_totalChannels <= cdcDestOut(11 downto 0);
            end if;
            o_totalChannels <= AXI_totalChannels;
        end if;
    end process;
    
end Behavioral;
