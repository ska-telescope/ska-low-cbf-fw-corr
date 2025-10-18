#!/bin/bash
#  Distributed under the terms of the CSIRO Open Source Software Licence Agreement
#  See the file LICENSE for more info.


## This script creates a Vivado Vitis project,
## It synthesizes and produces an output bitfile to be programmed
## to an Alveo from the source in this git repository

######################################################################
## CLI support

SUPPORTED_VERSIONS=(2024.2 2025.1)
ShowHelp()
{
    echo "####################################################"
    echo "Usage: ${0##*/} [-h] <vitis version> "
    echo ""
    echo "e.g. ${0##*/} 2024.2 "
    echo ""
    echo "-h    Print this help then exit"
    echo "Supported Vivado Version: ${SUPPORTED_VERSIONS[*]}"    
    echo "####################################################"
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

if [ "$#" -lt 1 ]; then
    echo "Not enough parameters"
    ShowHelp
    exit 1
fi

#####################################################################
## Handle CLI Args
SPECIFIED_VIVADO_VERSION=$(echo $1 | tr "[:upper:]" "[:lower:]")

if [[ " ${SUPPORTED_VERSIONS[*]} " =~ " $SPECIFIED_VIVADO_VERSION " ]]; then
    echo -e "Vivado_Version: $SPECIFIED_VIVADO_VERSION"
else
    echo -e "Invalid Vivado_Version: $SPECIFIED_VIVADO_VERSION"
    echo -e "Valid Vivado_Versions: ${SUPPORTED_VERSIONS[*]}"
    exit 3
fi

#####################################################################

TARGET_ALVEO=(v80) 
XILINX_PATH=/tools/Xilinx
VIVADO_VERSION_IN_USE=$SPECIFIED_VIVADO_VERSION
kernel="correlator_v80"

## Add version to Env
export VIVADO_VERSION_IN_USE=$SPECIFIED_VIVADO_VERSION

if [ -z "`which ccze`" ]; then
    echo -e "Note: ccze not found, running in monochrome mode, install via apt"
    COLOUR="cat"
else
    COLOUR="ccze -A"
fi


export GITREPO=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)
echo -e "\nBase Git directory: $GITREPO"
export SVN=$GITREPO
echo -e "\n"
source $GITREPO/tools/bin/setup_radiohdl.sh 
echo -e "\nRADIOHDL is : $RADIOHDL"

echo
echo "<><><><><><><><><><><><><>  Automatic Register Generation System (ARGS)  <><><><><><><><><><><><><>"
echo

# Delete any existing ARGs
rm -rf $GITREPO/build/ARGS

echo "SKA Design: Re-generating ARGS from configuration YAML files"
echo
python3 $GITREPO/tools/radiohdl/base/vivado_config.py -l kernel -a | $COLOUR

if [ "$1" = "args" ]; then
    exit 0
fi

# ##Clean the build directory if we pass in a command line parameter called clean
# if [ "$1" = "clean" ]; then
    echo -e "Deleting Build Directory $GITREPO/build/v80"
    rm -rf $GITREPO/build/v80
# fi

sleep 5s

##Check that the build directories exists
if [ ! -d "$GITREPO/build/$TARGET_ALVEO" ]; then
    echo -e "Creating directory $GITREPO/build/$TARGET_ALVEO"
    mkdir -p $GITREPO/build/$TARGET_ALVEO
fi

##Check for IP repo not included in common
if [ ! -d "$GITREPO/common/v80_infra/iprepo" ]; then
    echo -e "IPrepo dir missing from /common/v80_infra/iprepo"
    echo -e "Seek help from a higher power."
    exit 1
fi

echo "Generate build info file"
cd $GITREPO/build
echo "$GITREPO/build"
./../common/scripts/build_details.sh

cd $GITREPO/build/$TARGET_ALVEO

# ............ Source VIVADO ............
if [ "$VIVADO_VERSION_IN_USE" = "2024.2" ]; then
    echo "Sourcing ${XILINX_PATH}/Vitis/$VIVADO_VERSION_IN_USE/settings64.sh"
    source ${XILINX_PATH}/Vitis/$VIVADO_VERSION_IN_USE/settings64.sh
else
    echo "Sourcing ${XILINX_PATH}/$VIVADO_VERSION_IN_USE/Vitis/settings64.sh"
    source ${XILINX_PATH}/$VIVADO_VERSION_IN_USE/Vitis/settings64.sh
fi

sleep 5s

if [ "$2" = "build" ]; then
    echo -e "Creating and building project"
    sleep 5s
    echo 
    echo "<><><><><><><><><><><><><>  Build Vivado Project <><><><><><><><><><><><><><>" | $COLOUR
    echo
    echo "Target Device for project is " $TARGET_ALVEO | $COLOUR
    echo "Vivado Version for project is " $VIVADO_VERSION_IN_USE | $COLOUR
    echo

    vivado -mode batch -source $GITREPO/designs/correlator_v80/create_v80_design.tcl -source $GITREPO/common/v80_infra/scripts/build_v80_design.tcl -tclargs $kernel | $COLOUR
else
    echo -e "Creating project."
    echo 
    echo "<><><><><><><><><><><><><>  Vivado Create Project <><><><><><><><><><><><><>" | $COLOUR
    echo
    echo "Target Device for project is " $TARGET_ALVEO | $COLOUR
    echo "Vivado Version for project is " $VIVADO_VERSION_IN_USE | $COLOUR
    echo

    vivado -mode batch -source $GITREPO/designs/correlator_v80/create_v80_design.tcl -tclargs $kernel | $COLOUR
fi

echo "Script complete"