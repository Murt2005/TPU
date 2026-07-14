`timescale 1ns / 1ps

// tpu_sequencer_4x4_tb — the M4 target shape: 16 PEs on 8 SB_MAC16s.
//
// Runs the full sequencer + datapath at ARRAY_ROWS=4, NUM_COLS=4, M_TILE=4 —
// the shape fpga/Makefile builds with USE_MAC16_PAIR=1 (each pair of
// row-adjacent PEs shares one hand-instantiated SB_MAC16 in dual-8x8 mode;
// fits at 93% LC with ABC_FLAGS=-abc9 -dff + the BRAM-backed unified
// buffer). The mmu is instantiated with USE_MAC16_PAIR=1 here, so this tb
// simulates the *shipped* DSP netlist path (yosys's SB_MAC16 model), not
// behavioral pe.sv.
//
// Matrix shapes at this parameterization:
//   W : 4x4  (ARRAY_ROWS x NUM_COLS)   LOAD_WEIGHTS LEN = 16, rows bottom-first
//   A : 4x4  (M_TILE x ARRAY_ROWS)     LOAD_ACT     LEN = 16, row-major
//   B : 4    (NUM_COLS int16)          LOAD_BIAS    LEN = 8
//   Y : 4x4  (M_TILE x NUM_COLS)       RUN response LEN = 32 (int16 LE)
//
// Expected results are computed in the testbench (integer matmul + bias +
// ReLU), not hand-entered, so stimulus values can be arbitrary.
// Avoids: dynamic arrays, open-array task args, `return` in tasks (iverilog limits).

module tpu_sequencer_4x4_tb;

    localparam int ARRAY_ROWS = 4;
    localparam int NUM_COLS   = 4;
    localparam int M_TILE     = 4;

    localparam int WEIGHT_WIDTH = 8;
    localparam int FIFO_DEPTH   = 4;   // >= ARRAY_ROWS (weight_fifo), >= M_TILE (accumulator)
    localparam int UB_ADDR_W    = $clog2(M_TILE);

    localparam int W_BYTES      = ARRAY_ROWS * NUM_COLS;   // 16
    localparam int A_BYTES      = M_TILE * ARRAY_ROWS;     // 8
    localparam int B_BYTES      = 2 * NUM_COLS;            // 8
    localparam int RESULT_BYTES = 2 * M_TILE * NUM_COLS;   // 16

    logic clk = 0;
    logic reset;
    logic dp_reset;
    int   errors = 0;

    // sequencer ports
    logic [7:0] rx_data;
    logic       rx_valid;
    logic [7:0] tx_data;
    logic       tx_valid_out;
    logic       tx_busy;

    logic        [NUM_COLS-1:0]      seq_we_col;
    logic signed [NUM_COLS-1:0][7:0] seq_wd_col;
    logic              seq_swap_banks;
    logic              seq_loading_phase;
    logic        [UB_ADDR_W-1:0]       seq_hw_addr;
    logic signed [ARRAY_ROWS-1:0][7:0] seq_hw_data;
    logic              seq_hw_valid;
    logic        [UB_ADDR_W-1:0] seq_ub_addr;
    logic              seq_ub_en;
    logic signed [NUM_COLS-1:0][15:0] seq_bias;
    logic               seq_tile_first, seq_tile_last;
    logic               accum_pass_done;
    logic signed [NUM_COLS-1:0][15:0] final_row_out;
    logic               final_row_valid;
    logic               seq_tpu_reset;
    logic               busy;

    // tx_busy = 0: testbench accepts every byte immediately
    assign tx_busy = 1'b0;
    assign dp_reset = reset | seq_tpu_reset;

    // datapath wires
    logic signed [ARRAY_ROWS-1:0][7:0]  ub_read_data;
    logic               ub_read_valid;
    logic signed [ARRAY_ROWS-1:0][7:0]  skewed_act;
    logic        [ARRAY_ROWS-1:0]       skewed_valid;
    logic signed [NUM_COLS-1:0][7:0]  wf_col;
    logic        [NUM_COLS-1:0]       wf_col_valid;
    logic signed [NUM_COLS-1:0][15:0] accum_in_data;
    logic        [NUM_COLS-1:0]       accum_in_valid;
    logic signed [NUM_COLS-1:0][15:0] acc_row_out;
    logic               acc_row_valid;
    logic signed [NUM_COLS-1:0][15:0] biased_row;
    logic               biased_valid;
    logic signed [ARRAY_ROWS-1:0][7:0]  ub_act_dummy;

    assign ub_act_dummy = '0;

    // DUT + datapath
    tpu_sequencer #(
        .ARRAY_ROWS(ARRAY_ROWS), .NUM_COLS(NUM_COLS), .M_TILE(M_TILE),
        .WAIT_TIMEOUT(200)
    ) dut (
        .clk(clk), .reset(reset),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_error(1'b0),
        .tx_data(tx_data), .tx_valid(tx_valid_out), .tx_busy(tx_busy),
        .write_enable_col(seq_we_col), .write_data_col(seq_wd_col),
        .swap_banks(seq_swap_banks), .loading_phase(seq_loading_phase),
        .host_write_addr(seq_hw_addr), .host_write_data(seq_hw_data),
        .host_write_valid(seq_hw_valid),
        .ub_read_addr(seq_ub_addr), .ub_read_en(seq_ub_en),
        .out_bias(seq_bias),
        .tile_first(seq_tile_first), .tile_last(seq_tile_last),
        .accum_pass_done(accum_pass_done),
        .final_row_out(final_row_out), .final_row_valid(final_row_valid),
        .tpu_reset(seq_tpu_reset), .busy(busy)
    );

    // UB: M_TILE addresses, each one ARRAY_ROWS-wide activation row
    unified_buffer #(.ROWS(M_TILE), .COLS(ARRAY_ROWS), .DATA_WIDTH(8)) u_ub (
        .clk(clk), .reset(dp_reset),
        .host_write_addr(seq_hw_addr), .host_write_data(seq_hw_data),
        .host_write_valid(seq_hw_valid),
        .host_read_addr({UB_ADDR_W{1'b0}}), .host_read_data(), .host_read_en(1'b0), .host_read_valid(),
        .ub_read_addr(seq_ub_addr), .ub_read_en(seq_ub_en),
        .ub_read_data(ub_read_data), .ub_read_valid(ub_read_valid),
        .act_write_data(ub_act_dummy), .act_write_valid(1'b0),
        .act_write_addr_reset(1'b0), .bank_swap(1'b0)
    );

    weight_fifo #(.WEIGHT_WIDTH(WEIGHT_WIDTH), .FIFO_DEPTH(FIFO_DEPTH), .NUM_COLS(NUM_COLS)) u_wf (
        .clk(clk), .reset(dp_reset),
        .write_enable_col(seq_we_col), .write_data_col(seq_wd_col),
        .swap_banks(seq_swap_banks), .loading_phase(seq_loading_phase),
        .out_col(wf_col), .out_col_valid(wf_col_valid),
        .shadow_loaded(), .active_bank(), .active_empty(), .active_full(), .any_shadow_full()
    );

    systolic_data_setup #(.ARRAY_ROWS(ARRAY_ROWS), .DATA_WIDTH(8)) u_sds (
        .clk(clk), .reset(dp_reset),
        .ub_read_data(ub_read_data), .ub_read_valid(ub_read_valid),
        .mmu_in_row(skewed_act), .mmu_in_valid(skewed_valid)
    );

    mmu #(.ARRAY_ROWS(ARRAY_ROWS), .NUM_COLS(NUM_COLS), .USE_MAC16_PAIR(1)) u_mmu (
        .clk(clk), .reset(dp_reset), .loading_phase(seq_loading_phase),
        .capture_weight_col(wf_col_valid),
        .in_col(wf_col), .in_col_valid(wf_col_valid),
        .in_row(skewed_act), .in_row_valid(skewed_valid),
        .out_partial_sum(accum_in_data), .out_partial_sum_valid(accum_in_valid)
    );

    // accumulator's ARRAY_ROWS parameter = output rows per pass = M_TILE
    accumulator #(.NUM_COLS(NUM_COLS), .PSUM_WIDTH(16), .FIFO_DEPTH(FIFO_DEPTH), .ARRAY_ROWS(M_TILE)) u_accum (
        .clk(clk), .reset(dp_reset),
        .in_partial_sum(accum_in_data), .in_partial_sum_valid(accum_in_valid),
        .tile_first(seq_tile_first), .tile_last(seq_tile_last),
        .out_row(acc_row_out), .out_row_valid(acc_row_valid),
        .pass_done(accum_pass_done), .any_fifo_full()
    );

    bias #(.NUM_COLS(NUM_COLS), .PSUM_WIDTH(16)) u_bias (
        .clk(clk), .reset(dp_reset),
        .in_row(acc_row_out), .in_row_valid(acc_row_valid),
        .in_bias(seq_bias), .out_row(biased_row), .out_row_valid(biased_valid)
    );

    activation #(.NUM_COLS(NUM_COLS), .PSUM_WIDTH(16)) u_act (
        .clk(clk), .reset(dp_reset),
        .in_row(biased_row), .in_row_valid(biased_valid),
        .out_row(final_row_out), .out_row_valid(final_row_valid)
    );

    always #5 clk = ~clk;

    // Stimulus matrices (int8-range values) + tb-side expected accumulator
    int W [ARRAY_ROWS][NUM_COLS];
    int A [M_TILE][ARRAY_ROWS];
    int B [NUM_COLS];
    int ACC [M_TILE][NUM_COLS];   // running A@W sum across K-tile passes

    // RX byte inject
    task automatic host_send_byte(input logic [7:0] b);
        @(posedge clk); #1;
        rx_data  = b;
        rx_valid = 1'b1;
        @(posedge clk); #1;
        rx_valid = 1'b0;
    endtask

    // TX byte capture. Concurrent: a response can start while the stimulus
    // side is still pacing out a STREAM_RUN frame's bytes (tx_busy is tied
    // low, so the whole response fires within a few cycles) — polling for
    // tx_valid only after sending would miss those 1-cycle pulses. Capture
    // every byte as it happens; collect_n just waits for the count.
    logic [7:0] rx_buf [2 + RESULT_BYTES];
    integer     cap_idx = 0;

    always @(posedge clk) begin
        if (tx_valid_out && cap_idx < 2 + RESULT_BYTES) begin
            rx_buf[cap_idx] = tx_data;
            cap_idx = cap_idx + 1;
        end
    end

    // Wait until n response bytes have been captured, then reset the
    // capture index (protocol is strictly request/response, so each
    // response is fully consumed before the next command is sent).
    task automatic collect_n(integer n);
        integer timeout;
        timeout = 0;
        while (cap_idx < n) begin
            @(posedge clk);
            timeout = timeout + 1;
            if (timeout > 5000) begin
                $error("[FATAL] Timeout waiting for %0d response bytes (got %0d)", n, cap_idx);
                errors = errors + 1;
                cap_idx = 0;
                disable collect_n;
            end
        end
        cap_idx = 0;
    endtask

    task automatic expect_ack(input string label);
        collect_n(2);
        if (rx_buf[0] !== 8'hAA || rx_buf[1] !== 8'h00) begin
            $error("[FAIL] %s ACK: got [%02X,%02X]", label, rx_buf[0], rx_buf[1]);
            errors++;
        end
    endtask

    // Send W over the wire: LOAD_WEIGHTS, rows bottom-first (wire contract)
    task automatic send_weights(input string label);
        host_send_byte(8'h01);
        host_send_byte(8'(W_BYTES));
        for (int i = ARRAY_ROWS - 1; i >= 0; i--)
            for (int c = 0; c < NUM_COLS; c++)
                host_send_byte(8'(W[i][c]));
        expect_ack({label, " WEIGHTS"});
    endtask

    // Send B: LOAD_BIAS, NUM_COLS int16 LE
    task automatic send_bias(input string label);
        logic signed [15:0] b16;
        host_send_byte(8'h02);
        host_send_byte(8'(B_BYTES));
        for (int c = 0; c < NUM_COLS; c++) begin
            b16 = 16'(B[c]);
            host_send_byte(b16[7:0]);
            host_send_byte(b16[15:8]);
        end
        expect_ack({label, " BIAS"});
    endtask

    // Send A: LOAD_ACT, natural row-major
    task automatic send_act(input string label);
        host_send_byte(8'h03);
        host_send_byte(8'(A_BYTES));
        for (int m = 0; m < M_TILE; m++)
            for (int k = 0; k < ARRAY_ROWS; k++)
                host_send_byte(8'(A[m][k]));
        expect_ack({label, " ACT"});
    endtask

    // Fold the current A@W into the tb-side running sum (one K-tile pass)
    task automatic accumulate_expected(input logic first);
        int s;
        for (int m = 0; m < M_TILE; m++)
            for (int c = 0; c < NUM_COLS; c++) begin
                s = 0;
                for (int k = 0; k < ARRAY_ROWS; k++)
                    s = s + A[m][k] * W[k][c];
                ACC[m][c] = first ? s : ACC[m][c] + s;
            end
    endtask

    // Collect and check a full RUN result against ACC + bias + ReLU.
    // Overflow semantics match the hardware exactly: the accumulator/bias
    // adders are 16-bit with silent wraparound and ReLU fires *after* that
    // truncation (rtl/accumulator.sv, rtl/bias.sv, rtl/activation.sv) --
    // same golden model as tests/hw_regression.py's golden().
    task automatic check_result(input string label);
        logic signed [15:0] exp16;
        int errors_before;
        logic signed [15:0] got;
        errors_before = errors;
        collect_n(2 + RESULT_BYTES);
        if (rx_buf[0] !== 8'hAA || rx_buf[1] !== 8'(RESULT_BYTES)) begin
            $error("[FAIL] %s RUN header: [%02X,%02X]", label, rx_buf[0], rx_buf[1]);
            errors++;
        end else begin
            for (int m = 0; m < M_TILE; m++)
                for (int c = 0; c < NUM_COLS; c++) begin
                    exp16 = 16'(ACC[m][c] + B[c]);   // non-saturating 16-bit wrap
                    if (exp16 < 0) exp16 = '0;       // ReLU after truncation
                    got = signed'({rx_buf[2 + 2*(m*NUM_COLS + c) + 1],
                                   rx_buf[2 + 2*(m*NUM_COLS + c)]});
                    if (got !== exp16) begin
                        $error("[FAIL] %s r%0dc%0d: exp %0d got %0d",
                               label, m, c, exp16, got);
                        errors++;
                    end
                end
            if (errors == errors_before)
                $display("[PASS] %s: all %0dx%0d results match", label, M_TILE, NUM_COLS);
        end
        repeat (20) @(posedge clk);
    endtask

    // Single-shot compute: load W/B/A, RUN LEN=0, check
    task automatic do_compute(input string label);
        send_weights(label);
        send_bias(label);
        send_act(label);
        host_send_byte(8'h04);
        host_send_byte(8'h00);
        accumulate_expected(1'b1);
        check_result(label);
    endtask

    // RUN_TILE (0x06): current W and A in ONE frame, weights in NATURAL
    // row-major order (no bottom-first pre-reversal — that's RUN_TILE's wire
    // contract, unlike legacy LOAD_WEIGHTS). last=0 expects a bare ACK;
    // last=1 checks the accumulated result.
    task automatic do_run_tile_pass(input logic first, input logic last, input string label);
        host_send_byte(8'h06);
        host_send_byte(8'(1 + W_BYTES + A_BYTES));
        host_send_byte({6'b0, last, first});
        for (int r = 0; r < ARRAY_ROWS; r++)
            for (int c = 0; c < NUM_COLS; c++)
                host_send_byte(8'(W[r][c]));
        for (int m = 0; m < M_TILE; m++)
            for (int k = 0; k < ARRAY_ROWS; k++)
                host_send_byte(8'(A[m][k]));
        accumulate_expected(first);
        if (last) begin
            check_result(label);
        end else begin
            expect_ack({label, " mid-tile"});
            $display("[PASS] %s: tile ACK received (no data yet)", label);
            repeat (20) @(posedge clk);
        end
    endtask

    // STREAM_RUN payload bytes go paced: the sequencer runs a full pipeline
    // pass (~30 cycles at this shape) between tiles without consuming rx
    // bytes, relying on the real UART byte cadence (~120 cycles/byte at
    // 12 MHz/1 Mbaud) to cover it. 60 cycles/byte models that floor.
    task automatic sr_send_byte(input logic [7:0] b);
        host_send_byte(b);
        repeat (60) @(posedge clk);
    endtask

    // Send the current W (natural row-major) + A as one STREAM_RUN tile and
    // fold it into the tb-side expected accumulator.
    task automatic sr_send_tile(input logic first);
        for (int r = 0; r < ARRAY_ROWS; r++)
            for (int c = 0; c < NUM_COLS; c++)
                sr_send_byte(8'(W[r][c]));
        for (int m = 0; m < M_TILE; m++)
            for (int k = 0; k < ARRAY_ROWS; k++)
                sr_send_byte(8'(A[m][k]));
        accumulate_expected(first);
    endtask

    // Tiled RUN pass (LEN=1 flags). first/last as in the protocol; when
    // last=0 expects a bare ACK, when last=1 checks the accumulated result.
    task automatic do_tiled_pass(input logic first, input logic last, input string label);
        send_weights(label);
        send_act(label);
        host_send_byte(8'h04);
        host_send_byte(8'h01);
        host_send_byte({6'b0, last, first});
        accumulate_expected(first);
        if (last) begin
            check_result(label);
        end else begin
            expect_ack({label, " mid-tile"});
            $display("[PASS] %s: tile ACK received (no data yet)", label);
            repeat (20) @(posedge clk);
        end
    endtask

    int urandom_seed;

    initial begin
        clk      = 0;
        reset    = 1;
        rx_data  = '0;
        rx_valid = 1'b0;

        repeat (4) @(posedge clk); #1;
        reset = 0;
        @(posedge clk); #1;

        $display("\n=== Starting tpu_sequencer 4x4 (M_TILE=2, SB_MAC16 pairs) Testbench ===\n");

        // Test 1: asymmetric values everywhere — any transposed/conflated
        // index produces a different product. Mixed-sign to cross ReLU.
        $display("[Test 1] Full matmul, asymmetric W/A, mixed-sign bias");
        W = '{'{1, 2, 3, 4}, '{5, 6, 7, 8}, '{9, 10, 11, 12}, '{13, 14, 15, 16}};
        A = '{'{1, 2, 3, -4}, '{5, -6, 7, 8}, '{-2, 4, 1, 3}, '{6, 0, -5, 2}};
        B = '{10, -20, 5, -40};
        do_compute("T1");

        // Test 2: one-hot weight columns select single A columns — catches
        // row/col ordering bugs in the weight path specifically.
        // W is the cyclic permutation: col c = e_{(c+1) mod 4}, so output
        // col c picks A[:, (c+1) mod 4].
        $display("[Test 2] One-hot weight columns (selection matrix)");
        W = '{'{0, 0, 0, 1}, '{1, 0, 0, 0}, '{0, 1, 0, 0}, '{0, 0, 1, 0}};
        A = '{'{11, 22, -33, 44}, '{55, -66, 77, 88}, '{-12, 34, 56, -78}, '{9, -8, 7, -6}};
        B = '{0, 0, 0, 0};
        do_compute("T2");

        // Test 3: K-dim tiling over the wire — two passes accumulate in the
        // datapath (Y = A0@W0 + A1@W1 + B), exercising rows_got/M_TILE and
        // accum_pass_done at the wide shape.
        $display("[Test 3] K-dim tiling over the wire (LEN=1 RUN flags)");
        B = '{5, -5, 15, -15};
        send_bias("T3");
        W = '{'{2, 0, -1, 3}, '{0, 3, 2, -2}, '{1, -1, 0, 2}, '{-2, 0, 3, 1}};
        A = '{'{1, 2, -1, 3}, '{-3, 4, 0, -2}, '{2, -1, 3, 1}, '{0, 2, -2, 4}};
        do_tiled_pass(1'b1, 1'b0, "T3 K-tile0");
        W = '{'{1, -1, 4, 0}, '{2, -2, 0, 4}, '{0, 1, -3, 2}, '{3, 0, 1, -1}};
        A = '{'{2, 2, -1, 0}, '{1, 0, 3, -2}, '{-1, 3, 0, 2}, '{4, -2, 1, 0}};
        do_tiled_pass(1'b0, 1'b1, "T3 K-tile1");

        // Test 4: single-shot RUN_TILE at the 4x4 shape
        // (LEN = 1 + 16 + 16 = 33 bytes in one frame).
        $display("[Test 4] RUN_TILE single frame, 4x4 shape");
        W = '{'{3, -2, 1, 0}, '{-1, 4, -3, 2}, '{2, 1, 0, -3}, '{0, -1, 2, 4}};
        A = '{'{4, -3, 2, 1}, '{1, 5, -2, 0}, '{-3, 2, 4, -1}, '{0, 1, -4, 3}};
        B = '{7, -7, 3, -3};
        send_bias("T4");
        do_run_tile_pass(1'b1, 1'b1, "T4 RUN_TILE");

        // Test 5: K-dim tiling via RUN_TILE frames (same accumulator math
        // as Test 3, one frame per K-tile).
        $display("[Test 5] K-dim tiling via RUN_TILE frames, 4x4 shape");
        B = '{-3, 3, -6, 6};
        send_bias("T5");
        W = '{'{1, 2, -2, 0}, '{-2, 1, 3, 1}, '{0, -1, 2, 3}, '{1, 0, -1, 2}};
        A = '{'{1, 0, 2, -1}, '{2, -2, 0, 1}, '{3, 1, -1, 0}, '{-2, 0, 2, 1}};
        do_run_tile_pass(1'b1, 1'b0, "T5 K-tile0");
        W = '{'{-1, 1, 2, 2}, '{0, 3, 1, 0}, '{2, -2, 0, 1}, '{-1, 0, 3, -2}};
        A = '{'{3, 1, -2, 0}, '{-1, 0, 1, 2}, '{0, -3, 2, 1}, '{1, 2, 0, -2}};
        do_run_tile_pass(1'b0, 1'b1, "T5 K-tile1");

        // Test 6: STREAM_RUN with 3 tiles in one frame at the 4x4 shape
        // — LEN = 2 + 3*(16+16) = 98 bytes, one response.
        $display("[Test 6] STREAM_RUN: 3 tiles, one frame, 4x4 shape");
        B = '{11, -11, 22, -22};
        send_bias("T6");
        host_send_byte(8'h07);
        host_send_byte(8'(2 + 3*(W_BYTES + A_BYTES)));
        sr_send_byte(8'h03);   // flags = TILE_FIRST|TILE_LAST
        sr_send_byte(8'd3);    // K_TILES = 3
        W = '{'{1, 2, 3, -1}, '{0, 2, -2, 1}, '{2, -1, 1, 0}, '{-1, 0, 2, 3}};
        A = '{'{1, 2, -1, 0}, '{5, -1, 2, 1}, '{0, 3, 1, -2}, '{-1, 2, 0, 1}};
        sr_send_tile(1'b1);
        W = '{'{2, 0, 0, -2}, '{1, 1, 3, 0}, '{0, 2, -1, 1}, '{3, -2, 0, 2}};
        A = '{'{0, 1, 2, -2}, '{2, 2, -1, 3}, '{1, -1, 0, 2}, '{3, 0, -2, 1}};
        sr_send_tile(1'b0);
        W = '{'{-1, 3, 1, 1}, '{2, -1, 0, 2}, '{1, 0, -2, 3}, '{0, 1, 2, -1}};
        A = '{'{1, 1, 0, -3}, '{-2, 0, 1, 2}, '{2, -1, 3, 0}, '{0, 2, -1, 1}};
        sr_send_tile(1'b0);
        check_result("T6 STREAM_RUN");

        // Test 7: randomized full-int8-range stress via RUN_TILE -- weights
        // and activations across [-128,127], bias across [-1000,1000],
        // exercising PSUM_WIDTH wraparound + post-truncation ReLU at the
        // deployed shape (the value class tests/hw_regression.py's stress
        // run uses on real hardware; T1-T6's hand-picked values never
        // overflow, so they can't catch a wraparound-path bug).
        $display("[Test 7] randomized full-int8-range stress via RUN_TILE");
        urandom_seed = 32'hC0FFEE;     // fixed seed: failures reproduce
        void'($urandom(urandom_seed));
        for (int t = 0; t < 40; t++) begin
            for (int r = 0; r < ARRAY_ROWS; r++)
                for (int c = 0; c < NUM_COLS; c++)
                    W[r][c] = int'($urandom % 256) - 128;
            for (int m = 0; m < M_TILE; m++)
                for (int k = 0; k < ARRAY_ROWS; k++)
                    A[m][k] = int'($urandom % 256) - 128;
            for (int c = 0; c < NUM_COLS; c++)
                B[c] = int'($urandom % 2001) - 1000;
            send_bias("T7");
            do_run_tile_pass(1'b1, 1'b1, $sformatf("T7 rand %0d", t));
        end

        // Test 8: randomized K-tiled chains (first/last flag pairs) with
        // the same full-range values -- the accumulator's persistent PSUM
        // crossing wraparound between passes.
        $display("[Test 8] randomized full-range 2-tile K-chains via RUN_TILE");
        for (int t = 0; t < 10; t++) begin
            for (int c = 0; c < NUM_COLS; c++)
                B[c] = int'($urandom % 2001) - 1000;
            send_bias("T8");
            for (int pass = 0; pass < 2; pass++) begin
                for (int r = 0; r < ARRAY_ROWS; r++)
                    for (int c = 0; c < NUM_COLS; c++)
                        W[r][c] = int'($urandom % 256) - 128;
                for (int m = 0; m < M_TILE; m++)
                    for (int k = 0; k < ARRAY_ROWS; k++)
                        A[m][k] = int'($urandom % 256) - 128;
                do_run_tile_pass(pass == 0, pass == 1,
                                 $sformatf("T8 chain %0d tile %0d", t, pass));
            end
        end

        $display("\n=== SIMULATION COMPLETE ===");
        if (errors == 0)
            $display(">>> ALL tpu_sequencer_4x4 TESTS PASSED <<<");
        else
            $display(">>> SIMULATION FAILED WITH %0d ERRORS <<<", errors);

        $finish;
    end

endmodule
