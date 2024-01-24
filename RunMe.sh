#!/bin/bash
#  Distributed under the terms of the CSIRO Open Source Software Licence Agreement
#  See the file LICENSE for more info.


## This script creates a Vivado Vitis project,
## It synthesizes and produces an output bitfile to be programmed
## to an Alveo from the source in this git repository

ALLOWED_ALVEO=(u55 v80) #ALVEO is either U50 or U55 as of Sept 2021
KERNELS_TO_GEN=(cor)
XILINX_PATH=/tools/Xilinx
VITIS_PROJ=TRUE
# use ptp submodule (we assume it's initialised)
PTP_IP="${PWD}/pub-timeslave/hw/cores"


ShowHelp()
{
    echo "Usage: ${0##*/} [-h] <device> <kernel> <build info> [clean/kernel/args]"
    echo ""
    echo "e.g. ${0##*/} u55 \"This is the build string\" kernel"
    echo ""
    echo "-h    Print this help then exit"
    echo "device: ${ALLOWED_ALVEO[*]}"
    echo "build info: free text (use quotes)"
    echo "clean: (optional) clean the build directory"
    echo "args: (optional) stop after ARGs generation"
    echo "kernel: (optional) stop after kernel project generation"
}

while getopts ":h" option; do
    case $option in
        h)
            ShowHelp
            exit;;
        ?)
            echo "Unknown option -${OPTARG}"
            echo "Use -h for help"
            exit 1;;
    esac
done

if [ "$#" -lt 2 ]; then
    echo "Not enough parameters"
    ShowHelp
    exit 1
fi

##Select Alveo Card Type
TARGET_ALVEO=$(echo $1 | tr "[:upper:]" "[:lower:]")
if [[ " ${ALLOWED_ALVEO[*]} " =~ " $TARGET_ALVEO " ]]; then
    echo -e "Device: $TARGET_ALVEO"
else
    echo -e "Invalid Device: $TARGET_ALVEO"
    echo -e "Valid devices are: ${ALLOWED_ALVEO[*]}"
    exit 2
fi
# assume U55 is the default otherwise set U50LV
export XPFM=/opt/xilinx/platforms/xilinx_u55c_gen3x16_xdma_3_202210_1/xilinx_u55c_gen3x16_xdma_3_202210_1.xpfm
export VITIS_TARGET=u55
VIVADO_VERSION_IN_USE=2022.2
kernel="correlator"

if [ $TARGET_ALVEO = "u50" ]; then
    export XPFM=/opt/xilinx/platforms/xilinx_u50lv_gen3x4_xdma_2_202010_1/xilinx_u50lv_gen3x4_xdma_2_202010_1.xpfm
    export VITIS_TARGET=u50
fi

if [ $TARGET_ALVEO = "v80" ]; then
    VIVADO_VERSION_IN_USE=2023.2
    export VITIS_TARGET=v80
    kernel="correlator_v80"
    VITIS_PROJ=FALSE
fi

export TARGET_ALVEO=$TARGET_ALVEO

if [ ! -f "$XPFM" ]; then
	echo "Error: can't find XPFM file $XPFM"
    exit 5
fi

# kernel=$(echo $2 | tr "[:upper:]" "[:lower:]")
# if [[ " ${KERNELS_TO_GEN[*]} " =~ " $kernel " ]]; then
#     echo -e "kernel: $kernel"
#     kernel="correlator"
# else
#     echo -e "Invalid kernel: $kernel"
#     echo -e "Valid kernels: ${KERNELS_TO_GEN[*]}"
#     exit 3
# fi

export PERSONALITY=$kernel

if [ "$2" = "" ]; then
    echo -e "Please supply a buildinfo string that will be associated with the .xcbin and .ccfg in the output files directory"
    echo -e './RunMe.sh u50 cnic "This is the build string"'
    echo -e ' Optionally supply the parameter "clean" to clean the output and build directories'
    echo -e './RunMe.sh u50 cnic "This is the build string" clean'
    exit 4
fi
BUILDINFO=$2
echo "Build Info: $BUILDINFO"

export GITREPO=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)
export RADIOHDL=$GITREPO

# $SVN is required for the RADIOHDL scripts
export SVN=$GITREPO
echo -e "\nBase Git directory: $GITREPO"

##Clean the build directory if we pass in a command line parameter called clean
if [ "$3" = "clean" ]; then
    echo -e "Deleting ARGS and Build Directory $GITREPO/build"
    echo -e "Deleting output Directory $GITREPO/output"
    rm -rf $GITREPO/build/ARGS
    rm -rf $GITREPO/build/$kernel
    rm -rf $GITREPO/output
fi

if [ -z "`which ccze`" ]; then
    echo -e "Note: ccze not found, running in monochrome mode"
    COLOUR="cat"
else
    COLOUR="ccze -A"
fi

##Check that the build directories exists
if [ ! -d "$GITREPO/build/$kernel" ]; then
    echo -e "Creating directory $GITREPO/build/$kernel"
    mkdir -p $GITREPO/build/$kernel
fi

##Check that the output directory exists
if [ ! -d "$GITREPO/output" ]; then
    echo -e "Creating directory $GITREPO/output"
    mkdir -p $GITREPO/output
fi

LOGFILE="$GITREPO/output/$kernel.log"
echo Logging to $LOGFILE
rm -f $LOGFILE
TEE_LOG="tee -a $LOGFILE"

if [ -n "$VIVADO_STACK" ]; then
    STACK_ARG="-stack $VIVADO_STACK"
    echo Using "$STACK_ARG" for vivado
else
    STACK_ARG=""
fi

##Create the New Project for Vitis from the VHDL Source Files
echo -e "Creating the New Project for $kernel from the VHDL Source Files\n\n"
cd $GITREPO/build/$kernel

source $GITREPO/tools/bin/setup_radiohdl.sh
echo
echo "<><><><><><><><><><><><><>  Automatic Register Generation System (ARGS)  <><><><><><><><><><><><><>" | $TEE_LOG
echo

echo "SKA Design: Re-generating ARGS from configuration YAML files in $GITREPO/libraries"
source $GITREPO/tools/bin/setup_radiohdl.sh 
echo
python3 $GITREPO/tools/radiohdl/base/vivado_config.py -l $kernel -a | $TEE_LOG | $COLOUR

if [ "$3" = "args" ]; then
    exit 0
fi

echo "Generate build info file"
cd $GITREPO/build
echo "$GITREPO/build"
./../common/scripts/build_details.sh

export VITIS_VERSION=$VIVADO_VERSION_IN_USE

# If you wish to just generate the .CCFG , issue the following command
#python3 $GITREPO/tools/args/gen_c_config.py -f $kernel
echo "Sourcing ${XILINX_PATH}/Vitis/$VIVADO_VERSION_IN_USE/settings64.sh"
source ${XILINX_PATH}/Vitis/$VIVADO_VERSION_IN_USE/settings64.sh | $TEE_LOG | $COLOUR

echo
echo "<><><><><><><><><><><><><>  Vivado Create Project <><><><><><><><><><><><><>" | $TEE_LOG
echo
echo "Kernel for project is " $kernel | $TEE_LOG
echo "Target Device for project is " $TARGET_ALVEO | $TEE_LOG
echo "Vivado Version for project is " $VIVADO_VERSION_IN_USE | $TEE_LOG
echo
source ${XILINX_PATH}/Vitis/$VIVADO_VERSION_IN_USE/settings64.sh


vivado $STACK_ARG -mode batch -source $GITREPO/designs/$kernel/create_project.tcl -tclargs $kernel | $TEE_LOG | $COLOUR

if [ "$VITIS_PROJ" = "FALSE" ]; then
    exit 0
fi

##Find latest Vivado project directorys
PRJ_DIR=$GITREPO/build/$kernel/
cd $PRJ_DIR

NEWEST_DIR=`ls -td -- */ | head -n 1 | tr -d '\n'`
if [ -z $NEWEST_DIR ]; then
    echo "FAIL: Could not find the latest ${kernel}_build_ directory"
    exit 1
fi

PRJ_DIR+=$NEWEST_DIR
#strip trailing slash
PRJ_DIR=${PRJ_DIR%/}
echo ""
echo "Newest Vivado Project Directory=" $PRJ_DIR | $TEE_LOG

#Copy ARG generated .CCFG file to the project directory
cp $GITREPO/build/ARGS/$kernel/$kernel.ccfg $PRJ_DIR/

cd $PRJ_DIR
echo
# TB_REGISTERS_INPUT=$GITREPO/designs/$kernel/src/tb/registers.txt
# if [ -f "$TB_REGISTERS_INPUT" ]; then
#     TB_REGISTERS_OUTPUT=$GITREPO/designs/$kernel/src/tb/registers_tb.txt
#     echo "Generating $TB_REGISTERS_OUTPUT for the testbench from $TB_REGISTERS_INPUT" | $TEE_LOG
#     python3 $GITREPO/tools/args/gen_tb_config.py -c $PRJ_DIR/${kernel}.ccfg -i "$TB_REGISTERS_INPUT" -o "$TB_REGISTERS_OUTPUT" | $TEE_LOG
#     cp $GITREPO/designs/$kernel/src/tb/registers*.txt .
# else
#     echo "Skipping testbench generation, $TB_REGISTERS_INPUT does not exist"
# fi

echo $BUILDINFO >> $PRJ_DIR/buildinfo.txt

if [ "$3" = "kernel" ]; then
    exit 0
fi


## Package up the Vitis Kernel and Generate an XO file

echo
echo "<><><><><><><><><><><><><>  Vivado PACKAGE KERNEL  <><><><><><><><><><><><><>" | $TEE_LOG
echo

vivado $PRJ_DIR/$kernel.xpr $STACK_ARG -mode batch -source $GITREPO/designs/$kernel/src/scripts/package_kernel.tcl | $TEE_LOG | $COLOUR
echo
echo "<><><><><><><><><><><><><>  Vivado Generate XO File <><><><><><><><><><><><><>" | $TEE_LOG
echo

vivado $PRJ_DIR/$kernel.xpr $STACK_ARG -mode batch -source $GITREPO/designs/$kernel/src/scripts/gen_xo.tcl -tclargs ./$kernel.xo $kernel $GITREPO/designs/$kernel/src/scripts/$VITIS_TARGET | $TEE_LOG | $COLOUR



##Run Vitis
cd $PRJ_DIR

source /opt/xilinx/xrt/setup.sh | $TEE_LOG | $COLOUR
echo
echo
echo "<><><><><><><><><><><><><>  Running Vitis v++ <><><><><><><><><><><><><>" | $TEE_LOG
echo

v++ --optimize 0 --report_level 2 --save-temps --config "$GITREPO/designs/$kernel/src/scripts/$VITIS_TARGET/connectivity.ini" -l -t hw -o $kernel.xclbin --user_ip_repo_paths $PTP_IP -f $XPFM $PRJ_DIR/$kernel.xo | $TEE_LOG | $COLOUR

cp $LOGFILE $PRJ_DIR/

cd $GITREPO/build/ARGS/py/$kernel/
NEWEST_FPGAMAP=`ls -rd fpgamap_* |head -n1 | tr -d '\n'`
if [ -z $NEWEST_FPGAMAP ]; then
    echo "FAIL: Could not find the latest fpgamap.py file "
    exit 1
fi



if [ -f "$PRJ_DIR/$kernel.xclbin" ]; then
    echo "xclbin file was created, copying build to the $GITREPO/output directory."

    cd $PRJ_DIR
    cd ..
    rm latest
    ln -s $PRJ_DIR latest

    cd $GITREPO/output
    mkdir $NEWEST_DIR
    cd $NEWEST_DIR

    cp "$PRJ_DIR/$kernel.log" .
    cp $PRJ_DIR/$kernel.xclbin .
    cp $PRJ_DIR/$kernel.ltx .
    cp $PRJ_DIR/buildinfo.txt .
    cp $GITREPO/build/ARGS/py/$kernel/$NEWEST_FPGAMAP .
    cp $GITREPO/build/ARGS/$kernel/$kernel.ccfg .
    mkdir logs
    cd logs
    cp $PRJ_DIR/v++_$kernel.log .
    cp $PRJ_DIR/_x/logs/link/vivado.log .
    cp $PRJ_DIR/_x/logs/link/v++.log .
    cd ..
    cd $GITREPO/output
    rm latest
    ln -s $NEWEST_DIR latest
    scp -r $NEWEST_DIR $USERMACHINE:~/project/ska-low-cbf-firmware/output
    echo
    echo
    echo "Please navigate to the directory $PRJ_DIR for the output .xclbin files and log files including $kernel.log "
    echo
else
    echo "[ERROR] xclbin file was NOT created"
    exit 2
fi
