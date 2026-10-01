`timescale 1ns / 1ps

// N x N grid of isa_pe. activations enter row r at column 0 already skewed by r;
// the row-select weight bus is skewed here, column c by c cycles, so a tile's
// weight row lands in each column exactly as far ahead of its flip
module isa_array #(
    parameter int N = 8
) (
    input  logic                      clk,
    input  logic                      reset,

    input  logic signed [N-1:0][7:0]  act,
    input  logic        [N-1:0]       act_first,
    input  logic        [N-1:0]       act_valid,

    input  logic                      wvalid,
    input  logic [$clog2(N)-1:0]      wrow,
    input  logic signed [N-1:0][7:0]  wdata,

    output logic signed [N-1:0][31:0] psum,
    output logic        [N-1:0]       psum_valid
);

    localparam int RW = $clog2(N);

    // per-column weight bus after the column skew
    logic              cw_valid [N];
    logic [RW-1:0]     cw_row   [N];
    logic signed [7:0] cw_data  [N];

    genvar r, c;
    generate
        for (c = 0; c < N; c++) begin : g_wskew
            if (c == 0) begin : g_direct
                assign cw_valid[c] = wvalid;
                assign cw_row[c]   = wrow;
                assign cw_data[c]  = wdata[c];
            end else begin : g_delay
                logic              dv [c];
                logic [RW-1:0]     dr [c];
                logic signed [7:0] dd [c];
                always_ff @(posedge clk) begin
                    if (reset) begin
                        for (int i = 0; i < c; i++) dv[i] <= 1'b0;
                    end else begin
                        dv[0] <= wvalid;
                        for (int i = 1; i < c; i++) dv[i] <= dv[i-1];
                    end
                    dr[0] <= wrow;
                    dd[0] <= wdata[c];
                    for (int i = 1; i < c; i++) begin
                        dr[i] <= dr[i-1];
                        dd[i] <= dd[i-1];
                    end
                end
                assign cw_valid[c] = dv[c-1];
                assign cw_row[c]   = dr[c-1];
                assign cw_data[c]  = dd[c-1];
            end
        end

        for (r = 0; r < N; r++) begin : g_row
            logic signed [7:0]  a  [N+1];
            logic               f  [N+1];
            logic               v  [N+1];
            assign a[0] = act[r];
            assign f[0] = act_first[r];
            assign v[0] = act_valid[r];
            for (c = 0; c < N; c++) begin : g_col
                logic signed [31:0] p;
                logic               pv;
                logic signed [31:0] pin;
                if (r == 0) begin : g_top
                    assign pin = '0;
                end else begin : g_mid
                    assign pin = g_row[r-1].g_col[c].p;
                end
                isa_pe u_pe (
                    .clk(clk), .reset(reset),
                    .act_in(a[c]), .first_in(f[c]), .act_valid_in(v[c]), .psum_in(pin),
                    .wsel(cw_valid[c] && cw_row[c] == RW'(r)), .wdata(cw_data[c]),
                    .act_out(a[c+1]), .first_out(f[c+1]), .act_valid_out(v[c+1]),
                    .psum_out(p), .psum_valid(pv));
                if (r == N - 1) begin : g_out
                    assign psum[c]       = p;
                    assign psum_valid[c] = pv;
                end
            end
        end
    endgenerate

endmodule
