-- ct2_test2_top.vhd  --  8 VCs, 2 subarray-beams both in correlator 0
--library ct_lib;
entity ct2_test2_top is end ct2_test2_top;
architecture Behavioral of ct2_test2_top is
begin
    tb : entity work.ct2_v80_tb
    generic map (
        g_VIRTUAL_CHANNELS => 8,
        g_CORRELATOR_CORES => 1,
        g_BAD_POLY_VC      => x"FFFF",  -- disabled
        g_BAD_POLY_PACKETS => 0,
        g_SB_COUNTS => (x"00000002", x"00000000", x"00000000", x"00000000"),
        
        ------------------------------------------------------------------------------------------------------
        -- Demap: 8 VCs in 2 groups of 4
        --   word0: bit31=valid, bits28:20=sky_freq_idx(200=0xC8), bits19:8=station, bits7:0=SB_id
        --   0x8C800000: valid=1, sky_freq=200, station=0,  SB=0
        --   0x8C800400: valid=1, sky_freq=200, station=0,  SB=1
        g_DEMAP_TABLE => (
            x"84000000", x"00000000",   -- VCs  0-3:  station=0,  SB=0
            x"84000001", x"00000000"    -- VCs  4-7:  station=0,  SB=1
        ),
        -- SB 0:
        --   word0: stations=3 (0x3), coarse_start=200(0xC8)   -> 0x00C80003
        --   word1: fine_start=0                               -> 0x00000000
        --   word2: num_fine= 288 (0x120), fine_per_int=24(0x18), int_mode=1 (849ms) -> 0x98000D80
        --   word3: HBM_base_addr=0                            -> 0x00000000
        -- SB 0, second entry:
        --   word0: stations=6 (0x6), coarse_start=200(0xC8)   -> 0x00C80006
        --   word1: fine_start=0                               -> 0x00000000
        --   word2: num_fine= 288 (0x120), fine_per_int=24(0x18), int_mode=1 (849ms) -> 0x98000D80
        --   word3: HBM_base_addr=                             -> 0x0001B000
        --
        -- Second base address is 0xD800 = 256 * (1 group of stations) * 12 * (288 fine/4)) / 4
        g_SB_C0_TABLE => (x"00400003", x"00000000", x"98000D80", x"00000000",
                          x"00400003", x"00000000", x"98000D80", x"000A2000"),
        g_SB_C1_TABLE => (0 => x"00000000"),
        g_SIM_DURATION_US => 7500, -- 4400us ? should be just enough for the 288/24 = 12 visibility blocks to be output
        g_HBM_DUMP_FILE   => "/home/hum089/projects/perentie/corr_latest/ska-low-cbf-fw-corr/libraries/signalProcessing/cornerturn2/test2/ct2_test2_hbm.txt",
        g_VIS_DUMP_FILE   => "/home/hum089/projects/perentie/corr_latest/ska-low-cbf-fw-corr/libraries/signalProcessing/cornerturn2/test2/ct2_test2_vis_dump.txt"
        -------------------------------------------------------------------------------------------------------
        
    );
end Behavioral;
