----------------------------------------------------------------------------------
-- Company:  CSIRO
-- Engineer: David Humphrey (dave.humphrey@csiro.au)
-- 
-- Create Date:    12:17:33 03/02/2010 
-- Module Name:    packet_receive - Behavioral 
-- Description: 
--   Logs data from a packet interface to a file.
--
--
-- Output text file format matches the input file format used for the atomic cots testbench "tb_vitisAccelCore":
--  hread(line_in,LFAArepeats,good);
--  hread(line_in,LFAAData,good);
--  hread(line_in,LFAAvalid,good);
--  hread(line_in,LFAAeop,good);
--  hread(line_in,LFAAerror,good);
--  hread(line_in,LFAAempty0,good);
--  hread(line_in,LFAAempty1,good);
--  hread(line_in,LFAAempty2,good);
--  hread(line_in,LFAAempty3,good);
--  hread(line_in,LFAAsop,good);
--
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

use std.textio.all;
use IEEE.std_logic_textio.all;

--library textutil;       -- Synposys Text I/O package
--use textutil.std_logic_textio.all;

entity lbus_packet_receive is
   Generic (
      log_file_name : string := "logfile.txt"
   );
   Port ( 
      clk     : in  std_logic;     -- clock
      i_rst   : in  std_logic;     -- reset input
      i_din   : in  std_logic_vector(511 downto 0);  -- actual data out.
      i_valid : in  std_logic_vector(3 downto 0);     -- data out valid (high for duration of the packet)
      i_eop   : in  std_logic_vector(3 downto 0);
      i_sop   : in  std_logic_vector(3 downto 0);
      i_empty0 : in std_logic_vector(3 downto 0);
      i_empty1 : in std_logic_vector(3 downto 0);
      i_empty2 : in std_logic_vector(3 downto 0);
      i_empty3 : in std_logic_vector(3 downto 0)
   );
end lbus_packet_receive;

architecture Behavioral of lbus_packet_receive is

   constant one0 : std_logic_vector(3 downto 0) := "0000";
   constant FOUR0 : std_logic_vector(15 downto 0) := x"0000";
   constant FOUR1 : std_logic_vector(3 downto 0) := "0001";
   constant T0 : std_logic_vector(511 downto 0) := (others => '0');

begin

    
	cmd_store_proc : process
		file logfile: TEXT;
		--variable data_in : std_logic_vector((BIT_WIDTH-1) downto 0);
		variable line_out : Line;
    begin
	    FILE_OPEN(logfile,log_file_name,WRITE_MODE);
		
		loop
            -- wait until we need to read another command
            -- need to when : rising clock edge, and last_cmd_cycle high
            -- read the next entry from the file and put it out into the command queue.
            wait until rising_edge(clk);
            if i_valid /= "0000" then
                -- write data to the file
                hwrite(line_out,FOUR0,RIGHT,4);  -- repeats of this line, tied to 0
                hwrite(line_out,i_din,RIGHT,130);
                hwrite(line_out,i_valid,RIGHT,2);
                hwrite(line_out,i_eop,RIGHT,2);
                hwrite(line_out,one0,RIGHT,2);  -- error, tied to 0
                hwrite(line_out,i_empty0,RIGHT,2);
                hwrite(line_out,i_empty1,RIGHT,2);
                hwrite(line_out,i_empty2,RIGHT,2);
                hwrite(line_out,i_empty3,RIGHT,2);
                hwrite(line_out,i_sop,RIGHT,2);
             
                writeline(logfile,line_out);
            end if;
         
        end loop;
        file_close(logfile);	
        wait;
    end process cmd_store_proc;


end Behavioral;

