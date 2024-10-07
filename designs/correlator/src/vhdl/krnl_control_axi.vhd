----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey
-- 
-- Create Date: 21.08.2020 23:35:08
-- Module Name: krnl_control_axi - Behavioral
-- Description: 
--  Translation from verilog due to weird problem with packaging.
-- 
--//------------------------Address Info-------------------
--// 0x00 : Control signals
--//        bit 0  - ap_start (Read/Write/COH)
--//        bit 1  - ap_done (Read/COR)
--//        bit 2  - ap_idle (Read)
--//        bit 3  - ap_ready (Read)
--//        bit 7  - auto_restart (Read/Write)
--//        others - reserved
--// 0x04 : Global Interrupt Enable Register
--//        bit 0  - Global Interrupt Enable (Read/Write)
--//        others - reserved
--// 0x08 : IP Interrupt Enable Register (Read/Write)
--//        bit 0  - Channel 0 (ap_done)
--//        bit 1  - Channel 1 (ap_ready)
--//        others - reserved
--// 0x0c : IP Interrupt Status Register (Read/TOW)
--//        bit 0  - Channel 0 (ap_done)
--//        bit 1  - Channel 1 (ap_ready)
--//        others - reserved
--// 0x10 : DMA Source address bits(31:0). This is an ARGS address, so it 32 
--// 0x14 : DMA destination address bits(63:32)
--// 0x18 : DMA Shared memory address bits(31:0)
--// 0x1c : DMA shared memory address bits(63:32)
--// 0x20 : DMA length. 32 bits.
--// 0x24 : HBM base address for the first corner turn, bits 31:0
--// 0x28 : HBM base address for the first corner turn, bits 63:32
--// 0x2C : HBM base address for the second corner turn, bits 31:0
--// 0x30 : HBM base address for the second corner turn, bits 63:32
--// (SC = Self Clear, COR = Clear on Read, TOW = Toggle on Write, COH = Clear on Handshake)
--
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity krnl_control_axi is
    generic (
        C_S_AXI_ADDR_WIDTH : integer := 7;
        C_S_AXI_DATA_WIDTH : integer := 32
    );
    Port (
        ACLK : in std_logic; -- put  wire                          ACLK,
        ARESET : in std_logic; -- input  wire                          ARESET,
        AWADDR : in std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);  -- input  wire [C_S_AXI_ADDR_WIDTH-1:0] AWADDR,
        AWVALID : in std_logic; --  input  wire                          AWVALID,
        AWREADY : out std_logic; -- output wire                          AWREADY,
        WDATA : in std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0); --  input  wire [C_S_AXI_DATA_WIDTH-1:0] WDATA,
        WSTRB : in std_logic_vector(C_S_AXI_DATA_WIDTH/8-1 downto 0); -- input  wire [C_S_AXI_DATA_WIDTH/8-1:0] WSTRB,
        WVALID : in std_logic; --  input  wire                          WVALID,
        WREADY : out std_logic; -- output wire                          WREADY,
        BRESP : out std_logic_vector(1 downto 0); -- output wire [1:0]                    BRESP,
        BVALID : out std_logic; -- : output wire                          BVALID,
        BREADY : in std_logic; -- input  wire                          BREADY,
        ARADDR : in std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0); -- input  wire [C_S_AXI_ADDR_WIDTH-1:0] ARADDR,
        ARVALID : in std_logic; -- input  wire                          ARVALID,
        ARREADY : out std_logic; -- output wire                          ARREADY,
        RDATA : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0); -- output wire [C_S_AXI_DATA_WIDTH-1:0] RDATA,
        RRESP : out std_logic_vector(1 downto 0);  -- output wire [1:0]                    RRESP,
        RVALID : out std_logic; -- output wire                          RVALID,
        RREADY : in std_logic; -- input  wire                          RREADY,
        interrupt : out std_logic; -- output wire                          interrupt,
        -- user signals
        ap_start : out std_logic; -- output wire                          ap_start,
        ap_done : in std_logic; -- input  wire                          ap_done,
        ap_ready : in std_logic; -- input  wire                          ap_ready,
        ap_idle : in std_logic; -- input  wire                          ap_idle,
        dma_src : out std_logic_vector(31 downto 0);     --  dma_src,
        dma_dest : out std_logic_vector(31 downto 0);    --  dma_dest,
        dma_shared : out std_logic_vector(63 downto 0);  --  dma_shared,
        dma_size : out std_logic_vector(31 downto 0);    --  dma_size
        m01_shared : out std_logic_vector(63 downto 0);  --  Memory address to use for filterbank corner turn
        m02_shared : out std_logic_vector(63 downto 0);
        m03_shared : out std_logic_vector(63 downto 0);
        m04_shared : out std_logic_vector(63 downto 0);
        m05_shared : out std_logic_vector(63 downto 0);
        m06_shared : out std_logic_vector(63 downto 0)
    );
end krnl_control_axi;

architecture Behavioral of krnl_control_axi is

    constant ADDR_AP_CTRL      : std_logic_vector(6 downto 0) := "0000000";
    constant ADDR_GIE          : std_logic_vector(6 downto 0) := "0000100";
    constant ADDR_IER          : std_logic_vector(6 downto 0) := "0001000";
    constant ADDR_ISR          : std_logic_vector(6 downto 0) := "0001100";
    constant ADDR_DMA_SRC_0    : std_logic_vector(6 downto 0) := "0010000";
    constant ADDR_DMA_DEST_0   : std_logic_vector(6 downto 0) := "0010100";
    constant ADDR_DMA_SHARED_0 : std_logic_vector(6 downto 0) := "0011000";
    constant ADDR_DMA_SHARED_1 : std_logic_vector(6 downto 0) := "0011100";
    constant ADDR_DMA_SIZE     : std_logic_vector(6 downto 0) := "0100000";
    constant ADDR_M01_SHARED_0 : std_logic_vector(6 downto 0) := "0100100";
    constant ADDR_M01_SHARED_1 : std_logic_vector(6 downto 0) := "0101000";
    constant ADDR_M02_SHARED_0 : std_logic_vector(6 downto 0) := "0101100";
    constant ADDR_M02_SHARED_1 : std_logic_vector(6 downto 0) := "0110000";
    constant ADDR_M03_SHARED_0 : std_logic_vector(6 downto 0) := "0110100";
    constant ADDR_M03_SHARED_1 : std_logic_vector(6 downto 0) := "0111000";
    constant ADDR_M04_SHARED_0 : std_logic_vector(6 downto 0) := "0111100";
    constant ADDR_M04_SHARED_1 : std_logic_vector(6 downto 0) := "1000000";
    constant ADDR_M05_SHARED_0 : std_logic_vector(6 downto 0) := "1000100";
    constant ADDR_M05_SHARED_1 : std_logic_vector(6 downto 0) := "1001000";
    constant ADDR_M06_SHARED_0 : std_logic_vector(6 downto 0) := "1001100";
    constant ADDR_M06_SHARED_1 : std_logic_vector(6 downto 0) := "1010000";
    
    type wr_fsm_type is (wrIdle, wrData, wrResp);
    type rd_fsm_type is (rdIdle, rdData);
    signal wstate : wr_fsm_type := wrIdle;
    signal rstate : rd_fsm_type := rdIdle;
    constant ADDR_BITS : integer := 7;
    
    signal waddr : std_logic_vector(ADDR_BITS-1 downto 0);
    signal wmask : std_logic_vector(31 downto 0);
    signal aw_hs : std_logic;
    signal w_hs : std_logic;
    signal ar_hs : std_logic;
    signal raddr : std_logic_vector(ADDR_BITS-1 downto 0);
    -- internal registers
    signal int_ap_idle : std_logic;
    signal int_ap_ready : std_logic;
    signal int_ap_done : std_logic := '0';
    signal int_ap_start : std_logic := '0';
    signal int_auto_restart : std_logic := '0';
    signal int_gie : std_logic := '0';
    signal int_ier : std_logic_vector(1 downto 0) := "00";
    signal int_isr : std_logic_vector(1 downto 0) := "00";
    signal int_dma_src : std_logic_vector(31 downto 0) := (others => '0');
    signal int_dma_dest : std_logic_vector(31 downto 0) := (others => '0');
    signal int_dma_shared : std_logic_vector(63 downto 0) := (others => '0');
    signal int_dma_size : std_logic_vector(31 downto 0) := (others => '0');
    signal int_m01_shared : std_logic_vector(63 downto 0) := (others => '0');
    signal int_m02_shared : std_logic_vector(63 downto 0) := (others => '0');
    signal int_m03_shared : std_logic_vector(63 downto 0) := (others => '0');
    signal int_m04_shared : std_logic_vector(63 downto 0) := (others => '0');
    signal int_m05_shared : std_logic_vector(63 downto 0) := (others => '0');
    signal int_m06_shared : std_logic_vector(63 downto 0) := (others => '0');
    signal AWREADYint : std_logic;
    signal ARREADYint : std_logic;
    signal WreadyInt : std_logic;
    signal RVALIDInt : std_logic;

begin

    --------------------------AXI write fsm------------------
    AWREADYint <= '1' when ARESET = '0' and wstate = wrIdle else '0'; -- (not ARESET) and (wstate == WRIDLE);
    AWREADY <= AWREADYint;
    WREADYint <= '1' when (wstate = WRDATA) else '0';
    WREADY <= WREADYint;
    BRESP   <= "00"; -- 2'b00;  // OKAY
    BVALID  <= '1' when (wstate = WRRESP) else '0';
    --wmask   = { {8{WSTRB[3]}}, {8{WSTRB[2]}}, {8{WSTRB[1]}}, {8{WSTRB[0]}} };
    wmask(31 downto 24) <= WSTRB(3) & WSTRB(3) & WSTRB(3) & WSTRB(3) & WSTRB(3) & WSTRB(3) & WSTRB(3) & WSTRB(3);
    wmask(23 downto 16) <= WSTRB(2) & WSTRB(2) & WSTRB(2) & WSTRB(2) & WSTRB(2) & WSTRB(2) & WSTRB(2) & WSTRB(2);
    wmask(15 downto 8) <= WSTRB(1) & WSTRB(1) & WSTRB(1) & WSTRB(1) & WSTRB(1) & WSTRB(1) & WSTRB(1) & WSTRB(1);
    wmask(7 downto 0) <= WSTRB(0) & WSTRB(0) & WSTRB(0) & WSTRB(0) & WSTRB(0) & WSTRB(0) & WSTRB(0) & WSTRB(0);
    
    aw_hs   <= AWVALID and AWREADYint;
    w_hs   <= WVALID and WREADYint;

    --// wstate
    process(ACLK)
    begin
        if rising_edge(ACLK) then
            if ARESET = '1' then
                wstate <= wrIdle;
            else
                case wstate is
                    when wrIdle =>
                        if AWValid = '1' then
                            wstate <= wrData;
                        end if;
                    when wrData =>
                        if (wvalid = '1') then
                            wstate <= wrResp;
                        end if;
                    when wrResp =>
                        if Bready = '1' then
                            wstate <= wrIdle;
                        end if;
                    when others =>
                        wstate <= wrIdle;
                end case;
            end if;
            
            waddr <= AWADDR(addr_bits-1 downto 0);
        end if;
    end process;



    ------------------------AXI read fsm-------------------
    --assign ARREADY = (~ARESET) && (rstate == RDIDLE);
    ARREADYint <= '1' when (ARESET = '0' and rstate = rdIdle) else '0';
    ARREADY <= ARREADYint;
    --RDATA   = rdata;
    RRESP   <= "00"; -- 2'b00;  // OKAY
    RVALIDint  <= '1' when (rstate = RDDATA) else '0';
    Rvalid <= RVALIDInt;
    ar_hs   <= ARVALID and ARREADYint;
    raddr   <= ARADDR(ADDR_BITS-1 downto 0);

    --// rstate
    process(ACLK)
    begin
        if rising_edge(ACLK) then
            if ARESET = '1' then
                rstate <= RDIDLE;
            else
                case rstate is
                    when RDIdle =>
                        if (ARVALID = '1') then
                            rstate <= RDDATA;
                        end if;
                    when RDDATA =>
                        if (RREADY = '1' and RVALIDInt = '1') then
                            rstate <= RDIDLE;
                        end if;
                    when others => 
                        rstate <= RDIDLE;                    
                    
                end case;
            end if;
            
            rdata <= (others => '0');
            if ar_hs = '1' then
                case raddr is
                    when ADDR_AP_CTRL =>
                        rdata(0) <= int_ap_start;
                        rdata(1) <= int_ap_done;
                        rdata(2) <= int_ap_idle;
                        rdata(3) <= int_ap_ready;
                        rdata(7) <= int_auto_restart;
                    when ADDR_GIE =>
                        rdata(0) <= int_gie;
                    when ADDR_IER =>
                        rdata(1 downto 0) <= int_ier;
                    when ADDR_ISR =>
                        rdata(1 downto 0) <= int_isr;
                    when ADDR_DMA_SRC_0 =>
                        rdata <= int_dma_src(31 downto 0);
                    when ADDR_DMA_DEST_0 =>
                        rdata <= int_dma_dest(31 downto 0);
                    when ADDR_DMA_SHARED_0 =>
                        rdata <= int_dma_shared(31 downto 0);
                    when ADDR_DMA_SHARED_1 =>
                        rdata <= int_dma_shared(63 downto 32);
                    when ADDR_DMA_SIZE => 
                        rdata <= int_dma_size(31 downto 0);
                    when ADDR_M01_SHARED_0 =>
                        rdata <= int_m01_shared(31 downto 0);
                    when ADDR_M01_SHARED_1 =>
                        rdata <= int_m01_shared(63 downto 32);
                    when ADDR_M02_SHARED_0 =>
                        rdata <= int_m02_shared(31 downto 0);
                    when ADDR_M02_SHARED_1 =>
                        rdata <= int_m02_shared(63 downto 32);
                    when ADDR_M03_SHARED_0 =>
                        rdata <= int_m03_shared(31 downto 0);
                    when ADDR_M03_SHARED_1 =>
                        rdata <= int_m03_shared(63 downto 32);
                    when ADDR_M04_SHARED_0 =>
                        rdata <= int_m04_shared(31 downto 0);
                    when ADDR_M04_SHARED_1 =>
                        rdata <= int_m04_shared(63 downto 32);
                    when ADDR_M05_SHARED_0 =>
                        rdata <= int_m05_shared(31 downto 0);
                    when ADDR_M05_SHARED_1 =>
                        rdata <= int_m05_shared(63 downto 32);
                    when ADDR_M06_SHARED_0 =>
                        rdata <= int_m06_shared(31 downto 0);
                    when ADDR_M06_SHARED_1 =>
                        rdata <= int_m06_shared(63 downto 32);
                    when others =>
                        rdata <= (others => '0');
                end case;
            end if;
          
            -- int_ap_start
            if (ARESET = '1') then
                int_ap_start <= '0'; -- 1'b0;
            elsif (w_hs = '1' and (waddr = ADDR_AP_CTRL) and (WSTRB(0) = '1' and WDATA(0) = '1')) then
                int_ap_start <= '1'; -- 1'b1;
            elsif (int_ap_ready = '1') then
                int_ap_start <= int_auto_restart; --// clear on handshake/auto restart
            end if;
            
            -- int_auto_restart
            if (ARESET = '1') then
                int_auto_restart <= '0'; -- 1'b0;
            elsif (w_hs = '1' and (waddr = ADDR_AP_CTRL) and WSTRB(0) = '1') then
                int_auto_restart <=  WDATA(7);
            end if;

            -- int_ap_done
            if (ARESET = '1') then
                int_ap_done <= '0'; -- 1'b0;
            elsif (ap_done = '1') then
                int_ap_done <= '1'; -- 1'b1;
            elsif (ar_hs = '1' and (raddr = ADDR_AP_CTRL)) then
                int_ap_done <= '0'; -- 1'b0; // clear on read
            end if;
            
            -- int_gie
            if (ARESET = '1') then
                int_gie <= '0'; -- 1'b0;
            elsif (w_hs = '1' and (waddr = ADDR_GIE) and WSTRB(0) = '1') then
                int_gie <= WDATA(0);
            end if;
        
            -- int_ier
            if (ARESET = '1') then
                int_ier <= "00"; -- 1'b0;
            elsif (w_hs = '1' and (waddr = ADDR_IER) and (WSTRB(0) = '1')) then
                int_ier <= WDATA(1 downto 0);
            end if;
        
            -- int_isr[0]
            if (ARESET = '1') then
                int_isr(0) <= '0'; -- 1'b0;
            elsif (int_ier(0) = '1' and ap_done = '1') then
                int_isr(0) <= '1'; -- 1'b1;
            elsif (w_hs = '1' and (waddr = ADDR_ISR) and (WSTRB(0) = '1')) then
                int_isr(0) <= int_isr(0) xor WDATA(0); -- // toggle on write
            end if;
        
            -- int_isr[1]
            if (ARESET = '1') then
                int_isr(1) <= '0'; -- 1'b0;
            elsif (int_ier(1) = '1' and ap_ready = '1') then
                int_isr(1) <= '1'; -- 1'b1;
            elsif (w_hs = '1' and (waddr = ADDR_ISR) and WSTRB(0) = '1') then
                int_isr(1) <= int_isr(1) xor WDATA(1); -- // toggle on write
            end if;
        
            -- int_dma_src[31:0]
            if (ARESET = '1') then
                int_dma_src(31 downto 0) <= (others => '0');
            elsif (w_hs = '1' and (waddr = ADDR_DMA_SRC_0)) then
                int_dma_src(31 downto 0) <= (WDATA(31 downto 0) and wmask) or (int_dma_src(31 downto 0) and (not wmask));
            end if;
            
            -- int_dma_dest[31:0]
            if (ARESET = '1') then
                int_dma_dest(31 downto 0) <= (others => '0');
            elsif (w_hs = '1' and (waddr = ADDR_DMA_DEST_0)) then
                int_dma_dest(31 downto 0) <= (WDATA(31 downto 0) and wmask) or (int_dma_dest(31 downto 0) and (not wmask));
            end if;
            
            --// int_dma_shared[31:0]
            if (ARESET = '1') then
                int_dma_shared(31 downto 0) <= (others => '0');
            elsif (w_hs = '1' and (waddr = ADDR_DMA_SHARED_0)) then
                int_dma_shared(31 downto 0) <= (WDATA(31 downto 0) and wmask) or (int_dma_shared(31 downto 0) and (not wmask));
            end if;
            
            -- int_dma_shared[63:32]
            if (ARESET = '1') then
                int_dma_shared(63 downto 32) <= (others => '0');
            elsif (w_hs = '1' and (waddr = ADDR_DMA_SHARED_1)) then
                int_dma_shared(63 downto 32) <= (WDATA(31 downto 0) and wmask) or (int_dma_shared(63 downto 32) and (not wmask));
            end if;
            
            --// int_dma_size[31:0]
            if (ARESET = '1') then
                int_dma_size(31 downto 0) <= (others => '0');
            elsif (w_hs = '1' and (waddr = ADDR_DMA_SIZE)) then
                int_dma_size(31 downto 0) <= (WDATA(31 downto 0) and wmask) or (int_dma_size(31 downto 0) and (not wmask));
            end if;
            
            -- 
            if (ARESET = '1') then
                int_m01_shared(31 downto 0) <= (others => '0');
            elsif (w_hs = '1' and (waddr = ADDR_M01_SHARED_0)) then
                int_m01_shared(31 downto 0) <= (WDATA(31 downto 0) and wmask) or (int_m01_shared(31 downto 0) and (not wmask));
            end if;
            
            -- int_dma_shared[63:32]
            if (ARESET = '1') then
                int_m01_shared(63 downto 32) <= (others => '0');
            elsif (w_hs = '1' and (waddr = ADDR_M01_SHARED_1)) then
                int_m01_shared(63 downto 32) <= (WDATA(31 downto 0) and wmask) or (int_m01_shared(63 downto 32) and (not wmask));
            end if;
            
            -- m02_shared
            if (ARESET = '1') then
                int_m02_shared(31 downto 0) <= (others => '0');
            elsif (w_hs = '1' and (waddr = ADDR_M02_SHARED_0)) then
                int_m02_shared(31 downto 0) <= (WDATA(31 downto 0) and wmask) or (int_m02_shared(31 downto 0) and (not wmask));
            end if;
            if (ARESET = '1') then
                int_m02_shared(63 downto 32) <= (others => '0');
            elsif (w_hs = '1' and (waddr = ADDR_M02_SHARED_1)) then
                int_m02_shared(63 downto 32) <= (WDATA(31 downto 0) and wmask) or (int_m02_shared(63 downto 32) and (not wmask));
            end if;

            -- m03_shared
            if (ARESET = '1') then
                int_m03_shared(31 downto 0) <= (others => '0');
            elsif (w_hs = '1' and (waddr = ADDR_M03_SHARED_0)) then
                int_m03_shared(31 downto 0) <= (WDATA(31 downto 0) and wmask) or (int_m03_shared(31 downto 0) and (not wmask));
            end if;
            if (ARESET = '1') then
                int_m03_shared(63 downto 32) <= (others => '0');
            elsif (w_hs = '1' and (waddr = ADDR_M03_SHARED_1)) then
                int_m03_shared(63 downto 32) <= (WDATA(31 downto 0) and wmask) or (int_m03_shared(63 downto 32) and (not wmask));
            end if;
            
            -- m04_shared
            if (ARESET = '1') then
                int_m04_shared(31 downto 0) <= (others => '0');
            elsif (w_hs = '1' and (waddr = ADDR_M04_SHARED_0)) then
                int_m04_shared(31 downto 0) <= (WDATA(31 downto 0) and wmask) or (int_m04_shared(31 downto 0) and (not wmask));
            end if;
            if (ARESET = '1') then
                int_m04_shared(63 downto 32) <= (others => '0');
            elsif (w_hs = '1' and (waddr = ADDR_M04_SHARED_1)) then
                int_m04_shared(63 downto 32) <= (WDATA(31 downto 0) and wmask) or (int_m04_shared(63 downto 32) and (not wmask));
            end if;
        
            -- m05_shared
            if (ARESET = '1') then
                int_m05_shared(31 downto 0) <= (others => '0');
            elsif (w_hs = '1' and (waddr = ADDR_M05_SHARED_0)) then
                int_m05_shared(31 downto 0) <= (WDATA(31 downto 0) and wmask) or (int_m05_shared(31 downto 0) and (not wmask));
            end if;
            if (ARESET = '1') then
                int_m05_shared(63 downto 32) <= (others => '0');
            elsif (w_hs = '1' and (waddr = ADDR_M05_SHARED_1)) then
                int_m05_shared(63 downto 32) <= (WDATA(31 downto 0) and wmask) or (int_m05_shared(63 downto 32) and (not wmask));
            end if;
            
            -- m05_shared
            if (ARESET = '1') then
                int_m06_shared(31 downto 0) <= (others => '0');
            elsif (w_hs = '1' and (waddr = ADDR_M06_SHARED_0)) then
                int_m06_shared(31 downto 0) <= (WDATA(31 downto 0) and wmask) or (int_m06_shared(31 downto 0) and (not wmask));
            end if;
            if (ARESET = '1') then
                int_m06_shared(63 downto 32) <= (others => '0');
            elsif (w_hs = '1' and (waddr = ADDR_M06_SHARED_1)) then
                int_m06_shared(63 downto 32) <= (WDATA(31 downto 0) and wmask) or (int_m06_shared(63 downto 32) and (not wmask));
            end if;
            
        end if;
    end process;
    
    interrupt    <= int_gie and (int_isr(0) or int_isr(1));
    ap_start     <= int_ap_start;
    int_ap_idle  <= ap_idle;
    int_ap_ready <= ap_ready;
    dma_src      <= int_dma_src;
    dma_dest     <= int_dma_dest;
    dma_shared   <= int_dma_shared;
    dma_size     <= int_dma_size;
    m01_shared   <= int_m01_shared;
    m02_shared   <= int_m02_shared;
    m03_shared   <= int_m03_shared;
    m04_shared   <= int_m04_shared;
    m05_shared   <= int_m05_shared;
    m06_shared   <= int_m06_shared;
    
end Behavioral;
