`timescale 1ns / 1ps

// pe: w_next loads from the weight bus while w_cur computes; a valid activation with
// the flip bit computes with w_next and promotes it. psum = w * act + psum_in
module pe_tb;
    `include "check.svh"

    logic clk = 1'b0, reset = 1'b1;
    logic signed [7:0]  act_in = '0, wdata = '0, act_out;
    logic               first_in = 1'b0, act_valid_in = 1'b0, wsel = 1'b0;
    logic signed [31:0] psum_in = '0, psum_out;
    logic               first_out, act_valid_out, psum_valid;

    pe dut (.*);

    always #5 clk = ~clk;
    task automatic tick(); @(posedge clk); #1; endtask

    task automatic load(input logic signed [7:0] w);
        wsel = 1'b1; wdata = w; tick(); wsel = 1'b0;
    endtask

    task automatic mac(input logic signed [7:0] a, input logic first, input logic signed [31:0] pin);
        act_in = a; first_in = first; act_valid_in = 1'b1; psum_in = pin;
        tick();
        act_valid_in = 1'b0; first_in = 1'b0;
    endtask

    initial begin
        tick(); tick(); reset = 1'b0;

        `TEST("a tile's first activation computes with the loaded weight")
        load(8'sd5);
        mac(8'sd3, 1'b1, 32'sd10);
        `CHECK_EQ(psum_out, 32'sd25, "5*3 + 10")
        `CHECK(psum_valid && act_valid_out && first_out, "valid and flip pass through")
        `CHECK_EQ(act_out, 8'sd3, "activation passes right")

        `TEST("later activations keep using it")
        mac(8'sd4, 1'b0, 32'sd0);
        `CHECK_EQ(psum_out, 32'sd20, "5*4")
        `CHECK(!first_out, "no flip")

        `TEST("the next weight loads without disturbing the current one")
        load(-8'sd7);
        mac(8'sd2, 1'b0, 32'sd1);
        `CHECK_EQ(psum_out, 32'sd11, "still 5*2 + 1")
        mac(8'sd2, 1'b1, 32'sd1);
        `CHECK_EQ(psum_out, -32'sd13, "flip: -7*2 + 1")
        mac(8'sd3, 1'b0, 32'sd0);
        `CHECK_EQ(psum_out, -32'sd21, "-7*3 after the flip")

        `TEST("a write in the flip's own cycle is the next tile's weight")
        load(8'sd3);
        wsel = 1'b1; wdata = 8'sd9;
        mac(8'sd1, 1'b1, 32'sd0);
        wsel = 1'b0;
        `CHECK_EQ(psum_out, 32'sd3, "this tile flips to 3")
        mac(8'sd1, 1'b1, 32'sd0);
        `CHECK_EQ(psum_out, 32'sd9, "the next tile flips to 9")

        `TEST("int8 extremes, signed")
        load(-8'sd128);
        mac(-8'sd128, 1'b1, 32'sd0);
        `CHECK_EQ(psum_out, 32'sd16384, "-128 * -128")
        mac(8'sd127, 1'b0, -32'sd5);
        `CHECK_EQ(psum_out, -32'sd16261, "-128 * 127 - 5")

        `TEST("an invalid activation neither computes nor flips")
        load(8'sd2);
        act_in = 8'sd50; first_in = 1'b1; act_valid_in = 1'b0; tick(); first_in = 1'b0;
        `CHECK(!psum_valid, "no valid out")
        `CHECK_EQ(psum_out, -32'sd16261, "psum held")
        mac(8'sd1, 1'b1, 32'sd0);
        `CHECK_EQ(psum_out, 32'sd2, "the pending weight is still there")

        tb_done();
    end
endmodule
