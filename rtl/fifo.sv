`timescale 1ns / 1ps

// Generic circular-queue FIFO.
// Has no awareness of the MMU, PSums, weights, or rows
// Reusable anywhere a simple synchronous FIFO is needed (weight loading,
// accumulator column buffers, unified_buffer, etc).
module fifo #(
    parameter int WIDTH = 16,
    parameter int DEPTH = 4  // must be a power of 2
) (
    input  logic                        clk,
    input  logic                        reset,

    input  logic                        write_enable,
    input  logic signed [WIDTH-1:0]     write_data,

    input  logic                        read_enable,
    output logic signed [WIDTH-1:0]     read_data,

    output logic                        full,
    output logic                        empty
);

    localparam int PTR_WIDTH = $clog2(DEPTH);

    // compile/simulation time assert that DEPTH is a power of 2
    initial begin
        assert ((1 << PTR_WIDTH) == DEPTH)
            else $fatal(1, "fifo: DEPTH=%0d is not a power of 2 ( wraps at %0d)",
                        DEPTH, (1 << PTR_WIDTH));
    end

    logic signed [WIDTH-1:0] memory [DEPTH];

    logic [PTR_WIDTH-1:0] write_ptr;
    logic [PTR_WIDTH-1:0] read_ptr;
    logic [PTR_WIDTH:0]   data_count;

    assign full  = (data_count == DEPTH);
    assign empty = (data_count == 0);

    assign read_data = memory[read_ptr];

    always_ff @(posedge clk) begin
        if (reset) begin
            write_ptr <= '0;
            read_ptr <= '0;
            data_count  <= '0;
        end else begin
            // Write
            if (write_enable && !full) begin
                memory[write_ptr] <= write_data;
                write_ptr      <= write_ptr + 1'b1;
            end

            // Read
            if (read_enable && !empty) begin
                read_ptr <= read_ptr + 1'b1;
            end

            // data_count update, handles simultaneous read+write correctly
            case ({(write_enable && !full), (read_enable && !empty)})
                2'b10:   data_count <= data_count + 1'b1;
                2'b01:   data_count <= data_count - 1'b1;
                default: data_count <= data_count; // 00: no change, 11: simultaneous r/w nets to no change
            endcase
        end
    end

endmodule
