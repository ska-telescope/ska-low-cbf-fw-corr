-- ct2_test2_top.vhd  --  8 VCs, 2 subarray-beams both in correlator 0
library ct_lib;
entity ct2_test2_top is end ct2_test2_top;
architecture Behavioral of ct2_test2_top is
begin
    tb : entity ct_lib.ct2_v80_tb
    generic map (
        g_VIRTUAL_CHANNELS => 8,
        g_CORRELATOR_CORES => 1,
        g_BAD_POLY_VC      => x"0004",
        g_BAD_POLY_PACKETS => 0,
        g_SB_COUNTS => (x"00000002", x"00000000", x"00000000", x"00000000"),
        -- VCs 0-3: SB=0 station=0; VCs 4-7: SB=1 station=4
        g_DEMAP_TABLE => (
            x"99000000", x"00000000",   -- VCs 0-3: sky_freq=400, station=0, SB=0
            x"99100001", x"00000000"    -- VCs 4-7: sky_freq=400, station=4, SB=1
        ),
        -- Two SB entries for corr0
        g_SB_C0_TABLE => (
            x"01900004", x"00000000", x"98000D80", x"00000000",   -- SB 0
            x"01910004", x"00000000", x"98000D80", x"00000000"    -- SB 1
        ),
        g_SB_C1_TABLE => (0 => x"00000000"),
        g_SIM_DURATION_US => 5000,
        g_HBM_DUMP_FILE   => "ct2_test2_hbm.txt"
    );
end Behavioral;
