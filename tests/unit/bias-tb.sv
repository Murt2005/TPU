`timescale 1ns / 1ps

// bias: per-column add when enabled, 32-bit wrap; pass-through when not
module bias_tb;
    `include "check.svh"

    localparam int N = 4;
    logic [N*32-1:0] row_in, bias_row_in, row_out;
    logic            bias_enable_in;

    bias #(.ARRAY_SIZE(N)) dut (.*);

    initial begin
        row_in      = {32'h7fffffff, -32'sd10, 32'sd0, 32'sd5};
        bias_row_in = {32'sd1, 32'sd3, -32'sd7, 32'sd100};

        `TEST("disabled passes the row through")
        bias_enable_in = 1'b0; #1;
        `CHECK_EQ(row_out, row_in, "row")

        `TEST("enabled adds per column, wrapping")
        bias_enable_in = 1'b1; #1;
        `CHECK_EQ(row_out[31:0],   32'sd105, "col 0")
        `CHECK_EQ(row_out[63:32],  -32'sd7,  "col 1")
        `CHECK_EQ(row_out[95:64],  -32'sd7,  "col 2")
        `CHECK_EQ(row_out[127:96], 32'h80000000, "col 3 wraps")

        tb_done();
    end
endmodule
