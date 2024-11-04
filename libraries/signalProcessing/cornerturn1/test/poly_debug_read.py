
import argparse
import struct
import numpy as np
np.set_printoptions(edgeitems=30, linewidth=100000, formatter=dict(float=lambda x: "%.3g" % x))
import matplotlib.pyplot as plt

RECORD_SIZE_BYTES = 32
DECODE_MAX = 528384
#DECODE_MAX = 1000000

def parse_args():
    parser = argparse.ArgumentParser(description="Reader for polynomial debug HBM files")
    parser.add_argument('-f','--file', help="HBM dump filename")
    args = parser.parse_args()
    return args


if __name__ == "__main__":
    # get filename
    args = parse_args()
    filename = args.file

    # read all data in a single operation
    with open(filename, mode="rb") as f:
        data = f.read()
    n_bytes = len(data)
    print(f"{n_bytes} bytes read")
    
    # ensure we're reading whole-32-byte records only
    bytes_to_decode = (n_bytes//RECORD_SIZE_BYTES)*RECORD_SIZE_BYTES
    if bytes_to_decode > (DECODE_MAX * RECORD_SIZE_BYTES):
        bytes_to_decode = DECODE_MAX * RECORD_SIZE_BYTES
        print("Limiting number of records decoded")
    # Number of 32-byte records
    n_records = bytes_to_decode // RECORD_SIZE_BYTES
    print(f"decoding {n_records} records")
    ###############################################################33
    # Numpy arrays for each signal
    # FPGA uptime in seconds
    uptime = np.zeros(n_records, dtype = np.float64)
    # Polynomial evaluation time relative to the SKA epoch
    # combines 
    #  delay_packet (0 to 63, per 283ms corner turn frame), 
    #  poly_ct_frame (0, 1, or 2, 283 ms corner turn frame within an integration)
    #  poly_integration (uint32, integration since SKA epoch)
    sample_time = np.zeros(n_records, dtype = np.float64)
    vc = np.zeros(n_records, dtype = np.uint16)
    delay_offset = np.zeros(n_records, dtype = np.uint16)
    hpol_phase = np.zeros(n_records, dtype = np.uint32)
    hpol_deltaP = np.zeros(n_records, dtype = np.uint32)
    buffer_select = np.zeros(n_records, dtype = np.uint8)
    FIFO_dataCount = np.zeros(n_records, dtype = np.uint16)
    poly_wr_occurred = np.zeros(n_records, dtype = np.uint8)
    poly_wr_addr = np.zeros(n_records, dtype = np.uint16)
    poly_rslt = np.zeros(n_records, dtype = np.float32)
    poly_time = np.zeros(n_records, dtype = np.float32)
    # time per filterbank output sample, about 4.4ms
    t44ms = 4096 * 1080e-9
    # time for a single step of the uptime counter
    uptime_unit = 256 / 300e6
    #  Extract each 32-byte record in turn
    rc = 0
    for offset in range(0, bytes_to_decode, RECORD_SIZE_BYTES):
        rec = data[offset:offset+RECORD_SIZE_BYTES]

        #a, b, c, d, e, f, g, h, j, k = struct.unpack("IHHIIIHHff", rec)
        #print(f"{a},{b},{c},{d},{e},{f},{g},{h},{j},{k}")
        
        s_uptime, delay, delay_offset[rc], hpol_phase[rc], hpol_deltaP[rc], integ, sel_cnt, wr_info, poly_rslt[rc], poly_time[rc] = struct.unpack("IHHIIIHHff", rec)
        uptime[rc] = s_uptime * uptime_unit
        vc[rc] = delay & 0x03ff
        packet_4p4ms = (delay >> 10) & 0x03f
        integration = (integ >> 2)
        ct_frame = integ & 0x3
        # 64 x 4.4ms per corner turn frame, 192 x 4.4ms per integration
        sample_time[rc] = packet_4p4ms * t44ms + integration * t44ms * 192 + ct_frame * t44ms * 64
        buffer_select[rc] = sel_cnt >> 15
        FIFO_dataCount[rc] = sel_cnt & 0x7ff
        poly_wr_occurred[rc] = wr_info >> 15
        poly_wr_addr[rc] = wr_info & 0x7fff
        rc += 1
    
    # Find the number of unique virtual channels
    all_vcs = np.unique(vc)
    print(f"Number of virtual channels found = {all_vcs.size}")
    if all_vcs.size < 100:
        print(f"Virtual channels found : ")
        print(all_vcs)
    
    # Plot delays for all virtual channels
    plt.figure()
    del_mean = np.zeros(16)
    for vc_plot in range(0,16):
        this_vc = np.argwhere(vc == vc_plot)
        this_vc = this_vc[960:]
        plt.subplot(4,4,vc_plot+1)
        del_mean[vc_plot] = np.mean(poly_rslt[this_vc])
        plt.plot(poly_rslt[this_vc], 'g.-')
        plt.ylabel('t (ns)')
        plt.title(f'poly evaluations, vc = {vc_plot}')
        
    vc_diff = np.zeros((16,16))
    for vc1 in range(16):
        for vc2 in range(vc1+1):
            vc_diff[vc1,vc2] = del_mean[vc1] - del_mean[vc2]
    print("mean differences in delays : ")
    print(np.round(vc_diff))
    
    
    # Plot some things for a particular virtual channel
    for vc_plot in range(0,2):
        this_vc = np.argwhere(vc == vc_plot)
        this_vc = this_vc[960:]
        plt.figure()
        plt.plot(sample_time[this_vc], 'r.-')
        plt.title(f'time since epoch for all evaluations, vc = {vc_plot}')
        plt.figure()
        plt.plot(poly_rslt[this_vc],'g.-')
        plt.ylabel('t (ns)')
        plt.title(f'poly evaluations, vc = {vc_plot}')
        
        plt.figure()
        plt.subplot(3,1,1)
        plt.plot(delay_offset[this_vc],'r.-')
        plt.title(f'coarse delay, vc = {vc_plot}')
        plt.subplot(3,1,2)
        plt.plot(hpol_phase[this_vc],'r.-')
        plt.title('Phase offset')
        plt.subplot(3,1,3)
        plt.plot(hpol_deltaP[this_vc],'r.-')
        plt.title('phase slope')
        
        plt.figure()
        plt.plot(poly_time[this_vc],'r.-')
        plt.title(f't used in polynomial, vc = {vc_plot}')
    
        plt.figure()
        plt.subplot(2,1,1)
        plt.plot(uptime[this_vc],'r.-')
        plt.title('uptime')
        plt.subplot(2,1,2)
        plt.plot(buffer_select[this_vc],'r.-')
        plt.title('buffer selected')
        plt.show()
    
    plt.figure()
    plt.subplot(4,1,1)
    plt.plot(poly_wr_occurred,'r.-')
    plt.title('ARGs writes')
    plt.subplot(4,1,2)
    plt.plot(poly_wr_addr,'r.-')
    plt.title('Recent ARGS write address')
    plt.subplot(4,1,3)
    plt.plot(buffer_select,'r.-')
    plt.title('Buffer selected (all VCs)')
    plt.subplot(4,1,4)
    plt.plot(FIFO_dataCount,'r.-')
    plt.title('FIFO data count')
    plt.show()
        
    

