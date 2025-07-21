### Changelog
## Correlator Personality
* 0.1.7
    * Enable single station correlation.
* 0.1.6
    * Fix for channel leakage after several scans.
* 0.1.5
    * Bug release
        * Visibility Flags in data packets Endian swapped
        * Powerup Value for INIT padding now 256, counter for this increased to 16 bits.
        * Integration ID incrementing correctly for single subarray configurations.
* 0.1.4
    * Firmware enables Zooms
        * Zooms from 1 correlator fine channel (=226Hz resolution ) to standard visibilities (=5.4kHz resolution) to 24kHz resolution.
        * Zoom window IDs are zero for standard visibilities and non-zero for zooms.
        * The value for zoom window ID is set in subarray configuration parameters.
    * Short integrations of 0.283 now available.
* 0.1.3
    * 59 tap ripple correction filter for 16d and 18a TPM filters
    * Selectable using the ripple_select regiser in CT1
        * 0 = identity filter (no correction)
        * 1 = 16d
        * 2 = 18a
* 0.1.2
    * Fix small base lines creating large packets.
    * Stage 2 (18a) ripple correction implemented.
* 0.1.1 - DO NOT USE
    * Subarray addition/removal during a scan support added.
        * END packet generation added to hardware in the common module.
    * To be used with Processor v0.15.4
* 0.1.0
    * AA1 release
    * To be used with Processor v0.15.1
* 0.0.8 (not released) - 
    * SPEAD DATA packet generates Visibility Flag headers and this logic is connected through.
    * SPS input support 100G burst traffic.
    * HBM reset modules added for CT2 to allow for config change.
    * Added update mechanism to SPEAD packetiser scratchpad to allow dynamic updates to INIT packet.
    * Fix for delay polynomials zero crossing.
    * Fix for duplicate timestamps.
    * Fix for stalling due to config change.
    * Fix for scaling in filterbank.
* 0.0.7 - 
    * Enable above 16x16 baselines, up to 246.
    * Correct single station readout bug.
* 0.0.6 - 
    * Fix for SPEAD v3, timestamps.
    * LFAA statistic RAMs update to have common layout for SPEAD v1,v2,v3
    * SPEAD INIT byte count control logic added.
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
