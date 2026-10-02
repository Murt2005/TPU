`timescale 1ns / 1ps

// show-ahead FIFO on block RAM (registered read). the RAM is read every cycle at the
// next head, so an entry shows two cycles after its write: by then the read never
// meets a write to the same address in the same cycle. full counts every write at once
module block_fifo #(
    parameter int WIDTH = 128,
    parameter int DEPTH = 256   // must be a power of 2
) (
    input  logic             clk,
    input  logic             reset,

    input  logic             write_enable_in,
    input  logic [WIDTH-1:0] write_data_in,

    input  logic             read_enable_in,
    output logic [WIDTH-1:0] read_data_out,

    output logic             full_out,
    output logic             empty_out
);

    localparam int POINTER_WIDTH = $clog2(DEPTH);

    initial
        assert ((1 << POINTER_WIDTH) == DEPTH)
        else $fatal(1, "block_fifo: DEPTH=%0d is not a power of 2", DEPTH);

    logic [WIDTH-1:0]         memory [DEPTH];
    logic [POINTER_WIDTH-1:0] write_pointer, read_pointer, next_read_pointer;
    logic [POINTER_WIDTH:0]   stored, visible;
    logic                     written, popping, pushing;

    assign pushing           = write_enable_in && !full_out;
    assign popping           = read_enable_in && !empty_out;
    assign next_read_pointer = read_pointer + POINTER_WIDTH'(popping);
    assign full_out          = stored == (POINTER_WIDTH+1)'(DEPTH);
    assign empty_out         = visible == 0;

    always_ff @(posedge clk) begin
        if (pushing) memory[write_pointer] <= write_data_in;
        read_data_out <= memory[next_read_pointer];
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            write_pointer <= '0;
            read_pointer  <= '0;
            stored        <= '0;
            visible       <= '0;
            written       <= 1'b0;
        end else begin
            written       <= pushing;
            write_pointer <= write_pointer + POINTER_WIDTH'(pushing);
            read_pointer  <= next_read_pointer;
            stored        <= stored + (POINTER_WIDTH+1)'(pushing) - (POINTER_WIDTH+1)'(popping);
            visible       <= visible + (POINTER_WIDTH+1)'(written) - (POINTER_WIDTH+1)'(popping);
        end
    end

endmodule
