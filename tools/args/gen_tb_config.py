#! /usr/bin/env python3
###############################################################################
#
# Copyright (C) 2021
# CSIRO (Commonwealth Scientific and Industrial Research Organization) <http://www.csiro.au/>
# GPO Box 1700, Canberra, ACT 2601, Australia
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
#   Author           Date      Version comments
#   David Humphrey   Jan 2021  Original
#
###############################################################################

"""
    Converts a text file with register data that can be loaded in the register viewer to a very similar file with actual addresses that the testbench uses.
    
    Two input files :
     - <fpga name>.ccfg
        The .ccfg file is generated in ARGS using the script "gen_c_config.py"
     - <datafile>.txt
        Contains the data to be written to the registers. This is in the format accepted by the gemini viewer tool,
        consisting of the register name followed by a list of 32 bit hex value to write to the register.
        E.g.
            [lfaadecode100g.statctrl.vctable][0]
            0x00212241
            0x00412241
            0x00612241
            ...
            
    One output file :
     - <datafile>.txt
        Contains the same data as the input datafile, but with the register names replaced with addresses and size (number of words to write to that address).

    Program structure:
     (1) Read in the .ccfg file, and create a dictionary to link register names to addreses
     (2) Parse the data file
     
     
"""

import sys
import os
from argparse import ArgumentParser


if __name__ == '__main__':

    parser = ArgumentParser(
        description='ARGS tool script to generate testbench input data with actual addresses.')
    parser.add_argument('-c', '--ccfg', required=True, help='ARGS ccfg file name')
    parser.add_argument('-i', '--input', required=True, help='Input data file name')
    parser.add_argument('-o', '--output', required=True, help='Output data file name')
    
    ccfg_name = parser.parse_args().ccfg
    input_name = parser.parse_args().input
    output_name = parser.parse_args().output
    
    # Parse the ccfg file
    nameAddrDict = {}
    with open(ccfg_name,'r') as ccfg:
        for ccfg_line in ccfg:
            ccfg_split = ccfg_line.split() 
            if (ccfg_split[0] == "BitField" or ccfg_split[0] == "BlockRAM" or ccfg_split[0] == "DistrRAM"):
                address = ccfg_split[1]
                concatenatedName = ""
                for concatElement in ccfg_split[4:]:
                    concatenatedName = concatenatedName + '.' + concatElement
                name = concatenatedName[1:]
                nameAddrDict[name] = address
                
    #
    #print(nameAddrDict)
    
    # Parse the input file
    with open(input_name,'r') as inputData:
        dataList = []
        burstActive = False
        outString = ''
        for inputLine in inputData:
            inputLine3 = inputLine.replace(']',' ')
            inputLine4 = inputLine3.replace('[',' ')
            inputSplit = inputLine4.split()
            if (inputLine[0] == '['):
                if burstActive:
                    # write out the previous command now we know how many data words there are. Note length is the number of bytes, not words.
                    outString = outString + 'wr ' + "{0:0>8x}".format(wrAddr) + ' ' + "{0:0>8x}".format(4*len(dataList)) + '\n'
                    for dout in dataList:
                        outString = outString + dout + '\n'
                    dataList = []
                    burstActive = False;
                if inputSplit[0] in nameAddrDict:
                    wrAddr = nameAddrDict[inputSplit[0]]
                    wrAddrOffset = inputSplit[1]
                    wrAddr = int(wrAddr,16) + int(wrAddrOffset,10);
                    wrAddr = 4 * wrAddr  # convert from word address to byte address.
                    burstActive = True;
                else:
                    print('Register ' + inputSplit[0] + ' was not found in the ccfg file, ignoring it.')
                    wrAddr = '0'
                
            else:
                dataList.append(inputSplit[0][2:])
        # Put in the last transaction
        if burstActive:
            outString = outString + 'wr ' + "{0:0>8x}".format(wrAddr) + ' ' + "{0:0>8x}".format(4*len(dataList)) + '\n'
            for dout in dataList:
                outString = outString + dout + '\n'
            burstActive = False;
        # write to a file
        outputData = open(output_name,'w')
        outputData.write(outString)
        outputData.close()