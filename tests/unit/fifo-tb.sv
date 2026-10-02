`timescale 1ns / 1ps

// fifo: show-ahead order, full/empty, ignored write-when-full and read-when-empty,
// simultaneous read and write, wrap-around
module fifo_tb;
    `include "check.svh"

    logic clk = 1'b0, reset = 1'b1;
    logic               write_enable_in = 1'b0, read_enable_in = 1'b0;
    logic signed [15:0] write_data_in = '0, read_data_out;
    logic               full_out, empty_out;

    fifo #(.WIDTH(16), .DEPTH(4)) dut (.*);

    always #5 clk = ~clk;
    task automatic tick(); @(posedge clk); #1; endtask

    initial begin
        tick(); tick(); reset = 1'b0;

        `TEST("empty after reset")
        `CHECK(empty_out && !full_out, "flags")

        `TEST("fills in order, a write when full is ignored")
        write_enable_in = 1'b1;
        for (int i = 0; i < 5; i++) begin
            write_data_in = 16'(100 + i);
            tick();
        end
        write_enable_in = 1'b0;
        `CHECK(full_out && !empty_out, "full after 4")

        `TEST("show-ahead reads in order")
        for (int i = 0; i < 4; i++) begin
            `CHECK_EQ(read_data_out, 16'(100 + i), $sformatf("item %0d", i))
            read_enable_in = 1'b1; tick(); read_enable_in = 1'b0;
        end
        `CHECK(empty_out && !full_out, "empty after 4 reads")

        `TEST("a read when empty is ignored")
        read_enable_in = 1'b1; tick(); read_enable_in = 1'b0;
        `CHECK(empty_out, "still empty")
        write_enable_in = 1'b1; write_data_in = 16'sd7; tick(); write_enable_in = 1'b0;
        `CHECK_EQ(read_data_out, 16'sd7, "the next write is the head")

        `TEST("simultaneous read and write keep the count, wrap around")
        for (int i = 0; i < 10; i++) begin
            `CHECK_EQ(read_data_out, i == 0 ? 16'sd7 : 16'(200 + i - 1), $sformatf("head %0d", i))
            write_enable_in = 1'b1; read_enable_in = 1'b1; write_data_in = 16'(200 + i);
            tick();
            `CHECK(!empty_out && !full_out, "one item in flight")
        end
        write_enable_in = 1'b0; read_enable_in = 1'b0;

        `TEST("negative values survive")
        read_enable_in = 1'b1; tick(); read_enable_in = 1'b0;
        write_enable_in = 1'b1; write_data_in = -16'sd32768; tick(); write_enable_in = 1'b0;
        `CHECK_EQ(read_data_out, -16'sd32768, "most negative")

        tb_done();
    end
endmodule
