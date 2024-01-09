--------------------------------------------------------------------------------
--
--  This file was automatically generated using ARGS config file LFAADecode100G_lfaadecode100g.peripheral.yaml
--
--  This wrapper depends on IP created by ip_LFAADecode100G_lfaadecode100g_<entity>_axi4.tcl
--
--  Modified from ARGS-generated original to use an XPM component for the BRAM.
--------------------------------------------------------------------------------

LIBRARY ieee, common_lib, axi4_lib;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE common_lib.common_pkg.ALL;
USE common_lib.common_mem_pkg.ALL;
USE axi4_lib.axi4_full_pkg.ALL;
Library xpm;
use xpm.vcomponents.all;

ENTITY LFAADecode100G_lfaadecode100g_vcstats_ram IS
    GENERIC (
        g_ram_b     : t_c_mem   := (latency => 1, adr_w => 13, dat_w => 32, addr_base => 0, nof_slaves => 1, nof_dat => 8192, init_sl => '0')
    );
    PORT (
        CLK_A       : IN    STD_LOGIC;
        RST_A       : IN    STD_LOGIC;
        CLK_B       : IN    STD_LOGIC;
        RST_B       : IN    STD_LOGIC;
        MM_IN       : IN    t_axi4_full_mosi;
        MM_OUT      : OUT   t_axi4_full_miso;
        user_we     : in    std_logic;
        user_addr   : in    std_logic_vector(g_ram_b.adr_w-1 downto 0);
        user_din    : in    std_logic_vector(g_ram_b.dat_w-1 downto 0);
        user_dout   : out   std_logic_vector(g_ram_b.dat_w-1 downto 0)
    );
END LFAADecode100G_lfaadecode100g_vcstats_ram;

ARCHITECTURE str OF LFAADecode100G_lfaadecode100g_vcstats_ram IS

    CONSTANT c_ram_a	: t_c_mem :=
        (latency	=> 1,
        adr_w	    => 13,
        dat_w	    => 32,
        addr_base   => 0,
        nof_slaves  => 1,
        nof_dat	    => 8192,
        init_sl	    => '0');

    CONSTANT c_ram_b	: t_c_mem := g_ram_b;

    TYPE t_we_arr IS ARRAY (INTEGER RANGE <>) OF STD_LOGIC_VECTOR(c_ram_b.dat_w/8-1 downto 0);

    SIGNAL sig_clka     : std_logic;
    SIGNAL sig_rsta     : std_logic;
    SIGNAL sig_wea      : std_logic_vector(c_ram_a.dat_w/8-1 downto 0);
    SIGNAL sig_wea_sum  : std_logic;
    SIGNAL sig_rea_sum  : std_logic;
    SIGNAL sig_ena      : std_logic;
    SIGNAL sig_addra    : std_logic_vector(c_ram_a.adr_w+1 downto 0);
    SIGNAL sig_dina     : std_logic_vector(c_ram_a.dat_w-1 downto 0);
    SIGNAL sig_douta    : std_logic_vector(c_ram_a.dat_w-1 downto 0);
    SIGNAL sig_clkb     : std_logic;
    SIGNAL sig_rstb     : std_logic;
    SIGNAL sig_enb      : std_logic;
    SIGNAL sig_web      : std_logic_vector(c_ram_b.dat_w/8-1 downto 0);
    SIGNAL sig_addrb    : std_logic_vector(c_ram_b.adr_w+1 downto 0);
    SIGNAL sig_dinb     : std_logic_vector(c_ram_b.dat_w-1 downto 0);
    SIGNAL sig_doutb    : std_logic_vector(c_ram_b.dat_w-1 downto 0);


    SIGNAL sig_arstn    : std_logic;
    SIGNAL sig_brstn    : std_logic;
    

    COMPONENT ip_LFAADecode100G_lfaadecode100g_vcstats_axi_a
      PORT (
        s_axi_aclk : IN STD_LOGIC;
        s_axi_aresetn : IN STD_LOGIC;
        s_axi_awaddr : IN STD_LOGIC_VECTOR(c_ram_a.adr_w+1 DOWNTO 0);
        s_axi_awlen : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        s_axi_awsize : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        s_axi_awburst : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_awlock : IN STD_LOGIC;
        s_axi_awcache : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        s_axi_awprot : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        s_axi_awvalid : IN STD_LOGIC;
        s_axi_awready : OUT STD_LOGIC;
        s_axi_wdata : IN STD_LOGIC_VECTOR(c_ram_a.dat_w-1 DOWNTO 0);
        s_axi_wstrb : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        s_axi_wlast : IN STD_LOGIC;
        s_axi_wvalid : IN STD_LOGIC;
        s_axi_wready : OUT STD_LOGIC;
        s_axi_bresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_bvalid : OUT STD_LOGIC;
        s_axi_bready : IN STD_LOGIC;
        s_axi_araddr : IN STD_LOGIC_VECTOR(c_ram_a.adr_w+1 DOWNTO 0);
        s_axi_arlen : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        s_axi_arsize : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        s_axi_arburst : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_arlock : IN STD_LOGIC;
        s_axi_arcache : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        s_axi_arprot : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        s_axi_arvalid : IN STD_LOGIC;
        s_axi_arready : OUT STD_LOGIC;
        s_axi_rdata : OUT STD_LOGIC_VECTOR(c_ram_a.dat_w-1 DOWNTO 0);
        s_axi_rresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_rlast : OUT STD_LOGIC;
        s_axi_rvalid : OUT STD_LOGIC;
        s_axi_rready : IN STD_LOGIC;
        bram_rst_a : OUT STD_LOGIC;
        bram_clk_a : OUT STD_LOGIC;
        bram_en_a : OUT STD_LOGIC;
        bram_we_a : OUT STD_LOGIC_VECTOR(c_ram_a.dat_w/8-1 DOWNTO 0);
        bram_addr_a : OUT STD_LOGIC_VECTOR(c_ram_a.adr_w+1 DOWNTO 0);
        bram_wrdata_a : OUT STD_LOGIC_VECTOR(c_ram_a.dat_w-1 DOWNTO 0);
        bram_rddata_a : IN STD_LOGIC_VECTOR(c_ram_a.dat_w-1 DOWNTO 0)
      );
    END COMPONENT;

    signal sig_wea_slv : std_logic_vector(0 downto 0);
    signal user_we_slv : std_logic_vector(0 downto 0); -- (g_ram_b.dat_w/8 - 1) downto 0);

--    COMPONENT ip_LFAADecode100G_lfaadecode100g_vcstats_bram
--      PORT (
--        clka : IN STD_LOGIC;
--        rsta : IN STD_LOGIC;
--        ena : IN STD_LOGIC;
--        wea : IN STD_LOGIC_VECTOR(c_ram_a.dat_w/8-1 DOWNTO 0);
--        addra : IN STD_LOGIC_VECTOR(c_ram_a.adr_w-1 DOWNTO 0); -- adjust for AXI and nof_slaves
--        dina : IN STD_LOGIC_VECTOR(c_ram_a.dat_w-1 DOWNTO 0);
--        douta : OUT STD_LOGIC_VECTOR(c_ram_a.dat_w-1 DOWNTO 0);
--        clkb : IN STD_LOGIC;
--        rstb : IN STD_LOGIC;
--        enb : IN STD_LOGIC;
--        web : IN STD_LOGIC_VECTOR(g_ram_b.dat_w/8-1 DOWNTO 0);
--        addrb : IN STD_LOGIC_VECTOR(g_ram_b.adr_w-1 DOWNTO 0);
--        dinb : IN STD_LOGIC_VECTOR(g_ram_b.dat_w-1 DOWNTO 0);
--        doutb : OUT STD_LOGIC_VECTOR(g_ram_b.dat_w-1 DOWNTO 0)
--      );
--    END COMPONENT;
BEGIN

    sig_arstn <= not RST_A;
    sig_brstn <= not RST_B;

    u_axi4_ctrl_a : COMPONENT ip_LFAADecode100G_lfaadecode100g_vcstats_axi_a -- mm bus side
    PORT MAP(
        s_axi_aclk      => CLK_A,
        s_axi_aresetn   => sig_arstn,
        s_axi_awaddr    => MM_IN.awaddr(c_ram_a.adr_w+1 downto 0),
        s_axi_awlen     => MM_IN.awlen,
        s_axi_awsize    => MM_IN.awsize,
        s_axi_awburst   => MM_IN.awburst,
        s_axi_awlock    => MM_IN.awlock ,
        s_axi_awcache   => MM_IN.awcache,
        s_axi_awprot    => MM_IN.awprot,
        s_axi_awvalid   => MM_IN.awvalid,
        s_axi_awready   => MM_OUT.awready,
        s_axi_wdata     => MM_IN.wdata(c_ram_a.dat_w-1 downto 0),
        s_axi_wstrb     => MM_IN.wstrb(c_ram_a.dat_w/8-1 downto 0),
        s_axi_wlast     => MM_IN.wlast,
        s_axi_wvalid    => MM_IN.wvalid,
        s_axi_wready    => MM_OUT.wready,
        s_axi_bresp     => MM_OUT.bresp,
        s_axi_bvalid    => MM_OUT.bvalid,
        s_axi_bready    => MM_IN.bready ,
        s_axi_araddr    => MM_IN.araddr(c_ram_a.adr_w+1 downto 0),
        s_axi_arlen     => MM_IN.arlen,
        s_axi_arsize    => MM_IN.arsize,
        s_axi_arburst   => MM_IN.arburst,
        s_axi_arlock    => MM_IN.arlock ,
        s_axi_arcache   => MM_IN.arcache,
        s_axi_arprot    => MM_IN.arprot,
        s_axi_arvalid   => MM_IN.arvalid,
        s_axi_arready   => MM_OUT.arready,
        s_axi_rdata     => MM_OUT.rdata(c_ram_a.dat_w-1 downto 0),
        s_axi_rresp     => MM_OUT.rresp,
        s_axi_rlast     => MM_OUT.rlast,
        s_axi_rvalid    => MM_OUT.rvalid,
        s_axi_rready    => MM_IN.rready,
        bram_rst_a      => sig_rsta,
        bram_clk_a      => sig_clka,
        bram_en_a       => sig_ena,
        bram_we_a       => sig_wea,
        bram_addr_a     => sig_addra,
        bram_wrdata_a   => sig_dina,
        bram_rddata_a   => sig_douta
    );




--    u_blk_mem: COMPONENT ip_LFAADecode100G_lfaadecode100g_vcstats_bram
--    PORT MAP(
--        clka       => sig_clka,
--        rsta       => sig_rsta,
--        wea        => sig_wea,
--        ena        => sig_ena,
--        addra      => sig_addra(c_ram_a.adr_w+1 downto 2),
--        dina       => sig_dina(c_ram_a.dat_w-1 downto 0),
--        douta      => sig_douta(c_ram_a.dat_w-1 downto 0),
--        clkb       => CLK_B,
--        rstb       => RST_B,
--        enb        => '1',
--        web        => user_we_slv,
--        addrb      => user_addr(g_ram_b.adr_w-1 downto 0),
--        dinb       => user_din(g_ram_b.dat_w-1 downto 0),
--        doutb      => user_dout(g_ram_b.dat_w-1 downto 0)
--    );
    
    wegen : for i in 0 to (g_ram_b.dat_w/8 - 1) generate
        user_we_slv(i) <= user_we;
    end generate;

    -- 2 cycle read latency port A, 2 cycle port B, 8192 deep x 32 bits wide.
    -- xpm_memory_tdpram: True Dual Port RAM
    -- Xilinx Parameterized Macro, version 2023.2
    xpm_memory_tdpram_inst : xpm_memory_tdpram
    generic map (
        ADDR_WIDTH_A => 13,               -- DECIMAL
        ADDR_WIDTH_B => 13,               -- DECIMAL
        AUTO_SLEEP_TIME => 0,            -- DECIMAL
        BYTE_WRITE_WIDTH_A => 32,        -- DECIMAL
        BYTE_WRITE_WIDTH_B => 32,        -- DECIMAL
        CASCADE_HEIGHT => 0,             -- DECIMAL
        CLOCKING_MODE => "independent_clock", -- String
        ECC_BIT_RANGE => "7:0",          -- String
        ECC_MODE => "no_ecc",            -- String
        ECC_TYPE => "none",              -- String
        IGNORE_INIT_SYNTH => 0,          -- DECIMAL
        MEMORY_INIT_FILE => "none",      -- String
        MEMORY_INIT_PARAM => "0",        -- String
        MEMORY_OPTIMIZATION => "true",   -- String
        MEMORY_PRIMITIVE => "auto",      -- String
        MEMORY_SIZE => 262144,           -- DECIMAL = 8192*32
        MESSAGE_CONTROL => 0,            -- DECIMAL
        RAM_DECOMP => "auto",            -- String
        READ_DATA_WIDTH_A => 32,         -- DECIMAL
        READ_DATA_WIDTH_B => 32,         -- DECIMAL
        READ_LATENCY_A => 2,             -- DECIMAL
        READ_LATENCY_B => 2,             -- DECIMAL
        READ_RESET_VALUE_A => "0",       -- String
        READ_RESET_VALUE_B => "0",       -- String
        RST_MODE_A => "SYNC",            -- String
        RST_MODE_B => "SYNC",            -- String
        SIM_ASSERT_CHK => 0,             -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_EMBEDDED_CONSTRAINT => 0,    -- DECIMAL
        USE_MEM_INIT => 0,               -- DECIMAL
        USE_MEM_INIT_MMI => 0,           -- DECIMAL
        WAKEUP_TIME => "disable_sleep",  -- String
        WRITE_DATA_WIDTH_A => 32,        -- DECIMAL
        WRITE_DATA_WIDTH_B => 32,        -- DECIMAL
        WRITE_MODE_A => "no_change",     -- String
        WRITE_MODE_B => "no_change",     -- String
        WRITE_PROTECT => 1               -- DECIMAL
   ) port map (
        dbiterra => open,        -- 1-bit output: Status signal to indicate double bit error occurrence
        dbiterrb => open,        -- 1-bit output: Status signal to indicate double bit error occurrence
        douta => sig_douta,      -- READ_DATA_WIDTH_A-bit output: Data output for port A read operations.
        doutb => user_dout,      -- READ_DATA_WIDTH_B-bit output: Data output for port B read operations.
        sbiterra => open,        -- 1-bit output: Status signal to indicate single bit error occurrence
        sbiterrb => open,        -- 1-bit output: Status signal to indicate single bit error occurrence
        addra => sig_addra(c_ram_a.adr_w+1 downto 2), -- ADDR_WIDTH_A-bit input: Address for port A write and read operations.
        addrb => user_addr(g_ram_b.adr_w-1 downto 0), -- ADDR_WIDTH_B-bit input: Address for port B write and read operations.
        clka => sig_clka,        -- 1-bit input: Clock signal for port A.
        clkb => CLK_B,           -- 1-bit input: Clock signal for port B when parameter CLOCKING_MODE is "independent_clock". 
        dina => sig_dina,        -- WRITE_DATA_WIDTH_A-bit input: Data input for port A write operations.
        dinb => user_din,        -- WRITE_DATA_WIDTH_B-bit input: Data input for port B write operations.
        ena => sig_ena,          -- 1-bit input: Memory enable signal for port A.
        enb => '1',              -- 1-bit input: Memory enable signal for port B. 
        injectdbiterra => '0',   -- 1-bit input: Controls double bit error injection on input data 
        injectdbiterrb => '0',   -- 1-bit input: Controls double bit error injection on input data
        injectsbiterra => '0',   -- 1-bit input: Controls single bit error injection on input data 
        injectsbiterrb => '0',   -- 1-bit input: Controls single bit error injection on input data 
        regcea => '1',           -- 1-bit input: Clock Enable for the last register stage on the output data path.
        regceb => '1',           -- 1-bit input: Clock Enable for the last register stage on the output data path.
        rsta => sig_rsta,        -- 1-bit input: Reset signal for the final port A output register stage. 
        rstb => RST_B,           -- 1-bit input: Reset signal for the final port B output register stage. 
        sleep => '0',            -- 1-bit input: sleep signal to enable the dynamic power saving feature.
        wea => sig_wea_slv,      -- WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-bit input: Write enable vector
        web => user_we_slv       -- WRITE_DATA_WIDTH_B/BYTE_WRITE_WIDTH_B-bit input: Write enable vector
    );
    
    sig_wea_slv(0) <= sig_wea(0);
    user_we_slv(0) <= user_we;
    
end str;
