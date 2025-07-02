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
library correlator_lib, common_lib, spead_lib, ethernet_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use ethernet_lib.ethernet_pkg.ALL;
--use spead_lib.CbfPsrHeader_pkg.ALL;
use spead_lib.spead_packet_pkg.ALL;
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
--constant init_fname     : string := "../../../../../../../HBM_read_out_test_triangle.txt";

constant g_TEST_CASE        : string := "../../../../../../../low-cbf-model/src_atomic/run_cor_1sa_17stations/";
--constant g_VIS_CHECK_FILE   : string := "LTA_vis_check.txt";
constant g_VIS_CHECK_FILE   : string := "hbm_default_layout.txt";

constant init_fname         : string := g_TEST_CASE & g_VIS_CHECK_FILE;

constant USE_TEST_CASE      : BOOLEAN := TRUE;
constant GEN_DATA_END       : BOOLEAN := TRUE;

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

signal tb_300_rst           : std_logic := '0';

signal power_up_rst_clock_400   : std_logic_vector(31 downto 0) := c_ones_dword;
signal power_up_rst_clock_300   : std_logic_vector(31 downto 0) := c_ones_dword;
signal power_up_rst_clock_322   : std_logic_vector(31 downto 0) := c_ones_dword;

signal cmac_ready               : std_logic;

signal loop_generator           : integer := 0;
signal loops                    : integer := 0;

signal rx_packet_size           : std_logic_vector(13 downto 0) := "00" & x"000";   -- MODULO 64!!
signal rx_enable_capture        : std_logic := '0';

signal HBM_axi_ar               : t_axi4_full_addr;                 -- read address bus : out t_axi4_full_addr (.valid, .addr(39:0), .len(7:0))
signal HBM_axi_arready          : std_logic;
signal HBM_axi_r                : t_axi4_full_data;                 -- r data bus : in t_axi4_full_data (.valid, .data(511:0), .last, .resp(1:0))
signal HBM_axi_rready           : std_logic;

-- SPEAD Signals
signal from_spead_pack          : t_spead_to_hbm_bus_array(1 downto 0);
signal to_spead_pack            : t_hbm_to_spead_bus_array(1 downto 0);

signal packetiser_enable        : std_logic_vector(1 downto 0); 

signal i_spead_lite_axi_mosi    : t_axi4_lite_mosi_arr(1 downto 0); 
signal o_spead_lite_axi_miso    : t_axi4_lite_miso_arr(1 downto 0);

signal i_spead_full_axi_mosi    : t_axi4_full_mosi_arr(1 downto 0);
signal o_spead_full_axi_miso    : t_axi4_full_miso_arr(1 downto 0);

signal hbm_start_addr           : std_logic_vector(31 downto 0);
signal stim_sub_array           : std_logic_vector(7 downto 0); 
signal stim_freq_index          : std_logic_vector(16 downto 0);
signal stim_table_select        : std_logic;

signal stim_time_ref            : std_logic_vector(63 downto 0);
signal ints_since_epoch         : std_logic_vector(31 downto 0);
signal no_of_283s               : std_logic_vector(1 downto 0);
signal time_of_int              : std_logic;

signal data_valid               : std_logic := '0';

signal stim_count               : integer := 0;

signal interrupt_hbm_rd         : std_logic := '0';

constant DEBUG_VEC_SIZE         : integer := 11;
signal tb_debug                 : std_logic_vector((DEBUG_VEC_SIZE-1) downto 0);

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


--HBM_axi_r.data  <=  test_meta_triangle_1(j) when meta_data_sel = '1' else
--                    test_triangle_2(i);


run_proc : process(clock_300)
begin
    if rising_edge(clock_300) then
        if clock_300_rst = '1' then
            data_valid      <= '0';
            i <= 0;
            j <= 0;
            meta_data_sel   <= '0';
            test_meta_done  <= '0';
            init_mem        <= '0';
            cmac_ready      <= '0';
            tb_debug        <= (others => '0');
            
            ints_since_epoch<= 32D"0";
            no_of_283s      <= "00";
            time_of_int     <= '0';
            stim_time_ref   <= (others => '0');
        else
            stim_table_select   <= '0';
            tb_debug(4)        <= '0';  -- END target sub array dummy value
            
            if testCount_300 = 1 then
                init_mem    <= '1';

                -- enable packetiser
                tb_debug(10)<= '1';
            else
                init_mem    <= '0';
            end if;

            

            if testCount_300 = 50 then
                row         <= 5D"0" & zero_byte;
                row_count   <= 9D"0";
                data_valid  <= '0';
            else
                row         <= "00000" & zero_byte;
                row_count   <= "000000000";
                data_valid  <= '0';
            end if;
            
            stim_time_ref   <= (others => '0');

            -- using defaul values send end packets.
            if testCount_300 = 1500 then
                tb_debug(3)        <= '0';  -- trigger END
            end if;

            if testCount_300 = 26500 then
                tb_debug(3)        <= '0';  -- trigger END
            end if;

            if testCount_300 = 30000 then
                tb_debug(2)        <= '0';  -- trigger INIT
            end if;
            
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


            if USE_TEST_CASE = TRUE AND (GEN_DATA_END = TRUE) then
                tb_300_rst      <= '0';
                if testCount_300 = 1000 then 
                    -- META DATA FROM CORRELATOR SIM
                    row             <= 13D"0";
                    row_count       <= 9D"253";
                    data_valid      <= '1';
                    stim_table_select   <= '1';
                    stim_freq_index <= 17D"0";
                    stim_sub_array  <= 8D"68";
                    hbm_start_addr  <= x"00000000";
                end if;
                
                    
                if testCount_300 = 150000 then 
                    -- META DATA FROM CORRELATOR SIM
                    row             <= 13D"0";
                    row_count       <= 9D"254";
                    data_valid      <= '1';
    
                    stim_table_select   <= '0';
                    stim_freq_index <= 17D"0";
                    stim_sub_array  <= 8D"69";
                    hbm_start_addr  <= x"00000000";
                end if;

                if testCount_300 = 9990 then
                    tb_300_rst      <= '1';
                end if;
                
                if testCount_300 = 300000 then 
                    -- META DATA FROM CORRELATOR SIM
                    row             <= 13D"0";
                    row_count       <= 9D"255";
                    data_valid      <= '1';
    
                    stim_table_select   <= '1';
                    stim_freq_index <= 17D"0";
                    stim_sub_array  <= 8D"70";
                    hbm_start_addr  <= x"00000000";
                end if;
                
                if testCount_300 = 14990 then
                    tb_300_rst      <= '1';
                end if;
                
                if testCount_300 = 450000 then 
                    -- META DATA FROM CORRELATOR SIM
                    row             <= 13D"0";
                    row_count       <= 9D"256";
                    data_valid      <= '1';
    
                    stim_freq_index <= 17D"0";
                    stim_sub_array  <= 8D"71";
                    hbm_start_addr  <= x"00000000";
                end if;
                
                if (testCount_300 >= 401420) AND (testCount_300 < 401830) then
                    interrupt_hbm_rd    <= '1';
                else
                    interrupt_hbm_rd    <= '0';
                end if; 
            end if;

            if USE_TEST_CASE = FALSE AND (GEN_DATA_END = TRUE) then
-- HEAP data size rams
-- ADDR    Config      Value(inc Epoch offset)
-- 0       6x6         722         0x2d2
-- 1       8x8         1232        0x4d0
-- 2       12x12       2660        0xa64
-- 3       16x16       4632        0x1218
-- 4       18x18       5822        0x16be
-- 5       20x20       7148        0x1bec
-- 6       22x22       8610        0x21a2
-- 7       24x24       10208       0x27e0
-- 8       26x26       11942       0x2ea6
-- 9       28x28       13812       0x35f4
-- 
-- 
-- 
-- 64	    249	        1058258	    0x1025D2
-- 65	    250	        1066758	    0x104706
-- 66	    251	        1075292	    0x10685C
-- 67	    252	        1083860	    0x1089D4
-- 68	    253	        1092462	    0x10AB6E
-- 69	    254	        1101098	    0x10CD2A
-- 70	    255	        1109768	    0x10EF08
-- 71	    256	        1118472	    0x111108

            if stim_count = 35000 then
                stim_count <= 100;
            elsif clock_300_rst = '0' then
                stim_count  <= stim_count + 1;
            end if;

                -- some stimulus for initial triangle testing.
                if stim_count = 1000 then 
                    -- META DATA FROM CORRELATOR SIM
                    row             <= 13D"0";
                    row_count       <= 9D"6";
                    data_valid      <= '1';
    
                    stim_freq_index <= 17D"0";
                    stim_sub_array  <= 8D"0";
    
                elsif stim_count = 4000 then
                    -- META DATA FROM CORRELATOR SIM
                    row             <= 13D"0";
                    row_count       <= 9D"6";
                    data_valid      <= '1';
    
                    stim_freq_index <= 17D"1";
                    stim_sub_array  <= 8D"0";
                    
                elsif stim_count = 7000 then
                    -- META DATA FROM CORRELATOR SIM
                    row             <= 13D"0";
                    row_count       <= 9D"6";
                    data_valid      <= '1';
    
                    stim_freq_index <= 17D"0";
                    stim_sub_array  <= 8D"0";
                elsif stim_count = 10000 then
                    -- META DATA FROM CORRELATOR SIM
                    row             <= 13D"0";
                    row_count       <= 9D"16";
                    data_valid      <= '1';
    
                    stim_freq_index <= 17D"1";
                    stim_sub_array  <= 8D"3";
                elsif stim_count = 13000 then
                    -- META DATA FROM CORRELATOR SIM
                    row             <= 13D"0";
                    row_count       <= 9D"18";
                    data_valid      <= '1';
    
                    stim_freq_index <= 17D"0";
                    stim_sub_array  <= 8D"4";
                    
                    stim_time_ref(31 downto 0)  <= 32D"4";
                    stim_time_ref(33 downto 32) <= "00";
                    stim_time_ref(34)           <= '1';
                elsif stim_count = 17000 then
                    -- META DATA FROM CORRELATOR SIM
                    row             <= 13D"0";
                    row_count       <= 9D"20";
                    data_valid      <= '1';
    
                    stim_freq_index <= 17D"1";
                    stim_sub_array  <= 8D"5";
                    
                    stim_time_ref(31 downto 0)  <= 32D"3";
                    stim_time_ref(33 downto 32) <= "01";
                    stim_time_ref(34)           <= '1';
                elsif stim_count = 21000 then
                    -- META DATA FROM CORRELATOR SIM
                    row             <= 13D"0";
                    row_count       <= 9D"22";
                    data_valid      <= '1';
    
                    stim_freq_index <= 17D"1";
                    stim_sub_array  <= 8D"6";
                    
                    stim_time_ref(31 downto 0)  <= 32D"3";
                    stim_time_ref(33 downto 32) <= "10";
                    stim_time_ref(34)           <= '1';
    
                elsif stim_count = 25000 then
                    -- META DATA FROM CORRELATOR SIM
                    row             <= 13D"0";
                    row_count       <= 9D"50";
                    data_valid      <= '1';
    
                    stim_freq_index <= 17D"0";
                    stim_sub_array  <= 8D"11";
    
                    stim_time_ref(31 downto 0)  <= 32D"3";
                    stim_time_ref(33 downto 32) <= "00";
                    stim_time_ref(34)           <= '0';
                end if;
            
            end if;
            
            i <= 0;
            meta_data_sel <= '0';
            cmac_ready  <= '1';
        
            HBM_axi_r.resp  <= "00";

        end if;

    end if;
end process;



DUT : entity correlator_lib.correlator_data_reader generic map ( 
        DEBUG_ILA           => FALSE
    )
    Port map ( 
        -- debug_vector 
        --i_debug(0)          => interrupt_hbm_rd,
        -- clock used for all data input and output from this module (300 MHz)
        i_axi_clk           => clock_300,
        i_axi_rst           => clock_300_rst,

        i_local_reset       => NOT packetiser_enable(0),

        -- ARGs Debug
        i_spead_hbm_rd_lite_axi_mosi => c_axi4_lite_mosi_rst,
        o_spead_hbm_rd_lite_axi_miso => open,
        
        -- config of current sub/freq data read
        i_hbm_start_addr    => hbm_start_addr,
                                                                    -- Start address of the meta data is at (i_HBM_start_addr/16 + 256 Mbytes)
        i_sub_array         => stim_sub_array,
        i_freq_index        => stim_freq_index,
        i_data_valid        => data_valid,
        i_time_ref          => stim_time_ref,
                            
        i_row               => row,
        i_row_count         => row_count,
        i_table_select      => stim_table_select,
        i_bad_poly          => '0',
        o_HBM_curr_addr     => HBM_curr_addr,

        -- HBM read interface
        o_HBM_axi_ar        => HBM_axi_ar,
        i_HBM_axi_arready   => HBM_axi_arready,
        i_HBM_axi_r         => HBM_axi_r,
        o_HBM_axi_rready    => HBM_axi_rready,
        
        -- Packed up Correlator Data.
        i_from_spead_pack   => from_spead_pack(0),
        o_to_spead_pack     => to_spead_pack(0)

    );


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

    -- place holder for the RR logic
    to_spead_pack(1).spead_data_rdy     <= '0';

DUT_2 : entity spead_lib.spead_top generic map ( 
        g_CORRELATORS       => 2,
        g_DEBUG_VEC_SIZE    => DEBUG_VEC_SIZE,
        g_DEBUG_ILA         => FALSE
    )
    port map ( 
        -- clock used for all data input and output from this module (300 MHz)
        i_axi_clk           => clock_300,
        i_axi_rst           => clock_300_rst,

        i_local_reset       => '0',
        
        i_table_swap_in_progress  => '0',
        i_packetiser_table_select => '0',

        -- streaming AXI to CMAC
        i_cmac_clk          => clock_322,
        i_cmac_clk_rst      => clock_322_rst,

        o_tx_axis_tdata     => open,
        o_tx_axis_tkeep     => open,
        o_tx_axis_tvalid    => open,
        o_tx_axis_tlast     => open,
        o_tx_axis_tuser     => open,
        i_tx_axis_tready    => cmac_ready,

        -- Packed up Correlator Data.
        o_from_spead_pack   => from_spead_pack,
        i_to_spead_pack     => to_spead_pack,

        o_packetiser_enable => packetiser_enable,

        i_debug             => tb_debug,

        -- ARGs
        i_spead_lite_axi_mosi   => i_spead_lite_axi_mosi,
        o_spead_lite_axi_miso   => o_spead_lite_axi_miso,
        i_spead_full_axi_mosi   => i_spead_full_axi_mosi,
        o_spead_full_axi_miso   => o_spead_full_axi_miso
    );  

end Behavioral;
