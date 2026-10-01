`timescale 1ns / 1ps

module bias_tb;
    localparam int NUM_COLS   = 2;
    localparam int PSUM_WIDTH = 16;

    logic clk;
    logic reset;

    logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] in_row;
    logic                         in_row_valid;
    logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] in_bias;

    logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] out_row;
    logic                         out_row_valid;

    int errors = 0;
    int row_idx = 0;

    // expected rows, consumed in order by the monitor
    localparam int MAX_ROWS = 16;
    logic signed [PSUM_WIDTH-1:0] expected_rows [MAX_ROWS][NUM_COLS];
    int expected_count = 0;

    bias #(
        .NUM_COLS(NUM_COLS),
        .PSUM_WIDTH(PSUM_WIDTH)
    ) uut (.*);

    always #5 clk = ~clk;

    // self-checking monitor: fires whenever a biased row comes out
    always @(posedge clk) begin
        if (!reset && out_row_valid) begin
            if (row_idx >= expected_count) begin
                $error("[FAIL] Got more rows than expected at time %0t | [%0d, %0d]",
                       $time, out_row[0], out_row[1]);
                errors++;
            end else if (out_row[0] !== expected_rows[row_idx][0] ||
                         out_row[1] !== expected_rows[row_idx][1]) begin
                $error("[FAIL] Row %0d at time %0t | Got: [%0d, %0d] Expected: [%0d, %0d]",
                       row_idx, $time, out_row[0], out_row[1],
                       expected_rows[row_idx][0], expected_rows[row_idx][1]);
                errors++;
            end else begin
                $display("[PASS] Row %0d at time %0t | [%0d, %0d]",
                          row_idx, $time, out_row[0], out_row[1]);
            end
            row_idx++;
        end
    end

    task automatic drive_row(input logic signed [PSUM_WIDTH-1:0] row0,
                              input logic signed [PSUM_WIDTH-1:0] row1,
                              input logic signed [PSUM_WIDTH-1:0] bias0,
                              input logic signed [PSUM_WIDTH-1:0] bias1);
        in_row[0]       = row0;
        in_row[1]       = row1;
        in_bias[0]      = bias0;
        in_bias[1]      = bias1;
        in_row_valid    = 1'b1;
        @(negedge clk);
        in_row_valid    = 1'b0;
    endtask

    task automatic push_expected(input logic signed [PSUM_WIDTH-1:0] e0,
                                  input logic signed [PSUM_WIDTH-1:0] e1);
        expected_rows[expected_count][0] = e0;
        expected_rows[expected_count][1] = e1;
        expected_count++;
    endtask

    initial begin
        clk = 0; reset = 1;
        in_row[0] = 0; in_row[1] = 0;
        in_bias[0] = 0; in_bias[1] = 0;
        in_row_valid = 0;

        #15 reset = 0;
        @(negedge clk);

        $display("\n Starting bias Testbench \n");

        // test 1: basic positive bias add
        $display(" Test 1: basic positive bias add ");
        push_expected(16'sd13, 16'sd16); // 8+5, 11+5
        drive_row(16'sd8, 16'sd11, 16'sd5, 16'sd5);

        // let it drain through the register and settle before next test
        repeat (2) @(negedge clk);

        // test 2: negative bias, including a sign flip to negative
        $display(" Test 2: negative bias (sign flip) ");
        push_expected(-16'sd2, 16'sd0); // 8 + (-10) = -2, 11 + (-11) = 0
        drive_row(16'sd8, 16'sd11, -16'sd10, -16'sd11);

        repeat (2) @(negedge clk);

        // test 3: zero bias is a pure pass-through
        $display(" Test 3: zero bias pass-through ");
        push_expected(16'sd20, 16'sd27);
        drive_row(16'sd20, 16'sd27, 16'sd0, 16'sd0);

        repeat (2) @(negedge clk);

        // test 4: back-to-back rows, different bias per column each cycle,
        // no bubble cycle in between (pipeline must not stall or merge rows)
        $display(" Test 4: back-to-back rows, no stall ");
        push_expected(16'sd9,  16'sd1);   // row A: 8+1, 11+(-10)
        push_expected(16'sd21, 16'sd29);  // row B: 20+1, 27+2

        in_row[0] = 16'sd8;  in_row[1] = 16'sd11;
        in_bias[0] = 16'sd1; in_bias[1] = -16'sd10;
        in_row_valid = 1'b1;
        @(negedge clk);

        in_row[0] = 16'sd20; in_row[1] = 16'sd27;
        in_bias[0] = 16'sd1; in_bias[1] = 16'sd2;
        in_row_valid = 1'b1;
        @(negedge clk);

        in_row_valid = 1'b0;
        repeat (2) @(negedge clk);

        // test 5: in_row_valid low must not produce an output row, even
        // if in_row / in_bias happen to hold stale nonzero data
        $display(" Test 5: invalid input produces no output ");
        in_row[0] = 16'sd99; in_row[1] = 16'sd99;
        in_bias[0] = 16'sd1; in_bias[1] = 16'sd1;
        in_row_valid = 1'b0;
        repeat (3) @(negedge clk);

        if (row_idx != expected_count) begin
            $error("[FAIL] Test 5: unexpected row appeared while in_row_valid was low (row_idx=%0d expected=%0d)",
                   row_idx, expected_count);
            errors++;
        end else begin
            $display("[PASS] No spurious row while in_row_valid low");
        end

        // test 6: out_row_valid stays low while reset is held, and nothing spurious follows it
        // racing reset against an in-flight row only tests NBA ordering, so it isn't attempted
        $display(" Test 6: reset mid-stream (idle pipeline) ");
        reset = 1'b1;
        in_row_valid = 1'b0;
        @(negedge clk);
        if (out_row_valid !== 1'b0) begin
            $error("[FAIL] Test 6: out_row_valid not low while reset held at time %0t", $time);
            errors++;
        end
        @(negedge clk);
        if (out_row_valid !== 1'b0) begin
            $error("[FAIL] Test 6: out_row_valid not low on second reset cycle at time %0t", $time);
            errors++;
        end else begin
            $display("[PASS] out_row_valid stays low while reset held");
        end
        reset = 1'b0;
        @(negedge clk);

        if (row_idx != expected_count) begin
            $error("[FAIL] Test 6: spurious row appeared during/after reset (row_idx=%0d expected=%0d)",
                   row_idx, expected_count);
            errors++;
        end else begin
            $display("[PASS] No spurious row during reset");
        end

        // test 7: normal operation after reset
        $display(" Test 7: post-reset normal operation ");
        @(negedge clk);
        push_expected(16'sd108, 16'sd111);
        drive_row(16'sd8, 16'sd11, 16'sd100, 16'sd100);

        push_expected(16'sd120, 16'sd127);
        drive_row(16'sd20, 16'sd27, 16'sd100, 16'sd100);

        repeat (3) @(negedge clk);

        $display("\n=== SIMULATION COMPLETE ===\n");
        if (errors == 0) $display(">>> ALL bias TESTS PASSED <<<");
        else $display(">>> %0d bias TESTS FAILED <<<", errors);

        $finish;
    end

    initial begin
        $dumpfile("bias_simulation.vcd");
        $dumpvars(0, bias_tb);
    end
endmodule
