`timescale 1ns / 1ps

// Integration testbench for accumulator -> bias.
//
// Drives the accumulator's per-column partial-sum inputs directly (same
// staggered-skew stimulus pattern as accumulator_tb.sv, reproducing the
// diagonal output timing actually observed from a real mmu), then verifies
// that bias.sv correctly adds a stationary per-column bias to each
// fully-reduced row the accumulator produces.
//
// This isolates accumulator+bias correctness from the MMU/weight_fifo/
// systolic_data_setup machinery -- tpu_core_tb.sv covers the full chain.
module accum_bias_tb;
    localparam int NUM_COLS   = 2;
    localparam int PSUM_WIDTH = 16;
    localparam int FIFO_DEPTH = 4;

    logic clk;
    logic reset;

    // Accumulator inputs
    logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] in_partial_sum;
    logic                       [NUM_COLS-1:0] in_partial_sum_valid;

    // Accumulator -> bias interconnect
    logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] acc_out_row;
    logic                         acc_out_row_valid;
    logic                         any_fifo_full;

    // Stationary per-column bias
    logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] in_bias;

    // Final bias-added output
    logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] out_row;
    logic                         out_row_valid;

    int errors = 0;
    int rows_received = 0;

    // Expected final rows: accumulator's A@W = [[8,11],[20,27]] (the same
    // canonical scenario used across mmu_tb / accumulator_tb / accum_mmu_tb)
    // plus a uniform stationary bias of [100, 200] per column.
    logic signed [PSUM_WIDTH-1:0] in_bias_value [NUM_COLS] = '{16'sd100, 16'sd200};
    logic signed [PSUM_WIDTH-1:0] expected_rows [2][NUM_COLS] = '{
        '{16'sd108, 16'sd211},
        '{16'sd120, 16'sd227}
    };

    accumulator #(
        .NUM_COLS(NUM_COLS),
        .PSUM_WIDTH(PSUM_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_acc (
        .clk(clk),
        .reset(reset),
        .in_partial_sum(in_partial_sum),
        .in_partial_sum_valid(in_partial_sum_valid),
        .tile_first(1'b1),   // single-shot 2x2 matmul: no K-tiling in this tb
        .tile_last(1'b1),
        .out_row(acc_out_row),
        .out_row_valid(acc_out_row_valid),
        .pass_done(),
        .any_fifo_full(any_fifo_full)
    );

    bias #(
        .NUM_COLS(NUM_COLS),
        .PSUM_WIDTH(PSUM_WIDTH)
    ) u_bias (
        .clk(clk),
        .reset(reset),
        .in_row(acc_out_row),
        .in_row_valid(acc_out_row_valid),
        .in_bias(in_bias),
        .out_row(out_row),
        .out_row_valid(out_row_valid)
    );

    always #5 clk = ~clk;

    // Self-checking scoreboard
    always @(posedge clk) begin
        if (!reset && out_row_valid) begin
            if (rows_received >= 2) begin
                $error("[FAIL] Received unexpected extra row at time %0t", $time);
                errors++;
            end else if (out_row[0] !== expected_rows[rows_received][0] ||
                         out_row[1] !== expected_rows[rows_received][1]) begin
                $error("[FAIL] Row %0d mismatch at time %0t. Got [%0d, %0d], Expected [%0d, %0d]",
                       rows_received, $time, out_row[0], out_row[1],
                       expected_rows[rows_received][0], expected_rows[rows_received][1]);
                errors++;
            end else begin
                $display("[PASS] Biased Row %0d Received at time %0t: [%0d, %0d]",
                         rows_received, $time, out_row[0], out_row[1]);
            end
            rows_received++;
        end
    end

    initial begin
        clk = 0;
        reset = 1;
        in_partial_sum[0] = 0; in_partial_sum[1] = 0;
        in_partial_sum_valid[0] = 0; in_partial_sum_valid[1] = 0;
        in_bias[0] = in_bias_value[0];
        in_bias[1] = in_bias_value[1];

        #15 reset = 0;
        @(negedge clk);

        $display("\nStarting Accumulator + Bias Integration Test");
        $display("Stationary bias = [%0d, %0d]", in_bias_value[0], in_bias_value[1]);

        // Reproduce the same diagonal-skew timing accumulator_tb.sv uses,
        // matching the real mmu_tb trace: col0 produces row0's value one
        // cycle before col1 produces row0's value.

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
        repeat (8) @(negedge clk);

        if (rows_received != 2) begin
            $error("[FAIL] Expected 2 rows, but received %0d", rows_received);
            errors++;
        end

        if (errors == 0) $display("\n>>> ALL ACCUMULATOR + BIAS INTEGRATION TESTS PASSED <<<\n");
        else $display("\n>>> %0d ACCUMULATOR + BIAS INTEGRATION TESTS FAILED <<<\n", errors);

        $finish;
    end

    initial begin
        $dumpfile("accum_bias_integration.vcd");
        $dumpvars(0, accum_bias_tb);
    end

endmodule
