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

# 31 FIR tap deripple filter, for the SPS 18-tap filter 
c_deripple = np.array([5,-7,12,-21,31,169,-676,504,-833,1007,-1243,1442,-1620,1756,-1842,68166,-1842,1756,-1620,1442,-1243,1007,-833,504,-676,169,31,-21,12,-7,5])

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
    parser.add_argument(
        "-t",
        "--tbdata",
        type=argparse.FileType(mode="rt"),
        help="File to read CT1 output from",
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

def conv_signed_16bit(din):
    if din > 32767:
        return (din - 65536)
    else:
        return (din)

def get_tb_data(tb_file, virtual_channels):
    # Load data saved by the testbench
    # File Format : text
    #   - 4 lines of meta data, one per channel
    #                  <1-4> HdeltaP, HoffsetP, VdeltaP, VoffsetP, integration, frame, virtual channel
    # array element:    0       1       2         3          4           5        6          7 
    #   - 4096 lines of data   
    #      5 <re Hpol> <im Hpol> <re Vpol> <im Vpol> ... (x4 for 4 virtual channels)

    first_integration_set = False
    first_integration = 0
    # Number of packets received for each integration, frame and virtual channel
    packet_count = np.zeros((10,3,virtual_channels),dtype=np.int32)
    # meta data : [integration, frame, packet, vc, hdelta/Hoffset/Vdelta/Voffset]
    # 75 packets = 11 preload + 64 per frame
    meta_data = np.zeros((10,3,75,virtual_channels,4),dtype = np.int64)
    # data [integration,frame,packet,vc,Hre/Him/Vre/Vim,sample]
    data_data = np.zeros((10,3,75,virtual_channels,4,4096), dtype = np.int32)
    vc_list = np.zeros(4,dtype = np.int32)
    for line in tb_file:
        dval = line.split()
        dint = [int(di,16) for di in dval]
        if dint[0] == 1:
            if not first_integration_set:
                first_integration_set = True
                first_integration = dint[5]
        if (dint[0] == 1 or dint[0] == 2 or dint[0] == 3 or dint[0] == 4):
            integration = dint[5] - first_integration
            frame = dint[6]
            vc = dint[7]
            vc_list[dint[0]-1] = vc
            # meta data indexed by [integration, frame (0,1,2), packet (), vc, parameter]
            #  where parameter : 0 = HdeltaP, 1 = HoffsetP, 2 = VdeltaP, 3 = VoffsetP
            meta_data[integration, frame, packet_count[integration, frame, vc], vc, 0] = dint[1]
            meta_data[integration, frame, packet_count[integration, frame, vc], vc, 1] = dint[2]
            meta_data[integration, frame, packet_count[integration, frame, vc], vc, 2] = dint[3]
            meta_data[integration, frame, packet_count[integration, frame, vc], vc, 3] = dint[4]
            packet_count[integration, frame, vc] = packet_count[integration, frame, vc] + 1
            dcount = 0
        else:
            # dint[0] == 5, the data part
            # data_data index by [integration, frame, packet_count, vc, Hre/Him/Vre/Vim, sample
            if dcount == 4095:
                print(f"Read last element of testbench packet : integration {integration}, frame = {frame}, packet_count = {packet_count[integration,frame,vc]}")
            if dcount > 4095:
                print(f"!!!!! Too many samples in the packet to the filterbank, dcount = {dcount}")
            data_data[integration, frame, packet_count[integration,frame,vc] - 1, vc_list[0], 0, dcount] = conv_signed_16bit(dint[1])
            data_data[integration, frame, packet_count[integration,frame,vc] - 1, vc_list[0], 1, dcount] = conv_signed_16bit(dint[2])
            data_data[integration, frame, packet_count[integration,frame,vc] - 1, vc_list[0], 2, dcount] = conv_signed_16bit(dint[3])
            data_data[integration, frame, packet_count[integration,frame,vc] - 1, vc_list[0], 3, dcount] = conv_signed_16bit(dint[4])
            data_data[integration, frame, packet_count[integration,frame,vc] - 1, vc_list[1], 0, dcount] = conv_signed_16bit(dint[5])
            data_data[integration, frame, packet_count[integration,frame,vc] - 1, vc_list[1], 1, dcount] = conv_signed_16bit(dint[6])
            data_data[integration, frame, packet_count[integration,frame,vc] - 1, vc_list[1], 2, dcount] = conv_signed_16bit(dint[7])
            data_data[integration, frame, packet_count[integration,frame,vc] - 1, vc_list[1], 3, dcount] = conv_signed_16bit(dint[8])
            data_data[integration, frame, packet_count[integration,frame,vc] - 1, vc_list[2],0, dcount] = conv_signed_16bit(dint[9])
            data_data[integration, frame, packet_count[integration,frame,vc] - 1, vc_list[2],1, dcount] = conv_signed_16bit(dint[10])
            data_data[integration, frame, packet_count[integration,frame,vc] - 1, vc_list[2],2, dcount] = conv_signed_16bit(dint[11])
            data_data[integration, frame, packet_count[integration,frame,vc] - 1, vc_list[2],3, dcount] = conv_signed_16bit(dint[12])
            data_data[integration, frame, packet_count[integration,frame,vc] - 1, vc_list[3],0, dcount] = conv_signed_16bit(dint[13])
            data_data[integration, frame, packet_count[integration,frame,vc] - 1, vc_list[3],1, dcount] = conv_signed_16bit(dint[14])
            data_data[integration, frame, packet_count[integration,frame,vc] - 1, vc_list[3],2, dcount] = conv_signed_16bit(dint[15])
            data_data[integration, frame, packet_count[integration,frame,vc] - 1, vc_list[3],3, dcount] = conv_signed_16bit(dint[16])
            dcount = dcount + 1
    
    return (meta_data, data_data, packet_count)

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

def fix_8bit_rfi(din):
    # take values in the range 0 to 255 and convert to integers, with
    # x=128 = 0x80 = RFI => 0
    # x>128 = negative => x-256
    # x<128 = positive => x
    dout = din
    for n1 in range(din.size):
        if (din[n1] == 128):
            dout[n1] = 0
        elif din[n1] > 128:
            dout[n1] = din[n1] - 256
        else:
            dout[n1] = din[n1]
    return dout

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

    # Get the output of the simulation
    if args.tbdata:
        (meta_data, data_data, packet_count) = get_tb_data(args.tbdata, total_blocks)
        tb_valid = True
    else:
        tb_valid = False
    
    # Calculate the expected delays for each virtual channel
    integration_start = config["integration_start"]
    sim_frames = config["sim_frames"]
    data_mismatch = 0
    data_match = 0
    meta_match = 0
    meta_mismatch = 0
    for frame in range(sim_frames):
        integration_offset = frame // 3
        integration = integration_start + integration_offset
        frame_in_integration = frame - integration_offset * 3
        for vc in range(vc_max + 1):
            # Find the config entry for this virtual channel
            vc_found = False
            for n, src_cfg in config["polynomials"].items():
                this_vc = src_cfg["virtual_channel"]
                if vc == this_vc:
                    if vc_found == True:
                        print(f"!!!! Multiple instances of virtual channel {this_vc} in config yaml file")
                    vc_found = True
                    cfg_n = n
            if  not vc_found:
                print(f"!!! frame {frame}, No specification for virtual channel {vc}")
            else:
                src_cfg = config["polynomials"][vc]
                if (src_cfg["valid0"]==1) and (integration >= src_cfg["integration0"]):
                    cfg0_valid = True
                else:
                    cfg0_valid = False
                if (src_cfg["valid1"]==1) and (integration >= src_cfg["integration1"]):
                    cfg1_valid = True
                else:
                    cfg1_valid = False
               
                if cfg1_valid and ((not cfg0_valid) or (src_cfg["integration1"] > src_cfg["integration0"])):
                    # select second configuration
                    poly = src_cfg["poly1"]
                    # sky frequency in GHz
                    sky_freq = src_cfg["sky_freq1"]
                    # Validity time : 32 bit buf_integration: Integration period at which the polynomial becomes valid.
                    integration_validity = src_cfg["integration1"]
                    # seconds from the polynomial epoch to the start of the integration period, as a double precision value
                    buf_offset = src_cfg["buf_offset1"]
                    # Double precision offset in ns for the second polarisation (relative to the first polarisation). 
                    Ypol_offset = src_cfg["Ypol_offset1"]
                else:
                    if (not cfg0_valid) and (not cfg1_valid):
                        print(f"No valid polynomials, ")
                    # select first configuration
                    poly = src_cfg["poly0"]
                    sky_freq = src_cfg["sky_freq0"]
                    integration_validity = src_cfg["integration0"]
                    buf_offset = src_cfg["buf_offset0"]
                    Ypol_offset = src_cfg["Ypol_offset0"]
                
                for packet in range(75):
                    # 75 packets produced by CT1 for each frame
                    # 11 preload packets, then 64 packets.
                    # Time in seconds in the polynomial
                    t = buf_offset + frame_in_integration * 0.283115520 + (integration - integration_validity) * 0.849346560
                    # Each packet is 4.4ms
                    if packet > 10:
                        t = t + (packet-11) * 0.00442368
                    delay_Xpol = poly[0] + poly[1]*t + poly[2]*(t**2) + poly[3]*(t**3) + poly[4]*(t**4) + poly[5]*(t**5)
                    delay_Ypol = delay_Xpol + Ypol_offset
                    delay_samples_Xpol = delay_Xpol/1080.0
                    delay_samples_Ypol = delay_Ypol/1080.0
                    if packet == 0:
                        coarse_delay = np.int32(np.floor(delay_samples_Xpol))
                    fine_delay_Xpol = delay_samples_Xpol - coarse_delay
                    fine_delay_Ypol = delay_samples_Ypol - coarse_delay
                    if (fine_delay_Xpol >= 0):
                        fine_delay_Xpol = np.int64(np.floor(fine_delay_Xpol * 16384*65536))
                    else:
                        fine_delay_Xpol = 65536*65536 - np.int64(np.floor(-fine_delay_Xpol*16384*65536))
                    if (fine_delay_Ypol >= 0):
                        fine_delay_Ypol = np.int64(np.floor(fine_delay_Ypol * 16384*65536))
                    else:
                        fine_delay_Ypol = 65536*65536 - np.int64(np.floor(-fine_delay_Ypol*16384*65536))
                    phase_X = delay_Xpol * sky_freq
                    phase_Y = delay_Ypol * sky_freq
                    phase_X = np.int64(np.floor(65536*65536 * (phase_X - np.floor(phase_X))))
                    phase_Y = np.int64(np.floor(65536*65536 * (phase_Y - np.floor(phase_Y))))
                    
                    # print(f"VC = {vc}, (int,frame,packet) = ({integration},{frame_in_integration},{packet}) coarse = {coarse_delay}, fine X = {fine_delay_Xpol}, fine Y = {fine_delay_Ypol}, phase X = {phase_X}, phase_Y = {phase_Y}")
                    if tb_valid:
                        # Compare with the data loaded from the testbench
                        # Calculate which sample this packet should start at
                        # Simulation puts the sample number in the data, where the 
                        # sample number is the number of samples since the epoch
                        first_sample = integration * 192 * 4096 + frame_in_integration * 64*4096 + packet*4096 - 6*4096 - coarse_delay
                        
                        
                        # create the expected value
                        # Apply the deripple FIR filter = c_deripple = [5,-7,12,-21,31,169,-676,504,-833,1007,-1243,1442,-1620,1756,-1842,68166,-1842,1756,-1620,1442,-1243,1007,-833,504,-676,169,31,-21,12,-7,5]
                        # to the expected data
                        # 
                        # Get the expected samples that the deripple filter is applied to. Initialisation of the FIR filter needs:
                        #  - 15 samples extra at the front
                        #  - total 30 samples extra
                        first_sample = integration * 192 * 4096 + frame_in_integration * 64*4096 + packet*4096 - 6*4096 - coarse_delay - 15
                        packet_samples = np.arange(first_sample,first_sample+2048+30)
                        expected_packet_Xre = fix_8bit_rfi(packet_samples % 256)
                        expected_packet_Xim = fix_8bit_rfi((packet_samples // 256) % 256)
                        expected_packet_Yre = fix_8bit_rfi((packet_samples // 65536) % 256)
                        expected_packet_Yim = fix_8bit_rfi(vc * np.ones(2048+30))   # Yim is fixed to the virtual channel in the testbench
                        #if (packet == 0) and (vc == 0):
                        #    print(f"First 31 packet samples = {packet_samples[0:32]}")
                        
                        for sample in range(2048):
                            Xre = data_data[integration_offset,frame_in_integration,packet,vc,0,sample]
                            Xim = data_data[integration_offset,frame_in_integration,packet,vc,1,sample]
                            Yre = data_data[integration_offset,frame_in_integration,packet,vc,2,sample]
                            Yim = data_data[integration_offset,frame_in_integration,packet,vc,3,sample]
                            
                            # Apply the deripple filter to the expected values
                            expected_Xre = 0
                            expected_Xim = 0
                            expected_Yre = 0
                            expected_Yim = 0
                            for FIR_tap in range(31):
                                expected_Xre = expected_Xre + c_deripple[FIR_tap] * expected_packet_Xre[sample + FIR_tap]
                                expected_Xim = expected_Xim + c_deripple[FIR_tap] * expected_packet_Xim[sample + FIR_tap]
                                expected_Yre = expected_Yre + c_deripple[FIR_tap] * expected_packet_Yre[sample + FIR_tap]
                                expected_Yim = expected_Yim + c_deripple[FIR_tap] * expected_packet_Yim[sample + FIR_tap]
                                #if (sample == 0) and (packet == 0) and (vc == 0):
                                #    print(f"FIR {FIR_tap}, FIR tap = {c_deripple[FIR_tap]}, data = {expected_packet_Xre[sample + FIR_tap]}, cumulative sum = {expected_Xre}")
                            
                            # divide by 512, convergent round to even
                            expected_Xre = np.round(expected_Xre / 512)
                            expected_Xim = np.round(expected_Xim / 512)
                            expected_Yre = np.round(expected_Yre / 512)
                            expected_Yim = np.round(expected_Yim / 512)
                            if (expected_Xre != Xre) or (expected_Xim != Xim) or (expected_Yre != Yre) or (expected_Yim != Yim):
                                if data_mismatch < 20:
                                    print(f"Bad sample : VC = {vc}, (int,frame,packet) = ({integration},{frame_in_integration},{packet}) coarse = {coarse_delay}")
                                    print(f"   At sample {sample}, expected ({expected_Xre},{expected_Xim},{expected_Yre},{expected_Yim}), testbench = ({Xre},{Xim},{Yre},{Yim})")
                                data_mismatch += 1
                            else:
                                data_match += 1 
                        # Compare fine delays
                        fine_delay_Xpol_tb = meta_data[integration_offset,frame_in_integration,packet,vc,0]
                        phase_X_tb = meta_data[integration_offset,frame_in_integration,packet,vc,1]
                        fine_delay_Ypol_tb = meta_data[integration_offset,frame_in_integration,packet,vc,2]
                        phase_Y_tb = meta_data[integration_offset,frame_in_integration,packet,vc,3]
                        #if ((fine_delay_Xpol_tb != fine_delay_Xpol) or (fine_delay_Ypol_tb != fine_delay_Ypol) or (phase_X_tb != phase_X) or (phase_Y_tb != phase_Y)):
                        if ((np.abs(fine_delay_Xpol_tb - fine_delay_Xpol) > 1) or (np.abs(fine_delay_Ypol_tb - fine_delay_Ypol) > 1) or (np.abs(phase_X_tb - phase_X) > 1) or (np.abs(phase_Y_tb - phase_Y) > 1)):
                            if meta_mismatch < 20:
                                print(f"PYTHON : VC = {vc}, (int,frame,packet) = ({integration},{frame_in_integration},{packet}) coarse = {coarse_delay}, fine X = {fine_delay_Xpol}, fine Y = {fine_delay_Ypol}, phase X = {phase_X}, phase_Y = {phase_Y}")    
                                print(f"    TB : fine X = {fine_delay_Xpol_tb}, fine Y = {fine_delay_Ypol_tb}, phase X = {phase_X_tb}, phase_Y = {phase_Y_tb}")
                            meta_mismatch += 1
                        else:
                            meta_match += 1
                    else:
                        print(f"No tb data : VC = {vc}, (int,frame,packet) = ({integration},{frame_in_integration},{packet}) coarse = {coarse_delay}, fine X = {fine_delay_Xpol}, fine Y = {fine_delay_Ypol}, phase X = {phase_X}, phase_Y = {phase_Y}")

    if tb_valid:
        print(f"checked {sim_frames} frames against simulation")
        print(f"    data sample mismatch = {data_mismatch}, data samples matched = {data_match} ")
        print(f"    meta data mismatch = {meta_mismatch}, meta data matched = {meta_match}")

if __name__ == "__main__":
    main()