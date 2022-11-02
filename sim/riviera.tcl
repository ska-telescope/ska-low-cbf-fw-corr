set_property target_simulator Riviera [current_project]
set_property -name {riviera.simulate.asim.more_options} -value {-ieee_nowarn} -objects [get_filesets sim_1]
set_property -name {riviera.compile.vhdl_syntax} -value {2008} -objects [get_filesets sim_1]
set_property -name {riviera.compile.vhdl_relax} -value {true} -objects [get_filesets sim_1]
set_property -name {riviera.simulate.runtime} -value {2000us} -objects [get_filesets sim_1]
set_property simulator_language VHDL [current_project]

###################################
## design needs to be synthesised to create all the output products for Riviera.
launch_runs synth_1 -jobs 16
wait_on_run synth_1

## if {$argc > 0} {
##   set_property generic "LFAA_BLOCKS_PER_FRAME_DIV3_generic=[lindex $argv 0] default_bigsim=[lindex $argv 1]" -object [get_filesets sim_1]
## }
launch_simulation -batch

