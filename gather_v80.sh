#!/bin/bash
#  Gather the output files from V80 into the output dir
# run this after PDI is assembled.

# Delete existing contents
if [ -z "$( ls -A 'output' )" ]; then
   echo "Empty"
else
   rm -r output/*
fi

# bitstream file
cp build/v80/v80_top.pdi output/

# find and copy ltx file
find . -name 'v80_top.ltx' | xargs cp -t output/

# Get ARGs map
find . -name 'fpga*.py' | xargs cp -t output/