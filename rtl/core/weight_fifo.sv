`timescale 1ns / 1ps

// weight FIFO: ping-pong banks, the shadow loads while the active drains
module weight_fifo #(
    parameter int WEIGHT_WIDTH = 8,
    parameter int FIFO_DEPTH   = 4,  // must be a power of 2 & >= array dimension (N)
    parameter int NUM_COLS     = 2
) (
    input  logic clk,
    input  logic reset,

    input  logic                                          [NUM_COLS-1:0] write_enable_col,
    input  logic signed [NUM_COLS-1:0][WEIGHT_WIDTH-1:0]                 write_data_col,

    input  logic         swap_banks,

    output logic          shadow_loaded,
    output logic          active_bank,

    input  logic loading_phase,

    output logic signed [NUM_COLS-1:0][WEIGHT_WIDTH-1:0] out_col,
    output logic                      [NUM_COLS-1:0]      out_col_valid,

    output logic active_empty,
    output logic active_full,
    output logic any_shadow_full
);

    logic active_bank_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            active_bank_q <= 1'b0;
        end else if (swap_banks) begin
            active_bank_q <= ~active_bank_q;
        end
    end

    assign active_bank = active_bank_q;

    logic shadow_bank_q;
    assign shadow_bank_q = ~active_bank_q;

    logic                           bank_write_enable [2][NUM_COLS]; // [bank][col]
    logic signed [WEIGHT_WIDTH-1:0] bank_write_data   [2][NUM_COLS];
    logic                           bank_read_enable  [2][NUM_COLS];
    logic signed [WEIGHT_WIDTH-1:0] bank_read_data    [2][NUM_COLS];
    logic                           bank_full         [2][NUM_COLS];
    logic                           bank_empty        [2][NUM_COLS];

    genvar b, c;
    generate
        for (b = 0; b < 2; b++) begin : gen_bank
            for (c = 0; c < NUM_COLS; c++) begin : gen_col
                fifo #(
                    .WIDTH(WEIGHT_WIDTH),
                    .DEPTH(FIFO_DEPTH)
                ) u_fifo (
                    .clk          (clk),
                    .reset        (reset),
                    .write_enable (bank_write_enable[b][c]),
                    .write_data   (bank_write_data[b][c]),
                    .read_enable  (bank_read_enable[b][c]),
                    .read_data    (bank_read_data[b][c]),
                    .full         (bank_full[b][c]),
                    .empty        (bank_empty[b][c])
                );
            end
        end
    endgenerate

    always_comb begin
        for (int bi = 0; bi < 2; bi++) begin
            for (int ci = 0; ci < NUM_COLS; ci++) begin
                bank_write_enable[bi][ci] = 1'b0;
                bank_write_data[bi][ci]   = '0;
            end
        end
        for (int ci = 0; ci < NUM_COLS; ci++) begin
            bank_write_enable[shadow_bank_q][ci] = write_enable_col[ci];
            bank_write_data[shadow_bank_q][ci]   = write_data_col[ci];
        end
    end

    logic [NUM_COLS-1:0] pop_col;

    always_comb begin
        for (int ci = 0; ci < NUM_COLS; ci++) begin
            pop_col[ci] = loading_phase && !bank_empty[active_bank_q][ci];
        end
    end

    always_comb begin
        for (int bi = 0; bi < 2; bi++) begin
            for (int ci = 0; ci < NUM_COLS; ci++) begin
                bank_read_enable[bi][ci] = 1'b0;
            end
        end
        for (int ci = 0; ci < NUM_COLS; ci++) begin
            bank_read_enable[active_bank_q][ci] = pop_col[ci];
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            for (int ci = 0; ci < NUM_COLS; ci++) begin
                out_col[ci]       <= '0;
                out_col_valid[ci] <= 1'b0;
            end
        end else begin
            for (int ci = 0; ci < NUM_COLS; ci++) begin
                out_col[ci]       <= pop_col[ci] ? bank_read_data[active_bank_q][ci] : '0;
                out_col_valid[ci] <= pop_col[ci];
            end
        end
    end

    always_comb begin
        active_empty    = 1'b1;
        active_full     = 1'b0;
        any_shadow_full = 1'b0;
        shadow_loaded   = 1'b1;
        for (int ci = 0; ci < NUM_COLS; ci++) begin
            active_empty    &= bank_empty[active_bank_q][ci];
            active_full     |= bank_full[active_bank_q][ci];
            any_shadow_full |= bank_full[shadow_bank_q][ci];
            shadow_loaded   &= !bank_empty[shadow_bank_q][ci];
        end
    end

endmodule
