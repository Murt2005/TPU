`timescale 1ns / 1ps

// accumulators: the array's columns come out skewed by one cycle each, so per-column
// FIFOs re-align them into rows; each row carries a tag {overwrite, ACC row} pushed
// when its activations were issued, and is written (or added) into the ACC memory.
// ACT reads ACC through the same port; MM has priority
module accumulator #(
    parameter int N         = 8,
    parameter int ACC_DEPTH = 1024,
    parameter int ACC_AW    = $clog2(ACC_DEPTH)
) (
    input  logic                      clk,
    input  logic                      reset,

    input  logic signed [N-1:0][31:0] psum,
    input  logic        [N-1:0]       psum_valid,

    input  logic                      tag_push,
    input  logic [ACC_AW:0]           tag_in,        // {overwrite, acc_row}
    output logic                      row_written,   // a row reaches ACC this cycle

    input  logic [ACC_AW-1:0]         act_raddr,
    output logic                      act_busy,      // MM owns the read port this cycle
    output logic [N*32-1:0]           rdata          // one cycle after the address
);

    localparam int SKEW_DEPTH = (2 * N <= 4) ? 4 : (2 * N <= 8) ? 8 : (2 * N <= 16) ? 16 : (2 * N <= 32) ? 32 : 64;
    localparam int TAG_DEPTH  = 64;

    logic [N-1:0]              col_empty;
    logic signed [N-1:0][31:0] col_head;
    logic                      row_pop;

    genvar gc;
    generate
        for (gc = 0; gc < N; gc++) begin : g_col
            fifo #(.WIDTH(32), .DEPTH(SKEW_DEPTH)) u_col (
                .clk(clk), .reset(reset),
                .write_enable(psum_valid[gc]), .write_data(psum[gc]),
                .read_enable(row_pop), .read_data(col_head[gc]),
                .full(), .empty(col_empty[gc])
            );
        end
    endgenerate

    logic            tag_empty;
    logic [ACC_AW:0] tag_head;

    fifo #(.WIDTH(ACC_AW + 1), .DEPTH(TAG_DEPTH)) u_tags (
        .clk(clk), .reset(reset),
        .write_enable(tag_push), .write_data(tag_in),
        .read_enable(row_pop), .read_data(tag_head),
        .full(), .empty(tag_empty)
    );

    assign row_pop = (col_empty == '0) && !tag_empty;

    // read-modify-write: read at pop, add and write back the next cycle. the same
    // ACC row comes round again at most once per window (>= N >= 2 cycles), so
    // the write always lands before the next read
    logic                  mm_re;
    logic [ACC_AW-1:0]     mm_raddr;
    logic                  s1_valid, s1_ow;
    logic [ACC_AW-1:0]     s1_addr;
    logic [N*32-1:0]       s1_psum;
    logic [N*32-1:0]       wdata;

    assign mm_re       = row_pop && !tag_head[ACC_AW];
    assign mm_raddr    = tag_head[ACC_AW-1:0];
    assign act_busy    = mm_re;
    assign row_written = s1_valid;
    always_comb
        for (int c = 0; c < N; c++)
            wdata[32*c +: 32] = s1_ow ? s1_psum[32*c +: 32] : rdata[32*c +: 32] + s1_psum[32*c +: 32];

    always_ff @(posedge clk) begin
        if (reset) begin
            s1_valid <= 1'b0;
            s1_ow    <= 1'b0;
            s1_addr  <= '0;
            s1_psum  <= '0;
        end else begin
            s1_valid <= row_pop;
            s1_ow    <= tag_head[ACC_AW];
            s1_addr  <= tag_head[ACC_AW-1:0];
            s1_psum  <= col_head;
        end
    end

    // the ACC memory: registered read, so it maps to block RAM
    logic [N*32-1:0] acc [ACC_DEPTH];
    always_ff @(posedge clk) begin
        if (s1_valid) acc[s1_addr] <= wdata;
        rdata <= acc[mm_re ? mm_raddr : act_raddr];
    end

endmodule
