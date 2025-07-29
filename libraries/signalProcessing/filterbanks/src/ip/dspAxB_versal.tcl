# Versal version uses DSP58, which has a wider output.

create_ip -name dsp_macro -vendor xilinx.com -library ip -version 1.0 -module_name dsp_AxB_plus_PCIN_versal
set_property -dict [list \
  CONFIG.a_binarywidth {0} \
  CONFIG.a_width {27} \
  CONFIG.areg_3 {true} \
  CONFIG.areg_4 {false} \
  CONFIG.b_binarywidth {0} \
  CONFIG.b_width {18} \
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
  CONFIG.has_pcout {true} \
  CONFIG.instruction1 {A*B+PCIN} \
  CONFIG.mreg_5 {true} \
  CONFIG.p_binarywidth {0} \
  CONFIG.p_full_width {58} \
  CONFIG.p_width {58} \
  CONFIG.pcin_binarywidth {0} \
  CONFIG.pipeline_options {Expert} \
  CONFIG.preg_6 {true} \
] [get_ips dsp_AxB_plus_PCIN_versal]

create_ip -name dsp_macro -vendor xilinx.com -library ip -version 1.0 -module_name DSP_AxB_versal
set_property -dict [list \
  CONFIG.a_binarywidth {0} \
  CONFIG.a_width {27} \
  CONFIG.areg_3 {true} \
  CONFIG.areg_4 {false} \
  CONFIG.b_binarywidth {0} \
  CONFIG.b_width {18} \
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
  CONFIG.has_pcout {true} \
  CONFIG.instruction1 {A*B} \
  CONFIG.mreg_5 {true} \
  CONFIG.p_binarywidth {0} \
  CONFIG.p_full_width {45} \
  CONFIG.p_width {45} \
  CONFIG.pcin_binarywidth {0} \
  CONFIG.pipeline_options {Expert} \
  CONFIG.preg_6 {true} \
] [get_ips DSP_AxB_versal]
create_ip_run [get_ips DSP_AxB_versal]
