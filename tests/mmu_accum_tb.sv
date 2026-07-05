`timescale 1ns / 1ps

module mmu_acc_integration_tb;
    localparam int NUM_COLS = 2;
    localparam int PSUM_WIDTH = 16;
    localparam int FIFO_DEPTH = 4;

    logic clk;
    logic reset;

    // MMU Input Signals
    logic loading_phase;
    logic capture_weight_col_0;
    logic capture_weight_col_1;

    logic signed [7:0] in_row_0, in_row_1;
    logic              in_row_0_valid, in_row_1_valid;
    logic signed [7:0] in_col_0, in_col_1;
    logic              in_col_0_valid, in_col_1_valid;

    // MMU Output / Accumulator Input Interconnect
    logic signed [15:0] mmu_out_psum_0, mmu_out_psum_1;
    logic               mmu_out_psum_0_valid, mmu_out_psum_1_valid;

    // Array mapped signals for the Accumulator
    logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] acc_in_psum;
    logic                       [NUM_COLS-1:0] acc_in_psum_valid;

    assign acc_in_psum[0] = mmu_out_psum_0;
    assign acc_in_psum[1] = mmu_out_psum_1;
    assign acc_in_psum_valid[0] = mmu_out_psum_0_valid;
    assign acc_in_psum_valid[1] = mmu_out_psum_1_valid;

    // Accumulator Output Signals
    logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] out_row;
    logic                         out_row_valid;
    logic                         any_fifo_full;

    int errors = 0;
    int rows_received = 0;

    // Expected final matrix C = [[8, 11], [20, 27]]
    logic signed [PSUM_WIDTH-1:0] expected_rows [2][NUM_COLS] = '{
        '{16'sd8,  16'sd11},
        '{16'sd20, 16'sd27}
    };

    // Module Instantiations
    mmu u_mmu (
        .clk(clk),
        .reset(reset),
        .loading_phase(loading_phase),
        .capture_weight_col_0(capture_weight_col_0),
        .capture_weight_col_1(capture_weight_col_1),
        .in_row_0(in_row_0),
        .in_row_0_valid(in_row_0_valid),
        .in_row_1(in_row_1),
        .in_row_1_valid(in_row_1_valid),
        .in_col_0(in_col_0),
        .in_col_0_valid(in_col_0_valid),
        .in_col_1(in_col_1),
        .in_col_1_valid(in_col_1_valid),
        .out_partial_sum_0(mmu_out_psum_0),
        .out_partial_sum_0_valid(mmu_out_psum_0_valid),
        .out_partial_sum_1(mmu_out_psum_1),
        .out_partial_sum_1_valid(mmu_out_psum_1_valid)
    );

    accumulator #(
        .NUM_COLS(NUM_COLS),
        .PSUM_WIDTH(PSUM_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_acc (
        .clk(clk),
        .reset(reset),
        .in_partial_sum(acc_in_psum),
        .in_partial_sum_valid(acc_in_psum_valid),
        .out_row(out_row),
        .out_row_valid(out_row_valid),
        .any_fifo_full(any_fifo_full)
    );

    always #5 clk = ~clk;

    // Self-Checking Scoreboard
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
                $display("[PASS] Aligned Row %0d Received at time %0t: [%0d, %0d]", 
                         rows_received, $time, out_row[0], out_row[1]);
            end
            rows_received++;
        end
    end

    // Stimulus Generation
    initial begin
        // 1. Initialize Default State
        clk = 0;
        reset = 1;
        loading_phase = 0;
        capture_weight_col_0 = 0;
        capture_weight_col_1 = 0;
        in_row_0 = 0; in_row_0_valid = 0;
        in_row_1 = 0; in_row_1_valid = 0;
        in_col_0 = 0; in_col_0_valid = 0;
        in_col_1 = 0; in_col_1_valid = 0;

        #15 reset = 0;
        @(negedge clk);

        $display("\nStarting MMU + Accumulator Integration Test");

        // 2. Load Weights (W = [[4,5], [2,3]])
        $display("Phase 1: Loading Weights");
        loading_phase = 1; 
        capture_weight_col_0 = 1; 
        capture_weight_col_1 = 1;
        
        in_col_0 = 8'sd2; in_col_0_valid = 1; 
        in_col_1 = 8'sd3; in_col_1_valid = 1;
        @(negedge clk);
        
        in_col_0 = 8'sd4; in_col_0_valid = 1; 
        in_col_1 = 8'sd5; in_col_1_valid = 1;
        @(negedge clk);
        
        loading_phase = 0; 
        capture_weight_col_0 = 0; 
        capture_weight_col_1 = 0;
        in_col_0 = 0; in_col_0_valid = 0;
        in_col_1 = 0; in_col_1_valid = 0;
        
        @(negedge clk);

        // 3. Stream Activations (A = [[1,2], [3,4]])
        $display("Phase 2: Streaming Activations");
        
        // Step 1: A[0][0]
        in_row_0 = 8'sd1; in_row_0_valid = 1;
        in_row_1 = 8'sd0; in_row_1_valid = 0;
        @(negedge clk);
        
        // Step 2: A[1][0] and A[0][1]
        in_row_0 = 8'sd3; in_row_0_valid = 1;
        in_row_1 = 8'sd2; in_row_1_valid = 1;
        @(negedge clk);
        
        // Step 3: A[1][1]
        in_row_0 = 8'sd0; in_row_0_valid = 0;
        in_row_1 = 8'sd4; in_row_1_valid = 1;
        @(negedge clk);
        
        // Idle out
        in_row_1 = 8'sd0; in_row_1_valid = 0;

        // 4. Wait for the accumulator to catch all staggered psums
        repeat (15) @(negedge clk);

        if (rows_received != 2) begin
            $error("[FAIL] Expected 2 rows, but received %0d", rows_received);
            errors++;
        end

        if (errors == 0) $display("\n>>> ALL INTEGRATION TESTS PASSED <<<\n");
        else $display("\n>>> %0d INTEGRATION TESTS FAILED <<<\n", errors);

        $finish;
    end

    // --- Waveform Logging ---
    initial begin
        $dumpfile("mmu_acc_integration.vcd");
        $dumpvars(0, mmu_acc_integration_tb);
    end

endmodule
