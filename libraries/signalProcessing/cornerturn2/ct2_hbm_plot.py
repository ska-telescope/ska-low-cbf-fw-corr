#!/usr/bin/env python3
"""
ct2_hbm_plot.py -- Read a CT2 HBM memory dump and plot one station/fine-channel.

HBM layout (get_ct2_HBM_addr_v80.vhd):
  Each 256-byte block holds 16 time samples × 4 stations × 2 pol × 2 bytes (int8 complex).
  Blocks are arranged as a 3-D array:
    addr = SB_base + 256 * (fine_ch_rel * 12 * n_sg  +  time_block * n_sg  +  station_group)
  where
    n_sg          = ceil(SB_N_STATIONS / 4)
    station_group = STATION // 4
    fine_ch_rel   = (coarse * 3456 + fine) - (SB_COARSE_START * 3456 + SB_FINE_START)

Within-block layout (ct2_check.py / corr_ct2_din_v80.vhd):
  8 AXI beats × 32 bytes, beat k covers time samples 2k and 2k+1:
    bytes [k*32 + 0  .. k*32+15]: time 2k,   station 0-3 each = {H.re, H.im, V.re, V.im}
    bytes [k*32 + 16 .. k*32+31]: time 2k+1, station 0-3

Dump file format:
  Raw binary, byte address 0 onwards.  Unwritten locations contain FEEDCAFE
  (bytes CA FE ED FE in little-endian, i.e. 0xFEEDCAFE stored little-endian).
Debug data encoding (corr_ct2_din_v80.vhd lines 705-777):
  When i_insert_dbg='1', each 32-bit sample word packs field values instead of signal data.
  The bit layout differs between the first station of each group (s_in_group=0) and the rest:

    s_in_group == 0:  [9:0]=VC, [21:10]=fine[11:0], [27:22]=time[5:0], [29:28]=mod3, [31:30]=849ms
    s_in_group != 0:  [11:0]=VC, [21:12]=fine[9:0], [27:22]=time[5:0], [29:28]=mod3, [31:30]=849ms

  VC = virtual channel (= station index), fine = fineChannel_del1 (0-3455 absolute within coarse),
  time = timeStep (packet count within CT frame, 0-63), mod3 = frameCount_mod3 (0-2),
  849ms = free-running frame counter (unpredictable, not checked).
"""

import math
import sys
import argparse
import struct
import numpy as np
import matplotlib.pyplot as plt

# ---------------------------------------------------------------------------
# Constants – adjust these for your simulation / hardware run
# ---------------------------------------------------------------------------

N_WORDS_TO_READ = 1024 * 1024 // 4   # 1 MiB (number of 32-bit words)

# Subarray-beam parameters (must match the generic map in your *_top.vhd)
SB_HBM_BASE_ADDR = 0x00000000  # byte address of the SB in HBM
SB_COARSE_START  = 0           # first coarse channel for this SB (0-511)
SB_FINE_START    = 0           # first fine channel within that coarse ch (0-3455)
SB_N_STATIONS    = 12          # total stations (virtual channels) in this SB
SB_N_FINE        = 3456        # total fine channels stored for this SB

# Which station and fine channel to plot (must be within the SB ranges above)
PLOT_STATION  = 0   # station index within the SB; maps 1-to-1 to virtual channel
PLOT_FINE_CH  = 0   # relative fine channel (0 = SB_COARSE_START*3456 + SB_FINE_START)

# Sentinel value for unwritten HBM locations
UNWRITTEN = 0xFEEDCAFE


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def load_dump(path: str, n_words: int) -> bytearray:
    """Load up to n_words 32-bit words from a raw binary dump file."""
    max_bytes = n_words * 4
    with open(path, 'rb') as fh:
        data = fh.read(max_bytes)
    return bytearray(data)


def block_byte_offset(t_in_block: int, s_in_group: int) -> int:
    """
    Byte offset within a 256-byte block for time sample t_in_block (0-15)
    and station-within-group s_in_group (0-3).
    Returns the offset to the first byte {H.re, H.im, V.re, V.im} for that sample.
    """
    beat   = t_in_block // 2   # AXI beat (0-7)
    parity = t_in_block %  2   # 0=even, 1=odd half of beat
    return beat * 32 + parity * 16 + s_in_group * 4


def hbm_block_addr(
    fine_ch_rel: int,
    time_block: int,
    station_group: int,
    n_sg: int,
    sb_base: int,
) -> int:
    return sb_base + 256 * (
        fine_ch_rel * 12 * n_sg + time_block * n_sg + station_group
    )


# ---------------------------------------------------------------------------
# Main decoder
# ---------------------------------------------------------------------------

def decode(buf: bytearray) -> tuple:
    """
    Extract the 192-sample time series for PLOT_STATION / PLOT_FINE_CH.

    Returns four numpy int8 arrays of length 192:
      h_re, h_im, v_re, v_im
    """
    n_sg          = math.ceil(SB_N_STATIONS / 4)
    station_group = PLOT_STATION // 4
    s_in_group    = PLOT_STATION %  4

    assert 0 <= PLOT_STATION < SB_N_STATIONS, "PLOT_STATION out of range"
    assert 0 <= PLOT_FINE_CH < SB_N_FINE,    "PLOT_FINE_CH out of range"

    n_time_samples = 12 * 16    # 192 total
    h_re = np.zeros(n_time_samples, dtype=np.int8)
    h_im = np.zeros(n_time_samples, dtype=np.int8)
    v_re = np.zeros(n_time_samples, dtype=np.int8)
    v_im = np.zeros(n_time_samples, dtype=np.int8)
    unwritten_blocks = 0

    for tb in range(12):
        blk_addr = hbm_block_addr(PLOT_FINE_CH, tb, station_group, n_sg, SB_HBM_BASE_ADDR)

        if blk_addr + 256 > len(buf):
            print(f"WARNING: block address 0x{blk_addr:08X} (time_block={tb}) "
                  f"is outside the loaded buffer ({len(buf)} bytes) – skipping",
                  file=sys.stderr)
            continue

        # Quick check for unwritten block
        sentinel = int.from_bytes(buf[blk_addr:blk_addr + 4], 'little')
        if sentinel == UNWRITTEN:
            unwritten_blocks += 1

        for t in range(16):
            off   = blk_addr + block_byte_offset(t, s_in_group)
            tidx  = tb * 16 + t
            h_re[tidx] = struct.unpack_from('b', buf, off)[0]
            h_im[tidx] = struct.unpack_from('b', buf, off + 1)[0]
            v_re[tidx] = struct.unpack_from('b', buf, off + 2)[0]
            v_im[tidx] = struct.unpack_from('b', buf, off + 3)[0]

    if unwritten_blocks:
        print(f"WARNING: {unwritten_blocks}/12 time blocks appear unwritten (FEEDCAFE)",
              file=sys.stderr)

    return h_re, h_im, v_re, v_im


# ---------------------------------------------------------------------------
# Debug data checker (corr_ct2_din_v80.vhd lines 705-777)
# ---------------------------------------------------------------------------

def decode_debug_fields(h_re, h_im, v_re, v_im, s_in_group: int) -> tuple:
    """
    Decode one 32-bit debug sample back to (vc, fine, time_step, frame_mod3, frame_849ms).
    The four bytes are h_re=byte0, h_im=byte1, v_re=byte2, v_im=byte3 (little-endian word).
    """
    b0 = int(h_re) & 0xFF
    b1 = int(h_im) & 0xFF
    b2 = int(v_re) & 0xFF
    b3 = int(v_im) & 0xFF
    if s_in_group == 0:
        # [9:0]=VC, [21:10]=fine[11:0], [27:22]=time[5:0], [29:28]=mod3, [31:30]=849ms
        vc          = b0 | ((b1 & 0x03) << 8)
        fine        = ((b1 >> 2) & 0x3F) | ((b2 & 0x3F) << 6)
    else:
        # [11:0]=VC, [21:12]=fine[9:0], [27:22]=time[5:0], [29:28]=mod3, [31:30]=849ms
        vc          = b0 | ((b1 & 0x0F) << 8)
        fine        = ((b1 >> 4) & 0x0F) | ((b2 & 0x3F) << 4)
    time_step   = ((b2 >> 6) & 0x03) | ((b3 & 0x0F) << 2)
    frame_mod3  = (b3 >> 4) & 0x03
    frame_849ms = (b3 >> 6) & 0x03
    return vc, fine, time_step, frame_mod3, frame_849ms


def check_debug(h_re, h_im, v_re, v_im) -> dict:
    """
    Decode debug fields from all 192 samples and compare against expected values.

    Expected:
      vc        = PLOT_STATION  (constant)
      fine      = (SB_FINE_START + PLOT_FINE_CH) % 3456, masked to available bits
      time_step = sample_index % 64  (0-63, resets every CT frame)
      frame_mod3= sample_index // 64  (0, 1, 2)
      frame_849ms is a free-running counter – not checked.

    Returns a dict of decoded arrays and per-sample pass/fail flags.
    """
    s_in_group = PLOT_STATION % 4
    fine_abs   = (SB_FINE_START + PLOT_FINE_CH) % 3456
    fine_bits  = 12 if s_in_group == 0 else 10
    fine_mask  = (1 << fine_bits) - 1

    n = len(h_re)
    vc_arr   = np.zeros(n, dtype=np.int32)
    fine_arr = np.zeros(n, dtype=np.int32)
    time_arr = np.zeros(n, dtype=np.int32)
    mod3_arr = np.zeros(n, dtype=np.int32)
    f849_arr = np.zeros(n, dtype=np.int32)

    for i in range(n):
        vc_arr[i], fine_arr[i], time_arr[i], mod3_arr[i], f849_arr[i] = \
            decode_debug_fields(h_re[i], h_im[i], v_re[i], v_im[i], s_in_group)

    t          = np.arange(n)
    vc_exp     = np.full(n, PLOT_STATION,           dtype=np.int32)
    fine_exp   = np.full(n, fine_abs & fine_mask,   dtype=np.int32)
    time_exp   = (t % 64).astype(np.int32)
    mod3_exp   = (t // 64).astype(np.int32)

    vc_ok   = vc_arr             == vc_exp
    fine_ok = (fine_arr & fine_mask) == fine_exp
    time_ok = time_arr           == time_exp
    mod3_ok = mod3_arr           == mod3_exp
    all_ok  = vc_ok & fine_ok & time_ok & mod3_ok

    return {
        'vc': vc_arr, 'fine': fine_arr, 'time_step': time_arr,
        'frame_mod3': mod3_arr, 'frame_849ms': f849_arr,
        'vc_exp': vc_exp, 'fine_exp': fine_exp,
        'time_exp': time_exp, 'mod3_exp': mod3_exp,
        'vc_ok': vc_ok, 'fine_ok': fine_ok, 'time_ok': time_ok, 'mod3_ok': mod3_ok,
        'all_ok': all_ok, 'n_errors': int(np.sum(~all_ok)),
        'fine_bits': fine_bits,
    }


def print_debug_report(r: dict) -> None:
    n = len(r['vc'])
    print(f"\nDebug check: station={PLOT_STATION}, fine_ch_rel={PLOT_FINE_CH}, "
          f"fine_abs={r['fine_exp'][0]} ({r['fine_bits']}-bit field for this station)")
    if r['n_errors'] == 0:
        print(f"  PASS – all {n} samples match")
    else:
        print(f"  FAIL – {r['n_errors']}/{n} samples mismatch")
        MAX_DETAIL = 20
        shown = 0
        for i in range(n):
            if r['all_ok'][i]:
                continue
            fields = []
            if not r['vc_ok'][i]:
                fields.append(f"vc={r['vc'][i]} (exp {r['vc_exp'][i]})")
            if not r['fine_ok'][i]:
                fields.append(f"fine={r['fine'][i]} (exp {r['fine_exp'][i]})")
            if not r['time_ok'][i]:
                fields.append(f"time={r['time_step'][i]} (exp {r['time_exp'][i]})")
            if not r['mod3_ok'][i]:
                fields.append(f"mod3={r['frame_mod3'][i]} (exp {r['mod3_exp'][i]})")
            print(f"  t={i:3d} (tb={i//16}, t_in_blk={i%16}): {', '.join(fields)}")
            shown += 1
            if shown >= MAX_DETAIL:
                print(f"  ... ({r['n_errors'] - shown} more errors not shown)")
                break


def plot_debug_check(r: dict, dump_path: str) -> None:
    t = np.arange(len(r['vc']))

    status = "PASS" if r['n_errors'] == 0 else f"FAIL - {r['n_errors']} errors"
    fig, axes = plt.subplots(2, 2, figsize=(12, 7), sharex=True)
    fig.suptitle(
        f"CT2 debug check: station={PLOT_STATION}, fine_ch_rel={PLOT_FINE_CH}  ({status})\n"
        f"{dump_path}",
        fontsize=9,
    )

    panels = [
        (axes[0, 0], r['vc'],         r['vc_exp'],   r['vc_ok'],   "Virtual channel (VC)"),
        (axes[0, 1], r['fine'],        r['fine_exp'],  r['fine_ok'],  f"Fine channel ({r['fine_bits']}-bit)"),
        (axes[1, 0], r['time_step'],   r['time_exp'],  r['time_ok'],  "Time step (0–63)"),
        (axes[1, 1], r['frame_mod3'],  r['mod3_exp'],  r['mod3_ok'],  "Frame mod-3 (0–2)"),
    ]

    for ax, actual, expected, ok, label in panels:
        ax.step(t, actual,   where='post', color='tab:blue',   linewidth=1.0, label='actual')
        ax.step(t, expected, where='post', color='tab:orange', linewidth=0.8,
                linestyle='--', label='expected', alpha=0.7)
        bad = np.where(~ok)[0]
        if len(bad):
            ax.scatter(bad, actual[bad], color='red', s=20, zorder=5, label='mismatch')
        ax.set_title(label)
        ax.legend(fontsize=7, loc='upper right')
        ax.grid(True, alpha=0.3)
        for tb in range(1, 12):
            ax.axvline(tb * 16, color='gray', linestyle='--', linewidth=0.5, alpha=0.6)

    for ax in axes[1, :]:
        ax.set_xlabel("Time sample index (0–191)")

    fig.tight_layout()
    out = "ct2_debug_check_out.png"
    plt.savefig(out, dpi=150)
    print(f"Saved: {out}")
    try:
        plt.show()
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Plotting
# ---------------------------------------------------------------------------

def plot(h_re, h_im, v_re, v_im, dump_path: str) -> None:
    t = np.arange(len(h_re))

    fig, axes = plt.subplots(2, 2, figsize=(12, 7), sharex=True)
    fig.suptitle(
        f"CT2 HBM dump: station={PLOT_STATION}, fine_ch_rel={PLOT_FINE_CH}\n"
        f"(SB base=0x{SB_HBM_BASE_ADDR:08X}, "
        f"coarse_start={SB_COARSE_START}, fine_start={SB_FINE_START}, "
        f"N_stations={SB_N_STATIONS}, N_fine={SB_N_FINE})\n"
        f"{dump_path}",
        fontsize=9,
    )

    pairs = [
        (axes[0, 0], h_re, "H-pol  real",  "tab:blue"),
        (axes[0, 1], h_im, "H-pol  imag",  "tab:orange"),
        (axes[1, 0], v_re, "V-pol  real",  "tab:green"),
        (axes[1, 1], v_im, "V-pol  imag",  "tab:red"),
    ]

    for ax, data, label, color in pairs:
        ax.step(t, data, where='post', color=color, linewidth=0.8)
        ax.set_ylabel("Value (int8)")
        ax.set_title(label)
        ax.grid(True, alpha=0.3)
        # Mark time-block boundaries
        for tb in range(1, 12):
            ax.axvline(tb * 16, color='gray', linestyle='--', linewidth=0.5, alpha=0.6)

    for ax in axes[1, :]:
        ax.set_xlabel("Time sample index (0–191)")

    fig.tight_layout()
    out = "ct2_hbm_plot_out.png"
    plt.savefig(out, dpi=150)
    print(f"Saved: {out}")
    try:
        plt.show()
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    global PLOT_STATION, PLOT_FINE_CH

    ap = argparse.ArgumentParser(description="Decode and plot one station/fine-channel from a CT2 HBM dump")
    ap.add_argument("hbm_dump", help="HBM dump file (raw binary)")
    ap.add_argument("--station", type=int, default=None,
                    help=f"Station index to plot (default: {PLOT_STATION})")
    ap.add_argument("--fine-ch", type=int, default=None,
                    help=f"Relative fine channel to plot (default: {PLOT_FINE_CH})")
    ap.add_argument("--check-debug", action="store_true",
                    help="Decode debug fields (corr_ct2_din_v80 lines 705-777) and verify against expected values")
    args = ap.parse_args()

    if args.station is not None:
        PLOT_STATION = args.station
    if args.fine_ch is not None:
        PLOT_FINE_CH = args.fine_ch

    n_sg = math.ceil(SB_N_STATIONS / 4)
    print(f"Configuration:")
    print(f"  Dump file       : {args.hbm_dump}")
    print(f"  Words to load   : {N_WORDS_TO_READ:,}  ({N_WORDS_TO_READ * 4 / 1024**2:.1f} MiB)")
    print(f"  SB base addr    : 0x{SB_HBM_BASE_ADDR:08X}")
    print(f"  SB stations     : {SB_N_STATIONS}  (n_sg = {n_sg})")
    print(f"  SB fine channels: {SB_N_FINE}")
    print(f"  Plotting        : station={PLOT_STATION}, fine_ch_rel={PLOT_FINE_CH}")

    print(f"\nLoading dump ...")
    buf = load_dump(args.hbm_dump, N_WORDS_TO_READ)
    print(f"Loaded {len(buf):,} bytes.")

    print("Decoding ...")
    h_re, h_im, v_re, v_im = decode(buf)

    if args.check_debug:
        result = check_debug(h_re, h_im, v_re, v_im)
        print_debug_report(result)
        plot_debug_check(result, args.hbm_dump)
    else:
        print("Plotting ...")
        plot(h_re, h_im, v_re, v_im, args.hbm_dump)


if __name__ == "__main__":
    main()
