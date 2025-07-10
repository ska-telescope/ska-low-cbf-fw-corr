----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 08/15/2022 09:34:16 AM
-- Module Name: centroid_divider - Behavioral
-- Description: 
--  Convert raw centroid data into 2 byte values to be sent to SDP.
--  Input data is
--   - 24 bit sum of times (i_timeSum)
--       - Max possible value is (192/2 (=average accumulated value)) * (192 times) * (127 fine channels) = 2328672
--   - 16 bit number of contributing samples (i_Nsamples).
--       - Max possible value is (192 times) * (127 fine channels) = 24384
-- 
--  Output values are : 
--   - time centroid = (256/i_totalTimes) * (i_timeSum / i_Nsamples) - 128
--      i.e. 256 * i_timeSum / (i_totalTimes * i_Nsamples) - 128
--          Note  i_timeSum is always less than (i_totalTimes * i_Nsamples)
--
--     There is an additional correction to account for the time sample numbering runs 0:(i_totalTimes-1)
--     For short integrations (i_totalTimes = 64), the average time is (0+63)/2 = 31.5
--     (The equation above would be correct if the time samples were at the center of the intervales,
--      i.e. 0.5, 1.5, 2.5 etc)
--     The offset of 0.5 is scaled up by a factor of 4 to get the 8-bit output value, so
--     there is an offset of 2 in the final output value.
--     Likewise for long integrations (i_totalTimes = 192), the 0.5 offset is scaled up by a factor 
--     of (256/192) to 0.6666 in the output.
--     To correct for this either 2 (short integrations) or 1 (long integrations) is added to the TCI as a final step.
--
--   - weight        = 255 * sqrt(i_Nsamples / (totalTimes * totalChannels))
--   
----------------------------------------------------------------------------------

library IEEE, common_lib, correlator_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
USE common_lib.common_pkg.ALL;

entity centroid_divider is
    port (
        i_clk : in std_logic;
        -- data input
        -- Expected limit on timeSum and NSamples is the integration of 192 time samples, 127 fine channels.
        -- So maximum timesum = sum(0:191) * 127 = 2328672 (minimum 22 bits required)
        -- maximum NSamples = 192 * 127 = 24384 (minimum 15 bits required)
        i_timeSum : in std_logic_vector(23 downto 0);      -- Sum of the time indices for the samples that were used in the integration.
        i_Nsamples : in std_logic_vector(15 downto 0);     -- Number of samples used in the integration.        
        
        --i_timeSum : in std_logic_vector(18 downto 0);      -- Sum of the time indices for the samples that were used in the integration.
        --i_Nsamples : in std_logic_vector(12 downto 0);     -- Number of samples used in the integration.
        
        -- semi-static inputs
        i_totalTimes : in std_logic_vector(7 downto 0);    -- total time samples being integrated, e.g. 192. 
        i_totalChannels : in std_logic_vector(6 downto 0); -- Number of channels integrated, typically 24, can be up to 127
        -- Outputs,  21 clock latency.
        o_centroid : out std_logic_vector(7 downto 0);
        o_weight : out std_logic_vector(7 downto 0)
    );
end centroid_divider;

architecture Behavioral of centroid_divider is

    signal totalTimes : signed(8 downto 0);
    signal Nsamples : signed(15 downto 0);
    signal totalChannels : signed(7 downto 0);
    signal centroid_denominator0 : signed(24 downto 0); -- = totalTimes * Nsamples, max possible value is 192 * 24384 = 4681728
    signal weight_denominator0 : signed(16 downto 0);   -- = totalTimes * totalChannels, max possible value is 192 * 127 = 24384
    
    signal centroid_numerator0: std_logic_vector(23 downto 0);
    signal centroid_denominator1, centroid_numerator1 : std_logic_vector(23 downto 0);
    signal weight_numerator0 : std_logic_vector(15 downto 0);
    signal weight_denominator1,  weight_numerator1 : std_logic_vector(15 downto 0);
    signal timeSum : std_logic_vector(23 downto 0);
    
    signal centroid_numerator : t_slv_24_arr(9 downto 0);
    signal centroid_denominator : t_slv_24_arr(9 downto 0);
    signal centroid_result : t_slv_9_arr(9 downto 0);
    
    signal weight_numerator : t_slv_16_arr(13 downto 0);
    signal weight_denominator : t_slv_16_arr(13 downto 0);
    signal weight_result : t_slv_13_arr(13 downto 0);
    
    signal sqrt_weight : std_logic_vector(7 downto 0);
    signal centroid_del : t_slv_8_arr(6 downto 0);
    signal sqrt_input : std_logic_vector(11 downto 0);
    signal force_zeroA, force_zero0, force_zero1 : std_logic;
    signal force_zero : std_logic_vector(16 downto 0);
    signal short_integrationA, short_integration0, short_integration1 : std_logic;
    signal short_integration : std_logic_vector(16 downto 0);
    
begin
    
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            -- 1st pipeline stage
            totalTimes <= signed('0' & i_totalTimes);  -- 9 bit signed value, +ve integer should be either 64 or 192
            Nsamples <= signed(i_Nsamples); -- 16 bit signed value, max value is assumed to be 192*127 = 24384, so the top bit will always be zero.
            totalChannels <= signed('0' & i_totalChannels);  -- 8 bit signed value, maximum possible value is 127
            timeSum <= i_timeSum;
            if (unsigned(i_Nsamples) = 0) then
                force_zeroA <= '1';
            else
                force_zeroA <= '0';
            end if;
            if (unsigned(i_totalTimes) < 128) then
                -- Used to generate the final correction of +2 to account for off-by-0.5 
                -- in the time centroids.
                short_integrationA <= '1';
            else
                -- Long integrations (192 time samples, 0.849ms) need a correction of 0.6666 
                -- at the output (but we have integers so we use a correction of +1 below) 
                short_integrationA <= '0';
            end if;
            
            
            -- 2nd pipeline stage
            centroid_denominator0 <= totalTimes * Nsamples;  -- (9 bit) x (16 bit) = 25 bit, max possible value = 192 * (192*127) = 4681728, so will fit into a signed 24 bit value
            centroid_numerator0 <= timeSum; -- 24 bit value, max possible is 2328672
            weight_denominator0 <= totalTimes * totalChannels; -- (9 bit) * (8 bit) = 17 bit, max possible value = 192 * 127 = 24384
            weight_numerator0 <= std_logic_vector(Nsamples); -- 16 bit value, max possible is 24384
            force_zero0       <= force_zeroA;
            short_integration0 <= short_integrationA;
            
            -- 3rd pipeline stage
            centroid_denominator1 <= std_logic_vector(centroid_denominator0(23 downto 0));
            centroid_numerator1   <= centroid_numerator0;
            weight_denominator1   <= std_logic_vector(weight_denominator0(15 downto 0));
            weight_numerator1     <= weight_numerator0;
            short_integration1    <= short_integration0;
            force_zero1           <= force_zero0;
            
            -- 4th pipeline stage
            centroid_numerator(0) <= centroid_numerator1;
            centroid_denominator(0) <= centroid_denominator1;
            weight_numerator(0) <= weight_numerator1;
            weight_denominator(0) <= weight_denominator1;
            force_zero(0) <= force_zero1;
            short_integration(0) <= short_integration1;
            
            -- Extra 7 pipeline stages to match the latency of the weight
            centroid_del(0) <= std_logic_vector(unsigned(centroid_result(9)(7 downto 0)) - 128);
            centroid_del(6 downto 1) <= centroid_del(5 downto 0);
            
            -- Extra 16 pipeline stages for force_zero signal, to match the dividers.
            force_zero(16 downto 1) <= force_zero(15 downto 0);
            short_integration(16 downto 1) <= short_integration(15 downto 0);
            
            -- output stage
            if force_zero(16) = '1' then
                o_centroid <= (others => '0');
                o_weight <= (others => '0');
            else
                if short_integration(16) = '1' then
                    o_centroid <= std_logic_vector(unsigned(centroid_del(6)) + 2);
                else
                    o_centroid <= std_logic_vector(unsigned(centroid_del(6)) + 1);
                end if;
                o_weight <= sqrt_weight;
            end if;
            
        end if;
    end process;
    
    centroid_result(0) <= "000000000";
    weight_result(0) <= "0000000000000";
    
    weight_div_stages : for i in 0 to 12 generate
    
        process(i_clk)
            variable weight_numerator_v : std_logic_vector(15 downto 0);
        begin
            if rising_edge(i_clk) then
                
                -- Divider for data valid, 12 bit result, which is then converted via sqrt rom to an 8 bit result.
                -- This algorithm relies on the initial denominator being greater than or equal to the initial numerator.
                -- numerator = total number of samples used (up to 24384)
                -- denominator = total possible number of samples (also up to 24384)
                if (unsigned(weight_numerator(i)) >= unsigned(weight_denominator(i))) then 
                    weight_numerator_v := std_logic_vector(unsigned(weight_numerator(i)) - unsigned(weight_denominator(i)));
                    weight_result(i+1) <= weight_result(i)(11 downto 0) & '1';
                else
                    weight_numerator_v := weight_numerator(i);
                    weight_result(i+1) <= weight_result(i)(11 downto 0) & '0';
                end if;
                weight_numerator(i+1)(15 downto 0) <= weight_numerator_v(14 downto 0) & '0';
                weight_denominator(i+1) <= weight_denominator(i);
                
            end if;
        end process;
    
    end generate;
    
    centroid_div_stages : for i in 0 to 8 generate
    
        process(i_clk)
            variable centroid_numerator_v : std_logic_vector(23 downto 0);
        begin
            if rising_edge(i_clk) then
                
                -- Divider : 8 stages of shift and subtract for the centroid
                -- Algorithm assumes the initial denominator being larger than the initial numerator.
                -- numerator = i_timesum = sum of the time indeces of all the contributing samples
                -- denominator = i_totalTimes * i_NSamples
                if (unsigned(centroid_numerator(i)) >= unsigned(centroid_denominator(i))) then 
                    centroid_numerator_v := std_logic_vector(unsigned(centroid_numerator(i)) - unsigned(centroid_denominator(i)));
                    centroid_result(i+1) <= centroid_result(i)(7 downto 0) & '1';
                else
                    centroid_numerator_v := centroid_numerator(i);
                    centroid_result(i+1) <= centroid_result(i)(7 downto 0) & '0';
                end if;
                centroid_numerator(i+1)(23 downto 0) <= centroid_numerator_v(22 downto 0) & '0';
                centroid_denominator(i+1) <= centroid_denominator(i);
                
            end if;
        end process;
    
    end generate;
    
    
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            -- Saturate weight_result to 4095.
            -- The only way this can happen is if the result of the division is 4096
            -- which occurs when there are no omitted samples,
            -- i.e. i_Nsamples = i_totalTimes * i_totalChannels
            if weight_result(13)(12) = '1' then
                sqrt_input <= "111111111111";
            else
                sqrt_input <= weight_result(13)(11 downto 0);
            end if;
        end if;
    end process;
    
    -- Square root of the weight
    -- 2 cycle latency.
    sqrt_romi : entity correlator_lib.sqrt_rom 
    port map ( 
        i_clk  => i_clk, --  in  std_logic; 
        i_addr => sqrt_input, -- in  std_logic_vector(11 downto 0); 
        o_data => sqrt_weight -- out std_logic_vector(7 downto 0) 
    );
    
    
end Behavioral;

