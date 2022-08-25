# make sure that the file fpgamap_xxxx.py is in PWD (or PYTHONPATH) when running
import logging
from time import sleep
from ska_low_cbf_proc.alveo_cl import MemConfig
from ska_low_cbf_proc.pst_fpga import PstFpga

import sys

print(f"***************** Packet_spam.py ************************")
for i, arg in enumerate(sys.argv):
    print(f"Argument {i:>6}: {arg}")
print(f"*********************************************************\n\n")

XILINX_OUTPUT_DIRECTORY = sys.argv[1]

print(f"XILINX_OUTPUT_DIRECTORY ={XILINX_OUTPUT_DIRECTORY}") 


N_FPGAS = 20
my_logger = logging.getLogger()
#logging.basicConfig(level=logging.DEBUG)
memories = [
    MemConfig(1024 * 4, True),
    MemConfig(1 << 30, True),
    MemConfig(256 << 20, False),
    MemConfig(256 << 20, False),
    MemConfig(256 << 20, False),
    MemConfig(256 << 20, False),
]

fpgas = []
print("Creating FPGA objects")
for n in range(N_FPGAS):
    print("\n***", n, "***\n")
    try:
        this_fpga = PstFpga(
        XILINX_OUTPUT_DIRECTORY +"/"+ "vitisAccelCore.xclbin", my_logger, memories, card=n
        )
        fpgas.append(this_fpga)
    except Exception as e:
        print("%%%%%%%%%%%% EXCEPTION %%%%%%%%%%%%%")
        print(e)
        print("%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%")
    finally:
        print(f"end {n}\n")

# we need to wait 3s for background polling loop
# to initialise
sleep(1)
print("Enabling output & packet generator")
for fpga in fpgas:
    print(".",end ='')
    fpga.packetiser.enable = False
    # RESET
    fpga._fpga["drp"]["cmac_stat_reset"] = 1
    fpga._fpga["drp"]["cmac_stat_reset"] = 0
    # Enable Packetiser to insert IP headers etc so that Spam doesn't taste so bad
    fpga.packetiser.control_vector = fpga.packetiser.control_vector.value | 8

    # Reset the GTP's and counters
    #fpga._fpga["system"]["qsfpgty_resets"] = 1
    #fpga._fpga["system"]["qsfpgty_resets"] = 0
    
    # note this is a combination field, low 16 bits are dst, high 16 bits are src
    #fpga._fpga["packetiser"]["data"][10] = 9510
 
print ("\n\n\n********** Please clear the P4 switch counters with the command 'pm port-stats-clr -/-'")
print ("\n********** Use the command 'pm show' on the switch to see the counters ")
input ("\n********** Once done Press Enter to continue...")

for fpga in fpgas: 
    fpga.packetiser.enable = True
    fpga.packetiser.generator = True

sleep(1)
while True:
    print(f"{len(fpgas)} FPGAs")
    print(f"{'TX':>12s} {'RX':>12} {'Bad FCS':>12} {'Bad Code':>12}")
    for n in range(len(fpgas)):
        print(
            f'{fpgas[n]._fpga["system"]["eth100g_tx_total_packets"].value:12d}',
            f'{fpgas[n]._fpga["system"]["eth100g_rx_total_packets"].value:12d}',
            f'{fpgas[n]._fpga["system"]["eth100g_rx_bad_fcs"].value:12d}',
            f'{fpgas[n]._fpga["system"]["eth100g_rx_bad_code"].value:12d}',
        )
    print("-" * 51)
    sleep(1)
