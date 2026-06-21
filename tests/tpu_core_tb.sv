`timescale 1ns / 1ps

module tpu_core_tb;
    localparam int WEIGHT_WIDTH = 8;
    localparam int FIFO_DEPTH   = 4;

    logic clk;
    logic reset;

    // ==========================================
    // 1. Signals & Glue Logic
    // ==========================================
    
    // Weight FIFO External Interfaces
    logic write_enable_col_0, write_enable_col_1;
    logic signed [WEIGHT_WIDTH-1:0] write_data_col_0, write_data_col_1;
    logic swap_banks;
    logic loading_phase;
    
    logic signed [WEIGHT_WIDTH-1:0] wf_col_0, wf_col_1;
    logic wf_col_0_valid, wf_col_1_valid;

    // Activation Skew (Unified Buffer simulation)
    logic signed [7:0] ub_read_data [2];
    logic              ub_read_valid;
    logic signed [7:0] skewed_act_data [2];
    logic              skewed_act_valid [2];

    // MMU Outputs
    logic signed [15:0] mmu_out_0, mmu_out_1;
    logic mmu_out_0_valid, mmu_out_1_valid;

    // Accumulator Inputs/Outputs
    logic signed [15:0] accum_in_data [2];
    logic               accum_in_valid [2];
    logic signed [15:0] final_row_out [2];
    logic               final_row_valid;

    // Glue Logic: Pack MMU scalar outputs into Accumulator arrays
    assign accum_in_data[0]  = mmu_out_0;
    assign accum_in_data[1]  = mmu_out_1;
    assign accum_in_valid[0] = mmu_out_0_valid;
    assign accum_in_valid[1] = mmu_out_1_valid;

    int errors = 0;

    // ==========================================
    // 2. Instantiations
    // ==========================================

    weight_fifo #(.WEIGHT_WIDTH(WEIGHT_WIDTH), .FIFO_DEPTH(FIFO_DEPTH)) u_wf (
        .clk(clk), .reset(reset),
        .write_enable_col_0(write_enable_col_0), .write_data_col_0(write_data_col_0),
        .write_enable_col_1(write_enable_col_1), .write_data_col_1(write_data_col_1),
        .swap_banks(swap_banks), .loading_phase(loading_phase),
        .out_col_0(wf_col_0), .out_col_0_valid(wf_col_0_valid),
        .out_col_1(wf_col_1), .out_col_1_valid(wf_col_1_valid),
        /* empty/full status flags unconnected for TB */
        .shadow_loaded(), .active_bank(), .active_empty(), .active_full(), .any_shadow_full()
    );

    activation_skew #(.ARRAY_ROWS(2), .DATA_WIDTH(8)) u_skew (
        .clk(clk), .reset(reset),
        .ub_read_data(ub_read_data), .ub_read_valid(ub_read_valid),
        .mmu_in_row(skewed_act_data), .mmu_in_valid(skewed_act_valid)
    );

    mmu u_mmu (
        .clk(clk), .reset(reset),
        .loading_phase(loading_phase),
        .capture_weight_col_0(wf_col_0_valid), 
        .capture_weight_col_1(wf_col_1_valid),
        .in_col_0(wf_col_0), .in_col_0_valid(wf_col_0_valid),
        .in_col_1(wf_col_1), .in_col_1_valid(wf_col_1_valid),
        
        // Connect to skewed activations
        .in_row_0(skewed_act_data[0]), .in_row_0_valid(skewed_act_valid[0]),
        .in_row_1(skewed_act_data[1]), .in_row_1_valid(skewed_act_valid[1]),
        
        .out_partial_sum_0(mmu_out_0), .out_partial_sum_0_valid(mmu_out_0_valid),
        .out_partial_sum_1(mmu_out_1), .out_partial_sum_1_valid(mmu_out_1_valid)
    );

    accumulator #(.NUM_COLS(2), .PSUM_WIDTH(16), .FIFO_DEPTH(FIFO_DEPTH)) u_accum (
        .clk(clk), .reset(reset),
        .in_partial_sum(accum_in_data), .in_partial_sum_valid(accum_in_valid),
        .out_row(final_row_out), .out_row_valid(final_row_valid),
        .any_fifo_full()
    );

    // ==========================================
    // 3. Test Stimulus
    // ==========================================
    always #5 clk = ~clk;

    initial begin
        // Initialization
        clk = 0; reset = 1;
        write_enable_col_0 = 0; write_data_col_0 = 0;
        write_enable_col_1 = 0; write_data_col_1 = 0;
        swap_banks = 0; loading_phase = 0;
        ub_read_data[0] = 0; ub_read_data[1] = 0; ub_read_valid = 0;

        #15 reset = 0;
        @(posedge clk); #1;

        $display("\n=== Starting TPU Core Integration Test ===");

        // Step 1: Load Weights [[4,5], [2,3]] into shadow bank (bottom row first)
        $display("\n[Step 1] Loading weights into FIFO...");
        write_enable_col_0 = 1; write_data_col_0 = 8'sd2;
        write_enable_col_1 = 1; write_data_col_1 = 8'sd3;
        @(posedge clk); #1;
        
        write_data_col_0 = 8'sd4;
        write_data_col_1 = 8'sd5;
        @(posedge clk); #1;
        
        write_enable_col_0 = 0; write_enable_col_1 = 0;

        // Step 2: Swap Banks and push into MMU
        $display("[Step 2] Swapping banks and asserting loading_phase...");
        swap_banks = 1;
        @(posedge clk); #1;
        swap_banks = 0; loading_phase = 1;

        // Hold for 3 cycles (N+1 rule for 2x2)
        @(posedge clk); #1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        loading_phase = 0;
        @(posedge clk); #1; // Idle settle tick

        // Step 3: Stream flat activations A = [[1,2], [3,4]] from "Unified Buffer"
        $display("[Step 3] Streaming flat activations into Skew unit...");
        ub_read_data[0] = 8'sd1; ub_read_data[1] = 8'sd2; ub_read_valid = 1'b1;
        @(posedge clk); #1;

        ub_read_data[0] = 8'sd3; ub_read_data[1] = 8'sd4; ub_read_valid = 1'b1;
        @(posedge clk); #1;

        ub_read_valid = 0;

        // Step 4: Wait for Accumulator to output the de-skewed rows
        $display("[Step 4] Awaiting Accumulator output...");
        
        // Wait for first row
        wait(final_row_valid);
        @(posedge clk); // Align to check
        if (final_row_out[0] !== 16'sd8 || final_row_out[1] !== 16'sd11) begin
            $error("[FAIL] Row 0 incorrect. Expected [8, 11], Got [%0d, %0d]", final_row_out[0], final_row_out[1]);
            errors++;
        end else begin
            $display("  -> [PASS] Output Row 0: [%0d, %0d]", final_row_out[0], final_row_out[1]);
        end
        #1;

        // Wait for second row
        wait(final_row_valid);
        @(posedge clk);
        if (final_row_out[0] !== 16'sd20 || final_row_out[1] !== 16'sd27) begin
            $error("[FAIL] Row 1 incorrect. Expected [20, 27], Got [%0d, %0d]", final_row_out[0], final_row_out[1]);
            errors++;
        end else begin
            $display("  -> [PASS] Output Row 1: [%0d, %0d]", final_row_out[0], final_row_out[1]);
        end

        $display("\n=== SIMULATION COMPLETE ===");
        if (errors == 0) $display(">>> ALL INTEGRATION TESTS PASSED <<<");
        
        $finish;
    end
endmodule
