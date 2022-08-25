----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 17.08.2020 16:06:42
-- Module Name: cdma_wrapper - Behavioral 
-- Description: 
--   Wrapper for CDMA core; puts in a source, destination address and size, and waits
-- until it the transaction is complete. 
-- 
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
--use IEEE.NUMERIC_STD.ALL;
library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
USE axi4_lib.axi4_full_pkg.ALL;

entity cdma_wrapper is
    Port(
        i_clk      : in std_logic;
        i_rst      : in std_logic;
        i_srcAddr  : in std_logic_vector(31 downto 0);  -- byte address of the source data
        i_destAddr : in std_logic_vector(31 downto 0);  -- byte address for the data to be copied to
        i_size     : in std_logic_vector(31 downto 0);  -- Bytes to copy.
        i_start    : in std_logic;
        o_idle     : out std_logic; -- High whenever not busy.
        o_done     : out std_logic; -- Pulses high to indicate transaction is complete.
        o_status   : out std_logic_vector(14 downto 0);  -- status register in the cdma core, read after the command is complete.
        -- AXI master 
        o_AXI_mosi   : out t_axi4_full_mosi;
        i_AXI_miso   : in t_axi4_full_miso
    );
end cdma_wrapper;

architecture Behavioral of cdma_wrapper is

    type ctrl_fsm_type is (idle, wr_control, wr_control_wait, wr_src_addr, wr_src_addr_wait, wr_dest_addr, wr_dest_addr_wait,
                           wr_size, wr_size_wait, get_status, get_status_wait, clear_irq, clear_irq_wait,  wait_done,
                           issue_soft_reset, soft_reset_wait);
    signal ctrl_fsm : ctrl_fsm_type := idle;

    signal resetn : std_logic := '0';

    signal s_axi_lite_bready : std_logic;
    signal s_axi_lite_bvalid : std_logic;
    signal s_axi_lite_bresp : std_logic_vector(1 downto 0);
 
    signal s_axi_lite_awvalid : std_logic;
    signal s_axi_lite_awaddr : std_logic_vector(5 downto 0);
    signal s_axi_lite_wvalid : std_logic;
    signal s_axi_lite_wdata : std_logic_vector(31 downto 0);
    signal s_axi_lite_awready : std_logic;
    signal s_axi_lite_wready : std_logic;
 
    signal cdma_introut : std_logic;


    signal s_axi_lite_arready : std_logic;
    signal s_axi_lite_arvalid : std_logic;
    signal s_axi_lite_araddr : std_logic_vector(5 downto 0);
    signal s_axi_lite_rready : std_logic;
    signal s_axi_lite_rvalid : std_logic;
    signal s_axi_lite_rdata : std_logic_vector(31 downto 0);
    signal s_axi_lite_rresp : std_logic_vector(1 downto 0);
    signal status : std_logic_vector(14 downto 0);

    COMPONENT axi_cdma_0
    PORT (
        m_axi_aclk : IN STD_LOGIC;
        s_axi_lite_aclk : IN STD_LOGIC;
        s_axi_lite_aresetn : IN STD_LOGIC;
        cdma_introut : OUT STD_LOGIC;
        s_axi_lite_awready : OUT STD_LOGIC;
        s_axi_lite_awvalid : IN STD_LOGIC;
        s_axi_lite_awaddr : IN STD_LOGIC_VECTOR(5 DOWNTO 0);
        s_axi_lite_wready : OUT STD_LOGIC;
        s_axi_lite_wvalid : IN STD_LOGIC;
        s_axi_lite_wdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
        s_axi_lite_bready : IN STD_LOGIC;
        s_axi_lite_bvalid : OUT STD_LOGIC;
        s_axi_lite_bresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        s_axi_lite_arready : OUT STD_LOGIC;
        s_axi_lite_arvalid : IN STD_LOGIC;
        s_axi_lite_araddr : IN STD_LOGIC_VECTOR(5 DOWNTO 0);
        s_axi_lite_rready : IN STD_LOGIC;
        s_axi_lite_rvalid : OUT STD_LOGIC;
        s_axi_lite_rdata : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
        s_axi_lite_rresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_arready : IN STD_LOGIC;
        m_axi_arvalid : OUT STD_LOGIC;
        m_axi_araddr : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
        m_axi_arlen : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
        m_axi_arsize : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        m_axi_arburst : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_arprot : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        m_axi_arcache : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        m_axi_rready : OUT STD_LOGIC;
        m_axi_rvalid : IN STD_LOGIC;
        m_axi_rdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
        m_axi_rresp : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_rlast : IN STD_LOGIC;
        m_axi_awready : IN STD_LOGIC;
        m_axi_awvalid : OUT STD_LOGIC;
        m_axi_awaddr : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
        m_axi_awlen : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
        m_axi_awsize : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        m_axi_awburst : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_awprot : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        m_axi_awcache : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        m_axi_wready : IN STD_LOGIC;
        m_axi_wvalid : OUT STD_LOGIC;
        m_axi_wdata : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
        m_axi_wstrb : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        m_axi_wlast : OUT STD_LOGIC;
        m_axi_bready : OUT STD_LOGIC;
        m_axi_bvalid : IN STD_LOGIC;
        m_axi_bresp : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        cdma_tvect_out : OUT STD_LOGIC_VECTOR(31 DOWNTO 0));
    END COMPONENT;
    
begin
    
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            resetn <= not i_rst;
            
            if ctrl_fsm = idle then
                o_idle <= '1';
            else
                o_idle <= '0';
            end if;
            
            if ctrl_fsm = wait_done and cdma_introut = '1' then
                o_done <= '1';
            else
                o_done <= '0';
            end if;
            
            o_status <= status;
            
            if resetn = '0' then
                ctrl_fsm <= idle;
                status <= (others => '0');
            else
                case ctrl_fsm is
                    when idle =>
                        s_axi_lite_arvalid <= '0';
                        s_axi_lite_awvalid <= '0';
                        s_axi_lite_wvalid <= '0';
                        s_axi_lite_awaddr <= "000000";
                        s_axi_lite_wdata <= (others => '0');
                        if i_start = '1' then
                            ctrl_fsm <= wr_control;
                        end if;

                    when wr_control =>
                        s_axi_lite_awvalid <= '1';
                        s_axi_lite_awaddr <= "000000";  -- 0x0 = control register address
                        s_axi_lite_wvalid <= '1';
                        s_axi_lite_wdata <= "00000000000000010001000000000000";
                        ctrl_fsm <= wr_control_wait;
                        
                    when wr_control_wait =>
                        if s_axi_lite_awready = '1' then
                            s_axi_lite_awvalid <= '0';
                        end if;
                        if s_axi_lite_wready = '1' then
                            s_axi_lite_wvalid <= '0';
                        end if;
                        if s_axi_lite_awvalid = '0' and s_axi_lite_wvalid = '0' then                    
                            ctrl_fsm <= wr_src_addr;
                        end if;
                
                    when wr_src_addr =>
                        s_axi_lite_awvalid <= '1';
                        s_axi_lite_awaddr <= "011000";  -- 0x18 = source address
                        s_axi_lite_wvalid <= '1';
                        s_axi_lite_wdata <= i_srcAddr;
                        ctrl_fsm <= wr_src_addr_wait;
                    
                    when wr_src_addr_wait =>
                        if s_axi_lite_awready = '1' then
                            s_axi_lite_awvalid <= '0';
                        end if;
                        if s_axi_lite_wready = '1' then
                            s_axi_lite_wvalid <= '0';
                        end if;
                        if s_axi_lite_awvalid = '0' and s_axi_lite_wvalid = '0' then
                            ctrl_fsm <= wr_dest_addr;
                        end if;
                    
                    when wr_dest_addr =>
                        s_axi_lite_awvalid <= '1';
                        s_axi_lite_awaddr <= "100000";  -- 0x20 = destination address
                        s_axi_lite_wvalid <= '1';
                        s_axi_lite_wdata <= i_destAddr;
                        ctrl_fsm <= wr_dest_addr_wait;
                    
                    when wr_dest_addr_wait =>
                        if s_axi_lite_awready = '1' then
                            s_axi_lite_awvalid <= '0';
                        end if;
                        if s_axi_lite_wready = '1' then
                            s_axi_lite_wvalid <= '0';
                        end if;
                        if s_axi_lite_awvalid = '0' and s_axi_lite_wvalid = '0' then
                            ctrl_fsm <= wr_size;
                        end if;
                
                    when wr_size =>
                        s_axi_lite_awvalid <= '1';
                        s_axi_lite_awaddr <= "101000";  -- 0x28 = number of bytes to transfer
                        s_axi_lite_wvalid <= '1';
                        s_axi_lite_wdata <= i_size;
                        ctrl_fsm <= wr_size_wait;
                
                    when wr_size_wait =>
                        if s_axi_lite_awready = '1' then
                            s_axi_lite_awvalid <= '0';
                        end if;
                        if s_axi_lite_wready = '1' then
                            s_axi_lite_wvalid <= '0';
                        end if;
                        if s_axi_lite_awvalid = '0' and s_axi_lite_wvalid = '0' then
                            ctrl_fsm <= wait_done;
                        end if;                   
                
                    when wait_done =>
                        s_axi_lite_arvalid <= '0';
                        if cdma_introut = '1' then 
                            ctrl_fsm <= get_status;
                        end if;
                   
                    when get_status => -- check the status register 
                        s_axi_lite_arvalid <= '1';
                        ctrl_fsm <= get_status_wait;
                        
                    when get_status_wait =>
                        if s_axi_lite_rvalid = '1' then
                            status <= s_axi_lite_rdata(14 downto 0);
                            s_axi_lite_arvalid <= '0';
                            ctrl_fsm <= clear_irq;
                        end if;
                    
                    when clear_irq =>
                        s_axi_lite_awvalid <= '1';
                        s_axi_lite_awaddr <= "000100";  -- 0x4 = status register
                        s_axi_lite_wvalid <= '1';
                        s_axi_lite_wdata(31 downto 16) <= x"0000";
                        s_axi_lite_wdata(15) <= '0';
                        s_axi_lite_wdata(14 downto 12) <= "111"; -- clear all interrupts
                        s_axi_lite_wdata(11 downto 0) <= x"000";
                        ctrl_fsm <= clear_irq_wait;
                    
                    when clear_irq_wait =>
                        if s_axi_lite_awready = '1' then
                            s_axi_lite_awvalid <= '0';
                        end if;
                        if s_axi_lite_wready = '1' then
                            s_axi_lite_wvalid <= '0';
                        end if;
                        if s_axi_lite_awvalid = '0' and s_axi_lite_wvalid = '0' then
                            if status(4) = '1' or status(5) = '1' or status(6) = '1' then
                                -- there was an error; issue a soft reset of the cdma core
                                ctrl_fsm <= issue_soft_reset;
                            else
                                ctrl_fsm <= idle;
                            end if;
                        end if;
                    
                    when issue_soft_reset => 
                        s_axi_lite_awvalid <= '1';
                        s_axi_lite_awaddr <= "000000";  -- 0x0 = control register
                        s_axi_lite_wvalid <= '1';
                        s_axi_lite_wdata <= "00000000000000010001000000000100"; -- bit 2 = reset.
                        ctrl_fsm <= soft_reset_wait;
                    
                    when soft_reset_wait =>
                        if s_axi_lite_awready = '1' then
                            s_axi_lite_awvalid <= '0';
                        end if;
                        if s_axi_lite_wready = '1' then
                            s_axi_lite_wvalid <= '0';
                        end if;
                        if s_axi_lite_awvalid = '0' and s_axi_lite_wvalid = '0' then
                            ctrl_fsm <= idle;
                        end if;
                    
                    when others =>
                        ctrl_fsm <= idle;
                end case;
            end if; 
            
        end if;
    end process;

    s_axi_lite_bready <= '1';

    
    s_axi_lite_araddr <= "000100";  -- We only ever read the status register (register 4)
    s_axi_lite_rready <= '1';

    u_cdma : axi_cdma_0
    port map (
        m_axi_aclk => i_clk,
        s_axi_lite_aclk => i_clk,
        s_axi_lite_aresetn => resetn,
        cdma_introut       => cdma_introut,
        -- AXI slave interface to configure 
        s_axi_lite_awready => s_axi_lite_awready,  -- out std_logic;
        s_axi_lite_awvalid => s_axi_lite_awvalid,  -- in std_logic;
        s_axi_lite_awaddr => s_axi_lite_awaddr,    -- in(5:0);
        s_axi_lite_wready => s_axi_lite_wready,    -- out std_logic;
        s_axi_lite_wvalid => s_axi_lite_wvalid,    -- in std_logic;
        s_axi_lite_wdata => s_axi_lite_wdata,      -- in(31:0);
        s_axi_lite_bready => s_axi_lite_bready,    -- in std_logic;
        s_axi_lite_bvalid => s_axi_lite_bvalid,    -- out std_logic;
        s_axi_lite_bresp => s_axi_lite_bresp,      -- out(1:0);
        s_axi_lite_arready => s_axi_lite_arready,  -- out std_logic;
        s_axi_lite_arvalid => s_axi_lite_arvalid,  -- in std_logic;
        s_axi_lite_araddr => s_axi_lite_araddr,    -- in(5:0);
        s_axi_lite_rready => s_axi_lite_rready,    -- in std_logic;
        s_axi_lite_rvalid => s_axi_lite_rvalid,    -- out std_logic;
        s_axi_lite_rdata => s_axi_lite_rdata,      -- out(31:0);
        s_axi_lite_rresp => s_axi_lite_rresp,      -- out(1:0);
        -- AXI master interface to the interconnect
        m_axi_arready => i_AXI_miso.arready,   -- in std_logic;
        m_axi_arvalid => o_AXI_mosi.arvalid,   -- out std_logic;
        m_axi_araddr => o_AXI_mosi.araddr(31 downto 0),     -- out(31:0)
        m_axi_arlen => o_AXI_mosi.arlen(7 downto 0),       -- out(7:0)
        m_axi_arsize => o_AXI_mosi.arsize(2 downto 0),     -- out(2:0)
        m_axi_arburst => o_AXI_mosi.arburst(1 downto 0),   -- out(1:0)
        m_axi_arprot => o_AXI_mosi.arprot(2 downto 0),     -- out(2:0)
        m_axi_arcache => o_AXI_mosi.arcache(3 downto 0),   -- out(3:0)
        m_axi_rready => o_AXI_mosi.rready,     -- out std_logic;
        m_axi_rvalid => i_AXI_miso.rvalid,     -- in std_logic;
        m_axi_rdata => i_AXI_miso.rdata(31 downto 0),       -- in(31:0);
        m_axi_rresp => i_AXI_miso.rresp(1 downto 0),       -- in(1:0);
        m_axi_rlast => i_AXI_miso.rlast,       -- in std_logic;
        m_axi_awready => i_AXI_miso.awready,   -- in std_logic;
        m_axi_awvalid => o_AXI_mosi.awvalid,   -- out std_logic;
        m_axi_awaddr => o_AXI_mosi.awaddr(31 downto 0),     -- out(31:0)
        m_axi_awlen => o_AXI_mosi.awlen(7 downto 0),       -- out(7:0)
        m_axi_awsize => o_AXI_mosi.awsize(2 downto 0),     -- out(2:0)
        m_axi_awburst => o_AXI_mosi.awburst(1 downto 0),   -- out(1:0)
        m_axi_awprot => o_AXI_mosi.awprot(2 downto 0),     -- out(2:0)
        m_axi_awcache => o_AXI_mosi.awcache(3 downto 0),   -- out(3:0)
        m_axi_wready => i_AXI_miso.wready,     -- in std_logic;
        m_axi_wvalid => o_AXI_mosi.wvalid,     -- out std_logic;
        m_axi_wdata => o_AXI_mosi.wdata(31 downto 0),       -- out(31:0);
        m_axi_wstrb => o_AXI_mosi.wstrb(3 downto 0),       -- out(3:0);
        m_axi_wlast => o_AXI_mosi.wlast,       -- out std_logic;
        m_axi_bready => o_AXI_mosi.bready,     -- out std_logic;
        m_axi_bvalid => i_AXI_miso.bvalid,     -- in std_logic;
        m_axi_bresp => i_AXI_miso.bresp(1 downto 0),       -- in(1:0);
        cdma_tvect_out => open      -- Undocumented output pin; document just says "it is safe to leave these pins unconnected"
    );

    -- default assignments for otherwise unused fields in o_AXI_mosi
    o_AXI_mosi.awuser <= "0000";
    o_AXI_mosi.awlock <= '0';
    o_AXI_mosi.wid <= (others => '0');
    o_AXI_mosi.arid <= (others => '0');
    o_AXI_mosi.aruser <= "0000";
    o_AXI_mosi.arlock <= '0';
    o_AXI_mosi.awregion <= "0000";
    o_AXI_mosi.arregion <= "0000";
    o_AXI_mosi.arqos <= "0000";
    o_AXI_mosi.awqos <= "0000";


end Behavioral;
