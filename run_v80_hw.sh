#!/bin/bash
# V80 build - STAGE 1 of 2: Vivado hardware compile ONLY.
#
# This is the long-running (~hours) step. It produces the full build/ tree:
#   build/v80/v80_top.pdi   (hw partial PDI / bitstream)
#   build/v80/v80_top.xsa   (hardware export - REQUIRED by the FW step)
#   build/v80/v80_top.ltx
#   build/v80/v80_top.runs/impl_1/*.rpt, *.log
#   build/ARGS/py/correlator_v80/fpgamap_*.py
#
# In CI this job's build/ artifact can be reused by a later pipeline via a
# 'v80_reuse=<jobid>' keyword in the commit message (see tools/fetch_hw_build.sh),
# so the assemble step (run_v80_rest.sh) can run without recompiling.

# create project and compile
./create_v80.sh 2025.1 build
RC=$?

echo -e "*********************************************************"
echo -e "**********             HW complete              *********"
echo -e "*********************************************************"

exit $RC
