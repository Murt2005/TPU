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

    int errors = 0; // Track failures

    pe uut (.*);

    always #5 clk = ~clk;

    // --- HELPER TASK FOR SELF-CHECKING ---
    task check_compute(
        input logic signed [7:0]  test_activation,
        input logic signed [15:0] test_partial_sum,
        input logic signed [15:0] expected_partial_sum,
        input logic signed [7:0]  expected_activation
    );
        begin
            in_activation = test_activation;
            in_partial_sum = test_partial_sum;
            @(posedge clk);
            #1;
            
            if (out_partial_sum !== expected_partial_sum || out_activation !== expected_activation) begin
                $error("[FAIL] Time: %0t | Activation: %d, Partial Sum In: %d | Got: %d (Expected: %d)", 
                       $time, test_activation, test_partial_sum, out_partial_sum, expected_partial_sum);
                errors++;
            end else begin
                $display("[PASS] Time: %0t | Partial Sum Out: %d", $time, out_partial_sum);
            end
        end
    endtask

    initial begin
        clk = 0; reset = 1;
        in_activation = 0; in_partial_sum = 0;
        loading_phase = 0; capture_weight = 0; in_weight = 0;
        
        #15 reset = 0;

        // --- STEP 1: LOAD WEIGHT ---
        @(posedge clk);
        loading_phase = 1; capture_weight = 1; in_weight = 8'd5;
        @(posedge clk);
        loading_phase = 0; capture_weight = 0; in_weight = 8'd0;

        // --- STEP 2: TEST CASES ---
        $display("--- Starting PE Compute Tests ---");
        
        // Normal positive numbers: 5 * 3 + 10 = 25
        check_compute(8'd3, 16'd10, 16'd25, 8'd3);
        
        // Negative activation: 5 * (-2) + 0 = -10
        check_compute(-8'd2, 16'd0, -16'd10, -8'd2);
        
        // Zero activation: 5 * 0 + 100 = 100
        check_compute(8'd0, 16'd100, 16'd100, 8'd0);
        
        // Edge case (Max positive 8-bit): 5 * 127 + 0 = 635
        check_compute(8'd127, 16'd0, 16'd635, 8'd127);

        // --- SUMMARY ---
        if (errors == 0) $display("\n>>> ALL PE TESTS PASSED! <<<");
        else $display("\n>>> %d PE TESTS FAILED <<<", errors);

        $finish;
    end

    initial begin
        $dumpfile("pe_simulation.vcd");
        $dumpvars(0, pe_tb);
    end
endmodule
