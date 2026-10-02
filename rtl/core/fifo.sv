`timescale 1ns / 1ps

// generic circular-queue FIFO
module fifo #(
    parameter int WIDTH = 16,
    parameter int DEPTH = 4   // must be a power of 2
) (
    input  logic                    clk,
    input  logic                    reset,

    input  logic                    write_enable_in,
    input  logic signed [WIDTH-1:0] write_data_in,

    input  logic                    read_enable_in,
    output logic signed [WIDTH-1:0] read_data_out,

    output logic                    full_out,
    output logic                    empty_out
);

    localparam int POINTER_WIDTH = $clog2(DEPTH);

    initial
        assert ((1 << POINTER_WIDTH) == DEPTH)
        else $fatal(1, "fifo: DEPTH=%0d is not a power of 2 (wraps at %0d)", DEPTH, (1 << POINTER_WIDTH));

    logic signed [WIDTH-1:0] memory [DEPTH];

    logic [POINTER_WIDTH-1:0] write_pointer;
    logic [POINTER_WIDTH-1:0] read_pointer;
    logic [POINTER_WIDTH:0]   data_count;

    assign full_out  = (data_count == (POINTER_WIDTH+1)'(DEPTH));
    assign empty_out = (data_count == 0);

    // check later if this should be changed to memory[read_pointer] && read_enable_in
    assign read_data_out = memory[read_pointer];

    always_ff @(posedge clk) begin
        if (reset) begin
            write_pointer <= '0;
            read_pointer  <= '0;
            data_count    <= '0;
        end else begin
            if (write_enable_in && !full_out) begin
                memory[write_pointer] <= write_data_in;
                write_pointer         <= write_pointer + 1'b1;
            end

            if (read_enable_in && !empty_out) begin
                read_pointer <= read_pointer + 1'b1;
            end

            case ({(write_enable_in && !full_out), (read_enable_in && !empty_out)})
                2'b10:   data_count <= data_count + 1'b1;
                2'b01:   data_count <= data_count - 1'b1;
                default: data_count <= data_count;
            endcase
        end
    end

endmodule
