#!/usr/bin/env python3
"""
ct2_check.py  --  Verify CT2 HBM contents against expected values.

Usage:
    python3 ct2_check.py <top_vhdl_file> <hbm_dump_file>

The top-level VHDL wrapper (e.g. ct2_test5_top.vhd) instantiates ct2_v80_tb
with a generic map containing the full test configuration.  This script parses
that file to extract the configuration, then verifies that the HBM dump file
(produced by the simulation) contains the expected data at every location that
should have been written.

HBM dump format (from HBM_axi_tbModel_multi.MemDump):
  Sparse format: one line per allocated 32-bit word, only for written addresses.
  Each line: <byte-addr-hex> <data-hex>
  Byte address is the full physical AXI address (up to 34 bits for 16 GB space).
  Unwritten addresses simply absent from the file (no sentinel value).

Data encoding in the testbench (ct2_v80_tb.vhd):
  For each of the 12 filterbank channels, at fine channel fc and
  time sample t_within_frame (0-63) within ct_frame f (0-2) and
  integration i:
    Hpol.re  = fc & 0xFF
    Hpol.im  = ((fc >> 8) & 0x0F) | ((i & 0x0F) << 4)
    Vpol.re  = (t_within_frame & 0x3F) | ((f & 0x03) << 6)
    Vpol.im  = vc & 0xFF

HBM address formula (from get_ct2_HBM_addr_v80.vhd, 4-buffer split):
  fc_group     = fc % 4   (= i_fine_channel[1:0], selects the 4 GB HBM region)
  within_region = SB_base + 256 * ((fine_ch_rel // 4) * 12 * n_sg  +  tb * n_sg  +  sg)
  physical_addr = (fc_group << 32) | within_region
  where:
    fine_ch_rel = (coarse_channel*3456 + fc) - (SB_coarseStart*3456 + SB_fineStart)
    n_sg        = ceil(SB_stations / 4)
    tb          = time_block (0..11, each covering 16 consecutive time samples)
    sg          = station_group = station // 4

Within-block layout (256 bytes = 8 AXI beats of 32 bytes each):
  Beat k (k=0..7) covers time samples 2k (even) and 2k+1 (odd).
    bytes [k*32 + 0  .. k*32 + 15]: time sample 2k,   4 stations
    bytes [k*32 + 16 .. k*32 + 31]: time sample 2k+1, 4 stations
  Within 16 bytes for 4 stations (station 0..3 of the group):
    bytes s*4+0: Hpol.re
    bytes s*4+1: Hpol.im
    bytes s*4+2: Vpol.re
    bytes s*4+3: Vpol.im
"""

import re
import sys
import math
import argparse
from pathlib import Path


# ---------------------------------------------------------------------------
# VHDL generic-map parser
# ---------------------------------------------------------------------------

def _strip_comments(text):
    """Remove VHDL single-line comments."""
    return re.sub(r'--[^\n]*', '', text)


def _find_generic_map(text):
    """Return the content between the outermost generic map ( ... )."""
    m = re.search(r'\bgeneric\s+map\s*\(', text, re.IGNORECASE)
    if not m:
        raise ValueError("No 'generic map' found in file")
    start = m.end()
    depth = 1
    i = start
    while i < len(text) and depth:
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
        i += 1
    return text[start:i - 1]


def _parse_hex_array(s):
    """Parse a VHDL array aggregate like (x"AABB", x"1122", ...) -> list[int]."""
    items = re.findall(r'x"([0-9A-Fa-f]+)"', s)
    return [int(h, 16) for h in items]


def parse_generic_map(vhdl_file):
    """
    Parse a ct2_*_top.vhd wrapper and return a dict of generic values.
    Keys match the generic names in ct2_v80_tb (lower-case, without g_ prefix).
    """
    text = _strip_comments(Path(vhdl_file).read_text())
    gm   = _find_generic_map(text)

    result = {}

    def _int(name):
        m = re.search(rf'\b{name}\s*=>\s*(\d+)', gm, re.IGNORECASE)
        if m:
            result[name.lower().lstrip('g_')] = int(m.group(1))

    def _hex16(name):
        m = re.search(rf'\b{name}\s*=>\s*x"([0-9A-Fa-f]+)"', gm, re.IGNORECASE)
        if m:
            result[name.lower().lstrip('g_')] = int(m.group(1), 16)

    def _string(name):
        m = re.search(rf'\b{name}\s*=>\s*"([^"]*)"', gm, re.IGNORECASE)
        if m:
            result[name.lower().lstrip('g_')] = m.group(1)

    def _array(name):
        m = re.search(rf'\b{name}\s*=>\s*(\(.*?\))', gm, re.IGNORECASE | re.DOTALL)
        if m:
            result[name.lower().lstrip('g_')] = _parse_hex_array(m.group(1))

    _int('g_VIRTUAL_CHANNELS')
    _int('g_CORRELATOR_CORES')
    _int('g_BAD_POLY_PACKETS')
    _int('g_SIM_DURATION_US')
    _hex16('g_BAD_POLY_VC')
    _string('g_HBM_DUMP_FILE')
    _array('g_SB_COUNTS')
    _array('g_DEMAP_TABLE')
    _array('g_SB_C0_TABLE')
    _array('g_SB_C1_TABLE')

    return result


# ---------------------------------------------------------------------------
# Configuration decoding
# ---------------------------------------------------------------------------

def decode_demap(demap_words, virtual_channels):
    """
    Return a list indexed by VC (0..virtual_channels-1) of dicts:
      {'valid', 'sky_freq_idx', 'station', 'sb_id'}
    Demap table has 2 words per group of 4 VCs.
    """
    result = []
    for vc in range(virtual_channels):
        group  = vc // 4
        word0  = demap_words[group * 2] if group * 2 < len(demap_words) else 0
        valid       = (word0 >> 31) & 1
        sky_freq    = (word0 >> 20) & 0x1FF
        station     = (word0 >>  8) & 0xFFF
        sb_id       = (word0 >>  0) & 0xFF
        result.append({'valid': valid, 'sky_freq_idx': sky_freq,
                       'station': station + (vc % 4), 'sb_id': sb_id})
    return result


def decode_sb_table(sb_words, correlator_id=0):
    """
    Return a list of SB dicts from a flat 4-words-per-SB array.
    """
    sbs = []
    n = len(sb_words) // 4
    for i in range(n):
        w0, w1, w2, w3 = sb_words[i*4:(i+1)*4]
        sbs.append({
            'stations':     w0 & 0xFFFF,
            'coarse_start': (w0 >> 16) & 0xFFFF,
            'fine_start':   w1 & 0xFFFF,
            'num_fine':     w2 & 0xFFFFFF,
            'fine_per_int': (w2 >> 24) & 0x7F,
            'int_mode_849': (w2 >> 31) & 1,
            'hbm_base':     w3,
            'correlator':   correlator_id,
        })
    return sbs


# ---------------------------------------------------------------------------
# HBM dump loader
# ---------------------------------------------------------------------------

def load_dump(filename):
    """
    Load the sparse HBM dump file into a dict mapping byte-address -> 32-bit word.

    File format (from HBM_axi_tbModel_multi.MemDump):
      <byte-addr-hex> <data-hex>   (one 32-bit word per line)

    Only addresses that were actually written appear in the file.
    Addresses not in the returned dict were never written.
    """
    dump = {}
    with open(filename) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) != 2:
                continue
            addr = int(parts[0], 16)
            word = int(parts[1], 16)
            dump[addr] = word
    return dump


def dump_read_byte(dump, byte_addr):
    """Return the byte at byte_addr from a sparse dump dict, or None if unwritten."""
    word_addr = byte_addr & ~3
    word = dump.get(word_addr)
    if word is None:
        return None
    byte_in_word = byte_addr & 3
    return (word >> (byte_in_word * 8)) & 0xFF


# ---------------------------------------------------------------------------
# Expected-value computation
# ---------------------------------------------------------------------------

def expected_sample(vc, fine_ch, time_sample_849ms, integration=0):
    """
    Return (Hpol_re, Hpol_im, Vpol_re, Vpol_im) for one sample.
    time_sample_849ms: 0..191 (16 time-samples per time-block, 12 time-blocks)
    """
    t_within_frame = time_sample_849ms % 64          # packets_sent (0-63)
    ct_frame       = (time_sample_849ms // 64) & 3   # fb_ctFrame   (0-2)
    hpol_re = fine_ch & 0xFF
    hpol_im = ((fine_ch >> 8) & 0x0F) | ((integration & 0x0F) << 4)
    vpol_re = (t_within_frame & 0x3F) | ((ct_frame & 0x03) << 6)
    vpol_im = vc & 0xFF
    return hpol_re, hpol_im, vpol_re, vpol_im


def block_byte_offset(time_within_block, station_within_group):
    """
    Byte offset within a 256-byte HBM block for a given
    time-sample-within-block (0..15) and station-within-group (0..3).

    Layout (from corr_ct2_din_v80.vhd bufWrData packing):
      Beat k (32 bytes) covers time samples 2k and 2k+1.
        Lower 16 bytes: time 2k,   stations 0-3 each with {Hpol.re,Hpol.im,Vpol.re,Vpol.im}
        Upper 16 bytes: time 2k+1, stations 0-3
    """
    beat     = time_within_block // 2   # 0..7
    parity   = time_within_block %  2   # 0=even, 1=odd
    return beat * 32 + parity * 16 + station_within_group * 4


# ---------------------------------------------------------------------------
# Main checker
# ---------------------------------------------------------------------------

def check(cfg, dump):
    """
    Returns (n_blocks_checked, n_blocks_bad, n_samples_bad, n_unwritten).
    Prints details of the first few mismatches.

    dump is a dict mapping byte_address (int) -> 32-bit word (int),
    as returned by load_dump().  Missing addresses were never written.
    Physical address layout (4-buffer split):
      bits 33:32 = fc_group = fc % 4  (selects the 4 GB HBM region)
      bits 31:0  = SB_base + 256 * (fine_ch_rel*12*n_sg + tb*n_sg + sg)
    """
    demap_words  = cfg.get('demap_table', [0])
    sb_c0_words  = cfg.get('sb_c0_table', [0])
    sb_c1_words  = cfg.get('sb_c1_table', [0])
    sb_counts    = cfg.get('sb_counts',   [1, 0, 0, 0])
    virt_chs     = cfg.get('virtual_channels', 12)

    demap = decode_demap(demap_words, virt_chs)

    # Build mapping: sb_id -> sb_config
    sb_by_id = {}
    for corr in range(2):
        sb_arr = sb_c0_words if corr == 0 else sb_c1_words
        sbs    = decode_sb_table(sb_arr, corr)
        id_base = 128 * corr
        for idx, sb in enumerate(sbs):
            sb_by_id[id_base + idx] = sb

    n_blocks_checked = 0
    n_blocks_bad     = 0
    n_samples_bad    = 0
    n_unwritten      = 0
    MAX_DETAIL       = 20

    for vc in range(virt_chs):
        dm = demap[vc]
        if not dm['valid']:
            continue
        sb_id = dm['sb_id']
        if sb_id not in sb_by_id:
            print(f"  WARNING: VC {vc} refers to SB_id {sb_id} not in SB table")
            continue
        sb = sb_by_id[sb_id]

        station        = dm['station']   # station index within SB (vc-specific)
        sky_freq_idx   = dm['sky_freq_idx']
        coarse_start   = sb['coarse_start']
        fine_start     = sb['fine_start']
        num_fine       = sb['num_fine']
        stations_total = sb['stations']
        hbm_base       = sb['hbm_base']
        n_sg           = math.ceil(stations_total / 4)

        station_group  = station // 4
        s_in_group     = station %  4

        for fc in range(3456):
            # Compute relative fine_channel index within the SB
            fine_ch_abs = sky_freq_idx * 3456 + fc
            fine_ch_sb  = (coarse_start * 3456 + fine_start)
            fine_ch_rel = fine_ch_abs - fine_ch_sb
            if fine_ch_rel < 0 or fine_ch_rel >= num_fine:
                continue

            # fc_group selects the 4 GB HBM region (= i_fine_channel[1:0])
            # i_fine_channel is the per-coarse fine channel index (0..3455), i.e. fc.
            fc_group = fc & 3

            for time_block in range(12):
                within_region = (hbm_base +
                                 256 * ((fine_ch_rel // 4) * 12 * n_sg
                                        + time_block * n_sg
                                        + station_group))
                # Physical address: fc_group occupies bits 33:32
                phys_addr = (fc_group << 32) | (within_region & 0xFFFFFFFF)

                # Check whether any byte of this block was written
                if dump.get(phys_addr & ~3) is None:
                    n_unwritten += 1
                    continue

                n_blocks_checked += 1
                block_bad = False

                for t_in_block in range(16):
                    time_849ms = time_block * 16 + t_in_block
                    exp = expected_sample(vc, fc, time_849ms, integration=0)
                    off = block_byte_offset(t_in_block, s_in_group)

                    act = tuple(
                        dump_read_byte(dump, phys_addr + off + b)
                        for b in range(4)
                    )
                    if None in act:
                        # Word containing this sample was not written
                        n_samples_bad += 1
                        block_bad = True
                        if n_samples_bad <= MAX_DETAIL:
                            print(f"  MISSING   addr=0x{phys_addr:010X}+0x{off:02X}"
                                  f" vc={vc} fc={fc} tb={time_block} t={t_in_block}"
                                  f" fc_grp={fc_group} st_grp={station_group} s_in={s_in_group}")
                        continue

                    if act != exp:
                        n_samples_bad += 1
                        block_bad = True
                        if n_samples_bad <= MAX_DETAIL:
                            print(f"  MISMATCH  addr=0x{phys_addr:010X}+0x{off:02X}"
                                  f" vc={vc} fc={fc} tb={time_block} t={t_in_block}"
                                  f" fc_grp={fc_group} st_grp={station_group} s_in={s_in_group}"
                                  f"  expected=({exp[0]:02X},{exp[1]:02X},"
                                  f"{exp[2]:02X},{exp[3]:02X})"
                                  f"  actual=({act[0]:02X},{act[1]:02X},"
                                  f"{act[2]:02X},{act[3]:02X})")

                if block_bad:
                    n_blocks_bad += 1

    return n_blocks_checked, n_blocks_bad, n_samples_bad, n_unwritten


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="Verify CT2 HBM dump against expected values")
    ap.add_argument('vhdl_top',  help="Top-level VHDL wrapper file (e.g. ct2_test5_top.vhd)")
    ap.add_argument('hbm_dump',  help="HBM dump file produced by simulation")
    args = ap.parse_args()

    print(f"Parsing configuration from: {args.vhdl_top}")
    cfg = parse_generic_map(args.vhdl_top)

    print(f"  virtual_channels = {cfg.get('virtual_channels', '?')}")
    print(f"  hbm_dump_file    = {cfg.get('hbm_dump_file', '?')}")

    print(f"\nLoading HBM dump: {args.hbm_dump}")
    dump = load_dump(args.hbm_dump)
    print(f"  {len(dump)} 32-bit words loaded ({len(dump)*4} bytes)")

    print("Checking ...\n")
    checked, bad_blocks, bad_samples, unwritten = check(cfg, dump)

    print()
    print("=== ct2_check result ===")
    print(f"  Blocks checked   : {checked}")
    print(f"  Unwritten blocks : {unwritten}")
    print(f"  Bad blocks       : {bad_blocks}")
    print(f"  Bad samples      : {bad_samples}")
    if bad_blocks == 0 and bad_samples == 0:
        if checked == 0:
            print("  WARNING: no blocks were checked (simulation may not have run long enough)")
        else:
            print("  PASS")
    else:
        print("  FAIL")


if __name__ == '__main__':
    main()
