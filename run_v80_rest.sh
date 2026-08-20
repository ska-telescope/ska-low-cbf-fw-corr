#!/bin/bash
# V80 build - STAGE 2 of 2: FW compile, PDI assembly, packaging + timing check.
#
# Consumes the build/ tree produced by STAGE 1 (run_v80_hw.sh). In CI that
# build/ arrives either as the artifact of the 'vivado compile v80' job in this
# pipeline, or as a reused artifact fetched from a previous job via
# tools/fetch_hw_build.sh (commit keyword 'v80_reuse=<jobid>').
#
# This step is fast (minutes): it does NOT re-run Vivado place & route.

# Check if output dir exists
if [ ! -d "output" ]; then
    echo -e "Creating directory output"
    mkdir -p output
fi

# Sanity check: the reused/handed-over build must contain the HW export.
if [ ! -f build/v80/v80_top.xsa ]; then
    echo "ERROR: build/v80/v80_top.xsa not found - STAGE 1 output is missing."
    echo "       The assemble step needs the full build/ tree, not just the bitstream."
    exit 1
fi

# compile fw
./common/v80_infra/create_fw_project.sh 2025.1

echo -e "*********************************************************"
echo -e "**********             FW complete              *********"
echo -e "*********************************************************"

# combine to make PDI
./common/v80_infra/create_pdi.sh 2025.1

echo -e "*********************************************************"
echo -e "**********            PDI complete              *********"
echo -e "*********************************************************"

# bundle up files needed for archive to be sent to package register

# Delete existing contents
if [ -z "$( ls -A 'output' )" ]; then
   echo "Empty"
else
   rm -r output/*
fi

# run HBM address collation script.
./common/scripts/hbm_addr_extract.sh designs/correlator_v80/src_v80/vhdl/target_fpga_pkg.vhd

cp addresses.hbm output/

# bitstream file
cp build/v80/v80_top.pdi output/

# find and copy ltx file
find . -name 'v80_top.ltx' | xargs cp -t output/

# Get ARGs map
cp build/ARGS/py/correlator_v80/fpgamap_*.py output/

echo -e "*********************************************************"
echo -e "**********        Files in Output Dir           *********"
echo -e "*********************************************************"

# Harvest the logs from the build and check timing
mkdir -p output/reports

# Make dir for implementation reports
mkdir -p output/reports/impl_1
cp build/v80/v80_top.runs/impl_1/*.rpt output/reports/impl_1
cp build/v80/v80_top.runs/impl_1/*.log output/reports/impl_1

# Check that everything the 'output/' artifact is supposed to contain is really
# there, before the timing check and before GitLab collects the artifact.
# GitLab only WARNS about artifact paths that match nothing, and output/ is also
# what package_firmware_v80.sh tars for the package registry and what the CAR
# release is built from - so a gap here propagates a long way.
#
# This runs FIRST because the timing check below greps runme.log, and 'grep -q'
# on a missing file returns 2, which lands in the else branch and reports
# "met timing". A missing log must not read as a pass.
./common/scripts/check_v80_artifacts.sh assemble || exit 1

# check timing in runme.log
   File=output/reports/impl_1/runme.log

   if grep -q "The design failed to meet the timing requirements" "$File"; then
      echo -e "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
      echo -e "!!!!!!!!!!! BANG BOOM - Timing failed  !!!!!!!!!!!!!!!!!!"
      echo -e "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
      exit 1
   else
      echo -e "*********************************************************"
      echo -e "**********     Build impl_1 met timing       ************"
      echo -e "*********************************************************"
   fi
