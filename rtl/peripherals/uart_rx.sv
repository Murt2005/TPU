`timescale 1ns / 1ps

// UART RX: 8N1 UART receiver
module uart_rx #(
    parameter int CLK_FREQ  = 50_000_000,
    parameter int BAUD_RATE = 115_200
) (
    input  logic       clk,
    input  logic       reset,

    input  logic       rx_serial,

    output logic [7:0] rx_data,
    output logic       rx_valid,
    output logic       rx_error
);

    localparam int TICKS_PER_BIT = CLK_FREQ / BAUD_RATE;
    localparam int SAMPLE_TICK   = TICKS_PER_BIT / 2;
    localparam int CTR_WIDTH     = $clog2(TICKS_PER_BIT + 1);
    localparam logic [CTR_WIDTH-1:0] LAST_TICK = CTR_WIDTH'(TICKS_PER_BIT - 1);

    // double-flop synchroniser
    logic rx_sync_0, rx_sync;
    logic rx_sync_prev;
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
                S_IDLE: begin
                    if (rx_sync_prev && !rx_sync) begin
                        baud_ctr <= '0;
                        state    <= S_START;
                    end
                end

                S_START: begin
                    if (baud_ctr == SAMPLE_TICK[CTR_WIDTH-1:0]) begin
                        if (!rx_sync) begin
                            baud_ctr <= '0;
                            bit_idx  <= '0;
                            state    <= S_DATA;
                        end else begin
                            state <= S_IDLE;
                        end
                    end else begin
                        baud_ctr <= baud_ctr + 1'b1;
                    end
                end

                S_DATA: begin
                    if (baud_ctr == LAST_TICK) begin
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

                S_STOP: begin
                    if (baud_ctr == SAMPLE_TICK[CTR_WIDTH-1:0]) begin
                        if (rx_sync) begin
                            rx_data  <= shift_reg;
                            rx_valid <= 1'b1;
                            rx_error <= 1'b0;
                        end else begin
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
