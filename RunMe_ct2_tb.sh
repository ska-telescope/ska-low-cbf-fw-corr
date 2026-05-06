#!/bin/bash
#  Distributed under the terms of the CSIRO Open Source Software Licence Agreement
#  See the file LICENSE for more info.


## This script creates a Vivado Vitis project,
## It synthesizes and produces an output bitfile to be programmed
## to an Alveo from the source in this git repository

ALLOWED_ALVEO=(u55) #ALVEO is either U50 or U55 as of Sept 2021
KERNELS_TO_GEN=(cor)
XILINX_PATH=/tools/Xilinx
VIVADO_VERSION_IN_USE=2022.2


##Select Alveo Card Type
TARGET_ALVEO="u55"
export TARGET_ALVEO=$TARGET_ALVEO
kernel="correlator_ct2_tb"
export PERSONALITY=$kernel

export GITREPO=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)
export RADIOHDL=$GITREPO

# $SVN is required for the RADIOHDL scripts
export SVN=$GITREPO
echo -e "\nBase Git directory: $GITREPO"

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

if [ -n "$XILINX_REFERENCE_DESIGN" ]; then
    echo "XILINX_REFERENCE_DESIGN: Using Existing ARGS FILES"
    echo
else
    echo "SKA Design: Re-generating ARGS from configuration YAML files in $GITREPO/libraries"
    source $GITREPO/tools/bin/setup_radiohdl.sh 
    echo
    python3 $GITREPO/tools/radiohdl/base/vivado_config.py -l $kernel -a | $TEE_LOG | $COLOUR
fi

if [ "$4" = "args" ]; then
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
source ${XILINX_PATH}/Vitis/$VIVADO_VERSION_IN_USE/settings64.sh | $TEE_LOG

echo
echo "<><><><><><><><><><><><><>  Vivado Create Project <><><><><><><><><><><><><>" | $TEE_LOG
echo
echo "Kernel for project is " $kernel | $TEE_LOG
echo "Target Device for project is " $TARGET_ALVEO | $TEE_LOG
echo "Vivado Version for project is " $VIVADO_VERSION_IN_USE | $TEE_LOG
echo
source ${XILINX_PATH}/Vitis/$VIVADO_VERSION_IN_USE/settings64.sh


vivado $STACK_ARG -mode batch -source $GITREPO/designs/correlator/create_project_ct2_tb.tcl -tclargs $kernel | $TEE_LOG
