`timescale 1ns / 1ps

// tpu_top — FPGA top-level.
//
// Wires together:
//   uart_rx          (raw pin → byte stream)
//   uart_tx          (byte stream → raw pin)
//   tpu_sequencer    (command decoder + pipeline orchestrator)
//   unified_buffer   (activation scratchpad)
//   weight_fifo      (double-buffered weight FIFO)
//   systolic_data_setup (skew / stagger activations)
//   mmu              (2×2 systolic array)
//   accumulator      (column-FIFO row reassembler)
//   bias             (per-column stationary bias add)
//   activation       (ReLU)
//
// Parameters mirror the testbench defaults so sim and hardware match.
//
// Pin mapping for DE1-SoC (Cyclone V):
//   clk_50mhz → PIN_AF14 (CLOCK_50 on DE1-SoC)
//   rx_pin    → GPIO header or UART-to-USB bridge RX
//   tx_pin    → GPIO header or UART-to-USB bridge TX
//   reset_n   → KEY[0] (active-low push-button)

module tpu_top #(
    parameter int CLK_FREQ    = 50_000_000,
    parameter int BAUD_RATE   = 115_200,
    parameter int WEIGHT_WIDTH = 8,
    parameter int FIFO_DEPTH   = 4
) (
    input  logic clk,
    input  logic reset_n,   // active-low (DE1-SoC KEY[0])

    input  logic rx_pin,    // UART RX from host
    output logic tx_pin     // UART TX to host
);

    // =========================================================================
    // Synchronous active-high reset
    // =========================================================================
    logic rst;
    assign rst = ~reset_n;

    // =========================================================================
    // UART byte streams
    // =========================================================================
    logic [7:0] rx_byte;
    logic        rx_valid;
    logic        rx_error;

    logic [7:0] tx_byte;
    logic        tx_valid_seq;
    logic        tx_busy;

    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) u_rx (
        .clk       (clk),
        .reset     (rst),
        .rx_serial (rx_pin),
        .rx_data   (rx_byte),
        .rx_valid  (rx_valid),
        .rx_error  (rx_error)
    );

    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) u_tx (
        .clk       (clk),
        .reset     (rst),
        .tx_data   (tx_byte),
        .tx_valid  (tx_valid_seq),
        .tx_busy   (tx_busy),
        .tx_serial (tx_pin)
    );

    // =========================================================================
    // Sequencer control signals
    // =========================================================================
    // weight_fifo
    logic              seq_we_col_0, seq_we_col_1;
    logic signed [7:0] seq_wd_col_0, seq_wd_col_1;
    logic              seq_swap_banks;
    logic              seq_loading_phase;

    // unified_buffer host-write
    logic              seq_hw_addr;
    logic signed [7:0] seq_hw_data [2];
    logic              seq_hw_valid;

    // unified_buffer UB-read
    logic              seq_ub_addr;
    logic              seq_ub_en;

    // bias
    logic signed [15:0] seq_bias [2];

    // pipeline final output
    logic signed [15:0] final_row_out [2];
    logic               final_row_valid;

    // soft-reset from sequencer (CMD_RESET)
    logic seq_tpu_reset;

    // Combined reset for datapath modules: global reset OR soft reset
    logic dp_reset;
    assign dp_reset = rst | seq_tpu_reset;

    tpu_sequencer #(.WAIT_TIMEOUT(200)) u_seq (
        .clk              (clk),
        .reset            (rst),
        // RX
        .rx_data          (rx_byte),
        .rx_valid         (rx_valid),
        // TX
        .tx_data          (tx_byte),
        .tx_valid         (tx_valid_seq),
        .tx_busy          (tx_busy),
        // weight_fifo
        .write_enable_col_0 (seq_we_col_0),
        .write_data_col_0   (seq_wd_col_0),
        .write_enable_col_1 (seq_we_col_1),
        .write_data_col_1   (seq_wd_col_1),
        .swap_banks         (seq_swap_banks),
        .loading_phase      (seq_loading_phase),
        // unified_buffer host-write
        .host_write_addr    (seq_hw_addr),
        .host_write_data    (seq_hw_data),
        .host_write_valid   (seq_hw_valid),
        // unified_buffer UB-read
        .ub_read_addr       (seq_ub_addr),
        .ub_read_en         (seq_ub_en),
        // bias
        .out_bias           (seq_bias),
        // pipeline result
        .final_row_out      (final_row_out),
        .final_row_valid    (final_row_valid),
        // soft reset
        .tpu_reset          (seq_tpu_reset),
        .busy               ()
    );

    // =========================================================================
    // Datapath glue
    // =========================================================================

    // unified_buffer → systolic_data_setup
    logic signed [7:0] ub_read_data [2];
    logic              ub_read_valid;

    // systolic_data_setup → MMU
    logic signed [7:0] skewed_act [2];
    logic              skewed_valid [2];

    // weight_fifo → MMU
    logic signed [7:0] wf_col_0, wf_col_1;
    logic              wf_col_0_valid, wf_col_1_valid;

    // MMU → accumulator
    logic signed [15:0] mmu_out_0, mmu_out_1;
    logic               mmu_out_0_valid, mmu_out_1_valid;

    logic signed [15:0] accum_in_data  [2];
    logic               accum_in_valid [2];
    assign accum_in_data[0]  = mmu_out_0;
    assign accum_in_data[1]  = mmu_out_1;
    assign accum_in_valid[0] = mmu_out_0_valid;
    assign accum_in_valid[1] = mmu_out_1_valid;

    // accumulator → bias
    logic signed [15:0] acc_row_out [2];
    logic               acc_row_valid;

    // bias → activation
    logic signed [15:0] biased_row [2];
    logic               biased_valid;

    // Activation write port tied off (single-layer mode)
    logic signed [7:0] ub_act_dummy [2];
    assign ub_act_dummy[0] = 8'sd0;
    assign ub_act_dummy[1] = 8'sd0;

    // =========================================================================
    // Module instantiations
    // =========================================================================

    unified_buffer #(.ROWS(2), .COLS(2), .DATA_WIDTH(8)) u_ub (
        .clk                (clk),
        .reset              (dp_reset),
        .host_write_addr    (seq_hw_addr),
        .host_write_data    (seq_hw_data),
        .host_write_valid   (seq_hw_valid),
        .host_read_addr     (1'b0),
        .host_read_data     (),
        .host_read_en       (1'b0),
        .host_read_valid    (),
        .ub_read_addr       (seq_ub_addr),
        .ub_read_en         (seq_ub_en),
        .ub_read_data       (ub_read_data),
        .ub_read_valid      (ub_read_valid),
        .act_write_data     (ub_act_dummy),
        .act_write_valid    (1'b0),
        .act_write_addr_reset(1'b0),
        .bank_swap          (1'b0)
    );

    weight_fifo #(.WEIGHT_WIDTH(WEIGHT_WIDTH), .FIFO_DEPTH(FIFO_DEPTH)) u_wf (
        .clk                (clk),
        .reset              (dp_reset),
        .write_enable_col_0 (seq_we_col_0),
        .write_data_col_0   (seq_wd_col_0),
        .write_enable_col_1 (seq_we_col_1),
        .write_data_col_1   (seq_wd_col_1),
        .swap_banks         (seq_swap_banks),
        .loading_phase      (seq_loading_phase),
        .out_col_0          (wf_col_0),
        .out_col_0_valid    (wf_col_0_valid),
        .out_col_1          (wf_col_1),
        .out_col_1_valid    (wf_col_1_valid),
        .shadow_loaded      (),
        .active_bank        (),
        .active_empty       (),
        .active_full        (),
        .any_shadow_full    ()
    );

    systolic_data_setup #(.ARRAY_ROWS(2), .DATA_WIDTH(8)) u_sds (
        .clk            (clk),
        .reset          (dp_reset),
        .ub_read_data   (ub_read_data),
        .ub_read_valid  (ub_read_valid),
        .mmu_in_row     (skewed_act),
        .mmu_in_valid   (skewed_valid)
    );

    mmu u_mmu (
        .clk                     (clk),
        .reset                   (dp_reset),
        .loading_phase           (seq_loading_phase),
        .capture_weight_col_0    (wf_col_0_valid),
        .capture_weight_col_1    (wf_col_1_valid),
        .in_col_0                (wf_col_0),
        .in_col_0_valid          (wf_col_0_valid),
        .in_col_1                (wf_col_1),
        .in_col_1_valid          (wf_col_1_valid),
        .in_row_0                (skewed_act[0]),
        .in_row_0_valid          (skewed_valid[0]),
        .in_row_1                (skewed_act[1]),
        .in_row_1_valid          (skewed_valid[1]),
        .out_partial_sum_0       (mmu_out_0),
        .out_partial_sum_0_valid (mmu_out_0_valid),
        .out_partial_sum_1       (mmu_out_1),
        .out_partial_sum_1_valid (mmu_out_1_valid)
    );

    accumulator #(.NUM_COLS(2), .PSUM_WIDTH(16), .FIFO_DEPTH(FIFO_DEPTH)) u_accum (
        .clk                  (clk),
        .reset                (dp_reset),
        .in_partial_sum       (accum_in_data),
        .in_partial_sum_valid (accum_in_valid),
        .out_row              (acc_row_out),
        .out_row_valid        (acc_row_valid),
        .any_fifo_full        ()
    );

    bias #(.NUM_COLS(2), .PSUM_WIDTH(16)) u_bias (
        .clk          (clk),
        .reset        (dp_reset),
        .in_row       (acc_row_out),
        .in_row_valid (acc_row_valid),
        .in_bias      (seq_bias),
        .out_row      (biased_row),
        .out_row_valid(biased_valid)
    );

    activation #(.NUM_COLS(2), .PSUM_WIDTH(16)) u_act (
        .clk          (clk),
        .reset        (dp_reset),
        .in_row       (biased_row),
        .in_row_valid (biased_valid),
        .out_row      (final_row_out),
        .out_row_valid(final_row_valid)
    );

endmodule
