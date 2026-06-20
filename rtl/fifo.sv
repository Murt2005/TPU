`timescale 1ns / 1ps

// Generic circular-queue FIFO.
// No awareness of the MMU, PSums, weights, or rows -- pure storage primitive.
// Reusable anywhere a simple synchronous FIFO is needed (weight loading,
// accumulator column buffers, unified_buffer, etc).
module fifo #(
    parameter int WIDTH = 16,
    parameter int DEPTH = 4                       // must be a power of 2
) (
    input  logic                   clk,
    input  logic                   reset,

    input  logic                   write_enable,
    input  logic signed [WIDTH-1:0] write_data,

    input  logic                   read_enable,
    output logic signed [WIDTH-1:0] read_data,

    output logic                   full,
    output logic                   empty
);

    localparam int PTR_WIDTH = $clog2(DEPTH);

    logic signed [WIDTH-1:0] mem [DEPTH];

    logic [PTR_WIDTH-1:0] write_ptr, read_ptr;
    logic [PTR_WIDTH:0]   count;

    assign full  = (count == DEPTH);
    assign empty = (count == 0);

    assign read_data = mem[read_ptr];

    always_ff @(posedge clk) begin
        if (reset) begin
            write_ptr <= '0;
            read_ptr <= '0;
            count  <= '0;
        end else begin
            // Write
            if (write_enable && !full) begin
                mem[write_ptr] <= write_data;
                write_ptr      <= write_ptr + 1'b1;
            end

            // Read
            if (read_enable && !empty) begin
                read_ptr <= read_ptr + 1'b1;
            end

            // Count update -- handles simultaneous read+write correctly
            case ({(write_enable && !full), (read_enable && !empty)})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count; // 00: no change, 11: simultaneous r/w nets to no change
            endcase
        end
    end

endmodule
