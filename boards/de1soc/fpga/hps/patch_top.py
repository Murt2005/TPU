#!/usr/bin/env python3
"""wire hex_pio into Terasic's ghrd_top.v: the export port on u0 and a
hex_display driving HEX0..5. idempotent. usage: patch_top.py ghrd_top.v"""
import sys

path = sys.argv[1]
s = open(path).read()
if "hex_pio_external_connection_export" in s:
    sys.exit(0)
anchor = ".led_pio_external_connection_export"
i = s.index(anchor)
s = s[:i] + ".hex_pio_external_connection_export    ( hex_code ),\n    " + s[i:]
decl = "wire    [8:0]   fpga_led_internal;"
s = s.replace(decl, decl + "\nwire    [31:0]  hex_code;", 1)
j = s.rindex("endmodule")
s = s[:j] + """hex_display u_hex (
    .code(hex_code[29:0]),
    .hex0(HEX0), .hex1(HEX1), .hex2(HEX2), .hex3(HEX3), .hex4(HEX4), .hex5(HEX5)
);

""" + s[j:]
open(path, "w").write(s)
