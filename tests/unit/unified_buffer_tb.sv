`timescale 1ns / 1ps

// unified_buffer: one-cycle reads; ACT's write wins the write port over LD's, MM's
// read wins the read port over ACT's
module unified_buffer_tb;
    `include "check.svh"

    localparam int N = 4, D = 16, AW = $clog2(D);
    logic clk = 1'b0;
    logic           load_write_enable_in = 1'b0, activate_write_enable_in = 1'b0, matmul_read_enable_in = 1'b0;
    logic [AW-1:0]  load_write_address_in = '0, activate_write_address_in = '0, matmul_read_address_in = '0, activate_read_address_in = '0;
    logic [N*8-1:0] load_write_data_in = '0, activate_write_data_in = '0, read_data_out;

    unified_buffer #(.ARRAY_SIZE(N), .DEPTH(D)) dut (.*);

    always #5 clk = ~clk;
    task automatic tick(); @(posedge clk); #1; endtask

    task automatic read_act(int a); activate_read_address_in = AW'(a); matmul_read_enable_in = 1'b0; tick(); endtask

    initial begin
        tick();

        `TEST("LD writes, read one cycle later")
        load_write_enable_in = 1'b1; load_write_address_in = 4'd3; load_write_data_in = 32'h11223344; tick(); load_write_enable_in = 1'b0;
        read_act(3);
        `CHECK_EQ(read_data_out, 32'h11223344, "entry 3")

        `TEST("ACT's write wins the write port")
        load_write_enable_in = 1'b1; load_write_address_in = 4'd5; load_write_data_in = 32'hAAAAAAAA;
        activate_write_enable_in = 1'b1; activate_write_address_in = 4'd6; activate_write_data_in = 32'hBBBBBBBB;
        tick(); load_write_enable_in = 1'b0; activate_write_enable_in = 1'b0;
        read_act(6);
        `CHECK_EQ(read_data_out, 32'hBBBBBBBB, "ACT's entry written")
        read_act(5);
        `CHECK(read_data_out !== 32'hAAAAAAAA, "LD's write that cycle is dropped (the LD engine holds it)")

        `TEST("MM's read wins the read port")
        activate_read_address_in = 4'd6; matmul_read_enable_in = 1'b1; matmul_read_address_in = 4'd3; tick(); matmul_read_enable_in = 1'b0;
        `CHECK_EQ(read_data_out, 32'h11223344, "MM's address read")

        tb_done();
    end
endmodule
