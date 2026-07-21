#!/bin/bash
# run_flatten_tb.sh
#
# Creates a standalone Vivado project for the flatten_tb simulation and runs
# both test modes (impulse and pseudo-random LFSR), reporting PASS / FAIL.
#
# Usage (from repo root):
#   libraries/signalProcessing/cornerturn1/run_flatten_tb.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITREPO="$(cd "$SCRIPT_DIR/../../.." && pwd)"

VIVADO_SETTINGS=/tools/Xilinx/2025.1/Vitis/settings64.sh
if [ ! -f "$VIVADO_SETTINGS" ]; then
    echo "Error: Vivado settings not found at $VIVADO_SETTINGS"
    exit 1
fi

source "$VIVADO_SETTINGS"

echo "Repo root : $GITREPO"
echo "Vivado    : $(which vivado)"
echo

vivado -mode batch \
    -source "$SCRIPT_DIR/create_flatten_tb.tcl" \
    2>&1 | tee "$GITREPO/build/flatten_tb_run.log"

echo
echo "Full log: $GITREPO/build/flatten_tb_run.log"

# Extract PASS/FAIL lines from the log
grep -E "PASS|FAIL|mismatches" "$GITREPO/build/flatten_tb_run.log" || true
