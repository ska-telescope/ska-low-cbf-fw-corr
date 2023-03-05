----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 08/15/2022 09:34:16 AM
-- Module Name: centroid_divider - Behavioral
-- Description: 
--  Convert raw centroid data into 2 byte values to be sent to SDP.
--  Input data is
--   - 19 bit sum of times (i_timeSum)
--       - Max possible value is (192/2 (=average accumulated value)) * (192 times) * (24 fine channels) = 442368
--   - 13 bit number of contributing samples (i_Nsamples).
--       - Max possible value is (192 times) * (24 fine channels) = 4608
-- 
--  Output values are : 
--   - time centroid = (256/i_totalTimes) * (i_timeSum / i_Nsamples) - 128
--      i.e. 256 * i_timeSum / (i_totalTimes * i_Nsamples) - 128
--          Note  i_timeSum is always less than (i_totalTime * i_Nsamples)
--   - weight        = 255 * sqrt(i_Nsamples / (totalTimes * totalChannels)) 
--          Likewise, i_Nsamples is at most (totalTimes * totalChannels)
----------------------------------------------------------------------------------

library IEEE, common_lib, correlator_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
USE common_lib.common_pkg.ALL;

entity centroid_divider is
    port (
        i_clk : in std_logic;
        -- data input
        i_timeSum : in std_logic_vector(18 downto 0);      -- Sum of the time indices for the samples that were used in the integration.
        i_Nsamples : in std_logic_vector(12 downto 0);     -- Number of samples used in the integration.
        -- semi-static inputs
        i_totalTimes : in std_logic_vector(7 downto 0);    -- total time samples being integrated, e.g. 192. 
        i_totalChannels : in std_logic_vector(4 downto 0); -- Number of channels integrated, typically 24.
        -- Outputs,  21 clock latency.
        o_centroid : out std_logic_vector(7 downto 0);
        o_weight : out std_logic_vector(7 downto 0)
    );
end centroid_divider;

architecture Behavioral of centroid_divider is

    signal totalTimes : signed(8 downto 0);
    signal Nsamples : signed(13 downto 0);
    signal totalChannels : signed(5 downto 0);
    signal centroid_denominator0 : signed(22 downto 0); -- = totalTimes * Nsamples, max possible value is 192 * 4608 = 884736
    signal weight_denominator0 : signed(14 downto 0);   -- = totalTimes * totalChannels, max possible value is 192 * 24 = 4608
    
    signal centroid_numerator0: std_logic_vector(20 downto 0);
    signal centroid_denominator1, centroid_numerator1 : std_logic_vector(20 downto 0);
    signal weight_numerator0 : std_logic_vector(12 downto 0);
    signal weight_denominator1,  weight_numerator1 : std_logic_vector(12 downto 0);
    signal timeSum : std_logic_vector(18 downto 0);
    
    signal centroid_numerator : t_slv_21_arr(9 downto 0);
    signal centroid_denominator : t_slv_21_arr(9 downto 0);
    signal centroid_result : t_slv_9_arr(9 downto 0);
    
    signal weight_numerator : t_slv_14_arr(13 downto 0);
    signal weight_denominator : t_slv_14_arr(13 downto 0);
    signal weight_result : t_slv_13_arr(13 downto 0);
    
    signal sqrt_weight : std_logic_vector(7 downto 0);
    signal centroid_del : t_slv_8_arr(6 downto 0);
    signal sqrt_input : std_logic_vector(11 downto 0);
    signal force_zeroA, force_zero0, force_zero1 : std_logic;
    signal force_zero : std_logic_vector(16 downto 0);
    
begin
    
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            -- 1st pipeline stage
            totalTimes <= signed('0' & i_totalTimes);
            Nsamples <= signed('0' & i_Nsamples);
            totalChannels <= signed('0' & i_totalChannels);
            timeSum <= i_timeSum;
            if (unsigned(i_Nsamples) = 0) then
                force_zeroA <= '1';
            else
                force_zeroA <= '0';
            end if;
            
            -- 2nd pipeline stage
            centroid_denominator0 <= totalTimes * Nsamples;
            centroid_numerator0 <= "00" & timeSum;
            weight_denominator0 <= totalTimes * totalChannels;
            weight_numerator0 <= std_logic_vector(Nsamples(12 downto 0));
            force_zero0       <= force_zeroA;
            
            -- 3rd pipeline stage
            centroid_denominator1 <= std_logic_vector(centroid_denominator0(20 downto 0));
            centroid_numerator1   <= centroid_numerator0;
            weight_denominator1   <= std_logic_vector(weight_denominator0(12 downto 0));
            weight_numerator1     <= weight_numerator0;
            force_zero1           <= force_zero0;
            
            -- 4th pipeline stage
            centroid_numerator(0) <= centroid_numerator1;
            centroid_denominator(0) <= centroid_denominator1;
            weight_numerator(0) <= '0' & weight_numerator1;
            weight_denominator(0) <= '0' & weight_denominator1;
            force_zero(0) <= force_zero1;
            
            -- Extra 7 pipeline stages to match the latency of the weight
            centroid_del(0) <= std_logic_vector(unsigned(centroid_result(9)(7 downto 0)) - 128);
            centroid_del(6 downto 1) <= centroid_del(5 downto 0);
            
            -- Extra 16 pipeline stages for force_zero signal, to match the dividers.
            force_zero(16 downto 1) <= force_zero(15 downto 0);
            
            -- output stage
            if force_zero(16) = '1' then
                o_centroid <= (others => '0');
                o_weight <= (others => '0');
            else
                o_centroid <= centroid_del(6);
                o_weight <= sqrt_weight;
            end if;
            
        end if;
    end process;
    
    centroid_result(0) <= "000000000";
    weight_result(0) <= "0000000000000";
    
    weight_div_stages : for i in 0 to 12 generate
    
        process(i_clk)
            variable weight_numerator_v : std_logic_vector(13 downto 0);
        begin
            if rising_edge(i_clk) then
                
                -- Divider for data valid, 12 bit result, which is then converted via sqrt rom to an 8 bit result.
                -- Note this algorithm relies on the initial denominator being greater than or equal to the initial numerator.
                if (unsigned(weight_numerator(i)) >= unsigned(weight_denominator(i))) then 
                    weight_numerator_v := std_logic_vector(unsigned(weight_numerator(i)) - unsigned(weight_denominator(i)));
                    weight_result(i+1) <= weight_result(i)(11 downto 0) & '1';
                else
                    weight_numerator_v := weight_numerator(i);
                    weight_result(i+1) <= weight_result(i)(11 downto 0) & '0';
                end if;
                weight_numerator(i+1)(13 downto 0) <= weight_numerator_v(12 downto 0) & '0';
                weight_denominator(i+1) <= weight_denominator(i);
                
            end if;
        end process;
    
    end generate;
    
    centroid_div_stages : for i in 0 to 8 generate
    
        process(i_clk)
            variable centroid_numerator_v : std_logic_vector(20 downto 0);
        begin
            if rising_edge(i_clk) then
                
                -- Divider : 8 stages of shift and subtract for the centroid
                -- Algorithm assumes the initial denominator being larger than the initial numerator.
                if (unsigned(centroid_numerator(i)) >= unsigned(centroid_denominator(i))) then 
                    centroid_numerator_v := std_logic_vector(unsigned(centroid_numerator(i)) - unsigned(centroid_denominator(i)));
                    centroid_result(i+1) <= centroid_result(i)(7 downto 0) & '1';
                else
                    centroid_numerator_v := centroid_numerator(i);
                    centroid_result(i+1) <= centroid_result(i)(7 downto 0) & '0';
                end if;
                centroid_numerator(i+1)(20 downto 0) <= centroid_numerator_v(19 downto 0) & '0';
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

