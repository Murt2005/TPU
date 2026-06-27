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

    // Unified Buffer control signals (host write / UB read)
    logic        host_write_addr;              // 1-bit: ROWS=2 → ADDR_WIDTH=1
    logic signed [7:0] host_write_data [2];
    logic        host_write_valid;
    logic        ub_read_addr;
    logic        ub_read_en;

    // UB → SDS (driven by UB outputs, consumed by SDS)
    logic signed [7:0] ub_read_data [2];
    logic              ub_read_valid;

    // act_write tied off — tpu_core_tb tests single-layer inference only
    logic signed [7:0] ub_act_write_dummy [2];
    assign ub_act_write_dummy[0] = 8'sd0;
    assign ub_act_write_dummy[1] = 8'sd0;

    // Skewed activation data from SDS → MMU
    logic signed [7:0] skewed_act_data [2];
    logic              skewed_act_valid [2];

    // MMU Outputs
    logic signed [15:0] mmu_out_0, mmu_out_1;
    logic               mmu_out_0_valid, mmu_out_1_valid;

    // Accumulator inputs/outputs
    logic signed [15:0] accum_in_data  [2];
    logic               accum_in_valid [2];
    logic signed [15:0] acc_row_out  [2];
    logic               acc_row_valid;

    // Bias
    logic signed [15:0] in_bias    [2];
    logic signed [15:0] biased_row [2];
    logic               biased_valid;

    // Activation (final stage)
    logic signed [15:0] final_row_out [2];
    logic               final_row_valid;

    // Glue: pack MMU scalar outputs into accumulator arrays
    assign accum_in_data[0]  = mmu_out_0;
    assign accum_in_data[1]  = mmu_out_1;
    assign accum_in_valid[0] = mmu_out_0_valid;
    assign accum_in_valid[1] = mmu_out_1_valid;

    int errors = 0;

    // Output monitor queue
    logic [31:0] result_queue[$];

    always_ff @(posedge clk) begin
        if (reset) begin
            result_queue.delete();
        end else if (final_row_valid) begin
            result_queue.push_back({final_row_out[0], final_row_out[1]});
        end
    end

    unified_buffer #(.ROWS(2), .COLS(2), .DATA_WIDTH(8)) u_ub (
        .clk(clk), .reset(reset),
        .host_write_addr(host_write_addr),
        .host_write_data(host_write_data),
        .host_write_valid(host_write_valid),
        // Host read unused in single-layer tests
        .host_read_addr(1'b0),
        .host_read_data(),
        .host_read_en(1'b0),
        .host_read_valid(),
        .ub_read_addr(ub_read_addr),
        .ub_read_en(ub_read_en),
        .ub_read_data(ub_read_data),
        .ub_read_valid(ub_read_valid),
        // Activation write-back unused (single-layer, no bank swap)
        .act_write_data(ub_act_write_dummy),
        .act_write_valid(1'b0),
        .act_write_addr_reset(1'b0),
        .bank_swap(1'b0)
    );

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
        .out_row(biased_row), .out_row_valid(biased_valid)
    );

    activation #(.NUM_COLS(2), .PSUM_WIDTH(16)) u_act (
        .clk(clk), .reset(reset),
        .in_row(biased_row), .in_row_valid(biased_valid),
        .out_row(final_row_out), .out_row_valid(final_row_valid)
    );


    // Pre-load a 2×2 activation matrix into the UB active bank (row by row).
    task automatic write_activations_to_ub(input int a00, input int a01,
                                            input int a10, input int a11);
        host_write_addr    = 1'b0;
        host_write_data[0] = 8'(a00); host_write_data[1] = 8'(a01);
        host_write_valid   = 1;
        @(posedge clk); #1;
        host_write_addr    = 1'b1;
        host_write_data[0] = 8'(a10); host_write_data[1] = 8'(a11);
        @(posedge clk); #1;
        host_write_valid = 0;
    endtask

    // Trigger two consecutive UB reads (rows 0 then 1).
    // The UB's 2-cycle read latency means data arrives at SDS 2 cycles
    // after ub_read_en — the pipeline handles the rest automatically.
    task automatic stream_activations_from_ub();
        ub_read_addr = 1'b0; ub_read_en = 1;
        @(posedge clk); #1;
        ub_read_addr = 1'b1;
        @(posedge clk); #1;
        ub_read_en = 0;
    endtask

    // Load two weight rows into the shadow bank (bottom row first).
    task automatic load_weights(input int w00, input int w01,
                                input int w10, input int w11);
        write_enable_col_0 = 1; write_data_col_0 = 8'(w10);
        write_enable_col_1 = 1; write_data_col_1 = 8'(w11);
        @(posedge clk); #1;
        write_data_col_0 = 8'(w00);
        write_data_col_1 = 8'(w01);
        @(posedge clk); #1;
        write_enable_col_0 = 0; write_enable_col_1 = 0;
        @(posedge clk); #1;
    endtask

    // Swap shadow → active then drain weights into the MMU.
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

    // Block until the next row appears in result_queue, then check it.
    task automatic await_row(input int exp0, input int exp1,
                             input string row_name);
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

        raw_val = result_queue.pop_front();
        got_c0  = raw_val[31:16];
        got_c1  = raw_val[15:0];

        if (got_c0 !== 16'(signed'(exp0)) || got_c1 !== 16'(signed'(exp1))) begin
            $error("[FAIL] %s: Expected [%0d, %0d], Got [%0d, %0d]",
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
        swap_banks    = 0;
        loading_phase = 0;
        host_write_addr = 0; host_write_data[0] = 0; host_write_data[1] = 0;
        host_write_valid = 0;
        ub_read_addr = 0; ub_read_en = 0;
        in_bias[0] = 16'sd100; in_bias[1] = 16'sd200;

        #15 reset = 0;
        @(posedge clk); #1;

        $display("\n=== Starting TPU Core Integration Test Suite ===");

        // ------------------------------------------------------------------
        // Test 1 – Happy path: basic compute.
        // W=[[4,5],[2,3]], A=[[1,2],[3,4]], bias=[100,200]
        // A@W = [[8,11],[20,27]], biased = [[108,211],[120,227]]
        // ReLU: all positive -> same.
        // ------------------------------------------------------------------
        $display("\n[Test 1] Happy Path: Basic Compute");
        write_activations_to_ub(1, 2, 3, 4);
        load_weights(4, 5, 2, 3);
        trigger_weight_load();
        stream_activations_from_ub();

        await_row(108, 211, "Test 1 - Row 0");
        await_row(120, 227, "Test 1 - Row 1");

        // ------------------------------------------------------------------
        // Test 2 – Zero weights & activations (bias check).
        // W=[[0,0],[0,0]], A=[[0,0],[0,0]], bias=[-10,-20]
        // biased = [[-10,-20],[-10,-20]]; ReLU -> [0,0].
        // ------------------------------------------------------------------
        $display("\n[Test 2] Zero Weights & Activations (ReLU clamps negative bias)");
        in_bias[0] = -16'sd10; in_bias[1] = -16'sd20;
        write_activations_to_ub(0, 0, 0, 0);
        load_weights(0, 0, 0, 0);
        trigger_weight_load();
        stream_activations_from_ub();

        await_row(0, 0, "Test 2 - Row 0");
        await_row(0, 0, "Test 2 - Row 1");

        // ------------------------------------------------------------------
        // Test 3 – Negative signed arithmetic.
        // W=[[-1,-2],[-3,-4]], A=[[-1,1],[2,-2]], bias=[0,0]
        // A@W row0 = [-2,-2] → ReLU → [0,0]
        // A@W row1 = [4,4]   → ReLU → [4,4]
        // ------------------------------------------------------------------
        $display("\n[Test 3] Negative Signed Arithmetic (ReLU clamps negative MACs)");
        in_bias[0] = 16'sd0; in_bias[1] = 16'sd0;
        write_activations_to_ub(-1, 1, 2, -2);
        load_weights(-1, -2, -3, -4);
        trigger_weight_load();
        stream_activations_from_ub();

        await_row(0, 0, "Test 3 - Row 0");
        await_row(4, 4, "Test 3 - Row 1");

        // ------------------------------------------------------------------
        // Test 4 – Gapped streaming (stall recovery).
        // W=[[1,0],[0,1]], A: row0=[10,20] then 5-cycle gap then row1=[30,40]
        // A@W row0=[10,20], row1=[30,40]. All positive -> ReLU no-op.
        // ------------------------------------------------------------------
        $display("\n[Test 4] Gapped Streaming (Stall Recovery)");
        write_activations_to_ub(10, 20, 30, 40);
        load_weights(1, 0, 0, 1);
        trigger_weight_load();

        // Stream row 0 from UB, pause, then row 1
        ub_read_addr = 1'b0; ub_read_en = 1;
        @(posedge clk); #1;
        ub_read_en = 0;
        repeat(5) @(posedge clk); #1;
        ub_read_addr = 1'b1; ub_read_en = 1;
        @(posedge clk); #1;
        ub_read_en = 0;

        await_row(10, 20, "Test 4 - Row 0");
        await_row(30, 40, "Test 4 - Row 1");

        // ------------------------------------------------------------------
        // Test 5 – Double buffering / back-to-back matrices.
        // Matrix A: W=I, A=[[5,15],[25,35]], bias=[0,0] -> [[5,15],[25,35]]
        // Matrix B: W=2*I, A=[[10,10],[20,20]], bias=[0,0] -> [[20,20],[40,40]]
        // ------------------------------------------------------------------
        $display("\n[Test 5] Double Buffering / Back-to-Back Matrices");
        in_bias[0] = 16'sd0; in_bias[1] = 16'sd0;

        write_activations_to_ub(5, 15, 25, 35);
        load_weights(1, 0, 0, 1);
        trigger_weight_load();
        stream_activations_from_ub();

        // Load Matrix B weights into shadow while Matrix A computes
        $display("  -> Loading Matrix B weights into shadow while Matrix A computes...");
        load_weights(2, 0, 0, 2);

        await_row(5,  15, "Test 5 - Matrix A Row 0");
        await_row(25, 35, "Test 5 - Matrix A Row 1");

        // Write Matrix B activations to UB then compute
        write_activations_to_ub(10, 10, 20, 20);
        trigger_weight_load();
        stream_activations_from_ub();

        await_row(20, 20, "Test 5 - Matrix B Row 0");
        await_row(40, 40, "Test 5 - Matrix B Row 1");

        // ------------------------------------------------------------------
        // Test 6 – ReLU clamp via large negative bias.
        // W=I, A=[[3,7],[5,2]], bias=[-100,-100] -> all negative -> [[0,0],[0,0]]
        // ------------------------------------------------------------------
        $display("\n[Test 6] ReLU Clamp: large negative bias overrides positive MAC");
        in_bias[0] = -16'sd100; in_bias[1] = -16'sd100;
        write_activations_to_ub(3, 7, 5, 2);
        load_weights(1, 0, 0, 1);
        trigger_weight_load();
        stream_activations_from_ub();

        await_row(0, 0, "Test 6 - Row 0");
        await_row(0, 0, "Test 6 - Row 1");

        // ------------------------------------------------------------------
        // Test 7 – Partial ReLU clamp (col0 clamped, col1 passes through).
        // W=[[2,0],[0,3]], A=[[1,1],[1,1]], bias=[-5,50]
        // A@W = [[2,3],[2,3]]; biased = [[-3,53],[-3,53]]; ReLU = [[0,53],[0,53]]
        // ------------------------------------------------------------------
        $display("\n[Test 7] Partial ReLU Clamp: col0 clamped, col1 passes through");
        in_bias[0] = -16'sd5; in_bias[1] = 16'sd50;
        write_activations_to_ub(1, 1, 1, 1);
        load_weights(2, 0, 0, 3);
        trigger_weight_load();
        stream_activations_from_ub();

        await_row(0, 53, "Test 7 - Row 0");
        await_row(0, 53, "Test 7 - Row 1");

        // ------------------------------------------------------------------
        $display("\n=== SIMULATION COMPLETE ===");
        if (errors == 0) begin
            $display(">>> ALL INTEGRATION TESTS PASSED <<<");
        end else begin
            $display(">>> SIMULATION FAILED WITH %0d ERRORS <<<", errors);
        end

        $finish;
    end
endmodule
