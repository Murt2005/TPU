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
    logic signed [15:0] acc_row_out [2];
    logic               acc_row_valid;

    // Bias Input/Output (final stage of the pipeline)
    logic signed [15:0] in_bias [2];
    logic signed [15:0] final_row_out [2];
    logic               final_row_valid;

    // Glue Logic: Pack MMU scalar outputs into Accumulator arrays
    assign accum_in_data[0]  = mmu_out_0;
    assign accum_in_data[1]  = mmu_out_1;
    assign accum_in_valid[0] = mmu_out_0_valid;
    assign accum_in_valid[1] = mmu_out_1_valid;

    int errors = 0;

    // Output Monitor Queue
    logic [31:0] result_queue[$];

    always_ff @(posedge clk) begin
        if (reset) begin
            result_queue.delete();
        end else if (final_row_valid) begin
            // Concatenate col0 and col1 into a 32-bit entry
            result_queue.push_back({final_row_out[0], final_row_out[1]});
        end
    end

    weight_fifo #(.WEIGHT_WIDTH(WEIGHT_WIDTH), .FIFO_DEPTH(FIFO_DEPTH)) u_wf (
        .clk(clk), .reset(reset),
        .write_enable_col_0(write_enable_col_0), .write_data_col_0(write_data_col_0),
        .write_enable_col_1(write_enable_col_1), .write_data_col_1(write_data_col_1),
        .swap_banks(swap_banks), .loading_phase(loading_phase),
        .out_col_0(wf_col_0), .out_col_0_valid(wf_col_0_valid),
        .out_col_1(wf_col_1), .out_col_1_valid(wf_col_1_valid),
        .shadow_loaded(), .active_bank(), .active_empty(), 
        .active_full(), .any_shadow_full()
    );

    systolic_data_setup #(.ARRAY_ROWS(2), .DATA_WIDTH(8)) u_skew (
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
        .in_row_0(skewed_act_data[0]), .in_row_0_valid(skewed_act_valid[0]),
        .in_row_1(skewed_act_data[1]), .in_row_1_valid(skewed_act_valid[1]),
        .out_partial_sum_0(mmu_out_0), .out_partial_sum_0_valid(mmu_out_0_valid),
        .out_partial_sum_1(mmu_out_1), .out_partial_sum_1_valid(mmu_out_1_valid)
    );

    accumulator #(.NUM_COLS(2), .PSUM_WIDTH(16), .FIFO_DEPTH(FIFO_DEPTH)) u_accum (
        .clk(clk), .reset(reset),
        .in_partial_sum(accum_in_data), .in_partial_sum_valid(accum_in_valid),
        .out_row(acc_row_out), .out_row_valid(acc_row_valid),
        .any_fifo_full()
    );

    bias #(.NUM_COLS(2), .PSUM_WIDTH(16)) u_bias (
        .clk(clk), .reset(reset),
        .in_row(acc_row_out), .in_row_valid(acc_row_valid),
        .in_bias(in_bias),
        .out_row(final_row_out), .out_row_valid(final_row_valid)
    );

    task automatic load_weights(input int w00, input int w01, input int w10, input int w11);
        write_enable_col_0 = 1; write_data_col_0 = 8'(w10);
        write_enable_col_1 = 1; write_data_col_1 = 8'(w11);
        @(posedge clk); #1;
        write_data_col_0 = 8'(w00);
        write_data_col_1 = 8'(w01);
        @(posedge clk); #1;
        write_enable_col_0 = 0; write_enable_col_1 = 0;
        @(posedge clk); #1;
    endtask

    task automatic trigger_weight_load();
        swap_banks = 1;
        @(posedge clk); #1;
        swap_banks = 0; loading_phase = 1;
        @(posedge clk); #1; 
        @(posedge clk); #1; 
        @(posedge clk); #1; 
        loading_phase = 0;
        @(posedge clk); #1;
    endtask

    task automatic stream_activations(input int a00, input int a01, input int a10, input int a11);
        ub_read_data[0] = 8'(a00); ub_read_data[1] = 8'(a01); ub_read_valid = 1;
        @(posedge clk); #1;
        ub_read_data[0] = 8'(a10); ub_read_data[1] = 8'(a11); ub_read_valid = 1;
        @(posedge clk); #1;
        ub_read_valid = 0;
    endtask

    task automatic stream_single_row(input int a0, input int a1);
        ub_read_data[0] = 8'(a0); ub_read_data[1] = 8'(a1); ub_read_valid = 1;
        @(posedge clk); #1;
        ub_read_valid = 0;
    endtask

    task automatic await_row(input int exp0, input int exp1, input string row_name);
        logic [31:0] raw_val;
        logic signed [15:0] got_c0, got_c1;
        int timeout_cnt;
        
        timeout_cnt = 0;

        while (result_queue.size() == 0) begin
            @(posedge clk);
            timeout_cnt++;
            if (timeout_cnt > 100) begin
                $error("[FATAL] %s TIMEOUT! Pipeline hung or output missed.", row_name);
                errors++;
                $finish;
            end
        end

        // Pop and slice the packed 32-bit value back into two 16-bit signed ints
        raw_val = result_queue.pop_front();
        got_c0  = raw_val[31:16];
        got_c1  = raw_val[15:0];

        if (got_c0 !== 16'(signed'(exp0)) || got_c1 !== 16'(signed'(exp1))) begin
            $error("[FAIL] %s incorrect. Expected [%0d, %0d], Got [%0d, %0d]", 
                   row_name, exp0, exp1, got_c0, got_c1);
            errors++;
        end else begin
            $display("  -> [PASS] %s: [%0d, %0d]", row_name, got_c0, got_c1);
        end
    endtask

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        reset = 1;
        write_enable_col_0 = 0; write_data_col_0 = 0;
        write_enable_col_1 = 0; write_data_col_1 = 0;
        swap_banks = 0;
        loading_phase = 0;
        ub_read_data[0] = 0; ub_read_data[1] = 0; ub_read_valid = 0;
        in_bias[0] = 16'sd100; in_bias[1] = 16'sd200;

        #15 reset = 0;
        @(posedge clk); #1;

        $display("\n=== Starting TPU Core Integration Test Suite ===");

        // ---------------------------------------------------------
        $display("\n[Test 1] Happy Path: Basic Compute");
        load_weights(4, 5, 2, 3);
        trigger_weight_load();
        stream_activations(1, 2, 3, 4);
        
        await_row(108, 211, "Test 1 - Row 0");
        await_row(120, 227, "Test 1 - Row 1");

        // ---------------------------------------------------------
        $display("\n[Test 2] Zero Weights & Activations (Bias check)");
        in_bias[0] = -16'sd10; in_bias[1] = -16'sd20;
        load_weights(0, 0, 0, 0);
        trigger_weight_load();
        stream_activations(0, 0, 0, 0);

        await_row(-10, -20, "Test 2 - Row 0");
        await_row(-10, -20, "Test 2 - Row 1");

        // ---------------------------------------------------------
        $display("\n[Test 3] Negative Signed Arithmetic");
        in_bias[0] = 16'sd0; in_bias[1] = 16'sd0;
        load_weights(-1, -2, -3, -4);
        trigger_weight_load();
        stream_activations(-1, 1, 2, -2);
        
        await_row(-2, -2, "Test 3 - Row 0");
        await_row(4, 4,   "Test 3 - Row 1");

        // ---------------------------------------------------------
        $display("\n[Test 4] Gapped Streaming (Stall Recovery)");
        load_weights(1, 0, 0, 1);
        trigger_weight_load();
        
        stream_single_row(10, 20);
        
        repeat(5) @(posedge clk); 
        
        stream_single_row(30, 40);

        await_row(10, 20, "Test 4 - Row 0");
        await_row(30, 40, "Test 4 - Row 1");

        // ---------------------------------------------------------
        $display("\n[Test 5] Double Buffering / Back-to-Back Matrices");
        in_bias[0] = 16'sd0; in_bias[1] = 16'sd0;
        
        load_weights(1, 0, 0, 1);
        trigger_weight_load();
        stream_activations(5, 15, 25, 35);

        $display("  -> Loading Matrix B into shadow bank while Matrix A computes...");
        load_weights(2, 0, 0, 2);

        await_row(5, 15,  "Test 5 - Matrix A Row 0");
        await_row(25, 35, "Test 5 - Matrix A Row 1");

        trigger_weight_load();
        stream_activations(10, 10, 20, 20);

        await_row(20, 20, "Test 5 - Matrix B Row 0");
        await_row(40, 40, "Test 5 - Matrix B Row 1");

        // ---------------------------------------------------------
        $display("\n=== SIMULATION COMPLETE ===");
        if (errors == 0) begin
            $display(">>> ALL INTEGRATION TESTS PASSED <<<");
        end else begin
            $display(">>> SIMULATION FAILED WITH %0d ERRORS <<<", errors);
        end
        
        $finish;
    end
endmodule
