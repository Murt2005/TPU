`timescale 1ns / 1ps

module spi_slave (
    input  logic clk,
    input  logic reset,

    input  logic sck,
    input  logic csn,
    input  logic mosi,
    output logic miso,

    output logic [7:0] rx_data,
    output logic       rx_valid,

    input  logic [7:0] tx_data,
    input  logic       tx_valid,
    output logic       tx_busy
);

    localparam logic [7:0] IDLE_BYTE = 8'h00;

    logic [2:0] rx_bit = '0;
    logic [6:0] rx_shift;
    logic [7:0] rx_hold;
    logic       rx_flag = 1'b0;

    always_ff @(posedge sck or posedge csn) begin
        if (csn) rx_bit <= '0;
        else     rx_bit <= (rx_bit == 3'd7) ? '0 : rx_bit + 3'd1;
    end

    always_ff @(posedge sck) begin
        if (!csn) begin
            rx_shift <= {rx_shift[5:0], mosi};
            if (rx_bit == 3'd7) begin
                rx_hold <= {rx_shift, mosi};
                rx_flag <= ~rx_flag;
            end
        end
    end

    logic [2:0] rx_flag_sync;  // 2FF + edge-detect stage
    always_ff @(posedge clk) begin
        if (reset) begin
            rx_flag_sync <= '0;
            rx_valid     <= 1'b0;
            rx_data      <= '0;
        end else begin
            rx_flag_sync <= {rx_flag_sync[1:0], rx_flag};
            rx_valid     <= 1'b0;
            if (rx_flag_sync[2] != rx_flag_sync[1]) begin
                rx_data  <= rx_hold;
                rx_valid <= 1'b1;
            end
        end
    end

    logic        fifo_full, fifo_empty;
    logic signed [7:0] fifo_head;
    logic signed [7:0] fifo_wr_data;
    logic        fifo_pop;
    assign fifo_wr_data = signed'(tx_data);

    fifo #(.WIDTH(8), .DEPTH(16)) u_tx_fifo (
        .clk          (clk),
        .reset        (reset),
        .write_enable (tx_valid && !fifo_full),
        .write_data   (fifo_wr_data),
        .read_enable  (fifo_pop),
        .read_data    (fifo_head),
        .full         (fifo_full),
        .empty        (fifo_empty)
    );
    assign tx_busy = fifo_full;

    logic [1:0] sck_sync, csn_sync;
    logic       sck_prev, csn_prev;
    always_ff @(posedge clk) begin
        if (reset) begin
            sck_sync <= '0;
            csn_sync <= 2'b11;
            sck_prev <= 1'b0;
            csn_prev <= 1'b1;
        end else begin
            sck_sync <= {sck_sync[0], sck};
            csn_sync <= {csn_sync[0], csn};
            sck_prev <= sck_sync[1];
            csn_prev <= csn_sync[1];
        end
    end
    wire cs_active     = !csn_sync[1];
    wire cs_fall       = csn_prev && !csn_sync[1];
    wire sck_fall_sync = cs_active && sck_prev && !sck_sync[1];

    logic [7:0] tx_shift;
    logic [2:0] tx_bit;

    assign miso = tx_shift[7];

    always_ff @(posedge clk) begin
        if (reset) begin
            tx_shift <= IDLE_BYTE;
            tx_bit   <= '0;
            fifo_pop <= 1'b0;
        end else begin
            fifo_pop <= 1'b0;
            if (cs_fall) begin
                tx_bit <= '0;
                if (!fifo_empty) begin
                    tx_shift <= 8'(fifo_head);
                    fifo_pop <= 1'b1;
                end else begin
                    tx_shift <= IDLE_BYTE;
                end
            end else if (sck_fall_sync) begin
                if (tx_bit == 3'd7) begin
                    tx_bit <= '0;
                    if (!fifo_empty) begin
                        tx_shift <= 8'(fifo_head);
                        fifo_pop <= 1'b1;
                    end else begin
                        tx_shift <= IDLE_BYTE;
                    end
                end else begin
                    tx_shift <= {tx_shift[6:0], 1'b0};
                    tx_bit   <= tx_bit + 3'd1;
                end
            end
        end
    end

endmodule
