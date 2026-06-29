-- ct2_test1_top.vhd  --  8 VCs, 2 subarray-beams, one per correlator
library ct_lib;
entity ct2_test1_top is end ct2_test1_top;
architecture Behavioral of ct2_test1_top is
begin
    tb : entity ct_lib.ct2_v80_tb
    generic map (
        g_VIRTUAL_CHANNELS => 8,
        g_CORRELATOR_CORES => 1,
        g_BAD_POLY_VC      => x"0004",
        g_BAD_POLY_PACKETS => 0,
        -- 1 SB in each correlator
        g_SB_COUNTS => (x"00000001", x"00000000", x"00000001", x"00000000"),
        -- VCs 0-3: SB_id=0 (corr0), station=0; VCs 4-7: SB_id=0x80=128 (corr1), station=4
        g_DEMAP_TABLE => (
            x"99000000", x"00000000",   -- VCs 0-3:  sky_freq=400, station=0,  SB=0
            x"99100080", x"00000000"    -- VCs 4-7:  sky_freq=400, station=4,  SB=128
        ),
        g_SB_C0_TABLE => (x"01900004", x"00000000", x"98000D80", x"00000000"),
        g_SB_C1_TABLE => (x"01910004", x"00000000", x"98000D80", x"00000000"),
        g_SIM_DURATION_US => 5000,
        g_HBM_DUMP_FILE   => "ct2_test1_hbm.txt"
    );
end Behavioral;
