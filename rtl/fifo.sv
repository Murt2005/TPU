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

    input  logic                   wr_en,
    input  logic signed [WIDTH-1:0] wr_data,

    input  logic                   rd_en,
    output logic signed [WIDTH-1:0] rd_data,

    output logic                   full,
    output logic                   empty
);

    localparam int PTR_WIDTH = $clog2(DEPTH);

    logic signed [WIDTH-1:0] mem [DEPTH];

    logic [PTR_WIDTH-1:0] wr_ptr, rd_ptr;
    logic [PTR_WIDTH:0]   count;

    assign full  = (count == DEPTH);
    assign empty = (count == 0);

    assign rd_data = mem[rd_ptr];

    always_ff @(posedge clk) begin
        if (reset) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count  <= '0;
        end else begin
            // Write
            if (wr_en && !full) begin
                mem[wr_ptr] <= wr_data;
                wr_ptr      <= wr_ptr + 1'b1;
            end

            // Read
            if (rd_en && !empty) begin
                rd_ptr <= rd_ptr + 1'b1;
            end

            // Count update -- handles simultaneous read+write correctly
            case ({(wr_en && !full), (rd_en && !empty)})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count; // 00: no change, 11: simultaneous r/w nets to no change
            endcase
        end
    end

endmodule
