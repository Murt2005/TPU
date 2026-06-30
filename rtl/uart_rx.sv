`timescale 1ns / 1ps

// uart_rx — 8N1 UART receiver.
//
// Samples rx_serial at 16x oversampling.  On each received byte, pulses
// rx_valid for exactly one clock cycle with rx_data holding the byte.
//
// Parameters:
//   CLK_FREQ  — system clock frequency in Hz  (default 50 MHz, DE1-SoC)
//   BAUD_RATE — desired baud rate             (default 115200)
//
// Interface:
//   rx_serial  — raw pin from FPGA top-level (async, sampled internally)
//   rx_data    — 8-bit byte, valid when rx_valid is high
//   rx_valid   — one-cycle pulse per received byte
//   rx_error   — framing error flag (stop bit was 0); clears next start detection

module uart_rx #(
    parameter int CLK_FREQ  = 50_000_000,
    parameter int BAUD_RATE = 115_200
) (
    input  logic       clk,
    input  logic       reset,

    input  logic       rx_serial,   // raw async pin

    output logic [7:0] rx_data,
    output logic       rx_valid,
    output logic       rx_error
);

    // Baud timing: 16x oversampling means one bit period = OVERSAMPLE ticks
    // We sample at tick 8 (mid-bit) for maximum noise margin
    localparam int OVERSAMPLE   = 16;
    localparam int TICKS_PER_BIT = CLK_FREQ / BAUD_RATE;
    localparam int SAMPLE_TICK   = TICKS_PER_BIT / 2;   // mid-bit sample point
    localparam int CTR_WIDTH     = $clog2(TICKS_PER_BIT + 1);

    // Double-flop synchroniser
    logic rx_sync_0, rx_sync;
    logic rx_sync_prev;   // one-cycle delayed copy for falling-edge detection
    always_ff @(posedge clk) begin
        rx_sync_0    <= rx_serial;
        rx_sync      <= rx_sync_0;
        rx_sync_prev <= rx_sync;
    end

    typedef enum logic [1:0] {
        S_IDLE  = 2'd0,
        S_START = 2'd1,
        S_DATA  = 2'd2,
        S_STOP  = 2'd3
    } state_t;

    state_t              state;
    logic [CTR_WIDTH-1:0] baud_ctr;
    logic [2:0]           bit_idx;
    logic [7:0]           shift_reg;

    always_ff @(posedge clk) begin
        if (reset) begin
            state    <= S_IDLE;
            baud_ctr <= '0;
            bit_idx  <= '0;
            shift_reg<= '0;
            rx_data  <= '0;
            rx_valid <= 1'b0;
            rx_error <= 1'b0;
        end else begin
            rx_valid <= 1'b0;

            case (state)
                // IDLE: wait for falling edge (start bit)
                // Only enter S_START on a true 1→0 transition to prevent phantom
                // frames after framing errors where the line stays low.
                S_IDLE: begin
                    if (rx_sync_prev && !rx_sync) begin
                        // Detected falling edge: genuine start bit candidate
                        baud_ctr <= '0;
                        state    <= S_START;
                    end
                end

                // START: wait until mid-start-bit, verify it's still 0
                S_START: begin
                    if (baud_ctr == SAMPLE_TICK[CTR_WIDTH-1:0]) begin
                        if (!rx_sync) begin
                            // Valid start bit confirmed
                            baud_ctr <= '0;
                            bit_idx  <= '0;
                            state    <= S_DATA;
                        end else begin
                            // Glitch — abort, return to IDLE
                            state <= S_IDLE;
                        end
                    end else begin
                        baud_ctr <= baud_ctr + 1'b1;
                    end
                end

                // DATA: sample 8 data bits (LSB first)
                S_DATA: begin
                    if (baud_ctr == (TICKS_PER_BIT - 1)) begin
                        baud_ctr              <= '0;
                        shift_reg[bit_idx]    <= rx_sync;
                        if (bit_idx == 3'd7) begin
                            state <= S_STOP;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end else begin
                        baud_ctr <= baud_ctr + 1'b1;
                    end
                end

                // STOP: verify stop bit (must be 1)
                S_STOP: begin
                    if (baud_ctr == SAMPLE_TICK[CTR_WIDTH-1:0]) begin
                        if (rx_sync) begin
                            // Good stop bit
                            rx_data  <= shift_reg;
                            rx_valid <= 1'b1;
                            rx_error <= 1'b0;
                        end else begin
                            // Framing error — latch error flag; it stays set
                            // until the next valid byte clears it (or reset)
                            rx_error <= 1'b1;
                        end
                        state    <= S_IDLE;
                        baud_ctr <= '0;
                    end else begin
                        baud_ctr <= baud_ctr + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
