#!/bin/bash
# run all the bash scripts to create a v80 correlator

# Check if output dir exists
if [ ! -d "output" ]; then
    echo -e "Creating directory output"
    mkdir -p output
fi

# create project and compile
./create_v80.sh build

echo -e "*********************************************************"
echo -e "**********             HW complete              *********"
echo -e "*********************************************************"

# compile fw
./common/v80_infra/create_fw_project.sh

echo -e "*********************************************************"
echo -e "**********             FW complete              *********"
echo -e "*********************************************************"

# combine to make PDI
./common/v80_infra/create_pdi.sh

echo -e "*********************************************************"
echo -e "**********            PDI complete              *********"
echo -e "*********************************************************"

# bundle up
./gather_v80.sh

echo -e "*********************************************************"
echo -e "**********        Files in Output Dir           *********"
echo -e "*********************************************************"