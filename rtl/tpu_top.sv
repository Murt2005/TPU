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
    parameter int FIFO_DEPTH   = 4,   // must be a power of 2, >= ARRAY_ROWS
    // Array geometry (see docs/SEQUENCER_REDESIGN.md §1):
    //   ARRAY_ROWS — systolic rows = K-tile depth
    //   NUM_COLS   — systolic columns = N-tile width
    //   M_TILE     — activation rows streamed per RUN (UB address depth)
    parameter int ARRAY_ROWS   = 2,
    parameter int NUM_COLS     = 2,
    parameter int M_TILE       = ARRAY_ROWS,
    // Host PHY select: 0 = UART on rx_pin/tx_pin (default, the validated
    // bring-up path), 1 = SPI slave on spi_* (rtl/spi_slave.sv; the RP2350
    // drives it as mode-0 master over the shared config bus). Only the
    // selected PHY is instantiated; the other side's pins idle.
    parameter int USE_SPI      = 0
) (
    input  logic clk,
    input  logic reset_n,   // active-low (DE1-SoC KEY[0])

    input  logic rx_pin,    // UART RX from host
    output logic tx_pin,    // UART TX to host

    // SPI slave pins (USE_SPI=1 builds; see fpga/tpu_top.pcf for the
    // pico2-ice config-bus pin mapping)
    input  logic spi_sck,
    input  logic spi_csn,
    input  logic spi_mosi,
    output logic spi_miso
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

    generate
        if (USE_SPI != 0) begin : gen_spi_phy
            spi_slave u_spi (
                .clk      (clk),
                .reset    (rst),
                .sck      (spi_sck),
                .csn      (spi_csn),
                .mosi     (spi_mosi),
                .miso     (spi_miso),
                .rx_data  (rx_byte),
                .rx_valid (rx_valid),
                .tx_data  (tx_byte),
                .tx_valid (tx_valid_seq),
                .tx_busy  (tx_busy)
            );
            // SPI has no start/stop framing, so no framing-error source
            assign rx_error = 1'b0;
            assign tx_pin   = 1'b1;   // UART line idles high
        end else begin : gen_uart_phy
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

            assign spi_miso = 1'b0;
        end
    endgenerate

    // =========================================================================
    // Sequencer control signals
    // =========================================================================
    // unified_buffer address width (must match tpu_sequencer's derived
    // UB_ADDR_W and unified_buffer's ADDR_WIDTH with ROWS = M_TILE)
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
    assign dp_reset = rst | seq_tpu_reset;

    tpu_sequencer #(
        .ARRAY_ROWS   (ARRAY_ROWS),
        .NUM_COLS     (NUM_COLS),
        .M_TILE       (M_TILE),
        .WAIT_TIMEOUT (200)
    ) u_seq (
        .clk              (clk),
        .reset            (rst),
        // RX
        .rx_data          (rx_byte),
        .rx_valid         (rx_valid),
        .rx_error         (rx_error),
        // TX
        .tx_data          (tx_byte),
        .tx_valid         (tx_valid_seq),
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

    // =========================================================================
    // Datapath glue
    // =========================================================================

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

    // =========================================================================
    // Module instantiations
    // =========================================================================

    // UB geometry: ROWS = M_TILE addresses, each holding one ARRAY_ROWS-wide
    // activation row (COLS must equal ARRAY_ROWS — its read port feeds
    // systolic_data_setup's ARRAY_ROWS-wide input).
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

    mmu #(.ARRAY_ROWS(ARRAY_ROWS), .NUM_COLS(NUM_COLS)) u_mmu (
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

    // accumulator's ARRAY_ROWS parameter counts output rows per pass — that
    // is M_TILE (one output row per streamed activation row), not the
    // systolic row count.
    accumulator #(.NUM_COLS(NUM_COLS), .PSUM_WIDTH(16), .FIFO_DEPTH(FIFO_DEPTH), .ARRAY_ROWS(M_TILE)) u_accum (
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
