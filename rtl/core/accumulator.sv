`timescale 1ns / 1ps

// accumulators: the array's columns come out skewed by one cycle each, so per-column
// FIFOs re-align them into rows; each row carries a tag {overwrite, ACC row} pushed
// when its activations were issued, and is written (or added) into the ACC memory.
// ACT reads ACC through the same port; MM has priority
module accumulator #(
    parameter int ARRAY_SIZE        = 8,
    parameter int ACC_DEPTH         = 1024,
    parameter int ACC_ADDRESS_WIDTH = $clog2(ACC_DEPTH)
) (
    input  logic  clk,
    input  logic  reset,

    input  logic signed [ARRAY_SIZE-1:0][31:0] partial_sum,
    input  logic [ARRAY_SIZE-1:0]        partial_sum_valid,

    input  logic                         tag_push,
    input  logic [ACC_ADDRESS_WIDTH:0]   tag_in,                // {overwrite, acc_row}
    output logic                         row_written,           // a row reaches ACC this cycle

    input  logic [ACC_ADDRESS_WIDTH-1:0] activate_read_address,
    output logic                         activate_read_blocked, // MM owns the read port this cycle
    output logic [ARRAY_SIZE*32-1:0]     read_data              // one cycle after the address
);

    localparam int SKEW_DEPTH = (2 * ARRAY_SIZE <= 4) ? 4 : (2 * ARRAY_SIZE <= 8) ? 8 : (2 * ARRAY_SIZE <= 16) ? 16 : (2 * ARRAY_SIZE <= 32) ? 32 : 64;
    localparam int TAG_DEPTH  = 64;

    logic        [ARRAY_SIZE-1:0]        column_empty;
    logic signed [ARRAY_SIZE-1:0] [31:0] column_head;
    logic                                row_pop;

    genvar lane;
    generate
        for (lane = 0; lane < ARRAY_SIZE; lane++) begin : g_column
            fifo #(.WIDTH(32), .DEPTH(SKEW_DEPTH)) u_column (
                .clk(clk), .reset(reset),
                .write_enable(partial_sum_valid[lane]), .write_data(partial_sum[lane]),
                .read_enable(row_pop), .read_data(column_head[lane]),
                .full(), .empty(column_empty[lane])
            );
        end
    endgenerate

    logic                       tag_empty;
    logic [ACC_ADDRESS_WIDTH:0] tag_head;

    fifo #(.WIDTH(ACC_ADDRESS_WIDTH + 1), .DEPTH(TAG_DEPTH)) u_tags (
        .clk(clk), .reset(reset),
        .write_enable(tag_push), .write_data(tag_in),
        .read_enable(row_pop), .read_data(tag_head),
        .full(), .empty(tag_empty)
    );

    assign row_pop = (column_empty == '0) && !tag_empty;

    // read-modify-write: read at pop, add and write back the next cycle. the same
    // ACC row comes round again at most once per window (>= N >= 2 cycles), so
    // the write always lands before the next read
    logic                         matmul_read_enable;
    logic [ACC_ADDRESS_WIDTH-1:0] matmul_read_address;
    logic                         write_back_valid, write_back_overwrite;
    logic [ACC_ADDRESS_WIDTH-1:0] write_back_address;
    logic [ARRAY_SIZE*32-1:0]     write_back_partial_sum;
    logic [ARRAY_SIZE*32-1:0]     write_data;

    assign matmul_read_enable    = row_pop && !tag_head[ACC_ADDRESS_WIDTH];
    assign matmul_read_address   = tag_head[ACC_ADDRESS_WIDTH-1:0];
    assign activate_read_blocked = matmul_read_enable;
    assign row_written           = write_back_valid;
    always_comb
        for (int column = 0; column < ARRAY_SIZE; column++)
            write_data[32*column +: 32] = write_back_overwrite ? write_back_partial_sum[32*column +: 32] : read_data[32*column +: 32] + write_back_partial_sum[32*column +: 32];

    always_ff @(posedge clk) begin
        if (reset) begin
            write_back_valid       <= 1'b0;
            write_back_overwrite   <= 1'b0;
            write_back_address     <= '0;
            write_back_partial_sum <= '0;
        end else begin
            write_back_valid       <= row_pop;
            write_back_overwrite   <= tag_head[ACC_ADDRESS_WIDTH];
            write_back_address     <= tag_head[ACC_ADDRESS_WIDTH-1:0];
            write_back_partial_sum <= column_head;
        end
    end

    // the ACC memory: registered read, so it maps to block RAM
    logic [ARRAY_SIZE*32-1:0] memory [ACC_DEPTH];
    always_ff @(posedge clk) begin
        if (write_back_valid) memory[write_back_address] <= write_data;
        read_data <= memory[matmul_read_enable ? matmul_read_address : activate_read_address];
    end

endmodule
