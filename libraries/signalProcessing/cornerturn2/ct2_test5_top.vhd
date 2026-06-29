-- ct2_test5_top.vhd  --  12 VCs, 1 subarray-beam (default/full test)
--library ct_lib;
entity ct2_test5_top is end ct2_test5_top;
architecture Behavioral of ct2_test5_top is
begin
    tb : entity work.ct2_v80_tb
    generic map (
        g_VIRTUAL_CHANNELS => 12,
        g_CORRELATOR_CORES => 1,
        g_BAD_POLY_VC      => x"FFFF",   -- disabled
        g_BAD_POLY_PACKETS => 0,
        -- 1 SB in corr0 table0, also 1 in table1 (same config, both tables active)
        g_SB_COUNTS => (x"00000001", x"00000001", x"00000000", x"00000000"),
        -- Demap: 12 VCs in 3 groups of 4
        --   word0: bit31=valid, bits28:20=sky_freq_idx(200=0xC8), bits19:8=station, bits7:0=SB_id
        --   0x8C800000: valid=1, sky_freq=200, station=0,  SB=0
        --   0x8C800400: valid=1, sky_freq=200, station=4,  SB=0
        --   0x8C800800: valid=1, sky_freq=200, station=8,  SB=0
        g_DEMAP_TABLE => (
            x"8C800000", x"00000000",   -- VCs  0-3:  station=0,  SB=0
            x"8C800400", x"00000000",   -- VCs  4-7:  station=4,  SB=0
            x"8C800800", x"00000000"    -- VCs 8-11:  station=8,  SB=0
        ),
        -- SB 0:
        --   word0: stations=12(0xC), coarse_start=200(0xC8)   -> 0x00C8000C
        --   word1: fine_start=0                                -> 0x00000000
        --   word2: num_fine= 288 (0x120), fine_per_int=24(0x18), int_mode=1 (849ms) -> 0x98000D80
        --   word3: HBM_base_addr=0                            -> 0x00000000
        g_SB_C0_TABLE => (x"00C8000C", x"00000000", x"98000120", x"00000000"),
        g_SB_C1_TABLE => (0 => x"00000000"),
        g_SIM_DURATION_US => 4000,
        g_HBM_DUMP_FILE   => "ct2_test5_hbm.txt"
    );
end Behavioral;
