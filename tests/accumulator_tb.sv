`timescale 1ns / 1ps

module accumulator_tb;
    localparam int NUM_COLS = 2;
    localparam int PSUM_WIDTH = 16;

    logic clk;
    logic reset;

    logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] in_partial_sum;
    logic                       [NUM_COLS-1:0] in_partial_sum_valid;

    logic tile_first;
    logic tile_last;
    logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] out_row;
    logic                         out_row_valid;
    logic                         pass_done;
    logic                         any_fifo_full;

    int errors = 0;
    int row_idx = 0;
    int pass_done_count = 0;

    // Expected output rows: A @ W = [[8,11],[20,27]] from the mmu_tb scenario
    logic signed [PSUM_WIDTH-1:0] expected_rows [2][NUM_COLS] = '{
        '{16'sd8,  16'sd11},
        '{16'sd20, 16'sd27}
    };

    accumulator #(
        .NUM_COLS(NUM_COLS),
        .PSUM_WIDTH(PSUM_WIDTH),
        .FIFO_DEPTH(4)
    ) uut (.*);

    always #5 clk = ~clk;

    // Self-checking monitor: fires whenever a row comes out
    always @(posedge clk) begin
        if (!reset && out_row_valid) begin
            if (row_idx >= 2) begin
                $error("[FAIL] Got more rows than expected at time %0t", $time);
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
        if (!reset && pass_done) pass_done_count++;
    end

    initial begin
        clk = 0; reset = 1;
        in_partial_sum[0] = 0; in_partial_sum[1] = 0;
        in_partial_sum_valid[0] = 0; in_partial_sum_valid[1] = 0;
        tile_first = 1'b1; tile_last = 1'b1;   // single-shot 2x2 matmul, no K-tiling yet

        #15 reset = 0;
        @(negedge clk);

        $display("\n=== STARTING ACCUMULATOR TESTBENCH ===\n");

        // Mimic the real mmu_tb timing: col0 row0 (=8) arrives one cycle
        // before col1 row0 (=11), reproducing the diagonal output skew
        // actually observed in the mmu simulation trace.

        // Cycle A: col0 produces row0 value (8)
        in_partial_sum[0] = 16'sd8;
        in_partial_sum_valid[0] = 1'b1;
        in_partial_sum_valid[1] = 1'b0;
        @(negedge clk);

        // Cycle B: col0 produces row1 value (20), col1 produces row0 value (11)
        in_partial_sum[0] = 16'sd20;
        in_partial_sum_valid[0] = 1'b1;
        in_partial_sum[1] = 16'sd11;
        in_partial_sum_valid[1] = 1'b1;
        @(negedge clk);

        // Cycle C: col1 produces row1 value (27), col0 has nothing more
        in_partial_sum[0] = 16'sd0;
        in_partial_sum_valid[0] = 1'b0;
        in_partial_sum[1] = 16'sd27;
        in_partial_sum_valid[1] = 1'b1;
        @(negedge clk);

        // Drain
        in_partial_sum_valid[0] = 1'b0;
        in_partial_sum_valid[1] = 1'b0;
        repeat (5) @(negedge clk);

        if (row_idx != 2) begin
            $error("[FAIL] Expected 2 rows total, got %0d", row_idx);
            errors++;
        end
        if (pass_done_count != 1) begin
            $error("[FAIL] Expected pass_done to pulse once for the single-shot pass, got %0d", pass_done_count);
            errors++;
        end

        // ------------------------------------------------------------------
        // K-tiling test: two passes accumulating into the same 2x2 output
        // before being forwarded downstream, mimicking a matmul whose K
        // dimension is twice ARRAY_ROWS. Pass 1 contributes row0=[3,4],
        // row1=[5,6] (tile_first=1, tile_last=0 -- must NOT forward to
        // out_row). Pass 2 contributes row0=[1,2], row1=[2,3]
        // (tile_first=0, tile_last=1 -- forwards the running sum:
        // row0=[4,6], row1=[7,9]).
        // ------------------------------------------------------------------
        $display("\n=== K-TILING TEST: two-pass accumulation ===\n");
        row_idx = 0;
        pass_done_count = 0;
        expected_rows[0][0] = 16'sd4; expected_rows[0][1] = 16'sd6;
        expected_rows[1][0] = 16'sd7; expected_rows[1][1] = 16'sd9;

        // Pass 1 (tile_first=1, tile_last=0): accumulate only, no output.
        tile_first = 1'b1;
        tile_last  = 1'b0;

        in_partial_sum[0] = 16'sd3;
        in_partial_sum_valid[0] = 1'b1;
        in_partial_sum_valid[1] = 1'b0;
        @(negedge clk);

        in_partial_sum[0] = 16'sd5;
        in_partial_sum_valid[0] = 1'b1;
        in_partial_sum[1] = 16'sd4;
        in_partial_sum_valid[1] = 1'b1;
        @(negedge clk);

        in_partial_sum[0] = 16'sd0;
        in_partial_sum_valid[0] = 1'b0;
        in_partial_sum[1] = 16'sd6;
        in_partial_sum_valid[1] = 1'b1;
        @(negedge clk);

        in_partial_sum_valid[0] = 1'b0;
        in_partial_sum_valid[1] = 1'b0;
        repeat (5) @(negedge clk);

        if (row_idx != 0) begin
            $error("[FAIL] Pass 1 (tile_last=0) must not forward any row, got %0d", row_idx);
            errors++;
        end
        if (pass_done_count != 1) begin
            $error("[FAIL] Expected pass_done to pulse once after pass 1, got %0d", pass_done_count);
            errors++;
        end

        // Pass 2 (tile_first=0, tile_last=1): add to the running sum and
        // forward the final result.
        tile_first = 1'b0;
        tile_last  = 1'b1;

        in_partial_sum[0] = 16'sd1;
        in_partial_sum_valid[0] = 1'b1;
        in_partial_sum_valid[1] = 1'b0;
        @(negedge clk);

        in_partial_sum[0] = 16'sd2;
        in_partial_sum_valid[0] = 1'b1;
        in_partial_sum[1] = 16'sd2;
        in_partial_sum_valid[1] = 1'b1;
        @(negedge clk);

        in_partial_sum[0] = 16'sd0;
        in_partial_sum_valid[0] = 1'b0;
        in_partial_sum[1] = 16'sd3;
        in_partial_sum_valid[1] = 1'b1;
        @(negedge clk);

        in_partial_sum_valid[0] = 1'b0;
        in_partial_sum_valid[1] = 1'b0;
        repeat (5) @(negedge clk);

        if (row_idx != 2) begin
            $error("[FAIL] Pass 2 (tile_last=1) expected 2 forwarded rows, got %0d", row_idx);
            errors++;
        end
        if (pass_done_count != 2) begin
            $error("[FAIL] Expected pass_done to have pulsed twice total, got %0d", pass_done_count);
            errors++;
        end

        if (errors == 0) $display("\n>>> ALL ACCUMULATOR TESTS PASSED! <<<");
        else $display("\n>>> %0d ACCUMULATOR TESTS FAILED <<<", errors);

        $finish;
    end

    initial begin
        $dumpfile("accumulator_simulation.vcd");
        $dumpvars(0, accumulator_tb);
    end
endmodule
