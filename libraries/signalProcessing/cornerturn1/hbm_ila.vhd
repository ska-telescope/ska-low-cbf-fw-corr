----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 24/05/2024
-- Module Name: hbm_ila.vhd - Behavioral
-- Description: 
--  Write data to HBM, just like an ILA
--  
----------------------------------------------------------------------------------
library IEEE, common_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
Library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;
USE common_lib.common_pkg.ALL;

Library xpm;
use xpm.vcomponents.all;

entity hbm_ila is
    port (
        dsp_clk    : in std_logic;
        -- 16 bytes of debug data, and valid.
        i_ila_data       : in std_logic_vector(255 downto 0);
        i_ila_data_valid : in std_logic;
        o_hbm_addr       : out std_logic_vector(31 downto 0); -- Address we are up to in the HBM.
        -- Write out to the HBM
        -- write address buses : out t_axi4_full_addr(.valid, .addr(39:0), .len(7:0))
        axi_clk  : in std_logic;
        axi_rst  : in std_logic;
        o_HBM_axi_aw      : out t_axi4_full_addr;
        i_HBM_axi_awready : in std_logic;
        -- w data buses : out t_axi4_full_data(.valid, .data(511:0), .last, .resp(1:0))
        o_HBM_axi_w       : out t_axi4_full_data;
        i_HBM_axi_wready  : in std_logic  -- in std_logic;
    );
end hbm_ila;

architecture Behavioral of hbm_ila is
    
    signal fifo_wren : std_logic;
    signal fifo_dout : std_logic_vector(512 downto 0);
    signal aw_addr : std_logic_vector(39 downto 0) := x"0000000000";
    signal rd_en, fifo_empty : std_logic;
    signal wcount : std_logic_vector(6 downto 0) := "0000000";
    signal fifo_din : std_logic_vector(512 downto 0);
    signal to_send_count : std_logic_vector(7 downto 0) := x"00";
    type aw_fsm_t is (set_aw, wait_aw, next_addr, done);
    signal aw_fsm : aw_fsm_t := done;
    signal wr_rst_busy_del, wr_rst_busy, dsp_rst, aw_req_sent : std_logic := '0';
    signal valid_final, send_aw : std_logic := '0';
    signal data_final : std_logic_vector(255 downto 0);
    signal send_aw_axi : std_logic := '0';
    
begin
    
    process(dsp_clk)
    begin
        if rising_edge(dsp_clk) then
            
            -- pipeline data in, and handle reset
            wr_rst_busy_del <= wr_rst_busy;
            valid_final <= (not wr_rst_busy_del) and (i_ila_data_valid);
            data_final <= i_ila_data;        
        
            -- Build 512 bit wide words, and write to the FIFO
            if wr_rst_busy_del = '1' then
                wcount <= (others => '0');
            elsif valid_final = '1' then
                wcount <= std_logic_vector(unsigned(wcount) + 1);
            end if;
            
            if wcount = "1111111" then
                fifo_din(512) <= '1';
            else
                fifo_din(512) <= '0';
            end if;
            
            if valid_final = '1' then
                fifo_din(511 downto 256) <= data_final;
                fifo_din(255 downto 0) <= fifo_din(511 downto 256);
            end if;
            
            if valid_final = '1' and wcount(0) = '1' then
                fifo_wrEn <= '1';
            else
                fifo_wrEn <= '0';
            end if;
            
            if valid_final = '1' and wcount = "1111111" then
                -- Once every 64 words written to the FIFO, trigger an aw transaction
                send_aw <= '1';
            else
                send_aw <= '0';
            end if;
            
        end if;
    end process;
    
    xpm_cdc_single_inst : xpm_cdc_single
    generic map (
        DEST_SYNC_FF => 4,   -- DECIMAL; range: 2-10
        INIT_SYNC_FF => 0,   -- DECIMAL; 0=disable simulation init values, 1=enable simulation init values
        SIM_ASSERT_CHK => 0, -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        SRC_INPUT_REG => 1   -- DECIMAL; 0=do not register input, 1=register input
    ) port map (
        dest_out => dsp_rst,  -- 1-bit output: src_in synchronized to the destination clock domain. This output is registered.
        dest_clk => dsp_clk,  -- 1-bit input: Clock signal for the destination clock domain.
        src_clk => axi_clk,   -- 1-bit input: optional; required when SRC_INPUT_REG = 1
        src_in => axi_rst     -- 1-bit input: Input signal to be synchronized to dest_clk domain.
    );
    
    
    -- Dual clock fifo to hold data while we write to HBM
    xpm_fifo_async_inst : xpm_fifo_async
    generic map (
        CASCADE_HEIGHT => 0,        -- DECIMAL
        CDC_SYNC_STAGES => 2,       -- DECIMAL
        DOUT_RESET_VALUE => "0",    -- String
        ECC_MODE => "no_ecc",       -- String
        FIFO_MEMORY_TYPE => "auto", -- String
        FIFO_READ_LATENCY => 0,     -- DECIMAL
        FIFO_WRITE_DEPTH => 512,    -- DECIMAL
        FULL_RESET_VALUE => 0,      -- DECIMAL
        PROG_EMPTY_THRESH => 10,    -- DECIMAL
        PROG_FULL_THRESH => 10,     -- DECIMAL
        RD_DATA_COUNT_WIDTH => 10,  -- DECIMAL
        READ_DATA_WIDTH => 513,     -- DECIMAL
        READ_MODE => "fwft",        -- String
        RELATED_CLOCKS => 0,        -- DECIMAL
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "1707", -- String; bit 12 enables the data valid flag.
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 513,    -- DECIMAL
        WR_DATA_COUNT_WIDTH => 1    -- DECIMAL
    ) port map (
        almost_empty => open,     -- 1-bit output: Almost Empty
        almost_full => open,      -- 1-bit output: Almost Full
        data_valid => o_HBM_axi_w.valid, -- 1-bit output: Read Data Valid
        dbiterr => open,       -- 1-bit output: Double Bit Error
        dout => fifo_dout,     -- READ_DATA_WIDTH-bit output: Read Data
        empty => fifo_empty,   -- 1-bit output: Empty Flag
        full => open,          -- 1-bit output: Full Flag
        overflow => open,      -- 1-bit output: Overflow
        prog_empty => open,    -- 1-bit output: Programmable Empty
        prog_full => open,     -- 1-bit output: Programmable Full
        rd_data_count => open, -- RD_DATA_COUNT_WIDTH-bit output
        rd_rst_busy => open,   -- 1-bit output: Read Reset Busy
        sbiterr => open,       -- 1-bit output: Single Bit Error
        underflow => open,     -- 1-bit output: Underflow
        wr_ack => open,        -- 1-bit output: Write Acknowledge
        wr_data_count => open, -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count
        wr_rst_busy => wr_rst_busy,  -- 1-bit output: Write Reset Busy
        din => fifo_din,      -- WRITE_DATA_WIDTH-bit input: Write Data
        injectdbiterr => '0', -- 1-bit input: Double Bit Error Injection
        injectsbiterr => '0', -- 1-bit input: Single Bit Error Injection
        rd_clk => axi_clk,    -- 1-bit input: Read clock: Used for read operation
        rd_en => rd_en,       -- 1-bit input: Read Enable
        rst => dsp_rst,       -- 1-bit input: Reset: Must be synchronous to wr_clk.
        sleep => '0',         -- 1-bit input: Dynamic power saving
        wr_clk => dsp_clk,    -- 1-bit input: Write clock: Used for write operation
        wr_en => fifo_wrEn    -- 1-bit input: Write Enable
    );
    
    rd_en <= '1' when fifo_empty = '0' and i_HBM_axi_wready = '1' else '0';
    o_HBM_axi_w.last <= fifo_dout(512);
    o_HBM_axi_w.data <= fifo_dout(511 downto 0);
    
    xpm_cdc_pulse_inst : xpm_cdc_pulse
    generic map (
        DEST_SYNC_FF => 4,   -- DECIMAL; range: 2-10
        INIT_SYNC_FF => 0,   -- DECIMAL; 0=disable simulation init values, 1=enable simulation init values
        REG_OUTPUT => 0,     -- DECIMAL; 0=disable registered output, 1=enable registered output
        RST_USED => 0,       -- DECIMAL; 0=no reset, 1=implement reset
        SIM_ASSERT_CHK => 0  -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
    ) port map (
        dest_pulse => send_aw_axi, -- 1-bit output: Outputs a pulse the size of one dest_clk period
        dest_clk => axi_clk,       -- 1-bit input: Destination clock.
        dest_rst => '0',           -- 1-bit input: optional; required when RST_USED = 1
        src_clk => dsp_clk,        -- 1-bit input: Source clock.
        src_pulse => send_aw,      -- 1-bit input: Rising edge of this signal initiates a pulse transfer to the destination clock domain. 
        src_rst => '0'             -- 1-bit input: optional; required when RST_USED = 1
    );
    
    
    -- Each write to HBM is 4096 bytes.
    -- Generate 8 aw requests, each a write of 4096 bytes.
    process(axi_clk)
    begin
        if rising_edge(axi_clk) then
            
            if axi_rst = '1' then
                to_send_count <= (others => '0');
            elsif send_aw_axi = '1' and aw_req_sent = '0' then
                to_send_count <= std_logic_vector(unsigned(to_send_count) + 1);
            elsif send_aw_axi = '0' and aw_req_sent = '1' then
                to_send_count <= std_logic_vector(unsigned(to_send_count) - 1);
            end if;
            
            if axi_rst = '1' then
                aw_fsm <= done;
            else
                case aw_fsm is
                    when set_aw =>
                        o_HBM_axi_aw.valid <= '1';
                        o_HBM_axi_aw.addr <= aw_addr;
                        aw_fsm <= wait_aw;
                        
                    when wait_aw =>
                        if i_HBM_axi_awready = '1' then
                            o_HBM_axi_aw.valid <= '0';
                            aw_fsm <= next_addr;
                        end if;
                        
                    when next_addr =>
                        aw_addr <= std_logic_Vector(unsigned(aw_addr) + 4096);
                        o_HBM_axi_aw.valid <= '0';
                        aw_fsm <= done;
                    
                    when done =>
                        if unsigned(to_send_count) > 0 then
                            aw_fsm <= set_aw;
                        end if;
                        o_HBM_axi_aw.valid <= '0';
                end case;
            end if;
            
            if aw_fsm = next_addr then
                aw_req_sent <= '1';
            else
                aw_req_sent <= '0';
            end if;
            
            o_hbm_addr <= aw_addr(31 downto 0);
            
        end if;
    end process;
    
    o_HBM_axi_aw.len <= "00111111"; -- Write 64 words per transaction = 4096 bytes. 
    o_HBM_axi_w.resp <= "00";
    
end Behavioral;
