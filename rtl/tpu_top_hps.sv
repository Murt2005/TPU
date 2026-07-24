`timescale 1ns / 1ps

// tpu_top_hps — DE1-SoC (Cyclone V) top-level.
//
// Pairs the board-neutral tpu_core (rtl/tpu_core.sv) with the HPS Avalon-MM
// bridge PHY (rtl/hps_bridge.sv) and a power-on-reset generator. This is the
// module you instantiate as a component inside the Platform Designer (Qsys)
// system, wiring avs_* to the HPS lightweight HPS->FPGA bridge (h2f_lw) and
// clk to the fabric clock the bridge is clocked from. The pico2-ice serial
// top is rtl/tpu_top.sv; both wrap the same core.
//
// There are no chip pins here beyond clk/reset_n and the Avalon bus — the bus
// is an internal fabric connection (to the HPS), not FPGA IO, which is exactly
// why the DE1-SoC needs a separate top from the serial-pin tpu_top.
module tpu_top_hps #(
    parameter int WEIGHT_WIDTH = 8,
    parameter int FIFO_DEPTH   = 4,   // must be a power of 2, >= ARRAY_ROWS
    parameter int ARRAY_ROWS   = 2,
    parameter int NUM_COLS     = 2,
    parameter int M_TILE       = ARRAY_ROWS,
    parameter int USE_MAC16_PAIR = 0
) (
    input  logic clk,
    input  logic reset_n,

    // Avalon-MM slave to the HPS lightweight bridge. See rtl/hps_bridge.sv for
    // the register map. Configure the Qsys slave as fixed read latency 1, no
    // waitrequest, clocked by this clk.
    input  logic [1:0]  avs_address,
    input  logic        avs_read,
    output logic [31:0] avs_readdata,
    input  logic        avs_write,
    input  logic [31:0] avs_writedata
);

    // Power-on-reset generator (see rtl/tpu_top.sv for the full rationale):
    // holds reset for the first 256 cycles after configuration so every
    // module's registers pass through their `if (reset)` branch at least once,
    // regardless of reset_n's level at config.
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

    // Host byte streams between the HPS bridge and the core
    logic [7:0] rx_byte;
    logic       rx_valid;
    logic       tx_byte_valid;
    logic [7:0] tx_byte;
    logic       tx_busy;

    hps_bridge u_hps (
        .clk           (clk),
        .reset         (rst),
        .avs_address   (avs_address),
        .avs_read      (avs_read),
        .avs_readdata  (avs_readdata),
        .avs_write     (avs_write),
        .avs_writedata (avs_writedata),
        .rx_data       (rx_byte),
        .rx_valid      (rx_valid),
        .tx_data       (tx_byte),
        .tx_valid      (tx_byte_valid),
        .tx_busy       (tx_busy)
    );

    tpu_core #(
        .WEIGHT_WIDTH   (WEIGHT_WIDTH),
        .FIFO_DEPTH     (FIFO_DEPTH),
        .ARRAY_ROWS     (ARRAY_ROWS),
        .NUM_COLS       (NUM_COLS),
        .M_TILE         (M_TILE),
        .USE_MAC16_PAIR (USE_MAC16_PAIR)
    ) u_core (
        .clk      (clk),
        .reset    (rst),
        .rx_data  (rx_byte),
        .rx_valid (rx_valid),
        .rx_error (1'b0),          // memory-mapped host, no framing errors
        .tx_data  (tx_byte),
        .tx_valid (tx_byte_valid),
        .tx_busy  (tx_busy)
    );

endmodule
