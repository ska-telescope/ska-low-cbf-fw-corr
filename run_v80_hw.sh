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

if [ $RC -ne 0 ]; then
    echo "ERROR: create_v80.sh exited ${RC}."
    exit $RC
fi

# create_v80.sh pipes Vivado through ccze and ends with a success echo, so a
# zero exit code does not prove the compile worked. Check that the files this
# job is supposed to archive actually exist: GitLab only WARNS about an
# 'artifacts: paths:' entry that matches nothing, so without this a build that
# produced no PDI would upload a partial artifact and still go green.
./common/scripts/check_v80_artifacts.sh hw || exit 1

exit 0
