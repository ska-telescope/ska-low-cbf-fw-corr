# CAR_OCI_REGISTRY_HOST and PROJECT are combined to define
# the Docker tag for this project. The definition below inherits the standard
# value for CAR_OCI_REGISTRY_HOST = artefact.skao.int and overwrites
# PROJECT to give a final Docker tag
#
PROJECT = ska-low-cbf-fw-corr

# Fixed variables
# Timeout for gitlab-runner when run locally
TIMEOUT = 86400

CI_PROJECT_DIR ?= .
CI_PROJECT_PATH_SLUG ?= ska-low-cbf-fw-corr
CI_ENVIRONMENT_SLUG ?= ska-low-cbf-fw-corr

# define private overrides for above variables in here
-include PrivateRules.mak

# Hook into SKA release logic to sync .release label with our VHDL code
post-set-release:
	common/scripts/vhdl_set_version.sh "$(VERSION)" "designs/correlator/src/vhdl/version_pkg.vhd"

# Include the required modules from the SKA makefile submodule
include .make/release.mk
include .make/raw.mk
include .make/make.mk
include .make/help.mk
include .make/docs.mk

