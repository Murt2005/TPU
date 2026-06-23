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
    logic               mmu_out_0_valid, mmu_out_1_valid;

    // Accumulator inputs/outputs
    logic signed [15:0] accum_in_data  [2];
    logic               accum_in_valid [2];
    logic signed [15:0] acc_row_out  [2];
    logic               acc_row_valid;

    // Bias
    logic signed [15:0] in_bias      [2];
    logic signed [15:0] biased_row   [2];
    logic               biased_valid;

    // Activation (final stage)
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
        .out_row(biased_row), .out_row_valid(biased_valid)
    );

    activation #(.NUM_COLS(2), .PSUM_WIDTH(16)) u_act (
        .clk(clk), .reset(reset),
        .in_row(biased_row), .in_row_valid(biased_valid),
        .out_row(final_row_out), .out_row_valid(final_row_valid)
    );

    // Load two weight rows into the shadow bank (bottom row first, matching
    // the staggered-skew convention: last row reaches its PE first).
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

    // Swap shadow -> active then drain weights into the MMU.
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

    // Stream a 2-row activation matrix (row0 then row1).
    task automatic stream_activations(input int a00, input int a01,
                                      input int a10, input int a11);
        ub_read_data[0] = 8'(a00); ub_read_data[1] = 8'(a01); ub_read_valid = 1;
        @(posedge clk); #1;
        ub_read_data[0] = 8'(a10); ub_read_data[1] = 8'(a11); ub_read_valid = 1;
        @(posedge clk); #1;
        ub_read_valid = 0;
    endtask

    // Stream a single activation row.
    task automatic stream_single_row(input int a0, input int a1);
        ub_read_data[0] = 8'(a0); ub_read_data[1] = 8'(a1); ub_read_valid = 1;
        @(posedge clk); #1;
        ub_read_valid = 0;
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
        ub_read_data[0] = 0; ub_read_data[1] = 0; ub_read_valid = 0;
        in_bias[0] = 16'sd100; in_bias[1] = 16'sd200;

        #15 reset = 0;
        @(posedge clk); #1;

        $display("\n=== Starting TPU Core Integration Test Suite ===");

        // Test 1 – Happy path: basic compute.
        // W=[[4,5],[2,3]], A=[[1,2],[3,4]], bias=[100,200]
        // A@W = [[8,11],[20,27]], biased = [[108,211],[120,227]]
        // ReLU: all positive -> same.
        $display("\n[Test 1] Happy Path: Basic Compute");
        load_weights(4, 5, 2, 3);
        trigger_weight_load();
        stream_activations(1, 2, 3, 4);

        await_row(108, 211, "Test 1 - Row 0");
        await_row(120, 227, "Test 1 - Row 1");

        // Test 2 – Zero weights & activations (bias check).
        // W=[[0,0],[0,0]], A=[[0,0],[0,0]], bias=[-10,-20]
        // A@W = [[0,0],[0,0]], biased = [[-10,-20],[-10,-20]]
        // ReLU: all negative -> clamped to [0,0].
        $display("\n[Test 2] Zero Weights & Activations (ReLU clamps negative bias)");
        in_bias[0] = -16'sd10; in_bias[1] = -16'sd20;
        load_weights(0, 0, 0, 0);
        trigger_weight_load();
        stream_activations(0, 0, 0, 0);

        await_row(0, 0, "Test 2 - Row 0");
        await_row(0, 0, "Test 2 - Row 1");

        // Test 3 – Negative signed arithmetic.
        // W=[[-1,-2],[-3,-4]], A=[[-1,1],[2,-2]], bias=[0,0]
        // Row 0: (-1*-1 + -2*0) = 1, (-1*1 + -2*0) = -1... let's be precise.
        //
        // Weight layout in load_weights: row0=[w00,w01], row1=[w10,w11]
        // W = [[-1,-2],   A = [[-1, 1],
        //      [-3,-4]]        [ 2,-2]]
        // A@W row0 = [-1*-1 + 1*-3, -1*-2 + 1*-4] = [1-3, 2-4] = [-2,-2]
        // A@W row1 = [ 2*-1 +-2*-3,  2*-2 +-2*-4] = [-2+6,-4+8] = [4, 4]
        // bias=[0,0] -> same. ReLU: [-2,-2]->[0,0], [4,4]->[4,4]
        // ------------------------------------------------------------------
        $display("\n[Test 3] Negative Signed Arithmetic (ReLU clamps negative MACs)");
        in_bias[0] = 16'sd0; in_bias[1] = 16'sd0;
        load_weights(-1, -2, -3, -4);
        trigger_weight_load();
        stream_activations(-1, 1, 2, -2);

        await_row(0, 0,  "Test 3 - Row 0");   // [-2,-2] clamped to [0,0]
        await_row(4, 4,  "Test 3 - Row 1");   // [4,4] positive passthrough

        // ------------------------------------------------------------------
        // Test 4 – Gapped streaming (stall recovery).
        // W=[[1,0],[0,1]], A: row0=[10,20] then gap then row1=[30,40], bias=[0,0]
        // A@W row0 = [10,20], row1 = [30,40]. All positive -> ReLU no-op.
        // ------------------------------------------------------------------
        $display("\n[Test 4] Gapped Streaming (Stall Recovery)");
        load_weights(1, 0, 0, 1);
        trigger_weight_load();

        stream_single_row(10, 20);
        repeat(5) @(posedge clk);
        stream_single_row(30, 40);

        await_row(10, 20, "Test 4 - Row 0");
        await_row(30, 40, "Test 4 - Row 1");

        // ------------------------------------------------------------------
        // Test 5 – Double buffering / back-to-back matrices.
        // Matrix A: W=I, A=[[5,15],[25,35]], bias=[0,0] -> [[5,15],[25,35]]
        // Matrix B: W=2*I, A=[[10,10],[20,20]], bias=[0,0] -> [[20,20],[40,40]]
        // All positive -> ReLU no-op.
        // ------------------------------------------------------------------
        $display("\n[Test 5] Double Buffering / Back-to-Back Matrices");
        in_bias[0] = 16'sd0; in_bias[1] = 16'sd0;

        load_weights(1, 0, 0, 1);
        trigger_weight_load();
        stream_activations(5, 15, 25, 35);

        $display("  -> Loading Matrix B into shadow bank while Matrix A computes...");
        load_weights(2, 0, 0, 2);

        await_row(5,  15, "Test 5 - Matrix A Row 0");
        await_row(25, 35, "Test 5 - Matrix A Row 1");

        trigger_weight_load();
        stream_activations(10, 10, 20, 20);

        await_row(20, 20, "Test 5 - Matrix B Row 0");
        await_row(40, 40, "Test 5 - Matrix B Row 1");

        // ------------------------------------------------------------------
        // Test 6 – ReLU clamp via large negative bias.
        // W=[[1,0],[0,1]], A=[[3,7],[5,2]], bias=[-100,-100]
        // A@W = [[3,7],[5,2]] (identity weights)
        // biased = [[-97,-93],[-95,-98]]  -> ReLU -> [[0,0],[0,0]]
        // Verifies the activation stage correctly clamps, not the bias stage.
        // ------------------------------------------------------------------
        $display("\n[Test 6] ReLU Clamp: large negative bias overrides positive MAC");
        in_bias[0] = -16'sd100; in_bias[1] = -16'sd100;
        load_weights(1, 0, 0, 1);
        trigger_weight_load();
        stream_activations(3, 7, 5, 2);

        await_row(0, 0, "Test 6 - Row 0");
        await_row(0, 0, "Test 6 - Row 1");

        // ------------------------------------------------------------------
        // Test 7 – Partial ReLU clamp (mixed: one column clamped, one not).
        // W=[[2,0],[0,3]], A=[[1,1],[1,1]], bias=[-1, 50]
        // A@W row0 = [2*1+0*1, 0*1+3*1] = [2, 3]
        // A@W row1 = [2*1+0*1, 0*1+3*1] = [2, 3]
        // biased   = [[2-1, 3+50],  [2-1, 3+50]]  = [[1,53],[1,53]]
        // ReLU     = [[1,53],[1,53]]   (all positive — both pass through)
        //
        // Now shift bias to make col0 go negative:
        // bias=[-5, 50] -> biased = [[-3,53],[-3,53]] -> ReLU = [[0,53],[0,53]]
        // ------------------------------------------------------------------
        $display("\n[Test 7] Partial ReLU Clamp: col0 clamped, col1 passes through");
        in_bias[0] = -16'sd5; in_bias[1] = 16'sd50;
        load_weights(2, 0, 0, 3);
        trigger_weight_load();
        stream_activations(1, 1, 1, 1);

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
