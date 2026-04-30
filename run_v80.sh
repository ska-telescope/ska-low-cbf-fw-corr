#!/bin/bash
# run all the bash scripts to create a v80 correlator

# Check if output dir exists
if [ ! -d "output" ]; then
    echo -e "Creating directory output"
    mkdir -p output
fi

# create project and compile
./create_v80.sh 2025.1 build

echo -e "*********************************************************"
echo -e "**********             HW complete              *********"
echo -e "*********************************************************"

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
./common/scripts/hbm_addr_extract.sh designs/correlator_v80/src_v80/vhdl/correlator_core.vhd

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

# check timing in runme.log
   File=output/reports/impl_1/runme.log

   if ! grep -q "The design failed to meet the timing requirements" "$File"; then
      echo "BANG BOOM - Timing failed!!!!"
   else
      echo -e "*********************************************************"
      echo -e "**********     Build impl_1 met timing       ************"
      echo -e "*********************************************************"
   fi
