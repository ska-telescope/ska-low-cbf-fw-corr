----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 15.03.2021 15:00:34
-- Design Name: 
-- Module Name: HBM_axi_tbModel - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
--  Model of the HBM to use in the testbench.
--  Includes a high read latency, to mimic the real HBM.
--  The memory is up to 4GBytes in size.
--  Memory is allocated on the fly in blocks of 4 Kbytes when it is written.
--
--  
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.math_real.all ;
library xpm;
use xpm.vcomponents.all;
use std.textio.all;
use IEEE.std_logic_textio.all;
library xil_defaultlib;
use xil_defaultlib.ALL;

entity HBM_axi_tbModel is
    generic (
        AXI_ADDR_WIDTH : integer := 32;   -- Byte address width. This also defines the amount of data. Use the correct width for the HBM memory block, e.g. 28 bits for 256 MBytes.
        AXI_ID_WIDTH : integer := 1;
        AXI_DATA_WIDTH : integer := 256;  -- Must be a multiple of 32 bits.
        READ_QUEUE_SIZE : integer := 16;
        MIN_LAG : integer := 80;
        INCLUDE_PROTOCOL_CHECKER : boolean := TRUE;
        RANDSEED : natural := 12345;
        LATENCY_LOW_PROBABILITY : natural := 95;   -- probability, as a percentage, that non-zero gaps between read beats will be small (i.e. < 3 clocks)
        LATENCY_ZERO_PROBABILITY : natural := 80   -- probability, as a percentage, that the gap between read beats will be zero.
    );
    Port (
        i_clk : in std_logic;
        i_rst_n : in std_logic;
        --
        axi_awvalid : in std_logic;
        axi_awready : out std_logic;
        axi_awaddr  : in std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
        axi_awid    : in std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        axi_awlen   : in std_logic_vector(7 downto 0);
        axi_awsize  : in std_logic_vector(2 downto 0);
        axi_awburst : in std_logic_vector(1 downto 0);
        axi_awlock  : in std_logic_vector(1 downto 0);
        axi_awcache : in std_logic_vector(3 downto 0);
        axi_awprot  : in std_logic_vector(2 downto 0);
        axi_awqos   : in std_logic_vector(3 downto 0);
        axi_awregion : in std_logic_vector(3 downto 0);
        axi_wvalid   : in std_logic;
        axi_wready   : out std_logic;
        axi_wdata    : in std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
        axi_wstrb    : in std_logic_vector(AXI_DATA_WIDTH/8-1 downto 0);   -- !! ignored 
        axi_wlast    : in std_logic;
        axi_bvalid   : out std_logic;
        axi_bready   : in std_logic;   -- Ignored in this testbench model.
        axi_bresp    : out std_logic_vector(1 downto 0);
        axi_bid      : out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        axi_arvalid  : in std_logic;
        axi_arready  : out std_logic;
        axi_araddr   : in std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
        axi_arid     : in std_logic_vector(AXI_ID_WIDTH-1 downto 0);
        axi_arlen    : in std_logic_vector(7 downto 0);
        axi_arsize   : in std_logic_vector(2 downto 0);
        axi_arburst  : in std_logic_vector(1 downto 0);
        axi_arlock   : in std_logic_vector(1 downto 0);
        axi_arcache  : in std_logic_vector(3 downto 0);
        axi_arprot   : in std_logic_Vector(2 downto 0);
        axi_arqos    : in std_logic_vector(3 downto 0);
        axi_arregion : in std_logic_vector(3 downto 0);
        axi_rvalid   : out std_logic;
        axi_rready   : in std_logic;
        axi_rdata    : out std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
        axi_rlast    : out std_logic;
        axi_rid      : out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        axi_rresp    : out std_logic_vector(1 downto 0);
        -- protocol checker outputs
        pc_status   : out std_logic_vector(159 downto 0);
        pc_asserted : out std_logic;
        -- control dump to disk.
        i_write_to_disk : in std_logic;
        i_write_to_disk_addr : in integer; -- address to start the memory dump at.
        i_write_to_disk_size : in integer; -- size in bytes
        i_fname : in string;
        -- Initialisation of the memory
        -- The memory is loaded with the contents of the file i_init_fname in 
        -- any clock cycle where i_init_mem is high.
        i_init_mem   : in std_logic;
        i_init_fname : in string
    );
end HBM_axi_tbModel;

architecture Behavioral of HBM_axi_tbModel is

    COMPONENT axi_protocol_checker_256
    PORT (
        pc_status : OUT STD_LOGIC_VECTOR(159 DOWNTO 0);
        pc_asserted : OUT STD_LOGIC;
        aclk : IN STD_LOGIC;
        aresetn : IN STD_LOGIC;
        pc_axi_awaddr : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
        pc_axi_awlen : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        pc_axi_awsize : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        pc_axi_awburst : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        pc_axi_awlock : IN STD_LOGIC_VECTOR(0 DOWNTO 0);
        pc_axi_awcache : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        pc_axi_awprot : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        pc_axi_awqos : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        pc_axi_awregion : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        pc_axi_awvalid : IN STD_LOGIC;
        pc_axi_awready : IN STD_LOGIC;
        pc_axi_wlast : IN STD_LOGIC;
        pc_axi_wdata : IN STD_LOGIC_VECTOR(255 DOWNTO 0);
        pc_axi_wstrb : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
        pc_axi_wvalid : IN STD_LOGIC;
        pc_axi_wready : IN STD_LOGIC;
        pc_axi_bresp : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        pc_axi_bvalid : IN STD_LOGIC;
        pc_axi_bready : IN STD_LOGIC;
        pc_axi_araddr : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
        pc_axi_arlen : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        pc_axi_arsize : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        pc_axi_arburst : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        pc_axi_arlock : IN STD_LOGIC_VECTOR(0 DOWNTO 0);
        pc_axi_arcache : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        pc_axi_arprot : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        pc_axi_arqos : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        pc_axi_arregion : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        pc_axi_arvalid : IN STD_LOGIC;
        pc_axi_arready : IN STD_LOGIC;
        pc_axi_rlast : IN STD_LOGIC;
        pc_axi_rdata : IN STD_LOGIC_VECTOR(255 DOWNTO 0);
        pc_axi_rresp : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        pc_axi_rvalid : IN STD_LOGIC;
        pc_axi_rready : IN STD_LOGIC);
    END COMPONENT;

    COMPONENT axi_protocol_checker_512
    PORT (
        pc_status : OUT STD_LOGIC_VECTOR(159 DOWNTO 0);
        pc_asserted : OUT STD_LOGIC;
        aclk : IN STD_LOGIC;
        aresetn : IN STD_LOGIC;
        pc_axi_awaddr : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
        pc_axi_awlen : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        pc_axi_awsize : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        pc_axi_awburst : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        pc_axi_awlock : IN STD_LOGIC_VECTOR(0 DOWNTO 0);
        pc_axi_awcache : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        pc_axi_awprot : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        pc_axi_awqos : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        pc_axi_awregion : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        pc_axi_awvalid : IN STD_LOGIC;
        pc_axi_awready : IN STD_LOGIC;
        pc_axi_wlast : IN STD_LOGIC;
        pc_axi_wdata : IN STD_LOGIC_VECTOR(511 DOWNTO 0);
        pc_axi_wstrb : IN STD_LOGIC_VECTOR(63 DOWNTO 0);
        pc_axi_wvalid : IN STD_LOGIC;
        pc_axi_wready : IN STD_LOGIC;
        pc_axi_bresp : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        pc_axi_bvalid : IN STD_LOGIC;
        pc_axi_bready : IN STD_LOGIC;
        pc_axi_araddr : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
        pc_axi_arlen : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        pc_axi_arsize : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        pc_axi_arburst : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        pc_axi_arlock : IN STD_LOGIC_VECTOR(0 DOWNTO 0);
        pc_axi_arcache : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        pc_axi_arprot : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        pc_axi_arqos : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        pc_axi_arregion : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        pc_axi_arvalid : IN STD_LOGIC;
        pc_axi_arready : IN STD_LOGIC;
        pc_axi_rlast : IN STD_LOGIC;
        pc_axi_rdata : IN STD_LOGIC_VECTOR(511 DOWNTO 0);
        pc_axi_rresp : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        pc_axi_rvalid : IN STD_LOGIC;
        pc_axi_rready : IN STD_LOGIC);
    END COMPONENT;

    signal axi_awaddr_ext, axi_araddr_ext : std_logic_vector(39 downto 0);

    signal pseudoRand1, pseudoRand2 : natural;
    signal stallCount : natural;
    type readStall_type is (running, stall);
    signal readStall_fsm : readStall_type := running; 

    signal nowCount : integer := 0;
    signal now32bit : std_logic_vector(31 downto 0);
    signal axi_araddr_20bit : std_logic_vector(19 downto 0);
    signal axi_awaddr_20bit : std_logic_vector(19 downto 0);
    signal axi_arFIFO_din : std_logic_vector((40 + AXI_ADDR_WIDTH-1) downto 0);
    signal axi_arFIFO_wren : std_logic;
    signal axi_arFIFO_WrDataCount : std_logic_vector(5 downto 0);
    signal axi_arFIFO_dout : std_logic_vector((40 + AXI_ADDR_WIDTH-1) downto 0);
    signal axi_arFIFO_empty : std_logic;
    signal axi_arFIFO_rdEn : std_logic;

    signal axi_araddr_delayed : std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
    signal axi_arlen_delayed : std_logic_vector(7 downto 0);
    signal axi_reqTime : std_logic_vector(31 downto 0);
    
    signal axi_arvalid_delayed, axi_arready_delayed : std_logic;
    
    signal rcount : std_logic_vector(31 downto 0) := x"00000000";

    type w_fsm_type is (idle, wr_data, wr_wait);
    signal w_fsm : w_fsm_type := idle;
    signal aw_addr : std_logic_vector(AXI_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal aw_len : integer := 0;
    signal aw_size : std_logic_vector(2 downto 0) := "000";
    signal w_data : std_logic_vector(AXI_DATA_WIDTH-1 downto 0) := (others => '0');
    signal w_last : std_logic;
    signal w_data_used : std_logic := '0';

    type r_fsm_type is (idle, rd_data);
    signal r_fsm : r_fsm_type := idle;
    signal ar_addr : std_logic_vector(AXI_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal ar_len : integer := 0;    
    
    -- The memory
    constant BLOCK_WIDTH : integer := 12;
    constant DATAWIDTHLOG2 : integer := integer(ceil(log2(real(AXI_DATA_WIDTH)))) - 3; -- = log2(width in bytes), e.g. 5 for 256 bit interface.
    
    type MemoryPType is protected
        procedure MemWrite ( 
            Addr : in std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
            Data : in std_logic_vector(AXI_DATA_WIDTH-1 downto 0));
        
        procedure MemRead (
            Addr  : in  std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
            Data  : out std_logic_vector(AXI_DATA_WIDTH-1 downto 0));
        
        procedure MemDump (
            Addr  : in integer;
            dumpSize : in integer;
            fname : in string);
        
        procedure MemInit (fname : in string);
        
        impure function MemRead(Addr : std_logic_vector) return std_logic_vector;
        

    end protected MemoryPType;
    
    type MemoryPType is protected body
        type MemBlockType    is array (0 to 1023) of integer;  -- Each memory block allocated is 1024 integers, to store 4096 bytes.
        type MemBlockPtrType is access MemBlockType;
        type MemArrayType    is array (0 to (2**(AXI_ADDR_WIDTH-BLOCK_WIDTH) - 1)) of MemBlockPtrType ;
        
        variable memArray : MemArrayType := (others => NULL);
        
        procedure MemWrite(Addr : in std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
                           Data : in std_logic_vector(AXI_DATA_WIDTH-1 downto 0)) is
            variable BlockAddr, WordAddr  : integer;
        begin
            
            if is_X(Addr) then
                report "MemoryPType.MemWrite:  Address X, Write Ignored.";
                return;
            end if; 
            
            -- Slice out upper address to form block address
            BlockAddr := to_integer(unsigned(Addr((AXI_ADDR_WIDTH-1) downto BLOCK_WIDTH)));
            
            -- If empty, allocate a memory block
            -- Byte addresses are used, but each memory element is an integer (=4bytes), 
            -- so subtract 2 from BLOCK_WIDTH to get the number of integers needed for the block.
            if (memArray(BlockAddr) = NULL) then 
                memArray(BlockAddr) := new MemBlockType;
                --report "memwrite : allocated block " & integer'image(BlockAddr);
            end if;
            
            -- Address of a word within a block. 
            -- "Addr" is a byte address, but wordAddr indexes 4-byte words, so drop the low 2 bits.
            WordAddr := to_integer(unsigned(Addr(BLOCK_WIDTH -1 downto 2)));
            
            -- Write to BlockAddr, WordAddr
            for n in 0 to (2**(DATAWIDTHLOG2-2) - 1) loop
                if (Is_X(Data)) then 
                    memArray(BlockAddr)(WordAddr+n) := -1163010387; --  3131956909;   -- this is "baaddead" in hex.
                else
                    memArray(BlockAddr)(WordAddr+n) := to_integer(signed(Data((32*n + 31) downto 32*n))) ;
                end if;
            end loop;
        end procedure MemWrite;
        
        procedure MemRead (Addr : in  std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
                           Data : out std_logic_vector(AXI_DATA_WIDTH-1 downto 0)) is
            variable BlockAddr, WordAddr  : integer;
        begin
          
            -- If Addr X, data = X. This will trigger a warning from the AXI protocol block.
            if is_X(Addr) then
                Data := (Data'range => 'X'); 
                return; 
            end if;
          
            -- Slice out upper address to form block address
            BlockAddr := to_integer(unsigned(Addr((AXI_ADDR_WIDTH-1) downto BLOCK_WIDTH)));

            
            -- Empty Block, return all U
            if (memArray(BlockAddr) = NULL) then 
                for n in 0 to (2**(DATAWIDTHLOG2-2) - 1) loop
                    Data((32*n + 31) downto 32*n) := std_logic_vector(to_signed(-1163010387,32));
                end loop;
                --Data := (Data'range => 'U');
                report "memread : read from unallocated block " & integer'image(BlockAddr); 
                return;
            end if;
            
            -- Address of a word within a block (See comments for analogous line in the MemWrite function) 
            WordAddr := to_integer(unsigned(Addr(BLOCK_WIDTH-1 downto 2)));
            
            -- Get the Word from the Array
            for n in 0 to (2**(DATAWIDTHLOG2-2) - 1) loop
                Data((32*n + 31) downto 32*n) := std_logic_vector(to_signed(memArray(BlockAddr)(WordAddr+n), 32));
            end loop;
            
        end procedure MemRead;
        
        procedure MemDump (Addr : in integer;  -- byte address
                           dumpSize : in integer; -- number of bytes to write out
                           fname : in string) is   -- filename to write to.
            file logfile: TEXT;
            variable line_out : Line;
            variable fullAddr : std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
            variable BlockAddr, WordAddr  : integer;
            variable thisData : std_logic_vector(31 downto 0);
        begin
            FILE_OPEN(logfile,fname,WRITE_MODE);
            --baseAddr := to_integer(unsigned(Addr));
            for n in 0 to ((dumpSize/4)-1) loop
                fullAddr := std_logic_vector(to_unsigned(Addr,AXI_ADDR_WIDTH) + 4*n);
                -- Slice out upper address to form block address
                BlockAddr :=  to_integer(unsigned(fullAddr((AXI_ADDR_WIDTH-1) downto BLOCK_WIDTH)));
                WordAddr := to_integer(unsigned(fullAddr(BLOCK_WIDTH-1 downto 2)));
                if (memArray(BlockAddr) = NULL) then
                    thisData := x"feedcafe";
                else
                    thisData := std_logic_vector(to_signed(memArray(BlockAddr)(WordAddr),32));
                end if;
                hwrite(line_out,thisData,RIGHT,8);
                writeline(logfile,line_out);
            end loop;
            
            file_close(logfile);
        end procedure MemDump;
        
        -- Initialise the memory with data from a file.
        -- File format is hexadecimal text, with each line consisting of 1025 hex values, with each value being a 32-bit integer in hex format, no prefix (e.g. CAFE8888, not 0xCAFE8888)
        -- First value in each line is the address to write the data to, in units of 4 bytes, the remaining values are up to 4 kbytes of data.
        procedure MemInit (fname : in string) is
            file dinFile : TEXT;
            variable line_in : Line;
            variable good : boolean;
            variable memAddr : std_logic_vector(31 downto 0);
            variable memData : std_logic_vector(31 downto 0);
            variable memAddrInt4096 : integer;
            variable wordCount : integer;
            variable lineBase : integer;
        begin
            FILE_OPEN(dinFile,fname,READ_MODE);
            while (not endfile(dinfile)) loop 
                readline(dinfile, line_in);
                
                hread(line_in,memAddr,good);
                
                -- Where we start within a 4 kByte block.
                lineBase := to_integer(unsigned(memAddr(9 downto 0)));
                -- Which 4 kByte block.
                memAddrInt4096 := to_integer(unsigned(memAddr(31 downto 10)));
                
                if (memArray(memAddrInt4096) = NULL) then 
                    memArray(memAddrInt4096) := new MemBlockType;
                end if;
                
                good := True;
                wordCount := 0;
                while good loop
                    hread(line_in,memData,good);
                    if (good) then
                        assert ((lineBase+wordCount) < 4096) report "Single line in the initialisation file cannot cross a 4096 byte boundary" severity failure;
                        memArray(memAddrInt4096)(lineBase + wordCount) := to_integer(signed(memData));
                        wordCount := wordCount + 1;
                    end if;
                end loop;
                
            end loop;
        end procedure MemInit;
        
        
        ------------------------------------------------------------
        impure function MemRead(Addr  : std_logic_vector) return std_logic_vector is
            --variable BlockAddr, WordAddr  : integer;
            variable Data : std_logic_vector(AXI_DATA_WIDTH-1 downto 0); 
        begin
            MemRead(Addr, Data) ; 
            return Data ; 
        end function MemRead ; 

    end protected body MemoryPType ;
    
    shared variable hbm_memory : MemoryPType;

begin
        
    -- FIFO for AR commands, to emulate the large latency of the HBM.
    -- Data stored in the fifo is the ar bus:
    --   m02_araddr - 20 bits
    --   m02_arlen  - 8 bits
    --   
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            nowCount <= nowCount + 1;  -- used to ensure a minimum delay between ar requests and data being returned.
        end if;
    end process;
    
    now32bit <= std_logic_vector(to_unsigned(nowCount,32));
    
    axi_arFIFO_din(31 downto 0) <= now32bit;
    axi_arFIFO_din(39 downto 32) <= axi_arlen;
    axi_arFIFO_din((40 + AXI_ADDR_WIDTH-1) downto 40) <= axi_araddr;
    axi_arFIFO_wren <= axi_arvalid and axi_arready;
    axi_arready <= '1' when (unsigned(axi_arFIFO_wrDataCount) < READ_QUEUE_SIZE) else '0';
    
    fifo_m02_ar_inst : xpm_fifo_sync
    generic map (
        DOUT_RESET_VALUE => "0",    -- String
        ECC_MODE => "no_ecc",       -- String
        FIFO_MEMORY_TYPE => "distributed", -- String
        FIFO_READ_LATENCY => 1,     -- DECIMAL
        FIFO_WRITE_DEPTH => 32,     -- DECIMAL; Allow up to 32 outstanding read requests.
        FULL_RESET_VALUE => 0,      -- DECIMAL
        PROG_EMPTY_THRESH => 10,    -- DECIMAL
        PROG_FULL_THRESH => 10,     -- DECIMAL
        RD_DATA_COUNT_WIDTH => 6,   -- DECIMAL
        READ_DATA_WIDTH => 40+AXI_ADDR_WIDTH,      -- DECIMAL
        READ_MODE => "fwft",        -- String
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "0404", -- String  -- bit 2 and bit 10 enables write data count and read data count
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 40+AXI_ADDR_WIDTH, -- DECIMAL
        WR_DATA_COUNT_WIDTH => 6    -- DECIMAL
    )
    port map (
        almost_empty => open,      -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
        almost_full => open,       -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
        data_valid => open,        -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
        dbiterr => open,           -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
        dout => axi_arFIFO_dout,   -- READ_DATA_WIDTH-bit output: Read Data: The output data bus is driven when reading the FIFO.
        empty => axi_arFIFO_empty, -- 1-bit output: Empty Flag: When asserted, this signal indicates that- the FIFO is empty.
        full => open,              -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full.
        overflow => open,          -- 1-bit output: Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected, because the FIFO is full
        prog_empty => open,        -- 1-bit output: Programmable Empty: This signal is asserted when the number of words in the FIFO is less than or equal to the programmable empty threshold value.
        prog_full => open,         -- 1-bit output: Programmable Full: This signal is asserted when the number of words in the FIFO is greater than or equal to the programmable full threshold value.
        rd_data_count => open,     -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
        rd_rst_busy => open,       -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
        sbiterr => open,           -- 1-bit output: Single Bit Error: Indicates that the ECC decoder detected and fixed a single-bit error.
        underflow => open,         -- 1-bit output: Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected because the FIFO is empty.
        wr_ack => open,            -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.
        wr_data_count => axi_arFIFO_WrDataCount, -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        wr_rst_busy => open,       -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
        din => axi_arFIFO_din,     -- WRITE_DATA_WIDTH-bit input: Write Data: The input data bus used when writing the FIFO.
        injectdbiterr => '0',      -- 1-bit input: Double Bit Error Injection
        injectsbiterr => '0',      -- 1-bit input: Single Bit Error Injection: 
        rd_en => axi_arFIFO_rdEn,  -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO. 
        rst => '0',                -- 1-bit input: Reset: Must be synchronous to wr_clk.
        sleep => '0',              -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
        wr_clk => i_clk,          -- 1-bit input: Write clock: Used for write operation. wr_clk must be a free running clock.
        wr_en => axi_arFIFO_wrEn   -- 1-bit input: Write Enable: 
    );
    
    axi_araddr_delayed <= axi_arFIFO_dout((40 + AXI_ADDR_WIDTH-1) downto 40);
    axi_arlen_delayed <= axi_arFIFO_dout(39 downto 32);
    axi_reqTime <= axi_arFIFO_dout(31 downto 0);
    
    axi_arvalid_delayed <= '1' when axi_arFIFO_empty = '0' and ((unsigned(axi_reqTime) + MIN_LAG) < nowCount) else '0';
    axi_arFIFO_rden <= axi_arvalid_delayed and axi_arready_delayed;
    
    -- replace rdata with a read count for debugging
--    axi_rdata <= rcount & rcount & rcount & rcount & rcount & rcount & rcount & rcount;

--    process(i_clk)
--    begin
--        if rising_Edge(i_clk) then
--            if axi_rvalid = '1' and axi_rready = '1' then
--                rcount <= std_logic_vector(unsigned(rcount) + 1);
--            end if;
--        end if;
--    end process;
    

    
    -----------------------------------------------------------------------------------
    -- Convert the AXI bus into memory transactions
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rst_n = '0' then
                w_fsm <= idle;
                r_fsm <= idle;
                axi_rlast <= '0';
                axi_rvalid <= '0';
            else
                case w_fsm is
                    when idle =>
                        if axi_awvalid = '1' then
                            aw_addr <= axi_awaddr;
                            aw_size <= axi_awsize;
                            aw_len <= TO_INTEGER(unsigned(axi_awlen(7 downto 0)));
                            if axi_wvalid = '1' or w_data_used = '1' then
                                w_fsm <= wr_data;
                            else
                                w_fsm <= wr_wait;
                            end if;
                        end if;
                        if axi_wvalid = '1' and w_data_used = '0' then
                            w_data <= axi_wdata;
                            w_last <= axi_wlast;
                            w_data_used <= '1';
                        end if;
                    
                    when wr_data =>  -- write data to the memory
                        hbm_memory.memWrite(aw_addr,w_data);
                        aw_addr <= std_logic_vector(unsigned(aw_addr) + (AXI_DATA_WIDTH/8));
                        if (aw_len /= 0) then
                            aw_len <= aw_len - 1;
                            if axi_wvalid = '1' then
                                w_fsm <= wr_data;
                            else
                                w_fsm <= wr_wait;
                            end if;
                        else
                            w_fsm <= idle;
                        end if;
                        if axi_wvalid = '1' then
                            w_data <= axi_wdata;
                            w_data_used <= '1';
                            w_last <= axi_wlast;
                        else
                            w_data_used <= '0';  -- Since we just wrote it to the memory.
                        end if;
                        assert (aw_len = 0 and w_last = '1') or (aw_len /= 0 and w_last = '0') report "Bad value for axi_wlast" severity failure;
                        assert (2**to_integer(unsigned(aw_size)) = (AXI_DATA_WIDTH/8)) report "Bad value for axi_awsize" severity failure;
                    
                    when wr_wait =>  -- we have the address, but we are still waiting for valid data to write
                        if axi_wvalid = '1' then
                            w_data <= axi_wdata;
                            w_last <= axi_wlast;
                            w_data_used <= '1';
                            w_fsm <= wr_data;
                        end if;
                    
                    when others =>
                        w_fsm <= idle;
                
                end case;
                
                case r_fsm is
                    when idle =>
                        if axi_arvalid_delayed = '1' and axi_arready_delayed = '1' then
                            ar_addr <= axi_araddr_delayed;
                            ar_len <= TO_INTEGER(unsigned(axi_arlen_delayed(7 downto 0)));
                            r_fsm <= rd_data;
                        end if;
                        if axi_rready = '1' then
                            axi_rlast <= '0';
                            axi_rvalid <= '0';
                        end if;
                    
                    when rd_data =>
                        if ((axi_rvalid = '0' or axi_rready = '1') and readStall_fsm = running) then
                            axi_rdata <= hbm_memory.memRead(ar_addr);
                            ar_addr <= std_logic_vector(unsigned(ar_addr) + (AXI_DATA_WIDTH/8));
                            axi_rvalid <= '1';
                            
                            if (ar_len = 0) then
                                if axi_arvalid_delayed = '1' and axi_arready_delayed = '1' then
                                    ar_addr <= axi_araddr_delayed;
                                    ar_len <= TO_INTEGER(unsigned(axi_arlen_delayed(7 downto 0)));
                                    r_fsm <= rd_data;
                                else
                                    r_fsm <= idle;
                                end if;
                                axi_rlast <= '1';
                            else
                                ar_len <= ar_len - 1;
                                axi_rlast <= '0';
                            end if;
                        elsif (axi_rvalid = '1' and axi_rready = '1') then -- must be that (readStall_fsm = stall) 
                            axi_rvalid <= '0';
                        end if;
                    
                    when others =>
                        r_fsm <= idle;
                        axi_rlast <= '0';
                        axi_rvalid <= '0';
                    
                end case;
                
            end if;
            
            -- Generate pseudo-random latencies for the read data.
            if i_rst_n = '0' then
                pseudoRand1 <= RANDSEED;
                pseudoRand2 <= RANDSEED;
                readStall_fsm <= running;
            else
                pseudoRand1 <= pseudoRand1 + 131;
                pseudoRand2 <= pseudoRand2 + 173;
                case readStall_fsm is
                    when running =>
                        if ((pseudoRand1 mod 101) < LATENCY_ZERO_PROBABILITY) then
                            readStall_fsm <= running; 
                        else
                            readStall_fsm <= stall;
                            if ((pseudoRand2 mod 101) < LATENCY_LOW_PROBABILITY) then
                                stallCount <= (pseudoRand2 mod 3);
                            else
                                stallCount <= (pseudoRand2 mod 41);
                            end if; 
                        end if;
                    
                    when stall =>
                        if (stallCount > 0) then
                            stallCount <= stallCount - 1;
                        else
                            readStall_fsm <= running;
                        end if;
                    
                end case;
            
            end if;
            
            -----------------------------------------------------------------------------
            -- dump memory contents to disk
            if i_write_to_disk = '1' then
                hbm_memory.memDump(i_write_to_disk_addr, i_write_to_disk_size, i_fname);
            end if; 
            
            if i_init_mem = '1' then
                hbm_memory.MemInit(i_init_fname);
            end if;
            
        end if;
    end process; 
    
    axi_awready <= '1' when w_fsm = idle else '0';
    axi_wready <= '1' when (w_data_used = '0' or w_fsm = wr_data) else '0';
    
    axi_arready_delayed <= '1' when (r_fsm = idle or (r_fsm = rd_data and ar_len = 0 and (axi_rvalid = '0' or axi_rready = '1') and readStall_fsm = running)) else '0';
    
    axi_bvalid <= '1' when (w_fsm = wr_data and aw_len = 0) else '0';
    axi_bresp <= "00";
    axi_rresp <= "00";
    axi_rid <= (others => '0');
    
    ---------------------------------------------------------------------------------------------------
    --
    axi_awaddr_ext(39 downto AXI_ADDR_WIDTH) <= (others => '0');
    axi_awaddr_ext((AXI_ADDR_WIDTH-1) downto 0) <= axi_awaddr;
    
    axi_araddr_ext(39 downto AXI_ADDR_WIDTH) <= (others => '0');
    axi_araddr_ext((AXI_ADDR_WIDTH-1) downto 0) <= axi_araddr;
        
    pcgen : if (INCLUDE_PROTOCOL_CHECKER and (AXI_DATA_WIDTH = 256)) generate
    
        pccheck : axi_protocol_checker_256
        PORT MAP (
            pc_status   => pc_status,  -- 160 bits, each for a different warning or error
            pc_asserted => pc_asserted, -- logical or of pc_status
            aclk        => i_clk,
            aresetn     => i_rst_n,
            
            pc_axi_awaddr   => axi_awaddr_ext(31 downto 0),
            pc_axi_awlen    => axi_awlen,
            pc_axi_awsize   => axi_awsize,
            pc_axi_awburst  => axi_awburst,
            pc_axi_awlock   => axi_awlock(0 downto 0),
            pc_axi_awcache  => axi_awcache,
            pc_axi_awprot   => axi_awprot,
            pc_axi_awqos    => axi_awqos,
            pc_axi_awregion => axi_awregion,
            pc_axi_awvalid  => axi_awvalid,
            pc_axi_awready  => axi_awready,
            
            pc_axi_wlast  => axi_wlast,
            pc_axi_wdata  => axi_wdata,
            pc_axi_wstrb  => axi_wstrb,
            pc_axi_wvalid => axi_wvalid,
            pc_axi_wready => axi_wready,
            
            pc_axi_bresp  => axi_bresp,
            pc_axi_bvalid => axi_bvalid,
            pc_axi_bready => axi_bready,
            
            pc_axi_araddr   => axi_araddr_ext(31 downto 0),
            pc_axi_arlen    => axi_arlen,
            pc_axi_arsize   => axi_arsize,
            pc_axi_arburst  => axi_arburst,
            pc_axi_arlock   => axi_arlock(0 downto 0),
            pc_axi_arcache  => axi_arcache,
            pc_axi_arprot   => axi_arprot,
            pc_axi_arqos    => axi_arqos,
            pc_axi_arregion => axi_arregion,
            pc_axi_arvalid  => axi_arvalid,
            pc_axi_arready  => axi_arready,
            
            pc_axi_rlast  => axi_rlast,
            pc_axi_rdata  => axi_rdata,
            pc_axi_rresp  => axi_rresp,
            pc_axi_rvalid => axi_rvalid,
            pc_axi_rready => axi_rready
        );
    end generate;

    pcgen512 : if (INCLUDE_PROTOCOL_CHECKER and (AXI_DATA_WIDTH = 512)) generate
    
        pccheck : axi_protocol_checker_512
        PORT MAP (
            pc_status   => pc_status,  -- 160 bits, each for a different warning or error
            pc_asserted => pc_asserted, -- logical or of pc_status
            aclk        => i_clk,
            aresetn     => i_rst_n,
            
            pc_axi_awaddr   => axi_awaddr_ext(31 downto 0),
            pc_axi_awlen    => axi_awlen,
            pc_axi_awsize   => axi_awsize,
            pc_axi_awburst  => axi_awburst,
            pc_axi_awlock   => axi_awlock(0 downto 0),
            pc_axi_awcache  => axi_awcache,
            pc_axi_awprot   => axi_awprot,
            pc_axi_awqos    => axi_awqos,
            pc_axi_awregion => axi_awregion,
            pc_axi_awvalid  => axi_awvalid,
            pc_axi_awready  => axi_awready,
            
            pc_axi_wlast  => axi_wlast,
            pc_axi_wdata  => axi_wdata,
            pc_axi_wstrb  => axi_wstrb,
            pc_axi_wvalid => axi_wvalid,
            pc_axi_wready => axi_wready,
            
            pc_axi_bresp  => axi_bresp,
            pc_axi_bvalid => axi_bvalid,
            pc_axi_bready => axi_bready,
            
            pc_axi_araddr   => axi_araddr_ext(31 downto 0),
            pc_axi_arlen    => axi_arlen,
            pc_axi_arsize   => axi_arsize,
            pc_axi_arburst  => axi_arburst,
            pc_axi_arlock   => axi_arlock(0 downto 0),
            pc_axi_arcache  => axi_arcache,
            pc_axi_arprot   => axi_arprot,
            pc_axi_arqos    => axi_arqos,
            pc_axi_arregion => axi_arregion,
            pc_axi_arvalid  => axi_arvalid,
            pc_axi_arready  => axi_arready,
            
            pc_axi_rlast  => axi_rlast,
            pc_axi_rdata  => axi_rdata,
            pc_axi_rresp  => axi_rresp,
            pc_axi_rvalid => axi_rvalid,
            pc_axi_rready => axi_rready
        );
    end generate;
   
    pcnogen : if (not INCLUDE_PROTOCOL_CHECKER) generate
        pc_status <= (others => '0');
        pc_asserted <= '0';
    end generate;
    
end Behavioral;
