create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_clock_uncertainty
# KEY0 and SW are synchronized; LEDs and displays are static once the run finishes
set_false_path -from [get_ports {KEY[*] SW[*]}]
set_false_path -to [get_ports {LEDR[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*]}]
