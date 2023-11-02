create_ip -name dds_compiler -vendor xilinx.com -library ip -version 6.0 -module_name GenSinCos
set_property -dict [list CONFIG.Component_Name {GenSinCos} CONFIG.PartsPresent {SIN_COS_LUT_only} CONFIG.Noise_Shaping {Taylor_Series_Corrected} CONFIG.Phase_Width {24} CONFIG.Output_Width {18} CONFIG.Amplitude_Mode {Unit_Circle} CONFIG.Parameter_Entry {Hardware_Parameters} CONFIG.Has_Phase_Out {false} CONFIG.DATA_Has_TLAST {Not_Required} CONFIG.S_PHASE_Has_TUSER {Not_Required} CONFIG.M_DATA_Has_TUSER {Not_Required} CONFIG.Latency {7} CONFIG.Output_Frequency1 {0} CONFIG.PINC1 {0} CONFIG.Negative_Sine {true}] [get_ips GenSinCos]
create_ip_run [get_ips GenSinCos]

create_ip -name cmpy -vendor xilinx.com -library ip -version 6.0 -module_name FineDelayComplexMult
set_property -dict [list CONFIG.Component_Name {FineDelayComplexMult} CONFIG.BPortWidth {18} CONFIG.OptimizeGoal {Performance} CONFIG.RoundMode {Truncate} CONFIG.OutputWidth {35} CONFIG.MinimumLatency {4}] [get_ips FineDelayComplexMult]
create_ip_run [get_ips FineDelayComplexMult]
