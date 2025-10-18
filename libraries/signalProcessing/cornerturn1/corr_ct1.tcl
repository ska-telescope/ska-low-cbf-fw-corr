create_ip -name blk_mem_gen -vendor xilinx.com -library ip -version 8.4 -module_name ct_valid_bram
set_property -dict [list CONFIG.Component_Name {ct_valid_bram} CONFIG.Memory_Type {True_Dual_Port_RAM} CONFIG.Assume_Synchronous_Clk {true} CONFIG.Write_Width_A {1} CONFIG.Write_Depth_A {131072} CONFIG.Read_Width_A {1} CONFIG.Operating_Mode_A {NO_CHANGE} CONFIG.Enable_A {Always_Enabled} CONFIG.Write_Width_B {32} CONFIG.Read_Width_B {1} CONFIG.Operating_Mode_B {READ_FIRST} CONFIG.Enable_B {Always_Enabled} CONFIG.Register_PortA_Output_of_Memory_Primitives {true} CONFIG.Register_PortB_Output_of_Memory_Primitives {true} CONFIG.Port_B_Clock {100} CONFIG.Port_B_Write_Rate {50} CONFIG.Port_B_Enable_Rate {100}] [get_ips ct_valid_bram]
set_property -dict [list CONFIG.Operating_Mode_A {READ_FIRST}] [get_ips ct_valid_bram]
create_ip_run [get_ips ct_valid_bram]

create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -version 4.1 -module_name axi_bram_ctrl_ct1_poly
set_property -dict [list \
  CONFIG.SUPPORTS_NARROW_BURST {0} \
  CONFIG.SINGLE_PORT_BRAM {1} \
  CONFIG.Component_Name {axi_bram_ctrl_ct1_poly} \
  CONFIG.READ_LATENCY {3} \
  CONFIG.MEM_DEPTH {65536}] [get_ips axi_bram_ctrl_ct1_poly]
create_ip_run [get_ips axi_bram_ctrl_ct1_poly]

create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name fp64_add
set_property -dict [list \
  CONFIG.A_Precision_Type {Double} \
  CONFIG.Add_Sub_Value {Add} \
  CONFIG.C_A_Exponent_Width {11} \
  CONFIG.C_A_Fraction_Width {53} \
  CONFIG.C_Accum_Input_Msb {32} \
  CONFIG.C_Accum_Lsb {-31} \
  CONFIG.C_Accum_Msb {32} \
  CONFIG.C_Latency {14} \
  CONFIG.C_Mult_Usage {Full_Usage} \
  CONFIG.C_Rate {1} \
  CONFIG.C_Result_Exponent_Width {11} \
  CONFIG.C_Result_Fraction_Width {53} \
  CONFIG.Component_Name {fp64_add} \
  CONFIG.Flow_Control {NonBlocking} \
  CONFIG.Has_RESULT_TREADY {false} \
  CONFIG.Result_Precision_Type {Double} \
] [get_ips fp64_add]
create_ip_run [get_ips fp64_add]

create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name fp64_mult
set_property -dict [list \
  CONFIG.A_Precision_Type {Double} \
  CONFIG.C_A_Exponent_Width {11} \
  CONFIG.C_A_Fraction_Width {53} \
  CONFIG.C_Accum_Input_Msb {32} \
  CONFIG.C_Accum_Lsb {-31} \
  CONFIG.C_Accum_Msb {32} \
  CONFIG.C_Latency {12} \
  CONFIG.C_Mult_Usage {Full_Usage} \
  CONFIG.C_Rate {1} \
  CONFIG.C_Result_Exponent_Width {11} \
  CONFIG.C_Result_Fraction_Width {53} \
  CONFIG.Component_Name {fp64_mult} \
  CONFIG.Flow_Control {NonBlocking} \
  CONFIG.Has_RESULT_TREADY {false} \
  CONFIG.Operation_Type {Multiply} \
  CONFIG.Result_Precision_Type {Double} \
] [get_ips fp64_mult]
create_ip_run [get_ips fp64_mult]

create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name fp64_to_int
set_property -dict [list \
  CONFIG.A_Precision_Type {Double} \
  CONFIG.C_A_Exponent_Width {11} \
  CONFIG.C_A_Fraction_Width {53} \
  CONFIG.C_Accum_Input_Msb {32} \
  CONFIG.C_Accum_Lsb {-31} \
  CONFIG.C_Accum_Msb {32} \
  CONFIG.C_Latency {6} \
  CONFIG.C_Mult_Usage {No_Usage} \
  CONFIG.C_Rate {1} \
  CONFIG.C_Result_Exponent_Width {32} \
  CONFIG.C_Result_Fraction_Width {32} \
  CONFIG.Component_Name {fp64_to_int} \
  CONFIG.Flow_Control {NonBlocking} \
  CONFIG.Has_RESULT_TREADY {false} \
  CONFIG.Operation_Type {Float_to_fixed} \
  CONFIG.Result_Precision_Type {Custom} \
] [get_ips fp64_to_int]
create_ip_run [get_ips fp64_to_int]

create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name uint64_to_double
set_property -dict [list \
  CONFIG.A_Precision_Type {Uint64} \
  CONFIG.C_A_Exponent_Width {64} \
  CONFIG.C_A_Fraction_Width {0} \
  CONFIG.C_Accum_Input_Msb {32} \
  CONFIG.C_Accum_Lsb {-31} \
  CONFIG.C_Accum_Msb {32} \
  CONFIG.C_Latency {6} \
  CONFIG.C_Mult_Usage {No_Usage} \
  CONFIG.C_Rate {1} \
  CONFIG.C_Result_Exponent_Width {11} \
  CONFIG.C_Result_Fraction_Width {53} \
  CONFIG.Component_Name {uint64_to_double} \
  CONFIG.Flow_Control {NonBlocking} \
  CONFIG.Has_RESULT_TREADY {false} \
  CONFIG.Operation_Type {Fixed_to_float} \
  CONFIG.Result_Precision_Type {Double} \
] [get_ips uint64_to_double]
create_ip_run [get_ips uint64_to_double]

create_ip -name mult_gen -vendor xilinx.com -library ip -version 12.0 -module_name mult_x1e9
set_property -dict [list \
  CONFIG.CcmImp {Dedicated_Multiplier} \
  CONFIG.Component_Name {mult_x1e9} \
  CONFIG.ConstValue {1000000000} \
  CONFIG.MultType {Constant_Coefficient_Multiplier} \
  CONFIG.PipeStages {4} \
  CONFIG.PortAType {Unsigned} \
  CONFIG.PortAWidth {32} \
] [get_ips mult_x1e9]
create_ip_run [get_ips mult_x1e9]

create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name fp64_to_fp32
set_property -dict [list \
  CONFIG.A_Precision_Type {Double} \
  CONFIG.C_A_Exponent_Width {11} \
  CONFIG.C_A_Fraction_Width {53} \
  CONFIG.C_Accum_Input_Msb {32} \
  CONFIG.C_Accum_Lsb {-31} \
  CONFIG.C_Accum_Msb {32} \
  CONFIG.C_Latency {3} \
  CONFIG.C_Mult_Usage {No_Usage} \
  CONFIG.C_Rate {1} \
  CONFIG.C_Result_Exponent_Width {8} \
  CONFIG.C_Result_Fraction_Width {24} \
  CONFIG.Component_Name {fp64_to_fp32} \
  CONFIG.Flow_Control {NonBlocking} \
  CONFIG.Has_RESULT_TREADY {false} \
  CONFIG.Operation_Type {Float_to_float} \
  CONFIG.Result_Precision_Type {Single} \
] [get_ips fp64_to_fp32]
create_ip_run [get_ips fp64_to_fp32]


create_ip -name fir_compiler -vendor xilinx.com -library ip -version 7.2 -module_name sps_flatten
set_property -dict [list \
  CONFIG.CoefficientVector \
{0,  0, 0,    0,  0,   0,   0,   0,  0,    0,   0,    0,   0,    0,   0,     0,    0,     0,    0,     0,    0,     0,    0,     0, 65536,     0,    0,     0,    0,     0,    0,     0,    0,     0,    0,    0,   0,    0,   0,    0,  0,   0,  0,   0,  0,   0,  0,  0, 0, \
 3, -6, 10, -16, 24, -34,  46, -61, 98, -128, 173, -229, 300, -387, 488,  -621, 1881, -1705, 2110, -2498, 2861, -3172, 3411, -3562, 69172, -3562, 3411, -3172, 2861, -2498, 2110, -1705, 1881,  -621,  488, -387, 300, -229, 173, -128, 98, -61, 46, -34, 24, -16, 10, -6, 3, \
 1, -2, 4,   -7, 12, -21,  36, -51, 78, -111, 155, -213, 284, -362, 652, -1263, 1209, -1653, 1944, -2288, 2583, -2843, 3040, -3165, 68751, -3165, 3040, -2843, 2583, -2288, 1944, -1653, 1209, -1263,  652, -362, 284, -213, 155, -111, 78, -51, 36, -21, 12,  -7,  4, -2, 1} \
  CONFIG.Coefficient_Fractional_Bits {0} \
  CONFIG.Coefficient_Sets {3} \
  CONFIG.Coefficient_Sign {Signed} \
  CONFIG.Coefficient_Structure {Inferred} \
  CONFIG.Coefficient_Width {18} \
  CONFIG.Component_Name {sps_flatten} \
  CONFIG.Data_Fractional_Bits {0} \
  CONFIG.Data_Width {8} \
  CONFIG.Output_Rounding_Mode {Full_Precision} \
  CONFIG.Quantization {Integer_Coefficients} \
  CONFIG.Clock_Frequency {300.0} \
  CONFIG.Sample_Frequency {300} \
  CONFIG.Filter_Architecture {Systolic_Multiply_Accumulate} \
  CONFIG.Output_Rounding_Mode {Convergent_Rounding_to_Even} \
  CONFIG.Output_Width {16} \
  CONFIG.M_DATA_Has_TUSER {User_Field} \
  CONFIG.S_DATA_Has_TUSER {User_Field} \
] [get_ips sps_flatten]
create_ip_run [get_ips sps_flatten]

