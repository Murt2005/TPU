`timescale 1ns / 1ps

// generic circular-queue FIFO. 4 Kbit or less goes in MLABs (LUT RAM, 640 bits each):
// an M10K block is 10 Kbit, and the engine queues and column FIFOs filled theirs 1-7%
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

    localparam bit SMALL = WIDTH * DEPTH <= 4096;

    logic [POINTER_WIDTH-1:0] write_pointer;
    logic [POINTER_WIDTH-1:0] read_pointer;
    logic [POINTER_WIDTH:0]   data_count;

    assign full_out  = (data_count == (POINTER_WIDTH+1)'(DEPTH));
    assign empty_out = (data_count == 0);

    logic write_now;
    assign write_now = write_enable_in && !full_out;

    generate
        if (SMALL) begin : g_mlab
            (* ramstyle = "MLAB, no_rw_check" *) logic signed [WIDTH-1:0] memory [DEPTH];
            always_ff @(posedge clk) if (write_now) memory[write_pointer] <= write_data_in;
            assign read_data_out = memory[read_pointer];
        end else begin : g_block
            logic signed [WIDTH-1:0] memory [DEPTH];
            always_ff @(posedge clk) if (write_now) memory[write_pointer] <= write_data_in;
            assign read_data_out = memory[read_pointer];
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (reset) begin
            write_pointer <= '0;
            read_pointer  <= '0;
            data_count    <= '0;
        end else begin
            if (write_now)
                write_pointer <= write_pointer + 1'b1;

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
