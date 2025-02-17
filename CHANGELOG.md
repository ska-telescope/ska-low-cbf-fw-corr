### Changelog
## Correlator Personality
* 0.1.1
    * Subarray addition/removal during a scan support added.
        * END packet generation added to hardware in the common module.
    * To be used with Processor v0.15.3
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
