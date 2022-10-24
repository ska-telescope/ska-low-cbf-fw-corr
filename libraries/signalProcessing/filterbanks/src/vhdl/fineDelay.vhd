----------------------------------------------------------------------------------
-- Company: CSIRO 
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 14.01.2020 11:02:14
-- Module Name: fineDelay - Behavioral
-- Project Name: SKA - Perentie
-- Description: 
--  Fine delay module. Introduces a delay via a phase shift in the fine channels at the output of the filterbank.
--  The delay is controlled by the .hpol_phase_shift and .vpol_phase_shift fields in i_header.
--  .Xpol_phase_shift (X = H or V) is a 16 bit value, with 1 sign bit, 12 integer bits and 3 fractional bits, in units of 2^-12 rotations.
--  (or equivalently 1 sign bit, 15 fractional bits, units of rotations).
--  The phase shift is the rotation at the high (Nyquist) edge of the coarse channel. For each case (correlator, PSS,PST),
--  the phase shift of the lowest (first received) fine channel is calculated, together with a phase step between fine channels.  
-- 
--  For the correlator (generic FBSelection = 0), inputs are bursts of 3456 clocks, with the header valid on the first clock of the burst.
--     * Phase step between fine channels = P/2048
--     * Phase of first fine channel      = -P * 1728/2048   (Note 1728 = 27 * 64)
--  For PST (generic FBSelection = 1), inputs are bursts of 216 clocks, with the header valid on the first clock of the burst.
--     * Phase step between fine channels = P/128
--     * Phase of first fine channel      = -P * 108/128     (Note 108 = 27 * 4)
--  For PSS (generic FBSelection = 2), inputs are bursts of 54 clocks, with the header valid on the first clock of the burst.
--     * Phase step between fine channels = P/32
--     * Phase of first fine channel      = -P * 27/32
-- 
-- Arithmetic :
--  For phase input value of "P", the phase values used are :
--     * PSS : (-P*27 + n*P)/32,     n = 0:53
--     * PST : (-P*108 + n*P)/128,   n = 0:215
--     * Cor : (-P*1728 + n*P)/2048, n = 0:3455
--   
----------------------------------------------------------------------------------

library IEEE, dsp_top_lib, filterbanks_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use dsp_top_lib.dsp_top_pkg.all;
use filterbanks_lib.all;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity fineDelay is
    generic (
        -- FBSelection chooses which filterbank we are operating on.
        --  0 = PSS (64 fine channels, 54 kept).
        --  1 = PST (256 fine channels, 216 kept)
        --  2 = Correlator (4096 fine channels, 3456 fine channels kept)
        FBSELECTION : integer := 0
    );
    port (
        i_clk         : in std_logic;
        -- data and header in
        i_data        : in t_FB_output_payload;  -- 16 bit data : .Hpol.re, Hpol.im, .Vpol.re, .Vpol.im 
        i_dataValid   : in std_logic;
        i_header      : in t_CT1_META_out; -- .HDeltaP(15:0), .VDeltaP(15:0), .frameCount(36:0), virtualChannel(15:0), .valid
        i_headerValid : in std_logic;  -- Must be a 1 clock pulse on the first clock of the packet.
        -- Data and Header out
        o_data        : out t_ctc_output_payload;   -- 8 bit data : .Hpol.re, Hpol.im, .Vpol.re, .Vpol.im 
        o_dataValid   : out std_logic;
        o_header      : out t_CT1_META_out; -- .HDeltaP(15:0), .VDeltaP(15:0), .frameCount(36:0), virtualChannel(15:0), .valid
        o_headerValid : out std_logic;
        -------------------------------------------
        -- control and monitoring
        -- Disable the fine delay. Instead of multiplying by the output of the sin/cos lookup, just scale by unity.
        i_disable     : in std_logic;
        -- Scale down by 2^(i_RFIScale) before clipping for RFI.
        -- Unity for the sin/cos lookup is 0x10000, so :
        --   i_RFIScale < 16  ==> Amplify the output of the filterbanks.
        --   i_RFIScale = 16  ==> Amplitude of the filterbank output is unchanged.
        --   i_RFIScale > 16  ==> Amplitude of the filterbank output is reduced.
        i_RFIScale    : in std_logic_vector(4 downto 0); 
        -- For monitoring of the output level.
        -- Higher level should keep track of : 
        --   * The total number of frames processed.
        --   * The sum of each of the outputs below. (but note one is superfluous since it can be calculated from the total frames processed and the sum of all the others).
        --      - These sums should be 32 bit values, which ensures wrapping will occur at most once per hour.
        -- For the correlator:
        --   - Each frame corresponds to 3456 fine channels x 2 (H & V polarisations) * 2 (re+im).
        --   - Every fine channel must be one of the categories below, so they will sum to 3456*2*2 = 13824.
        o_overflow    : out std_logic_vector(15 downto 0); -- Number of fine channels which were clipped.
        o_64_127      : out std_logic_vector(15 downto 0); -- Number of fine channels in the range 64 to 128.
        o_32_63       : out std_logic_vector(15 downto 0); -- Number of fine channels in the range 32 to 64.
        o_16_31       : out std_logic_vector(15 downto 0); -- Number of fine channels in the range 16 to 32.
        o_0_15        : out std_logic_vector(15 downto 0); -- Number of fine channels in the range 0 to 15.
        o_virtualChannel : out std_logic_vector(15 downto 0);
        o_histogramValid : out std_logic -- indicates histogram data is valid.
    );
end fineDelay;

architecture Behavioral of fineDelay is

    signal fineDelayDisable : std_logic;
    signal RFIScale : std_logic_vector(4 downto 0);
    
    signal headerDel1, headerDel2, headerDel3, headerDel4, headerDel5, headerDel6, headerDel7, headerDel8, headerDel9 : t_CT1_META_out;
    signal headerDel10, headerDel11, headerDel12, headerDel13, headerDel14, headerDel15, headerDel16, headerDel17, headerDel18 : t_CT1_META_out;
    signal validDel1, validDel2, validDel3, validDel4, validDel5, validDel6, validDel7, validDel8, validDel9 : std_logic;
    signal validDel10, validDel11, validDel12, validDel13, validDel14, validDel15, validDel16, validDel17, validDel18 : std_logic;
    signal hpol_phase_shift_ext : std_logic_vector(27 downto 0);
    signal hpol_phase_shift_extx2 : std_logic_vector(27 downto 0);
    signal hpol_phase_shift_extx8 : std_logic_vector(27 downto 0);
    signal hpol_phase_shift_extx16 : std_logic_vector(27 downto 0);
    signal hpol_phase_x3 : std_logic_vector(27 downto 0);
    signal hpol_phase_x24 : std_logic_vector(27 downto 0);
    signal hpol_phase_x27 : std_logic_vector(27 downto 0);

    signal vpol_phase_shift_ext : std_logic_vector(27 downto 0);
    signal vpol_phase_shift_extx2 : std_logic_vector(27 downto 0);
    signal vpol_phase_shift_extx8 : std_logic_vector(27 downto 0);
    signal vpol_phase_shift_extx16 : std_logic_vector(27 downto 0);
    signal vpol_phase_x3 : std_logic_vector(27 downto 0);
    signal vpol_phase_x24 : std_logic_vector(27 downto 0);
    signal vpol_phase_x27 : std_logic_vector(27 downto 0);
    
    signal HpolPhaseCurrent, VpolPhaseCurrent : std_logic_vector(27 downto 0);
    signal dataValidDel1, dataValidDel2, dataValidDel3, dataValidDel4, dataValidDel5, dataValidDel6, dataValidDel7, dataValidDel8, dataValidDel9 : std_logic;
    signal dataValidDel10, dataValidDel11, dataValidDel12, dataValidDel13, dataValidDel14, dataValidDel15, dataValidDel16, dataValidDel17, dataValidDel18 : std_logic;
    
    signal dataDel1, dataDel2, dataDel3, dataDel4, dataDel5, dataDel6, dataDel7, dataDel8, dataDel9 : t_FB_output_payload;
    signal dataDel10, dataDel11, dataDel12, dataDel13, dataDel14, dataDel15, dataDel16, dataDel17, dataDel18 : t_FB_output_payload;
    
    signal HpolMultIn, VpolMultIn : std_logic_vector(31 downto 0); 
    signal HpolMultOut, VpolMultOut : std_logic_vector(79 downto 0);
    signal HpolPhase, VpolPhase : std_logic_vector(15 downto 0);
    signal HpolSinCos, VpolSinCos : std_logic_vector(47 downto 0);
    
    signal HpolShiftReal43, VpolShiftReal43 : std_logic_vector(14 downto 0);
    signal HpolShiftImag43, VpolShiftImag43 : std_logic_vector(14 downto 0);
    signal HpolRealSaturated, VpolRealSaturated, HpolImagSaturated, VpolImagSaturated : std_logic;
    signal HpolRealLowZero, VpolRealLowZero, HpolImagLowZero, VpolImagLowZero : std_logic;
    
    signal HpolRealRounded, HpolImagRounded, VpolRealRounded, VpolImagRounded : std_logic_vector(7 downto 0);
    signal soverflow, s64_127, s32_63, s16_31, s0_15 : std_logic_vector(3 downto 0);
    
    signal soverflowCount, s64_127Count, s32_63Count, s16_31Count, s0_15Count : std_logic_vector(2 downto 0);
    signal soverflowCountExt, s64_127CountExt, s32_63CountExt, s16_31CountExt, s0_15CountExt : std_logic_vector(15 downto 0);
    signal countOverflow, count64_127, count32_63, count16_31, count0_15 : std_logic_vector(15 downto 0);
    signal dataValidDel19 : std_logic;
    signal virtualChannel : std_logic_vector(15 downto 0);
    
    -- create_ip -name dds_compiler -vendor xilinx.com -library ip -version 6.0 -module_name GenSinCos
    -- set_property -dict [list CONFIG.Component_Name {GenSinCos} CONFIG.PartsPresent {SIN_COS_LUT_only} CONFIG.Noise_Shaping {None} CONFIG.Phase_Width {13} CONFIG.Output_Width {18} CONFIG.Amplitude_Mode {Unit_Circle} CONFIG.Parameter_Entry {Hardware_Parameters} CONFIG.Has_Phase_Out {false} CONFIG.DATA_Has_TLAST {Not_Required} CONFIG.S_PHASE_Has_TUSER {Not_Required} CONFIG.M_DATA_Has_TUSER {Not_Required} CONFIG.Latency {6} CONFIG.Output_Frequency1 {0} CONFIG.PINC1 {0}] [get_ips GenSinCos]
    -- Uses 1 x 36k BRAM.
    component GenSinCos
    port (
        aclk                : in std_logic;
        s_axis_phase_tvalid : in std_logic;
        s_axis_phase_tdata  : in std_logic_vector(15 downto 0);   -- signed input, only bits(12:0) used
        m_axis_data_tvalid  : out std_logic;                      -- 6 cycle latency.
        m_axis_data_tdata   : out std_logic_vector(47 downto 0)); -- bits(17:0) = cosine, bits(41:24) = sine, 1/2 scale, so unity is 0x10000 
    end component;
    
    -- create_ip -name cmpy -vendor xilinx.com -library ip -version 6.0 -module_name FineDelayComplexMult
    -- set_property -dict [list CONFIG.Component_Name {FineDelayComplexMult} CONFIG.BPortWidth {18} CONFIG.OptimizeGoal {Performance} CONFIG.RoundMode {Truncate} CONFIG.OutputWidth {35} CONFIG.MinimumLatency {4}] [get_ips FineDelayComplexMult]
    component FineDelayComplexMult
    port (
        aclk               : in std_logic;
        s_axis_a_tvalid    : in std_logic;
        s_axis_a_tdata     : in std_logic_vector(31 downto 0); -- (15:0) = real, (31:16) = imaginary
        s_axis_b_tvalid    : in std_logic;
        s_axis_b_tdata     : in std_logic_vector(47 downto 0); -- (17:0) = real, (41:24) = imaginary.
        m_axis_dout_tvalid : out std_logic;
        m_axis_dout_tdata  : out std_logic_vector(79 downto 0));  -- 4 cycle latency
    end component;
    
    
begin
    
    hpol_phase_shift_ext    <=  
        "000000000000" & headerDel1.HDeltaP when headerDel1.HDeltaP(15) = '0' else 
        "111111111111" & headerDel1.hDeltaP;
    hpol_phase_shift_extx2  <=  
        "00000000000" & headerDel1.HDeltaP & '0' when headerDel1.HDeltaP(15) = '0' else
        "11111111111" & headerDel1.HDeltaP & '0';
    hpol_phase_shift_extx8  <= 
        "000000000" & headerDel1.HDeltaP & "000" when headerDel1.HDeltaP(15) = '0' else
        "111111111" & headerDel1.HDeltaP & "000";
    hpol_phase_shift_extx16 <= 
        "00000000" & headerDel1.HDeltaP & "0000" when headerDel1.HDeltaP(15) = '0' else
        "11111111" & headerDel1.HDeltaP & "0000";

    vpol_phase_shift_ext    <=  
        "000000000000" & headerDel1.VDeltaP when headerDel1.VDeltaP(15) = '0' else 
        "111111111111" & headerDel1.VDeltaP;
    vpol_phase_shift_extx2  <=  
        "00000000000" & headerDel1.VDeltaP & '0' when headerDel1.VDeltaP(15) = '0' else
        "11111111111" & headerDel1.VDeltaP & '0';
    vpol_phase_shift_extx8  <= 
        "000000000" & headerDel1.VDeltaP & "000" when headerDel1.VDeltaP(15) = '0' else
        "111111111" & headerDel1.VDeltaP & "000";
    vpol_phase_shift_extx16 <= 
        "00000000" & headerDel1.VDeltaP & "0000" when headerDel1.VDeltaP(15) = '0' else
        "11111111" & headerDel1.VDeltaP & "0000";
    
    hpol_phase_x24 <= hpol_phase_x3(24 downto 0) & "000";
    vpol_phase_x24 <= vpol_phase_x3(24 downto 0) & "000";
    
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            
            fineDelayDisable <= i_disable;
            RFIScale <= i_RFIScale;
            
            -- First pipeline stage; capture header and data.
            if i_headerValid = '1' then
                headerDel1 <= i_header;
            end if;
            validDel1 <= i_headerValid;
            dataDel1 <= i_data;
            dataValidDel1 <= i_dataValid;
            
            -- Second pipeline stage; get phase * 3
            hpol_phase_x3 <= std_logic_vector(signed(hpol_phase_shift_ext) + signed(hpol_phase_shift_extx2));
            vpol_phase_x3 <= std_logic_vector(signed(vpol_phase_shift_ext) + signed(vpol_phase_shift_extx2));
            headerDel2 <= headerDel1;
            dataDel2 <= dataDel1;
            validDel2 <= validDel1;
            dataValidDel2 <= dataValidDel1;
            
            -- 3rd pipeline stage; get phase * 27
            hpol_phase_x27 <= std_logic_vector(signed(hpol_phase_x3) + signed(hpol_phase_x24));
            vpol_phase_x27 <= std_logic_vector(signed(vpol_phase_x3) + signed(vpol_phase_x24));
            headerDel3 <= headerDel2;
            dataDel3 <= dataDel2;
            validDel3 <= validDel2;
            dataValidDel3 <= dataValidDel2;
            
            -- 4th pipeline stage; 
            --  - at the start of the packet, get the first phase to use ( = -phase * 27, with a scale factor depending on generic FBSelection)
            --  - at other times, add to the phase to step across the band (e.g. for correlator, phase = phase + phaseIn/2048).
            if fineDelayDisable = '1' then
                HpolPhaseCurrent <= (others => '0');
                VpolPhaseCurrent <= (others => '0');
            elsif validDel3 = '1' then 
                -- validDel3 is a pulse at the start of the packet.
                if (FBSELECTION = 0) then -- PSS
                    -- HOffsetP uses 32768 to represent pi radians.
                    -- Scale up by 2^5 here.
                    -- Then scale down by 2^8 to get HPolPhase. which is the input to the sin/cos LUT component.
                    -- Input to the sin/cos LUT is 4096 for pi radians. check: 32768 * 2^5 / 2^8 = 4096.
                    HpolPhaseCurrent <= std_logic_vector(shift_left(resize(signed(headerDel3.HOffsetP),28),5) - shift_left(signed(hpol_phase_x27),1));
                    VpolPhaseCurrent <= std_logic_vector(shift_left(resize(signed(headerDel3.VOffsetP),28),5) - shift_left(signed(vpol_phase_x27),1));
                elsif (FBSELECTION = 1) then -- PST, multiply by 4 compared with PSS (216 channels vs. 54)
                    HpolPhaseCurrent <= std_logic_vector(shift_left(resize(signed(headerDel3.HOffsetP),28),7) - shift_left(signed(hpol_phase_x27),3));
                    VpolPhaseCurrent <= std_logic_vector(shift_left(resize(signed(headerDel3.VOffsetP),28),7) - shift_left(signed(vpol_phase_x27),3));
                else  -- Correlator, multiply by 64 compared with PSS (3456 channels vs. 54)
                    HpolPhaseCurrent <= std_logic_vector(shift_left(resize(signed(headerDel3.HOffsetP),28),11) - shift_left(signed(hpol_phase_x27),7));
                    VpolPhaseCurrent <= std_logic_vector(shift_left(resize(signed(headerDel3.VOffsetP),28),11) - shift_left(signed(vpol_phase_x27),7));
                end if;
            elsif dataValidDel3 = '1' then
                -- Accumulate the phase across the band.
                -- Note this only occurs on the second clock of the frame, so headerDel4 is correct.
                HpolPhaseCurrent <= std_logic_vector(signed(HpolPhaseCurrent) + shift_left(resize(signed(headerDel4.HDeltaP),28),1));
                VpolPhaseCurrent <= std_logic_vector(signed(VpolPhaseCurrent) + shift_left(resize(signed(headerDel4.VDeltaP),28),1));
            end if;
            headerDel4 <= headerDel3;
            dataDel4 <= dataDel3;
            validDel4 <= validDel3;
            dataValidDel4 <= dataValidDel3;
            
            headerDel5 <= headerDel4;
            dataDel5 <= dataDel4;
            validDel5 <= validDel4;
            dataValidDel5 <= dataValidDel4;
            
            headerDel6 <= headerDel5;
            dataDel6 <= dataDel5;
            validDel6 <= validDel5;
            dataValidDel6 <= dataValidDel5;

            headerDel7 <= headerDel6;
            dataDel7 <= dataDel6;
            validDel7 <= validDel6;
            dataValidDel7 <= dataValidDel6;

            headerDel8 <= headerDel7;
            dataDel8 <= dataDel7;
            validDel8 <= validDel7;
            dataValidDel8 <= dataValidDel7;
            
            headerDel9 <= headerDel8;
            dataDel9 <= dataDel8;
            validDel9 <= validDel8;
            dataValidDel9 <= dataValidDel8;
            
            -- 6 cycle latency for the sin/cos lookup, so sin/cos lookup is valid on Del10. 
            headerDel10 <= headerDel9;
            dataDel10 <= dataDel9;
            validDel10 <= validDel9;
            dataValidDel10 <= dataValidDel9;
            
            headerDel11 <= headerDel10;
            dataDel11 <= dataDel10;
            validDel11 <= validDel10;
            dataValidDel11 <= dataValidDel10;
            
            headerDel12 <= headerDel11;
            dataDel12 <= dataDel11;
            validDel12 <= validDel11;
            dataValidDel12 <= dataValidDel11;

            headerDel13 <= headerDel12;
            dataDel13 <= dataDel12;
            validDel13 <= validDel12;
            dataValidDel13 <= dataValidDel12;

            -- Phase is valid on del4.
            --  - 6 clocks for the sinCos lookup
            --  - 4 clocks for the complex multiplication
            -- So the result of the complex multiplication is valid on del14.
            headerDel14 <= headerDel13;
            dataDel14 <= dataDel13;
            validDel14 <= validDel13;
            dataValidDel14 <= dataValidDel13;
            
            -- Scale by i_RFIScale(4:3) (in "ShiftandRound" modules)
            headerDel15 <= headerDel14;
            dataDel15 <= dataDel14;
            validDel15 <= validDel14;
            dataValidDel15 <= dataValidDel14;
            
            -- Scale by RFIScale(2:0), and calculate the convergent rounding. (in "ShiftandRound" modules)
            headerDel16 <= headerDel15;
            dataDel16 <= dataDel15;
            validDel16 <= validDel15;
            dataValidDel16 <= dataValidDel15;

            -- Apply convergent rounding (in "ShiftandRound" modules)
            headerDel17 <= headerDel16;
            dataDel17 <= dataDel16;
            validDel17 <= validDel16;
            dataValidDel17 <= dataValidDel16;

            -- Saturate (in "ShiftandRound" modules)
            headerDel18 <= headerDel17;
            dataDel18 <= dataDel17;
            validDel18 <= validDel17;
            dataValidDel18 <= dataValidDel17;            
            
            --------------------------------------------------------------------
            -- Log statistics and generate the output data.
            o_data.Hpol.re <= HpolRealRounded; 
            o_data.Hpol.im <= HpolImagRounded;
            o_data.Vpol.re <= VpolRealRounded;
            o_data.Vpol.im <= VpolImagRounded;
            o_dataValid <= dataValidDel18;
            o_header <= headerDel18;
            o_headerValid <= validDel18;
            if validDel18 = '1' then -- first output sample in a packet
                virtualChannel <= headerDel18.virtualChannel;
                countOverflow <=  soverflowCountExt;
                count64_127   <=  s64_127CountExt;
                count32_63    <=  s32_63CountExt;
                count16_31    <=  s16_31CountExt;
                count0_15     <=  s0_15CountExt;
            elsif dataValidDel18 = '1' then  -- data output samples.
                countOverflow <= std_logic_vector(unsigned(countOverflow) + unsigned(soverflowCountExt));
                count64_127   <= std_logic_vector(unsigned(count64_127) + unsigned(s64_127CountExt));
                count32_63    <= std_logic_vector(unsigned(count32_63) + unsigned(s32_63CountExt));
                count16_31    <= std_logic_vector(unsigned(count16_31) + unsigned(s16_31CountExt));
                count0_15     <= std_logic_vector(unsigned(count0_15) + unsigned(s0_15CountExt));
            end if;
            
            dataValidDel19 <= dataValidDel18;
            if dataValidDel19 = '1' and dataValidDel18 = '0' then -- falling edge, output the histogram counts
                o_overflow  <= countOverflow; -- Number of fine channels which were clipped.
                o_64_127    <= count64_127;   -- Number of fine channels in the range 64 to 128.
                o_32_63     <= count32_63;    -- Number of fine channels in the range 32 to 64.
                o_16_31     <= count16_31;    -- Number of fine channels in the range 16 to 32.
                o_0_15      <= count0_15;     -- Number of fine channels in the range 0 to 15.
                o_virtualChannel <= virtualChannel;
                o_histogramValid <= '1';
            else
                o_histogramValid <= '0';
            end if;
            
        end if;
    end process;
    
    -- 13 bit representation for the sin/cos lookup, so divide by 8 to convert from 16 bits.
    -- HpolPhaseCurrent is scaled up by a factor of 1, 4, or 64 (depending on FBSELECTION), so that
    -- it can be incremented by headerDel4.HDeltaP. It then has to be scaled down here to get the correct 
    -- scale at the input to the sin/cos lookup.
    HpolPhase <= 
        HpolPhaseCurrent(23 downto 8) when (FBSELECTION = 0) else    -- PSS
        HpolPhaseCurrent(25 downto 10) when (FBSELECTION = 1) else   -- PST
        HpolPhaseCurrent(27) & HpolPhaseCurrent(27) & HpolPhaseCurrent(27 downto 14);  -- Correlator
    VpolPhase <= 
        VpolPhaseCurrent(23 downto 8) when (FBSELECTION = 0) else
        VpolPhaseCurrent(25 downto 10) when (FBSELECTION = 1) else
        VpolPhaseCurrent(27) & VpolPhaseCurrent(27) & VpolPhaseCurrent(27 downto 14);
    
    -- Phase is represented with 13 bits.
    -- e.g. An unsigned input value of 4096 corresponds to pi radians.
    HpolGenSinCos : GenSinCos
    port map (
        aclk => i_clk,
        s_axis_phase_tvalid => '1',
        s_axis_phase_tdata => HpolPhase,
        m_axis_data_tvalid => open,
        m_axis_data_tdata => HpolSinCos
    );    
    
    VPolGenSinCos : GenSinCos
    port map (
        aclk => i_clk,
        s_axis_phase_tvalid => '1',
        s_axis_phase_tdata => VpolPhase,
        m_axis_data_tvalid => open,
        m_axis_data_tdata => VpolSinCos    
    );

    HpolMultIn(15 downto 0) <= dataDel10.hpol.re;
    HpolMultIn(31 downto 16) <= dataDel10.hpol.im;

    HpolMult : FineDelayComplexMult
    port map (
        aclk               => i_clk,
        s_axis_a_tvalid    => '1',
        s_axis_a_tdata     => HpolMultIn,    -- (31:0), (15:0) = real, (31:16) = imaginary.
        s_axis_b_tvalid    => '1',
        s_axis_b_tdata     => HpolSinCos,    -- (47:0), (17:0) = real, (41:24) = imaginary.
        m_axis_dout_tvalid => open,          -- 4 cycle latency
        m_axis_dout_tdata  => HpolMultOut    -- (79:0), (34:0) = real, (74:40) = imaginary.
    );

    VpolMultIn(15 downto 0) <= dataDel10.vpol.re;
    VpolMultIn(31 downto 16) <= dataDel10.vpol.im;

    VpolMult : FineDelayComplexMult
    port map (
        aclk               => i_clk,
        s_axis_a_tvalid    => '1',
        s_axis_a_tdata     => VpolMultIn,   -- (31:0), (15:0) = real, (31:16) = imaginary.
        s_axis_b_tvalid    => '1',
        s_axis_b_tdata     => VpolSinCos,   -- (47:0), (17:0) = real, (41:24) = imaginary.
        m_axis_dout_tvalid => open,         -- 4 cycle latency
        m_axis_dout_tdata  => VpolMultOut   -- (79:0), (34:0) = real, (74:40) = imaginary.
    );
    
    
    HpolRealSR : entity filterbanks_lib.ShiftandRound
    port map(
        i_clk   => i_clk,
        i_shift => RFIScale, --  in(4:0);
        i_data  => HpolMultOut(34 downto 0),  -- in(34:0);
        o_data16 => open,                     -- out(15:0);  -- 3 cycle latency
        o_data8  => HpolRealRounded,          -- out(7:0)    -- 4 cycle latency
        -- statistics on the amplitude of o_data8
        o_overflow => soverflow(0), -- out std_logic; 4 cycle latency, aligns with o_data8
        o_64_127   => s64_127(0),  -- out std_logic; output is in the range 64 to 127
        o_32_63    => s32_63(0),   -- out std_logic; output is in the range 32 to 64.
        o_16_31    => s16_31(0),   -- out std_logic; output is in the range 16 to 32.
        o_0_15     => s0_15(0)     -- out std_logic; output is in the range 0 to 15
    );
    
    
    
    HpolImagSR : entity filterbanks_lib.ShiftandRound
    port map(
        i_clk   => i_clk,
        i_shift => RFIScale, --  in(4:0);
        i_data  => HpolMultOut(74 downto 40), -- in(34:0);
        o_data16 => open,                     -- out(15:0);  -- 3 cycle latency
        o_data8  => HpolImagRounded,          -- out(7:0)    -- 4 cycle latency
        -- statistics on the amplitude of o_data8
        o_overflow => soverflow(1), -- out std_logic; 4 cycle latency, aligns with o_data8
        o_64_127   => s64_127(1),  -- out std_logic; output is in the range 64 to 127
        o_32_63    => s32_63(1),   -- out std_logic; output is in the range 32 to 64.
        o_16_31    => s16_31(1),   -- out std_logic; output is in the range 16 to 32.
        o_0_15     => s0_15(1)     -- out std_logic; output is in the range 0 to 15        
    );

    VpolRealSR : entity filterbanks_lib.ShiftandRound
    port map(
        i_clk   => i_clk,
        i_shift => RFIScale, --  in(4:0);
        i_data  => VpolMultOut(34 downto 0),  -- in(34:0);
        o_data16 => open,                     -- out(15:0);  -- 3 cycle latency
        o_data8  => VpolRealRounded,          -- out(7:0)    -- 4 cycle latency
        -- statistics on the amplitude of o_data8
        o_overflow => soverflow(2), -- out std_logic; 4 cycle latency, aligns with o_data8
        o_64_127   => s64_127(2),  -- out std_logic; output is in the range 64 to 127
        o_32_63    => s32_63(2),   -- out std_logic; output is in the range 32 to 64.
        o_16_31    => s16_31(2),   -- out std_logic; output is in the range 16 to 32.
        o_0_15     => s0_15(2)     -- out std_logic; output is in the range 0 to 15 
    );

    VpolImagSR : entity filterbanks_lib.ShiftandRound
    port map(
        i_clk   => i_clk,
        i_shift => RFIScale, --  in(4:0);
        i_data  => VpolMultOut(74 downto 40),  -- in(34:0);
        o_data16 => open,                     -- out(15:0);  -- 3 cycle latency
        o_data8  => VpolImagRounded,           -- out(7:0)    -- 4 cycle latency
        -- statistics on the amplitude of o_data8
        o_overflow => soverflow(3), -- out std_logic; 4 cycle latency, aligns with o_data8
        o_64_127   => s64_127(3),  -- out std_logic; output is in the range 64 to 127
        o_32_63    => s32_63(3),   -- out std_logic; output is in the range 32 to 64.
        o_16_31    => s16_31(3),   -- out std_logic; output is in the range 16 to 32.
        o_0_15     => s0_15(3)     -- out std_logic; output is in the range 0 to 15
    );

    -- Convert bit vectors to counts of the number of occurrences.
    with soverflow select
        soverflowCount <= 
            "000" when "0000",
            "001" when "0001",
            "001" when "0010",
            "010" when "0011",
            "001" when "0100",
            "010" when "0101",
            "010" when "0110",
            "011" when "0111",
            "001" when "1000",
            "010" when "1001",
            "010" when "1010",
            "011" when "1011",
            "010" when "1100",
            "011" when "1101",
            "011" when "1110",
            "100" when others;  -- i.e. "1111";
    
    with s64_127 select
        s64_127Count <= 
            "000" when "0000",
            "001" when "0001",
            "001" when "0010",
            "010" when "0011",
            "001" when "0100",
            "010" when "0101",
            "010" when "0110",
            "011" when "0111",
            "001" when "1000",
            "010" when "1001",
            "010" when "1010",
            "011" when "1011",
            "010" when "1100",
            "011" when "1101",
            "011" when "1110",
            "100" when others;  -- i.e. "1111";

    with s32_63 select
        s32_63Count <= 
            "000" when "0000",
            "001" when "0001",
            "001" when "0010",
            "010" when "0011",
            "001" when "0100",
            "010" when "0101",
            "010" when "0110",
            "011" when "0111",
            "001" when "1000",
            "010" when "1001",
            "010" when "1010",
            "011" when "1011",
            "010" when "1100",
            "011" when "1101",
            "011" when "1110",
            "100" when others;  -- i.e. "1111";

    with s16_31 select
        s16_31Count <= 
            "000" when "0000",
            "001" when "0001",
            "001" when "0010",
            "010" when "0011",
            "001" when "0100",
            "010" when "0101",
            "010" when "0110",
            "011" when "0111",
            "001" when "1000",
            "010" when "1001",
            "010" when "1010",
            "011" when "1011",
            "010" when "1100",
            "011" when "1101",
            "011" when "1110",
            "100" when others;  -- i.e. "1111";
            
    with s0_15 select
        s0_15Count <= 
            "000" when "0000",
            "001" when "0001",
            "001" when "0010",
            "010" when "0011",
            "001" when "0100",
            "010" when "0101",
            "010" when "0110",
            "011" when "0111",
            "001" when "1000",
            "010" when "1001",
            "010" when "1010",
            "011" when "1011",
            "010" when "1100",
            "011" when "1101",
            "011" when "1110",
            "100" when others;  -- i.e. "1111";
    
    soverflowCountExt <= "0000000000000" & soverflowCount;
    s64_127CountExt   <= "0000000000000" & s64_127Count;
    s32_63CountExt    <= "0000000000000" & s32_63Count;
    s16_31CountExt    <= "0000000000000" & s16_31Count;
    s0_15CountExt     <= "0000000000000" & s0_15Count;
    
    
    
end Behavioral;
