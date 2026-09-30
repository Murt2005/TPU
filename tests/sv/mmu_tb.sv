`timescale 1ns / 1ps

module mmu_tb;
    logic                clk;
    logic                reset;
    logic                loading_phase;
    logic [1:0]          capture_weight_col;

    logic signed [1:0][7:0] in_row;
    logic        [1:0]      in_row_valid;

    logic signed [1:0][7:0] in_col;
    logic        [1:0]      in_col_valid;

    logic signed [1:0][15:0] out_partial_sum;
    logic        [1:0]       out_partial_sum_valid;

    int errors = 0;
    int exp_col0_q[$], exp_col1_q[$];

    // Instantiate MMU
    mmu #(.ARRAY_ROWS(2), .NUM_COLS(2)) uut (.*);

    // Clock generator (10ns period)
    always #5 clk = ~clk;

    // --- Self-checking scoreboard (the original testbench had none --
    // this makes the back-to-back gap test below automatically verified
    // instead of requiring you to eyeball the telemetry) ---
    always @(posedge clk) begin
        if (!reset) begin
            if (out_partial_sum_valid[0]) begin
                if (exp_col0_q.size() == 0) begin
                    $error("[FAIL] Unexpected col0 output %0d at time %0t", out_partial_sum[0], $time);
                    errors++;
                end else begin
                    int e;
                    e = exp_col0_q.pop_front();
                    if (out_partial_sum[0] !== e) begin
                        $error("[FAIL] col0 at %0t: got %0d, expected %0d", $time, out_partial_sum[0], e);
                        errors++;
                    end else begin
                        $display("[PASS] col0 at %0t: %0d", $time, out_partial_sum[0]);
                    end
                end
            end
            if (out_partial_sum_valid[1]) begin
                if (exp_col1_q.size() == 0) begin
                    $error("[FAIL] Unexpected col1 output %0d at time %0t", out_partial_sum[1], $time);
                    errors++;
                end else begin
                    int e;
                    e = exp_col1_q.pop_front();
                    if (out_partial_sum[1] !== e) begin
                        $error("[FAIL] col1 at %0t: got %0d, expected %0d", $time, out_partial_sum[1], e);
                        errors++;
                    end else begin
                        $display("[PASS] col1 at %0t: %0d", $time, out_partial_sum[1]);
                    end
                end
            end
        end
    end

    // --- Dynamic Telemetry Logger ---
    // Hierarchical paths follow mmu's generate-block naming:
    // uut.gen_pe_rows.gen_row[r].gen_col[c].pe_inst
    always @(negedge clk) begin
        if (!reset) begin
            $display("[Time=%0t] --- Mode: %s ---", $time, loading_phase ? "WEIGHT LOAD" : "COMPUTE");

            // PE00 Telemetry
            $display("  PE00 | Act: In=%2d (V:%b), Out=%2d | Weight: In=%2d (V:%b), Reg=%2d | PSum: In=%2d (V:%b), Out=%2d (V:%b)",
                     uut.gen_pe_rows.gen_row[0].gen_col[0].pe_inst.in_activation,  uut.gen_pe_rows.gen_row[0].gen_col[0].pe_inst.in_activation_valid,  uut.gen_pe_rows.gen_row[0].gen_col[0].pe_inst.out_activation,
                     uut.gen_pe_rows.gen_row[0].gen_col[0].pe_inst.in_weight,      uut.gen_pe_rows.gen_row[0].gen_col[0].pe_inst.in_weight_valid,      uut.gen_pe_rows.gen_row[0].gen_col[0].pe_inst.weight_reg,
                     uut.gen_pe_rows.gen_row[0].gen_col[0].pe_inst.in_partial_sum, uut.gen_pe_rows.gen_row[0].gen_col[0].pe_inst.in_partial_sum_valid, uut.gen_pe_rows.gen_row[0].gen_col[0].pe_inst.out_partial_sum, uut.gen_pe_rows.gen_row[0].gen_col[0].pe_inst.out_partial_sum_valid);

            // PE01 Telemetry
            $display("  PE01 | Act: In=%2d (V:%b), Out=%2d | Weight: In=%2d (V:%b), Reg=%2d | PSum: In=%2d (V:%b), Out=%2d (V:%b)",
                     uut.gen_pe_rows.gen_row[0].gen_col[1].pe_inst.in_activation,  uut.gen_pe_rows.gen_row[0].gen_col[1].pe_inst.in_activation_valid,  uut.gen_pe_rows.gen_row[0].gen_col[1].pe_inst.out_activation,
                     uut.gen_pe_rows.gen_row[0].gen_col[1].pe_inst.in_weight,      uut.gen_pe_rows.gen_row[0].gen_col[1].pe_inst.in_weight_valid,      uut.gen_pe_rows.gen_row[0].gen_col[1].pe_inst.weight_reg,
                     uut.gen_pe_rows.gen_row[0].gen_col[1].pe_inst.in_partial_sum, uut.gen_pe_rows.gen_row[0].gen_col[1].pe_inst.in_partial_sum_valid, uut.gen_pe_rows.gen_row[0].gen_col[1].pe_inst.out_partial_sum, uut.gen_pe_rows.gen_row[0].gen_col[1].pe_inst.out_partial_sum_valid);

            // PE10 Telemetry
            $display("  PE10 | Act: In=%2d (V:%b), Out=%2d | Weight: In=%2d (V:%b), Reg=%2d | PSum: In=%2d (V:%b), Out=%2d (V:%b)",
                     uut.gen_pe_rows.gen_row[1].gen_col[0].pe_inst.in_activation,  uut.gen_pe_rows.gen_row[1].gen_col[0].pe_inst.in_activation_valid,  uut.gen_pe_rows.gen_row[1].gen_col[0].pe_inst.out_activation,
                     uut.gen_pe_rows.gen_row[1].gen_col[0].pe_inst.in_weight,      uut.gen_pe_rows.gen_row[1].gen_col[0].pe_inst.in_weight_valid,      uut.gen_pe_rows.gen_row[1].gen_col[0].pe_inst.weight_reg,
                     uut.gen_pe_rows.gen_row[1].gen_col[0].pe_inst.in_partial_sum, uut.gen_pe_rows.gen_row[1].gen_col[0].pe_inst.in_partial_sum_valid, uut.gen_pe_rows.gen_row[1].gen_col[0].pe_inst.out_partial_sum, uut.gen_pe_rows.gen_row[1].gen_col[0].pe_inst.out_partial_sum_valid);

            // PE11 Telemetry
            $display("  PE11 | Act: In=%2d (V:%b), Out=%2d | Weight: In=%2d (V:%b), Reg=%2d | PSum: In=%2d (V:%b), Out=%2d (V:%b)",
                     uut.gen_pe_rows.gen_row[1].gen_col[1].pe_inst.in_activation,  uut.gen_pe_rows.gen_row[1].gen_col[1].pe_inst.in_activation_valid,  uut.gen_pe_rows.gen_row[1].gen_col[1].pe_inst.out_activation,
                     uut.gen_pe_rows.gen_row[1].gen_col[1].pe_inst.in_weight,      uut.gen_pe_rows.gen_row[1].gen_col[1].pe_inst.in_weight_valid,      uut.gen_pe_rows.gen_row[1].gen_col[1].pe_inst.weight_reg,
                     uut.gen_pe_rows.gen_row[1].gen_col[1].pe_inst.in_partial_sum, uut.gen_pe_rows.gen_row[1].gen_col[1].pe_inst.in_partial_sum_valid, uut.gen_pe_rows.gen_row[1].gen_col[1].pe_inst.out_partial_sum, uut.gen_pe_rows.gen_row[1].gen_col[1].pe_inst.out_partial_sum_valid);

            $display("  SYSTEM OUTPUTS | Col0 PSum = %4d (Valid: %b) | Col1 PSum = %4d (Valid: %b)",
                     out_partial_sum[0], out_partial_sum_valid[0], out_partial_sum[1], out_partial_sum_valid[1]);
            $display("-------------------------------------------------------------------------------------------------------");
        end
    end

    // --- Drive Test Signals ---
    initial begin
        // Reset state initialization
        clk                   = 0;
        reset                 = 1;
        loading_phase         = 0;
        capture_weight_col    = 2'b00;
        in_row                = '0;
        in_row_valid          = 2'b00;
        in_col                = '0;
        in_col_valid          = 2'b00;

        #15;
        @(posedge clk);
        #1 reset = 0;

        $display("\n=== Starting MMU Testbench ===\n");

        // Matrix 1 expected outputs: C1 = A1 @ W1 = [[8,11],[20,27]]
        exp_col0_q.push_back(8);   exp_col1_q.push_back(11);
        exp_col0_q.push_back(20);  exp_col1_q.push_back(27);

        // ------------------------------------------
        // Test 1: Staggered Stationary Weight Loading
        // Target Weight Matrix:
        //  [4, 5]
        //  [2, 3]
        // ------------------------------------------
        $display("\n Test 1: Staggered Stationary Weight Loading");
        @(posedge clk);
        #1;
        loading_phase      = 1;
        capture_weight_col = 2'b11;

        // Cycle 0: Inject bottom weights (row 1 weights) into the top ports
        in_col[0] = 8'sd2; in_col_valid[0] = 1'b1;
        in_col[1] = 8'sd3; in_col_valid[1] = 1'b1;

        @(posedge clk);
        #1;
        // Cycle 1: Push bottom weights down to row 1 PEs, inject top weights (row 0 weights)
        in_col[0] = 8'sd4; in_col_valid[0] = 1'b1;
        in_col[1] = 8'sd5; in_col_valid[1] = 1'b1;

        // At the next edge, PE00/PE01 capture [4,5] and PE10/PE11 capture [2,3]
        @(posedge clk);
        #1;
        loading_phase      = 0;
        capture_weight_col = 2'b00;
        in_col[0] = 0; in_col_valid[0] = 1'b0;
        in_col[1] = 0; in_col_valid[1] = 1'b0;

        // Give the pipeline one idle tick to settle
        @(posedge clk);

        // ------------------------------------------
        // Test 2: Systolic Staggered Data Input Streaming
        // Target Activation Matrix (A):
        //  [1, 2]
        //  [3, 4]
        // Expected Matrix Multiplication Output:
        //  C = A * W => [1*4 + 2*2,  1*5 + 2*3] = [8,  11]
        //               [3*4 + 4*2,  3*5 + 4*3] = [20, 27]
        // ------------------------------------------

        $display("\n Test 2: Systolic Staggered Data Input Streaming");
        // Cycle 0: Feed A[0][0]=1 to Row 0. Row 1 waits.
        @(posedge clk);
        #1;
        in_row[0] = 8'sd1; in_row_valid[0] = 1'b1;
        in_row[1] = 8'sd0; in_row_valid[1] = 1'b0;

        // Cycle 1: Stagger step. Feed A[1][0]=3 to Row 0, feed A[0][1]=2 to Row 1.
        @(posedge clk);
        #1;
        in_row[0] = 8'sd3; in_row_valid[0] = 1'b1;
        in_row[1] = 8'sd2; in_row_valid[1] = 1'b1;

        // Cycle 2: Feed A[1][1]=4 to Row 1. Row 0 data stream is exhausted.
        @(posedge clk);
        #1;
        in_row[0] = 8'sd0; in_row_valid[0] = 1'b0;
        in_row[1] = 8'sd4; in_row_valid[1] = 1'b1;

        // Cycle 3: All matrix data sent. Pull inputs to idle, wait for computations to flush.
        @(posedge clk);
        #1;
        in_row[0] = 8'sd0; in_row_valid[0] = 1'b0;
        in_row[1] = 8'sd0; in_row_valid[1] = 1'b0;

        // Keep clock cycling to observe output accumulation results completely clearing out
        #40;

        // Test 3: back-to-back weight reload no reset in between
        // Same drain margin the original single-pass test already proved
        // sufficient (#40) -- but instead of stopping here, we immediately
        // load a second weight matrix and run a second activation pass in
        // the SAME simulation epoch, with no reset between matrices.
        // ------------------------------------------
        $display("\n Test 3: back to back weight reload with no reset in between");

        // W2 = [[1,1],[1,1]], A2 = [[2,3],[4,5]] -> C2 = A2@W2 = [[5,5],[9,9]]
        exp_col0_q.push_back(5);  exp_col1_q.push_back(5);
        exp_col0_q.push_back(9);  exp_col1_q.push_back(9);

        @(posedge clk);
        #1;
        loading_phase = 1; capture_weight_col = 2'b11;
        in_col[0] = 8'sd1; in_col_valid[0] = 1'b1;
        in_col[1] = 8'sd1; in_col_valid[1] = 1'b1;

        @(posedge clk);
        #1;
        in_col[0] = 8'sd1; in_col_valid[0] = 1'b1;
        in_col[1] = 8'sd1; in_col_valid[1] = 1'b1;

        @(posedge clk);
        #1;
        loading_phase = 0; capture_weight_col = 2'b00;
        in_col[0] = 0; in_col_valid[0] = 1'b0;
        in_col[1] = 0; in_col_valid[1] = 1'b0;

        @(posedge clk);  // idle settle tick, same as the original Phase1->Phase2 transition

        @(posedge clk);
        #1;
        in_row[0] = 8'sd2; in_row_valid[0] = 1'b1;
        in_row[1] = 8'sd0; in_row_valid[1] = 1'b0;

        @(posedge clk);
        #1;
        in_row[0] = 8'sd4; in_row_valid[0] = 1'b1;
        in_row[1] = 8'sd3; in_row_valid[1] = 1'b1;

        @(posedge clk);
        #1;
        in_row[0] = 8'sd0; in_row_valid[0] = 1'b0;
        in_row[1] = 8'sd5; in_row_valid[1] = 1'b1;

        @(posedge clk);
        #1;
        in_row[0] = 8'sd0; in_row_valid[0] = 1'b0;
        in_row[1] = 8'sd0; in_row_valid[1] = 1'b0;

        #40;

        $display("\n=== SIMULATION COMPLETE ===\n");
        if (errors == 0 && exp_col0_q.size() == 0 && exp_col1_q.size() == 0) begin
            $display(">>> ALL MMU TESTS PASSED <<<");
        end else begin
            $display(">>> %0d FAILURE(S), %0d expected output(s) never arrived <<<",
                      errors, exp_col0_q.size() + exp_col1_q.size());
        end

        $finish;
    end

    // --- Waveform Dump ---
    initial begin
        $dumpfile("mmu_simulation.vcd");
        $dumpvars(0, mmu_tb);
    end
endmodule
