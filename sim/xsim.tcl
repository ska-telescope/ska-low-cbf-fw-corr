set_property target_simulator "XSim" [current_project]
set_property -name {xsim.compile.xvlog.more_options} -value {-d SIM_SPEED_UP} -objects [get_filesets sim_1]

if {$argc > 0} {
   set_property generic "LFAA_BLOCKS_PER_FRAME_DIV3_generic=[lindex $argv 0] default_bigsim=[lindex $argv 1]" -object [get_filesets sim_1]
}
launch_simulation

run all
