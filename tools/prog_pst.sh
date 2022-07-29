#!/bin/bash
if (( $# < 2 )); then
#if   [ "$1" == "" ] || [ "$2" == "" ]; then
	echo -e " Usage : $0 [Card_number] [Xilinx_output_directory with .xlbin file]"
	exit
fi


CARD_NUM=$1
XILINX_BUILD_DIRECTORY=$2
source /opt/xilinx/xrt/setup.sh
alveo2gemini -d$CARD_NUM -h"1Gs 256Mi 256Mi 256Mi 256Mi" -f $XILINX_BUILD_DIRECTORY/vitisAccelCore.xclbin -p30337

