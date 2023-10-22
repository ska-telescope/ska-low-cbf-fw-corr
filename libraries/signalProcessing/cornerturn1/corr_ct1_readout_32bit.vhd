----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 30.09.2020 17:20:23
-- Module Name: pst_readout_32bit - Behavioral 
-- Description: 
--   Readout of data for a single station for the correlator first stage corner turn.
-- 
----------------------------------------------------------------------------------
library IEEE, xpm, ct_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use xpm.vcomponents.all;

entity corr_ct1_readout_32bit is
    Port(
        i_clk : in std_logic;
        i_rst : in std_logic;  -- Drive this high for one clock between each virtual channel.
        o_rstBusy : out std_logic;
        -- Data in from the buffer
        i_data : in std_logic_vector(511 downto 0); --
        -- data in from the FIFO that shadows the buffer
        i_rdOffset : in std_logic_vector(3 downto 0);  -- Sample offset in the 512 bit word; 0 = use all 16 samples, "01" = Skip first sample, "10" = ... ; Only used on the first 512 bit word after i_rst.
        i_HDeltaP : in std_logic_vector(15 downto 0);  -- use every 256th input for the meta data (each word in = 512 bits = 16 samples, so 256 input samples = 4096 time samples = 1 output packet)
        i_VDeltaP : in std_logic_vector(15 downto 0);
        i_HoffsetP : in std_logic_vector(15 downto 0);
        i_VoffsetP : in std_logic_vector(15 downto 0);
        i_vc       : in std_logic_vector(15 downto 0);
        i_packet   : in std_logic_vector(7 downto 0);
        i_valid : in std_logic; -- should go high no more than once every 16 clocks
        o_stop  : out std_logic;
        -- data out
        o_data : out std_logic_vector(31 downto 0);
        o_HDeltaP : out std_logic_vector(15 downto 0); --
        o_VDeltaP : out std_logic_vector(15 downto 0); 
        o_HOffsetP : out std_logic_vector(15 downto 0);
        o_VOffsetP : out std_logic_vector(15 downto 0);
        o_vc       : out std_logic_vector(15 downto 0);
        o_packet   : out std_logic_vector(7 downto 0);
        o_valid : out std_logic;
        i_run : in std_logic -- should go high for a burst of 64 clocks to output a packet.
    );
end corr_ct1_readout_32bit;

architecture Behavioral of corr_ct1_readout_32bit is

    signal reg512 : std_logic_vector(511 downto 0);
    signal fifoWrDataCount : std_logic_vector(5 downto 0);
    signal fifoDin : std_logic_vector(31 downto 0);
    signal fifoWrEn : std_logic;
    
    signal sampleOffset : std_logic_vector(4 downto 0);
    signal curSample : std_logic_Vector(4 downto 0);
    
    signal startOfFrame : std_logic;
    signal fifoEmpty : std_logic;
    signal fifoRdDataCount : std_logic_vector(5 downto 0);
    signal fifoRdEn : std_logic;
    signal validCount : std_logic_vector(7 downto 0);

begin
    
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            
            if i_rst = '1' then
                sampleOffset <= "00000";  -- There are 16 time samples in a 512 bit word; this counts where the first used sample starts in each new 512 bit word.
                curSample <= "10000";    -- Which of the 16 time samples we are up to in the most recent 512 bit word.
                startOfFrame <= '1';
                validCount <= "00000000";    -- Count of i_valid modulo 256, since we want to keep every 256th value from i_HDeltaP, i_VDeltaP.
            elsif i_valid = '1' then
                startOfFrame <= '0';
                validCount <= std_logic_vector(unsigned(validCount) + 1);
                if startOfFrame = '1' then
                    sampleOffset <= '0' & i_rdOffset;
                else
                    sampleOffset <= "00000";
                end if;
                curSample <= "00000";
                reg512 <= i_data;
            elsif curSample /= "10000" then
                curSample <= std_logic_vector(unsigned(curSample) + 1);
                reg512 <= x"00000000" & reg512(511 downto 32);
            end if;
            
            -- FIFO is only 64 deep, so we never have more than a whole packet in it (one packet = 4096 samples)
            -- So we just capture the fine delay information and it will be valid on the first output cycle of each packet.
            if i_valid = '1' and validCount = "00000000" then
                o_HDeltaP <= i_HDeltaP; -- use every 16th input sample for the meta data
                o_VDeltaP <= i_VDeltaP;
                o_HOffsetP <= i_HoffsetP;
                o_VOffsetP <= i_VoffsetP;
                o_vc <= i_vc;
                o_packet <= i_packet;
            end if;
            
            fifoDin <= reg512(31 downto 0);
            if ((unsigned(curSample) >= unsigned(sampleOffset)) and (curSample /= "10000")) then
                fifoWrEn <= '1';
            else
                fifoWrEn <= '0';
            end if;
            
            if (unsigned(fifoWrDataCount) > 16) then  -- 16 words in the FIFO = 64 bytes.
                o_stop <= '1';
            else
                o_stop <= '0';
            end if;
            
            o_valid <= i_run;  -- one clock latency to read from the FIFO.
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Output FIFOs for the data.
    -- FIFOs are 64 deep x 32 bit words.
    xpm_fifo_sync_inst : xpm_fifo_sync
    generic map (
        DOUT_RESET_VALUE => "0",    -- String
        ECC_MODE => "no_ecc",       -- String
        FIFO_MEMORY_TYPE => "distributed", -- String
        FIFO_READ_LATENCY => 1,     -- DECIMAL
        FIFO_WRITE_DEPTH => 64,   -- DECIMAL
        FULL_RESET_VALUE => 0,      -- DECIMAL
        PROG_EMPTY_THRESH => 10,    -- DECIMAL
        PROG_FULL_THRESH => 10,     -- DECIMAL
        RD_DATA_COUNT_WIDTH => 6,   -- DECIMAL
        READ_DATA_WIDTH => 32,      -- DECIMAL
        READ_MODE => "std",         -- String
        SIM_ASSERT_CHK => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        USE_ADV_FEATURES => "0404", -- String
        WAKEUP_TIME => 0,           -- DECIMAL
        WRITE_DATA_WIDTH => 32,     -- DECIMAL
        WR_DATA_COUNT_WIDTH => 6    -- DECIMAL
    )
    port map (
        almost_empty => open,     -- 1-bit output: Almost Empty : When asserted, this signal indicates that only one more read can be performed before the FIFO goes to empty.
        almost_full => open,      -- 1-bit output: Almost Full: When asserted, this signal indicates that only one more write can be performed before the FIFO is full.
        data_valid => open, -- 1-bit output: Read Data Valid: When asserted, this signal indicates that valid data is available on the output bus (dout).
        dbiterr => open,          -- 1-bit output: Double Bit Error: Indicates that the ECC decoder detected a double-bit error and data in the FIFO core is corrupted.
        dout => o_data,                   -- READ_DATA_WIDTH-bit output: Read Data: The output data bus is driven when reading the FIFO.
        empty => fifoEmpty,                 -- 1-bit output: Empty Flag: When asserted, this signal indicates that- the FIFO is empty.
        full => open,                   -- 1-bit output: Full Flag: When asserted, this signal indicates that the FIFO is full.
        overflow => open,           -- 1-bit output: Overflow: This signal indicates that a write request (wren) during the prior clock cycle was rejected, because the FIFO is full
        prog_empty => open,       -- 1-bit output: Programmable Empty: This signal is asserted when the number of words in the FIFO is less than or equal to the programmable empty threshold value.
        prog_full => open,         -- 1-bit output: Programmable Full: This signal is asserted when the number of words in the FIFO is greater than or equal to the programmable full threshold value.
        rd_data_count => fifoRdDataCount, -- RD_DATA_COUNT_WIDTH-bit output: Read Data Count: This bus indicates the number of words read from the FIFO.
        rd_rst_busy => open,     -- 1-bit output: Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.
        sbiterr => open,             -- 1-bit output: Single Bit Error: Indicates that the ECC decoder detected and fixed a single-bit error.
        underflow => open,         -- 1-bit output: Underflow: Indicates that the read request (rd_en) during the previous clock cycle was rejected because the FIFO is empty.
        wr_ack => open,               -- 1-bit output: Write Acknowledge: This signal indicates that a write request (wr_en) during the prior clock cycle is succeeded.
        wr_data_count => fifoWrDataCount, -- WR_DATA_COUNT_WIDTH-bit output: Write Data Count: This bus indicates the number of words written into the FIFO.
        wr_rst_busy => o_rstBusy,     -- 1-bit output: Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
        din => fifoDin,                     -- WRITE_DATA_WIDTH-bit input: Write Data: The input data bus used when writing the FIFO.
        injectdbiterr => '0', -- 1-bit input: Double Bit Error Injection
        injectsbiterr => '0', -- 1-bit input: Single Bit Error Injection: 
        rd_en => fifoRdEn,       -- 1-bit input: Read Enable: If the FIFO is not empty, asserting this signal causes data (on dout) to be read from the FIFO. 
        rst => i_rst,           -- 1-bit input: Reset: Must be synchronous to wr_clk.
        sleep => '0',         -- 1-bit input: Dynamic power saving- If sleep is High, the memory/fifo block is in power saving mode.
        wr_clk => i_clk,     -- 1-bit input: Write clock: Used for write operation. wr_clk must be a free running clock.
        wr_en => fifoWrEn     -- 1-bit input: Write Enable: 
    );

    fifoRdEn <= i_run;


end Behavioral;
