`timescale 1ns / 1ps

// end-to-end sequencer test via direct rx_data/rx_valid injection, tx_busy held low
// avoids dynamic arrays, open-array task args and `return` in tasks (iverilog limits)
module tpu_sequencer_tb;

    localparam int WEIGHT_WIDTH = 8;
    localparam int FIFO_DEPTH   = 4;

    logic clk = 0;
    logic reset;
    logic dp_reset;
    int   errors = 0;

    // sequencer ports
    logic [7:0] rx_data;
    logic       rx_valid;
    logic       rx_error_in;   // tb-driven framing-error injection
    logic [7:0] tx_data;
    logic       tx_valid_out;
    logic       tx_busy;

    logic              [1:0] seq_we_col;
    logic signed [1:0][7:0]  seq_wd_col;
    logic              seq_swap_banks;
    logic              seq_loading_phase;
    logic              seq_hw_addr;
    logic signed [1:0][7:0] seq_hw_data;
    logic              seq_hw_valid;
    logic              seq_ub_addr;
    logic              seq_ub_en;
    logic signed [1:0][15:0] seq_bias;
    logic               seq_tile_first, seq_tile_last;
    logic               seq_act_bypass;
    logic               accum_pass_done;
    logic signed [1:0][15:0] final_row_out;
    logic               final_row_valid;
    logic               seq_tpu_reset;
    logic               busy;

    // tx_busy = 0: testbench accepts every byte immediately
    assign tx_busy = 1'b0;
    assign dp_reset = reset | seq_tpu_reset;

    // datapath wires
    logic signed [1:0][7:0]  ub_read_data;
    logic               ub_read_valid;
    logic signed [1:0][7:0]  skewed_act;
    logic               [1:0] skewed_valid;
    logic signed [1:0][7:0] wf_col;
    logic               [1:0] wf_col_valid;
    logic signed [1:0][15:0] accum_in_data;
    logic               [1:0] accum_in_valid;
    logic signed [1:0][15:0] acc_row_out;
    logic               acc_row_valid;
    logic signed [1:0][15:0] biased_row;
    logic               biased_valid;
    logic signed [1:0][7:0]  ub_act_dummy;

    assign ub_act_dummy[0]   = 8'sd0;
    assign ub_act_dummy[1]   = 8'sd0;

    // DUT + datapath (2x2 defaults: ARRAY_ROWS=NUM_COLS=M_TILE=2)
    tpu_sequencer #(.WAIT_TIMEOUT(200)) dut (
        .clk(clk), .reset(reset),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_error(rx_error_in),
        .tx_data(tx_data), .tx_valid(tx_valid_out), .tx_busy(tx_busy),
        .write_enable_col(seq_we_col), .write_data_col(seq_wd_col),
        .swap_banks(seq_swap_banks), .loading_phase(seq_loading_phase),
        .host_write_addr(seq_hw_addr), .host_write_data(seq_hw_data),
        .host_write_valid(seq_hw_valid),
        .ub_read_addr(seq_ub_addr), .ub_read_en(seq_ub_en),
        .out_bias(seq_bias),
        .tile_first(seq_tile_first), .tile_last(seq_tile_last), .act_bypass(seq_act_bypass),
        .accum_pass_done(accum_pass_done),
        .final_row_out(final_row_out), .final_row_valid(final_row_valid),
        .tpu_reset(seq_tpu_reset), .busy(busy)
    );

    unified_buffer #(.ROWS(2),.COLS(2),.DATA_WIDTH(8)) u_ub (
        .clk(clk),.reset(dp_reset),
        .host_write_addr(seq_hw_addr),.host_write_data(seq_hw_data),
        .host_write_valid(seq_hw_valid),
        .host_read_addr(1'b0),.host_read_data(),.host_read_en(1'b0),.host_read_valid(),
        .ub_read_addr(seq_ub_addr),.ub_read_en(seq_ub_en),
        .ub_read_data(ub_read_data),.ub_read_valid(ub_read_valid),
        .act_write_data(ub_act_dummy),.act_write_valid(1'b0),
        .act_write_addr_reset(1'b0),.bank_swap(1'b0)
    );

    weight_fifo #(.WEIGHT_WIDTH(WEIGHT_WIDTH),.FIFO_DEPTH(FIFO_DEPTH)) u_wf (
        .clk(clk),.reset(dp_reset),
        .write_enable_col(seq_we_col),.write_data_col(seq_wd_col),
        .swap_banks(seq_swap_banks),.loading_phase(seq_loading_phase),
        .out_col(wf_col),.out_col_valid(wf_col_valid),
        .shadow_loaded(),.active_bank(),.active_empty(),.active_full(),.any_shadow_full()
    );

    systolic_data_setup #(.ARRAY_ROWS(2),.DATA_WIDTH(8)) u_sds (
        .clk(clk),.reset(dp_reset),
        .ub_read_data(ub_read_data),.ub_read_valid(ub_read_valid),
        .mmu_in_row(skewed_act),.mmu_in_valid(skewed_valid)
    );

    mmu #(.ARRAY_ROWS(2), .NUM_COLS(2)) u_mmu (
        .clk(clk),.reset(dp_reset),.loading_phase(seq_loading_phase),
        .capture_weight_col(wf_col_valid),
        .in_col(wf_col),.in_col_valid(wf_col_valid),
        .in_row(skewed_act),.in_row_valid(skewed_valid),
        .out_partial_sum(accum_in_data),.out_partial_sum_valid(accum_in_valid)
    );

    accumulator #(.NUM_COLS(2),.PSUM_WIDTH(16),.FIFO_DEPTH(FIFO_DEPTH)) u_accum (
        .clk(clk),.reset(dp_reset),
        .in_partial_sum(accum_in_data),.in_partial_sum_valid(accum_in_valid),
        .tile_first(seq_tile_first),.tile_last(seq_tile_last),
        .out_row(acc_row_out),.out_row_valid(acc_row_valid),
        .pass_done(accum_pass_done),.any_fifo_full()
    );

    bias #(.NUM_COLS(2),.PSUM_WIDTH(16)) u_bias (
        .clk(clk),.reset(dp_reset),
        .in_row(acc_row_out),.in_row_valid(acc_row_valid),
        .in_bias(seq_bias),.out_row(biased_row),.out_row_valid(biased_valid)
    );

    activation #(.NUM_COLS(2),.PSUM_WIDTH(16)) u_act (
        .bypass(seq_act_bypass),
        .clk(clk),.reset(dp_reset),
        .in_row(biased_row),.in_row_valid(biased_valid),
        .out_row(final_row_out),.out_row_valid(final_row_valid)
    );

    always #5 clk = ~clk;

    // RX byte inject
    task automatic host_send_byte(input logic [7:0] b);
        @(posedge clk); #1;
        rx_data  = b;
        rx_valid = 1'b1;
        @(posedge clk); #1;
        rx_valid = 1'b0;
    endtask

    // pace STREAM_RUN bytes at 60 cycles: the sequencer ignores RX for a pass between tiles
    task automatic sr_send_byte(input logic [7:0] b);
        host_send_byte(b);
        repeat (60) @(posedge clk);
    endtask

    // one STREAM_RUN tile: weights in natural row-major order, then acts
    task automatic sr_send_tile(
        input logic signed [7:0] w00, w01, w10, w11,
        input logic signed [7:0] a00, a01, a10, a11
    );
        sr_send_byte(8'(w00)); sr_send_byte(8'(w01));
        sr_send_byte(8'(w10)); sr_send_byte(8'(w11));
        sr_send_byte(8'(a00)); sr_send_byte(8'(a01));
        sr_send_byte(8'(a10)); sr_send_byte(8'(a11));
    endtask

    // simulate a UART framing error: uart_rx latches rx_error (no rx_valid
    // for the corrupted byte) and clears it on the next good byte.
    task automatic inject_framing_error;
        @(posedge clk); #1;
        rx_error_in = 1'b1;
        repeat (2) @(posedge clk); #1;
        rx_error_in = 1'b0;
    endtask

    // capture TX bytes concurrently: a response can start while a STREAM_RUN frame is still going out
    logic [7:0] rx_buf [10];   // big enough for longest RUN response
    integer     cap_idx = 0;

    always @(posedge clk) begin
        if (tx_valid_out && cap_idx < 10) begin
            rx_buf[cap_idx] = tx_data;
            cap_idx = cap_idx + 1;
        end
    end

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

    // sends LOAD_WEIGHTS, LOAD_BIAS, LOAD_ACT, RUN, then checks 10-byte response
    task automatic do_compute(
        input logic signed [7:0] w00, w01, w10, w11,
        input logic signed [15:0] b0, b1,
        input logic signed [7:0] a00, a01, a10, a11,
        input logic signed [15:0] er0c0, er0c1, er1c0, er1c1,
        input string label
    );
        logic signed [15:0] gr0c0, gr0c1, gr1c0, gr1c1;

        // load_weights: cmd=01, len=4, [w10,w11,w00,w01]
        host_send_byte(8'h01);
        host_send_byte(8'h04);
        host_send_byte(8'(w10));
        host_send_byte(8'(w11));
        host_send_byte(8'(w00));
        host_send_byte(8'(w01));
        collect_n(2);   // ACK: [AA, 00]
        if (rx_buf[0] !== 8'hAA || rx_buf[1] !== 8'h00) begin
            $error("[FAIL] %s WEIGHTS ACK: got [%02X,%02X]", label, rx_buf[0], rx_buf[1]);
            errors++;
        end

        // LOAD_BIAS: CMD=02, LEN=4, [b0_lo,b0_hi,b1_lo,b1_hi]
        host_send_byte(8'h02);
        host_send_byte(8'h04);
        host_send_byte(b0[7:0]);
        host_send_byte(b0[15:8]);
        host_send_byte(b1[7:0]);
        host_send_byte(b1[15:8]);
        collect_n(2);
        if (rx_buf[0] !== 8'hAA || rx_buf[1] !== 8'h00) begin
            $error("[FAIL] %s BIAS ACK: got [%02X,%02X]", label, rx_buf[0], rx_buf[1]);
            errors++;
        end

        // load_act: cmd=03, len=4, [a00,a01,a10,a11]
        host_send_byte(8'h03);
        host_send_byte(8'h04);
        host_send_byte(8'(a00));
        host_send_byte(8'(a01));
        host_send_byte(8'(a10));
        host_send_byte(8'(a11));
        collect_n(2);
        if (rx_buf[0] !== 8'hAA || rx_buf[1] !== 8'h00) begin
            $error("[FAIL] %s ACT ACK: got [%02X,%02X]", label, rx_buf[0], rx_buf[1]);
            errors++;
        end

        // RUN: CMD=04, LEN=0
        host_send_byte(8'h04);
        host_send_byte(8'h00);
        collect_n(10);   // [STATUS, LEN=8, r0c0_lo,hi, r0c1_lo,hi, r1c0_lo,hi, r1c1_lo,hi]

        gr0c0 = signed'({rx_buf[3], rx_buf[2]});
        gr0c1 = signed'({rx_buf[5], rx_buf[4]});
        gr1c0 = signed'({rx_buf[7], rx_buf[6]});
        gr1c1 = signed'({rx_buf[9], rx_buf[8]});

        if (rx_buf[0] !== 8'hAA || rx_buf[1] !== 8'h08) begin
            $error("[FAIL] %s RUN header: [%02X,%02X]", label, rx_buf[0], rx_buf[1]);
            errors++;
        end else if (gr0c0 !== er0c0 || gr0c1 !== er0c1 ||
                     gr1c0 !== er1c0 || gr1c1 !== er1c1) begin
            $error("[FAIL] %s RUN: exp [%0d,%0d / %0d,%0d] got [%0d,%0d / %0d,%0d]",
                   label, er0c0, er0c1, er1c0, er1c1,
                   gr0c0, gr0c1, gr1c0, gr1c1);
            errors++;
        end else begin
            $display("[PASS] %s: row0=[%0d,%0d] row1=[%0d,%0d]",
                     label, gr0c0, gr0c1, gr1c0, gr1c1);
        end

        repeat (20) @(posedge clk);
    endtask

    // RUN with a flags byte; last=0 expects a bare ACK
    task automatic do_tiled_run(
        input logic signed [7:0] w00, w01, w10, w11,
        input logic signed [7:0] a00, a01, a10, a11,
        input logic first, input logic last,
        input logic signed [15:0] er0c0, er0c1, er1c0, er1c1,
        input string label
    );
        logic [7:0] flags;
        logic signed [15:0] gr0c0, gr0c1, gr1c0, gr1c1;

        // load_weights: cmd=01, len=4, [w10,w11,w00,w01]
        host_send_byte(8'h01);
        host_send_byte(8'h04);
        host_send_byte(8'(w10));
        host_send_byte(8'(w11));
        host_send_byte(8'(w00));
        host_send_byte(8'(w01));
        collect_n(2);
        if (rx_buf[0] !== 8'hAA || rx_buf[1] !== 8'h00) begin
            $error("[FAIL] %s WEIGHTS ACK: got [%02X,%02X]", label, rx_buf[0], rx_buf[1]);
            errors++;
        end

        // load_act: cmd=03, len=4, [a00,a01,a10,a11]
        host_send_byte(8'h03);
        host_send_byte(8'h04);
        host_send_byte(8'(a00));
        host_send_byte(8'(a01));
        host_send_byte(8'(a10));
        host_send_byte(8'(a11));
        collect_n(2);
        if (rx_buf[0] !== 8'hAA || rx_buf[1] !== 8'h00) begin
            $error("[FAIL] %s ACT ACK: got [%02X,%02X]", label, rx_buf[0], rx_buf[1]);
            errors++;
        end

        // RUN: CMD=04, LEN=1, [flags]
        flags = {6'b0, last, first};
        host_send_byte(8'h04);
        host_send_byte(8'h01);
        host_send_byte(flags);

        if (last) begin
            collect_n(10);
            gr0c0 = signed'({rx_buf[3], rx_buf[2]});
            gr0c1 = signed'({rx_buf[5], rx_buf[4]});
            gr1c0 = signed'({rx_buf[7], rx_buf[6]});
            gr1c1 = signed'({rx_buf[9], rx_buf[8]});
            if (rx_buf[0] !== 8'hAA || rx_buf[1] !== 8'h08) begin
                $error("[FAIL] %s RUN header: [%02X,%02X]", label, rx_buf[0], rx_buf[1]);
                errors++;
            end else if (gr0c0 !== er0c0 || gr0c1 !== er0c1 ||
                         gr1c0 !== er1c0 || gr1c1 !== er1c1) begin
                $error("[FAIL] %s RUN: exp [%0d,%0d / %0d,%0d] got [%0d,%0d / %0d,%0d]",
                       label, er0c0, er0c1, er1c0, er1c1,
                       gr0c0, gr0c1, gr1c0, gr1c1);
                errors++;
            end else begin
                $display("[PASS] %s: row0=[%0d,%0d] row1=[%0d,%0d]",
                         label, gr0c0, gr0c1, gr1c0, gr1c1);
            end
        end else begin
            collect_n(2);
            if (rx_buf[0] !== 8'hAA || rx_buf[1] !== 8'h00) begin
                $error("[FAIL] %s tile ACK: got [%02X,%02X]", label, rx_buf[0], rx_buf[1]);
                errors++;
            end else begin
                $display("[PASS] %s: tile ACK received (no data yet)", label);
            end
        end

        repeat (20) @(posedge clk);
    endtask

    // RUN_TILE: weights in natural row-major order; last=0 expects a bare ACK
    task automatic do_run_tile(
        input logic signed [7:0] w00, w01, w10, w11,
        input logic signed [7:0] a00, a01, a10, a11,
        input logic first, input logic last,
        input logic signed [15:0] er0c0, er0c1, er1c0, er1c1,
        input string label
    );
        logic signed [15:0] gr0c0, gr0c1, gr1c0, gr1c1;

        // RUN_TILE: CMD=06, LEN=9, [flags, w00,w01,w10,w11, a00,a01,a10,a11]
        host_send_byte(8'h06);
        host_send_byte(8'h09);
        host_send_byte({6'b0, last, first});
        host_send_byte(8'(w00));
        host_send_byte(8'(w01));
        host_send_byte(8'(w10));
        host_send_byte(8'(w11));
        host_send_byte(8'(a00));
        host_send_byte(8'(a01));
        host_send_byte(8'(a10));
        host_send_byte(8'(a11));

        if (last) begin
            collect_n(10);
            gr0c0 = signed'({rx_buf[3], rx_buf[2]});
            gr0c1 = signed'({rx_buf[5], rx_buf[4]});
            gr1c0 = signed'({rx_buf[7], rx_buf[6]});
            gr1c1 = signed'({rx_buf[9], rx_buf[8]});
            if (rx_buf[0] !== 8'hAA || rx_buf[1] !== 8'h08) begin
                $error("[FAIL] %s RUN_TILE header: [%02X,%02X]", label, rx_buf[0], rx_buf[1]);
                errors++;
            end else if (gr0c0 !== er0c0 || gr0c1 !== er0c1 ||
                         gr1c0 !== er1c0 || gr1c1 !== er1c1) begin
                $error("[FAIL] %s RUN_TILE: exp [%0d,%0d / %0d,%0d] got [%0d,%0d / %0d,%0d]",
                       label, er0c0, er0c1, er1c0, er1c1,
                       gr0c0, gr0c1, gr1c0, gr1c1);
                errors++;
            end else begin
                $display("[PASS] %s: row0=[%0d,%0d] row1=[%0d,%0d]",
                         label, gr0c0, gr0c1, gr1c0, gr1c1);
            end
        end else begin
            collect_n(2);
            if (rx_buf[0] !== 8'hAA || rx_buf[1] !== 8'h00) begin
                $error("[FAIL] %s tile ACK: got [%02X,%02X]", label, rx_buf[0], rx_buf[1]);
                errors++;
            end else begin
                $display("[PASS] %s: tile ACK received (no data yet)", label);
            end
        end

        repeat (20) @(posedge clk);
    endtask

    initial begin
        clk         = 0;
        reset       = 1;
        rx_data     = '0;
        rx_valid    = 1'b0;
        rx_error_in = 1'b0;

        repeat (4) @(posedge clk); #1;
        reset = 0;
        @(posedge clk); #1;

        $display("\n=== Starting tpu_sequencer Testbench ===\n");

        // test 1: W=[[4,5],[2,3]], A=[[1,2],[3,4]], bias=[100,200] -> [[108,211],[120,227]]
        $display("[Test 1] Happy path: A@W + bias + ReLU");
        do_compute(4,5,2,3, 16'sd100,16'sd200, 1,2,3,4, 16'sd108,16'sd211,16'sd120,16'sd227, "T1");

        // test 2: zero weights, negative bias → all ReLU clamped to 0
        $display("[Test 2] Zero weights + neg bias → all zeros");
        do_compute(0,0,0,0, -16'sd10,-16'sd20, 0,0,0,0, 16'sd0,16'sd0,16'sd0,16'sd0, "T2");

        // test 3: RESET command
        $display("[Test 3] RESET command");
        host_send_byte(8'h05);
        host_send_byte(8'h00);
        collect_n(2);
        if (rx_buf[0] !== 8'hAA || rx_buf[1] !== 8'h00) begin
            $error("[FAIL] T3 RESET ACK: got [%02X,%02X]", rx_buf[0], rx_buf[1]);
            errors++;
        end else begin
            $display("[PASS] T3 RESET: ACK received");
        end
        repeat (10) @(posedge clk);

        // post-reset compute should still work
        $display("[Test 3b] Post-reset compute");
        do_compute(4,5,2,3, 16'sd100,16'sd200, 1,2,3,4, 16'sd108,16'sd211,16'sd120,16'sd227, "T3b");

        // test 4: unknown CMD → STATUS_ERR. 0xEE, not 0xFF: 0xFF is CMD_NOP,
        // the SPI read-poll filler, silently ignored in S_IDLE (see below).
        $display("[Test 4] Unknown CMD 0xEE → STATUS_ERR");
        host_send_byte(8'hEE);
        host_send_byte(8'h00);
        collect_n(2);
        if (rx_buf[0] !== 8'hFF) begin
            $error("[FAIL] T4: expected STATUS_ERR=0xFF, got 0x%02X", rx_buf[0]);
            errors++;
        end else begin
            $display("[PASS] T4: STATUS_ERR received");
        end
        repeat (10) @(posedge clk);

        // test 4b: NOP is ignored and the next command still parses
        $display("[Test 4b] CMD_NOP 0xFF ignored in S_IDLE");
        host_send_byte(8'hFF);
        host_send_byte(8'hFF);
        host_send_byte(8'hFF);
        repeat (200) @(posedge clk);
        if (cap_idx != 0) begin
            $error("[FAIL] T4b: NOP produced %0d response byte(s), expected none", cap_idx);
            errors++;
            cap_idx = 0;
        end else begin
            $display("[PASS] T4b: NOP filler ignored");
        end
        do_compute(4,5,2,3, 16'sd100,16'sd200, 1,2,3,4, 16'sd108,16'sd211,16'sd120,16'sd227, "T4b post-NOP");

        // test 5: negative arithmetic, A@W = [[-2,-2],[4,4]] -> [[0,0],[4,4]]
        $display("[Test 5] Negative arithmetic + ReLU clamp");
        do_compute(-1,-2,-3,-4, 16'sd0,16'sd0, -1,1,2,-2, 16'sd0,16'sd0,16'sd4,16'sd4, "T5");

        // test 6: identity
        $display("[Test 6] Identity weight matrix");
        do_compute(1,0,0,1, 16'sd0,16'sd0, 10,20,30,40, 16'sd10,16'sd20,16'sd30,16'sd40, "T6");

        // test 7: K-tiling over the wire, two 2x2 K-tiles -> [[7,10],[19,22]];
        // pass 1 returns a bare ACK
        $display("[Test 7] K-dim tiling over the wire (LEN=1 RUN flags)");
        host_send_byte(8'h02);   // LOAD_BIAS = [0,0]
        host_send_byte(8'h04);
        host_send_byte(8'h00); host_send_byte(8'h00);
        host_send_byte(8'h00); host_send_byte(8'h00);
        collect_n(2);
        if (rx_buf[0] !== 8'hAA || rx_buf[1] !== 8'h00) begin
            $error("[FAIL] T7 BIAS ACK: got [%02X,%02X]", rx_buf[0], rx_buf[1]);
            errors++;
        end

        do_tiled_run(1,0,0,1, 1,2,5,6, 1'b1, 1'b0,
                     16'sd0,16'sd0,16'sd0,16'sd0, "T7 K-tile0");
        do_tiled_run(2,0,0,2, 3,4,7,8, 1'b0, 1'b1,
                     16'sd7,16'sd10,16'sd19,16'sd22, "T7 K-tile1");

        // test 8: RUN_TILE single-shot, bias [100,200] preloaded
        $display("[Test 8] RUN_TILE single frame (doc §3.1 worked example)");
        host_send_byte(8'h02);   // LOAD_BIAS = [100,200]
        host_send_byte(8'h04);
        host_send_byte(8'h64); host_send_byte(8'h00);
        host_send_byte(8'hC8); host_send_byte(8'h00);
        collect_n(2);
        if (rx_buf[0] !== 8'hAA || rx_buf[1] !== 8'h00) begin
            $error("[FAIL] T8 BIAS ACK: got [%02X,%02X]", rx_buf[0], rx_buf[1]);
            errors++;
        end
        do_run_tile(4,5,2,3, 1,2,3,4, 1'b1, 1'b1,
                    16'sd108,16'sd211,16'sd120,16'sd227, "T8 RUN_TILE");

        // test 9: K-dim tiling via RUN_TILE — same math as test 7, but one
        // frame per K-tile instead of three, and natural-order weights.
        $display("[Test 9] K-dim tiling via RUN_TILE frames");
        host_send_byte(8'h02);   // LOAD_BIAS = [0,0]
        host_send_byte(8'h04);
        host_send_byte(8'h00); host_send_byte(8'h00);
        host_send_byte(8'h00); host_send_byte(8'h00);
        collect_n(2);
        if (rx_buf[0] !== 8'hAA || rx_buf[1] !== 8'h00) begin
            $error("[FAIL] T9 BIAS ACK: got [%02X,%02X]", rx_buf[0], rx_buf[1]);
            errors++;
        end
        do_run_tile(1,0,0,1, 1,2,5,6, 1'b1, 1'b0,
                    16'sd0,16'sd0,16'sd0,16'sd0, "T9 K-tile0");
        do_run_tile(2,0,0,2, 3,4,7,8, 1'b0, 1'b1,
                    16'sd7,16'sd10,16'sd19,16'sd22, "T9 K-tile1");

        // test 10: framing error mid-frame → explicit STATUS_ERR (not a
        // silent drop), and the sequencer recovers for the next command.
        $display("[Test 10] UART framing error mid-frame -> STATUS_ERR + recovery");
        host_send_byte(8'h01);   // CMD_LOAD_WEIGHTS
        host_send_byte(8'h04);   // LEN=4
        host_send_byte(8'h11);   // 1 of 4 payload bytes...
        inject_framing_error;    // ...then byte 2 arrives corrupted
        collect_n(2);
        if (rx_buf[0] !== 8'hFF || rx_buf[1] !== 8'h00) begin
            $error("[FAIL] T10: expected [FF,00], got [%02X,%02X]", rx_buf[0], rx_buf[1]);
            errors++;
        end else begin
            $display("[PASS] T10: STATUS_ERR on framing error");
        end
        repeat (10) @(posedge clk);

        $display("[Test 10b] Post-framing-error compute");
        do_compute(4,5,2,3, 16'sd100,16'sd200, 1,2,3,4, 16'sd108,16'sd211,16'sd120,16'sd227, "T10b");

        // test 11: two identity tiles in one STREAM_RUN frame -> [[6,8],[10,12]]
        $display("[Test 11] STREAM_RUN: 2 tiles, one frame, one response");
        host_send_byte(8'h02);   // LOAD_BIAS = [0,0]
        host_send_byte(8'h04);
        host_send_byte(8'h00); host_send_byte(8'h00);
        host_send_byte(8'h00); host_send_byte(8'h00);
        collect_n(2);
        if (rx_buf[0] !== 8'hAA || rx_buf[1] !== 8'h00) begin
            $error("[FAIL] T11 BIAS ACK: got [%02X,%02X]", rx_buf[0], rx_buf[1]);
            errors++;
        end
        host_send_byte(8'h07);   // CMD_STREAM_RUN
        host_send_byte(8'h12);   // LEN = 2 + 2*8 = 18
        sr_send_byte(8'h03);     // flags = TILE_FIRST|TILE_LAST
        sr_send_byte(8'h02);     // K_TILES = 2
        sr_send_tile(1,0,0,1, 1,2,3,4);
        sr_send_tile(1,0,0,1, 5,6,7,8);
        collect_n(10);
        if (rx_buf[0] !== 8'hAA || rx_buf[1] !== 8'h08 ||
            signed'({rx_buf[3],rx_buf[2]}) !== 16'sd6  ||
            signed'({rx_buf[5],rx_buf[4]}) !== 16'sd8  ||
            signed'({rx_buf[7],rx_buf[6]}) !== 16'sd10 ||
            signed'({rx_buf[9],rx_buf[8]}) !== 16'sd12) begin
            $error("[FAIL] T11 STREAM_RUN: got [%02X,%02X] rows [%0d,%0d / %0d,%0d]",
                   rx_buf[0], rx_buf[1],
                   signed'({rx_buf[3],rx_buf[2]}), signed'({rx_buf[5],rx_buf[4]}),
                   signed'({rx_buf[7],rx_buf[6]}), signed'({rx_buf[9],rx_buf[8]}));
            errors++;
        end else begin
            $display("[PASS] T11: row0=[6,8] row1=[10,12] from one 2-tile frame");
        end
        repeat (20) @(posedge clk);

        // test 12: a K-run across two STREAM_RUN frames, same math as test 7
        $display("[Test 12] STREAM_RUN K-run across two frames (flags chunking)");
        host_send_byte(8'h07);
        host_send_byte(8'h0A);   // LEN = 2 + 1*8 = 10
        sr_send_byte(8'h01);     // flags = TILE_FIRST only
        sr_send_byte(8'h01);     // K_TILES = 1
        sr_send_tile(1,0,0,1, 1,2,5,6);
        collect_n(2);
        if (rx_buf[0] !== 8'hAA || rx_buf[1] !== 8'h00) begin
            $error("[FAIL] T12 frame0 ACK: got [%02X,%02X]", rx_buf[0], rx_buf[1]);
            errors++;
        end
        host_send_byte(8'h07);
        host_send_byte(8'h0A);
        sr_send_byte(8'h02);     // flags = TILE_LAST only
        sr_send_byte(8'h01);
        sr_send_tile(2,0,0,2, 3,4,7,8);
        collect_n(10);
        if (rx_buf[0] !== 8'hAA || rx_buf[1] !== 8'h08 ||
            signed'({rx_buf[3],rx_buf[2]}) !== 16'sd7  ||
            signed'({rx_buf[5],rx_buf[4]}) !== 16'sd10 ||
            signed'({rx_buf[7],rx_buf[6]}) !== 16'sd19 ||
            signed'({rx_buf[9],rx_buf[8]}) !== 16'sd22) begin
            $error("[FAIL] T12 frame1: got [%02X,%02X] rows [%0d,%0d / %0d,%0d]",
                   rx_buf[0], rx_buf[1],
                   signed'({rx_buf[3],rx_buf[2]}), signed'({rx_buf[5],rx_buf[4]}),
                   signed'({rx_buf[7],rx_buf[6]}), signed'({rx_buf[9],rx_buf[8]}));
            errors++;
        end else begin
            $display("[PASS] T12: row0=[7,10] row1=[19,22] across two frames");
        end
        repeat (20) @(posedge clk);

        // test 13: malformed STREAM_RUN headers answer STATUS_ERR up front
        $display("[Test 13] STREAM_RUN header validation");
        host_send_byte(8'h07);
        host_send_byte(8'h0A);   // LEN says 1 tile...
        sr_send_byte(8'h03);
        sr_send_byte(8'h00);     // ...but K_TILES = 0
        collect_n(2);
        if (rx_buf[0] !== 8'hFF) begin
            $error("[FAIL] T13a K_TILES=0: expected STATUS_ERR, got 0x%02X", rx_buf[0]);
            errors++;
        end else $display("[PASS] T13a: K_TILES=0 rejected");
        repeat (10) @(posedge clk);
        host_send_byte(8'h07);
        host_send_byte(8'h0B);   // LEN = 11 != 2 + 1*8
        sr_send_byte(8'h03);
        sr_send_byte(8'h01);
        collect_n(2);
        if (rx_buf[0] !== 8'hFF) begin
            $error("[FAIL] T13b LEN mismatch: expected STATUS_ERR, got 0x%02X", rx_buf[0]);
            errors++;
        end else $display("[PASS] T13b: LEN/K_TILES mismatch rejected");
        // the 9 unsent frame bytes were never transmitted, so the sequencer
        // is back in S_IDLE — a normal compute must still work.
        repeat (10) @(posedge clk);
        $display("[Test 13c] Post-reject compute");
        do_compute(4,5,2,3, 16'sd100,16'sd200, 1,2,3,4, 16'sd108,16'sd211,16'sd120,16'sd227, "T13c");

        $display("\n=== SIMULATION COMPLETE ===");
        if (errors == 0)
            $display(">>> ALL tpu_sequencer TESTS PASSED <<<");
        else
            $display(">>> SIMULATION FAILED WITH %0d ERRORS <<<", errors);

        $finish;
    end

endmodule
