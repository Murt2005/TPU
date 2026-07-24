# Timing constraints for the DE1-SoC TPU fabric (Cyclone V, 50 MHz).
#
# Declares the 50 MHz fabric clock the TPU logic runs on so the Timing Analyzer
# (quartus_sta) can check closure. The HPS hard IP and the h2f_lw bridge bring
# their own generated constraints from the GHRD/Qsys system; this file only adds
# the fabric-clock constraint for the TPU path. If you clock the fabric from an
# HPS-emitted clock rather than CLOCK_50, rename the target accordingly.
#
# NOTE: scaffolding — confirm the actual clock port/name in your generated
# system (it may be a Qsys clock net rather than the top-level CLOCK_50 pin).

create_clock -name clk_50 -period 20.000 [get_ports {CLOCK_50}]

# Async, debounced pushbutton reset — not timing-critical.
set_false_path -from [get_ports {KEY[0]}] -to [all_registers]

derive_clock_uncertainty
