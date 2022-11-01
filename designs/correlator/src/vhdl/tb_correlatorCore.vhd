----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 20.08.2020 21:59:42
-- Design Name: 
-- Module Name: tb_vitisAccelCore - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------
library IEEE;
library common_lib, correlator_lib;
library axi4_lib;
library xpm;
use xpm.vcomponents.all;
use IEEE.STD_LOGIC_1164.ALL;
use axi4_lib.axi4_stream_pkg.ALL;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;
--use dsp_top_lib.run2_tb_pkg.ALL;
use std.textio.all;
use IEEE.std_logic_textio.all;
use IEEE.NUMERIC_STD.ALL;
use common_lib.common_pkg.all;
use std.env.finish;

library technology_lib;
USE technology_lib.tech_mac_100g_pkg.ALL;

entity tb_correlatorCore is
    generic (
        LFAA_BLOCKS_PER_FRAME_DIV3_generic :integer := 2;
        default_bigsim                     :boolean := FALSE
    );
end tb_correlatorCore;

architecture Behavioral of tb_correlatorCore is

    -- signal cmd_file_name    : string(1 to 21) := "LFAA100GE_tb_data.txt";
    -- signal RegCmd_file_name : string(1 to 14) := "HWData1_tb.txt";

    signal ap_clk : std_logic := '0';
    signal clk100 : std_logic := '0';
    signal ap_rst_n : std_logic := '0';
    signal mc_lite_mosi : t_axi4_lite_mosi;
    signal mc_lite_miso : t_axi4_lite_miso;

    signal LFAADone : std_logic := '0';
    -- The shared memory in the shell is 128Kbytes;
    -- i.e. 32k x 4 byte words. 
    type memType is array(32767 downto 0) of integer;
    shared variable sharedMem : memType;
    
    function strcmp(a, b : string) return boolean is
        alias a_val : string(1 to a'length) is a;
        alias b_val : string(1 to b'length) is b;
        variable a_char, b_char : character;
    begin
        if a'length /= b'length then
            return false;
        elsif a = b then
            return true;
        else
            return false;
        end if;
    end;
    
    COMPONENT axi_bram_RegisterSharedMem
    PORT (
        s_axi_aclk : IN STD_LOGIC;
        s_axi_aresetn : IN STD_LOGIC;
        s_axi_awaddr : IN STD_LOGIC_VECTOR(16 DOWNTO 0);
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
        s_axi_araddr : IN STD_LOGIC_VECTOR(16 DOWNTO 0);
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
        bram_addr_a : OUT STD_LOGIC_VECTOR(16 DOWNTO 0);
        bram_wrdata_a : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
        bram_rddata_a : IN STD_LOGIC_VECTOR(31 DOWNTO 0));
    END COMPONENT;
    
    --signal s_axi_aclk :  STD_LOGIC;
    --signal s_axi_aresetn :  STD_LOGIC;
    signal m00_awaddr :  STD_LOGIC_VECTOR(63 DOWNTO 0);
    signal m00_awlen :  STD_LOGIC_VECTOR(7 DOWNTO 0);
    signal m00_awsize :  STD_LOGIC_VECTOR(2 DOWNTO 0);
    signal m00_awburst :  STD_LOGIC_VECTOR(1 DOWNTO 0);
    signal m00_awlock :  STD_LOGIC;
    signal m00_awcache :  STD_LOGIC_VECTOR(3 DOWNTO 0);
    signal m00_awprot :  STD_LOGIC_VECTOR(2 DOWNTO 0);
    signal m00_awvalid :  STD_LOGIC;
    signal m00_awready :  STD_LOGIC;
    signal m00_wdata :  STD_LOGIC_VECTOR(31 DOWNTO 0);
    signal m00_wstrb :  STD_LOGIC_VECTOR(3 DOWNTO 0);
    signal m00_wlast :  STD_LOGIC;
    signal m00_wvalid :  STD_LOGIC;
    signal m00_wready :  STD_LOGIC;
    signal m00_bresp :  STD_LOGIC_VECTOR(1 DOWNTO 0);
    signal m00_bvalid :  STD_LOGIC;
    signal m00_bready :  STD_LOGIC;
    signal m00_araddr :  STD_LOGIC_VECTOR(63 DOWNTO 0);
    signal m00_arlen :  STD_LOGIC_VECTOR(7 DOWNTO 0);
    signal m00_arsize : STD_LOGIC_VECTOR(2 DOWNTO 0);
    signal m00_arburst : STD_LOGIC_VECTOR(1 DOWNTO 0);
    signal m00_arlock :  STD_LOGIC;
    signal m00_arcache :  STD_LOGIC_VECTOR(3 DOWNTO 0);
    signal m00_arprot :  STD_LOGIC_VECTOR(2 DOWNTO 0);
    signal m00_arvalid :  STD_LOGIC;
    signal m00_arready :  STD_LOGIC;
    signal m00_rdata :  STD_LOGIC_VECTOR(31 DOWNTO 0);
    signal m00_rresp :  STD_LOGIC_VECTOR(1 DOWNTO 0);
    signal m00_rlast :  STD_LOGIC;
    signal m00_rvalid :  STD_LOGIC;
    signal m00_rready :  STD_LOGIC;
    
    signal m00_clk : std_logic;
    signal m00_we : std_logic_vector(3 downto 0);
    signal m00_addr : std_logic_vector(16 downto 0);
    signal m00_wrData : std_logic_vector(31 downto 0);
    signal m00_rdData : std_logic_vector(31 downto 0);
    

    signal m01_awvalid : std_logic;
    signal m01_awready : std_logic;
    signal m01_awaddr : std_logic_vector(63 downto 0);
    signal m01_awid : std_logic_vector(0 downto 0);
    signal m01_awlen : std_logic_vector(7 downto 0);
    signal m01_awsize : std_logic_vector(2 downto 0);
    signal m01_awburst : std_logic_vector(1 downto 0);
    signal m01_awlock :  std_logic_vector(1 downto 0);
    signal m01_awcache :  std_logic_vector(3 downto 0);
    signal m01_awprot :  std_logic_vector(2 downto 0);
    signal m01_awqos :  std_logic_vector(3 downto 0);
    signal m01_awregion :  std_logic_vector(3 downto 0);
    signal m01_wvalid :  std_logic;
    signal m01_wready :  std_logic;
    signal m01_wdata :  std_logic_vector(511 downto 0);
    signal m01_wstrb :  std_logic_vector(63 downto 0);
    signal m01_wlast :  std_logic;
    signal m01_bvalid : std_logic;
    signal m01_bready :  std_logic;
    signal m01_bresp :  std_logic_vector(1 downto 0);
    signal m01_bid :  std_logic_vector(0 downto 0);
    signal m01_arvalid :  std_logic;
    signal m01_arready :  std_logic;
    signal m01_araddr :  std_logic_vector(63 downto 0);
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
    signal m01_rdata :  std_logic_vector(511 downto 0);
    signal m01_rlast :  std_logic;
    signal m01_rid :  std_logic_vector(0 downto 0);
    signal m01_rresp :  std_logic_vector(1 downto 0);
    
    signal m02_awvalid : std_logic;
    signal m02_awready : std_logic;
    signal m02_awaddr : std_logic_vector(63 downto 0);
    signal m02_awid : std_logic_vector(0 downto 0);
    signal m02_awlen : std_logic_vector(7 downto 0);
    signal m02_awsize : std_logic_vector(2 downto 0);
    signal m02_awburst : std_logic_vector(1 downto 0);
    signal m02_awlock :  std_logic_vector(1 downto 0);
    signal m02_awcache :  std_logic_vector(3 downto 0);
    signal m02_awprot :  std_logic_vector(2 downto 0);
    signal m02_awqos :  std_logic_vector(3 downto 0);
    signal m02_awregion :  std_logic_vector(3 downto 0);
    signal m02_wvalid :  std_logic;
    signal m02_wready :  std_logic;
    signal m02_wdata :  std_logic_vector(511 downto 0);
    signal m02_wstrb :  std_logic_vector(63 downto 0);
    signal m02_wlast :  std_logic;
    signal m02_bvalid : std_logic;
    signal m02_bready :  std_logic;
    signal m02_bresp :  std_logic_vector(1 downto 0);
    signal m02_bid :  std_logic_vector(0 downto 0);
    signal m02_arvalid :  std_logic;
    signal m02_arready :  std_logic;
    signal m02_araddr :  std_logic_vector(63 downto 0);
    signal m02_arid :  std_logic_vector(0 downto 0);
    signal m02_arlen :  std_logic_vector(7 downto 0);
    signal m02_arsize :  std_logic_vector(2 downto 0);
    signal m02_arburst : std_logic_vector(1 downto 0);
    signal m02_arlock :  std_logic_vector(1 downto 0);
    signal m02_arcache :  std_logic_vector(3 downto 0);
    signal m02_arprot :  std_logic_Vector(2 downto 0);
    signal m02_arqos :  std_logic_vector(3 downto 0);
    signal m02_arregion :  std_logic_vector(3 downto 0);
    signal m02_rvalid :  std_logic;
    signal m02_rready :  std_logic;
    signal m02_rdata :  std_logic_vector(511 downto 0);
    signal m02_rlast :  std_logic;
    signal m02_rid :  std_logic_vector(0 downto 0);
    signal m02_rresp :  std_logic_vector(1 downto 0);

    signal m03_awvalid : std_logic;
    signal m03_awready : std_logic;
    signal m03_awaddr : std_logic_vector(63 downto 0);
    signal m03_awid : std_logic_vector(0 downto 0);
    signal m03_awlen : std_logic_vector(7 downto 0);
    signal m03_awsize : std_logic_vector(2 downto 0);
    signal m03_awburst : std_logic_vector(1 downto 0);
    signal m03_awlock :  std_logic_vector(1 downto 0);
    signal m03_awcache :  std_logic_vector(3 downto 0);
    signal m03_awprot :  std_logic_vector(2 downto 0);
    signal m03_awqos :  std_logic_vector(3 downto 0);
    signal m03_awregion :  std_logic_vector(3 downto 0);
    signal m03_wvalid :  std_logic;
    signal m03_wready :  std_logic;
    signal m03_wdata :  std_logic_vector(511 downto 0);
    signal m03_wstrb :  std_logic_vector(63 downto 0);
    signal m03_wlast :  std_logic;
    signal m03_bvalid : std_logic;
    signal m03_bready :  std_logic;
    signal m03_bresp :  std_logic_vector(1 downto 0);
    signal m03_bid :  std_logic_vector(0 downto 0);
    signal m03_arvalid :  std_logic;
    signal m03_arready :  std_logic;
    signal m03_araddr :  std_logic_vector(63 downto 0);
    signal m03_arid :  std_logic_vector(0 downto 0);
    signal m03_arlen :  std_logic_vector(7 downto 0);
    signal m03_arsize :  std_logic_vector(2 downto 0);
    signal m03_arburst : std_logic_vector(1 downto 0);
    signal m03_arlock :  std_logic_vector(1 downto 0);
    signal m03_arcache :  std_logic_vector(3 downto 0);
    signal m03_arprot :  std_logic_Vector(2 downto 0);
    signal m03_arqos :  std_logic_vector(3 downto 0);
    signal m03_arregion :  std_logic_vector(3 downto 0);
    signal m03_rvalid :  std_logic;
    signal m03_rready :  std_logic;
    signal m03_rdata :  std_logic_vector(511 downto 0);
    signal m03_rlast :  std_logic;
    signal m03_rid :  std_logic_vector(0 downto 0);
    signal m03_rresp :  std_logic_vector(1 downto 0);

    signal eth100_rx_sosi : t_lbus_sosi;
    signal eth100_tx_sosi : t_lbus_sosi;
    signal eth100_tx_siso : t_lbus_siso;
    signal setupDone : std_logic;
    signal eth100G_clk : std_logic := '0';
    
    signal m00_bram_we : STD_LOGIC_VECTOR(3 DOWNTO 0);
    signal m00_bram_en : STD_LOGIC;
    signal m00_bram_addr : STD_LOGIC_VECTOR(16 DOWNTO 0);
    signal m00_bram_addr_word : std_logic_vector(14 downto 0);
    signal m00_bram_wrData : STD_LOGIC_VECTOR(31 DOWNTO 0);
    signal m00_bram_rdData : STD_LOGIC_VECTOR(31 DOWNTO 0);
    signal m00_bram_clk : std_logic;
    signal validMemRstActive : std_logic; 

    signal m02_arFIFO_dout, m02_arFIFO_din : std_logic_vector(63 downto 0);
    signal m02_arFIFO_empty, m02_arFIFO_rdEn, m02_arFIFO_wrEn : std_logic;
    signal m02_arFIFO_wrDataCount : std_logic_vector(5 downto 0);
    signal M02_READ_QUEUE_SIZE, MIN_LAG : integer;
    signal m02_arlen_delayed : std_logic_vector(7 downto 0);
    signal m02_arsize_delayed : std_logic_vector(2 downto 0);
    signal m02_arburst_delayed : std_logic_vector(1 downto 0);
    signal m02_arcache_delayed : std_logic_vector(3 downto 0);
    signal m02_arprot_delayed : std_logic_vector(2 downto 0);
    signal m02_arqos_delayed : std_logic_vector(3 downto 0);
    signal m02_arregion_delayed : std_logic_vector(3 downto 0);
    
    signal m02_araddr_delayed : std_logic_vector(19 downto 0);
    signal m02_reqTime : std_logic_vector(31 downto 0);
    signal m02_arvalid_delayed, m02_arready_delayed : std_logic;
        
    signal wr_addr_x410E0, rd_addr_x410E0 : std_logic := '0'; 
    signal wrdata_x410E0, rddata_x410E0 : std_logic := '0';
    
    -- Do an axi-lite read of a single 32-bit register.
    PROCEDURE axi_lite_rd(SIGNAL mm_clk   : IN STD_LOGIC;
                          SIGNAL axi_miso : IN t_axi4_lite_miso;
                          SIGNAL axi_mosi : OUT t_axi4_lite_mosi;
                          register_addr   : NATURAL;  -- 4-byte word address
                          variable rd_data  : out std_logic_vector(31 downto 0)) is

        VARIABLE stdio             : line;
        VARIABLE result            : STD_LOGIC_VECTOR(31 DOWNTO 0);
        variable wvalidInt         : std_logic;
        variable awvalidInt        : std_logic;
        
    BEGIN

        -- Start transaction
        WAIT UNTIL rising_edge(mm_clk);
            -- Setup read address
            axi_mosi.arvalid <= '1';
            axi_mosi.araddr <= std_logic_vector(to_unsigned(register_addr*4, 32));
            axi_mosi.rready <= '1';

        read_address_wait: LOOP
            WAIT UNTIL rising_edge(mm_clk);
            IF axi_miso.arready = '1' THEN
               axi_mosi.arvalid <= '0';
               axi_mosi.araddr <= (OTHERS => '0');
            END IF;

            IF axi_miso.rvalid = '1' THEN
               EXIT;
            END IF;
        END LOOP;

        
        rd_data := axi_miso.rdata(31 downto 0);
        -- Read response
        IF axi_miso.rresp = "01" THEN
            write(stdio, string'("exclusive access error "));
            writeline(output, stdio);
        ELSIF axi_miso.rresp = "10" THEN
            write(stdio, string'("slave error "));
            writeline(output, stdio);
        ELSIF axi_miso.rresp = "11" THEN
           write(stdio, string'("address decode error "));
           writeline(output, stdio);
        END IF;


        
        WAIT UNTIL rising_edge(mm_clk);
        axi_mosi.rready <= '0';
    end procedure;
        
begin

    ap_clk <= not ap_clk after 1.666 ns; -- 300 MHz clock.
    clk100 <= not clk100 after 5 ns; -- 100 MHz clock
    eth100G_clk <= not eth100G_clk after 1.553 ns; -- 322 MHz

    -- process
    --     file RegCmdfile: TEXT;
    --     variable RegLine_in : Line;
    --     variable RegGood : boolean;
    --     variable cmd_str : string(1 to 2);
    --     variable regAddr : std_logic_vector(31 downto 0);
    --     variable regSize : std_logic_vector(31 downto 0);
    --     variable regData : std_logic_vector(31 downto 0);
    --     variable readResult : std_logic_vector(31 downto 0);
    -- begin        
    --     SetupDone <= '0';
    --     ap_rst_n <= '1';
        
    --     --FILE_OPEN(RegCmdfile,RegCmd_file_name,READ_MODE);
        
    --     for i in 1 to 10 loop
    --         WAIT UNTIL RISING_EDGE(ap_clk);
    --     end loop;
    --     ap_rst_n <= '0';
    --     for i in 1 to 10 loop
    --          WAIT UNTIL RISING_EDGE(ap_clk);
    --     end loop;
    --     ap_rst_n <= '1';
        
    --     for i in 1 to 100 loop
    --          WAIT UNTIL RISING_EDGE(ap_clk);
    --     end loop;
        
    --     -- For some reason the first transaction doesn't work; this is just a dummy transaction
    --     -- Arguments are       clk,    miso      ,    mosi     , 4-byte word Addr, write ?, data)
    --     axi_lite_transaction(ap_clk, mc_lite_miso, mc_lite_mosi, 0,    true, x"00000000");
        
    --     -- Addresses in the axi lite control module
    --     -- ADDR_AP_CTRL         = 6'h00,
    --     -- ADDR_DMA_SRC_0       = 6'h10,
    --     -- ADDR_DMA_DEST_0      = 6'h14,
    --     -- ADDR_DMA_SHARED_0    = 6'h18,
    --     -- ADDR_DMA_SHARED_1    = 6'h1C,
    --     -- ADDR_DMA_SIZE        = 6'h20,
    --     --
    --     axi_lite_transaction(ap_clk, mc_lite_miso, mc_lite_mosi, 6, true, x"DEF20000");  -- Full address of the shared memory; arbitrary so long as it is 128K aligned.
    --     axi_lite_transaction(ap_clk, mc_lite_miso, mc_lite_mosi, 7, true, x"56789ABC");  -- High 32 bits of the  address of the shared memory; arbitrary.
        
        
    --     -- Pseudo code :
    --     --
    --     --  Repeat while there are commands in the command file:
    --     --    - Read command from the file (either read or write, together with the ARGs register address)
    --     --        - Possible commands : [read address length]   <-- Does a register read.
    --     --                              [write address length]  <-- Does a register write
    --     --    - If this is a write, then read the write data from the file, and copy into a shared variable used by the memory.
    --     --    - trigger the kernel to do the register read/write.
    --     --  Trigger sending of the 100G test data.
    --     --
        
    --     -- 
        
        
    --     SetupDone <= '1';
    --     wait;
    -- end process;
    
    
    -- m00_bram_addr_word <= m00_bram_addr(16 downto 2);
    
    -- process(m00_bram_clk)
    -- begin
    --     if rising_edge(m00_bram_clk) then
    --         m00_bram_rdData <= std_logic_vector(to_signed(sharedMem(to_integer(unsigned(m00_bram_addr_word))),32)); 
            
    --         if m00_bram_we(0) = '1' and m00_bram_en = '1' then
    --             sharedMem(to_integer(unsigned(m00_bram_addr_word))) := to_integer(signed(m00_bram_wrData));
    --         end if;
            
    --         assert (m00_bram_we(3 downto 0) /= "0000" or m00_bram_we(3 downto 0) /= "1111") report "Byte wide write enables should never occur to shared memory" severity error;
            
    --     end if;
    -- end process;
    
    -----------------------------------------------------------------------------------
    -----------------------------------------------------------------------------------
    -- axi BRAM controller to interface to the shared memory for register reads and writes.
    
    registerSharedMem : axi_bram_RegisterSharedMem
    PORT MAP (
        s_axi_aclk => ap_clk,
        s_axi_aresetn => ap_rst_n,
        s_axi_awaddr => m00_awaddr(16 downto 0),
        s_axi_awlen => m00_awlen,
        s_axi_awsize => m00_awsize,
        s_axi_awburst => m00_awburst,
        s_axi_awlock => '0',
        s_axi_awcache => m00_awcache,
        s_axi_awprot => m00_awprot,
        s_axi_awvalid => m00_awvalid,
        s_axi_awready => m00_awready,
        s_axi_wdata => m00_wdata,
        s_axi_wstrb => m00_wstrb,
        s_axi_wlast => m00_wlast,
        s_axi_wvalid => m00_wvalid,
        s_axi_wready => m00_wready,
        s_axi_bresp => m00_bresp,
        s_axi_bvalid => m00_bvalid,
        s_axi_bready => m00_bready,
        s_axi_araddr => m00_araddr(16 downto 0),
        s_axi_arlen => m00_arlen,
        s_axi_arsize => m00_arsize,
        s_axi_arburst => m00_arburst,
        s_axi_arlock => '0',
        s_axi_arcache => m00_arcache,
        s_axi_arprot => m00_arprot,
        s_axi_arvalid => m00_arvalid,
        s_axi_arready => m00_arready,
        s_axi_rdata => m00_rdata,
        s_axi_rresp => m00_rresp,
        s_axi_rlast => m00_rlast,
        s_axi_rvalid => m00_rvalid,
        s_axi_rready => m00_rready,
        bram_rst_a => open,   -- OUT STD_LOGIC;
        bram_clk_a => m00_bram_clk, -- OUT STD_LOGIC;
        bram_en_a  => m00_bram_en, -- OUT STD_LOGIC;
        bram_we_a  => m00_bram_we, -- OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        bram_addr_a => m00_bram_addr, -- OUT STD_LOGIC_VECTOR(16 DOWNTO 0);
        bram_wrdata_a => m00_bram_wrData, -- OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
        bram_rddata_a => m00_bram_rdData  -- IN STD_LOGIC_VECTOR(31 DOWNTO 0)
    );
    
    -------------------------------------------------------------------------------------------
    -- 100 GE data input
    -- eth100_rx_sosi
    -- TYPE t_lbus_sosi IS RECORD  -- Source Out and Sink In
    --   data       : STD_LOGIC_VECTOR(511 DOWNTO 0);                -- Data bus
    --   valid      : STD_LOGIC_VECTOR(3 DOWNTO 0);    -- Data segment enable
    --   eop        : STD_LOGIC_VECTOR(3 DOWNTO 0);    -- End of packet
    --   sop        : STD_LOGIC_VECTOR(3 DOWNTO 0);    -- Start of packet
    --   error      : STD_LOGIC_VECTOR(3 DOWNTO 0);    -- Error flag, indicates data has an error
    --   empty      : t_empty_arr(3 DOWNTO 0);         -- Number of bytes empty in the segment  (four 4bit entries)
    -- END RECORD;
    process
        file cmdfile: TEXT;
        variable line_in : Line;
        variable good : boolean;
        variable LFAArepeats : std_logic_vector(15 downto 0);
        variable LFAAData  : std_logic_vector(511 downto 0);
        variable LFAAvalid : std_logic_vector(3 downto 0);
        variable LFAAeop   : std_logic_vector(3 downto 0);
        variable LFAAerror : std_logic_vector(3 downto 0);
        variable LFAAempty0 : std_logic_vector(3 downto 0);
        variable LFAAempty1 : std_logic_vector(3 downto 0);
        variable LFAAempty2 : std_logic_vector(3 downto 0);
        variable LFAAempty3 : std_logic_vector(3 downto 0);
        variable LFAAsop    : std_logic_vector(3 downto 0);
    begin
        
        eth100_rx_sosi.data <= (others => '0');  -- 512 bits
        eth100_rx_sosi.valid <= "0000";          -- 4 bits
        eth100_rx_sosi.eop <= "0000";  
        eth100_rx_sosi.sop <= "0000";
        eth100_rx_sosi.error <= "0000";
        eth100_rx_sosi.empty(0) <= "0000";
        eth100_rx_sosi.empty(1) <= "0000";
        eth100_rx_sosi.empty(2) <= "0000";
        eth100_rx_sosi.empty(3) <= "0000";
        
--        FILE_OPEN(cmdfile,cmd_file_name,READ_MODE);
--        wait until SetupDone = '1';
        
--        wait until rising_edge(eth100G_clk);
        
--        while (not endfile(cmdfile)) loop 
--            readline(cmdfile, line_in);
--            hread(line_in,LFAArepeats,good);
--            hread(line_in,LFAAData,good);
--            hread(line_in,LFAAvalid,good);
--            hread(line_in,LFAAeop,good);
--            hread(line_in,LFAAerror,good);
--            hread(line_in,LFAAempty0,good);
--            hread(line_in,LFAAempty1,good);
--            hread(line_in,LFAAempty2,good);
--            hread(line_in,LFAAempty3,good);
--            hread(line_in,LFAAsop,good);
            
--            eth100_rx_sosi.data <= LFAAData;  -- 512 bits
--            eth100_rx_sosi.valid <= LFAAValid;          -- 4 bits
--            eth100_rx_sosi.eop <= LFAAeop;
--            eth100_rx_sosi.sop <= LFAAsop;
--            eth100_rx_sosi.error <= LFAAerror;
--            eth100_rx_sosi.empty(0) <= LFAAempty0;
--            eth100_rx_sosi.empty(1) <= LFAAempty1;
--            eth100_rx_sosi.empty(2) <= LFAAempty2;
--            eth100_rx_sosi.empty(3) <= LFAAempty3;
            
--            wait until rising_edge(eth100G_clk);
--            while LFAArepeats /= "0000000000000000" loop
--                LFAArepeats := std_logic_vector(unsigned(LFAArepeats) - 1);
--                wait until rising_edge(eth100G_clk);
--            end loop;
--        end loop;
        
--        LFAADone <= '1';
--        wait;

        report "number of tx packets all received";

        wait for 5 us;
        report "simulation successfully finished";
        finish;
    end process;
    
    eth100_tx_siso.ready <= '1';
    eth100_tx_siso.underflow <= '0';
    eth100_tx_siso.overflow <= '0';
    
    -- Capture data packets in eth100_tx_sosi to a file.
    -- fields in eth100_tx_sosi are
    --   .data(511:0)
    --   .valid(3:0)
    --   .eop(3:0)
    --   .sop(3:0)
    --   .empty(3:0)(3:0)
    
     lbusRX : entity correlator_lib.lbus_packet_receive
     Generic map (
         log_file_name => "lbus_out.txt"
     )
     Port map ( 
         clk      => eth100G_clk, -- in  std_logic;     -- clock
         i_rst    => '0', -- in  std_logic;     -- reset input
         i_din    => eth100_tx_sosi.data, -- in  std_logic_vector(511 downto 0);  -- actual data out.
         i_valid  => eth100_tx_sosi.valid, -- in  std_logic_vector(3 downto 0);     -- data out valid (high for duration of the packet)
         i_eop    => eth100_tx_sosi.eop,   -- in  std_logic_vector(3 downto 0);
         i_sop    => eth100_tx_sosi.sop,   -- in  std_logic_vector(3 downto 0);
         i_empty0 => eth100_tx_sosi.empty(0), --  in std_logic_vector(3 downto 0);
         i_empty1 => eth100_tx_sosi.empty(1), -- in std_logic_vector(3 downto 0);
         i_empty2 => eth100_tx_sosi.empty(2), -- in std_logic_vector(3 downto 0);
         i_empty3 => eth100_tx_sosi.empty(3)  -- in std_logic_vector(3 downto 0)
     );
    
-- temp lbus out stimulus
lbus_out_proc : process(eth100G_clk)
begin
    if rising_edge(eth100G_clk) then
        eth100_tx_sosi.data(511 downto 384)     <= x"0123456789ABCDEF2222222222222222";
        eth100_tx_sosi.data(383 downto 256)     <= x"1888888889ABCDEF4444444444444444";
        eth100_tx_sosi.data(255 downto 128)     <= x"2DEADBEEF9ABCDEF6666666666666666";
        eth100_tx_sosi.data(127 downto 0)       <= x"300000000000CDEF8888888888888888";
        
        
        eth100_tx_sosi.valid                    <= x"A";
        
        
        eth100_tx_sosi.eop                      <= x"A";
        eth100_tx_sosi.sop                      <= x"A";
        eth100_tx_sosi.empty(0)                 <= x"0";
        eth100_tx_sosi.empty(1)                 <= x"0";
        eth100_tx_sosi.empty(2)                 <= x"A";
        eth100_tx_sosi.empty(3)                 <= x"0";

    end if;
end process;
    
    
--    dut : entity correlator_lib.correlator_core
--    generic map (
--        g_SIMULATION => TRUE, -- BOOLEAN;  -- when true, the 100GE core is disabled and instead the lbus comes from the top level pins
--        g_USE_META => FALSE,   -- BOOLEAN;  -- puts meta data in place of the filterbank data in the corner turn, to help debug the corner turn.
--        -- GLOBAL GENERICS for PERENTIE LOGIC
--        g_DEBUG_ILA              => FALSE, --  BOOLEAN
--        g_LFAA_BLOCKS_PER_FRAME  => 32,    --  allowed values are 32, 64 or 128. 32 and 64 are for simulation. For real system, use 128.
        
        
--        C_S_AXI_CONTROL_ADDR_WIDTH   => 8,  -- integer := 7;
--        C_S_AXI_CONTROL_DATA_WIDTH   => 32, -- integer := 32;
--        C_M_AXI_ADDR_WIDTH => 64,         -- integer := 64;
--        C_M_AXI_DATA_WIDTH => 32,         -- integer := 32;
--        C_M_AXI_ID_WIDTH => 1,             -- integer := 1
--        -- M01 = first stage corner turn, between LFAA ingest and the filterbanks
--        M01_AXI_ADDR_WIDTH => 64,
--        M01_AXI_DATA_WIDTH => 512,
--        M01_AXI_ID_WIDTH   => 1,
--        -- M02 = Correlator HBM; buffer between the filterbanks and the correlator
--        M02_AXI_ADDR_WIDTH => 64,
--        M02_AXI_DATA_WIDTH => 512, 
--        M02_AXI_ID_WIDTH   => 1,
--        -- M03 = Visibilities
--        M03_AXI_ADDR_WIDTH => 64, 
--        M03_AXI_DATA_WIDTH => 512,  
--        M03_AXI_ID_WIDTH   => 1
--    ) port map (
--        ap_clk   => ap_clk, --  in std_logic;
--        ap_rst_n => ap_rst_n, -- in std_logic;
        
--        -----------------------------------------------------------------------
--        -- Ports used for simulation only.
--        --
--        -- Received data from 100GE
--        i_eth100_rx_sosi => eth100_rx_sosi, -- in t_lbus_sosi;
--        -- Data to be transmitted on 100GE
--        o_eth100_tx_sosi => eth100_tx_sosi, -- out t_lbus_sosi;
--        i_eth100_tx_siso => eth100_tx_siso, --  in t_lbus_siso;
--        i_clk_100GE      => eth100G_clk,     -- in std_logic;        
--        -- reset of the valid memory is in progress.
--        o_validMemRstActive => validMemRstActive, -- out std_logic;  
--        --  Note: A minimum subset of AXI4 memory mapped signals are declared.  AXI
--        --  signals omitted from these interfaces are automatically inferred with the
--        -- optimal values for Xilinx SDx systems.  This allows Xilinx AXI4 Interconnects
--        -- within the system to be optimized by removing logic for AXI4 protocol
--        -- features that are not necessary. When adapting AXI4 masters within the RTL
--        -- kernel that have signals not declared below, it is suitable to add the
--        -- signals to the declarations below to connect them to the AXI4 Master.
--        --
--        -- List of omitted signals - effect
--        -- -------------------------------
--        --  ID - Transaction ID are used for multithreading and out of order transactions.  This increases complexity. This saves logic and increases Fmax in the system when ommited.
--        -- SIZE - Default value is log2(data width in bytes). Needed for subsize bursts. This saves logic and increases Fmax in the system when ommited.
--        -- BURST - Default value (0b01) is incremental.  Wrap and fixed bursts are not recommended. This saves logic and increases Fmax in the system when ommited.
--        -- LOCK - Not supported in AXI4
--        -- CACHE - Default value (0b0011) allows modifiable transactions. No benefit to changing this.
--        -- PROT - Has no effect in SDx systems.
--        -- QOS - Has no effect in SDx systems.
--        -- REGION - Has no effect in SDx systems.
--        -- USER - Has no effect in SDx systems.
--        --  RESP - Not useful in most SDx systems.
--        --------------------------------------------------------------------------------------
--        --  AXI4-Lite slave interface
--        s_axi_control_awvalid => mc_lite_mosi.awvalid, --  in std_logic;
--        s_axi_control_awready => mc_lite_miso.awready, --  out std_logic;
--        s_axi_control_awaddr  => mc_lite_mosi.awaddr(7 downto 0), -- in std_logic_vector(C_S_AXI_CONTROL_ADDR_WIDTH-1 downto 0);
--        s_axi_control_wvalid  => mc_lite_mosi.wvalid, -- in std_logic;
--        s_axi_control_wready  => mc_lite_miso.wready, -- out std_logic;
--        s_axi_control_wdata   => mc_lite_mosi.wdata(31 downto 0), -- in std_logic_vector(C_S_AXI_CONTROL_DATA_WIDTH-1 downto 0);
--        s_axi_control_wstrb   => mc_lite_mosi.wstrb(3 downto 0), -- in std_logic_vector(C_S_AXI_CONTROL_DATA_WIDTH/8-1 downto 0);
--        s_axi_control_arvalid => mc_lite_mosi.arvalid, -- in std_logic;
--        s_axi_control_arready => mc_lite_miso.arready, -- out std_logic;
--        s_axi_control_araddr  => mc_lite_mosi.araddr(7 downto 0), -- in std_logic_vector(C_S_AXI_CONTROL_ADDR_WIDTH-1 downto 0);
--        s_axi_control_rvalid  => mc_lite_miso.rvalid,  -- out std_logic;
--        s_axi_control_rready  => mc_lite_mosi.rready, -- in std_logic;
--        s_axi_control_rdata   => mc_lite_miso.rdata(31 downto 0), -- out std_logic_vector(C_S_AXI_CONTROL_DATA_WIDTH-1 downto 0);
--        s_axi_control_rresp   => mc_lite_miso.rresp(1 downto 0), -- out std_logic_vector(1 downto 0);
--        s_axi_control_bvalid  => mc_lite_miso.bvalid, -- out std_logic;
--        s_axi_control_bready  => mc_lite_mosi.bready, -- in std_logic;
--        s_axi_control_bresp   => mc_lite_miso.bresp(1 downto 0), -- out std_logic_vector(1 downto 0);
  
--        -- AXI4 master interface for accessing registers : m00_axi
--        m00_axi_awvalid => m00_awvalid, -- out std_logic;
--        m00_axi_awready => m00_awready, -- in std_logic;
--        m00_axi_awaddr  => m00_awaddr,  -- out std_logic_vector(C_M_AXI_ADDR_WIDTH-1 downto 0);
--        m00_axi_awid    => open, --s_axi_awid,    -- out std_logic_vector(C_M_AXI_ID_WIDTH - 1 downto 0);
--        m00_axi_awlen   => m00_awlen,   -- out std_logic_vector(7 downto 0);
--        m00_axi_awsize  => m00_awsize,  -- out std_logic_vector(2 downto 0);
--        m00_axi_awburst => m00_awburst, -- out std_logic_vector(1 downto 0);
--        m00_axi_awlock  => open, -- s_axi_awlock,  -- out std_logic_vector(1 downto 0);
--        m00_axi_awcache => m00_awcache, -- out std_logic_vector(3 downto 0);
--        m00_axi_awprot  => m00_awprot,  -- out std_logic_vector(2 downto 0);
--        m00_axi_awqos   => open, -- s_axi_awqos,   -- out std_logic_vector(3 downto 0);
--        m00_axi_awregion => open, -- s_axi_awregion, -- out std_logic_vector(3 downto 0);
--        m00_axi_wvalid   => m00_wvalid,   -- out std_logic;
--        m00_axi_wready   => m00_wready,   -- in std_logic;
--        m00_axi_wdata    => m00_wdata,    -- out std_logic_vector(C_M_AXI_DATA_WIDTH-1 downto 0);
--        m00_axi_wstrb    => m00_wstrb,    -- out std_logic_vector(C_M_AXI_DATA_WIDTH/8-1 downto 0);
--        m00_axi_wlast    => m00_wlast,    -- out std_logic;
--        m00_axi_bvalid   => m00_bvalid,   -- in std_logic;
--        m00_axi_bready   => m00_bready,   -- out std_logic;
--        m00_axi_bresp    => m00_bresp,    -- in std_logic_vector(1 downto 0);
--        m00_axi_bid      => "0", -- s_axi_bid,      -- in std_logic_vector(C_M_AXI_ID_WIDTH - 1 downto 0);
--        m00_axi_arvalid  => m00_arvalid,  -- out std_logic;
--        m00_axi_arready  => m00_arready,  -- in std_logic;
--        m00_axi_araddr   => m00_araddr,   -- out std_logic_vector(C_M_AXI_ADDR_WIDTH-1 downto 0);
--        m00_axi_arid     => open, -- s_axi_arid,     -- out std_logic_vector(C_M_AXI_ID_WIDTH-1 downto 0);
--        m00_axi_arlen    => m00_arlen,    -- out std_logic_vector(7 downto 0);
--        m00_axi_arsize   => m00_arsize,   -- out std_logic_vector(2 downto 0);
--        m00_axi_arburst  => m00_arburst,  -- out std_logic_vector(1 downto 0);
--        m00_axi_arlock   => open, -- s_axi_arlock,   -- out std_logic_vector(1 downto 0);
--        m00_axi_arcache  => m00_arcache,  -- out std_logic_vector(3 downto 0);
--        m00_axi_arprot   => m00_arprot,   -- out std_logic_Vector(2 downto 0);
--        m00_axi_arqos    => open, -- s_axi_arqos,    -- out std_logic_vector(3 downto 0);
--        m00_axi_arregion => open, -- s_axi_arregion, -- out std_logic_vector(3 downto 0);
--        m00_axi_rvalid   => m00_rvalid,   -- in std_logic;
--        m00_axi_rready   => m00_rready,   -- out std_logic;
--        m00_axi_rdata    => m00_rdata,    -- in std_logic_vector(C_M_AXI_DATA_WIDTH-1 downto 0);
--        m00_axi_rlast    => m00_rlast,    -- in std_logic;
--        m00_axi_rid      => "0", -- s_axi_rid,      -- in std_logic_vector(C_M_AXI_ID_WIDTH - 1 downto 0);
--        m00_axi_rresp    => m00_rresp,    -- in std_logic_vector(1 downto 0);


--        ---------------------------------------------------------------------------------------
--        -- AXI4 master interface for accessing HBM for the LFAA ingest corner turn : m01_axi
--        m01_axi_awvalid => m01_awvalid,   -- out std_logic;
--        m01_axi_awready => m01_awready,   -- in std_logic;
--        m01_axi_awaddr  => m01_awaddr,    -- out std_logic_vector(M01_AXI_ADDR_WIDTH-1 downto 0);
--        m01_axi_awid    => m01_awid,      -- out std_logic_vector(M01_AXI_ID_WIDTH - 1 downto 0);
--        m01_axi_awlen   => m01_awlen,     -- out std_logic_vector(7 downto 0);
--        m01_axi_awsize  => m01_awsize,    -- out std_logic_vector(2 downto 0);
--        m01_axi_awburst => m01_awburst,   -- out std_logic_vector(1 downto 0);
--        m01_axi_awlock  => m01_awlock,    -- out std_logic_vector(1 downto 0);
--        m01_axi_awcache => m01_awcache,   -- out std_logic_vector(3 downto 0);
--        m01_axi_awprot  => m01_awprot,    -- out std_logic_vector(2 downto 0);
--        m01_axi_awqos    => m01_awqos,    -- out std_logic_vector(3 downto 0);
--        m01_axi_awregion => m01_awregion, -- out std_logic_vector(3 downto 0);
--        m01_axi_wvalid   => m01_wvalid,   -- out std_logic;
--        m01_axi_wready   => m01_wready,   -- in std_logic;
--        m01_axi_wdata    => m01_wdata,    -- out std_logic_vector(M01_AXI_DATA_WIDTH-1 downto 0);
--        m01_axi_wstrb    => m01_wstrb,    -- out std_logic_vector(M01_AXI_DATA_WIDTH/8-1 downto 0);
--        m01_axi_wlast    => m01_wlast,    -- out std_logic;
--        m01_axi_bvalid   => m01_bvalid,   -- in std_logic;
--        m01_axi_bready   => m01_bready,   -- out std_logic;
--        m01_axi_bresp    => m01_bresp,    -- in std_logic_vector(1 downto 0);
--        m01_axi_bid      => m01_bid,      -- in std_logic_vector(M01_AXI_ID_WIDTH - 1 downto 0);
--        m01_axi_arvalid  => m01_arvalid,  -- out std_logic;
--        m01_axi_arready  => m01_arready,  -- in std_logic;
--        m01_axi_araddr   => m01_araddr,   -- out std_logic_vector(M01_AXI_ADDR_WIDTH-1 downto 0);
--        m01_axi_arid     => m01_arid,     -- out std_logic_vector(M01_AXI_ID_WIDTH-1 downto 0);
--        m01_axi_arlen    => m01_arlen,    -- out std_logic_vector(7 downto 0);
--        m01_axi_arsize   => m01_arsize,   -- out std_logic_vector(2 downto 0);
--        m01_axi_arburst  => m01_arburst,  -- out std_logic_vector(1 downto 0);
--        m01_axi_arlock   => m01_arlock,   -- out std_logic_vector(1 downto 0);
--        m01_axi_arcache  => m01_arcache,  -- out std_logic_vector(3 downto 0);
--        m01_axi_arprot   => m01_arprot,   -- out std_logic_Vector(2 downto 0);
--        m01_axi_arqos    => m01_arqos,    -- out std_logic_vector(3 downto 0);
--        m01_axi_arregion => m01_arregion, -- out std_logic_vector(3 downto 0);
--        m01_axi_rvalid   => m01_rvalid,   -- in std_logic;
--        m01_axi_rready   => m01_rready,   -- out std_logic;
--        m01_axi_rdata    => m01_rdata,    -- in std_logic_vector(M01_AXI_DATA_WIDTH-1 downto 0);
--        m01_axi_rlast    => m01_rlast,    -- in std_logic;
--        m01_axi_rid      => m01_rid,      -- in std_logic_vector(M01_AXI_ID_WIDTH - 1 downto 0);
--        m01_axi_rresp    => m01_rresp,    -- in std_logic_vector(1 downto 0);
--        ---------------------------------------------------------------------------------------
--        -- AXI4 master interface for accessing HBM for the Filterbank corner turn : m02_axi
--        m02_axi_awvalid => m02_awvalid,   -- out std_logic;
--        m02_axi_awready => m02_awready,   -- in std_logic;
--        m02_axi_awaddr  => m02_awaddr,    -- out std_logic_vector(M01_AXI_ADDR_WIDTH-1 downto 0);
--        m02_axi_awid    => m02_awid,      -- out std_logic_vector(M01_AXI_ID_WIDTH - 1 downto 0);
--        m02_axi_awlen   => m02_awlen,     -- out std_logic_vector(7 downto 0);
--        m02_axi_awsize  => m02_awsize,    -- out std_logic_vector(2 downto 0);
--        m02_axi_awburst => m02_awburst,   -- out std_logic_vector(1 downto 0);
--        m02_axi_awlock  => m02_awlock,    -- out std_logic_vector(1 downto 0);
--        m02_axi_awcache => m02_awcache,   -- out std_logic_vector(3 downto 0);
--        m02_axi_awprot  => m02_awprot,    -- out std_logic_vector(2 downto 0);
--        m02_axi_awqos    => m02_awqos,    -- out std_logic_vector(3 downto 0);
--        m02_axi_awregion => m02_awregion, -- out std_logic_vector(3 downto 0);
--        m02_axi_wvalid   => m02_wvalid,   -- out std_logic;
--        m02_axi_wready   => m02_wready,   -- in std_logic;
--        m02_axi_wdata    => m02_wdata,    -- out std_logic_vector(M01_AXI_DATA_WIDTH-1 downto 0);
--        m02_axi_wstrb    => m02_wstrb,    -- out std_logic_vector(M01_AXI_DATA_WIDTH/8-1 downto 0);
--        m02_axi_wlast    => m02_wlast,    -- out std_logic;
--        m02_axi_bvalid   => m02_bvalid,   -- in std_logic;
--        m02_axi_bready   => m02_bready,   -- out std_logic;
--        m02_axi_bresp    => m02_bresp,    -- in std_logic_vector(1 downto 0);
--        m02_axi_bid      => m02_bid,      -- in std_logic_vector(M01_AXI_ID_WIDTH - 1 downto 0);
--        m02_axi_arvalid  => m02_arvalid,  -- out std_logic;
--        m02_axi_arready  => m02_arready,  -- in std_logic;
--        m02_axi_araddr   => m02_araddr,   -- out std_logic_vector(M01_AXI_ADDR_WIDTH-1 downto 0);
--        m02_axi_arid     => m02_arid,     -- out std_logic_vector(M01_AXI_ID_WIDTH-1 downto 0);
--        m02_axi_arlen    => m02_arlen,    -- out std_logic_vector(7 downto 0);
--        m02_axi_arsize   => m02_arsize,   -- out std_logic_vector(2 downto 0);
--        m02_axi_arburst  => m02_arburst,  -- out std_logic_vector(1 downto 0);
--        m02_axi_arlock   => m02_arlock,   -- out std_logic_vector(1 downto 0);
--        m02_axi_arcache  => m02_arcache,  -- out std_logic_vector(3 downto 0);
--        m02_axi_arprot   => m02_arprot,   -- out std_logic_Vector(2 downto 0);
--        m02_axi_arqos    => m02_arqos,    -- out std_logic_vector(3 downto 0);
--        m02_axi_arregion => m02_arregion, -- out std_logic_vector(3 downto 0);
--        m02_axi_rvalid   => m02_rvalid,   -- in std_logic;
--        m02_axi_rready   => m02_rready,   -- out std_logic;
--        m02_axi_rdata    => m02_rdata,    -- in std_logic_vector(M01_AXI_DATA_WIDTH-1 downto 0);
--        m02_axi_rlast    => m02_rlast,    -- in std_logic;
--        m02_axi_rid      => m02_rid,      -- in std_logic_vector(M01_AXI_ID_WIDTH - 1 downto 0);
--        m02_axi_rresp    => m02_rresp,    -- in std_logic_vector(1 downto 0);
        
--        --
--        m03_axi_awvalid => m03_awvalid,   -- out std_logic;
--        m03_axi_awready => m03_awready,   -- in std_logic;
--        m03_axi_awaddr  => m03_awaddr,    -- out std_logic_vector(M01_AXI_ADDR_WIDTH-1 downto 0);
--        m03_axi_awid    => m03_awid,      -- out std_logic_vector(M01_AXI_ID_WIDTH - 1 downto 0);
--        m03_axi_awlen   => m03_awlen,     -- out std_logic_vector(7 downto 0);
--        m03_axi_awsize  => m03_awsize,    -- out std_logic_vector(2 downto 0);
--        m03_axi_awburst => m03_awburst,   -- out std_logic_vector(1 downto 0);
--        m03_axi_awlock  => m03_awlock,    -- out std_logic_vector(1 downto 0);
--        m03_axi_awcache => m03_awcache,   -- out std_logic_vector(3 downto 0);
--        m03_axi_awprot  => m03_awprot,    -- out std_logic_vector(2 downto 0);
--        m03_axi_awqos    => m03_awqos,    -- out std_logic_vector(3 downto 0);
--        m03_axi_awregion => m03_awregion, -- out std_logic_vector(3 downto 0);
--        m03_axi_wvalid   => m03_wvalid,   -- out std_logic;
--        m03_axi_wready   => m03_wready,   -- in std_logic;
--        m03_axi_wdata    => m03_wdata,    -- out std_logic_vector(M01_AXI_DATA_WIDTH-1 downto 0);
--        m03_axi_wstrb    => m03_wstrb,    -- out std_logic_vector(M01_AXI_DATA_WIDTH/8-1 downto 0);
--        m03_axi_wlast    => m03_wlast,    -- out std_logic;
--        m03_axi_bvalid   => m03_bvalid,   -- in std_logic;
--        m03_axi_bready   => m03_bready,   -- out std_logic;
--        m03_axi_bresp    => m03_bresp,    -- in std_logic_vector(1 downto 0);
--        m03_axi_bid      => m03_bid,      -- in std_logic_vector(M01_AXI_ID_WIDTH - 1 downto 0);
--        m03_axi_arvalid  => m03_arvalid,  -- out std_logic;
--        m03_axi_arready  => m03_arready,  -- in std_logic;
--        m03_axi_araddr   => m03_araddr,   -- out std_logic_vector(M01_AXI_ADDR_WIDTH-1 downto 0);
--        m03_axi_arid     => m03_arid,     -- out std_logic_vector(M01_AXI_ID_WIDTH-1 downto 0);
--        m03_axi_arlen    => m03_arlen,    -- out std_logic_vector(7 downto 0);
--        m03_axi_arsize   => m03_arsize,   -- out std_logic_vector(2 downto 0);
--        m03_axi_arburst  => m03_arburst,  -- out std_logic_vector(1 downto 0);
--        m03_axi_arlock   => m03_arlock,   -- out std_logic_vector(1 downto 0);
--        m03_axi_arcache  => m03_arcache,  -- out std_logic_vector(3 downto 0);
--        m03_axi_arprot   => m03_arprot,   -- out std_logic_Vector(2 downto 0);
--        m03_axi_arqos    => m03_arqos,    -- out std_logic_vector(3 downto 0);
--        m03_axi_arregion => m03_arregion, -- out std_logic_vector(3 downto 0);
--        m03_axi_rvalid   => m03_rvalid,   -- in std_logic;
--        m03_axi_rready   => m03_rready,   -- out std_logic;
--        m03_axi_rdata    => m03_rdata,    -- in std_logic_vector(M01_AXI_DATA_WIDTH-1 downto 0);
--        m03_axi_rlast    => m03_rlast,    -- in std_logic;
--        m03_axi_rid      => m03_rid,      -- in std_logic_vector(M01_AXI_ID_WIDTH - 1 downto 0);
--        m03_axi_rresp    => m03_rresp,    -- in std_logic_vector(1 downto 0);
        
--        --
--        -- GT pins
--        -- clk_gt_freerun is a 50MHz free running clock, according to the GT kernel Example Design user guide.
--        -- But it looks like it is configured to be 100MHz in the example designs for all parts except the U280. 
--        clk_freerun => clk100, --  in std_logic; 
--        gt_rxp_in      => "0000", --  in std_logic_vector(3 downto 0);
--        gt_rxn_in      => "1111", -- in std_logic_vector(3 downto 0);
--        gt_txp_out     => open, -- out std_logic_vector(3 downto 0);
--        gt_txn_out     => open, -- out std_logic_vector(3 downto 0);
--        gt_refclk_p    => '0', -- in std_logic;
--        gt_refclk_n    => '1'  -- in std_logic
--    );


    -- Emulate HBM
    -- 3 Gbyte of memory for the first corner turn.
    -- HBM1G_1 : entity correlator_lib.HBM_axi_tbModel
    -- generic map (
    --     AXI_ADDR_WIDTH => 32, -- : integer := 32;   -- Byte address width. This also defines the amount of data. Use the correct width for the HBM memory block, e.g. 28 bits for 256 MBytes.
    --     AXI_ID_WIDTH => 1, -- integer := 1;
    --     AXI_DATA_WIDTH => 512, -- integer := 256;  -- Must be a multiple of 32 bits.
    --     READ_QUEUE_SIZE => 16, --  integer := 16;
    --     MIN_LAG => 60,  -- integer := 80   
    --     INCLUDE_PROTOCOL_CHECKER => TRUE,
    --     RANDSEED => 43526, -- : natural := 12345;
    --     LATENCY_LOW_PROBABILITY => 95, --  natural := 95;   -- probability, as a percentage, that non-zero gaps between read beats will be small (i.e. < 3 clocks)
    --     LATENCY_ZERO_PROBABILITY => 80 -- natural := 80   -- probability, as a percentage, that the gap between read beats will be zero.
    -- ) Port map (
    --     i_clk => ap_clk,
    --     i_rst_n => ap_rst_n,
    --     axi_awaddr => m01_awaddr(31 downto 0),
    --     axi_awid   =>  m01_awid, -- in std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
    --     axi_awlen => m01_awlen,
    --     axi_awsize => m01_awsize,
    --     axi_awburst => m01_awburst,
    --     axi_awlock => m01_awlock,
    --     axi_awcache => m01_awcache,
    --     axi_awprot => m01_awprot,
    --     axi_awqos  => m01_awqos, -- in(3:0)
    --     axi_awregion => m01_awregion, -- in(3:0)
    --     axi_awvalid => m01_awvalid,
    --     axi_awready => m01_awready,
    --     axi_wdata => m01_wdata,
    --     axi_wstrb => m01_wstrb,
    --     axi_wlast => m01_wlast,
    --     axi_wvalid => m01_wvalid,
    --     axi_wready => m01_wready,
    --     axi_bresp => m01_bresp,
    --     axi_bvalid => m01_bvalid,
    --     axi_bready => m01_bready,
    --     axi_bid => m01_bid, -- out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
    --     axi_araddr => m01_araddr(31 downto 0),
    --     axi_arlen => m01_arlen,
    --     axi_arsize => m01_arsize,
    --     axi_arburst => m01_arburst,
    --     axi_arlock => m01_arlock,
    --     axi_arcache => m01_arcache,
    --     axi_arprot => m01_arprot,
    --     axi_arvalid => m01_arvalid,
    --     axi_arready => m01_arready,
    --     axi_arqos => m01_arqos,
    --     axi_arid  => m01_arid,
    --     axi_arregion => m01_arregion,
    --     axi_rdata => m01_rdata,
    --     axi_rresp => m01_rresp,
    --     axi_rlast => m01_rlast,
    --     axi_rvalid => m01_rvalid,
    --     axi_rready => m01_rready
    -- );

    -- -- 6 GBytes second stage corner turn.
    -- HBM6G : entity correlator_lib.HBM_axi_tbModel
    -- generic map (
    --     AXI_ADDR_WIDTH => 33, -- : integer := 32;   -- Byte address width. This also defines the amount of data. Use the correct width for the HBM memory block, e.g. 28 bits for 256 MBytes.
    --     AXI_ID_WIDTH => 1, -- integer := 1;
    --     AXI_DATA_WIDTH => 512, -- integer := 256;  -- Must be a multiple of 32 bits.
    --     READ_QUEUE_SIZE => 16, --  integer := 16;
    --     MIN_LAG => 60,  -- integer := 80   
    --     INCLUDE_PROTOCOL_CHECKER => TRUE,
    --     RANDSEED => 43526, -- : natural := 12345;
    --     LATENCY_LOW_PROBABILITY => 95, --  natural := 95;   -- probability, as a percentage, that non-zero gaps between read beats will be small (i.e. < 3 clocks)
    --     LATENCY_ZERO_PROBABILITY => 80 -- natural := 80   -- probability, as a percentage, that the gap between read beats will be zero.
    -- ) Port map (
    --     i_clk => ap_clk,
    --     i_rst_n => ap_rst_n,
    --     axi_awaddr  => m02_awaddr(32 downto 0),
    --     axi_awid    => m02_awid, -- in std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
    --     axi_awlen   => m02_awlen,
    --     axi_awsize  => m02_awsize,
    --     axi_awburst => m02_awburst,
    --     axi_awlock  => m02_awlock,
    --     axi_awcache => m02_awcache,
    --     axi_awprot  => m02_awprot,
    --     axi_awqos   => m02_awqos, -- in(3:0)
    --     axi_awregion => m02_awregion, -- in(3:0)
    --     axi_awvalid  => m02_awvalid,
    --     axi_awready  => m02_awready,
    --     axi_wdata    => m02_wdata,
    --     axi_wstrb    => m02_wstrb,
    --     axi_wlast    => m02_wlast,
    --     axi_wvalid   => m02_wvalid,
    --     axi_wready   => m02_wready,
    --     axi_bresp    => m02_bresp,
    --     axi_bvalid   => m02_bvalid,
    --     axi_bready   => m02_bready,
    --     axi_bid      => m02_bid, -- out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
    --     axi_araddr   => m02_araddr(32 downto 0),
    --     axi_arlen    => m02_arlen,
    --     axi_arsize   => m02_arsize,
    --     axi_arburst  => m02_arburst,
    --     axi_arlock   => m02_arlock,
    --     axi_arcache  => m02_arcache,
    --     axi_arprot   => m02_arprot,
    --     axi_arvalid  => m02_arvalid,
    --     axi_arready  => m02_arready,
    --     axi_arqos    => m02_arqos,
    --     axi_arid     => m02_arid,
    --     axi_arregion => m02_arregion,
    --     axi_rdata    => m02_rdata,
    --     axi_rresp    => m02_rresp,
    --     axi_rlast    => m02_rlast,
    --     axi_rvalid   => m02_rvalid,
    --     axi_rready   => m02_rready
    -- );
 
    -- -- 512 MByte visibilities buffer
    -- HBM512M : entity correlator_lib.HBM_axi_tbModel
    -- generic map (
    --     AXI_ADDR_WIDTH => 29, -- : integer := 32;   -- Byte address width. This also defines the amount of data. Use the correct width for the HBM memory block, e.g. 28 bits for 256 MBytes.
    --     AXI_ID_WIDTH => 1, -- integer := 1;
    --     AXI_DATA_WIDTH => 512, -- integer := 256;  -- Must be a multiple of 32 bits.
    --     READ_QUEUE_SIZE => 16, --  integer := 16;
    --     MIN_LAG => 60,  -- integer := 80   
    --     INCLUDE_PROTOCOL_CHECKER => TRUE,
    --     RANDSEED => 43526, -- : natural := 12345;
    --     LATENCY_LOW_PROBABILITY => 95, --  natural := 95;   -- probability, as a percentage, that non-zero gaps between read beats will be small (i.e. < 3 clocks)
    --     LATENCY_ZERO_PROBABILITY => 80 -- natural := 80   -- probability, as a percentage, that the gap between read beats will be zero.
    -- ) Port map (
    --     i_clk => ap_clk,
    --     i_rst_n => ap_rst_n,
    --     axi_awaddr  => m03_awaddr(28 downto 0),
    --     axi_awid    => m03_awid, -- in std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
    --     axi_awlen   => m03_awlen,
    --     axi_awsize  => m03_awsize,
    --     axi_awburst => m03_awburst,
    --     axi_awlock  => m03_awlock,
    --     axi_awcache => m03_awcache,
    --     axi_awprot  => m03_awprot,
    --     axi_awqos   => m03_awqos, -- in(3:0)
    --     axi_awregion => m03_awregion, -- in(3:0)
    --     axi_awvalid  => m03_awvalid,
    --     axi_awready  => m03_awready,
    --     axi_wdata    => m03_wdata,
    --     axi_wstrb    => m03_wstrb,
    --     axi_wlast    => m03_wlast,
    --     axi_wvalid   => m03_wvalid,
    --     axi_wready   => m03_wready,
    --     axi_bresp    => m03_bresp,
    --     axi_bvalid   => m03_bvalid,
    --     axi_bready   => m03_bready,
    --     axi_bid      => m03_bid, -- out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
    --     axi_araddr   => m03_araddr(28 downto 0),
    --     axi_arlen    => m03_arlen,
    --     axi_arsize   => m03_arsize,
    --     axi_arburst  => m03_arburst,
    --     axi_arlock   => m03_arlock,
    --     axi_arcache  => m03_arcache,
    --     axi_arprot   => m03_arprot,
    --     axi_arvalid  => m03_arvalid,
    --     axi_arready  => m03_arready,
    --     axi_arqos    => m03_arqos,
    --     axi_arid     => m03_arid,
    --     axi_arregion => m03_arregion,
    --     axi_rdata    => m03_rdata,
    --     axi_rresp    => m03_rresp,
    --     axi_rlast    => m03_rlast,
    --     axi_rvalid   => m03_rvalid,
    --     axi_rready   => m03_rready
    -- );

end Behavioral;
