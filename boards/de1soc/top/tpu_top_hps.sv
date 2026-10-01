`timescale 1ns / 1ps

// DE1-SoC top: hps_bridge + tpu_core + power-on reset; instantiated as a Qsys component
module tpu_top_hps #(
    parameter int WEIGHT_WIDTH = 8,
    parameter int FIFO_DEPTH   = 4,   // must be a power of 2, >= ARRAY_ROWS
    parameter int ARRAY_ROWS   = 2,
    parameter int NUM_COLS     = 2,
    parameter int M_TILE       = ARRAY_ROWS,
    parameter int PSUM_WIDTH   = 16,
    parameter int USE_MAC16_PAIR = 0
) (
    input  logic clk,
    input  logic reset_n,

    // qsys slave settings: fixed read latency 1, no waitrequest, clocked by clk
    input  logic [1:0]  avs_address,
    input  logic        avs_read,
    output logic [31:0] avs_readdata,
    input  logic        avs_write,
    input  logic [31:0] avs_writedata
);

    // power-on reset, same reason as tpu_top: don't rely on reset_n pulsing
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
        .PSUM_WIDTH     (PSUM_WIDTH),
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
