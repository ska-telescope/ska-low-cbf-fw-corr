#!/bin/bash
# run_flatten_tb.sh
#
# Creates a standalone Vivado project for the flatten_tb simulation and runs
# both test modes (impulse and pseudo-random LFSR), reporting PASS / FAIL.
#
# flatten_tb drives the Xilinx FIR compiler IP (sps_flatten, the U55 reference)
# and the custom double-rate filter (sps_flatten_dclk, V80) with identical
# input, and prints a line for every tdata or tuser mismatch.
#
# A run is only accepted if, for BOTH modes, the testbench printed a PASS line.
# The absence of mismatch lines on its own is not evidence: if the two filters
# were never simultaneously valid, or if the stimulus never reached them, no
# comparison happens and no mismatch is printed. flatten_tb guards against that
# by counting the samples it compared and failing when that count, or the count
# of non-zero compared samples, is zero.
#
# Usage (from anywhere):
#   libraries/signalProcessing/cornerturn1/run_flatten_tb.sh

# No 'set -u': the Vivado settings script references unset variables such as
# PYTHONPATH and would abort the run before vivado is reached.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITREPO="$(cd "$SCRIPT_DIR/../../.." && pwd)"

VIVADO_SETTINGS=/tools/Xilinx/2025.1/Vivado/settings64.sh
if [ ! -f "$VIVADO_SETTINGS" ]; then
    echo "Error: Vivado settings not found at $VIVADO_SETTINGS"
    exit 1
fi

# shellcheck disable=SC1090
source "$VIVADO_SETTINGS"

echo "Repo root : $GITREPO"
echo "Vivado    : $(which vivado)"
echo

mkdir -p "$GITREPO/build"
LOG="$GITREPO/build/flatten_tb_run.log"

# Start from a clean log so a stale one cannot be mistaken for this run.
rm -f "$LOG"

vivado -mode batch -nojournal \
    -source "$SCRIPT_DIR/create_flatten_tb.tcl" \
    2>&1 | tee "$LOG"
VIVADO_RC=${PIPESTATUS[0]}
if [ "$VIVADO_RC" -ne 0 ]; then
    echo
    echo "FAIL: vivado exited with status $VIVADO_RC"
    grep -i "^ERROR" "$LOG" | head -10
    exit 1
fi

echo
echo "Full log: $LOG"
echo

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
# Two modes are run, so two PASS lines are required. Counting FAIL lines as
# well means a mode that failed for want of a comparison is caught, not just
# one that produced differing data.
PASSES=$(grep -c "^PASS:" "$LOG" || true)
FAILS=$(grep -c "^FAIL:" "$LOG" || true)
MISMATCHES=$(grep -c "MISMATCH" "$LOG" || true)

echo "=== flatten_tb summary ==="
grep -E "^(=== flatten_tb result|g_DATA_SELECT|Samples compared|Non-zero outputs|Data mismatches|Tuser mismatches|PASS:|FAIL:)" "$LOG" || true
echo

if [ "$MISMATCHES" -gt 0 ]; then
    echo "First mismatch lines:"
    grep -E "MISMATCH" "$LOG" | head -20
    echo
fi

if [ "$FAILS" -gt 0 ] || [ "$PASSES" -ne 2 ]; then
    echo "FAIL: expected a PASS from both test modes, got $PASSES PASS and $FAILS FAIL"
    echo "      ($MISMATCHES mismatch lines in the log)"
    exit 1
fi

echo "PASS: both modes bit-identical between sps_flatten and sps_flatten_dclk."
exit 0
