#!/usr/bin/env python3
"""
ct2_hbm_plot.py -- Read a CT2 HBM memory dump and plot / check one station &
                   fine channel.

NEW V80 LAYOUT (fine channels split across 4 HBM memories)
----------------------------------------------------------
get_ct2_HBM_addr_v80.vhd places each 256-byte block in one of 4 separate 4 GB
HBM regions, selected by the low 2 bits of the (per-coarse) fine channel:

    fc_group   = fine_channel mod 4              -> which of the 4 memories
    within_idx = fine_channel // 4 (relative)    -> fine index inside that memory

Within a single memory the 256-byte blocks form a 3-D array:

    block_index = within_idx * 12 * n_sg  +  time_block * n_sg  +  station_group
    byte_addr   = SB_base + 256 * block_index
  where
    n_sg          = ceil(SB_N_STATIONS / 4)
    station_group = STATION // 4
    within_idx    = (SB_FINE_START + fine_ch_rel)//4  -  SB_FINE_START//4
    fc_group      = (SB_FINE_START + fine_ch_rel) mod 4

So the captures live in a directory holding one file per fc_group:
    hbm0.bin  -> fine channels  0, 4, 8,  ...   (fine mod 4 == 0)
    hbm1.bin  -> fine channels  1, 5, 9,  ...   (fine mod 4 == 1)
    hbm2.bin  -> fine channels  2, 6, 10, ...   (fine mod 4 == 2)
    hbm3.bin  -> fine channels  3, 7, 11, ...   (fine mod 4 == 3)

(A single .bin file may still be passed; it is then treated as one combined
buffer with the legacy non-split addressing -- useful for old dumps.)

Within-block layout (corr_ct2_din_v80.vhd):
  8 AXI beats x 32 bytes, beat k covers time samples 2k and 2k+1:
    bytes [k*32 + 0  .. k*32+15]: time 2k,   station 0-3 each = {H.re, H.im, V.re, V.im}
    bytes [k*32 + 16 .. k*32+31]: time 2k+1, station 0-3

Debug data encoding (corr_ct2_din_v80.vhd lines 705-780):
  When i_insert_dbg='1', each 32-bit sample word packs field values:
    s_in_group == 0:  [9:0]=VC,  [21:10]=fine[11:0], [27:22]=time[5:0], [29:28]=mod3, [31:30]=849ms
    s_in_group != 0:  [11:0]=VC, [21:12]=fine[9:0],  [27:22]=time[5:0], [29:28]=mod3, [31:30]=849ms
  VC = virtual channel (= station index), fine = fineChannel_del1 (0-3455 absolute
  within coarse), time = timeStep (0-63), mod3 = frameCount_mod3 (0-2),
  849ms = free-running frame counter (unpredictable, not checked).
"""

import os
import math
import sys
import argparse
import struct
import numpy as np
import matplotlib.pyplot as plt

# ---------------------------------------------------------------------------
# Constants - adjust these for your simulation / hardware run
# ---------------------------------------------------------------------------

N_WORDS_TO_READ = 679477248      # max 32-bit words to read per file

# Subarray-beam parameters (must match the generic map in your *_top.vhd)
SB_HBM_BASE_ADDR = 0x00000000    # within-region byte address of the SB
SB_COARSE_START  = 0             # first coarse channel for this SB (0-511)
SB_FINE_START    = 0             # first fine channel within that coarse ch (0-3455)
SB_N_STATIONS    = 256           # total stations (virtual channels) in this SB
SB_N_FINE        = 3456          # total fine channels stored for this SB

# Which station and fine channel to plot (must be within the SB ranges above)
PLOT_STATION  = 0    # station index within the SB; maps 1-to-1 to virtual channel
PLOT_FINE_CH  = 0    # relative fine channel (0 = SB_COARSE_START*3456 + SB_FINE_START)

# Sentinel value for unwritten HBM locations
UNWRITTEN = 0xFEEDCAFE

N_FC_GROUPS = 4      # fine channels split across 4 memories (fine mod 4)


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

def load_one(path: str, n_words: int) -> np.ndarray:
    with open(path, 'rb') as fh:
        data = fh.read(n_words * 4)
    return np.frombuffer(data, dtype=np.uint8).copy()


def load_buffers(path: str, n_words: int):
    """
    Return (buffers, split) where:
      - if `path` is a directory, load hbm0.bin..hbm3.bin -> buffers[0..3], split=True
      - if `path` is a file, load it as buffers[0], split=False (legacy layout)
    """
    if os.path.isdir(path):
        buffers = []
        for g in range(N_FC_GROUPS):
            fname = os.path.join(path, f"hbm{g}.bin")
            if not os.path.isfile(fname):
                raise FileNotFoundError(f"expected {fname} for fc_group {g}")
            buffers.append(load_one(fname, n_words))
        return buffers, True
    else:
        return [load_one(path, n_words)], False


# ---------------------------------------------------------------------------
# Addressing
# ---------------------------------------------------------------------------

def block_byte_offset(t_in_block: int, s_in_group: int) -> int:
    """Byte offset within a 256-byte block for time t_in_block (0-15), station s_in_group (0-3)."""
    beat   = t_in_block // 2
    parity = t_in_block %  2
    return beat * 32 + parity * 16 + s_in_group * 4


def hbm_block_locate(fine_ch_rel, time_block, station_group, n_sg, sb_base, split):
    """
    Return (fc_group, byte_addr) for one 256-byte block.

    split=True : new V80 layout, fine channels spread across 4 memories.
                 fc_group selects the memory; within_idx = fine//4 indexes it.
    split=False: legacy single-memory layout (fine_ch_rel used directly).
    """
    if split:
        abs_fine   = SB_FINE_START + fine_ch_rel       # per-coarse fine channel
        fc_group   = abs_fine % N_FC_GROUPS
        within_idx = (abs_fine // N_FC_GROUPS) - (SB_FINE_START // N_FC_GROUPS)
    else:
        fc_group   = 0
        within_idx = fine_ch_rel
    addr = sb_base + 256 * (within_idx * 12 * n_sg + time_block * n_sg + station_group)
    return fc_group, addr


# ---------------------------------------------------------------------------
# Decode one station / fine channel -> 192-sample time series
# ---------------------------------------------------------------------------

def decode(buffers, split, station, fine_ch_rel):
    """
    Extract the 192-sample int8 time series (h_re, h_im, v_re, v_im) plus a
    status dict (out-of-buffer / unwritten block counts) for one
    (station, fine_ch_rel).
    """
    n_sg          = math.ceil(SB_N_STATIONS / 4)
    station_group = station // 4
    s_in_group    = station %  4

    n_time = 12 * 16
    h_re = np.zeros(n_time, dtype=np.int8)
    h_im = np.zeros(n_time, dtype=np.int8)
    v_re = np.zeros(n_time, dtype=np.int8)
    v_im = np.zeros(n_time, dtype=np.int8)
    oob = 0
    unwritten = 0

    for tb in range(12):
        fc_group, blk = hbm_block_locate(
            fine_ch_rel, tb, station_group, n_sg, SB_HBM_BASE_ADDR, split)
        buf = buffers[fc_group] if fc_group < len(buffers) else None

        if buf is None or blk + 256 > len(buf):
            oob += 1
            continue

        if int.from_bytes(bytes(buf[blk:blk + 4]), 'little') == UNWRITTEN:
            unwritten += 1

        for t in range(16):
            off  = blk + block_byte_offset(t, s_in_group)
            tidx = tb * 16 + t
            h_re[tidx] = np.int8(buf[off])
            h_im[tidx] = np.int8(buf[off + 1])
            v_re[tidx] = np.int8(buf[off + 2])
            v_im[tidx] = np.int8(buf[off + 3])

    return h_re, h_im, v_re, v_im, {'oob': oob, 'unwritten': unwritten}


# ---------------------------------------------------------------------------
# Debug field decode / check
# ---------------------------------------------------------------------------

def decode_debug_fields(h_re, h_im, v_re, v_im, s_in_group: int) -> tuple:
    b0 = int(h_re) & 0xFF
    b1 = int(h_im) & 0xFF
    b2 = int(v_re) & 0xFF
    b3 = int(v_im) & 0xFF
    if s_in_group == 0:
        vc   = b0 | ((b1 & 0x03) << 8)
        fine = ((b1 >> 2) & 0x3F) | ((b2 & 0x3F) << 6)
    else:
        vc   = b0 | ((b1 & 0x0F) << 8)
        fine = ((b1 >> 4) & 0x0F) | ((b2 & 0x3F) << 4)
    time_step   = ((b2 >> 6) & 0x03) | ((b3 & 0x0F) << 2)
    frame_mod3  = (b3 >> 4) & 0x03
    frame_849ms = (b3 >> 6) & 0x03
    return vc, fine, time_step, frame_mod3, frame_849ms


def check_debug(h_re, h_im, v_re, v_im, station, fine_ch_rel) -> dict:
    """Decode debug fields for all 192 samples and compare against expected."""
    s_in_group = station % 4
    abs_fine   = (SB_FINE_START + fine_ch_rel) % 3456
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

    t        = np.arange(n)
    vc_exp   = np.full(n, station, dtype=np.int32)
    fine_exp = np.full(n, abs_fine & fine_mask, dtype=np.int32)
    time_exp = (t % 64).astype(np.int32)
    mod3_exp = (t // 64).astype(np.int32)

    vc_ok   = vc_arr               == vc_exp
    fine_ok = (fine_arr & fine_mask) == fine_exp
    time_ok = time_arr             == time_exp
    mod3_ok = mod3_arr             == mod3_exp
    all_ok  = vc_ok & fine_ok & time_ok & mod3_ok

    return {
        'station': station, 'fine_ch_rel': fine_ch_rel,
        'vc': vc_arr, 'fine': fine_arr, 'time_step': time_arr,
        'frame_mod3': mod3_arr, 'frame_849ms': f849_arr,
        'vc_exp': vc_exp, 'fine_exp': fine_exp,
        'time_exp': time_exp, 'mod3_exp': mod3_exp,
        'vc_ok': vc_ok, 'fine_ok': fine_ok, 'time_ok': time_ok, 'mod3_ok': mod3_ok,
        'all_ok': all_ok, 'n_errors': int(np.sum(~all_ok)),
        'fine_bits': fine_bits,
    }


def print_debug_report(r: dict, max_detail: int = 20) -> None:
    n = len(r['vc'])
    print(f"  station={r['station']:4d} fine_ch_rel={r['fine_ch_rel']:4d} "
          f"(fine_abs={r['fine_exp'][0]}, {r['fine_bits']}-bit field): "
          f"FAIL {r['n_errors']}/{n}")
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
        print(f"    t={i:3d} (tb={i//16}, t_in_blk={i%16}): {', '.join(fields)}")
        shown += 1
        if shown >= max_detail:
            print(f"    ... ({r['n_errors'] - shown} more not shown)")
            break


# ---------------------------------------------------------------------------
# check-debug sweep across the fine-channel split
# ---------------------------------------------------------------------------

def available_fine_channels(buffers, split):
    """List of fine_ch_rel whose first time block fits inside the loaded buffer(s)."""
    n_sg = math.ceil(SB_N_STATIONS / 4)
    fines = []
    for fc in range(SB_N_FINE):
        fc_group, blk = hbm_block_locate(fc, 11, SB_N_STATIONS - 1, n_sg,
                                         SB_HBM_BASE_ADDR, split)  # last block of this fine
        if fc_group < len(buffers) and blk + 256 <= len(buffers[fc_group]):
            fines.append(fc)
    return fines


def run_check_debug(buffers, split, stations, max_detail, fines_override=None):
    """Sweep (station, fine_ch_rel) pairs, decode debug fields and verify."""
    fines = available_fine_channels(buffers, split)
    if fines_override is not None:
        fines = [fc for fc in fines_override if fc in set(fines)]
    if not fines:
        print("  No fine channels fit inside the loaded buffer(s) - nothing to check.")
        return None
    print(f"  Sweeping {len(stations)} station(s) x {len(fines)} fine channel(s) "
          f"(fine_ch_rel {fines[0]}..{fines[-1]})")
    if split:
        groups = sorted({(SB_FINE_START + fc) % N_FC_GROUPS for fc in fines})
        print(f"  fc_groups present: {groups}")

    n_checked = 0
    n_fail_series = 0
    n_sample_err = 0
    first_fail = None
    last_pass = None

    for st in stations:
        for fc in fines:
            h_re, h_im, v_re, v_im, status = decode(buffers, split, st, fc)
            if status['oob']:
                continue
            r = check_debug(h_re, h_im, v_re, v_im, st, fc)
            n_checked += 1
            if r['n_errors']:
                n_fail_series += 1
                n_sample_err += r['n_errors']
                if first_fail is None:
                    first_fail = r
                if n_fail_series <= max_detail:
                    print_debug_report(r, max_detail=8)
            else:
                last_pass = r

    print()
    print("=== check-debug result ===")
    print(f"  series checked : {n_checked}")
    print(f"  series failed  : {n_fail_series}")
    print(f"  sample errors  : {n_sample_err}")
    if n_checked == 0:
        print("  WARNING: nothing checked")
    elif n_fail_series == 0:
        print("  PASS")
    else:
        print("  FAIL")
    # Return a representative series to plot (first failing, else a passing one).
    return first_fail if first_fail is not None else last_pass


# ---------------------------------------------------------------------------
# Plotting
# ---------------------------------------------------------------------------

def plot_debug_check(r: dict, src: str) -> None:
    if r is None:
        return
    t = np.arange(len(r['vc']))
    status = "PASS" if r['n_errors'] == 0 else f"FAIL - {r['n_errors']} errors"
    fig, axes = plt.subplots(2, 2, figsize=(12, 7), sharex=True)
    fig.suptitle(
        f"CT2 debug check: station={r['station']}, fine_ch_rel={r['fine_ch_rel']}  ({status})\n{src}",
        fontsize=9)
    panels = [
        (axes[0, 0], r['vc'],        r['vc_exp'],   r['vc_ok'],   "Virtual channel (VC)"),
        (axes[0, 1], r['fine'],      r['fine_exp'], r['fine_ok'], f"Fine channel ({r['fine_bits']}-bit)"),
        (axes[1, 0], r['time_step'], r['time_exp'], r['time_ok'], "Time step (0-63)"),
        (axes[1, 1], r['frame_mod3'],r['mod3_exp'], r['mod3_ok'], "Frame mod-3 (0-2)"),
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
        ax.set_xlabel("Time sample index (0-191)")
    fig.tight_layout()
    out = "ct2_debug_check_out.png"
    plt.savefig(out, dpi=150)
    print(f"Saved: {out}")
    try:
        plt.show()
    except Exception:
        pass


def plot(h_re, h_im, v_re, v_im, station, fine_ch_rel, src: str) -> None:
    t = np.arange(len(h_re))
    fig, axes = plt.subplots(2, 2, figsize=(12, 7), sharex=True)
    fig.suptitle(
        f"CT2 HBM dump: station={station}, fine_ch_rel={fine_ch_rel}\n"
        f"(SB base=0x{SB_HBM_BASE_ADDR:08X}, coarse_start={SB_COARSE_START}, "
        f"fine_start={SB_FINE_START}, N_stations={SB_N_STATIONS}, N_fine={SB_N_FINE})\n{src}",
        fontsize=9)
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
        for tb in range(1, 12):
            ax.axvline(tb * 16, color='gray', linestyle='--', linewidth=0.5, alpha=0.6)
    for ax in axes[1, :]:
        ax.set_xlabel("Time sample index (0-191)")
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

    ap = argparse.ArgumentParser(
        description="Decode/plot/check a CT2 HBM dump (V80 4-memory fine-channel split)")
    ap.add_argument("hbm_path",
                    help="Directory with hbm0.bin..hbm3.bin (new split layout), "
                         "or a single .bin file (legacy single-memory layout)")
    ap.add_argument("--station", type=int, default=None,
                    help=f"Station index (default: {PLOT_STATION})")
    ap.add_argument("--fine-ch", type=int, default=None,
                    help=f"Relative fine channel (default: {PLOT_FINE_CH})")
    ap.add_argument("--check-debug", action="store_true",
                    help="Decode debug fields and verify against expected values")
    ap.add_argument("--all-stations", action="store_true",
                    help="check-debug: sweep every station (default: just --station)")
    ap.add_argument("--max-detail", type=int, default=20,
                    help="Max failing series to print in detail (default 20)")
    args = ap.parse_args()

    if args.station is not None:
        PLOT_STATION = args.station
    if args.fine_ch is not None:
        PLOT_FINE_CH = args.fine_ch

    n_sg = math.ceil(SB_N_STATIONS / 4)
    print("Configuration:")
    print(f"  Input           : {args.hbm_path}")
    print(f"  SB base addr    : 0x{SB_HBM_BASE_ADDR:08X}")
    print(f"  SB stations     : {SB_N_STATIONS}  (n_sg = {n_sg})")
    print(f"  SB fine channels: {SB_N_FINE}  (fine_start = {SB_FINE_START})")

    print("\nLoading dump ...")
    buffers, split = load_buffers(args.hbm_path, N_WORDS_TO_READ)
    if split:
        print(f"  Loaded 4 fc_group memories: " +
              ", ".join(f"hbm{g}={len(b):,}B" for g, b in enumerate(buffers)))
    else:
        print(f"  Loaded single buffer: {len(buffers[0]):,} bytes (legacy layout)")

    if args.check_debug:
        if args.all_stations:
            stations = list(range(SB_N_STATIONS))
        else:
            stations = [PLOT_STATION]
        fines_override = [PLOT_FINE_CH] if args.fine_ch is not None else None
        print("\nChecking debug fields ...")
        rep = run_check_debug(buffers, split, stations, args.max_detail,
                              fines_override=fines_override)
        plot_debug_check(rep, args.hbm_path)
    else:
        print(f"\nDecoding station={PLOT_STATION}, fine_ch_rel={PLOT_FINE_CH} ...")
        h_re, h_im, v_re, v_im, status = decode(buffers, split, PLOT_STATION, PLOT_FINE_CH)
        if status['oob']:
            print(f"  WARNING: {status['oob']}/12 time blocks outside the loaded buffer(s)")
        if status['unwritten']:
            print(f"  WARNING: {status['unwritten']}/12 time blocks unwritten (FEEDCAFE)")
        print("Plotting ...")
        plot(h_re, h_im, v_re, v_im, PLOT_STATION, PLOT_FINE_CH, args.hbm_path)


if __name__ == "__main__":
    main()
