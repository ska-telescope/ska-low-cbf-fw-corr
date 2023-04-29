----------------------------------------------------------------------------------
-- Company: CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date: 08/09/2022 01:12:25 PM
-- Module Name: cmac_quad_wrapper - Behavioral
-- Description: 
--   4 complex multiply-accumulates, along with time centroid calculation, for a correlator cell.
-- 
----------------------------------------------------------------------------------

library IEEE, correlator_lib, common_lib;
use IEEE.STD_LOGIC_1164.ALL;
USE common_lib.common_pkg.ALL;
use IEEE.NUMERIC_STD.ALL;
use correlator_lib.cmac_pkg.ALL;

entity cmac_quad_wrapper is
    port(
        i_clk : in std_logic;
        -- Source data
        i_col_data : in std_logic_vector(31 downto 0); -- (7:0) = pol 0 real, (15:8) = pol 0 imaginary, (23:16) = pol 1 real, (31:24) = pol 1 imaginary.
        i_col_meta : in t_cmac_input_bus;              -- .valid, .first, .last, .rfi, .sample_cnt
        i_row_data : in std_logic_vector(31 downto 0); -- (7:0) = pol 0 real, (15:8) = pol 0 imaginary, (23:16) = pol 1 real, (31:24) = pol 1 imaginary.
        i_row_meta : in t_cmac_input_bus;              -- .valid, .first, .last, .rfi, .sample_cnt
        -- pipelined source data
        o_col_data : out std_logic_vector(31 downto 0); -- (7:0) = pol 0 real, (15:8) = pol 0 imaginary, (23:16) = pol 1 real, (31:24) = pol 1 imaginary.
        o_col_meta : out t_cmac_input_bus;              -- .valid, .first, .last, .rfi, .sample_cnt
        o_row_data : out std_logic_vector(31 downto 0); -- (7:0) = pol 0 real, (15:8) = pol 0 imaginary, (23:16) = pol 1 real, (31:24) = pol 1 imaginary.
        o_row_meta : out t_cmac_input_bus;              -- .valid, .first, .last, .rfi, .sample_cnt
        -- Output data
        -- Output is a burst of 4 clocks, with (1) Col pol0 - row pol0, (2) col pol0 - row pol1, (3) col pol1 - row pol 0, (4) col pol 1 - row pol 1
        -- Centroid data is valid in the first output clock.
        i_shiftOut : in std_logic;   -- indicates that data should be shifted out on the o_visData and o_centroid busses
        o_shiftOut : out std_logic;  -- indicates the next quad in the pipeline should send its data.
        
        i_visValid : in std_logic;
        i_visData : in std_logic_vector(47 downto 0);  -- input from upstream quad
        i_centroid : in std_logic_vector(23 downto 0); --
        
        o_visValid : out std_logic;  -- o_visData is valid.
        o_visData : out std_logic_vector(47 downto 0); -- Visibility data, 23:0 = real, 47:24 = imaginary.
        o_centroid : out std_logic_vector(23 downto 0) -- (7:0) = samples accumulated, (23:8) = centroid sum.
    );
    
        -- prevent optimisation 
    attribute keep_hierarchy : string;
    attribute keep_hierarchy of cmac_quad_wrapper : entity is "yes";
    
    
end cmac_quad_wrapper;

architecture Behavioral of cmac_quad_wrapper is

    signal XX_vld, XY_vld, YX_vld, YY_vld : std_logic;
    signal XX_data, XY_data, YX_data, YY_data, XX_hold, XY_hold, YX_hold, YY_hold : std_logic_vector(47 downto 0);
    signal is_rfi, rfi_first, rfi_last, rfi_vld : std_logic_vector(3 downto 0);
    signal rfi_count : t_slv_8_arr(6 downto 0);
    signal rfi_dv_count, rfi_dv_hold : std_logic_vector(7 downto 0);
    signal rfi_tci_accum, rfi_tci_hold : std_logic_vector(15 downto 0);
    signal shiftActive : std_logic;
    signal shiftCount : std_logic_vector(1 downto 0);
    
begin
    
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            -- Pipeline for the input data
            o_col_data <= i_col_data;
            o_col_meta <= i_col_meta;
            o_row_data <= i_row_data;
            o_row_meta <= i_row_meta;
            
            -- Readout pipeline/shift register
            if XX_vld = '1' then
                XX_hold <= XX_data;
                XY_hold <= XY_data;
                YX_hold <= YX_data;
                YY_hold <= YY_data;
                rfi_dv_hold <= rfi_dv_count;
                rfi_tci_hold <= rfi_tci_accum;
            end if;
            
            if i_shiftOut = '1' then
                shiftCount <= "00";
                shiftActive <= '1';
            elsif shiftActive = '1' then
                shiftCount <= std_logic_vector(unsigned(shiftCount) + 1);
                if shiftCount = "11" then
                    shiftActive <= '0';
                end if; 
            end if;
            
            if shiftActive = '1' then
                case shiftCount is
                    when "00" => o_visData <= XX_hold;
                    when "01" => o_visData <= XY_hold;
                    when "10" => o_visData <= YX_hold;
                    when others => o_visData <= YY_hold;
                end case;
                o_centroid(7 downto 0) <= rfi_dv_hold;
                o_centroid(23 downto 8) <= rfi_tci_hold;
                o_visValid <= '1';
            else
                o_visValid <= i_visValid;
                o_visData <= i_visData;
                o_centroid <= i_centroid;
            end if;
            
            if shiftActive = '1' and shiftCount = "11" then
                o_shiftOut <= '1';
            else
                o_shiftOut <= '0';
            end if;
            
        end if;
    end process;

    --  .data (27 bit), .vld (1 bit), .first (1 bit), .last (1 bit), .rfi (1 bit), .sample_cnt (16 bit), .auto_corr (1 bit).

    -- RFI calculation
    -- Counts the number of valid (non-rfi) samples, and sums the times for those samples.
    process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_row_meta.rfi = '1' or i_col_meta.rfi = '1' then
                is_rfi(0) <= '1';
            else
                is_rfi(0) <= '0';
            end if;
            rfi_first(0) <= i_col_meta.first;
            rfi_last(0) <= i_col_meta.last;
            rfi_count(0) <= std_logic_vector(i_col_meta.sample_cnt(7 downto 0));
            rfi_vld(0) <= i_col_meta.vld;
            
            -- Delay to match cmac
            is_rfi(3 downto 1) <= is_rfi(2 downto 0);
            rfi_first(3 downto 1) <= rfi_first(2 downto 0);
            rfi_last(3 downto 1) <= rfi_last(2 downto 0);
            rfi_count(3 downto 1) <= rfi_count(2 downto 0);
            rfi_vld(3 downto 1) <= rfi_vld(2 downto 0);
            
            if rfi_vld(3) = '1' then
                if is_rfi(3) = '1' then
                    if rfi_first(3) = '1' then
                        rfi_tci_accum <= (others => '0');
                        rfi_dv_count <= (others => '0');
                    end if;
                else -- not rfi; increment data valid count and time centroid 
                    if rfi_first(3) = '1' then
                        rfi_tci_accum <= "00000000" & rfi_count(3);
                        rfi_dv_count <= "00000001";
                    else
                        rfi_tci_accum <= std_logic_vector(unsigned(rfi_tci_accum) + resize(unsigned(rfi_count(3)),16));
                        rfi_dv_count <= std_logic_vector(unsigned(rfi_dv_count) + 1);
                    end if;
                end if;
            end if;
            
        end if;
    end process;


    cmac_XX : entity correlator_lib.cmac
    generic map (
        g_ACCUM_WIDTH     => 24, -- natural := 24;
        g_SAMPLE_WIDTH    => 8,  -- natural range 1 to 9 := 8;  -- >6 uses two 18b multiplers
        g_CMAC_LATENCY    => 5   -- natural range work.cmac_pkg.c_CMAC_LATENCY to work.cmac_pkg.c_CMAC_LATENCY  -- i.e. 5
    ) port map (
        i_clk       => i_clk, -- in std_logic;
        i_clk_reset => '0',   -- in std_logic;  -- all this does is disable simulation error messages.

        i_row       => i_row_meta,   -- in t_cmac_input_bus;  only uses .vld, .first and .last
        i_row_real  => i_row_data(7 downto 0),  -- in std_logic_vector(7 downto 0);
        i_row_imag  => i_row_data(15 downto 8), -- in std_logic_vector(7 downto 0);
        
        i_col       => i_col_meta, --  in t_cmac_input_bus;
        i_col_real  => i_col_data(7 downto 0),  --  in std_logic_vector(7 downto 0);
        i_col_imag  => i_col_data(15 downto 8), --  in std_logic_vector(7 downto 0);

        -- Readout interface. Readout pulses high 5 clocks after i_<col|row>.last
        o_readout_vld  => XX_vld, -- out std_logic;
        o_readout_data => XX_data -- out std_logic_vector((g_ACCUM_WIDTH*2 - 1) downto 0)  -- real part in low g_ACCUM_WIDTH bits, imaginary part in high g_ACCUM_BITS 
    );

    cmac_XY : entity correlator_lib.cmac
    generic map (
        g_ACCUM_WIDTH     => 24, -- natural := 24;
        g_SAMPLE_WIDTH    => 8,  -- natural range 1 to 9 := 8;  -- >6 uses two 18b multiplers
        g_CMAC_LATENCY    => 5   -- natural range work.cmac_pkg.c_CMAC_LATENCY to work.cmac_pkg.c_CMAC_LATENCY  -- i.e. 5
    ) port map (
        i_clk       => i_clk, -- in std_logic;
        i_clk_reset => '0',   -- in std_logic;  -- all this does is disable simulation error messages.
        i_row       => i_row_meta,   -- in t_cmac_input_bus;  only uses .vld, .first and .last
        i_row_real  => i_row_data(7 downto 0),  -- in (7:0);
        i_row_imag  => i_row_data(15 downto 8), -- in (7:0);
        i_col       => i_col_meta, --  in t_cmac_input_bus;
        i_col_real  => i_col_data(23 downto 16),  --  in (7:0);
        i_col_imag  => i_col_data(31 downto 24), --  in (7:0);
        -- Readout interface. Readout pulses high 5 or 6 clocks after i_<col|row>.last
        o_readout_vld  => XY_vld, -- out std_logic;
        o_readout_data => XY_data -- out std_logic_vector((g_ACCUM_WIDTH*2 - 1) downto 0)  -- real part in low g_ACCUM_WIDTH bits, imaginary part in high g_ACCUM_BITS 
    );

    cmac_YX : entity correlator_lib.cmac
    generic map (
        g_ACCUM_WIDTH     => 24, -- natural := 24;
        g_SAMPLE_WIDTH    => 8,  -- natural range 1 to 9 := 8;  -- >6 uses two 18b multiplers
        g_CMAC_LATENCY    => 5   -- natural range work.cmac_pkg.c_CMAC_LATENCY to work.cmac_pkg.c_CMAC_LATENCY  -- i.e. 5
    ) port map (
        i_clk       => i_clk, -- in std_logic;
        i_clk_reset => '0',   -- in std_logic;  -- all this does is disable simulation error messages.
        i_row       => i_row_meta,   -- in t_cmac_input_bus;  only uses .vld, .first and .last
        i_row_real  => i_row_data(23 downto 16), -- in (7:0);
        i_row_imag  => i_row_data(31 downto 24), -- in (7:0); 
        i_col       => i_col_meta, --  in t_cmac_input_bus;
        i_col_real  => i_col_data(7 downto 0),  --  in (7:0);
        i_col_imag  => i_col_data(15 downto 8), --  in (7:0);
        -- Readout interface. Readout pulses high 5 or 6 clocks after i_<col|row>.last
        o_readout_vld  => YX_vld, -- out std_logic;
        o_readout_data => YX_data -- out std_logic_vector((g_ACCUM_WIDTH*2 - 1) downto 0)  -- real part in low g_ACCUM_WIDTH bits, imaginary part in high g_ACCUM_BITS 
    );

    cmac_YY : entity correlator_lib.cmac
    generic map (
        g_ACCUM_WIDTH     => 24, -- natural := 24;
        g_SAMPLE_WIDTH    => 8,  -- natural range 1 to 9 := 8;  -- >6 uses two 18b multiplers
        g_CMAC_LATENCY    => 5   -- natural range work.cmac_pkg.c_CMAC_LATENCY to work.cmac_pkg.c_CMAC_LATENCY  -- i.e. 5
    ) port map (
        i_clk       => i_clk, -- in std_logic;
        i_clk_reset => '0',   -- in std_logic;  -- all this does is disable simulation error messages.

        i_row       => i_row_meta,   -- in t_cmac_input_bus;  only uses .vld, .first and .last
        i_row_real  => i_row_data(23 downto 16),  -- in std_logic_vector(7 downto 0);
        i_row_imag  => i_row_data(31 downto 24), -- in std_logic_vector(7 downto 0);
        
        i_col       => i_col_meta, --  in t_cmac_input_bus;
        i_col_real  => i_col_data(23 downto 16),  --  in std_logic_vector(7 downto 0);
        i_col_imag  => i_col_data(31 downto 24), --  in std_logic_vector(7 downto 0);

        -- Readout interface. Readout pulses high 5 or 6 clocks after i_<col|row>.last
        o_readout_vld  => YY_vld, -- out std_logic;
        o_readout_data => YY_data -- out std_logic_vector((g_ACCUM_WIDTH*2 - 1) downto 0)  -- real part in low g_ACCUM_WIDTH bits, imaginary part in high g_ACCUM_BITS 
    );

end Behavioral;
