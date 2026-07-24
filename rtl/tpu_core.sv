`timescale 1ns / 1ps

// tpu_core — board-neutral TPU core: sequencer + full datapath.
//
// Everything between the host byte-stream and the compute pipeline, with NO
// physical PHY and NO board pins. A board-specific top (rtl/tpu_top.sv for the
// pico2-ice serial link, rtl/tpu_top_hps.sv for the DE1-SoC HPS bridge) pairs
// this with a PHY that turns some transport into the byte-stream interface
// below, plus a power-on-reset generator that drives `reset`.
//
// Byte-stream interface (identical to what uart_rx/uart_tx, spi_slave, and
// hps_bridge expose):
//   rx_data/rx_valid/rx_error : one host->FPGA byte (+ framing-error flag)
//   tx_data/tx_valid          : one FPGA->host byte (tx_valid pulsed by the seq)
//   tx_busy                   : PHY busy sending the current tx byte
//
// Wires together:
//   tpu_sequencer    (command decoder + pipeline orchestrator)
//   unified_buffer   (activation scratchpad)
//   weight_fifo      (double-buffered weight FIFO)
//   systolic_data_setup (skew / stagger activations)
//   mmu              (ARRAY_ROWS x NUM_COLS systolic array)
//   accumulator      (column-FIFO row reassembler + K-tiling running sum)
//   bias             (per-column stationary bias add)
//   activation       (ReLU)
module tpu_core #(
    parameter int WEIGHT_WIDTH = 8,
    parameter int FIFO_DEPTH   = 4,   // must be a power of 2, >= ARRAY_ROWS
    // Array geometry (see docs/SEQUENCER_REDESIGN.md §1):
    //   ARRAY_ROWS — systolic rows = K-tile depth
    //   NUM_COLS   — systolic columns = N-tile width
    //   M_TILE     — activation rows streamed per RUN (UB address depth)
    parameter int ARRAY_ROWS   = 2,
    parameter int NUM_COLS     = 2,
    parameter int M_TILE       = ARRAY_ROWS,
    parameter int USE_MAC16_PAIR = 0
) (
    input  logic clk,
    input  logic reset,          // synchronous active-high (from the board POR)

    // Host byte-stream interface (driven by the board top's PHY)
    input  logic [7:0] rx_data,
    input  logic       rx_valid,
    input  logic       rx_error,
    output logic [7:0] tx_data,
    output logic       tx_valid,
    input  logic       tx_busy
);

    // Sequencer control signals:
    //  unified_buffer address width (must match tpu_sequencer's derived
    //  UB_ADDR_W and unified_buffer's ADDR_WIDTH with ROWS = M_TILE)
    localparam int UB_ADDR_W = (M_TILE > 1) ? $clog2(M_TILE) : 1;

    // weight_fifo (array-port style, one lane per column)
    logic        [NUM_COLS-1:0]      seq_we_col;
    logic signed [NUM_COLS-1:0][7:0] seq_wd_col;
    logic              seq_swap_banks;
    logic              seq_loading_phase;

    // unified_buffer host-write
    logic        [UB_ADDR_W-1:0]        seq_hw_addr;
    logic signed [ARRAY_ROWS-1:0][7:0]  seq_hw_data;
    logic              seq_hw_valid;

    // unified_buffer UB-read
    logic        [UB_ADDR_W-1:0] seq_ub_addr;
    logic              seq_ub_en;

    // bias
    logic signed [NUM_COLS-1:0][15:0] seq_bias;

    // K-tiling control (accumulator persistent-sum passes)
    logic seq_tile_first, seq_tile_last;
    logic accum_pass_done;

    // pipeline final output
    logic signed [NUM_COLS-1:0][15:0] final_row_out;
    logic               final_row_valid;

    // soft-reset from sequencer (CMD_RESET)
    logic seq_tpu_reset;

    // Combined reset for datapath modules: global reset OR soft reset
    logic dp_reset;
    assign dp_reset = reset | seq_tpu_reset;

    tpu_sequencer #(
        .ARRAY_ROWS   (ARRAY_ROWS),
        .NUM_COLS     (NUM_COLS),
        .M_TILE       (M_TILE),
        .WAIT_TIMEOUT (200)
    ) u_seq (
        .clk              (clk),
        .reset            (reset),
        // RX
        .rx_data          (rx_data),
        .rx_valid         (rx_valid),
        .rx_error         (rx_error),
        // TX
        .tx_data          (tx_data),
        .tx_valid         (tx_valid),
        .tx_busy          (tx_busy),
        // weight_fifo
        .write_enable_col   (seq_we_col),
        .write_data_col     (seq_wd_col),
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

    // unified_buffer → systolic_data_setup
    logic signed [ARRAY_ROWS-1:0][7:0] ub_read_data;
    logic              ub_read_valid;

    // systolic_data_setup → MMU
    logic signed [ARRAY_ROWS-1:0][7:0] skewed_act;
    logic        [ARRAY_ROWS-1:0]      skewed_valid;

    // weight_fifo → MMU
    logic signed [NUM_COLS-1:0][7:0] wf_col;
    logic        [NUM_COLS-1:0]      wf_col_valid;

    // MMU → accumulator
    logic signed [NUM_COLS-1:0][15:0] accum_in_data;
    logic        [NUM_COLS-1:0]       accum_in_valid;

    // accumulator → bias
    logic signed [NUM_COLS-1:0][15:0] acc_row_out;
    logic               acc_row_valid;

    // bias → activation
    logic signed [NUM_COLS-1:0][15:0] biased_row;
    logic               biased_valid;

    // Activation write port tied off (single-layer mode)
    logic signed [ARRAY_ROWS-1:0][7:0] ub_act_dummy;
    assign ub_act_dummy = '0;

    // Module instantiations
    //  UB geometry: ROWS = M_TILE addresses, each holding one ARRAY_ROWS-wide
    //  activation row (COLS must equal ARRAY_ROWS — its read port feeds
    //  systolic_data_setup's ARRAY_ROWS-wide input).
    unified_buffer #(.ROWS(M_TILE), .COLS(ARRAY_ROWS), .DATA_WIDTH(8)) u_ub (
        .clk                (clk),
        .reset              (dp_reset),
        .host_write_addr    (seq_hw_addr),
        .host_write_data    (seq_hw_data),
        .host_write_valid   (seq_hw_valid),
        .host_read_addr     ({UB_ADDR_W{1'b0}}),
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

    weight_fifo #(.WEIGHT_WIDTH(WEIGHT_WIDTH), .FIFO_DEPTH(FIFO_DEPTH), .NUM_COLS(NUM_COLS)) u_wf (
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

    systolic_data_setup #(.ARRAY_ROWS(ARRAY_ROWS), .DATA_WIDTH(8)) u_sds (
        .clk            (clk),
        .reset          (dp_reset),
        .ub_read_data   (ub_read_data),
        .ub_read_valid  (ub_read_valid),
        .mmu_in_row     (skewed_act),
        .mmu_in_valid   (skewed_valid)
    );

    mmu #(.ARRAY_ROWS(ARRAY_ROWS), .NUM_COLS(NUM_COLS),
          .USE_MAC16_PAIR(USE_MAC16_PAIR)) u_mmu (
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

    // accumulator's ROWS_PER_PASS counts output rows per pass — that is M_TILE
    // (one output row per streamed activation row), not the systolic row count.
    accumulator #(.NUM_COLS(NUM_COLS), .PSUM_WIDTH(16), .FIFO_DEPTH(FIFO_DEPTH), .ROWS_PER_PASS(M_TILE)) u_accum (
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

    bias #(.NUM_COLS(NUM_COLS), .PSUM_WIDTH(16)) u_bias (
        .clk          (clk),
        .reset        (dp_reset),
        .in_row       (acc_row_out),
        .in_row_valid (acc_row_valid),
        .in_bias      (seq_bias),
        .out_row      (biased_row),
        .out_row_valid(biased_valid)
    );

    activation #(.NUM_COLS(NUM_COLS), .PSUM_WIDTH(16)) u_act (
        .clk          (clk),
        .reset        (dp_reset),
        .in_row       (biased_row),
        .in_row_valid (biased_valid),
        .out_row      (final_row_out),
        .out_row_valid(final_row_valid)
    );

endmodule
