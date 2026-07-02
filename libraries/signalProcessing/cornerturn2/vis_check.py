#!/usr/bin/env python3
"""
vis_check.py  --  Verify correlator visibility HBM contents against an
                  independent reference model.

Usage:
    python3 vis_check.py <top_vhdl_file> <vis_dump_file> [options]

The top-level VHDL wrapper (e.g. ct2_test5_top.vhd) instantiates ct2_v80_tb
with a generic map containing the full test configuration.  This script parses
that file (reusing ct2_check.py's parser), reconstructs the correlator input
analytically from the testbench's deterministic data encoding, computes the
expected visibilities + TCI/DV exactly as the firmware does, lays them out in
the visibility-HBM byte layout, and compares against the dump produced by the
simulation (HBM_axi_tbModel_multi.MemDump).

------------------------------------------------------------------------------
Reference for the visibility output format (RTL, source of truth)
------------------------------------------------------------------------------
The visibility HBM is a *sequential circular buffer*.  correlator_HBM.vhd
increments a write pointer (fifo_wr_ptr) by one cell per cell produced:

  cell N visibilities : byte address  N * 8192          (region bits 31:28 = 0)
  cell N TCI/DV       : byte address  0x1000_0000 + N*512   (256 MB offset)

A "cell" is a 16x16 dual-pol station block = 256 elements x 32 bytes = 8192 B.
Element e (e = row*16 + col, row-major) holds the 4 polarisation products of
the station pair (row, col), as 8 x fp32:

  offset e*32 + (p1*2 + p2)*8 + 0 : Re( vis[p1,p2] )  (float32)
  offset e*32 + (p1*2 + p2)*8 + 4 : Im( vis[p1,p2] )  (float32)

where p1 = row-station polarisation, p2 = col-station polarisation, and
  vis[p1,p2] = sum over (fine channels, time samples) of
               sample(row, p1) * conj(sample(col, p2))
(matching ska_low_cbf_model.correlator_model.run_correlation).  The stored
value is the integer accumulation converted to fp32 and scaled by
total_samples/valid_samples (vis2fp.vhd).  We accumulate exactly in integer
arithmetic and convert to fp32 once, matching the hardware accumulator.

TCI/DV (centroid_divider.vhd / correlator_model):
  byte offset 2*e + 0 : DV (FD)  = round(255 * sqrt(valid_count/total_samples))
  byte offset 2*e + 1 : TCI       = round((256/t_i_max)*valid_weight/valid_count
                                          - 128 + tci_correction)
  t_i_max = 192 (long, tci_correction=1) or 64 (short, tci_correction=2).

Cell production order (replicated from run_correlation), per subarray-beam:
  for output_channel in range(N_fine // N_fine_integrate):
    for output_time  in range(time_groups):       # 1 (192-sample) or 3 (64)
      for tile_row in range(ceil(N_stations/256)):
        for tile_col in range(tile_row+1):
          for cell_row in range(cell_rows):
            for cell_col in range(cell_row+1 if diag else 16):
              emit one cell
The integration counter advances once per 849 ms frame; visibility values
depend on it through the Hpol.im encoding, so each integration differs.
"""

import os
import sys
import math
import struct
import argparse

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ct2_check  # noqa: E402  (sibling module, parser reuse)


# ---------------------------------------------------------------------------
# Configuration decoding
# ---------------------------------------------------------------------------

def decode_sb_table_full(sb_words):
    """
    Decode the subarray-beam table (4 words per entry) into a list of dicts,
    matching ska_low_cbf_model.correlator_model.subarray_beam_unpack.
    """
    sbs = []
    n = len(sb_words) // 4
    for i in range(n):
        w0, w1, w2, w3 = sb_words[i * 4:(i + 1) * 4]
        coarse_start = (w0 >> 16) & 0xFFFF
        if coarse_start > 32767:
            coarse_start -= 32768
            output_disable = 1
        else:
            output_disable = 0
        n_time_bit = (w2 >> 31) & 1
        n_time_integrate = 192 if n_time_bit == 1 else 64
        sbs.append({
            'n_stations':       w0 & 0xFFFF,
            'coarse_start':     coarse_start,
            'output_disable':   output_disable,
            'fine_start':       w1 & 0xFFFF,
            'n_fine':           w2 & 0xFFFFFF,
            'n_fine_integrate': (w2 >> 24) & 0x7F,
            'n_time_integrate': n_time_integrate,
            'hbm_base':         w3,
        })
    return sbs


def build_station_map(demap, sb_index):
    """
    Return {station_index_within_sb: {'vc', 'sky_freq_idx'}} for the given SB.
    demap is the per-VC list from ct2_check.decode_demap.
    For correlator 0 the demap sb_id equals the SB table index directly.
    """
    station_map = {}
    for vc, dm in enumerate(demap):
        if not dm['valid']:
            continue
        if dm['sb_id'] != sb_index:
            continue
        station_map[dm['station']] = {'vc': vc, 'sky_freq_idx': dm['sky_freq_idx']}
    return station_map


# ---------------------------------------------------------------------------
# Analytic reconstruction of the correlator input samples
# ---------------------------------------------------------------------------

def _s8(x):
    """Interpret the low 8 bits of x as a signed byte."""
    x &= 0xFF
    return x - 256 if x >= 128 else x


def station_samples(station_info, sb, fine_rel_range, time_indices, integration):
    """
    Build the complex sample array for one station over the requested fine
    channels and time samples.

    Returns (samp, valid) where:
      samp  : complex128 array (2 pol, n_fine, n_time), pol 0 = Hpol, 1 = Vpol.
      valid : int array (n_fine, n_time), 1 = usable sample, 0 = RFI.

    The values are exactly those generated by the testbench filterbank emulator
    (see ct2_check.expected_sample), reconstructed for the (vc, fine, time) that
    the corner turn would have stored for this station.

    RFI flagging (matches the firmware): a sample is flagged as RFI if ANY of
    its four data bytes (Hpol.re, Hpol.im, Vpol.re, Vpol.im) equals 0x80, the
    most-negative signed byte.  RFI samples are dropped from the correlation
    sum and from the valid-sample / centroid counts.  (This is independent of
    the bad_poly flag, which only propagates to the output packets.)
    """
    vc = station_info['vc']
    sky = station_info['sky_freq_idx']
    n_fine = len(fine_rel_range)
    n_time = len(time_indices)
    out = np.zeros((2, n_fine, n_time), dtype=np.complex128)

    # Per-fine-channel Hpol bytes, and whether Hpol contributes an RFI marker.
    h_rfi = np.zeros(n_fine, dtype=bool)
    # Per-coarse fine-channel index for each relative fine channel:
    #   fc = coarse_start*3456 + fine_start + fine_rel - sky*3456
    for fi, fine_rel in enumerate(fine_rel_range):
        fc = sb['coarse_start'] * 3456 + sb['fine_start'] + fine_rel - sky * 3456
        if fc < 0 or fc > 3455:
            # No data was generated for this fine channel; leave as zero.
            continue
        hpol_re_b = fc & 0xFF
        hpol_im_b = ((fc >> 8) & 0x0F) | ((integration & 0x0F) << 4)
        out[0, fi, :] = complex(_s8(hpol_re_b), _s8(hpol_im_b))
        if hpol_re_b == 0x80 or hpol_im_b == 0x80:
            h_rfi[fi] = True

    # Per-time-sample Vpol bytes, and whether Vpol contributes an RFI marker.
    v_rfi = np.zeros(n_time, dtype=bool)
    vpol_im_b = vc & 0xFF
    for ti, t in enumerate(time_indices):
        vpol_re_b = (t % 64) | (((t // 64) & 0x03) << 6)
        out[1, :, ti] = complex(_s8(vpol_re_b), _s8(vpol_im_b))
        if vpol_re_b == 0x80 or vpol_im_b == 0x80:
            v_rfi[ti] = True

    # A sample is valid unless either polarisation contributes an RFI marker.
    valid = (~(h_rfi[:, np.newaxis] | v_rfi[np.newaxis, :])).astype(np.int64)
    return out, valid


# ---------------------------------------------------------------------------
# Per-integration correlation / TCI / DV
# ---------------------------------------------------------------------------

def compute_integration(sb, station_map, output_channel, output_time,
                        time_groups, integration):
    """
    Compute the visibility matrix and TCI/DV for one (output_channel,
    output_time) of one integration.

    Returns (vis, tci, fd) where:
      vis : complex128 array (n16, n16, 2, 2)   -- normalised visibilities
      tci : int array      (n16, n16)
      fd  : int array      (n16, n16)
    n16 = ceil(N_stations/16)*16 (firmware pads cells to 16 stations).
    """
    n_stations = int(sb['n_stations'])
    n16 = int(math.ceil(n_stations / 16) * 16)
    n_fpi = int(sb['n_fine_integrate'])
    n_time_integrate = int(sb['n_time_integrate'])

    # Fine channels (relative to SB) integrated for this output channel.
    fine_rel_range = range(output_channel * n_fpi, (output_channel + 1) * n_fpi)

    # Time samples integrated for this output time group.
    if time_groups == 1:
        time_start, n_time_group = 0, 192
        t_i_max, tci_correction = 192, 1
    else:
        time_start, n_time_group = output_time * 64, 64
        t_i_max, tci_correction = 64, 2
    time_indices = list(range(time_start, time_start + n_time_group))
    # Index within the integration window (0 .. n_time_group-1) for the centroid.
    time_weight = np.arange(n_time_group, dtype=np.int64)

    total_samples = n_time_integrate * n_fpi

    # Build sample arrays for every station present: shape (2, n_fine, n_time).
    samp = {}
    valid = {}
    for s in range(n_stations):
        if s in station_map:
            samp[s], valid[s] = station_samples(station_map[s], sb,
                                                fine_rel_range, time_indices,
                                                integration)
        else:
            samp[s] = np.zeros((2, len(fine_rel_range), n_time_group),
                               dtype=np.complex128)
            valid[s] = np.zeros((len(fine_rel_range), n_time_group), dtype=np.int64)

    vis = np.zeros((n16, n16, 2, 2), dtype=np.complex128)
    tci = np.zeros((n16, n16), dtype=np.int64)
    fd = np.zeros((n16, n16), dtype=np.int64)

    for s1 in range(n_stations):
        # The firmware fills full 16x16 cells, so station2 runs to the cell
        # boundary above station1 (capped at N_stations).
        s2_max = min(int(math.ceil((s1 + 1) / 16) * 16), n_stations)
        for s2 in range(s2_max):
            v1 = valid[s1]
            v2 = valid[s2]
            vmask = v1 * v2  # (n_fine, n_time)
            valid_count = int(vmask.sum())
            if valid_count == 0:
                continue
            valid_weight = int((vmask * time_weight[np.newaxis, :]).sum())

            # Correlation: sum over (fine, time) of samp(s1,p1)*conj(samp(s2,p2)).
            # Accumulate exactly: int8 products fit comfortably in int64.
            for p1 in range(2):
                for p2 in range(2):
                    prod = samp[s1][p1] * np.conj(samp[s2][p2]) * vmask
                    acc = prod.sum()
                    re = int(round(acc.real))
                    im = int(round(acc.imag))
                    # int -> fp32, then scale by total/valid (vis2fp).
                    scale = total_samples / valid_count
                    vis[s1, s2, p1, p2] = complex(
                        np.float32(np.float32(re) * np.float32(scale)),
                        np.float32(np.float32(im) * np.float32(scale)))

            tci[s1, s2] = int(round((256.0 / t_i_max) * valid_weight / valid_count
                                    - 128 + tci_correction))
            fd[s1, s2] = int(round(255.0 * math.sqrt(valid_count / total_samples)))

    return vis, tci, fd


# ---------------------------------------------------------------------------
# Cell production sequence
# ---------------------------------------------------------------------------

def cell_descriptors(sb, max_cells):
    """
    Yield cell descriptors in the exact order the firmware writes them, up to
    max_cells cells (looping over integrations).  Each descriptor is a dict:
      integration, output_channel, output_time,
      row_first_station, col_first_station
    """
    n_stations = int(sb['n_stations'])
    n_fpi = int(sb['n_fine_integrate'])
    n_fine = int(sb['n_fine'])
    n_output_channels = n_fine // n_fpi if n_fpi else 0
    time_groups = 1 if sb['n_time_integrate'] == 192 else 3
    tile_rows = int(math.ceil(n_stations / 256)) if n_stations else 0

    count = 0
    integration = 0
    while count < max_cells:
        for oc in range(n_output_channels):
            for ot in range(time_groups):
                for tile_row in range(tile_rows):
                    for tile_col in range(tile_row + 1):
                        if tile_row < (tile_rows - 1):
                            cell_rows = 16
                        else:
                            rem = n_stations % 256
                            if rem == 0:
                                rem = 256
                            cell_rows = int(math.ceil(rem / 16))
                        for cell_row in range(cell_rows):
                            if tile_row == tile_col:
                                cell_columns = cell_row + 1
                            else:
                                cell_columns = 16
                            for cell_col in range(cell_columns):
                                yield {
                                    'integration': integration,
                                    'output_channel': oc,
                                    'output_time': ot,
                                    'row_first_station': tile_row * 256 + cell_row * 16,
                                    'col_first_station': tile_col * 256 + cell_col * 16,
                                }
                                count += 1
                                if count >= max_cells:
                                    return
        integration += 1
        if n_output_channels == 0 or tile_rows == 0:
            return  # nothing to produce; avoid infinite loop


# ---------------------------------------------------------------------------
# Dump access helpers
# ---------------------------------------------------------------------------

VIS_REGION_BASE = 0x0000_0000
TCI_REGION_BASE = 0x1000_0000
CELL_VIS_BYTES = 8192
CELL_TCI_BYTES = 512


def dump_float32(dump, byte_addr):
    """Return the float32 stored at byte_addr (4-byte aligned), or None."""
    word = dump.get(byte_addr)
    if word is None:
        return None
    return struct.unpack('<f', struct.pack('<I', word & 0xFFFFFFFF))[0]


def written_cell_indices(dump):
    """Set of cell indices that have any visibility data written."""
    cells = set()
    for addr in dump:
        if addr < TCI_REGION_BASE:
            cells.add(addr // CELL_VIS_BYTES)
    return sorted(cells)


# ---------------------------------------------------------------------------
# Diagnostics
#
# The first dump is the moment to settle the conventions that the model and the
# RTL might disagree on (conjugation direction, station row/col ordering,
# polarisation-product order, and any overall scale).  When a cell mismatches,
# diagnose_cell() tries every combination of those transforms against the
# actual data and reports which one matches, so a single sim run resolves them.
# ---------------------------------------------------------------------------

def read_actual_cell(dump, cell_index):
    """
    Read one cell's actual data into arrays.
    Returns (vis[16,16,2,2] complex (nan where missing),
             fd[16,16] int (-1 missing), tci[16,16] int (-1 missing)).
    Indexing follows the assumed layout: element e=row*16+col, product (p1,p2).
    """
    vis_base = VIS_REGION_BASE + cell_index * CELL_VIS_BYTES
    tci_base = TCI_REGION_BASE + cell_index * CELL_TCI_BYTES
    av = np.full((16, 16, 2, 2), np.nan, dtype=np.complex128)
    afd = np.full((16, 16), -1, dtype=np.int64)
    atci = np.full((16, 16), -1, dtype=np.int64)
    for row in range(16):
        for col in range(16):
            e = row * 16 + col
            for p1 in range(2):
                for p2 in range(2):
                    off = e * 32 + (p1 * 2 + p2) * 8
                    re = dump_float32(dump, vis_base + off)
                    im = dump_float32(dump, vis_base + off + 4)
                    if re is not None and im is not None:
                        av[row, col, p1, p2] = complex(re, im)
            fd = ct2_check.dump_read_byte(dump, tci_base + 2 * e)
            tc = ct2_check.dump_read_byte(dump, tci_base + 2 * e + 1)
            if fd is not None:
                afd[row, col] = fd
            if tc is not None:
                atci[row, col] = tc
    return av, afd, atci


def expected_cell_block(desc, sb, station_map, time_groups):
    """Expected vis[16,16,2,2], fd[16,16], tci[16,16] for one cell descriptor."""
    vis, tci, fd = compute_integration(
        sb, station_map, desc['output_channel'], desc['output_time'],
        time_groups, desc['integration'])
    n16 = vis.shape[0]
    rfs, cfs = desc['row_first_station'], desc['col_first_station']
    ev = np.zeros((16, 16, 2, 2), dtype=np.complex128)
    efd = np.zeros((16, 16), dtype=np.int64)
    etci = np.zeros((16, 16), dtype=np.int64)
    for row in range(16):
        for col in range(16):
            sr, sc = rfs + row, cfs + col
            if sr < n16 and sc < n16:
                ev[row, col] = vis[sr, sc]
                efd[row, col] = int(fd[sr, sc]) & 0xFF
                etci[row, col] = int(tci[sr, sc]) & 0xFF
    return ev, efd, etci


def _transform(ev, transpose_st, swap_pol, conj):
    e = ev
    if transpose_st:
        e = np.transpose(e, (1, 0, 2, 3))
    if swap_pol:
        e = np.transpose(e, (0, 1, 3, 2))
    if conj:
        e = np.conj(e)
    return e


def diagnose_cell(av, ev, vis_rtol, vis_atol):
    """
    Try each (station-transpose, pol-swap, conjugate) combination against the
    actual visibilities and print a ranked report, including the best-fit
    complex scale for the leading candidate.
    """
    finite = np.isfinite(av.real) & np.isfinite(av.imag)
    if not finite.any():
        print("  [diagnose] no actual visibility data in this cell")
        return
    a = av[finite]
    print("\n  === visibility convention diagnosis (first mismatching cell) ===")
    print("  transform                         match@1.0   best|scale|   match@scale")
    results = []
    for tr in (0, 1):
        for sp in (0, 1):
            for cj in (0, 1):
                e = _transform(ev, tr, sp, cj)[finite]
                # match fraction at unit scale
                tol = vis_atol + vis_rtol * np.abs(e)
                m1 = np.mean(np.abs(a - e) <= tol) if e.size else 0.0
                # best-fit complex least-squares scale a ~= s*e
                denom = np.vdot(e, e)
                if abs(denom) > 0:
                    s = np.vdot(e, a) / denom
                else:
                    s = 0.0 + 0.0j
                es = s * e
                tol2 = vis_atol + vis_rtol * np.abs(es)
                ms = np.mean(np.abs(a - es) <= tol2) if e.size else 0.0
                name = (("T" if tr else "-") + ("P" if sp else "-") +
                        ("C" if cj else "-"))
                label = {
                    "---": "identity (row*conj(col))",
                    "--C": "conjugate",
                    "-P-": "pol-swap",
                    "-PC": "pol-swap + conj",
                    "T--": "station-transpose",
                    "T-C": "transpose + conj  (= Hermitian of cols)",
                    "TP-": "transpose + pol-swap",
                    "TPC": "transpose + pol-swap + conj (full Hermitian)",
                }[name]
                results.append((m1, ms, abs(s), s, label))
    results.sort(key=lambda r: (max(r[0], r[1])), reverse=True)
    for m1, ms, absS, s, label in results:
        print(f"  {label:34s} {m1*100:6.1f}%    {absS:9.4f}   {ms*100:6.1f}%")
    # The visibility matrix is Hermitian: V[r,c,p1,p2] = conj(V[c,r,p2,p1]).
    # So "transpose + pol-swap + conj" is a symmetry, and the eight transforms
    # collapse into two equivalence classes (with/without an extra conjugate).
    # Any transform tied at the top is equally valid to adopt.
    print("  (note: the matrix is Hermitian, so transpose+pol-swap+conj is a "
          "symmetry;\n   transforms tie within two equivalence classes.)")
    best = results[0]
    print(f"\n  best candidate: '{best[4]}'  "
          f"(match@1.0={best[0]*100:.1f}%, scale={best[3]:.4f}, "
          f"match@scale={best[1]*100:.1f}%)")
    if best[0] > 0.98:
        print("  -> matches at unit scale: adopt this transform in the checker.")
    elif best[1] > 0.98:
        print(f"  -> matches after scaling by {best[3]:.4f}; normalisation differs "
              f"(check vis2fp total/valid scaling).")
    else:
        print("  -> no clean match; inspect the per-product detail above.")


def diagnose_meta(afd, atci, efd, etci, tci_tol):
    """Check whether FD/TCI byte order (even=FD,odd=TCI) is right or swapped."""
    fin = (afd >= 0) & (atci >= 0)
    if not fin.any():
        print("  [diagnose] no actual TCI/DV data in this cell")
        return
    def frac(actA, expA, actB, expB):
        okA = np.abs(actA[fin] - expA[fin]) <= tci_tol
        okB = np.array([_wrap_diff(int(x), int(y)) <= tci_tol
                        for x, y in zip(actB[fin], expB[fin])])
        return np.mean(okA & okB)
    # assumed: even byte = FD, odd byte = TCI
    m_assumed = frac(afd, efd, atci, etci)
    # swapped: even byte = TCI, odd byte = FD
    m_swapped = frac(afd, etci, atci, efd)
    print("\n  === TCI/DV byte-order diagnosis ===")
    print(f"  even=FD, odd=TCI (assumed): {m_assumed*100:6.1f}%")
    print(f"  even=TCI, odd=FD (swapped): {m_swapped*100:6.1f}%")
    if m_swapped > m_assumed and m_swapped > 0.9:
        print("  -> TCI/DV byte order appears swapped relative to the checker.")


# ---------------------------------------------------------------------------
# Checking
# ---------------------------------------------------------------------------

def _update_worst(worst, key, res, loc, exp, act):
    """Track the largest residual seen for a quantity, regardless of pass/fail."""
    if res > worst[key]['res']:
        worst[key] = {'res': res, 'loc': loc, 'exp': exp, 'act': act}


def check_cell(dump, desc, sb, station_map, time_groups,
               vis_rtol, vis_atol, tci_tol, max_detail, detail_count, worst):
    """
    Check one cell.  Returns (n_re_bad, n_im_bad, n_meta_bad, n_missing).
    `worst` is updated in place with the largest residual seen.
    """
    vis, tci, fd = compute_integration(
        sb, station_map, desc['output_channel'], desc['output_time'],
        time_groups, desc['integration'])

    n16 = vis.shape[0]
    rfs = desc['row_first_station']
    cfs = desc['col_first_station']

    cell_index = desc['cell_index']
    vis_base = VIS_REGION_BASE + cell_index * CELL_VIS_BYTES
    tci_base = TCI_REGION_BASE + cell_index * CELL_TCI_BYTES

    n_re_bad = 0
    n_im_bad = 0
    n_meta_bad = 0
    n_missing = 0

    for row in range(16):
        for col in range(16):
            srow = rfs + row
            scol = cfs + col
            e = row * 16 + col
            # Expected visibility (zero if station out of range).
            if srow < n16 and scol < n16:
                exp_vis = vis[srow, scol]
            else:
                exp_vis = np.zeros((2, 2), dtype=np.complex128)

            for p1 in range(2):
                for p2 in range(2):
                    off = e * 32 + (p1 * 2 + p2) * 8
                    act_re = dump_float32(dump, vis_base + off)
                    act_im = dump_float32(dump, vis_base + off + 4)
                    exp_re = float(exp_vis[p1, p2].real)
                    exp_im = float(exp_vis[p1, p2].imag)
                    if act_re is None or act_im is None:
                        n_missing += 1
                        continue
                    loc = f"cell={cell_index} e={e} row_st={srow} col_st={scol} p={p1}{p2}"
                    _update_worst(worst, 're', abs(act_re - exp_re), loc, exp_re, act_re)
                    _update_worst(worst, 'im', abs(act_im - exp_im), loc, exp_im, act_im)
                    re_bad = abs(act_re - exp_re) > vis_atol + vis_rtol * abs(exp_re)
                    im_bad = abs(act_im - exp_im) > vis_atol + vis_rtol * abs(exp_im)
                    if re_bad:
                        n_re_bad += 1
                    if im_bad:
                        n_im_bad += 1
                    if (re_bad or im_bad) and detail_count[0] < max_detail:
                        detail_count[0] += 1
                        tag = ("re+im" if re_bad and im_bad
                               else "re" if re_bad else "im")
                        print(f"  VIS[{tag:>5}] cell={cell_index} e={e} "
                              f"row_st={srow} col_st={scol} p={p1}{p2}"
                              f"  exp=({exp_re:.3f},{exp_im:.3f})"
                              f"  act=({act_re:.3f},{act_im:.3f})")

            # Meta: byte 2e = FD/DV, byte 2e+1 = TCI.
            if srow < n16 and scol < n16:
                exp_fd = int(fd[srow, scol]) & 0xFF
                exp_tci = int(tci[srow, scol]) & 0xFF
            else:
                exp_fd = 0
                exp_tci = 0
            act_fd = ct2_check.dump_read_byte(dump, tci_base + 2 * e)
            act_tci = ct2_check.dump_read_byte(dump, tci_base + 2 * e + 1)
            if act_fd is None or act_tci is None:
                n_missing += 1
            else:
                mloc = f"cell={cell_index} e={e} row_st={srow} col_st={scol}"
                _update_worst(worst, 'fd', abs(act_fd - exp_fd), mloc, exp_fd, act_fd)
                _update_worst(worst, 'tci', _wrap_diff(act_tci, exp_tci), mloc, exp_tci, act_tci)
                fd_bad = abs(act_fd - exp_fd) > tci_tol
                tci_bad = _wrap_diff(act_tci, exp_tci) > tci_tol
                if fd_bad or tci_bad:
                    n_meta_bad += 1
                    if detail_count[0] < max_detail:
                        detail_count[0] += 1
                        print(f"  META cell={cell_index} e={e} "
                              f"row_st={srow} col_st={scol}"
                              f"  exp(FD,TCI)=({exp_fd},{exp_tci})"
                              f"  act=({act_fd},{act_tci})")

    return n_re_bad, n_im_bad, n_meta_bad, n_missing


def _wrap_diff(a, b):
    """Smallest difference between two 8-bit values treating them as signed."""
    d = (a - b) & 0xFF
    if d > 128:
        d -= 256
    return abs(d)


def check(cfg, dump, vis_rtol, vis_atol, tci_tol, max_detail, diagnose=False):
    demap_words = cfg.get('demap_table', [0])
    sb_c0_words = cfg.get('sb_c0_table', [0])
    virt_chs = cfg.get('virtual_channels', 12)

    demap = ct2_check.decode_demap(demap_words, virt_chs)
    sbs = decode_sb_table_full(sb_c0_words)

    empty_worst = {k: {'res': -1.0, 'loc': '', 'exp': 0.0, 'act': 0.0}
                   for k in ('re', 'im', 'tci', 'fd')}

    cells = written_cell_indices(dump)
    if not cells:
        print("  WARNING: no visibility cells written (simulation may not have "
              "run long enough)")
        return 0, 0, 0, 0, 0, empty_worst
    max_cell = cells[-1]
    print(f"  {len(cells)} visibility cells present (max cell index {max_cell})")

    # Only one enabled subarray-beam is supported in this first pass.
    enabled = [i for i, sb in enumerate(sbs)
               if sb['n_stations'] > 0 and not sb['output_disable']]
    if len(enabled) == 0:
        print("  WARNING: no enabled subarray-beams in the SB table")
        return 0, 0, 0, 0, len(cells), empty_worst
    if len(enabled) > 1:
        print(f"  NOTE: {len(enabled)} enabled subarray-beams; this checker "
              f"currently verifies only the first (index {enabled[0]}).")
    sb_index = enabled[0]
    sb = sbs[sb_index]
    station_map = build_station_map(demap, sb_index)
    time_groups = 1 if sb['n_time_integrate'] == 192 else 3

    print(f"  subarray-beam {sb_index}: stations={sb['n_stations']} "
          f"n_fine={sb['n_fine']} fine_per_int={sb['n_fine_integrate']} "
          f"n_time={sb['n_time_integrate']} "
          f"stations_mapped={len(station_map)}")

    # Build the production sequence up to the highest written cell.
    descs = list(cell_descriptors(sb, max_cell + 1))
    for idx, d in enumerate(descs):
        d['cell_index'] = idx

    n_checked = 0
    n_re_bad = 0
    n_im_bad = 0
    n_meta_bad = 0
    n_missing = 0
    detail_count = [0]
    worst = {k: {'res': -1.0, 'loc': '', 'exp': 0.0, 'act': 0.0}
             for k in ('re', 'im', 'tci', 'fd')}
    cell_set = set(cells)
    for d in descs:
        if d['cell_index'] not in cell_set:
            continue
        rb, ib, mb, ms = check_cell(dump, d, sb, station_map, time_groups,
                                    vis_rtol, vis_atol, tci_tol, max_detail,
                                    detail_count, worst)
        n_checked += 1
        n_re_bad += rb
        n_im_bad += ib
        n_meta_bad += mb
        n_missing += ms

    # On mismatch (or when forced), diagnose the first written cell to identify
    # which convention the RTL actually uses.
    if (diagnose or n_re_bad > 0 or n_im_bad > 0 or n_meta_bad > 0) and cells:
        first_idx = cells[0]
        first_desc = next((d for d in descs if d['cell_index'] == first_idx), None)
        if first_desc is not None:
            av, afd, atci = read_actual_cell(dump, first_idx)
            ev, efd, etci = expected_cell_block(first_desc, sb, station_map,
                                                time_groups)
            print(f"\n--- diagnosing cell {first_idx} "
                  f"(integration={first_desc['integration']}, "
                  f"oc={first_desc['output_channel']}, "
                  f"ot={first_desc['output_time']}, "
                  f"row_st={first_desc['row_first_station']}, "
                  f"col_st={first_desc['col_first_station']}) ---")
            diagnose_cell(av, ev, vis_rtol, vis_atol)
            diagnose_meta(afd, atci, efd, etci, tci_tol)

    return n_checked, n_re_bad, n_im_bad, n_meta_bad, n_missing, worst


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="Verify correlator visibility HBM dump against the model")
    ap.add_argument('vhdl_top', help="Top-level VHDL wrapper (e.g. ct2_test5_top.vhd)")
    ap.add_argument('vis_dump', help="Visibility HBM dump produced by simulation")
    ap.add_argument('--vis-rtol', type=float, default=1e-3,
                    help="Relative tolerance for visibility fp32 compare")
    ap.add_argument('--vis-atol', type=float, default=1.0,
                    help="Absolute tolerance for visibility fp32 compare")
    ap.add_argument('--tci-tol', type=int, default=1,
                    help="Tolerance (LSBs) for TCI/DV byte compare")
    ap.add_argument('--max-detail', type=int, default=40,
                    help="Maximum number of mismatch lines to print")
    ap.add_argument('--diagnose', action='store_true',
                    help="Always run convention diagnosis on the first cell, "
                         "even if the check passes")
    args = ap.parse_args()

    print(f"Parsing configuration from: {args.vhdl_top}")
    cfg = ct2_check.parse_generic_map(args.vhdl_top)
    print(f"  virtual_channels = {cfg.get('virtual_channels', '?')}")

    print(f"\nLoading visibility dump: {args.vis_dump}")
    dump = ct2_check.load_dump(args.vis_dump)
    print(f"  {len(dump)} 32-bit words loaded ({len(dump) * 4} bytes)")

    print("Checking ...\n")
    checked, re_bad, im_bad, meta_bad, missing, worst = check(
        cfg, dump, args.vis_rtol, args.vis_atol, args.tci_tol, args.max_detail,
        diagnose=args.diagnose)

    print()
    print("=== vis_check result ===")
    print(f"  Cells checked      : {checked}")
    print(f"  Bad vis (real)     : {re_bad}")
    print(f"  Bad vis (imag)     : {im_bad}")
    print(f"  Bad TCI/DV         : {meta_bad}")
    print(f"  Missing words      : {missing}")

    # Always report the worst mismatch seen, pass or fail.
    if checked > 0:
        print("  Worst mismatch (residual = |actual - expected|):")
        for key, label, unit in (('re', 'vis real', ''), ('im', 'vis imag', ''),
                                  ('tci', 'TCI', ' LSB'), ('fd', 'FD/DV', ' LSB')):
            w = worst[key]
            if w['res'] < 0:
                continue
            if key in ('re', 'im'):
                tol = args.vis_atol + args.vis_rtol * abs(w['exp'])
                pct = (w['res'] / tol * 100.0) if tol > 0 else 0.0
                print(f"    {label:8s}: {w['res']:.4g}{unit}  "
                      f"({pct:.3f}% of its {tol:.4g} threshold)  "
                      f"exp={w['exp']:.4g} act={w['act']:.4g}  @ {w['loc']}")
            else:
                print(f"    {label:8s}: {int(w['res'])}{unit} (threshold {args.tci_tol})  "
                      f"exp={int(w['exp'])} act={int(w['act'])}  @ {w['loc']}")
    if checked == 0:
        print("  WARNING: nothing checked")
        sys.exit(2)
    elif re_bad == 0 and im_bad == 0 and meta_bad == 0 and missing == 0:
        print("  PASS")
        sys.exit(0)
    else:
        if re_bad == 0 and meta_bad == 0 and missing == 0 and im_bad > 0:
            print("  FAIL (imaginary parts only — real parts and TCI/DV all "
                  "match; see notes)")
        else:
            print("  FAIL")
        sys.exit(1)


if __name__ == '__main__':
    main()
