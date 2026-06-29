-- ct2_test0_top.vhd  --  8 VCs, 1 subarray-beam, bad poly on VC 0 packet 0
library ct_lib;
entity ct2_test0_top is end ct2_test0_top;
architecture Behavioral of ct2_test0_top is
begin
    tb : entity ct_lib.ct2_v80_tb
    generic map (
        g_VIRTUAL_CHANNELS => 8,
        g_CORRELATOR_CORES => 1,
        g_BAD_POLY_VC      => x"0000",
        g_BAD_POLY_PACKETS => 0,
        g_SB_COUNTS => (x"00000001", x"00000000", x"00000000", x"00000000"),
        -- Demap: VCs 0-3 -> station 0 SB 0, VCs 4-7 -> station 4 SB 0
        g_DEMAP_TABLE => (
            x"99000000", x"00000000",   -- VCs 0-3:  valid, sky_freq=400, station=0, SB=0
            x"99000400", x"00000000"    -- VCs 4-7:  valid, sky_freq=400, station=4, SB=0
        ),
        -- SB 0: 8 stations, coarse_start=0x190=400, fine_start=0, num_fine=3456, fine_per_int=24, 849ms, HBM_base=0
        g_SB_C0_TABLE => (x"01900008", x"00000000", x"98000D80", x"00000000"),
        g_SB_C1_TABLE => (0 => x"00000000"),
        g_SIM_DURATION_US => 5000,
        g_HBM_DUMP_FILE   => "ct2_test0_hbm.txt"
    );
end Behavioral;
