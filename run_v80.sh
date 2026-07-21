#!/bin/bash
# run all the bash scripts to create a v80 correlator
#
# The build is split into two stages so CI can reuse a prior Vivado compile:
#   run_v80_hw.sh    - STAGE 1: Vivado HW compile (slow, produces build/)
#   run_v80_rest.sh  - STAGE 2: FW + PDI assembly + packaging (fast)
# This wrapper runs both back-to-back for a normal, local, end-to-end build.

set -e

./run_v80_hw.sh
./run_v80_rest.sh
