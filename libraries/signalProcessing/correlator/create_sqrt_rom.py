#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Created on Thu Aug 18 14:23:27 2022

@author: hum089
"""

# Create VHDL rom for sqrt of a value in the range 0-4095, scaled to 0 to 255.
import numpy as np

if __name__ == "__main__":
    
    rom_name = 'sqrt_rom'
    with open(rom_name + '.vhd','w') as f:
        f.write('-- Created by python script create_sqrt_rom.py \n')
        f.write('library ieee;\n')
        f.write('use ieee.std_logic_1164.all;\n')
        f.write('use ieee.std_logic_unsigned.all;\n\n')
        f.write('entity ' + rom_name + ' is \n') 
        f.write('port( \n')
        f.write('    i_clk  : in  std_logic; \n')
        f.write('    i_addr : in  std_logic_vector(11 downto 0); \n')
        f.write('    o_data : out std_logic_vector(7 downto 0) \n')
        f.write('    ); \n')
        f.write('end ' + rom_name + '; \n');
        f.write(' \n')
        f.write('architecture behavioral of ' + rom_name + ' is \n')
        f.write('    type rom_type is array(0 to 4095) of std_logic_vector(7 downto 0); \n')
        f.write('    signal rom : rom_type := (\n')
        for rom_row in range(4096):
            d = np.round(255 * np.sqrt(rom_row/4095.0))
            
            f.write('    x\"' + "{0:0{1}x}".format(int(d),2) + '\"')
            if (rom_row < 4095):
                f.write(', \n')
            else:
                f.write('); \n')
        f.write('    attribute rom_style : string;\n')
        f.write('    attribute rom_style of ROM : signal is \"block\";\n')
        f.write('    signal data : std_logic_vector(7 downto 0);\n')
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
            
            
            


 