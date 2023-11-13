----------------------------------------------------------------------------------
-- Company:  CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 09/06/2023 11:33:47 PM
-- Module Name: poly_axi_bram_wrapper - Behavioral
-- Description: 
--  Interface axi full to a block of ultraRAMs to hold the polynomial coeficients.
--  (2 buffers) * (1024 polynomials) * (10 words/polynomial) * (8 bytes/word) = 
--  160 kBytes = 20480 * 8 bytes
--             = 40960 * 4 bytes
-- 
--  Input is 18-bit byte address = 262,144 byte address space, of which the low 160 kbyte = 163840 bytes is used.
----------------------------------------------------------------------------------
library IEEE, common_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
Library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;
use common_lib.common_pkg.ALL;
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
        i_bram_addr    : in std_logic_vector(14 downto 0); -- 15 bit address = 8-byte word address (=18 bit byte address)
        o_bram_rddata  : out std_logic_vector(63 downto 0);
        ------------------------------------------------------
        -- AXI full interface
        i_vd_full_axi_mosi : in  t_axi4_full_mosi;
        o_vd_full_axi_miso : out t_axi4_full_miso
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
 
begin

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

    -- Transactions are always 32 bits wide, so only need to check 1 bit of the byte enable.
    axi_bram_wrEn_low <= axi_bram_en and axi_bram_we_byte(0) and (not axi_bram_addr(2));
    axi_bram_wrEn_high <= axi_bram_en and axi_bram_we_byte(0) and (axi_bram_addr(2));
    
    axi_bram_wren <= axi_bram_wrEn_high & axi_bram_wren_high & axi_bram_wren_high & axi_bram_wren_high &
                     axi_bram_wren_low & axi_bram_wren_low & axi_bram_wren_low & axi_bram_wren_low;
    
    axi_bram_wrdata_64bit <= axi_bram_wrdata & axi_bram_wrdata;
    
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            axi_addr_del1 <= axi_bram_addr(2 downto 0);
            axi_addr_del2 <= axi_addr_del1;
            axi_addr_del3 <= axi_addr_del2;
        end if;
    end process;
    
    axi_bram_rddata <= data_a_q(31 downto 0) when axi_addr_del3(2) = '0' else data_a_q(63 downto 32);
    
    
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
        READ_LATENCY_A          => 3,              
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
        addra                   => axi_bram_addr(17 downto 3), -- axi bram controller generates byte addresses
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

end Behavioral;



-- XPM_MEMORY instantiation template for True Dual Port RAM configurations
-- Refer to the targeted device family architecture libraries guide for XPM_MEMORY documentation
-- =======================================================================================================================

-- Parameter usage table, organized as follows:
-- +---------------------------------------------------------------------------------------------------------------------+
-- | Parameter name       | Data type          | Restrictions, if applicable                                             |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Description                                                                                                         |
-- +---------------------------------------------------------------------------------------------------------------------+
-- +---------------------------------------------------------------------------------------------------------------------+
-- | ADDR_WIDTH_A         | Integer            | Range: 1 - 20. Default value = 6.                                       |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specify the width of the port A address port addra, in bits.                                                        |
-- | Must be large enough to access the entire memory from port A, i.e. &gt;= $clog2(MEMORY_SIZE/[WRITE|READ]_DATA_WIDTH_A).|
-- +---------------------------------------------------------------------------------------------------------------------+
-- | ADDR_WIDTH_B         | Integer            | Range: 1 - 20. Default value = 6.                                       |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specify the width of the port B address port addrb, in bits.                                                        |
-- | Must be large enough to access the entire memory from port B, i.e. &gt;= $clog2(MEMORY_SIZE/[WRITE|READ]_DATA_WIDTH_B).|
-- +---------------------------------------------------------------------------------------------------------------------+
-- | AUTO_SLEEP_TIME      | Integer            | Range: 0 - 15. Default value = 0.                                       |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Number of clk[a|b] cycles to auto-sleep, if feature is available in architecture                                    |
-- | 0 - Disable auto-sleep feature                                                                                      |
-- | 3-15 - Number of auto-sleep latency cycles                                                                          |
-- | Do not change from the value provided in the template instantiation                                                 |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | BYTE_WRITE_WIDTH_A   | Integer            | Range: 1 - 4608. Default value = 32.                                    |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | To enable byte-wide writes on port A, specify the byte width, in bits-                                              |
-- | 8- 8-bit byte-wide writes, legal when WRITE_DATA_WIDTH_A is an integer multiple of 8                                |
-- | 9- 9-bit byte-wide writes, legal when WRITE_DATA_WIDTH_A is an integer multiple of 9                                |
-- | Or to enable word-wide writes on port A, specify the same value as for WRITE_DATA_WIDTH_A.                          |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | BYTE_WRITE_WIDTH_B   | Integer            | Range: 1 - 4608. Default value = 32.                                    |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | To enable byte-wide writes on port B, specify the byte width, in bits-                                              |
-- | 8- 8-bit byte-wide writes, legal when WRITE_DATA_WIDTH_B is an integer multiple of 8                                |
-- | 9- 9-bit byte-wide writes, legal when WRITE_DATA_WIDTH_B is an integer multiple of 9                                |
-- | Or to enable word-wide writes on port B, specify the same value as for WRITE_DATA_WIDTH_B.                          |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | CASCADE_HEIGHT       | Integer            | Range: 0 - 64. Default value = 0.                                       |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | 0- No Cascade Height, Allow Vivado Synthesis to choose.                                                             |
-- | 1 or more - Vivado Synthesis sets the specified value as Cascade Height.                                            |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | CLOCKING_MODE        | String             | Allowed values: common_clock, independent_clock. Default value = common_clock.|
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Designate whether port A and port B are clocked with a common clock or with independent clocks-                     |
-- | "common_clock"- Common clocking; clock both port A and port B with clka                                             |
-- | "independent_clock"- Independent clocking; clock port A with clka and port B with clkb                              |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | ECC_MODE             | String             | Allowed values: no_ecc, both_encode_and_decode, decode_only, encode_only. Default value = no_ecc.|
-- |---------------------------------------------------------------------------------------------------------------------|
-- |                                                                                                                     |
-- |   "no_ecc" - Disables ECC                                                                                           |
-- |   "encode_only" - Enables ECC Encoder only                                                                          |
-- |   "decode_only" - Enables ECC Decoder only                                                                          |
-- |   "both_encode_and_decode" - Enables both ECC Encoder and Decoder                                                   |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | MEMORY_INIT_FILE     | String             | Default value = none.                                                   |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specify "none" (including quotes) for no memory initialization, or specify the name of a memory initialization file-|
-- | Enter only the name of the file with .mem extension, including quotes but without path (e.g. "my_file.mem").        |
-- | File format must be ASCII and consist of only hexadecimal values organized into the specified depth by              |
-- | narrowest data width generic value of the memory. Initialization of memory happens through the file name specified only when parameter|
-- | MEMORY_INIT_PARAM value is equal to "". |                                                                           |
-- | When using XPM_MEMORY in a project, add the specified file to the Vivado project as a design source.                |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | MEMORY_INIT_PARAM    | String             | Default value = 0.                                                      |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specify "" or "0" (including quotes) for no memory initialization through parameter, or specify the string          |
-- | containing the hex characters. Enter only hex characters with each location separated by delimiter (,).             |
-- | Parameter format must be ASCII and consist of only hexadecimal values organized into the specified depth by         |
-- | narrowest data width generic value of the memory.For example, if the narrowest data width is 8, and the depth of    |
-- | memory is 8 locations, then the parameter value should be passed as shown below.                                    |
-- | parameter MEMORY_INIT_PARAM = "AB,CD,EF,1,2,34,56,78"                                                               |
-- | Where "AB" is the 0th location and "78" is the 7th location.                                                        |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | MEMORY_OPTIMIZATION  | String             | Allowed values: true, false. Default value = true.                      |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specify "true" to enable the optimization of unused memory or bits in the memory structure. Specify "false" to      |
-- | disable the optimization of unused memory or bits in the memory structure.                                          |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | MEMORY_PRIMITIVE     | String             | Allowed values: auto, block, distributed, mixed, ultra. Default value = auto.|
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Designate the memory primitive (resource type) to use-                                                              |
-- | "auto"- Allow Vivado Synthesis to choose                                                                            |
-- | "distributed"- Distributed memory                                                                                   |
-- | "block"- Block memory                                                                                               |
-- | "ultra"- Ultra RAM memory                                                                                           |
-- | "mixed"- Mixed memory                                                                                               |
-- | NOTE: There may be a behavior mismatch if Block RAM or Ultra RAM specific features, like ECC or Asymmetry, are selected with MEMORY_PRIMITIVE set to "auto".|
-- +---------------------------------------------------------------------------------------------------------------------+
-- | MEMORY_SIZE          | Integer            | Range: 2 - 150994944. Default value = 2048.                             |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specify the total memory array size, in bits.                                                                       |
-- | For example, enter 65536 for a 2kx32 RAM.                                                                           |
-- | When ECC is enabled and set to "encode_only", then the memory size has to be multiples of READ_DATA_WIDTH_[A|B]     |
-- | When ECC is enabled and set to "decode_only", then the memory size has to be multiples of WRITE_DATA_WIDTH_[A|B].   |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | MESSAGE_CONTROL      | Integer            | Range: 0 - 1. Default value = 0.                                        |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specify 1 to enable the dynamic message reporting such as collision warnings, and 0 to disable the message reporting|
-- +---------------------------------------------------------------------------------------------------------------------+
-- | READ_DATA_WIDTH_A    | Integer            | Range: 1 - 4608. Default value = 32.                                    |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specify the width of the port A read data output port douta, in bits.                                               |
-- | The values of READ_DATA_WIDTH_A and WRITE_DATA_WIDTH_A must be equal.                                               |
-- | When ECC is enabled and set to "encode_only", then READ_DATA_WIDTH_A has to be multiples of 72-bits                 |
-- | When ECC is enabled and set to "decode_only" or "both_encode_and_decode", then READ_DATA_WIDTH_A has to be          |
-- | multiples of 64-bits.                                                                                               |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | READ_DATA_WIDTH_B    | Integer            | Range: 1 - 4608. Default value = 32.                                    |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specify the width of the port B read data output port doutb, in bits.                                               |
-- | The values of READ_DATA_WIDTH_B and WRITE_DATA_WIDTH_B must be equal.                                               |
-- | When ECC is enabled and set to "encode_only", then READ_DATA_WIDTH_B has to be multiples of 72-bits                 |
-- | When ECC is enabled and set to "decode_only" or "both_encode_and_decode", then READ_DATA_WIDTH_B has to be          |
-- | multiples of 64-bits.                                                                                               |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | READ_LATENCY_A       | Integer            | Range: 0 - 100. Default value = 2.                                      |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specify the number of register stages in the port A read data pipeline. Read data output to port douta takes this   |
-- | number of clka cycles.                                                                                              |
-- | To target block memory, a value of 1 or larger is required- 1 causes use of memory latch only; 2 causes use of      |
-- | output register. To target distributed memory, a value of 0 or larger is required- 0 indicates combinatorial output.|
-- | Values larger than 2 synthesize additional flip-flops that are not retimed into memory primitives.                  |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | READ_LATENCY_B       | Integer            | Range: 0 - 100. Default value = 2.                                      |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specify the number of register stages in the port B read data pipeline. Read data output to port doutb takes this   |
-- | number of clkb cycles (clka when CLOCKING_MODE is "common_clock").                                                  |
-- | To target block memory, a value of 1 or larger is required- 1 causes use of memory latch only; 2 causes use of      |
-- | output register. To target distributed memory, a value of 0 or larger is required- 0 indicates combinatorial output.|
-- | Values larger than 2 synthesize additional flip-flops that are not retimed into memory primitives.                  |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | READ_RESET_VALUE_A   | String             | Default value = 0.                                                      |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specify the reset value of the port A final output register stage in response to rsta input port is assertion.      |
-- | As this parameter is a string, please specify the hex values inside double quotes. As an example,                   |
-- | If the read data width is 8, then specify READ_RESET_VALUE_A = "EA";                                                |
-- | When ECC is enabled, then reset value is not supported.                                                             |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | READ_RESET_VALUE_B   | String             | Default value = 0.                                                      |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specify the reset value of the port B final output register stage in response to rstb input port is assertion.      |
-- | As this parameter is a string, please specify the hex values inside double quotes. As an example,                   |
-- | If the read data width is 8, then specify READ_RESET_VALUE_B = "EA";                                                |
-- | When ECC is enabled, then reset value is not supported.                                                             |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | RST_MODE_A           | String             | Allowed values: SYNC, ASYNC. Default value = SYNC.                      |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Describes the behaviour of the reset                                                                                |
-- |                                                                                                                     |
-- |   "SYNC" - when reset is applied, synchronously resets output port douta to the value specified by parameter READ_RESET_VALUE_A|
-- |   "ASYNC" - when reset is applied, asynchronously resets output port douta to zero                                  |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | RST_MODE_B           | String             | Allowed values: SYNC, ASYNC. Default value = SYNC.                      |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Describes the behaviour of the reset                                                                                |
-- |                                                                                                                     |
-- |   "SYNC" - when reset is applied, synchronously resets output port doutb to the value specified by parameter READ_RESET_VALUE_B|
-- |   "ASYNC" - when reset is applied, asynchronously resets output port doutb to zero                                  |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | SIM_ASSERT_CHK       | Integer            | Range: 0 - 1. Default value = 0.                                        |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | 0- Disable simulation message reporting. Messages related to potential misuse will not be reported.                 |
-- | 1- Enable simulation message reporting. Messages related to potential misuse will be reported.                      |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | USE_EMBEDDED_CONSTRAINT| Integer            | Range: 0 - 1. Default value = 0.                                        |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specify 1 to enable the set_false_path constraint addition between clka of Distributed RAM and doutb_reg on clkb    |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | USE_MEM_INIT         | Integer            | Range: 0 - 1. Default value = 1.                                        |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specify 1 to enable the generation of below message and 0 to disable generation of the following message completely.|
-- | "INFO - MEMORY_INIT_FILE and MEMORY_INIT_PARAM together specifies no memory initialization.                         |
-- | Initial memory contents will be all 0s."                                                                            |
-- | NOTE: This message gets generated only when there is no Memory Initialization specified either through file or      |
-- | Parameter.                                                                                                          |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | USE_MEM_INIT_MMI     | Integer            | Range: 0 - 1. Default value = 0.                                        |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specify 1 to expose this memory information to be written out in the MMI file.                                      |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | WAKEUP_TIME          | String             | Allowed values: disable_sleep, use_sleep_pin. Default value = disable_sleep.|
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specify "disable_sleep" to disable dynamic power saving option, and specify "use_sleep_pin" to enable the           |
-- | dynamic power saving option                                                                                         |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | WRITE_DATA_WIDTH_A   | Integer            | Range: 1 - 4608. Default value = 32.                                    |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specify the width of the port A write data input port dina, in bits.                                                |
-- | The values of WRITE_DATA_WIDTH_A and READ_DATA_WIDTH_A must be equal.                                               |
-- | When ECC is enabled and set to "encode_only" or "both_encode_and_decode", then WRITE_DATA_WIDTH_A has to be         |
-- | multiples of 64-bits                                                                                                |
-- | When ECC is enabled and set to "decode_only", then WRITE_DATA_WIDTH_A has to be multiples of 72-bits.               |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | WRITE_DATA_WIDTH_B   | Integer            | Range: 1 - 4608. Default value = 32.                                    |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Specify the width of the port B write data input port dinb, in bits.                                                |
-- | The values of WRITE_DATA_WIDTH_B and READ_DATA_WIDTH_B must be equal.                                               |
-- | When ECC is enabled and set to "encode_only" or "both_encode_and_decode", then WRITE_DATA_WIDTH_B has to be         |
-- | multiples of 64-bits                                                                                                |
-- | When ECC is enabled and set to "decode_only", then WRITE_DATA_WIDTH_B has to be multiples of 72-bits.               |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | WRITE_MODE_A         | String             | Allowed values: no_change, read_first, write_first. Default value = no_change.|
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Write mode behavior for port A output data port, douta.                                                             |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | WRITE_MODE_B         | String             | Allowed values: no_change, read_first, write_first. Default value = no_change.|
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Write mode behavior for port B output data port, doutb.                                                             |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | WRITE_PROTECT        | Integer            | Range: 0 - 1. Default value = 1.                                        |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Default value is 1, means write is protected through enable and write enable and hence the LUT is placed before the memory. This is the default behaviour to access memory.|
-- | When 0, disables write protection. Write enable (WE) directly connected to memory.                                  |
-- | NOTE: Disable this option only if the advanced users can guarantee that the write enable (WE) cannot be given without enable (EN).|
-- +---------------------------------------------------------------------------------------------------------------------+

-- Port usage table, organized as follows:
-- +---------------------------------------------------------------------------------------------------------------------+
-- | Port name      | Direction | Size, in bits                         | Domain  | Sense       | Handling if unused     |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Description                                                                                                         |
-- +---------------------------------------------------------------------------------------------------------------------+
-- +---------------------------------------------------------------------------------------------------------------------+
-- | addra          | Input     | ADDR_WIDTH_A                          | clka    | NA          | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Address for port A write and read operations.                                                                       |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | addrb          | Input     | ADDR_WIDTH_B                          | clkb    | NA          | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Address for port B write and read operations.                                                                       |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | clka           | Input     | 1                                     | NA      | Rising edge | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Clock signal for port A. Also clocks port B when parameter CLOCKING_MODE is "common_clock".                         |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | clkb           | Input     | 1                                     | NA      | Rising edge | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Clock signal for port B when parameter CLOCKING_MODE is "independent_clock".                                        |
-- | Unused when parameter CLOCKING_MODE is "common_clock".                                                              |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | dbiterra       | Output    | 1                                     | clka    | Active-high | DoNotCare              |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Status signal to indicate double bit error occurrence on the data output of port A.                                 |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | dbiterrb       | Output    | 1                                     | clkb    | Active-high | DoNotCare              |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Status signal to indicate double bit error occurrence on the data output of port A.                                 |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | dina           | Input     | WRITE_DATA_WIDTH_A                    | clka    | NA          | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Data input for port A write operations.                                                                             |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | dinb           | Input     | WRITE_DATA_WIDTH_B                    | clkb    | NA          | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Data input for port B write operations.                                                                             |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | douta          | Output    | READ_DATA_WIDTH_A                     | clka    | NA          | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Data output for port A read operations.                                                                             |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | doutb          | Output    | READ_DATA_WIDTH_B                     | clkb    | NA          | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Data output for port B read operations.                                                                             |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | ena            | Input     | 1                                     | clka    | Active-high | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Memory enable signal for port A.                                                                                    |
-- | Must be high on clock cycles when read or write operations are initiated. Pipelined internally.                     |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | enb            | Input     | 1                                     | clkb    | Active-high | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Memory enable signal for port B.                                                                                    |
-- | Must be high on clock cycles when read or write operations are initiated. Pipelined internally.                     |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | injectdbiterra | Input     | 1                                     | clka    | Active-high | Tie to 1'b0            |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Controls double bit error injection on input data when ECC enabled (Error injection capability is not available in  |
-- | "decode_only" mode).                                                                                                |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | injectdbiterrb | Input     | 1                                     | clkb    | Active-high | Tie to 1'b0            |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Controls double bit error injection on input data when ECC enabled (Error injection capability is not available in  |
-- | "decode_only" mode).                                                                                                |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | injectsbiterra | Input     | 1                                     | clka    | Active-high | Tie to 1'b0            |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Controls single bit error injection on input data when ECC enabled (Error injection capability is not available in  |
-- | "decode_only" mode).                                                                                                |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | injectsbiterrb | Input     | 1                                     | clkb    | Active-high | Tie to 1'b0            |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Controls single bit error injection on input data when ECC enabled (Error injection capability is not available in  |
-- | "decode_only" mode).                                                                                                |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | regcea         | Input     | 1                                     | clka    | Active-high | Tie to 1'b1            |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Clock Enable for the last register stage on the output data path.                                                   |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | regceb         | Input     | 1                                     | clkb    | Active-high | Tie to 1'b1            |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Clock Enable for the last register stage on the output data path.                                                   |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | rsta           | Input     | 1                                     | clka    | Active-high | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Reset signal for the final port A output register stage.                                                            |
-- | Synchronously resets output port douta to the value specified by parameter READ_RESET_VALUE_A.                      |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | rstb           | Input     | 1                                     | clkb    | Active-high | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Reset signal for the final port B output register stage.                                                            |
-- | Synchronously resets output port doutb to the value specified by parameter READ_RESET_VALUE_B.                      |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | sbiterra       | Output    | 1                                     | clka    | Active-high | DoNotCare              |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Status signal to indicate single bit error occurrence on the data output of port A.                                 |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | sbiterrb       | Output    | 1                                     | clkb    | Active-high | DoNotCare              |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Status signal to indicate single bit error occurrence on the data output of port B.                                 |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | sleep          | Input     | 1                                     | NA      | Active-high | Tie to 1'b0            |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | sleep signal to enable the dynamic power saving feature.                                                            |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | wea            | Input     | WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A | clka    | Active-high | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Write enable vector for port A input data port dina. 1 bit wide when word-wide writes are used.                     |
-- | In byte-wide write configurations, each bit controls the writing one byte of dina to address addra.                 |
-- | For example, to synchronously write only bits [15-8] of dina when WRITE_DATA_WIDTH_A is 32, wea would be 4'b0010.   |
-- +---------------------------------------------------------------------------------------------------------------------+
-- | web            | Input     | WRITE_DATA_WIDTH_B/BYTE_WRITE_WIDTH_B | clkb    | Active-high | Required               |
-- |---------------------------------------------------------------------------------------------------------------------|
-- | Write enable vector for port B input data port dinb. 1 bit wide when word-wide writes are used.                     |
-- | In byte-wide write configurations, each bit controls the writing one byte of dinb to address addrb.                 |
-- | For example, to synchronously write only bits [15-8] of dinb when WRITE_DATA_WIDTH_B is 32, web would be 4'b0010.   |
-- +---------------------------------------------------------------------------------------------------------------------+


				
			

