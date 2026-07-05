`timescale 1ns / 1ps

// tpu_sequencer_tb — end-to-end sequencer test.
// Uses direct rx_data/rx_valid injection; tx_busy held low (instant accept).
// Avoids: dynamic arrays, open-array task args, `return` in tasks (iverilog limits).

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
    logic [7:0] tx_data;
    logic       tx_valid_out;
    logic       tx_busy;

    logic              seq_we_col_0, seq_we_col_1;
    logic signed [7:0] seq_wd_col_0, seq_wd_col_1;
    logic              seq_swap_banks;
    logic              seq_loading_phase;
    logic              seq_hw_addr;
    logic signed [7:0] seq_hw_data [2];
    logic              seq_hw_valid;
    logic              seq_ub_addr;
    logic              seq_ub_en;
    logic signed [15:0] seq_bias [2];
    logic signed [15:0] final_row_out [2];
    logic               final_row_valid;
    logic               seq_tpu_reset;
    logic               busy;

    // tx_busy = 0: testbench accepts every byte immediately
    assign tx_busy = 1'b0;
    assign dp_reset = reset | seq_tpu_reset;

    // datapath wires
    logic signed [7:0]  ub_read_data [2];
    logic               ub_read_valid;
    logic signed [7:0]  skewed_act [2];
    logic               skewed_valid [2];
    logic signed [7:0]  wf_col_0, wf_col_1;
    logic               wf_col_0_valid, wf_col_1_valid;
    logic signed [15:0] mmu_out_0, mmu_out_1;
    logic               mmu_out_0_valid, mmu_out_1_valid;
    logic signed [15:0] accum_in_data [2];
    logic               accum_in_valid [2];
    logic signed [15:0] acc_row_out [2];
    logic               acc_row_valid;
    logic signed [15:0] biased_row [2];
    logic               biased_valid;
    logic signed [7:0]  ub_act_dummy [2];

    assign accum_in_data[0]  = mmu_out_0;
    assign accum_in_data[1]  = mmu_out_1;
    assign accum_in_valid[0] = mmu_out_0_valid;
    assign accum_in_valid[1] = mmu_out_1_valid;
    assign ub_act_dummy[0]   = 8'sd0;
    assign ub_act_dummy[1]   = 8'sd0;

    // DUT + datapath
    tpu_sequencer #(.WAIT_TIMEOUT(200)) dut (
        .clk(clk), .reset(reset),
        .rx_data(rx_data), .rx_valid(rx_valid),
        .tx_data(tx_data), .tx_valid(tx_valid_out), .tx_busy(tx_busy),
        .write_enable_col_0(seq_we_col_0), .write_data_col_0(seq_wd_col_0),
        .write_enable_col_1(seq_we_col_1), .write_data_col_1(seq_wd_col_1),
        .swap_banks(seq_swap_banks), .loading_phase(seq_loading_phase),
        .host_write_addr(seq_hw_addr), .host_write_data(seq_hw_data),
        .host_write_valid(seq_hw_valid),
        .ub_read_addr(seq_ub_addr), .ub_read_en(seq_ub_en),
        .out_bias(seq_bias),
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
        .write_enable_col_0(seq_we_col_0),.write_data_col_0(seq_wd_col_0),
        .write_enable_col_1(seq_we_col_1),.write_data_col_1(seq_wd_col_1),
        .swap_banks(seq_swap_banks),.loading_phase(seq_loading_phase),
        .out_col_0(wf_col_0),.out_col_0_valid(wf_col_0_valid),
        .out_col_1(wf_col_1),.out_col_1_valid(wf_col_1_valid),
        .shadow_loaded(),.active_bank(),.active_empty(),.active_full(),.any_shadow_full()
    );

    systolic_data_setup #(.ARRAY_ROWS(2),.DATA_WIDTH(8)) u_sds (
        .clk(clk),.reset(dp_reset),
        .ub_read_data(ub_read_data),.ub_read_valid(ub_read_valid),
        .mmu_in_row(skewed_act),.mmu_in_valid(skewed_valid)
    );

    mmu u_mmu (
        .clk(clk),.reset(dp_reset),.loading_phase(seq_loading_phase),
        .capture_weight_col_0(wf_col_0_valid),.capture_weight_col_1(wf_col_1_valid),
        .in_col_0(wf_col_0),.in_col_0_valid(wf_col_0_valid),
        .in_col_1(wf_col_1),.in_col_1_valid(wf_col_1_valid),
        .in_row_0(skewed_act[0]),.in_row_0_valid(skewed_valid[0]),
        .in_row_1(skewed_act[1]),.in_row_1_valid(skewed_valid[1]),
        .out_partial_sum_0(mmu_out_0),.out_partial_sum_0_valid(mmu_out_0_valid),
        .out_partial_sum_1(mmu_out_1),.out_partial_sum_1_valid(mmu_out_1_valid)
    );

    accumulator #(.NUM_COLS(2),.PSUM_WIDTH(16),.FIFO_DEPTH(FIFO_DEPTH)) u_accum (
        .clk(clk),.reset(dp_reset),
        .in_partial_sum(accum_in_data),.in_partial_sum_valid(accum_in_valid),
        .out_row(acc_row_out),.out_row_valid(acc_row_valid),.any_fifo_full()
    );

    bias #(.NUM_COLS(2),.PSUM_WIDTH(16)) u_bias (
        .clk(clk),.reset(dp_reset),
        .in_row(acc_row_out),.in_row_valid(acc_row_valid),
        .in_bias(seq_bias),.out_row(biased_row),.out_row_valid(biased_valid)
    );

    activation #(.NUM_COLS(2),.PSUM_WIDTH(16)) u_act (
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

    // TX byte collect — stores into module-level rx_buf, advances rx_idx
    logic [7:0] rx_buf [10];   // big enough for longest RUN response
    integer     rx_idx;

    task automatic collect_byte(integer idx);
        integer timeout;
        timeout = 0;
        while (!tx_valid_out) begin
            @(posedge clk);
            timeout = timeout + 1;
            if (timeout > 2000) begin
                $error("[FATAL] Timeout waiting for tx_valid (byte %0d)", idx);
                errors = errors + 1;
                disable collect_byte;
            end
        end
        rx_buf[idx] = tx_data;
        @(posedge clk); #1;
    endtask

    task automatic collect_n(integer n);
        integer i;
        for (i = 0; i < n; i = i + 1)
            collect_byte(i);
    endtask

    // Sends LOAD_WEIGHTS, LOAD_BIAS, LOAD_ACT, RUN, then checks 10-byte response
    task automatic do_compute(
        input logic signed [7:0] w00, w01, w10, w11,
        input logic signed [15:0] b0, b1,
        input logic signed [7:0] a00, a01, a10, a11,
        input logic signed [15:0] er0c0, er0c1, er1c0, er1c1,
        input string label
    );
        logic signed [15:0] gr0c0, gr0c1, gr1c0, gr1c1;

        // LOAD_WEIGHTS: CMD=01, LEN=4, [w10,w11,w00,w01]
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

        // LOAD_ACT: CMD=03, LEN=4, [a00,a01,a10,a11]
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

    initial begin
        clk      = 0;
        reset    = 1;
        rx_data  = '0;
        rx_valid = 1'b0;

        repeat (4) @(posedge clk); #1;
        reset = 0;
        @(posedge clk); #1;

        $display("\n=== Starting tpu_sequencer Testbench ===\n");

        // Test 1: happy path
        // W=[[4,5],[2,3]], A=[[1,2],[3,4]], bias=[100,200]
        // A@W = [[8,11],[20,27]] + bias = [[108,211],[120,227]], ReLU same
        $display("[Test 1] Happy path: A@W + bias + ReLU");
        do_compute(4,5,2,3, 16'sd100,16'sd200, 1,2,3,4, 16'sd108,16'sd211,16'sd120,16'sd227, "T1");

        // Test 2: zero weights, negative bias → all ReLU clamped to 0
        $display("[Test 2] Zero weights + neg bias → all zeros");
        do_compute(0,0,0,0, -16'sd10,-16'sd20, 0,0,0,0, 16'sd0,16'sd0,16'sd0,16'sd0, "T2");

        // Test 3: RESET command
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

        // Post-reset compute should still work
        $display("[Test 3b] Post-reset compute");
        do_compute(4,5,2,3, 16'sd100,16'sd200, 1,2,3,4, 16'sd108,16'sd211,16'sd120,16'sd227, "T3b");

        // Test 4: unknown CMD → STATUS_ERR
        $display("[Test 4] Unknown CMD 0xFF → STATUS_ERR");
        host_send_byte(8'hFF);
        host_send_byte(8'h00);
        collect_n(2);
        if (rx_buf[0] !== 8'hFF) begin
            $error("[FAIL] T4: expected STATUS_ERR=0xFF, got 0x%02X", rx_buf[0]);
            errors++;
        end else begin
            $display("[PASS] T4: STATUS_ERR received");
        end
        repeat (10) @(posedge clk);

        // Test 5: negative arithmetic + ReLU
        // W=[[-1,-2],[-3,-4]], A=[[-1,1],[2,-2]], bias=[0,0]
        // row0: (-1)(-1)+(1)(-3)=-2+( -3)? Wait:
        // A@W: A=acts, W=weights. MMU computes A*W.
        // row0=[a00,a01]=[-1,1], W col0=[w00,w10]=[-1,-3], W col1=[w01,w11]=[-2,-4]
        // result[0][0] = -1*-1 + 1*-3 = 1-3 = -2 → ReLU → 0
        // result[0][1] = -1*-2 + 1*-4 = 2-4 = -2 → ReLU → 0
        // row1=[a10,a11]=[2,-2]
        // result[1][0] = 2*-1 + (-2)*-3 = -2+6 = 4 → ReLU → 4
        // result[1][1] = 2*-2 + (-2)*-4 = -4+8 = 4 → ReLU → 4
        $display("[Test 5] Negative arithmetic + ReLU clamp");
        do_compute(-1,-2,-3,-4, 16'sd0,16'sd0, -1,1,2,-2, 16'sd0,16'sd0,16'sd4,16'sd4, "T5");

        // Test 6: identity matrix
        // W=[[1,0],[0,1]], A=[[10,20],[30,40]], bias=[0,0]
        // → [[10,20],[30,40]]
        $display("[Test 6] Identity weight matrix");
        do_compute(1,0,0,1, 16'sd0,16'sd0, 10,20,30,40, 16'sd10,16'sd20,16'sd30,16'sd40, "T6");

        $display("\n=== SIMULATION COMPLETE ===");
        if (errors == 0)
            $display(">>> ALL tpu_sequencer TESTS PASSED <<<");
        else
            $display(">>> SIMULATION FAILED WITH %0d ERRORS <<<", errors);

        $finish;
    end

endmodule
