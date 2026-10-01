`timescale 1ns / 1ps

// pico2-ice top: UART or SPI PHY + tpu_core + power-on reset
module tpu_top #(
    parameter int CLK_FREQ    = 50_000_000,
    parameter int BAUD_RATE   = 115_200,
    parameter int WEIGHT_WIDTH = 8,
    parameter int FIFO_DEPTH   = 4,   // must be a power of 2, >= ARRAY_ROWS
    parameter int ARRAY_ROWS   = 2,
    parameter int NUM_COLS     = 2,
    parameter int M_TILE       = ARRAY_ROWS,

    // must stay 16 with USE_MAC16_PAIR=1
    parameter int PSUM_WIDTH   = 16,
    parameter int USE_SPI      = 0,   // 0 = UART pins, 1 = SPI slave

    parameter int USE_MAC16_PAIR = 0
) (
    input  logic clk,
    input  logic reset_n,

    input  logic rx_pin,
    output logic tx_pin,

    input  logic spi_sck,
    input  logic spi_csn,
    input  logic spi_mosi,
    output logic spi_miso
);

    // power-on reset: reset_n idles high from configuration on this board, so
    // without it no `if (reset)` branch ever fires and uart_tx powers up stuck
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
    logic       rx_error;

    logic [7:0] tx_byte;
    logic       tx_valid_seq;
    logic       tx_busy;

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
            // no start/stop framing on SPI
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
        .rx_error (rx_error),
        .tx_data  (tx_byte),
        .tx_valid (tx_valid_seq),
        .tx_busy  (tx_busy)
    );

endmodule
