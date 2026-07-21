-- ct2_test4_top.vhd  --  1 VC, 1 SB, fine-channel integration (2 channels per output)
library ct_lib;
entity ct2_test4_top is end ct2_test4_top;
architecture Behavioral of ct2_test4_top is
begin
    tb : entity ct_lib.ct2_v80_tb
    generic map (
        g_VIRTUAL_CHANNELS => 1,
        g_CORRELATOR_CORES => 1,
        g_BAD_POLY_VC      => x"FFFF",   -- disabled
        g_BAD_POLY_PACKETS => 0,
        g_SB_COUNTS => (x"00000001", x"00000000", x"00000000", x"00000000"),
        -- 1 VC group: valid, sky_freq=0x264=612, station=0, SB=0
        g_DEMAP_TABLE => (
            x"86400000", x"00000000",
            x"00000000", x"00000000"    -- second group unused
        ),
        -- SB 0: 1 station, coarse=0x64=100, fine_start=0x6BA=1722, num_fine=12, fine_per_int=2, 849ms, HBM_base=0
        g_SB_C0_TABLE => (
            x"00640001", x"000006BA", x"8200000C", x"00000000",
            x"00000000", x"00000000", x"00000000", x"00000000"    -- second SB entry unused
        ),
        g_SB_C1_TABLE => (0 => x"00000000"),
        g_SIM_DURATION_US => 5000,
        g_HBM_DUMP_FILE   => "ct2_test4_hbm.txt"
    );
end Behavioral;
