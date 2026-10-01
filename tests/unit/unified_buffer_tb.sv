`timescale 1ns / 1ps

// unified_buffer: one-cycle reads; ACT's write wins the write port over LD's, MM's
// read wins the read port over ACT's
module unified_buffer_tb;
    `include "check.svh"

    localparam int N = 4, D = 16, AW = $clog2(D);
    logic clk = 1'b0;
    logic ld_we = 1'b0, act_we = 1'b0, mm_re = 1'b0;
    logic [AW-1:0] ld_waddr = '0, act_waddr = '0, mm_raddr = '0, act_raddr = '0;
    logic [N*8-1:0] ld_wdata = '0, act_wdata = '0, rdata;

    unified_buffer #(.N(N), .DEPTH(D)) dut (.*);

    always #5 clk = ~clk;
    task automatic tick(); @(posedge clk); #1; endtask

    task automatic read_act(int a); act_raddr = AW'(a); mm_re = 1'b0; tick(); endtask

    initial begin
        tick();

        `TEST("LD writes, read one cycle later")
        ld_we = 1'b1; ld_waddr = 4'd3; ld_wdata = 32'h11223344; tick(); ld_we = 1'b0;
        read_act(3);
        `CHECK_EQ(rdata, 32'h11223344, "entry 3")

        `TEST("ACT's write wins the write port")
        ld_we = 1'b1; ld_waddr = 4'd5; ld_wdata = 32'hAAAAAAAA;
        act_we = 1'b1; act_waddr = 4'd6; act_wdata = 32'hBBBBBBBB;
        tick(); ld_we = 1'b0; act_we = 1'b0;
        read_act(6);
        `CHECK_EQ(rdata, 32'hBBBBBBBB, "ACT's entry written")
        read_act(5);
        `CHECK(rdata !== 32'hAAAAAAAA, "LD's write that cycle is dropped (the LD engine holds it)")

        `TEST("MM's read wins the read port")
        act_raddr = 4'd6; mm_re = 1'b1; mm_raddr = 4'd3; tick(); mm_re = 1'b0;
        `CHECK_EQ(rdata, 32'h11223344, "MM's address read")

        tb_done();
    end
endmodule
