---------------------------------------------------------------------------------------------------
-- 
-- Signal processing - Main Package
--
---------------------------------------------------------------------------------------------------
--
-- Author  : David Humphrey & Norbert Abel (norbert_abel@gmx.net)
-- Standard: VHDL'08
--
---------------------------------------------------------------------------------------------------
-- Types used to connect different signal processing modules.
--
---------------------------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;

package DSP_top_pkg is
    

    constant pc_WALL_TIME_LEN    : natural := 32+30;
    type t_wall_time is record
        sec : std_logic_vector(31 downto 0);
        ns  : std_logic_vector(29 downto 0);
    end record; 
    
    function slv_to_wall_time(i: std_logic_vector) return t_wall_time;
    function wall_time_to_slv(i: t_wall_time) return std_logic_vector;   
    function "<=" (i1, i2: t_wall_time) return boolean;
    function ">=" (i1, i2: t_wall_time) return boolean;

    -------------------------------------------------------------------------------------------------------------------
    -- Stuff that is probably not used anywhere, kept just in case; Can safely delete once the project has been built.
    --
    constant pc_CTC_DATA_WIDTH    : natural := 16;         --re+im
    constant pc_CTC_META_WIDTH    : natural := 9+9+1+32+3; --coarse+station+pol+ts+in_port
    constant pc_CTC_HEADER_WIDTH  : natural := 128;
    constant pc_CTC_INPUT_TS_NUM  : natural := 2;          --how many timestamps per cycle on the input port?
    constant pc_CTC_INPUT_WIDTH   : natural := pc_CTC_DATA_WIDTH*2*pc_CTC_INPUT_TS_NUM;  --dual polarisation x pc_CTC_INPUT_TS_NUM timestamps, to get 64 bit wide data input
    
    -------------------------------------------------------------------------------------------------------------------
    
    type t_complex_Int8 is record  -- real and imaginary components at the input and output of the corner turn are 8 bit real, 8 bit imaginary.    
        re       : std_logic_vector(7 downto 0);
        im       : std_logic_vector(7 downto 0);
    end record;
    constant pc_COMPLEX_INT8_ZERO : t_complex_Int8 := (re=>(others=>'0'), im=>(others=>'0'));
    constant pc_COMPLEX_INT8_RFI  : t_complex_Int8 := (re=>B"10000000",   im=>B"10000000");     

    type t_complex_int16 is record -- real and imaginary components at the output of the filterbank are 16 bit real, 16 bit imaginary.
        re : std_logic_vector(15 downto 0);
        im : std_logic_vector(15 downto 0);
    end record; 

    type t_ctc_meta is record    
        coarse   : std_logic_vector(8 downto 0);
        station  : std_logic_vector(8 downto 0);
        pol      : std_logic_vector(0 downto 0);
        ts       : std_logic_vector(31 downto 0);
        in_port  : std_logic_vector(2 downto 0);
    end record;
    constant pc_CTC_META_ZERO : t_ctc_meta := (coarse=>(others=>'0'), station=>(others=>'0'), pol=>(others=>'0'), ts=>(others=>'0'), in_port=>(others=>'0'));

    type t_ctc_meta_a is array (integer range <>) of t_ctc_meta;
    
    function slv_to_meta(i: std_logic_vector) return t_ctc_meta;
    function slv_to_meta(i: std_logic_vector) return t_ctc_meta_a;
    function meta_to_slv(i: t_ctc_meta) return std_logic_vector;
    function meta_to_slv(i: t_ctc_meta_a) return std_logic_vector;

    type t_ctc_data is record
        data     : t_complex_int8;
        meta     : t_ctc_meta;
    end record;
    constant pc_CTC_DATA_ZERO : t_ctc_data := (data=>pc_COMPLEX_INT8_ZERO, meta=>pc_CTC_META_ZERO);
    
    type t_ctc_coarse_data_a is array (integer range <>) of std_logic_vector(8 downto 0);
    type t_ctc_station_data_a is array (integer range <>) of std_logic_vector(8 downto 0);

    --------------------------------------------------
    -- CTC INPUT DATA
    --------------------------------------------------
    type t_ctc_input_data    is array (pc_CTC_INPUT_WIDTH/pc_CTC_DATA_WIDTH-1 downto 0) of t_ctc_data;             
    type t_ctc_input_data_a  is array (integer range <>) of t_ctc_input_data;
    function payload_to_slv(i: t_ctc_input_data) return std_logic_vector;
    function slv_to_payload(i: std_logic_vector; seg: integer) return t_complex_Int8;
    type t_ctc_input_data_slv_a is array (integer range<>) of std_logic_vector(pc_CTC_INPUT_WIDTH-1 downto 0);

    -- Packet header at the input of the coarse corner turn (and also at the output of the LFAA ingest)
    type t_ctc_input_header is record
        packet_count      : std_logic_vector(39 downto 0);
        virtual_channel   : std_logic_vector(15 downto 0);
        channel_frequency : std_logic_vector(15 downto 0);
        station_id        : std_logic_vector(15 downto 0);
        station_selected  : std_logic_vector(7 downto 0);   -- station within this link; for 40G links, 2 stations are on one link, so this value is 0 or 1. For 100G LFAA data, there are 4 stations per link, so this value will be 0 to 3.
    end record;
    
    constant t_ctc_input_header_ID : std_logic_vector(7 downto 0) := "00000001";  -- Used in packet headers coming out of the interconnect module to identify the packet type. 
    
    constant pc_CTC_INPUT_HEADER_ZERO : t_ctc_input_header := (
        packet_count      => (others =>'0'),
        virtual_channel   => (others =>'0'),
        channel_frequency => (others =>'0'),
        station_id        => (others =>'0'),
        station_selected  => (others =>'0')
    );
    type t_ctc_input_header_a is array (integer range <>) of t_ctc_input_header;
    
    --------------------------------------------------
    -- CTC OUTPUT DATA
    --------------------------------------------------
    type t_ctc_output_header is record
        -- timestamp : 
        --   + High 32 bits are the packet_count field from t_ctc_input_header
        --   + Low 11 bits selects the specific sample within the LFAA packet, which will be non-zero due to the coarse offset .
        timestamp         : std_logic_vector(31 downto 0); 
        -- coarse delay is the number of LFAA samples the packet has been delayed by. 
        -- This is only used for debug; The control system needs to be aware of the delays to assign a correct timestamps at the correlator output. 
        coarse_delay      : std_logic_vector(15 downto 0);
        virtual_channel   : std_logic_vector(15 downto 0); -- copied from the relevant input header field (t_ctc_input_header)
        station_id        : std_logic_vector(15 downto 0);
        hpol_phase_shift  : std_logic_vector(15 downto 0); -- The header applies to both horizontal and vertical polarisations.
        vpol_phase_shift  : std_logic_vector(15 downto 0);  
    end record;
    
    type t_CT1_META_out is record
        HDeltaP        : std_logic_vector(31 downto 0);
        VDeltaP        : std_logic_vector(31 downto 0);
        HOffsetP       : std_logic_vector(31 downto 0);
        VOffsetP       : std_logic_vector(31 downto 0);
        integration    : std_logic_vector(31 downto 0); --  which integration is this for; units of 849ms since epoch
        ctFrame        : std_logic_vector(1 downto 0);  --  which corner turn frame is this; 0, 1, or 2; units of 283ms; relative to integration.
        virtualChannel : std_logic_vector(15 downto 0); --  Virtual channels are processed in order, so this just counts.
        bad_poly       : std_logic;
        valid          : std_logic;
    end record;
    type t_CT1_META_out_arr is array (integer range <>) of t_CT1_META_out;
    
--    type t_atomic_CT_pst_META_out is record
--        HDeltaP        : std_logic_vector(15 downto 0);
--        VDeltaP        : std_logic_vector(15 downto 0);
--        HOffsetP       : std_logic_vector(15 downto 0);
--        VOffsetP       : std_logic_vector(15 downto 0);
--        frameCount     : std_logic_vector(36 downto 0); -- high 32 bits is the LFAA frame count, low 5 bits is the 64 sample block within the frame. 
--        virtualChannel : std_logic_vector(15 downto 0); --  Virtual channels are processed in order, so this just counts.
--        valid          : std_logic; 
--    end record;
--    type t_atomic_CT_pst_META_out_arr is array (integer range <>) of t_atomic_CT_pst_META_out;
    
    
    constant pc_CTC_OUTPUT_HEADER_ZERO : t_ctc_output_header := (
        timestamp         => (others=>'0'),
        coarse_delay      => (others=>'0'),
        virtual_channel   => (others=>'0'),
        station_id        => (others=>'0'),
        hpol_phase_shift  => (others=>'0'),
        vpol_phase_shift  => (others=>'0')
    );
    type t_ctc_output_header_arr is array (integer range <>) of t_ctc_output_header;
    
    
    -----------------------------------------------------------
    -- Packet header at the output of the fine delay (FD). 
    -- Much the same as t_ctc_output_header, but combines two streams, so has two station_ids.
    -- Also has everything byte aligned.
    type t_FD_output_header is record
        timestamp         : std_logic_vector(31 downto 0);
        virtual_channel   : std_logic_vector(15 downto 0);
        station_id0       : std_logic_vector(15 downto 0);
        station_id1       : std_logic_vector(15 downto 0);  -- Data for two stations is packed into a single packet
        fine_channel      : std_logic_vector(15 downto 0);  -- Index of the first fine channel in this packet (e.g. for correlator, fine channels run from 0 to 3455).
        coarse_delay0     : std_logic_vector(15 downto 0);  -- coarse delay used for station_id0
        coarse_delay1     : std_logic_vector(15 downto 0);
    end record;
    
    constant t_FD_output_header_ID : std_logic_vector(7 downto 0) := "00000010";  -- Used in packet headers coming out of the interconnect module to identify the packet type. 
    
    constant pc_FD_OUTPUT_HEADER_ZERO : t_FD_output_header := (
        timestamp         => (others => '0'),
        virtual_channel   => (others => '0'),
        station_id0       => (others => '0'),
        station_id1       => (others => '0'),
        fine_channel      => (others => '0'),
        coarse_delay0     => (others => '0'),
        coarse_delay1     => (others => '0')
    );
    
    function slv_to_header(i: std_logic_vector(pc_CTC_HEADER_WIDTH-1 downto 0)) return t_ctc_input_header;
    function slv_to_header(i : std_logic_vector(111 downto 0)) return t_ctc_output_header;
    function slv_to_header(i : std_logic_vector(127 downto 0)) return t_FD_output_header;
    function header_to_slv(i: t_ctc_input_header) return std_logic_vector;
    function header_to_slv(i: t_ctc_output_header) return std_logic_vector;
    function header_to_slv(i: t_FD_output_header) return std_logic_vector;
    
    --function header_to_slv(i: t_atomic_CT_pst_META_out) return std_logic_vector;
    
    --------------------------------------------------
    -- CTC OUTPUT DATA, also used in the filterbanks.
    --------------------------------------------------
    type t_ctc_output_payload is record     
        hpol : t_complex_Int8;
        vpol : t_complex_Int8;
    end record;
    
    type t_ctc_output_payload_arr is array(integer range <>) of t_ctc_output_payload;
    
    type t_FB_output_payload is record
        hpol : t_complex_Int16;
        vpol : t_complex_Int16;
    end record;
    
    type t_FB_output_payload_a is array(integer range <>) of t_FB_output_payload;
    
    --type t_ctc_output_data is record
    --    data     : t_ctc_output_payload;
    --    meta     : t_ctc_meta_a(1 downto 0); --0=hpol, 1=vpol
    --end record;
    constant pc_CTC_OUTPUT_DATA_ZERO : t_ctc_data := (data=>pc_COMPLEX_INT8_ZERO, meta=>pc_CTC_META_ZERO);
    --type t_ctc_output_data_a is array (integer range <>) of t_ctc_output_data;
    
    function sel (s: boolean; a: integer; b: integer) return integer;
    
end package DSP_top_pkg;

package body DSP_top_pkg is

    -- Helper functions
    function sel (s: boolean; a: integer; b: integer) return integer is
    begin
        if s then return a; else return b; end if;
    end function;
    
    
    --------------------------------------------------
    -- WALL TIME
    --------------------------------------------------
    function slv_to_wall_time(i: std_logic_vector) return t_wall_time is
        variable o: t_wall_time;
    begin
        o.sec := i(30+31 downto 30);
        o.ns  := i(29 downto 0);
        return o;
    end function;
    
    function wall_time_to_slv(i: t_wall_time) return std_logic_vector is
        variable o: std_logic_vector(30+32-1 downto 0);   
    begin
        o(30+31 downto 30) := i.sec;
        o(29 downto 0)     := i.ns;
        return o;
    end function;
     
    function "<=" (i1, i2: t_wall_time) return boolean is
    begin
        if wall_time_to_slv(i1) <= wall_time_to_slv(i2) then
            return true;
        else
            return false;
        end if;        
    end function;

    function ">=" (i1, i2: t_wall_time) return boolean is
    begin
        if wall_time_to_slv(i1) >= wall_time_to_slv(i2) then
            return true;
        else
            return false;
        end if;        
    end function;

    --------------------------------------------------
    -- COMMON 16 bit DATA
    --------------------------------------------------
    function slv_to_meta(i: std_logic_vector) return t_ctc_meta is
        variable o:  t_ctc_meta;
        variable tmp: std_logic_vector(i'length-1 downto 0); --i can have a range that does not start at 0
    begin
        tmp := i;
        o.coarse  := tmp(08 downto 00);
        o.station := tmp(17 downto 09);
        o.pol     := tmp(18 downto 18);
        o.ts      := tmp(50 downto 19);
        o.in_port := tmp(53 downto 51);
        return o;
    end function;

    function slv_to_meta(i: std_logic_vector) return t_ctc_meta_a is
        constant segments : integer := i'length / pc_CTC_META_WIDTH;
        variable tmp      : std_logic_vector(i'length-1 downto 0); --i can have a range that does not start at 0
        variable o        : t_ctc_meta_a(segments-1 downto 0);
    begin
        tmp := i;
        for p in 0 to segments-1 loop
            o(p) := slv_to_meta(tmp((p+1)*pc_CTC_META_WIDTH-1 downto p*pc_CTC_META_WIDTH));
        end loop;
        return o;
    end function;

    function meta_to_slv(i: t_ctc_meta) return std_logic_vector is
        variable o: std_logic_vector(pc_CTC_META_WIDTH-1 downto 0);
    begin
        o(08 downto 00) := i.coarse;
        o(17 downto 09) := i.station;
        o(18 downto 18) := i.pol;
        o(50 downto 19) := i.ts;
        o(53 downto 51) := i.in_port;
        return o;
    end function;

    function meta_to_slv(i: t_ctc_meta_a) return std_logic_vector is
        variable o: std_logic_vector((i'length)*pc_CTC_META_WIDTH-1 downto 0);
    begin
        for p in 0 to i'length-1 loop
            o((p+1)*pc_CTC_META_WIDTH-1 downto p*pc_CTC_META_WIDTH) := meta_to_slv(i(p));
        end loop;
        return o;
    end function;

    function payload_to_slv(i: t_ctc_input_data) return std_logic_vector is
        variable o: std_logic_vector(pc_CTC_INPUT_WIDTH-1 downto 0);
    begin
        for seg in 0 to pc_CTC_INPUT_WIDTH/pc_CTC_DATA_WIDTH-1 loop
            o(07+16*seg downto 0+16*seg) := i(seg).data.re;
            o(15+16*seg downto 8+16*seg) := i(seg).data.im;
        end loop;
        return o;    
    end function;

    function slv_to_payload(i: std_logic_vector; seg: integer) return t_complex_Int8 is
        variable o: t_complex_Int8;
    begin
        o.re := i(07+16*seg downto 0+16*seg);
        o.im := i(15+16*seg downto 8+16*seg);
        return o;    
    end function;

    --------------------------------------------------
    -- HEADER
    --------------------------------------------------
    function slv_to_header(i: std_logic_vector(pc_CTC_HEADER_WIDTH-1 downto 0)) return t_ctc_input_header is
        variable o: t_ctc_input_header;
    begin
        o.packet_count      := i(31 downto 0);
        o.virtual_channel   := i(47 downto 32);  -- WARNING - IC_LFAAInputFifo assumes that the virtual channel occurs in the low 64 bits; Do not move to the high 64 bits.
        o.channel_frequency := i(63 downto 48);
        o.station_id        := i(79 downto 64);
        o.station_selected  := i(87 downto 80);
        return o;
    end function;

    function header_to_slv(i: t_ctc_input_header) return std_logic_vector is
        variable o: std_logic_vector(pc_CTC_HEADER_WIDTH-1 downto 0);
    begin
        o(31 downto 0)  := i.packet_count;
        o(47 downto 32)  := i.virtual_channel;
        o(63 downto 48)  := i.channel_frequency;
        o(79 downto 64)  := i.station_id;
        o(87 downto 80)  := i.station_selected;
        o(127 downto 88) := (others => '0');
        return o;
    end function;

    
    function slv_to_header(i : std_logic_vector(111 downto 0)) return t_ctc_output_header is
        variable o: t_ctc_output_header;
    begin
        o.timestamp := i(31 downto 0);
        o.coarse_delay := i(47 downto 32);
        o.virtual_channel := i(63 downto 48);
        o.station_id  := i(79 downto 64);
        o.hpol_phase_shift := i(95 downto 80);
        o.vpol_phase_shift := i(111 downto 96);
        return o;
    end function;

    function header_to_slv(i: t_ctc_output_header) return std_logic_vector is
        variable o: std_logic_vector(111 downto 0);
    begin
        o(31 downto 0) := i.timestamp;
        o(47 downto 32) := i.coarse_delay;
        o(63 downto 48) := i.virtual_channel;
        o(79 downto 64) := i.station_id;
        o(95 downto 80) := i.hpol_phase_shift;
        o(111 downto 96) := i.vpol_phase_shift;
        return o;
    end function;




    function slv_to_header(i : std_logic_vector(127 downto 0)) return t_FD_output_header is
        variable o: t_fd_output_header;
    begin
        o.timestamp := i(31 downto 0);
        o.virtual_channel := i(47 downto 32);
        o.station_id0 := i(63 downto 48);
        o.station_id1 := i(79 downto 64);
        o.fine_channel := i(95 downto 80);
        o.coarse_delay0 := i(111 downto 96);
        o.coarse_delay1 := i(127 downto 112); 
        return o;
    end function;

    function header_to_slv(i: t_FD_output_header) return std_logic_vector is
        variable o: std_logic_vector(127 downto 0);
    begin
        o(31 downto 0) := i.timestamp;
        o(47 downto 32) := i.virtual_channel;
        o(63 downto 48) := i.station_id0;
        o(79 downto 64) := i.station_id1;
        o(95 downto 80) := i.fine_channel;
        o(111 downto 96) := i.coarse_delay0;
        o(127 downto 112) := i.coarse_delay1;
        return o;
    end function;


   -- function header_to_slv(i: t_atomic_CT_pst_META_out) return std_logic_vector is
   --     variable o: std_logic_vector(85 downto 0);
   -- begin
   --     o(15 downto 0) := i.HDeltaP;
   --     o(31 downto 16) := i.VDeltaP;
   --     o(47 downto 32) := i.virtualChannel;
   --     o(84 downto 48) := i.frameCount;
   --     o(85) := i.valid;
   --     return o;
   -- end function;

end DSP_top_pkg;