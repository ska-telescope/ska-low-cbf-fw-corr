#!/bin/bash
#  Distributed under the terms of the CSIRO Open Source Software Licence Agreement
#  See the file LICENSE for more info.


## Convenience wrapper for building the V80 100G networking design by hand on a
## dev machine. It only selects the design .tcl and hands everything else to
## create_v80.sh, so all of that script's arguments and behaviour apply:
##
##   ./create_v80_100g.sh 2025.1          create the Vivado project only
##   ./create_v80_100g.sh 2025.1 build    create the project and build it
##   ./create_v80_100g.sh -h              help
##
## In CI the same thing is done by setting V80_DESIGN_TCL on the job instead of
## calling this wrapper - see 'vivado compile v80 100g' in .gitlab-ci.yml.
##
## Note the project is still created in build/v80 and named v80_top, shared with
## the standard V80 design, so building one after the other in the same working
## copy overwrites the previous build. See the V80_DESIGN_TCL comment block in
## create_v80.sh for why that is deliberate.

MY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

export V80_DESIGN_TCL="create_v80_100g_design.tcl"

exec "${MY_DIR}/create_v80.sh" "$@"
