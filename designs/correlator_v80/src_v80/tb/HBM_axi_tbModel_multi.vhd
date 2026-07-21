----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
--
-- Module Name: HBM_axi_tbModel_multi - Behavioral
-- Description:
--  Multi-interface variant of HBM_axi_tbModel_rec.
--  g_NUM_INTERFACES AXI interfaces (each with AW/W/B/AR/R channels) all share
--  one memory array, modelling a single HBM pseudo-channel that is reachable
--  from multiple master paths.
--
--  Typical PST CT1 usage (g_NUM_INTERFACES=3):
--    Interface 0 : write-only  o_wr0_axi_aw / m01_axi_w  (bit30=0 addresses)
--    Interface 1 : write-only  o_wr1_axi_aw / m02_axi_w  (bit30=1 addresses)
--    Interface 2 : read-only   o_m01_axi_ar / i_m01_axi_r
--
--  Unused AW/W/AR channels should be driven with .valid='0'.
--  Unused AR channels will never see activity, so arready / r outputs for those
--  interfaces can be left unconnected (open).
--
--  The protocol checker is not included in this version; use HBM_axi_tbModel_rec
--  for single-interface protocol checking.
----------------------------------------------------------------------------------

library IEEE, axi4_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.math_real.all;
library xpm;
use xpm.vcomponents.all;
use std.textio.all;
use IEEE.std_logic_textio.all;
use axi4_lib.axi4_full_pkg.all;

entity HBM_axi_tbModel_multi is
    generic (
        g_NUM_INTERFACES         : integer := 3;
        AXI_DATA_WIDTH           : integer := 512;
        AXI_ADDR_WIDTH           : integer := 32;
        READ_QUEUE_SIZE          : integer := 16;
        MIN_LAG                  : integer := 80;
        RANDSEED                 : natural := 12345;
        LATENCY_LOW_PROBABILITY  : natural := 95;
        LATENCY_ZERO_PROBABILITY : natural := 80
    );
    port (
        i_clk   : in  std_logic;
        i_rst_n : in  std_logic;
        -- Write address channels
        i_axi_aw      : in  t_axi4_full_addr_arr(g_NUM_INTERFACES-1 downto 0);
        o_axi_awready : out std_logic_vector(g_NUM_INTERFACES-1 downto 0);
        -- Write data channels
        i_axi_w       : in  t_axi4_full_data_arr(g_NUM_INTERFACES-1 downto 0);
        o_axi_wready  : out std_logic_vector(g_NUM_INTERFACES-1 downto 0);
        -- Write response channels
        o_axi_b       : out t_axi4_full_b_arr(g_NUM_INTERFACES-1 downto 0);
        -- Read address channels
        i_axi_ar      : in  t_axi4_full_addr_arr(g_NUM_INTERFACES-1 downto 0);
        o_axi_arready : out std_logic_vector(g_NUM_INTERFACES-1 downto 0);
        -- Read data channels
        o_axi_r       : out t_axi4_full_data_arr(g_NUM_INTERFACES-1 downto 0);
        i_axi_rready  : in  std_logic_vector(g_NUM_INTERFACES-1 downto 0);
        -- Shared memory dump (one port covers the whole shared memory)
        i_write_to_disk      : in  std_logic;
        i_fname              : in  string;
        -- Memory initialisation
        i_init_mem   : in  std_logic;
        i_init_fname : in  string
    );
end HBM_axi_tbModel_multi;

architecture Behavioral of HBM_axi_tbModel_multi is

    constant BLOCK_WIDTH    : integer := 12;
    constant DATAWIDTHLOG2  : integer := integer(ceil(log2(real(AXI_DATA_WIDTH)))) - 3;
    constant FIFO_WIDTH     : integer := 40 + AXI_ADDR_WIDTH;

    ---------------------------------------------------------------------------
    -- Shared memory (protected type; serialises concurrent accesses)
    ---------------------------------------------------------------------------
    type MemoryPType is protected
        procedure MemWrite(Addr : in  std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
                           Data : in  std_logic_vector(AXI_DATA_WIDTH-1 downto 0));
        procedure MemRead (Addr : in  std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
                           Data : out std_logic_vector(AXI_DATA_WIDTH-1 downto 0));
        procedure MemDump (fname : in string);
        procedure MemInit (fname : in string);
        impure function MemRead(Addr : std_logic_vector) return std_logic_vector;
    end protected MemoryPType;

    type MemoryPType is protected body
        type MemBlockType    is array (0 to 1023) of integer;
        type MemBlockPtrType is access MemBlockType;
        type MemArrayType    is array (0 to (2**(AXI_ADDR_WIDTH-BLOCK_WIDTH) - 1)) of MemBlockPtrType;
        variable memArray : MemArrayType := (others => NULL);

        procedure MemWrite(Addr : in std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
                           Data : in std_logic_vector(AXI_DATA_WIDTH-1 downto 0)) is
            variable BlockAddr, WordAddr : integer;
        begin
            if is_X(Addr) then
                report "HBM_axi_tbModel_multi.MemWrite: Address X, Write Ignored.";
                return;
            end if;
            BlockAddr := to_integer(unsigned(Addr(AXI_ADDR_WIDTH-1 downto BLOCK_WIDTH)));
            if memArray(BlockAddr) = NULL then
                memArray(BlockAddr) := new MemBlockType;
            end if;
            WordAddr := to_integer(unsigned(Addr(BLOCK_WIDTH-1 downto 2)));
            for n in 0 to (2**(DATAWIDTHLOG2-2) - 1) loop
                if Is_X(Data) then
                    memArray(BlockAddr)(WordAddr+n) := -1163010387;
                else
                    memArray(BlockAddr)(WordAddr+n) := to_integer(signed(Data(32*n+31 downto 32*n)));
                end if;
            end loop;
        end procedure MemWrite;

        procedure MemRead(Addr : in  std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
                          Data : out std_logic_vector(AXI_DATA_WIDTH-1 downto 0)) is
            variable BlockAddr, WordAddr : integer;
        begin
            if is_X(Addr) then
                Data := (Data'range => 'X');
                return;
            end if;
            BlockAddr := to_integer(unsigned(Addr(AXI_ADDR_WIDTH-1 downto BLOCK_WIDTH)));
            if memArray(BlockAddr) = NULL then
                for n in 0 to (2**(DATAWIDTHLOG2-2) - 1) loop
                    Data(32*n+31 downto 32*n) := std_logic_vector(to_signed(-1163010387, 32));
                end loop;
                report "HBM_axi_tbModel_multi.MemRead: unallocated block " & integer'image(BlockAddr);
                return;
            end if;
            WordAddr := to_integer(unsigned(Addr(BLOCK_WIDTH-1 downto 2)));
            for n in 0 to (2**(DATAWIDTHLOG2-2) - 1) loop
                Data(32*n+31 downto 32*n) := std_logic_vector(to_signed(memArray(BlockAddr)(WordAddr+n), 32));
            end loop;
        end procedure MemRead;

        procedure MemDump(fname : in string) is
            -- Sparse dump: iterate over the block array and emit only allocated blocks.
            -- Each output line contains the byte address followed by the 32-bit word:
            --   <addr-hex> <data-hex>
            -- This avoids producing a huge file when data is spread across a wide
            -- (e.g. 16 GB) address space.
            file logfile : TEXT;
            variable line_out : Line;
            variable byteAddr : std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
            variable thisData : std_logic_vector(31 downto 0);
        begin
            FILE_OPEN(logfile, fname, WRITE_MODE);
            for b in 0 to (2**(AXI_ADDR_WIDTH-BLOCK_WIDTH) - 1) loop
                if memArray(b) /= NULL then
                    for w in 0 to (2**BLOCK_WIDTH/4 - 1) loop
                        -- Build byte address without integer overflow: upper bits = block
                        -- index, lower BLOCK_WIDTH bits = word-within-block × 4 bytes.
                        byteAddr := std_logic_vector(
                            to_unsigned(b, AXI_ADDR_WIDTH-BLOCK_WIDTH) &
                            to_unsigned(w * 4, BLOCK_WIDTH));
                        thisData := std_logic_vector(to_signed(memArray(b)(w), 32));
                        hwrite(line_out, byteAddr);
                        write(line_out, string'(" "));
                        hwrite(line_out, thisData);
                        writeline(logfile, line_out);
                    end loop;
                end if;
            end loop;
            file_close(logfile);
        end procedure MemDump;

        procedure MemInit(fname : in string) is
            file dinFile : TEXT;
            variable line_in : Line;
            variable good : boolean;
            variable memAddr : std_logic_vector(31 downto 0);
            variable memData : std_logic_vector(31 downto 0);
            variable memAddrInt4096 : integer;
            variable wordCount : integer;
            variable lineBase  : integer;
        begin
            FILE_OPEN(dinFile, fname, READ_MODE);
            while not endfile(dinFile) loop
                readline(dinFile, line_in);
                hread(line_in, memAddr, good);
                lineBase       := to_integer(unsigned(memAddr(9 downto 0)));
                memAddrInt4096 := to_integer(unsigned(memAddr(31 downto 10)));
                if memArray(memAddrInt4096) = NULL then
                    memArray(memAddrInt4096) := new MemBlockType;
                end if;
                good      := True;
                wordCount := 0;
                while good loop
                    hread(line_in, memData, good);
                    if good then
                        assert (lineBase + wordCount) < 4096 report "MemInit line crosses 4096-byte boundary" severity failure;
                        memArray(memAddrInt4096)(lineBase + wordCount) := to_integer(signed(memData));
                        wordCount := wordCount + 1;
                    end if;
                end loop;
            end loop;
        end procedure MemInit;

        impure function MemRead(Addr : std_logic_vector) return std_logic_vector is
            variable Data : std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
        begin
            MemRead(Addr, Data);
            return Data;
        end function MemRead;

    end protected body MemoryPType;

    shared variable hbm_memory : MemoryPType;

    ---------------------------------------------------------------------------
    -- Per-interface state (array signals; index = interface number)
    ---------------------------------------------------------------------------
    type w_fsm_type      is (idle, wr_data, wr_wait);
    type w_fsm_arr_t     is array (integer range <>) of w_fsm_type;
    type r_fsm_type      is (idle, rd_data);
    type r_fsm_arr_t     is array (integer range <>) of r_fsm_type;
    type readStall_type  is (running, stall);
    type stall_arr_t     is array (integer range <>) of readStall_type;
    type addr_arr_t      is array (integer range <>) of std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
    type data_arr_t      is array (integer range <>) of std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
    type slv8_arr_t      is array (integer range <>) of std_logic_vector(7 downto 0);
    type slv32_arr_t     is array (integer range <>) of std_logic_vector(31 downto 0);
    type slv6_arr_t      is array (integer range <>) of std_logic_vector(5 downto 0);
    type fifo_arr_t      is array (integer range <>) of std_logic_vector(FIFO_WIDTH-1 downto 0);
    type int_arr_t       is array (integer range <>) of integer;
    type nat_arr_t       is array (integer range <>) of natural;

    signal w_fsm_arr       : w_fsm_arr_t(0 to g_NUM_INTERFACES-1)  := (others => idle);
    signal aw_addr_arr     : addr_arr_t(0 to g_NUM_INTERFACES-1)   := (others => (others => '0'));
    signal aw_len_arr      : int_arr_t(0 to g_NUM_INTERFACES-1)    := (others => 0);
    signal w_data_arr      : data_arr_t(0 to g_NUM_INTERFACES-1)   := (others => (others => '0'));
    signal w_last_arr      : std_logic_vector(g_NUM_INTERFACES-1 downto 0) := (others => '0');
    signal w_data_used_arr : std_logic_vector(g_NUM_INTERFACES-1 downto 0) := (others => '0');

    signal r_fsm_arr       : r_fsm_arr_t(0 to g_NUM_INTERFACES-1)  := (others => idle);
    signal ar_addr_arr     : addr_arr_t(0 to g_NUM_INTERFACES-1)   := (others => (others => '0'));
    signal ar_len_arr      : int_arr_t(0 to g_NUM_INTERFACES-1)    := (others => 0);
    signal axi_rvalid_arr  : std_logic_vector(g_NUM_INTERFACES-1 downto 0) := (others => '0');
    signal axi_rlast_arr   : std_logic_vector(g_NUM_INTERFACES-1 downto 0) := (others => '0');
    signal axi_rdata_arr   : data_arr_t(0 to g_NUM_INTERFACES-1)   := (others => (others => '0'));

    -- AR FIFO signals (one FIFO per interface, instantiated in generate)
    signal axi_arFIFO_din_arr         : fifo_arr_t(0 to g_NUM_INTERFACES-1);
    signal axi_arFIFO_wren_arr        : std_logic_vector(g_NUM_INTERFACES-1 downto 0);
    signal axi_arFIFO_WrDataCount_arr : slv6_arr_t(0 to g_NUM_INTERFACES-1);
    signal axi_arFIFO_dout_arr        : fifo_arr_t(0 to g_NUM_INTERFACES-1);
    signal axi_arFIFO_empty_arr       : std_logic_vector(g_NUM_INTERFACES-1 downto 0);
    signal axi_arFIFO_rdEn_arr        : std_logic_vector(g_NUM_INTERFACES-1 downto 0);

    signal axi_araddr_delayed_arr     : addr_arr_t(0 to g_NUM_INTERFACES-1);
    signal axi_arlen_delayed_arr      : slv8_arr_t(0 to g_NUM_INTERFACES-1);
    signal axi_reqTime_arr            : slv32_arr_t(0 to g_NUM_INTERFACES-1);
    signal axi_arvalid_delayed_arr    : std_logic_vector(g_NUM_INTERFACES-1 downto 0);
    signal axi_arready_delayed_arr    : std_logic_vector(g_NUM_INTERFACES-1 downto 0);

    -- Pseudo-random latency state per interface
    signal pseudoRand1_arr   : nat_arr_t(0 to g_NUM_INTERFACES-1) := (others => RANDSEED);
    signal pseudoRand2_arr   : nat_arr_t(0 to g_NUM_INTERFACES-1) := (others => RANDSEED);
    signal stallCount_arr    : int_arr_t(0 to g_NUM_INTERFACES-1)  := (others => 0);
    signal readStall_arr     : stall_arr_t(0 to g_NUM_INTERFACES-1):= (others => running);

    -- Output enable signals (for port assignment)
    signal axi_awready_arr   : std_logic_vector(g_NUM_INTERFACES-1 downto 0);
    signal axi_wready_arr    : std_logic_vector(g_NUM_INTERFACES-1 downto 0);
    signal axi_arready_arr   : std_logic_vector(g_NUM_INTERFACES-1 downto 0);
    signal axi_bvalid_arr    : std_logic_vector(g_NUM_INTERFACES-1 downto 0);

    signal nowCount : integer := 0;
    signal now32bit : std_logic_vector(31 downto 0);

begin

    ---------------------------------------------------------------------------
    -- Port assignments
    ---------------------------------------------------------------------------
    o_axi_awready <= axi_awready_arr;
    o_axi_wready  <= axi_wready_arr;
    o_axi_arready <= axi_arready_arr;

    gen_port_out : for k in 0 to g_NUM_INTERFACES-1 generate
        o_axi_r(k).valid <= axi_rvalid_arr(k);
        o_axi_r(k).data  <= std_logic_vector(resize(unsigned(axi_rdata_arr(k)), 512));
        o_axi_r(k).last  <= axi_rlast_arr(k);
        o_axi_r(k).resp  <= "00";
        o_axi_b(k).valid <= axi_bvalid_arr(k);
        o_axi_b(k).resp  <= "00";
    end generate;

    ---------------------------------------------------------------------------
    -- Shared clock counter (used for AR request timestamping)
    ---------------------------------------------------------------------------
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            nowCount <= nowCount + 1;
        end if;
    end process;
    now32bit <= std_logic_vector(to_unsigned(nowCount, 32));

    ---------------------------------------------------------------------------
    -- Per-interface logic (generate)
    ---------------------------------------------------------------------------
    ifgen : for k in 0 to g_NUM_INTERFACES-1 generate

        -- AR FIFO input packing: [reqTime(31:0), len(39:32), addr(FIFO_WIDTH-1:40)]
        axi_arFIFO_din_arr(k)(31 downto 0)          <= now32bit;
        axi_arFIFO_din_arr(k)(39 downto 32)         <= i_axi_ar(k).len;
        axi_arFIFO_din_arr(k)(FIFO_WIDTH-1 downto 40) <= i_axi_ar(k).addr(AXI_ADDR_WIDTH-1 downto 0);

        axi_arready_arr(k)   <= '1' when (unsigned(axi_arFIFO_WrDataCount_arr(k)) < READ_QUEUE_SIZE) else '0';
        axi_arFIFO_wren_arr(k) <= i_axi_ar(k).valid and axi_arready_arr(k);

        fifo_ar_inst : xpm_fifo_sync
        generic map (
            DOUT_RESET_VALUE    => "0",
            ECC_MODE            => "no_ecc",
            FIFO_MEMORY_TYPE    => "distributed",
            FIFO_READ_LATENCY   => 1,
            FIFO_WRITE_DEPTH    => 32,
            FULL_RESET_VALUE    => 0,
            PROG_EMPTY_THRESH   => 10,
            PROG_FULL_THRESH    => 10,
            RD_DATA_COUNT_WIDTH => 6,
            READ_DATA_WIDTH     => FIFO_WIDTH,
            READ_MODE           => "fwft",
            SIM_ASSERT_CHK      => 0,
            USE_ADV_FEATURES    => "0404",
            WAKEUP_TIME         => 0,
            WRITE_DATA_WIDTH    => FIFO_WIDTH,
            WR_DATA_COUNT_WIDTH => 6
        )
        port map (
            almost_empty  => open,
            almost_full   => open,
            data_valid    => open,
            dbiterr       => open,
            dout          => axi_arFIFO_dout_arr(k),
            empty         => axi_arFIFO_empty_arr(k),
            full          => open,
            overflow      => open,
            prog_empty    => open,
            prog_full     => open,
            rd_data_count => open,
            rd_rst_busy   => open,
            sbiterr       => open,
            underflow     => open,
            wr_ack        => open,
            wr_data_count => axi_arFIFO_WrDataCount_arr(k),
            wr_rst_busy   => open,
            din           => axi_arFIFO_din_arr(k),
            injectdbiterr => '0',
            injectsbiterr => '0',
            rd_en         => axi_arFIFO_rdEn_arr(k),
            rst           => '0',
            sleep         => '0',
            wr_clk        => i_clk,
            wr_en         => axi_arFIFO_wren_arr(k)
        );

        -- Unpack FIFO output
        axi_araddr_delayed_arr(k) <= axi_arFIFO_dout_arr(k)(FIFO_WIDTH-1 downto 40);
        axi_arlen_delayed_arr(k)  <= axi_arFIFO_dout_arr(k)(39 downto 32);
        axi_reqTime_arr(k)        <= axi_arFIFO_dout_arr(k)(31 downto 0);

        -- Delayed-valid: only present an AR entry after MIN_LAG clocks
        axi_arvalid_delayed_arr(k) <=
            '1' when (axi_arFIFO_empty_arr(k) = '0' and
                      (unsigned(axi_reqTime_arr(k)) + MIN_LAG) < nowCount)
            else '0';
        axi_arFIFO_rdEn_arr(k) <= axi_arvalid_delayed_arr(k) and axi_arready_delayed_arr(k);

        -- Write/read FSM ready signals
        axi_awready_arr(k) <= '1' when w_fsm_arr(k) = idle else '0';
        axi_wready_arr(k)  <= '1' when (w_data_used_arr(k) = '0' or w_fsm_arr(k) = wr_data) else '0';
        axi_bvalid_arr(k)  <= '1' when (w_fsm_arr(k) = wr_data and aw_len_arr(k) = 0) else '0';

        axi_arready_delayed_arr(k) <=
            '1' when (r_fsm_arr(k) = idle or
                      (r_fsm_arr(k) = rd_data and ar_len_arr(k) = 0 and
                       (axi_rvalid_arr(k) = '0' or i_axi_rready(k) = '1') and
                       readStall_arr(k) = running))
            else '0';

        -- Main AXI FSM process for this interface
        process(i_clk)
        begin
            if rising_edge(i_clk) then
                if i_rst_n = '0' then
                    w_fsm_arr(k)      <= idle;
                    r_fsm_arr(k)      <= idle;
                    axi_rlast_arr(k)  <= '0';
                    axi_rvalid_arr(k) <= '0';
                    -- Offset seeds so interfaces diverge immediately
                    pseudoRand1_arr(k)  <= RANDSEED + k * 97;
                    pseudoRand2_arr(k)  <= RANDSEED + k * 97;
                    readStall_arr(k)    <= running;
                else
                    -- Write FSM
                    case w_fsm_arr(k) is
                        when idle =>
                            if i_axi_aw(k).valid = '1' then
                                aw_addr_arr(k) <= i_axi_aw(k).addr(AXI_ADDR_WIDTH-1 downto 0);
                                aw_len_arr(k)  <= TO_INTEGER(unsigned(i_axi_aw(k).len));
                                if i_axi_w(k).valid = '1' or w_data_used_arr(k) = '1' then
                                    w_fsm_arr(k) <= wr_data;
                                else
                                    w_fsm_arr(k) <= wr_wait;
                                end if;
                            end if;
                            if i_axi_w(k).valid = '1' and w_data_used_arr(k) = '0' then
                                w_data_arr(k)      <= i_axi_w(k).data(AXI_DATA_WIDTH-1 downto 0);
                                w_last_arr(k)      <= i_axi_w(k).last;
                                w_data_used_arr(k) <= '1';
                            end if;

                        when wr_data =>
                            hbm_memory.MemWrite(aw_addr_arr(k), w_data_arr(k));
                            aw_addr_arr(k) <= std_logic_vector(unsigned(aw_addr_arr(k)) + (AXI_DATA_WIDTH/8));
                            if aw_len_arr(k) /= 0 then
                                aw_len_arr(k) <= aw_len_arr(k) - 1;
                                if i_axi_w(k).valid = '1' then
                                    w_fsm_arr(k) <= wr_data;
                                else
                                    w_fsm_arr(k) <= wr_wait;
                                end if;
                            else
                                w_fsm_arr(k) <= idle;
                            end if;
                            if i_axi_w(k).valid = '1' then
                                w_data_arr(k)      <= i_axi_w(k).data(AXI_DATA_WIDTH-1 downto 0);
                                w_data_used_arr(k) <= '1';
                                w_last_arr(k)      <= i_axi_w(k).last;
                            else
                                w_data_used_arr(k) <= '0';
                            end if;
                            assert (aw_len_arr(k) = 0 and w_last_arr(k) = '1') or
                                   (aw_len_arr(k) /= 0 and w_last_arr(k) = '0')
                                report "HBM_axi_tbModel_multi: bad axi_wlast on interface " &
                                       integer'image(k) severity failure;

                        when wr_wait =>
                            if i_axi_w(k).valid = '1' then
                                w_data_arr(k)      <= i_axi_w(k).data(AXI_DATA_WIDTH-1 downto 0);
                                w_last_arr(k)      <= i_axi_w(k).last;
                                w_data_used_arr(k) <= '1';
                                w_fsm_arr(k)       <= wr_data;
                            end if;

                        when others =>
                            w_fsm_arr(k) <= idle;
                    end case;

                    -- Read FSM
                    case r_fsm_arr(k) is
                        when idle =>
                            if axi_arvalid_delayed_arr(k) = '1' and axi_arready_delayed_arr(k) = '1' then
                                ar_addr_arr(k) <= axi_araddr_delayed_arr(k);
                                ar_len_arr(k)  <= TO_INTEGER(unsigned(axi_arlen_delayed_arr(k)));
                                r_fsm_arr(k)   <= rd_data;
                            end if;
                            if i_axi_rready(k) = '1' then
                                axi_rlast_arr(k)  <= '0';
                                axi_rvalid_arr(k) <= '0';
                            end if;

                        when rd_data =>
                            if (axi_rvalid_arr(k) = '0' or i_axi_rready(k) = '1') and
                               readStall_arr(k) = running then
                                axi_rdata_arr(k)  <= hbm_memory.MemRead(ar_addr_arr(k));
                                ar_addr_arr(k)    <= std_logic_vector(unsigned(ar_addr_arr(k)) + (AXI_DATA_WIDTH/8));
                                axi_rvalid_arr(k) <= '1';
                                if ar_len_arr(k) = 0 then
                                    if axi_arvalid_delayed_arr(k) = '1' and axi_arready_delayed_arr(k) = '1' then
                                        ar_addr_arr(k) <= axi_araddr_delayed_arr(k);
                                        ar_len_arr(k)  <= TO_INTEGER(unsigned(axi_arlen_delayed_arr(k)));
                                        r_fsm_arr(k)   <= rd_data;
                                    else
                                        r_fsm_arr(k) <= idle;
                                    end if;
                                    axi_rlast_arr(k) <= '1';
                                else
                                    ar_len_arr(k)    <= ar_len_arr(k) - 1;
                                    axi_rlast_arr(k) <= '0';
                                end if;
                            elsif axi_rvalid_arr(k) = '1' and i_axi_rready(k) = '1' then
                                axi_rvalid_arr(k) <= '0';
                            end if;

                        when others =>
                            r_fsm_arr(k)      <= idle;
                            axi_rlast_arr(k)  <= '0';
                            axi_rvalid_arr(k) <= '0';
                    end case;

                    -- Pseudo-random read latency
                    pseudoRand1_arr(k) <= pseudoRand1_arr(k) + 131;
                    pseudoRand2_arr(k) <= pseudoRand2_arr(k) + 173;
                    case readStall_arr(k) is
                        when running =>
                            if (pseudoRand1_arr(k) mod 101) < LATENCY_ZERO_PROBABILITY then
                                readStall_arr(k) <= running;
                            else
                                readStall_arr(k) <= stall;
                                if (pseudoRand2_arr(k) mod 101) < LATENCY_LOW_PROBABILITY then
                                    stallCount_arr(k) <= pseudoRand2_arr(k) mod 3;
                                else
                                    stallCount_arr(k) <= pseudoRand2_arr(k) mod 41;
                                end if;
                            end if;
                        when stall =>
                            if stallCount_arr(k) > 0 then
                                stallCount_arr(k) <= stallCount_arr(k) - 1;
                            else
                                readStall_arr(k) <= running;
                            end if;
                    end case;

                end if;
            end if;
        end process;

    end generate ifgen;

    ---------------------------------------------------------------------------
    -- Memory dump and initialisation (single shared memory)
    ---------------------------------------------------------------------------
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_write_to_disk = '1' then
                hbm_memory.MemDump(i_fname);
            end if;
            if i_init_mem = '1' then
                hbm_memory.MemInit(i_init_fname);
            end if;
        end if;
    end process;

end Behavioral;
