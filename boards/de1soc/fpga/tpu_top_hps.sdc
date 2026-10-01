# the HPS and h2f_lw bridge bring their own constraints from the GHRD; this adds the
# fabric clock. if the system clocks the TPU from a Qsys net, retarget it from CLOCK_50
create_clock -name clk_50 -period 20.000 [get_ports {CLOCK_50}]

# pushbutton reset, not timing-critical
set_false_path -from [get_ports {KEY[0]}] -to [all_registers]

derive_clock_uncertainty
