`timescale 1ns / 1ps

// Integration testbench for bias -> activation.
//
// Verifies the two-stage tail of the TPU pipeline in isolation:
//   accumulator_output -> bias -> activation(ReLU) -> final output
//
// The accumulator is NOT instantiated here; partial-sum inputs are driven
// directly with the same diagonal-skew pattern used in accumulator_tb.sv and
// accum_bias_tb.sv, reproducing the canonical A@W = [[8,11],[20,27]] result.
//
// Test matrix (what we're specifically checking beyond what bias_tb covers):
//
//   Test 1 – ReLU keeps positive bias-added values intact.
//             bias=[100,200], accum=[[8,11],[20,27]] -> [[108,211],[120,227]]
//             All positive, so ReLU changes nothing.
//
//   Test 2 – ReLU clamps values the bias pushed negative.
//             bias=[-200,-200], accum=[[8,11],[20,27]]
//               raw biased: [[-192,-189],[-180,-173]]
//               after ReLU:   [[0,0],[0,0]]
//
//   Test 3 – Partial clamp: bias pushes only one column negative.
//             bias=[-5, 100], accum=[[8,11],[20,27]]
//               raw biased: [[3,111],[15,127]]
//               after ReLU:  [[3,111],[15,127]]   (all still positive)
//
//   Test 4 – Threshold boundary: bias exactly cancels accumulator value.
//             Drive accum col0=5, col1=-5, bias=[−5,5]
//               raw biased: [0, 0]  ->  ReLU: [0, 0]
//
// Latency chain:
//   accumulator drives -> bias (1 cycle) -> activation (1 cycle)
//   Total tail latency from accumulator out_row_valid to activation out_row_valid: 2 cycles.
module bias_activation_tb;
    localparam int NUM_COLS   = 2;
    localparam int PSUM_WIDTH = 16;
    localparam int FIFO_DEPTH = 4;

    logic clk;
    logic reset;

    // Accumulator inputs (driven directly, no accumulator instantiated)
    logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] in_partial_sum;
    logic                       [NUM_COLS-1:0] in_partial_sum_valid;

    // Accumulator outputs / bias inputs
    logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] acc_out_row;
    logic                         acc_out_valid;
    logic                         any_fifo_full;

    // Stationary bias
    logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] in_bias;

    // Bias outputs / activation inputs
    logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] biased_row;
    logic                         biased_valid;

    // Final activation outputs
    logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] out_row;
    logic                         out_row_valid;

    int errors       = 0;
    int rows_received = 0;

    accumulator #(
        .NUM_COLS(NUM_COLS),
        .PSUM_WIDTH(PSUM_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_acc (
        .clk                (clk),
        .reset              (reset),
        .in_partial_sum     (in_partial_sum),
        .in_partial_sum_valid(in_partial_sum_valid),
        .tile_first         (1'b1),   // single-shot 2x2 matmul: no K-tiling in this tb
        .tile_last          (1'b1),
        .out_row            (acc_out_row),
        .out_row_valid      (acc_out_valid),
        .pass_done          (),
        .any_fifo_full      (any_fifo_full)
    );

    bias #(
        .NUM_COLS(NUM_COLS),
        .PSUM_WIDTH(PSUM_WIDTH)
    ) u_bias (
        .clk         (clk),
        .reset       (reset),
        .in_row      (acc_out_row),
        .in_row_valid(acc_out_valid),
        .in_bias     (in_bias),
        .out_row     (biased_row),
        .out_row_valid(biased_valid)
    );

    activation #(
        .NUM_COLS(NUM_COLS),
        .PSUM_WIDTH(PSUM_WIDTH)
    ) u_act (
        .clk         (clk),
        .reset       (reset),
        .in_row      (biased_row),
        .in_row_valid(biased_valid),
        .out_row     (out_row),
        .out_row_valid(out_row_valid)
    );

    always #5 clk = ~clk;

    // Scoreboard: expected rows filled before each sub-test, checked here.
    logic signed [PSUM_WIDTH-1:0] expected_rows [2][NUM_COLS];

    always @(posedge clk) begin
        if (!reset && out_row_valid) begin
            if (rows_received >= 2) begin
                $error("[FAIL] Spurious extra row at time %0t: [%0d, %0d]",
                       $time, out_row[0], out_row[1]);
                errors++;
            end else if (out_row[0] !== expected_rows[rows_received][0] ||
                         out_row[1] !== expected_rows[rows_received][1]) begin
                $error("[FAIL] Row %0d mismatch. Expected [%0d, %0d], Got [%0d, %0d]",
                       rows_received,
                       expected_rows[rows_received][0], expected_rows[rows_received][1],
                       out_row[0], out_row[1]);
                errors++;
            end else begin
                $display("[PASS] Row %0d at time %0t: [%0d, %0d]",
                         rows_received, $time, out_row[0], out_row[1]);
            end
            rows_received++;
        end
    end

    // Helper: drive the same A@W diagonal pattern as accumulator_tb.sv.
    // Produces: row0=[col0_r0, col1_r0], row1=[col0_r1, col1_r1]
    task automatic drive_accum(
        input logic signed [PSUM_WIDTH-1:0] col0_r0, col1_r0,
        input logic signed [PSUM_WIDTH-1:0] col0_r1, col1_r1
    );
        // Cycle A: col0 produces row0
        @(negedge clk);
        in_partial_sum[0]       = col0_r0;
        in_partial_sum_valid[0] = 1'b1;
        in_partial_sum_valid[1] = 1'b0;

        // Cycle B: col0 produces row1, col1 produces row0
        @(negedge clk);
        in_partial_sum[0]       = col0_r1;
        in_partial_sum_valid[0] = 1'b1;
        in_partial_sum[1]       = col1_r0;
        in_partial_sum_valid[1] = 1'b1;

        // Cycle C: col1 produces row1
        @(negedge clk);
        in_partial_sum_valid[0] = 1'b0;
        in_partial_sum[1]       = col1_r1;
        in_partial_sum_valid[1] = 1'b1;

        @(negedge clk);
        in_partial_sum_valid[0] = 1'b0;
        in_partial_sum_valid[1] = 1'b0;
    endtask

    task automatic wait_for_rows(input int n);
        int ticks;
        ticks = 0;
        while (rows_received < n) begin
            @(posedge clk);
            ticks++;
            if (ticks > 40) begin
                $error("[FATAL] Timeout waiting for row %0d", rows_received);
                errors++;
                disable wait_for_rows;
            end
        end
    endtask

    initial begin
        clk = 0;
        reset = 1;
        in_partial_sum[0]       = '0;
        in_partial_sum[1]       = '0;
        in_partial_sum_valid[0] = 1'b0;
        in_partial_sum_valid[1] = 1'b0;
        in_bias[0] = '0;
        in_bias[1] = '0;

        #15 reset = 0;
        @(posedge clk); #1;

        $display("\nStarting Bias + Activation Integration Test");

        // ==================================================================
        $display("\n Test 1: positive accum + positive bias -> ReLU no-op ");
        // accum = [[8,11],[20,27]], bias = [100,200]
        // biased = [[108,211],[120,227]], ReLU = same
        rows_received = 0;
        in_bias[0] = 16'sd100; in_bias[1] = 16'sd200;
        expected_rows[0][0] = 16'sd108; expected_rows[0][1] = 16'sd211;
        expected_rows[1][0] = 16'sd120; expected_rows[1][1] = 16'sd227;

        drive_accum(16'sd8, 16'sd11, 16'sd20, 16'sd27);
        wait_for_rows(2);

        // ==================================================================
        $display("\n Test 2: negative biased values clamped to zero by ReLU ");
        // accum = [[8,11],[20,27]], bias = [-200,-200]
        // biased = [[-192,-189],[-180,-173]], ReLU = [[0,0],[0,0]]
        rows_received = 0;
        in_bias[0] = -16'sd200; in_bias[1] = -16'sd200;
        expected_rows[0][0] = 16'sd0; expected_rows[0][1] = 16'sd0;
        expected_rows[1][0] = 16'sd0; expected_rows[1][1] = 16'sd0;

        repeat(4) @(negedge clk);   // flush pipeline between sub-tests
        drive_accum(16'sd8, 16'sd11, 16'sd20, 16'sd27);
        wait_for_rows(2);

        // ==================================================================
        $display("\n Test 3: partial clamp (mixed bias, all results >= 0) ");
        // accum = [[8,11],[20,27]], bias = [-5, 100]
        // biased = [[3,111],[15,127]], ReLU = same
        rows_received = 0;
        in_bias[0] = -16'sd5; in_bias[1] = 16'sd100;
        expected_rows[0][0] = 16'sd3;  expected_rows[0][1] = 16'sd111;
        expected_rows[1][0] = 16'sd15; expected_rows[1][1] = 16'sd127;

        repeat(4) @(negedge clk);
        drive_accum(16'sd8, 16'sd11, 16'sd20, 16'sd27);
        wait_for_rows(2);

        // ==================================================================
        $display("\n Test 4: exact-zero boundary (bias exactly cancels accum) ");
        // Drive col0=5 col1=−5 for both rows; bias=[-5, 5]
        // biased row0 = [0,0], row1 = [0,0], ReLU = [0,0]
        rows_received = 0;
        in_bias[0] = -16'sd5; in_bias[1] = 16'sd5;
        expected_rows[0][0] = 16'sd0; expected_rows[0][1] = 16'sd0;
        expected_rows[1][0] = 16'sd0; expected_rows[1][1] = 16'sd0;

        repeat(4) @(negedge clk);
        drive_accum(16'sd5, -16'sd5, 16'sd5, -16'sd5);
        wait_for_rows(2);

        // ==================================================================
        repeat(6) @(negedge clk);

        $display("\n=== SIMULATION COMPLETE ===");
        if (errors == 0)
            $display(">>> ALL bias_activation TESTS PASSED <<<");
        else
            $display(">>> %0d bias_activation TESTS FAILED <<<", errors);

        $finish;
    end

    initial begin
        $dumpfile("bias_activation_integration.vcd");
        $dumpvars(0, bias_activation_tb);
    end

endmodule
