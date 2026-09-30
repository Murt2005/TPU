`timescale 1ns / 1ps

// uart_tx — 8N1 UART transmitter.
//
// Accepts one byte at a time.  When tx_valid is pulsed high with tx_data
// present, it shifts out: start bit (0), 8 data bits LSB-first, stop bit (1).
// tx_busy is high throughout transmission; assert tx_valid only when tx_busy
// is low to avoid dropping bytes.
//
// Parameters:
//   CLK_FREQ  — system clock frequency in Hz
//   BAUD_RATE — baud rate

module uart_tx #(
    parameter int CLK_FREQ  = 50_000_000,
    parameter int BAUD_RATE = 115_200
) (
    input  logic       clk,
    input  logic       reset,

    input  logic [7:0] tx_data,
    input  logic       tx_valid,   // pulse high for one cycle to send tx_data
    output logic       tx_busy,    // high while transmitting; consumer must wait

    output logic       tx_serial   // raw UART TX pin
);

    localparam int TICKS_PER_BIT = CLK_FREQ / BAUD_RATE;
    localparam int CTR_WIDTH     = $clog2(TICKS_PER_BIT + 1);
    localparam logic [CTR_WIDTH-1:0] LAST_TICK = CTR_WIDTH'(TICKS_PER_BIT - 1);

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
            state     <= S_IDLE;
            baud_ctr  <= '0;
            bit_idx   <= '0;
            shift_reg <= '0;
            tx_serial <= 1'b1;
            tx_busy   <= 1'b0;
        end else begin
            case (state)
                // IDLE: line high, wait for tx_valid
                S_IDLE: begin
                    tx_serial <= 1'b1;
                    tx_busy   <= 1'b0;
                    if (tx_valid) begin
                        shift_reg <= tx_data;
                        baud_ctr  <= '0;
                        tx_busy   <= 1'b1;
                        state     <= S_START;
                    end
                end

                // START: drive line low for one full bit period
                S_START: begin
                    tx_serial <= 1'b0;
                    if (baud_ctr == LAST_TICK) begin
                        baud_ctr <= '0;
                        bit_idx  <= '0;
                        state    <= S_DATA;
                    end else begin
                        baud_ctr <= baud_ctr + 1'b1;
                    end
                end

                // DATA: shift out 8 bits LSB-first
                S_DATA: begin
                    tx_serial <= shift_reg[bit_idx];
                    if (baud_ctr == LAST_TICK) begin
                        baud_ctr <= '0;
                        if (bit_idx == 3'd7) begin
                            state <= S_STOP;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end else begin
                        baud_ctr <= baud_ctr + 1'b1;
                    end
                end

                // STOP: drive line high for one full bit period
                S_STOP: begin
                    tx_serial <= 1'b1;
                    if (baud_ctr == LAST_TICK) begin
                        baud_ctr <= '0;
                        tx_busy  <= 1'b0;
                        state    <= S_IDLE;
                    end else begin
                        baud_ctr <= baud_ctr + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
