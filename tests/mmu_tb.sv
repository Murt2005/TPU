`timescale 1ns / 1ps

module mmu_tb;
    logic clk;
    logic reset;
    logic loading_phase;
    logic capture_weight_col0;
    logic capture_weight_col1;

    logic signed [7:0] row0_in, row1_in;
    logic signed [7:0] col0_in, col1_in;
    logic signed [15:0] partial_sum_out_0, partial_sum_out_1;

    mmu uut (.*);

    always #5 clk = ~clk;

    initial begin
        clk = 0; reset = 1;
        loading_phase = 0; capture_weight_col0 = 0; capture_weight_col1 = 0;
        row0_in = 0; row1_in = 0; col0_in = 0; col1_in = 0;
        
        #15 reset = 0; #10;

        // --- Phase 1: Load Weights First ---
        // Matrix W:
        // [4, 5]
        // [2, 3]
        // Cycle 0: Feed row0 weights (W00=2 into col0, W01=3 into col1)
        loading_phase = 1; capture_weight_col0 = 1; capture_weight_col1 = 1;
        col0_in = 8'd2; col1_in = 8'd3;
        #10;
        
        // Cycle 1: Push row0 weights down to row1 PEs, feed row1 weights into row0 PEs
        // (W10=4 into col0, W11=5 into col1)
        col0_in = 8'd4; col1_in = 8'd5;
        #10;
        
        // Stop weight loading
        loading_phase = 0; capture_weight_col0 = 0; capture_weight_col1 = 0;
        col0_in = 0; col1_in = 0;
        #10;

        // --- Phase 2: Load Staggered Activations ---
        // Matrix A:
        //  [1, 2]
        //  [3, 4]
        // T0: row0_in gets A00 (1)
        row0_in = 8'd1;  row1_in = 8'd0;
        #10;
        
        // T1: row0_in gets A10 (3), row1_in gets A01 (2)
        row0_in = 8'd3;  row1_in = 8'd2;
        #10;
        
        // T2: row0_in gets 0, row1_in gets A11 (4)
        row0_in = 8'd0;  row1_in = 8'd4;
        #10;
        
        // T3: Clear inputs, flush the rest out
        row1_in = 8'd0;
        
        // Keep cycling to let outputs stream out the bottom
        #40;
        $finish;
    end

    // Monitor Outputs
    initial begin
        $monitor("Time=%0t | Psum_Col0=%d | Psum_Col1=%d", $time, partial_sum_out_0, partial_sum_out_1);
    end

    initial begin
        $dumpfile("mmu_simulation.vcd");
        $dumpvars(0, mmu_tb);
    end
endmodule
