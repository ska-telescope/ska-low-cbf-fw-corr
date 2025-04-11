#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Created on Wed Aug 17 13:42:14 2022

@author: hum089
"""

# Create VHDL roms for inverse of an integer as a 32-bit floating point value.
import numpy as np
import struct

def float_to_hex(f):
    return hex(struct.unpack('<I', struct.pack('<f', f))[0])[2:]


if __name__ == "__main__":
    
    for rom in range(9):
        rom_name = 'inv_rom' + str(rom)
        with open(rom_name + '.vhd','w') as f:
            f.write('-- Created by python script create_inv_roms.py \n')
            f.write('library ieee;\n')
            f.write('use ieee.std_logic_1164.all;\n')
            f.write('use ieee.std_logic_unsigned.all;\n\n')
            f.write('entity ' + rom_name + ' is \n') 
            f.write('port( \n')
            f.write('    i_clk  : in  std_logic; \n')
            f.write('    i_addr : in  std_logic_vector(8 downto 0); \n')
            f.write('    o_data : out std_logic_vector(31 downto 0) \n')
            f.write('    ); \n')
            f.write('end ' + rom_name + '; \n');
            f.write(' \n')
            f.write('architecture behavioral of ' + rom_name + ' is \n')
            f.write('    type rom_type is array(511 downto 0) of std_logic_vector(31 downto 0); \n')
            f.write('    signal rom : rom_type := (\n')
            for rom_row in range(512):
                # array is (511 downto 0), so first entry is for 511, so flip the order 
                rom_row_reversed = 511 - rom_row
                d = np.float32(rom * 512 + rom_row_reversed)
                if (d == 0):
                    dinv = '00000000'
                else:
                    dinv =  float_to_hex(1/d)
                f.write('    x\"' + dinv + '\"')
                if (rom_row < 511):
                    f.write(', \n')
                else:
                    f.write('); \n')
            f.write('    attribute rom_style : string;\n')
            f.write('    attribute rom_style of ROM : signal is \"block\";\n')
            f.write('    signal data : std_logic_vector(31 downto 0);\n')
            f.write('    \n')
            f.write('begin \n')
            f.write('    process(i_clk) \n')
            f.write('    begin \n')
            f.write('        if rising_edge(i_clk) then \n')
            f.write('            data <= ROM(conv_integer(i_addr)); \n')
            f.write('            o_data <= data;\n')
            f.write('        end if;\n')
            f.write('    end process;\n')
            f.write('end behavioral; \n')
            f.write('')
            
            
            


 
