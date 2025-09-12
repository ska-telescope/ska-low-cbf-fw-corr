----------------------------------------------------------------------------------
-- Company:  CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 09/06/2023 11:33:47 PM
-- Module Name: poly_axi_bram_wrapper - Behavioral
-- Description: 
--  Interface axi full to a block of ultraRAMs to hold the polynomial coeficients.
--  2 separate memories :
--   -----------------------------------------------------------------------------
--   Polynomials:
--     (2 buffers) * (1024 polynomials) * (10 words/polynomial) * (8 bytes/word) = 
--     160 kBytes = 20480 * 8 bytes
--                = 40960 * 4 bytes
--     Base address is 0x0
--   -----------------------------------------------------------------------------
--   RFI Thresholds:
--    (1024 virtual channels) * (4 bytes) = 4096 bytes
--    Base address is 196608 = 0x30000 (byte address)
--                    49152 = 0xC000   (4-byte address)
--  ------------------------------------------------------------------------------
--  Input is 18-bit byte address = 262,144 byte address space
----------------------------------------------------------------------------------
library IEEE, common_lib, correlator_lib, signal_processing_common;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
Library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;
use common_lib.common_pkg.ALL;
use signal_processing_common.target_fpga_pkg.ALL;
Library xpm;
use xpm.vcomponents.all;
-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity poly_axi_bram_wrapper is
    port (
        i_clk : in std_logic;
        i_rst : in std_logic;
        -------------------------------------------------------
        -- Block ram interface for access by the rest of the module
        -- Memory is 20480 x 8 byte words
        -- read latency 3 clocks
        i_bram_addr         : in std_logic_vector(14 downto 0); -- 15 bit address = 8-byte word address (=18 bit byte address)
        o_bram_rddata       : out std_logic_vector(63 downto 0);
        -- 1024 x 4-byte words for the RFI threshold
        i_RFI_bram_addr   : in  std_logic_vector(9 downto 0);
        o_RFI_bram_rddata : out std_logic_vector(31 downto 0);
        ------------------------------------------------------
        noc_wren            : IN STD_LOGIC;
        noc_wr_adr          : IN STD_LOGIC_VECTOR(17 DOWNTO 0); -- This is a 4-byte address from the NOC
        noc_wr_dat          : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
        noc_rd_dat          : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
        ------------------------------------------------------
        -- AXI full interface
        i_vd_full_axi_mosi  : in  t_axi4_full_mosi;
        o_vd_full_axi_miso  : out t_axi4_full_miso;
        ------------------------------------------------------
        -- debug
        o_dbg_wrEn : out std_logic;
        o_dbg_wrAddr : out std_logic_vector(14 downto 0) 
    );
end poly_axi_bram_wrapper;

architecture Behavioral of poly_axi_bram_wrapper is
    
    component axi_bram_ctrl_ct1_poly
    port (
        s_axi_aclk : IN STD_LOGIC;
        s_axi_aresetn : IN STD_LOGIC;
        s_axi_awaddr : IN STD_LOGIC_VECTOR(17 DOWNTO 0);
        s_axi_awlen : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        s_axi_awsize : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        s_axi_awburst : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_awlock : IN STD_LOGIC;
        s_axi_awcache : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        s_axi_awprot : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        s_axi_awvalid : IN STD_LOGIC;
        s_axi_awready : OUT STD_LOGIC;
        s_axi_wdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
        s_axi_wstrb : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        s_axi_wlast : IN STD_LOGIC;
        s_axi_wvalid : IN STD_LOGIC;
        s_axi_wready : OUT STD_LOGIC;
        s_axi_bresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_bvalid : OUT STD_LOGIC;
        s_axi_bready : IN STD_LOGIC;
        s_axi_araddr : IN STD_LOGIC_VECTOR(17 DOWNTO 0);
        s_axi_arlen : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        s_axi_arsize : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        s_axi_arburst : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_arlock : IN STD_LOGIC;
        s_axi_arcache : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        s_axi_arprot : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        s_axi_arvalid : IN STD_LOGIC;
        s_axi_arready : OUT STD_LOGIC;
        s_axi_rdata : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
        s_axi_rresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_rlast : OUT STD_LOGIC;
        s_axi_rvalid : OUT STD_LOGIC;
        s_axi_rready : IN STD_LOGIC;
        bram_rst_a : OUT STD_LOGIC;
        bram_clk_a : OUT STD_LOGIC;
        bram_en_a : OUT STD_LOGIC;
        bram_we_a : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        bram_addr_a : OUT STD_LOGIC_VECTOR(17 DOWNTO 0);
        bram_wrdata_a : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
        bram_rddata_a : IN STD_LOGIC_VECTOR(31 DOWNTO 0));
    end component;

    signal axi_bram_en      : std_logic;
    signal axi_bram_we_byte : std_logic_vector(3 downto 0);
    signal axi_bram_addr    : std_logic_vector(17 downto 0);
    signal axi_bram_wrdata  : std_logic_vector(31 downto 0);
    signal axi_bram_rddata  : std_logic_vector(31 downto 0);

    signal axi_addr         : std_logic_vector(17 downto 0);
    
    signal axi_bram_wrdata_64bit : std_logic_vector(63 downto 0);
    
    signal reset_n : std_logic;
    
   
    constant g_NO_OF_ADDR_BITS      : INTEGER := 13;
    constant g_D_Q_WIDTH            : INTEGER := 64;
    constant g_BYTE_ENABLE_WIDTH    : INTEGER := 8;
    
    CONSTANT ADDR_SPACE             : INTEGER := pow2(g_NO_OF_ADDR_BITS);
    CONSTANT MEMORY_SIZE_GENERIC    : INTEGER := ADDR_SPACE * g_D_Q_WIDTH;    

    signal axi_bram_wren_high, axi_bram_wren_low : std_logic;
    signal axi_bram_wren : std_logic_vector(7 downto 0);
    signal axi_addr_del1, axi_addr_del2, axi_addr_del3 : std_logic_vector(2 downto 0);
    signal data_a_q : std_logic_vector(63 downto 0);
    
    signal RFI_axi_bram_wrEn : std_logic_vector(0 downto 0);
    signal RFI_data_a_q : std_logic_vector(31 downto 0);
    signal axi_memsel_del2, axi_memsel_del1 : std_logic_vector(1 downto 0);
    signal RFI_web : std_logic_vector(0 downto 0);
    
begin
    
    -- ARGS U55
    gen_u55_args : IF (C_TARGET_DEVICE = "U55") GENERATE
        reset_n <= not i_rst;
    
        datagen_memspace : axi_bram_ctrl_ct1_poly
        PORT MAP (
            s_axi_aclk      => i_clk,
            s_axi_aresetn   => reset_n, -- in std_logic;
            s_axi_awaddr    => i_vd_full_axi_mosi.awaddr(17 downto 0),
            s_axi_awlen     => i_vd_full_axi_mosi.awlen,
            s_axi_awsize    => i_vd_full_axi_mosi.awsize,
            s_axi_awburst   => i_vd_full_axi_mosi.awburst,
            s_axi_awlock    => i_vd_full_axi_mosi.awlock ,
            s_axi_awcache   => i_vd_full_axi_mosi.awcache,
            s_axi_awprot    => i_vd_full_axi_mosi.awprot,
            s_axi_awvalid   => i_vd_full_axi_mosi.awvalid,
            s_axi_awready   => o_vd_full_axi_miso.awready,
            s_axi_wdata     => i_vd_full_axi_mosi.wdata(31 downto 0),
            s_axi_wstrb     => i_vd_full_axi_mosi.wstrb(3 downto 0),
            s_axi_wlast     => i_vd_full_axi_mosi.wlast,
            s_axi_wvalid    => i_vd_full_axi_mosi.wvalid,
            s_axi_wready    => o_vd_full_axi_miso.wready,
            s_axi_bresp     => o_vd_full_axi_miso.bresp,
            s_axi_bvalid    => o_vd_full_axi_miso.bvalid,
            s_axi_bready    => i_vd_full_axi_mosi.bready ,
            s_axi_araddr    => i_vd_full_axi_mosi.araddr(17 downto 0),
            s_axi_arlen     => i_vd_full_axi_mosi.arlen,
            s_axi_arsize    => i_vd_full_axi_mosi.arsize,
            s_axi_arburst   => i_vd_full_axi_mosi.arburst,
            s_axi_arlock    => i_vd_full_axi_mosi.arlock ,
            s_axi_arcache   => i_vd_full_axi_mosi.arcache,
            s_axi_arprot    => i_vd_full_axi_mosi.arprot,
            s_axi_arvalid   => i_vd_full_axi_mosi.arvalid,
            s_axi_arready   => o_vd_full_axi_miso.arready,
            s_axi_rdata     => o_vd_full_axi_miso.rdata(31 downto 0),
            s_axi_rresp     => o_vd_full_axi_miso.rresp,
            s_axi_rlast     => o_vd_full_axi_miso.rlast,
            s_axi_rvalid    => o_vd_full_axi_miso.rvalid,
            s_axi_rready    => i_vd_full_axi_mosi.rready,
        
            bram_rst_a      => open,
            bram_clk_a      => open,
            bram_en_a       => axi_bram_en,      -- out std_logic;
            bram_we_a       => axi_bram_we_byte, -- out (3:0);
            bram_addr_a     => axi_bram_addr,    -- out (17:0);
            bram_wrdata_a   => axi_bram_wrdata,  -- out (31:0);
            bram_rddata_a   => axi_bram_rddata   -- in (31:0);
        );
        
        -- "axi_bram_addr" is a byte address
        -- "axi_addr" is address of 4-byte words
        -- Polynomials have (2 buffers) * (1024 virtual channels) * (80 bytes) = 163840 bytes 
        --  = 40960 (4-byte words)
        --  = 20480 (8-byte words)
        -- Transactions are always 32 bits wide, so only need to check 1 bit of the byte enable.
        axi_bram_wrEn_low  <= '1' when (axi_bram_en = '1') and (axi_bram_we_byte(0) = '1') and (axi_bram_addr(2) = '0') and (axi_bram_addr(17 downto 16) /= "11") else '0';
        axi_bram_wrEn_high <= '1' when (axi_bram_en = '1') and (axi_bram_we_byte(0) = '1') and (axi_bram_addr(2) = '1') and (axi_bram_addr(17 downto 16) /= "11") else '0';
        
        -- RFI threshold byte address from 0x30000 to 0x30FFF
        RFI_axi_bram_wrEn(0) <= '1' when (axi_bram_en = '1') and (axi_bram_we_byte(0) = '1') and (axi_bram_addr(17 downto 12) = "110000") else '0';
        axi_addr(15 downto 0) <= axi_bram_addr(17 downto 2);
        axi_addr(17 downto 16) <= "00";
        
    END GENERATE;

    -- ARGS Gaskets for V80
    gen_v80_args : IF (C_TARGET_DEVICE = "V80") GENERATE
        reg_proc : process(i_clk)
        begin
            if rising_edge(i_clk) then
                -- Address is already dropped byte bits by the time it is here.
                axi_bram_wrEn_low   <= noc_wren and (not noc_wr_adr(0));
                axi_bram_wrEn_high  <= noc_wren and (noc_wr_adr(0));
            
                if noc_wren = '1' and noc_wr_adr(0) = '0' and noc_wr_adr(17 downto 16) = "00" and noc_wr_adr(15 downto 14) /= "11" then
                    axi_bram_wrEn_low <= '1';
                else
                    axi_bram_wrEn_low <= '0';
                end if;
                
                if noc_wren = '1' and noc_wr_adr(0) = '1' and noc_wr_adr(17 downto 16) = "00" and noc_wr_adr(15 downto 14) /= "11" then
                    axi_bram_wrEn_high <= '1';
                else
                    axi_bram_wrEn_high <= '0';
                end if;
                
                axi_addr            <= noc_wr_adr;   -- IN STD_LOGIC_VECTOR(17 DOWNTO 0);
                axi_bram_wrdata     <= noc_wr_dat;
                
                if noc_wr_adr(17 downto 10) = "00110000" then
                    RFI_axi_bram_wrEn(0) <= '1';
                else
                    RFI_axi_bram_wrEn(0) <= '0';
                end if;
                
            end if;
        end process;        
    
        noc_rd_dat <= axi_bram_rddata;   -- OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    
    END GENERATE;
    
    axi_bram_wren(7 downto 4) <= axi_bram_wrEn_high & axi_bram_wren_high & axi_bram_wren_high & axi_bram_wren_high;
    axi_bram_wren(3 downto 0) <= axi_bram_wren_low & axi_bram_wren_low & axi_bram_wren_low & axi_bram_wren_low;
    
    axi_bram_wrdata_64bit <= axi_bram_wrdata & axi_bram_wrdata;
    
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            axi_addr_del1 <= axi_addr(2 downto 0);
            axi_addr_del2 <= axi_addr_del1;
            axi_addr_del3 <= axi_addr_del2;
            
            axi_memsel_del1 <= axi_addr(15 downto 14);
            axi_memsel_del2 <= axi_memsel_del1;
            
        end if;
    end process;
    
    axi_bram_rddata <= 
        RFI_data_a_q when axi_memsel_del2 = "11" else
        data_a_q(31 downto 0) when axi_addr_del2(0) = '0' else 
        data_a_q(63 downto 32);
    
    
    uram_1 : xpm_memory_tdpram
    generic map (    
        -- Common module generics
        AUTO_SLEEP_TIME         => 0,              --Do not Change
        CASCADE_HEIGHT          => 0,
        CLOCKING_MODE           => "common_clock", --string; "common_clock", "independent_clock" 
        ECC_MODE                => "no_ecc",       --string; "no_ecc", "encode_only", "decode_only" or "both_encode_and_decode" 

        MEMORY_INIT_FILE        => "none",          --string; "none" or "<filename>.mem" 
        MEMORY_INIT_PARAM       => "",              --string;
        MEMORY_OPTIMIZATION     => "true",          --string; "true", "false" 
        MEMORY_PRIMITIVE        => "ultra",         --string; "auto", "distributed", "block" or "ultra" ;
        MEMORY_SIZE             => 1310720,         -- Total memory size in bits; 20480 x 64 bits = 1310720
        MESSAGE_CONTROL         => 0,               --integer; 0,1

        USE_MEM_INIT            => 0,               --integer; 0,1
        WAKEUP_TIME             => "disable_sleep", --string; "disable_sleep" or "use_sleep_pin" 
        USE_EMBEDDED_CONSTRAINT => 0,               --integer: 0,1
       
    
        RST_MODE_A              => "SYNC",   
        RST_MODE_B              => "SYNC", 
        WRITE_MODE_A            => "no_change",    --string; "write_first", "read_first", "no_change" 
        WRITE_MODE_B            => "no_change",    --string; "write_first", "read_first", "no_change" 

        -- Port A module generics ... ARGs side
        READ_DATA_WIDTH_A       => 64,    
        READ_LATENCY_A          => C_ARGS_RD_LATENCY,              
        READ_RESET_VALUE_A      => "0",            

        WRITE_DATA_WIDTH_A      => 64,
        BYTE_WRITE_WIDTH_A      => 8,
        ADDR_WIDTH_A            => 15,
    
        -- Port B module generics
        READ_DATA_WIDTH_B       => 64,
        READ_LATENCY_B          => 3,
        READ_RESET_VALUE_B      => "0",

        WRITE_DATA_WIDTH_B      => 64,
        BYTE_WRITE_WIDTH_B      => 8,
        ADDR_WIDTH_B            => 15
    ) port map (
        -- Common module ports
        sleep                   => '0',
        -- Port A side
        clka                    => i_clk,  -- clock from the 100GE core; 322 MHz
        rsta                    => '0',
        ena                     => '1',
        regcea                  => '1',

        wea                     => axi_bram_wren,  -- 7:0
        addra                   => axi_addr(15 downto 1), -- axi_addr is a 4-byte address, memory is 8-bytes wide
        dina                    => axi_bram_wrdata_64bit,
        douta                   => data_a_q,

        -- Port B side
        clkb                    => i_clk, 
        rstb                    => '0',
        enb                     => '1',
        regceb                  => '1',

        web                     => "00000000",
        addrb                   => i_bram_addr,
        dinb                    => x"0000000000000000",
        doutb                   => o_bram_rddata,

        -- other features
        injectsbiterra          => '0',
        injectdbiterra          => '0',
        injectsbiterrb          => '0',
        injectdbiterrb          => '0',        
        sbiterra                => open,
        dbiterra                => open,
        sbiterrb                => open,
        dbiterrb                => open
    );    
    
    -- RFI threshold memory
    -- 32-bit value for each virtual channel.
    bram_1 : xpm_memory_tdpram
    generic map (    
        -- Common module generics
        AUTO_SLEEP_TIME         => 0,              --Do not Change
        CASCADE_HEIGHT          => 0,
        CLOCKING_MODE           => "common_clock", --string; "common_clock", "independent_clock" 
        ECC_MODE                => "no_ecc",       --string; "no_ecc", "encode_only", "decode_only" or "both_encode_and_decode" 
        MEMORY_INIT_FILE        => "none",          --string; "none" or "<filename>.mem" 
        MEMORY_INIT_PARAM       => "",              --string;
        MEMORY_OPTIMIZATION     => "true",          --string; "true", "false" 
        MEMORY_PRIMITIVE        => "block",         --string; "auto", "distributed", "block" or "ultra" ;
        MEMORY_SIZE             => 32768,           -- Total memory size in bits; 1024 x 32 bits = 32768
        MESSAGE_CONTROL         => 0,               --integer; 0,1

        USE_MEM_INIT            => 0,               --integer; 0,1
        WAKEUP_TIME             => "disable_sleep", --string; "disable_sleep" or "use_sleep_pin" 
        USE_EMBEDDED_CONSTRAINT => 0,               --integer: 0,1
       
    
        RST_MODE_A              => "SYNC",   
        RST_MODE_B              => "SYNC", 
        WRITE_MODE_A            => "no_change",    --string; "write_first", "read_first", "no_change" 
        WRITE_MODE_B            => "no_change",    --string; "write_first", "read_first", "no_change" 

        -- Port A module generics ... ARGs side
        READ_DATA_WIDTH_A       => 32,    
        READ_LATENCY_A          => C_ARGS_RD_LATENCY,              
        READ_RESET_VALUE_A      => "0",            

        WRITE_DATA_WIDTH_A      => 32,
        BYTE_WRITE_WIDTH_A      => 32,
        ADDR_WIDTH_A            => 10,
    
        -- Port B module generics
        READ_DATA_WIDTH_B       => 32,
        READ_LATENCY_B          => 3,
        READ_RESET_VALUE_B      => "0",

        WRITE_DATA_WIDTH_B      => 32,
        BYTE_WRITE_WIDTH_B      => 32,
        ADDR_WIDTH_B            => 10
    ) port map (
        -- Common module ports
        sleep                   => '0',
        -- Port A side
        clka                    => i_clk,  -- clock from the 100GE core; 322 MHz
        rsta                    => '0',
        ena                     => '1',
        regcea                  => '1',

        wea                     => RFI_axi_bram_wren,  -- 7:0
        addra                   => axi_addr(9 downto 0), -- axi bram controller generates 4-byte addresses
        dina                    => axi_bram_wrdata,
        douta                   => RFI_data_a_q,

        -- Port B side
        clkb                    => i_clk, 
        rstb                    => '0',
        enb                     => '1',
        regceb                  => '1',

        web                     => RFI_web,
        addrb                   => i_RFI_bram_addr,
        dinb                    => x"00000000",
        doutb                   => o_RFI_bram_rddata,

        -- other features
        injectsbiterra          => '0',
        injectdbiterra          => '0',
        injectsbiterrb          => '0',
        injectdbiterrb          => '0',        
        sbiterra                => open,
        dbiterra                => open,
        sbiterrb                => open,
        dbiterrb                => open
    );    
    
    RFI_web(0) <= '0';
    
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            o_dbg_wrEn <= axi_bram_wrEn_low or axi_bram_wrEn_high;
            o_dbg_wrAddr <= axi_bram_addr(17 downto 3);
        end if;
    end process;
    
end Behavioral;


				
			

