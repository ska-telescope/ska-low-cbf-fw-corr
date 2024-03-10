# Low CBF Firmware - Correlator Repository
This repository contains FPGA firmware to implement Low CBF correlator and
associated functions.

## Documentation
[![Documentation Status](https://readthedocs.org/projects/ska-telescope-ska-low-cbf-fw-corr/badge/?version=latest)](https://developer.skao.int/projects/ska-low-cbf-fw-corr/en/latest/?badge=latest)

The documentation for this project can be found in the `docs` folder, or browsed in the SKA development portal:

* [ska-low-cbf-fw-corr documentation](https://developer.skatelescope.org/projects/ska-low-cbf-fw-corr/en/latest/index.html "SKA Developer Portal: ska-low-cbf-fw-corr documentation")

## Project Avatar (Repository Icon)
[Matrix icons created by HAJICON - Flaticon](https://www.flaticon.com/free-icons/matrix "matrix icons")

## Description

FPGAs implementing Low CBF receive dual-polarisation I/Q data from stations in
the Low Array and perform filtering, correlation, beamforming operations before
delivering the results to SDP, PSS and PST via optical link. Firmware for the
FPGAs is written mostly in VHDL.

## License

The firmware in this repository is released under the BSD 3-Clause Licence, as
per LICENSE in the root directory of this repository, except where a source file
specifically mentions another license.

---

## Directory Structure

* _/common_ - this is a submodule refering to
  [ska-low-cbf-fw-common](https://gitlab.com/ska-telescope/low-cbf/ska-low-cbf-fw-common)
* _/pub-timeslave_ this is a submodule refering to
  [AtomicRulesLLC/pub-timeslave](https://github.com/AtomicRulesLLC/pub-timeslave)
* _/libraries_ - For all firmware libraries. Contains 5 top level directories
  (all code to be placed inside one of them) to provide logical grouping but all
  libraries are available in the same flat namespace. Within each top level
  directory there is a subdirectory that is structured as shown in Figure 3-3
  (details listed below) which contains all user code and text benches. The
  subdirectory name is open to the designer. The top level directories are:
  * _/base_ - Includes common libraries and building blocks that may be used as
    small components for higher level libraries i.e. pipeline registers, fifos
    and AXI4 definitions. This directory also includes all the wrappers for
    technology blocks
  * _/signalProcessing_ - Includes high level DSP libraries i.e. beamformer or
    filterbank
  * _/technology_ - Vendor specific IP implementations
* _/tools_ - Contains all of the RadioHDL scripts and configuration files, and
  other tools
  * _/args_ - Contains all ARGS script code and templates
  * _/bin_ - Binary files required for RadioHDL operation
  * _/DAC_Cable_Test_ - For testing direct attach copper cables
  * _/doc_ - RadioHDL documentation
  * _/modelsim_ - Configuration scripts for modelsim simulator tool
  * _/radiohdl_ - Contains scripts to automatically build simulation and FPGA
    project files. Contains the high level executable python scripts
    * Modelsim_config.py - Build project files for modelsim
    * Vivado_config.py - Build project files (and bitfiles) for Vivado
  * _/vivado_ - Configuration scripts for Xilinx Vivado simulator & building
    tool
  * _/quartus_ - Configuration scripts for Altera building tool

---

## FPGA IDE

Xilinx tool is Vitis 2022.2
Target ALVEO - U55C - platform 3

## Tool Environment

RadioHDL (in the 'tools' directory) is a set of python modules that can create a
Vivado or Quartus project that allows the source code to be compiled into
executable form with the FPGA vendor's tools (Vivado for Xilinx, Quartus for
Intel/Altera). RadioHDL supports both Windows and Linux operating systems. The
following software needs to be accessible (in the system PATH) in order to build
project files:

* Make (Available in /tools/bin for win32 platforms)
* Python 3.6+
* Python Libraries (numpy, pylatex, yaml)

## Environment Variables

The following environment variables must be defined for the python scripts to
run correctly. All paths should conform to the path syntax of the operating
system being used.

* RADIOHDL = checkout directory of the Low.CBF subversion firmware tree without trailing slash
* HDL_BUILD_DIR = directory to build project to. Normal configured as $RADIOHDL/build
* $RADIOHDL/tools/bin added to PATH
* $MODEL_TECH_XILINX_LIB = directory containing precompiled Xilinx Modelsim libraries
* $MODEL_TECH_DIR = Modelsim directory

# Changelog

* 0.0.5 - 
    * LFAA_decode upgraded to support SPS packets v1, v2, v3 without configuration.
    * LFAA_decode address map update to include CDC updates to ARGs, see YAML.
* 0.0.4 - 
    * Multi-packet DATA Heap added to support greater than 16x16
    * Timestamping update for Epoch Offset calculation.
    * Add mechanism for rate control for all three SPEAD packets.
* 0.0.3 - 
    * IPv4 checksum bug fix.
* 0.0.2 - 
    * Delay Polynomials and Tracking implemented.
    * Supports upto 16 x 16 matrix.
    * SPEAD updates to Hz, Timestamps and INIT packet byte length.
    * FAT release.
* 0.0.1 - 
    * Two instance correlator.
    * U55C  - xilinx_u55c_gen3x16_xdma_3_202210_1
