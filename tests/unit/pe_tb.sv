`timescale 1ns / 1ps

// pe: weight_next loads from the weight bus while weight_current computes; a valid
// activation with the flip bit computes with weight_next and promotes it.
// partial_sum_out = weight * activation_in + partial_sum_in
module pe_tb;
    `include "check.svh"

    logic clk = 1'b0, reset = 1'b1;
    logic signed [7:0]  activation_in = '0, weight_in = '0, activation_out;
    logic               weight_flip_in = 1'b0, activation_valid_in = 1'b0, weight_valid_in = 1'b0;
    logic signed [31:0] partial_sum_in = '0, partial_sum_out;
    logic               partial_sum_valid_in = 1'b0;
    logic               weight_flip_out, activation_valid_out, partial_sum_valid_out;

    pe dut (.*);

    always #5 clk = ~clk;
    task automatic tick(); @(posedge clk); #1; endtask

    task automatic load(input logic signed [7:0] w);
        weight_valid_in = 1'b1; weight_in = w; tick(); weight_valid_in = 1'b0;
    endtask

    task automatic mac(input logic signed [7:0] a, input logic flip, input logic signed [31:0] pin);
        activation_in = a; weight_flip_in = flip; activation_valid_in = 1'b1;
        partial_sum_in = pin; partial_sum_valid_in = 1'b1;
        tick();
        activation_valid_in = 1'b0; weight_flip_in = 1'b0; partial_sum_valid_in = 1'b0;
    endtask

    initial begin
        tick(); tick(); reset = 1'b0;

        `TEST("a tile's first activation computes with the loaded weight")
        load(8'sd5);
        mac(8'sd3, 1'b1, 32'sd10);
        `CHECK_EQ(partial_sum_out, 32'sd25, "5*3 + 10")
        `CHECK(partial_sum_valid_out && activation_valid_out && weight_flip_out, "valid and flip pass through")
        `CHECK_EQ(activation_out, 8'sd3, "activation passes right")

        `TEST("later activations keep using it")
        mac(8'sd4, 1'b0, 32'sd0);
        `CHECK_EQ(partial_sum_out, 32'sd20, "5*4")
        `CHECK(!weight_flip_out, "no flip")

        `TEST("the next weight loads without disturbing the current one")
        load(-8'sd7);
        mac(8'sd2, 1'b0, 32'sd1);
        `CHECK_EQ(partial_sum_out, 32'sd11, "still 5*2 + 1")
        mac(8'sd2, 1'b1, 32'sd1);
        `CHECK_EQ(partial_sum_out, -32'sd13, "flip: -7*2 + 1")
        mac(8'sd3, 1'b0, 32'sd0);
        `CHECK_EQ(partial_sum_out, -32'sd21, "-7*3 after the flip")

        `TEST("a write in the flip's own cycle is the next tile's weight")
        load(8'sd3);
        weight_valid_in = 1'b1; weight_in = 8'sd9;
        mac(8'sd1, 1'b1, 32'sd0);
        weight_valid_in = 1'b0;
        `CHECK_EQ(partial_sum_out, 32'sd3, "this tile flips to 3")
        mac(8'sd1, 1'b1, 32'sd0);
        `CHECK_EQ(partial_sum_out, 32'sd9, "the next tile flips to 9")

        `TEST("int8 extremes, signed")
        load(-8'sd128);
        mac(-8'sd128, 1'b1, 32'sd0);
        `CHECK_EQ(partial_sum_out, 32'sd16384, "-128 * -128")
        mac(8'sd127, 1'b0, -32'sd5);
        `CHECK_EQ(partial_sum_out, -32'sd16261, "-128 * 127 - 5")

        `TEST("an invalid activation neither computes nor flips, even with a valid partial sum")
        load(8'sd2);
        activation_in = 8'sd50; weight_flip_in = 1'b1; activation_valid_in = 1'b0; partial_sum_valid_in = 1'b1;
        tick();
        weight_flip_in = 1'b0; partial_sum_valid_in = 1'b0;
        `CHECK(!partial_sum_valid_out, "no valid out")
        `CHECK_EQ(partial_sum_out, -32'sd16261, "psum held")
        mac(8'sd1, 1'b1, 32'sd0);
        `CHECK_EQ(partial_sum_out, 32'sd2, "the pending weight is still there")

        tb_done();
    end
endmodule
