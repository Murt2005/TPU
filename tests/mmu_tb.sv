`timescale 1ns / 1ps

module mmu_tb;
    logic                clk;
    logic                reset;
    logic                loading_phase;
    logic                capture_weight_col_0;
    logic                capture_weight_col_1;

    logic signed [7:0]   in_row_0, in_row_1;
    logic                in_row_0_valid, in_row_1_valid;
    
    logic signed [7:0]   in_col_0, in_col_1;
    logic                in_col_0_valid, in_col_1_valid;
    
    logic signed [15:0]  out_partial_sum_0, out_partial_sum_1;
    logic                out_partial_sum_0_valid, out_partial_sum_1_valid;

    // Instantiate MMU
    mmu uut (.*);

    // Clock generator (10ns period)
    always #5 clk = ~clk;

    // --- Dynamic Telemetry Logger ---
    always @(negedge clk) begin
        if (!reset) begin
            $display("[Time=%0t] --- Mode: %s ---", $time, loading_phase ? "WEIGHT LOAD" : "COMPUTE");
            
            // PE00 Telemetry
            $display("  PE00 | Act: In=%2d (V:%b), Out=%2d | Weight: In=%2d (V:%b), Reg=%2d | PSum: In=%2d (V:%b), Out=%2d (V:%b)",
                     uut.pe00.in_activation,  uut.pe00.in_activation_valid,  uut.pe00.out_activation,
                     uut.pe00.in_weight,      uut.pe00.in_weight_valid,      uut.pe00.weight_reg,
                     uut.pe00.in_partial_sum, uut.pe00.in_partial_sum_valid, uut.pe00.out_partial_sum, uut.pe00.out_partial_sum_valid);
            
            // PE01 Telemetry
            $display("  PE01 | Act: In=%2d (V:%b), Out=%2d | Weight: In=%2d (V:%b), Reg=%2d | PSum: In=%2d (V:%b), Out=%2d (V:%b)",
                     uut.pe01.in_activation,  uut.pe01.in_activation_valid,  uut.pe01.out_activation,
                     uut.pe01.in_weight,      uut.pe01.in_weight_valid,      uut.pe01.weight_reg,
                     uut.pe01.in_partial_sum, uut.pe01.in_partial_sum_valid, uut.pe01.out_partial_sum, uut.pe01.out_partial_sum_valid);
            
            // PE10 Telemetry
            $display("  PE10 | Act: In=%2d (V:%b), Out=%2d | Weight: In=%2d (V:%b), Reg=%2d | PSum: In=%2d (V:%b), Out=%2d (V:%b)",
                     uut.pe10.in_activation,  uut.pe10.in_activation_valid,  uut.pe10.out_activation,
                     uut.pe10.in_weight,      uut.pe10.in_weight_valid,      uut.pe10.weight_reg,
                     uut.pe10.in_partial_sum, uut.pe10.in_partial_sum_valid, uut.pe10.out_partial_sum, uut.pe10.out_partial_sum_valid);
            
            // PE11 Telemetry
            $display("  PE11 | Act: In=%2d (V:%b), Out=%2d | Weight: In=%2d (V:%b), Reg=%2d | PSum: In=%2d (V:%b), Out=%2d (V:%b)",
                     uut.pe11.in_activation,  uut.pe11.in_activation_valid,  uut.pe11.out_activation,
                     uut.pe11.in_weight,      uut.pe11.in_weight_valid,      uut.pe11.weight_reg,
                     uut.pe11.in_partial_sum, uut.pe11.in_partial_sum_valid, uut.pe11.out_partial_sum, uut.pe11.out_partial_sum_valid);
                     
            $display("  SYSTEM OUTPUTS | Col0 PSum = %4d (Valid: %b) | Col1 PSum = %4d (Valid: %b)", 
                     out_partial_sum_0, out_partial_sum_0_valid, out_partial_sum_1, out_partial_sum_1_valid);
            $display("-------------------------------------------------------------------------------------------------------");
        end
    end

    // --- Drive Test Signals ---
    initial begin
        // Reset state initialization
        clk                  = 0; 
        reset                = 1;
        loading_phase        = 0; 
        capture_weight_col_0 = 0; 
        capture_weight_col_1 = 0;
        in_row_0             = 0; 
        in_row_0_valid       = 0; 
        in_row_1             = 0; 
        in_row_1_valid       = 0;
        in_col_0             = 0; 
        in_col_0_valid       = 0; 
        in_col_1             = 0; 
        in_col_1_valid       = 0;
        
        #15;
        @(posedge clk);
        #1 reset = 0; 
        
        $display("\n=== STARTING MMU TESTBENCH EXECUTION ===\n");

        // ------------------------------------------
        // PHASE 1: STAGGERED STATIONARY WEIGHT LOADING
        // Target Weight Matrix:
        //  [4, 5]
        //  [2, 3]
        // ------------------------------------------
        @(posedge clk);
        #1;
        loading_phase        = 1; 
        capture_weight_col_0 = 1; 
        capture_weight_col_1 = 1;
        
        // Cycle 0: Inject bottom weights (row 1 weights) into the top ports
        in_col_0       = 8'sd2; in_col_0_valid = 1'b1; 
        in_col_1       = 8'sd3; in_col_1_valid = 1'b1;
        
        @(posedge clk);
        #1;
        // Cycle 1: Push bottom weights down to row 1 PEs, inject top weights (row 0 weights)
        in_col_0       = 8'sd4; in_col_0_valid = 1'b1; 
        in_col_1       = 8'sd5; in_col_1_valid = 1'b1;
        
        // At the next edge, PE00/PE01 capture [4,5] and PE10/PE11 capture [2,3]
        @(posedge clk);
        #1;
        loading_phase        = 0; 
        capture_weight_col_0 = 0; 
        capture_weight_col_1 = 0;
        in_col_0             = 0; in_col_0_valid = 1'b0; 
        in_col_1             = 0; in_col_1_valid = 1'b0;

        // Give the pipeline one idle tick to settle
        @(posedge clk);
        
        // ------------------------------------------
        // PHASE 2: SYSTOLIC STAGGERED DATA STREAMING
        // Target Activation Matrix (A):
        //  [1, 2]
        //  [3, 4]
        // Expected Matrix Multiplication Output:
        //  C = A * W => [1*4 + 2*2,  1*5 + 2*3] = [8,  11]
        //               [3*4 + 4*2,  3*5 + 4*3] = [20, 27]
        // ------------------------------------------
        
        // Cycle 0: Feed A[0][0]=1 to Row 0. Row 1 waits.
        @(posedge clk);
        #1;
        in_row_0 = 8'sd1; in_row_0_valid = 1'b1;
        in_row_1 = 8'sd0; in_row_1_valid = 1'b0;
        
        // Cycle 1: Stagger step. Feed A[1][0]=3 to Row 0, feed A[0][1]=2 to Row 1.
        @(posedge clk);
        #1;
        in_row_0 = 8'sd3; in_row_0_valid = 1'b1;
        in_row_1 = 8'sd2; in_row_1_valid = 1'b1;
        
        // Cycle 2: Feed A[1][1]=4 to Row 1. Row 0 data stream is exhausted.
        @(posedge clk);
        #1;
        in_row_0 = 8'sd0; in_row_0_valid = 1'b0;
        in_row_1 = 8'sd4; in_row_1_valid = 1'b1;
        
        // Cycle 3: All matrix data sent. Pull inputs to idle, wait for computations to flush.
        @(posedge clk);
        #1;
        in_row_0 = 8'sd0; in_row_0_valid = 1'b0;
        in_row_1 = 8'sd0; in_row_1_valid = 1'b0;
        
        // Keep clock cycling to observe output accumulation results completely clearing out
        #40;
        
        $display("\n=== SIMULATION COMPLETE ===\n");
        $finish;
    end

    // --- Waveform Dump ---
    initial begin
        $dumpfile("mmu_simulation.vcd");
        $dumpvars(0, mmu_tb);
    end
endmodule
