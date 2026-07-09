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
    // Power-on-reset generator: holds an internal reset for the first 256
    // cycles after configuration, regardless of reset_n's level. Needed
    // because every module's registers (e.g. uart_tx's tx_busy/state) only
    // get their known-good value inside their `if (reset)` branch -- if
    // reset_n is already idle-high the instant the FPGA configures (true on
    // boards where the reset button is a plain pull-up with no reset IC),
    // that branch would otherwise never fire even once, leaving those
    // registers to whatever value the toolchain's power-on initial-value
    // inference happens to pick. Confirmed on iCE40/pico2-ice: without this,
    // uart_tx never transmits (tx_busy powers up stuck) even though the
    // exact same design works fine in simulation, where testbenches always
    // pulse reset explicitly at the start.
    logic [7:0] por_ctr = '0;
    logic       por_done = 1'b0;
    always_ff @(posedge clk) begin
        if (!por_done) begin
            por_ctr <= por_ctr + 1'b1;
            if (por_ctr == 8'hFF) por_done <= 1'b1;
        end
    end

    logic rst;
    assign rst = ~reset_n | ~por_done;

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
    logic signed [1:0][7:0] seq_hw_data;
    logic              seq_hw_valid;

    // unified_buffer UB-read
    logic              seq_ub_addr;
    logic              seq_ub_en;

    // bias
    logic signed [1:0][15:0] seq_bias;

    // K-tiling control (accumulator persistent-sum passes)
    logic seq_tile_first, seq_tile_last;
    logic accum_pass_done;

    // pipeline final output
    logic signed [1:0][15:0] final_row_out;
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
        // K-tiling control
        .tile_first         (seq_tile_first),
        .tile_last          (seq_tile_last),
        .accum_pass_done    (accum_pass_done),
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
    logic signed [1:0][7:0] ub_read_data;
    logic              ub_read_valid;

    // systolic_data_setup → MMU
    logic signed [1:0][7:0] skewed_act;
    logic              [1:0] skewed_valid;

    // sequencer's per-column weight_fifo write port, packed into arrays
    // for weight_fifo's generate-block column interface
    logic              [1:0] seq_we_col;
    logic signed [1:0][7:0]  seq_wd_col;
    assign seq_we_col[0] = seq_we_col_0;
    assign seq_we_col[1] = seq_we_col_1;
    assign seq_wd_col[0] = seq_wd_col_0;
    assign seq_wd_col[1] = seq_wd_col_1;

    // weight_fifo → MMU
    logic signed [1:0][7:0] wf_col;
    logic              [1:0] wf_col_valid;

    // MMU → accumulator
    logic signed [1:0][15:0] accum_in_data;
    logic              [1:0] accum_in_valid;

    // accumulator → bias
    logic signed [1:0][15:0] acc_row_out;
    logic               acc_row_valid;

    // bias → activation
    logic signed [1:0][15:0] biased_row;
    logic               biased_valid;

    // Activation write port tied off (single-layer mode)
    logic signed [1:0][7:0] ub_act_dummy;
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

    weight_fifo #(.WEIGHT_WIDTH(WEIGHT_WIDTH), .FIFO_DEPTH(FIFO_DEPTH), .NUM_COLS(2)) u_wf (
        .clk                (clk),
        .reset              (dp_reset),
        .write_enable_col   (seq_we_col),
        .write_data_col     (seq_wd_col),
        .swap_banks         (seq_swap_banks),
        .loading_phase      (seq_loading_phase),
        .out_col            (wf_col),
        .out_col_valid      (wf_col_valid),
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

    mmu #(.ARRAY_ROWS(2), .NUM_COLS(2)) u_mmu (
        .clk                   (clk),
        .reset                 (dp_reset),
        .loading_phase         (seq_loading_phase),
        .capture_weight_col    (wf_col_valid),
        .in_col                (wf_col),
        .in_col_valid          (wf_col_valid),
        .in_row                (skewed_act),
        .in_row_valid          (skewed_valid),
        .out_partial_sum       (accum_in_data),
        .out_partial_sum_valid (accum_in_valid)
    );

    accumulator #(.NUM_COLS(2), .PSUM_WIDTH(16), .FIFO_DEPTH(FIFO_DEPTH)) u_accum (
        .clk                  (clk),
        .reset                (dp_reset),
        .in_partial_sum       (accum_in_data),
        .in_partial_sum_valid (accum_in_valid),
        .tile_first           (seq_tile_first),
        .tile_last            (seq_tile_last),
        .out_row              (acc_row_out),
        .out_row_valid        (acc_row_valid),
        .pass_done            (accum_pass_done),
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
