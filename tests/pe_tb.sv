`timescale 1ns / 1ps

module pe_tb;
    logic clk;
    logic reset;
    logic signed [7:0]  in_activation;
    logic signed [7:0]  out_activation;
    logic signed [15:0] in_partial_sum;
    logic signed [15:0] out_partial_sum;
    logic               loading_phase;
    logic               capture_weight;
    logic signed [7:0]  in_weight;
    logic signed [7:0]  out_weight;

    // UUT Instance
    pe uut (.*);

    // Clock Generation
    always #5 clk = ~clk;

    initial begin
        clk = 0;
        reset = 1;
        in_activation = 0;
        in_partial_sum = 0;
        loading_phase = 0;
        capture_weight = 0;
        in_weight = 0;
        
        #10;
        reset = 0;
        #10;

        // Load Weight = 5
        loading_phase = 1;
        capture_weight = 1;
        in_weight = 8'd5;
        #10;
        
        // Turn off loading flags
        loading_phase = 0;
        capture_weight = 0;
        in_weight = 8'd0;
        #10;

        // Step 2: Test Compute Mode (5 * 3 + 10 = 25)
        in_activation = 8'd3;
        in_partial_sum = 16'd10;
        #10;
        $display("[TB] Out Partial_Sum: %d (Expected: 25)", out_partial_sum);
        $display("[TB] Out Activation  : %d (Expected: 3)", out_activation);
        
        // Step 3: Negative numbers test (5 * -2 + 0 = -10)
        in_activation = -8'd2;
        in_partial_sum = 16'd0;
        #10;
        $display("[TB] Out Partial_Sum: %d (Expected: -10)", out_partial_sum);

        reset = 1;
        #10;

        $finish;
    end

    initial begin
        $dumpfile("pe_simulation.vcd");
        $dumpvars(0, pe_tb);
    end
endmodule
