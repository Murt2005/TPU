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

    // --- Internal Wire States ---
    // Captures every port and internal register on the falling edge of the clock
    always @(negedge clk) begin
        if (!reset) begin
            $display("[Time=%0t] --- Mode: %s ---", $time, loading_phase ? "WEIGHT LOAD" : "COMPUTE");
            
            // PE00
            $display("  PE00 | Act: In=%3d, Out=%3d | Weight: In=%3d, Out=%3d, Internal=%3d | PSum: In=%5d, Out=%5d",
                     uut.pe00.in_activation,  uut.pe00.out_activation,
                     uut.pe00.in_weight,      uut.pe00.out_weight,     uut.pe00.weight,
                     uut.pe00.in_partial_sum, uut.pe00.out_partial_sum);
            
            // PE01 Telemetry
            $display("  PE01 | Act: In=%3d, Out=%3d | Weight: In=%3d, Out=%3d, Internal=%3d | PSum: In=%5d, Out=%5d",
                     uut.pe01.in_activation,  uut.pe01.out_activation,
                     uut.pe01.in_weight,      uut.pe01.out_weight,     uut.pe01.weight,
                     uut.pe01.in_partial_sum, uut.pe01.out_partial_sum);
            
            // PE10 Telemetry
            $display("  PE10 | Act: In=%3d, Out=%3d | Weight: In=%3d, Out=%3d, Internal=%3d | PSum: In=%5d, Out=%5d",
                     uut.pe10.in_activation,  uut.pe10.out_activation,
                     uut.pe10.in_weight,      uut.pe10.out_weight,     uut.pe10.weight,
                     uut.pe10.in_partial_sum, uut.pe10.out_partial_sum);
            
            // PE11 Telemetry
            $display("  PE11 | Act: In=%3d, Out=%3d | Weight: In=%3d, Out=%3d, Internal=%3d | PSum: In=%5d, Out=%5d",
                     uut.pe11.in_activation,  uut.pe11.out_activation,
                     uut.pe11.in_weight,      uut.pe11.out_weight,     uut.pe11.weight,
                     uut.pe11.in_partial_sum, uut.pe11.out_partial_sum);
                     
            $display("  MMU OUTPUTS | Psum_Col0 = %5d | Psum_Col1 = %5d", partial_sum_out_0, partial_sum_out_1);
            $display("-------------------------------------------------------------------------------------------------------");
        end
    end

    initial begin
        // Initialize everything
        clk = 0; reset = 1;
        loading_phase = 0; capture_weight_col0 = 0; capture_weight_col1 = 0;
        row0_in = 0; row1_in = 0; col0_in = 0; col1_in = 0;
        
        #15 reset = 0; #10;

        $display("\n=== STARTING TESTBENCH EXECUTION ===\n");

        // --- PHASE 1: LOAD WEIGHTS ---
        // Matrix W:
        // [4, 5]
        // [2, 3]
        loading_phase = 1; capture_weight_col0 = 1; capture_weight_col1 = 1;
        
        // Cycle 0: Feed row0 weights down
        col0_in = 8'd2; col1_in = 8'd3;
        #10;
        
        // Cycle 1: Push row0 weights to row1 PEs, feed row1 weights into row0 PEs
        col0_in = 8'd4; col1_in = 8'd5;
        #10;
        
        // Disable weight loading phase
        loading_phase = 0; capture_weight_col0 = 0; capture_weight_col1 = 0;
        col0_in = 0; col1_in = 0;
        #10;

        // --- PHASE 2: COMPUTE STAGGERED ACTIVATIONS ---
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
        
        // Clear all inputs and let data stream completely out the bottom of the array
        row0_in = 8'd0;  row1_in = 8'd0;
        #20;
        
        $display("\n=== SIMULATION COMPLETE ===\n");
        $finish;
    end

    initial begin
        $dumpfile("mmu_simulation.vcd");
        $dumpvars(0, mmu_tb);
    end
endmodule
