// the PE's pins, for its driver and monitor
interface pe_if (input logic clk);
    logic               reset;
    logic signed [7:0]  activation_in;
    logic               activation_valid_in;
    logic               weight_flip_in;
    logic signed [31:0] partial_sum_in;
    logic               partial_sum_valid_in;
    logic signed [7:0]  weight_in;
    logic               weight_valid_in;
    logic signed [7:0]  activation_out;
    logic               activation_valid_out;
    logic               weight_flip_out;
    logic signed [31:0] partial_sum_out;
    logic               partial_sum_valid_out;
endinterface
