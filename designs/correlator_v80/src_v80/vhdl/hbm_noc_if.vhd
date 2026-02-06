-------------------------------------------------------------------------------
--
-- File Name: hbm_noc_if.vhd
-- Contributing Authors: Giles Babich, David Humphrey
-- Wrapper for the HBM NOC interface, fills in all the extra axi4 signals
-------------------------------------------------------------------------------

LIBRARY IEEE, UNISIM, common_lib, axi4_lib;
LIBRARY noc_lib;

USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE common_lib.common_pkg.ALL;
USE axi4_lib.axi4_lite_pkg.ALL;
USE axi4_lib.axi4_stream_pkg.ALL;
USE axi4_lib.axi4_full_pkg.ALL;

USE UNISIM.vcomponents.all;
Library xpm;
use xpm.vcomponents.all;

-------------------------------------------------------------------------------
entity hbm_noc_if is
    generic (
        g_HBM_base_addr : std_logic_vector(63 downto 0) := x"0000004600000000";  -- default is the HBM base address
        g_USE_VNOC : boolean := false  -- "pl_hbm" for the native HBM interfaces at the top of the chip or "VNOC" for other NOC interfaces
    );
    port (
        clk : in std_logic;
        -- write
        i_HBM_axi_aw      : in t_axi4_full_addr; -- write address bus : out t_axi4_full_addr(.valid, .addr(39:0), .len(7:0))
        o_HBM_axi_awready : out std_logic;
        i_HBM_axi_w       : in t_axi4_full_data; -- w data bus : out t_axi4_full_data(.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_wready  : out std_logic;
        o_HBM_axi_b       : out t_axi4_full_b;     -- write response bus : in t_axi4_full_b(.valid, .resp); resp of "00" or "01" means ok, "10" or "11" means the write failed.
        i_HBM_axi_bready  : in std_logic;
        -- read
        i_HBM_axi_ar : in t_axi4_full_addr;
        o_HBM_axi_arready : out std_logic;
        o_HBM_axi_r : out t_axi4_full_data;
        i_HBM_axi_rready : in std_logic
    );
end hbm_noc_if;

-------------------------------------------------------------------------------
architecture structure of hbm_noc_if is

    constant NOC_DATA_WIDTH     : integer   := 256;                 -- 32/64/128/256/512
    constant NOC_ADDR_WIDTH     : integer   := 64;                  -- 12 to 64
    constant NOC_ID_WIDTH       : integer   := 1;                   -- 1 to 16
    constant NOC_AUSER_WIDTH    : integer   := 16;                  -- 16 for VNOC with parity disabled, 18 for VNOC with parity enabled 
    constant NOC_DUSER_WIDTH    : integer   := 1;                   -- 2*DATA_WIDTH/8 for parity enablement with VNOC, 1 for VNOC with parity disabled cases.

    signal HBM_axi_awaddr   : std_logic_vector(63 downto 0);
    signal HBM_axi_awid     : std_logic_vector(0 downto 0);
    --signal HBM_axi_awlen    : t_slv_8_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_awsize   : std_logic_vector(2 downto 0); --t_slv_3_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_awburst  : std_logic_vector(1 downto 0); --t_slv_2_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_awlock   : std_logic_vector(0 downto 0); --t_slv_1_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_awcache  : std_logic_vector(3 downto 0); -- t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_awprot   : std_logic_vector(2 downto 0); -- t_slv_3_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_awqos    : std_logic_vector(3 downto 0); --t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_awregion : std_logic_vector(3 downto 0); --t_slv_4_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_wstrb    : std_logic_vector(63 downto 0); -- t_slv_64_arr(g_HBM_INTERFACES-1 downto 0);
    signal HBM_axi_bvalid   : std_logic;
    signal HBM_axi_bready   : std_logic;
    signal HBM_axi_bresp    : std_logic_vector(1 downto 0);
    signal HBM_axi_bid      : std_logic_vector(0 downto 0);
    signal HBM_axi_arready  : std_logic;
    signal HBM_axi_araddr   : std_logic_vector(63 downto 0);
    signal HBM_axi_arid     : std_logic_vector(0 downto 0);
    signal HBM_axi_arsize   : std_logic_vector(2 downto 0);
    signal HBM_axi_arburst  : std_logic_vector(1 downto 0);
    signal HBM_axi_arlock   : std_logic_vector(0 downto 0);
    signal HBM_axi_arcache  : std_logic_vector(3 downto 0);
    signal HBM_axi_arprot   : std_logic_vector(2 downto 0);
    signal HBM_axi_arqos    : std_logic_vector(3 downto 0);
    signal HBM_axi_arregion : std_logic_vector(3 downto 0);
    signal HBM_axi_rready   : std_logic;
    signal HBM_axi_rid      : std_logic_vector(0 downto 0);
    signal HBM_axi_awuser   : std_logic_vector(15 downto 0);

    signal HBM_axi_wid      : std_logic_vector(0 downto 0);
    signal HBM_axi_wuser    : std_logic_vector(0 downto 0);
    signal HBM_axi_buser    : std_logic_vector(15 downto 0);
    signal HBM_axi_aruser   : std_logic_vector(15 downto 0);
    signal HBM_axi_ruser    : std_logic_vector(0 downto 0);

    signal HBM_axi_araddr256Mbyte, HBM_axi_awaddr256Mbyte : std_logic_vector(7 downto 0);
    
    -- V80 contains 32GB of HBM
    -- Base address for this is 0x40_0000_0000
    -- Biggest HBM block in Correlator is 4GB
    --constant HBM_base_addr  : t_slv_64_arr(g_HBM_interfaces-1 downto 0) := ( x"0000004600000000",   -- Base         
    --                                                                         x"0000004500000000",   -- +4GB addr
    --                                                                         x"0000004400000000",   -- +4GB addr
    --                                                                        x"0000004200000000",   -- +4GB addr
    --                                                                         x"0000004100000000",   -- +4GB addr
    --                                                                         x"0000004700000000"    -- +4GB addr    -- LFAA
    --                                                                        );
-- From Xilinx Doc PG313
-- Base address 0 - LFAA    - HBM14_PORT0_hbmc  - 0x47_0000_0000
-- Base address 1 - CT2_1   - HBM2_PORT0_hbmc   - 0x41_0000_0000
-- Base address 2 - CT2_2   - HBM4_PORT0_hbmc   - 0x42_0000_0000
-- Base address 3 - Corr_1  - HBM8_PORT0_hbmc   - 0x44_0000_0000
-- Base address 4 - Corr_2  - HBM10_PORT0_hbmc  - 0x45_0000_0000
-- Base address 5 - ILA     - HBM12_PORT0_hbmc  - 0x46_0000_0000

    signal axi_dbg : std_logic_vector(127 downto 0);
    signal axi_dbg_valid : std_logic;
    
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
    
begin
    
    HBM_axi_araddr256Mbyte          <= i_HBM_axi_ar.addr(35 downto 28); -- 8 bit address of 256MByte pieces, within 64 Gbytes ((35:0) addresses 64 Gbytes)
    HBM_axi_araddr(63 downto 36)    <= g_HBM_base_addr(63 downto 36);
    HBM_axi_araddr(35 downto 28)    <= std_logic_vector(unsigned(g_HBM_base_addr(35 downto 28)) + unsigned(HBM_axi_araddr256Mbyte));
    HBM_axi_araddr(27 downto 0)     <= i_HBM_axi_ar.addr(27 downto 0);
    
    HBM_axi_awaddr256Mbyte          <= i_HBM_axi_aw.addr(35 downto 28); -- 8 bit address of 256MByte pieces, within 64 Gbytes ((35:0) addresses 64 Gbytes)
    HBM_axi_awaddr(63 downto 36)    <= g_HBM_base_addr(63 downto 36);
    HBM_axi_awaddr(35 downto 28)    <= std_logic_vector(unsigned(g_HBM_base_addr(35 downto 28)) + unsigned(HBM_axi_awaddr256Mbyte));
    HBM_axi_awaddr(27 downto 0)     <= i_HBM_axi_aw.addr(27 downto 0);
    
    -- register slice ports that have a fixed value.
    HBM_axi_awsize       <= get_axi_size(NOC_DATA_WIDTH);
    HBM_axi_awburst      <= "01";   -- "01" indicates incrementing addresses for each beat in the burst.  -- out std_logic_vector(1 downto 0);
    HBM_axi_bready       <= '1';  -- Always accept acknowledgement of write transactions. -- out std_logic;
    HBM_axi_wstrb        <= (others => '1');  -- We always write all bytes in the bus. --  out std_logic_vector(63 downto 0);
    HBM_axi_arsize       <= get_axi_size(NOC_DATA_WIDTH);   -- 6 = 64 bytes per beat = 512 bit wide bus. -- out std_logic_vector(2 downto 0);
    HBM_axi_arburst      <= "01";    -- "01" = incrementing address for each beat in the burst. -- out std_logic_vector(1 downto 0);
    
    -- these have no ports on the axi register slice
    HBM_axi_arlock(0)    <= '0';
    HBM_axi_awlock(0)    <= '0';
    HBM_axi_awcache      <= "0011";  -- out std_logic_vector(3 downto 0); bufferable transaction. Default in Vitis environment.
    HBM_axi_awprot       <= "000";   -- Has no effect in Vitis environment. -- out std_logic_vector(2 downto 0);
    HBM_axi_awqos        <= "0000";  -- Has no effect in vitis environment, -- out std_logic_vector(3 downto 0);
    HBM_axi_awregion     <= "0000"; -- Has no effect in Vitis environment. -- out std_logic_vector(3 downto 0);
    HBM_axi_arcache      <= "0011";  -- out std_logic_vector(3 downto 0); bufferable transaction. Default in Vitis environment.
    HBM_axi_arprot       <= "000";   -- Has no effect in vitis environment; out std_logic_Vector(2 downto 0);
    HBM_axi_arqos        <= "0000"; -- Has no effect in vitis environment; out std_logic_vector(3 downto 0);
    HBM_axi_arregion     <= "0000"; -- Has no effect in vitis environment; out std_logic_vector(3 downto 0);
    HBM_axi_awid(0)      <= '0';   -- We only use a single ID -- out std_logic_vector(0 downto 0);
    HBM_axi_arid(0)      <= '0';     -- ID are not used. -- out std_logic_vector(0 downto 0);
    
    HBM_axi_awuser       <= x"0000";     -- New NOC fields to keeep an eye on.
    HBM_axi_wid(0)       <= '0';         -- New NOC fields to keeep an eye on.
    HBM_axi_wuser(0)     <= '0';         -- New NOC fields to keeep an eye on.
    
    -- HBM Master NoC
    vnoc_gen : if g_USE_VNOC generate
        i_hbm_noc : xpm_nmu_mm
        generic map (
            NOC_FABRIC    => "VNOC",	        -- "VNOC" or "pl" or "pl_hbm"
            DATA_WIDTH    => NOC_DATA_WIDTH,	-- 32/64/128/256/512
            ADDR_WIDTH    => NOC_ADDR_WIDTH,	-- 12 to 64
            ID_WIDTH      => NOC_ID_WIDTH,		-- 1 to 16
            AUSER_WIDTH   => NOC_AUSER_WIDTH,	-- 16 for VNOC with parity disabled, 18 for VNOC with parity enabled 
            DUSER_WIDTH   => NOC_DUSER_WIDTH,	-- 2*DATA_WIDTH/8 for parity enablement with VNOC, 1 for VNOC with parity disabled cases
            ENABLE_USR_INTERRUPT => "false",	-- false/true
            SIDEBAND_PINS => "false"		    -- false/true/addr/data
        ) port map ( 
            s_axi_aclk              => clk,
            -----------------------------------------------------
            -- To Logic
            -- ADDR
            s_axi_awid              => HBM_axi_awid,
            s_axi_awaddr            => HBM_axi_awaddr,
            s_axi_awlen             => i_HBM_axi_aw.len,
            s_axi_awsize            => HBM_axi_awsize,
            s_axi_awburst           => HBM_axi_awburst,
            s_axi_awlock            => HBM_axi_awlock,
            s_axi_awcache           => HBM_axi_awcache,
            s_axi_awprot            => HBM_axi_awprot,
            s_axi_awregion          => HBM_axi_awregion,
            s_axi_awqos             => HBM_axi_awqos,
            s_axi_awuser            => HBM_axi_awuser,                -- Where does this go?
            s_axi_awvalid           => i_HBM_axi_aw.valid,
            s_axi_awready           => o_HBM_axi_awready,
    
            -- DATA
            s_axi_wid               => HBM_axi_wid,
            s_axi_wdata             => i_HBM_axi_w.data(255 downto 0),
            s_axi_wstrb             => HBM_axi_wstrb(31 downto 0),
            s_axi_wlast             => i_HBM_axi_w.last,
            s_axi_wuser             => HBM_axi_wuser,
            s_axi_wvalid            => i_HBM_axi_w.valid,
            s_axi_wready            => o_HBM_axi_wready,
    
            s_axi_bid               => HBM_axi_bid,
            s_axi_bresp             => o_HBM_axi_b.resp,
            s_axi_buser             => HBM_axi_buser,
            s_axi_bvalid            => o_HBM_axi_b.valid,
            s_axi_bready            => i_HBM_axi_bready,
            
            -- reading from logic
            s_axi_arid              => HBM_axi_arid,
            s_axi_araddr            => HBM_axi_araddr, --HBM_axi_ar(i).addr,
            s_axi_arlen             => i_HBM_axi_ar.len,
            s_axi_arsize            => HBM_axi_arsize,
            s_axi_arburst           => HBM_axi_arburst,
            s_axi_arlock            => HBM_axi_arlock,
            s_axi_arcache           => HBM_axi_arcache,
            s_axi_arprot            => HBM_axi_arprot,
            s_axi_arregion          => HBM_axi_arregion,
            s_axi_arqos             => HBM_axi_arqos,
            s_axi_aruser            => HBM_axi_aruser,
            s_axi_arvalid           => i_HBM_axi_ar.valid,
            s_axi_arready           => o_HBM_axi_arready,
    
            -- DATA
            s_axi_rid               => HBM_axi_rid,
            s_axi_rdata             => o_HBM_axi_r.data(255 downto 0),
            s_axi_rresp             => o_HBM_axi_r.resp,
            s_axi_rlast             => o_HBM_axi_r.last,
            s_axi_ruser             => HBM_axi_ruser,
            s_axi_rvalid            => o_HBM_axi_r.valid,
            s_axi_rready            => i_HBM_axi_rready,
            
            nmu_usr_interrupt_in    => x"0"
        );
    end generate;
    
    
    hbm_noc_geni : if (not g_USE_VNOC) generate
        i_hbm_noc : xpm_nmu_mm
        generic map (
            NOC_FABRIC    => "pl_hbm",	        -- "VNOC" or "pl" or "pl_hbm"
            DATA_WIDTH    => NOC_DATA_WIDTH,	-- 32/64/128/256/512
            ADDR_WIDTH    => NOC_ADDR_WIDTH,	-- 12 to 64
            ID_WIDTH      => NOC_ID_WIDTH,		-- 1 to 16
            AUSER_WIDTH   => NOC_AUSER_WIDTH,	-- 16 for VNOC with parity disabled, 18 for VNOC with parity enabled 
            DUSER_WIDTH   => NOC_DUSER_WIDTH,	-- 2*DATA_WIDTH/8 for parity enablement with VNOC, 1 for VNOC with parity disabled cases
            ENABLE_USR_INTERRUPT => "false",	-- false/true
            SIDEBAND_PINS => "false"		    -- false/true/addr/data
        ) port map ( 
            s_axi_aclk              => clk,
            -----------------------------------------------------
            -- To Logic
            -- ADDR
            s_axi_awid              => HBM_axi_awid,
            s_axi_awaddr            => HBM_axi_awaddr,
            s_axi_awlen             => i_HBM_axi_aw.len,
            s_axi_awsize            => HBM_axi_awsize,
            s_axi_awburst           => HBM_axi_awburst,
            s_axi_awlock            => HBM_axi_awlock,
            s_axi_awcache           => HBM_axi_awcache,
            s_axi_awprot            => HBM_axi_awprot,
            s_axi_awregion          => HBM_axi_awregion,
            s_axi_awqos             => HBM_axi_awqos,
            s_axi_awuser            => HBM_axi_awuser,                -- Where does this go?
            s_axi_awvalid           => i_HBM_axi_aw.valid,
            s_axi_awready           => o_HBM_axi_awready,
    
            -- DATA
            s_axi_wid               => HBM_axi_wid,
            s_axi_wdata             => i_HBM_axi_w.data(255 downto 0),
            s_axi_wstrb             => HBM_axi_wstrb(31 downto 0),
            s_axi_wlast             => i_HBM_axi_w.last,
            s_axi_wuser             => HBM_axi_wuser,
            s_axi_wvalid            => i_HBM_axi_w.valid,
            s_axi_wready            => o_HBM_axi_wready,
    
            s_axi_bid               => HBM_axi_bid,
            s_axi_bresp             => o_HBM_axi_b.resp,
            s_axi_buser             => HBM_axi_buser,
            s_axi_bvalid            => o_HBM_axi_b.valid,
            s_axi_bready            => i_HBM_axi_bready,
            
            -- reading from logic
            s_axi_arid              => HBM_axi_arid,
            s_axi_araddr            => HBM_axi_araddr, --HBM_axi_ar(i).addr,
            s_axi_arlen             => i_HBM_axi_ar.len,
            s_axi_arsize            => HBM_axi_arsize,
            s_axi_arburst           => HBM_axi_arburst,
            s_axi_arlock            => HBM_axi_arlock,
            s_axi_arcache           => HBM_axi_arcache,
            s_axi_arprot            => HBM_axi_arprot,
            s_axi_arregion          => HBM_axi_arregion,
            s_axi_arqos             => HBM_axi_arqos,
            s_axi_aruser            => HBM_axi_aruser,
            s_axi_arvalid           => i_HBM_axi_ar.valid,
            s_axi_arready           => o_HBM_axi_arready,
    
            -- DATA
            s_axi_rid               => HBM_axi_rid,
            s_axi_rdata             => o_HBM_axi_r.data(255 downto 0),
            s_axi_rresp             => o_HBM_axi_r.resp,
            s_axi_rlast             => o_HBM_axi_r.last,
            s_axi_ruser             => HBM_axi_ruser,
            s_axi_rvalid            => o_HBM_axi_r.valid,
            s_axi_rready            => i_HBM_axi_rready,
            
            nmu_usr_interrupt_in    => x"0"
        );
    
    end generate;
        
END structure;
