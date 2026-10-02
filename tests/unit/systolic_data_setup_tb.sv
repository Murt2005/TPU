`timescale 1ns / 1ps

// systolic_data_setup: element i of each row comes out i cycles later, with its valid
module systolic_data_setup_tb;
    `include "check.svh"

    localparam int R = 4;
    logic clk = 1'b0, reset = 1'b1;
    logic signed [R-1:0][7:0] UB_read_data = '0, MMU_in_row;
    logic UB_read_valid = 1'b0;
    logic [R-1:0] MMU_in_valid;

    systolic_data_setup #(.ARRAY_ROWS(R), .DATA_WIDTH(8)) dut (.*);

    always #5 clk = ~clk;
    task automatic tick(); @(posedge clk); #1; endtask

    // three back-to-back rows, element i of row t = 10*t + i
    function automatic logic signed [7:0] el(int t, int i); return 8'(10 * t + i); endfunction

    initial begin
        tick(); tick(); reset = 1'b0;

        `TEST("nothing valid after reset")
        `CHECK_EQ(MMU_in_valid, '0, "valids")

        `TEST("element i lags by i cycles, back-to-back rows")
        for (int cyc = 0; cyc < 3 + R; cyc++) begin
            UB_read_valid = cyc < 3;
            for (int i = 0; i < R; i++) UB_read_data[i] = cyc < 3 ? el(cyc, i) : 8'sd0;
            #1;     // lane 0 is combinational
            for (int i = 0; i < R; i++) begin
                int t = cyc - i;
                `CHECK_EQ(MMU_in_valid[i], 1'(t >= 0 && t < 3), $sformatf("cycle %0d lane %0d valid", cyc, i))
                if (t >= 0 && t < 3)
                    `CHECK_EQ(MMU_in_row[i], el(t, i), $sformatf("cycle %0d lane %0d data", cyc, i))
            end
            tick();
        end

        tb_done();
    end
endmodule
