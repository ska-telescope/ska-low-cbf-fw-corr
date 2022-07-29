#!/bin/bash
# Assume the "ska-low-cbf-proc"  git repo is in the same directory as this repo "low-cbf-firmware" 
# It is assumed that the required software from the "ska-low-cbf-proc"  git repo 
# is in the same directory as this repo "low-cbf-firmware" 

pushd ../../../
cd ska-low-cbf-proc/src
SKA_LOW_CBF_PROC_DIRECTORY=$(pwd)
popd

clear
if [ "$1" = "" ]; then
	echo -e "\n\n**************************************************"
	
	echo -e " Please supply the directory where the xilinx output" 
	echo -e " .xlbin file is and the fpgamap_xxxxx.py exist "

	echo -e "\n"
	echo -e "******************************************************"
	echo -e "\n\n"
	exit 
else
	export BUILD_DIRECTORY=$1
fi


source /opt/xilinx/xrt/setup.sh
echo -e "PYTHONPATH="$PYTHONPATH
echo -e "\n\n\n\n"
declare -x PYTHONPATH=$PYTHONPATH:$SKA_LOW_CBF_PROC_DIRECTORY:$BUILD_DIRECTORY
echo -e "PYTHONPATH="$PYTHONPATH

# If you need to hard rest one of the Alveo's that are stuck in an infinite loop
# xbutil reset -d 1

# Copy the FPGAmap_xxxxx.py file to the current directory
#cp $BUILD_DIRECTORY/fpga* .

# These are the version requirements for some of the python libraries
#pip3 install pyopencl==2021.1.1 --upgrade
#pip3 install numpy==1.19.5 --upgrade
#python3 packet_spam.py $BUILD_DIRECTORY 2>/dev/null
python3 packet_spam.py $BUILD_DIRECTORY 

