# -*- coding: utf-8 -*-
#
# Copyright (c) 2022 CSIRO Space and Astronomy.
#
# Distributed under the terms of the CSIRO Open Source Software Licence
# Agreement. See LICENSE for more info.

"""
Standalone code to create configuration for the SKA low correlator corner turn 1 module
---------------------------------------------
Introduction:
Corner turn 1 (CT1) buffers packets and then plays them back in a known order.
Main functionality being tested here is the configuration and calculation of the delay polynomials.
This code reads in a yaml file and writes out configuration data for the yaml test case.
The configurationd data includes the polynomial coefficients.
----------------------------------------------
Configuration memory:
  The memory is organised into blocks of 80 bytes.
  Within that memory :
    words 0 to 9 : Config for virtual channel 0, buffer 0 (see below for specification of contents)
    words 10 to 19 : Config for virtual channel 1, buffer 0
    ...
    words 10230 to 10239 : Config for virtual channel 1023, first buffer
    words 10240 to 20479 : Config for all 1024 virtual channels, second buffer

  Polynomial data is stored in the memory as a block of 9 x 64bit words for each virtual channel:   
      word 0 = c0,
       ...  
      word 5 = c5,
               c0 to c5 are double precision floating point values for the delay polynomial :
               c0 + c1*t + c2 * t^2 + c3 * t^3 + c4 * t^4 + c5 * t^5
               Units for c0,.. c5 are ns/s^k for k=0,1,..5
      word 6 = Sky frequency in GHz
               Used to convert the delay (in ns) to a phase rotation.
               (delay in ns) * (sky frequency in GHz) = # of rotations
               From the Matlab code:
                % Phase Rotation
                %  The sampling point is (DelayOffset_all * Ts)*1e-9 ns
                %  then multiply by the center frequency (CF) to get the number of rotations.
                %
                %  The number of cycles of the center frequency per output sample is not an integer due to the oversampling of the LFAA data.
                %  For example, for coarse channel 65, the center frequency is 65 * 781250 Hz = 50781250 Hz.
                %  50781250 Hz = a period of 1/50781250 = 19.692 ns. The sampling period for the LFAA data is 1080 ns, so 
                %  a signal at the center of channel 65 goes through 1080/19.692 = 54.8438 cycles. 
                %  So a delay which is an integer number of LFAA samples still requires a phase shift to be correct.
                resampled = resampled .* exp(1i * 2*pi*DelayOffset_all * Ts * 1e-9 * CF);
                # Note : DelayOffset_all = delay in number of samples (of period Ts)
                #        Ts = sample period in ns (i.e. 1080 for SPS data)
                #        CF = channel center frequency in Hz, e.g. 65 * 781250 = 50781250 for the first SPS channel
                #        - The value [Ts * 1e-9 * CF] is the value stored here.

      word 7 = buf_offset_seconds : seconds from the polynomial epoch to the start of the integration period, as a double precision value 
              
      word 8 = double precision offset in ns for the second polarisation (relative to the first polarisation).   

      word 9 = Validity time
               - bits 31:0 = buf_integration : Integration period at which the polynomial becomes valid. Integration period
                             is in units of 0.84934656 seconds, i.e. units of (384 SPS packets) 
               - bit 32 = Entry is valid.

"""

# import matplotlib.pyplot as plt
import argparse
import numpy as np
import yaml
import typing


def command_line_args():
    parser = argparse.ArgumentParser(description="Correlator CT1 polynomial configuration generator")
    parser.add_argument(
        "-d",
        "--data",
        type=argparse.FileType(mode="wt"),
        help="File to write configuration data to, only writes non-zero data",
        required=False,
    )
    parser.add_argument(
        "-c",
        "--cfgfull",
        type=argparse.FileType(mode="wt"),
        help="File to write full configuration data to, i.e. all 160 kBytes of data",
        required=False,
    )
    #parser.add_argument("-H0", "--HBM0", help="HBM buffer 0 data from firmware to check",
    #                    type=argparse.FileType(mode="r"))
    #parser.add_argument("-f", "--filter", help="Interpolation filter taps", type=argparse.FileType(mode="r"))
    parser.add_argument(
        "configuration",
        help="Test Configuration (YAML)",
        type=argparse.FileType(mode="r"),
    )
    return parser.parse_args()

def parse_config(file: typing.IO) -> typing.Dict:
    """
    Reads configuration YAML file, checks if required values are present.

    :param file: The YAML file object
    :return: Settings dict, guaranteed to contain the keys specified in required_keys
    :raises AssertionError: if required key(s) are missing
    """
    config = yaml.safe_load(file)

    required_keys = {"polynomials"}
    assert config.keys() >= required_keys, "Configuration YAML missing required key(s)"
    print("\n??\tSettings:")
    for parameter, value in config.items():
        if parameter == "polynomials":
            print("\tpolynomials:")
            for n, src_cfg in config["polynomials"].items():
                print(f"\t  {n}:")
                for src_param, src_val in src_cfg.items():
                    print(f"\t    {src_param}: {src_val}")
        else:
            print(f"\t{parameter}: {value}")
    return config


def ct1_config(config):
    """
    :param config: configuration data as read from the yaml file,
    config["polynomials"][source number]["virtual_channel","poly0","sky_freq0","buf_offset0","Ypol_offset0","integration0","valid0",
        "poly1","sky_freq1","buf_offset1","Ypol_offset1","integration1","valid1",]
    :return: numpy array of uint32 to be loaded into the CT1 polynomial configuration memory.
    """
    # keys start from 0, so add 1 to get total sources
    total_sources = np.max(list(config["polynomials"].keys())) + 1
    print(f"total_sources = {total_sources}")
    # each source has 2*80 bytes of configuration data
    # store as 4-byte integers so 40 entries per source
    config_array_buf0 = np.zeros(1024*20, np.uint32)
    config_array_buf1 = np.zeros(1024*20, np.uint32)
    poly_coefficients0 = np.zeros(6, np.float64)
    poly_coefficients1 = np.zeros(6, np.float64)
    vc_max = 0
    for n, src_cfg in config["polynomials"].items():
        vc = src_cfg["virtual_channel"]
        if vc > vc_max :
            vc_max = vc
        for c_index in range(6):
            poly_coefficients0[c_index] = np.float64(src_cfg["poly0"][c_index])
            poly_coefficients1[c_index] = np.float64(src_cfg["poly1"][c_index])
            
        config_array_buf0[(vc*20):(vc*20+12)] = np.frombuffer(poly_coefficients0.tobytes(), dtype=np.uint32)
        config_array_buf0[(vc*20+12):(vc*20+14)] = np.frombuffer(np.float64(src_cfg["sky_freq0"]).tobytes(), dtype=np.uint32)

        config_array_buf1[(vc*20):(vc*20+12)] = np.frombuffer(poly_coefficients1.tobytes(), dtype=np.uint32)
        config_array_buf1[(vc*20+12):(vc*20+14)] = np.frombuffer(np.float64(src_cfg["sky_freq1"]).tobytes(), dtype=np.uint32)

        # buf_offset_seconds : seconds from the polynomial epoch to the start of the integration period, as a double precision value 
        config_array_buf0[(vc*20+14):(vc*20+16)] = np.frombuffer(np.float64(src_cfg["buf_offset0"]).tobytes(), dtype=np.uint32)
        config_array_buf1[(vc*20+14):(vc*20+16)] = np.frombuffer(np.float64(src_cfg["buf_offset1"]).tobytes(), dtype=np.uint32)
        
        # word 8 = double precision offset in ns for the second polarisation (relative to the first polarisation).   
        config_array_buf0[(vc*20+16):(vc*20+18)] = np.frombuffer(np.float64(src_cfg["Ypol_offset0"]).tobytes(), dtype=np.uint32)
        config_array_buf1[(vc*20+16):(vc*20+18)] = np.frombuffer(np.float64(src_cfg["Ypol_offset1"]).tobytes(), dtype=np.uint32)
        
        # word 9 = Validity time
        # bits 31:0 = buf_integration : Integration period at which the polynomial becomes valid. Integration period
        #                     is in units of 0.84934656 seconds, i.e. units of (384 SPS packets) 
        # bit 32 = Entry is valid.
        config_array_buf0[vc*20+18] = np.frombuffer(np.int32(src_cfg["integration0"]).tobytes(), dtype=np.uint32)
        config_array_buf1[vc*20+18] = np.frombuffer(np.int32(src_cfg["integration1"]).tobytes(), dtype=np.uint32)
        
        config_array_buf0[vc*20+19] = np.frombuffer(np.int32(src_cfg["valid0"]).tobytes(), dtype=np.uint32)
        config_array_buf1[vc*20+19] = np.frombuffer(np.int32(src_cfg["valid1"]).tobytes(), dtype=np.uint32)
        
    return (config_array_buf0, config_array_buf1, vc_max)

"""
def create_stream(config, filters, stream_index, n_samples):
    
 #   create a data stream from the config data.
 #   Uses data specification for 4 sources,
 #   in config["sources"][stream_index*4:stream_index*4+4]
 #   :param config: configuration data as read from the yaml file,
 #   config["sources"][source number]["poly","sky_freq","seed","tone_freq","select_tone","scale"]
  #  :param filters: 2048x32 numpy array with interpolation filter coefficients.
  #  :param stream_index: specifies the set of sources to use
  #  :param n_samples: Number of samples to generate
    
    # Generate an extra 2048 samples to prevent running out of samples
    # due to the coarse (sample) delay.
    n_samples_extra = n_samples + 2048
    source_samples = np.zeros(n_samples_extra, dtype=np.complex128)
    interpolated = np.zeros(n_samples, dtype=np.complex128)
    rotated = np.zeros(n_samples, dtype=np.complex128)
    scaled = np.zeros(n_samples, dtype=np.complex128)
    summed = np.zeros((n_samples, 2), dtype=np.complex128)
    for pol in range(2):
        for data_source in range(4):
            # 8 consecutive sources specify one data stream.
            # 4 for the first polarisation, then 4 for the second polarisation
            s_index = stream_index*8 + pol*4 + data_source
            if s_index in config["sources"]:
                if config["sources"][s_index]["select_tone"]:
                    phase_step = np.double(config["sources"][s_index]["tone_freq"])
                    phase = 2 * np.pi * phase_step/32768 * np.arange(n_samples_extra)
                    source_samples = 16384 * np.exp(1j*phase)
                else:
                    seed = config["sources"][s_index]["seed"]
                    source_samples = np.double(rand64(seed, n_samples_extra, True)) + \
                        1j * np.double(rand64(seed, n_samples_extra, False))
                    src_std = np.std(source_samples)
                # Process blocks of 32 samples
                for sample_block in range(n_samples//32):
                    poly = config["sources"][s_index]["poly"]
                    t = sample_block * 32 * 1080.0e-9
                    # delay in ns
                    delay = poly[0] + poly[1]*t + poly[2]*(t**2) + poly[3]*(t**3) + poly[4]*(t**4) + poly[5]*(t**5)
                    delay_samples = np.uint32(np.floor(delay/1080.0))
                    interp_filter_select = np.uint32(np.round(2048*(delay/1080.0 - delay_samples)))
                    interp_filter = filters[interp_filter_select, :]
                    phase_correction = np.exp(1j * 2 * np.pi * delay * config["sources"][s_index]["sky_freq"])
                    for sample in range(32):
                        # The sample the first filter tap applies to
                        start_sample = 17 + sample_block*32 + delay_samples - 15 + sample
                        # The output sample we are generating
                        cur_sample = sample_block*32 + sample
                        samples_selected = source_samples[start_sample:(start_sample + 32)]
                        # scale by 256 to match intermediate value in the firmware
                        interpolated[cur_sample] = np.sum(interp_filter * samples_selected) / 256
                        rotated[cur_sample] = interpolated[cur_sample] * phase_correction
                        scaled[cur_sample] = rotated[cur_sample] * config["sources"][s_index]["scale"]
                summed[:, pol] += scaled
    # scaling factor : 14 bits for the filter taps, 16 bits for the configured scale factor.
    # less 8 bits already scaled at the output of the filter
    summed = np.round(summed / 2**22)
    summed_std = np.std(summed)
    return summed
"""

def main():
    # Read command-line arguments
    args = command_line_args()
    config = parse_config(args.configuration)
    # convert config into a data file to load into the firmware
    (cfg_array0, cfg_array1, vc_max) = ct1_config(config)
    # Write to file.
    # Writes are in blocks of 20 words, preceded by the address to write to.
    total_blocks = vc_max+1
    first_block = True
    for b in range(total_blocks):
        # 80 bytes per block
        block_addr = b*80
        block_addr2 = 1024*80 + b*80
        non_zero = np.any(cfg_array0[b*20:(b*20+20)])
        if non_zero:
            if not first_block:
                args.data.write("\n")
            first_block = False
            args.data.write(f"[{block_addr:08x}]")
            for n in range(20):
                args.data.write(f"\n{cfg_array0[b*20+n]:08x}")
            args.data.write(f"\n[{block_addr2:08x}]")
            for n in range(20):
                args.data.write(f"\n{cfg_array1[b*20+n]:08x}")
    
    # Also write a configuration file that initialises the entire 1 MByte
    # of configuration address space.
    # This can be used for initialising the hardware, otherwise the ultraRAM
    # buffer could contain anything on startup.
    # 2 buffers, 1024 streams, 20 x 4 byte words
    if args.cfgfull:
        full_config_array = np.zeros(2*1024*20, np.uint32)
        # Load both buffers
        full_config_array[0:cfg_array0.size] = cfg_array0[:]
        full_config_array[20480:(20480+cfg_array1.size)] = cfg_array1[:]
        # Write in blocks of 4 kByte (40 * 4096 = 160 kBytes)
        for block in range(40):
            # Offset is in units of 4 bytes (?)
            if block > 0:
                args.cfgfull.write("\n")
            args.cfgfull.write(f"[vd_datagen.vd_ram.data][{(block*1024)}]")
            for n in range(1024):
                args.cfgfull.write(f"\n0x{full_config_array[block*1024+n]:08x}")


if __name__ == "__main__":
    main()