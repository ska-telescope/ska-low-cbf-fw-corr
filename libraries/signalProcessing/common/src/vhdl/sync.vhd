----------------------------------------------------------------------------------
-- Company:     CSIRO
-- Create Date: Nov 2020
-- Engineer:    Giles Babich
--
-- General purpose synchroniser to utilise common timing constraint.
-- there is no reference to component name in timing constraint, just instance.
-- therefore use an instance name of sync_INSERT UNIQUE NAME HERE_sig
-- set_false_path -from [get_pins -hier -filter {NAME=~*/sync_*_sig/delay_reg[0]/C}] -to [get_pins -hier -filter {NAME=~*/sync_*_sig/delay_reg[1]/D}]
----------------------------------------------------------------------------------


library IEEE, XPM;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use xpm.vcomponents.all;

library UNISIM;
use UNISIM.VComponents.all;


entity sync is
    generic (
        USE_XPM     : boolean   := true;        -- IF false see comment above about timing constraint.
        WIDTH       : integer   := 1;
        MAX_ROUTE   : string    := "400ps"
    );
    Port ( 
        Clock_a     : in std_logic;
        Clock_b     : in std_logic;
        data_in     : in std_logic_vector((WIDTH-1) downto 0);
        data_out    : out std_logic_vector((WIDTH-1) downto 0)
    );
end sync;

architecture rtl of sync is

CONSTANT USE_NOT_XPM : boolean := (NOT USE_XPM);

signal delay        : std_logic_vector(2 downto 0);

attribute maxdelay : string;
attribute ASYNC_REG : string;
   
attribute maxdelay of delay : signal is MAX_ROUTE;
attribute ASYNC_REG of delay: signal is "TRUE";

begin

XPM_INST : IF USE_XPM GENERATE

    bits_to_sync : FOR I in 0 to (WIDTH-1) GENERATE

        xpm_cdc_inst : xpm_cdc_single
            generic map (
                DEST_SYNC_FF    => 4,   
                INIT_SYNC_FF    => 1,   
                SRC_INPUT_REG   => 1,   
                SIM_ASSERT_CHK  => 1    
            )
            port map (
                dest_clk        => Clock_b,   
                dest_out        => data_out(I), 
                        
                src_clk         => Clock_a,    
                src_in          => data_in(I)
            );
            
    END GENERATE;
    
        
END GENERATE;



USE_RTL : IF USE_NOT_XPM GENERATE

CDC : process(clock_a)
begin
    if rising_edge(clock_a) then
        delay(0)    <= data_in(0);
    end if;
end process;


CDC_b : process(clock_b)
begin
    if rising_edge(clock_b) then
        delay(1)    <= delay(0);
        delay(2)    <= delay(1);
    end if;
end process;

data_out(0) <= delay(2);

END GENERATE;

end rtl;
