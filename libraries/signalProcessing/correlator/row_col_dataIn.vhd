----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 08/11/2022 12:19:06 PM
-- Module Name: row_col_dataIn - Behavioral
-- Description: 
--  Data input pipeline for the row and column memories for the correlator.
--  Input signals come from the corner turn, output signals go to the row and col memories.
-- 
----------------------------------------------------------------------------------

library IEEE, common_lib;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
USE common_lib.common_pkg.ALL;

entity row_col_dataIn is
    port(
        i_axi_clk : in std_logic;
        --------------------------------------------------------------------------
        -- Data input from the corner turn
        --
        i_cor_data  : in std_logic_vector(255 downto 0); 
        -- meta data
        i_cor_time     : in std_logic_vector(7 downto 0); -- time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
        -- Counts the virtual channels in i_cor_data, always in steps of 4,where the value is the first of the 4 virtual channels in i_cor_data
        -- If i_cor_tileType = '0', then up to 256 channels are delivered, with the same channels going to both row and column memories.
        --                          In this case, i_cor_VC_count will run from 0 to 256 in steps of 4.
        -- If i_cor_tileType = '1', then up to 512 channels are delivered, with different channels going to the row and column memories.
        --                          counts 0 to 255 go to the column memories, while counts 256-511 go to the row memories. 
        i_cor_station : in std_logic_vector(8 downto 0); 
        -- Options for tileType : 
        --   '0' = Triangle. In this case, all the input data goes to both the row and column memories, and a triangle from the correlation matrix is computed.
        --            For correlation cells on the diagonal, only non-duplicate entries are sent out.
        --   '1' = Rectangle. In this case, the first 256 virtual channels on i_cor0_data go to the column memories, while the next 128 virtual channels go to the row memories.
        --            All correlation products for the rectangle are then computed.
        i_cor_tileType : in std_logic;
        i_cor_valid : in std_logic;  -- i_cor0_data, i_cor0_time, i_cor0_VC, i_cor0_FC and i_cor0_tileType are valid when i_cor0_valid = '1'
        i_wrBuffer : in std_logic; -- which half of the buffers to write to.
        ----------------------------------------------------------------------------
        -- Control signals to write data to the row and column memories.
        o_colWrData : out t_slv_64_arr(15 downto 0);
        o_colWrAddr : out t_slv_10_arr(15 downto 0);
        o_colWrEn   : out t_slv_1_arr(15 downto 0);
        --
        o_rowWrData : out t_slv_64_arr(15 downto 0);
        o_rowWrAddr : out t_slv_10_arr(15 downto 0);
        o_rowWrEn   : out t_slv_1_arr(15 downto 0)
        
    );
end row_col_dataIn;

architecture Behavioral of row_col_dataIn is

    attribute dont_touch : string;

    signal cor_data_del1 : std_logic_vector(255 downto 0);
    --signal cor_data_del1_neg : std_logic_vector(255 downto 0);
    signal cor_time_del1 : std_logic_vector(7 downto 0);
    signal cor_station_del1, cor_station_del2, cor_station_del3, cor_station_del4 : std_logic_vector(8 downto 0);
    signal cor_valid_del1, cor_valid_del2, cor_valid_del3, cor_valid_del4 : std_logic;
    
    signal colwrDataDel : t_slv_64_arr(15 downto 0);
    signal rowWrDataDel : t_slv_64_arr(15 downto 0);
    attribute dont_touch of colWrDataDel : signal is "true";
    attribute dont_touch of rowWrDataDel : signal is "true";
    
    signal col_wren0_3, col_wren4_7, col_wren8_11, col_wren12_15 : std_logic;
    signal row_wren0_3, row_wren4_7, row_wren8_11, row_wren12_15 : std_logic;
    
    signal colWrAddrDel0, colWrAddrDel1, colWrAddrDel2, colWrAddrDel3 : std_logic_vector(9 downto 0);
    signal rowWrAddrDel0, rowWrAddrDel1, rowWrAddrDel2, rowWrAddrDel3 : std_logic_vector(9 downto 0);
    attribute dont_touch of colWrAddrDel0 : signal is "true";
    attribute dont_touch of colWrAddrDel1 : signal is "true";
    attribute dont_touch of colWrAddrDel2 : signal is "true";
    attribute dont_touch of colWrAddrDel3 : signal is "true";
    
    attribute dont_touch of rowWrAddrDel0 : signal is "true";
    attribute dont_touch of rowWrAddrDel1 : signal is "true";
    attribute dont_touch of rowWrAddrDel2 : signal is "true";
    attribute dont_touch of rowWrAddrDel3 : signal is "true";
    
    signal wrBufferDel1 : std_logic;
    
    signal cor_tileType_del1, cor_tileType_del2, cor_tileType_del3, cor_tileType_del4 : std_logic;
    
begin

    process(i_axi_clk)
    begin
        if rising_edge(i_axi_clk) then
            
            -- 
            -- i_cor_data  : in std_logic_vector(255 downto 0); 
            --  meta data
            -- i_cor_time : in std_logic_vector(7 downto 0); -- time samples runs from 0 to 190, in steps of 2. 192 time samples per 849ms integration interval; 2 time samples in each 256 bit data word.
            -- i_cor_VC   : in std_logic_vector(11 downto 0); -- first of the 4 virtual channels in o_cor0_data
            
            cor_data_del1 <= i_cor_data;
            cor_time_del1 <= i_cor_time;
            cor_station_del1 <= i_cor_station;
            cor_valid_del1 <= i_cor_valid;
            cor_tileType_del1 <= i_cor_tileType;
            wrBufferDel1 <= i_wrBuffer;
            
            cor_station_del2 <= cor_station_del1;
            cor_valid_del2 <= cor_valid_del1;
            cor_tileType_del2 <= cor_tileType_del1;
            
            cor_station_del3 <= cor_station_del2;
            cor_valid_del3 <= cor_valid_del2;
            cor_tileType_del3 <= cor_tileType_del2;
            
            cor_station_del4 <= cor_station_del3;
            cor_valid_del4 <= cor_valid_del3;
            cor_tileType_del4 <= cor_tileType_del3;
            
            -- Get the negative of each byte for use in the complex conjugate.
            -- Note that rfi is signalled via most negative value (i.e. 0x80), which maps to the same value here. 
            --for b in 0 to 31 loop
            --    cor_data_del1_neg(b*8 + 7 downto b*8) <= std_logic_vector(unsigned(not i_cor_data(b*8 + 7 downto b*8)) + 1); 
            --end loop;
            
            -- Each 256 bit word : two time samples, 4 consecutive virtual channels
            -- (31:0) = time 0, virtual channel 0; (63:32) = time 0, virtual channel 1; (95:64) = time 0, virtual channel 2; (127:96) = time 0, virtual channel 3;
            -- (159:128) = time 1, virtual channel 0; (191:160) = time 1, virtual channel 1; (223:192) = time 1, virtual channel 2; (255:224) = time 1, virtual channel 3;
            -- Note 4 consecutive channels always go to 4 consecutive memories. 
            -- So break the 256 bit bus into 4 x 64 bit busses. Each 64 bit bus has 4 possible destinations.
            colWrDataDel(0)(31 downto 0)  <= cor_data_del1(31 downto 24)   & cor_data_del1(23 downto 16)   & cor_data_del1(15 downto 8)    & cor_data_del1(7 downto 0); -- first time samples for first virtual channel
            colWrDataDel(0)(63 downto 32) <= cor_data_del1(159 downto 152) & cor_data_del1(151 downto 144) & cor_data_del1(143 downto 136) & cor_data_del1(135 downto 128);
            colWrDataDel(1)(31 downto 0)  <= cor_data_del1(63 downto 56)   & cor_data_del1(55 downto 48)   & cor_data_del1(47 downto 40)   & cor_data_del1(39 downto 32);
            colWrDataDel(1)(63 downto 32) <= cor_data_del1(191 downto 184) & cor_data_del1(183 downto 176) & cor_data_del1(175 downto 168) & cor_data_del1(167 downto 160);
            colWrDataDel(2)(31 downto 0)  <= cor_data_del1(95 downto 88)   & cor_data_del1(87 downto 80)   & cor_data_del1(79 downto 72)   & cor_data_del1(71 downto 64);
            colWrDataDel(2)(63 downto 32) <= cor_data_del1(223 downto 216) & cor_data_del1(215 downto 208) & cor_data_del1(207 downto 200) & cor_data_del1(199 downto 192);
            colWrDataDel(3)(31 downto 0)  <= cor_data_del1(127 downto 120) & cor_data_del1(119 downto 112) & cor_data_del1(111 downto 104) & cor_data_del1(103 downto 96);
            colWrDataDel(3)(63 downto 32) <= cor_Data_del1(255 downto 248) & cor_Data_del1(247 downto 240) & cor_Data_del1(239 downto 232) & cor_Data_del1(231 downto 224);
             
            colWrDataDel(4) <= colWrDataDel(0);
            colWrDataDel(5) <= colWrDataDel(1);
            colWrDataDel(6) <= colWrDataDel(2);
            colWrDataDel(7) <= colWrDataDel(3);
            
            colWrDataDel(8) <= colWrDataDel(4);
            colWrDataDel(9) <= colWrDataDel(5);
            colWrDataDel(10) <= colWrDataDel(6);
            colWrDataDel(11) <= colWrDataDel(7);
            
            colWrDataDel(12) <= colWrDataDel(8);
            colWrDataDel(13) <= colWrDataDel(9);
            colWrDataDel(14) <= colWrDataDel(10);
            colWrDataDel(15) <= colWrDataDel(11);
            
            colWrAddrDel0(4 downto 0) <= cor_time_del1(5 downto 1);
            colWrAddrDel0(8 downto 5) <= cor_station_del1(7 downto 4);
            colWrAddrDel0(9) <= wrBufferDel1;
            
            colWrAddrDel1 <= colWrAddrDel0;
            colWrAddrDel2 <= colWrAddrDel1;
            colWrAddrDel3 <= colWrAddrDel2;
            if cor_station_del1(3 downto 2) = "00" and cor_valid_del1 = '1' and cor_station_del1(8) = '0' then  -- VC(1:0) should always be 0, since 4 virtual channels are delivered per data word.
                col_wren0_3 <= '1';
            else
                col_wren0_3 <= '0';
            end if;
            
            if cor_station_del2(3 downto 2) = "01" and cor_valid_del2 = '1' and cor_station_del2(8) = '0' then  -- del2 to match the pipeline delay on the data.
                col_wren4_7 <= '1';
            else
                col_wren4_7 <= '0';
            end if;
            
            if cor_station_del3(3 downto 2) = "10" and cor_valid_del3 = '1' and cor_station_del3(8) = '0' then
                col_wren8_11 <= '1';
            else
                col_wren8_11 <= '0';
            end if;
            
            if cor_station_del4(3 downto 2) = "11" and cor_valid_del4 = '1' and cor_station_del4(8) = '0' then
                col_wren12_15 <= '1';
            else
                col_wren12_15 <= '0';
            end if;
            
            -- Separate pipeline for row write enable, data, and address.
            rowWrDataDel(0)(63 downto 0) <= cor_data_del1(159 downto 128) & cor_data_del1(31 downto 0);
            rowWrDataDel(1)(63 downto 0) <= cor_data_del1(191 downto 160) & cor_data_del1(63 downto 32);
            rowWrDataDel(2)(63 downto 0) <= cor_data_del1(223 downto 192) & cor_data_del1(95 downto 64);
            rowWrDataDel(3)(63 downto 0) <= cor_data_del1(255 downto 224) & cor_data_del1(127 downto 96);
            rowWrDataDel(4) <= rowWrDataDel(0);
            rowWrDataDel(5) <= rowWrDataDel(1);
            rowWrDataDel(6) <= rowWrDataDel(2);
            rowWrDataDel(7) <= rowWrDataDel(3);
            rowWrDataDel(8) <= rowWrDataDel(4);
            rowWrDataDel(9) <= rowWrDataDel(5);
            rowWrDataDel(10) <= rowWrDataDel(6);
            rowWrDataDel(11) <= rowWrDataDel(7);
            rowWrDataDel(12) <= rowWrDataDel(8);
            rowWrDataDel(13) <= rowWrDataDel(9);
            rowWrDataDel(14) <= rowWrDataDel(10);
            rowWrDataDel(15) <= rowWrDataDel(11);
            
            rowWrAddrDel0(4 downto 0) <= cor_time_del1(5 downto 1);
            rowWrAddrDel0(8 downto 5) <= cor_station_del1(7 downto 4);
            rowWrAddrDel0(9) <= wrBufferDel1;
            rowWrAddrDel1 <= rowWrAddrDel0;
            rowWrAddrDel2 <= rowWrAddrDel1;
            rowWrAddrDel3 <= rowWrAddrDel2;
            
            if cor_station_del1(3 downto 2) = "00" and cor_valid_del1 = '1' and (cor_station_del1(8) = '1' or cor_tileType_del1 = '0') then
                row_wren0_3 <= '1';
            else
                row_wrEn0_3 <= '0';
            end if;
            if cor_station_del2(3 downto 2) = "01" and cor_valid_del2 = '1' and (cor_station_del2(8) = '1' or cor_tileType_del2 = '0') then
                row_wren4_7 <= '1';
            else
                row_wrEn4_7 <= '0';
            end if;           
            if cor_station_del3(3 downto 2) = "10" and cor_valid_del3 = '1' and (cor_station_del3(8) = '1' or cor_tileType_del3 = '0') then
                row_wren8_11 <= '1';
            else
                row_wrEn8_11 <= '0';
            end if;
            if cor_station_del4(3 downto 2) = "11" and cor_valid_del4 = '1' and (cor_station_del4(8) = '1' or cor_tileType_del4 = '0') then
                row_wren12_15 <= '1';
            else
                row_wrEn12_15 <= '0';
            end if;
            
        end if;
    end process;
    
    o_colWrData <= colWrDataDel;
    o_colWrEn(0)(0) <= col_wren0_3;
    o_colWrEn(1)(0) <= col_wren0_3;
    o_colWrEn(2)(0) <= col_wren0_3;
    o_colWrEn(3)(0) <= col_wren0_3;
    o_colWrEn(4)(0) <= col_wren4_7;
    o_colWrEn(5)(0) <= col_wren4_7;
    o_colWrEn(6)(0) <= col_wren4_7;
    o_colWrEn(7)(0) <= col_wren4_7;
    o_colWrEn(8)(0) <= col_wren8_11;
    o_colWrEn(9)(0) <= col_wren8_11;
    o_colWrEn(10)(0) <= col_wren8_11;
    o_colWrEn(11)(0) <= col_wren8_11;
    o_colWrEn(12)(0) <= col_wren12_15;
    o_colWrEn(13)(0) <= col_wren12_15;
    o_colWrEn(14)(0) <= col_wren12_15;
    o_colWrEn(15)(0) <= col_wren12_15;
    
    o_colWrAddr(0) <= colWrAddrDel0;
    o_colWrAddr(1) <= colWrAddrDel0;
    o_colWrAddr(2) <= colWrAddrDel0;
    o_colWrAddr(3) <= colWrAddrDel0;
    o_colWrAddr(4) <= colWrAddrDel1;
    o_colWrAddr(5) <= colWrAddrDel1;
    o_colWrAddr(6) <= colWrAddrDel1;
    o_colWrAddr(7) <= colWrAddrDel1;
    o_colWrAddr(8) <= colWrAddrDel2;
    o_colWrAddr(9)  <= colWrAddrDel2;
    o_colWrAddr(10) <= colWrAddrDel2;
    o_colWrAddr(11) <= colWrAddrDel2;
    o_colWrAddr(12) <= colWrAddrDel3;
    o_colWrAddr(13) <= colWrAddrDel3;
    o_colWrAddr(14) <= colWrAddrDel3;
    o_colWrAddr(15) <= colWrAddrDel3;
    
    o_rowWrData <= rowWrDataDel;
    o_rowWrEn(0)(0) <= row_wren0_3;
    o_rowWrEn(1)(0) <= row_wren0_3;
    o_rowWrEn(2)(0) <= row_wren0_3;
    o_rowWrEn(3)(0) <= row_wren0_3;
    o_rowWrEn(4)(0) <= row_wren4_7;
    o_rowWrEn(5)(0) <= row_wren4_7;
    o_rowWrEn(6)(0) <= row_wren4_7;
    o_rowWrEn(7)(0) <= row_wren4_7;
    o_rowWrEn(8)(0) <= row_wren8_11;
    o_rowWrEn(9)(0) <= row_wren8_11;
    o_rowWrEn(10)(0) <= row_wren8_11;
    o_rowWrEn(11)(0) <= row_wren8_11;
    o_rowWrEn(12)(0) <= row_wren12_15;
    o_rowWrEn(13)(0) <= row_wren12_15;
    o_rowWrEn(14)(0) <= row_wren12_15;
    o_rowWrEn(15)(0) <= row_wren12_15;    
    
    o_rowWrAddr(0) <= rowWrAddrDel0;
    o_rowWrAddr(1) <= rowWrAddrDel0;
    o_rowWrAddr(2) <= rowWrAddrDel0;
    o_rowWrAddr(3) <= rowWrAddrDel0;
    o_rowWrAddr(4) <= rowWrAddrDel1;
    o_rowWrAddr(5) <= rowWrAddrDel1;
    o_rowWrAddr(6) <= rowWrAddrDel1;
    o_rowWrAddr(7) <= rowWrAddrDel1;
    o_rowWrAddr(8) <= rowWrAddrDel2;
    o_rowWrAddr(9) <= rowWrAddrDel2;
    o_rowWrAddr(10) <= rowWrAddrDel2;
    o_rowWrAddr(11) <= rowWrAddrDel2;
    o_rowWrAddr(12) <= rowWrAddrDel3;
    o_rowWrAddr(13) <= rowWrAddrDel3;
    o_rowWrAddr(14) <= rowWrAddrDel3;
    o_rowWrAddr(15) <= rowWrAddrDel3;
    
end Behavioral;


