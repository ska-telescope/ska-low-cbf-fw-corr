create_ip -name dsp_macro -vendor xilinx.com -library ip -version 1.0 -module_name dsp_mult_24x24
set_property -dict [list \
    CONFIG.a_binarywidth {0} \
    CONFIG.a_width {24} \
    CONFIG.areg_3 {true} \
    CONFIG.areg_4 {false} \
    CONFIG.b_binarywidth {0} \
    CONFIG.b_width {24} \
    CONFIG.breg_3 {true} \
    CONFIG.breg_4 {false} \
    CONFIG.c_binarywidth {0} \
    CONFIG.c_width {48} \
    CONFIG.concat_binarywidth {0} \
    CONFIG.concat_width {48} \
    CONFIG.creg_3 {false} \
    CONFIG.creg_4 {false} \
    CONFIG.creg_5 {false} \
    CONFIG.d_width {18} \
    CONFIG.instruction1 {A*B} \
    CONFIG.mreg_5 {true} \
    CONFIG.p_binarywidth {0} \
    CONFIG.p_full_width {48} \
    CONFIG.p_width {48} \
    CONFIG.pcin_binarywidth {0} \
    CONFIG.pipeline_options {Expert} \
    CONFIG.preg_6 {true} \
] [get_ips dsp_mult_24x24]
create_ip_run [get_ips dsp_mult_24x24]
