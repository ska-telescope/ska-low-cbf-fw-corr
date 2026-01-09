----------------------------------------------------------------------------------
-- Company:  CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 09/06/2023 11:33:47 PM
-- Module Name: poly_axi_bram_wrapper_v80 - Behavioral
-- Description:
--  Interface axi full to a block of ultraRAMs to hold the polynomial coeficients.
--  2 separate memories :
--   -----------------------------------------------------------------------------
--   Polynomials:
--     (2 buffers) * (3072 polynomials) * (10 words/polynomial) * (8 bytes/word) = 
--     480 kBytes = 61440 * 8 bytes
--                = 122880 * 4 bytes
--     Base address is 0x0
--     Valid addresses of 4-byte words range from 0x0 to x1DFFF
--   -----------------------------------------------------------------------------
--   RFI Thresholds:
--    (3072 virtual channels) * (4 bytes) = 12288 bytes
--    Base address is 491520 = 0x78000              (byte address)
--                    491520/4 = 122880 = 0x1E000   (4-byte address)
--                    491520/8 = 61440  = 0xF000    (8-byte address)
--    Range of valid NOC (4-byte word) addresses is 0x1E000 to 0x1EC00 
-- ---------------------------------------------------------------------
--  19 bit byte address = 524288 bytes of address space
-- 
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

entity poly_axi_bram_wrapper_v80 is
    port (
        i_clk : in std_logic;
        i_rst : in std_logic;
        -------------------------------------------------------
        -- Block ram interface for access by the rest of the module
        -- Memory is 20480 x 8 byte words
        -- read latency 3 clocks
        i_bram_addr         : in std_logic_vector(15 downto 0); -- 16 bit address of 8-byte words (= 19 bit byte address)
        o_bram_rddata       : out std_logic_vector(63 downto 0);
        -- 1024 x 4-byte words for the RFI threshold
        i_RFI_bram_addr   : in  std_logic_vector(11 downto 0);
        o_RFI_bram_rddata : out std_logic_vector(31 downto 0);
        ------------------------------------------------------
        noc_wren            : IN STD_LOGIC;
        noc_wr_adr          : IN STD_LOGIC_VECTOR(17 DOWNTO 0); -- This is a 4-byte address from the NOC
        noc_wr_dat          : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
        noc_rd_dat          : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
        ------------------------------------------------------
        -- debug
        o_dbg_wrEn : out std_logic;
        o_dbg_wrAddr : out std_logic_vector(14 downto 0) 
    );
end poly_axi_bram_wrapper_v80;

architecture Behavioral of poly_axi_bram_wrapper_v80 is
    
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
    signal axi_memsel_del2, axi_memsel_del1 : std_logic_vector(4 downto 0);
    signal RFI_web : std_logic_vector(0 downto 0);
    
begin

    -- ARGS Gaskets for V80
    reg_proc : process(i_clk)
    begin
        if rising_edge(i_clk) then
            -- Address is already dropped byte bits by the time it is here.
            axi_bram_wrEn_low   <= noc_wren and (not noc_wr_adr(0));
            axi_bram_wrEn_high  <= noc_wren and (noc_wr_adr(0));
        
            -- Valid noc_wr_adr ranges from 0x0 to 0x1DFFF = 122880
            if noc_wren = '1' and noc_wr_adr(0) = '0' and (unsigned(noc_wr_adr) < 122880) then
                axi_bram_wrEn_low <= '1';
            else
                axi_bram_wrEn_low <= '0';
            end if;
            
            if noc_wren = '1' and noc_wr_adr(0) = '1' and (unsigned(noc_wr_adr) < 122880) then
                axi_bram_wrEn_high <= '1';
            else
                axi_bram_wrEn_high <= '0';
            end if;
            
            axi_addr        <= noc_wr_adr;   -- in (17:0);
            axi_bram_wrdata <= noc_wr_dat;
            
            -- Range of valid NOC (4-byte word) addresses is 0x1E000 to 0x1EBFF 
            if noc_wr_adr(17 downto 12) = "011110" and (noc_wr_adr(11 downto 10) = "00" or noc_wr_adr(11 downto 10) = "01" or noc_wr_adr(11 downto 10) = "10") then
                RFI_axi_bram_wrEn(0) <= '1';
            else
                RFI_axi_bram_wrEn(0) <= '0';
            end if;
            
        end if;
    end process;        

    noc_rd_dat <= axi_bram_rddata;   -- OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    
    axi_bram_wren(7 downto 4) <= axi_bram_wrEn_high & axi_bram_wren_high & axi_bram_wren_high & axi_bram_wren_high;
    axi_bram_wren(3 downto 0) <= axi_bram_wren_low & axi_bram_wren_low & axi_bram_wren_low & axi_bram_wren_low;
    
    axi_bram_wrdata_64bit <= axi_bram_wrdata & axi_bram_wrdata;
    
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            axi_addr_del1 <= axi_addr(2 downto 0);
            axi_addr_del2 <= axi_addr_del1;
            axi_addr_del3 <= axi_addr_del2;
            
            axi_memsel_del1 <= axi_addr(16 downto 12);
            axi_memsel_del2 <= axi_memsel_del1;
        end if;
    end process;
    
    axi_bram_rddata <= 
        RFI_data_a_q when axi_memsel_del2 = "11110" else
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
        MEMORY_SIZE             => 3932160,         -- Total memory size in bits; (2 buffers) * (3072 virtual channels) * (10 words) * (64 bits/word) = 3932160
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
        ADDR_WIDTH_A            => 16,
    
        -- Port B module generics
        READ_DATA_WIDTH_B       => 64,
        READ_LATENCY_B          => 3,
        READ_RESET_VALUE_B      => "0",

        WRITE_DATA_WIDTH_B      => 64,
        BYTE_WRITE_WIDTH_B      => 8,
        ADDR_WIDTH_B            => 16
    ) port map (
        -- Common module ports
        sleep                   => '0',
        -- Port A side
        clka                    => i_clk,  -- clock from the 100GE core; 322 MHz
        rsta                    => '0',
        ena                     => '1',
        regcea                  => '1',

        wea                     => axi_bram_wren,  -- 7:0
        addra                   => axi_addr(16 downto 1), -- axi_addr is a 4-byte address, memory is 8-bytes wide
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
        MEMORY_INIT_FILE        => "none",         --string; "none" or "<filename>.mem" 
        MEMORY_INIT_PARAM       => "",             --string;
        MEMORY_OPTIMIZATION     => "true",         --string; "true", "false" 
        MEMORY_PRIMITIVE        => "block",        --string; "auto", "distributed", "block" or "ultra" ;
        MEMORY_SIZE             => 98304,          -- Total memory size in bits; 3072 x 32 bits = 98304
        MESSAGE_CONTROL         => 0,              --integer; 0,1

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
        ADDR_WIDTH_A            => 12,
    
        -- Port B module generics
        READ_DATA_WIDTH_B       => 32,
        READ_LATENCY_B          => 3,
        READ_RESET_VALUE_B      => "0",

        WRITE_DATA_WIDTH_B      => 32,
        BYTE_WRITE_WIDTH_B      => 32,
        ADDR_WIDTH_B            => 12
    ) port map (
        -- Common module ports
        sleep                   => '0',
        -- Port A side
        clka                    => i_clk,  -- clock from the 100GE core; 322 MHz
        rsta                    => '0',
        ena                     => '1',
        regcea                  => '1',

        wea                     => RFI_axi_bram_wren,  -- 7:0
        addra                   => axi_addr(11 downto 0), -- axi bram controller generates 4-byte addresses
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
