----------------------------------------------------------------------------------
-- Company:  CSIRO - CASS
-- Engineer: David Humphrey
-- 
-- Create Date: 21.11.2018 23:51:01
-- Module Name: correlatorFB_tb - Behavioral
-- Description: 
--  Testbench for the low.CBF correlator Filterbank
-- 
----------------------------------------------------------------------------------
library IEEE, axi4_lib, common_lib, filterbanks_lib, dsp_top_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use dsp_top_lib.dsp_top_pkg.all;
use common_lib.common_pkg.all;


entity correlatorFB_tb is
end correlatorFB_tb;

architecture Behavioral of correlatorFB_tb is
    
    signal clk : std_logic := '0';
    signal clkCount : std_logic_vector(7 downto 0) := "00000000";
    signal rst : std_logic := '1';
    
    signal samples0, samples1, samples2, samples3 : std_logic_vector(15 downto 0);
    signal tx_rst : std_logic := '1';
    signal tx_rdy : std_logic := '0';
    signal s0Valid, s1Valid, s2Valid, s3Valid, s4Valid : std_logic; 
    
    signal data0, data1, data2, data3 : t_slv_8_arr(1 downto 0);
    signal data0out, data1out, data2out, data3out : t_slv_16_arr(1 downto 0);
    signal validIn, validInDel : std_logic;
    signal metaIn, metaOut : std_logic_vector(63 downto 0) := (others => '0');
    signal validOut, ValidOutDel : std_logic;
    
    signal FIRTapDataIn : std_logic_vector(17 downto 0);  -- For register writes of the filtertaps.
    signal FIRTapDataOut : std_logic_vector(17 downto 0); -- For register reads of the filtertaps. 3 cycle latency from FIRTapAddr_i
    signal FIRTapAddrIn : std_logic_vector(15 downto 0);  -- 4096 * 12 filter taps = 49152 total.
    signal FIRTapWE : std_logic;
    signal FIRTapClk : std_logic;
    
    signal corDout_arr : t_FB_output_payload_a(3 downto 0);    
    signal corFBHeader : t_CT1_META_out_arr(3 downto 0);
    signal corFBHeaderValid : std_logic;
    signal RFIScale : std_logic_vector(4 downto 0);
    
    signal FDdata : t_ctc_output_payload_arr(1 downto 0);   -- 8 bit data : .Hpol.re, Hpol.im, .Vpol.re, .Vpol.im 
    signal FDdataValid : std_logic_vector(1 downto 0);
    signal FDheader    : t_CT1_META_out_arr(1 downto 0); -- .HDeltaP(31:0), .VDeltaP(31:0), .HOffsetP(31:0), .VOffsetP(31:0), integration(31:0), ctFrame(1:0), virtualChannel(15:0);
    signal FDheaderValid : std_logic_vector(1 downto 0);
    
begin
    
    clk <= not clk after 1.25 ns;  -- 400 MHz
    
    RFIScale <= "10010";
    
    -- Generate input data
    process(clk)
    begin
        if rising_edge(clk) then
            
            if clkCount /= "11111111" then
                clkCount <= std_logic_vector(unsigned(clkCount) + 1);
                rst <= '1';
            else
                rst <= '0';
            end if;
            
            if clkCount /= "11111111" and clkCount /= "11111110" then
                tx_rst <= '1';
                tx_rdy <= '0';
            else
                tx_rst <= '0';
                tx_rdy <= '1';
            end if;

            validInDel <= validIn;
            if validIn = '0' and validInDel = '1' then
                metaIn <= std_logic_vector(unsigned(metaIn) + 1);
            end if;
            
        end if;
    end process;   
    
    
    tx0 : entity work.packet_transmit
    generic map (
        BIT_WIDTH => 16,
        cmd_file_name => "/home/hum089/projects/perentie/ska-low-cbf-fw-corr/libraries/signalProcessing/filterbanks/src/matlab/single_28Hz_tone_amplitude4/correlatorFBDin0.txt"
    )
    port map ( 
        clk     => clk,
        dout_o  => samples0, -- out std_logic_vector((BIT_WIDTH - 1) downto 0);
        valid_o => validIn,  -- out std_logic;
        rdy_i   => tx_rdy    -- in std_logic;    -- module we are sending the packet to is ready to receive data.
    );

    tx1 : entity work.packet_transmit
    generic map (
        BIT_WIDTH => 16,
        cmd_file_name => "/home/hum089/projects/perentie/ska-low-cbf-fw-corr/libraries/signalProcessing/filterbanks/src/matlab/single_28Hz_tone_amplitude4/correlatorFBDin1.txt"
    )
    port map ( 
        clk     => clk,
        dout_o  => samples1, -- out std_logic_vector((BIT_WIDTH - 1) downto 0);
        valid_o => open,
        rdy_i   => tx_rdy    -- in std_logic;    -- module we are sending the packet to is ready to receive data.
    );

    tx2 : entity work.packet_transmit
    generic map (
        BIT_WIDTH => 16,
        cmd_file_name => "/home/hum089/projects/perentie/ska-low-cbf-fw-corr/libraries/signalProcessing/filterbanks/src/matlab/single_28Hz_tone_amplitude4/correlatorFBDin2.txt"
    )
    port map ( 
        clk     => clk,
        dout_o  => samples2, -- out std_logic_vector((BIT_WIDTH - 1) downto 0);
        valid_o => open, 
        rdy_i   => tx_rdy    -- in std_logic;    -- module we are sending the packet to is ready to receive data.
    );

    tx3 : entity work.packet_transmit
    generic map (
        BIT_WIDTH => 16,
        cmd_file_name => "/home/hum089/projects/perentie/ska-low-cbf-fw-corr/libraries/signalProcessing/filterbanks/src/matlab/single_28Hz_tone_amplitude4/correlatorFBDin3.txt"
    )
    port map ( 
        clk     => clk,
        dout_o  => samples3, -- out std_logic_vector((BIT_WIDTH - 1) downto 0);
        valid_o => open,
        rdy_i   => tx_rdy    -- in std_logic;    -- module we are sending the packet to is ready to receive data.
    );

    data0(0) <= samples0(7 downto 0);
    data0(1) <= samples0(15 downto 8);
    data1(0) <= samples1(7 downto 0);
    data1(1) <= samples1(15 downto 8);
    data2(0) <= samples2(7 downto 0);
    data2(1) <= samples2(15 downto 8);
    data3(0) <= samples3(7 downto 0);
    data3(1) <= samples3(15 downto 8);
    
    FIRTapDataIn <= (others => '0');
    FIRTapAddrIn <= (others => '0');
    FIRTapWE <= '0';
    FIRTapClk <= '0';
    
    fb : entity filterbanks_lib.correlatorFBTop25
    port map(
        -- clock, target is 380 MHz
        clk => clk,
        rst => rst,
        -- Data input, common valid signal, expects packets of 4096 samples. Requires at least 2 clocks idle time between packets.
        data0_i => data0, -- in array8bit_type(1 downto 0);  -- 4 Inputs, each complex data, 8 bit real, 8 bit imaginary.
        data1_i => data1, -- in array8bit_type(1 downto 0);
        data2_i => data2, -- in array8bit_type(1 downto 0);
        data3_i => data3, -- in array8bit_type(1 downto 0);
        meta_i  => metaIn, -- in(63:0)
        valid_i => validIn, -- in std_logic;
        -- Data out; bursts of 3456 clocks for each channel.
        data0_o => data0Out, -- out array16bit_type(1 downto 0);   -- 4 outputs, real and imaginary parts in (0) and (1) respectively;
        data1_o => data1Out, -- out array16bit_type(1 downto 0);
        data2_o => data2Out, -- out array16bit_type(1 downto 0);
        data3_o => data3Out, -- out array16bit_type(1 downto 0);
        meta_o  => metaOut,  -- out(63:0)
        valid_o => validOut, -- out std_logic;
        -- Writing FIR Taps
        FIRTapData_i => FIRTapDataIn,  -- in std_logic_vector(17 downto 0);  -- For register writes of the filtertaps.
        FIRTapData_o => FIRTapDataOut, -- out std_logic_vector(17 downto 0); -- For register reads of the filtertaps. 3 cycle latency from FIRTapAddr_i
        FIRTapAddr_i => FIRTapAddrIn,  -- in std_logic_vector(15 downto 0);  -- 4096 * 12 filter taps = 49152 total.
        FIRTapWE_i   => FIRTapWE,      -- in std_logic;
        FIRTapClk    => FIRTapClk      -- in std_logic
    );
    
    corDout_arr(0).hpol.re <= data0Out(0);  -- 16 bit data into the fine delay module.
    corDout_arr(0).hpol.im <= data0Out(1);
    corDout_arr(0).vpol.re <= data1Out(0);
    corDout_arr(0).vpol.im <= data1Out(1);
    corDout_arr(1).hpol.re <= data2Out(0);  -- 16 bit data into the fine delay module.
    corDout_arr(1).hpol.im <= data2Out(1);
    corDout_arr(1).vpol.re <= data3Out(0);
    corDout_arr(1).vpol.im <= data3Out(1);
    
    -- Set delays to be zero.
    corFBHeader(0).HDeltaP <= (others => '0');
    corFBHeader(0).VDeltaP <= (others => '0');
    corFBHeader(0).HOffsetP <= (others => '0');
    corFBHeader(0).VOffsetP <= (others => '0');
    corFBHeader(0).virtualChannel <= (others => '0');
    corFBHeader(0).valid <= '0'; -- unused
    corFBHeader(0).integration <= (others => '0');
    corFBHeader(0).ctFrame <= (others => '0');
    corFBHeader(0).bad_poly <= '0';
    
    corFBHeader(1).HDeltaP <= (others => '0');
    corFBHeader(1).VDeltaP <= (others => '0');
    corFBHeader(1).HOffsetP <= (others => '0');
    corFBHeader(1).VOffsetP <= (others => '0');
    corFBHeader(1).virtualChannel <= (others => '0');
    corFBHeader(1).valid <= '0'; -- unused
    corFBHeader(1).integration <= (others => '0');
    corFBHeader(1).ctFrame <= (others => '0');
    corFBHeader(1).bad_poly <= '0';
    
    corFBHeaderValid <= ValidOut and (not ValidOutDel);
    
    process(clk)
    begin
        if rising_edge(clk) then
            ValidOutDel <= ValidOut;
        end if;
    end process;
    
    FDGen : for i in 0 to 1 generate 
        FineDelay : entity filterbanks_lib.fineDelay
        generic map (
            FBSELECTION => 2  -- 2 = Correlator
        )
        port map (
            i_clk  => clk,
            -- data and header in
            i_data        => corDout_arr(i),    -- in t_FB_output_payload;  -- 16 bit data : .Hpol.re, Hpol.im, .Vpol.re, .Vpol.im 
            i_dataValid   => validOut,          -- in std_logic;
            i_header      => corFBHeader(i),    -- .HDeltaP(31:0), .VDeltaP(31:0), .HOffsetP(31:0), .VOffsetP(31:0), integration(31:0), ctFrame(1:0), virtualChannel(15:0);
            i_headerValid => corFBHeaderValid,  -- in std_logic;
            -- Data and Header out
            o_data        => FDdata(i),        -- out t_ctc_output_payload;   -- 8 bit data : .Hpol.re, Hpol.im, .Vpol.re, .Vpol.im 
            o_dataValid   => FDDataValid(i),   -- out std_logic;
            o_header      => FDHeader(i),      -- .HDeltaP(31:0), .VDeltaP(31:0), .HOffsetP(31:0), .VOffsetP(31:0), integration(31:0), ctFrame(1:0), virtualChannel(15:0);
            o_headerValid => FDheaderValid(i), -- out std_logic;
    
            -------------------------------------------
            -- control and monitoring
            -- Disable the fine delay. Instead of multiplying by the output of the sin/cos lookup, just scale by unity.
            i_disable     => '0', -- in std_logic;
            -- Scale down by 2^(i_RFIScale) before clipping for RFI.
            -- Unity for the sin/cos lookup is 0x10000, so :
            --   i_RFIScale < 16  ==> Amplify the output of the filterbanks.
            --   i_RFIScale = 16  ==> Amplitude of the filterbank output is unchanged.
            --   i_RFIScale > 16  ==> Amplitude of the filterbank output is reduced.
            i_RFIScale    => RFIScale, -- in std_logic_vector(4 downto 0); 
            -- For monitoring of the output level.
            -- Higher level should keep track of : 
            --   * The total number of frames processed.
            --   * The sum of each of the outputs below. (but note one is superfluous since it can be calculated from the total frames processed and the sum of all the others).
            --      - These sums should be 32 bit values, which ensures wrapping will occur at most once per hour.
            -- For the correlator:
            --   - Each frame corresponds to 3456 fine channels x 2 (H & V polarisations) * 2 (re+im).
            --   - Every fine channel must be one of the categories below, so they will sum to 3456*2*2 = 13824.
            o_overflow    => open, -- hist_overflow(i),     -- out(15:0); -- Number of fine channels which were clipped.
            o_64_127      => open, -- hist_64_127(i),  -- out(15:0); -- Number of fine channels in the range 64 to 128.
            o_32_63       => open, -- hist_32_63(i),   -- out(15:0); -- Number of fine channels in the range 32 to 64.
            o_16_31       => open, -- hist_16_31(i),   -- out(15:0); -- Number of fine channels in the range 16 to 32.
            o_0_15        => open, -- hist_0_15(i),    -- out(15:0); -- Number of fine channels in the range 0 to 15.
            o_virtualChannel => open, -- hist_virtualChannel(i), -- out(8:0);
            o_histogramValid => open  -- hist_valid(i) -- out std_logic -- indicates histogram data is valid.
        );
    end generate;    
    
    
    log0 : entity work.packet_receive
    Generic map (
        BIT_WIDTH => 16,
        log_file_name => "/home/hum089/projects/perentie/ska-low-cbf-fw-corr/libraries/signalProcessing/filterbanks/src/matlab/single_28Hz_tone_amplitude4/correlatorFBDout0_log.txt"
    )
    Port map (
        clk     => clk, -- in  std_logic;     -- clock
        rst_i   => rst,  -- in  std_logic;     -- reset input
        din0_i  => data0Out(0), -- in  std_logic_vector((BIT_WIDTH - 1) downto 0);  -- actual data out.
        din1_i  => data0Out(1),
        valid_i => validOut, -- in  std_logic;     -- data out valid (high for duration of the packet)
        rdy_o   => open         -- out std_logic      -- module we are sending the packet to is ready to receive data.
    );

    log1 : entity work.packet_receive
    Generic map (
        BIT_WIDTH => 16,
        log_file_name => "/home/hum089/projects/perentie/ska-low-cbf-fw-corr/libraries/signalProcessing/filterbanks/src/matlab/single_28Hz_tone_amplitude4/correlatorFBDout1_log.txt"
    )
    Port map (
        clk     => clk, -- in  std_logic;     -- clock
        rst_i   => rst,  -- in  std_logic;     -- reset input
        din0_i  => data1Out(0), -- in  std_logic_vector((BIT_WIDTH - 1) downto 0);  -- actual data out.
        din1_i  => data1Out(1),
        valid_i => validOut,    -- in  std_logic;     -- data out valid (high for duration of the packet)
        rdy_o   => open         -- out std_logic      -- module we are sending the packet to is ready to receive data.
    );

    log2 : entity work.packet_receive
    Generic map (
        BIT_WIDTH => 16,
        log_file_name => "/home/hum089/projects/perentie/ska-low-cbf-fw-corr/libraries/signalProcessing/filterbanks/src/matlab/single_28Hz_tone_amplitude4/correlatorFBDout2_log.txt"
    )
    Port map (
        clk     => clk, -- in  std_logic;     -- clock
        rst_i   => rst,  -- in  std_logic;     -- reset input
        din0_i  => data2Out(0), -- in  std_logic_vector((BIT_WIDTH - 1) downto 0);  -- actual data out.
        din1_i  => data2Out(1),
        valid_i => validOut,    -- in  std_logic;     -- data out valid (high for duration of the packet)
        rdy_o   => open         -- out std_logic      -- module we are sending the packet to is ready to receive data.
    );
    
    log3 : entity work.packet_receive
    Generic map (
        BIT_WIDTH => 16,
        log_file_name => "/home/hum089/projects/perentie/ska-low-cbf-fw-corr/libraries/signalProcessing/filterbanks/src/matlab/single_28Hz_tone_amplitude4/correlatorFBDout3_log.txt"
    )
    Port map (
        clk     => clk,  -- in  std_logic;     -- clock
        rst_i   => rst,  -- in  std_logic;     -- reset input
        din0_i  => data3Out(0), -- in  std_logic_vector((BIT_WIDTH - 1) downto 0);  -- actual data out.
        din1_i  => data3Out(1),
        valid_i => validOut, -- in  std_logic;     -- data out valid (high for duration of the packet)
        rdy_o   => open         -- out std_logic      -- module we are sending the packet to is ready to receive data.
    );
    
    ------------------------------------------------------
    -- 8 bit output of fine delay
    FDlog0 : entity work.packet_receive
    Generic map (
        BIT_WIDTH => 8,
        log_file_name => "/home/hum089/projects/perentie/ska-low-cbf-fw-corr/libraries/signalProcessing/filterbanks/src/matlab/single_28Hz_tone_amplitude4/correlatorFDDout0_log.txt"
    )
    Port map (
        clk     => clk, -- in  std_logic;     -- clock
        rst_i   => rst,  -- in  std_logic;     -- reset input
        din0_i  => FDdata(0).hpol.re, -- in  std_logic_vector((BIT_WIDTH - 1) downto 0);  -- actual data out.
        din1_i  => FDdata(0).hpol.im,
        valid_i => FDDataValid(0), -- in  std_logic;     -- data out valid (high for duration of the packet)
        rdy_o   => open         -- out std_logic      -- module we are sending the packet to is ready to receive data.
    );

    FDlog1 : entity work.packet_receive
    Generic map (
        BIT_WIDTH => 8,
        log_file_name => "/home/hum089/projects/perentie/ska-low-cbf-fw-corr/libraries/signalProcessing/filterbanks/src/matlab/single_28Hz_tone_amplitude4/correlatorFDDout1_log.txt"
    )
    Port map (
        clk     => clk, -- in  std_logic;     -- clock
        rst_i   => rst,  -- in  std_logic;     -- reset input
        din0_i  => FDdata(0).vpol.re, -- in  std_logic_vector((BIT_WIDTH - 1) downto 0);  -- actual data out.
        din1_i  => FDdata(0).vpol.im,
        valid_i => FDDataValid(0),    -- in  std_logic;     -- data out valid (high for duration of the packet)
        rdy_o   => open         -- out std_logic      -- module we are sending the packet to is ready to receive data.
    );

    FDlog2 : entity work.packet_receive
    Generic map (
        BIT_WIDTH => 8,
        log_file_name => "/home/hum089/projects/perentie/ska-low-cbf-fw-corr/libraries/signalProcessing/filterbanks/src/matlab/single_28Hz_tone_amplitude4/correlatorFDDout2_log.txt"
    )
    Port map (
        clk     => clk, -- in  std_logic;     -- clock
        rst_i   => rst,  -- in  std_logic;     -- reset input
        din0_i  => FDdata(1).hpol.re, -- in  std_logic_vector((BIT_WIDTH - 1) downto 0);  -- actual data out.
        din1_i  => FDdata(1).hpol.im,
        valid_i => FDDataValid(1),    -- in  std_logic;     -- data out valid (high for duration of the packet)
        rdy_o   => open         -- out std_logic      -- module we are sending the packet to is ready to receive data.
    );
    
    FDlog3 : entity work.packet_receive
    Generic map (
        BIT_WIDTH => 8,
        log_file_name => "/home/hum089/projects/perentie/ska-low-cbf-fw-corr/libraries/signalProcessing/filterbanks/src/matlab/single_28Hz_tone_amplitude4/correlatorFDDout3_log.txt"
    )
    Port map (
        clk     => clk,  -- in  std_logic;     -- clock
        rst_i   => rst,  -- in  std_logic;     -- reset input
        din0_i  => FDdata(1).vpol.re, -- in  std_logic_vector((BIT_WIDTH - 1) downto 0);  -- actual data out.
        din1_i  => FDdata(1).hpol.im,
        valid_i => FDDataValid(1), -- in  std_logic;     -- data out valid (high for duration of the packet)
        rdy_o   => open         -- out std_logic      -- module we are sending the packet to is ready to receive data.
    );
    
end Behavioral;


