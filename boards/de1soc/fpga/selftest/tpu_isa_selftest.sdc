create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_clock_uncertainty
# KEY0 is synchronized; LEDs and displays are static once the run finishes
set_false_path -from [get_ports {KEY[*]}]
set_false_path -to [get_ports {LEDR[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*]}]
