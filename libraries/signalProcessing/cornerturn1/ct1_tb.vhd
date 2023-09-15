----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey
-- 
-- Create Date: 08/14/2023 10:14:24 PM
-- Module Name: ct1_tb - Behavioral
-- Description: 
--  Standalone testbench for correlator corner turn 1
-- 
----------------------------------------------------------------------------------

library IEEE, correlator_lib, ct_lib, common_lib;
use IEEE.STD_LOGIC_1164.ALL;
Library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;
use IEEE.NUMERIC_STD.ALL;
use std.textio.all;
use IEEE.std_logic_textio.all;
USE ct_lib.corr_ct1_reg_pkg.ALL;
USE common_lib.common_pkg.ALL;
library DSP_top_lib;
use DSP_top_lib.DSP_top_pkg.all;

entity ct1_tb is
    generic(
        g_VIRTUAL_CHANNELS : integer := 4;
        g_PACKET_GAP : integer := 800;
        g_PACKET_COUNT_START : std_logic_Vector(47 downto 0) := x"03421AFE0270"
    );
--  Port ( );
end ct1_tb;

architecture Behavioral of ct1_tb is

    function get_axi_size(AXI_DATA_WIDTH : integer) return std_logic_vector is
    begin
        if AXI_DATA_WIDTH = 8 then
            return "000";
        elsif AXI_DATA_WIDTH = 16 then
            return "001";
        elsif AXI_DATA_WIDTH = 32 then
            return "010";
        elsif AXI_DATA_WIDTH = 64 then
            return "011";
        elsif AXI_DATA_WIDTH = 128 then
            return "100";
        elsif AXI_DATA_WIDTH = 256 then
            return "101";
        elsif AXI_DATA_WIDTH = 512 then
            return "110";    -- size of 6 indicates 64 bytes in each beat (i.e. 512 bit wide bus) -- out std_logic_vector(2 downto 0);
        elsif AXI_DATA_WIDTH = 1024 then
            return "111";
        else
            assert FALSE report "Bad AXI data width" severity failure;
            return "000";
        end if;
    end get_axi_size;
    constant M01_DATA_WIDTH : integer := 512;

    signal m01_axi_aw : t_axi4_full_addr;
    --signal m01_axi_awready : std_logic;
    signal m01_axi_b : t_axi4_full_b;
    signal m01_axi_ar : t_axi4_full_addr;
    signal m01_axi_r : t_axi4_full_data;
    signal m01_axi_w : t_axi4_full_data;
    
    signal m01_awvalid : std_logic;
    signal m01_awready : std_logic;
    signal m01_awaddr : std_logic_vector(31 downto 0);
    signal m01_awid : std_logic_vector(0 downto 0);
    signal m01_awlen : std_logic_vector(7 downto 0);
    signal m01_awsize : std_logic_vector(2 downto 0);
    signal m01_awburst : std_logic_vector(1 downto 0);
    signal m01_awlock :  std_logic_vector(1 downto 0);
    signal m01_awcache :  std_logic_vector(3 downto 0);
    signal m01_awprot :  std_logic_vector(2 downto 0);
    signal m01_awqos :  std_logic_vector(3 downto 0);
    signal m01_awregion :  std_logic_vector(3 downto 0);
    signal m01_wready :  std_logic;
    signal m01_wstrb :  std_logic_vector(63 downto 0);
    signal m01_bvalid : std_logic;
    signal m01_bready :  std_logic;
    signal m01_bresp :  std_logic_vector(1 downto 0);
    signal m01_bid :  std_logic_vector(0 downto 0);
    signal m01_arvalid :  std_logic;
    signal m01_arready :  std_logic;
    signal m01_araddr :  std_logic_vector(31 downto 0);
    signal m01_arid :  std_logic_vector(0 downto 0);
    signal m01_arlen :  std_logic_vector(7 downto 0);
    signal m01_arsize :  std_logic_vector(2 downto 0);
    signal m01_arburst : std_logic_vector(1 downto 0);
    signal m01_arlock :  std_logic_vector(1 downto 0);
    signal m01_arcache :  std_logic_vector(3 downto 0);
    signal m01_arprot :  std_logic_Vector(2 downto 0);
    signal m01_arqos :  std_logic_vector(3 downto 0);
    signal m01_arregion :  std_logic_vector(3 downto 0);
    signal m01_rvalid :  std_logic;
    signal m01_rready :  std_logic;
    signal m01_rdata :  std_logic_vector((M01_DATA_WIDTH-1) downto 0);
    signal m01_rlast :  std_logic;
    signal m01_rid :  std_logic_vector(0 downto 0);
    signal m01_rresp :  std_logic_vector(1 downto 0);

    signal clk300, clk300_rst, data_rst : std_logic := '0';
    signal virtual_channels : std_logic_vector(10 downto 0);
    
    signal axi_lite_mosi : t_axi4_lite_mosi;
    signal axi_lite_miso : t_axi4_lite_miso;

    signal pkt_packet_count : std_logic_vector(47 downto 0);
    signal pkt_virtual_channel : std_logic_vector(15 downto 0);
    signal pkt_wait_count : integer := 0;
    signal pkt_valid : std_logic := '0';
    type pkt_fsm_type is (idle, send_pkt, update_counts, pkt_gap);
    signal pkt_fsm : pkt_fsm_type;
    
    type wdata_fsm_type is (idle, send_burst, update_burst);
    signal wdata_fsm : wdata_fsm_type := idle;
    signal wdata_virtual_channel : std_logic_vector(15 downto 0);
    signal wdata_packet_count : std_logic_vector(47 downto 0);
    signal wdata_word_count : std_logic_vector(7 downto 0);
    signal wdata_burst_count : std_logic_vector(7 downto 0);
   -- signal rst_active : std_logic;
    
    signal fb_sof, fb_valid : std_logic;   -- Start of frame, occurs for every new set of channels.
    signal fb_sofFull : std_logic; -- Start of a full frame, i.e. 128 LFAA packets worth.
    signal fb_data0, fb_data1, fb_data2, fb_data3, fb_data4, fb_data5, fb_data6, fb_data7 : t_slv_8_arr(1 downto 0);
    signal fb_meta01, fb_meta23, fb_meta45, fb_meta67  : t_CT1_META_out;
    
    signal write_HBM_to_disk : std_logic;
    signal hbm_dump_addr : integer;
    signal hbm_dump_filename, init_fname : string(1 to 9) := "dummy.txt";
    signal init_mem : std_logic;
    signal rst_n : std_logic;
begin

    clk300 <= not clk300 after 1.666 ns;
    rst_n <= not clk300_rst;
    
    process
        file RegCmdfile: TEXT;
       -- variable RegLine_in : Line;
       -- variable regData, regAddr : std_logic_vector(31 downto 0);
       -- variable RegGood : boolean;
       -- variable c : character;
    begin
        data_rst <= '1';
        clk300_rst <= '1';
        
        axi_lite_mosi.awaddr <= (others => '0');
        axi_lite_mosi.awprot <= "000";
        axi_lite_mosi.awvalid <= '0';
        axi_lite_mosi.wdata <= (others => '0');
        axi_lite_mosi.wstrb <= "1111";
        axi_lite_mosi.wvalid <= '0';
        axi_lite_mosi.bready <= '0';
        axi_lite_mosi.araddr <= (others => '0');
        axi_lite_mosi.arprot <= "000";
        axi_lite_mosi.arvalid <= '0';
        axi_lite_mosi.rready <= '0';
        
--        axi_full_mosi.awaddr <= (others => '0');
--        axi_full_mosi.awvalid <= '0';
--        -- Always write bursts of 64 bytes = 16 x 4-byte words = 1 polynomial specification
--        axi_full_mosi.awlen <= "00001111";
--        axi_full_mosi.wvalid <= '0';
--        axi_full_mosi.wdata <= (others => '0');
--        axi_full_mosi.wlast <= '0';
        
        wait until rising_edge(clk300);
        wait for 100 ns;
        wait until rising_edge(clk300);
        clk300_rst <= '0';
        wait until rising_edge(clk300);
        wait for 100 ns;
        wait until rising_edge(clk300);
        data_rst <= '1';
        wait until rising_edge(clk300);
        -- setup registers, just set table0 valid.
        axi_lite_transaction(clk300, axi_lite_miso, axi_lite_mosi, 
            c_config_table0_valid_address.base_address + c_config_table0_valid_address.address,
            true, x"00000001");
        
        wait until rising_edge(clk300);
        wait for 100 ns;
        wait until rising_edge(clk300);
        
        -- !! Put this in to do writes to configure the polynomials.
--        -- write configuration data to memory over the axi full interface.
--        FILE_OPEN(RegCmdfile, g_REGISTER_INIT_FILENAME, READ_MODE);
        
--        while (not endfile(RegCmdfile)) loop
--            -- Get data for 1 source (64 bytes = 16 x 4byte words)
--            readline(regCmdFile, regLine_in);
--            -- drop "[" character that indicates the address
--            read(regLine_in,c,regGood);
--            -- get the address
--            hread(regLine_in,regAddr,regGood);
--            axi_full_mosi.awaddr(31 downto 0) <= regAddr;
--            axi_full_mosi.awvalid <= '1';
--            wait until (rising_edge(clk) and axi_full_miso.awready='1');
--            wait for 1 ps;
--            axi_full_mosi.awvalid <= '0';
--            for i in 0 to 15 loop
--                readline(regCmdFile, regLine_in);
--                hread(regLine_in,regData,regGood);
--                axi_full_mosi.wvalid <= '1';
--                axi_full_mosi.wdata(31 downto 0) <= regData;
--                if i=15 then
--                    axi_full_mosi.wlast <= '1';
--                else
--                    axi_full_mosi.wlast <= '0';
--                end if;
--                wait until (rising_edge(clk) and axi_full_miso.wready = '1');
--                wait for 1 ps;
--            end loop;
--            axi_full_mosi.wvalid <= '0';
--            wait until rising_edge(clk);
--            wait until rising_edge(clk);
--        end loop;
--        wait until rising_edge(clk);
--        wait for 100 ns;
--        -- read back some data 
--        wait until rising_edge(clk);
--        do_readback <= '1';
--        wait until rising_edge(clk);
--        wait until rising_edge(clk);
--        do_readback <= '0';

        ---------------------------------------------------------------
        wait until rising_edge(clk300);
        wait for 100 ns;
        wait until rising_edge(clk300);
        data_rst <= '0';
        wait until rising_edge(clk300);
        wait until rising_edge(clk300);
        wait;
    end process;

    virtual_channels <= std_logic_vector(to_unsigned(g_VIRTUAL_CHANNELS,11));
    
    --------------------------------------------------------------------------------
    -- Emulate the LFAA decode module
    -- Generate writes on pkt_virtual_channel, pkt_packet_count, pkt_valid
    -- Also generate the wdata bus with dummy data
    process(clk300)
    begin
        if rising_Edge(clk300) then
            -- generate data on pkt_virtual_channel, pkt_packet_count, pkt_valid
            -- Time between packets is at least 200 clocks
            -- (8300byte packets at 100Gbit/sec, 3.333 ns clock period)
            if data_rst = '1' then
                pkt_fsm <= pkt_gap;
                pkt_packet_count <= g_PACKET_COUNT_START;
                pkt_virtual_channel <= (others => '0');
                pkt_wait_count <= 0;
            else
                case pkt_fsm is
                    when idle => 
                        pkt_wait_count <= 0;
                        pkt_fsm <= send_pkt;
                        
                    when send_pkt =>
                        pkt_valid <= '1';
                        pkt_fsm <= update_counts;
                        
                    when update_counts =>
                        pkt_valid <= '0';
                        pkt_fsm <= pkt_gap;
                        if (unsigned(pkt_virtual_channel) >= (g_VIRTUAL_CHANNELS-1)) then
                            pkt_virtual_channel <= (others => '0');
                            pkt_packet_count <= std_logic_vector(unsigned(pkt_packet_count) + 1);
                        else
                            pkt_virtual_channel <= std_logic_vector(unsigned(pkt_virtual_channel) + 1);
                        end if;
                        
                    when pkt_gap =>
                        pkt_valid <= '0';
                        pkt_wait_count <= pkt_wait_count + 1;
                        if (pkt_wait_count > g_PACKET_GAP) then
                            pkt_fsm <= idle;
                        end if;
                end case;
            end if;
            
            -- generate write data for the packets
            if data_rst = '1' then
                wdata_fsm <= idle;
                wdata_virtual_channel <= (others => '0');
                wdata_packet_count <= g_PACKET_COUNT_START;
                -- 8192 bytes per packet,
                -- split into 16 x 512 bytes
                --  = 16 x 8 words
                wdata_word_count <= (others => '0');
                wdata_burst_count <= (others => '0');
            else
                case wdata_fsm is
                    when idle =>
                        wdata_fsm <= send_burst;
                    
                    when send_burst =>
                        if m01_wready = '1' then
                            if (unsigned(wdata_word_count) = 7) then
                                wdata_fsm <= update_burst;
                            else
                                wdata_word_count <= std_logic_vector(unsigned(wdata_word_count) + 1);
                            end if;
                        end if;
                        
                    when update_burst =>
                        wdata_word_count <= (others => '0');
                        if (unsigned(wdata_burst_count) = 15) then
                            wdata_burst_count <= (others => '0');
                            if (unsigned(wdata_virtual_channel) >= (g_VIRTUAL_CHANNELS-1)) then
                                wdata_virtual_channel <= (others => '0');
                                wdata_packet_count <= std_logic_vector(unsigned(wdata_packet_count) + 1);
                            else
                                wdata_virtual_channel <= std_logic_vector(unsigned(wdata_virtual_channel) + 1);
                            end if;
                        else
                            wdata_burst_count <= std_logic_vector(unsigned(wdata_burst_count) + 1);
                        end if;
                        wdata_fsm <= send_burst;
                    
                end case;
            end if;
        
        end if;
    end process;
    
    m01_axi_w.data(3 downto 0) <= wdata_word_count(3 downto 0);
    m01_axi_w.data(11 downto 4) <= wdata_burst_count;
    m01_axi_w.data(15 downto 12) <= "0000";
    m01_axi_w.data(31 downto 16) <= wdata_virtual_channel;
    m01_axi_w.data(63 downto 32) <= (others => '0');
    m01_axi_w.data(127 downto 64) <= x"0000" & wdata_packet_count;
    m01_axi_w.data(511 downto 128) <= (others => '0'); 
    m01_axi_w.valid <= '1' when wdata_fsm = send_burst else '0';
    m01_axi_w.last <= '1' when unsigned(wdata_word_count) = 7 else '0';

    
    ct1i : entity ct_lib.corr_ct1_top
    port map (
        -- shared memory interface clock (300 MHz)
        i_shared_clk     => clk300, --  in std_logic;
        i_shared_rst     => clk300_rst, --  in std_logic;
        -- Registers (uses the shared memory clock)
        i_saxi_mosi      => axi_lite_mosi, -- in  t_axi4_lite_mosi;
        o_saxi_miso      => axi_lite_miso, -- out t_axi4_lite_miso;
        -- other config (comes from LFAA ingest module).
        -- This should be valid before coming out of reset.
        i_virtualChannels => virtual_channels, -- in std_logic_vector(10 downto 0); -- total virtual channels 
        i_rst             => data_rst,         -- in std_logic;   -- While in reset, process nothing.
        -- o_rst            : out std_logic;   -- Reset is now driven from the LFAA ingest module.
        --o_validMemRstActive => rst_active,     -- out std_logic;  -- reset is in progress, don't send data; Only used in the testbench. Reset takes about 20us.
        -- Headers for each valid packet received by the LFAA ingest.
        -- LFAA packets are about 8300 bytes long, so at 100Gbps each LFAA packet is about 660 ns long. This is about 200 of the interface clocks (@300MHz)
        -- These signals use i_shared_clk
        i_virtualChannel => pkt_virtual_channel, -- in std_logic_vector(15 downto 0); -- Single number which incorporates both the channel and station; this module supports values in the range 0 to 1023.
        i_packetCount    => pkt_packet_count,    -- in std_logic_vector(47 downto 0);
        i_valid          => pkt_valid,           -- in std_logic;
        ------------------------------------------------------------------------------------
        -- Data output, to go to the filterbanks.
        -- Data bus output to the Filterbanks
        -- 8 Outputs, each complex data, 8 bit real, 8 bit imaginary.
        --FB_clk  : in std_logic;  -- interface runs off i_shared_clk
        o_sof     => fb_sof,     -- out std_logic;   -- Start of frame, occurs for every new set of channels.
        o_sofFull => fb_sofFull, -- out std_logic; -- Start of a full frame, i.e. 128 LFAA packets worth.
        o_data0  => fb_data0,  -- out t_slv_8_arr(1 downto 0);
        o_data1  => fb_data1,  -- out t_slv_8_arr(1 downto 0);
        o_meta01 => fb_meta01, -- out t_CT1_META_out; --   - .HDeltaP(15:0), .VDeltaP(15:0), .frameCount(31:0), virtualChannel(15:0), .valid
        o_data2  => fb_data2,  -- out t_slv_8_arr(1 downto 0);
        o_data3  => fb_data3,  -- out t_slv_8_arr(1 downto 0);
        o_meta23 => fb_meta23, -- out t_CT1_META_out;
        o_data4  => fb_data4,  -- out t_slv_8_arr(1 downto 0);
        o_data5  => fb_data5,  -- out t_slv_8_arr(1 downto 0);
        o_meta45 => fb_meta45, -- out t_CT1_META_out;
        o_data6  => fb_data6,  -- out t_slv_8_arr(1 downto 0);
        o_data7  => fb_data7,  -- out t_slv_8_arr(1 downto 0);
        o_meta67 => fb_meta67, -- out t_CT1_META_out;
        o_valid  => fb_valid,  -- out std_logic;
        -------------------------------------------------------------
        -- AXI bus to the shared memory. 
        -- This has the aw, b, ar and r buses (the w bus is on the output of the LFAA decode module)
        -- w bus - write data
        o_m01_axi_aw => m01_axi_aw, --  out t_axi4_full_addr; -- write address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m01_axi_awready => m01_awready, -- in std_logic;
        -- b bus - write response
        i_m01_axi_b  => m01_axi_b, -- in t_axi4_full_b;   -- (.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        -- ar bus - read address
        o_m01_axi_ar      => m01_axi_ar, -- out t_axi4_full_addr; -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
        i_m01_axi_arready => m01_arready, -- in std_logic;
        -- r bus - read data
        i_m01_axi_r       => m01_axi_r, --  in  t_axi4_full_data;
        o_m01_axi_rready  => m01_rready  --  out std_logic
    );
    
    m01_awaddr <= m01_axi_aw.addr(31 downto 0);
    m01_awlen <= m01_axi_aw.len;
    m01_awvalid <= m01_axi_aw.valid;
    
    m01_araddr <= m01_axi_ar.addr(31 downto 0);
    m01_arlen <= m01_axi_ar.len;
    m01_arvalid <= m01_axi_ar.valid;
    
    -- Other unused axi ports
    m01_awsize <= get_axi_size(M01_DATA_WIDTH);
    m01_awburst <= "01";   -- "01" indicates incrementing addresses for each beat in the burst. 
    m01_bready  <= '1';  -- Always accept acknowledgement of write transactions. -- out std_logic;
    m01_wstrb  <= (others => '1');  -- We always write all bytes in the bus. --  out std_logic_vector(63 downto 0);
    m01_arsize  <= get_axi_size(M01_DATA_WIDTH);   -- 6 = 64 bytes per beat = 512 bit wide bus. -- out std_logic_vector(2 downto 0);
    m01_arburst <= "01";    -- "01" = incrementing address for each beat in the burst. -- out std_logic_vector(1 downto 0);
    
    m01_arlock <= "00";
    m01_awlock <= "00";
    m01_awid(0) <= '0';   -- We only use a single ID -- out std_logic_vector(0 downto 0);
    m01_awcache <= "0011";  -- out std_logic_vector(3 downto 0); bufferable transaction. Default in Vitis environment.
    m01_awprot  <= "000";   -- Has no effect in Vitis environment. -- out std_logic_vector(2 downto 0);
    m01_awqos   <= "0000";  -- Has no effect in vitis environment, -- out std_logic_vector(3 downto 0);
    m01_awregion <= "0000"; -- Has no effect in Vitis environment. -- out std_logic_vector(3 downto 0);
    m01_arid(0) <= '0';     -- ID are not used. -- out std_logic_vector(0 downto 0);
    m01_arcache <= "0011";  -- out std_logic_vector(3 downto 0); bufferable transaction. Default in Vitis environment.
    m01_arprot  <= "000";   -- Has no effect in vitis environment; out std_logic_Vector(2 downto 0);
    m01_arqos    <= "0000"; -- Has no effect in vitis environment; out std_logic_vector(3 downto 0);
    m01_arregion <= "0000"; -- Has no effect in vitis environment; out std_logic_vector(3 downto 0);
    
    -- m02 HBM interface : 2nd stage corner turn between filterbanks and beamformer, 2x256 MBytes.
    HBM3G_1 : entity correlator_lib.HBM_axi_tbModel
    generic map (
        AXI_ADDR_WIDTH => 32, -- : integer := 32;   -- Byte address width. This also defines the amount of data. Use the correct width for the HBM memory block, e.g. 28 bits for 256 MBytes.
        AXI_ID_WIDTH => 1, -- integer := 1;
        AXI_DATA_WIDTH => 512, -- integer := 256;  -- Must be a multiple of 32 bits.
        READ_QUEUE_SIZE => 16, --  integer := 16;
        MIN_LAG => 60,  -- integer := 80   
        INCLUDE_PROTOCOL_CHECKER => TRUE,
        RANDSEED => 43526, -- : natural := 12345;
        LATENCY_LOW_PROBABILITY => 97, --  natural := 95;   -- probability, as a percentage, that non-zero gaps between read beats will be small (i.e. < 3 clocks)
        LATENCY_ZERO_PROBABILITY => 97 -- natural := 80   -- probability, as a percentage, that the gap between read beats will be zero.
    ) Port map (
        i_clk        => clk300,
        i_rst_n      => rst_n,
        axi_awaddr   => m01_awaddr(31 downto 0),
        axi_awid     => m01_awid, -- in std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        axi_awlen    => m01_awlen,
        axi_awsize   => m01_awsize,
        axi_awburst  => m01_awburst,
        axi_awlock   => m01_awlock,
        axi_awcache  => m01_awcache,
        axi_awprot   => m01_awprot,
        axi_awqos    => m01_awqos, -- in(3:0)
        axi_awregion => m01_awregion, -- in(3:0)
        axi_awvalid  => m01_awvalid,
        axi_awready  => m01_awready,
        axi_wdata    => m01_axi_w.data,
        axi_wstrb    => m01_wstrb,
        axi_wlast    => m01_axi_w.last,
        axi_wvalid   => m01_axi_w.valid,
        axi_wready   => m01_wready,
        axi_bresp    => m01_bresp,
        axi_bvalid   => m01_bvalid,
        axi_bready   => m01_bready,
        axi_bid      => m01_bid, -- out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        axi_araddr   => m01_araddr(31 downto 0),
        axi_arlen    => m01_arlen,
        axi_arsize   => m01_arsize,
        axi_arburst  => m01_arburst,
        axi_arlock   => m01_arlock,
        axi_arcache  => m01_arcache,
        axi_arprot   => m01_arprot,
        axi_arvalid  => m01_arvalid,
        axi_arready  => m01_arready,
        axi_arqos    => m01_arqos,
        axi_arid     => m01_arid,
        axi_arregion => m01_arregion,
        axi_rdata    => m01_axi_r.data,
        axi_rresp    => m01_axi_r.resp,
        axi_rlast    => m01_axi_r.last,
        axi_rvalid   => m01_axi_r.valid,
        axi_rready   => m01_rready,
        i_write_to_disk => write_HBM_to_disk, -- in std_logic;
        i_write_to_disk_addr => hbm_dump_addr, -- address to start the memory dump at.
        -- 4 Mbytes = first 8 data streams
        i_write_to_disk_size => 4194304, -- size in bytes
        i_fname => hbm_dump_filename, -- : in string
        -- Initialisation of the memory
        -- The memory is loaded with the contents of the file i_init_fname in 
        -- any clock cycle where i_init_mem is high.
        i_init_mem   => init_mem, --  in std_logic;
        i_init_fname => init_fname -- : in string
    );

    write_HBM_to_disk <= '0';
    hbm_dump_addr <= 0;
    --hbm_dump_filename <= "";
    init_mem <= '0';
    --init_fname <= "dummy.vhd";


end Behavioral;
