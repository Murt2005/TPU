`timescale 1ns / 1ps

// mmu: back-to-back tiles on the overlap schedule mm_engine uses (each tile's m rows
// at the start of a max(m, N) window, the next tile's weight rows in its last N
// cycles), every output column against a plain matmul
module mmu_tb;
    `include "check.svh"

    localparam int N = 4, T = 3, MMAX = 2 * N + 1;
    logic clk = 1'b0, reset = 1'b1;

    logic signed [N-1:0][8:0] sds_in = '0, skewed;
    logic        [N-1:0]      skewed_valid;
    logic                     sds_valid = 1'b0;
    logic signed [N-1:0][7:0] activation;
    logic        [N-1:0]      activation_first;
    logic                     weight_valid = 1'b0;
    logic [$clog2(N)-1:0]     weight_row = '0;
    logic signed [N-1:0][7:0] weight_data = '0;
    logic signed [N-1:0][31:0] partial_sum;
    logic        [N-1:0]       partial_sum_valid;

    systolic_data_setup #(.ARRAY_ROWS(N), .DATA_WIDTH(9)) u_sds (
        .clk(clk), .reset(reset), .UB_read_data(sds_in), .UB_read_valid(sds_valid),
        .MMU_in_row(skewed), .MMU_in_valid(skewed_valid));
    always_comb
        for (int r = 0; r < N; r++) begin
            activation[r]       = skewed[r][7:0];
            activation_first[r] = skewed[r][8];
        end

    mmu #(.ARRAY_SIZE(N)) dut (
        .clk(clk), .reset(reset), .activation(activation), .activation_first(activation_first), .activation_valid(skewed_valid),
        .weight_valid(weight_valid), .weight_row(weight_row), .weight_data(weight_data), .partial_sum(partial_sum), .partial_sum_valid(partial_sum_valid));

    always #5 clk = ~clk;
    task automatic tick(); @(posedge clk); #1; endtask

    int got [N][$];
    always @(posedge clk)
        for (int c = 0; c < N; c++)
            if (partial_sum_valid[c]) got[c].push_back(partial_sum[c]);

    logic signed [7:0] W [T][N][N];     // [tile][K row][column]
    logic signed [7:0] A [T][MMAX][N];  // [tile][activation row][K]

    function automatic logic signed [7:0] rnd8(); return 8'($urandom); endfunction

    task automatic run(int m);
        reset = 1'b1; tick(); tick(); reset = 1'b0;
        for (int c = 0; c < N; c++) got[c].delete();
        for (int t = 0; t < T; t++) begin
            for (int r = 0; r < N; r++) for (int c = 0; c < N; c++) W[t][r][c] = rnd8();
            for (int i = 0; i < m; i++) for (int r = 0; r < N; r++) A[t][i][r] = rnd8();
        end
        W[0][0][0] = -8'sd128; A[0][0][0] = -8'sd128;     // the extremes, once
        // window w streams tile w-1's rows and loads tile w's weights
        for (int w = 0; w <= T; w++) begin
            int len;
            len = (w > 0 && m > N) ? m : (w < T ? N : m);
            for (int pos = 0; pos < len; pos++) begin
                logic acts, wts;
                acts = w > 0 && pos < m;
                wts  = w < T && pos >= len - N;
                sds_valid = acts;
                for (int r = 0; r < N; r++)
                    sds_in[r] = acts ? {1'(pos == 0), A[w-1][pos][r]} : '0;
                weight_valid = wts;
                weight_row   = wts ? $clog2(N)'(pos - (len - N)) : '0;
                for (int c = 0; c < N; c++) weight_data[c] = wts ? W[w][pos - (len - N)][c] : 8'sd0;
                tick();
            end
        end
        sds_valid = 1'b0; weight_valid = 1'b0;
        repeat (3 * N) tick();
        for (int c = 0; c < N; c++) begin
            `CHECK_EQ(got[c].size(), T * m, $sformatf("column %0d row count", c))
            for (int t = 0; t < T; t++)
                for (int i = 0; i < m; i++) begin
                    int want = 0;
                    for (int r = 0; r < N; r++) want += int'(A[t][i][r]) * int'(W[t][r][c]);
                    if (got[c].size() > t * m + i)
                        `CHECK_EQ(got[c][t * m + i], want, $sformatf("m=%0d tile %0d row %0d col %0d", m, t, i, c))
                end
        end
    endtask

    initial begin
        void'($urandom(32'd2026));
        `TEST("m = 1: one row per tile, windows of N cycles")
        run(1);
        `TEST("m = N: the array fed every cycle")
        run(N);
        `TEST("m = 2N + 1: windows longer than N")
        run(2 * N + 1);
        tb_done();
    end
endmodule
