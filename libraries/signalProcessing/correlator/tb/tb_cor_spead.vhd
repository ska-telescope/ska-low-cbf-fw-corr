----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: Giles Babich
-- 
-- 
-- TB for correlator reading and data packing 
-- 
-- 
----------------------------------------------------------------------------------


library IEEE,technology_lib, PSR_Packetiser_lib, signal_processing_common, HBM_PktController_lib; 
library correlator_lib, common_lib, spead_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use spead_lib.ethernet_pkg.ALL;
use spead_lib.CbfPsrHeader_pkg.ALL;
use common_lib.common_pkg.ALL;
Library axi4_lib;
USE axi4_lib.axi4_lite_pkg.ALL;
use axi4_lib.axi4_full_pkg.all;


entity tb_cor_spead is
--  Port ( );
end tb_cor_spead;

architecture Behavioral of tb_cor_spead is
constant fname          : string := "";
-- assuming stim in base of repo for the moment.
constant init_fname     : string := "../../../../../../../LTA_HBM_dbg_check.txt";
constant HBM_addr_width         : integer := 32;

signal init_mem     : std_logic     := '0';

signal clock_300 : std_logic := '0';    -- 3.33ns
signal clock_400 : std_logic := '0';    -- 2.50ns
signal clock_322 : std_logic := '0';    -- 3.11ns

signal testCount_400        : integer   := 0;
signal testCount_300        : integer   := 0;
signal testCount_322        : integer   := 0;

signal clock_400_rst        : std_logic := '1';
signal clock_300_rst        : std_logic := '1';
signal clock_322_rst        : std_logic := '1';

signal power_up_rst_clock_400   : std_logic_vector(31 downto 0) := c_ones_dword;
signal power_up_rst_clock_300   : std_logic_vector(31 downto 0) := c_ones_dword;
signal power_up_rst_clock_322   : std_logic_vector(31 downto 0) := c_ones_dword;

signal loop_generator           : integer := 0;
signal loops                    : integer := 0;

signal rx_packet_size           : std_logic_vector(13 downto 0) := "00" & x"000";   -- MODULO 64!!
signal rx_enable_capture        : std_logic := '0';

signal HBM_axi_ar               : t_axi4_full_addr;                 -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
signal HBM_axi_arready          : std_logic;
signal HBM_axi_r                : t_axi4_full_data;                 -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
signal HBM_axi_rready           : std_logic;

signal spead_data               : t_slv_512_arr(1 downto 0);
signal spead_data_rd            : std_logic_vector(1 downto 0); 
signal current_array            : t_slv_8_arr(1 downto 0); 
signal spead_data_rdy           : std_logic_vector(1 downto 0);
signal byte_count               : t_slv_14_arr(1 downto 0); 
signal enabled_array            : t_slv_8_arr(1 downto 0); 
signal freq_index               : t_slv_17_arr(1 downto 0);
signal time_ref                 : t_slv_64_arr(1 downto 0);

signal hbm_start_addr           : std_logic_vector(31 downto 0);
signal sub_array                : std_logic_vector(7 downto 0);      -- max of 16 zooms x 8 sub arrays = 128

signal data_valid               : std_logic := '0';

signal row                      : std_logic_vector(12 downto 0);     -- The index of the first row that is available, counts from zero.
signal row_count                : std_logic_vector(8 downto 0);      -- The number of rows available to be read out. Valid range is 1 to 256.
signal HBM_curr_addr            : std_logic_vector(31 downto 0);

constant cor_1                  : std_logic_vector(255 downto 0)    := x"1111111111111111111111111111111111111111111111111111111111111111";
constant cor_2                  : std_logic_vector(255 downto 0)    := x"2222222222222222222222222222222222222222222222222222222222222222";
constant cor_3                  : std_logic_vector(255 downto 0)    := x"3333333333333333333333333333333333333333333333333333333333333333";
constant cor_4                  : std_logic_vector(255 downto 0)    := x"4444444444444444444444444444444444444444444444444444444444444444";
constant cor_5                  : std_logic_vector(255 downto 0)    := x"5555555555555555555555555555555555555555555555555555555555555555";
constant cor_6                  : std_logic_vector(255 downto 0)    := x"6666666666666666666666666666666666666666666666666666666666666666";
constant cor_7                  : std_logic_vector(255 downto 0)    := x"7777777777777777777777777777777777777777777777777777777777777777";
constant cor_8                  : std_logic_vector(255 downto 0)    := x"8888888888888888888888888888888888888888888888888888888888888888";
constant cor_9                  : std_logic_vector(255 downto 0)    := x"9999999999999999999999999999999999999999999999999999999999999999";
constant cor_A                  : std_logic_vector(255 downto 0)    := x"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
constant cor_B                  : std_logic_vector(255 downto 0)    := x"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";
constant cor_C                  : std_logic_vector(255 downto 0)    := x"CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC";
constant cor_D                  : std_logic_vector(255 downto 0)    := x"DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD";
constant cor_E                  : std_logic_vector(255 downto 0)    := x"EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE";
constant cor_F                  : std_logic_vector(255 downto 0)    := x"FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF";

signal i                        : integer := 0;
signal j                        : integer := 0;
signal meta_data_sel            : std_logic := '0';
signal test_meta_done           : std_logic := '0';
                                                            -- LOTS OF 256 BITS TO EMULATE META LAYOUT.
signal test_meta_triangle_1     : t_slv_512_arr(0 to 7)     := (zero_128 & zero_64      & zero_32       & x"DDEEAAFF"
                                                                & zero_128 & zero_64    & zero_32       & x"0000BEEF",
                                                                zero_128 & zero_64      & x"ACDC4545"   & x"FEEDDEAF"       
                                                                & zero_128 & zero_64    & x"00007E55"   & x"B0B0ABCD",
                                                                
                                                                zero_512, zero_512, zero_512, zero_512, zero_512, zero_512
                                                                );

--  4x4 matrix                                                  ROW 1
signal test_triangle_1          : t_slv_512_arr(0 to 31)    := (zero_256 & x"1A1B1C1D1A1B1C1D1A1B1C1D1A1B1C1D1A1B1C1D1A1B1C1D1A1B1C1D1A1B1C1D",
                                                                zero_512, zero_512, zero_512, zero_512, zero_512, zero_512, zero_512,
                                                                -- ROW 2
                                                                x"3A3B3C3D3A3B3C3D3A3B3C3D3A3B3C3D3A3B3C3D3A3B3C3D3A3B3C3D3A3B3C3D" & x"2A2B2C2D2A2B2C2D2A2B2C2D2A2B2C2D2A2B2C2D2A2B2C2D2A2B2C2D2A2B2C2D", 
                                                                zero_512, zero_512, zero_512, zero_512, zero_512, zero_512, zero_512,
                                                                -- ROW 3
                                                                x"5A5B5C5D5A5B5C5D5A5B5C5D5A5B5C5D5A5B5C5D5A5B5C5D5A5B5C5D5A5B5C5D" & x"4A4B4C4D4A4B4C4D4A4B4C4D4A4B4C4D4A4B4C4D4A4B4C4D4A4B4C4D4A4B4C4D",
                                                                zero_256 & x"6A6B6C6D6A6B6C6D6A6B6C6D6A6B6C6D6A6B6C6D6A6B6C6D6A6B6C6D6A6B6C6D", 
                                                                zero_512, zero_512, zero_512, zero_512, zero_512, zero_512,
                                                                -- ROW 4
                                                                x"8A8B8C8D8A8B8C8D8A8B8C8D8A8B8C8D8A8B8C8D8A8B8C8D8A8B8C8D8A8B8C8D" & x"7A7B7C7D7A7B7C7D7A7B7C7D7A7B7C7D7A7B7C7D7A7B7C7D7A7B7C7D7A7B7C7D",
                                                                x"AAABACADAAABACADAAABACADAAABACADAAABACADAAABACADAAABACADAAABACAD" & x"9A9B9C9D9A9B9C9D9A9B9C9D9A9B9C9D9A9B9C9D9A9B9C9D9A9B9C9D9A9B9C9D",
                                                                zero_512, zero_512, zero_512, zero_512, zero_512, zero_512
                                                                );

-- 20 x 20 matrix
-- 16C x 16R
-- 16C x 4R  + 16C x 4R
-- 16x16 + 16x4x2 = 256 + 128 = 384
                                                                --ROW 1                                                                
signal test_triangle_2          : t_slv_512_arr(0 to 191)   := (zero_256 & x"1A1B1C1D1A1B1C1D1A1B1C1D1A1B1C1D1A1B1C1D1A1B1C1D1A1B1C1D1A1B1C1D",
                                                                zero_512, zero_512, zero_512, zero_512, zero_512, zero_512, zero_512,
                                                                -- ROW 2
                                                                x"3A3B3C3D3A3B3C3D3A3B3C3D3A3B3C3D3A3B3C3D3A3B3C3D3A3B3C3D3A3B3C3D" & x"2A2B2C2D2A2B2C2D2A2B2C2D2A2B2C2D2A2B2C2D2A2B2C2D2A2B2C2D2A2B2C2D", 
                                                                zero_512, zero_512, zero_512, zero_512, zero_512, zero_512, zero_512,
                                                                -- ROW 3
                                                                x"5A5B5C5D5A5B5C5D5A5B5C5D5A5B5C5D5A5B5C5D5A5B5C5D5A5B5C5D5A5B5C5D" & x"4A4B4C4D4A4B4C4D4A4B4C4D4A4B4C4D4A4B4C4D4A4B4C4D4A4B4C4D4A4B4C4D",
                                                                zero_256 & x"6A6B6C6D6A6B6C6D6A6B6C6D6A6B6C6D6A6B6C6D6A6B6C6D6A6B6C6D6A6B6C6D", 
                                                                zero_512, zero_512, zero_512, zero_512, zero_512, zero_512,
                                                                -- ROW 4
                                                                x"8A8B8C8D8A8B8C8D8A8B8C8D8A8B8C8D8A8B8C8D8A8B8C8D8A8B8C8D8A8B8C8D" & x"7A7B7C7D7A7B7C7D7A7B7C7D7A7B7C7D7A7B7C7D7A7B7C7D7A7B7C7D7A7B7C7D",
                                                                x"AAABACADAAABACADAAABACADAAABACADAAABACADAAABACADAAABACADAAABACAD" & x"9A9B9C9D9A9B9C9D9A9B9C9D9A9B9C9D9A9B9C9D9A9B9C9D9A9B9C9D9A9B9C9D",
                                                                zero_512, zero_512, zero_512, zero_512, zero_512, zero_512,
                                                                -- ROW 5
                                                                cor_2 & cor_1 , cor_4 & cor_3 , zero_256 & cor_5 , zero_512 , zero_512 , zero_512 , zero_512 , zero_512,
                                                                -- ROW 6
                                                                cor_7 & cor_6 , cor_9 & cor_8 , cor_b & cor_a , zero_512 , zero_512 , zero_512 , zero_512 , zero_512,
                                                                -- ROW 7
                                                                cor_3 & cor_3 , cor_3 & cor_3 , cor_3 & cor_3 , zero_256 & cor_3 , zero_512 , zero_512 , zero_512 , zero_512,
                                                                -- ROW 8
                                                                cor_4 & cor_4 , cor_4 & cor_4 , cor_4 & cor_4 , cor_4 & cor_4 , zero_512 , zero_512 , zero_512 , zero_512,
                                                                -- ROW 9
                                                                cor_5 & cor_5 , cor_5 & cor_5 , cor_5 & cor_5 , cor_5 & cor_5 , zero_256 & cor_5 , zero_512 , zero_512 , zero_512,
                                                                -- ROW 10
                                                                cor_6 & cor_6 , cor_6 & cor_6 , cor_6 & cor_6 , cor_6 & cor_6 , cor_6 & cor_6 , zero_512 , zero_512 , zero_512,
                                                                -- ROW 11
                                                                cor_7 & cor_7 , cor_7 & cor_7 , cor_7 & cor_7 , cor_7 & cor_7 , cor_7 & cor_7 , zero_256 & cor_7 , zero_512 , zero_512,
                                                                -- ROW 12
                                                                cor_8 & cor_8 , cor_8 & cor_8 , cor_8 & cor_8 , cor_8 & cor_8 , cor_8 & cor_8 , cor_8 & cor_8 , zero_512 , zero_512,
                                                                -- ROW 13
                                                                cor_9 & cor_9 , cor_9 & cor_9 , cor_9 & cor_9 , cor_9 & cor_9 , cor_9 & cor_9 , cor_9 & cor_9 , zero_256 & cor_9 , zero_512,
                                                                -- ROW 14
                                                                cor_a & cor_a , cor_a & cor_a , cor_a & cor_a , cor_a & cor_a , cor_a & cor_a , cor_a & cor_a , cor_a & cor_a , zero_512,
                                                                -- ROW 15
                                                                cor_b & cor_b , cor_b & cor_b , cor_b & cor_b , cor_b & cor_b , cor_b & cor_b , cor_b & cor_b , cor_b & cor_b , zero_256 & cor_b,
                                                                -- ROW 16
                                                                cor_c & cor_c , cor_c & cor_c , cor_c & cor_c , cor_c & cor_c , cor_c & cor_c , cor_c & cor_c , cor_c & cor_c , cor_c & cor_c,
                                                                --------------------------------------------------------------------------------------------------------------------------------
                                                                -- ROW 17
                                                                cor_d & cor_d , cor_d & cor_d , cor_d & cor_d , cor_d & cor_d , cor_d & cor_d , cor_d & cor_d , cor_d & cor_d , cor_d & cor_d,
                                                                zero_256 & cor_2 , zero_512 , zero_512 , zero_512 , zero_512 , zero_512 , zero_512 , zero_512,
                                                                -- ROW 18
                                                                cor_e & cor_e , cor_e & cor_e , cor_e & cor_e , cor_e & cor_e , cor_e & cor_e , cor_e & cor_e , cor_e & cor_e , cor_e & cor_e,
                                                                cor_4 & cor_4 , zero_512 , zero_512 , zero_512 , zero_512 , zero_512 , zero_512 , zero_512,
                                                                -- ROW 19
                                                                cor_f & cor_f , cor_f & cor_f , cor_f & cor_f , cor_f & cor_f , cor_f & cor_f , cor_f & cor_f , cor_f & cor_f , cor_f & cor_f,
                                                                cor_6 & cor_6 , zero_256 & cor_6 , zero_512 , zero_512 , zero_512 , zero_512 , zero_512 , zero_512 ,
                                                                -- ROW 20
                                                                cor_9 & cor_9 , cor_9 & cor_9 , cor_9 & cor_9 , cor_9 & cor_9 , cor_9 & cor_9 , cor_9 & cor_9 , cor_9 & cor_9 , cor_9 & cor_9,
                                                                cor_1 & cor_1 , cor_1 & cor_1 , zero_512 , zero_512 , zero_512 , zero_512 , zero_512 , zero_512 
                                                                
                                                                );                                                                
                                    

begin

clock_300 <= not clock_300 after 3.33 ns;
clock_322 <= not clock_322 after 3.11 ns;
clock_400 <= not clock_400 after 2.50 ns;
    
-------------------------------------------------------------------------------------------------------------
-- powerup resets for SIM
test_runner_proc_clk300: process(clock_300)
begin
    if rising_edge(clock_300) then
        -- power up reset logic
        if power_up_rst_clock_300(31) = '1' then
            power_up_rst_clock_300(31 downto 0) <= power_up_rst_clock_300(30 downto 0) & '0';
            clock_300_rst   <= '1';
            testCount_300   <= 0;
            
        else
            clock_300_rst   <= '0';
            testCount_300   <= testCount_300 + 1;
            
        end if;
    end if;
end process;

test_runner_proc_clk322: process(clock_322)
begin
    if rising_edge(clock_322) then
        -- power up reset logic
        if power_up_rst_clock_322(31) = '1' then
            power_up_rst_clock_322(31 downto 0) <= power_up_rst_clock_322(30 downto 0) & '0';
            clock_322_rst   <= '1';
            testCount_322   <= 0;
        else
            clock_322_rst   <= '0';
            testCount_322   <= testCount_322 + 1;
        end if;
    end if;
end process;


test_runner_proc_clk400: process(clock_400)
begin
    if rising_edge(clock_400) then
        -- power up reset logic
        if power_up_rst_clock_400(31) = '1' then
            power_up_rst_clock_400(31 downto 0) <= power_up_rst_clock_400(30 downto 0) & '0';
            testCount_400   <= 0;
            clock_400_rst   <= '1';
        else
            testCount_400   <= testCount_400 + 1;
            clock_400_rst   <= '0';
        end if;
    end if;
end process;

-------------------------------------------------------------------------------------------------------------


-- HBM_axi_r.data  <=  test_meta_triangle_1(j) when meta_data_sel = '0' else
--                     test_triangle_2(i);


run_proc : process(clock_300)
begin
    if rising_edge(clock_300) then
        if clock_300_rst = '1' then
            data_valid  <= '0';
            i <= 0;
            j <= 0;
            meta_data_sel <= '0';
            test_meta_done <= '0';
            init_mem        <= '0';
        else
            
            if testCount_300 = 1 then
                init_mem    <= '1';
            else
                init_mem    <= '0';
            end if;

            freq_index(0)   <= (others => '0');
            sub_array       <= (others => '0');
            hbm_start_addr  <= x"00000000";

            if testCount_300 = 50 then
                row         <= 5D"0" & zero_byte;
                row_count   <= 9D"0";
                data_valid  <= '0';
            else
                row         <= "00000" & zero_byte;
                row_count   <= "000000000";
                data_valid  <= '0';
            end if;

            -- if meta_data_sel = '0' then 
            --     HBM_axi_r.data  <=  test_meta_triangle_1;
            -- else
            --     HBM_axi_r.data  <=  test_triangle_1(i);
            -- end if;
            
            if HBM_axi_r.valid = '1' then
                if HBM_axi_r.last = '1' AND meta_data_sel = '0' then
                    meta_data_sel <= '1';
                                        
                elsif meta_data_sel = '1' then
                    if i < 191 then
                        i <= i + 1;  
                    end if;
                end if;

                j <= j + 1;
            end if;

            -- some stimulus for initial triangle testing.
            if testCount_300 = 69 then --AND testCount_300 < 103 then
                -- META DATA FROM CORRELATOR SIM
                row         <= 13D"0";
                row_count   <= 9D"6";
                data_valid  <= '1';

            elsif testCount_300 > 75 then
            -- elsif testCount_300 > 200 AND testCount_300 < 392 then
            --     i <= i + 1;
            --     HBM_axi_r.data  <= test_triangle_2(i);
            --     --HBM_axi_r.valid <= '1';

            --     row         <= 13D"0";
            --     row_count   <= 9D"20";
            --     data_valid  <= '1';
            -- elsif testCount_300 > 800 AND testCount_300 < 992 then
            --     i <= i + 1;
            --     HBM_axi_r.data  <= test_triangle_2(i);
            --     --HBM_axi_r.valid <= '1';

            --     row         <= 13D"0";
            --     row_count   <= 9D"256";
            --     data_valid  <= '1';
            -- elsif testCount_300 > 36800 AND testCount_300 < 36992 then
            --     i <= i + 1;
            --     HBM_axi_r.data  <= test_triangle_2(i);
            --     --HBM_axi_r.valid <= '1';

            --     row         <= 13D"256";
            --     row_count   <= 9D"20";
            --     data_valid  <= '1';
            else
                i <= 0;
                --HBM_axi_r.data  <= zero_512;
                meta_data_sel <= '0';
                --HBM_axi_r.valid <= '0';
            end if;
                HBM_axi_r.resp  <= "00";
                --HBM_axi_r.last  <= '0';
        end if;

    end if;
end process;

DUT : entity correlator_lib.correlator_data_reader generic map ( 
        DEBUG_ILA           => FALSE
    )
    Port map ( 
        -- clock used for all data input and output from this module (300 MHz)
        i_axi_clk           => clock_300,
        i_axi_rst           => clock_300_rst,

        i_local_reset       => clock_300_rst,

        -- config of current sub/freq data read
        i_hbm_start_addr    => hbm_start_addr,
                                                                    -- Start address of the meta data is at (i_HBM_start_addr/16 + 256 Mbytes)
        i_sub_array         => sub_array,
        i_freq_index        => (others => '0'),
        i_data_valid        => data_valid,
        i_time_ref          => (others => '0'),
                            
        i_row               => row,
        i_row_count         => row_count,

        o_HBM_curr_addr     => HBM_curr_addr,

        -- HBM read interface
        o_HBM_axi_ar        => HBM_axi_ar,
        i_HBM_axi_arready   => HBM_axi_arready,
        i_HBM_axi_r         => HBM_axi_r,
        o_HBM_axi_rready    => HBM_axi_rready,
        
        -- Packed up Correlator Data.
        o_spead_data        => spead_data(0),
        i_spead_data_rd     => spead_data_rd(0),
        o_current_array     => current_array(0),
        o_spead_data_rdy    => spead_data_rdy(0),
        o_byte_count        => byte_count(0),
        i_enabled_array     => enabled_array(0),
        o_freq_index        => freq_index(0),
        o_time_ref          => time_ref(0)

    );


    -- signal HBM_axi_ar               : t_axi4_full_addr;                 -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
    -- signal HBM_axi_arready          : std_logic;
    -- signal HBM_axi_r                : t_axi4_full_data;                 -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
    -- signal HBM_axi_rready           : std_logic;

    HBM_interface : entity correlator_lib.HBM_axi_tbModel
    generic map (
        AXI_ADDR_WIDTH => HBM_addr_width, 
        AXI_ID_WIDTH => 1, 
        AXI_DATA_WIDTH => 512, 
        READ_QUEUE_SIZE => 16, 
        MIN_LAG => 60,    
        INCLUDE_PROTOCOL_CHECKER => TRUE,
        RANDSEED => 43526,             -- natural := 12345;
        LATENCY_LOW_PROBABILITY => 60, -- natural := 95;  -- probability, as a percentage, that non-zero gaps between read beats will be small (i.e. < 3 clocks)
        LATENCY_ZERO_PROBABILITY => 60 -- natural := 80   -- probability, as a percentage, that the gap between read beats will be zero.
    ) Port map (
        i_clk          => clock_300,
        i_rst_n        => not clock_300_rst, 
        -- WR
        axi_awaddr     => (others => '0'),
        axi_awid       => "0", 
        axi_awlen      => (others => '0'),
        axi_awsize     => "110",
        axi_awburst    => "01", 
        axi_awlock     => "00",  
        axi_awcache    => "0011", 
        axi_awprot     => "000",
        axi_awqos      => "0000", 
        axi_awregion   => "0000",
        axi_awvalid    => '0', 
        axi_awready    => open, 
        axi_wdata      => (others => '0'), 
        axi_wstrb      => (others => '0'),
        axi_wlast      => '0',
        axi_wvalid     => '0',
        axi_wready     => open,
        axi_bresp      => open,
        axi_bvalid     => open,
        axi_bready     => '1', 
        axi_bid        => open,
        -- RD 
        axi_araddr     => HBM_axi_ar.addr(HBM_addr_width-1 downto 0),
        axi_arlen      => HBM_axi_ar.len,
        axi_arsize     => "110",   -- 6 = 64 bytes per beat = 512 bit wide bus. -- out std_logic_vector(2 downto 0);
        axi_arburst    => "01",    -- "01" = incrementing address for each beat in the burst. -- out std_logic_vector(1 downto 0);
        axi_arlock     => "00",
        axi_arcache    => "0011",
        axi_arprot     => "000",
        axi_arvalid    => HBM_axi_ar.valid,
        axi_arready    => HBM_axi_arready,
        axi_arqos      => "0000",
        axi_arid       => "0",
	    axi_arregion   => "0000",
        axi_rdata      => HBM_axi_r.data,
        axi_rresp      => HBM_axi_r.resp,
        axi_rlast      => HBM_axi_r.last,
        axi_rvalid     => HBM_axi_r.valid,
        axi_rready     => HBM_axi_rready,

        -- control dump to disk.
        i_write_to_disk         => '0',
        i_write_to_disk_addr    => 0,
        i_write_to_disk_size    => 0,
        i_fname                 => fname,
        -- Initialisation of the memory
        -- The memory is loaded with the contents of the file i_init_fname in 
        -- any clock cycle where i_init_mem is high.
        i_init_mem              => init_mem,
        i_init_fname            => init_fname
    );

DUT_2 : entity spead_lib.spead_top generic map ( 
        DEBUG_ILA           => FALSE
    )
    port map ( 
        -- clock used for all data input and output from this module (300 MHz)
        i_axi_clk           => clock_300,
        i_axi_rst           => clock_300_rst,

        i_local_reset       => '0',

        -- streaming AXI to CMAC
        i_cmac_clk          => clock_322,
        i_cmac_clk_rst      => clock_322_rst,

        o_tx_axis_tdata     => open,
        o_tx_axis_tkeep     => open,
        o_tx_axis_tvalid    => open,
        o_tx_axis_tlast     => open,
        o_tx_axis_tuser     => open,
        i_tx_axis_tready    => (NOT clock_322_rst),

        -- Packed up Correlator Data.
        i_spead_data        => spead_data,
        o_spead_data_rd     => spead_data_rd,
        i_current_array     => current_array,
        i_spead_data_rdy    => spead_data_rdy,
        i_byte_count        => byte_count,
        o_enabled_array     => enabled_array,
        i_freq_index        => freq_index,
        i_time_ref          => time_ref

        -- ARGs

    );  

end Behavioral;
