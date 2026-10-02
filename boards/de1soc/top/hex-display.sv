`timescale 1ns / 1ps

// six seven-segment digits from one 30-bit word: digit d is code[5d +: 5],
// 0-15 a hex digit, 16 blank, 17 a dash, anything else blank. active-low segments
module hex_display (
    input  logic [29:0] code,
    output logic [6:0]  hex0, hex1, hex2, hex3, hex4, hex5
);

    function automatic logic [6:0] seg(input logic [4:0] c);
        case (c)
            5'h00: return 7'b1000000; 5'h01: return 7'b1111001; 5'h02: return 7'b0100100;
            5'h03: return 7'b0110000; 5'h04: return 7'b0011001; 5'h05: return 7'b0010010;
            5'h06: return 7'b0000010; 5'h07: return 7'b1111000; 5'h08: return 7'b0000000;
            5'h09: return 7'b0010000; 5'h0A: return 7'b0001000; 5'h0B: return 7'b0000011;
            5'h0C: return 7'b1000110; 5'h0D: return 7'b0100001; 5'h0E: return 7'b0000110;
            5'h0F: return 7'b0001110; 5'h11: return 7'b0111111;
            default: return 7'b1111111;
        endcase
    endfunction

    assign hex0 = seg(code[4:0]);
    assign hex1 = seg(code[9:5]);
    assign hex2 = seg(code[14:10]);
    assign hex3 = seg(code[19:15]);
    assign hex4 = seg(code[24:20]);
    assign hex5 = seg(code[29:25]);

endmodule
