`timescale 1ns / 1ps

// activation: ReLU/identity, and the requantizer against tpu.golden.requant's vectors
// (gen_requant.py), N lanes at a time with a different quant word per lane
module activation_tb;
    `include "check.svh"

    localparam int N = 4;
    logic clk = 1'b0, reset = 1'b1;
    logic [N*32-1:0] in_row = '0, out_row, mul_in = '0, quant_row = '0;
    logic relu = 1'b0, mul_en = 1'b0;
    logic [N*8-1:0] q_row;

    activation #(.N(N)) dut (.*);

    always #5 clk = ~clk;
    task automatic tick(); @(posedge clk); #1; endtask

    initial begin
        string path;
        int fd, n, nv = 0, bad = 0;
        logic [31:0] v [$], q [$];
        logic [7:0]  want [$];
        logic [31:0] a, b;
        logic [7:0]  c;

        tick(); tick(); reset = 1'b0;

        `TEST("ReLU zeroes negatives, identity doesn't")
        in_row = {-32'sd1, 32'sd0, 32'sd7, 32'h80000000};
        relu = 1'b1; #1;
        `CHECK_EQ(out_row, {32'sd0, 32'sd0, 32'sd7, 32'sd0}, "relu")
        relu = 1'b0; #1;
        `CHECK_EQ(out_row, in_row, "identity")

        `TEST("requantizer matches tpu.golden.requant")
        if (!$value$plusargs("vectors=%s", path)) $fatal(1, "pass +vectors=<file>");
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "can't open %s", path);
        while ($fscanf(fd, "%h %h %h", a, b, c) == 3) begin
            v.push_back(a); q.push_back(b); want.push_back(c);
        end
        $fclose(fd);
        `CHECK(v.size() > 1000, $sformatf("only %0d vectors", v.size()))
        for (int i = 0; i + N <= v.size(); i += N) begin
            for (int l = 0; l < N; l++) begin
                mul_in[32*l +: 32]    = v[i + l];
                quant_row[32*l +: 32] = q[i + l];
            end
            mul_en = 1'b1; tick(); mul_en = 1'b0;
            for (int l = 0; l < N; l++) begin
                nv++;
                if (q_row[8*l +: 8] !== want[i + l]) begin
                    bad++;
                    if (bad <= 5)
                        `CHECK_EQ(q_row[8*l +: 8], want[i + l], $sformatf("v=0x%h q=0x%h", v[i + l], q[i + l]))
                end
            end
        end
        `CHECK_EQ(bad, 0, $sformatf("mismatches out of %0d vectors", nv))

        tb_done();
    end
endmodule
