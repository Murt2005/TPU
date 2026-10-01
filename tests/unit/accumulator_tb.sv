`timescale 1ns / 1ps

// accumulator: column-skewed partial sums are re-aligned into rows and written to, or
// added into, the ACC row their tag names; ACT reads through the same port
module accumulator_tb;
    `include "check.svh"

    localparam int N = 4, D = 16, AW = $clog2(D);
    logic clk = 1'b0, reset = 1'b1;
    logic signed [N-1:0][31:0] psum = '0;
    logic        [N-1:0]       psum_valid = '0;
    logic                      tag_push = 1'b0, row_written, act_busy;
    logic [AW:0]               tag_in = '0;
    logic [AW-1:0]             act_raddr = '0;
    logic [N*32-1:0]           rdata;

    accumulator #(.N(N), .ACC_DEPTH(D)) dut (.*);

    always #5 clk = ~clk;
    task automatic tick(); @(posedge clk); #1; endtask

    int written = 0, busy_cycles = 0;
    always @(posedge clk) begin
        if (row_written) written++;
        if (act_busy) busy_cycles++;
    end

    // rows arrive the way the mmu emits them: column c of row k at cycle k + c
    task automatic send(input int n, input int addr [], input logic ow [], input int vals [][N]);
        for (int cyc = 0; cyc < n + N; cyc++) begin
            tag_push = cyc < n;
            tag_in   = cyc < n ? {ow[cyc], AW'(addr[cyc])} : '0;
            for (int c = 0; c < N; c++) begin
                int k = cyc - c;
                psum_valid[c] = k >= 0 && k < n;
                psum[c]       = (k >= 0 && k < n) ? vals[k][c] : 0;
            end
            tick();
        end
        tag_push = 1'b0; psum_valid = '0;
        repeat (4) tick();
    endtask

    task automatic expect_row(int addr, int want [N], string what);
        act_raddr = AW'(addr); tick();
        for (int c = 0; c < N; c++)
            `CHECK_EQ(rdata[32*c +: 32], 32'(want[c]), $sformatf("%s, ACC[%0d] col %0d", what, addr, c))
    endtask

    int addr [];
    logic ow [];
    int vals [][N];

    initial begin
        tick(); tick(); reset = 1'b0;

        `TEST("overwrite: three skewed rows land whole, and MM never reads")
        addr = '{2, 3, 4}; ow = '{1, 1, 1};
        vals = '{'{1, 2, 3, 4}, '{-5, 6, -7, 8}, '{32'h7fffffff, 0, -1, 100}};
        written = 0; busy_cycles = 0;
        send(3, addr, ow, vals);
        `CHECK_EQ(written, 3, "rows written")
        `CHECK_EQ(busy_cycles, 0, "no ACC reads for overwrites")
        for (int k = 0; k < 3; k++) expect_row(addr[k], vals[k], "overwrite");

        `TEST("accumulate: read-modify-write, 32-bit wrap")
        ow = '{0, 0, 0};
        vals = '{'{10, 20, 30, 40}, '{5, -6, 7, -8}, '{1, 0, 1, -100}};
        written = 0; busy_cycles = 0;
        send(3, addr, ow, vals);
        `CHECK_EQ(written, 3, "rows written")
        `CHECK_EQ(busy_cycles, 3, "one ACC read per accumulated row")
        expect_row(2, '{11, 22, 33, 44}, "accumulate");
        expect_row(3, '{0, 0, 0, 0}, "accumulate to zero");
        expect_row(4, '{32'h80000000, 0, 0, 0}, "wraps");

        `TEST("the same row again N rows later sees the first write")
        addr = '{5, 6, 7, 8, 5}; ow = '{1, 1, 1, 1, 0};
        vals = '{'{1, 1, 1, 1}, '{0, 0, 0, 0}, '{0, 0, 0, 0}, '{0, 0, 0, 0}, '{2, 3, 4, 5}};
        send(5, addr, ow, vals);
        expect_row(5, '{3, 4, 5, 6}, "overwrite then add");

        tb_done();
    end
endmodule
