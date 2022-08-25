.. vim: syntax=rst

GitLab Continuous Integration (CI) Configuration
================================================

The CI configuration inherits from both the `SKA Templates Repository
<https://gitlab.com/ska-telescope/templates-repository>` and
`Low CBF Firmware Common
<https://gitlab.com/ska-telescope/low-cbf/ska-low-cbf-fw-common>`

Upload to Central Artefact Repository (CAR)
-------------------------------------------

Our Low CBF Firmware Common scripts already included a packaging step that
uploads to the GitLab package registry. 

For upload to CAR, the package_firmware.sh script is called with a variable set
so it doesn't upload, the uncompressed files to be packaged are copied into the
raw directory, and then the SKA Makefiles take care of the rest.

