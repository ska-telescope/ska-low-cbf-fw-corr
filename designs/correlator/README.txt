# Some useful commands.

# 1. Use bash
bash

# 2. set SVN to the checkout root
export SVN=~/path_name/your_firmware_dir_name

# 3. Setup RadioHDl
source $SVN/tools/bin/setup_radiohdl.sh

# 4. Run RadioHDL with -a option, to generate all ARGS files (and do nothing else)
python3 $SVN/tools/radiohdl/base/vivado_config.py -l correlator -a

# 5. Generate the c config file for use by the fpga viewer application :
# Result will be in build/ARGS/correlator
# This is also done automatically when running args?
python3 $SVN/tools/args/gen_c_config.py -f vitisAccelCore

# Note that the fpga map file (python structures with register names and addresses) will be in build/ARGS/py/correlator/fpgamap_???.py

# set which version of Vivado to use.
source /tools/Xilinx/Vitis/2021.2/settings64.sh

# 5. Run the setup project script
vivado -mode batch -source create_project_u55.tcl

# 6. Open the project in vivado

# 7. More stuff to do to run vitis...
source /opt/xilinx/xrt/setup.sh

# Look in the src/scripts directory

