#!/bin/bash
# run all the bash scripts to create a v80 correlator

# Check if output dir exists
if [ ! -d "output" ]; then
    echo -e "Creating directory output"
    mkdir -p output
fi

# create project and compile
./create_v80.sh build

# compile fw
./common/v80_infra/create_fw_project.sh

# combine to make PDI
./common/v80_infra/create_fw_project.sh

# bundle up
./gather_v80.sh