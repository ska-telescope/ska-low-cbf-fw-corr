----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 30.10.2020 22:21:03
-- Module Name: ct_atomic_cor_out - Behavioral
-- Description: 
--  Calculate the address in HBM memory of a 512-byte block of data for corner turn 2.
--
--  The 512 byte blocks are arranged in a 3-D array (fine_channel, i_time_block, station)
--                                                        |                         |
--                                                  slowest changing          fastest changing
--
--  Where :
--   * i_time_block = 0 to 5, for 6 blocks of 32 time samples each (there are 32 time samples in a 512 byte block written to the HBM).
--                    Note 6 x 32 = 192 time samples total = 849 ms of data.
--   * station = floor(i_station/4); where i_station runs from 0 to (i_SB_stations-1). 
--               Groups of 4 stations are stored in each 512 byte data block,
--               so the low 2 bits of i_station are ignored (thus floor(i_station/4))
--   * fine_channel = (i_coarse_channel*3456 + i_fine_channel) - (i_SB_coarseStart * 3456 + i_SB_fineStart)
--  
--  The address calculated is:
--   o_HBM_addr = i_SB_HBM_base_addr + 512 * [fine_channel * 6 * ceil(i_SB_stations/4) + i_time_block * ceil(i_SB_stations/4) + station]
--
--  ---------------------------------------------------------
--  Aside : Each 512 byte block of data contains data for : 
--    * 32 time samples
--    * 4 stations
--    * 2 polarisations
--    = 32 * 4 * 2 * (2 byte complex) = 512 bytes
--  
----------------------------------------------------------------------------------
library IEEE, ct_lib, DSP_top_lib, common_lib, axi4_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use DSP_top_lib.DSP_top_pkg.all;
USE common_lib.common_pkg.all;

entity get_ct2_HBM_addr is
    port(
        i_axi_clk : in std_logic;
        -- Values from the Subarray-beam table
        i_SB_HBM_base_Addr : in std_logic_vector(31 downto 0); -- Base address in HBM for this subarray-beam
        i_SB_coarseStart   : in std_logic_vector(8 downto 0);  -- First coarse channel for this subarray-beam, x781.25 kHz to get the actual sky frequency 
        i_SB_fineStart     : in std_logic_vector(11 downto 0); -- First fine channel for this subarray-beam, runs from 0 to 3455
        i_SB_stations      : in std_logic_vector(15 downto 0); -- Total number of stations in this subarray-beam
        i_SB_N_fine        : in std_logic_vector(23 downto 0); -- Total number of fine channels to store for this subarray-beam
        -- Values for this particular block of 512 bytes. Each block of 512 bytes is 4 stations, 32 time samples ((4stations)*(32timesamples)*(2pol)*(1byte)(2(complex)) = 512 bytes)
        i_coarse_channel   : in std_logic_vector(8 downto 0);  -- coarse channel for this block, x781.25kHz to get the actual sky frequency (so is comparable to i_SB_coarseStart
        i_fine_channel     : in std_logic_vector(23 downto 0); -- fine channel for this block; Actual channel referred to is i_coarse_channel*3456 + i_fine_channel, so it is ok for this to be more than 3455.
        i_station          : in std_logic_vector(11 downto 0); -- Index of this station within the subarray; low 2 bits are ignored.
        i_time_block       : in std_logic_vector(2 downto 0);  -- Which time block this is for; 0 to 5. Each time block is 32 time samples.
        i_buffer           : in std_logic; -- Which half of the buffer to calculate for (each half is 1.5 Gbytes)
        -- All above data is valid, do the calculation.
        i_valid            : in std_logic;
        -- Resulting address in the HBM, after 8 cycles latency.
        o_HBM_addr     : out std_logic_vector(31 downto 0); -- Always 512-byte aligned.
        o_out_of_range : out std_logic; -- indicates that the values for (i_coarse_channel, i_fine_channel, i_station, i_time_block) are out of range, and thus o_HBM_addr is not valid.
        o_fine_high    : out std_logic; -- indicates that the fine channel selected is higher than the maximum fine channel (i.e. > (i_SB_coarseStart * 3456 + i_SB_fineStart))
        o_fine_remaining : out std_logic_vector(11 downto 0); -- Number of fine channels remaining to send for this coarse channel.
        o_valid        : out std_logic -- some fixed number of clock cycles after i_valid.
    );
end get_ct2_HBM_addr;

architecture Behavioral of get_ct2_HBM_addr is
    
    signal SB_N_fine, coarse_diff_x_3456_p_fine_m_fstart_ext : std_logic_vector(24 downto 0);
    signal SB_N_fine_del1, SB_N_fine_del2, SB_N_fine_del3, SB_N_fine_del4, fine_remaining : std_logic_vector(24 downto 0);
    signal demap_station_x128 : std_logic_vector(31 downto 0);
    --signal demap_station_x256_del1, demap_station_x256_del2 : std_logic_vector(31 downto 0);
    signal HBM_base_plus_station : std_logic_vector(31 downto 0);
    signal coarse_diff_del1 : std_logic_vector(8 downto 0);
    signal coarse_diff_del1_ext : std_logic_vector(9 downto 0);
    constant c_3456 : std_logic_vector(12 downto 0) := "0110110000000"; -- 3456
    signal coarse_diff_x_3456_del2 : signed(22 downto 0);
    signal coarse_out_of_range : std_logic := '0';
    signal fine_channel_del1 : std_logic_vector(23 downto 0);
    signal SB_fineStart_del1, SB_fineStart_del2 : std_logic_vector(11 downto 0);
    signal time_x_N_fine_del4, time_x_N_fine_del3 : std_logic_vector(22 downto 0);
    signal fine_channel_del2, SB_fineStart_del3, sum3, coarse_diff_x_3456_plus_fine_del3, coarse_diff_x_3456_p_fine_m_fstart, sum1_del5 : std_logic_vector(22 downto 0);
    signal sum1_ext_del5 : std_logic_vector(23 downto 0);
    signal SB_stations_div4_del1, SB_stations_div4_del2, SB_stations_div4_del3, SB_stations_div4_del4 : std_logic_vector(13 downto 0);
    signal SB_stations_div4_del2_ext : std_logic_vector(15 downto 0);
    signal SB_stations_div4_del1_lowbits : std_logic_vector(1 downto 0);
    signal SB_stations_div4_del5 : std_logic_vector(15 downto 0);  -- The number of (sub)stations in this subarray-beam
    signal stations_x_sum1 : signed(39 downto 0);
    signal stations_x_sum1_x512 : std_logic_vector(31 downto 0);
    signal HBM_base_plus_station_del2, HBM_base_plus_station_del3, HBM_base_plus_station_del4, HBM_base_plus_station_del5, HBM_base_plus_station_del6, HBM_base_plus_station_del7 : std_logic_vector(31 downto 0);
    signal valid_del : std_logic_vector(7 downto 0);
    
    signal fine_high, fine_low, bad_station, bad_time : std_logic;
    signal bad_del2, bad_del3, bad_del4, bad_del5, bad_del6, bad_del7 : std_logic;
    signal buffer_del1 : std_logic;
    constant c_buffer_offset : std_logic_vector(31 downto 0) := x"60000000"; -- 1.5 Gbytes; second half of the buffer is 1.5 Gbytes on.
    signal fine_high_del6, fine_high_del7 : std_logic;
    signal fine_remaining_del6, fine_remaining_del7 : std_logic_vector(11 downto 0);
    
    signal time_block_del1 : std_logic_vector(2 downto 0);
    signal time_block_del2 : std_logic_vector(3 downto 0);
    signal stations_x6_del3, stations_x6_del4, stations_x4_ext, stations_x2_ext : std_logic_vector(17 downto 0);
    
    signal coarse_diff_x_3456_p_fine_m_fstart_24bit : std_logic_vector(23 downto 0);
    signal fine_offset_del5 : signed(41 downto 0);
    signal HBM_base_station_time_del6, HBM_base_station_time_del5, HBM_base_station_time_del4, fine_offset_x512_del6 : std_logic_vector(31 downto 0);
    
    signal HBM_base_station_time_fine_del7 : std_logic_vector(31 downto 0);
    signal time_x_stations_del3 : signed(19 downto 0);
    signal time_x_stations_x512 : std_logic_vector(31 downto 0);
    
begin
    
    -- Drop low 2 bits of i_station, since we only return 512-byte aligned addresses.
    demap_station_x128 <= "0000000000000" & i_station(11 downto 2) & "000000000"; -- 32 bits = 13+10+9
    SB_N_Fine <= '0' & i_SB_N_fine;
    coarse_diff_del1_ext <= '0' & coarse_diff_del1;
    sum1_ext_del5 <= '0' & sum1_del5;
    stations_x4_ext <= "00" & SB_stations_div4_del2 & "00";
    stations_x2_ext <= "000" & SB_stations_div4_del2 & '0';
    SB_stations_div4_del2_ext <= "00" & SB_stations_div4_del2;
    coarse_diff_x_3456_p_fine_m_fstart_ext <= "00" & coarse_diff_x_3456_p_fine_m_fstart;
    coarse_diff_x_3456_p_fine_m_fstart_24bit <= '0' & coarse_diff_x_3456_p_fine_m_fstart;
    
    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            
            -- Check that the inputs are in range.
            if (unsigned(i_coarse_channel) < unsigned(i_SB_coarseStart)) then
                coarse_out_of_range <= '1';
            else
                coarse_out_of_range <= '0';
            end if;
            
            if ((unsigned(i_coarse_channel) = unsigned(i_SB_coarseStart)) and (unsigned(i_fine_channel) < unsigned(i_SB_fineStart))) then
                fine_low <= '1';
            else
                fine_low <= '0';
            end if;
            
            if (unsigned(i_station) >= unsigned(i_SB_stations)) then
                bad_station <= '1';
            else
                bad_station <= '0';
            end if;
            
            if (i_time_block = "110" or i_time_block = "111") then
                bad_time <= '1';
            else
                bad_time <= '0';
            end if;
            
            bad_del2 <= coarse_out_of_range or fine_low or bad_station or bad_time;
            bad_del3 <= bad_del2;
            bad_del4 <= bad_del3;
            bad_del5 <= bad_del4;
            
            SB_N_fine_del1 <= SB_N_Fine;
            SB_N_fine_del2 <= SB_N_Fine_del1;
            SB_N_Fine_del3 <= SB_N_Fine_del2;
            SB_N_Fine_del4 <= SB_N_Fine_del3;
            
            if (unsigned(coarse_diff_x_3456_p_fine_m_fstart_ext) >= unsigned(SB_N_Fine_del4)) then
                fine_high <= '1';
            else
                fine_high <= '0';
            end if;
            fine_remaining <= std_logic_vector(unsigned(SB_N_Fine_del4) - unsigned(coarse_diff_x_3456_p_fine_m_fstart_ext));
            
            bad_del6 <= bad_del5;
            fine_high_del6 <= fine_high;
            if (unsigned(fine_remaining) > 3456) then
                fine_remaining_del6 <= x"D80"; -- 3456 decimal, i.e. all of the current coarse channel.
            else
                fine_remaining_del6 <= fine_remaining(11 downto 0);
            end if;
            
            fine_high_del7 <= fine_high_del6;
            bad_del7 <= bad_del6;
            fine_remaining_del7 <= fine_remaining_del6;
            
            ------------------------------------------
            -- The address for this data in the HBM is derived from the inputs to this module according to :
            --   
            -- o_HBM_addr = i_SB_HBM_base_addr + 512 * [
            --               ((i_coarse_channel*3456 + i_fine_channel) - (i_SB_coarseStart * 3456 + i_SB_fineStart)) * 6 * ceil(i_SB_stations/4) + 
            --               i_time_block * ceil(i_SB_stations/4)
            --               floor(i_station/4)]
            --
            HBM_base_plus_station <= std_logic_vector(unsigned(i_SB_HBM_base_addr) + unsigned(demap_station_x128));
            time_block_del1 <= i_time_block;
            buffer_del1 <= i_buffer;
            SB_stations_div4_del1 <= i_SB_stations(15 downto 2);
            SB_stations_div4_del1_lowbits <= i_SB_stations(1 downto 0);
            fine_channel_del1 <= i_fine_channel;
            SB_fineStart_del1 <= i_SB_fineStart;
            coarse_diff_del1 <= std_logic_vector(unsigned(i_coarse_channel) - unsigned(i_SB_coarseStart));
            
            ------------------------------------------------------------
            if buffer_del1 = '0' then
                HBM_base_plus_station_del2 <= HBM_base_plus_station;
            else
                HBM_base_plus_station_del2 <= std_logic_vector(unsigned(HBM_base_plus_station) + unsigned(c_buffer_offset));
            end if;
            time_block_del2 <= '0' & time_block_del1;
            if SB_stations_div4_del1_lowbits = "00" then
                SB_stations_div4_del2 <= SB_stations_div4_del1;
            else
                SB_stations_div4_del2 <= std_logic_vector(unsigned(SB_stations_div4_del1) + 1);
            end if;
            fine_channel_del2 <= fine_channel_del1(22 downto 0); -- convert to 23 bit value.
            coarse_diff_x_3456_del2 <= signed(coarse_diff_del1_ext) * (signed(c_3456)); -- 10 bit x 13 bit = 23 bit result.
            SB_fineStart_del2 <= SB_fineStart_del1;
            
            ------------------------------------------------------------
            stations_x6_del3 <= std_logic_vector(unsigned(stations_x2_ext) + unsigned(stations_x4_ext));            
            
            -- At this point HBM_base_plus_station_del3 <= i_SB_HBM_base_addr + 512 * floor(i_station/4) + c_buffer_offset
            HBM_base_plus_station_del3 <= HBM_base_plus_station_del2;
            SB_fineStart_del3 <= "00000000000" & SB_fineStart_del2;
            coarse_diff_x_3456_plus_fine_del3 <= std_logic_vector(unsigned(coarse_diff_x_3456_del2) + unsigned(fine_channel_del2));
            
            -- 20 bit result = 16 bit x 4 bit
            time_x_stations_del3 <= signed(SB_stations_div4_del2_ext) * signed(time_block_del2);
            
            ------------------------------------------------------------
            HBM_base_station_time_del4 <= HBM_base_plus_station_del3;
            time_x_stations_x512 <= "000" & std_logic_vector(time_x_stations_del3) & "000000000";
            stations_x6_del4 <= stations_x6_del3;
            -- this value is the number of fine channels that we are past the first fine channel, as defined by (i_SB_coarseStart*3456 + i_SB_fineStart)
            -- aligns with _del4
            coarse_diff_x_3456_p_fine_m_fstart <= std_logic_vector(unsigned(coarse_diff_x_3456_plus_fine_del3) - unsigned(SB_fineStart_del3));
            
            ------------------------------------------------------------
            HBM_base_station_time_del5 <= std_logic_vector(unsigned(HBM_base_station_time_del4) + unsigned(time_x_stations_x512));
            -- (24 bit) * (18 bit)
            fine_offset_del5 <= signed(coarse_diff_x_3456_p_fine_m_fstart_24bit) * signed(stations_x6_del4);
            
            ------------------------------------------------------------
            HBM_base_station_time_del6 <= HBM_base_station_time_del5;
            fine_offset_x512_del6 <= std_logic_vector(fine_offset_del5(22 downto 0)) & "000000000";
            
            ------------------------------------------------------------
            HBM_base_station_time_fine_del7 <= std_logic_vector(unsigned(HBM_base_station_time_del6) + unsigned(fine_offset_x512_del6));
            
            ------------------------------------------------------------
            o_HBM_addr <= HBM_base_station_time_fine_del7;
            o_valid <= valid_del(6); -- valid_del(6) instead of valid_del(7), since valid_del(0) = "del1"
            o_out_of_range <= bad_del7;
            o_fine_high <= fine_high_del7;
            o_fine_remaining <= fine_remaining_del7;
            
            valid_del(0) <= i_valid;
            valid_del(7 downto 1) <= valid_del(6 downto 0);
            
        end if;
    end process;
    
    
end Behavioral;

