#!/bin/bash
echo "source this file, to add the tools directory to your path for easy programming of an alveo from the command line"
echo "i.e.  source prog_setup.sh"
echo -e
echo "prog_trafgen <directory with .xclbin file>"
CURRENT_DIR=$(pwd)
export PATH=$CURRENT_DIR:$PATH

