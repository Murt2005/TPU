`timescale 1ns / 1ps

module tpu_core_tb;
    localparam int WEIGHT_WIDTH = 8;
    localparam int FIFO_DEPTH   = 4;

    logic clk;
    logic reset;


    // weight FIFO external interfaces
    logic write_enable_col_0, write_enable_col_1;
    logic signed [WEIGHT_WIDTH-1:0] write_data_col_0, write_data_col_1;
    logic swap_banks;
    logic loading_phase;

    logic [1:0] write_enable_col;
    logic signed [1:0][WEIGHT_WIDTH-1:0] write_data_col;
    assign write_enable_col[0] = write_enable_col_0;
    assign write_enable_col[1] = write_enable_col_1;
    assign write_data_col[0]   = write_data_col_0;
    assign write_data_col[1]   = write_data_col_1;

    logic signed [1:0][WEIGHT_WIDTH-1:0] wf_col;
    logic [1:0] wf_col_valid;

    // unified buffer control signals (host write / UB read)
    logic        host_write_addr;              // 1-bit: ROWS=2 → ADDR_WIDTH=1
    logic signed [1:0][7:0] host_write_data;
    logic        host_write_valid;
    logic        ub_read_addr;
    logic        ub_read_en;

    // UB → SDS (driven by UB outputs, consumed by SDS)
    logic signed [1:0][7:0] ub_read_data;
    logic              ub_read_valid;

    // act_write tied off — tpu_core_tb tests single-layer inference only
    logic signed [1:0][7:0] ub_act_write_dummy;
    assign ub_act_write_dummy[0] = 8'sd0;
    assign ub_act_write_dummy[1] = 8'sd0;

    // skewed activation data from SDS → MMU
    logic signed [1:0][7:0] skewed_act_data;
    logic              [1:0] skewed_act_valid;

    // accumulator inputs/outputs
    logic signed [1:0][15:0] accum_in_data;
    logic              [1:0] accum_in_valid;
    logic signed [1:0][15:0] acc_row_out;
    logic               acc_row_valid;
    logic               acc_pass_done;
    // K-tiling control -- tied first=last=1 (single-shot) except test 8
    logic               tile_first = 1'b1;
    logic               tile_last  = 1'b1;

    // bias
    logic signed [1:0][15:0] in_bias;
    logic signed [1:0][15:0] biased_row;
    logic               biased_valid;

    // activation (final stage)
    logic signed [1:0][15:0] final_row_out;
    logic               final_row_valid;

    int errors = 0;

    // output monitor queue
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
        // host read unused in single-layer tests
        .host_read_addr(1'b0),
        .host_read_data(),
        .host_read_en(1'b0),
        .host_read_valid(),
        .ub_read_addr(ub_read_addr),
        .ub_read_en(ub_read_en),
        .ub_read_data(ub_read_data),
        .ub_read_valid(ub_read_valid),
        // activation write-back unused (single-layer, no bank swap)
        .act_write_data(ub_act_write_dummy),
        .act_write_valid(1'b0),
        .act_write_addr_reset(1'b0),
        .bank_swap(1'b0)
    );

    weight_fifo #(.WEIGHT_WIDTH(WEIGHT_WIDTH), .FIFO_DEPTH(FIFO_DEPTH)) u_wf (
        .clk(clk), .reset(reset),
        .write_enable_col(write_enable_col), .write_data_col(write_data_col),
        .swap_banks(swap_banks), .loading_phase(loading_phase),
        .out_col(wf_col), .out_col_valid(wf_col_valid),
        .shadow_loaded(), .active_bank(), .active_empty(),
        .active_full(), .any_shadow_full()
    );

    systolic_data_setup #(.ARRAY_ROWS(2), .DATA_WIDTH(8)) u_skew (
        .clk(clk), .reset(reset),
        .ub_read_data(ub_read_data), .ub_read_valid(ub_read_valid),
        .mmu_in_row(skewed_act_data), .mmu_in_valid(skewed_act_valid)
    );

    mmu #(.ARRAY_ROWS(2), .NUM_COLS(2)) u_mmu (
        .clk(clk), .reset(reset),
        .loading_phase(loading_phase),
        .capture_weight_col(wf_col_valid),
        .in_col(wf_col), .in_col_valid(wf_col_valid),
        .in_row(skewed_act_data), .in_row_valid(skewed_act_valid),
        .out_partial_sum(accum_in_data), .out_partial_sum_valid(accum_in_valid)
    );

    accumulator #(.NUM_COLS(2), .PSUM_WIDTH(16), .FIFO_DEPTH(FIFO_DEPTH)) u_accum (
        .clk(clk), .reset(reset),
        .in_partial_sum(accum_in_data), .in_partial_sum_valid(accum_in_valid),
        .tile_first(tile_first), .tile_last(tile_last),
        .out_row(acc_row_out), .out_row_valid(acc_row_valid),
        .pass_done(acc_pass_done),
        .any_fifo_full()
    );

    bias #(.NUM_COLS(2), .PSUM_WIDTH(16)) u_bias (
        .clk(clk), .reset(reset),
        .in_row(acc_row_out), .in_row_valid(acc_row_valid),
        .in_bias(in_bias),
        .out_row(biased_row), .out_row_valid(biased_valid)
    );

    activation #(.NUM_COLS(2), .PSUM_WIDTH(16)) u_act (
        .bypass(1'b0),   // relu always on in this bench
        .clk(clk), .reset(reset),
        .in_row(biased_row), .in_row_valid(biased_valid),
        .out_row(final_row_out), .out_row_valid(final_row_valid)
    );


    // pre-load a 2×2 activation matrix into the UB active bank (row by row)
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

    task automatic stream_activations_from_ub();
        ub_read_addr = 1'b0; ub_read_en = 1;
        @(posedge clk); #1;
        ub_read_addr = 1'b1;
        @(posedge clk); #1;
        ub_read_en = 0;
    endtask

    // load two weight rows into the shadow bank (bottom row first)
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

    // swap shadow → active then drain weights into the MMU
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

    // block until the next row appears in result_queue, then check it
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

    // block until acc_pass_done pulses (used for non-final K-tile passes,
    // where tile_last=0 means final_row_valid/result_queue never fire).
    task automatic await_pass_done(input string label);
        int timeout_cnt;
        timeout_cnt = 0;
        while (!acc_pass_done) begin
            @(posedge clk);
            timeout_cnt++;
            if (timeout_cnt > 100) begin
                $error("[FATAL] %s TIMEOUT waiting for pass_done.", label);
                errors++;
                $finish;
            end
        end
        $display("  -> [PASS] %s: pass_done seen", label);
        @(posedge clk);
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

        // test 1: W=[[4,5],[2,3]], A=[[1,2],[3,4]], bias=[100,200] -> [[108,211],[120,227]]
        $display("\n[Test 1] Happy Path: Basic Compute");
        write_activations_to_ub(1, 2, 3, 4);
        load_weights(4, 5, 2, 3);
        trigger_weight_load();
        stream_activations_from_ub();

        await_row(108, 211, "Test 1 - Row 0");
        await_row(120, 227, "Test 1 - Row 1");

        // test 2: all zero with bias [-10,-20] -> clamped to 0
        $display("\n[Test 2] Zero Weights & Activations (ReLU clamps negative bias)");
        in_bias[0] = -16'sd10; in_bias[1] = -16'sd20;
        write_activations_to_ub(0, 0, 0, 0);
        load_weights(0, 0, 0, 0);
        trigger_weight_load();
        stream_activations_from_ub();

        await_row(0, 0, "Test 2 - Row 0");
        await_row(0, 0, "Test 2 - Row 1");

        // test 3: negative arithmetic, A@W = [[-2,-2],[4,4]] -> [[0,0],[4,4]]
        $display("\n[Test 3] Negative Signed Arithmetic (ReLU clamps negative MACs)");
        in_bias[0] = 16'sd0; in_bias[1] = 16'sd0;
        write_activations_to_ub(-1, 1, 2, -2);
        load_weights(-1, -2, -3, -4);
        trigger_weight_load();
        stream_activations_from_ub();

        await_row(0, 0, "Test 3 - Row 0");
        await_row(4, 4, "Test 3 - Row 1");

        // test 4: a 5-cycle gap between rows
        $display("\n[Test 4] Gapped Streaming (Stall Recovery)");
        write_activations_to_ub(10, 20, 30, 40);
        load_weights(1, 0, 0, 1);
        trigger_weight_load();

        // stream row 0 from UB, pause, then row 1
        ub_read_addr = 1'b0; ub_read_en = 1;
        @(posedge clk); #1;
        ub_read_en = 0;
        repeat(5) @(posedge clk); #1;
        ub_read_addr = 1'b1; ub_read_en = 1;
        @(posedge clk); #1;
        ub_read_en = 0;

        await_row(10, 20, "Test 4 - Row 0");
        await_row(30, 40, "Test 4 - Row 1");

        // test 5: back-to-back matrices, W=I then W=2I
        $display("\n[Test 5] Double Buffering / Back-to-Back Matrices");
        in_bias[0] = 16'sd0; in_bias[1] = 16'sd0;

        write_activations_to_ub(5, 15, 25, 35);
        load_weights(1, 0, 0, 1);
        trigger_weight_load();
        stream_activations_from_ub();

        // load matrix B weights into shadow while matrix A computes
        $display("  -> Loading Matrix B weights into shadow while Matrix A computes...");
        load_weights(2, 0, 0, 2);

        await_row(5,  15, "Test 5 - Matrix A Row 0");
        await_row(25, 35, "Test 5 - Matrix A Row 1");

        // write matrix B activations to UB then compute
        write_activations_to_ub(10, 10, 20, 20);
        trigger_weight_load();
        stream_activations_from_ub();

        await_row(20, 20, "Test 5 - Matrix B Row 0");
        await_row(40, 40, "Test 5 - Matrix B Row 1");

        // test 6: bias [-100,-100] clamps everything
        $display("\n[Test 6] ReLU Clamp: large negative bias overrides positive MAC");
        in_bias[0] = -16'sd100; in_bias[1] = -16'sd100;
        write_activations_to_ub(3, 7, 5, 2);
        load_weights(1, 0, 0, 1);
        trigger_weight_load();
        stream_activations_from_ub();

        await_row(0, 0, "Test 6 - Row 0");
        await_row(0, 0, "Test 6 - Row 1");

        // test 7: bias [-5,50] clamps col0 only -> [[0,53],[0,53]]
        $display("\n[Test 7] Partial ReLU Clamp: col0 clamped, col1 passes through");
        in_bias[0] = -16'sd5; in_bias[1] = 16'sd50;
        write_activations_to_ub(1, 1, 1, 1);
        load_weights(2, 0, 0, 3);
        trigger_weight_load();
        stream_activations_from_ub();

        await_row(0, 53, "Test 7 - Row 0");
        await_row(0, 53, "Test 7 - Row 1");

        // test 8: K-tiling through the full datapath, two 2x2 K-tiles -> [[7,10],[19,22]].
        // pass 1 (first=1,last=0) must only raise pass_done, never final_row_valid
        $display("\n[Test 8] K-dim tiling: two weight-reload passes, hardware-side accumulation");
        in_bias[0] = 16'sd0; in_bias[1] = 16'sd0;

        tile_first = 1'b1; tile_last = 1'b0;
        write_activations_to_ub(1, 2, 5, 6);
        load_weights(1, 0, 0, 1);
        trigger_weight_load();
        stream_activations_from_ub();
        await_pass_done("Test 8 - K-tile 0 pass_done");

        if (result_queue.size() != 0) begin
            $error("[FAIL] Test 8: tile_last=0 pass must not push to result_queue (got %0d)",
                   result_queue.size());
            errors++;
        end

        tile_first = 1'b0; tile_last = 1'b1;
        write_activations_to_ub(3, 4, 7, 8);
        load_weights(2, 0, 0, 2);
        trigger_weight_load();
        stream_activations_from_ub();

        await_row(7,  10, "Test 8 - Row 0");
        await_row(19, 22, "Test 8 - Row 1");

        tile_first = 1'b1; tile_last = 1'b1;   // restore single-shot default

        $display("\n=== SIMULATION COMPLETE ===");
        if (errors == 0) begin
            $display(">>> ALL INTEGRATION TESTS PASSED <<<");
        end else begin
            $display(">>> SIMULATION FAILED WITH %0d ERRORS <<<", errors);
        end

        $finish;
    end
endmodule
