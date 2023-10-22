----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey
-- 
-- Create Date: 04 june 2023 01:11:00 AM
-- Module Name: poly_eval - Behavioral
-- Description: 
--  Evaluate Delay polynomials.
--  Each polynomial is defined by 6 double precision values that are read from the
--  memory (o_rd_addr, i_rd_data).
--  A seventh value defines the sky frequency in cycles per ns = GHz = (freq in Hz) * 1e-9.
--
-- For the correlator, we have to evaluate the polynomials 
--  - 4 different polynomials 
--      - (because the corner turn sends on 4 virtual channels at a time)
--  - New value required at least once every 4096 clocks.
--     - (For PST once every 256 clocks, for PSS every 64 clocks.)
--  - 64 values are generated per corner turn frame
--     - 64 * (4096 samples) * (1080ns/sample) = 283.11552 ms
--     - Time step between packets = 4096*1080ns = 4423680 ns = 0.004423680 seconds
--
--
--  Polynomial data is stored in a memory block that this module accesses through 
--  the "o_rd_addr", "i_rd_data" ports.
--  Within that memory :
--    words 0 to 9 : Config for virtual channel 0, buffer 0 (see below for specification of contents)
--    words 10 to 19 : Config for virtual channel 1, buffer 0
--    ...
--    words 10230 to 10239 : Config for virtual channel 1023, first buffer
--    words 10240 to 20479 : Config for all 1024 virtual channels, second buffer
--
--  Polynomial data is stored in the memory as a block of 9 x 64bit words for each virtual channel:   
--      word 0 = c0,
--       ...  
--      word 5 = c5,
--               c0 to c5 are double precision floating point values for the delay polynomial :
--               c0 + c1*t + c2 * t^2 + c3 * t^3 + c4 * t^4 + c5 * t^5
--               Units for c0,.. c5 are ns/s^k for k=0,1,..5
--      word 6 = Sky frequency in GHz
--               Used to convert the delay (in ns) to a phase rotation.
--               (delay in ns) * (sky frequency in GHz) = # of rotations
--               From the Matlab code:
--                % Phase Rotation
--                %  The sampling point is (DelayOffset_all * Ts)*1e-9 ns
--                %  then multiply by the center frequency (CF) to get the number of rotations.
--                %
--                %  The number of cycles of the center frequency per output sample is not an integer due to the oversampling of the LFAA data.
--                %  For example, for coarse channel 65, the center frequency is 65 * 781250 Hz = 50781250 Hz.
--                %  50781250 Hz = a period of 1/50781250 = 19.692 ns. The sampling period for the LFAA data is 1080 ns, so 
--                %  a signal at the center of channel 65 goes through 1080/19.692 = 54.8438 cycles. 
--                %  So a delay which is an integer number of LFAA samples still requires a phase shift to be correct.
--                resampled = resampled .* exp(1i * 2*pi*DelayOffset_all * Ts * 1e-9 * CF);
--                # Note : DelayOffset_all = delay in number of samples (of period Ts)
--                #        Ts = sample period in ns (i.e. 1080 for SPS data)
--                #        CF = channel center frequency in Hz, e.g. 65 * 781250 = 50781250 for the first SPS channel
--                #        - The value [Ts * 1e-9 * CF] is the value stored here.
--
--      word 7 = buf_offset_seconds : seconds from the polynomial epoch to the start of the integration period, as a double precision value 
--              
--      word 8 = double precision offset in ns for the second polarisation (relative to the first polarisation).   
--
--      word 9 = Validity time
--               - bits 31:0 = buf_integration : Integration period at which the polynomial becomes valid. Integration period
--                             is in units of 0.84934656 seconds, i.e. units of (384 SPS packets) 
--               - bit 32 = Entry is valid.
--
-- -------------------------------------------------------------------------------
-- Processing Steps :
--  - Work out which polynomial is valid for each virtual channel:
--      - Read word 7 (validity time) for the two buffers
--        Pick the correct buffer
--  - Determine the time to use for "t" in the polynomial.
--      - Note "t" can be different for each virtual channel, since each virtual 
--        channel can have a different validity time
--      - To calculate t :
--          - Find integrations from start of validity 
--              integration_offset = i_integration - buf_integration
--              integration_offset_seconds = (double)(integration_offset * 0.849346560)
--              integration_offset_epoch = integration_offset_seconds + buf_offset_seconds
--              ct_frame_offset_epoch = integration_offset_epoch + [0, 283115520, 566231040]
--                  (offset for the corner turn frame within an integration)
--          - For each new time sample within a corner turn frame, 
--              add (4096*1080e-9) = 4.4368 ms = 0.004423680 seconds
--  - Evaluate polynomial to get a delay in samples and phase offset:
--      - get c0
--      - get c1
--      - * : c1 * t
--      - + : c0 + c1*t
--      - * : t*t
--      - * : c2*t*t
--      - + : c0 + c1*t + c2*t*t
--      - * : t*t*t
--      - * : c3*t*t*t
--      - + : c0 + c1*t + c2*t*t + c3*t*t*t
--      - * : t*t*t*t
--      - * : c4*t*t*t*t
--      - + : c0 + c1*t + c2*t*t + c3*t*t*t + c4*t*t*t*t
--      - * : t*t*t*t*t
--      - * : c5*t*t*t*t*t
--      - + : delay_ns_hpol = c0 + c1*t + c2*t*t + c3*t*t*t + c4*t*t*t*t + c5*t*t*t*t*t
--      - + : delay_ns_vpol = delay_ns_hpol + offset (offset comes from config memory word 9)
--      - * : delay_samples_hpol = delay_ns_hpol * (1/1080ns)
--          : delay_samples_vpol = delay_ns_vpol * (1/1080ns)
--          - Convert to 32.32 bit fixed point value
--          - Integer part of delay_samples_hpol is o_sample_offset
--          - fractional part is o_hpol_deltaP, as a 14 bit value
--               so .111111111 => o_hpol_deltaP = 16383
--          - subtract off the integer part of delay_samples_hpol from delay_samples_vpol
--               -> gives o_vpol_deltaP
--      - * : Hpol rotations = (double) delay_ns_hpol * (sky_frequency_GHz) 
--      - * : Vpol rotations = (double) delay_ns_hpol * (sky_frequency_GHz)
--      - to_int : o_Hpol_phase = (int64) Hpol rotations
--                 o_Vpol_phase = (int64) Vpol rotations
--                 - o_Hpol/Vpol_phase = fractional bits of hpol/vpol_phase  
--
--
-- fsm states : 
--   Per virtual channel -(1) (a) Read validity time buffer 0
--                            (b) Read validity time buffer 1
--                            - Trigger pipeline to calculate :
--                                - 
--                        (2) 
--                        (2) (a) Read c0
--                            (b) Read c1
--
----------------------------------------------------------------------------------
library IEEE, ct_lib;
use IEEE.STD_LOGIC_1164.ALL;
library vd_datagen_lib;
use IEEE.NUMERIC_STD.ALL;
library common_lib;
USE common_lib.common_pkg.ALL;

entity poly_eval is
    generic(
        -- Number of virtual channels to generate in at a time, code supports up to 16
        -- Code assumes at least 4, otherwise it would need extra delays to wait for data to return from the memory. 
        g_VIRTUAL_CHANNELS : integer range 4 to 16 := 4;
        g_VC_LOG2 : integer := 2
    );
    port(
        clk : in std_logic;
        -- First output after a reset will reset the data generation
        i_rst : in std_logic;
        -- Control
        i_start            : in std_logic; -- start on a batch of 4 polynomials
        i_virtual_channels : in t_slv_16_arr((g_VIRTUAL_CHANNELS-1) downto 0); -- List of virtual channels to evaluate; this maps to the address in the lookup table.
        i_integration      : in std_logic_vector(31 downto 0); -- which integration is this for ?
        i_ct_frame         : in std_logic_vector(1 downto 0);     -- 3 corner turn frames per integration
        o_idle             : out std_logic;
        
        -- read the config memory (to get polynomial coefficients)
        -- Block ram interface for access by the rest of the module
        -- Memory is 20480 x 8 byte words = (2 buffers) x (10240 words) = (1024 virtual channels) x (10 words)
        -- read latency 3 clocks
        o_rd_addr  : out std_logic_vector(14 downto 0);
        i_rd_data  : in std_logic_vector(63 downto 0);  -- 3 clock latency.
        
        
        -----------------------------------------------------------------------
        -- Output delay parameters 
        -- For each pulse on i_start, this module generates 64*4 = 256 outputs
        -- in bursts of 4 outputs. (4 virtual channels, 64 time samples)
        --
        -- For each virtual channel :
        --  - Virtual channel. 15 bits. Copy of one of the i_poly entries
        --  - packet count. 8 bits. Counts from 0 to 63 for the 64 output packets generated by the correlator 
        --                          per 283ms corner turn frame. 
        --  - Coarse delay : 11 bits. Number of 1080ns samples to delay by
        --  - bufHpolDeltaP : 16 bits. Delay as a phase step across the coarse channel
        --  - bufHpolPhase  : 16 bits. Phase offset for H pol
        --  - bufVpolDeltaP : 16 bits. Delay as a phase step across the coarse channel
        --  - bufVpolPhase  : 16 bits. Phase offset for V pol
        o_vc : out std_logic_vector(15 downto 0);
        o_packet : out std_logic_vector(15 downto 0);
        --
        o_sample_offset : out std_logic_vector(11 downto 0); -- Number of whole 1080ns samples to delay by.
        -- Units for deltaP are rotations; 1 sign bit, 15 fractional bits.
        -- So pi radians at the band edge = 16384.
        -- As a fraction of a coarse sample, 1 coarse sample = pi radian at the band edge = 16384
        --                                   0.5 coarse samples = pi/2 radians at the band edge = 8192
        o_Hpol_deltaP : out std_logic_vector(15 downto 0);
        -- Phase uses 32768 to represent pi radians. Note this differs by a factor of 2 compared with Hpol_deltaP.
        o_Hpol_phase : out std_logic_vector(15 downto 0);
        o_Vpol_deltaP : out std_logic_vector(15 downto 0);
        o_Vpol_phase : out std_logic_vector(15 downto 0);
        o_valid : out std_logic
    );
end poly_eval;

architecture Behavioral of poly_eval is

    -- double precision 1e-9
    constant c_fp64_1eMinus9 : std_logic_vector(63 downto 0) := x"3E112E0BE826D695";
    -- double precision 0.849346560 = (1080ns) * (2048 samples per packet) * (384 packets per frame)
    constant c_fp64_0p849346560 : std_logic_vector(63 downto 0) := x"3FEB2DD8D6457179";
    -- one corner turn frame = 1080ns * 2048 * 128 = 0.283115520 seconds
    constant c_fp64_0p283115520 : std_logic_vector(63 downto 0) := x"3FD21E908ED8F651";
    -- two corner turn frames = 1080ns * 2048 * 128 * 2 = 0.566231040
    constant c_fp64_0p566231040 : std_logic_vector(63 downto 0) := x"3FE21E908ED8F651";
    
    -- Need to multiply time in ns by the period in ns to get number of samples,
    -- divide by 1080 = multiply by 1/1080
    constant c_fp64_rate : std_logic_vector(63 downto 0) := x"3F4E573AC901E574"; -- = 1/1080    

    COMPONENT fp64_add
    PORT (
        aclk : IN STD_LOGIC;
        s_axis_a_tvalid : IN STD_LOGIC;
        s_axis_a_tdata : IN STD_LOGIC_VECTOR(63 DOWNTO 0);
        s_axis_b_tvalid : IN STD_LOGIC;
        s_axis_b_tdata : IN STD_LOGIC_VECTOR(63 DOWNTO 0);
        m_axis_result_tvalid : OUT STD_LOGIC;
        m_axis_result_tdata : OUT STD_LOGIC_VECTOR(63 DOWNTO 0));
    END COMPONENT;
    
    COMPONENT fp64_mult
    PORT (
        aclk : IN STD_LOGIC;
        s_axis_a_tvalid : IN STD_LOGIC;
        s_axis_a_tdata : IN STD_LOGIC_VECTOR(63 DOWNTO 0);
        s_axis_b_tvalid : IN STD_LOGIC;
        s_axis_b_tdata : IN STD_LOGIC_VECTOR(63 DOWNTO 0);
        m_axis_result_tvalid : OUT STD_LOGIC;
        m_axis_result_tdata : OUT STD_LOGIC_VECTOR(63 DOWNTO 0));
    END COMPONENT;

    COMPONENT fp64_to_int
    PORT (
        aclk : IN STD_LOGIC;
        s_axis_a_tvalid : IN STD_LOGIC;
        s_axis_a_tdata : IN STD_LOGIC_VECTOR(63 DOWNTO 0);
        m_axis_result_tvalid : OUT STD_LOGIC;
        m_axis_result_tdata : OUT STD_LOGIC_VECTOR(63 DOWNTO 0));
    END COMPONENT;

    component uint64_to_double
    port (
        aclk : in std_logic;
        s_axis_a_tvalid : in std_logic;
        s_axis_a_tdata : in std_logic_vector(63 downto 0);
        m_axis_result_tvalid : out std_logic;
        m_axis_result_tdata : out std_logic_vector(63 downto 0));
    end component;
    
    signal poly_term : std_logic_vector(63 downto 0);
    signal time_ns : std_logic_vector(63 downto 0);
    signal time_s : std_logic_vector(63 downto 0);
    signal running : std_logic := '0';
    signal start_del1, start_del2 : std_logic := '0';
    signal phase_del : t_slv_4_arr(32 downto 0);
    signal phase_count_del : t_slv_11_arr(32 downto 0);
    signal short_phase : std_logic;
    signal coef_buf : std_logic;
    signal fp64_add_valid_in, fp64_mult_valid_in, fp64_to_int_valid_in : std_logic := '0';
    signal fp64_add_din0, fp64_add_din1, fp64_add_dout : std_logic_vector(63 downto 0);
    signal fp64_mult_din0, fp64_mult_din1, fp64_mult_dout : std_logic_vector(63 downto 0);
    signal fp64_add_valid_out, fp64_mult_valid_out, fp64_to_int_valid_out : std_logic := '0';
    signal fp64_to_int_din, fp64_to_int_dout : std_logic_vector(63 downto 0);
    
    signal int_to_fp64_valid_in, int_to_fp64_valid_out : std_logic;
    signal int_to_fp64_din, int_to_fp64_dout : std_logic_vector(63 downto 0);    
    
    signal cur_val_rdAddr : std_logic_vector(8 downto 0); 
    signal cur_val_rdData : std_logic_vector(63 downto 0);
    signal cur_val_wrAddr : std_logic_vector(8 downto 0);
    signal cur_val_wrEn : std_logic := '0';
    signal cur_val_wrData : std_logic_vector(63 downto 0);
    signal offset_del1, offset_del2 : std_logic_vector(19 downto 0);
    signal frame_count : std_logic_vector(31 downto 0) := x"00000000";
    signal startup : std_logic := '0';
    signal long_phase : std_logic := '0';

    ------------------------------------------------------
    type poly_fsm_type is (start, wait_x10, get_validity_buf0, get_validity_buf1, wait_integration_offset, calc_t_start, 
                           wait_t_calculation, add_packet_time, wait_add_packet_time, 
                           get_c0, get_c1, get_c2, get_c3, get_c4, get_c5,
                           wait_c1_x_t, wait_c2_x_t2, wait_c3_x_t3, wait_c4_x_t4, wait_c5_x_t5, 
                           t_x_t, t_x_t2, t_x_t3, t_x_t4, t_x_t5, 
                           add_vpol_offset, mult_hpol_1_on_1080ns, mult_hpol_sky_frequency, wait_vpol, vpol_idle,
                           mult_vpol_1_on_1080ns, mult_vpol_sky_frequency, send_values, wait_done, done, wait_new_vc);
    
    signal poly_fsm : poly_fsm_type := wait_new_vc;
    type t_poly_fsm_del is array(47 downto 0) of poly_fsm_type;
    signal poly_fsm_del : t_poly_fsm_del;
    signal virtual_channels : t_slv_16_arr((g_VIRTUAL_CHANNELS-1) downto 0);
    signal virtual_channels_x10, virtual_channels_x8, virtual_channels_x2, vc_base_addr : t_slv_20_arr((g_VIRTUAL_CHANNELS-1) downto 0);
    signal integration : std_logic_vector(31 downto 0);
    signal ct_frame : std_logic_vector(1 downto 0);
    signal vc_count : std_logic_vector((g_VC_LOG2-1) downto 0);
    signal vc_count_del : t_slv_2_arr(47 downto 0);
    signal no_valid_buffer_count : std_logic_vector(15 downto 0) := x"0000";
    signal state_count : std_logic_vector(7 downto 0);
    
    signal cur_time, cur_poly_state, cur_time_n : t_slv_64_arr((g_VIRTUAL_CHANNELS-1) downto 0);
    signal sample_offset, sample_diff : t_slv_12_arr((g_VIRTUAL_CHANNELS-1) downto 0);
    
    signal integration_buf0_del5, integration_buf1_del6, integration_buf0_del6, integration_buf0_del7, integration_buf1_del7, integration_offset_del8  : std_logic_vector(31 downto 0);
    signal valid_buf0, valid_buf1_del6, buf0_ok_del6, buf1_more_recent_del7, buf1_ok_del7, buf0_ok_del7 : std_logic := '0';
    signal buffer_select : std_logic_vector(g_VIRTUAL_CHANNELS-1 downto 0);
    signal packets_sent : std_logic_vector(7 downto 0) := x"00";
    signal packets_sent_eq_zero_del : std_logic_vector(31 downto 0);
    
    signal Hpol_deltaP, Hpol_phase : t_slv_16_arr((g_VIRTUAL_CHANNELS-1) downto 0);
    signal Vpol_deltaP, Vpol_phase : t_slv_16_arr((g_VIRTUAL_CHANNELS-1) downto 0);
    
begin
    
    vc_gen : for i in 0 to (g_VIRTUAL_CHANNELS-1) generate
        -- Processing for each of the virtual channels.
        -- 
        
        virtual_channels_x8(i) <= '0' & virtual_channels(i) & "000";
        virtual_channels_x2(i) <= "000" & virtual_channels(i) & '0';
        
        process(clk)
        begin
            if rising_edge(clk) then
                virtual_channels_x10(i) <= std_logic_vector(unsigned(virtual_channels_x8(i)) + unsigned(virtual_channels_x2(i)));
                
                if buffer_select(i) = '0' then
                    vc_base_addr(i) <= virtual_channels_x10(i);
                else
                    vc_base_addr(i) <= std_logic_vector(unsigned(virtual_channels_x10(i)) + 10240);
                end if; 
                
                -- Current time for each virtual channel
                if (poly_fsm_del(13) = get_validity_buf1) then
                    -- Load the time after converting to a double at the start of a run
                    -- This is (double)((int)i_integration - (int)buf_integration)
                    -- so is time as a double in units of integrations.
                    if (to_integer(unsigned(vc_count_del(13))) = i) then
                        cur_time(i) <= int_to_fp64_dout;
                    end if;
                elsif (poly_fsm_del(43) = calc_t_start) then
                    -- Load the time as used in the polynomials.
                    -- (i.e. seconds since epoch for this virtual channel) 
                    -- Two cases : 
                    --   - At the start of a run, after the chain of calculations :
                    --       integration_offset_seconds = (double)integration_offset * 0.849346560      <== fp64 multiplier, "integration_offset" comes from cur_time(i)
                    --       integration_offset_epoch = integration_offset_seconds + buf_offset_seconds <== FP64 
                    --       ct_frame_offset_epoch = integration_offset_epoch + [0, 283115520, 566231040]
                    --   - After updating to the next filterbank input
                    --       cur_time(i) <= cur_time(i) + (4096*1080ns = 0.0044236800)
                    --        
                    if to_integer(unsigned(vc_count_del(43))) = i then
                        cur_time(i) <= fp64_add_dout;
                    end if;
                end if;
                
                if (poly_fsm_del(43) = calc_t_start) then
                    if to_integer(unsigned(vc_count_del(43))) = i then
                        cur_time_n(i) <= fp64_add_dout;
                    end if;
                elsif (poly_fsm_del(16) = t_x_t) or (poly_fsm_del(16) = t_x_t2) or (poly_fsm_del(16) = t_x_t3) or (poly_fsm_del(16) = t_x_t4) then
                    -- 4 cycle latency before inputs to the multiplier are (t x t^n), then 12 cycles to get the output
                    -- update cur_time_n with previous value x time (i.e. "time^n")
                    if to_integer(unsigned(vc_count_del(16))) = i then
                        cur_time_n(i) <= fp64_mult_dout;
                    end if;
                end if;
                
                
                if poly_fsm_del(4) = get_c0 then
                    -- del(1) => rd address valid, del(4) rd data valid
                    cur_poly_state(to_integer(unsigned(vc_count_del(4)))) <= i_rd_data;
                elsif ((poly_fsm_del(32) = get_c1) or (poly_fsm_del(32) = get_c2) or (poly_fsm_del(32) = get_c3) or 
                       (poly_fsm_del(32) = get_c4) or (poly_fsm_del(32) = get_c5)) then
                    -- del(1) => rd address valid
                    -- del(4) => i_rd_data valid
                    -- del(5) => fp64_mult_din0/1 valid
                    --  ...
                    -- del(17) => fp64_mult_dout valid
                    -- del(18) => fp64_add_din0/1 valid
                    --  ...
                    -- del(32) => fp64_add_dout valid
                    if to_integer(unsigned(vc_count_del(32))) = i then
                        cur_poly_state(i) <= fp64_add_dout;
                    end if;
                end if;
                
                -- 
                if (poly_fsm_del(24) = mult_hpol_1_on_1080ns) then
                    -- fp64_to_int_din is valid on del(18),
                    -- 6 clock latency, so output is valid on del(24)
                    if (to_integer(unsigned(vc_count_del(24))) = i) then
                        if packets_sent_eq_zero_del(24) = '1' then
                            -- Sample offset is only set once (at the start of each frame) 
                            sample_offset(i) <= fp64_to_int_dout(43 downto 32);
                            --  .111111111 => o_hpol_deltaP = 16383
                            Hpol_deltaP(i) <= "00" & fp64_to_int_dout(31 downto 18);
                        else
                            -- For later frames, sample offset can't be changed, so 
                            -- deltaP can be more than 1 sample.
                            -- 3 possible cases:
                            --   sample_diff = 0  --> Hpol_deltaP <= "00" & fp64_to_int_dout(31 downto 18);
                            --   sample_diff = 1  --> Hpol_deltaP <= "01" & fp64_to_int_dout(31 downto 18);  i.e. fine delay is positive, greater than 1 sample
                            --   sample_diff = -1 --> Hpol_deltaP <= "11" & fp64_to_int_dout(31 downto 18);  i.e. fine delay is negative.
                            Hpol_deltaP(i)(13 downto 0) <= fp64_to_int_dout(31 downto 18);
                            if (unsigned(fp64_to_int_dout(43 downto 32)) > unsigned(sample_offset(i))) then
                                Hpol_deltaP(i)(15 downto 14) <= "01";
                            elsif (unsigned(fp64_to_int_dout(43 downto 32)) = unsigned(sample_offset(i))) then
                                Hpol_deltaP(i)(15 downto 14) <= "00";
                            else
                                Hpol_deltaP(i)(15 downto 14) <= "11";
                            end if;
                        end if;
                    end if;
                end if;
                if (poly_fsm_del(24) = mult_vpol_1_on_1080ns) then
                    if (to_integer(unsigned(vc_count_del(24))) = i) then
                        -- fine delay for Vpol is same calculation as for Hpol, except that
                        -- the integer delay is set by Hpol sample delay (V and H have same integer delay).
                        Vpol_deltaP(i)(13 downto 0) <= fp64_to_int_dout(31 downto 18);
                        if (unsigned(fp64_to_int_dout(43 downto 32)) > unsigned(sample_offset(i))) then
                            Vpol_deltaP(i)(15 downto 14) <= "01";
                        elsif (unsigned(fp64_to_int_dout(43 downto 32)) = unsigned(sample_offset(i))) then
                            Vpol_deltaP(i)(15 downto 14) <= "00";
                        else
                            Vpol_deltaP(i)(15 downto 14) <= "11";
                        end if;
                    end if;
                end if;
                if (poly_fsm_del(24) = mult_hpol_sky_frequency) then
                    if (to_integer(unsigned(vc_count_del(24))) = i) then
                        Hpol_phase(i) <= fp64_to_int_dout(31 downto 16);
                    end if;
                end if;
                if (poly_fsm_del(24) = mult_vpol_sky_frequency) then
                    if (to_integer(unsigned(vc_count_del(24))) = i) then
                        Vpol_phase(i) <= fp64_to_int_dout(31 downto 16);
                    end if;
                end if;
                
            end if;
        end process;
        
    end generate;
    
    vc_count_del(0) <= vc_count;
    poly_fsm_del(0) <= poly_fsm;
    
    process(clk)
    begin
        if rising_edge(clk) then
            
            if i_start = '1' then
                poly_fsm <= start;
                -- Number of packets sent for this set of virtual channels in this corner turn frame.
                -- Counts from 0 to 
                packets_sent <= (others => '0');
            else
                case poly_fsm is
                    when start =>
                        poly_fsm <= wait_x10;
                        virtual_channels <= i_virtual_channels;
                        integration <= i_integration;
                        ct_frame <= i_ct_frame;
                    
                    when wait_x10 =>
                        -- wait until virtual_channels_x10 is valid.
                        poly_fsm <= get_validity_buf0;
                        vc_count <= (others => '0');
                    
                    when get_validity_buf0 =>
                        -- read the validity time from the polynomial memory.
                        -- Offset 7 in each 10-word block = validity time, bits 31:0 = integration at which 
                        --  the polynomial becomes valid, bit 32 = entry is valid.
                        -- Loop through g_VIRTUAL_CHANNELS x 2 times, once for each buffer.
                        poly_fsm <= get_validity_buf1;
                    
                    when get_validity_buf1 =>
                        -- read validity info for the second buffer for each virtual channel
                        -- validity = offset 7 within set of 10 words, second buffer = offset 10240
                        if (unsigned(vc_count) = (g_VIRTUAL_CHANNELS-1)) then
                            poly_fsm <= wait_integration_offset;
                        else
                            vc_count <= std_logic_vector(unsigned(vc_count) + 1);
                            poly_fsm <= get_validity_buf0;
                        end if;
                        state_count <= (others => '0');
                    
                        ------------------------------------------------------------
                        -- Pipeline for calculating the time in the polynomial
                        --
                        --  Calculates :
                        --     - determine which buffer to use (valid and most recent)
                        --     - Get the integration offset as an integer:
                        --         integration_offset = ((int)i_integration - (int)buf_integration)
                        --     - Convert to double precision and store in the time signal (cur_time(.))
                        --         integration_offset (double) = double(integration_offset)          <== Use int to fp64 core
                        --
                        -- cycle state_count    poly_fsm               Comments
                        --   0               get_validity_buf0      
                        --   1               get_validity_buf1        o_rd_addr = buffer 0 validity
                        --   2     0         wait_integration_offset  o_rd_addr = buffer 1 validity
                        --   3     1                        
                        --   4     2                                  i_rd_data = buffer 0 validity
                        --   5     3                                  i_rd_data = buffer 1 validity    buf0_ok_del5
                        --   6     4                                                                   buf0_ok_del6, buf1_ok_del6
                        --   7     5                                  integration_offset_del8 <= integration_buf0/1_del7 - integration;
                        --   8     6                                  int_to_fp64_din <= integration_offset_del8   -- Convert integration offset to fp64
                        --   9     7                                  
                        --  10     8                                  
                        --  11     9                                      [ ... 6 cycle latency to convert integration offset to fp64 ... ]
                        --  12     10                                  
                        --  13     11                                  
                        --  14     12                                 cur_time <= int_to_fp64_dout

                    when wait_integration_offset =>
                        -- wait until we have the integration offset as an integer for all the virtual channels,
                        -- then start the calculation of the time.
                        if (unsigned(state_count) = 12) then
                            poly_fsm <= calc_t_start;
                            state_count <= (others => '0');
                        else
                            state_count <= std_logic_vector(unsigned(state_count) + 1);
                        end if;
                        vc_count <= (others => '0');
                    
                    when calc_t_start =>
                        if (unsigned(vc_count) = (g_VIRTUAL_CHANNELS-1)) then
                            poly_fsm <= wait_t_calculation;
                            vc_count <= (others => '0');
                        else
                            vc_count <= std_logic_vector(unsigned(vc_count) + 1);
                        end if;
                        state_count <= (others => '0');
                    
                        ------------------------------------------------------------
                        -- Pipeline for calculating the time in the polynomial from the integration
                        --     integration_offset_seconds = (double)cur_time(i) (=integration offset) * 0.849346560      <== fp64 multiplier
                        --     integration_offset_epoch = integration_offset_seconds + buf_offset_seconds <== FP64 
                        --     ct_frame_offset_epoch = integration_offset_epoch + [0, 283115520, 566231040]
                        --
                        -- 
                        --     -- Note - in the state calc_t_start for g_VIRTUAL_CHANNELS clocks, then moves through this sequence --
                        --     -- repeated use of the same fp64 adder assumes that g_VIRTUAL_CHANNELS is at most 14                --
                        -- state_count
                        --  0                              fp64_mult_din0 <= cur_time(i) ( *  c_fp64_0p849346560);  -- Convert integrations to seconds
                        --  1
                        --  2
                        --  3
                        --  4
                        --  5
                        --  6                                 [ ... 12 cycle latency to multiply to get integration offset in seconds ... ]
                        --  7
                        --  8
                        --  9                                 
                        --  10                                o_rd_addr = config word 7
                        --  11
                        --  12
                        --  13                             fp64_add_din0 <= fp64_mult_dout  ( + [config word 7 = epoch offset ); 
                        --  14
                        --  15
                        --  16
                        --  17
                        --  18
                        --  19
                        --  20
                        --  21                                 [ ... 14 cycle latency for the adder (add epoch offset to integration time) ... ]
                        --  22
                        --  23
                        --  24
                        --  25
                        --  26
                        --  27
                        --  28                             fp64_add_din0 <= fp64_add_dout + [0, 0.283, 0.566]; -- Add offset for the corner turn frame that we are processing
                        --  29
                        --  30
                        --  31
                        --  32
                        --  33
                        --  34
                        --  35
                        --  36
                        --  37                                [ ... 14 cycle latency for the adder (time + [0, 0.283, 0.566]) ... ]
                        --  38
                        --  39
                        --  40
                        --  41
                        --  42
                        --  43                             t = fp64_add_dout; -- This is the time that is used in the polynomial. 
                        --  44
                    
                    when wait_t_calculation =>
                        -- Wait until we finish the calculation of the time at the start of the 
                        -- corner turn.
                        -- (as described in comments above)
                        state_count <= std_logic_vector(unsigned(state_count) + 1);
                        if (unsigned(state_count) = 43) then
                            poly_fsm <= get_c0;
                        end if;
                        vc_count <= (others => '0');
                        
                    when add_packet_time =>
                        -- For each new time sample within a corner turn frame, 
                        --  add (4096*1080e-9) = 4.4368 ms = 0.004423680 seconds
                        vc_count <= std_logic_vector(unsigned(vc_count) + 1);
                        if (unsigned(vc_count) = (g_VIRTUAL_CHANNELS-1)) then
                            poly_fsm <= wait_add_packet_time;
                        end if;
                        state_count <= (others => '0');
                    
                    when wait_add_packet_time =>
                        state_count <= std_logic_vector(unsigned(state_count) + 1);
                        if (unsigned(state_count) = 14) then
                            poly_fsm <= get_c0;
                        end if;
                        vc_count <= (others => '0');
                        
                    when get_c0 =>
                        -- Read c0 coefficient, address offset = 0, store in the cur_poly_state(i) register
                        if (unsigned(vc_count) = (g_VIRTUAL_CHANNELS-1)) then
                            poly_fsm <= get_c1;
                            vc_count <= (others => '0');
                        else
                            vc_count <= std_logic_vector(unsigned(vc_count) + 1);
                        end if;
                        state_count <= (others => '0');
                        
                    when get_c1 =>
                        -- read c1 coefficient, address offset = 1, feed into pipeline calculation of c1 * t + c0
                        poly_fsm <= t_x_t;
                        state_count <= std_logic_vector(unsigned(state_count) + 1);
                    
                    when t_x_t =>
                        -- Multiplication : t x t (i.e. get t^2 for virtual channel vc_count) 
                        if (unsigned(vc_count) = (g_VIRTUAL_CHANNELS-1)) then
                            poly_fsm <= wait_c1_x_t;
                            vc_count <= (others => '0');
                        else
                            vc_count <= std_logic_vector(unsigned(vc_count) + 1);
                            poly_fsm <= get_c1;
                        end if;
                        state_count <= std_logic_vector(unsigned(state_count) + 1);
                        
                    when wait_c1_x_t =>
                        -- Pipelined multiplication and addition : c1 x t + c0
                        if (unsigned(state_count) > 15) then
                            -- 12 clock latency for the fp64 multiplier, 14 clock latency for the fp64 adder 
                            -- few clocks for intermediate pipeline stages, so after 16 clocks we are ready to (start) the next calculation.
                            poly_fsm <= get_c2;
                            state_count <= (others => '0');
                        else
                            state_count <= std_logic_vector(unsigned(state_count) + 1);
                        end if;
                        vc_count <= (others => '0');
                    
                    when get_c2 =>
                        -- read c2 coefficient, address offset = 2, feed into pipeline calculation of c2 * t^2 + (cur_poly_state = c1 * t + c0)
                        poly_fsm <= t_x_t2;
                        state_count <= std_logic_vector(unsigned(state_count) + 1);
                        
                    when t_x_t2 =>
                        -- Get t^3 = t^2 * t for virtual channel vc_count
                        if (unsigned(vc_count) = (g_VIRTUAL_CHANNELS-1)) then
                            poly_fsm <= wait_c2_x_t2;
                            vc_count <= (others => '0');
                        else
                            vc_count <= std_logic_vector(unsigned(vc_count) + 1);
                            poly_fsm <= get_c2;
                        end if;
                        state_count <= std_logic_vector(unsigned(state_count) + 1);
                    
                    when wait_c2_x_t2 =>
                        -- wait for pipelined multiplication and addition to complete
                        --  cur_poly_state <= c2 * t^2 + (cur_poly_state = c1 * t + c0)
                        if (unsigned(state_count) > 15) then
                            poly_fsm <= get_c3;
                            state_count <= (others => '0');
                        else
                            state_count <= std_logic_vector(unsigned(state_count) + 1); 
                        end if;
                        vc_count <= (others => '0');
                        
                    when get_c3 =>
                        -- read c3 coefficient, address offset = 3, feed into pipeline calculation of c3 * t^3 + (cur_poly_state = c2 * t^2 + c1 * t + c0)
                        poly_fsm <= t_x_t3;
                        state_count <= std_logic_vector(unsigned(state_count) + 1);
                    
                    when t_x_t3 =>
                        -- Get t^4 = t^3 * t for virtual channel vc_count
                        if (unsigned(vc_count) = (g_VIRTUAL_CHANNELS-1)) then
                            poly_fsm <= wait_c3_x_t3;
                            vc_count <= (others => '0');
                        else
                            vc_count <= std_logic_vector(unsigned(vc_count) + 1);
                            poly_fsm <= get_c3;
                        end if;
                        state_count <= std_logic_vector(unsigned(state_count) + 1);
                    
                    when wait_c3_x_t3 =>
                        -- wait for pipelined multiplication and addition to complete:
                        --  cur_poly_state(vc_count) <= c3 * t^3 + (cur_poly_state = c2 * t^2 + c1 * t + c0)
                        if (unsigned(state_count) > 15 ) then
                            poly_fsm <= get_c4;
                            state_count <= (others => '0');
                        else
                            state_count <= std_logic_vector(unsigned(state_count) + 1);
                        end if;
                        vc_count <= (others => '0');
                    
                    when get_c4 =>
                        -- read c4 coefficient, address offset = 4, feed into pipeline calculation of c4 * t^4 +  (cur_poly_state = c3 * t^3 + c2 * t^2 + c1 * t + c0)
                        poly_fsm <= t_x_t4;
                        state_count <= std_logic_vector(unsigned(state_count) + 1);

                    when t_x_t4 =>
                        -- Get t^5 = t^4 * t for virtual channel vc_count
                        if (unsigned(vc_count) = (g_VIRTUAL_CHANNELS-1)) then
                            poly_fsm <= wait_c4_x_t4;
                            vc_count <= (others => '0');
                        else
                            vc_count <= std_logic_vector(unsigned(vc_count) + 1);
                            poly_fsm <= get_c4;
                        end if;
                        state_count <= std_logic_vector(unsigned(state_count) + 1);
                        
                    when wait_c4_x_t4 =>
                        -- Pipelined multiplication and addition : cur_poly_state(vc_count) <= c4 * t^4 + (cur_poly_state = c3 * t^3 + c2 * t^2 + c1 * t + c0)
                        if (unsigned(state_count) > 15) then
                            poly_fsm <= get_c5;
                            state_count <= (others => '0');
                        else
                            state_count <= std_logic_vector(unsigned(state_count) + 1);
                        end if;
                        vc_count <= (others => '0');
                    
                    when get_c5 =>
                        -- read c5 coefficient, address offset = 5, feed into pipeline calculation of c5*t^5 + (cur_poly_state = c4*t^4 + c3 * t^3 + c2 * t^2 + c1 * t + c0)
                        poly_fsm <= t_x_t5;
                        state_count <= std_logic_vector(unsigned(state_count) + 1);

                    when t_x_t5 =>
                        -- No calculation required here.
                        -- This is a dummy state just to be consistent with the pipeline for the other calculations.
                        if (unsigned(vc_count) = (g_VIRTUAL_CHANNELS-1)) then
                            poly_fsm <= wait_c5_x_t5;
                            vc_count <= (others => '0');
                        else
                            vc_count <= std_logic_vector(unsigned(vc_count) + 1);
                            poly_fsm <= get_c5;
                        end if;
                        state_count <= std_logic_vector(unsigned(state_count) + 1);
                        
                    when wait_c5_x_t5 =>
                        -- Pipelined multiplication and addition : cur_poly_state(vc_count) <= c4 * t^4 + (cur_poly_state = c3 * t^3 + c2 * t^2 + c1 * t + c0)
                        if (unsigned(state_count) > 15) then
                            poly_fsm <= add_vpol_offset;
                            state_count <= (others => '0');
                        else
                            state_count <= std_logic_vector(unsigned(state_count) + 1);
                        end if;
                        vc_count <= (others => '0');
                    
                    when add_vpol_offset =>
                        -- add the offset for the other polarisation (config word 8)
                        poly_fsm <= mult_hpol_1_on_1080ns;
                        state_count <= std_logic_vector(unsigned(state_count) + 1);
                    
                    when mult_hpol_1_on_1080ns => 
                        -- multiply : delay (from polynomial) * (1/1080ns) 
                        -- to get the coarse sample offset.
                        poly_fsm <= mult_hpol_sky_frequency;
                        state_count <= std_logic_vector(unsigned(state_count) + 1);
                    
                    when mult_hpol_sky_frequency =>
                        -- multiply by the sky frequency
                        if (unsigned(vc_count) = (g_VIRTUAL_CHANNELS-1)) then
                            poly_fsm <= wait_vpol;
                            vc_count <= (others => '0');
                        else
                            vc_count <= std_logic_vector(unsigned(vc_count) + 1);
                            poly_fsm <= add_vpol_offset;
                        end if;
                        state_count <= std_logic_vector(unsigned(state_count) + 1);
                    
                    when wait_vpol =>
                        -- Wait until the fp64 sum to calculate vpol is done
                        -- 4 clock latency to get the vpol offset from the memory,
                        -- +14 clock latency for the fp64 adder, so need a minimum of 18 clocks
                        -- before vpol is valid 
                        if (unsigned(state_count) > 19) then
                            -- 
                            poly_fsm <= vpol_idle;
                            state_count <= (others => '0');
                        else
                            state_count <= std_logic_vector(unsigned(state_count) + 1);
                        end if;
                        
                    when vpol_idle =>
                        -- do nothing for one clock.
                        -- This is here so that there is 3 clocks per virtual channel for 
                        -- calculating the x1/1080 and x sky_frequency steps for vpol just as there is for hpol
                        -- Otherwise it would be possible to get ahead of the vpol adder for later virtual channels.
                        poly_fsm <= mult_vpol_1_on_1080ns;
                    
                    when mult_vpol_1_on_1080ns => 
                        -- multiply : delay (from polynomial) * (1/1080ns) 
                        -- to get the coarse sample offset.
                        poly_fsm <= mult_vpol_sky_frequency;
                        state_count <= std_logic_vector(unsigned(state_count) + 1);
                    
                    when mult_vpol_sky_frequency =>
                        -- multiply by the sky frequency
                        if (unsigned(vc_count) = (g_VIRTUAL_CHANNELS-1)) then
                            poly_fsm <= wait_done;
                            vc_count <= (others => '0');
                            state_count <= (others => '0');
                        else
                            vc_count <= std_logic_vector(unsigned(vc_count) + 1);
                            poly_fsm <= vpol_idle;
                            state_count <= std_logic_vector(unsigned(state_count) + 1);
                        end if;
                        
                    when wait_done =>
                        state_count <= std_logic_vector(unsigned(state_count) + 1);
                        if (unsigned(state_count) > 31) then
                            poly_fsm <= send_values;
                        end if;
                        vc_count <= (others => '0');
                    
                    when send_values =>
                        -- put values on the output bus 
                        -- (o_vc, o_packet, o_sample_offset, o_Hpol_deltaP, o_Hpol_phase, o_Vpol_deltaP, o_Vpol_phase)
                        if (unsigned(vc_count) = (g_VIRTUAL_CHANNELS-1)) then
                            poly_fsm <= done;
                            vc_count <= (others => '0');
                        else
                            vc_count <= std_logic_vector(unsigned(vc_count) + 1);
                        end if;
                    
                    when done =>
                        -- Either move to the next timestep, or wait for the next set of virtual channels to process.
                        if (unsigned(packets_sent) < 63) then
                            poly_fsm <= add_packet_time;
                            packets_sent <= std_logic_vector(unsigned(packets_sent) + 1);
                        else
                            poly_fsm <= wait_new_vc;
                        end if;
                        vc_count <= (others => '0');
                        
                    when wait_new_vc =>
                        poly_fsm <= wait_new_vc;
                    
                end case;
            end if;
            
            vc_count_del(47 downto 1) <= vc_count_del(46 downto 0);
            poly_fsm_del(47 downto 1) <= poly_fsm_del(46 downto 0);
            
            if (unsigned(packets_sent) = 0) then
                packets_sent_eq_zero_del(0) <= '1';
            else
                packets_sent_eq_zero_del(0) <= '0';
            end if;
            packets_sent_eq_zero_del(31 downto 1) <= packets_sent_eq_zero_del(30 downto 0);
            
            if poly_fsm = send_values then
                o_vc <= virtual_channels(to_integer(unsigned(vc_count)));
                o_packet <= x"00" & packets_sent; -- out std_logic_vector(15 downto 0);
                o_sample_offset  <= sample_offset(to_integer(unsigned(vc_count)))(11 downto 0); -- Number of whole 1080ns samples to delay by.
                o_Hpol_deltaP <= Hpol_deltaP(to_integer(unsigned(vc_count))); -- out std_logic_vector(15 downto 0);
                o_Hpol_phase  <= Hpol_phase(to_integer(unsigned(vc_count)));
                o_Vpol_deltaP <= Vpol_deltaP(to_integer(unsigned(vc_count)));
                o_Vpol_phase <= Vpol_phase(to_integer(unsigned(vc_count)));
                o_valid <= '1';
            else
                o_vc <= (others => '0');
                o_packet <= (others => '0'); -- out std_logic_vector(15 downto 0);
                o_sample_offset <= (others => '0'); -- Number of whole 1080ns samples to delay by.
                o_Hpol_deltaP <= (others => '0');
                o_Hpol_phase  <= (others => '0');
                o_Vpol_deltaP <= (others => '0');
                o_Vpol_phase  <= (others => '0');
                o_valid <= '0';
            end if;
            
            
            if poly_fsm = get_validity_buf0 then
                o_rd_addr <= std_logic_vector(unsigned(virtual_channels_x10(to_integer(unsigned(vc_count)))) + 9);
            elsif poly_fsm = get_validity_buf1 then
                -- read validity info for the second buffer for each virtual channel
                -- validity = offset 7 within set of 10 words, second buffer = offset 10240
                o_rd_addr <= std_logic_vector(unsigned(virtual_channels_x10(to_integer(unsigned(vc_count)))) + 10240 + 9);
            elsif (poly_fsm_del(10) = calc_t_start) then
                -- Fetch from configuration memory the offset in seconds from the integration to the 
                -- start of validity for the polynomial (word 7).
                o_rd_addr <= std_logic_vector(unsigned(vc_base_addr(to_integer(unsigned(vc_count_del(10))))) + 7);
            elsif (poly_fsm_del(0) = get_c0) then
                o_rd_addr <= std_logic_vector(unsigned(vc_base_addr(to_integer(unsigned(vc_count_del(0))))) + 0);
            elsif (poly_fsm_del(0) = get_c1) then
                o_rd_addr <= std_logic_vector(unsigned(vc_base_addr(to_integer(unsigned(vc_count_del(0))))) + 1);
            elsif (poly_fsm_del(0) = get_c2) then
                o_rd_addr <= std_logic_vector(unsigned(vc_base_addr(to_integer(unsigned(vc_count_del(0))))) + 2);
            elsif (poly_fsm_del(0) = get_c3) then
                o_rd_addr <= std_logic_vector(unsigned(vc_base_addr(to_integer(unsigned(vc_count_del(0))))) + 3);
            elsif (poly_fsm_del(0) = get_c4) then
                o_rd_addr <= std_logic_vector(unsigned(vc_base_addr(to_integer(unsigned(vc_count_del(0))))) + 4);
            elsif (poly_fsm_del(0) = get_c5) then
                o_rd_addr <= std_logic_vector(unsigned(vc_base_addr(to_integer(unsigned(vc_count_del(0))))) + 5);
            elsif (poly_fsm_del(0) = add_vpol_offset) then
                o_rd_addr <= std_logic_vector(unsigned(vc_base_addr(to_integer(unsigned(vc_count_del(0))))) + 8);
            else -- if ((poly_fsm_del(0) = mult_hpol_sky_frequency) or (poly_fsm_del(0) = mult_vpol_sky_frequency)) then
                o_rd_addr <= std_logic_vector(unsigned(vc_base_addr(to_integer(unsigned(vc_count_del(0))))) + 6);
            end if;
            
            if poly_fsm = wait_new_vc then
                o_idle <= '1';
            else
                o_idle <= '0';
            end if;
            -------------------------------------------------------------------
            -- Determine which buffer to use for each of the virtual channels
            --
            -- del1 : o_rd_addr valid, del4 : i_rd_data valid
            if poly_fsm_del(4) = get_validity_buf0 then
                integration_buf0_del5 <= i_rd_data(31 downto 0);
                valid_buf0 <= i_rd_data(32);
            end if;
            
            -- pipeline : buf1 data read from the config memory is valid.
            if poly_fsm_del(5) = get_validity_buf0 then
                integration_buf1_del6 <= i_rd_data(31 downto 0);
                valid_buf1_del6 <= i_rd_data(32);
                if ((valid_buf0 = '1') and (unsigned(integration_buf0_del5) >= unsigned(integration))) then
                    buf0_ok_del6 <= '1';  -- del5 is relative to the fsm
                else
                    buf0_ok_del6 <= '0';
                end if;
            end if;
            integration_buf0_del6 <= integration_buf0_del5;
            
            -- pipeline : calculate which buffer is more recent.
            if poly_fsm_del(6) = get_validity_buf0 then
                if (unsigned(integration_buf1_del6) > unsigned(integration_buf0_del6)) then
                    buf1_more_recent_del7 <= '1';
                else
                    buf1_more_recent_del7 <= '0';
                end if;
                if (valid_buf1_del6 = '1' and (unsigned(integration_buf1_del6) >= unsigned(integration))) then
                    buf1_ok_del7 <= '1';
                else
                    buf1_ok_del7 <= '0';
                end if;
            end if;
            buf0_ok_del7 <= buf0_ok_del6;
            integration_buf0_del7 <= integration_buf0_del6;
            integration_buf1_del7 <= integration_buf1_del6;
            
            -- pipeline : Assign which buffer we will use for each virtual channel
            -- and which integration the times are referenced to.
            if poly_fsm_del(7) = get_validity_buf0 then
                if ((buf0_ok_del7 = '1' and buf1_ok_del7 = '1' and buf1_more_recent_del7 = '0') or
                    (buf0_ok_del7 = '1' and buf1_ok_del7 = '0') or
                    (buf0_ok_del7 = '0' and buf1_ok_del7 = '0')) then
                    -- choose buf0 for vc = vc_count_del6
                    -- This is also the default choice in the case where neither buffer is valid.
                    buffer_select(to_integer(unsigned(vc_count_del(7)))) <= '0';
                    integration_offset_del8 <= std_logic_vector(unsigned(integration_buf0_del7) - unsigned(integration));
                elsif buf1_ok_del7 = '1' then
                    -- choose buf1
                    buffer_select(to_integer(unsigned(vc_count_del(7)))) <= '1';
                    integration_offset_del8 <= std_logic_vector(unsigned(integration_buf1_del7) - unsigned(integration));
                end if;
            end if;
            
            if i_rst = '1' then
                no_valid_buffer_count <= (others => '0');
            elsif poly_fsm_del(7) = get_validity_buf1 and buf0_ok_del7 = '0' and buf1_ok_del7 = '0' then
                no_valid_buffer_count <= std_logic_vector(unsigned(no_valid_buffer_count) + 1);
            end if;
            
            -- pipeline - 
            
            
            -----------------------------------------------------------------------------
            -- Input to the int to float conversion
            if poly_fsm_del(8) = get_validity_buf0 then
                int_to_fp64_valid_in <= '1';
                int_to_fp64_din <= x"00000000" & integration_offset_del8;
            else
                int_to_fp64_valid_in <= '0';
                int_to_fp64_din <= (others => '0');
            end if;
            
            -- Input to the double precision multiplier
            if poly_fsm = calc_t_start then
                -- multiply : integration_offset_seconds = (double)(integration_offset * 0.849346560)
                -- poly_fsm_del9 = get_validity_buf0, then input to the int to float block is valid
                -- int2float has a 6 cycle latency, so poly_fsm_del15 = get_validity_buf0 => int to float output is valid.
                fp64_mult_valid_in <= '1';
                fp64_mult_din0 <= cur_time(to_integer(unsigned(vc_count)));
                fp64_mult_din1 <= c_fp64_0p849346560;
            elsif (poly_fsm_del(4) = get_c1) or (poly_fsm_del(4) = get_c2) or (poly_fsm_del(4) = get_c3) or (poly_fsm_del(4) = get_c4) or (poly_fsm_del(4) = get_c5) then
                fp64_mult_valid_in <= '1';
                fp64_mult_din0 <= cur_time_n(to_integer(unsigned(vc_count_del(4))));
                fp64_mult_din1 <= i_rd_data;
            elsif (poly_fsm_del(4) = t_x_t) or (poly_fsm_del(4) = t_x_t2) or (poly_fsm_del(4) = t_x_t3) or (poly_fsm_del(4) = t_x_t4) then
                -- del(4) because this happens directly after the get_c1, get_c2 etc states, which drive the multiplier with a delay of 4 due to the delay reading the memory.
                fp64_mult_valid_in <= '1';
                fp64_mult_din0 <= cur_time_n(to_integer(unsigned(vc_count_del(4))));
                fp64_mult_din1 <= cur_time(to_integer(unsigned(vc_count_del(4))));
                
            elsif (poly_fsm_del(4) = mult_hpol_1_on_1080ns) or (poly_fsm_del(4) = mult_vpol_1_on_1080ns) then
                -- To avoid clashes in the use of the multiplier, this has to have the same latency 
                -- relative to the state machine as for the mult_hpol_sky_frequency state
                fp64_mult_valid_in <= '1';
                fp64_mult_din0 <= cur_poly_state(to_integer(unsigned(vc_count_del(4))));
                fp64_mult_din1 <= c_fp64_rate;
            elsif ((poly_fsm_del(4) = mult_hpol_sky_frequency) or (poly_fsm_del(4) = mult_vpol_sky_frequency)) then
                -- o_rd_addr is valid on del(1)
                -- i_rd_data is valid on del(4)
                fp64_mult_valid_in <= '1';
                fp64_mult_din0 <= cur_poly_state(to_integer(unsigned(vc_count_del(4))));
                fp64_mult_din1 <= i_rd_data;
            else
                fp64_mult_valid_in <= '0';
                fp64_mult_din0 <= (others => '0');
                fp64_mult_din1 <= (others => '0');
            end if;
            
            -- Input to the double precision adder
            if poly_fsm_del(13) = calc_t_start then
                -- Integration_offset_epoch = integration_offset_seconds + buf_offset_seconds
                fp64_add_valid_in <= '1';
                fp64_add_din0 <= fp64_mult_dout;
                fp64_add_din1 <= i_rd_data;
            elsif poly_fsm_del(28) = calc_t_start then
                -- ct_frame_offset_epoch = integration_offset_epoch + [0, 0.283115520, 0.566231040]
                -- Where integration_offset_epoch is the output of the adder
                fp64_add_valid_in <= '1';
                fp64_add_din0 <= fp64_add_dout;
                if (ct_frame = "00") then
                    fp64_add_din1 <= (others => '0');
                elsif (ct_frame = "01") then
                    fp64_add_din1 <= c_fp64_0p283115520;
                else -- ct_frame = "10"
                    fp64_add_din1 <= c_fp64_0p566231040;
                end if;
            elsif ((poly_fsm_del(17) = get_c1) or (poly_fsm_del(17) = get_c2) or (poly_fsm_del(17) = get_c3) or 
                   (poly_fsm_del(17) = get_c4) or (poly_fsm_del(17) = get_c5)) then
                -- (cX*t^X) + cur_poly_state
                -- input to the fp64 multiplier is valid on del(5), 12 cycle latency, fp64_mult_dout is valid on del(17)
                fp64_add_valid_in <= '1';
                fp64_add_din0 <= fp64_mult_dout;
                fp64_add_din1 <= cur_poly_state(to_integer(unsigned(vc_count_del(17))));
            elsif (poly_fsm_del(4) = add_vpol_offset) then
                -- o_rd_addr aligns with del(1)
                -- 3 cycle latency to read, i_rd_data aligns with del(4)
                fp64_add_valid_in <= '1';
                fp64_add_din0 <= i_rd_data;
                fp64_add_din1 <= cur_poly_state(to_integer(unsigned(vc_count_del(4))));
            else
                fp64_add_valid_in <= '0';
                fp64_add_din0 <= (others => '0');
                fp64_add_din1 <= (others => '0');
            end if;
            
            if ((poly_fsm_del(17) = mult_hpol_1_on_1080ns) or (poly_fsm_del(17) = mult_vpol_1_on_1080ns) or 
                (poly_fsm_del(17) = mult_hpol_sky_frequency) or (poly_fsm_del(17) = mult_vpol_sky_frequency)) then
                -- fp64_mult_din was valid on del(5), fp64_mult_dout is valid on del(17)
                fp64_to_int_valid_in <= '1';
                fp64_to_int_din <= fp64_mult_dout;
            else
                fp64_to_int_valid_in <= '0';
                fp64_to_int_din <= (others => '0');
            end if;

            
            -----------------------------------------------------------------------------
            
        end if;
    end process;
    
    -- Double precision floating point adder, 14 clock latency
    fp64_addi : fp64_add
    PORT map (
        aclk => clk, -- 
        s_axis_a_tvalid => fp64_add_valid_in, -- IN STD_LOGIC;
        s_axis_a_tdata  => fp64_add_din0, -- IN STD_LOGIC_VECTOR(63 DOWNTO 0);
        s_axis_b_tvalid => fp64_add_valid_in, -- IN STD_LOGIC;
        s_axis_b_tdata  => fp64_add_din1, -- IN STD_LOGIC_VECTOR(63 DOWNTO 0);
        m_axis_result_tvalid => fp64_add_valid_out, --  OUT STD_LOGIC;
        m_axis_result_tdata  => fp64_add_dout  -- OUT STD_LOGIC_VECTOR(63 DOWNTO 0));
    );
    
    -- double precision floating point multiplier, 12 clock latency
    fp64_multi : fp64_mult
    PORT MAP (
        aclk => clk,
        s_axis_a_tvalid => fp64_mult_valid_in,
        s_axis_a_tdata => fp64_mult_din0,
        s_axis_b_tvalid => fp64_mult_valid_in,
        s_axis_b_tdata => fp64_mult_din1,
        m_axis_result_tvalid => fp64_mult_valid_out,
        m_axis_result_tdata => fp64_mult_dout
    );
    
    -- Double precision to 32.32 int, 6 clock latency
    fp64_to_inti : fp64_to_int
    PORT MAP (
        aclk => clk,
        s_axis_a_tvalid => fp64_to_int_valid_in,
        s_axis_a_tdata => fp64_to_int_din,
        m_axis_result_tvalid => fp64_to_int_valid_out,
        m_axis_result_tdata => fp64_to_int_dout
    );
    
    -- Int to double precision float, 6 clock latency
    int_to_fp64i : uint64_to_double
    port map (
        aclk => clk,
        s_axis_a_tvalid => int_to_fp64_valid_in,
        s_axis_a_tdata => int_to_fp64_din,
        m_axis_result_tvalid => int_to_fp64_valid_out,
        m_axis_result_tdata => int_to_fp64_dout
    );
    
end Behavioral;
