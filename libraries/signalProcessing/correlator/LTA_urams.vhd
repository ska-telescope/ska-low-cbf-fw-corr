----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 08/12/2022 03:31:05 PM
-- Module Name: hybrid_uram_bram - Behavioral 
-- Description: 
--   Memory for the long term accumulator.
--   Constructed from 128 ultraRAMs total.
--   Conceptually, there are 32 separate memories, each (4096 deep) x (288 bits wide) (i.e. 4 ultraRAMs)
--    - The 32 memories are split into 2 groups of 16 memories.
--   Each group of 4 urams is either used for 
--     - read-modify-write when accumulating data from the correlator array.
--        - In this mode, the read address selects 
--           - a specific visibility, i.e. one 64-bit output from the 4 memories.
--           - The centroid data.
--        - The read address cascades through the row memories, so that the read data for each row memory comes out 1 clock after the previous row memory.
--        - There is no write address input, but write data is assumed to follow the read data for that address with a 2 clock latency.
--     - Reading out completed visibility data.
--        - In this mode, 256 bits is read out, together with the centroid data, i.e. all 4 ultraRAMs are read out in parallel.
--           - So the 256 bits are 4 visibilites, for all combinations of 2 dual-pol stations.
--        - Centroid data is converted to 2 bytes - one byte each for weight and time centroid.
--        - There is a single read address input to this module, which has :
--           - bits 3:0 = row in the 16x16 correlation matrix.
--           - bits 7:4 = col in the 16x16 correlation matrix.
--           - bits 15:8 = particular correlation cell within a tile.
--
----------------------------------------------------------------------------------

library IEEE, common_lib, xpm;
use IEEE.STD_LOGIC_1164.ALL;
USE common_lib.common_pkg.ALL;
use xpm.vcomponents.all;
use IEEE.NUMERIC_STD.ALL;

entity LTA_urams is
    port( 
        i_clk : in std_logic;
        i_wrBuffer : in std_logic; -- Selects which buffer is used for accumulation
        ----------------------------------------------------------------------------------------
        -- read-modify-write interface for the accumulator functionality: 
        -- read address
        i_cell      : in std_logic_vector(7 downto 0); -- 16x16 = 256 possible different cells being accumulated in the ultraRAM buffer at a time.
        i_readCount : in std_logic_vector(5 downto 0); -- 64 different visibilities per row of the correlation matrix. 
        i_valid     : in std_logic;                    -- i_cell and i_readCount are valid.
        -- Read data
        -- output for each row; first has 6 cycle latency from i_cell, i_readcount, one extra cycle latency for each of the 16 outputs.
        o_AccumVisibilties : out t_slv_64_arr(15 downto 0); 
        o_AccumCentroid : out t_slv_32_arr(15 downto 0);    -- constant for 4 clocks at a time, since the centroid data is the same for all combinations of polarisations.
        -- Write data, must be valid 1 clock after o_AccumVisibilities, o_AccumCentroid.
        i_wrVisibilities : in t_slv_64_arr(15 downto 0); 
        i_wrCentroid : in t_slv_32_arr(15 downto 0);      -- Should be valid for the 4 consecutive clocks where i_wrVisibilities is for the same station pair.
        ----------------------------------------------------------------------------------------
        -- Data output 
        -- 256 bit bus for visibilities, 32 bit bus for centroid data.
        -- readoutAddr : bits 3:0 = cell column, bits 7:4 = cell row, bits 15:8 = cell.
        i_readoutAddr  : in std_logic_vector(15 downto 0);
        i_readoutActive : in std_logic;
        i_readoutBuffer : in std_logic;
        o_readoutVisibilities : out std_logic_vector(255 downto 0);  -- 21 clock latency from i_readoutAddr to the data.
        o_readoutCentroid     : out std_logic_vector(31 downto 0)
    );

        -- prevent optimisation 
    attribute keep_hierarchy : string;
    attribute keep_hierarchy of LTA_urams : entity is "yes";

end LTA_urams;

architecture Behavioral of LTA_urams is
    
    signal buf0_rdAddr : t_slv_12_arr(15 downto 0);
    type t_dout is array(15 downto 0) of t_slv_72_arr(3 downto 0);
    signal buf0_dout : t_dout;
    signal buf1_rdAddr : t_slv_12_arr(15 downto 0);
    signal buf1_dout : t_dout;
    signal accumulator_rdAddr : std_logic_vector(11 downto 0);
    signal accumulator_memSelect : t_slv_2_arr(21 downto 0);
    signal AccumVisibilities0, AccumVisibilities1 : t_slv_64_arr(15 downto 0);
    signal wrBufferDel : std_logic_vector(19 downto 0);
    signal buf0_centroid, buf1_centroid : t_slv_32_arr(15 downto 0);
    signal wrAddr : t_slv_12_arr(15 downto 0);
    signal wrData : t_slv_72_arr(15 downto 0);
    type t_wren is array(15 downto 0) of t_slv_1_Arr(3 downto 0);
    signal buf0_wren : t_wren;
    signal buf1_wrEn : t_wren;
    signal dout0, dout1 : t_slv_288_arr(15 downto 0);
    signal readoutRowDel : t_slv_4_Arr(18 downto 0);
    
    signal accumulator_rdAddr_del1, accumulator_rdAddr_del2, accumulator_rdAddr_del3 : std_logic_vector(11 downto 0);
    signal accumulator_rdAddr_del4, accumulator_rdAddr_del5, accumulator_rdAddr_del6, accumulator_rdAddr_del7 : std_logic_vector(11 downto 0);
    signal readCount_Del1, readCount_Del2, readCount_Del3 : std_logic_vector(1 downto 0);
    signal readCount_Del4, readCount_Del5, readCount_Del6, readCount_Del7 : std_logic_vector(1 downto 0);
    signal valid_del1, valid_del2, valid_del3, valid_del4, valid_del5, valid_del6, valid_del7 : std_logic;
    signal wrBuffer_del1, wrBuffer_del2, wrBuffer_del3 : std_logic;
    signal wrBuffer_del4, wrBuffer_del5, wrBuffer_del6, wrBuffer_del7 : std_logic;
    signal readout_cell : std_logic_vector(7 downto 0);
    signal readout_column, readout_row : std_logic_vector(3 downto 0);
    signal readoutSelBuf0 : std_logic_vector(19 downto 0);
    
begin
    
    accumulator_rdAddr(3 downto 0) <= i_readCount(5 downto 2);
    accumulator_rdAddr(11 downto 4) <= i_cell;
    readout_column <= i_readoutAddr(3 downto 0);
    readout_row <= i_readoutAddr(7 downto 4);
    readout_cell <= i_readoutAddr(15 downto 8);
    
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            
            if i_readoutActive = '1' and i_readoutBuffer = '0' then
                buf0_rdAddr(0) <= readout_cell & readout_column;
                readoutSelBuf0(0) <= '1';
            else
                buf0_rdAddr(0) <= accumulator_rdAddr;
                readoutSelBuf0(0) <= '0';
            end if;
            readoutSelBuf0(19 downto 1) <= readoutSelBuf0(18 downto 0);
            
            
            if i_readoutActive = '1' and i_readoutBuffer = '1' then
                buf1_rdAddr(0) <= readout_cell & readout_column;
            else
                buf1_rdAddr(0) <= accumulator_rdAddr;
            end if;
            
            buf0_rdAddr(15 downto 1) <= buf0_rdAddr(14 downto 0);
            buf1_rdAddr(15 downto 1) <= buf1_rdAddr(14 downto 0);
            
            -- Which of the four memories is currently selected for reading.
            accumulator_memSelect(0) <= i_readCount(1 downto 0); -- so accumulator_memSelect(j) aligns with bufX_rdAddr(j)
            accumulator_memSelect(21 downto 1) <= accumulator_memSelect(20 downto 0);
            
            wrBufferDel(0) <= i_wrBuffer;
            wrBufferDel(19 downto 1) <= wrBufferDel(18 downto 0);
            
            for row in 0 to 15 loop
                AccumVisibilities0(row) <= buf0_dout(row)(to_integer(unsigned(accumulator_memSelect(row+3))))(63 downto 0);  -- 3 cycle read latency on the memory, so add 3 to memSelect.
                AccumVisibilities1(row) <= buf1_dout(row)(to_integer(unsigned(accumulator_memSelect(row+3))))(63 downto 0);
                if wrBufferDel(row+4) = '0' then
                    o_AccumVisibilties(row) <= AccumVisibilities0(row);
                    o_AccumCentroid(row)    <= buf0_centroid(row);
                else
                    o_AccumVisibilties(row) <= AccumVisibilities1(row);
                    o_AccumCentroid(row)    <= buf1_centroid(row);
                end if;
                
                buf0_centroid(row) <= buf0_dout(row)(3)(71 downto 64) & buf0_dout(row)(2)(71 downto 64) & buf0_dout(row)(1)(71 downto 64) & buf0_dout(row)(0)(71 downto 64);
                buf1_centroid(row) <= buf1_dout(row)(3)(71 downto 64) & buf1_dout(row)(2)(71 downto 64) & buf1_dout(row)(1)(71 downto 64) & buf1_dout(row)(0)(71 downto 64);
                
                wrData(row)(63 downto 0) <= i_wrVisibilities(row);
                case accumulator_memSelect(row+6) is
                    when "00" => wrData(row)(71 downto 64) <= i_wrCentroid(row)(7 downto 0);
                    when "01" => wrData(row)(71 downto 64) <= i_wrCentroid(row)(15 downto 8);
                    when "10" => wrData(row)(71 downto 64) <= i_wrCentroid(row)(23 downto 16);
                    when others => wrData(row)(71 downto 64) <= i_wrCentroid(row)(31 downto 24);
                end case;
                
            end loop;

            -- write address is the same for both memories, and lags accumulator_rdAddr by 6 clocks.
            accumulator_rdAddr_Del1 <= accumulator_rdAddr;
            accumulator_rdAddr_Del2 <= accumulator_rdAddr_Del1;
            accumulator_rdAddr_Del3 <= accumulator_rdAddr_Del2;
            accumulator_rdAddr_Del4 <= accumulator_rdAddr_Del3;
            accumulator_rdAddr_Del5 <= accumulator_rdAddr_Del4;
            accumulator_rdAddr_Del6 <= accumulator_rdAddr_Del5;
            accumulator_rdAddr_Del7 <= accumulator_rdAddr_Del6;
            
            readCount_Del1 <= i_readCount(1 downto 0);
            readCount_del2 <= readCount_del1;
            readCount_del3 <= readCount_Del2;
            readCount_del4 <= readCOunt_del3;
            readCount_Del5 <= readCount_del4;
            readCount_del6 <= readCount_del5;
            readCount_del7 <= readCount_del6;
            
            valid_del1 <= i_valid;
            valid_del2 <= valid_del1;
            valid_del3 <= valid_del2;
            valid_del4 <= valid_del3;
            valid_del5 <= valid_del4;
            valid_del6 <= valid_del5;
            valid_del7 <= valid_del6;
            
            wrBuffer_del1 <= i_wrBuffer;
            wrBuffer_del2 <= wrBuffer_del1;
            wrBuffer_del3 <= wrBuffer_del2;
            wrBuffer_del4 <= wrBuffer_del3;
            wrBuffer_del5 <= wrBuffer_del4;
            wrBuffer_del6 <= wrBuffer_del5;
            wrBuffer_del7 <= wrBuffer_del6;
            
            wrAddr(0) <= accumulator_rdAddr_del7;
            wrAddr(15 downto 1) <= wrAddr(14 downto 0);
            
            if valid_del7 = '1' and wrBuffer_del7 = '0' then
                case readCount_del7 is
                    when "00" => buf0_wrEn(0)(0) <= "1"; buf0_wrEn(0)(1) <= "0"; buf0_wrEn(0)(2) <= "0"; buf0_wrEn(0)(3) <= "0";
                    when "01" => buf0_wrEn(0)(0) <= "0"; buf0_wrEn(0)(1) <= "1"; buf0_wrEn(0)(2) <= "0"; buf0_wrEn(0)(3) <= "0";
                    when "10" => buf0_wrEn(0)(0) <= "0"; buf0_wrEn(0)(1) <= "0"; buf0_wrEn(0)(2) <= "1"; buf0_wrEn(0)(3) <= "0";
                    when others => buf0_wrEn(0)(0) <= "0"; buf0_wrEn(0)(1) <= "0"; buf0_wrEn(0)(2) <= "0"; buf0_wrEn(0)(3) <= "1";
                end case;
            else
                buf0_wrEn(0)(0) <= "0"; buf0_wrEn(0)(1) <= "0"; buf0_wrEn(0)(2) <= "0"; buf0_wrEn(0)(3) <= "0";
            end if;
            
            if valid_del7 = '1' and wrBuffer_del7 = '1' then
                case readCount_del7 is
                    when "00" => buf1_wrEn(0)(0) <= "1"; buf1_wrEn(0)(1) <= "0"; buf1_wrEn(0)(2) <= "0"; buf1_wrEn(0)(3) <= "0";
                    when "01" => buf1_wrEn(0)(0) <= "0"; buf1_wrEn(0)(1) <= "1"; buf1_wrEn(0)(2) <= "0"; buf1_wrEn(0)(3) <= "0";
                    when "10" => buf1_wrEn(0)(0) <= "0"; buf1_wrEn(0)(1) <= "0"; buf1_wrEn(0)(2) <= "1"; buf1_wrEn(0)(3) <= "0";
                    when others => buf1_wrEn(0)(0) <= "0"; buf1_wrEn(0)(1) <= "0"; buf1_wrEn(0)(2) <= "0"; buf1_wrEn(0)(3) <= "1";
                end case;
            else
                buf1_wrEn(0)(0) <= "0"; buf1_wrEn(0)(1) <= "0"; buf1_wrEn(0)(2) <= "0"; buf1_wrEn(0)(3) <= "0";
            end if;
            
            buf0_wrEn(15 downto 1) <= buf0_wrEn(14 downto 0);
            buf1_wrEn(15 downto 1) <= buf1_wrEn(14 downto 0);
            
            readoutRowDel(0) <= readout_row;
            readoutRowDel(18 downto 1) <= readoutRowDel(17 downto 0);
            dout0(0) <= buf0_dout(0)(3) & buf0_dout(0)(2) & buf0_dout(0)(1) & buf0_dout(0)(0);
            dout1(0) <= buf1_dout(0)(3) & buf1_dout(0)(2) & buf1_dout(0)(1) & buf1_dout(0)(0);
            
            if readoutSelBuf0(19) = '1' then
                o_readoutVisibilities <= dout0(15)(279 downto 216) & dout0(15)(207 downto 144) & dout0(15)(135 downto 72) & dout0(15)(63 downto 0);
                o_readoutCentroid <= dout0(15)(287 downto 280) & dout0(15)(215 downto 208) & dout0(15)(143 downto 136) & dout0(15)(71 downto 64);
            else
                o_readoutVisibilities <= dout1(15)(279 downto 216) & dout1(15)(207 downto 144) & dout1(15)(135 downto 72) & dout1(15)(63 downto 0);
                o_readoutCentroid <= dout1(15)(287 downto 280) & dout1(15)(215 downto 208) & dout1(15)(143 downto 136) & dout1(15)(71 downto 64);
            end if;
            
        end if;
    end process;
    
    
    row_mux_gen : for row in 1 to 15 generate

        -- 256 bit wide readout
        -- read address is staggered, this uses a chain of 2-1 muxes to select the read data that was required.
        -- i.e. for buf 0: (with 1 clock latency indicated by each "->"
        --
        --  buf0_rdAddr(0)->--------------->--------------->buf0_dout(0)--->dout0(0)----|
        --  |                                                                           |
        --  --------------->buf0_rdAddr(1)->--------------->--------------->buf0_dout(1)->dout0(1)----|
        --                  |                                                                       |
        --                  --------------->buf0_rdAddr(2)->--------------->------------->buf0_dout(2)->dout0(2)
        --                                  |
        --                                  --------------->buf0_rdAddr(3)-> etc.
        --
        process(i_clk)
        begin
            if rising_edge(i_clk) then
            
                if (unsigned(readoutRowDel(row+3)) = row) then  -- +3 since there is a 3 cycle read latency for the memories.
                    dout0(row) <= buf0_dout(row)(3) & buf0_dout(row)(2) & buf0_dout(row)(1) & buf0_dout(row)(0);
                else
                    dout0(row) <= dout0(row-1);
                end if;
                
                if (unsigned(readoutRowDel(row+3)) = row) then
                    dout1(row) <= buf1_dout(row)(3) & buf1_dout(row)(2) & buf1_dout(row)(1) & buf1_dout(row)(0);
                else
                    dout1(row) <= dout1(row-1);
                end if;
          
            end if;
        end process;
    
    end generate;
    
    
    uram_row_gen : for row in 0 to 15 generate
    
        -- 16 blocks of memory, one for each row of the correlation being calculated in the CMAC array.
        -- Each block is 4 individually instantiated ultraRAMs.
        uram_mem_gen : for mem in 0 to 3 generate
            -- Groups of four memories are in parallel so that all correlations for a station pair (i.e. pol 0 x pol 0, pol 0 x pol 1 etc) are read at the same time
            
            -- Data :
            --   bits 63:0 from each memory contain a visibility for a particular pair of polarisations.
            --   bits 71:64 from all 4 memories are concatenated together to get 32 bits of centroid data. 
            
            -- Address : 
            --   Within a single memory, the address is :
            --    bits (3:0) = 16 different correlations, all the columns for a single row of the 16x16 station correlation matrix.
            --    bits (11:4) = 256 different correlation cells within a tile.
            
            -- 2 memories, "buf0" and "buf1" for double buffering, 
            -- One for read out to HBM while the other is being used for accumulating the next tile. 
            xpm_memory_sdpram0_inst : xpm_memory_sdpram
            generic map (
                ADDR_WIDTH_A => 12,              -- DECIMAL
                ADDR_WIDTH_B => 12,              -- DECIMAL
                AUTO_SLEEP_TIME => 0,            -- DECIMAL
                BYTE_WRITE_WIDTH_A => 72,        -- DECIMAL
                CASCADE_HEIGHT => 0,             -- DECIMAL
                CLOCKING_MODE => "common_clock", -- String
                ECC_MODE => "no_ecc",            -- String
                MEMORY_INIT_FILE => "none",      -- String
                MEMORY_INIT_PARAM => "0",        -- String
                MEMORY_OPTIMIZATION => "true",   -- String
                MEMORY_PRIMITIVE => "ultra",     -- String
                MEMORY_SIZE => 294912,           -- DECIMAL  -- Total bits in the memory; 4096 * 72 = 294912
                MESSAGE_CONTROL => 0,            -- DECIMAL
                READ_DATA_WIDTH_B => 72,         -- DECIMAL
                READ_LATENCY_B => 3,             -- DECIMAL
                READ_RESET_VALUE_B => "0",       -- String
                RST_MODE_A => "SYNC",            -- String
                RST_MODE_B => "SYNC",            -- String
                SIM_ASSERT_CHK => 0,             -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
                USE_EMBEDDED_CONSTRAINT => 0,    -- DECIMAL
                USE_MEM_INIT => 0,               -- DECIMAL
                WAKEUP_TIME => "disable_sleep",  -- String
                WRITE_DATA_WIDTH_A => 72,        -- DECIMAL
                WRITE_MODE_B => "read_first"     -- String
            ) port map (
                dbiterrb => open,       -- 1-bit output: Status signal to indicate double bit error occurrence on the data output of port A.
                doutb => buf0_dout(row)(mem),  -- READ_DATA_WIDTH_B-bit output: Data output for port B read operations.
                sbiterrb => open,       -- 1-bit output: Status signal to indicate single bit error occurrence on the data output of port B.
                addra => WrAddr(row), -- ADDR_WIDTH_A-bit input: Address for port A write and read operations.
                addrb => buf0_RdAddr(row), -- ADDR_WIDTH_B-bit input: Address for port B write and read operations.
                clka => i_clk,          -- 1-bit input: Clock signal for port A. Also clocks port B when parameter CLOCKING_MODE is "common_clock".
                clkb => i_clk,          -- Unused when parameter CLOCKING_MODE is "common_clock".
                dina => wrData(row),    -- WRITE_DATA_WIDTH_A-bit input: Data input for port A write operations.
                ena => '1',             -- 1-bit input: Memory enable signal for port A.
                enb => '1',             -- 1-bit input: Memory enable signal for port B.
                injectdbiterra => '0',  -- 1-bit input: Controls double bit error injection on input data
                injectsbiterra => '0',  -- 1-bit input: Controls single bit error injection on input data
                regceb => '1',          -- 1-bit input: Clock Enable for the last register stage on the output data path.
                rstb => '0',            -- 1-bit input: Reset signal for the final port B output register
                sleep => '0',           -- 1-bit input: sleep signal to enable the dynamic power saving feature.
                wea => buf0_wrEn(row)(mem)     -- WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-bit input: Write enable vector for port A input data port dina. 
            );
            
            xpm_memory_sdpram1_inst : xpm_memory_sdpram
            generic map (
                ADDR_WIDTH_A => 12,              -- DECIMAL
                ADDR_WIDTH_B => 12,              -- DECIMAL
                AUTO_SLEEP_TIME => 0,            -- DECIMAL
                BYTE_WRITE_WIDTH_A => 72,        -- DECIMAL
                CASCADE_HEIGHT => 0,             -- DECIMAL
                CLOCKING_MODE => "common_clock", -- String
                ECC_MODE => "no_ecc",            -- String
                MEMORY_INIT_FILE => "none",      -- String
                MEMORY_INIT_PARAM => "0",        -- String
                MEMORY_OPTIMIZATION => "true",   -- String
                MEMORY_PRIMITIVE => "ultra",     -- String
                MEMORY_SIZE => 294912,           -- DECIMAL  -- Total bits in the memory; 16384 * 72 = 294912
                MESSAGE_CONTROL => 0,            -- DECIMAL
                READ_DATA_WIDTH_B => 72,         -- DECIMAL
                READ_LATENCY_B => 3,             -- DECIMAL  (NOTE : cascaded urams need latency > 3 to use registers in the cascade path).
                READ_RESET_VALUE_B => "0",       -- String
                RST_MODE_A => "SYNC",            -- String
                RST_MODE_B => "SYNC",            -- String
                SIM_ASSERT_CHK => 0,             -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
                USE_EMBEDDED_CONSTRAINT => 0,    -- DECIMAL
                USE_MEM_INIT => 0,               -- DECIMAL
                WAKEUP_TIME => "disable_sleep",  -- String
                WRITE_DATA_WIDTH_A => 72,        -- DECIMAL
                WRITE_MODE_B => "read_first"     -- String
            ) port map (
                dbiterrb => open,       -- 1-bit output: Status signal to indicate double bit error occurrence on the data output of port A.
                doutb => buf1_dout(row)(mem),  -- READ_DATA_WIDTH_B-bit output: Data output for port B read operations.
                sbiterrb => open,       -- 1-bit output: Status signal to indicate single bit error occurrence on the data output of port B.
                addra => WrAddr(row), -- ADDR_WIDTH_A-bit input: Address for port A write and read operations.
                addrb => buf1_RdAddr(row), -- ADDR_WIDTH_B-bit input: Address for port B write and read operations.
                clka => i_clk,          -- 1-bit input: Clock signal for port A. Also clocks port B when parameter CLOCKING_MODE is "common_clock".
                clkb => i_clk,          -- Unused when parameter CLOCKING_MODE is "common_clock".
                dina => wrData(row),    -- WRITE_DATA_WIDTH_A-bit input: Data input for port A write operations.
                ena => '1',             -- 1-bit input: Memory enable signal for port A.
                enb => '1',             -- 1-bit input: Memory enable signal for port B.
                injectdbiterra => '0',  -- 1-bit input: Controls double bit error injection on input data
                injectsbiterra => '0',  -- 1-bit input: Controls single bit error injection on input data
                regceb => '1',          -- 1-bit input: Clock Enable for the last register stage on the output data path.
                rstb => '0',            -- 1-bit input: Reset signal for the final port B output register
                sleep => '0',           -- 1-bit input: sleep signal to enable the dynamic power saving feature.
                wea => buf1_wrEn(row)(mem)  -- WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-bit input: Write enable vector for port A input data port dina. 
            );
        
        end generate;
                
    end generate;

end Behavioral;
